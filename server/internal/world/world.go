// Package world tracks which characters are currently "in the game world"
// (as opposed to just logged in / at character select): their position,
// zone, and who else is nearby. Own design — there's no original data to
// be informed by here the way account/character had DB facts to draw on;
// this is just what a minimal multiplayer position-sync system needs.
//
// Deliberately in-memory only, unlike account/character's SQLite stores —
// live position data resetting on a server restart is normal for an MMO,
// not a bug to fix. Where a character last stood is kept on its character
// row instead, under cmd/server's -persist-position (round 573,
// session/position.go), and read back when it enters the world again.
package world

import (
	"sync"
	"sync/atomic"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
)

// Position is a point in 3D space. Units are arbitrary at this stage — no
// real map data exists yet to calibrate against.
type Position struct {
	X, Y, Z float64
}

// LifeState is the engine's life-state byte as OpenSRO keeps it: chardata[0],
// read through IGObj::GetLifeState (vtable +0xf8) and written only through
// IGObj::SetLifeState (+0x1f0) -- docs/protocol/character_state.md, "The life
// state, and the siege revive countdown (round 411)" through "Life-state 2 is
// the character's DEAD state, closed with a typed receiver (round 413)". Only
// the two character values are modelled here; 3 ("removed from the world")
// and the unread 4 and 6 are not. Kept in memory with the position, as the
// engine keeps it on the PC object (round 549).
type LifeState uint8

const (
	// LifeAlive is 1: the engine's own ALIVE, the value every "must be
	// alive" guard wants (GUILDERR_IM_DEAD and 0x6807 on GetLifeState() != 1).
	LifeAlive LifeState = 1
	// LifeDead is 2: the character's DEAD state (round 413). The retail
	// resurrect request acts only here (GObjPC_HandleResurrectMsg_053,
	// `cmp al,0x2` at 0x510077) and GObjPC::Revive (0x4df290) is what leaves
	// it, passing 1 through SetLifeState.
	LifeDead LifeState = 2
)

