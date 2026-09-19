package session

import (
	"sync"
	"time"
)

// itemCooldownTracker is the item half of the character's cooldown block
// (pc+0x1f40): a timer per COOLTIME GROUP, shared by every item in the group
// (round 263, docs/protocol/ITEM_FORMAT.md "Reuse cooltime"). Process-wide
// and in memory, keyed by character; the engine additionally persists delays
// of 300 s or more, which srrevamp does not yet.
type itemCooldownTracker struct {
	mu    sync.Mutex
	until map[int64]map[uint32]time.Time
}

var itemCooldowns = newItemCooldownTracker()

func newItemCooldownTracker() *itemCooldownTracker {
	return &itemCooldownTracker{until: map[int64]map[uint32]time.Time{}}
}

// Ready reports whether the character's timer for the group has run out.
func (t *itemCooldownTracker) Ready(characterID int64, group uint32, now time.Time) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	if m := t.until[characterID]; m != nil {
		if until, ok := m[group]; ok && now.Before(until) {
			return false
		}
	}
	return true
}

// Arm starts the group's timer for d from now.
func (t *itemCooldownTracker) Arm(characterID int64, group uint32, d time.Duration, now time.Time) {
	t.mu.Lock()
	defer t.mu.Unlock()
	m := t.until[characterID]
	if m == nil {
		m = map[uint32]time.Time{}
		t.until[characterID] = m
	}
	m[group] = now.Add(d)
}
