package relay

import (
	"bufio"
	"context"
	"errors"
	"io"
	"log/slog"
	"net"
	"sync"
	"sync/atomic"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
)

// Front is the client-facing process of -role front: it accepts clients on
// Addr and relays each to a world host -- the open world's (Home) at first,
// then wherever a re-route sends it. A stream that breaks without a re-route
// (its host died, or was declared dead: HostDown) is recovered: the front
// opens a stream to the open world's host asking it to put the character
// back at its return point, and the player sees the ordinary loading screen.
type Front struct {
	Addr   string
	Secret string
	ID     string
	// Home is the open world's host's relay address (logins and recoveries
	// go there).
	Home   func(ctx context.Context) (host, addr string, err error)
	Logger *slog.Logger
	// Dial opens a stream (net.Dialer by default).
	Dial func(ctx context.Context, addr string) (net.Conn, error)
	// RecoverLimit bounds the recoveries of one client in RecoverWindow
	// (OURS: a character whose recovery keeps failing is disconnected
	// rather than bounced for ever).
	RecoverLimit  int
	RecoverWindow time.Duration

	mu    sync.Mutex
	links map[*link]struct{}

	// Counters (the load test's).
	Accepted, Reroutes, Recoveries, Dropped atomic.Int64
}

// link is one client and its current stream.
type link struct {
	f      *Front
	client net.Conn
	cw     sync.Mutex // writes to the client

	mu        sync.Mutex
	up        net.Conn
	upHost    string
	gen       int
	switching bool
	pending   []*proto.Packet
	bind      *Bind
	closed    bool
	recovered []time.Time
	// sent counts the frames written to the current stream; recent keeps
	// the last ones (with their numbers) for a re-route's replay.
	sent   int64
	recent []sentFrame
}

type sentFrame struct {
	n int64
	p *proto.Packet
}

// replayKeep is how many sent frames a link keeps for a re-route (OURS: the
// frames a client sends in the milliseconds a move is decided in).
const replayKeep = 256

func (f *Front) logger() *slog.Logger {
	if f.Logger != nil {
		return f.Logger
	}
	return slog.Default()
}

func (f *Front) dial(ctx context.Context, addr string) (net.Conn, error) {
	if f.Dial != nil {
		return f.Dial(ctx, addr)
	}
	d := net.Dialer{Timeout: 5 * time.Second}
	return d.DialContext(ctx, "tcp", addr)
}

// ListenAndServe accepts clients until ctx ends.
func (f *Front) ListenAndServe(ctx context.Context) error {
	ln, err := (&net.ListenConfig{}).Listen(ctx, "tcp", f.Addr)
	if err != nil {
		return err
	}
	return f.Serve(ctx, ln)
}

// Serve accepts clients on ln until ctx ends.
func (f *Front) Serve(ctx context.Context, ln net.Listener) error {
	f.mu.Lock()
	if f.links == nil {
		f.links = map[*link]struct{}{}
	}
	f.mu.Unlock()
	f.logger().Info("front listening", "addr", ln.Addr().String(), "front", f.ID)
	go func() {
		<-ctx.Done()
		ln.Close()
	}()
	for {
		c, err := ln.Accept()
		if err != nil {
			if ctx.Err() != nil {
				f.closeAll()
				return nil
			}
			var ne net.Error
			if errors.As(err, &ne) {
				continue
			}
			return err
		}
		f.Accepted.Add(1)
		l := &link{f: f, client: c}
		f.mu.Lock()
		f.links[l] = struct{}{}
		f.mu.Unlock()
		go l.serve(ctx)
	}
}

func (f *Front) closeAll() {
	f.mu.Lock()
	var ls []*link
	for l := range f.links {
		ls = append(ls, l)
	}
	f.mu.Unlock()
	for _, l := range ls {
		l.close()
	}
}

// Clients is the number of connected clients.
func (f *Front) Clients() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.links)
}

// HostDown closes every stream to host (the reaper declared it dead, or it
// hangs): each of its clients is recovered.
func (f *Front) HostDown(host string) {
	f.mu.Lock()
	var ls []*link
	for l := range f.links {
		ls = append(ls, l)
	}
	f.mu.Unlock()
	for _, l := range ls {
		l.mu.Lock()
		up, h := l.up, l.upHost
		l.mu.Unlock()
		if h == host && up != nil {
			up.Close()
		}
	}
}

func (l *link) close() {
	l.mu.Lock()
	if l.closed {
		l.mu.Unlock()
		return
	}
	l.closed = true
	up := l.up
	l.mu.Unlock()
	l.client.Close()
	if up != nil {
		up.Close()
	}
	l.f.mu.Lock()
	delete(l.f.links, l)
	l.f.mu.Unlock()
}

func (l *link) hello() Hello {
	return Hello{Secret: l.f.Secret, Version: Version, Front: l.f.ID, Client: l.client.RemoteAddr().String()}
}

// serve opens the first stream (to the open world's host) and pumps the
// client's frames up.
func (l *link) serve(ctx context.Context) {
	defer l.close()
	host, addr, err := l.f.Home(ctx)
	if err != nil {
		l.f.logger().Warn("front: no open-world host", "err", err)
		return
	}
	up, err := dialHello(ctx, l.f.dial, addr, l.hello())
	if err != nil {
		l.f.logger().Warn("front: cannot reach the open-world host", "host", host, "addr", addr, "err", err)
		return
	}
	l.attach(up, host)
	r := bufio.NewReader(l.client)
	for {
		p, err := proto.Read(r, nil, nil)
		if err != nil {
			return
		}
		if IsControl(p.Opcode) {
			continue // a client may not speak for the front
		}
		l.mu.Lock()
		if l.switching {
			l.pending = append(l.pending, p)
			l.mu.Unlock()
			continue
		}
		up := l.up
		l.sent++
		l.recent = append(l.recent, sentFrame{l.sent, p})
		if len(l.recent) > replayKeep {
			l.recent = l.recent[len(l.recent)-replayKeep:]
		}
		l.mu.Unlock()
		if up != nil {
			if err := writeFrame(up, p); err != nil {
				// The stream broke; its reader recovers or closes. The
				// frame is lost with it.
				l.f.Dropped.Add(1)
			}
		}
	}
}

