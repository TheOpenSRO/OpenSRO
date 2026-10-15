// Package gateway is the first hop a client TCP connection hits: it accepts
// connections, frames incoming bytes into packets via internal/proto, and
// hands each decoded packet to a Handler. It has no opcode-specific game
// logic — that belongs in whatever's built on top of Handler.
package gateway

import (
	"bufio"
	"bytes"
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"runtime/debug"
	"sync"
	"sync/atomic"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/proto"
)

// Handler processes one decoded packet from a session. Returning an error
// closes that session's connection.
type Handler func(ctx context.Context, sess *Session, p *proto.Packet) error

// Chain combines multiple Handlers into one, calling each in order for
// every packet. Each Handler is expected to check the opcode(s) it cares
// about and no-op (return nil) otherwise — Chain itself does no opcode
// routing. Stops and returns early on the first error.
func Chain(handlers ...Handler) Handler {
	return func(ctx context.Context, sess *Session, p *proto.Packet) error {
		for _, h := range handlers {
			if err := h(ctx, sess, p); err != nil {
				return err
			}
		}
		return nil
	}
}

// Codec frames one session's packets on a wire other than OpenSRO's own
// (round 788: the retail listeners, retailgw.ServerCodec). A Server with no
// Codec uses OpenSRO's framing (proto.Read / proto.Write) exactly as before;
// handlers see the same *Session and proto.Packet either way, so the lobby,
// the login service and the disconnect bookkeeping run unchanged on both.
type Codec interface {
	// Start runs once on the session's goroutine before its first read: the
	// server's half of a handshake the server opens (it may Send).
	Start(sess *Session) error
	// ReadPacket reads the next packet for the handlers, consuming the
	// frames that belong to the codec itself (the handshake).
	ReadPacket(r *bufio.Reader) (*proto.Packet, error)
	// AppendFrame appends p's wire bytes to out. It is called under the
	// session's queue lock, in Send order, from any goroutine that Sends.
	AppendFrame(out []byte, p *proto.Packet) ([]byte, error)
}

// Session is one accepted, live client connection. It also carries a small
// generic key/value bag so higher-level handlers (login, character
// selection, ...) can remember state across packets on the same connection
// — e.g. "which account authenticated on this connection" — without gateway
// itself knowing anything about accounts or characters.
type Session struct {
	id   uint64
	conn net.Conn
	// codec is the wire's framing when it is not OpenSRO's own (nil).
	codec Codec

	mu     sync.RWMutex
	values map[string]any

	secMu    sync.Mutex
	sendRoll *proto.RollingByte
	sendSum  *proto.PacketChecksum
	recvRoll *proto.RollingByte
	recvSum  *proto.PacketChecksum

	// The outbound queue (round 662). Send encodes its frame into out and
	// returns; the session's own writer goroutine (writeLoop) drains out to the
	// socket. So no goroutine that sends -- the monster AI's tick, the respawn
	// scheduler, another player's blow, a zone broadcast -- ever waits on this
	// client's socket. outMu guards everything below it but blocked and
	// blockedAt; outCond wakes the writer on a new frame or a close, and wakes
	// flush on the writer's progress.
	outMu   sync.Mutex
	outCond *sync.Cond
	// out is the encoded frames waiting for the writer, in Send order;
	// inFlight is how many bytes the writer has taken and not yet finished
	// writing. Their sum is what SendQueueLimit bounds.
	out      []byte
	inFlight int
	// queued and written count every byte that ever entered the queue and
	// every byte the writer put on the socket: flush waits for written to
	// reach queued.
	queued, written int64
	// closing refuses new Sends: set by Close, by closeAfterDrain and by a
	// stall. writerDone is closed when the writer goroutine has returned.
	closing    bool
	writerDone chan struct{}
	// stalled is set when the session was given up for its sends (round 656's
	// deadline and budget, round 662's queue limit): every later Send returns
	// ErrSendStalled at once.
	stalled atomic.Bool
	// blocked is the writer's blocking debt (SendBlockBudget): the time its
	// writes have spent on the socket, less SendBlockBudget per
	// SendBlockWindow since, as of blockedAt. Only the writer touches them.
	blocked   time.Duration
	blockedAt time.Time
	// The send bounds this session runs with: SendTimeout, SendBlockBudget,
	// SendBlockWindow and SendQueueLimit as they were when it connected
	// (startWriter), so a test that changes them races no live writer.
	// debt is blocked as of the writer's last write, for the stall line.
	// Guarded by outMu.
	debt                    time.Duration
	timeout, budget, window time.Duration
	queueLimit              int
	// The send accounting's own record, for the disconnect line and the peak
	// lines (round 656's third review; round 662 adds the queue): the highest
	// debt reached, the longest single write, the bytes written, the most
	// bytes ever waiting in the queue, and the most bytes Sent in any
	// SendBurstWindow, with the last of each a peak line reported. Guarded by
	// outMu.
	peakDebt, longestWrite   time.Duration
	sentBytes                int64
	peakQueued, loggedQueued int
	burst                    burstMeter
	loggedBurst              int
	logger                   *slog.Logger
}

