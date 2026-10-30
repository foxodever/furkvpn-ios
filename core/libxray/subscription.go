package libxray

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"regexp"
	"strconv"
	"strings"
)

// The Remnawave Xray JSON subscription is an array of complete Xray configs with "remarks". Its
// list of servers is parsed the way the Android app's SubscriptionParser does it.

type serverEntry struct {
	// Stable id across subscription updates: remarks plus occurrence number.
	Key     string `json:"key"`
	Remarks string `json:"remarks"`
	Flag    string `json:"flag,omitempty"`
	Title   string `json:"title"`
	// SERVER, AUTO (balancers or several servers) or SEPARATOR (a host with the address 0.0.0.0,
	// shown as a section title).
	Kind    string `json:"kind"`
	Summary string `json:"summary,omitempty"`
}

type parsedSubscription struct {
	Servers []serverEntry `json:"servers"`
	// The configs as the panel sent them, configs[i] for servers[i].
	Configs []string `json:"configs"`
}

// ParseSubscription parses the subscription body and returns JSON: {"servers": [{"key", "remarks",
// "flag", "title", "kind", "summary"}], "configs": ["<config of servers[i]>"]}. The error is "bad
// format" when the body has no Xray configs and "no servers" when they are all section titles.
func ParseSubscription(body string) (string, error) {
	sub, err := parseSubscription(body)
	if err != nil {
		return "", err
	}
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(sub); err != nil {
		return "", err
	}
	return strings.TrimSpace(buf.String()), nil
}

func parseSubscription(body string) (*parsedSubscription, error) {
	badFormat := errors.New("bad format")
	body = strings.TrimSpace(body)
	var items []json.RawMessage
	if strings.HasPrefix(body, "[") {
		if json.Unmarshal([]byte(body), &items) != nil {
			return nil, badFormat
		}
	} else {
		items = []json.RawMessage{json.RawMessage(body)}
	}
	sub := &parsedSubscription{Servers: []serverEntry{}, Configs: []string{}}
	var configs []map[string]any
	for _, item := range items {
		cfg, err := parseConfig(string(item))
		if err != nil {
			continue
		}
		if _, ok := cfg["outbounds"].([]any); !ok {
			continue
		}
		var compact bytes.Buffer
		if json.Compact(&compact, item) != nil {
			continue
		}
		configs = append(configs, cfg)
		sub.Configs = append(sub.Configs, compact.String())
	}
	if len(configs) == 0 {
		return nil, badFormat
	}
	sub.Servers = subscriptionEntries(configs)
	for _, s := range sub.Servers {
		if s.Kind != "SEPARATOR" {
			return sub, nil
		}
	}
	return nil, errors.New("no servers")
}

func subscriptionEntries(configs []map[string]any) []serverEntry {
	seen := map[string]int{}
	entries := make([]serverEntry, len(configs))
	for i, cfg := range configs {
		remarks := strings.TrimSpace(stringOf(cfg["remarks"]))
		if remarks == "" {
			remarks = fmt.Sprintf("Server %d", i+1)
		}
		seen[remarks]++
		var proxies []map[string]any
		outbounds, _ := cfg["outbounds"].([]any)
		for _, o := range outbounds {
			if ob, ok := o.(map[string]any); ok && proxyProtocols[stringOf(ob["protocol"])] {
				proxies = append(proxies, ob)
			}
		}
		routing, _ := cfg["routing"].(map[string]any)
		balancers, _ := routing["balancers"].([]any)
		kind := "SERVER"
		switch {
		case len(proxies) == 0 || addressOf(proxies[0]) == "0.0.0.0":
			kind = "SEPARATOR"
		case len(proxies) > 1 || len(balancers) > 0:
			kind = "AUTO"
		}
		e := serverEntry{Key: fmt.Sprintf("%s#%d", remarks, seen[remarks]), Remarks: remarks, Kind: kind}
		if kind == "SEPARATOR" {
			e.Title = separatorTitle(remarks)
		} else {
			e.Flag, e.Title = splitFlag(remarks)
		}
		if kind == "SERVER" {
			e.Summary = summaryOf(proxies[0])
		}
		entries[i] = e
	}
	return entries
}

// stringOf is a JSON string or number as text, "" for anything else.
func stringOf(v any) string {
	switch s := v.(type) {
	case string:
		return s
	case json.Number:
		return s.String()
	}
	return ""
}

func firstObject(v any) map[string]any {
	list, _ := v.([]any)
	if len(list) == 0 {
		return nil
	}
	return asMap(list[0])
}

