package session

// The carried runtime (round 869, OURS, docs/protocol/game_worlds.md 12.1):
// what is a character's own and travels with it between world units. In one
// process the per-character books -- the buff book, the item and skill-group
// cooldowns, the motion state, the abnormal states -- are keyed by the
// character, not by a world, so a warp between units keeps them untouched
// (TestCarriedStateAcrossWorlds). A move to another process (lane W2's
// re-route) carries them in a CarriedState: SnapshotCarried on the source,
// RestoreCarried on the target.

import (
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/buff"
)

// CarriedState is a character's carried runtime.
type CarriedState struct {
	// Buffs is the buff book's records (a snapshot: RestoreCarried does not
	// yet rebuild a book -- the book's own state bits, wall and speed holders
	// are W2's to carry; OPEN).
	Buffs []buff.Record
	// GroupCooldowns and ItemCooldowns are the item/skill cooldown block's
	// two maps (block+0x2c by group, block+0x10 by item; itemcooldown.go).
	GroupCooldowns map[uint32]time.Time
	ItemCooldowns  map[int64]time.Time
}

// SnapshotCarried is characterID's carried runtime now.
func SnapshotCarried(characterID int64) CarriedState {
	s := CarriedState{Buffs: buffBooks.Active(characterID), GroupCooldowns: map[uint32]time.Time{}, ItemCooldowns: map[int64]time.Time{}}
	itemCooldowns.mu.Lock()
	for g, t := range itemCooldowns.until[characterID] {
		s.GroupCooldowns[g] = t
	}
	for id, t := range itemCooldowns.perItem[characterID] {
		s.ItemCooldowns[id] = t
	}
	itemCooldowns.mu.Unlock()
	return s
}

// RestoreCarried puts a snapshot's cooldowns back on characterID (the target
// process of a re-route).
func RestoreCarried(characterID int64, s CarriedState) {
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
