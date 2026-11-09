package libxray

import (
	"encoding/json"
	"net/netip"
	"testing"
)

func routesOf(t *testing.T, lanDirect bool) (v4, v6 []tunRoute) {
	t.Helper()
	var r struct {
		IPv4 []tunRoute `json:"ipv4"`
		IPv6 []tunRoute `json:"ipv6"`
	}
	if err := json.Unmarshal([]byte(TunnelRoutes(lanDirect)), &r); err != nil {
		t.Fatal(err)
	}
	return r.IPv4, r.IPv6
}

func inRoutes(ip string, routes []tunRoute) bool {
	addr := netip.MustParseAddr(ip)
	for _, r := range routes {
		if netip.PrefixFrom(netip.MustParseAddr(r.Address), r.Prefix).Contains(addr) {
			return true
		}
	}
	return false
}

func TestLanAndMulticastStayOutOfTheTunnel(t *testing.T) {
	v4, v6 := routesOf(t, true)
	for _, local := range []string{"192.168.1.50", "10.0.0.1", "172.16.5.5", "172.31.255.255", "169.254.1.1", "224.0.0.251", "239.255.255.250", "255.255.255.255"} {
		if inRoutes(local, v4) {
			t.Errorf("%s goes into the tunnel", local)
		}
	}
	for _, internet := range []string{"8.8.8.8", "1.1.1.1", "172.15.255.255", "172.32.0.1", "100.64.0.1", "223.255.255.255", "77.88.8.8"} {
		if !inRoutes(internet, v4) {
			t.Errorf("%s misses the tunnel", internet)
		}
	}
	for _, local := range []string{"fe80::1", "fd00::1", "ff02::fb"} {
		if inRoutes(local, v6) {
			t.Errorf("%s goes into the tunnel", local)
		}
	}
	for _, internet := range []string{"2a00:1450:4010::1", "2001:4860:4860::8888"} {
		if !inRoutes(internet, v6) {
			t.Errorf("%s misses the tunnel", internet)
		}
	}
}

func TestFewRoutes(t *testing.T) {
	// The smallest split of the address space around the local ranges: a few dozen prefixes.
	v4, v6 := routesOf(t, true)
	if len(v4) >= 50 || len(v6) >= 20 {
		t.Errorf("%d IPv4 and %d IPv6 routes", len(v4), len(v6))
	}
	v4, v6 = routesOf(t, false)
	if len(v4) != 1 || v4[0] != (tunRoute{"0.0.0.0", 0}) || len(v6) != 1 || v6[0] != (tunRoute{"::", 0}) {
		t.Errorf("without lanDirect: %v %v", v4, v6)
	}
}
