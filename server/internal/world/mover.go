package world

import (
	"math"
	"sync/atomic"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
)

// Moving by destination (round 749, docs/protocol/crowd_scale.md C3).
//
// READ (docs/protocol/opcodes/movement.md, "0xB021 in full"): retail's client
// sends one 0x7021 per accepted click, the server answers it with one 0xB021
// to the 3 x 3 blocks, the mover included, and then steps the mover itself
// (CGObjMoverByDest::vslot_003, 0x48c4e0) and refiles it in its message block
// as it walks. Nothing is sent per step and nothing on arrival.
//
// OURS: OpenSRO's server has no navigation mesh for players (round 744), so it
// does not step them. It keeps each mover's leg -- where it started, where it
// goes, when, how fast -- and computes the position the leg gives at any
// moment (Mover.At). Every copy the hub hands out carries that position, so a
// range check, a monster's chase, a pick-up's reach or a spawn record reads
// where the character is now, not where its last message left it. A periodic
// pass (AdvanceMovers) refiles the movers whose position crossed a block line,
// which the spawn and despawn messages follow, and settles the ones that
// arrived. A wall that stops the walk is the client's to report (session's
// stop report); the hub takes the position the report gives (StopAt).

// Mover is one character's leg in progress. A Mover is never changed once the
// hub has published it on an entity: a change replaces the pointer, so a copy
// of an Entity read under the lock stays valid after it.
type Mover struct {
	// Src is where the leg starts, at Start.
	Src Position
	// Dest is the destination form's point (Heading false).
	Dest Position
	// Heading is the heading form: no point, a direction (DirX, DirZ) the
	// character runs along until something stops it (round 653's sky run;
	// READ, CGObjMoverByCmd steps while the command's bit 0 is set).
	Heading    bool
	DirX, DirZ float64
	// Command and WireAngle are the heading form's own bytes, kept for the
	// spawn record of a character still running (0x48be00's no-destination
	// branch writes the mover's +0x168 and +0x164).
	Command   byte
	WireAngle uint16
	// Start is when the leg began; Speed is units a second.
	Start time.Time
	Speed float64
	// dist is the destination form's ground length.
	dist float64
	// Wall is MoveOrder.Wall.
	Wall bool
	// Origin is where the leg's line was last given a height the server's
	// own walk settled (round 822, OURS: GroundFunc): Src when the leg
	// began or turned; a speed re-base moves Src along the same line and
	// keeps it. The height the leg has the character at now is found by
	// walking from here (Hub.walkedLocked). The zero Position: Src.
	Origin Position
	// A heading run's walk (round 857): walked says the server's navigation
	// mesh walks the run (a WallFunc is installed); clear is how far along
	// it from Src the walk has found no wall, clearY the walked height
	// there, and wallAt (with Wall and Dest) where the first wall stops it
	// (+Inf: none found yet). The run never goes past clear: an unwalked
	// stretch holds it until Hub.WalkHeadingRuns walks on.
	walked bool
	clear  float64
	clearY float64
	wallAt float64
}

// WallFunc walks a mover from `from` (its height the walk's footing) along
// the ground direction (dirX, dirZ) for length units on the server's
// navigation mesh (round 857, session.SetNavmesh): the point reached and its
// height, and whether a wall stopped it there. ok false where nothing can be
// walked (no mesh, a dungeon): the run goes on unwalked.
type WallFunc func(zone string, from Position, dirX, dirZ, length float64) (end Position, wall, ok bool)

var wallFunc atomic.Pointer[WallFunc]

// SetWallFunc installs f (nil: none). Without one a heading run is a straight
// line until something else stops it, as before round 857.
func SetWallFunc(f WallFunc) {
	if f == nil {
		wallFunc.Store(nil)
		return
	}
	wallFunc.Store(&f)
}

// HeadingWalkSeconds and HeadingWalkMin are how much of a heading run the
// server walks at a time (OURS, round 857): that many seconds of run, at
// least that many units; a run with less than half of it walked ahead is
// walked on by the mover pass (Hub.WalkHeadingRuns, every 250 ms).
const (
	HeadingWalkSeconds = 2.0
	HeadingWalkMin     = 20.0
)

