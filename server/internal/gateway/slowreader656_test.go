package gateway

import (
	"context"
	"io"
	"net"
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/proto"
)

// Round 656's second review: a peer that reads slowly but steadily finishes
// every write inside SendTimeout, so the deadline alone never closes it --
// and a writer that fans out to it and to others (the monster AI's tick, the
// respawn scheduler, another player's blow) waits on it write after write.
// SendBlockBudget closes such a session once its writes have kept their
// writer waiting that long; the other player's sends go on. (Since round 662
// the fan-out does not wait at all, and the slow reader is closed by its
// queue limit or its own writer's budget: sendqueue662_test.go.)
func TestASlowSteadyReaderIsClosedWithinItsBudget(t *testing.T) {
	oldTimeout := SendTimeout
	SendTimeout = time.Second
	t.Cleanup(func() { SendTimeout = oldTimeout })
	budget := slowReaderBudget(t) // 300 ms, draining 300 ms per 3 s

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
	slowConn := dial()
	slow := <-sessions
	fastConn := dial()
	fast := <-sessions
	go io.Copy(io.Discard, fastConn)
	go func() { // 16 KB every 10 ms: about 1.6 MB/s, for ever
		buf := make([]byte, 16<<10)
		for {
			if _, err := io.ReadFull(slowConn, buf); err != nil {
				return
			}
			time.Sleep(10 * time.Millisecond)
		}
	}()

	// The fan-out: each pass writes one frame to the slow player, then one to
	// the fast one, as the AI tick writes a push to every watcher.
	frame := &proto.Packet{Opcode: 2, Data: make([]byte, 16<<10)}
	var heldBySlow time.Duration
	var slowErr error
	end := time.Now().Add(5 * time.Second)
	for time.Now().Before(end) {
		start := time.Now()
		slowErr = slow.Send(frame)
		heldBySlow += time.Since(start)
		if slowErr != nil {
			break
		}
		if err := fast.Send(frame); err != nil {
			t.Fatalf("the fast player's send failed: %v", err)
		}
		// Round 662: Send only queues, so a flat-out loop would outrun even
		// the fast player's reader and pass its queue limit; a pass a
		// millisecond is 16 MB/s to each.
		time.Sleep(time.Millisecond)
	}
	t.Logf("the slow reader held the fan-out %v, then: %v", heldBySlow.Round(time.Millisecond), slowErr)
	if slowErr == nil {
		t.Fatalf("the slow reader was never closed: it held the fan-out %v over 5 s (budget %v)", heldBySlow.Round(time.Millisecond), budget)
	}
	if heldBySlow > budget+500*time.Millisecond {
		t.Errorf("the slow reader held the fan-out %v before it was closed, budget %v", heldBySlow.Round(time.Millisecond), budget)
	}
	if err := fast.Send(frame); err != nil {
		t.Errorf("the fast player was closed too: %v", err)
	}
}
