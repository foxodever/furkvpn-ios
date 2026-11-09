package libxray

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

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
}

func TestDebugUploadPostsReports(t *testing.T) {
	got := make(chan string, 1)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		select {
		case got <- string(b):
		default:
		}
	}))
	defer srv.Close()
	DebugNote("tunnel started")
	StartDebugUpload(srv.URL, "")
	defer StopDebugUpload()
	select {
	case report := <-got:
		if !strings.Contains(report, "core running=false") || !strings.Contains(report, "[ext] tunnel started") {
			t.Errorf("report:\n%s", report)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("no report")
	}
}

func TestReportsLeaveOutDestinations(t *testing.T) {
	h := &debugLogHandler{}
	h.Handle(&xlog.AccessMessage{From: "172.19.0.1:50001", To: "tcp:secret-site.example:443", Status: xlog.AccessAccepted, Detour: "tun-in -> proxy"})
	h.Handle(&xlog.GeneralMessage{Severity: xlog.Severity_Warning, Content: "failed to dial udp:[2a00::1]:53 and tcp:9.9.9.9:853"})
	report := debugReport()
	for _, leak := range []string{"secret-site.example", "2a00::1", "9.9.9.9"} {
		if strings.Contains(report, leak) {
			t.Errorf("%s in the report:\n%s", leak, report)
		}
	}
	if !strings.Contains(report, "tcp:*:443") || !strings.Contains(report, "udp:*:53") {
		t.Errorf("ports and networks gone:\n%s", report)
	}
	if !strings.Contains(DebugLog(), "secret-site.example") {
		t.Error("the on-device log lost the destination")
	}
}
