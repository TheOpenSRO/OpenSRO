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
// The choice can stand on its own merits -- OpenSRO has no cross-session
// consequence that turns on a mana total -- but it is own design, and
// internal/character's EngineOnlyColumns records it as one with a test that
// keeps it stated.
package mana

import (
	"sync"
	"time"
)

// PASSIVE REGENERATION, SETTLED IN ROUND 607 (N sits down). Everything below is
// READ from SR_GameServer.exe unless it says otherwise; the history of how this
// note got here is at the end, because two earlier readings were wrong.
//
// THE TICK is CGObjPC::vslot_362 (0x004e2990), a per-character timer the
// character's constructor registers (CGObjChar::vslot_000, 0x4a6dd3..0x4a6df0:
// interval .rdata 0x00b45dc0 = 4.0, callback the slot-362 thunk 0x4ac6f0). The
// timer record starts at 0 elapsed (0x4ab640 stores fldz), and the list tick
// (0x4ab690) adds dt, fires at most once when the interval is reached and
// subtracts the interval -- so the first tick is 4 s after the character is
// made and the phase then holds. What the callback does, from the disassembly
// (the decompiled C loses the x87 stack):
//
//	if (GetLifeState() != 1) return;                              // 0x4e29a7
//	if (PKPenaltyPoint > 0 && <byte +2 of the object at +0x128's +0x10> == 0)
//	    { take trunc(MaxHP * 0.02) through slot 0x4fc; return; }  // 0xb45ec8, not modelled
//	if (status & 0x20) return;                                    // zombie, 0x4e2a37
//	if (MaxHP == CurHP && MaxMP == CurMP) return;                 // 0x4e2a7e
//	if (GetMotionState() not in {STAND 0, SIT 4}) return;         // 0x4e2a8a..0x4e2aa8
//	hp = 0; if (this[0xa2d]) {                                    // on unless a timed HP effect runs
//	    hp  = ftol(float(MaxHP) * EvaluateParam(25 'hprg') / 100.0)   // 100.0 at 0xb45af0
//	    hp  = max(hp, 1)                                          // 0x4e2afb
//	    cap = ftol(float(MaxHP) * 0.5)                            // 0.5 at 0xb45c50
//	    hp  = clamp(hp, 0, cap)                                   // CLAMP(), GObjPC.cpp:0xdf9
//	}
//	mp: the same with MaxMP, EvaluateParam(26 'mprg'), GObjPC.cpp:0xe02
//	ApplyHPMPDelta(hp, mp, 0x10)                                  // 0x4a86a0
//
// THE POOL IS THE MAXIMUM. The value multiplied is vtable slot 0x110 (0x114 for
// MP). In CGObjPC's vtable (0x00af59fc) that slot holds 0x4a6830, which is
// `ftol(EvaluateParam(3))` -- param 3 is 'hp', the computed maximum -- while the
// current HP is slot 0x108, 0x4aa5e0, which reads the stored value through
// charData's own vtable. So a tick restores a percentage of MAXHP/MAXMP, and
// the half cap is half the maximum, which never binds at these rates.
//
// THE RATES ARE THE MOTION STATE'S. SetMotionState (slot 343, 0x4a9d00)
// writes the base slot of params 25 and 26 on every call for a PC:
// 8.0 (.rdata 0x00b45e14) when the new state is SIT, 0.8 (.rdata 0x00b45b94)
// for any other state (0x4a9d3c..0x4a9d8d). CGObjChar's constructor calls
// SetMotionState(STAND) (0x4a6fd3..0x4a6fe8), and so does GObjPC::Revive
// (0x4df427), so every living PC carries 0.8 from the start: 0.8% of the
// maximum every 4 s standing still, 8% sitting, and nothing at all while
// walking, running or in the 1.5 s sit/stand transition.
//
// Worked: MaxHP 1000 -> 8 a tick standing, 80 sitting. MaxHP 200 -> 1 standing
// (the floor; 1.6 truncates to 1), 16 sitting.
//
// NOT MODELLED, disclosed: the PK-penalty branch (OpenSRO keeps no
// PKPenaltyPoint), the zombie status and the timed-effect switch (no status
// effects), skill buffs on 'hprg'/'mprg' (their slot-1/slot-3 writers are skill
// effects), and ApplyHPMPDelta's params 143/144 cut (no source of either).
//
// HISTORY. Until 2026-09-16 this note said there was no periodic regeneration
// at all; the timer was found then. That pass read slot 0x110 as the CURRENT
// pool and 'hprg'/'mprg' as 0 ("slot 0, the base, is never written"), and
// shipped an own-design 4% of current. Both halves were wrong: the slot is the
// maximum (docs/protocol/igobj_vtable.md had corrected the slot the same day,
// from other witnesses, without the regen note following), and the base IS
// written -- by SetMotionState, which param_writers.md (2026-09-18) already
// listed as a writer of params 25 and 26. The census the old note relied on
// counted skill-effect writes only.
const (
	// RegenInterval is REAL: the timer's float, `.rdata 0x00b45dc0` = 4.0,
	// in seconds (round 223: the timer vector is ticked by CGObjChar::Update
	// with the main loop's delta in seconds).
	RegenInterval = 4 * time.Second

	// StandRegenPercent is 'hprg'/'mprg' in every motion state but SIT: the
	// float at `.rdata 0x00b45b94`, which is 0.8 rounded to float32
	// (0.800000011920929). REAL.
	StandRegenPercent float32 = 0.8
	// SitRegenPercent is 'hprg'/'mprg' while SIT: `.rdata 0x00b45e14` = 8.0.
	// REAL.
	SitRegenPercent float32 = 8.0
)

