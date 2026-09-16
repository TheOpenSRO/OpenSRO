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

	// Duration is how long a berserk lasts. OWN DESIGN, and as of 2026-09-16
	// it has a PROVEN REASON rather than a failed search behind it: **this
	// server binary gives berserk no timer at all.**
	//
	// The proof is a mechanism plus an enumeration, not an absence of hits.
	//
	// 1. IGObj::SetBodyMode CAN carry a duration. Its fourth argument is a
	//    float, and near the end it does
	//
	//        if (param_3 != 0xff && 0.0 < param_4)
	//            *(float *)(state + 0x10) = param_4;
	//
	//    so a body mode is given a timed life only when the state-change slot
	//    is real and the float is positive.
	// 2. BERSERK IS BODY MODE 1. Combat_ResolveDamage reads GetBodyMode
	//    (vtable slot 64) and sets the berserk damage flag on `== 1`, which is
	//    the same byte at (*(this+0x30))+3 that SetBodyMode writes.
	// 3. All eleven SetBodyMode call sites were read, including the two whose
	//    arguments Ghidra lost. Exactly two carry a duration -- and both pass
	//    body mode **2**, not 1. Every mode-1 and every variable-mode site
	//    passes 0xff for the state-change slot, which is the value that skips
	//    the timer branch entirely.
	//
	// So the engine has a body-mode timer, uses it for another mode, and does
	// not use it for berserk. How a real berserk ends is therefore NOT a
	// duration this project failed to find; it is something else, and the
	// persisted `_CHAR.RemainHwanCount` beside Orbs above is the obvious
	// candidate -- a berserk spends a charge rather than running out a clock.
	// That is a hypothesis with no use-site and is not promoted.
	//
	// srrevamp's 20 seconds is therefore a straightforwardly invented timer for
	// a mechanic the game shapes differently, and is disclosed as one.
	//
	// (The Hwan REFERENCE TABLE `_REFHWANLEVEL` is real and its data ships in
	// Media.pk2, but it is a dead end for this question: the server loads it
	// and uses only its SIZE, to bounds-check the level
	// IGObj::UpdateHwanLevel will accept. No gameplay path reads its entries.)
	Duration = 20 * time.Second

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
	//   CGObjChar::IsBerserk     vtable slot 64 (0x004aa5b0) reads that same
	//                            byte -- which is what ties the two together.
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
