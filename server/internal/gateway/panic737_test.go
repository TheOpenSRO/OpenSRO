package gateway

import (
	"bufio"
	"context"
	"net"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
)

// A handler that panics ends its own session and nothing else (round 737's
// verification, N1): OnDisconnect runs for it, and a second session is
// served as before. Before, the panic ended the process.
func TestAHandlerPanicEndsOnlyItsSession(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	disconnected := make(chan uint64, 2)
	srv := &Server{
		Addr: "127.0.0.1:0",
		Handle: func(_ context.Context, sess *Session, p *proto.Packet) error {
			if p.Opcode == 0x6666 {
				var m map[int]int
				m[1] = 1 // a nil-map write: a real runtime panic
			}
			return sess.Send(&proto.Packet{Opcode: p.Opcode + 1, Data: p.Data})
		},
		OnDisconnect: func(sess *Session) { disconnected <- sess.ID() },
	}
	ln, err := net.Listen("tcp", srv.Addr)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	addr := ln.Addr().String()
	ln.Close()
	srv.Addr = addr
	go srv.ListenAndServe(ctx)

	dial := func() net.Conn {
		t.Helper()
		var conn net.Conn
		for i := 0; i < 50; i++ {
			if conn, err = net.DialTimeout("tcp", addr, 100*time.Millisecond); err == nil {
				return conn
			}
			time.Sleep(20 * time.Millisecond)
		}
		t.Fatalf("dial: %v", err)
		return nil
	}

	bad := dial()
	defer bad.Close()
	if err := proto.Write(bad, &proto.Packet{Opcode: 0x6666}, nil, nil); err != nil {
		t.Fatalf("write: %v", err)
	}
	select {
	case <-disconnected:
	case <-time.After(2 * time.Second):
		t.Fatal("the panicking session was not ended")
	}

	good := dial()
	defer good.Close()
	if err := proto.Write(good, &proto.Packet{Opcode: 0x6100, Data: []byte("ping")}, nil, nil); err != nil {
		t.Fatalf("write: %v", err)
	}
	good.SetReadDeadline(time.Now().Add(2 * time.Second))
	reply, err := proto.Read(bufio.NewReader(good), nil, nil)
	if err != nil {
		t.Fatalf("the server stopped serving after a handler panic: %v", err)
	}
	if reply.Opcode != 0x6101 || string(reply.Data) != "ping" {
		t.Fatalf("unexpected reply: %+v", reply)
	}
}
