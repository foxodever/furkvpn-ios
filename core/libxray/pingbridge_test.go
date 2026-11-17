package libxray

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

const bridgeTemplate = `{"outbounds":[{"tag":"proxy","protocol":"vless","settings":{"vnext":[{"address":"1.2.3.4","port":443,
  "users":[{"id":"27848739-7e62-4138-9fd3-098a63964b6b","encryption":"none"}]}]},
  "streamSettings":{"security":"tls","tlsSettings":{"serverName":"x.example"}}},
  {"tag":"direct","protocol":"freedom"}],
 "routing":{"rules":[{"type":"field","domain":["keyword:yandex"],"outboundTag":"direct"}]}}`

func TestPingBridgeInTheTunnelConfig(t *testing.T) {
	out, err := BuildTunnelConfig(bridgeTemplate, `{"interface":"en0","noDirect":true,"bridge":{"port":51234,"user":"u","pass":"p"}}`)
	if err != nil {
		t.Fatal(err)
	}
	cfg := mustParse(t, out)
	inbounds := cfg["inbounds"].([]any)
	if len(inbounds) != 2 {
		t.Fatalf("inbounds = %v", inbounds)
	}
	bridge := asMap(inbounds[1])
	settings := asMap(bridge["settings"])
	account := asMap(settings["accounts"].([]any)[0])
	if bridge["tag"] != pingBridgeInTag || bridge["protocol"] != "socks" || bridge["listen"] != "127.0.0.1" ||
		bridge["port"] != json.Number("51234") || settings["auth"] != "password" || account["user"] != "u" || account["pass"] != "p" {
		t.Errorf("bridge inbound = %v", bridge)
	}
	if _, sniffs := bridge["sniffing"]; sniffs {
		t.Error("the bridge sniffs: a server's address would become its TLS name")
	}
	// First of all the rules, and still straight out in compatibility mode (noDirect).
	rules := rulesOf(cfg)
	if rules[0]["outboundTag"] != pingBridgeOutTag || fmt.Sprint(rules[0]["inboundTag"]) != "["+pingBridgeInTag+"]" {
		t.Errorf("first rule = %v", rules[0])
	}
	for _, r := range rules[1:] {
		if r["outboundTag"] == pingBridgeOutTag {
			t.Errorf("another rule to the bridge: %v", r)
		}
	}
	var found bool
	for _, o := range cfg["outbounds"].([]any) {
		ob := asMap(o)
		if ob["tag"] != pingBridgeOutTag {
			continue
		}
		found = true
		if ob["protocol"] != "freedom" || asMap(asMap(ob["streamSettings"])["sockopt"])["interface"] != "en0" {
			t.Errorf("bridge outbound = %v", ob)
		}
	}
	if !found {
		t.Error("no bridge outbound")
	}
	if err := ValidateConfig(out); err != nil {
		t.Errorf("Xray refuses it: %v", err)
	}

	for _, options := range []string{`{}`, `{"bridge":{"port":0,"user":"u","pass":"p"}}`, `{"bridge":null}`} {
		plain, err := BuildTunnelConfig(bridgeTemplate, options)
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(plain, "furk-ping") {
			t.Errorf("%s: a bridge", options)
		}
	}
}