// SendTimeout is the longest one write of the session's writer may block on a
// client that is not reading before the session is given up (round 656). OURS,
// an engineering bound, not a retail number: a write only blocks once the
// kernel's socket buffers -- several hundred KB to a few MB each way -- are
// full. 10 s, not the 2 s round 656 shipped with (its review): a client whose
// main thread is busy -- a region load, a long frame -- stops reading for a
// while. A variable so a test can shorten it; 0 turns the deadline off.
//
// Since round 662 the write happens on the session's own writer goroutine
// (writeLoop), not on the goroutine that called Send, so the deadline bounds
// how long that writer waits, and nobody else waits at all.
var SendTimeout = 10 * time.Second

// SendBlockBudget and SendBlockWindow bound how long one session's writer may
// spend blocked on its socket in total (round 656's second review). Every
// write's time on the socket is added to the session's debt, and the debt
// drains at SendBlockBudget per SendBlockWindow of wall time (a leaky bucket):
// a session whose debt reaches the budget is closed, as a timed-out write
// closes it, and each write's deadline is capped at what is left of the
// budget. Variables so a test can shorten them; a budget of 0 turns the bound
// off.
//
// 10 s, draining 10 s per 60 s (round 656's third review). OURS, chosen
// against what a HEALTHY client does: the client reads its socket on the
// game's main thread (net_client.gd _process), so it reads nothing while a
// load freezes that thread, and a write blocks once the kernel's buffers fill
// meanwhile. The perf gate measures a 3.3 s freeze at the Jangan world entry;
// a peer frozen for 4 s (TestAPeerThatFreezesThenReadsIsNotClosed) runs its
// debt to about 4 s. 10 s is 3x the measured freeze and 2.5x that test.
//
// Round 662: before the queue this debt was time OTHER goroutines spent
// waiting -- the AI tick, the respawn scheduler, other players' blows -- so a
// peer that read slower than it was written to held them all up to ~10 s.
// Now only this session's own writer waits, and the budget only decides when
// a client that keeps not reading is given up.
var (
	SendBlockBudget = 10 * time.Second
	SendBlockWindow = 60 * time.Second
)

// SendQueueLimit is the most bytes one session may have waiting in its
// outbound queue (round 662): a Send that would take a non-empty queue past
// this closes the session, as a spent SendBlockBudget does. A Send into an
// empty queue is always taken, whatever its size (round 662's review). It bounds the memory a client
// that reads too slowly can hold, and closes such a client long before its
// writer's debt would, when the server writes to it faster than it reads.
// A variable so a test can shorten it; 0 turns the bound off.
//
// 2 MB. OURS, chosen from a measurement (docs/WORLD_ISSUES.md round 662):
// one real client on the render box through world entry at the Jangan spawn
// in a crowd of about 50 monsters a region (1,286 in its window: the paged
// list and its motion pages), /goto donwhang and back, and three GM-spawned
// uniques, all six monster switches on, 3.5 min a run. The most bytes Sent to
// it in any SendBurstWindow (4 s) was 265,072 -- the return to Jangan, where
// the view move sends ~1,250 monsters' enters and the list follows -- and the
// most ever waiting in its queue 107,478 (the entry's list, queued as one
// batch). The limit is about 8x that burst -- what a client frozen 4 s with
// the kernel holding nothing would have queued -- and 20x the queue's peak.
var SendQueueLimit = 2 << 20

// SendBurstWindow is the window the "burst" figure in the session's
// disconnect line is measured over: the most bytes Sent to the session within
// any such span (OURS, a measurement window only: the 4 s of
// TestAPeerThatFreezesThenReadsIsNotClosed, above the measured 3.3 s entry
// freeze). The figure is what SendQueueLimit is chosen against.
const SendBurstWindow = 4 * time.Second

// SendDrainTimeout is how long a session that is ending (its read loop is
// done: the client hung up, a handler returned an error, the server is
// stopping) keeps writing what is still queued before its connection is
// closed (closeAfterDrain), so a frame sent just before the end -- an error
// reply ahead of a handler's error -- still reaches the client, as it did
// when Send wrote synchronously. OURS: long enough for a reading client to
// take a full queue over a slow link, short enough that a gone client's
// goroutine does not linger; only the ending session's own goroutine waits.
var SendDrainTimeout = 2 * time.Second

