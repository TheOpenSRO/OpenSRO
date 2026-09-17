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
// treated as transient combat state that refills on its own, so it lives in
// memory and a character comes back full after a restart.
//
// THIS IS A DIVERGENCE FROM THE ENGINE, corrected 2026-09-17. The wording here
// used to argue that "being topped up on mana should not be worth reconnecting
// for, because the pool refills anyway", which reads as though the design
// followed the game. It does not: `_CHAR` carries an **MP** column right beside
// **HP** (docs/protocol/db_columns.md), so the real server persists current
// mana and relogging does not refill it.
//
// The choice can stand on its own merits -- srrevamp has no cross-session
// consequence that turns on a mana total -- but it is own design, and
// internal/character's EngineOnlyColumns records it as one with a test that
// keeps it stated.
package mana

import (
	"sync"
	"time"
)

// THE "NO PERIODIC REGENERATION" CLAIM WAS WRONG, corrected 2026-09-16.
//
// This note used to say "there is nothing to read: no periodic regeneration
// exists in the server binary at all", and further down that "there is no timer
// that would apply it even if it were not". Both are false, and the enumeration
// that produced them was sound about WRITERS while wrong about what drives them.
//
// The regeneration tick is `CGObjPC::vslot_362` (`0x004e2990`), and it is
// registered as a timer:
//
//	4a6dd3  fld  DWORD PTR ds:0xb45dc0   ; 4.0 -- the interval
//	4a6ddc  mov  eax,0x4ac6f0            ; the slot-362 thunk -- the callback
//	4a6de6  push esi                     ; this
//	4a6de7  lea  edi,[esi+0x18c]         ; the timer list
//	4a6df0  call 0x4ab640                ; register
//
// It was missed because slot 362 is never called directly: the thunk's address
// appears exactly once in the whole image, at `0x004a6ddd`, as the immediate of
// that `mov`. A caller search finds nothing; only an address search does.
//
// WHAT THE TICK DOES, from the disassembly (the decompiled C loses the x87
// stack, which is where the whole formula lives):
//
//	if (GetLifeState() != 1) return;                      // must be alive
//	if (curHP == maxHP && curMP == maxMP) return;         // nothing to do
//	if (GetBodyMode() not in {0, 4}) return;
//	if (this[0xa2d]) {                                    // HP enabled
//	    amount = ftol(curHP * EvaluateParam(25) / 100.0)  // 'hprg', /100 at 0xb45af0
//	    if (amount < 1) amount = 1                        // FLOOR OF 1
//	    bound  = ftol(curHP * 0.5)                        // 0.5 at 0xb45c50
//	    ...
//	}
//	if (this[0xa2c]) { the same with EvaluateParam(26), 'mprg' }
//
// and it asserts against `GObjPC.cpp` line 0xdf9 (3577).
//
// TWO THINGS THAT MATTER HERE. The rate is a percentage of the **current**
// pool, not the maximum -- so regeneration accelerates as it fills. And the
// **floor of 1** means the engine's own unbuffed rate is not zero: `'hprg'` and
// `'mprg'` default to 0, so a live, damaged character recovers exactly 1 per
// tick with no buff at all. The old note reasoned "the parameters default to 0,
// therefore the rate is zero" and never saw the floor.
//
// The `bound` above is read but NOT implemented here: the comparison that
// applies it sits at `0x004e2c00`, which this pass did not read, so its
// direction is unknown and guessing it would be inventing a rule.
//
// Monsters do not use the parameters at all -- `CGObjMob::vslot_362`
// (`0x004c1b00`) takes its amount from `_RefObjCommon+0xd4`, which is
// characterdata **column 40**. Every one of the 52 `CHAR_` rows holds -1 there
// and the engine skips a negative, which is the two halves agreeing.
//
// RegenInterval is now REAL. RegenPercentPerTick stays OWN DESIGN:
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
// the engine's own rate is whatever `'mprg'` evaluates to, which is 0 without a
// buff, leaving only the floor of 1 per tick. srrevamp has no source of
// `'mprg'` at all, so shipping the engine's literal rate would mean 1 MP every
// four seconds for every caster in the game. 4% of the current pool is kept
// instead, as a disclosed deviation: the SHAPE is the engine's (a percentage of
// the current pool, floored at 1, applied on the engine's own interval), and
// only the percentage is ours.
const (
	RegenPercentPerTick = 4
	// RegenInterval is REAL: the float the timer registration hands to the
	// tick callback, `.rdata 0x00b45dc0` = 4.0. The unit is inferred as
	// seconds -- the same inference the berserk duration carries, and for the
	// same reason: nothing in the timer module converts it.
	RegenInterval = 4 * time.Second
)

