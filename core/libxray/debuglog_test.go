package libxray

import (
	"strings"
	"testing"

	xlog "github.com/xtls/xray-core/common/log"
)

func TestDebugLogKeepsWarningsAndConnections(t *testing.T) {
	h := &debugLogHandler{}
	h.Handle(&xlog.GeneralMessage{Severity: xlog.Severity_Info, Content: "just info"})
	h.Handle(&xlog.GeneralMessage{Severity: xlog.Severity_Warning, Content: "failed to dial"})
	h.Handle(&xlog.AccessMessage{From: "172.19.0.1:50000", To: "tcp:example.com:443", Status: xlog.AccessAccepted, Detour: "tun-in -> proxy"})
	for i := 0; i < debugLogLines+10; i++ {
		h.Handle(&xlog.GeneralMessage{Severity: xlog.Severity_Error, Content: "again"})
	}
	out := DebugLog()
	if strings.Contains(out, "just info") {
		t.Error("info kept")
	}
	if !strings.Contains(out, "example.com:443") {
		t.Errorf("connection missing:\n%s", out)
	}
	if n := strings.Count(out, "again"); n != debugLogLines {
		t.Errorf("%d error lines kept", n)
	}
	if DebugErrors(-1) != "" || strings.Count(DebugErrors(2), "again") != 2 {
		t.Error("DebugErrors with odd counts")
	}
}