// ErrSendStalled is what Send returns on a session that was closed for its
// sends: a write ran past SendTimeout, its writer spent SendBlockBudget, or
// its queue passed SendQueueLimit.
var ErrSendStalled = errors.New("gateway: session stalled: its sends ran past their deadline, budget or queue limit and the connection was closed")

// ErrSessionClosed is what Send returns on a session that is closed or
// closing for any other reason.
var ErrSessionClosed = errors.New("gateway: session closed")

// ErrEndSession is a handler's way to end a session that has finished its
// business -- what it queued is written out, then the connection closes --
// without the WARN a failing handler gets (round 678: the front-end theme's
// one-question connection).
var ErrEndSession = errors.New("gateway: session ended by its handler")

// SetSecurity installs this session's real per-direction RollingByte/
// PacketChecksum generators (see proto.Read/Write) once a handshake derives
// them. Before this is called, Send and the read loop pass nil for both,
// which skips those fields' validation/generation entirely -- the correct
// behavior pre-handshake, not a workaround.
func (s *Session) SetSecurity(sendRoll *proto.RollingByte, sendSum *proto.PacketChecksum, recvRoll *proto.RollingByte, recvSum *proto.PacketChecksum) {
	s.secMu.Lock()
	defer s.secMu.Unlock()
	s.sendRoll, s.sendSum = sendRoll, sendSum
	s.recvRoll, s.recvSum = recvRoll, recvSum
}

func (s *Session) security() (sendRoll *proto.RollingByte, sendSum *proto.PacketChecksum, recvRoll *proto.RollingByte, recvSum *proto.PacketChecksum) {
	s.secMu.Lock()
	defer s.secMu.Unlock()
	return s.sendRoll, s.sendSum, s.recvRoll, s.recvSum
}

// ID uniquely identifies this session for the life of the process (not
// stable across restarts). Useful as a map key for higher-level state (e.g.
// world.Hub tracking who's in which zone) without comparing *Session
// pointers directly.
func (s *Session) ID() uint64 {
	return s.id
}

// RemoteAddr returns the client's address, mainly for logging.
func (s *Session) RemoteAddr() net.Addr {
	return s.conn.RemoteAddr()
}

// NewTestSession returns a *Session with the given ID and no real
// connection, for other packages' tests that need something to key state
// by (e.g. world.Hub, keyed on session ID) without spinning up a real TCP
// connection. Calling Send or RemoteAddr on the result will panic (nil
// conn) — it's only useful for its ID() and the Set/Get value bag.
func NewTestSession(id uint64) *Session {
	return &Session{id: id}
}

// Set stores a value under key for the lifetime of this connection.
func (s *Session) Set(key string, value any) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.values == nil {
		s.values = make(map[string]any)
	}
	s.values[key] = value
}

// Get retrieves a value previously stored with Set.
func (s *Session) Get(key string) (any, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	v, ok := s.values[key]
	return v, ok
}

// Send queues a packet for this session's client and returns without
// touching the socket (round 662): the session's writer goroutine writes the
// queue out in the order Send was called. The frame is encoded -- its
// rolling byte and checksum drawn -- here, in that same order, and its bytes
// are copied, so the caller may reuse p at once.
//
// Send returns an error at once for a payload too large for one frame (as
// proto.Write does), ErrSendStalled for a session closed for its sends -- or
// closed by this Send, when it would take the queue past SendQueueLimit --
// and ErrSessionClosed for one closed otherwise. A nil error means the frame
// is queued, not that it is on the wire; a session closed later never
// delivers it.
func (s *Session) Send(p *proto.Packet) error {
	return s.SendBatch(p)
}

// SendBatch queues several frames as one: no frame Sent from another
// goroutine can come between them on the wire (round 662; the paged monster
// list and its motion list, a monster's enter and its leg). It is all or
// nothing: a payload too large for one frame refuses the whole batch before
// anything is queued.
func (s *Session) SendBatch(ps ...*proto.Packet) error {
	return s.enqueue(ps, nil)
}

// Frame is one packet encoded once for many sessions (round 737,
// crowd_scale.md C2, OURS): a broadcast's payload and header are built once
// per event, not once per recipient. A session with no per-session security
// (SetSecurity never called -- every production session today) queues the
// encoded bytes as they are; one with security draws its own rolling byte and
// checksum for the frame, as Send does.
type Frame struct {
	p    proto.Packet
	wire []byte
}

