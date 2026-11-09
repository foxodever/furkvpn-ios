package libxray

import (
	"context"
	"fmt"
	"net"
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
			d := net.Dialer{Timeout: 3 * time.Second, Control: dialControlBound(iface)}
			started := time.Now()
			conn, err := d.Dial("tcp", net.JoinHostPort(ip.String(), strconv.Itoa(e.port)))
			if err != nil {
				fmt.Fprintf(&b, "TCP через %s: %v", iface, err)
			} else {
				conn.Close()
				fmt.Fprintf(&b, "TCP через %s: %d мс", iface, time.Since(started).Milliseconds())
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
	if len(list) > lines {
		list = list[len(list)-lines:]
	}
	return strings.Join(list, "\n")
}
