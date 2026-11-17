package libxray

import (
	"encoding/json"
	"net"
)

// The ping bridge. With Settings → «Уведомления через VPN» the tunnel takes every connection of the phone
// (includeAllNetworks; only then do Apple's notifications go through the VPN), and iOS no longer keeps the
// addresses left out of the tunnel's routes outside it: the app's pings, bound to the phone's interface and
// sent to those addresses, would go into the tunnel and through the current server, or nowhere. The one
// thing iOS still lets past the tunnel is the extension's own connections. So the extension's core listens
// on 127.0.0.1 (SOCKS, behind a password only the app and the extension know) and sends what comes in there
// straight out, the way the core reaches its servers; the app's delay tests dial their servers through it.

const (
	pingBridgeInTag  = "furk-ping-in"
	pingBridgeOutTag = "furk-ping-out"
	// The app's side: the outbound of a delay test that leads to the extension's bridge.
	pingBridgeDialTag = "furk-bridge"
)

// pingBridge is where the extension's bridge listens and its password: {"port": 51234, "user": "…", "pass": "…"}.
type pingBridge struct {
	Port int    `json:"port"`
	User string `json:"user"`
	Pass string `json:"pass"`
}

func (b *pingBridge) usable() bool { return b != nil && b.Port > 0 && b.Port < 65536 }

// FreeLocalPort returns a port on 127.0.0.1 that nothing listens on right now (for the ping bridge), 0
// when there is none.
func FreeLocalPort() int32 {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0
	}
	defer l.Close()
	return int32(l.Addr().(*net.TCPAddr).Port)
}

// The extension's side, added by BuildTunnelConfig: the inbound, its rule (before all others, the
// panel's and the user's: a ping must never go through a server) and the outbound.

func pingBridgeInbound(b *pingBridge) map[string]any {
	return map[string]any{
		"tag": pingBridgeInTag, "protocol": "socks", "listen": "127.0.0.1", "port": b.Port,
		"settings": map[string]any{
			"auth":     "password",
			"accounts": []any{map[string]any{"user": b.User, "pass": b.Pass}},
			// Hysteria and other servers over UDP.
			"udp": true, "ip": "127.0.0.1",
		},
	}
}

func pingBridgeRule() map[string]any {
	return map[string]any{"type": "field", "inboundTag": []any{pingBridgeInTag}, "outboundTag": pingBridgeOutTag}
}

func pingBridgeOutbound() map[string]any {
	return map[string]any{"tag": pingBridgeOutTag, "protocol": "freedom"}
}

// PingBridged is Ping with every server of the config dialed through the tunnel extension's ping bridge
// (bridgeJSON: {"port": …, "user": …, "pass": …}); -1 when the server did not answer or the bridge is unusable.
func PingBridged(configJSON string, testURL string, timeoutMs int32, bridgeJSON string) int64 {
	var b pingBridge
	if json.Unmarshal([]byte(bridgeJSON), &b) != nil || !b.usable() {
		return -1
	}
	bridged, err := throughBridge(configJSON, &b)
	if err != nil {
		return -1
	}
	return Ping(bridged, testURL, timeoutMs)
}

// throughBridge has every outbound that leads to a server dial through the bridge (sockopt.dialerProxy),
// except the later hops of a chain (their own dialerProxy): they go through their first hop, and that one
// goes through the bridge.
func throughBridge(configJSON string, b *pingBridge) (string, error) {
	cfg, err := parseConfig(configJSON)
	if err != nil {
		return "", err
	}
	outbounds, _ := cfg["outbounds"].([]any)
	for _, o := range outbounds {
		ob := asMap(o)
		if ob == nil || !proxyProtocols[stringOf(ob["protocol"])] {
			continue
		}
		stream := asMap(ob["streamSettings"])
		if stream == nil {
			stream = map[string]any{}
			ob["streamSettings"] = stream
		}
		sockopt := asMap(stream["sockopt"])
		if sockopt == nil {
			sockopt = map[string]any{}
			stream["sockopt"] = sockopt
		}
		if stringOf(sockopt["dialerProxy"]) != "" {
			continue
		}
		// Bound to an interface it would never reach 127.0.0.1.
		delete(sockopt, "interface")
		sockopt["dialerProxy"] = pingBridgeDialTag
	}
	cfg["outbounds"] = append(outbounds, map[string]any{
		"tag": pingBridgeDialTag, "protocol": "socks",
		"settings": map[string]any{"servers": []any{map[string]any{
			"address": "127.0.0.1", "port": b.Port,
			"users": []any{map[string]any{"user": b.User, "pass": b.Pass}},
		}}},
	})
	out, err := json.Marshal(cfg)
	return string(out), err
}
