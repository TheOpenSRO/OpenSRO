package gateway

import (
	"context"
	"io"
	"net"
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/proto"
)

// Round 656's third review: a healthy client reads its socket from the game's
// main thread (net_client.gd _process), so it reads nothing while a load
// freezes that thread -- 3.3 s at the Jangan world entry by the perf gate --
// and then everything at once. The send accounting must not close it for
// that. With the production budget and window (not shortened), a peer that
// stops reading for 4 s while a fan-out keeps writing to it, and then reads
// everything quickly, stays connected and receives every frame.
func TestAPeerThatFreezesThenReadsIsNotClosed(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().String()
	ln.Close()
	sessions := make(chan *Session, 2)
	srv := &Server{Addr: addr, Handle: func(_ context.Context, s *Session, _ *proto.Packet) error { sessions <- s; return nil }}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go srv.ListenAndServe(ctx)
	dial := func() net.Conn {
		var c net.Conn
		for i := 0; i < 50; i++ {
			if c, err = net.DialTimeout("tcp", addr, 100*time.Millisecond); err == nil {
				break
			}
			time.Sleep(10 * time.Millisecond)
		}
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { c.Close() })
		if err := proto.Write(c, &proto.Packet{Opcode: 1}, nil, nil); err != nil {
			t.Fatal(err)
		}
		return c
	}
	frozenConn := dial()
	frozen := <-sessions
	fastConn := dial()
	fast := <-sessions
	go io.Copy(io.Discard, fastConn)
	var got int64
	drained := make(chan struct{})
	go func() { // frozen for 4 s, then reads everything as fast as it can
		time.Sleep(4 * time.Second)
		n, _ := io.Copy(io.Discard, frozenConn)
		got = n
		close(drained)
	}()

	frame := &proto.Packet{Opcode: 2, Data: make([]byte, 16<<10)}
	var sent int64
	end := time.Now().Add(6 * time.Second)
	for time.Now().Before(end) {
		if err := frozen.Send(frame); err != nil {
			peak, longest, _ := frozen.SendStats()
			t.Fatalf("the freezing peer was closed after %d bytes: %v (debt peak %v, longest write %v, budget %v)",
				sent, err, peak.Round(time.Millisecond), longest.Round(time.Millisecond), SendBlockBudget)
		}
		sent += int64(len(frame.Data)) + 6
		if err := fast.Send(frame); err != nil {
			t.Fatalf("the fast peer: %v", err)
		}
	}
	peak, longest, _ := frozen.SendStats()
	t.Logf("the freezing peer: debt peak %v, longest write %v, %d bytes written, budget %v",
		peak.Round(time.Millisecond), longest.Round(time.Millisecond), sent, SendBlockBudget)
	frozen.Close()
	<-drained
	if got < sent {
		t.Errorf("the freezing peer read %d of %d bytes", got, sent)
	}
}
