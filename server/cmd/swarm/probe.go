package main

// The latency probe: one bot standing somewhere quiet (by default region
// 98/171, a field three regions from Jangan's plaza with no nest in it, so
// the crowd is out of its view and no monster is filed there) that clicks
// (retail 0x7021) between two points 8 units apart every -probe-every
// (250 ms) and times its own 0xB021 echo. The echo is the server's answer to
// a click: read off the socket, through the move handler and the world hub,
// back out the session's send queue -- what a player feels as lag. Every
// -probe-report (10 s) it logs p50 / p99 / max of the window, and any single
// round trip over -probe-spike (200 ms) on its own line with the send and
// echo times to the millisecond, for lining up with the server's log
// (mind the two machines' clocks). A click that has no echo within 5 s, a
// dropped connection and the reconnect are logged the same way.
//
// One click is in flight at a time: a stalled server shows as one long round
// trip, not a pile of queued ones. At 4 clicks a second the probe is far
// under the server's click bucket (30 a second) and its echo goes to its own
// view only. OURS throughout.

import (
	"bufio"
	"context"
	"database/sql"
	"encoding/binary"
	"fmt"
	"log"
	"math"
	"net"
	"sort"
	"sync"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/session"
	"github.com/TheOpenSRO/OpenSRO/server/internal/worldmap"
)

// probeConfig is the probe's placement and timing.
type probeConfig struct {
	prefix   string
	zone     string // the frame its spot is written in
	region   string // "x/y"
	x, y, z  float64
	every    time.Duration
	spike    time.Duration
	report   time.Duration
	timeout  time.Duration
	password string
}

// probeStep is how far apart the two points it clicks between are: more
// than the move gate's 5.0 near-destination bound (READ 0xb45b28), so a
// click never lands inside it.
const probeStep = 8.0

// probeStamp formats a time for the spike lines: local time to the
// millisecond, with the zone, as the server's slog lines carry.
const probeStamp = "2006-01-02T15:04:05.000Z07:00"

func (pc probeConfig) spot() (spot, error) {
	rx, ry, ok := worldmap.ParseRegionLabel(pc.region)
	if !ok {
		return spot{}, fmt.Errorf("-probe-region %q: want x/y", pc.region)
	}
	if pc.x < 1+probeStep || pc.x > worldmap.RegionSpan-2-probeStep || pc.z < 1 || pc.z > worldmap.RegionSpan-2 {
		return spot{}, fmt.Errorf("-probe-x/-probe-z (%.0f, %.0f) must be inside the region, %.0f from its west and east edges", pc.x, pc.z, 1+probeStep)
	}
	return spot{Zone: pc.zone, RX: rx, RY: ry, X: pc.x, Y: pc.y, Z: pc.z}, nil
}

// prober is a running probe.
type prober struct {
	cfg  probeConfig
	addr string
	db   *sql.DB
	at   spot

	mu       sync.Mutex
	window   []time.Duration
	sent     int
	lost     int
	spikes   int
	worst    time.Duration
	worstAt  time.Time
	total    int
	totalMax time.Duration
}

// probe runs `swarm probe`: the account, then the probe until SIGINT/SIGTERM.
func runProbe(ctx context.Context, addr string, db *sql.DB, pc probeConfig) error {
	at, err := pc.spot()
	if err != nil {
		return err
	}
	if pc.password == "" {
		return fmt.Errorf("no probe password")
	}
	if _, err := ensureAccounts(ctx, db, pc.prefix, 1, pc.password); err != nil {
		return err
	}
	p := &prober{cfg: pc, addr: addr, db: db, at: at}
	log.Printf("probe %s: clicking every %s at %s local (%.0f, %.0f) in the %s frame; reporting every %s, spikes over %s",
		botName(pc.prefix, 0), pc.every, pc.region, pc.x, pc.z, pc.zone, pc.report, pc.spike)
	go p.reportLoop(ctx)
	for ctx.Err() == nil {
		started := time.Now()
		err := p.session(ctx)
		if ctx.Err() != nil {
			break
		}
		log.Printf("probe: DISCONNECTED at %s after %s: %v; reconnecting in 5 s", time.Now().Format(probeStamp), time.Since(started).Round(time.Millisecond), err)
		select {
		case <-ctx.Done():
		case <-time.After(5 * time.Second):
		}
	}
	p.logWindow(true)
	return nil
}

// echoAt is one of the probe's own echoes: when it was read, and where it
// leads.
type echoAt struct {
	at   time.Time
	x, z int16
}

