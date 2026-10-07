package main

// One bot's connection: the login, the lobby create when its character does
// not exist yet, the gear seeded in Postgres, the Start into the world, then
// a reader that drains everything the server sends (a bot that stops reading
// is closed by the server's send bounds, gateway.SendQueueLimit) and, for a
// walker, retail click-moves.

import (
	"bufio"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"math"
	"math/rand"
	"net"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/npcspawn"
	"github.com/OpenSRO/OpenSRO/server/internal/pcspawn"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/session"
	"github.com/OpenSRO/OpenSRO/server/internal/worldmap"
)

const (
	frameHeader = 6
	sizeFlag    = 1 << 15
	// opMoveStop is retail's 0xB023 (session/destmove.go).
	opMoveStop uint16 = 0xB023
	// The move gate's near-destination bound (READ 0xb45b28, r749): a click
	// within it of the destination set is refused while moving. The walker
	// clicks only between legs and always farther than this.
	nearDestination = 5.0
)

// conn is a bot's framed connection with a reusable read buffer.
type conn struct {
	c   net.Conn
	r   *bufio.Reader
	hdr [frameHeader]byte
	buf []byte
	wmu sync.Mutex
	st  *stats
	// side, when set, is handed the frames await skips that sideKeep wants
	// (the observer's spawns that arrive before the bot's own SelfID).
	side     func(op uint16, data []byte)
	sideKeep func(op uint16) bool
}

func (c *conn) send(op uint16, data []byte) error {
	c.wmu.Lock()
	defer c.wmu.Unlock()
	_ = c.c.SetWriteDeadline(time.Now().Add(10 * time.Second))
	return proto.Write(c.c, &proto.Packet{Opcode: op, Data: data}, nil, nil)
}

// next reads one frame. The payload is read into the reusable buffer when
// keep(op) is true and discarded otherwise; it is valid until the next call.
func (c *conn) next(keep func(uint16) bool) (uint16, []byte, error) {
	if _, err := io.ReadFull(c.r, c.hdr[:]); err != nil {
		return 0, nil, err
	}
	raw := binary.LittleEndian.Uint16(c.hdr[0:2])
	op := binary.LittleEndian.Uint16(c.hdr[2:4])
	if raw&sizeFlag != 0 {
		return op, nil, proto.ErrEncrypted
	}
	size := int(raw &^ sizeFlag)
	c.st.packetsIn.Add(1)
	c.st.bytesIn.Add(int64(size + frameHeader))
	if keep != nil && !keep(op) {
		_, err := c.r.Discard(size)
		return op, nil, err
	}
	if cap(c.buf) < size {
		c.buf = make([]byte, size, max(size, 4096))
	}
	data := c.buf[:size]
	_, err := io.ReadFull(c.r, data)
	return op, data, err
}

// await reads until op arrives, within d.
func (c *conn) await(op uint16, d time.Duration) ([]byte, error) {
	_ = c.c.SetReadDeadline(time.Now().Add(d))
	defer c.c.SetReadDeadline(time.Time{})
	for {
		got, data, err := c.next(func(o uint16) bool { return o == op || (c.sideKeep != nil && c.sideKeep(o)) })
		if err != nil {
			return nil, fmt.Errorf("waiting for 0x%04x: %w", op, err)
		}
		if got == op {
			return data, nil
		}
		if data != nil && c.side != nil {
			c.side(got, data)
		}
	}
}

// bot is one swarm member.
type bot struct {
	sw       *swarm
	i        int
	name     string
	walker   bool
	observer bool
	seeded   bool
	state    atomic.Int32
	c        atomic.Pointer[conn]
}

const (
	stIdle int32 = iota
	stConnected
	stInWorld
)

// errFull is a login the server refused as full: retried later.
var errFull = errors.New("server full")

// run keeps the bot online until ctx ends, reconnecting with a backoff.
func (b *bot) run(ctx context.Context) {
	backoff := 2 * time.Second
	for ctx.Err() == nil {
		if err := b.sw.pace.wait(ctx); err != nil {
			return
		}
		started := time.Now()
		err := b.session(ctx)
		b.state.Store(stIdle)
		if ctx.Err() != nil {
			return
		}
		b.sw.st.drops.Add(1)
		b.sw.st.noteErr(err)
		if time.Since(started) > time.Minute {
			backoff = 2 * time.Second
		}
		wait := backoff
		if errors.Is(err, errFull) {
			wait = 30 * time.Second
		}
		wait += time.Duration(rand.Int63n(int64(time.Second)))
		select {
		case <-ctx.Done():
			return
		case <-time.After(wait):
		}
		b.sw.st.reconnects.Add(1)
		backoff = min(backoff*2, time.Minute)
	}
}

