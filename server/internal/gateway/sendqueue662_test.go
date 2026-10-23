package gateway

import (
	"bufio"
	"context"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"runtime"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
)

// Round 662: every session has its own outbound queue and writer goroutine.
// Send queues and returns; the writer drains the queue to the socket. These
// tests pin what that buys and what it must keep: a slow reader never holds
// its sender, and is closed by its queue limit or its writer's budget; a
// batch is never interleaved; the frames queued before a handler's error
// still reach the client; nothing is left behind by a session that ends.
// The round-662 API they need is in sendqueue662_setup_test.go, so that the
// file builds against a revision without the queue for the negative.

// queueRig is a gateway server whose handler hands each session over on its
// first packet (opcode 1), and runs extra for any other opcode.
type queueRig struct {
	addr     string
	sessions chan *Session
	gone     atomic.Int64
}

const opHelloQ uint16 = 1

func newQueueRig(t *testing.T, extra Handler) *queueRig {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	r := &queueRig{addr: ln.Addr().String(), sessions: make(chan *Session, 16)}
	ln.Close()
	srv := &Server{Addr: r.addr,
		Handle: func(ctx context.Context, s *Session, p *proto.Packet) error {
			if p.Opcode == opHelloQ {
				r.sessions <- s
				return nil
			}
			if extra != nil {
				return extra(ctx, s, p)
			}
			return nil
		},
		OnDisconnect: func(*Session) { r.gone.Add(1) }}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go srv.ListenAndServe(ctx)
	return r
}

