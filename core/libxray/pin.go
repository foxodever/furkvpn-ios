package libxray

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"strconv"
	"strings"
	"sync"
	"time"
)

// pinServers replaces the domain names of the servers of the outbounds at indexes with their
// addresses, so a delay test does not wait for DNS. What the name meant for the connection stays:
// it becomes the TLS / REALITY server name and the Host of WebSocket, HTTPUpgrade and XHTTP (the
// authority of gRPC) where those are not set. Returns the first lookup error.
func pinServers(cfg map[string]any, indexes []int) error {
	outbounds, _ := cfg["outbounds"].([]any)
	type target struct {
		outbound int
		domain   string
		set      func(ip string)
	}
	var targets []target
	for _, idx := range indexes {
		ob, _ := outbounds[idx].(map[string]any)
		settings, _ := ob["settings"].(map[string]any)
		if settings == nil {
			continue
		}
		addAddress := func(entry map[string]any) {
			address, _ := entry["address"].(string)
			if domain := domainOf(address); domain != "" {
				targets = append(targets, target{idx, domain, func(ip string) { entry["address"] = ip }})
			}
		}
		addAddress(settings)
		for _, key := range []string{"vnext", "servers"} {
			list, _ := settings[key].([]any)
			for _, item := range list {
				if entry, ok := item.(map[string]any); ok {
					addAddress(entry)
				}
			}
		}
		peers, _ := settings["peers"].([]any)
		for _, item := range peers {
			peer, _ := item.(map[string]any)
			endpoint, _ := peer["endpoint"].(string)
			if host, port, err := net.SplitHostPort(endpoint); err == nil && domainOf(host) != "" {
				targets = append(targets, target{idx, domainOf(host), func(ip string) { peer["endpoint"] = net.JoinHostPort(ip, port) }})
			}
		}
	}

	var domains []string
	seen := map[string]bool{}
	for _, t := range targets {
		if !seen[t.domain] {
			seen[t.domain] = true
			domains = append(domains, t.domain)
		}
	}
	found := make([]net.IP, len(domains))
	errs := make([]error, len(domains))
	var wg sync.WaitGroup
	limit := make(chan struct{}, 8)
	for n, domain := range domains {
		wg.Add(1)
		go func(n int, domain string) {
			defer wg.Done()
			limit <- struct{}{}
			defer func() { <-limit }()
			found[n], errs[n] = lookupServer(cfg, domain)
		}(n, domain)
	}
	wg.Wait()
	ips := map[string]net.IP{}
	lookupErrs := map[string]error{}
	for n, domain := range domains {
		ips[domain], lookupErrs[domain] = found[n], errs[n]
	}

	var firstErr error
	named := map[int]bool{}
	for _, t := range targets {
		ip := ips[t.domain]
		if ip == nil {
			if firstErr == nil {
				firstErr = fmt.Errorf("resolve %s: %w", t.domain, lookupErrs[t.domain])
			}
			continue
		}
		t.set(ip.String())
		if !named[t.outbound] {
			named[t.outbound] = true
			ob, _ := outbounds[t.outbound].(map[string]any)
			keepServerName(ob, t.domain)
		}
	}
	return firstErr
}

// keepServerName writes the server's domain name where Xray would otherwise take it from the
// address that pinServers replaces.
func keepServerName(ob map[string]any, domain string) {
	stream, _ := ob["streamSettings"].(map[string]any)
	if stream == nil {
		return
	}
	setIfEmpty := func(settingsKey, field string) {
		settings, _ := stream[settingsKey].(map[string]any)
		if settings == nil {
			settings = map[string]any{}
			stream[settingsKey] = settings
		}
		if v, _ := settings[field].(string); strings.TrimSpace(v) == "" {
			settings[field] = domain
		}
	}
	switch security, _ := stream["security"].(string); security {
	case "tls":
		setIfEmpty("tlsSettings", "serverName")
	case "reality":
		setIfEmpty("realitySettings", "serverName")
	}
	switch network, _ := stream["network"].(string); network {
	case "ws", "websocket":
		if headers, _ := asMap(stream["wsSettings"])["headers"].(map[string]any); headers["Host"] == nil && headers["host"] == nil {
			setIfEmpty("wsSettings", "host")
		}
	case "httpupgrade":
		setIfEmpty("httpupgradeSettings", "host")
	case "xhttp", "splithttp":
		key := network + "Settings"
		setIfEmpty(key, "host")
	case "grpc", "gun":
		setIfEmpty("grpcSettings", "authority")
	}
}

func asMap(v any) map[string]any {
	m, _ := v.(map[string]any)
	return m
}

// domainOf returns address when it is a domain name (not an IP address or a placeholder).
func domainOf(address string) string {
	address = strings.ToLower(strings.TrimSuffix(strings.TrimSpace(address), "."))
	if address == "" || address == "localhost" || net.ParseIP(address) != nil || !strings.Contains(address, ".") {
		return ""
	}
	return address
}

type cachedLookup struct {
	ip    net.IP
	until time.Time
}