// headingSpan is how far the run may go at now: the time's run, cut at the
// walked stretch (and the wall).
func (m *Mover) headingSpan(now time.Time) (d float64, atWall bool) {
	t := now.Sub(m.Start).Seconds()
	if t < 0 {
		t = 0
	}
	d = m.Speed * t
	if !m.walked {
		return d, false
	}
	if d >= m.wallAt {
		return m.wallAt, true
	}
	if d > m.clear {
		d = m.clear
	}
	return d, false
}

// GroundFunc is the height a mover walking from `from` straight to world
// (x, z) in zone arrives at on the server's navigation mesh, carrying its
// footing (a deck, the terrain under it) as the client's walk does; ok false
// where none was walked (round 822, OURS: session.SetNavmesh installs it).
type GroundFunc func(zone string, from Position, x, z float64) (y float64, ok bool)

var groundFunc atomic.Pointer[GroundFunc]

// SetGroundFunc installs f (nil: none). Without one every leg's height is the
// straight line Mover.At gives, as before round 822.
func SetGroundFunc(f GroundFunc) {
	if f == nil {
		groundFunc.Store(nil)
		return
	}
	groundFunc.Store(&f)
}

// LegGround is the height e's leg has it at now, walked from the leg's origin
// to e.Pos (GroundFunc); ok false with no leg or no GroundFunc. e is a copy
// the hub handed out (its Pos the leg's point now). Round 822: Mover.At's
// height is a guess -- a heading run keeps its start's height for the whole
// run, a destination leg runs a straight line to the clicked height -- and a
// guess more than SurfaceReachUp under a bridge deck seeded the server's walk
// on the river bed under it (MEASURED: Jangan west, 97/165's bridge), whose
// wall stop then put the player there.
func LegGround(e Entity) (float64, bool) {
	f := groundFunc.Load()
	if f == nil || e.Move == nil {
		return 0, false
	}
	from := e.Move.Origin
	if from == (Position{}) {
		from = e.Move.Src
	}
	return (*f)(e.Zone, from, e.Pos.X, e.Pos.Z)
}

// At is the position the leg gives at now: Src plus the travel direction times
// Speed x the time since Start, cut at Dest -- a retail mover never passes its
// destination (CGObjMoverByDest::vslot_003 replaces a step longer than what is
// left with dest - position, READ). arrived reports a destination leg that has
// reached its point. The height is interpolated along the leg: the server has
// no ground to take it from (OURS).
func (m *Mover) At(now time.Time) (pos Position, arrived bool) {
	if m.Heading {
		// Round 857: the run stops at the first wall the server's own walk
		// meets (READ: CGObjMoverByCmd's step goes through slot 305 to the
		// collision query like every mover's, and a blocking edge ends the
		// movement, movement.md "Collision per kind of mover").
		d, atWall := m.headingSpan(now)
		if atWall {
			return m.Dest, true
		}
		return Position{X: m.Src.X + m.DirX*d, Y: m.Src.Y, Z: m.Src.Z + m.DirZ*d}, false
	}
	t := now.Sub(m.Start).Seconds()
	if t < 0 {
		t = 0
	}
	d := m.Speed * t
	if d >= m.dist || m.dist <= 0 {
		return m.Dest, true
	}
	f := d / m.dist
	return Position{
		X: m.Src.X + (m.Dest.X-m.Src.X)*f,
		Y: m.Src.Y + (m.Dest.Y-m.Src.Y)*f,
		Z: m.Src.Z + (m.Dest.Z-m.Src.Z)*f,
	}, false
}

// Travelled is how far along the leg the character is at now.
func (m *Mover) Travelled(now time.Time) float64 {
	if m.Heading {
		d, _ := m.headingSpan(now)
		return d
	}
	t := now.Sub(m.Start).Seconds()
	if t < 0 {
		t = 0
	}
	d := m.Speed * t
	if !m.Heading && d > m.dist {
		return m.dist
	}
	return d
}

// Length is the destination leg's ground length (+Inf for a heading run).
func (m *Mover) Length() float64 {
	if m.Heading {
		if m.walked {
			return m.wallAt
		}
		return math.Inf(1)
	}
	return m.dist
}

