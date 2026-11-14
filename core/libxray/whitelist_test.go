package libxray

import (
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

func TestWhitelistHosts(t *testing.T) {
	if got := WhitelistHosts(""); got != "www.google.com,www.gstatic.com,vk.ru,ya.ru" {
		t.Errorf("defaults: %s", got)
	}
	got := WhitelistHosts(`{"blockedProbes":["https://A.example/x","https://a.example/y"],"allowedProbes":["bad url ::","https://b.example"]}`)
	if got != "a.example,b.example" {
		t.Errorf("%s", got)
	}
}

type checkAnswer struct {
	Status  string        `json:"status"`
	Blocked []probeResult `json:"blocked"`
	Allowed []probeResult `json:"allowed"`
}

func runCheck(t *testing.T, config string, addresses map[string]string, pinnedOnly bool) checkAnswer {
	t.Helper()
	b, _ := json.Marshal(addresses)
	var a checkAnswer
	if err := json.Unmarshal([]byte(WhitelistCheck(config, string(b), pinnedOnly, "")), &a); err != nil {
		t.Fatal(err)
	}
	return a
}

func TestWhitelistCheck(t *testing.T) {
	var userAgentMu sync.Mutex
	var userAgent string
	open := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		userAgentMu.Lock()
		userAgent = r.UserAgent()
		userAgentMu.Unlock()
		if r.Method != http.MethodHead {
			t.Errorf("method %s", r.Method)
		}
		http.Redirect(w, r, "https://elsewhere.example/", http.StatusFound)
	}))
	defer open.Close()
	_, port, _ := net.SplitHostPort(strings.TrimPrefix(open.URL, "http://"))
	// A port nothing listens on: the closed site.
	closed, _ := net.Listen("tcp", "127.0.0.1:0")
	_, closedPort, _ := net.SplitHostPort(closed.Addr().String())
	closed.Close()

	config := `{"blockedProbes":["http://google.test:` + closedPort + `/generate_204"],"allowedProbes":["http://vk.test:` + port + `","http://ya.test:` + port + `"]}`
	a := runCheck(t, config, map[string]string{"google.test": "127.0.0.1", "vk.test": "127.0.0.1", "ya.test": "127.0.0.1"}, true)
	if a.Status != whitelistOn {
		t.Fatalf("status %s: %+v", a.Status, a)
	}
	if a.Blocked[0].Error != "CONNECT" || a.Blocked[0].Host != "google.test" || a.Allowed[0].Ms == nil || a.Allowed[1].Ms == nil {
		t.Errorf("%+v", a)
	}
	userAgentMu.Lock()
	agent := userAgent
	userAgentMu.Unlock()
	if strings.Contains(strings.ToLower(agent), "furk") || agent == "" {
		t.Errorf("user agent %q", agent)
	}

	// Everything answers.
	config = `{"blockedProbes":["http://google.test:` + port + `"],"allowedProbes":["http://vk.test:` + port + `"]}`
	if a := runCheck(t, config, map[string]string{"google.test": "127.0.0.1", "vk.test": "127.0.0.1"}, true); a.Status != whitelistAllOK {
		t.Errorf("status %s", a.Status)
	}
	// Pinned only: a host without an address is not looked up.
	a = runCheck(t, config, map[string]string{"vk.test": "127.0.0.1"}, true)
	if a.Status != whitelistOn || a.Blocked[0].Error != "DNS" {
		t.Errorf("%+v", a)
	}
	// Nothing answers.
	config = `{"blockedProbes":["http://google.test:` + closedPort + `"],"allowedProbes":["http://vk.test:` + closedPort + `"]}`
	if a := runCheck(t, config, map[string]string{"google.test": "127.0.0.1", "vk.test": "127.0.0.1"}, true); a.Status != whitelistNoInternet {
		t.Errorf("status %s", a.Status)
	}
}

func TestWhitelistTarget(t *testing.T) {
	servers := `[
		{"key":"wifi","remarks":"🎲 Автовыбор Wi-Fi","kind":"AUTO"},
		{"key":"lte","remarks":"🎲️ Автовыбор LTE","kind":"AUTO"},
		{"key":"nl","remarks":"🇳🇱 Нидерланды","kind":"SERVER"},
		{"key":"bypass","remarks":"🇷🇺 Все операторы","kind":"SERVER"}
	]`
	cases := []struct {
		old, now, current, auto, want string
	}{
		{"ALL_OK", "WHITELIST", "nl", "", "lte"},
		{"UNKNOWN", "WHITELIST", "wifi", "", "lte"},
		{"ALL_OK", "WHITELIST", "bypass", "", ""},
		{"ALL_OK", "WHITELIST", "lte", "", ""},
		{"WHITELIST", "WHITELIST", "nl", "", ""},
		// Back: only from the server the app chose, or from a bypass server.
		{"WHITELIST", "ALL_OK", "lte", "lte", "wifi"},
		{"WHITELIST", "ALL_OK", "lte", "", ""},
		{"WHITELIST", "ALL_OK", "bypass", "", "wifi"},
		{"UNKNOWN", "ALL_OK", "bypass", "", ""},
		{"WHITELIST", "ALL_OK", "wifi", "wifi", ""},
		{"ALL_OK", "NO_INTERNET", "nl", "", ""},
		{"ALL_OK", "WHITELIST", "gone", "", ""},
	}
	for _, c := range cases {
		if got := WhitelistTarget(c.old, c.now, c.current, servers, "", c.auto); got != c.want {
			t.Errorf("%+v: got %q", c, got)
		}
	}
	if got := WhitelistTarget("ALL_OK", "WHITELIST", "nl", `[{"key":"nl","remarks":"NL","kind":"SERVER"}]`, "", ""); got != "" {
		t.Errorf("no LTE server: %q", got)
	}
	if got := WhitelistPingServers(servers, ""); got != `["lte","bypass"]` {
		t.Errorf("ping servers %s", got)
	}
}