// dial connects, says hello, and returns the client end and the server's
// session.
func (r *queueRig) dial(t *testing.T) (net.Conn, *Session) {
	t.Helper()
	var c net.Conn
	var err error
	for i := 0; i < 50; i++ {
		if c, err = net.DialTimeout("tcp", r.addr, 100*time.Millisecond); err == nil {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	if err := proto.Write(c, &proto.Packet{Opcode: opHelloQ}, nil, nil); err != nil {
		t.Fatal(err)
	}
	select {
	case s := <-r.sessions:
		return c, s
	case <-time.After(3 * time.Second):
		t.Fatal("the session never arrived")
	}
	return nil, nil
}

// smallBuffers cuts the server's send buffer for s to 16 KB, so a client
// that does not read backs the writer up after about a hundred KB (its own
// receive window), as over a real link, instead of after the loopback's
// megabytes. (The client's receive buffer is left alone: shrunk after the
// handshake it stalls the loopback into retransmits.)
func smallBuffers(t *testing.T, s *Session, client net.Conn) {
	t.Helper()
	if err := s.conn.(*net.TCPConn).SetWriteBuffer(16 << 10); err != nil {
		t.Fatal(err)
	}
}

// seqFrame is a size-byte frame whose payload starts with seq.
func seqFrame(op uint16, seq uint32, size int) *proto.Packet {
	data := make([]byte, size)
	binary.LittleEndian.PutUint32(data, seq)
	return &proto.Packet{Opcode: op, Data: data}
}

// trickle reads 16 KB every 10 ms (about 1.6 MB/s) until the connection
// ends.
func trickle(c net.Conn) {
	buf := make([]byte, 16<<10)
	for {
		if _, err := io.ReadFull(c, buf); err != nil {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// countFrames reads frames until the connection ends, counting them.
func countFrames(c net.Conn, n *atomic.Int64) {
	r := bufio.NewReader(c)
	for {
		if _, err := proto.Read(r, nil, nil); err != nil {
			return
		}
		n.Add(1)
	}
}

// waitFor polls cond every 5 ms until it holds or d passes.
func waitFor(d time.Duration, cond func() bool) bool {
	end := time.Now().Add(d)
	for time.Now().Before(end) {
		if cond() {
			return true
		}
		time.Sleep(5 * time.Millisecond)
	}
	return cond()
}

// A slow, steady reader no longer holds whoever sends to it: 100 frames of
// 16 KB to a client reading 1.6 MB/s through a 16 KB send buffer return in
// milliseconds (the queue limit is 2 MB here). A fan-out that then writes to
// it and to a fast client, a pass every millisecond (16 MB/s to each) -- the
// AI tick's shape -- never waits on it; the slow client is closed once its
// queue passes the limit, and the fast one receives every frame. Before
// round 662 the 100 frames alone took about a second, and the fan-out waited
// on every write.
func TestASlowReaderNeverHoldsTheSender(t *testing.T) {
	setQueueLimit(t, 2<<20)
	r := newQueueRig(t, nil)
	slowConn, slow := r.dial(t)
	fastConn, fast := r.dial(t)
	smallBuffers(t, slow, slowConn)
	go trickle(slowConn)
	var fastGot atomic.Int64
	go countFrames(fastConn, &fastGot)

	start := time.Now()
	for i := 0; i < 100; i++ {
		if err := slow.Send(seqFrame(2, uint32(i), 16<<10)); err != nil {
			t.Fatalf("frame %d to the slow reader: %v", i, err)
		}
	}
	if took := time.Since(start); took > 100*time.Millisecond {
		t.Errorf("100 frames to the slow reader took %v: its sender waited on its socket", took.Round(time.Millisecond))
	} else {
		t.Logf("100 frames to the slow reader took %v", took)
	}

	var longest time.Duration
	var slowErr error
	sentFast := int64(0)
	end := time.Now().Add(5 * time.Second)
	for time.Now().Before(end) && slowErr == nil {
		pass := time.Now()
		slowErr = slow.Send(seqFrame(2, 0, 16<<10))
		if err := fast.Send(seqFrame(2, 0, 16<<10)); err != nil {
			t.Fatalf("the fast client's send failed: %v", err)
		}
		sentFast++
		longest = max(longest, time.Since(pass))
		time.Sleep(time.Millisecond)
	}
	if slowErr == nil {
		t.Fatalf("the slow reader was never closed: the fan-out wrote to it for 5 s")
	}
	if !errors.Is(slowErr, ErrSendStalled) {
		t.Errorf("the slow reader's send ended with %v, want ErrSendStalled", slowErr)
	}
	// The fan-out goes on to the fast client alone.
	for i := 0; i < 200; i++ {
		pass := time.Now()
		if err := fast.Send(seqFrame(2, 0, 16<<10)); err != nil {
			t.Fatalf("the fast client's send failed after the slow one was closed: %v", err)
		}
		sentFast++
		longest = max(longest, time.Since(pass))
		time.Sleep(time.Millisecond)
	}
	if longest > 50*time.Millisecond {
		t.Errorf("a fan-out pass took %v: it waited on a socket", longest.Round(time.Millisecond))
	}
	if !waitFor(3*time.Second, func() bool { return fastGot.Load() == sentFast }) {
		t.Errorf("the fast client received %d of %d frames", fastGot.Load(), sentFast)
	}
	t.Logf("longest fan-out pass %v; the slow reader: %v", longest, slowErr)
}

// A reader slower than it is written to, with the queue limit out of reach,
// is closed by its writer's blocking budget (round 656's rule, now the
// writer's alone): the fan-out writes 16 KB to it and to a fast client every
// 5 ms (3.2 MB/s against its 1.6 MB/s), its writer blocks, and at the budget
// (300 ms here) it is closed. No pass of the fan-out waits on it meanwhile.
// Before round 662 the fan-out waited out that budget itself, a write at a
// time.
func TestASlowReaderIsClosedByItsWritersBudget(t *testing.T) {
	setQueueLimit(t, 64<<20)
	oldTimeout, oldBudget, oldWindow := SendTimeout, SendBlockBudget, SendBlockWindow
	SendTimeout, SendBlockBudget, SendBlockWindow = time.Second, 300*time.Millisecond, 3*time.Second
	t.Cleanup(func() { SendTimeout, SendBlockBudget, SendBlockWindow = oldTimeout, oldBudget, oldWindow })
	r := newQueueRig(t, nil)
	slowConn, slow := r.dial(t)
	fastConn, fast := r.dial(t)
	smallBuffers(t, slow, slowConn)
	go trickle(slowConn)
	var fastGot atomic.Int64
	go countFrames(fastConn, &fastGot)

	var longest time.Duration
	var slowErr error
	sentFast := int64(0)
	start := time.Now()
	end := start.Add(5 * time.Second)
	for time.Now().Before(end) && slowErr == nil {
		pass := time.Now()
		slowErr = slow.Send(seqFrame(2, 0, 16<<10))
		if err := fast.Send(seqFrame(2, 0, 16<<10)); err != nil {
			t.Fatalf("the fast client's send failed: %v", err)
		}
		sentFast++
		longest = max(longest, time.Since(pass))
		time.Sleep(5 * time.Millisecond)
	}
	if slowErr == nil {
		t.Fatalf("the slow reader was never closed in 5 s (budget %v)", SendBlockBudget)
	}
	if !errors.Is(slowErr, ErrSendStalled) {
		t.Errorf("the slow reader's send ended with %v, want ErrSendStalled", slowErr)
	}
	peak, _, _ := slow.SendStats()
	if peak < SendBlockBudget {
		t.Errorf("the slow reader was closed at a writer debt of %v, before its budget %v", peak, SendBlockBudget)
	}
	if longest > 50*time.Millisecond {
		t.Errorf("a fan-out pass took %v: it waited on the slow reader", longest.Round(time.Millisecond))
	}
	if !waitFor(3*time.Second, func() bool { return fastGot.Load() == sentFast }) {
		t.Errorf("the fast client received %d of %d frames", fastGot.Load(), sentFast)
	}
	t.Logf("closed after %v at writer debt %v; longest fan-out pass %v", time.Since(start).Round(time.Millisecond), peak, longest)
}

// A batch reaches the wire whole: 20 batches of 20 frames from one goroutine
// and 400 single frames from another, to the same session, and no single
// frame lands inside a batch (the paged monster list and its motion list, a
// monster's enter and its leg). The client reads a frame every 100 us
// through a 16 KB send buffer, so the socket is full and every write waits
// on it -- the case in which, before round 662, a waiting single frame got
// the send lock between two frames of a "batch", which were separate writes.
// Everything is also in order within each goroutine's own sends.
func TestSendBatchIsNeverInterleaved(t *testing.T) {
	setQueueLimit(t, 8<<20)
	r := newQueueRig(t, nil)
	conn, s := r.dial(t)
	smallBuffers(t, s, conn)
	const batches, per, singles, size = 20, 20, 400, 4 << 10
	type got struct {
		op  uint16
		seq uint32
	}
	frames := make(chan got, batches*per+singles)
	go func() {
		br := bufio.NewReader(conn)
		for {
			p, err := proto.Read(br, nil, nil)
			if err != nil {
				close(frames)
				return
			}
			frames <- got{p.Opcode, binary.LittleEndian.Uint32(p.Data)}
			time.Sleep(100 * time.Microsecond)
		}
	}()
	var wg sync.WaitGroup
	start := make(chan struct{})
	wg.Add(2)
	go func() {
		defer wg.Done()
		<-start
		for b := 0; b < batches; b++ {
			ps := make([]*proto.Packet, per)
			for i := range ps {
				ps[i] = seqFrame(10, uint32(b*per+i), size)
			}
			if err := sendBatch(s, ps...); err != nil {
				t.Errorf("batch %d: %v", b, err)
				return
			}
			runtime.Gosched()
		}
	}()
	go func() {
		defer wg.Done()
		<-start
		for i := 0; i < singles; i++ {
			if err := s.Send(seqFrame(20, uint32(i), size)); err != nil {
				t.Errorf("single %d: %v", i, err)
				return
			}
			runtime.Gosched()
		}
	}()
	close(start)
	wg.Wait()

	var next uint32 // the batch frame expected next
	var nextSingle uint32
	interleaved := 0
	for n := 0; n < batches*per+singles; n++ {
		var f got
		select {
		case f = <-frames:
		case <-time.After(5 * time.Second):
			t.Fatalf("only %d of %d frames arrived", n, batches*per+singles)
		}
		switch f.op {
		case 10:
			if f.seq != next {
				t.Fatalf("batch frame %d arrived when %d was due: out of order", f.seq, next)
			}
			next++
		case 20:
			if f.seq != nextSingle {
				t.Fatalf("single frame %d arrived when %d was due: out of order", f.seq, nextSingle)
			}
			nextSingle++
			if next%per != 0 {
				interleaved++
				if interleaved <= 3 {
					t.Errorf("single frame %d landed inside a batch, after its frame %d of %d", f.seq, next%per, per)
				}
			}
		}
	}
	if interleaved > 0 {
		t.Errorf("%d single frames landed inside a batch", interleaved)
	}
}

// A handler that sends and then returns an error closes its session (the
// gateway's rule), and what it sent first still reaches the client, in order,
// before the connection ends: the session drains its queue before closing
// (closeAfterDrain). OpenSRO has no kick and no logout reply; this is its
// one send-then-close. 40 frames of 16 KB (640 KB, under the 2 MB queue
// limit) go through a 16 KB send buffer, so most of them are still queued
// when the handler returns.
func TestTheFramesBeforeAHandlersErrorAreDelivered(t *testing.T) {
	const opBye = 5
	r := newQueueRig(t, func(_ context.Context, s *Session, p *proto.Packet) error {
		if p.Opcode != opBye {
			return nil
		}
		for i := 0; i < 40; i++ {
			if err := s.Send(seqFrame(2, uint32(i), 16<<10)); err != nil {
				return err
			}
		}
		if err := s.Send(seqFrame(6, 40, 8)); err != nil {
			return err
		}
		return errTest("goodbye")
	})
	conn, s := r.dial(t)
	smallBuffers(t, s, conn)
	if err := proto.Write(conn, &proto.Packet{Opcode: opBye}, nil, nil); err != nil {
		t.Fatal(err)
	}
	br := bufio.NewReader(conn)
	conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	for i := 0; i <= 40; i++ {
		p, err := proto.Read(br, nil, nil)
		if err != nil {
			t.Fatalf("frame %d of 41: %v -- the session was closed before its queue was written", i, err)
		}
		if seq := binary.LittleEndian.Uint32(p.Data); seq != uint32(i) {
			t.Fatalf("frame %d carried %d", i, seq)
		}
		if want := uint16(2); i == 40 {
			want = 6
			if p.Opcode != want {
				t.Fatalf("the last frame is %#x, want %#x", p.Opcode, want)
			}
		}
	}
	if _, err := proto.Read(br, nil, nil); !errors.Is(err, io.EOF) {
		t.Errorf("after the last frame: %v, want the connection closed (EOF)", err)
	}
}

// A thousand sessions connect and disconnect, one in ten leaving with 256 KB
// queued that its client never reads, and nothing is left behind: every
// session's writer returns and its queue is freed, and the process has no
// more goroutines than before.
func TestNoGoroutineLeakAcrossConnectDisconnect(t *testing.T) {
	const opEcho, opFlood = 3, 4
	var mu sync.Mutex
	var all []*Session
	r := newQueueRig(t, func(_ context.Context, s *Session, p *proto.Packet) error {
		switch p.Opcode {
		case opEcho:
			mu.Lock()
			all = append(all, s)
			mu.Unlock()
			return s.Send(&proto.Packet{Opcode: opEcho + 1})
		case opFlood:
			for i := 0; i < 16; i++ {
				if err := s.Send(seqFrame(2, uint32(i), 16<<10)); err != nil {
					return err
				}
			}
		}
		return nil
	})
	// The rig's own goroutines (the accept loop, its ctx watcher) are up.
	time.Sleep(50 * time.Millisecond)
	runtime.GC()
	before := runtime.NumGoroutine()

	const cycles = 1000
	for i := 0; i < cycles; i++ {
		c, err := net.DialTimeout("tcp", r.addr, time.Second)
		if err != nil {
			t.Fatal(err)
		}
		if err := proto.Write(c, &proto.Packet{Opcode: opHelloQ}, nil, nil); err != nil {
			t.Fatal(err)
		}
		<-r.sessions
		if err := proto.Write(c, &proto.Packet{Opcode: opEcho}, nil, nil); err != nil {
			t.Fatal(err)
		}
		c.SetReadDeadline(time.Now().Add(3 * time.Second))
		if _, err := proto.Read(bufio.NewReader(c), nil, nil); err != nil {
			t.Fatalf("cycle %d: the echo: %v", i, err)
		}
		if i%10 == 0 {
			if err := proto.Write(c, &proto.Packet{Opcode: opFlood}, nil, nil); err != nil {
				t.Fatal(err)
			}
			time.Sleep(time.Millisecond)
		}
		c.Close()
	}
	if !waitFor(10*time.Second, func() bool { return r.gone.Load() == cycles }) {
		t.Fatalf("%d of %d sessions ended", r.gone.Load(), cycles)
	}
	var after int
	if !waitFor(5*time.Second, func() bool { after = runtime.NumGoroutine(); return after <= before }) {
		buf := make([]byte, 1<<16)
		n := runtime.Stack(buf, true)
		t.Fatalf("%d goroutines before the %d cycles, %d after:\n%s", before, cycles, after, buf[:n])
	}
	mu.Lock()
	defer mu.Unlock()
	notFreed := 0
	for _, s := range all {
		if !waitFor(time.Second, func() bool { return queueFreed(s) }) {
			notFreed++
		}
	}
	if notFreed > 0 || len(all) != cycles {
		t.Errorf("%d of %d sessions kept their writer or their queue", notFreed, len(all))
	}
	t.Logf("%d goroutines before %d cycles, %d after", before, cycles, after)
}