// RegenHalfCapDivisor is the engine's ceiling on one tick: **half the current
// pool**.
//
// RECOVERED 2026-09-17. docs/SYSTEMS.md carried this as the system's one open
// item -- "the curHP*0.5 bound at 0x004e2c00 is read but its comparison is not"
// -- for as long as the row has existed. The comparison is at 0x004e2b4c, and
// the whole sequence reads:
//
//	004e2afb  cmp ebp,0x1 ; jge ; mov ebp,0x1   ; floor the amount at 1
//	004e2b05  fmul QWORD PTR ds:0xb45c50        ; cap = cur * 0.5
//	004e2b0b  call 0x9fbb40                     ; __ftol2, so TRUNCATED
//	004e2b4c  cmp ebp,edi ; jl ; mov ebp,edi    ; amount = min(amount, cap)
//
// `.rdata 0x00b45c50` is the double 0.5. `jl` keeps the amount when it is the
// smaller, so the pair is a min, and the cap is applied AFTER the floor at 1 --
// which is the only reason it ever binds.
//
// WHERE IT BINDS, which is the whole point. With RegenPercentPerTick at 4 the
// percentage term is 4% of the pool and the cap is 50% of it, so the cap is
// inert everywhere except at the very bottom, where the floor at 1 has pushed
// the amount above what the pool can support:
//
//	cur = 0  ->  cap 0, amount 0   (was 1)
//	cur = 1  ->  cap 0, amount 0   (was 1)
//	cur = 2  ->  cap 1, amount 1
//
// So **a character at 1 point does not passively regenerate at all**. That is a
// mechanic, not a rounding artifact: the engine spends four instructions to make
// the floor of 1 conditional on the pool being able to afford it.
const RegenHalfCapDivisor = 2

// RegenPerTick is what one tick restores to a pool holding cur out of max.
//
// The engine's shape, from CGObjPC::vslot_362: a percentage of the **current**
// pool, floored at 1, capped at half the current pool, and never more than the
// deficit. Percent-of-current is the part srrevamp had wrong -- it took a
// percentage of the maximum, which gives a drained caster the same trickle as a
// nearly-full one when the engine gives it less.
func RegenPerTick(cur, max int) int {
	if cur >= max || max <= 0 {
		return 0
	}
	if cur < 0 {
		cur = 0
	}
	amount := cur * RegenPercentPerTick / 100
	if amount < 1 {
		// The engine's own floor, and the reason its unbuffed rate is not
		// zero despite 'mprg' defaulting to 0.
		amount = 1
	}
	// The half-of-current cap, applied after the floor exactly as the engine
	// applies it. Integer division matches __ftol2's truncation toward zero.
	if cap := cur / RegenHalfCapDivisor; amount > cap {
		amount = cap
	}
	if deficit := max - cur; amount > deficit {
		amount = deficit
	}
	return amount
}

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
			// Each tick is a percentage of the pool as it stands, so the
			// ticks compound and cannot be multiplied out -- they are
			// applied in turn, stopping as soon as the pool is full.
			for i := 0; i < ticks; i++ {
				gain := RegenPerTick(cur, maxMP)
				if gain == 0 {
					break
				}
				cur += gain
			}
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
