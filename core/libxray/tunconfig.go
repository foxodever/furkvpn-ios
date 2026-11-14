package libxray

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
)

// BuildTunnelConfig turns a server config from the subscription into the config the iOS tunnel
// runs, like the Android app's XrayConfigBuilder: the panel's local socks/http inbounds are
// replaced by Xray's own TUN inbound, DNS from the TUN is answered by Xray's DNS module, and
// traffic counters are enabled. Everything else — outbounds, routing rules, balancers,
// observatory — is used exactly as the panel sent it.

const (
	tunTag        = "tun-in"
	dnsOutTag     = "dns-out"
	userDirectTag = "user-direct"
	userBlockTag  = "user-block"
	tunMTU        = 1500
)

// tunnelOptions come from the app: optionsJSON of BuildTunnelConfig.
type tunnelOptions struct {
	LogLevel string          `json:"logLevel"`
	Routing  *routingOptions `json:"routing"`
	// Tag of the auto-select server that was best a moment ago, to start the balancer with.
	Fallback string `json:"fallback"`
	// The phone's own network interface ("en0", "pdp_ip0"): every connection of the core is bound
	// to it, so none of them can loop back into the tunnel the core itself serves.
	Interface string `json:"interface"`
	// Where iOS doesn't let the extension past its own tunnel (see compat.go), nothing goes direct:
	// rules that would send traffic out of the phone directly send it through the server.
	NoDirect bool `json:"noDirect"`
}

// routingOptions are Settings → Routing; missing switches take the app's defaults.
type routingOptions struct {
	Enabled   *bool    `json:"enabled"`
	LanDirect *bool    `json:"lanDirect"`
	RuDirect  *bool    `json:"ruDirect"`
	Direct    []string `json:"direct"`
	Proxy     []string `json:"proxy"`
	Block     []string `json:"block"`
}

func (r *routingOptions) on(v *bool, def bool) bool {
	if v == nil {
		return def
	}
	return *v
}

var ruleConditions = map[string]bool{
	"domain": true, "ip": true, "port": true, "sourcePort": true, "source": true,
	"protocol": true, "inboundTag": true, "user": true, "attrs": true,
}

// BuildTunnelConfig returns the config to run for raw (a server config from the subscription).
// optionsJSON: {"logLevel": "error", "routing": {"enabled": true, "lanDirect": true, "ruDirect":
// false, "direct": [...], "proxy": [...], "block": [...]}, "fallback": "proxy-2"}.
func BuildTunnelConfig(raw string, optionsJSON string) (string, error) {
	cfg, err := parseConfig(raw)
	if err != nil {
		return "", fmt.Errorf("parse config: %w", err)
	}
	var opts tunnelOptions
	if strings.TrimSpace(optionsJSON) != "" {
		if err := json.Unmarshal([]byte(optionsJSON), &opts); err != nil {
			return "", fmt.Errorf("parse options: %w", err)
		}
	}
	if opts.LogLevel == "" {
		opts.LogLevel = "error"
	}
	if opts.Routing == nil {
		opts.Routing = &routingOptions{}
	}
	out := buildTunnelConfig(cfg, opts)
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(out); err != nil {
		return "", err
	}
	return strings.TrimSpace(buf.String()), nil
}