// Along projects the ground point (x, z) onto the leg: how far along it the
// nearest point of the leg lies (clamped to [0, Length]) and how far (x, z)
// is from that point.
func (m *Mover) Along(x, z float64) (along, off float64) {
	dx, dz := m.DirX, m.DirZ
	if !m.Heading {
		if m.dist <= 0 {
			return 0, math.Hypot(x-m.Src.X, z-m.Src.Z)
		}
		dx, dz = (m.Dest.X-m.Src.X)/m.dist, (m.Dest.Z-m.Src.Z)/m.dist
	}
	px, pz := x-m.Src.X, z-m.Src.Z
	along = px*dx + pz*dz
	if along < 0 {
		along = 0
	}
	if l := m.Length(); along > l {
		along = l
	}
	return along, math.Hypot(px-dx*along, pz-dz*along)
}

// MoveOrder is an accepted 0x7021 as the hub needs it: the destination (or
// the heading form) and the speed the leg runs at.
type MoveOrder struct {
	Dest Position
	// Heading is the heading form; HeadingRadians is the character's heading
	// (HeadingFromWire of the wire angle), Command and WireAngle the form's
	// bytes.
	Heading        bool
	HeadingRadians float64
	Command        byte
	WireAngle      uint16
	Speed          float64
	// SrcY, with HasSrcY, is the height the leg starts at (round 822: the
	// walked height, LegGround, in place of the guess the leg in progress or
	// the trusted point carries).
	SrcY    float64
	HasSrcY bool
	// Wall: Dest is where the server's navigation mesh stops the walk short
	// of the client's destination (round 812, session.navWalk): its arrival
	// ends the leg with a 0xB023 to the window, as the original server's
	// mover stopped by a blocking edge sends one (READ, movement.md).
	Wall bool
}

// MoveStatus is what StartMove did.
type MoveStatus int

const (
	// MoveAccepted: the leg is the character's now.
	MoveAccepted MoveStatus = iota
	// MoveNotInWorld: the session has no character in the world.
	MoveNotInWorld
	// MoveRefusedNear: a destination within NearDestination of the one the
	// character is already walking to (READ, GObjPC::FUN_004b0ea0's last gate,
	// 0xb45b28 = 5.0). Refused silently.
	MoveRefusedNear
)

// NearDestination is the 0x7021 handler's "same destination" distance: while
// the character moves, a new destination within it of the current one is
// refused (READ, 0xb45b28).
const NearDestination = 5.0

