package libxray

import (
	"bytes"
	"encoding/json"
	"net"
	"strings"
)

// Re-signed IPAs: a signing service that has one App ID signs the VPN extension with the app's
// application-identifier, and iOS then doesn't take the extension for the provider of its tunnel —
// once the tunnel is up, every connection the extension makes over the phone's main interface is
// dropped ("network is unreachable"), only addresses kept out of the tunnel's routes still get out.
// So the servers' names are resolved before the tunnel starts and their addresses written into the
// config and left out of the routes, and nothing goes direct (NoDirect).

// PinTunnelServers resolves the server names of every proxy outbound of raw — before the tunnel is
// up, while this process still reaches the network — and writes the addresses in, as the delay test
// does. JSON {"config": the pinned config, "exclude": [the servers' addresses and the name servers
// listed for their names]}: the tunnel leaves these out of its routes. Names that don't resolve
// stay as they are; a config that doesn't parse comes back unchanged.
func PinTunnelServers(raw string) string {
	answer := struct {
		Config  string   `json:"config"`
		Exclude []string `json:"exclude"`
	}{Config: raw, Exclude: []string{}}
	if cfg, err := parseConfig(raw); err == nil {
		indexes := proxyOutbounds(cfg)
		seen := map[string]bool{}
		add := func(host string) {
			if ip := net.ParseIP(strings.Trim(host, "[]")); ip != nil && !ip.IsLoopback() && !seen[ip.String()] {
				seen[ip.String()] = true
				answer.Exclude = append(answer.Exclude, ip.String())
			}
		}
		// The name servers first: they also answer a later lookup when the server changes.
		for _, host := range serverHosts(cfg, indexes) {
			if domain := domainOf(host); domain != "" {
				if _, server := listedNameServer(cfg, domain); server != "" {
					if h, _, err := net.SplitHostPort(server); err == nil {
						add(h)
					}
				}
			}
		}
		_ = pinServers(cfg, indexes)
		for _, host := range serverHosts(cfg, indexes) {
			add(host)
		}
		var buf bytes.Buffer
		enc := json.NewEncoder(&buf)
		enc.SetEscapeHTML(false)
		if enc.Encode(cfg) == nil {
			answer.Config = strings.TrimSpace(buf.String())
		}
	}
	b, _ := json.Marshal(answer)
	return string(b)
}

// serverHosts lists the server address of each of the outbounds at indexes: every vnext/servers
// entry, the flat form and WireGuard peers.
func serverHosts(cfg map[string]any, indexes []int) []string {
	outbounds, _ := cfg["outbounds"].([]any)
	var hosts []string
	for _, idx := range indexes {
		settings := asMap(asMap(outbounds[idx])["settings"])
		if address, _ := settings["address"].(string); address != "" {
			hosts = append(hosts, address)
		}
		for _, key := range []string{"vnext", "servers"} {
			list, _ := settings[key].([]any)
			for _, item := range list {
				if address, _ := asMap(item)["address"].(string); address != "" {
					hosts = append(hosts, address)
				}
			}
		}
		peers, _ := settings["peers"].([]any)
		for _, item := range peers {
			endpoint, _ := asMap(item)["endpoint"].(string)
			if host, _, err := net.SplitHostPort(endpoint); err == nil {
				hosts = append(hosts, host)
			}
		}
	}
	return hosts
}

// withoutDirect sends what the rules would send to a freedom outbound through the server instead,
// and adds a last catch-all to the server for configs whose first outbound (the default) is direct.
func withoutDirect(rules []any, outbounds []any, templateOutbounds []map[string]any, templateRules []any) []any {
	direct := map[string]bool{}
	for _, o := range outbounds {
		if ob := asMap(o); stringOf(ob["protocol"]) == "freedom" {
			direct[stringOf(ob["tag"])] = true
		}
	}
	key, tag := proxyTarget(templateOutbounds, templateRules)
	if key == "outboundTag" && direct[tag] {
		key, tag = "outboundTag", ""
		for _, ob := range templateOutbounds {
			if proxyProtocols[stringOf(ob["protocol"])] {
				tag = stringOf(ob["tag"])
				break
			}
		}
		if tag == "" {
			return rules // no server to send it to
		}
	}
	result := make([]any, 0, len(rules)+1)
	for _, rule := range rules {
		rm, ok := rule.(map[string]any)
		if !ok || !direct[stringOf(rm["outboundTag"])] {
			result = append(result, rule)
			continue
		}
		copied := map[string]any{}
		for k, v := range rm {
			if k != "outboundTag" {
				copied[k] = v
			}
		}
		copied[key] = tag
		result = append(result, copied)
	}
	return append(result, map[string]any{"type": "field", "network": "tcp,udp", key: tag})
}
