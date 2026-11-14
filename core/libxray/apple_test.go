package libxray

import (
	"encoding/json"
	"testing"
	"time"
)

func TestAutoSelectHealth(t *testing.T) {
	var h autoSelectHealth
	rechecks := 0
	var rounds [][]serverCheck
	observe := func() []serverCheck {
		c := rounds[0]
		if len(rounds) > 1 {
			rounds = rounds[1:]
		}
		return c
	}
	recheck := func() { rechecks++ }
	check := func(afterSleep bool, wantRestart bool, wantBest string, wantRechecks int) {
		t.Helper()
		rechecks = 0
		h.lastRecheck = time.Time{} // each case as if the last recheck was long ago
		r := h.check(afterSleep, observe, recheck)
		if r.Restart != wantRestart || r.Best != wantBest || rechecks != wantRechecks {
			t.Errorf("check = %+v after %d rechecks, want restart=%v best=%q after %d", r, rechecks, wantRestart, wantBest, wantRechecks)
		}
	}
	all := []serverCheck{{Tag: "a", Alive: true, Delay: 300}, {Tag: "b", Alive: true, Delay: 100}, {Tag: "c", Alive: true, Delay: 200}}
	rounds = [][]serverCheck{all}
	check(false, false, "b", 0)
	if len(h.inUse) != 2 || h.inUse[0] != "b" || h.inUse[1] != "c" {
		t.Fatalf("in use = %v", h.inUse)
	}

	// A server nobody uses goes down: nothing to do.
	rounds = [][]serverCheck{{{Tag: "a", Alive: false}, {Tag: "b", Alive: true, Delay: 100}, {Tag: "c", Alive: true, Delay: 200}}}
	check(false, false, "b", 0)

	// One that was in use fails once and answers on the second look: a hiccup.
	down := []serverCheck{{Tag: "a", Alive: true, Delay: 300}, {Tag: "b", Alive: false}, {Tag: "c", Alive: true, Delay: 200}}
	rounds = [][]serverCheck{down, all}
	check(false, false, "b", 1)

	// It fails twice: restart, starting with the best one left.
	rounds = [][]serverCheck{down, down}
	check(false, true, "c", 1)

	// None answers.
	rounds = [][]serverCheck{{{Tag: "a"}, {Tag: "b"}}}
	check(false, true, "", 1)

	// After sleep the servers are checked first and once.
	h.reset()
	rounds = [][]serverCheck{all}
	check(true, false, "b", 1)

	// No auto-select in the config.
	rounds = [][]serverCheck{nil}
	check(false, false, "", 0)

	// None answers, again and again: a recheck at most once a minute, nothing decided in between.
	h.reset()
	none := []serverCheck{{Tag: "a"}, {Tag: "b"}}
	rounds = [][]serverCheck{none}
	rechecks = 0
	if r := h.check(false, observe, recheck); !r.Restart || rechecks != 1 {
		t.Errorf("first look: %+v after %d rechecks", r, rechecks)
	}
	for i := 0; i < 5; i++ {
		if r := h.check(false, observe, recheck); r.Restart || rechecks != 1 {
			t.Errorf("look %d within a minute: %+v after %d rechecks", i+2, r, rechecks)
		}
	}
	h.lastRecheck = time.Now().Add(-recheckEvery)
	if r := h.check(false, observe, recheck); !r.Restart || rechecks != 2 {
		t.Errorf("a minute later: %+v after %d rechecks", r, rechecks)
	}
}

func TestStartTunnelReportsErrors(t *testing.T) {
	if msg := StartTunnel("not json", -1); msg == "" {
		t.Error("no error for a broken config")
	}
	if Ping("not json", "https://example.com", 100) != -1 {
		t.Error("ping of a broken config")
	}
}

func TestBindInterface(t *testing.T) {
	out, err := bindInterface(`{"outbounds":[
	  {"tag":"proxy","protocol":"vless","settings":{"vnext":[{"address":"1.2.3.4","port":443,"users":[{"id":"27848739-7e62-4138-9fd3-098a63964b6b","encryption":"none"}]}]},
	   "streamSettings":{"network":"xhttp","security":"tls","tlsSettings":{"serverName":"x.example"},"sockopt":{"tcpFastOpen":true,"mark":255}}},
	  {"tag":"direct","protocol":"freedom"}]}`, "en0")
	if err != nil {
		t.Fatal(err)
	}
	cfg := mustParse(t, out)
	outbounds := cfg["outbounds"].([]any)
	proxy := asMap(asMap(asMap(outbounds[0])["streamSettings"])["sockopt"])
	if proxy["interface"] != "en0" || proxy["tcpFastOpen"] != true || proxy["mark"] != json.Number("255") {
		t.Errorf("proxy sockopt = %v", proxy)
	}
	if direct := asMap(asMap(asMap(outbounds[1])["streamSettings"])["sockopt"]); direct["interface"] != "en0" {
		t.Errorf("direct sockopt = %v", direct)
	}
	if port := asMap(asMap(asMap(outbounds[0])["settings"])["vnext"].([]any)[0])["port"]; port != json.Number("443") {
		t.Errorf("port = %#v", port)
	}
	if err := ValidateConfig(out); err != nil {
		t.Errorf("Xray refuses it: %v", err)
	}
}