// SetClock replaces the hub's clock (tests and the crowd bench: a simulated
// second). Nil restores time.Now.
func (h *Hub) SetClock(f func() time.Time) {
	if f == nil {
		f = time.Now
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	h.clock = f
}

// outLocked is e as the hub hands it out at now: its position the leg gives,
// and no Mover once the leg has arrived. Caller holds h.mu.
func outLocked(e *Entity, now time.Time) Entity {
	c := *e
	if m := e.Move; m != nil {
		p, arrived := m.At(now)
		c.Pos = p
		if arrived {
			c.Move = nil
		}
	}
	return c
}

// settleLocked brings e's stored position up to now: a leg that has arrived
// ends at its destination, which is then the trusted point; one still running
// leaves e.Pos at its current point (the leg itself is unchanged). The
// movement allowance is brought up to now first (claim.go). Caller holds h.mu
// for writing.
func (h *Hub) settleLocked(e *Entity, now time.Time) {
	accrueLocked(e, now)
	m := e.Move
	if m == nil {
		return
	}
	p, arrived := m.At(now)
	e.Pos = p
	if arrived {
		e.Move = nil
		e.Trusted = m.Dest
		e.allowLeg = 0
		delete(h.moving, e.Session.ID())
	}
}

// endMoveLocked ends e's leg at its stored position, which the server fixed:
// it is the trusted point now. Caller has settled e.
func (h *Hub) endMoveLocked(e *Entity) {
	if e.Move != nil {
		e.Trusted = e.Pos
	}
	e.Move = nil
	e.allowLeg = 0
	delete(h.moving, e.Session.ID())
}

// refileLocked files e under the block its stored position is in and fills
// r's crossing (Gained, Lost) and recipients (Watchers) for that position.
// Caller holds h.mu for writing.
func (h *Hub) refileLocked(e *Entity, now time.Time, r *MoveResult) {
	old := e.Cell
	cell := CellOf(e.Zone, e.Pos)
	if cell != old {
		h.uncellLocked(e)
		e.Cell = cell
		h.cellLocked(e)
		// A held character (Entity.Held) is in no window: its move gains
		// and loses nobody.
		if !e.Held {
			r.Crossed = true
			h.crossingLocked(e, old, cell, now, r)
		}
	}
	r.Watchers = make([]Watcher, 0, h.windowCountLocked(cell))
	h.forWindowLocked(cell, func(o *Entity) {
		if o != e {
			r.Watchers = append(r.Watchers, Watcher{Session: o.Session, CharacterID: o.CharacterID})
		}
	})
}

// crossingLocked fills r's Gained and Lost for e's move from block old to
// block cell. Caller holds h.mu (a read lock will do).
func (h *Hub) crossingLocked(e *Entity, old, cell combat.Cell, now time.Time, r *MoveResult) {
	h.forWindowLocked(old, func(o *Entity) {
		if o != e && !InView(cell, o.Cell) {
			r.Lost = append(r.Lost, outLocked(o, now))
		}
	})
	h.forWindowLocked(cell, func(o *Entity) {
		if o != e && !InView(old, o.Cell) {
			r.Gained = append(r.Gained, outLocked(o, now))
		}
	})
}

// StartMove gives sess's character the leg o asks for, starting where its
// current leg has it now or, standing, at its trusted point (round 749's
// review, F1: a leg never starts from a client's claim). The result's Entity
// stands at that start (Pos) with the new leg (Move); its Watchers are the
// other players in view there, who are sent the 0xB021; a start in another
// block than the one the character was filed under carries the crossing.
func (h *Hub) StartMove(sess *gateway.Session, o MoveOrder) (MoveResult, MoveStatus) {
	h.mu.Lock()
	defer h.mu.Unlock()
	now := h.clock()
	e, ok := h.bySession[sess.ID()]
	if !ok {
		return MoveResult{}, MoveNotInWorld
	}
	if cur := e.Move; cur != nil && !o.Heading && !cur.Heading {
		if _, arrived := cur.At(now); !arrived && math.Hypot(o.Dest.X-cur.Dest.X, o.Dest.Z-cur.Dest.Z) <= NearDestination {
			return MoveResult{}, MoveRefusedNear
		}
	}
	// Round 749's verification, FP5: the standing time before a first walk is
	// banked at this speed, as a claim's is (Claim).
	if e.allowSpeed == 0 {
		e.allowSpeed = o.Speed
	}
	h.settleLocked(e, now)
	if e.Move == nil {
		e.Pos = e.Trusted
	}
	if o.HasSrcY {
		e.Pos.Y = o.SrcY
	}
	m := &Mover{Src: e.Pos, Origin: e.Pos, Start: now, Speed: o.Speed}
	if o.Heading {
		m.Heading = true
		m.DirX, m.DirZ = math.Sin(o.HeadingRadians), math.Cos(o.HeadingRadians)
		m.Command, m.WireAngle = o.Command, o.WireAngle
		m.startWalk()
		e.Heading = o.HeadingRadians
	} else {
		m.Dest = o.Dest
		m.Wall = o.Wall
		m.dist = math.Hypot(o.Dest.X-e.Pos.X, o.Dest.Z-e.Pos.Z)
		e.noteClientY(o.Dest.X, o.Dest.Y, o.Dest.Z) // the clicked ground's height
		e.Heading = HeadingToward(e.Heading, o.Dest.X-e.Pos.X, o.Dest.Z-e.Pos.Z)
	}
	e.Move = m
	e.allowLeg, e.allowSpeed = 0, o.Speed
	h.moving[sess.ID()] = e
	var r MoveResult
	h.refileLocked(e, now, &r)
	r.Entity = *e
	return r, MoveAccepted
}

// StopAt puts sess's character at pos and ends any leg: a placement the
// server itself makes (Relocate: a skill's move, a GM's, a test's), which
// becomes the trusted point. admit, when not nil, is shown the character as
// it stands now and may refuse (nothing changes; admitted false). ok is false
// when the session is not in the world. A client's claim goes through Claim.
func (h *Hub) StopAt(sess *gateway.Session, pos Position, kind MoveKind, heading float64, admit func(now time.Time, cur Entity) bool) (r MoveResult, admitted, ok bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	now := h.clock()
	e, exists := h.bySession[sess.ID()]
	if !exists {
		return MoveResult{}, false, false
	}
	if admit != nil && !admit(now, outLocked(e, now)) {
		r.Entity = outLocked(e, now)
		return r, false, true
	}
	h.placeLocked(e, now, pos, kind, heading, &r)
	e.Trusted = pos
	e.clientYKnown = false // the server's placement: its height is a guess
	r.Entity.Trusted = pos
	return r, true, true
}

// placeLocked ends e's leg and puts it at pos, turned as kind says, refiled.
func (h *Hub) placeLocked(e *Entity, now time.Time, pos Position, kind MoveKind, heading float64, r *MoveResult) {
	// The heading of a walk is measured from where the leg had the character.
	h.settleLocked(e, now)
	h.endMoveLocked(e)
	switch kind {
	case MoveWalk:
		e.Heading = HeadingToward(e.Heading, pos.X-e.Pos.X, pos.Z-e.Pos.Z)
	case MoveHeading:
		e.Heading = heading
	}
	e.Pos = pos
	h.refileLocked(e, now, r)
	r.Entity = *e
}

// HeadingRunLimit is how long the server lets a heading run go before it ends
// it (round 749's review, F10; OURS): retail's run has no end but a wall,
// which OpenSRO's server cannot see, so a run whose client died or went quiet
// would cross the map. A minute of running is 3,000 units at the base speed;
// a live client whose run lasts longer is stopped there (0xB023).
const HeadingRunLimit = 60 * time.Second

// Pass is what one AdvanceMovers did: the crossings (Gained and Lost; no
// Watchers -- the crossing's deliveries need none) and the heading runs it
// ended at HeadingRunLimit and the legs a wall ended (round 812), with
// Watchers, for their 0xB023.
type Pass struct {
	Crossings []MoveResult
	Ended     []MoveResult
	// Moved is every character the pass settled, as it stands now -- one
	// whose leg arrived in this pass included (round 773: the walk-in
	// zones are tested along each mover's path, session/walkin.go).
	Moved []Entity
}

// AdvanceMovers is the periodic pass over the characters with a leg: each
// one's stored position is brought up to now, a leg that arrived ends, a
// heading run past HeadingRunLimit ends, and the ones whose position crossed
// into another block are refiled. speedOf, when not nil, is each mover's run
// speed now: a leg whose speed changed (a buff, a GM's /speed) is re-based at
// it from where it stands. It is called before the write lock is taken.
//
// Round 749's review, F7: the write lock covers only the settling and the
// refiling; the crossings' Gained and Lost are read afterwards under the read
// lock, and no recipient list is built for a crossing (its deliveries read
// their own windows).
func (h *Hub) AdvanceMovers(speedOf func(characterID int64) float64) Pass {
	var speeds map[int64]float64
	if speedOf != nil {
		h.mu.RLock()
		ids := make([]int64, 0, len(h.moving))
		for _, e := range h.moving {
			ids = append(ids, e.CharacterID)
		}
		h.mu.RUnlock()
		speeds = make(map[int64]float64, len(ids))
		for _, id := range ids {
			speeds[id] = speedOf(id)
		}
	}
	type crossing struct {
		e         *Entity
		old, cell combat.Cell
	}
	var crossed []crossing
	var ended []*Entity
	var out Pass
	h.mu.Lock()
	held := time.Now()
	now := h.clock()
	out.Moved = make([]Entity, 0, len(h.moving))
	for _, e := range h.moving {
		wall := e.Move != nil && e.Move.Wall
		h.settleLocked(e, now)
		if wall && e.Move == nil {
			ended = append(ended, e) // stopped at the wall (round 812)
		}
		out.Moved = append(out.Moved, outLocked(e, now))
		if m := e.Move; m != nil {
			if s := speeds[e.CharacterID]; s > 0 {
				rebaseLocked(e, now, s)
			}
			if m.Heading && now.Sub(m.Start) >= HeadingRunLimit {
				h.endMoveLocked(e)
				ended = append(ended, e)
			}
		}
		if cell := CellOf(e.Zone, e.Pos); cell != e.Cell {
			old := e.Cell
			h.uncellLocked(e)
			e.Cell = cell
			h.cellLocked(e)
			if !e.Held {
				crossed = append(crossed, crossing{e, old, cell})
			}
		}
	}
	h.passHold.Store(int64(time.Since(held)))
	h.mu.Unlock()

	if len(crossed) == 0 && len(ended) == 0 {
		return out
	}
	h.mu.RLock()
	defer h.mu.RUnlock()
	for _, c := range crossed {
		if h.bySession[c.e.Session.ID()] != c.e {
			continue // left meanwhile
		}
		r := MoveResult{Crossed: true, Entity: outLocked(c.e, now)}
		h.crossingLocked(c.e, c.old, c.cell, now, &r)
		out.Crossings = append(out.Crossings, r)
	}
	for _, e := range ended {
		if h.bySession[e.Session.ID()] != e {
			continue
		}
		r := MoveResult{Entity: outLocked(e, now)}
		h.forWindowLocked(e.Cell, func(o *Entity) {
			if o != e {
				r.Watchers = append(r.Watchers, Watcher{Session: o.Session, CharacterID: o.CharacterID})
			}
		})
		out.Ended = append(out.Ended, r)
	}
	return out
}

// Moving reports how many characters have a leg (the pass's work).
func (h *Hub) Moving() int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(h.moving)
}