// stop closes the connection (the server logs the character out).
func (b *bot) stop() {
	if c := b.c.Load(); c != nil {
		c.c.Close()
	}
}

func (b *bot) session(ctx context.Context) error {
	sw := b.sw
	d := net.Dialer{Timeout: 10 * time.Second, KeepAliveConfig: net.KeepAliveConfig{Enable: true, Idle: 30 * time.Second, Interval: 10 * time.Second, Count: 3}}
	nc, err := d.DialContext(ctx, "tcp", sw.cfg.addr)
	if err != nil {
		return fmt.Errorf("dial: %w", err)
	}
	c := &conn{c: nc, r: bufio.NewReaderSize(nc, 32<<10), st: &sw.st}
	b.c.Store(c)
	defer func() {
		nc.Close()
		b.c.CompareAndSwap(c, nil)
	}()
	stopOnCancel := context.AfterFunc(ctx, func() { nc.Close() })
	defer stopOnCancel()
	b.state.Store(stConnected)

	// The login.
	if err := c.send(session.OpLogin, (&session.LoginRequest{Username: b.name, Password: sw.password}).Encode()); err != nil {
		return err
	}
	data, err := c.await(session.OpLoginResult, 15*time.Second)
	if err != nil {
		return fmt.Errorf("login: %w", err)
	}
	lr, err := session.DecodeLoginResult(data)
	if err != nil {
		return fmt.Errorf("login: %w", err)
	}
	if !lr.OK {
		if lr.Reason == session.LoginRefusedFull {
			return errFull
		}
		return fmt.Errorf("login refused: %s", lr.Reason)
	}

	// The character: created through the lobby the first time.
	ch, ok, err := botCharacter(ctx, sw.db, sw.cfg.prefix, b.name)
	if err != nil {
		return fmt.Errorf("looking up the character: %w", err)
	}
	if !ok {
		lk := lookFor(sw.cfg.seed, b.i)
		if err := c.send(session.OpLobby, lk.createRequest(b.name).Encode()); err != nil {
			return err
		}
		data, err := c.await(session.OpLobbyResult, 15*time.Second)
		if err != nil {
			return fmt.Errorf("create: %w", err)
		}
		res, err := session.DecodeLobbyResult(data)
		if err != nil {
			return fmt.Errorf("create: %w", err)
		}
		if !res.OK && res.Code != session.LobbyErrNameExists {
			return fmt.Errorf("create refused: code 0x%x (is the server's -chargen-csv loaded?)", res.Code)
		}
		sw.st.creates.Add(1)
		if ch, ok, err = botCharacter(ctx, sw.db, sw.cfg.prefix, b.name); err != nil || !ok {
			return fmt.Errorf("the created character is not in the database: %v", err)
		}
	}

	// Its gear and its spot, once a run, while it is not in the world.
	if !b.seeded {
		race, sex := raceSexOfGender(ch.Gender)
		gear := sw.cat.loadout(sw.cfg.seed, b.i, race, sex)
		lx, lz := standFor(sw.cfg.seed, b.i, sw.cfg.radius)
		if err := seedCharacter(ctx, sw.db, sw.cfg.prefix, ch.ID, gear, lx, lz); err != nil {
			return fmt.Errorf("seeding: %w", err)
		}
		b.seeded = true
		sw.st.seeded.Add(1)
		sw.gearSeen(gear)
	}

	// Start (0x7001) into the world. The observer reads the spawns that come
	// with the entry too.
	if b.observer {
		c.side, c.sideKeep = sw.obs.frame, observes
	}
	if err := c.send(session.OpStart, (&session.StartRequest{Name: b.name}).Encode()); err != nil {
		return err
	}
	data, err = c.await(session.OpEnterWorldResult, 20*time.Second)
	if err != nil {
		return fmt.Errorf("start: %w", err)
	}
	er, err := session.DecodeEnterWorldResult(data)
	if err != nil {
		return fmt.Errorf("start: %w", err)
	}
	if !er.OK {
		return fmt.Errorf("enter world refused: %s", er.Reason)
	}
	data, err = c.await(session.OpSelfID, 15*time.Second)
	if err != nil {
		return err
	}
	self, err := session.DecodeSelfID(data)
	if err != nil {
		return err
	}
	b.state.Store(stInWorld)
	sw.st.entries.Add(1)
	if sw.st.firstZone.Load() == nil {
		z := er.Zone
		sw.st.firstZone.Store(&z)
	}

	uid := uint32(self.CharacterID)
	var w *walker
	if b.walker {
		fx, fy, ok := parseFrame(er.FrameRegion)
		if !ok {
			fx, fy, ok = worldmap.FrameFor(er.Zone)
		}
		if ok {
			rx, ry, lx, lz := worldmap.FromWorld(float64(er.X), float64(er.Z), fx, fy)
			w = &walker{b: b, c: c, region: uint16(worldmap.RegionID(rx, ry)), rx: rx, ry: ry, x: lx, z: lz, y: float64(er.Y),
				echo: make(chan struct{}, 4), rnd: rand.New(rand.NewSource(sw.cfg.seed + int64(b.i)*13 + time.Now().UnixNano()))}
			go w.loop(ctx)
		}
	}
	var obs *observer
	if b.observer {
		obs = sw.obs
	}
	return b.read(c, uid, w, obs)
}