// Entity is one character currently present in the world.
type Entity struct {
	Session     *gateway.Session
	CharacterID int64
	Name        string
	// Zone is the bucket the entity is kept and broadcast in: everyone in it
	// hears its moves, and its monsters, chat and ground items are the
	// bucket's. It is the zone label the client asked for, except under
	// cmd/server's -single-frame (round 571), where every label with a frame
	// shares worldmap.WorldBucket (session.ZoneBucket) and the label is only
	// the client's grid-centre hint, never stored here.
	Zone string
	Pos  Position
	// Life is the character's life state, LifeAlive from Enter until a
	// monster's killing blow sets LifeDead (session/monsterstrike.go, behind
	// -player-dead-state) and a revive sets LifeAlive again.
	Life LifeState
	// DiedAt is when Life last became LifeDead (a failed revive puts it back
	// with the state); the zero time while alive. Round 549's auto-revive
	// read it; round 665 removed that fallback.
	DiedAt time.Time
	// Level is the character's level as the character store holds it, cached
	// here so the monster AI reads it off the entity instead of the store on
	// its tick and on its strike workers (round 555; until then
	// session/monsterai.go's linkAggro made one character.Store.GetByID per
	// link event under the tick's lock, and runStrike one per swing). Set from
	// the row at Enter and moved by SetLevel where a level changes: every
	// level-up path, gm's /level and, since round 874, a death penalty that
	// takes a level away (session/levelloss.go; GObjPC_GainExpAndLevel's
	// negative branch drops one level, READ s:0x4e569c). A stat-point spend
	// keeps it (session/stats.go).
	Level int
	// Arrival numbers the entity's arrivals in the world: a fresh value from
	// the hub on every Enter and ChangeZone (a teleport included, whatever
	// bucket it lands in), never reused. Round 622's review: a cast's
	// delayed act is dropped when its caster has arrived anew since the
	// cast started (session.announceCast).
	Arrival uint64
	// Heading is the way the character faces, the client's heading (+0x8c,
	// radians in [0, 2 pi); HeadingToward has the frame), kept from the
	// direction of its last walk (Relocate with MoveWalk) and carried through a zone
	// change, so the zone it arrives in sees it facing that way (round 637's
	// review follow-up; OpEntityEntered's trailing wire angle). 0 until the
	// character first moves: a heading is not saved with the position.
	Heading float64
	// Cell is the message block the entity stands in (combat.CellOf of Pos
	// in Zone), kept by the hub as Pos changes (round 737): the players in
	// view are those of the ViewRadius window of blocks around it. A
	// character with a leg is refiled by AdvanceMovers (round 749).
	Cell combat.Cell
	// Move is the character's leg in progress, nil when it stands (round
	// 749, mover.go). Every Entity the hub hands out carries the leg's
	// position at that moment in Pos.
	Move *Mover
	// Trusted is the last point the server itself fixed for the character
	// (round 749's review, F1; claim.go): an arrival, a placement it made, the
	// end of a leg, a correction. A client's stop or placement is measured
	// from it (or from the leg), never from the client's previous claim, so
	// claims cannot creep. While a leg runs, the leg is the reference.
	Trusted Position
	// Held is true while the character is out of the world between an
	// arrival and its client's loading-done report (round 786, OURS
	// mechanism for retail's re-entry: SR_GameServer's teleport takes the PC
	// out of the world and CGObj::EnterWorld puts it back only on the
	// client's 0x3012; session/arrival.go). A held entity is in every index
	// but the message blocks (byCell), so no other player's window holds it,
	// no crossing spawns it, and Sees is false; the monster AI skips it.
	// EnterHeld and ChangeZoneHeld set it, Release clears it.
	Held bool
	// The movement allowance (claim.go): units of run banked while standing,
	// at most AllowanceSeconds' worth, that a claim beyond the free slack
	// draws from. allowAt is when it was last brought up to date, allowLeg
	// how far the current leg had gone then, allowSpeed the run speed it
	// accrues at.
	allow, allowLeg, allowSpeed float64
	allowAt                     time.Time
	// The last height the CLIENT gave (a taken claim's, a 0x7021
	// destination's) and where (round 749's verification, FP1-FP3): a claim's
	// or a destination's height is bounded from it, never from a height the
	// server only guesses (an arrival's, a leg's straight line, a run's
	// start). clientYKnown is false until the client gives one, and again
	// after a placement the server makes.
	clientY      float64
	clientYX     float64
	clientYZ     float64
	clientYKnown bool
}

// ViewRadius is how many message blocks around its own a player sees other
// players in: 1, the 3 x 3 window of retail's 320-unit blocks (READ, round
// 664; docs/protocol/crowd_scale.md section 1, "The server": CMsgBlock links
// every block to its 8 neighbours, and an object put in a block is sent to,
// and sent, the objects of those nine). The same window as the monsters'
// (session.AOIRadius); players got it in round 737 (crowd_scale.md C1).
const ViewRadius = 1

// CellOf is the message block a position of zone falls in: combat.CellOf,
// the monsters' own index (combat.CellSpan = 320).
func CellOf(zone string, pos Position) combat.Cell {
	return combat.CellOf(zone, pos.X, pos.Z)
}

// InView reports whether a player standing in block a sees one in block b:
// the same zone and within ViewRadius blocks on both axes. Symmetric.
func InView(a, b combat.Cell) bool {
	return a.Near(b, ViewRadius)
}

// Hub tracks all entities currently in the world, grouped by zone and, since
// round 737, by message block (combat.Cell): a player's interest area is the
// ViewRadius window of blocks around its own, and the hub answers who is in
// it without copying the zone. Safe for concurrent use.
type Hub struct {
	mu        sync.RWMutex
	byZone    map[string]map[uint64]*Entity // zone -> session ID -> entity
	bySession map[uint64]*Entity
	// byChar and byName answer the lookups by character id and by name in
	// O(1) (round 737, crowd_scale.md C4: they were scans of every session).
	// A character in the world on two sessions at once (a reconnect racing
	// the old session's leave) is filed under the later; the earlier's
	// removal leaves the later's entry alone.
	byChar map[int64]*Entity
	byName map[string]*Entity
	// byCell is every entity by the block it stands in (Entity.Cell).
	byCell map[combat.Cell]map[uint64]*Entity
	// unit is the game-world unit owning this hub (round 869,
	// internal/gameworld), nil for a bare hub.
	unit atomic.Pointer[unitBox]
	// moving is every entity with a leg (Entity.Move), by session: the
	// periodic pass's work list (round 749).
	moving map[uint64]*Entity
	clock  func() time.Time
	// passHold is how long the last AdvanceMovers held the write lock, in
	// nanoseconds (round 749's review, F7: measured by world's tests).
	passHold atomic.Int64
}