// rebaseLocked restarts e's leg at speed from where it stands now: a buff or
// a GM's /speed changed its run speed mid-walk. Caller holds h.mu for writing
// and has settled e (so the allowance has been brought up to now).
func rebaseLocked(e *Entity, now time.Time, speed float64) {
	if e.Move == nil || e.Move.Speed == speed {
		return
	}
	m := *e.Move
	gone := m.Travelled(now)
	m.Src, m.Start, m.Speed = e.Pos, now, speed
	if !m.Heading {
		m.dist = math.Hypot(m.Dest.X-m.Src.X, m.Dest.Z-m.Src.Z)
	} else if m.walked {
		// The walked stretch and the wall are measured from Src (round 857).
		m.clear -= gone
		m.wallAt -= gone
	}
	e.Move = &m
	e.allowLeg, e.allowSpeed = 0, speed
}

// Halt ends sess's character's leg where the leg has it now -- a stop the
// server makes itself (a sit, a death, a state) -- and refiles it. A
// character with no leg is left where it stands. ok is false when the session
// is not in the world; moved says it had a leg. Round 822: the stop stands at
// the leg's walked height (LegGround), not the straight line's.
func (h *Hub) Halt(sess *gateway.Session) (r MoveResult, moved, ok bool) {
	leg, y, walked := h.walkedNow(sess)
	h.mu.Lock()
	defer h.mu.Unlock()
	now := h.clock()
	e, exists := h.bySession[sess.ID()]
	if !exists {
		return MoveResult{}, false, false
	}
	moved = e.Move != nil
	same := walked && e.Move == leg
	h.settleLocked(e, now)
	h.endMoveLocked(e)
	if same {
		e.Pos.Y, e.Trusted.Y = y, y
	}
	h.refileLocked(e, now, &r)
	r.Entity = *e
	return r, moved, true
}

