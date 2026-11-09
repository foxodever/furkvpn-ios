//go:build !darwin

package libxray

import "syscall"

// dialControlBound: binding to an interface is only needed (and done) on Apple platforms.
func dialControlBound(string) func(network, address string, c syscall.RawConn) error { return nil }
