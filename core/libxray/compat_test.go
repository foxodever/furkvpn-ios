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
}
