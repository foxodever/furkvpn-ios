package libxray

import "testing"

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
}

func TestStartTunnelReportsErrors(t *testing.T) {
	if msg := StartTunnel("not json", -1); msg == "" {
		t.Error("no error for a broken config")
	}
	if Ping("not json", "https://example.com", 100) != -1 {
		t.Error("ping of a broken config")
	}
}
