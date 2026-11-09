package libxray

import (
	"encoding/json"
	"regexp"
	"strconv"
	"strings"

	"golang.org/x/net/idna"
)

// User routing rules (Settings → Routing), the same as the Android app's RouteRules: what people
// type ("youtube.com", ".com", "https://site.ru/page", "1.2.3.4", "10.0.0.0/8", "кремль.рф",
// "keyword:yandex", Clash's "DOMAIN-KEYWORD,yandex") becomes a stored entry ("domain:youtube.com",
// "domain:.com", "keyword:yandex", "1.2.3.4", ...), and routeToXray turns that into Xray's form.
// Anything Xray could choke on is rejected here, because one bad entry stops the whole core.

// clashRule matches Clash / FLClash rule lines: "DOMAIN-KEYWORD,yandex", "DOMAIN-SUFFIX,ya.ru,DIRECT",
// "IP-CIDR,1.2.3.0/24". Plain DOMAIN needs its comma: "domain:" is our own prefix (a site with subdomains).
var clashRule = regexp.MustCompile(`(?i)^(?:(DOMAIN-SUFFIX|DOMAIN-KEYWORD|DOMAIN-REGEX|IP-CIDR6|IP-CIDR)\s*[,:]|(DOMAIN)\s*,)\s*([^,\s]+)`)

var (
	lanRanges = []string{"10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "fc00::/7", "fe80::/10"}
	ruDomains = []string{"domain:ru", "domain:xn--p1ai", "domain:su"}

	brokenSubnet = regexp.MustCompile(`^[0-9a-fA-F:.]+/\d+$`)
	hostLabel    = regexp.MustCompile(`^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$`)
)

type routeList struct {
	Valid   []string `json:"valid"`
	Invalid []string `json:"invalid"`
}

// ParseRouteList splits text by commas, spaces and new lines (a Clash rule line stays whole) and
// returns JSON: {"valid": [normalized entries], "invalid": [what was rejected]}.
func ParseRouteList(text string) string {
	valid, invalid := parseRouteList(text)
	b, _ := json.Marshal(routeList{Valid: valid, Invalid: invalid})
	return string(b)
}

func parseRouteList(text string) (valid, invalid []string) {
	valid, invalid = []string{}, []string{}
	seen := map[string]bool{}
	text = strings.NewReplacer("\r\n", "\n", "\r", "\n").Replace(text)
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		tokens := []string{line}
		if !clashRule.MatchString(line) {
			tokens = strings.FieldsFunc(line, func(r rune) bool { return r == ',' || r == ';' || r == ' ' || r == '\t' })
		}
		for _, raw := range tokens {
			if entry := normalizeRoute(raw); entry != "" {
				if !seen[entry] {
					seen[entry] = true
					valid = append(valid, entry)
				}
			} else {
				invalid = append(invalid, raw)
			}
		}
	}
	return valid, invalid
}

// normalizeRoute returns the stored entry, or "" when raw is not a domain, keyword, IP or subnet.
func normalizeRoute(raw string) string {
	s := strings.TrimSpace(raw)
	if s == "" {
		return ""
	}
	if m := clashRule.FindStringSubmatch(s); m != nil {
		kind := m[1]
		if kind == "" {
			kind = m[2]
		}
		value := m[3]
		switch strings.ToUpper(kind) {
		case "DOMAIN-SUFFIX":
			return routeDomain(value)
		case "DOMAIN":
			if h := routeHost(value); h != "" {
				return "full:" + h
			}
			return ""
		case "DOMAIN-KEYWORD":
			return routeKeyword(value)
		case "DOMAIN-REGEX":
			return routeRegexp(value)
		default:
			if isIPOrCIDR(value) {
				return strings.ToLower(value)
			}
			return ""
		}
	}
	lower := strings.ToLower(s)
	after := func() string { _, v, _ := strings.Cut(s, ":"); return v }
	switch {
	case strings.HasPrefix(lower, "geosite:"), strings.HasPrefix(lower, "geoip:"), strings.HasPrefix(lower, "ext:"):
		// Need geo databases the app doesn't ship.
		return ""
	case strings.HasPrefix(lower, "regexp:"):
		return routeRegexp(after())
	case strings.HasPrefix(lower, "keyword:"):
		return routeKeyword(after())
	case strings.HasPrefix(lower, "full:"):
		if h := routeHost(after()); h != "" {
			return "full:" + h
		}
		return ""
	case strings.HasPrefix(lower, "domain:"):
		return routeDomain(after())
	}
	// Subnets first: "10.0.0.0/8" must not lose its prefix as if it were a URL path.
	if isIPOrCIDR(s) {
		return strings.ToLower(s)
	}
	if brokenSubnet.MatchString(s) {
		return ""
	}
	if _, rest, ok := strings.Cut(s, "://"); ok {
		s = rest
	}
	s = cutAt(cutAt(cutAt(s, "/"), "?"), "#")
	if isIPOrCIDR(s) {
		return strings.ToLower(s)
	}
	return routeDomain(s)
}

func cutAt(s, sep string) string {
	before, _, _ := strings.Cut(s, sep)
	return before
}

// routeToXray is the entry as Xray needs it: "domain:.com" (kept with its dot for the list) is "domain:com".
func routeToXray(entry string) string {
	n := normalizeRoute(entry)
	if strings.HasPrefix(n, "domain:.") {
		return "domain:" + strings.TrimPrefix(n, "domain:.")
	}
	return n
}

