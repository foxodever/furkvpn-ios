package libxray

import (
	"net"
	"net/url"
	"strconv"
	"strings"
	"sync"

	applog "github.com/xtls/xray-core/app/log"
	xlog "github.com/xtls/xray-core/common/log"
	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/core"
)

// ConnectionListener receives every new connection of the running instance while it is set
// (the app's connection log, off by default).
type ConnectionListener interface {
	// OnConnection: network is "tcp" or "udp"; src is the client (the app's socket on the TUN,
	// or a device using the share proxy); dstIP is the address the client connected to, empty
	// when it asked for a domain; domain is that domain, or the name the address was resolved
	// from through Xray's DNS when known; inbound and outbound are the tags the route went through.
	OnConnection(network, srcIP string, srcPort int32, dstIP string, dstPort int32, domain, inbound, outbound string)
}

type connEvent struct {
	network, srcIP, dstIP, domain, inbound, outbound string
	srcPort, dstPort                                 int32
}

var (
	listenerMu sync.RWMutex
	listener   ConnectionListener
	dnsNames   = newNameCache(8192)
)

// SetConnectionListener turns the connection log on (non-nil) or off (nil), for the running
// instance right away and for the ones started later.
func SetConnectionListener(l ConnectionListener) {
	listenerMu.Lock()
	listener = l
	listenerMu.Unlock()
	createMu.Lock()
	restoreRunningLocked()
	createMu.Unlock()
}

func currentListener() ConnectionListener {
	listenerMu.RLock()
	defer listenerMu.RUnlock()
	return listener
}

// installLogHandler wraps the instance's logger with the connection log when it is on.
func installLogHandler(inst *core.Instance) {
	next, _ := inst.GetFeature((*applog.Instance)(nil)).(xlog.Handler)
	switch {
	case currentListener() != nil:
		xlog.RegisterHandler(&connLogHandler{next: next})
	case next != nil:
		xlog.RegisterHandler(next)
	}
}

// connLogHandler sees access records (one per connection, with the route taken) and DNS answers
// (to show names instead of addresses), then passes everything on to Xray's own logger.
type connLogHandler struct {
	next xlog.Handler
}

func (h *connLogHandler) Handle(msg xlog.Message) {
	switch m := msg.(type) {
	case *xlog.AccessMessage:
		recordConnection(m)
	case *xlog.DNSLog:
		if m.Error == nil {
			name := strings.TrimSuffix(m.Domain, ".")
			for _, ip := range m.Result {
				dnsNames.put(ip.String(), name)
			}
		}
	}
	if h.next != nil {
		h.next.Handle(msg)
	}
}

// recordConnection runs before the connection is handed to its outbound, while the client's socket
// is still open, so the app can still find out whose socket it is (a blocked connection is closed
// right after this). That costs a little time per connection, which is fine for a debug feature.
func recordConnection(m *xlog.AccessMessage) {
	// A debug feature must never take the VPN down.
	defer func() { _ = recover() }()
	if m.Status != xlog.AccessAccepted {
		return
	}
	l := currentListener()
	if l == nil {
		return
	}
	if e, ok := eventOf(m); ok {
		l.OnConnection(e.network, e.srcIP, e.srcPort, e.dstIP, e.dstPort, e.domain, e.inbound, e.outbound)
	}
}

func eventOf(m *xlog.AccessMessage) (connEvent, bool) {
	network, dstHost, dstPort, ok := endpointOf(m.To)
	if !ok || dstHost == "" {
		return connEvent{}, false
	}
	e := connEvent{network: network, dstPort: dstPort}
	e.inbound, e.outbound = splitDetour(m.Detour)
	if ip := net.ParseIP(dstHost); ip != nil {
		e.dstIP = ip.String()
		e.domain = dnsNames.get(e.dstIP)
	} else {
		e.domain = dstHost
	}
	if _, srcHost, srcPort, ok := endpointOf(m.From); ok && net.ParseIP(srcHost) != nil {
		e.srcIP = srcHost
		e.srcPort = srcPort
	}
	return e, true
}

// endpointOf understands what Xray puts into access records: destinations, socket addresses and URLs.
func endpointOf(v any) (network, host string, port int32, ok bool) {
	switch d := v.(type) {
	case xnet.Destination:
		return destinationEndpoint(d)
	case *xnet.Destination:
		if d != nil {
			return destinationEndpoint(*d)
		}
	case *net.TCPAddr:
		if d != nil {
			return "tcp", d.IP.String(), int32(d.Port), true
		}
	case *net.UDPAddr:
		if d != nil {
			return "udp", d.IP.String(), int32(d.Port), true
		}
	case *url.URL:
		if d != nil && d.Hostname() != "" {
			p, _ := strconv.Atoi(d.Port())
			if p == 0 {
				p = 80
				if d.Scheme == "https" {
					p = 443
				}
			}
			return "tcp", d.Hostname(), int32(p), true
		}
	}
	return "", "", 0, false
}

func destinationEndpoint(d xnet.Destination) (string, string, int32, bool) {
	if d.Address == nil {
		return "", "", 0, false
	}
	network := "tcp"
	if d.Network == xnet.Network_UDP {
		network = "udp"
	}
	host := ""
	if d.Address.Family().IsDomain() {
		host = d.Address.Domain()
	} else {
		host = d.Address.IP().String()
	}
	return network, host, int32(d.Port), true
}

// splitDetour turns "tun-in -> proxy" (also ">>" and "==>") into the inbound and outbound tags.
func splitDetour(detour string) (inbound, outbound string) {
	for _, sep := range []string{" ==> ", " -> ", " >> "} {
		if i := strings.Index(detour, sep); i >= 0 {
			return detour[:i], detour[i+len(sep):]
		}
	}
	return "", detour
}

// nameCache remembers which name an address was resolved from, keeping the latest [size] addresses.
type nameCache struct {
	mu    sync.Mutex
	size  int
	names map[string]string
	ring  []string
	next  int
}

// newNameCache takes its memory with the first name: allocated in full at the start, 8192 entries were
// ~0.6 MB of each process (the tunnel's extension too) with the connection log off.
func newNameCache(size int) *nameCache {
	return &nameCache{size: size}
}

func (c *nameCache) put(ip, name string) {
	if ip == "" || name == "" {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.ring == nil {
		c.names = make(map[string]string)
		c.ring = make([]string, c.size)
	}
	if _, ok := c.names[ip]; !ok {
		if old := c.ring[c.next]; old != "" {
			delete(c.names, old)
		}
		c.ring[c.next] = ip
		c.next = (c.next + 1) % len(c.ring)
	}
	c.names[ip] = name
}

func (c *nameCache) get(ip string) string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.names[ip]
}
