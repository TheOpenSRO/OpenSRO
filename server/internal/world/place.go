package world

// Round 869 (docs/protocol/game_worlds.md 11, 12): one Hub per game-world
// unit. Each instance's hub has its own lock and maps and shares none with
// the open world's or another instance's; what crosses them is here:
//
//   - the session's place (gateway.Session.Place): the hub its character is
//     in, read lock-free by every handler through For;
//   - the presence index: which hub holds a character, for what must find a
//     character wherever it is (a whisper, a party line, a per-character
//     timer's broadcast). OURS: in one process a sync.Map written only when
//     a character enters, changes zone or leaves -- never by a tick; with
//     several processes it is the registry's presence (internal/registry);
//   - Transfer, the move of a character from one hub to another.

import (
	"sync"
	"sync/atomic"

	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
)

// arrivalSeq numbers arrivals across every hub (Entity.Arrival: never
// reused, so an arrival in another world is new too).
var arrivalSeq atomic.Uint64

func nextArrival() uint64 { return arrivalSeq.Add(1) }

// presence is character id -> the *Hub that holds it.
var presence sync.Map

type unitBox struct{ v any }

// SetUnit records the game-world unit owning h (internal/gameworld.World).
func (h *Hub) SetUnit(u any) { h.unit.Store(&unitBox{u}) }

// Unit is the unit SetUnit recorded, nil for none.
func (h *Hub) Unit() any {
	if b := h.unit.Load(); b != nil {
		return b.v
	}
	return nil
}

// For is the hub sess's character is in: its place when it has one, else h
// (the open world's hub, or a test's only hub); nil for a nil h. A handler resolves its hub
// this way at its start, so everything it does acts in the caller's world.
func (h *Hub) For(sess *gateway.Session) *Hub {
	// A nil hub stays nil: a handler built without a hub tells no one.
	if h == nil {
		return nil
	}
	if sess != nil {
		if p, ok := sess.Place().(*Hub); ok && p != nil {
			return p
		}
	}
	return h
}

// Locate is the hub that holds character id, if any.
func Locate(characterID int64) (*Hub, bool) {
	v, ok := presence.Load(characterID)
	if !ok {
		return nil, false
	}
	return v.(*Hub), true
}

// HubOf is the hub that holds character id, or def when none does.
func HubOf(def *Hub, characterID int64) *Hub {
	if h, ok := Locate(characterID); ok {
		return h
	}
	return def
}

// Transfer moves sess's character from h into to, under zone at pos, held
// (Entity.Held) when held is set: ChangeZone across two hubs. The life
// state, level and heading travel with it, as in a zone change. It answers
// the entity before the move, the players of h that had it in view, and the
// players of to in view where it lands; ok is false when h does not hold
// the session. The session's place becomes to. The two hubs' locks are
// taken one after the other, never together.
func (h *Hub) Transfer(sess *gateway.Session, to *Hub, zone string, pos Position, held bool) (old Entity, remainingOld []Entity, othersNew []Entity, ok bool) {
	if to == h {
		return h.changeZone(sess, zone, pos, held)
	}
	h.mu.Lock()
	e, exists := h.bySession[sess.ID()]
	if !exists {
		h.mu.Unlock()
		return Entity{}, nil, nil, false
	}
	old = outLocked(e, h.clock())
	old.Move = nil
	h.removeLocked(sess.ID())
	remainingOld = h.viewOthersLocked(&old)
	h.mu.Unlock()

	to.mu.Lock()
	to.removeLocked(sess.ID())
	next := &Entity{Session: sess, CharacterID: old.CharacterID, Name: old.Name, Zone: zone, Pos: pos, Life: old.Life,
		DiedAt: old.DiedAt, Level: old.Level, Arrival: nextArrival(), Heading: old.Heading, Trusted: pos,
		allowAt: to.clock(), allowSpeed: old.allowSpeed, Held: held}
	to.insertLocked(next)
	othersNew = to.viewOthersLocked(next)
	to.mu.Unlock()
	sess.SetPlace(to)
	return old, remainingOld, othersNew, true
}

// routed is the hub sess's character is in when that is not h (nil when it
// is h or the session has no place): the session-keyed methods below hand
// themselves over to it, so a call made on the wrong hub still acts where
// the character is.
func (h *Hub) routed(sess *gateway.Session) *Hub {
	if sess == nil {
		return nil
	}
	if p, ok := sess.Place().(*Hub); ok && p != nil && p != h {
		return p
	}
	return nil
}
