package libxray

import (
	"encoding/json"
	"runtime/debug"
	"sort"
	"sync"
)

// Calls for the iOS app (Swift through gomobile): no error values or numbers paired with errors,
// so the Swift side gets plain strings and numbers.

// StartTunnel starts the core on the NetworkExtension TUN descriptor; it returns "" or the error.
// Auto-select's health state starts afresh with every core.
func StartTunnel(configJSON string, tunFd int32) string {
	autoSelect.reset()
	if err := Start(configJSON, tunFd); err != nil {
		return err.Error()
	}
	mu.Lock()
	inst := instance
	mu.Unlock()
	if inst != nil {
		createMu.Lock()
		installDebugLog(inst)
		createMu.Unlock()
	}
	return ""
}

// Ping returns MeasureDelay of configJSON in milliseconds, or -1 when the server did not answer.
func Ping(configJSON string, testURL string, timeoutMs int32) int64 {
	ms, err := MeasureDelay(configJSON, testURL, timeoutMs)
	if err != nil || ms < 0 {
		return -1
	}
	return ms
}

// PingVia is Ping with every connection of the test bound to the network interface iface ("en0" for
// Wi-Fi, "pdp_ip0" for cellular). While the VPN is on, the app's own connections go into the tunnel
// and a test from the app would measure the way through the current server; a socket bound to the
// phone's own interface goes past the tunnel (iOS doesn't enforce a VPN's routes on such sockets
// unless the VPN asks it to). Testing in the tunnel extension instead is not an option: every test
// is a whole Xray instance, auto-select's one probes all its servers at once, and the extension is
// killed at about 50 MB. Empty iface: plain Ping.
func PingVia(configJSON string, testURL string, timeoutMs int32, iface string) int64 {
	if iface != "" {
		bound, err := bindInterface(configJSON, iface)
		if err != nil {
			return -1
		}
		configJSON = bound
	}
	return Ping(configJSON, testURL, timeoutMs)
}

// bindInterface sets streamSettings.sockopt.interface on every outbound of the config.
func bindInterface(configJSON string, iface string) (string, error) {
	cfg, err := parseConfig(configJSON)
	if err != nil {
		return "", err
	}
	outbounds, _ := cfg["outbounds"].([]any)
	for _, o := range outbounds {
		ob := asMap(o)
		if ob == nil {
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
		sockopt["interface"] = iface
	}
	b, err := json.Marshal(cfg)
	return string(b), err
}

// SetMemoryLimit keeps the Go heap within mb megabytes (when mb > 0) and sets the GC target
// (when gcPercent > 0): the iOS Network Extension is killed at about 50 MB.
func SetMemoryLimit(mb int32, gcPercent int32) {
	if mb > 0 {
		debug.SetMemoryLimit(int64(mb) << 20)
	}
	if gcPercent > 0 {
		debug.SetGCPercent(int(gcPercent))
	}
}

// Auto-select switches only new connections, and only after its next check (once a minute). When
// a server it was using stops answering (checked twice), or none answers at all, the app restarts
// the core so apps reconnect through a live server instead of hanging on the dead one, and starts
// the next core with the best server as the balancer's fallback. The same logic as the Android
// app's VPN service; the app itself decides whether a restart can help (there is a network) and
// how often.

type autoSelectHealth struct {
	mu sync.Mutex
	// Auto-select servers that were carrying traffic at the last look (the two fastest).
	inUse []string
}

var autoSelect autoSelectHealth

func (h *autoSelectHealth) reset() {
	h.mu.Lock()
	h.inUse = nil
	h.mu.Unlock()
}

type autoSelectResult struct {
	Restart bool   `json:"restart"`
	Best    string `json:"best"`
}

// AutoSelectCheck looks at auto-select's last checks (afterSleep: checks all servers first, the
// phone may have slept with dead connections) and returns JSON: {"restart": true when a server it
// used stopped answering or none answers, "best": the fastest server answering now, or ""}.
func AutoSelectCheck(afterSleep bool) string {
	b, _ := json.Marshal(autoSelect.check(afterSleep, observatoryChecks, RecheckServers))
	return string(b)
}

func observatoryChecks() []serverCheck {
	status := ObservatoryStatus()
	if status == "" {
		return nil
	}
	var checks []serverCheck
	if json.Unmarshal([]byte(status), &checks) != nil {
		return nil
	}
	return checks
}

func (h *autoSelectHealth) check(afterSleep bool, observe func() []serverCheck, recheck func()) autoSelectResult {
	h.mu.Lock()
	defer h.mu.Unlock()
	if afterSleep {
		recheck()
	}
	checks := observe()
	if len(checks) == 0 {
		return autoSelectResult{}
	}
	lost := h.lost(h.inUse, checks)
	if !afterSleep && (len(lost) > 0 || !anyAlive(checks)) {
		// One failed check can be a hiccup: look again before dropping connections.
		recheck()
		if checks = observe(); len(checks) == 0 {
			return autoSelectResult{}
		}
		lost = h.lost(lost, checks)
	}
	var alive []serverCheck
	for _, c := range checks {
		if c.Alive {
			alive = append(alive, c)
		}
	}
	sort.SliceStable(alive, func(i, j int) bool { return alive[i].Delay < alive[j].Delay })
	var result autoSelectResult
	if len(alive) > 0 {
		result.Best = alive[0].Tag
	}
	h.inUse = nil
	for i := 0; i < len(alive) && i < 2; i++ {
		h.inUse = append(h.inUse, alive[i].Tag)
	}
	result.Restart = len(lost) > 0 || len(alive) == 0
	return result
}

// lost returns the tags that the checks see as not answering.
func (h *autoSelectHealth) lost(tags []string, checks []serverCheck) []string {
	var lost []string
	for _, tag := range tags {
		for _, c := range checks {
			if c.Tag == tag && !c.Alive {
				lost = append(lost, tag)
				break
			}
		}
	}
	return lost
}

func anyAlive(checks []serverCheck) bool {
	for _, c := range checks {
		if c.Alive {
			return true
		}
	}
	return false
}
