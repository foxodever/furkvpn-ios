// Package libxray is a thin gomobile-friendly wrapper around Xray-core for the FurkVPN apps (Android, iOS).
//
// The Android side prepares a complete Xray JSON config (subscription config with the
// inbounds replaced by a "tun" inbound) and passes the VpnService TUN file descriptor.
// Xray-core reads that descriptor from the "xray.tun.fd" environment flag. The iOS tunnel passes
// the utun descriptor of its NetworkExtension the same way (apple.go).
package libxray

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"

	"github.com/xtls/xray-core/app/observatory"
	"github.com/xtls/xray-core/common/platform"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/features/dns"
	"github.com/xtls/xray-core/features/extension"
	"github.com/xtls/xray-core/features/outbound"
	"github.com/xtls/xray-core/features/stats"
	"github.com/xtls/xray-core/infra/conf/serial"
	_ "github.com/xtls/xray-core/main/distro/all"
	"github.com/xtls/xray-core/transport/internet"
)

var (
	mu       sync.Mutex
	instance *core.Instance
)

// Xray keeps some state per process rather than per instance: the log handler, and the DNS client
// and outbound manager its dialer uses (servers with a domain name are resolved through that DNS
// client). Every core.New takes them over, so a throwaway delay-test instance would leave the
// running VPN resolving its servers through a closed instance: lookups time out after 4 seconds
// and auto-select, which gives a server 3 seconds, sees its servers as down. createMu serializes
// core.New with putting the state back; running is the instance it belongs to.
var (
	createMu sync.Mutex
	running  atomic.Pointer[core.Instance]
)

// restoreRunningLocked gives the process-wide state back to the running instance. Hold createMu.
func restoreRunningLocked() {
	inst := running.Load()
	if inst == nil {
		return
	}
	installLogHandler(inst)
	if dnsClient, ok := inst.GetFeature(dns.ClientType()).(dns.Client); ok {
		obm, _ := inst.GetFeature(outbound.ManagerType()).(outbound.Manager)
		internet.InitSystemDialer(dnsClient, obm)
	}
}

// XrayVersion returns the embedded Xray-core version.
func XrayVersion() string {
	return core.Version()
}

// InitEnv sets the directory where Xray looks for geoip.dat / geosite.dat and other assets.
func InitEnv(assetDir string) {
	_ = os.Setenv(platform.AssetLocation, assetDir)
}

// ValidateConfig parses the JSON config and builds it without starting anything.
func ValidateConfig(configJSON string) error {
	_, err := loadConfig(configJSON)
	return err
}

// Start launches Xray with the given JSON config. tunFd is the VpnService TUN
// descriptor used by a "tun" inbound, or a negative value when there is none.
func Start(configJSON string, tunFd int32) error {
	mu.Lock()
	defer mu.Unlock()
	if instance != nil {
		return errors.New("xray is already running")
	}
	if tunFd >= 0 {
		_ = os.Setenv(platform.TunFdKey, strconv.Itoa(int(tunFd)))
	} else {
		_ = os.Unsetenv(platform.TunFdKey)
	}
	cfg, err := loadConfig(withFixes(configJSON))
	if err != nil {
		return err
	}
	createMu.Lock()
	inst, err := core.New(cfg)
	createMu.Unlock()
	if err != nil {
		return fmt.Errorf("create xray instance: %w", err)
	}
	if err := inst.Start(); err != nil {
		_ = inst.Close()
		return fmt.Errorf("start xray: %w", err)
	}
	instance = inst
	createMu.Lock()
	running.Store(inst)
	// A delay test may have created its instance after this one and taken over the process-wide state.
	restoreRunningLocked()
	createMu.Unlock()
	return nil
}

// Stop shuts down the running instance. The caller owns and closes the TUN descriptor afterwards.
func Stop() error {
	mu.Lock()
	defer mu.Unlock()
	if instance == nil {
		return nil
	}
	running.Store(nil)
	err := instance.Close()
	instance = nil
	_ = os.Unsetenv(platform.TunFdKey)
	return err
}

// IsRunning reports whether an instance is active.
func IsRunning() bool {
	mu.Lock()
	defer mu.Unlock()
	return instance != nil
}

// QueryStats returns the value of a stats counter of the running instance, e.g.
// "inbound>>>tun-in>>>traffic>>>downlink". Returns 0 when the counter does not exist.
func QueryStats(name string, reset bool) int64 {
	mu.Lock()
	inst := instance
	mu.Unlock()
	if inst == nil {
		return 0
	}
	sm, ok := inst.GetFeature(stats.ManagerType()).(stats.Manager)
	if !ok || sm == nil {
		return 0
	}
	c := sm.GetCounter(name)
	if c == nil {
		return 0
	}
	if reset {
		return c.Set(0)
	}
	return c.Value()
}

func loadConfig(configJSON string) (*core.Config, error) {
	cfg, err := serial.LoadJSONConfig(strings.NewReader(configJSON))
	if err != nil {
		return nil, fmt.Errorf("parse config: %w", err)
	}
	return cfg, nil
}

type serverCheck struct {
	Tag   string `json:"tag"`
	Alive bool   `json:"alive"`
	Delay int64  `json:"delay"`
	All   int64  `json:"all"`
	Fail  int64  `json:"fail"`
}

// ObservatoryStatus returns the server checks of the running instance (what auto-select picks
// from) as JSON: [{"tag":"proxy-2","alive":true,"delay":120,"all":1,"fail":0}, ...]; empty when
// the config has no observatory.
func ObservatoryStatus() string {
	mu.Lock()
	inst := instance
	mu.Unlock()
	if inst == nil {
		return ""
	}
	obs, ok := inst.GetFeature(extension.ObservatoryType()).(extension.Observatory)
	if !ok || obs == nil {
		return ""
	}
	msg, err := obs.GetObservation(context.Background())
	if err != nil {
		return ""
	}
	result, ok := msg.(*observatory.ObservationResult)
	if !ok {
		return ""
	}
	checks := make([]serverCheck, 0, len(result.Status))
	for _, s := range result.Status {
		c := serverCheck{Tag: s.OutboundTag, Alive: s.Alive, Delay: s.Delay}
		if s.HealthPing != nil {
			c.All, c.Fail = s.HealthPing.All, s.HealthPing.Fail
		}
		checks = append(checks, c)
	}
	b, _ := json.Marshal(checks)
	return string(b)
}

// RecheckServers makes auto-select check all its servers right now instead of waiting for the
// next round (after the phone wakes up, or when a server it used stops answering). It returns
// when the checks are done.
func RecheckServers() {
	mu.Lock()
	inst := instance
	mu.Unlock()
	if inst == nil {
		return
	}
	feature := inst.GetFeature(extension.ObservatoryType())
	checker, ok := feature.(interface{ Check([]string) })
	obs, ok2 := feature.(extension.Observatory)
	if !ok || !ok2 {
		return
	}
	msg, err := obs.GetObservation(context.Background())
	if err != nil {
		return
	}
	result, ok := msg.(*observatory.ObservationResult)
	if !ok || len(result.Status) == 0 {
		return
	}
	tags := make([]string, 0, len(result.Status))
	for _, s := range result.Status {
		tags = append(tags, s.OutboundTag)
	}
	checker.Check(tags)
}