// walkedNow is sess's character's leg and the height it has the character at
// now (LegGround), walked outside the hub's lock; walked false with no leg or
// no GroundFunc. A caller applies the height only while the leg is still that
// one (a Mover is replaced, never changed, so the pointer says).
func (h *Hub) walkedNow(sess *gateway.Session) (leg *Mover, y float64, walked bool) {
	if groundFunc.Load() == nil {
		return nil, 0, false
	}
	h.mu.RLock()
	e, exists := h.bySession[sess.ID()]
	var c Entity
	if exists {
		c = outLocked(e, h.clock())
	}
	h.mu.RUnlock()
	if !exists || c.Move == nil {
		return nil, 0, false
	}
	y, walked = LegGround(c)
	return c.Move, y, walked
}

// Turn sets sess's character's heading -- an arrow key's 0x7024 (round 808;
// READ s:0x4b1360 -> slot 0x4b8 -> the current mover's vslot_005) -- and a
// heading run in progress goes on from where it has the character, along the
// new heading (CGObjMoverByCmd::vslot_005 sets the angle and keeps the
// command's forward bit). A walk to a point keeps its leg (INFERRED: the
// destination mover's vslot_005 is not read, and the retail client sends no
// turn during one). ok is false when the session is not in the world.
func (h *Hub) Turn(sess *gateway.Session, heading float64, wire uint16) (e Entity, ok bool) {
	leg, y, walked := h.walkedNow(sess)
	h.mu.Lock()
	defer h.mu.Unlock()
	now := h.clock()
	ent, exists := h.bySession[sess.ID()]
	if !exists {
		return Entity{}, false
	}
	same := walked && ent.Move == leg
	h.settleLocked(ent, now)
	ent.Heading = heading
	if m := ent.Move; m != nil && m.Heading {
		// Round 822: the run goes on from its walked height (LegGround).
		if same {
			ent.Pos.Y = y
		}
		n := *m
		n.Src, n.Origin, n.Start = ent.Pos, ent.Pos, now
		n.DirX, n.DirZ = math.Sin(heading), math.Cos(heading)
		n.WireAngle = wire
		n.startWalk()
		ent.Move = &n
		ent.allowLeg, ent.allowSpeed = 0, n.Speed
	}
	return outLocked(ent, now), true
}