func parseFrame(s string) (int, int, bool) {
	a, b, ok := strings.Cut(s, "/")
	if !ok {
		return 0, 0, false
	}
	x, err1 := strconv.Atoi(a)
	y, err2 := strconv.Atoi(b)
	return x, y, err1 == nil && err2 == nil
}

// read drains the connection until it fails.
func (b *bot) read(c *conn, uid uint32, w *walker, obs *observer) error {
	keep := func(op uint16) bool {
		switch op {
		case proto.OpMovementResponse, opMoveStop:
			return w != nil
		}
		return obs != nil && observes(op)
	}
	for {
		op, data, err := c.next(keep)
		if err != nil {
			return fmt.Errorf("read: %w", err)
		}
		if data == nil {
			continue
		}
		switch op {
		case proto.OpMovementResponse:
			if len(data) >= 4 && binary.LittleEndian.Uint32(data) == uid {
				if e, ok := session.DecodeMoveEcho(data); ok {
					w.echoed(e)
				}
			}
		case opMoveStop:
			if s, ok := session.DecodeMoveStop(data); ok && s.UID == uid {
				w.corrected(s)
			}
		default:
			obs.frame(op, data)
		}
	}
}

// walker sends a retail 0x7021 click to a random nearby plaza point every few
// seconds (3..7 s), one click per leg: the leg (at most about 40 units, under
// a second at the base run speed of 50) has ended before the next click, so no
// click falls inside the 5.0 near-destination gate, and the rate (one click
// per 3 s at most) is far under the server's bucket of 30 a second.
type walker struct {
	b      *bot
	c      *conn
	mu     sync.Mutex
	region uint16
	rx, ry int
	x, z   float64 // where the server has the bot, region-local
	y      float64
	sent   *proto.Movement
	echo   chan struct{}
	rnd    *rand.Rand
}

func (w *walker) loop(ctx context.Context) {
	st := &w.b.sw.st
	st.walkersOn.Add(1)
	defer st.walkersOn.Add(-1)
	for {
		wait := 3*time.Second + time.Duration(w.rnd.Int63n(int64(4*time.Second)))
		select {
		case <-ctx.Done():
			return
		case <-time.After(wait):
		}
		if w.b.c.Load() != w.c {
			return // the connection this walker drove is gone
		}
		mv, ok := w.nextClick()
		if !ok {
			continue
		}
		for len(w.echo) > 0 {
			<-w.echo
		}
		if err := w.c.send(proto.OpMovementRequest, mv.Encode()); err != nil {
			return
		}
		st.clicks.Add(1)
		select {
		case <-w.echo:
			st.echoes.Add(1)
		case <-time.After(1500 * time.Millisecond):
			st.noEcho.Add(1) // a silent refusal (retail sends none)
		case <-ctx.Done():
			return
		}
	}
}

// nextClick picks a destination 8..40 from where the bot stands: inside the
// plaza disc when the bot is in the plaza's region, else around itself, and
// always inside its own region.
func (w *walker) nextClick() (*proto.Movement, bool) {
	w.mu.Lock()
	defer w.mu.Unlock()
	radius := w.b.sw.cfg.radius
	inPlaza := w.rx == plazaRX && w.ry == plazaRY && math.Hypot(w.x-plazaX, w.z-plazaZ) <= radius+40
	for try := 0; try < 30; try++ {
		var lx, lz float64
		if inPlaza {
			lx, lz = plazaPoint(w.rnd, radius)
		} else {
			d, a := 8+w.rnd.Float64()*32, w.rnd.Float64()*2*math.Pi
			lx, lz = w.x+d*math.Cos(a), w.z+d*math.Sin(a)
		}
		ix, iz := math.Trunc(lx), math.Trunc(lz)
		if ix < 1 || iz < 1 || ix > worldmap.RegionSpan-2 || iz > worldmap.RegionSpan-2 {
			continue
		}
		dist := math.Hypot(ix-w.x, iz-w.z)
		if dist < 8 || dist > 40 {
			continue
		}
		if s := w.sent; s != nil && math.Hypot(ix-float64(s.LocalX), iz-float64(s.LocalZ)) <= nearDestination {
			continue
		}
		mv := &proto.Movement{Kind: 1, Region: w.region, LocalX: int16(ix), LocalY: int16(w.y), LocalZ: int16(iz)}
		w.sent = mv
		return mv, true
	}
	return nil, false
}