// NewHub returns an empty Hub.
func NewHub() *Hub {
	return &Hub{
		byZone:    make(map[string]map[uint64]*Entity),
		bySession: make(map[uint64]*Entity),
		byChar:    make(map[int64]*Entity),
		byName:    make(map[string]*Entity),
		byCell:    make(map[combat.Cell]map[uint64]*Entity),
		moving:    make(map[uint64]*Entity),
		clock:     time.Now,
	}
}

// Enter adds sess's character, at level, to zone at pos. If the session was
// already in the world (e.g. re-entering without a clean Leave), it's moved
// rather than duplicated. Returns a snapshot of the other entities already in
// view of pos (the ViewRadius window of blocks, round 737), for the caller to
// spawn to the arriving client and to announce the arrival to. The level
// is a parameter rather than a later SetLevel so no entity ever exists
// without one (Entity.Level).
func (h *Hub) Enter(sess *gateway.Session, characterID int64, name string, level int, zone string, pos Position) []Entity {
	return h.enter(sess, characterID, name, level, zone, pos, false)
}

// EnterHeld is Enter with the character held out of the world (Entity.Held)
// until Release: the world entry before the client's loading-done report
// (round 786, session/arrival.go).
func (h *Hub) EnterHeld(sess *gateway.Session, characterID int64, name string, level int, zone string, pos Position) []Entity {
	return h.enter(sess, characterID, name, level, zone, pos, true)
}

func (h *Hub) enter(sess *gateway.Session, characterID int64, name string, level int, zone string, pos Position, held bool) []Entity {
	h.mu.Lock()
	defer h.mu.Unlock()

	h.removeLocked(sess.ID())

	e := &Entity{Session: sess, CharacterID: characterID, Name: name, Zone: zone, Pos: pos, Life: LifeAlive, Level: level, Arrival: nextArrival(), Trusted: pos, allowAt: h.clock(), Held: held}
	h.insertLocked(e)
	sess.SetPlace(h)
	return h.viewOthersLocked(e)
}

