// Package world tracks which characters are currently "in the game world"
// (as opposed to just logged in / at character select): their position,
// zone, and who else is nearby. Own design — there's no original data to
// be informed by here the way account/character had DB facts to draw on;
// this is just what a minimal multiplayer position-sync system needs.
//
// Deliberately in-memory only, unlike account/character's SQLite stores —
// live position data resetting on a server restart is normal for an MMO,
// not a bug to fix.
package world

import (
	"sync"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/gateway"
)

// Position is a point in 3D space. Units are arbitrary at this stage — no
// real map data exists yet to calibrate against.
type Position struct {
	X, Y, Z float64
}

// LifeState is the engine's life-state byte as srrevamp keeps it: chardata[0],
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
	Zone        string
	Pos         Position
	// Life is the character's life state, LifeAlive from Enter until a
	// monster's killing blow sets LifeDead (session/monsterstrike.go, behind
	// -player-dead-state) and a revive sets LifeAlive again.
	Life LifeState
	// DiedAt is when Life last became LifeDead, for the auto-revive fallback
	// (session.RunAutoRevive); the zero time while alive.
	DiedAt time.Time
	// Level is the character's level as the character store holds it, cached
	// here so the monster AI reads it off the entity instead of the store on
	// its tick and on its strike workers (round 555; until then
	// session/monsterai.go's linkAggro made one character.Store.GetByID per
	// link event under the tick's lock, and runStrike one per swing). Set from
	// the row at Enter and moved by SetLevel where a level changes: the
	// level-up in session.performAttack and gm's /level. Nothing else moves a
	// level -- a death penalty takes experience only (GObjPC_OnDeath touches
	// no CurLevel; session/monsterstrike.go) and a stat-point spend keeps it
	// (session/stats.go) -- so the two writers are the whole set.
	Level int
}

// Hub tracks all entities currently in the world, grouped by zone. Safe for
// concurrent use.
type Hub struct {
	mu        sync.RWMutex
	byZone    map[string]map[uint64]*Entity // zone -> session ID -> entity
	bySession map[uint64]*Entity
}

// NewHub returns an empty Hub.
func NewHub() *Hub {
	return &Hub{
		byZone:    make(map[string]map[uint64]*Entity),
		bySession: make(map[uint64]*Entity),
	}
}

// Enter adds sess's character, at level, to zone at pos. If the session was
// already in the world (e.g. re-entering without a clean Leave), it's moved
// rather than duplicated. Returns a snapshot of the other entities already in
// that zone, for the caller to send an initial "who's here" packet. The level
// is a parameter rather than a later SetLevel so no entity ever exists
// without one (Entity.Level).
func (h *Hub) Enter(sess *gateway.Session, characterID int64, name string, level int, zone string, pos Position) []Entity {
	h.mu.Lock()
	defer h.mu.Unlock()

	h.removeLocked(sess.ID())

	e := &Entity{Session: sess, CharacterID: characterID, Name: name, Zone: zone, Pos: pos, Life: LifeAlive, Level: level}
	h.bySession[sess.ID()] = e
	if h.byZone[zone] == nil {
		h.byZone[zone] = make(map[uint64]*Entity)
	}
	h.byZone[zone][sess.ID()] = e

	return h.othersInZoneLocked(zone, sess.ID())
}

// Leave removes sess's character from the world, if present. Returns the
// entity that left and a snapshot of the entities remaining in its zone (to
// notify that this one left), or ok=false if the session wasn't in the
// world.
func (h *Hub) Leave(sess *gateway.Session) (left Entity, remaining []Entity, ok bool) {
	h.mu.Lock()
	defer h.mu.Unlock()

	e, exists := h.bySession[sess.ID()]
	if !exists {
		return Entity{}, nil, false
	}
	left = *e
	h.removeLocked(sess.ID())
	return left, h.othersInZoneLocked(left.Zone, sess.ID()), true
}

// Move updates sess's character's position. Returns the updated entity and
// a snapshot of the other entities in the same zone (to notify), or
// ok=false if the session isn't in the world.
func (h *Hub) Move(sess *gateway.Session, pos Position) (entity Entity, others []Entity, ok bool) {
	h.mu.Lock()
	defer h.mu.Unlock()

	e, exists := h.bySession[sess.ID()]
	if !exists {
		return Entity{}, nil, false
	}
	e.Pos = pos
	return *e, h.othersInZoneLocked(e.Zone, sess.ID()), true
}