var (
	lookupMu    sync.Mutex
	lookupCache = map[string]cachedLookup{}
	// The addresses given by SetServerAddresses, by name.
	serverAddresses = map[string]net.IP{}
)

// SetServerAddresses gives the delay tests the addresses the tunnel extension resolved the servers to
// ({name: address}, from ResolveServers) while the VPN is on; "{}" forgets them. A test connects to the
// address given here: past the tunnel it gets only to these, and the name isn't looked up through the
// tunnel's DNS.
func SetServerAddresses(addressesJSON string) {
	var given map[string]string
	_ = json.Unmarshal([]byte(addressesJSON), &given)
	addresses := map[string]net.IP{}
	for name, address := range given {
		if ip := net.ParseIP(address); ip != nil && domainOf(name) != "" {
			addresses[domainOf(name)] = ip
		}
	}
	lookupMu.Lock()
	serverAddresses = addresses
	lookupMu.Unlock()
}

const (
	lookupTTL     = 2 * time.Minute
	lookupTimeout = 4 * time.Second
)

// lookupServer resolves a server's domain name: through the plain DNS server the config lists it
// under (the subscription template resolves its servers through 77.88.8.8 directly), then through
// the phone's own DNS. The app is excluded from its VPN, so neither goes through a server. An IPv4
// address is preferred. An address given by SetServerAddresses comes before all of that.
func lookupServer(cfg map[string]any, domain string) (net.IP, error) {
	lookupMu.Lock()
	given := serverAddresses[domain]
	hit, ok := lookupCache[domain]
	lookupMu.Unlock()
	if given != nil {
		return given, nil
	}
	if ok && time.Now().Before(hit.until) {
		return hit.ip, nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), lookupTimeout)
	defer cancel()
	var addrs []net.IP
	var err error
	if network, server := listedNameServer(cfg, domain); server != "" {
		r := &net.Resolver{PreferGo: true, Dial: func(ctx context.Context, _, _ string) (net.Conn, error) {
			var d net.Dialer
			return d.DialContext(ctx, network, server)
		}}
		half, cancelHalf := context.WithTimeout(ctx, lookupTimeout/2)
		addrs, err = r.LookupIP(half, "ip", domain)
		cancelHalf()
	}
	if len(addrs) == 0 {
		addrs, err = net.DefaultResolver.LookupIP(ctx, "ip", domain)
	}
	var ip net.IP
	for _, a := range addrs {
		if a.To4() != nil {
			ip = a.To4()
			break
		}
		if ip == nil {
			ip = a
		}
	}
	if ip == nil {
		if err == nil {
			err = errors.New("no address")
		}
		return nil, err
	}
	lookupMu.Lock()
	if len(lookupCache) > 512 {
		lookupCache = map[string]cachedLookup{}
	}
	lookupCache[domain] = cachedLookup{ip, time.Now().Add(lookupTTL)}
	lookupMu.Unlock()
	return ip, nil
}

// listedNameServer returns the plain (UDP or TCP) DNS server of the config whose domain list
// covers domain, as a network and an address to dial.
func listedNameServer(cfg map[string]any, domain string) (network, address string) {
	dns, _ := cfg["dns"].(map[string]any)
	servers, _ := dns["servers"].([]any)
	for _, s := range servers {
		server, _ := s.(map[string]any)
		if server == nil || !domainListCovers(server["domains"], domain) {
			continue
		}
		raw, _ := server["address"].(string)
		port := "53"
		switch p := server["port"].(type) {
		case float64:
			port = strconv.Itoa(int(p))
		case interface{ String() string }:
			port = p.String()
		}
		network = "udp"
		switch {
		case strings.HasPrefix(raw, "tcp://"):
			network, raw = "tcp", strings.TrimPrefix(raw, "tcp://")
		case strings.HasPrefix(raw, "udp://"):
			raw = strings.TrimPrefix(raw, "udp://")
		}
		host := raw
		if h, p, err := net.SplitHostPort(raw); err == nil {
			host, port = h, p
		}
		if net.ParseIP(strings.Trim(host, "[]")) == nil {
			continue
		}
		return network, net.JoinHostPort(strings.Trim(host, "[]"), port)
	}
	return "", ""
}

// domainListCovers reports whether an Xray domain list ("full:", "domain:", "keyword:" or plain
// substring entries) matches domain.
func domainListCovers(list any, domain string) bool {
	entries, _ := list.([]any)
	for _, e := range entries {
		rule, _ := e.(string)
		rule = strings.ToLower(strings.TrimSpace(rule))
		switch {
		case strings.HasPrefix(rule, "full:"):
			if rule[len("full:"):] == domain {
				return true
			}
		case strings.HasPrefix(rule, "domain:"):
			d := rule[len("domain:"):]
			if domain == d || strings.HasSuffix(domain, "."+d) {
				return true
			}
		case strings.HasPrefix(rule, "keyword:"):
			if strings.Contains(domain, rule[len("keyword:"):]) {
				return true
			}
		case strings.Contains(rule, ":"):
			// regexp:, geosite: and the like are not worth evaluating here.
		case rule != "" && strings.Contains(domain, rule):
			return true
		}
	}
	return false
}
