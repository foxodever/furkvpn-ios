package libxray

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/xtls/xray-core/features/dns"
)

// What the iOS debug report checks step by step when the tunnel carries nothing: for the first
// servers of the running config, the name through the core's DNS and through the listed name
// server directly, a plain TCP connection to the server bound to the phone's interface, then a
// request through the core. Each step that fails points at a different cause.

var runningConfig struct {
	mu   sync.Mutex
	json string
}

func rememberRunningConfig(configJSON string) {
	runningConfig.mu.Lock()
	runningConfig.json = configJSON
	runningConfig.mu.Unlock()
}

type serverEndpoint struct {
	tag, address string
	port         int
	udp          bool
}

// serverEndpoints lists the address and port of each proxy outbound (vnext/servers/flat form).
func serverEndpoints(cfg map[string]any) []serverEndpoint {
	outbounds, _ := cfg["outbounds"].([]any)
	var list []serverEndpoint
	for _, idx := range proxyOutbounds(cfg) {
		ob := asMap(outbounds[idx])
		settings := asMap(ob["settings"])
		entry := settings
		for _, key := range []string{"vnext", "servers"} {
			if items, ok := settings[key].([]any); ok && len(items) > 0 {
				entry = asMap(items[0])
			}
		}
		address, _ := entry["address"].(string)
		port, _ := strconv.Atoi(fmt.Sprint(entry["port"]))
		protocol, _ := ob["protocol"].(string)
		tag, _ := ob["tag"].(string)
		if address != "" {
			list = append(list, serverEndpoint{tag, address, port, protocol == "hysteria" || protocol == "wireguard"})
		}
	}
	return list
}

// DiagnoseRunning returns the steps' results as text (iface: the interface the core is bound to).
func DiagnoseRunning(testURL string, iface string) string {
	runningConfig.mu.Lock()
	configJSON := runningConfig.json
	runningConfig.mu.Unlock()
	mu.Lock()
	inst := instance
	mu.Unlock()
	cfg, err := parseConfig(configJSON)
	if err != nil || inst == nil {
		return "ядро не запущено"
	}
	var b strings.Builder
	dnsClient, _ := inst.GetFeature(dns.ClientType()).(dns.Client)
	endpoints := serverEndpoints(cfg)
	if len(endpoints) > 3 {
		endpoints = endpoints[:3]
	}
	for _, e := range endpoints {
		fmt.Fprintf(&b, "[%s %s:%d] ", e.tag, e.address, e.port)
		ip := net.ParseIP(e.address)
		if domain := domainOf(e.address); domain != "" {
			if dnsClient != nil {
				ips, _, err := dnsClient.LookupIP(domain, dns.IPOption{IPv4Enable: true})
				if err != nil {
					fmt.Fprintf(&b, "DNS ядра: %v; ", err)
				} else {
					fmt.Fprintf(&b, "DNS ядра: %v; ", ips)
				}
			}
			network, server := listedNameServer(cfg, domain)
			if server != "" {
				r := &net.Resolver{PreferGo: true, Dial: func(ctx context.Context, _, _ string) (net.Conn, error) {
					d := net.Dialer{Control: dialControlBound(iface)}
					return d.DialContext(ctx, network, server)
				}}
				ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
				addrs, err := r.LookupIP(ctx, "ip4", domain)
				cancel()
				if err != nil {
					fmt.Fprintf(&b, "напрямую через %s: %v; ", server, err)
				} else {
					fmt.Fprintf(&b, "напрямую через %s: %v; ", server, addrs)
					if len(addrs) > 0 {
						ip = addrs[0]
					}
				}
			}
		}
		if ip != nil && !e.udp {
			via := iface
			if via == "" {
				via = "без привязки"
			}
			d := net.Dialer{Timeout: 3 * time.Second, Control: dialControlBound(iface)}
			started := time.Now()
			conn, err := d.Dial("tcp", net.JoinHostPort(ip.String(), strconv.Itoa(e.port)))
			if err != nil {
				fmt.Fprintf(&b, "TCP через %s: %v", via, err)
			} else {
				conn.Close()
				fmt.Fprintf(&b, "TCP через %s: %d мс", via, time.Since(started).Milliseconds())
			}
		}
		b.WriteString("\n")
	}
	fmt.Fprintf(&b, "Запрос через ядро: %s", CheckRunning(testURL, 5000))
	return b.String()
}

// DebugErrors returns the core's recent warnings and errors only (the report's most useful part).
func DebugErrors(lines int) string {
	debugLog.mu.Lock()
	defer debugLog.mu.Unlock()
	list := debugLog.lines
	if lines < 0 {
		lines = 0
	}
	if len(list) > lines {
		list = list[len(list)-lines:]
	}
	return strings.Join(list, "\n")
}

// ProbeNetwork asks 77.88.8.8 over TCP for a name: without binding and bound to each of ifaces
// ("en0,pdp_ip0"), all at once. Only a real answer counts: an unbound socket of a process iOS doesn't
// keep out of the tunnel would go into it and get none. JSON: {"unbound":"ok 41 мс" or the error,
// "en0":..., "pdp_ip0":...}.
func ProbeNetwork(ifaces string) string {
	return ProbeNetworkVia("77.88.8.8", ifaces)
}

// ProbeNetworkVia is ProbeNetwork with another name server (an IP address): one that the tunnel
// keeps out of its routes would answer even where nothing else gets out.
func ProbeNetworkVia(server string, ifaces string) string {
	probe := func(bind string) string { return ProbeDNS(net.JoinHostPort(server, "53"), bind) }
	result := map[string]string{}
	var resultMu sync.Mutex
	var wg sync.WaitGroup
	for _, name := range append([]string{""}, splitNames(ifaces)...) {
		wg.Add(1)
		go func() {
			defer wg.Done()
			answer := probe(name)
			if name == "" {
				name = "unbound"
			}
			resultMu.Lock()
			result[name] = answer
			resultMu.Unlock()
		}()
	}
	wg.Wait()
	b, _ := json.Marshal(result)
	return string(b)
}

