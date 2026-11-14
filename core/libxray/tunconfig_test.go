package libxray

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

const tunnelTemplate = `
{"remarks":"x","remnawave":{"id":1},"inbounds":[{"tag":"socks","protocol":"socks","port":10808,"sniffing":{"enabled":true}}],
 "outbounds":[{"tag":"proxy","protocol":"vless","settings":{"vnext":[{"address":"a.net","port":443}]}},{"tag":"direct","protocol":"freedom"}],
 "routing":{"rules":[{"type":"field","domain":["keyword:yandex"],"outboundTag":"direct"}]},
 "dns":{"servers":["77.88.8.8"],"queryStrategy":"UseIP"}}`

func buildTunnel(t *testing.T, raw, options string) map[string]any {
	t.Helper()
	out, err := BuildTunnelConfig(raw, options)
	if err != nil {
		t.Fatal(err)
	}
	var cfg map[string]any
	if err := json.Unmarshal([]byte(out), &cfg); err != nil {
		t.Fatal(err)
	}
	return cfg
}

func rulesOf(cfg map[string]any) []map[string]any {
	var rules []map[string]any
	for _, r := range asMap(cfg["routing"])["rules"].([]any) {
		rules = append(rules, r.(map[string]any))
	}
	return rules
}

func TestTunInboundDNSHijackAndNoAccessLog(t *testing.T) {
	out, err := BuildTunnelConfig(tunnelTemplate, `{"routing":{"enabled":false}}`)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, `"port":443`) || strings.Contains(out, `443.0`) {
		t.Errorf("numbers changed: %s", out)
	}
	cfg := buildTunnel(t, tunnelTemplate, `{"routing":{"enabled":false}}`)
	inbounds := cfg["inbounds"].([]any)
	tun := asMap(inbounds[0])
	if len(inbounds) != 1 || tun["tag"] != "tun-in" || tun["protocol"] != "tun" || asMap(tun["settings"])["mtu"] != 1500.0 {
		t.Errorf("inbounds = %v", inbounds)
	}
	// The template's sniffing is kept.
	if !reflect.DeepEqual(tun["sniffing"], map[string]any{"enabled": true}) {
		t.Errorf("sniffing = %v", tun["sniffing"])
	}
	rules := rulesOf(cfg)
	if rules[0]["outboundTag"] != "dns-out" || rules[0]["port"] != "53" || len(rules) != 2 {
		t.Errorf("rules = %v", rules)
	}
	if asMap(cfg["dns"])["queryStrategy"] != "UseIPv4" || asMap(cfg["log"])["access"] != "none" || asMap(cfg["log"])["loglevel"] != "error" {
		t.Errorf("dns/log = %v %v", cfg["dns"], cfg["log"])
	}
	if _, ok := cfg["remarks"]; ok {
		t.Error("remarks kept")
	}
	if _, ok := cfg["remnawave"]; ok {
		t.Error("remnawave kept")
	}
	system := asMap(asMap(cfg["policy"])["system"])
	if system["statsInboundUplink"] != true || system["statsInboundDownlink"] != true || cfg["stats"] == nil {
		t.Errorf("stats = %v %v", cfg["stats"], cfg["policy"])
	}
	if !hasOutboundTag(cfg["outbounds"].([]any), "dns-out") {
		t.Error("no dns-out")
	}
}

func TestDefaultOptionsSendTheLocalNetworkDirectly(t *testing.T) {
	cfg := buildTunnel(t, tunnelTemplate, "")
	rules := rulesOf(cfg)
	if len(rules) != 3 || rules[1]["outboundTag"] != "direct" || !strings.Contains(asString(rules[1]["ip"]), "192.168.0.0/16") {
		t.Errorf("rules = %v", rules)
	}
}

func asString(v any) string {
	b, _ := json.Marshal(v)
	return string(b)
}