// Release puts a held character (EnterHeld, ChangeZoneHeld) back into the
// world: filed under its block, so the players of its window see it from
// now on. It returns the entity as released and the other players in view
// of it (for its spawns, session.arrivePlayer); ok is false when the
// session is not in the world or was not held.
func (h *Hub) Release(sess *gateway.Session) (released Entity, others []Entity, ok bool) {
	if o := h.routed(sess); o != nil {
		return o.Release(sess)
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	e, exists := h.bySession[sess.ID()]
	if !exists || !e.Held {
		return Entity{}, nil, false
	}
	e.Held = false
	e.Cell = CellOf(e.Zone, e.Pos)
	h.cellLocked(e)
	return outLocked(e, h.clock()), h.viewOthersLocked(e), true
}

// Leave removes sess's character from the world, if present. Returns the
// entity that left and the sessions and characters that had it in view (to
// notify that this one left), or ok=false if the session wasn't in the
// world.
//
// Only who, not a snapshot of each (OURS, a cost fix): a disconnect in a
// crowd used to copy every entity in view, about a kilobyte each, under the
// write lock -- 2.1 ms and 8 MB a disconnect at 7,000 in one window, so a
// swarm's 3,000 dropping together held the lock for seconds (MEASURED,
// BenchmarkLeaveInCrowd; docs/WORLD_ISSUES.md, "The swarm lane's lag hunt").
func (h *Hub) Leave(sess *gateway.Session) (left Entity, remaining []Watcher, ok bool) {
	if o := h.routed(sess); o != nil {
		return o.Leave(sess)
	}
	h.mu.Lock()
	defer h.mu.Unlock()

	e, exists := h.bySession[sess.ID()]
	if !exists {
		return Entity{}, nil, false
	}
	left = outLocked(e, h.clock())
	left.Move = nil
	h.removeLocked(sess.ID())
	return left, h.watchersLocked(&left), true
}

// watchersLocked is who is in view of e's position, except e's own session.
// Caller must hold h.mu.
func (h *Hub) watchersLocked(e *Entity) []Watcher {
	if e.Held {
		return nil // nobody holds a held character (Entity.Held)
	}
	cell := CellOf(e.Zone, e.Pos)
	out := make([]Watcher, 0, h.windowCountLocked(cell))
	h.forWindowLocked(cell, func(o *Entity) {
		if o.Session.ID() != e.Session.ID() {
			out = append(out, Watcher{Session: o.Session, CharacterID: o.CharacterID})
		}
	})
	return out
}

// WatchersOf is es as Watchers.
func WatchersOf(es []Entity) []Watcher {
	out := make([]Watcher, len(es))
	for i, e := range es {
		out[i] = Watcher{Session: e.Session, CharacterID: e.CharacterID}
	}
	return out
}

// MoveKind is how a position change turns the character (Relocate).
type MoveKind int

const (
	// MoveWalk faces the way it moved (HeadingToward from the old position).
	MoveWalk MoveKind = iota
	// MoveRelocate keeps the heading: a skill's jump, a client's recovery or
	// teleport (the client's own placement, FUN_009e11e0, aims nothing).
	MoveRelocate
	// MoveHeading faces the given heading (a heading run, round 653).
	MoveHeading
)

// MoveResult is what a position change did (round 737): the entity after
// it; the other players in view of its new block (session and character),
// the move's recipients; and, when it crossed into another block, the players that came
// into view (Gained: in the new window, not the old) and went out of it
// (Lost: in the old window, not the new). Visibility is symmetric, so each of
// Gained now sees the mover and each of Lost no longer does.
// Watcher is one of a move's recipients: its session and its character.
type Watcher struct {
	Session     *gateway.Session
	CharacterID int64
}

type MoveResult struct {
	Entity   Entity
	Watchers []Watcher
	Crossed  bool
	Gained   []Entity
	Lost     []Entity
}

// Relocate moves sess's character to pos, turning it as kind says (heading
// is MoveHeading's), and refiles it under its new block. ok=false if the
// session isn't in the world.
func (h *Hub) Relocate(sess *gateway.Session, pos Position, kind MoveKind, heading float64) (MoveResult, bool) {
	// A placement ends a leg in progress (round 749, mover.go StopAt).
	r, _, ok := h.StopAt(sess, pos, kind, heading, nil)
	return r, ok
}

// ChangeZone moves sess's character to newZone at pos, the same discrete
// "leave the old zone, appear fresh in the new one" semantics as Leave
// followed by Enter, but as one atomic operation (no window where the
// character is in neither zone's byZone index). Returns the character's
// state before the move, everyone that had it in view where it was (to
// notify they left), and everyone in view where it arrives (to notify
// someone new arrived) -- or ok=false if the session wasn't in the world.
// A change to a point in view of where it was (-single-frame's warp between
// two towns of the one bucket, round 571, landing near) removes and re-adds
// it, so those players are in both lists: they hear it leave and then arrive
// at pos.
func (h *Hub) ChangeZone(sess *gateway.Session, newZone string, pos Position) (old Entity, remainingOld []Entity, othersNew []Entity, ok bool) {
	if o := h.routed(sess); o != nil {
		return o.ChangeZone(sess, newZone, pos)
	}
	return h.changeZone(sess, newZone, pos, false)
}

// ChangeZoneHeld is ChangeZone with the character held out of the world
// (Entity.Held) at its arrival until Release (round 786, session/arrival.go):
// the old window loses it at once, the new one gains it only on Release.
func (h *Hub) ChangeZoneHeld(sess *gateway.Session, newZone string, pos Position) (old Entity, remainingOld []Entity, othersNew []Entity, ok bool) {
	if o := h.routed(sess); o != nil {
		return o.ChangeZoneHeld(sess, newZone, pos)
	}
	return h.changeZone(sess, newZone, pos, true)
}

func (h *Hub) changeZone(sess *gateway.Session, newZone string, pos Position, held bool) (old Entity, remainingOld []Entity, othersNew []Entity, ok bool) {
	h.mu.Lock()
	defer h.mu.Unlock()

	e, exists := h.bySession[sess.ID()]
	if !exists {
		return Entity{}, nil, nil, false
	}
	old = outLocked(e, h.clock())
	old.Move = nil
	// A stale session of a reconnect -- its character entered again on a
	// newer session, which took the character and the name -- stays the
	// stale one through its zone change (round 737's verification, N4):
	// before, its re-insertion took the character back from the live
	// session.
	live, stale := h.byChar[old.CharacterID], h.byChar[old.CharacterID] != e
	h.removeLocked(sess.ID())
	remainingOld = h.viewOthersLocked(&old)

	// The life state, the level and the heading travel with the character: a zone change
	// is refused while dead (session.handleChangeZone), but the return to the
	// return point moves a dead character before it revives it (round 665,
	// session.ReviveHandler), and a state is never reset by a move.
	next := &Entity{Session: sess, CharacterID: old.CharacterID, Name: old.Name, Zone: newZone, Pos: pos, Life: old.Life, DiedAt: old.DiedAt, Level: old.Level, Arrival: nextArrival(), Heading: old.Heading, Trusted: pos, allowAt: h.clock(), allowSpeed: old.allowSpeed, Held: held}
	h.insertLocked(next)
	if stale {
		if live != nil {
			h.byChar[old.CharacterID] = live
			h.byName[live.Name] = live
		} else {
			delete(h.byChar, old.CharacterID)
			if h.byName[next.Name] == next {
				delete(h.byName, next.Name)
			}
		}
	}
	othersNew = h.viewOthersLocked(next)

	return old, remainingOld, othersNew, true
}

// SetLifeState moves characterID's life state from `from` to `to`, recording
// `at` as the time of death when `to` is LifeDead and clearing it otherwise.
// It reports whether the change was made: false when the character is not in
// the world, or when its state is not `from` -- a compare-and-swap, so a
// monster's blow and a revive racing each other cannot both claim the change
// (session.revivePlayer relies on that to send one OpReviveResult). Keyed by
// character rather than session because the writer that matters is a
// monster's blow (session/monsterstrike.go), which knows only the character.
func (h *Hub) SetLifeState(characterID int64, from, to LifeState, at time.Time) bool {
	h.mu.Lock()
	defer h.mu.Unlock()

	e, ok := h.byChar[characterID]
	if !ok {
		return false
	}
	if e.Life != from {
		return false
	}
	e.Life = to
	if to == LifeDead {
		e.DiedAt = at
	} else {
		e.DiedAt = time.Time{}
	}
	return true
}

// SetLevel moves characterID's cached level to level (Entity.Level) and
// reports whether the character was in the world to take it. The two callers
// are the two places a level changes: session.performAttack's level-up and
// gm's /level, each right after its character.Store.SetLeveling. Keyed by
// character, as SetLifeState is, because the readers that matter (the monster
// AI's link and swing) know only the character.
func (h *Hub) SetLevel(characterID int64, level int) bool {
	h.mu.Lock()
	e, ok := h.byChar[characterID]
	if !ok {
		h.mu.Unlock()
		return false
	}
	changed := e.Level != level
	e.Level = level
	h.mu.Unlock()
	// Round 865: a level change in the game refreshes an academy member
	// (session.academyLevelChanged), outside the hub's lock.
	if f := levelHook.Load(); changed && f != nil {
		(*f)(characterID, level)
	}
	return true
}

// levelHook hears every level SetLevel changes.
var levelHook atomic.Pointer[func(characterID int64, level int)]

// SetLevelHook installs f as the hook every SetLevel that changes a level
// calls (nil removes it). One hook for the process: the academy's.
func SetLevelHook(f func(characterID int64, level int)) {
	if f == nil {
		levelHook.Store(nil)
		return
	}
	levelHook.Store(&f)
}

// SetHeading sets sess's character's heading -- a restored one at world entry
// (round 637's review follow-up; character.HeadingStore). Reports whether the
// session is in the world.
func (h *Hub) SetHeading(sess *gateway.Session, heading float64) bool {
	if o := h.routed(sess); o != nil {
		return o.SetHeading(sess, heading)
	}
	h.mu.Lock()
	defer h.mu.Unlock()

	e, exists := h.bySession[sess.ID()]
	if !exists {
		return false
	}
	e.Heading = heading
	return true
}

// EntitiesInZone returns a snapshot of every entity currently in zone.
// Used by other systems (e.g. combat) that need to broadcast to everyone
// present rather than "everyone except the session that triggered this".
func (h *Hub) EntitiesInZone(zone string) []Entity {
	h.mu.RLock()
	defer h.mu.RUnlock()

	now := h.clock()
	// Sized up front (under -single-frame the zone is the whole world, and
	// every blow on a monster asks for it twice: monsterWatchers).
	out := make([]Entity, 0, len(h.byZone[zone]))
	for _, e := range h.byZone[zone] {
		out = append(out, outLocked(e, now))
	}
	return out
}

// ViewOfCharacter returns every entity in view of characterID's block as the
// hub has it now (the ViewRadius window, round 737): who sees it and whom it
// sees, itself included; nil when it is not in the world.
func (h *Hub) ViewOfCharacter(characterID int64) []Entity {
	h.mu.RLock()
	defer h.mu.RUnlock()
	e, ok := h.byChar[characterID]
	if !ok {
		return nil
	}
	now := h.clock()
	var out []Entity
	h.forWindowLocked(e.Cell, func(o *Entity) { out = append(out, outLocked(o, now)) })
	return out
}

// Sees reports whether the players on sessions a and b are both in the world
// and in view of each other now (InView of their blocks).
func (h *Hub) Sees(a, b uint64) bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	ea, ok := h.bySession[a]
	if !ok {
		return false
	}
	eb, ok := h.bySession[b]
	if !ok {
		return false
	}
	if ea.Held || eb.Held {
		return false
	}
	return InView(ea.Cell, eb.Cell)
}