// NewFrame encodes p once. It refuses a payload too large for one frame, as
// Send does. The payload is copied.
func NewFrame(p *proto.Packet) (*Frame, error) {
	if len(p.Data) > proto.MaxPayload {
		return nil, fmt.Errorf("proto: payload of %d bytes too large for a single frame", len(p.Data))
	}
	f := &Frame{p: proto.Packet{Opcode: p.Opcode, Data: append([]byte(nil), p.Data...)}}
	var b bytes.Buffer
	b.Grow(6 + len(p.Data))
	_ = proto.Write(&b, &f.p, nil, nil)
	f.wire = b.Bytes()
	return f, nil
}

// MustFrame is NewFrame for a payload the caller knows fits (a fixed-size
// message); it panics otherwise.
func MustFrame(p *proto.Packet) *Frame {
	f, err := NewFrame(p)
	if err != nil {
		panic(err)
	}
	return f
}

// Opcode is the frame's opcode.
func (f *Frame) Opcode() uint16 { return f.p.Opcode }

// Payload is the frame's payload; the caller must not change it.
func (f *Frame) Payload() []byte { return f.p.Data }

// SendFrames queues pre-encoded frames as one batch, as SendBatch does.
func (s *Session) SendFrames(fs ...*Frame) error {
	return s.enqueue(nil, fs)
}

// enqueue is SendBatch and SendFrames: ps then fs, as one batch.
func (s *Session) enqueue(ps []*proto.Packet, fs []*Frame) error {
	for _, p := range ps {
		if len(p.Data) > proto.MaxPayload {
			return fmt.Errorf("proto: payload of %d bytes too large for a single frame", len(p.Data))
		}
	}
	if s.stalled.Load() {
		return ErrSendStalled
	}
	if s.conn == nil {
		// NewTestSession: Send panicked on the nil conn before the queue, and
		// a test relies on that to drive a panic through a push
		// (TestPanickingPushLeavesTheWireLockFree); it still does.
		panic("gateway: Send on a session with no connection (NewTestSession)")
	}
	sendRoll, sendSum, _, _ := s.security()
	s.outMu.Lock()
	if s.stalled.Load() {
		s.outMu.Unlock()
		return ErrSendStalled
	}
	if s.closing || s.outCond == nil {
		s.outMu.Unlock()
		return ErrSessionClosed
	}
	// The limit is checked before anything is encoded (round 662's review),
	// so a refused batch draws no rolling byte. It bounds a queue that is
	// growing: a batch that would take a non-empty queue past the limit
	// closes the session. A batch into an empty queue is always taken, even
	// one bigger than the limit on its own (a paged list), since nothing is
	// piling up behind it; the next Send while it is still waiting is then
	// over the limit.
	size := 0
	for _, p := range ps {
		size += 6 + len(p.Data)
	}
	for _, f := range fs {
		size += len(f.wire)
	}
	if pending := len(s.out) + s.inFlight; s.queueLimit > 0 && pending > 0 && pending+size > s.queueLimit {
		s.stallLocked("queue")
		s.outMu.Unlock()
		return ErrSendStalled
	}
	before := len(s.out)
	if s.codec != nil {
		// A codec's frames are built aside first, so a payload the codec
		// refuses leaves the queue as it was (all or nothing).
		var buf []byte
		var err error
		for _, p := range ps {
			if buf, err = s.codec.AppendFrame(buf, p); err != nil {
				s.outMu.Unlock()
				return err
			}
		}
		for _, f := range fs {
			if buf, err = s.codec.AppendFrame(buf, &f.p); err != nil {
				s.outMu.Unlock()
				return err
			}
		}
		s.out = append(s.out, buf...)
		ps, fs = nil, nil
	}
	w := queueWriter{s}
	for _, p := range ps {
		// Writing into the queue's own buffer cannot fail; the size was
		// checked above.
		_ = proto.Write(w, p, sendRoll, sendSum)
	}
	for _, f := range fs {
		if sendRoll == nil && sendSum == nil {
			s.out = append(s.out, f.wire...)
		} else {
			_ = proto.Write(w, &f.p, sendRoll, sendSum)
		}
	}
	added := len(s.out) - before
	s.queued += int64(added)
	waiting := len(s.out) + s.inFlight
	if waiting > s.peakQueued {
		s.peakQueued = waiting
		if waiting >= SendQueueLogFloor && s.logger != nil && waiting >= 2*s.loggedQueued {
			s.loggedQueued = waiting
			s.logger.Info("send queue peak", "addr", s.conn.RemoteAddr(), "queued", waiting, "limit", s.queueLimit)
		}
	}
	if b := s.burst.add(time.Now(), added); b > 0 && s.logger != nil && b >= SendBurstLogFloor && b >= 2*s.loggedBurst {
		s.loggedBurst = b
		s.logger.Info("send burst peak", "addr", s.conn.RemoteAddr(), "bytes", b, "window", SendBurstWindow)
	}
	s.outCond.Signal()
	s.outMu.Unlock()
	return nil
}

