//go:build darwin

package libxray

import (
	"net"
	"strings"
	"syscall"

	"golang.org/x/sys/unix"
)

// dialControlBound binds a socket to the network interface iface (IP_BOUND_IF), past the tunnel;
// nil (no binding) for an empty iface.
func dialControlBound(iface string) func(network, address string, c syscall.RawConn) error {
	if iface == "" {
		return nil
	}
	return func(network, address string, c syscall.RawConn) error {
		ifi, err := net.InterfaceByName(iface)
		if err != nil {
			return err
		}
		var sockErr error
		if err := c.Control(func(fd uintptr) {
			if strings.HasSuffix(network, "6") {
				sockErr = unix.SetsockoptInt(int(fd), unix.IPPROTO_IPV6, unix.IPV6_BOUND_IF, ifi.Index)
			} else {
				sockErr = unix.SetsockoptInt(int(fd), unix.IPPROTO_IP, unix.IP_BOUND_IF, ifi.Index)
			}
		}); err != nil {
			return err
		}
		return sockErr
	}
}