// ChangeZone moves sess's character to newZone at pos, the same discrete
// "leave the old zone, appear fresh in the new one" semantics as Leave
// followed by Enter, but as one atomic operation (no window where the
// character is in neither zone's byZone index). Returns the character's
// state before the move, everyone left behind in the old zone (to notify
// they left), and everyone already present in the new zone (to notify
// someone new arrived) -- or ok=false if the session wasn't in the world.
func (h *Hub) ChangeZone(sess *gateway.Session, newZone string, pos Position) (old Entity, remainingOld []Entity, othersNew []Entity, ok bool) {
	h.mu.Lock()
	defer h.mu.Unlock()

	e, exists := h.bySession[sess.ID()]
	if !exists {
		return Entity{}, nil, nil, false
	}
	old = *e
	h.removeLocked(sess.ID())
	remainingOld = h.othersInZoneLocked(old.Zone, sess.ID())

	// The life state and the level travel with the character: a zone change
	// is refused while dead (session.handleChangeZone), so this carries
	// LifeAlive in practice, but a state is never reset by a move.
	next := &Entity{Session: sess, CharacterID: old.CharacterID, Name: old.Name, Zone: newZone, Pos: pos, Life: old.Life, DiedAt: old.DiedAt, Level: old.Level}
	h.bySession[sess.ID()] = next
	if h.byZone[newZone] == nil {
		h.byZone[newZone] = make(map[uint64]*Entity)
	}
	h.byZone[newZone][sess.ID()] = next
	othersNew = h.othersInZoneLocked(newZone, sess.ID())

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

	for _, e := range h.bySession {
		if e.CharacterID != characterID {
			continue
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
	return false
}

// SetLevel moves characterID's cached level to level (Entity.Level) and
// reports whether the character was in the world to take it. The two callers
// are the two places a level changes: session.performAttack's level-up and
// gm's /level, each right after its character.Store.SetLeveling. Keyed by
// character, as SetLifeState is, because the readers that matter (the monster
// AI's link and swing) know only the character.
func (h *Hub) SetLevel(characterID int64, level int) bool {
	h.mu.Lock()
	defer h.mu.Unlock()

	for _, e := range h.bySession {
		if e.CharacterID == characterID {
			e.Level = level
			return true
		}
	}
	return false
}

// EntitiesInZone returns a snapshot of every entity currently in zone.
// Used by other systems (e.g. combat) that need to broadcast to everyone
// present rather than "everyone except the session that triggered this".
func (h *Hub) EntitiesInZone(zone string) []Entity {
	h.mu.RLock()
	defer h.mu.RUnlock()

	var out []Entity
	for _, e := range h.byZone[zone] {
		out = append(out, *e)
	}
	return out
}

// AllEntities returns every entity currently in the world, in any zone.
//
// For periodic jobs that act on every online character rather than on one
// zone. Passive regeneration is the first (internal/mana).
func (h *Hub) AllEntities() []Entity {
	h.mu.RLock()
	defer h.mu.RUnlock()
	out := make([]Entity, 0, len(h.bySession))
	for _, e := range h.bySession {
		out = append(out, *e)
	}
	return out
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
	return *e, true
}

// EntityByCharacterID returns the entity for characterID, if they're
// currently in the world (in any zone). Used for online-status checks
// (e.g. friend lists) that only have a character ID on hand, not a name.
func (h *Hub) EntityByCharacterID(characterID int64) (Entity, bool) {
	h.mu.RLock()
	defer h.mu.RUnlock()

	for _, e := range h.bySession {
		if e.CharacterID == characterID {
			return *e, true
		}
	}
	return Entity{}, false
}

// FindByName returns the entity for the character named name, if they're
// currently in the world (in any zone). Used for cross-zone lookups like
// whispers, where the sender doesn't know or care which zone the target is
// in.
func (h *Hub) FindByName(name string) (Entity, bool) {
	h.mu.RLock()
	defer h.mu.RUnlock()

	for _, e := range h.bySession {
		if e.Name == name {
			return *e, true
		}
	}
	return Entity{}, false
}

// removeLocked removes a session's entity from both indexes. Caller must
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
}

// othersInZoneLocked returns a snapshot of every entity in zone except
// excludeSessionID. Caller must hold h.mu (read or write).
func (h *Hub) othersInZoneLocked(zone string, excludeSessionID uint64) []Entity {
	var out []Entity
	for id, e := range h.byZone[zone] {
		if id == excludeSessionID {
			continue
		}
		out = append(out, *e)
	}
	return out
}
