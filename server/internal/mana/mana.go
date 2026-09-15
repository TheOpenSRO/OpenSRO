// Package mana tracks each character's current MP so skills can cost
// something to cast.
//
// The two numbers that matter here are REAL, not invented: a character's
// maximum mana is the game's own formula (character.MaxMPFor --
// Int * 10 * 1.02^(level-1), recovered whole from the server binary's derived-
// stat graph), and a skill's cost is the real Consume_MP column of the client's
// own skilldata. This package only holds the pool in between.
//
// Current MP is deliberately NOT persisted, the same call berserk makes: it is
// transient combat state that refills on its own, so it lives in memory and a
// character comes back full after a restart. Max HP is persisted because
// damage should survive a relog; being topped up on mana should not be worth
// reconnecting for, because the pool refills anyway.
package mana

import (
	"sync"
	"time"
)

// RegenPerTick and RegenInterval are this project's OWN DESIGN, disclosed.
// The real game has an 'mprg' parameter in its derived-stat table (see the
// ParamKeeper notes in docs/GROUNDING_AUDIT.md) but its value has not been
// recovered, so rather than dress a guess up as the game's rate this is a
// plain, honest refill: a percentage of the pool every few seconds. It exists
// so a caster who runs dry recovers without having to relog, not as a claim
// about the original balance.
const (
	RegenPercentPerTick = 4
	RegenInterval       = 3 * time.Second
)

// Tracker holds live MP per character. The zero value is not usable; call
// NewTracker.
type Tracker struct {
	mu      sync.Mutex
	current map[int64]int
	lastGen map[int64]time.Time
}

func NewTracker() *Tracker {
	return &Tracker{current: map[int64]int{}, lastGen: map[int64]time.Time{}}
}

// Current returns the character's MP, topping it up for any regeneration owed
// since it was last touched. A character not seen before starts full.
func (t *Tracker) Current(characterID int64, maxMP int) int {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.currentLocked(characterID, maxMP)
}

func (t *Tracker) currentLocked(characterID int64, maxMP int) int {
	if maxMP < 0 {
		maxMP = 0
	}
	cur, seen := t.current[characterID]
	if !seen {
		t.current[characterID] = maxMP
		t.lastGen[characterID] = time.Now()
		return maxMP
	}
	// Regeneration is settled lazily rather than on a ticker: nothing needs
	// to know a character's mana until something asks, and this way an
	// offline character costs nothing.
	if cur < maxMP {
		last := t.lastGen[characterID]
		if ticks := int(time.Since(last) / RegenInterval); ticks > 0 {
			perTick := maxMP * RegenPercentPerTick / 100
			if perTick < 1 {
				perTick = 1
			}
			cur += ticks * perTick
			if cur > maxMP {
				cur = maxMP
			}
			t.current[characterID] = cur
			t.lastGen[characterID] = last.Add(time.Duration(ticks) * RegenInterval)
		}
	}
	if cur > maxMP {
		// The pool shrank (a level-down, or a fresh max): clamp.
		cur = maxMP
		t.current[characterID] = cur
	}
	return cur
}

// Spend takes cost MP from the character if they have it, returning the
// remaining MP and whether the cost was paid. A cost of zero or less always
// succeeds and takes nothing.
func (t *Tracker) Spend(characterID int64, maxMP, cost int) (remaining int, ok bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	cur := t.currentLocked(characterID, maxMP)
	if cost <= 0 {
		return cur, true
	}
	if cur < cost {
		return cur, false
	}
	cur -= cost
	t.current[characterID] = cur
	// Regeneration is measured from the moment of the spend.
	t.lastGen[characterID] = time.Now()
	return cur, true
}

// Restore adds amount back to the pool, never above maxMP, returning the new
// value. What a mana potion does.
func (t *Tracker) Restore(characterID int64, maxMP, amount int) int {
	t.mu.Lock()
	defer t.mu.Unlock()
	cur := t.currentLocked(characterID, maxMP)
	if amount > 0 {
		cur += amount
		if cur > maxMP {
			cur = maxMP
		}
		t.current[characterID] = cur
	}
	return cur
}

// Refill sets the character back to full (on level-up or respawn, where the
// game already restores health).
func (t *Tracker) Refill(characterID int64, maxMP int) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.current[characterID] = maxMP
	t.lastGen[characterID] = time.Now()
}

// Clear drops a character's state, on disconnect.
func (t *Tracker) Clear(characterID int64) {
	t.mu.Lock()
	defer t.mu.Unlock()
	delete(t.current, characterID)
	delete(t.lastGen, characterID)
}