// attach makes up the link's stream and starts its reader; replay is what
// the stream it replaces did not handle.
func (l *link) attach(up net.Conn, host string, replay ...*proto.Packet) {
	l.mu.Lock()
	l.up, l.upHost = up, host
	l.gen++
	gen := l.gen
	pending := append(replay, l.pending...)
	l.pending = nil
	l.sent = 0
	l.recent = nil
	for _, p := range pending {
		l.sent++
		l.recent = append(l.recent, sentFrame{l.sent, p})
	}
	l.switching = false
	closed := l.closed
	l.mu.Unlock()
	if closed {
		up.Close()
		return
	}
	for _, p := range pending {
		if err := writeFrame(up, p); err != nil {
			break
		}
	}
	go l.pumpDown(up, host, gen)
}

// pumpDown copies a stream's frames to the client, handling the control
// frames, until the stream ends.
func (l *link) pumpDown(up net.Conn, host string, gen int) {
	r := bufio.NewReader(up)
	for {
		p, err := proto.Read(r, nil, nil)
		if err != nil {
			l.streamEnded(up, host, gen, err)
			return
		}
		switch p.Opcode {
		case OpBind:
			var b Bind
			if jsonErr := unmarshal(p.Data, &b); jsonErr == nil {
				l.mu.Lock()
				if b.Char == 0 {
					l.bind = nil // an unbind: a logout, a kick
				} else {
					l.bind = &b
				}
				l.mu.Unlock()
			}
			continue
		case OpReroute:
			var rr Reroute
			if jsonErr := unmarshal(p.Data, &rr); jsonErr != nil {
				continue
			}
			l.reroute(up, gen, rr)
			return // the old stream is done; its host closes it
		}
		if IsControl(p.Opcode) {
			continue
		}
		l.cw.Lock()
		err = writeFrame(l.client, p)
		l.cw.Unlock()
		if err != nil {
			l.close()
			return
		}
	}
}

// reroute moves the client to rr's host: the client's frames wait while the
// new stream opens, then go there.
func (l *link) reroute(old net.Conn, gen int, rr Reroute) {
	l.mu.Lock()
	if l.gen != gen || l.closed {
		l.mu.Unlock()
		return
	}
	l.switching = true
	var replay []*proto.Packet
	for _, f := range l.recent {
		if f.n > rr.Consumed {
			replay = append(replay, f.p)
		}
	}
	l.mu.Unlock()
	l.f.Reroutes.Add(1)
	h := l.hello()
	h.Handoff = rr.Handoff
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	up, err := dialHello(ctx, l.f.dial, rr.Addr, h)
	old.Close()
	if err != nil {
		l.f.logger().Warn("front: the re-route's host cannot be reached; recovering", "host", rr.Host, "addr", rr.Addr, "err", err)
		l.recover(gen)
		return
	}
	l.attach(up, rr.Host, replay...)
}

// streamEnded is a stream that broke without a re-route: the client is
// recovered on the open world's host, or closed.
func (l *link) streamEnded(up net.Conn, host string, gen int, err error) {
	up.Close()
	l.mu.Lock()
	current := l.gen == gen && !l.closed
	l.mu.Unlock()
	if !current {
		return
	}
	if errors.Is(err, io.EOF) && !l.wantsRecover() {
		l.close()
		return
	}
	l.f.logger().Info("front: a stream broke", "host", host, "err", err)
	l.recover(gen)
}

func (l *link) wantsRecover() bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.bind != nil
}

// recover asks the open world's host to put the bound character back at its
// return point, on a fresh stream; a link with nobody in the world, or past
// its recovery limit, is closed.
func (l *link) recover(gen int) {
	l.mu.Lock()
	b := l.bind
	now := time.Now()
	limit, window := l.f.RecoverLimit, l.f.RecoverWindow
	if limit <= 0 {
		limit = 3
	}
	if window <= 0 {
		window = time.Minute
	}
	var recent []time.Time
	for _, t := range l.recovered {
		if now.Sub(t) < window {
			recent = append(recent, t)
		}
	}
	l.recovered = append(recent, now)
	tooMany := len(l.recovered) > limit
	l.switching = true
	l.mu.Unlock()
	if b == nil || tooMany {
		l.close()
		return
	}
	l.f.Recoveries.Add(1)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	var up net.Conn
	var host string
	// The open world's host may itself be the one that died and is being
	// replaced: try for a few seconds.
	for attempt := 0; attempt < 10; attempt++ {
		h, addr, err := l.f.Home(ctx)
		if err == nil {
			hello := l.hello()
			hello.Recover = b
			if c, err := dialHello(ctx, l.f.dial, addr, hello); err == nil {
				up, host = c, h
				break
			}
		}
		select {
		case <-ctx.Done():
		case <-time.After(500 * time.Millisecond):
		}
		if ctx.Err() != nil {
			break
		}
	}
	if up == nil {
		l.f.logger().Warn("front: recovery failed; closing the client", "character_id", b.Char)
		l.close()
		return
	}
	l.f.logger().Info("front: recovering a character on the open world's host", "character_id", b.Char, "host", host)
	l.attach(up, host)
}