// AllEntities returns every entity currently in the world, in any zone.
//
// For periodic jobs that act on every online character rather than on one
// zone. Passive regeneration is the first (internal/mana).
func (h *Hub) AllEntities() []Entity {
	h.mu.RLock()
	defer h.mu.RUnlock()
	now := h.clock()
	out := make([]Entity, 0, len(h.bySession))
	for _, e := range h.bySession {
		out = append(out, outLocked(e, now))
	}
	return out
}

// LastPassHold is how long the last mover pass held the write lock
// (opensro_world_mover_lock_hold_seconds).
func (h *Hub) LastPassHold() time.Duration { return time.Duration(h.passHold.Load()) }

// Count returns how many characters are in the world now, in any zone: the
// "current users" the server list reports (round 679, session.ServerStatus).
func (h *Hub) Count() int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(h.bySession)
}

// EntityBySession returns the entity currently associated with sessionID,
// if it's in the world. Used by systems (e.g. chat) that need to know a
// session's current character/zone without themselves tracking it.
func (h *Hub) EntityBySession(sessionID uint64) (Entity, bool) {
	h.mu.RLock()
	defer h.mu.RUnlock()

	e, ok := h.bySession[sessionID]
	if !ok {
		return Entity{}, false
	}
	return outLocked(e, h.clock()), true
}