func TestUserRulesGoBeforeServerRulesAndUseTheBalancer(t *testing.T) {
	auto := `
	{"outbounds":[{"tag":"proxy-1","protocol":"vless"},{"tag":"direct","protocol":"freedom"},{"tag":"block","protocol":"blackhole"}],
	 "routing":{"rules":[{"type":"field","protocol":["bittorrent"],"outboundTag":"direct"},
	                     {"type":"field","network":"tcp,udp","balancerTag":"Super_Balancer"}],
	            "balancers":[{"tag":"Super_Balancer","selector":["proxy"]}]}}`
	withDot := rulesOf(buildTunnel(t, auto, `{"routing":{"direct":["domain:.com","keyword:yandex"]}}`))
	if got := asString(withDot[1]["domain"]); withDot[1]["outboundTag"] != "direct" || got != `["domain:com","keyword:yandex"]` {
		t.Errorf("direct rule = %v", withDot[1])
	}

	rules := rulesOf(buildTunnel(t, auto, `{"routing":{"enabled":true,"lanDirect":true,"ruDirect":false,
	  "direct":["domain:sber.ru"],"proxy":["domain:yandex.ru"],"block":["domain:ads.example","1.2.3.4"]}}`))
	// dns hijack, block (domain, ip), direct (domain, LAN ip), proxy, then the panel's rules
	want := []string{"dns-out", "block", "block", "direct", "direct"}
	for i, tag := range want {
		if rules[i]["outboundTag"] != tag {
			t.Errorf("rule %d = %v, want %s", i, rules[i], tag)
		}
	}
	if !strings.Contains(asString(rules[4]["ip"]), "192.168.0.0/16") {
		t.Errorf("LAN rule = %v", rules[4])
	}
	if rules[5]["balancerTag"] != "Super_Balancer" || asString(rules[5]["domain"]) != `["domain:yandex.ru"]` {
		t.Errorf("proxy rule = %v", rules[5])
	}
	if asString(rules[6]["protocol"]) != `["bittorrent"]` {
		t.Errorf("panel rule = %v", rules[6])
	}

	// Without such outbounds in the template, the rules get their own.
	cfg := buildTunnel(t, `{"outbounds":[{"tag":"proxy","protocol":"vless"}]}`, `{"routing":{"lanDirect":false,"ruDirect":true,"block":["x.org"]}}`)
	rules = rulesOf(cfg)
	if rules[1]["outboundTag"] != "user-block" || rules[2]["outboundTag"] != "user-direct" || asString(rules[2]["domain"]) != `["domain:ru","domain:xn--p1ai","domain:su"]` {
		t.Errorf("rules = %v", rules)
	}
	outbounds := cfg["outbounds"].([]any)
	if !hasOutboundTag(outbounds, "user-block") || !hasOutboundTag(outbounds, "user-direct") {
		t.Errorf("outbounds = %v", outbounds)
	}
}

func TestFallbackIsTheServerThatWasBestAMomentAgo(t *testing.T) {
	auto := `
	{"outbounds":[{"tag":"proxy","protocol":"vless"},{"tag":"proxy-2","protocol":"vless"},{"tag":"direct","protocol":"freedom"}],
	 "routing":{"rules":[{"type":"field","network":"tcp,udp","balancerTag":"Super_Balancer"}],
	            "balancers":[{"tag":"Super_Balancer","selector":["proxy"],"fallbackTag":"proxy"},
	                         {"tag":"Other","selector":["eu-"]}]}}`
	balancers := func(fallback string) []any {
		cfg := buildTunnel(t, auto, `{"fallback":"`+fallback+`"}`)
		return asMap(cfg["routing"])["balancers"].([]any)
	}
	patched := balancers("proxy-2")
	if asMap(patched[0])["fallbackTag"] != "proxy-2" {
		t.Errorf("patched = %v", patched)
	}
	// Not one of that balancer's servers.
	if _, ok := asMap(patched[1])["fallbackTag"]; ok {
		t.Errorf("other balancer = %v", patched[1])
	}
	for _, fb := range []string{"gone", ""} {
		if got := asMap(balancers(fb)[0])["fallbackTag"]; got != "proxy" {
			t.Errorf("fallback %q: %v", fb, got)
		}
	}
}

