package libxray

import "strings"

// Hysteria 2 servers come from the panel as outbounds of protocol "hysteria" over the "hysteria"
// transport. Remnawave writes their port hopping the way Xray took it until 26.7:
//
//	"finalmask": {"quicParams": {"udpHop": {"ports": "20000-50000", "interval": "5-10"}}}
//
// The core here takes port hopping as the last UDP mask instead and ignores the old field, so
// the connection would stay on the one port the server is listed with.
//
//	"finalmask": {"udp": [..., {"type": "udphop", "settings": {"mode": "intervalLocal,intervalRemote",
//	              "remotePorts": "20000-50000", "interval": "5-10"}}]}
//
// Like the old hopping (and the Hysteria client), every hop moves to a new local socket and a
// random port of the range.

// defaultHopInterval is what the old field meant when it had no interval, in seconds.
const defaultHopInterval = 30

// upgradeHysteria rewrites the old port hopping of the config's outbounds into the new form.
// Reports whether it changed anything.
func upgradeHysteria(cfg map[string]any) bool {
	outbounds, _ := cfg["outbounds"].([]any)
	changed := false
	for _, o := range outbounds {
		stream := asMap(asMap(o)["streamSettings"])
		mask := asMap(stream["finalmask"])
		quic := asMap(mask["quicParams"])
		hop, ok := quic["udpHop"].(map[string]any)
		if !ok {
			continue
		}
		delete(quic, "udpHop")
		changed = true
		if isBlank(hop["ports"]) {
			continue
		}
		udp, _ := mask["udp"].([]any)
		hasHop := false
		for _, m := range udp {
			if t, _ := asMap(m)["type"].(string); strings.EqualFold(t, "udphop") {
				hasHop = true
			}
		}
		if hasHop {
			continue
		}
		interval := hop["interval"]
		if isBlank(interval) {
			interval = defaultHopInterval
		}
		udpHop := map[string]any{"type": "udphop", "settings": map[string]any{
			"mode":        "intervalLocal,intervalRemote",
			"remotePorts": hop["ports"],
			"interval":    interval,
		}}
		// Port hopping goes last: Xray applies the masks from the end of the list, and it has to
		// own the socket.
		mask["udp"] = append(udp, udpHop)
	}
	return changed
}

func isBlank(v any) bool {
	switch v := v.(type) {
	case nil:
		return true
	case string:
		return strings.TrimSpace(v) == ""
	}
	return false
}