// addressOf returns the server address of an outbound, "" when it has none.
func addressOf(ob map[string]any) string {
	settings := asMap(ob["settings"])
	if settings == nil {
		return ""
	}
	for _, list := range []string{"vnext", "servers"} {
		if a := stringOf(firstObject(settings[list])["address"]); a != "" {
			return a
		}
	}
	if e := stringOf(firstObject(settings["peers"])["endpoint"]); e != "" {
		if i := strings.LastIndex(e, ":"); i >= 0 {
			return e[:i]
		}
		return e
	}
	return stringOf(settings["address"])
}

// summaryOf is the protocol line under a server's name: "VLESS · XHTTP · REALITY".
func summaryOf(ob map[string]any) string {
	// Always QUIC with TLS; "hysteria" is both its protocol and its transport.
	if stringOf(ob["protocol"]) == "hysteria" {
		return "HYSTERIA2 · QUIC"
	}
	stream := asMap(ob["streamSettings"])
	parts := []string{strings.ToUpper(stringOf(ob["protocol"]))}
	switch n := strings.ToLower(stringOf(stream["network"])); n {
	case "", "raw", "tcp":
		parts = append(parts, "TCP")
	case "ws":
		parts = append(parts, "WS")
	case "xhttp", "splithttp":
		parts = append(parts, "XHTTP")
	case "grpc":
		parts = append(parts, "gRPC")
	case "httpupgrade":
		parts = append(parts, "HTTPUpgrade")
	case "kcp", "mkcp":
		parts = append(parts, "mKCP")
	default:
		parts = append(parts, strings.ToUpper(n))
	}
	switch strings.ToLower(stringOf(stream["security"])) {
	case "tls":
		parts = append(parts, "TLS")
	case "reality":
		parts = append(parts, "REALITY")
	}
	return strings.Join(parts, " · ")
}

// splitFlag: "🇳🇱 Нидерланды ⚡" -> ("🇳🇱", "Нидерланды ⚡").
func splitFlag(remarks string) (flag, title string) {
	runes := []rune(remarks)
	if len(runes) >= 2 && isRegionalIndicator(runes[0]) && isRegionalIndicator(runes[1]) {
		rest := strings.TrimSpace(string(runes[2:]))
		if rest == "" {
			rest = remarks
		}
		return string(runes[:2]), rest
	}
	return "", remarks
}

func isRegionalIndicator(r rune) bool { return r >= 0x1F1E6 && r <= 0x1F1FF }

var (
	separatorDecor  = regexp.MustCompile(`[\x{2B07}\x{2B06}\x{2B05}\x{27A1}\x{2193}\x{2191}\x{2190}\x{2192}\x{FE0F}\x{1F447}\x{1F446}\x{1F53D}\x{1F53C}]|[—–-]{2,}`)
	separatorPrefix = regexp.MustCompile(`(?i)^(внизу|ниже|below)\s+`)
	spaces          = regexp.MustCompile(`\s+`)
)

// separatorTitle: "⬇️ Внизу Домашние (Wi-Fi) ⬇️" -> "Домашние (Wi-Fi)".
func separatorTitle(remarks string) string {
	cleaned := strings.TrimSpace(spaces.ReplaceAllString(separatorDecor.ReplaceAllString(remarks, " "), " "))
	if t := strings.TrimSpace(separatorPrefix.ReplaceAllString(cleaned, "")); t != "" {
		return t
	}
	return strings.TrimSpace(remarks)
}

// DecodeHeader returns a Remnawave header value, which may be prefixed with "base64:", as text;
// "" when there is none or it does not decode.
func DecodeHeader(value string) string {
	v := strings.TrimSpace(value)
	if len(v) < 7 || !strings.EqualFold(v[:7], "base64:") {
		return v
	}
	data := strings.TrimRight(strings.TrimSpace(v[7:]), "=")
	for _, enc := range []*base64.Encoding{base64.RawStdEncoding, base64.RawURLEncoding} {
		if b, err := enc.DecodeString(data); err == nil {
			return strings.TrimSpace(string(b))
		}
	}
	return ""
}

// ParseUserInfo turns "upload=1; download=2; total=3; expire=4" (subscription-userinfo) into JSON:
// {"upload":1,"download":2,"total":3,"expire":4}, with only the keys that are there.
func ParseUserInfo(value string) string {
	info := map[string]int64{}
	for _, part := range strings.Split(value, ";") {
		k, v, ok := strings.Cut(part, "=")
		if !ok {
			continue
		}
		if f, err := strconv.ParseFloat(strings.TrimSpace(v), 64); err == nil && !math.IsNaN(f) && !math.IsInf(f, 0) {
			info[strings.ToLower(strings.TrimSpace(k))] = int64(f)
		}
	}
	b, _ := json.Marshal(info)
	return string(b)
}