// queueWriter appends to the session's queue; outMu is held by its user.
type queueWriter struct{ s *Session }

func (w queueWriter) Write(b []byte) (int, error) {
	w.s.out = append(w.s.out, b...)
	return len(b), nil
}

// startWriter makes the session's queue and starts its writer goroutine.
func (s *Session) startWriter() {
	s.timeout, s.budget, s.window, s.queueLimit = SendTimeout, SendBlockBudget, SendBlockWindow, SendQueueLimit
	s.outCond = sync.NewCond(&s.outMu)
	s.writerDone = make(chan struct{})
	go s.writeLoop()
}

// writerKeepCap is the largest buffer the writer keeps for reuse once it is
// written out: a bigger one (a burst's) is let go, so a session holds no
// more memory than it is using. OURS.
const writerKeepCap = 64 << 10

// writeLoop is the session's writer: it takes everything queued, writes it
// out in one write (writeDrain, round 737), and repeats, until the session closes
// and the queue is empty or the connection fails. The deadline for what it
// took is SendTimeout capped by what is left of the blocking budget (round
// 656), one deadline for all those frames; a write that times out, or one
// that spends the budget, closes the session.
func (s *Session) writeLoop() {
	defer close(s.writerDone)
	var spare []byte
	for {
		s.outMu.Lock()
		for len(s.out) == 0 && !s.closing {
			s.outCond.Wait()
		}
		if len(s.out) == 0 || s.stalled.Load() {
			// Closing with nothing left to write, or given up: the queue is
			// dropped with the session.
			s.dropLocked()
			s.outMu.Unlock()
			if s.stalled.Load() {
				_ = s.conn.Close()
			}
			return
		}
		buf := s.out
		s.out = spare[:0]
		s.inFlight = len(buf)
		s.outMu.Unlock()

		start := time.Now()
		limit := s.timeout
		spent := false
		if s.budget > 0 {
			if !s.blockedAt.IsZero() && s.window > 0 {
				drain := time.Duration(float64(start.Sub(s.blockedAt)) * float64(s.budget) / float64(s.window))
				s.blocked = max(0, s.blocked-drain)
			}
			s.blockedAt = start
			left := s.budget - s.blocked
			if left <= 0 {
				spent = true
			} else if limit <= 0 || left < limit {
				limit = left
			}
		}
		var n int
		var err error
		if !spent {
			if limit > 0 {
				_ = s.conn.SetWriteDeadline(start.Add(limit))
			}
			// A stall from Send (the queue limit) stores the flag, then sets a
			// past deadline: checked after this write's own deadline is set,
			// either the flag is seen here or that past deadline lands after
			// ours and breaks the write off at once.
			if s.stalled.Load() {
				err = ErrSendStalled
			} else {
				n, err = s.writeDrain(buf)
			}
		}
		took := time.Since(start)
		if s.budget > 0 {
			s.blocked += took
		}

		s.outMu.Lock()
		s.inFlight = 0
		s.debt = s.blocked
		s.written += int64(n)
		s.sentBytes += int64(n)
		if took > s.longestWrite {
			s.longestWrite = took
		}
		if s.blocked > s.peakDebt {
			s.peakDebt = s.blocked
			// A new peak of the debt past SendDebtLogFloor is logged, so a
			// live run can read how near a session came to its budget.
			if s.peakDebt >= SendDebtLogFloor && s.logger != nil {
				s.logger.Info("send debt peak", "addr", s.conn.RemoteAddr(), "debt", s.peakDebt,
					"write", took, "bytes", n, "budget", s.budget)
			}
		}
		if cap(buf) <= writerKeepCap {
			spare = buf[:0]
		} else {
			spare = nil
		}
		var ne net.Error
		switch {
		case s.stalled.Load():
			// Given up while this write was in flight (the queue limit).
		case spent || (s.budget > 0 && s.blocked >= s.budget):
			s.stallLocked("budget")
		case err != nil && errors.As(err, &ne) && ne.Timeout():
			s.stallLocked("timeout")
		}
		done := err != nil || s.stalled.Load()
		if done {
			// The connection is gone, or given up: nothing more is written.
			s.closing = true
			s.dropLocked()
		}
		s.outCond.Broadcast()
		s.outMu.Unlock()
		if done {
			_ = s.conn.Close()
			return
		}
	}
}

// writeSlice is the most one write of a drain carries (round 737's review,
// F4; OURS): a drain is written in slices of at most this, and each slice
// leaves the queue's in-flight count as soon as it is on the socket, so the
// queue limit measures what is still unwritten rather than a whole drain
// until its last byte lands. 64 KB is the loopback segment size the round-662
// notes measured; a frame is at most 32 KB.
const writeSlice = 64 << 10

