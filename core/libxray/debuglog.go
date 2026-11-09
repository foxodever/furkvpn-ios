package libxray

import (
	"bytes"
	"fmt"
	"net/http"
	"regexp"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	applog "github.com/xtls/xray-core/app/log"
	xlog "github.com/xtls/xray-core/common/log"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/features/stats"
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
func DebugLog() string { return debugLogText(false) }

// Destinations in log lines: "tcp:www.example.com:443", "udp:1.2.3.4:53".
var logDestination = regexp.MustCompile(`\b(tcp|udp):(\[[0-9a-fA-F:.]+\]|[^\s:\[\]]+):(\d+)`)

// debugLogText with redact leaves out where the connections went (the sites the user opens), keeping
// the network, the port and the route: what leaves the phone in a debug report.
func debugLogText(redact bool) string {
	debugLog.mu.Lock()
	defer debugLog.mu.Unlock()
	clean := func(l string) string {
		if !redact {
			return l
		}
		return logDestination.ReplaceAllString(l, "$1:*:$3")
	}
	var b strings.Builder
	fmt.Fprintf(&b, "Ошибки и предупреждения ядра (%d):\n", len(debugLog.lines))
	for _, l := range debugLog.lines {
		b.WriteString(clean(l) + "\n")
	}
	fmt.Fprintf(&b, "\nСоединения (%d последних):\n", len(debugLog.connections))
	for _, l := range debugLog.connections {
		b.WriteString(clean(l) + "\n")
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

// DebugNote adds a line of the Swift side (the extension's start, restarts, memory) to the log.
func DebugNote(text string) {
	debugLog.mu.Lock()
	remember(&debugLog.lines, "[ext] "+text)
	debugLog.mu.Unlock()
}

var debugUpload struct {
	mu   sync.Mutex
	stop chan struct{}
}

// StartDebugUpload posts the extension's state and the log without destinations to url every 5 seconds until
// StopDebugUpload, from a goroutine of its own: the report keeps coming even when the Swift side
// of the extension is stuck, and stops when the process dies. Temporary, for finding out why the
// VPN carries no traffic on the iPhone; the user turns it on in Settings → Диагностика.
func StartDebugUpload(url string) {
	debugUpload.mu.Lock()
	defer debugUpload.mu.Unlock()
	if debugUpload.stop != nil || url == "" {
		return
	}
	stop := make(chan struct{})
	debugUpload.stop = stop
	go func() {
		client := &http.Client{Timeout: 5 * time.Second}
		tick := time.NewTicker(5 * time.Second)
		defer tick.Stop()
		for {
			if resp, err := client.Post(url, "text/plain; charset=utf-8", bytes.NewBufferString(debugReport())); err == nil {
				resp.Body.Close()
			}
			select {
			case <-stop:
				return
			case <-tick.C:
			}
		}
	}()
}

func StopDebugUpload() {
	debugUpload.mu.Lock()
	defer debugUpload.mu.Unlock()
	if debugUpload.stop != nil {
		close(debugUpload.stop)
		debugUpload.stop = nil
	}
}

var debugMemoryLeft atomic.Int64

// DebugMemoryLeft is what iOS still allows the extension (os_proc_available_memory), in MB, for the report.
func DebugMemoryLeft(mb int32) { debugMemoryLeft.Store(int64(mb)) }

func debugReport() string {
	var m runtime.MemStats
	runtime.ReadMemStats(&m)
	// TryLock: a core stuck in Start/Stop holds mu, and the report must still go out.
	state := "busy (mu held)"
	var up, down int64
	if mu.TryLock() {
		inst := instance
		mu.Unlock()
		state = fmt.Sprintf("running=%v", inst != nil)
		if inst != nil {
			if sm, ok := inst.GetFeature(stats.ManagerType()).(stats.Manager); ok && sm != nil {
				if c := sm.GetCounter("inbound>>>tun-in>>>traffic>>>uplink"); c != nil {
					up = c.Value()
				}
				if c := sm.GetCounter("inbound>>>tun-in>>>traffic>>>downlink"); c != nil {
					down = c.Value()
				}
			}
		}
	}
	return fmt.Sprintf("time %s · core %s · tun ↑%d ↓%d · goroutines %d · heap %.1f MB · sys %.1f MB · iOS allows %d MB more\n%s",
		time.Now().Format("15:04:05"), state, up, down, runtime.NumGoroutine(),
		float64(m.HeapInuse)/(1<<20), float64(m.Sys)/(1<<20), debugMemoryLeft.Load(), debugLogText(true))
}
