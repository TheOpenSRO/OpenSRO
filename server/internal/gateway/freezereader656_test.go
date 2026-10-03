package gateway

import (
	"bufio"
	"context"
	"encoding/binary"
	"io"
	"net"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/proto"
)

// Round 656's third review: a healthy client reads its socket from the game's
// main thread (net_client.gd _process), so it reads nothing while a load
// freezes that thread -- 3.3 s at the Jangan world entry by the perf gate --
// and then everything at once. The send accounting must not close it for
// that. With the production budget, window and queue limit (not shortened),
// a peer that stops reading for 4 s while a fan-out keeps writing to it, and
// then reads everything quickly, stays connected and receives every frame, in
// order.
//
// Round 662: Send only queues, so the fan-out is paced -- 16 KB every 100 ms
// (160 KB/s, 640 KB over the freeze, under the 2 MB SendQueueLimit; the live
// client was sent about 6 KB/s, and 132 KB in its busiest 4 s, round 662) -- where round 656's wrote flat out, its pace set by its own
// blocking. The server's send buffer is cut to 16 KB, so the writer is
// blocked for most of the freeze and its debt runs up as round 656's did: the budget is
// exercised, not skipped. No Send waits meanwhile.
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
	smallBuffers(t, frozen, frozenConn)
	go io.Copy(io.Discard, fastConn)
	var got, outOfOrder int
	drained := make(chan struct{})
	go func() { // frozen for 4 s, then reads everything as fast as it can
		defer close(drained)
		time.Sleep(4 * time.Second)
		br := bufio.NewReader(frozenConn)
		for {
			p, err := proto.Read(br, nil, nil)
			if err != nil {
				return
			}
			if binary.LittleEndian.Uint32(p.Data) != uint32(got) {
				outOfOrder++
			}
			got++
		}
	}()

	var sent int
	var longest time.Duration
	end := time.Now().Add(6 * time.Second)
	for time.Now().Before(end) {
		start := time.Now()
		if err := frozen.Send(seqFrame(2, uint32(sent), 16<<10)); err != nil {
			peak, longestWrite, _ := frozen.SendStats()
			t.Fatalf("the freezing peer was closed after %d frames: %v (debt peak %v, longest write %v, budget %v)",
				sent, err, peak.Round(time.Millisecond), longestWrite.Round(time.Millisecond), SendBlockBudget)
		}
		sent++
		if err := fast.Send(seqFrame(2, 0, 16<<10)); err != nil {
			t.Fatalf("the fast peer: %v", err)
		}
		longest = max(longest, time.Since(start))
		time.Sleep(100 * time.Millisecond)
	}
	// Everything queued reaches the peer before the session is let go.
	if !frozen.flush(5 * time.Second) {
		t.Errorf("the freezing peer's queue did not drain in 5 s after it began reading")
	}
	peak, longestWrite, _ := frozen.SendStats()
	queuePeak, _ := frozen.QueueStats()
	t.Logf("the freezing peer: debt peak %v, longest write %v, queue peak %d bytes, %d frames sent, longest send %v, budget %v, limit %d",
		peak.Round(time.Millisecond), longestWrite.Round(time.Millisecond), queuePeak, sent, longest, SendBlockBudget, SendQueueLimit)
	if peak < 2*time.Second {
		t.Errorf("the writer's debt peaked at %v: the freeze never backed it up, so the budget was not exercised", peak)
	}
	if longest > 50*time.Millisecond {
		t.Errorf("a send to the freezing peer took %v: it waited on the socket", longest.Round(time.Millisecond))
	}
	frozen.Close()
	<-drained
	if got != sent || outOfOrder > 0 {
		t.Errorf("the freezing peer read %d of %d frames, %d out of order", got, sent, outOfOrder)
	}
}