// echoed is the bot's own 0xB021: the leg runs to the point it named, where
// the server's mover cuts it.
func (w *walker) echoed(e session.MoveEcho) {
	if e.Move == nil || e.Move.Kind == proto.MovementKindHeading {
		return
	}
	w.mu.Lock()
	w.x, w.z, w.region = float64(e.Move.LocalX), float64(e.Move.LocalZ), e.Move.Region
	w.rx, w.ry = worldmap.RegionXY(int(e.Move.Region))
	w.mu.Unlock()
	select {
	case w.echo <- struct{}{}:
	default:
	}
}

// corrected is the bot's own 0xB023: the server put it there.
func (w *walker) corrected(s session.MoveStop) {
	w.mu.Lock()
	w.x, w.z, w.region = float64(s.X), float64(s.Z), s.Region
	w.rx, w.ry = worldmap.RegionXY(int(s.Region))
	w.sent = nil
	w.mu.Unlock()
	w.b.sw.st.corrections.Add(1)
}

// observer decodes the players spawned to one bot, as a client would read
// them, so the run can say what an onlooker sees: each player's worn items
// and pluses (the 0x3015 / group spawn records, and 0x3038 changes).
type observer struct {
	mu      sync.Mutex
	group   []byte
	inGroup bool
	players map[uint32]pcspawn.Record
	equips  int
	decErrs int
	cat     *catalogue
}

func (o *observer) frame(op uint16, data []byte) {
	o.mu.Lock()
	defer o.mu.Unlock()
	switch op {
	case npcspawn.OpSingleSpawn:
		if rec, _, err := pcspawn.Decode(data, nil); err == nil {
			o.players[rec.UID] = rec
		} else {
			o.decErrs++
		}
	case npcspawn.OpGroupBegin:
		o.group, o.inGroup = append(o.group[:0], data...), len(data) == 3 && data[0] == npcspawn.GroupSpawn
	case npcspawn.OpGroupData:
		if o.inGroup {
			o.group = append(o.group, data...)
		}
	case npcspawn.OpGroupEnd:
		if !o.inGroup || len(o.group) < 3 {
			return
		}
		n := int(o.group[1]) | int(o.group[2])<<8
		body := o.group[3:]
		for i := 0; i < n; i++ {
			rec, rest, err := pcspawn.Decode(body, nil)
			if err != nil {
				o.decErrs++
				break // an NPC's group, or a form OpenSRO does not write
			}
			o.players[rec.UID] = rec
			body = rest
		}
		o.inGroup = false
	case session.OpEquipBroadcast:
		o.equips++
	}
}

// observes is what the observer decodes.
func observes(op uint16) bool {
	switch op {
	case npcspawn.OpSingleSpawn, npcspawn.OpGroupBegin, npcspawn.OpGroupData, npcspawn.OpGroupEnd, session.OpEquipBroadcast:
		return true
	}
	return false
}

// census is what the observer has seen.
type census struct {
	Players, WithGear, Plus3, Plus8, MaxPlus int
	Seals                                    map[string]int
	Equips, DecodeErrors                     int
	Sample                                   string
}

func (o *observer) census() census {
	o.mu.Lock()
	defer o.mu.Unlock()
	c := census{Players: len(o.players), Seals: map[string]int{}, Equips: o.equips, DecodeErrors: o.decErrs}
	for _, r := range o.players {
		if len(r.Items) == 0 {
			continue
		}
		c.WithGear++
		best := 0
		for _, it := range r.Items {
			gi, ok := o.cat.byID[int64(it.RefItemID)]
			if !ok || !(gi.isWeapon || gi.isShield) {
				continue // the glow counts are the weapon's and the shield's
			}
			best = max(best, int(it.Plus))
			if gi.isWeapon {
				c.Seals[gi.Seal.String()]++
				if c.Sample == "" && it.Plus >= 8 {
					c.Sample = fmt.Sprintf("%s wears %d %s +%d", r.Name, gi.ID, gi.Code, it.Plus)
				}
			}
		}
		if best >= 3 {
			c.Plus3++
		}
		if best >= 8 {
			c.Plus8++
		}
		c.MaxPlus = max(c.MaxPlus, best)
	}
	return c
}
