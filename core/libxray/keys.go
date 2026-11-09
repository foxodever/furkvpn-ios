package libxray

import (
	"encoding/json"
	"net/url"
	"regexp"
	"strings"
)

// A key is the Remnawave subscription link, the same one Happ takes. ParseKey turns whatever the
// user pasted, scanned or opened (a bare link, a https://furkapp.net/import?url=… link,
// furkvpn://import?url=…, or a message that contains a link) into a normalized key, like the
// Android app's KeyParser.

var (
	// Remnawave client-type suffixes: https://sub.example.com/<shortUuid>/<type>.
	clientSuffixes = map[string]bool{"json": true, "v2ray-json": true, "singbox": true, "mihomo": true, "clash": true, "stash": true}
	importHosts    = map[string]bool{"furkapp.net": true, "www.furkapp.net": true}

	keyURL     = regexp.MustCompile(`(?i)\b(?:https?|furkvpn)://[^\s"'<>«»]+`)
	keyBare    = regexp.MustCompile(`(?i)\b(?:[a-z0-9-]+\.)+[a-z]{2,}/[^\s"'<>«»]+`)
	keyURLArgs = regexp.MustCompile(`[?&]url=([^&#]+)`)

	// What the app accepts when the API's list is missing or empty: a broken answer must never lock
	// people out.
	defaultSubscriptionHosts = []string{"*.furkvpn.com", "furkconnection.net"}
)

type parsedKey struct {
	Result  string `json:"result"`
	URL     string `json:"url,omitempty"`
	Host    string `json:"host,omitempty"`
	Path    string `json:"path,omitempty"`
	ShortID string `json:"shortId,omitempty"`
}

// ParseKey returns JSON: {"result":"ok","url":"https://sub.furkvpn.com/<id>","host":"sub.furkvpn.com",
// "path":"/<id>","shortId":"<id>"}, or {"result":"empty"|"notALink"|"foreign"}. allowedHostsJSON is
// the API's allowedSubscriptionHosts: ["*.furkvpn.com", "furkconnection.net"].
func ParseKey(input string, allowedHostsJSON string) string {
	b, _ := json.Marshal(parseKey(input, hostPatterns(allowedHostsJSON)))
	return string(b)
}

// HostAllowed reports whether host is one of the patterns of allowedHostsJSON ("*.furkvpn.com"
// covers its subdomains, not furkvpn.com itself).
func HostAllowed(host string, allowedHostsJSON string) bool {
	return hostAllowed(host, hostPatterns(allowedHostsJSON))
}

func hostPatterns(allowedHostsJSON string) []string {
	var patterns []string
	if json.Unmarshal([]byte(allowedHostsJSON), &patterns) != nil || len(patterns) == 0 {
		return defaultSubscriptionHosts
	}
	return patterns
}

func parseKey(input string, allowed []string) parsedKey {
	text := strings.TrimSpace(input)
	if text == "" {
		return parsedKey{Result: "empty"}
	}
	links := findKeyURLs(text)
	if len(links) == 0 {
		return parsedKey{Result: "notALink"}
	}
	// A message may have other links before the key (t.me, the site): the first key wins.
	var first parsedKey
	for i, link := range links {
		result := parseKeyLink(link, allowed)
		if result.Result == "ok" {
			return result
		}
		if i == 0 {
			first = result
		}
	}
	return first
}

func parseKeyLink(candidate string, allowed []string) parsedKey {
	for range 3 {
		inner := unwrapKey(candidate)
		if inner == "" {
			break
		}
		candidate = inner
	}
	u, err := url.Parse(candidate)
	if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Hostname() == "" {
		return parsedKey{Result: "notALink"}
	}
	host := strings.TrimRight(strings.ToLower(u.Hostname()), ".")
	if importHosts[host] {
		return parsedKey{Result: "notALink"}
	}
	if !hostAllowed(host, allowed) {
		return parsedKey{Result: "foreign"}
	}
	var segments []string
	for _, s := range strings.Split(u.Path, "/") {
		if s != "" {
			segments = append(segments, s)
		}
	}
	if len(segments) > 1 && clientSuffixes[strings.ToLower(segments[len(segments)-1])] {
		segments = segments[:len(segments)-1]
	}
	if len(segments) == 0 {
		return parsedKey{Result: "notALink"}
	}
	authority := host
	if port := u.Port(); port != "" && !(u.Scheme == "https" && port == "443") && !(u.Scheme == "http" && port == "80") {
		authority += ":" + port
	}
	var path strings.Builder
	for _, s := range segments {
		path.WriteString("/" + url.PathEscape(s))
	}
	return parsedKey{
		Result:  "ok",
		URL:     "https://" + authority + path.String(),
		Host:    host,
		Path:    path.String(),
		ShortID: url.PathEscape(segments[len(segments)-1]),
	}
}

func hostAllowed(host string, patterns []string) bool {
	h := strings.TrimRight(strings.ToLower(host), ".")
	for _, raw := range patterns {
		p := strings.TrimRight(strings.ToLower(strings.TrimSpace(raw)), ".")
		switch {
		case p == "":
		case strings.HasPrefix(p, "*."):
			suffix := p[1:] // ".furkvpn.com"
			if strings.HasSuffix(h, suffix) && len(h) > len(suffix) {
				return true
			}
		case h == p:
			return true
		}
	}
	return false
}

func findKeyURLs(text string) []string {
	const trailing = ".,)]!?;"
	var links []string
	for _, m := range keyURL.FindAllString(text, -1) {
		links = append(links, strings.TrimRight(m, trailing))
	}
	if len(links) > 0 {
		return links
	}
	for _, m := range keyBare.FindAllString(text, -1) {
		links = append(links, "https://"+strings.TrimRight(m, trailing))
	}
	return links
}

// unwrapKey extracts the inner key from import wrappers, or returns "" when link is not a wrapper.
func unwrapKey(link string) string {
	lower := strings.ToLower(link)
	wrapper := strings.HasPrefix(lower, "furkvpn://")
	for h := range importHosts {
		wrapper = wrapper || strings.HasPrefix(lower, "https://"+h+"/") || strings.HasPrefix(lower, "http://"+h+"/")
	}
	if !wrapper {
		return ""
	}
	if m := keyURLArgs.FindStringSubmatch(link); m != nil {
		inner, err := url.QueryUnescape(m[1])
		if err != nil {
			return ""
		}
		return inner
	}
	// furkvpn://add/<url>
	_, rest, _ := strings.Cut(link, "://")
	_, tail, found := strings.Cut(rest, "/")
	if !found || !strings.HasPrefix(strings.ToLower(tail), "http") {
		return ""
	}
	inner, err := url.QueryUnescape(tail)
	if err != nil {
		return ""
	}
	return inner
}