func routeKind(entry string) string {
	for _, k := range []string{"domain", "keyword", "full", "regexp"} {
		if strings.HasPrefix(entry, k+":") {
			return k
		}
	}
	return "ip"
}

// RouteDisplay is what the list shows: "youtube.com" for "domain:youtube.com", "кремль.рф" for its
// punycode, "yandex" for "keyword:yandex" (the kind is a label next to it).
func RouteDisplay(entry string) string {
	switch routeKind(entry) {
	case "ip":
		return entry
	case "regexp", "keyword":
		_, v, _ := strings.Cut(entry, ":")
		return v
	}
	_, plain, _ := strings.Cut(entry, ":")
	if !strings.HasPrefix(plain, "xn--") && !strings.Contains(plain, ".xn--") {
		return plain
	}
	dot := strings.HasPrefix(plain, ".")
	unicode, err := idna.ToUnicode(strings.TrimPrefix(plain, "."))
	if err != nil {
		return plain
	}
	if dot {
		return "." + unicode
	}
	return unicode
}

// RouteEditable is the entry as one would type it, for editing: ".com", "keyword:yandex", "1.2.3.4".
func RouteEditable(entry string) string {
	switch routeKind(entry) {
	case "keyword":
		return "keyword:" + RouteDisplay(entry)
	case "full":
		return "full:" + RouteDisplay(entry)
	case "regexp":
		return entry
	}
	return RouteDisplay(entry)
}

// routeDomain makes a "domain:" entry; a leading dot (".com", "*.site.ru") is kept so the list
// shows it as it was typed.
func routeDomain(value string) string {
	v := strings.TrimSpace(value)
	h := routeHost(v)
	if h == "" {
		return ""
	}
	if strings.HasPrefix(v, ".") || strings.HasPrefix(v, "*.") {
		return "domain:." + h
	}
	return "domain:" + h
}

func routeKeyword(value string) string {
	word := strings.ToLower(strings.TrimSpace(value))
	if word == "" || strings.ContainsAny(word, " \t\n\r\f\v,") {
		return ""
	}
	return "keyword:" + word
}

// routeRegexp checks the pattern with Go's regexp, which is what Xray compiles it with.
func routeRegexp(pattern string) string {
	if pattern == "" {
		return ""
	}
	if _, err := regexp.Compile(pattern); err != nil {
		return ""
	}
	return "regexp:" + pattern
}

func routeHost(value string) string {
	h := strings.ToLower(strings.TrimRight(strings.TrimSpace(value), "."))
	h = strings.TrimPrefix(h, "*.")
	h = strings.TrimPrefix(h, ".")
	// "host:443" -> "host"
	if strings.Count(h, ":") == 1 {
		h = cutAt(h, ":")
	}
	if h == "" || len(h) > 253 {
		return ""
	}
	ascii, err := idna.ToASCII(h)
	if err != nil {
		return ""
	}
	ascii = strings.ToLower(ascii)
	labels := strings.Split(ascii, ".")
	// "300.1.1.1" is a broken IP, not a domain: top-level domains are never all digits.
	if allDigits(labels[len(labels)-1]) {
		return ""
	}
	for _, l := range labels {
		if !hostLabel.MatchString(l) {
			return ""
		}
	}
	return ascii
}

func allDigits(s string) bool {
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

func isIPOrCIDR(value string) bool {
	ip, prefix, _ := strings.Cut(value, "/")
	if prefix != "" && (len(prefix) > 3 || !allDigits(prefix)) {
		return false
	}
	bits, _ := strconv.Atoi(prefix)
	switch {
	case isIPv4(ip):
		return prefix == "" || bits <= 32
	case isIPv6(ip):
		return prefix == "" || bits <= 128
	}
	return false
}

func isIPv4(value string) bool {
	parts := strings.Split(value, ".")
	if len(parts) != 4 {
		return false
	}
	for _, p := range parts {
		if p == "" || len(p) > 3 || !allDigits(p) {
			return false
		}
		if n, _ := strconv.Atoi(p); n > 255 {
			return false
		}
		// "010" is rejected by Go's parser (Xray): no leading zeros.
		if len(p) > 1 && p[0] == '0' {
			return false
		}
	}
	return true
}

func isIPv6(value string) bool {
	if value == "" || strings.Count(value, ":") < 2 {
		return false
	}
	if strings.Index(value, "::") != strings.LastIndex(value, "::") {
		return false
	}
	var groups []string
	for _, half := range strings.Split(value, "::") {
		if half != "" {
			groups = append(groups, strings.Split(half, ":")...)
		}
	}
	extra := 0
	// Embedded IPv4 at the end: "::ffff:1.2.3.4"
	if len(groups) > 0 && strings.Contains(groups[len(groups)-1], ".") {
		if !isIPv4(groups[len(groups)-1]) {
			return false
		}
		groups = groups[:len(groups)-1]
		extra = 2
	}
	for _, g := range groups {
		if g == "" || len(g) > 4 {
			return false
		}
		if _, err := strconv.ParseUint(g, 16, 16); err != nil {
			return false
		}
	}
	total := len(groups) + extra
	if strings.Contains(value, "::") {
		return total < 8
	}
	return total == 8
}
