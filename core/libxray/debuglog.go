package libxray

import (
	"fmt"
	"strings"
	"sync"
	"time"

	applog "github.com/xtls/xray-core/app/log"
	xlog "github.com/xtls/xray-core/common/log"
	"github.com/xtls/xray-core/core"
)

// The core's recent messages for the iOS diagnostics screen: the extension has no console the
// user can reach, and a re-signed build may have no shared files either, so the app asks the
// extension for them (DebugLog). Warnings and errors, and one line per connection with the
// route it took — enough to tell "no packets from the tunnel" from "DNS fails" from "the
// server refuses".

const debugLogLines = 150

var debugLog = struct {
	mu          sync.Mutex
	lines       []string
	connections []string
}{}

func remember(list *[]string, line string) {
	*list = append(*list, time.Now().Format("15:04:05 ")+line)
	if len(*list) > debugLogLines {
		*list = (*list)[len(*list)-debugLogLines:]
	}
}

type debugLogHandler struct {
	next xlog.Handler
}

func (h *debugLogHandler) Handle(msg xlog.Message) {
	debugLog.mu.Lock()
	switch m := msg.(type) {
	case *xlog.AccessMessage:
		remember(&debugLog.connections, m.String())
	case *xlog.GeneralMessage:
		if m.Severity <= xlog.Severity_Warning {
			remember(&debugLog.lines, m.String())
		}
	}
	debugLog.mu.Unlock()
	if h.next != nil {
		h.next.Handle(msg)
	}
}

// installDebugLog puts the recorder in front of the handlers installLogHandler would register.
func installDebugLog(inst *core.Instance) {
	next, _ := inst.GetFeature((*applog.Instance)(nil)).(xlog.Handler)
	if currentListener() != nil {
		next = &connLogHandler{next: next}
	}
	xlog.RegisterHandler(&debugLogHandler{next: next})
}

// DebugLog returns the core's recent warnings and errors and its recent connections, as text.
func DebugLog() string {
	debugLog.mu.Lock()
	defer debugLog.mu.Unlock()
	var b strings.Builder
	fmt.Fprintf(&b, "Ошибки и предупреждения ядра (%d):\n", len(debugLog.lines))
	for _, l := range debugLog.lines {
		b.WriteString(l + "\n")
	}
	fmt.Fprintf(&b, "\nСоединения (%d последних):\n", len(debugLog.connections))
	for _, l := range debugLog.connections {
		b.WriteString(l + "\n")
	}
	return b.String()
}

// CheckRunning fetches testURL through the running core's own routing, from inside the extension:
// "212 мс" when the server and DNS work (then a dead VPN is the tunnel's side), or the error.
func CheckRunning(testURL string, timeoutMs int32) string {
	ms, err := MeasureRunningDelay(testURL, timeoutMs)
	if err != nil {
		return "ошибка: " + err.Error()
	}
	return fmt.Sprintf("%d мс", ms)
}
