package libxray

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

// White lists (a port of the Android app's WhitelistMonitor and WhitelistRules): some operators let
// through only approved services. A check asks, directly and not through the VPN, sites that white
// lists close (Google) and sites that stay open (VK, Yandex); only the second ones answering means
// white lists are on, and the app moves to a server made for them.

type whitelistConfig struct {
	BlockedProbes []string `json:"blockedProbes"`
	AllowedProbes []string `json:"allowedProbes"`
	LteServer     []string `json:"lteServer"`
	WifiServer    []string `json:"wifiServer"`
	BypassServer  []string `json:"bypassServer"`
	// While white lists are on, the ping button checks only servers with one of these words.
	PingServers []string `json:"pingServers"`
}

// parseWhitelistConfig reads the "whitelist" block of the app's config; a missing (or broken)
// list keeps the Android app's default.
func parseWhitelistConfig(configJSON string) whitelistConfig {
	var c whitelistConfig
	_ = json.Unmarshal([]byte(configJSON), &c)
	if c.BlockedProbes == nil {
		c.BlockedProbes = []string{"https://www.google.com/generate_204", "https://www.gstatic.com/generate_204"}
	}
	if c.AllowedProbes == nil {
		c.AllowedProbes = []string{"https://vk.ru", "https://ya.ru"}
	}
	if c.LteServer == nil {
		c.LteServer = []string{"LTE", "🎲"}
	}
	if c.WifiServer == nil {
		c.WifiServer = []string{"Wi-Fi", "🎲"}
	}
	if c.BypassServer == nil {
		c.BypassServer = []string{"Все операторы"}
	}
	if c.PingServers == nil {
		c.PingServers = []string{"Все операторы", "LTE"}
	}
	return c
}

const (
	whitelistAllOK      = "ALL_OK"
	whitelistOn         = "WHITELIST"
	whitelistNoInternet = "NO_INTERNET"
)

// WhitelistHosts lists the host names of the check's sites ("www.google.com,vk.ru"): the tunnel
// extension resolves them before its tunnel is up and leaves them out of its routes, so the check
// reaches them directly while the VPN is on.
func WhitelistHosts(configJSON string) string {
	c := parseWhitelistConfig(configJSON)
	var hosts []string
	seen := map[string]bool{}
	for _, raw := range append(append([]string{}, c.BlockedProbes...), c.AllowedProbes...) {
		if u, err := url.Parse(strings.TrimSpace(raw)); err == nil {
			if host := strings.ToLower(u.Hostname()); host != "" && !seen[host] {
				seen[host] = true
				hosts = append(hosts, host)
			}
		}
	}
	return strings.Join(hosts, ",")
}

type probeResult struct {
	URL   string `json:"url"`
	Host  string `json:"host"`
	Ms    *int64 `json:"ms,omitempty"`
	Error string `json:"error,omitempty"`
}

const (
	probeConnectTimeout = 4 * time.Second
	probeTimeout        = 6 * time.Second
)

// WhitelistCheck asks every site of the config with a plain HEAD request (any HTTP answer means the
// site is reachable) and tells what that means. addressesJSON ({host: address}) gives the addresses to
// connect to; with pinnedOnly, a host without one fails instead of being looked up (the lookup would go
// through the VPN). iface binds the connections to the phone's own interface ("" — no binding).
// JSON {"status": "ALL_OK"/"WHITELIST"/"NO_INTERNET", "blocked": [...], "allowed": [...]}, each
// {"url", "host", "ms"} or {"url", "host", "error": "TIMEOUT"/"DNS"/"CONNECT"/"TLS"/"OTHER"}.
func WhitelistCheck(configJSON string, addressesJSON string, pinnedOnly bool, iface string) string {
	c := parseWhitelistConfig(configJSON)
	var given map[string]string
	_ = json.Unmarshal([]byte(addressesJSON), &given)
	addresses := map[string]string{}
	for host, address := range given {
		if net.ParseIP(address) != nil {
			addresses[strings.ToLower(host)] = address
		}
	}
	client := probeClient(addresses, pinnedOnly, iface)
	defer client.CloseIdleConnections()

	probeAll := func(urls []string) []probeResult {
		results := make([]probeResult, len(urls))
		var wg sync.WaitGroup
		for n, raw := range urls {
			wg.Add(1)
			go func(n int, raw string) {
				defer wg.Done()
				results[n] = probe(client, raw)
			}(n, raw)
		}
		wg.Wait()
		return results
	}
	var blocked, allowed []probeResult
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); blocked = probeAll(c.BlockedProbes) }()
	go func() { defer wg.Done(); allowed = probeAll(c.AllowedProbes) }()
	wg.Wait()

	answer := struct {
		Status  string        `json:"status"`
		Blocked []probeResult `json:"blocked"`
		Allowed []probeResult `json:"allowed"`
	}{whitelistStatus(anyOK(blocked), anyOK(allowed)), blocked, allowed}
	b, _ := json.Marshal(answer)
	return string(b)
}

func whitelistStatus(blockedOK, allowedOK bool) string {
	switch {
	case blockedOK:
		return whitelistAllOK
	case allowedOK:
		return whitelistOn
	default:
		return whitelistNoInternet
	}
}

func anyOK(results []probeResult) bool {
	for _, r := range results {
		if r.Error == "" {
			return true
		}
	}
	return false
}

// errNoAddress: pinnedOnly and the host has no address given.
var errNoAddress = errors.New("no address for the host")

