package session

import (
	"sync"
	"time"
)

// itemCooldownTracker is the group map of the character's cooldown block
// (pc+0x1f40, the map at +0x2c): a timer per COOLTIME GROUP, shared by every
// item in the group (round 263, docs/protocol/ITEM_FORMAT.md "Reuse
// cooltime") and, since round 504, by every skill in the same cooldown group
// (skillGroupCooldowns). Process-wide and in memory, keyed by character; the
// engine additionally persists delays of 300 s or more, which srrevamp does
// not yet.
type itemCooldownTracker struct {
	mu    sync.Mutex
	until map[int64]map[uint32]time.Time
}

var itemCooldowns = newItemCooldownTracker()

// skillGroupCooldowns is the map SkillCooldowns::IsReady (0x64c1a0) consults
// for a skill with a cooldown group -- the high byte of its Action_Overlap,
// CRefSkill+0x8f (refdata.Skill.CooldownGroup) -- and the arm FUN_0064c700
// fills when that byte is non-zero: one timer per (character, group), shared
// by every skill in the group (round 504). An ungrouped skill keeps its own
// per-id timer, the skill store's LastUsed (the engine's map at block+0x1c).
//
// It is itemCooldowns ITSELF, not a second tracker, because the engine has
// one map here, not two. Both readers are handed the same block, pc+0x1f40
// (the skill gate at 0x58e083 `lea eax,[ebx+0x1f40]`, the item use at
// 0x510d95 `add esi,0x1f40` with esi the PC), and both look the group byte up
// in the map at block+0x2c: SkillCooldowns::IsReady at 0x64c245 and
// ItemCooldowns::IsReady (0x64c040) at 0x64c080, each `lea eax,[ebp+0x2c]`
// with ebp the block. So a skill group and an item cooltime group with the same
// byte share a timer. On the real tables they never meet: the skill groups are
// 1..114 without 72, 74, 84-87, 91, 94-96, 98, 99 and 113, and the item groups
// are 0x71 (113), 0xA7, 0xC8-0xCB, 0xF0-0xF2 and 0xF6.
var skillGroupCooldowns = itemCooldowns

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