func (p *prober) session(ctx context.Context) error {
	name := botName(p.cfg.prefix, 0)
	d := net.Dialer{Timeout: 10 * time.Second}
	nc, err := d.DialContext(ctx, "tcp", p.addr)
	if err != nil {
		return fmt.Errorf("dial: %w", err)
	}
	defer nc.Close()
	stop := context.AfterFunc(ctx, func() { nc.Close() })
	defer stop()
	if tc, ok := nc.(*net.TCPConn); ok {
		_ = tc.SetNoDelay(true)
	}
	c := &conn{c: nc, r: bufio.NewReaderSize(nc, 32<<10), st: &stats{}}
	if err := login(c, name, p.cfg.password); err != nil {
		return err
	}
	ch, _, err := ensureCharacter(ctx, c, p.db, p.cfg.prefix, name, lookFor(1, 0))
	if err != nil {
		return err
	}
	if err := seedCharacter(ctx, p.db, p.cfg.prefix, ch.ID, nil, p.at, 1); err != nil {
		return fmt.Errorf("placing the probe: %w", err)
	}
	er, uid, err := startWorld(c, name)
	if err != nil {
		return err
	}
	fx, fy, ok := parseFrame(er.FrameRegion)
	if !ok {
		fx, fy, ok = worldmap.FrameFor(er.Zone)
	}
	if !ok {
		return fmt.Errorf("no frame for zone %q", er.Zone)
	}
	rx, ry, lx, lz := worldmap.FromWorld(float64(er.X), float64(er.Z), fx, fy)
	log.Printf("probe: in the world at %d/%d local (%.1f, %.1f) y %.1f (zone %s)", rx, ry, lx, lz, er.Y, er.Zone)
	region := uint16(worldmap.RegionID(rx, ry))
	ax, az := int16(math.Trunc(lx)), int16(math.Trunc(lz))
	bx := ax + probeStep
	if float64(bx) > worldmap.RegionSpan-2 {
		bx = ax - probeStep
	}
	points := [2][2]int16{{bx, az}, {ax, az}}

	echoes := make(chan echoAt, 8)
	readErr := make(chan error, 1)
	go func() {
		keep := func(op uint16) bool { return op == proto.OpMovementResponse }
		for {
			op, data, err := c.next(keep)
			if err != nil {
				readErr <- err
				return
			}
			if op != proto.OpMovementResponse || len(data) < 4 || binary.LittleEndian.Uint32(data) != uid {
				continue
			}
			now := time.Now()
			if e, ok := session.DecodeMoveEcho(data); ok && e.Move != nil && e.Move.Kind != proto.MovementKindHeading {
				select {
				case echoes <- echoAt{at: now, x: e.Move.LocalX, z: e.Move.LocalZ}:
				default:
				}
			}
		}
	}()

	tick := time.NewTicker(p.cfg.every)
	defer tick.Stop()
	for i := 0; ; i++ {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case err := <-readErr:
			return fmt.Errorf("read: %w", err)
		case <-tick.C:
		}
		pt := points[i%2]
		mv := &proto.Movement{Kind: 1, Region: region, LocalX: pt[0], LocalY: int16(er.Y), LocalZ: pt[1]}
		for len(echoes) > 0 {
			<-echoes
		}
		sent := time.Now()
		if err := c.send(proto.OpMovementRequest, mv.Encode()); err != nil {
			return err
		}
		deadline := time.NewTimer(p.cfg.timeout)
	wait:
		for {
			select {
			case <-ctx.Done():
				deadline.Stop()
				return ctx.Err()
			case err := <-readErr:
				deadline.Stop()
				return fmt.Errorf("read: %w", err)
			case e := <-echoes:
				if e.x != pt[0] || e.z != pt[1] {
					continue // a stale echo
				}
				p.note(sent, e.at)
				break wait
			case <-deadline.C:
				p.noteLost(sent)
				break wait
			}
		}
		deadline.Stop()
	}
}

func (p *prober) note(sent, got time.Time) {
	rtt := got.Sub(sent)
	p.mu.Lock()
	p.sent++
	p.total++
	p.window = append(p.window, rtt)
	if rtt > p.worst {
		p.worst, p.worstAt = rtt, sent
	}
	p.totalMax = max(p.totalMax, rtt)
	spike := rtt > p.cfg.spike
	if spike {
		p.spikes++
	}
	p.mu.Unlock()
	if spike {
		log.Printf("probe: SPIKE rtt %s: click sent %s, echo read %s", rtt.Round(100*time.Microsecond), sent.Format(probeStamp), got.Format(probeStamp))
	}
}

func (p *prober) noteLost(sent time.Time) {
	p.mu.Lock()
	p.sent++
	p.lost++
	p.mu.Unlock()
	log.Printf("probe: NO ECHO within %s for the click sent %s", p.cfg.timeout, sent.Format(probeStamp))
}

func (p *prober) reportLoop(ctx context.Context) {
	t := time.NewTicker(p.cfg.report)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			p.logWindow(false)
		}
	}
}

// logWindow logs the window's numbers and starts a new one; final logs the
// run's totals.
func (p *prober) logWindow(final bool) {
	p.mu.Lock()
	w := p.window
	p.window = nil
	sent, lost, spikes, worst, worstAt := p.sent, p.lost, p.spikes, p.worst, p.worstAt
	p.sent, p.lost, p.spikes, p.worst = 0, 0, 0, 0
	total, totalMax := p.total, p.totalMax
	p.mu.Unlock()
	if final {
		defer log.Printf("probe: stopped after %d echoes, the longest %s", total, fmtRTT(totalMax))
	}
	if sent == 0 && final {
		return
	}
	if sent == 0 {
		log.Printf("probe: no clicks this window (not in the world)")
		return
	}
	p50, p99, mx := quantiles(w)
	line := fmt.Sprintf("probe: %d clicks, %d echoed, %d lost, %d over %s; rtt p50 %s p99 %s max %s",
		sent, len(w), lost, spikes, p.cfg.spike, fmtRTT(p50), fmtRTT(p99), fmtRTT(mx))
	if worst > 0 {
		line += " (at " + worstAt.Format(probeStamp) + ")"
	}
	log.Print(line)
}

// quantiles is the p50, p99 and max of d (nearest rank).
func quantiles(d []time.Duration) (p50, p99, mx time.Duration) {
	if len(d) == 0 {
		return 0, 0, 0
	}
	s := append([]time.Duration(nil), d...)
	sort.Slice(s, func(i, j int) bool { return s[i] < s[j] })
	rank := func(q float64) time.Duration {
		i := int(math.Ceil(q*float64(len(s)))) - 1
		return s[max(0, min(i, len(s)-1))]
	}
	return rank(0.50), rank(0.99), s[len(s)-1]
}

func fmtRTT(d time.Duration) string {
	return fmt.Sprintf("%.2fms", float64(d)/float64(time.Millisecond))
}
