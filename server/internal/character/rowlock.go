package character

import "sync"

// LockLeveling serialises one character's level/EXP/stat read-modify-write
// (GetByID, then SetLeveling with the whole row) across goroutines, and
// returns the unlock (round 712's review, finding 3). Since round 712 a party
// share pays every eligible member from the KILLER's goroutine, so a member's
// row can be written by another member's kill while its own session spends
// stat points, a monster's blow charges a death penalty or a GM sets a level.
// Every SetLeveling writer takes this lock around its read and its write; a
// lost update is invisible to the race detector, so the rule is the only
// guard. Not re-entrant: never take it twice on one goroutine.
func LockLeveling(characterID int64) (unlock func()) {
	v, _ := levelingLocks.LoadOrStore(characterID, &sync.Mutex{})
	mu := v.(*sync.Mutex)
	mu.Lock()
	return mu.Unlock
}

var levelingLocks sync.Map // int64 -> *sync.Mutex
