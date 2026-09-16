// Package berserk implements the Silkroad berserk gauge: fighting fills a
// five-orb gauge, and when it is full the player can go berserk for a burst of
// extra damage before it empties. The mechanic is the real one; how fast the
// gauge fills and how long a berserk lasts are still this project's own
// disclosed design.
//
// HOW MUCH IT HITS FOR IS NOT. That one is recovered -- see DamageNumerator.
// Berserk is "Hwan" inside the game, which is why three sessions of grepping
// for "berserk" found nothing.
package berserk

import (
	"sync"
	"time"
)

const (
	// Max is a full gauge and each orb is Max/Orbs of it. Max and the gauge
	// SHAPE are own design; Orbs is not.
	//
	// **Orbs = 5 is RECOVERED.** `_CHAR.RemainHwanCount` (charData+0x86 in the
	// schema CharData_BindDBColumns spells out) is a persisted count, and
	// `CUsedItemLimit::FUN_004a05b0` refuses an item outright when it has
	// reached 5:
	//
	//	return (-(uint)(*(char *)(charData + 0x86) != '') & 0xffffe7c3) + 0x183e;
	//
	// which is a branchless ternary: not-5 yields 1 (allowed), 5 yields error
	// 0x183e. A limit that refuses at exactly 5 is a cap of 5, so the five
	// pips the client draws are five real charges rather than a display
	// choice.
	//
	// **The shape around it is still ours, and the engine's is different.**
	// The game persists a COUNT that an item can raise and a berserk spends;
	// this package fills a 0..100 gauge from combat. Those are different
	// mechanics that happen to agree on the number five, and nothing found so
	// far says how the real count is earned -- so FillPerHit below stays own
	// design rather than being dressed up as a fill rate for a gauge the game
	// does not have.
	Max  = 100
	Orbs = 5

	// FillPerHit is the gauge gained from one of the player's attacks (own
	// design): ~13 hits to fill from empty.
	FillPerHit = 8

	// Duration is how long a berserk lasts: **60 seconds**, RECOVERED.
	//
	// THIS CORRECTS THE PREVIOUS TICK, which concluded "the engine gives
	// berserk no timer at all" and said so with a mechanism and an
	// enumeration behind it. The mechanism was right; the enumeration was not.
	// It grepped the DECOMPILED dump for call sites of SetBodyMode, and the
	// berserk activation handler sits in a region Ghidra never recovered as a
	// function -- so "all eleven call sites" was all eleven *decompiled* ones.
	// The disassembly has a twelfth, and it is the one that matters.
	//
	// The activation handler (around 0x00515bfd, unindexed) does:
	//
	//	if (GetBodyMode() == 1)            -> error 3   // already berserk
	//	if (charData[0x86] < 5)            -> error 1   // not enough charges
	//	SetParam-free: FUN_004e4d00(-5)                 // SPEND ALL FIVE
	//	dur = GetParam(60) + GetParam(195)
	//	SetBodyMode(mode=1, stateSlot=0, dur, 0)
	//
	// and because the slot is 0 rather than 0xff, SetBodyMode takes its timer
	// branch and hands the duration to AJStateChanger, whose per-tick update
	// is a float countdown (`*(float *)(this+0x10) -= elapsed`).
	//
	// **The 60 is GObjPC_InitStats's own value for param 60**:
	// `ParamKeeper_SetParam(0, 0, _DAT_00b461bc)` with `fld DWORD ds:0xb461bc`
	// = 60.0f. Param 195 is `hwit` -- the client calls it
	// PARAM_HWAN_TIME_INCREASE -- and InitStats sets it to 0, its registry
	// default, so an unbuffed berserk is exactly 60 and a buffed one is longer.
	//
	// THE UNIT IS INFERRED, not read. What is recovered is the number 60 and
	// the fact that it counts down as a float against elapsed time; no
	// conversion appears in the AJStateChanger module, so the tick's delta unit
	// was never actually read. Seconds is the only reading that makes sense of
	// a float countdown from 60.0 with a buff term capped at 100, but it is an
	// inference and is labelled one.
	//
	// The charge model is now recovered too, and it is NOT this package's
	// gauge: berserk requires all five charges and spends all five at once.
	// srrevamp fills a 0..100 bar and activates when full, which is the same
	// shape by luck rather than by design -- see Max/FillPerHit, still own
	// design, and Orbs, which this path grounds for a third time (the spend is
	// literally -5 against a field clamped to [0, 5]).
	Duration = 60 * time.Second

	// DamageNumerator/DamageDenominator are the REAL berserk damage
	// multiplier: exactly 2, i.e. berserk doubles the blow. Recovered
	// 2026-09-15 by walking the whole chain rather than by finding a
	// constant:
	//
	//   IGObj::SetBodyMode       vtable slot 198 (0x004a9fc0) writes the
	//                            berserk flag at (*(this+0x30))+3. NAME
	//                            CORRECTED 2026-09-15: this comment used to
	//                            call it CGObjChar::SetBerserk, which was this
	//                            project's invention. The binary names it
	//                            itself -- the base class's own assert puts
	//                            IGObj::SetBodyMode at slot 198 -- and berserk
	//                            is one body mode rather than the whole
	//                            function. One implementation serves all 17
	//                            character classes, so the dump indexing it
	//                            under CGObjCOS_Summoned does not make it a
	//                            summon's: CGObjChar is in the same RTTI list,
	//                            which is why a PLAYER can carry param 189.
	//   IGObj::GetBodyMode       vtable slot 64 (0x004aa5b0) reads that same
	//                            byte -- which is what ties the two together.
	//                            NAME CORRECTED 2026-09-16: this said
	//                            CGObjChar::IsBerserk, which was again this
	//                            project's invention rather than the game's.
	//                            The binary names slot 64 itself, in the base
	//                            class's "## Illegal ##" stub string, and calls
	//                            it GetBodyMode -- the exact twin of
	//                            SetBodyMode at slot 198. The implementation at
	//                            0x004aa5b0 does return "is the body mode 1",
	//                            which is why the invented name looked right.
	//                            See docs/protocol/igobj_vtable.md.
	//   Combat_ResolveDamage     (0x0058e5f0) sets bit 2 of the damage flags
	//                            when the ATTACKER IsBerserk().
	//   Formula_MitigatePhysicalDamage (0x0040e450) and its magical twin
	//                            (0x0040e830) then use
	//                                multiplier = GetParam(189) + 2.0
	//                            in place of the 1.0 they use otherwise, and
	//                            multiply the damage by it.
	//
	// The 2.0 is the double at .rdata 0x00b45f30. Its two neighbours in the
	// same block are 0x00b45af0 = 100.0 and 0x00b45ac0 = 1.0, the two
	// constants of this engine's already-confirmed `/(1 + p/100)` idiom, so
	// the width is not a guess: all three read as 0.0 at float width because
	// a double's low word is zero, and only the double reading is coherent.
	// (At float width the multiplier would be 0.0 and a berserk attacker
	// would deal no damage at all.)
	//
	// Param 189 is a separate "berserk damage bonus" STAT that adds on top.
	// SetBodyMode's fifth argument grants it a base of 0.3 (float at
	// 0x00b45b8c) and clears it otherwise -- but every call site in the
	// binary passes 0 there bar one, so the plain multiplier is 2.0 and 2.3
	// is the special case. Nothing here models that stat yet, so it is left
	// out rather than folded in at a guessed rate.
	//
	// The damage pipeline additionally reads params 128-131, 178, 180, 187,
	// 188 and 259, and none of the three functions that establish a
	// character's baseline -- Char_PublishCombatStats, GObjMob_PublishStats,
	// GObjPC_InitStats -- writes any of them (they write only 0x0-0x25,
	// 0x34-0x3c, 0x8c/0x8d and 0xbe-0xc8). Their only writers are skill
	// effects and tagged item modifiers, which srrevamp has none of.
	//
	// RE-CHECKED 2026-09-16 against the dump's blind spot, because the writer
	// census above is a census over what Ghidra recovered rather than over the
	// binary -- the distinction that made the berserk-timer claim wrong. There
	// IS a fourth writer of 178-181, at 0x004a4570, in a 4.3 KB region Ghidra
	// never turned into a function. It does not change this conclusion: it
	// writes them with `SetParam(slot 2, ctx 5, ...)` and removes the same ids
	// at the same ctx, which is a keyed modifier being applied and taken away,
	// not a baseline. An unbuffed character has no ctx-5 entry, so the params
	// stay at the registry default.
	//
	// The load-bearing half is therefore the DEFAULT, not the writer census:
	// what makes these terms zero is that the registry says 0 and every writer
	// found -- visible or not -- is a keyed modifier. Stated that way it does
	// not depend on having seen every writer. See client/tools/ghidra/
	// dump_gaps.py, which is how the fourth one was found.
	//
	// A param nothing writes falls back to its DEFAULT, not to zero -- the
	// read path calls ParamKeeper_EnsureParam first, and
	// ParamKeeper_EvaluateParam uses the descriptor's default as the base
	// whenever slot 0 is empty. So "nothing writes it" settles nothing on its
	// own; the default has to be read.
	//
	// It has been. The descriptors are a static table at VA 0x00c64110 (120
	// params, 20 bytes each), and **every one of 128-131, 178, 180, 187, 188
	// and 259 defaults to 0**. Only seven params in the whole registry default
	// to anything else, all of them to 100, and none is on this list. See
	// docs/protocol/param_registry.md.
	//
	// So for an unbuffed character those terms really do evaluate to zero and
	// the damage pipeline here is complete -- now on the table's authority
	// rather than on the assumption.
	DamageNumerator   = 2
	DamageDenominator = 1
)

