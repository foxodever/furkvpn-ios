// Package libxray is a thin gomobile-friendly wrapper around Xray-core for the FurkVPN Android app.
//
// The Android side prepares a complete Xray JSON config (subscription config with the
// inbounds replaced by a "tun" inbound) and passes the VpnService TUN file descriptor.
// Xray-core reads that descriptor from the "xray.tun.fd" environment flag.
package libxray

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/xtls/xray-core/common/platform"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/features/stats"
	"github.com/xtls/xray-core/infra/conf/serial"
	_ "github.com/xtls/xray-core/main/distro/all"

	xnet "github.com/xtls/xray-core/common/net"
)

var (
	mu       sync.Mutex
	instance *core.Instance
)

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
	cfg, err := loadConfig(configJSON)
	if err != nil {
		return err
	}
	inst, err := core.New(cfg)
	if err != nil {
		return fmt.Errorf("create xray instance: %w", err)
	}
	if err := inst.Start(); err != nil {
		_ = inst.Close()
		return fmt.Errorf("start xray: %w", err)
	}
	instance = inst
	return nil
}

// Stop shuts down the running instance. The caller owns and closes the TUN descriptor afterwards.
func Stop() error {
	mu.Lock()
	defer mu.Unlock()
	if instance == nil {
		return nil
	}
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

// MeasureDelay starts a throwaway instance from configJSON (inbounds, routing and
// observatories removed, so traffic goes straight to the first proxy outbound) and
// returns the time in milliseconds needed to fetch testURL through it.
func MeasureDelay(configJSON string, testURL string, timeoutMs int32) (int64, error) {
	stripped, err := stripForDelayTest(configJSON)
	if err != nil {
		return -1, err
	}
	cfg, err := loadConfig(stripped)
	if err != nil {
		return -1, err
	}
	inst, err := core.New(cfg)
	if err != nil {
		return -1, err
	}
	if err := inst.Start(); err != nil {
		_ = inst.Close()
		return -1, err
	}
	defer inst.Close()
	return httpDelay(inst, testURL, time.Duration(timeoutMs)*time.Millisecond)
}

// MeasureRunningDelay measures delay through the currently running instance (respecting its routing).
func MeasureRunningDelay(testURL string, timeoutMs int32) (int64, error) {
	mu.Lock()
	inst := instance
	mu.Unlock()
	if inst == nil {
		return -1, errors.New("xray is not running")
	}
	return httpDelay(inst, testURL, time.Duration(timeoutMs)*time.Millisecond)
}

func loadConfig(configJSON string) (*core.Config, error) {
	cfg, err := serial.LoadJSONConfig(strings.NewReader(configJSON))
	if err != nil {
		return nil, fmt.Errorf("parse config: %w", err)
	}
	return cfg, nil
}

var proxyProtocols = map[string]bool{
	"vless": true, "vmess": true, "trojan": true, "shadowsocks": true,
	"hysteria": true, "wireguard": true, "socks": true, "http": true,
}

// stripForDelayTest keeps only what is needed to reach the first proxy outbound.
func stripForDelayTest(configJSON string) (string, error) {
	var cfg map[string]any
	if err := json.Unmarshal([]byte(configJSON), &cfg); err != nil {
		return "", fmt.Errorf("parse config: %w", err)
	}
	outbounds, _ := cfg["outbounds"].([]any)
	proxyIdx := -1
	for i, o := range outbounds {
		ob, _ := o.(map[string]any)
		if p, _ := ob["protocol"].(string); proxyProtocols[p] {
			proxyIdx = i
			break
		}
	}
	if proxyIdx < 0 {
		return "", errors.New("config has no proxy outbound")
	}
	// The first outbound is the default route; keep the others so dialerProxy chains still resolve.
	ordered := make([]any, 0, len(outbounds))
	ordered = append(ordered, outbounds[proxyIdx])
	ordered = append(ordered, outbounds[:proxyIdx]...)
	ordered = append(ordered, outbounds[proxyIdx+1:]...)
	out := map[string]any{
		"log":       map[string]any{"loglevel": "none"},
		"outbounds": ordered,
	}
	if dns, ok := cfg["dns"]; ok {
		out["dns"] = dns
	}
	b, err := json.Marshal(out)
	return string(b), err
}

func httpDelay(inst *core.Instance, testURL string, timeout time.Duration) (int64, error) {
	tr := &http.Transport{
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			dest, err := xnet.ParseDestination(network + ":" + addr)
			if err != nil {
				return nil, err
			}
			return core.Dial(ctx, inst, dest)
		},
		DisableKeepAlives:   true,
		TLSHandshakeTimeout: timeout,
	}
	client := &http.Client{Transport: tr, Timeout: timeout}
	defer tr.CloseIdleConnections()

	start := time.Now()
	req, err := http.NewRequest(http.MethodGet, testURL, nil)
	if err != nil {
		return -1, err
	}
	resp, err := client.Do(req)
	if err != nil {
		return -1, err
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent && resp.StatusCode != http.StatusOK {
		return -1, fmt.Errorf("unexpected status %d", resp.StatusCode)
	}
	return time.Since(start).Milliseconds(), nil
}
