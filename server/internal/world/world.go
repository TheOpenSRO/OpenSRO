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