// Tracker holds each character's transient berserk state. Not persisted --
// berserk is in-the-moment combat state, cleared on disconnect like a duel.
type Tracker struct {
	mu          sync.Mutex
	gauge       map[int64]int
	activeUntil map[int64]time.Time
}

func NewTracker() *Tracker {
	return &Tracker{gauge: map[int64]int{}, activeUntil: map[int64]time.Time{}}
}

// Fill adds one attack's worth of gauge (capped at Max) and returns the new
// gauge value.
func (t *Tracker) Fill(characterID int64) int {
	t.mu.Lock()
	defer t.mu.Unlock()
	g := t.gauge[characterID] + FillPerHit
	if g > Max {
		g = Max
	}
	t.gauge[characterID] = g
	return g
}

// Gauge returns the current gauge (0..Max).
func (t *Tracker) Gauge(characterID int64) int {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.gauge[characterID]
}

// Activate goes berserk if the gauge is full, emptying it and returning true.
// A gauge that is not full is left untouched and false is returned.
func (t *Tracker) Activate(characterID int64) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.gauge[characterID] < Max {
		return false
	}
	t.gauge[characterID] = 0
	t.activeUntil[characterID] = time.Now().Add(Duration)
	return true
}

// Active reports whether the character is currently berserk.
func (t *Tracker) Active(characterID int64) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	return time.Now().Before(t.activeUntil[characterID])
}

// Boost applies the berserk damage multiplier to a base amount when active,
// else returns it unchanged.
//
// The real formula multiplies the damage that has ALREADY been through
// mitigation -- the multiplier is applied inside Formula_MitigatePhysicalDamage
// after the defence terms, not to the raw weapon roll. Callers that mitigate
// first and boost second match the game; one that boosted the raw roll would
// scale the defence away too.
func (t *Tracker) Boost(characterID int64, damage int) int {
	if !t.Active(characterID) {
		return damage
	}
	return damage * DamageNumerator / DamageDenominator
}

// Clear drops a character's state (on disconnect).
func (t *Tracker) Clear(characterID int64) {
	t.mu.Lock()
	defer t.mu.Unlock()
	delete(t.gauge, characterID)
	delete(t.activeUntil, characterID)
}
