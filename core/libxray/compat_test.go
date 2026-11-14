package libxray

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestPinTunnelServers(t *testing.T) {
	raw := `{"dns":{"servers":[{"address":"127.0.0.1","port":1,"domains":["domain:invalid"]}]},
	  "outbounds":[
	  {"tag":"proxy","protocol":"vless","settings":{"vnext":[{"address":"1.2.3.4","port":443}]}},
	  {"tag":"proxy-2","protocol":"trojan","settings":{"servers":[{"address":"[2001:db8::1]","port":443}]}},
	  {"tag":"wg","protocol":"wireguard","settings":{"peers":[{"endpoint":"5.6.7.8:51820"}]}},
	  {"tag":"proxy-3","protocol":"vless","settings":{"vnext":[{"address":"no-such-host.invalid","port":443}]}},
	  {"tag":"direct","protocol":"freedom"}]}`
	var answer struct {
		Config  string
		Exclude []string
	}
	if err := json.Unmarshal([]byte(PinTunnelServers(raw)), &answer); err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(answer.Exclude, ","); got != "1.2.3.4,2001:db8::1,5.6.7.8" {
		t.Errorf("exclude = %s", got)
	}
	if !strings.Contains(answer.Config, "no-such-host.invalid") || !strings.Contains(answer.Config, `"1.2.3.4"`) {
		t.Errorf("config = %s", answer.Config)
	}
	if json.Unmarshal([]byte(PinTunnelServers("not json")), &answer) != nil || answer.Config != "not json" || len(answer.Exclude) != 0 {
		t.Errorf("garbage: %+v", answer)
	}
}

func TestSubscriptionServers(t *testing.T) {
	configs := []string{
		`{"outbounds":[{"tag":"proxy","protocol":"vless","settings":{"vnext":[{"address":"NL.example.com","port":443}]}},{"tag":"direct","protocol":"freedom"}]}`,
		`{"outbounds":[{"tag":"proxy","protocol":"trojan","settings":{"servers":[{"address":"[2001:db8::1]","port":443}]}},
		  {"tag":"proxy-2","protocol":"vless","settings":{"vnext":[{"address":"nl.example.com","port":443}]}}]}`,
		"not json",
	}
	b, _ := json.Marshal(configs)
	if got := SubscriptionServers(string(b)); got != "nl.example.com,2001:db8::1" {
		t.Errorf("servers = %s", got)
	}
	if got := SubscriptionServers("garbage"); got != "" {
		t.Errorf("garbage = %s", got)
	}
}

func TestResolveServers(t *testing.T) {
	var answer struct {
		Addresses map[string]string
		Exclude   []string
	}
	if err := json.Unmarshal([]byte(ResolveServers("1.2.3.4, [2001:db8::1],no-such-host.invalid,127.0.0.1,1.2.3.4")), &answer); err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(answer.Exclude, ","); got != "1.2.3.4,2001:db8::1" {
		t.Errorf("exclude = %s", got)
	}
	if len(answer.Addresses) != 0 {
		t.Errorf("addresses = %v", answer.Addresses)
	}
}

func TestSetServerAddresses(t *testing.T) {
	SetServerAddresses(`{"Server.Invalid":"10.1.2.3","bad":"x"}`)
	defer SetServerAddresses("{}")
	if ip, err := lookupServer(nil, "server.invalid"); err != nil || ip.String() != "10.1.2.3" {
		t.Errorf("given address: %v %v", ip, err)
	}
	SetServerAddresses("{}")
	if _, err := lookupServer(nil, "server.invalid"); err == nil {
		t.Error("forgotten address still used")
	}
}

func TestNoDirect(t *testing.T) {
	raw := `{"outbounds":[
	  {"tag":"direct","protocol":"freedom"},
	  {"tag":"proxy","protocol":"vless","settings":{"vnext":[{"address":"1.2.3.4","port":443}]}},
	  {"tag":"block","protocol":"blackhole"}],
	  "routing":{"rules":[
	    {"type":"field","domain":["geosite:category-ru"],"outboundTag":"direct"},
	    {"type":"field","domain":["ads.example"],"outboundTag":"block"},
	    {"type":"field","network":"tcp,udp","outboundTag":"direct"}]}}`
	out, err := BuildTunnelConfig(raw, `{"noDirect":true,"routing":{"ruDirect":true}}`)
	if err != nil {
		t.Fatal(err)
	}
	var cfg struct {
		Routing struct{ Rules []map[string]any }
	}
	if err := json.Unmarshal([]byte(out), &cfg); err != nil {
		t.Fatal(err)
	}
	blocked := false
	for _, r := range cfg.Routing.Rules {
		if r["outboundTag"] == "direct" {
			t.Errorf("rule still direct: %v", r)
		}
		blocked = blocked || r["outboundTag"] == "block"
	}
	last := cfg.Routing.Rules[len(cfg.Routing.Rules)-1]
	if !blocked || last["outboundTag"] != "proxy" || last["network"] != "tcp,udp" {
		t.Errorf("rules = %v", cfg.Routing.Rules)
	}
	// Without the option direct rules stay.
	out, _ = BuildTunnelConfig(raw, `{}`)
	if !strings.Contains(out, `"outboundTag":"direct"`) {
		t.Error("direct rules gone without noDirect")
	}

	// A freedom outbound without a tag: the balancer's rules (no outboundTag) are not direct ones.
	balanced := `{"outbounds":[
	  {"protocol":"freedom"},
	  {"tag":"proxy-1","protocol":"vless","settings":{"vnext":[{"address":"1.2.3.4","port":443}]}},
	  {"tag":"proxy-2","protocol":"vless","settings":{"vnext":[{"address":"5.6.7.8","port":443}]}}],
	  "routing":{"rules":[
	    {"type":"field","domain":["domain:netflix.com"],"balancerTag":"eu"},
	    {"type":"field","network":"tcp,udp","balancerTag":"auto"}],
	   "balancers":[{"tag":"eu","selector":["proxy-2"]},{"tag":"auto","selector":["proxy"]}]}}`
	rules := rulesOf(buildTunnel(t, balanced, `{"noDirect":true}`))
	found := false
	for _, r := range rules {
		if asString(r["domain"]) == `["domain:netflix.com"]` {
			found = true
			if r["balancerTag"] != "eu" {
				t.Errorf("balancer rule retargeted: %v", r)
			}
		}
	}
	if !found {
		t.Errorf("rules = %v", rules)
	}
}

// "Through VPN" goes to a server even when the panel's catch-all sends everything else direct.
func TestThroughVPNNeverMeansDirect(t *testing.T) {
	raw := `{"outbounds":[
	  {"tag":"direct","protocol":"freedom"},
	  {"tag":"proxy","protocol":"vless","settings":{"vnext":[{"address":"1.2.3.4","port":443}]}}],
	  "routing":{"rules":[{"type":"field","network":"tcp,udp","outboundTag":"direct"}]}}`
	rules := rulesOf(buildTunnel(t, raw, `{"routing":{"lanDirect":false,"proxy":["domain:instagram.com"]}}`))
	for _, r := range rules {
		if asString(r["domain"]) == `["domain:instagram.com"]` && r["outboundTag"] != "proxy" {
			t.Errorf("through VPN rule = %v", r)
		}
	}
}
