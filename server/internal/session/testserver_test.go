package session

// Shared by the session tests: a gateway on a free port and a client
// connection to it (moved here from character_test.go in round 682, when the
// old 0x0010-0x0015 lobby and its tests went).

import (
	"context"
	"encoding/binary"
	"net"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
)

// startTestServer spins up a gateway.Server on an ephemeral port with the
// given handler, returning its address and a cleanup func.
func startTestServer(t *testing.T, handle gateway.Handler) (string, func()) {
	t.Helper()

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	addr := ln.Addr().String()
	ln.Close()

	srv := &gateway.Server{Addr: addr, Handle: handle}
	ctx, cancel := context.WithCancel(context.Background())
	errCh := make(chan error, 1)
	go func() { errCh <- srv.ListenAndServe(ctx) }()

	return addr, cancel
}

// dialTestServer dials addr and hides OpSelfID (round 616) and
// OpPlayerZoneNotice (round 737's review, OURS: the "entered/left the zone"
// line ahead of a real arrival's spawn or a leave's despawn) from the reader:
// every test written before it reads the packet after OpEnterWorldResult as
// the answer to its next request, and the id is not what any of them tests.
// A test of OpSelfID itself uses dialTestServerRaw.
func dialTestServer(t *testing.T, addr string) net.Conn {
	t.Helper()
	return &selfIDFilterConn{Conn: dialTestServerRaw(t, addr)}
}

// selfIDFilterConn drops whole OpSelfID frames from the byte stream it reads
// (unencrypted framing: proto's 6-byte header, u16 size, u16 opcode).
type selfIDFilterConn struct {
	net.Conn
	raw, out []byte
}

func (c *selfIDFilterConn) Read(p []byte) (int, error) {
	for len(c.out) == 0 {
		for len(c.raw) >= 6 {
			size := int(binary.LittleEndian.Uint16(c.raw[0:2]) & 0x7fff)
			if len(c.raw) < 6+size {
				break
			}
			if op := binary.LittleEndian.Uint16(c.raw[2:4]); op != OpSelfID && op != OpPlayerZoneNotice {
				c.out = append(c.out, c.raw[:6+size]...)
			}
			c.raw = c.raw[6+size:]
		}
		if len(c.out) > 0 {
			break
		}
		buf := make([]byte, 4096)
		n, err := c.Conn.Read(buf)
		c.raw = append(c.raw, buf[:n]...)
		if err != nil && n == 0 {
			return 0, err
		}
	}
	n := copy(p, c.out)
	c.out = c.out[n:]
	return n, nil
}

// dialTestServerRaw dials addr and returns the connection as it is.
func dialTestServerRaw(t *testing.T, addr string) net.Conn {
	t.Helper()
	var conn net.Conn
	var err error
	for i := 0; i < 50; i++ {
		conn, err = net.DialTimeout("tcp", addr, 100*time.Millisecond)
		if err == nil {
			return conn
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("dial: %v", err)
	return nil
}