func buildTunnelConfig(source map[string]any, opts tunnelOptions) map[string]any {
	out := map[string]any{}
	for k, v := range source {
		out[k] = v
	}
	delete(out, "remarks")
	delete(out, "remnawave")

	var sniffing any = map[string]any{
		"enabled": true, "destOverride": []any{"http", "tls", "quic"}, "routeOnly": false,
	}
	inbounds, _ := source["inbounds"].([]any)
	for _, in := range inbounds {
		if s, ok := asMap(in)["sniffing"].(map[string]any); ok {
			sniffing = s
			break
		}
	}
	tunSettings := map[string]any{"name": "tun0", "mtu": tunMTU}
	if opts.Interface != "" {
		// Binds what the core dials outside the outbounds' own settings too (Xray's dialer controller).
		tunSettings["autoOutboundsInterface"] = opts.Interface
	}
	out["inbounds"] = []any{map[string]any{
		"tag": tunTag, "protocol": "tun", "port": 0,
		"settings": tunSettings,
		"sniffing": sniffing,
	}}

	// DNS queries arriving from the TUN are resolved by Xray's DNS module (the panel's "dns" servers).
	sourceOutbounds, _ := source["outbounds"].([]any)
	outbounds := append([]any(nil), sourceOutbounds...)
	var templateOutbounds []map[string]any
	for _, o := range sourceOutbounds {
		if ob, ok := o.(map[string]any); ok {
			templateOutbounds = append(templateOutbounds, ob)
		}
	}
	dnsTag := ""
	for _, ob := range templateOutbounds {
		if stringOf(ob["protocol"]) == "dns" {
			dnsTag = stringOf(ob["tag"])
			break
		}
	}
	if dnsTag == "" {
		dnsTag = dnsOutTag
		outbounds = append(outbounds, map[string]any{"tag": dnsOutTag, "protocol": "dns"})
	}

	routing := map[string]any{}
	for k, v := range asMap(source["routing"]) {
		routing[k] = v
	}
	templateRules, _ := routing["rules"].([]any)
	var rules []any
	rules = append(rules, map[string]any{
		"type": "field", "inboundTag": []any{tunTag}, "port": "53", "outboundTag": dnsTag,
	})
	// The user's own rules go before the panel's ones.
	if r := opts.Routing; r.on(r.Enabled, true) {
		rules = append(rules, userRules(r, templateOutbounds, templateRules, &outbounds)...)
	}
	rules = append(rules, templateRules...)
	if opts.NoDirect {
		rules = withoutDirect(rules, outbounds, templateOutbounds, templateRules)
	}
	routing["rules"] = rules
	// Auto-select sends traffic to the balancer's fallback until its first checks finish and while
	// none of its servers answers; start with the server that was best a moment ago.
	if fb := opts.Fallback; fb != "" && hasOutboundTag(outbounds, fb) {
		if balancers, ok := routing["balancers"].([]any); ok {
			patched := make([]any, len(balancers))
			for i, b := range balancers {
				patched[i] = b
				balancer, ok := b.(map[string]any)
				if !ok {
					continue
				}
				selectors, _ := balancer["selector"].([]any)
				for _, s := range selectors {
					if sel, ok := s.(string); ok && strings.HasPrefix(fb, sel) {
						copied := map[string]any{}
						for k, v := range balancer {
							copied[k] = v
						}
						copied["fallbackTag"] = fb
						patched[i] = copied
						break
					}
				}
			}
			routing["balancers"] = patched
		}
	}
	out["routing"] = routing
	if opts.Interface != "" {
		bindOutbounds(outbounds, opts.Interface)
	}
	out["outbounds"] = outbounds

	// Servers are reached over IPv4; AAAA answers would make apps try IPv6 destinations that the
	// TUN accepts but the proxy cannot reach.
	dns := map[string]any{}
	if d, ok := source["dns"].(map[string]any); ok {
		for k, v := range d {
			dns[k] = v
		}
	}
	// No servers (no dns section, or one with hosts only): Xray would ask the system's resolver, which for
	// the tunnel's extension is the tunnel's own DNS.
	if servers, _ := dns["servers"].([]any); len(servers) == 0 {
		dns["servers"] = []any{"1.1.1.1", "8.8.8.8"}
	}
	dns["queryStrategy"] = "UseIPv4"
	// A plain (UDP) nameserver keeps one connection through whichever server auto-select picked
	// when it opened, and every DNS query of the phone (and of routing) goes through it for as long
	// as answers keep coming: a slow server keeps all DNS slow even after auto-select has moved on.
	// Over TCP every query is a new connection that the balancer sends to a live server.
	servers, _ := dns["servers"].([]any)
	tcpServers := make([]any, len(servers))
	for i, s := range servers {
		tcpServers[i] = dnsOverTCP(s)
	}
	dns["servers"] = tcpServers
	// An expired answer is given right away while a fresh one is fetched in the background, so a
	// server switch doesn't stall every site for the length of a DNS query.
	if _, ok := dns["serveStale"]; !ok {
		dns["serveStale"] = true
	}
	out["dns"] = dns

	out["stats"] = map[string]any{}
	policy := map[string]any{}
	for k, v := range asMap(source["policy"]) {
		policy[k] = v
	}
	system := map[string]any{}
	for k, v := range asMap(policy["system"]) {
		system[k] = v
	}
	system["statsInboundUplink"] = true
	system["statsInboundDownlink"] = true
	policy["system"] = system
	out["policy"] = policy

	// Never write visited addresses to the system log.
	out["log"] = map[string]any{"loglevel": opts.LogLevel, "access": "none", "dnsLog": false}
	return out
}

func hasOutboundTag(outbounds []any, tag string) bool {
	for _, o := range outbounds {
		if stringOf(asMap(o)["tag"]) == tag {
			return true
		}
	}
	return false
}

