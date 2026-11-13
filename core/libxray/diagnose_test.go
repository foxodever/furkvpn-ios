package libxray

import (
	"net"
	"strings"
	"testing"
)

func TestServerEndpoints(t *testing.T) {
	cfg := mustParse(t, `{"outbounds":[
	  {"tag":"proxy","protocol":"vless","settings":{"vnext":[{"address":"de.example.net","port":443}]}},
	  {"tag":"hy","protocol":"hysteria","settings":{"address":"1.2.3.4","port":8443}},
	  {"tag":"direct","protocol":"freedom"}]}`)
	got := serverEndpoints(cfg)
	if len(got) != 2 || got[0] != (serverEndpoint{"proxy", "de.example.net", 443, false}) || got[1] != (serverEndpoint{"hy", "1.2.3.4", 8443, true}) {
		t.Errorf("endpoints = %+v", got)
	}
	if DiagnoseRunning("https://example.com", "") != "ядро не запущено" {
		t.Error("diagnosed without a core")
	}
}

func TestProbeAndInterfaces(t *testing.T) {
	if UsableInterfaces("lo, no-such-if0,,") != "" {
		t.Error("loopback or a missing interface counted as usable")
	}
	got := ProbeNetwork(" ,no-such-if0")
	for _, key := range []string{`"unbound":`, `"no-such-if0":`} {
		if !strings.Contains(got, key) {
			t.Errorf("probe %s lacks %s", got, key)
		}
	}
	if InterfaceSummary() == "" {
		t.Error("empty interface summary")
	}
}

func TestNetworkSignature(t *testing.T) {
	ip := func(s ...string) []net.IP {
		var ips []net.IP
		for _, a := range s {
			ips = append(ips, net.ParseIP(a))
		}
		return ips
	}
	cases := []struct {
		name      string
		addresses map[string][]net.IP
		want      string
	}{
		{"wifi, cellular under it left out", map[string][]net.IP{"en0": ip("192.168.1.5", "2a00::5"), "pdp_ip0": ip("10.1.2.3"), "utun4": ip("172.19.0.1")}, "en0 192.168.1.5 +IPv6"},
		{"cellular", map[string][]net.IP{"pdp_ip0": ip("10.1.2.3", "2a00::7"), "pdp_ip1": ip("2a00::8"), "utun4": ip("172.19.0.1")}, "pdp_ip0 10.1.2.3 +IPv6"},
		{"cellular, IPv6 only", map[string][]net.IP{"pdp_ip0": ip("2a00::7")}, "pdp_ip0 +IPv6"},
		{"two en, sorted", map[string][]net.IP{"en1": ip("10.0.0.2"), "en0": ip("192.168.1.5", "192.168.1.4")}, "en0 192.168.1.4,192.168.1.5 · en1 10.0.0.2"},
		{"not en", map[string][]net.IP{"enx": ip("10.0.0.2"), "bridge100": ip("172.20.10.1")}, ""},
		{"none", map[string][]net.IP{"utun4": ip("172.19.0.1")}, ""},
	}
	for _, c := range cases {
		if got := networkSignature(c.addresses); got != c.want {
			t.Errorf("%s: %q, want %q", c.name, got, c.want)
		}
	}
}