// ProbeDNS asks the name server (host:port) over TCP for ya.ru, the socket bound to iface unless it
// is empty: "ok 41 мс" or the error, after 2 s at most.
func ProbeDNS(server string, iface string) string {
	r := &net.Resolver{PreferGo: true, Dial: func(ctx context.Context, _, _ string) (net.Conn, error) {
		d := net.Dialer{Control: dialControlBound(iface)}
		return d.DialContext(ctx, "tcp", server)
	}}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	started := time.Now()
	if _, err := r.LookupIP(ctx, "ip4", "ya.ru"); err != nil {
		return err.Error()
	}
	return fmt.Sprintf("ok %d мс", time.Since(started).Milliseconds())
}

// UsableInterfaces keeps, in order, those of names ("en0,pdp_ip0") that are up and have an address
// to reach the internet with (IPv4 or global IPv6): iOS lists Wi-Fi that is on but not joined to a
// network as well, and a socket bound to it gets "network is unreachable".
func UsableInterfaces(names string) string {
	var usable []string
	for _, name := range splitNames(names) {
		if len(interfaceAddresses(name)) > 0 {
			usable = append(usable, name)
		}
	}
	return strings.Join(usable, ",")
}

// InterfaceSummary describes the interfaces that are up, for the debug report:
// "en0 192.168.1.5 · pdp_ip0 10.1.2.3 +IPv6 · utun4 172.19.0.1".
func InterfaceSummary() string {
	list, err := net.Interfaces()
	if err != nil {
		return err.Error()
	}
	var parts []string
	for _, ifi := range list {
		if ifi.Flags&net.FlagUp == 0 || ifi.Flags&net.FlagLoopback != 0 {
			continue
		}
		var v4 []string
		v6 := 0
		for _, ip := range interfaceAddresses(ifi.Name) {
			if ip.To4() != nil {
				v4 = append(v4, ip.String())
			} else {
				v6++
			}
		}
		if len(v4) == 0 && v6 == 0 {
			continue
		}
		part := ifi.Name + " " + strings.Join(v4, ",")
		if v6 > 0 {
			part += " +IPv6"
		}
		parts = append(parts, strings.TrimSpace(part))
	}
	if len(parts) == 0 {
		return "нет интерфейсов с адресом"
	}
	return strings.Join(parts, " · ")
}

// NetworkSignature tells one of the phone's networks from another where iOS doesn't say which interface
// it sends through (the path of an extension it keeps behind its own tunnel is "unsatisfied" whatever the
// network): the Wi-Fi or Ethernet interfaces ("en…") with their IPv4 addresses, or, when none has an
// address, cellular ("pdp_ip0") — which stays up under Wi-Fi and would otherwise make its changes look like
// a new network. "" without a network. "en0 192.168.1.5", "pdp_ip0 10.1.2.3", "pdp_ip0 +IPv6".
func NetworkSignature() string {
	list, err := net.Interfaces()
	if err != nil {
		return ""
	}
	addresses := map[string][]net.IP{}
	for _, ifi := range list {
		if ips := interfaceAddresses(ifi.Name); len(ips) > 0 {
			addresses[ifi.Name] = ips
		}
	}
	return networkSignature(addresses)
}

// InterfaceSignature is NetworkSignature for the one interface iOS says it sends through ("en0"); "" when
// it has no address.
func InterfaceSignature(name string) string {
	return interfaceSignature(name, interfaceAddresses(name))
}

func networkSignature(addresses map[string][]net.IP) string {
	var names []string
	for name := range addresses {
		if digits := strings.TrimPrefix(name, "en"); digits != name && digits != "" && strings.Trim(digits, "0123456789") == "" {
			names = append(names, name)
		}
	}
	sort.Strings(names)
	if len(names) == 0 && len(addresses["pdp_ip0"]) > 0 {
		names = []string{"pdp_ip0"}
	}
	var parts []string
	for _, name := range names {
		parts = append(parts, interfaceSignature(name, addresses[name]))
	}
	return strings.Join(parts, " · ")
}

// interfaceSignature: the name and the IPv4 addresses, sorted; IPv6 only as "+IPv6", and only without an
// IPv4 one — iOS rotates the temporary addresses, and one that comes a few seconds after the IPv4 address
// is not another network.
func interfaceSignature(name string, ips []net.IP) string {
	var v4 []string
	v6 := false
	for _, ip := range ips {
		if ip.To4() != nil {
			v4 = append(v4, ip.String())
		} else {
			v6 = true
		}
	}
	switch {
	case len(v4) > 0:
		sort.Strings(v4)
		return name + " " + strings.Join(v4, ",")
	case v6:
		return name + " +IPv6"
	}
	return ""
}

// interfaceAddresses returns the interface's addresses other than link-local ones; none when it is
// down or missing.
func interfaceAddresses(name string) []net.IP {
	ifi, err := net.InterfaceByName(name)
	if err != nil || ifi.Flags&net.FlagUp == 0 {
		return nil
	}
	addrs, _ := ifi.Addrs()
	var ips []net.IP
	for _, a := range addrs {
		if n, ok := a.(*net.IPNet); ok && !n.IP.IsLinkLocalUnicast() && !n.IP.IsLoopback() {
			ips = append(ips, n.IP)
		}
	}
	return ips
}

func splitNames(names string) []string {
	var list []string
	for _, name := range strings.Split(names, ",") {
		if name = strings.TrimSpace(name); name != "" {
			list = append(list, name)
		}
	}
	return list
}