func TestDNSGoesOverTCPSoEachQueryPicksALiveServer(t *testing.T) {
	template := `
	{"outbounds":[{"tag":"proxy","protocol":"vless"}],
	 "dns":{"servers":["9.9.9.9","2606:4700:4700::1111",{"address":"77.88.8.8","port":5353,"domains":["domain:ru"]},
	                   "localhost","https://dns.google/dns-query","tcp://1.1.1.1"]}}`
	dns := asMap(buildTunnel(t, template, "")["dns"])
	servers := dns["servers"].([]any)
	if servers[0] != "tcp://9.9.9.9:53" || servers[1] != "tcp://[2606:4700:4700::1111]:53" {
		t.Errorf("servers = %v", servers)
	}
	withDomains := asMap(servers[2])
	if _, port := withDomains["port"]; withDomains["address"] != "tcp://77.88.8.8:5353" || port || asString(withDomains["domains"]) != `["domain:ru"]` {
		t.Errorf("server with domains = %v", withDomains)
	}
	if asString(servers[3:]) != `["localhost","https://dns.google/dns-query","tcp://1.1.1.1"]` {
		t.Errorf("others = %v", servers[3:])
	}
	if dns["serveStale"] != true || dns["queryStrategy"] != "UseIPv4" {
		t.Errorf("dns = %v", dns)
	}
	// No dns section: public resolvers.
	dns = asMap(buildTunnel(t, `{"outbounds":[{"tag":"proxy","protocol":"vless"}]}`, "")["dns"])
	if asString(dns["servers"]) != `["tcp://1.1.1.1:53","tcp://8.8.8.8:53"]` {
		t.Errorf("default dns = %v", dns)
	}
	// A dns section with hosts only: the same, and the hosts stay.
	dns = asMap(buildTunnel(t, `{"outbounds":[{"tag":"proxy","protocol":"vless"}],"dns":{"hosts":{"a.example":"1.2.3.4"}}}`, "")["dns"])
	if asString(dns["servers"]) != `["tcp://1.1.1.1:53","tcp://8.8.8.8:53"]` || dns["hosts"] == nil {
		t.Errorf("dns with hosts only = %v", dns)
	}
}

func TestTunnelConfigStarts(t *testing.T) {
	// What BuildTunnelConfig makes must be a config Xray accepts (the TUN itself is not opened here).
	auto := `{"remarks":"🇪🇺 Автовыбор",
	 "outbounds":[{"tag":"proxy","protocol":"vless","settings":{"vnext":[{"address":"a.net","port":443,"users":[{"id":"6a3e1e1e-0000-4000-8000-000000000000","encryption":"none"}]}]},"streamSettings":{"network":"tcp","security":"tls","tlsSettings":{"serverName":"a.net"}}},
	              {"tag":"direct","protocol":"freedom"},{"tag":"block","protocol":"blackhole"}],
	 "routing":{"rules":[{"type":"field","network":"tcp,udp","balancerTag":"auto"}],
	            "balancers":[{"tag":"auto","selector":["proxy"],"strategy":{"type":"leastPing"}}]},
	 "burstObservatory":{"subjectSelector":["proxy"],"pingConfig":{"destination":"https://www.gstatic.com/generate_204","interval":"1m","sampling":1,"timeout":"3s"}},
	 "dns":{"servers":[{"address":"77.88.8.8","domains":["full:a.net"]},"https://8.8.8.8/dns-query"]}}`
	out, err := BuildTunnelConfig(auto, `{"routing":{"ruDirect":true,"block":["ads.example","regexp:^x"],"proxy":["1.2.3.0/24","keyword:tg"]},"fallback":"proxy"}`)
	if err != nil {
		t.Fatal(err)
	}
	if err := ValidateConfig(out); err != nil {
		t.Fatal(err)
	}
}

func TestTunnelBoundToThePhonesInterface(t *testing.T) {
	raw := `{"outbounds":[{"tag":"proxy","protocol":"vless","settings":{"vnext":[{"address":"1.2.3.4","port":443,
	  "users":[{"id":"27848739-7e62-4138-9fd3-098a63964b6b","encryption":"none"}]}]},
	  "streamSettings":{"security":"tls","tlsSettings":{"serverName":"x.example"}}},
	  {"tag":"direct","protocol":"freedom"}]}`
	out, err := BuildTunnelConfig(raw, `{"interface":"pdp_ip0"}`)
	if err != nil {
		t.Fatal(err)
	}
	cfg := mustParse(t, out)
	tun := asMap(asMap(cfg["inbounds"].([]any)[0])["settings"])
	if tun["autoOutboundsInterface"] != "pdp_ip0" {
		t.Errorf("tun settings = %v", tun)
	}
	for _, o := range cfg["outbounds"].([]any) {
		if got := asMap(asMap(asMap(o)["streamSettings"])["sockopt"])["interface"]; got != "pdp_ip0" {
			t.Errorf("%v: interface %v", asMap(o)["tag"], got)
		}
	}
	if err := ValidateConfig(out); err != nil {
		t.Errorf("Xray refuses it: %v", err)
	}
	plain, _ := BuildTunnelConfig(raw, `{}`)
	if strings.Contains(plain, "autoOutboundsInterface") || strings.Contains(plain, `"interface"`) {
		t.Error("bound without an interface")
	}
}
