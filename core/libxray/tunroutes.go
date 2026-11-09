package libxray

import (
	"encoding/json"
	"math/big"
	"net/netip"
)

// What the tunnel takes: everything, or with "LAN directly" on (Settings → Routing, on by default)
// everything but the local network. Leaving it out of the routes, not only sending it direct in
// Xray, keeps multicast and broadcast on the real Wi-Fi: device discovery (AirPlay, Chromecast,
// printers) and connections to devices at home work as without the VPN. Port of the Android
// app's TunRoutes.

// Home networks, link-local, multicast and the reserved block with the broadcast address.
var (
	localIPv4 = []string{"10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "224.0.0.0/4", "240.0.0.0/4"}
	localIPv6 = []string{"fc00::/7", "fe80::/10", "ff00::/8"}
)

type tunRoute struct {
	Address string `json:"address"`
	Prefix  int    `json:"prefix"`
}

// TunnelRoutes returns JSON {"ipv4":[{"address":"0.0.0.0","prefix":1},...],"ipv6":[...]}: the
// routes of the tunnel, without the local network when lanDirect is set.
func TunnelRoutes(lanDirect bool) string {
	routes := struct {
		IPv4 []tunRoute `json:"ipv4"`
		IPv6 []tunRoute `json:"ipv6"`
	}{
		IPv4: []tunRoute{{"0.0.0.0", 0}},
		IPv6: []tunRoute{{"::", 0}},
	}
	if lanDirect {
		routes.IPv4 = complementRoutes(32, localIPv4)
		routes.IPv6 = complementRoutes(128, localIPv6)
	}
	b, _ := json.Marshal(routes)
	return string(b)
}

// complementRoutes is the whole address space without excluded, in as few prefixes as possible.
func complementRoutes(bits int, excluded []string) []tunRoute {
	type network struct {
		addr *big.Int
		len  int
	}
	var local []network
	for _, cidr := range excluded {
		p := netip.MustParsePrefix(cidr)
		local = append(local, network{new(big.Int).SetBytes(p.Addr().AsSlice()), p.Bits()})
	}
	sameTop := func(a, b *big.Int, length int) bool {
		return new(big.Int).Rsh(a, uint(bits-length)).Cmp(new(big.Int).Rsh(b, uint(bits-length))) == 0
	}
	var routes []tunRoute
	var walk func(net *big.Int, length int)
	walk = func(net *big.Int, length int) {
		inner := false
		for _, l := range local {
			if l.len <= length && sameTop(net, l.addr, l.len) {
				return // inside a local range
			}
			if l.len > length && sameTop(net, l.addr, length) {
				inner = true
			}
		}
		if !inner {
			routes = append(routes, tunRoute{formatAddr(net, bits), length})
			return
		}
		walk(net, length+1)
		walk(new(big.Int).SetBit(new(big.Int).Set(net), bits-length-1, 1), length+1)
	}
	walk(new(big.Int), 0)
	return routes
}

func formatAddr(value *big.Int, bits int) string {
	b := make([]byte, bits/8)
	value.FillBytes(b)
	addr, _ := netip.AddrFromSlice(b)
	return addr.String()
}
