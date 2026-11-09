package session

// The carried runtime (round 869, OURS, docs/protocol/game_worlds.md 12.1):
// what is a character's own and travels with it between world units. In one
// process the per-character books -- the buff book, the item and skill-group
// cooldowns, the motion state, the abnormal states -- are keyed by the
// character, not by a world, so a warp between units keeps them untouched
// (TestCarriedStateAcrossWorlds). A move to another process (lane W2's
// re-route, handoff.go) carries them in a CarriedState: SnapshotCarried on
// the source, RestoreCarried on the target.
//
// Lane W2: the buff book is carried whole (its records with their tokens and
// starts, its state bits, its speed and wall holders and the GM /speed
// factor: buff.BookState), and the live MP the mana tracker holds. Not
// carried (OPEN): the abnormal states running on the character (they end
// with the move, as a death ends them), a 'lnks' link to another character,
// the COS (they are put away on the source and called out again on the
// target by the arrival's cosArrived, as at a login).

import (
	"sync/atomic"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/buff"
	"github.com/TheOpenSRO/OpenSRO/server/internal/mana"
)

// CarriedState is a character's carried runtime.
type CarriedState struct {
	// Buffs is the buff book's records (what the book holds; Book has the
	// whole book).
	Buffs []buff.Record `json:"-"`
	// Book is the whole buff book.
	Book buff.BookState `json:"book"`
	// GroupCooldowns and ItemCooldowns are the item/skill cooldown block's
	// two maps (block+0x2c by group, block+0x10 by item; itemcooldown.go).
	GroupCooldowns map[uint32]time.Time `json:"group_cooldowns"`
	ItemCooldowns  map[int64]time.Time  `json:"item_cooldowns"`
	// MP is the live MP, when the tracker held it.
	MP    int  `json:"mp"`
	HasMP bool `json:"has_mp"`
}

// carriedMana is the mana tracker the MP is carried from (SetCarriedMana).
var carriedMana atomic.Pointer[mana.Tracker]

// SetCarriedMana names the process's mana tracker (cmd/server).
func SetCarriedMana(t *mana.Tracker) { carriedMana.Store(t) }

// SnapshotCarried is characterID's carried runtime now.
func SnapshotCarried(characterID int64) CarriedState {
	s := CarriedState{Buffs: buffBooks.Active(characterID), Book: buffBooks.Snapshot(characterID),
		GroupCooldowns: map[uint32]time.Time{}, ItemCooldowns: map[int64]time.Time{}}
	itemCooldowns.mu.Lock()
	for g, t := range itemCooldowns.until[characterID] {
		s.GroupCooldowns[g] = t
	}
	for id, t := range itemCooldowns.perItem[characterID] {
		s.ItemCooldowns[id] = t
	}
	itemCooldowns.mu.Unlock()
	if t := carriedMana.Load(); t != nil {
		s.MP, s.HasMP = t.Peek(characterID)
	}
	return s
}

// RestoreCarried puts a snapshot back on characterID (the target process
// of a re-route): its cooldowns, its buff book when the snapshot carries
// one, and its MP.
func RestoreCarried(characterID int64, s CarriedState) {
	if len(s.Book.Records) > 0 || s.Book.GMSpeed > 0 {
		buffBooks.Restore(characterID, s.Book)
	}
	if s.HasMP {
		if t := carriedMana.Load(); t != nil {
			t.Set(characterID, s.MP)
		}
	}
	itemCooldowns.mu.Lock()
	defer itemCooldowns.mu.Unlock()
	if len(s.GroupCooldowns) > 0 {
		m := itemCooldowns.until[characterID]
		if m == nil {
			m = map[uint32]time.Time{}
			itemCooldowns.until[characterID] = m
		}
		for g, t := range s.GroupCooldowns {
			m[g] = t
		}
	}
	if len(s.ItemCooldowns) > 0 {
		m := itemCooldowns.perItem[characterID]
		if m == nil {
			m = map[int64]time.Time{}
			itemCooldowns.perItem[characterID] = m
		}
		for id, t := range s.ItemCooldowns {
			m[id] = t
		}
	}
}
