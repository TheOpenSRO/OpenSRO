package gateway

import (
	"bufio"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
)

// Round 662's review (L1): the rolling byte and the checksum are drawn in
// the order the frames reach the wire. Eight goroutines Send 500 frames each
// to one session with real per-direction generators installed, and the
// client reads them back with generators seeded the same: a frame whose
// rolling byte or checksum was drawn in one order and queued in another
// fails proto.Read.
func TestRollingByteAndChecksumFollowWireOrder(t *testing.T) {
	r := newQueueRig(t, nil)
	conn, s := r.dial(t)
	s.SetSecurity(proto.NewRollingByte(0x11, 0x22, 0x33), proto.NewPacketChecksum(7), nil, nil)
	recvRoll, recvSum := proto.NewRollingByte(0x11, 0x22, 0x33), proto.NewPacketChecksum(7)
	const senders, per = 8, 500
	got := 0
	readErr := make(chan error, 1)
	go func() {
		br := bufio.NewReader(conn)
		conn.SetReadDeadline(time.Now().Add(10 * time.Second))
		for got < senders*per {
			if _, err := proto.Read(br, recvRoll, recvSum); err != nil {
				readErr <- err
				return
			}
			got++
		}
		readErr <- nil
	}()
	var wg sync.WaitGroup
	for i := 0; i < senders; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			for j := 0; j < per; j++ {
				if err := s.Send(seqFrame(uint16(100+i), uint32(j), 64+j%200)); err != nil {
					t.Errorf("sender %d frame %d: %v", i, j, err)
					return
				}
			}
		}(i)
	}
	wg.Wait()
	if err := <-readErr; err != nil {
		t.Fatalf("after %d of %d frames: %v", got, senders*per, err)
	}
}

// Round 662's review (L2): the queue limit bounds a queue that is growing,
// and is checked before the frames are queued -- so the queue never holds
// more than the limit while anything is waiting -- but a single batch into
// an empty queue is taken even when it is bigger than the limit on its own.
func TestTheQueueLimitBoundsAGrowingQueueNotOneBatch(t *testing.T) {
	const limit = 64 << 10
	setQueueLimit(t, limit)
	r := newQueueRig(t, nil)

	// One batch of three full pages (~96 KB) into an empty queue: taken and
	// delivered.
	conn, s := r.dial(t)
	pages := []*proto.Packet{seqFrame(2, 0, proto.MaxPayload), seqFrame(2, 1, proto.MaxPayload), seqFrame(2, 2, proto.MaxPayload)}
	if err := s.SendBatch(pages...); err != nil {
		t.Fatalf("a %d-byte batch into an empty queue (limit %d): %v", 3*(proto.MaxPayload+6), limit, err)
	}
	br := bufio.NewReader(conn)
	conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	for i := 0; i < 3; i++ {
		if _, err := proto.Read(br, nil, nil); err != nil {
			t.Fatalf("page %d of the batch: %v", i, err)
		}
	}
	if err := s.Send(&proto.Packet{Opcode: 3}); err != nil {
		t.Errorf("a Send after the big batch was written: %v", err)
	}

	// A client that never reads: 16 KB frames until the limit closes it; the
	// queue never held more than the limit.
	slowConn, slow := r.dial(t)
	smallBuffers(t, slow, slowConn)
	var err error
	sent := 0
	for ; sent < 10000 && err == nil; sent++ {
		err = slow.Send(seqFrame(2, uint32(sent), 16<<10))
	}
	if !errors.Is(err, ErrSendStalled) {
		t.Fatalf("the growing queue ended with %v after %d frames, want ErrSendStalled", err, sent)
	}
	if peak, _ := slow.QueueStats(); peak > limit {
		t.Errorf("the queue held %d bytes, past its %d-byte limit, before the session was closed", peak, limit)
	}
}
