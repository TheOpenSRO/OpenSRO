// Package berserk implements the Silkroad berserk ("Hwan") charges: killing
// blows earn whole orbs by chance, five orbs let the player go berserk for a
// burst of doubled damage, and the berserk spends all five. Every number in
// the earn, the spend, the duration and the multiplier is now read from
// SR_GameServer.exe (2026-09-19 for the earn; see EarnOnKill).
//
// There is NO fractional gauge in the engine. The one piece of state is
// `_CHAR.RemainHwanCount` (charData+0x86, 0..5); this package used to fill a
// 0..100 bar per attack as its own design, and that is gone. The 0..100 value
// still crosses the wire (Gauge) only because the HUD lights orb i at
// gauge >= (i+1)*20 -- it is Charges * 20, nothing more.
//
// Berserk is "Hwan" inside the game, which is why three sessions of grepping
// for "berserk" found nothing.
package berserk

import (
	"math"
	"math/rand"
	"sync"
	"time"
)

const (
	// Max is the wire scale of the orb display (each orb is Max/Orbs of it);
	// Orbs is the engine's own cap, and the count behind it is the engine's
	// own state -- neither is a design choice any more.
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
	// **How the count is earned is RECOVERED too (2026-09-19)** -- see
	// EarnOnKill and the Gain* constants. The engine keeps only that count;
	// Max is the wire scale the HUD expects (orb i lights at gauge >=
	// (i+1)*Max/Orbs), and Gauge is Charges*Max/Orbs.
	Max  = 100
	Orbs = 5

	// THE EARN RULE, read off the binary function by function. The only
	// mover of charData+0x86 is GObjPC::AddHwanCount (0x004e4d00: delta in
	// ESI, clamp [0,5], no gain while GetBodyMode()==1, persist with dirty bit
	// 0x10). Its combat caller is the per-target apply pass FUN_00593800, and
	// the condition it fires on is written by Combat_ResolveDamage at the
	// KILLING blow (crd line 1150): when the accumulated damage reaches the
	// target's HP it sets effect+0x54 = 1 -- but only if the attacker is not
	// berserk (GetBodyMode()!=1) and the target answered IGObj::GetLifeState
	// (slot 62) == 1, i.e. was alive. The apply pass then requires the
	// attacker to be a PC (slot 7 IsPC), calls FUN_00410880(pc,&amount) for a
	// chance out of 10000, and on `rand()%10000 < chance` adds `amount`.
	//
	// FUN_00410880, from its asm (0x410880-0x4109c0):
	//
	//	amount = 1
	//	pct    = 8.0                                  ; .rdata 0xb45e14 (float), read
	//	if LevelGapClass(target-attacker) == 2:       ; target more than 3 below
	//	    pct = 8.0 - 0.25 * (attackerLvl - targetLvl - 5)  ; 0xb45eb0, 0xb45ca8 (doubles), read
	//	    pct = clamp(pct, 0.25, 8.0)              ; floor 0xb45b50 (float), read
	//	chance = ftol(pct * 100.0)                    ; 0xb45af0 -> units of 1/100 %
	//	if target.IsMonster():
	//	    switch target.GetMonsterClass():          ; slot 75; jump table 0x4109e8
	//	      3, 8: amount = 5; chance = 10,000,000   ; unique -- all five, certain
	//	      4:    chance *= 5                         ; giant
	//	      6:    chance *= 2                         ; elite
	//	if p := attacker.GetParam(184); p != 0:  chance = chance * p / 100
	//	return chance & 0xffff
	//
	// LevelGapClass is FUN_0040fe60: diff = target - attacker (bytes);
	// diff < -3 -> 2, diff < 11 -> 0, else 1. Classes 0 and 1 both keep the
	// 8% -- a much higher target earns no bonus; only a much lower one
	// decays, 0.25% per level past a five-level gap, to a 0.25% floor.
	//
	// Param 184 (registry: default 0, max 1000, no tag recovered) is the
	// engine's own gain modifier; srrevamp publishes no source for it, so it
	// is 0 here and the branch is inert -- carried as Kill.GainPercent so a
	// buff that sets it can reach it. The rarity values are characterdata
	// column 15's (0 normal, 1 champion, 3/8 unique, 4 giant, 5 titan, 6
	// elite), the same field combat.Monster.Rarity carries.
	GainBasePercent      = 8.0
	GainFloorPercent     = 0.25
	GainSlopePerLevel    = 0.25
	GainSlopeStartLevels = 5
	GainCertain          = 10000 // a chance at or past this always succeeds (the engine's 10,000,000 sentinel)
	UniqueGain           = 5

	// Monster ranks the earn switch names (characterdata col 15).
	RarityUnique  = 3
	RarityGiant   = 4
	RarityElite   = 6
	RarityUnique2 = 8

	// Level-gap classes of FUN_0040fe60.
	gapTooLow  = -3 // diff < -3: the target is more than three levels below
	gapTooHigh = 11 // diff >= 11: the target is eleven or more above

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
	//	dur = EvaluateParam(60) + EvaluateParam(195)
	//	SetBodyMode(mode=1, stateSlot=0, dur, 0)
	//
	// CITATION CORRECTED 2026-09-16: those two reads are NOT GetParam. They go
	// through `EvaluateParam` (0x004b3740) with the id in **EAX**, a second
	// param-read path that the vtable-0x104 grep cannot see:
	//
	//	515c5c  lea eax,[esi+0x41]   ; esi = -5, so eax = 0x3c = param 60
	//	515c5f  call 0x4b3740
	//	515c68  mov eax,0xc3         ; param 195
	//	515c6d  call 0x4b3740
	//
	// and param 60's id is COMPUTED rather than literal, so it is invisible to
	// an id-literal grep on either path. Grepping for `GetParam(195)` across
	// both dumps returns zero hits, which is how this citation came to be
	// checked at all. See docs/protocol/param_registry.md, "Params are read
	// through two paths".
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

// Kill is what EarnOnKill needs to know about a killing blow.
type Kill struct {
	KillerLevel     int
	VictimLevel     int
	VictimIsMonster bool
	// VictimRarity is characterdata column 15 (combat.Monster.Rarity); only
	// read when VictimIsMonster.
	VictimRarity int
	// GainPercent is the killer's param 184, the engine's own modifier
	// (chance = chance * GainPercent / 100 when non-zero). srrevamp has no
	// source for it yet; pass 0.
	GainPercent int
}

// LevelGapClass is FUN_0040fe60: the class of a victim's level against the
// killer's. 2 means the victim is more than three levels below, 1 eleven or
// more above, 0 anything between.
func LevelGapClass(killerLevel, victimLevel int) int {
	diff := victimLevel - killerLevel
	switch {
	case diff < gapTooLow:
		return 2
	case diff < gapTooHigh:
		return 0
	default:
		return 1
	}
}

// GainChance is FUN_00410880 without the dice: the chance in units of 1/100
// of a percent (compared against rand()%10000) and the orbs a success adds.
// Pure, so the table in the tests is the table in the binary.
func GainChance(k Kill) (chance int, amount int) {
	amount = 1
	pct := GainBasePercent
	if LevelGapClass(k.KillerLevel, k.VictimLevel) == 2 {
		pct = GainBasePercent - GainSlopePerLevel*float64(k.KillerLevel-k.VictimLevel-GainSlopeStartLevels)
		pct = math.Min(math.Max(pct, GainFloorPercent), GainBasePercent)
	}
	// ftol(pct * 100): every reachable pct is a multiple of 0.25, so the
	// product is an exact integer and the rounding mode cannot matter.
	chance = int(math.Round(pct * 100))
	if k.VictimIsMonster {
		switch k.VictimRarity {
		case RarityUnique, RarityUnique2:
			amount = UniqueGain
			chance = GainCertain
		case RarityGiant:
			chance *= 5
		case RarityElite:
			chance *= 2
		}
	}
	if k.GainPercent != 0 {
		chance = chance * k.GainPercent / 100
	}
	return chance, amount
}

// roll10000 is rand()%10000; swapped by tests to force the dice.
var roll10000 = func() int { return rand.Intn(10000) }

// Tracker holds each character's transient berserk state. Not persisted --
// the real count is a DB column, but srrevamp clears it on disconnect like a
// duel until the character store carries it.
type Tracker struct {
	mu          sync.Mutex
	charges     map[int64]int
	activeUntil map[int64]time.Time
}

func NewTracker() *Tracker {
	return &Tracker{charges: map[int64]int{}, activeUntil: map[int64]time.Time{}}
}

// EarnOnKill rolls the engine's hwan gain for a killing blow the character
// landed and returns the orbs it added (0, 1, or UniqueGain), the count
// clamped at Orbs. Nothing is earned while berserk is active -- both the
// killing-blow test in Combat_ResolveDamage and AddHwanCount itself refuse
// it. The victim must have been alive when the blow landed; callers only
// reach this on a kill, which is that condition.
func (t *Tracker) EarnOnKill(characterID int64, k Kill) int {
	t.mu.Lock()
	defer t.mu.Unlock()
	if time.Now().Before(t.activeUntil[characterID]) {
		return 0
	}
	chance, amount := GainChance(k)
	if chance < GainCertain && roll10000() >= chance {
		return 0
	}
	before := t.charges[characterID]
	after := before + amount
	if after > Orbs {
		after = Orbs
	}
	t.charges[characterID] = after
	return after - before
}

// Charges returns the character's orb count (0..Orbs) -- the engine's
// RemainHwanCount.
func (t *Tracker) Charges(characterID int64) int {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.charges[characterID]
}

// Gauge returns the wire value the HUD expects (0..Max): Charges scaled so
// that orb i lights at gauge >= (i+1)*Max/Orbs.
func (t *Tracker) Gauge(characterID int64) int {
	return t.Charges(characterID) * (Max / Orbs)
}

// Activate goes berserk if all Orbs charges are held, spending all of them
// (the handler's FUN_004e4d00(-5)) and returning true. Fewer charges leave
// the count untouched and return false (the handler's error 1).
func (t *Tracker) Activate(characterID int64) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.charges[characterID] < Orbs {
		return false
	}
	t.charges[characterID] = 0
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
	delete(t.charges, characterID)
	delete(t.activeUntil, characterID)
}