// EntityByCharacterID returns the entity for characterID, if they're
// currently in the world (in any zone). Used for online-status checks
// (e.g. friend lists) that only have a character ID on hand, not a name.
func (h *Hub) EntityByCharacterID(characterID int64) (Entity, bool) {
	h.mu.RLock()
	defer h.mu.RUnlock()

	e, ok := h.byChar[characterID]
	if !ok {
		return Entity{}, false
	}
	return outLocked(e, h.clock()), true
}

// FindByName returns the entity for the character named name, if they're
// currently in the world (in any zone). Used for cross-zone lookups like
// whispers, where the sender doesn't know or care which zone the target is
// in.
func (h *Hub) FindByName(name string) (Entity, bool) {
	h.mu.RLock()
	defer h.mu.RUnlock()

	e, ok := h.byName[name]
	if !ok {
		return Entity{}, false
	}
	return outLocked(e, h.clock()), true
}

// insertLocked files e under every index, its block from its position.
// Caller must hold h.mu for writing.
func (h *Hub) insertLocked(e *Entity) {
	id := e.Session.ID()
	e.Cell = CellOf(e.Zone, e.Pos)
	h.bySession[id] = e
	if h.byZone[e.Zone] == nil {
		h.byZone[e.Zone] = make(map[uint64]*Entity)
	}
	h.byZone[e.Zone][id] = e
	h.byChar[e.CharacterID] = e
	h.byName[e.Name] = e
	h.cellLocked(e)
	presence.Store(e.CharacterID, h)
}