// userRules are the rules from Settings → Routing: blocked first, then direct (with the LAN and .ru
// presets), then through VPN. "Through VPN" uses the same route as the panel's catch-all rule, so it
// also works for auto-select configs with balancers.
func userRules(r *routingOptions, templateOutbounds []map[string]any, templateRules []any, outbounds *[]any) []any {
	tagOf := func(protocol, fallbackTag string) string {
		for _, ob := range templateOutbounds {
			if stringOf(ob["protocol"]) == protocol {
				if tag := stringOf(ob["tag"]); tag != "" {
					return tag
				}
				break
			}
		}
		if !hasOutboundTag(*outbounds, fallbackTag) {
			*outbounds = append(*outbounds, map[string]any{"tag": fallbackTag, "protocol": protocol})
		}
		return fallbackTag
	}

	// No server at all: as the panel has it, there is nothing better.
	proxyKey, proxyTag, _ := serverTarget(templateOutbounds, templateRules)

	var result []any
	for _, action := range []string{"block", "direct", "proxy"} {
		var entries []string
		switch action {
		case "block":
			entries = append(entries, r.Block...)
		case "direct":
			entries = append(entries, r.Direct...)
			if r.on(r.LanDirect, true) {
				entries = append(entries, lanRanges...)
			}
			if r.on(r.RuDirect, false) {
				entries = append(entries, ruDomains...)
			}
		case "proxy":
			entries = append(entries, r.Proxy...)
		}
		var ips, domains []any
		seen := map[string]bool{}
		for _, e := range entries {
			x := routeToXray(e)
			if x == "" || seen[x] {
				continue
			}
			seen[x] = true
			if isIPOrCIDR(x) {
				ips = append(ips, x)
			} else {
				domains = append(domains, x)
			}
		}
		if len(ips) == 0 && len(domains) == 0 {
			continue
		}
		key, tag := "outboundTag", ""
		switch action {
		case "block":
			tag = tagOf("blackhole", userBlockTag)
		case "direct":
			tag = tagOf("freedom", userDirectTag)
		case "proxy":
			key, tag = proxyKey, proxyTag
		}
		if len(domains) > 0 {
			result = append(result, map[string]any{"type": "field", "domain": domains, key: tag})
		}
		if len(ips) > 0 {
			result = append(result, map[string]any{"type": "field", "ip": ips, key: tag})
		}
	}
	return result
}

// proxyTarget is where the panel's catch-all rule sends traffic ("balancerTag" or "outboundTag" and
// the tag), or the first proxy outbound when there is no such rule.
func proxyTarget(templateOutbounds []map[string]any, templateRules []any) (key, tag string) {
	var catchAll map[string]any
	for _, rule := range templateRules {
		rm, ok := rule.(map[string]any)
		if !ok || (rm["balancerTag"] == nil && rm["outboundTag"] == nil) {
			continue
		}
		conditional := false
		for k := range rm {
			conditional = conditional || ruleConditions[k]
		}
		if !conditional {
			catchAll = rm
		}
	}
	switch {
	case catchAll != nil && catchAll["balancerTag"] != nil:
		return "balancerTag", stringOf(catchAll["balancerTag"])
	case catchAll != nil:
		return "outboundTag", stringOf(catchAll["outboundTag"])
	}
	for _, ob := range templateOutbounds {
		if proxyProtocols[stringOf(ob["protocol"])] {
			return "outboundTag", stringOf(ob["tag"])
		}
	}
	if len(templateOutbounds) > 0 && stringOf(templateOutbounds[0]["tag"]) != "" {
		return "outboundTag", stringOf(templateOutbounds[0]["tag"])
	}
	return "outboundTag", "proxy"
}

// serverTarget is where traffic for the server goes: the panel's catch-all (proxyTarget) or, when that sends
// it out directly, the first proxy outbound — "through VPN" must never mean direct. ok is false when the
// config has no proxy outbound to fall back to.
func serverTarget(templateOutbounds []map[string]any, templateRules []any) (key, tag string, ok bool) {
	key, tag = proxyTarget(templateOutbounds, templateRules)
	direct := false
	for _, ob := range templateOutbounds {
		if stringOf(ob["tag"]) == tag && stringOf(ob["protocol"]) == "freedom" {
			direct = true
			break
		}
	}
	if key != "outboundTag" || !direct {
		return key, tag, true
	}
	for _, ob := range templateOutbounds {
		if proxyProtocols[stringOf(ob["protocol"])] && stringOf(ob["tag"]) != "" {
			return "outboundTag", stringOf(ob["tag"]), true
		}
	}
	return key, tag, false
}

// dnsOverTCP: "9.9.9.9" (DNS over UDP) becomes "tcp://9.9.9.9:53"; DoH, local and other servers
// stay as they are.
func dnsOverTCP(server any) any {
	switch s := server.(type) {
	case string:
		if tcp := tcpAddress(s, 53); tcp != "" {
			return tcp
		}
	case map[string]any:
		port := 53
		if p, err := strconv.Atoi(stringOf(s["port"])); err == nil {
			port = p
		}
		tcp := tcpAddress(stringOf(s["address"]), port)
		if tcp == "" {
			return s
		}
		copied := map[string]any{}
		for k, v := range s {
			if k != "port" {
				copied[k] = v
			}
		}
		copied["address"] = tcp
		return copied
	}
	return server
}

func tcpAddress(address string, port int) string {
	switch {
	case strings.Contains(address, "/") || !isIPOrCIDR(address):
		return ""
	case strings.Contains(address, ":"):
		return fmt.Sprintf("tcp://[%s]:%d", address, port)
	}
	return fmt.Sprintf("tcp://%s:%d", address, port)
}