// probeClient makes the check's requests: a fresh connection each time (a kept-alive one could still
// work after the operator has closed new connections to the site), no redirects, no proxy, and Go's own
// User-Agent — these requests go to the sites from the real address and must not tell them it is FurkVPN.
func probeClient(addresses map[string]string, pinnedOnly bool, iface string) *http.Client {
	dialer := &net.Dialer{Timeout: probeConnectTimeout, Control: dialControlBound(iface)}
	transport := &http.Transport{
		Proxy:             nil,
		DisableKeepAlives: true,
		DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
			host, port, err := net.SplitHostPort(address)
			if err != nil {
				return nil, err
			}
			if ip, ok := addresses[strings.ToLower(host)]; ok {
				return dialer.DialContext(ctx, network, net.JoinHostPort(ip, port))
			}
			if pinnedOnly && net.ParseIP(host) == nil {
				return nil, &net.DNSError{Err: errNoAddress.Error(), Name: host, IsNotFound: true}
			}
			return dialer.DialContext(ctx, network, address)
		},
		TLSHandshakeTimeout:   probeConnectTimeout,
		ResponseHeaderTimeout: probeConnectTimeout,
	}
	return &http.Client{
		Transport:     transport,
		Timeout:       probeTimeout,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
}

func probe(client *http.Client, raw string) probeResult {
	result := probeResult{URL: raw, Host: raw}
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || u.Hostname() == "" {
		result.Error = "OTHER"
		return result
	}
	result.Host = strings.TrimPrefix(strings.ToLower(u.Hostname()), "www.")
	req, err := http.NewRequest(http.MethodHead, u.String(), nil)
	if err != nil {
		result.Error = "OTHER"
		return result
	}
	started := time.Now()
	resp, err := client.Do(req)
	if err != nil {
		result.Error = probeError(err)
		return result
	}
	resp.Body.Close()
	ms := time.Since(started).Milliseconds()
	result.Ms = &ms
	return result
}

func probeError(err error) string {
	var dnsErr *net.DNSError
	var netErr net.Error
	var certErr *tls.CertificateVerificationError
	var recordErr tls.RecordHeaderError
	var unknownAuthority x509.UnknownAuthorityError
	var hostnameErr x509.HostnameError
	var opErr *net.OpError
	switch {
	case errors.As(err, &dnsErr):
		return "DNS"
	case errors.As(err, &certErr), errors.As(err, &recordErr), errors.As(err, &unknownAuthority), errors.As(err, &hostnameErr):
		return "TLS"
	case errors.Is(err, context.DeadlineExceeded), errors.As(err, &netErr) && netErr.Timeout():
		return "TIMEOUT"
	case errors.As(err, &opErr):
		return "CONNECT"
	case strings.Contains(err.Error(), "tls:"):
		return "TLS"
	case strings.Contains(err.Error(), "EOF"), strings.Contains(err.Error(), "connection reset"):
		return "CONNECT"
	default:
		return "OTHER"
	}
}

type whitelistServer struct {
	Key     string `json:"key"`
	Remarks string `json:"remarks"`
	Kind    string `json:"kind"`
}

// normalizeName drops the emoji variation selector: "⚡️" and "⚡" are the same word.
func normalizeName(s string) string { return strings.ToLower(strings.ReplaceAll(s, "️", "")) }

func nameHasAll(remarks string, words []string) bool {
	if len(words) == 0 {
		return false
	}
	name := normalizeName(remarks)
	for _, w := range words {
		if !strings.Contains(name, normalizeName(w)) {
			return false
		}
	}
	return true
}

func nameHasAny(remarks string, words []string) bool {
	name := normalizeName(remarks)
	for _, w := range words {
		if strings.Contains(name, normalizeName(w)) {
			return true
		}
	}
	return false
}

// WhitelistTarget is the server (its key) to switch to when the check's status changes from old to
// now, or "" to keep current. White lists on: the LTE server, unless a bypass or LTE server is already
// chosen. White lists off: back to the Wi-Fi server, only from a bypass server or from the server the
// app itself chose earlier (autoSwitched); one the user picked by hand stays. serversJSON: the
// selectable servers, [{"key", "remarks", "kind"}].
func WhitelistTarget(old string, now string, current string, serversJSON string, configJSON string, autoSwitched string) string {
	c := parseWhitelistConfig(configJSON)
	var servers []whitelistServer
	_ = json.Unmarshal([]byte(serversJSON), &servers)
	var cur *whitelistServer
	for n := range servers {
		if servers[n].Key == current {
			cur = &servers[n]
			break
		}
	}
	if cur == nil {
		return ""
	}
	first := func(words []string) string {
		for _, s := range servers {
			if s.Kind != "SEPARATOR" && nameHasAll(s.Remarks, words) {
				return s.Key
			}
		}
		return ""
	}
	switch {
	case now == whitelistOn && old != whitelistOn:
		if nameHasAny(cur.Remarks, c.BypassServer) || nameHasAll(cur.Remarks, c.LteServer) {
			return ""
		}
		return first(c.LteServer)
	case now == whitelistAllOK && old != whitelistAllOK:
		fromBypass := old == whitelistOn && nameHasAny(cur.Remarks, c.BypassServer)
		if cur.Key == autoSwitched || fromBypass {
			if target := first(c.WifiServer); target != cur.Key {
				return target
			}
		}
	}
	return ""
}

// WhitelistPingServers lists the keys of the servers made for white lists (the config's pingServers
// words): while white lists are on, the only ones worth pinging. JSON array.
func WhitelistPingServers(serversJSON string, configJSON string) string {
	c := parseWhitelistConfig(configJSON)
	var servers []whitelistServer
	_ = json.Unmarshal([]byte(serversJSON), &servers)
	keys := []string{}
	for _, s := range servers {
		if s.Kind != "SEPARATOR" && nameHasAny(s.Remarks, c.PingServers) {
			keys = append(keys, s.Key)
		}
	}
	b, _ := json.Marshal(keys)
	return string(b)
}
