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
//
// Round 662: the write is the session's own writer's, so Send itself never
// blocks; the deadline closes the session from the writer. The sender is
// paced (32 KB every 5 ms) and the queue limit put out of reach, so it is the
// deadline, not the limit, that closes it.
func TestSendGivesUpOnAStalledClient(t *testing.T) {
	old := SendTimeout
	SendTimeout = 200 * time.Millisecond
	t.Cleanup(func() { SendTimeout = old })
	setQueueLimit(t, 256<<20)

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

	// The client never reads: keep sending until the writer's deadline
	// passes on a full socket and the session is given up.
	big := &proto.Packet{Opcode: 2, Data: make([]byte, proto.MaxPayload)}
	var sendErr error
	var longest time.Duration
	start := time.Now()
	for time.Since(start) < 30*time.Second {
		t0 := time.Now()
		sendErr = s.Send(big)
		longest = max(longest, time.Since(t0))
		if sendErr != nil {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	if !errors.Is(sendErr, ErrSendStalled) {
		t.Fatalf("the stalled client's sends ended with %v, want ErrSendStalled", sendErr)
	}
	if longest > 50*time.Millisecond {
		t.Errorf("a send to the stalled client took %v: Send waited on the socket", longest.Round(time.Millisecond))
	}
	_, longestWrite, _ := s.SendStats()
	if longestWrite < SendTimeout || longestWrite > SendTimeout+time.Second {
		t.Errorf("the writer's longest write was %v, the deadline is %v", longestWrite, SendTimeout)
	}
	t0 := time.Now()
	if err := s.Send(&proto.Packet{Opcode: 3}); !errors.Is(err, ErrSendStalled) || time.Since(t0) > 50*time.Millisecond {
		t.Errorf("the next send: %v after %v, want ErrSendStalled at once", err, time.Since(t0))
	}
	select {
	case <-gone:
	case <-time.After(2 * time.Second):
		t.Fatal("the stalled session was never disconnected")
	}
}
