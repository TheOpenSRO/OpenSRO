package gateway

import (
	"context"
	"errors"
	"net"
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/proto"
)

// Round 656: a client that stops reading costs its writer at most
// SendTimeout, once. Its session is then closed -- the read loop ends and
// OnDisconnect runs -- and every later Send fails at once with
// ErrSendStalled. Before the round a Send to such a client blocked for ever,
// and with it the monster AI's tick.
func TestSendGivesUpOnAStalledClient(t *testing.T) {
	old := SendTimeout
	SendTimeout = 200 * time.Millisecond
	t.Cleanup(func() { SendTimeout = old })

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().String()
	ln.Close()
	sessions := make(chan *Session, 1)
	gone := make(chan struct{})
	srv := &Server{Addr: addr,
		Handle:       func(_ context.Context, s *Session, _ *proto.Packet) error { sessions <- s; return nil },
		OnDisconnect: func(*Session) { close(gone) }}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go srv.ListenAndServe(ctx)

	var conn net.Conn
	for i := 0; i < 50; i++ {
		if conn, err = net.DialTimeout("tcp", addr, 100*time.Millisecond); err == nil {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if err := proto.Write(conn, &proto.Packet{Opcode: 1}, nil, nil); err != nil {
		t.Fatal(err)
	}
	s := <-sessions

	// The client never reads: fill both sockets' buffers until a Send blocks
	// past the deadline.
	big := &proto.Packet{Opcode: 2, Data: make([]byte, proto.MaxPayload)}
	var sendErr error
	var took time.Duration
	for i := 0; i < 100000; i++ {
		start := time.Now()
		if sendErr = s.Send(big); sendErr != nil {
			took = time.Since(start)
			break
		}
	}
	var ne net.Error
	if !errors.As(sendErr, &ne) || !ne.Timeout() {
		t.Fatalf("the stalled send ended with %v, want a timeout", sendErr)
	}
	if took > SendTimeout+time.Second {
		t.Errorf("the stalled send took %v, the deadline is %v", took, SendTimeout)
	}
	start := time.Now()
	if err := s.Send(&proto.Packet{Opcode: 3}); !errors.Is(err, ErrSendStalled) || time.Since(start) > 50*time.Millisecond {
		t.Errorf("the next send: %v after %v, want ErrSendStalled at once", err, time.Since(start))
	}
	select {
	case <-gone:
	case <-time.After(2 * time.Second):
		t.Fatal("the stalled session was never disconnected")
	}
}