func TestThroughBridge(t *testing.T) {
	out, err := throughBridge(`{"outbounds":[
	  {"tag":"proxy","protocol":"vless","settings":{"vnext":[{"address":"1.2.3.4","port":443,"users":[{"id":"27848739-7e62-4138-9fd3-098a63964b6b","encryption":"none"}]}]},
	   "streamSettings":{"security":"tls","tlsSettings":{"serverName":"x.example"},"sockopt":{"interface":"en0","tcpFastOpen":true}}},
	  {"tag":"own","protocol":"trojan","settings":{"servers":[{"address":"9.9.9.9","port":443,"password":"x"}]},
	   "streamSettings":{"security":"tls","tlsSettings":{"serverName":"y.example"},"sockopt":{"dialerProxy":"proxy"}}},
	  {"tag":"direct","protocol":"freedom"}]}`, &pingBridge{Port: 40000, User: "u", Pass: "p"})
	if err != nil {
		t.Fatal(err)
	}
	cfg := mustParse(t, out)
	outbounds := cfg["outbounds"].([]any)
	sockopt := func(i int) map[string]any { return asMap(asMap(asMap(outbounds[i])["streamSettings"])["sockopt"]) }
	if s := sockopt(0); s["dialerProxy"] != pingBridgeDialTag || s["interface"] != nil || s["tcpFastOpen"] != true {
		t.Errorf("proxy sockopt = %v", s)
	}
	if s := sockopt(1); s["dialerProxy"] != "proxy" {
		t.Errorf("a chain's second hop dials the bridge: %v", s)
	}
	if s := sockopt(2); s["dialerProxy"] != nil {
		t.Errorf("freedom dials the bridge: %v", s)
	}
	bridge := asMap(outbounds[3])
	server := asMap(asMap(bridge["settings"])["servers"].([]any)[0])
	if bridge["tag"] != pingBridgeDialTag || server["address"] != "127.0.0.1" || server["port"] != json.Number("40000") {
		t.Errorf("bridge outbound = %v", bridge)
	}
	if got := proxyOutbounds(cfg); fmt.Sprint(got) != "[0 1]" {
		t.Errorf("servers = %v: the bridge taken for one", got)
	}
	if err := ValidateConfig(out); err != nil {
		t.Errorf("Xray refuses it: %v", err)
	}
}

// The whole way: a delay test in the app → the extension's bridge (password) → straight out → the server.
func TestPingBridgedReachesTheServerThroughTheBridge(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusNoContent) }))
	defer srv.Close()

	// The "server": a SOCKS proxy on this machine.
	serverPort := int(FreeLocalPort())
	server, err := startTestInstance(mustParse(t, fmt.Sprintf(`{"log":{"loglevel":"none"},
	  "inbounds":[{"protocol":"socks","listen":"127.0.0.1","port":%d,"settings":{"auth":"noauth","udp":true}}],
	  "outbounds":[{"protocol":"freedom"}]}`, serverPort)))
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()

	// The extension's core with its bridge; its TUN inbound is left out (there is no tunnel here), and its
	// server is one that doesn't answer: a ping that went through it would fail.
	bridgePort := int(FreeLocalPort())
	tunnel, err := BuildTunnelConfig(bridgeTemplate, fmt.Sprintf(`{"bridge":{"port":%d,"user":"furk","pass":"secret"}}`, bridgePort))
	if err != nil {
		t.Fatal(err)
	}
	cfg := mustParse(t, tunnel)
	cfg["inbounds"] = cfg["inbounds"].([]any)[1:]
	cfg["log"] = map[string]any{"loglevel": "none"}
	ext, err := startTestInstance(cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer ext.Close()

	ping := fmt.Sprintf(`{"outbounds":[{"tag":"proxy","protocol":"socks","settings":{"servers":[{"address":"127.0.0.1","port":%d}]}}]}`, serverPort)
	if ms := PingBridged(ping, srv.URL, 3000, fmt.Sprintf(`{"port":%d,"user":"furk","pass":"secret"}`, bridgePort)); ms < 0 {
		t.Fatalf("through the bridge: %d", ms)
	}
	if ms := PingBridged(ping, srv.URL, 2000, fmt.Sprintf(`{"port":%d,"user":"furk","pass":"wrong"}`, bridgePort)); ms >= 0 {
		t.Errorf("with a wrong password: %d ms — the test didn't go through the bridge", ms)
	}
	if PingBridged(ping, srv.URL, 1000, `{}`) != -1 || PingBridged(ping, srv.URL, 1000, "nope") != -1 {
		t.Error("a ping without a bridge")
	}
}