// Correct puts sess's character back where the server has it -- its leg's
// point now, or its trusted point -- after a claim it refused (round 749's
// review, F1): the leg ends and the stored position is the trusted one.
func (h *Hub) Correct(sess *gateway.Session) (r MoveResult, ok bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	now := h.clock()
	e, exists := h.bySession[sess.ID()]
	if !exists {
		return MoveResult{}, false
	}
	h.settleLocked(e, now)
	h.endMoveLocked(e)
	e.Pos = e.Trusted
	h.refileLocked(e, now, &r)
	r.Entity = *e
	return r, true
}

// startWalk readies a new heading run for the server's walk (round 857): with
// a WallFunc installed nothing of it is walked yet, so it holds at Src until
// Hub.WalkHeadingRuns walks it (the session does at once, WalkHeadingRun).
func (m *Mover) startWalk() {
	if wallFunc.Load() == nil {
		return
	}
	m.walked, m.clear, m.clearY, m.wallAt, m.Wall = true, 0, m.Src.Y, math.Inf(1), false
}

// headingAhead is how far ahead of the run one walk reaches at speed.
func headingAhead(speed float64) float64 {
	return math.Max(HeadingWalkMin, speed*HeadingWalkSeconds)
}

// runWalk is one heading run's walk to make: the session, the leg it is for,
// the zone, where the walked stretch ends and how far to walk on.
type runWalk struct {
	sess   *gateway.Session
	leg    *Mover
	zone   string
	from   Position
	length float64
}

// WalkHeadingRun walks sess's character's heading run on if it needs it
// (WalkHeadingRuns for one session): the session calls it right after a run
// starts or turns, so the run moves from the first pass.
func (h *Hub) WalkHeadingRun(sess *gateway.Session) {
	id := sess.ID()
	h.walkRuns(func(e *Entity) bool { return e.Session.ID() == id })
}

// WalkHeadingRuns walks every heading run whose walked stretch ends less than
// half a walk ahead of it (round 857): each is walked on from where its walked
// stretch ends, outside the hub's lock, and its leg takes the result if it is
// still the same leg; a wall the walk meets ends the run there (Mover.At), and
// the pass that finds it there sends the 0xB023 (AdvanceMovers' Ended, as for
// a destination leg's wall).
func (h *Hub) WalkHeadingRuns() { h.walkRuns(nil) }

func (h *Hub) walkRuns(only func(e *Entity) bool) {
	f := wallFunc.Load()
	if f == nil {
		return
	}
	for pass := 0; pass < 4; pass++ {
		h.mu.RLock()
		now := h.clock()
		var todo []runWalk
		for _, e := range h.moving {
			m := e.Move
			if m == nil || !m.Heading || !m.walked || !math.IsInf(m.wallAt, 1) {
				continue
			}
			if only != nil && !only(e) {
				continue
			}
			ahead := headingAhead(m.Speed)
			if m.clear-m.Travelled(now) >= ahead/2 {
				continue
			}
			from := Position{X: m.Src.X + m.DirX*m.clear, Y: m.clearY, Z: m.Src.Z + m.DirZ*m.clear}
			todo = append(todo, runWalk{e.Session, m, e.Zone, from, ahead})
		}
		h.mu.RUnlock()
		if len(todo) == 0 {
			return
		}
		for _, w := range todo {
			end, wall, ok := (*f)(w.zone, w.from, w.leg.DirX, w.leg.DirZ, w.length)
			h.mu.Lock()
			if e, exists := h.bySession[w.sess.ID()]; exists && e.Move == w.leg {
				n := *w.leg
				switch {
				case !ok:
					n.walked = false // nothing to walk here: straight, as before
				case wall:
					n.wallAt = n.clear + math.Hypot(end.X-w.from.X, end.Z-w.from.Z)
					n.Dest, n.Wall = end, true
				default:
					n.clear += w.length
					n.clearY = end.Y
				}
				e.Move = &n
			}
			h.mu.Unlock()
		}
	}
}