// writeDrain writes buf, whole encoded frames taken off the queue, in slices
// of at most writeSlice, taking each slice off s.inFlight as it is written.
// It returns the bytes written.
func (s *Session) writeDrain(buf []byte) (int, error) {
	written := 0
	for len(buf) > 0 {
		k := min(len(buf), writeSlice)
		n, err := writeFrames(s.conn, buf[:k])
		written += n
		s.outMu.Lock()
		s.inFlight -= n
		s.outMu.Unlock()
		if err != nil {
			return written, err
		}
		buf = buf[k:]
	}
	return written, nil
}

// writeFrames writes buf, encoded frames, in ONE write: the writer's drain
// (round 737, crowd_scale.md C2, OURS), whatever was queued while its last
// write was on the socket -- so frames that pile up during a write go out
// together, and an isolated reply goes out at once. Round 662 wrote one
// frame per write (MEASURED then: the client read a frame's payload only once
// all of it sat in its socket's receive buffer, and over loopback one large
// write arrived as a few large segments whose kernel memory filled that buffer
// short of the 32 KB page the client waited for -- the wedge). That was the
// client's to fix, and it is fixed: since round 663 packet_reader.gd reads
// whatever is available into its own buffer on every poll, whatever sizes
// the segments come in. The frame-per-write mitigation then cost the server
// one syscall per frame -- round 736 MEASURED 79% of the server's CPU at 1000
// players in one place in `write` under this function -- so a drain is one
// write again. net.Conn.Write writes all of buf or returns an error.
func writeFrames(w io.Writer, buf []byte) (int, error) {
	if len(buf) == 0 {
		return 0, nil
	}
	return w.Write(buf)
}

// dropLocked frees the queue; outMu is held.
func (s *Session) dropLocked() {
	s.out, s.inFlight = nil, 0
	s.outCond.Broadcast()
}

// SendDebtLogFloor is the least send debt a "send debt peak" line reports
// (round 656's third review; OURS, a log threshold only).
var SendDebtLogFloor = 50 * time.Millisecond

// SendQueueLogFloor and SendBurstLogFloor are the least queue and burst a
// "send queue peak" / "send burst peak" line reports; above them a line is
// logged each time the peak doubles (round 662; OURS, log thresholds only).
var (
	SendQueueLogFloor = 64 << 10
	SendBurstLogFloor = 64 << 10
)

// SendStats is the session's send accounting: the highest blocking debt its
// writer reached, its longest single write, and the bytes written.
func (s *Session) SendStats() (peakDebt, longestWrite time.Duration, sentBytes int64) {
	s.outMu.Lock()
	defer s.outMu.Unlock()
	return s.peakDebt, s.longestWrite, s.sentBytes
}

// QueueStats is the session's queue accounting (round 662): the most bytes
// ever waiting in its queue, and the most bytes Sent to it within any
// SendBurstWindow.
func (s *Session) QueueStats() (peakQueued int, peakBurst int) {
	s.outMu.Lock()
	defer s.outMu.Unlock()
	return s.peakQueued, s.burst.peak
}

// stallLocked gives a session up for its sends (reason: "timeout", "budget"
// or "queue"); every later Send returns ErrSendStalled. outMu is held. It
// drops the queue and breaks off any write in flight with a past deadline;
// the writer then closes the connection (never under outMu: a TLS close can
// wait on its peer), so the read loop ends and OnDisconnect runs.
func (s *Session) stallLocked(reason string) {
	if s.logger != nil && !s.stalled.Load() {
		s.logger.Warn("session send stalled, closing", "addr", s.conn.RemoteAddr(), "reason", reason,
			"debt", s.debt, "budget", s.budget, "queued", len(s.out)+s.inFlight, "limit", s.queueLimit)
	}
	s.stalled.Store(true)
	s.closing = true
	s.out = nil
	_ = s.conn.SetWriteDeadline(time.Now())
	s.outCond.Broadcast()
}

// flush waits until every frame queued before it is on the socket, the
// session closes, or timeout passes; it reports whether the frames went out.
func (s *Session) flush(timeout time.Duration) bool {
	if s.outCond == nil {
		return false
	}
	deadline := time.Now().Add(timeout)
	timer := time.AfterFunc(timeout, func() {
		s.outMu.Lock()
		s.outCond.Broadcast()
		s.outMu.Unlock()
	})
	defer timer.Stop()
	s.outMu.Lock()
	defer s.outMu.Unlock()
	target := s.queued
	for s.written < target && !s.stalled.Load() && (len(s.out) > 0 || s.inFlight > 0) && time.Now().Before(deadline) {
		s.outCond.Wait()
	}
	return s.written >= target
}