// RegenHalfCap is the fraction of the maximum one tick may restore, the double
// 0.5 at `.rdata 0x00b45c50`, truncated through __ftol2 and applied after the
// floor at 1 (`cmp ebp,edi ; jl ; mov ebp,edi` at 0x4e2b4c). REAL. Against the
// MAXIMUM it binds only on a pool of 1, where the floor would otherwise hand
// out a whole point the cap of 0 does not allow.
const RegenHalfCap = 0.5

// RegenPerTick is what one tick restores to a pool whose maximum is max, at
// ratePercent ('hprg' or 'mprg'): trunc(max * rate / 100), floored at 1, then
// clamped to [0, trunc(max * 0.5)]. The engine clamps the sum to the maximum
// afterwards (the pool setters), which is the caller's store's job here.
//
// The arithmetic follows the x87 sequence: the pool is loaded with fild and
// stored as a FLOAT (`fstp DWORD PTR [esp+0x38]`), multiplied by the param in
// the FPU and divided by the double 100.0, then truncated. The rate is taken as
// the float32 the engine holds. Measured: for every pool from 1 to 2,000,000
// the truncated result is the same as with a float64 0.8, so this is fidelity
// to the arithmetic, not a difference anyone could see.
func RegenPerTick(max int, ratePercent float32) int {
	if max <= 0 {
		return 0
	}
	pool := float64(float32(max))
	amount := int(pool * float64(ratePercent) / 100.0)
	if amount < 1 {
		amount = 1
	}
	if cap := int(pool * RegenHalfCap); amount > cap {
		amount = cap
	}
	if amount < 0 {
		amount = 0
	}
	return amount
}

// Tracker holds live MP per character. The zero value is not usable; call
// NewTracker.
//
// It regenerates nothing by itself since round 607: passive recovery is the
// engine's per-character tick (session.RunRegen), which needs the motion state
// a lazy settlement here could not see.
type Tracker struct {
	mu      sync.Mutex
	current map[int64]int
}

func NewTracker() *Tracker {
	return &Tracker{current: map[int64]int{}}
}

// Current returns the character's MP. A character not seen before starts full.
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
		return maxMP
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
	return cur, true
}

// Restore adds amount back to the pool, never above maxMP, returning the new
// value. What a mana potion does, and what a regeneration tick does.
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
}

// Clear drops a character's state, on disconnect.
func (t *Tracker) Clear(characterID int64) {
	t.mu.Lock()
	defer t.mu.Unlock()
	delete(t.current, characterID)
}
