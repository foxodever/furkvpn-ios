package libxray

import (
	"bytes"
	"encoding/json"
	"net"
	"strings"
)

// parseConfig decodes an Xray JSON config keeping numbers as written.
func parseConfig(configJSON string) (map[string]any, error) {
	dec := json.NewDecoder(strings.NewReader(configJSON))
	dec.UseNumber()
	var cfg map[string]any
	if err := dec.Decode(&cfg); err != nil {
		return nil, err
	}
	return cfg, nil
}

// withFixes returns configJSON with resolveServersDirectly and upgradeHysteria applied, or
// unchanged when neither changes anything.
func withFixes(configJSON string) string {
	cfg, err := parseConfig(configJSON)
	if err != nil {
		return configJSON
	}
	resolved := resolveServersDirectly(cfg)
	if upgraded := upgradeHysteria(cfg); !resolved && !upgraded {
		return configJSON
	}
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(cfg); err != nil {
		return configJSON
	}
	return buf.String()
}

// resolveServersDirectly makes the config resolve all of its server domains the way it resolves
// the ones it lists. The subscription template lists the servers' domains under a DNS server
// that routing sends directly (77.88.8.8); a server missing from that list is resolved through
// the other DNS servers, which go through a proxy, often the very server being resolved, so
// every lookup of it waits out the 4-second DNS timeout (and auto-select, which gives a server
// 3 seconds, sees it as down). Reports whether it added anything.
func resolveServersDirectly(cfg map[string]any) bool {
	domains := serverDomains(cfg)
	if len(domains) == 0 {
		return false
	}
	dns, _ := cfg["dns"].(map[string]any)
	servers, _ := dns["servers"].([]any)
	for _, s := range servers {
		server, _ := s.(map[string]any)
		list, _ := server["domains"].([]any)
		covers := func(domain string) bool { return domainListCovers(list, domain) }
		matched := false
		for _, d := range domains {
			if covers(d) {
				matched = true
				break
			}
		}
		if !matched {
			continue
		}
		added := false
		for _, d := range domains {
			if !covers(d) {
				list = append(list, "full:"+d)
				added = true
			}
		}
		if added {
			server["domains"] = list
		}
		return added
	}
	return false
}

// serverDomains returns the domain names of the servers the config's proxy outbounds connect to.
func serverDomains(cfg map[string]any) []string {
	outbounds, _ := cfg["outbounds"].([]any)
	seen := map[string]bool{}
	var domains []string
	add := func(v any) {
		address, _ := v.(string)
		if d := domainOf(address); d != "" && !seen[d] {
			seen[d] = true
			domains = append(domains, d)
		}
	}
	for _, idx := range proxyOutbounds(cfg) {
		ob, _ := outbounds[idx].(map[string]any)
		settings, _ := ob["settings"].(map[string]any)
		add(settings["address"])
		for _, key := range []string{"vnext", "servers", "peers"} {
			list, _ := settings[key].([]any)
			for _, item := range list {
				entry, _ := item.(map[string]any)
				add(entry["address"])
				if endpoint, _ := entry["endpoint"].(string); endpoint != "" {
					if host, _, err := net.SplitHostPort(endpoint); err == nil {
						add(host)
					}
				}
			}
		}
	}
	return domains
}