// closeAfterDrain ends the session: no Send is taken after it, what is
// queued is written out for up to timeout, then the connection is closed and
// the writer is waited for, so neither the goroutine nor the queue outlives
// the session.
func (s *Session) closeAfterDrain(timeout time.Duration) {
	if s.outCond == nil {
		if s.conn != nil {
			_ = s.conn.Close()
		}
		return
	}
	s.outMu.Lock()
	s.closing = true
	s.outCond.Broadcast()
	s.outMu.Unlock()
	s.flush(timeout)
	_ = s.conn.Close()
	<-s.writerDone
}

// Close closes the session's connection at once; what is still queued is
// dropped. (The gateway's own end of a session drains first:
// closeAfterDrain.)
func (s *Session) Close() error {
	if s.outCond != nil {
		s.outMu.Lock()
		s.closing = true
		s.outCond.Broadcast()
		s.outMu.Unlock()
	}
	return s.conn.Close()
}

// burstMeter keeps the bytes Sent in each burstBucket of the last
// SendBurstWindow and the most seen in any window.
type burstMeter struct {
	buckets [burstBuckets]int
	at      int64 // index of the newest bucket
	sum     int
	peak    int
}

const (
	burstBuckets = 16
	burstBucket  = SendBurstWindow / burstBuckets
)

// add counts n bytes at now and returns the window's new peak, or 0 when the
// peak did not rise.
func (b *burstMeter) add(now time.Time, n int) int {
	idx := now.UnixNano() / int64(burstBucket)
	if gap := idx - b.at; gap >= burstBuckets {
		b.buckets = [burstBuckets]int{}
		b.sum = 0
	} else {
		for i := b.at + 1; i <= idx; i++ {
			k := i % burstBuckets
			b.sum -= b.buckets[k]
			b.buckets[k] = 0
		}
	}
	if idx > b.at {
		b.at = idx
	}
	b.buckets[b.at%burstBuckets] += n
	b.sum += n
	if b.sum > b.peak {
		b.peak = b.sum
		return b.peak
	}
	return 0
}

// Server accepts TCP connections and dispatches decoded packets to Handle.
type Server struct {
	Addr   string
	Handle Handler
	Logger *slog.Logger

	// TLSConfig, if set, makes ListenAndServe serve TLS instead of plain
	// TCP -- see docs/protocol/PROTOCOL_DECISION.md: this project's own
	// protocol deliberately has no custom encryption/obfuscation layer
	// (unlike the original game's rolling-byte scheme), on the reasoning
	// that a from-scratch client/server pair should reach for standard
	// TLS instead of reinventing crypto. Plain TCP (nil TLSConfig) remains
	// the default for local development.
	TLSConfig *tls.Config

	// OnDisconnect, if set, is called once when a session's connection ends
	// (client disconnect, read error, or a Handler error). Lets
	// higher-level state (e.g. world.Hub) clean up without gateway knowing
	// anything about what that state is. Don't assume anything about
	// whether the connection is still open at this point — use it for
	// bookkeeping (removing the session from other state), not for sending
	// a farewell packet to the disconnecting client.
	OnDisconnect func(sess *Session)

	// Codec, if set, makes one codec per connection: the session speaks that
	// wire instead of OpenSRO's own framing (round 788's retail listeners).
	Codec func() Codec

	// Quiet, if set, names the opcodes that make a session quiet when they
	// are its FIRST packet: its "session connected" and "session
	// disconnected" lines are logged at Debug instead of Info. Round 679's
	// review: the client's server list asks every listed server for its
	// status every 5 s on a connection of its own, and the theme is asked at
	// every launch; three INFO lines per question flooded the log. The
	// "connected" line is therefore written when the first packet arrives (or
	// when a session ends without one), not at accept.
	Quiet func(opcode uint16) bool
}

// nextSessionID numbers sessions across every Server in the process (round
// 788): the world hub and the session-keyed state key on Session.ID, and the
// retail agent's sessions share them with OpenSRO's own listener.
var nextSessionID atomic.Uint64

