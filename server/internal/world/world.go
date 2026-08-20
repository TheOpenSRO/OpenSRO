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

	"github.com/OpenSRO/srrevamp/server/internal/gateway"
)

// Position is a point in 3D space. Units are arbitrary at this stage — no
// real map data exists yet to calibrate against.
type Position struct {
	X, Y, Z float64
}

// Entity is one character currently present in the world.
type Entity struct {
	Session     *gateway.Session
	CharacterID int64
	Name        string
	Zone        string
	Pos         Position
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

// Enter adds sess's character to zone at pos. If the session was already in
// the world (e.g. re-entering without a clean Leave), it's moved rather
// than duplicated. Returns a snapshot of the other entities already in that
// zone, for the caller to send an initial "who's here" packet.
func (h *Hub) Enter(sess *gateway.Session, characterID int64, name, zone string, pos Position) []Entity {
	h.mu.Lock()
	defer h.mu.Unlock()

	h.removeLocked(sess.ID())

	e := &Entity{Session: sess, CharacterID: characterID, Name: name, Zone: zone, Pos: pos}
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