// removeLocked removes a session's entity from every index. Caller must
// hold h.mu.
func (h *Hub) removeLocked(sessionID uint64) {
	e, exists := h.bySession[sessionID]
	if !exists {
		return
	}
	delete(h.bySession, sessionID)
	if zoneEntities := h.byZone[e.Zone]; zoneEntities != nil {
		delete(zoneEntities, sessionID)
		if len(zoneEntities) == 0 {
			delete(h.byZone, e.Zone)
		}
	}
	if h.byChar[e.CharacterID] == e {
		delete(h.byChar, e.CharacterID)
		presence.CompareAndDelete(e.CharacterID, h)
	}
	if h.byName[e.Name] == e {
		delete(h.byName, e.Name)
	}
	h.uncellLocked(e)
	delete(h.moving, sessionID)
}

func (h *Hub) cellLocked(e *Entity) {
	if e.Held {
		return // out of the world until Release (Entity.Held)
	}
	m := h.byCell[e.Cell]
	if m == nil {
		m = make(map[uint64]*Entity)
		h.byCell[e.Cell] = m
	}
	m[e.Session.ID()] = e
}

func (h *Hub) uncellLocked(e *Entity) {
	if m := h.byCell[e.Cell]; m != nil {
		delete(m, e.Session.ID())
		if len(m) == 0 {
			delete(h.byCell, e.Cell)
		}
	}
}

// forWindowLocked calls f for every entity in the ViewRadius window of c.
// Caller must hold h.mu.
func (h *Hub) forWindowLocked(c combat.Cell, f func(*Entity)) {
	for x := c.X - ViewRadius; x <= c.X+ViewRadius; x++ {
		for z := c.Z - ViewRadius; z <= c.Z+ViewRadius; z++ {
			for _, o := range h.byCell[combat.Cell{Zone: c.Zone, X: x, Z: z}] {
				f(o)
			}
		}
	}
}

func (h *Hub) windowCountLocked(c combat.Cell) int {
	n := 0
	for x := c.X - ViewRadius; x <= c.X+ViewRadius; x++ {
		for z := c.Z - ViewRadius; z <= c.Z+ViewRadius; z++ {
			n += len(h.byCell[combat.Cell{Zone: c.Zone, X: x, Z: z}])
		}
	}
	return n
}

// viewOthersLocked returns a snapshot of every entity in view of e's
// position, except e's own session. Caller must hold h.mu.
func (h *Hub) viewOthersLocked(e *Entity) []Entity {
	now := h.clock()
	cell := CellOf(e.Zone, e.Pos)
	// Sized up front: grown by append, a crowd's snapshot was copied over
	// again at each doubling, under the write lock.
	out := make([]Entity, 0, h.windowCountLocked(cell))
	h.forWindowLocked(cell, func(o *Entity) {
		if o.Session.ID() != e.Session.ID() {
			out = append(out, outLocked(o, now))
		}
	})
	return out
}