// ListenAndServe binds Addr and serves connections until ctx is canceled or
// a fatal listener error occurs.
func (s *Server) ListenAndServe(ctx context.Context) error {
	logger := s.Logger
	if logger == nil {
		logger = slog.Default()
	}

	lc := net.ListenConfig{}
	ln, err := lc.Listen(ctx, "tcp", s.Addr)
	if err != nil {
		return err
	}
	defer ln.Close()

	if s.TLSConfig != nil {
		ln = tls.NewListener(ln, s.TLSConfig)
		logger.Info("gateway listening (TLS)", "addr", s.Addr)
	} else {
		logger.Info("gateway listening", "addr", s.Addr)
	}

	go func() {
		<-ctx.Done()
		ln.Close()
	}()

	for {
		conn, err := ln.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return nil // shutting down; not a real error
			}
			var ne net.Error
			if errors.As(err, &ne) {
				logger.Warn("accept error, continuing", "error", err)
				continue
			}
			return err
		}
		go s.serveConn(ctx, conn, logger)
	}
}

// ErrHandlerPanic is what dispatch returns for a handler that panicked: the
// session ends, the server goes on (round 737's verification, N1: one
// player's bug must never take the server down).
var ErrHandlerPanic = errors.New("gateway: handler panicked")

// dispatch runs s.Handle on p, turning a panic into ErrHandlerPanic after
// logging it with its stack. Only the session's own goroutine is covered:
// a panic on another goroutine (a ticker, a worker) still ends the process.
// A handler that panicked while holding a lock it takes without defer leaves
// it held; the hub's locks are all released by defer.
func (s *Server) dispatch(ctx context.Context, sess *Session, p *proto.Packet, logger *slog.Logger) (err error) {
	defer func() {
		if r := recover(); r != nil {
			logger.Error("handler panic, closing session", "addr", sess.RemoteAddr(), "opcode", fmt.Sprintf("0x%04x", p.Opcode), "panic", r, "stack", string(debug.Stack()))
			err = ErrHandlerPanic
		}
	}()
	return s.Handle(ctx, sess, p)
}

// recoverSession, deferred, logs a panic of the session's what (its
// disconnect bookkeeping) and lets the rest of the teardown run.
func recoverSession(logger *slog.Logger, sess *Session, what string) {
	if r := recover(); r != nil {
		logger.Error("session "+what+" panic", "addr", sess.RemoteAddr(), "panic", r, "stack", string(debug.Stack()))
	}
}

func (s *Server) serveConn(ctx context.Context, conn net.Conn, logger *slog.Logger) {
	sess := &Session{id: nextSessionID.Add(1), conn: conn, logger: logger}
	if s.Codec != nil {
		sess.codec = s.Codec()
	}
	sess.startWriter()
	// The end of a session, in this order: OnDisconnect's bookkeeping, then
	// what is still queued is written out (round 662: a frame sent just
	// before a handler's error reaches the client, as it did when Send wrote
	// synchronously), then the connection is closed and the writer gone.
	quiet, announced := false, false
	level := func() slog.Level {
		if quiet {
			return slog.LevelDebug
		}
		return slog.LevelInfo
	}
	announce := func() {
		if !announced {
			announced = true
			logger.Log(ctx, level(), "session connected", "addr", sess.RemoteAddr())
		}
	}
	defer func() {
		announce()
		sess.closeAfterDrain(SendDrainTimeout)
		peak, longest, sent := sess.SendStats()
		queuePeak, burst := sess.QueueStats()
		logger.Log(ctx, level(), "session disconnected", "addr", sess.RemoteAddr(),
			"send_debt_peak", peak, "longest_write", longest, "sent_bytes", sent,
			"send_queue_peak", queuePeak, "send_burst_peak", burst)
	}()
	if s.OnDisconnect != nil {
		defer func() {
			defer recoverSession(logger, sess, "disconnect")
			s.OnDisconnect(sess)
		}()
	}

	r := bufio.NewReader(conn)
	if sess.codec != nil {
		if err := sess.codec.Start(sess); err != nil {
			logger.Warn("session codec start failed", "addr", sess.RemoteAddr(), "error", err)
			return
		}
	}
	for {
		select {
		case <-ctx.Done():
			return
		default:
		}

		var p *proto.Packet
		var err error
		if sess.codec != nil {
			p, err = sess.codec.ReadPacket(r)
		} else {
			_, _, recvRoll, recvSum := sess.security()
			p, err = proto.Read(r, recvRoll, recvSum)
		}
		if err != nil {
			if !errors.Is(err, io.EOF) {
				logger.Warn("session read error", "addr", sess.RemoteAddr(), "error", err)
			}
			return
		}

		if !announced {
			quiet = s.Quiet != nil && s.Quiet(p.Opcode)
			announce()
		}
		if s.Handle == nil {
			continue
		}
		if err := s.dispatch(ctx, sess, p, logger); err != nil {
			if errors.Is(err, ErrEndSession) {
				logger.Debug("session ended by its handler", "addr", sess.RemoteAddr())
				return
			}
			logger.Warn("handler error, closing session", "addr", sess.RemoteAddr(), "error", err)
			return
		}
	}
}
