package character

import (
	"sync"
	"sync/atomic"
)

// baseStats keeps each character's base Strength and Intellect as a store last
// read or wrote them (round 875), so a monster's blow can scale the target's
// armour reinforce by its Str / Int without a character-store read per swing
// (session's monster swing reads none: the target's level is the entity's).
// Both stores note a row on GetByID and on SetLeveling, the one writer of
// Str and Int; a row the process never read is simply not cached, and the
// caller reads the store instead. OURS: a cache, not a rule of the game.
var baseStats sync.Map // int64 -> [2]int

func noteBaseStats(id int64, str, intel int) { baseStats.Store(id, [2]int{str, intel}) }

// BaseStats is the character's base Str and Int as last seen by a store; ok is
// false when no store has read or written the row in this process.
func BaseStats(id int64) (str, intel int, ok bool) {
	v, ok := baseStats.Load(id)
	if !ok {
		return 0, 0, false
	}
	s := v.([2]int)
	return s[0], s[1], true
}

// levelHook is told every level a store writes (round 877: session's worn
// items are tested again on a level change, as GObjPC_SetLevel's
// RefreshEquipParamEntryForPC is). Called after the write, outside any lock
// the store holds.
var levelHook atomic.Pointer[func(characterID int64, level int)]

// SetLevelHook registers the level hook (nil: none).
func SetLevelHook(f func(characterID int64, level int)) {
	if f == nil {
		levelHook.Store(nil)
		return
	}
	levelHook.Store(&f)
}

func noteLevel(id int64, level int) {
	if f := levelHook.Load(); f != nil {
		(*f)(id, level)
	}
}
