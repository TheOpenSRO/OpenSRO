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

// RegenPercentPerTick and RegenInterval are this project's OWN DESIGN. This
// note used to say the rate was the game's `'mprg'` parameter, waiting to be
// read. That search has now finished, and the answer is that there is nothing
// to read: no periodic regeneration exists in the server binary at all.
//
// The proof is an enumeration rather than a sampling, which is the only kind
// worth trusting for a negative. A character's HP and MP live in charData and
// are written through exactly two clamped setters -- GObjChar_SetCurHP
// (0x004a66f0) and GObjChar_SetCurMP (0x004a6790), which name their own source
// file in the assert "CLAMP() ==> min(%.3f) exceeded max(%.3f)",
// d:\work2005\...\GObjChar.h line 0x16c. Disassembling the whole PE and
// counting call sites gives 4 calls to the HP setter, 2 to the MP setter, 4 to
// the generic GObjPC_AdjustHpMp they funnel through, and -- the part that makes
// it an enumeration -- ZERO address-taken references to any of them, so none is
// ever reached through a vtable or function pointer. Every writer is therefore
// on this list, and every one has been read:
//
//	GObjPC_AdjustHpMp            the generic adjust (HP in EAX, MP in arg 2)
//	GObjPC_RecoverHpMp           potions and heal skills (params 143/144)
//	CGObjCOS_Summoned::ConsumeHpMp
//	CGObjChar::vslot_317 / 318   effect application (318 passes HP=0, MP only)
//	CGObjPC_PublishHpMp          clamp + send the HP/MP update packet
//	GObjPC_OnEffectExpired       re-clamp when a buff's MaxHP/MaxMP goes away
//	FUN_00634020                 siege-structure removal
//	GObjPC_RestorePoolOnLoad     login/respawn seed at RespawnFraction
//
// Not one is driven by a clock. Healing in this game is an event -- a potion, a
// skill, a respawn -- never a tick.
//
// `'hprg'`/`'mprg'` (params 25 and 26) are real but are not a resting rate.
// All seven writes of them in the binary come from skill effects, and every one
// targets slot 1 (the additive percent) or slot 3; slot 0, the base, is never
// written for either. They modify a regeneration that the server itself never
// performs, which fits a client-side display and item tooltips.
//
// And the baseline is zero as well, which was the last thing left to check. A
// param whose slot 0 is empty does not evaluate to zero by default -- it falls
// back to the per-param default in its descriptor record. Those records turned
// out to be a static table in the binary after all (VA 0x00c64110, 120 params,
// 20 bytes each; see docs/protocol/param_registry.md), and **`'hprg'` and
// `'mprg'` both default to 0**, with a maximum of 100.
//
// So the two halves agree: the engine's resting regeneration rate is zero, and
// there is no timer that would apply it even if it were not.
//
// So this is a plain, honest refill -- a percentage of the pool every few
// seconds -- so a caster who runs dry recovers without relogging. It is not a
// claim about the original balance, and there is no longer an `'mprg'` default
// to go looking for.
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
