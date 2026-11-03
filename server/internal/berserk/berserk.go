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
	// engine's own gain modifier; OpenSRO publishes no source for it, so it
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
	// THE UNIT IS READ (2026-09-19, round 223): the countdown is advanced by
	// the PC's periodic update CGObjPC::vslot_415 with a delta of 1.0 per call
	// (FUN_006560c0(pc+0x1dfc, 1.0f)), and vslot_415 is the callback of the
	// character's 1.0-second timer job (CGObjChar::Create registers the
	// slot-364 thunk with fld1; the timer vector is ticked by CGObjChar::Update
	// with the main loop's delta, GetTickCount milliseconds / 1000 -- see
	// docs/protocol/character_state.md). So 60.0 is sixty seconds. This note
	// used to call the unit an inference; it no longer is.
	//
	// The charge model is now recovered too, and it is NOT this package's
	// gauge: berserk requires all five charges and spends all five at once.
	// OpenSRO fills a 0..100 bar and activates when full, which is the same
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
	// effects and tagged item modifiers, which OpenSRO has none of.
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
	// (chance = chance * GainPercent / 100 when non-zero). OpenSRO has no
	// source for it yet; pass 0.
	GainPercent int
	// Source is the victim's uid (round 860): the 0x304E kind 4 a gain
	// sends names it (the killing blow's AddHwanCount, s:0x593b97), so the
	// client flies the violet orbs out of it.
	Source uint32
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

// Tracker holds each character's berserk state.
//
// The ORB COUNT is persisted as of 2026-09-20: it is `_CHAR.RemainHwanCount`
// on the engine's character row (charData +0x86, see
// docs/protocol/db_bind_offsets.tsv), and `character.Character.HwanCount`
// carries it here. Seed restores it when a character enters the world, and the
// combat paths write it back through `character.Store.SetHwanCount` whenever
// an orb is earned or spent.
//
// What remains transient is the ACTIVE window -- how long the berserk itself
// still has to run. The engine keeps that in live state too, and a character
// that logs out mid-berserk loses it here.
type Tracker struct {
	mu          sync.Mutex
	charges     map[int64]int
	activeUntil map[int64]time.Time
	// durationBonus is each character's timed contribution to param 60, the
	// berserk duration's base (see DurationBonus).
	durationBonus map[int64]timedBonus
	// turns serialise one character's orb changes with their persistence
	// (see Turn).
	turnsMu  sync.Mutex
	turns    map[int64]*sync.Mutex
	bonusGen uint64
	// notify is told every change of a character's count (SetNotify).
	notify func(characterID int64, count int, source uint32)
}

// SetNotify installs the count's announcer (round 860): GObjPC::AddHwanCount
// (s:0x4e4d00, READ) sends 0x304E {u8 4, u8 the new count, u32 the source}
// to the player alone (GObjPC::FUN_004e3fb0, the only 0x304E builder) after
// every change -- a kill's gain with the victim as the source, a potion's,
// a fill's or the activation's spend with 0. fn runs outside the tracker's
// lock; set it once, before play starts.
func (t *Tracker) SetNotify(fn func(characterID int64, count int, source uint32)) {
	t.notify = fn
}

func (t *Tracker) told(characterID int64, before, after int, source uint32) {
	if t.notify != nil && before != after {
		t.notify(characterID, after, source)
	}
}

type timedBonus struct {
	seconds int
	until   time.Time
	gen     uint64
}

func NewTracker() *Tracker {
	return &Tracker{charges: map[int64]int{}, activeUntil: map[int64]time.Time{},
		durationBonus: map[int64]timedBonus{}, turns: map[int64]*sync.Mutex{}}
}

// Turn takes the character's berserk turn and returns its release (round 632
// review). A caller that reads the orbs or the berserk state, spends an item,
// changes the orbs and persists them holds the turn across all of it, so a
// potion cannot be spent against a state a concurrent activation is changing.
// The engine needs no lock: the use and the activation both run on the PC's
// own thread. The tracker's own mu is never held across a store call.
func (t *Tracker) Turn(characterID int64) func() {
	t.turnsMu.Lock()
	m := t.turns[characterID]
	if m == nil {
		m = &sync.Mutex{}
		t.turns[characterID] = m
	}
	t.turnsMu.Unlock()
	m.Lock()
	return m.Unlock
}

// SetDurationBonus records a timed contribution of seconds to param 60 until
// the given time (round 632 review). Param 60 is the berserk duration's base
// (Duration's note: the activation reads EvaluateParam(60) +
// EvaluateParam(195), and GObjPC_InitStats sets 60 to 60.0). The Energy of
// life scroll's buff is a CTJ_CharParamKeeper timed job whose FourCC
// 0x706874 its table (CTJ_CharParamKeeper::FUN_006552d0, 0x6552fe) maps to
// param 0x3c = 60, slot 0, index 0; the job's apply (vslot_012, 0x655045 ->
// 0x655430 -> ParamKeeper_SetParam 0x4b3510) writes the job's value there,
// keyed by the job, and slot 0 SUMS its entries. So the value is seconds
// added to the base while the job runs. One per character: the engine
// refuses a second job with the same FourCC (FUN_00411560(10, fourcc),
// 0x49fd09 -> 0x1894).
func (t *Tracker) SetDurationBonus(characterID int64, seconds int, now time.Time, lasts time.Duration) {
	t.mu.Lock()
	t.bonusGen++
	gen := t.bonusGen
	t.durationBonus[characterID] = timedBonus{seconds: seconds, until: now.Add(lasts), gen: gen}
	t.mu.Unlock()
	// The job's own end (composite review): the entry goes when it runs out,
	// on real time, so a character who never returns leaves nothing behind.
	time.AfterFunc(lasts, func() {
		t.mu.Lock()
		defer t.mu.Unlock()
		if b, ok := t.durationBonus[characterID]; ok && b.gen == gen {
			delete(t.durationBonus, characterID)
		}
	})
}

// ClearDurationBonus ends the param-60 job early (the fill's last use does,
// CUsedItemLimit::vslot_007 -> FUN_004dd620 finds the type-10 job with
// FourCC 0x706874 and ends it).
func (t *Tracker) ClearDurationBonus(characterID int64) {
	t.mu.Lock()
	defer t.mu.Unlock()
	delete(t.durationBonus, characterID)
}

// DurationBonus returns the running param-60 contribution in seconds and
// when it ends, or 0 when none runs.
func (t *Tracker) DurationBonus(characterID int64, now time.Time) (int, time.Time) {
	t.mu.Lock()
	defer t.mu.Unlock()
	b, ok := t.durationBonus[characterID]
	if !ok {
		return 0, time.Time{}
	}
	if !now.Before(b.until) {
		delete(t.durationBonus, characterID)
		return 0, time.Time{}
	}
	return b.seconds, b.until
}

// EarnOnKill rolls the engine's hwan gain for a killing blow the character
// landed and returns the orbs it added (0, 1, or UniqueGain), the count
// clamped at Orbs. Nothing is earned while berserk is active -- both the
// killing-blow test in Combat_ResolveDamage and AddHwanCount itself refuse
// it. The victim must have been alive when the blow landed; callers only
// reach this on a kill, which is that condition.
func (t *Tracker) EarnOnKill(characterID int64, k Kill) int {
	t.mu.Lock()
	if time.Now().Before(t.activeUntil[characterID]) {
		t.mu.Unlock()
		return 0
	}
	chance, amount := GainChance(k)
	if chance < GainCertain && roll10000() >= chance {
		t.mu.Unlock()
		return 0
	}
	before := t.charges[characterID]
	after := before + amount
	if after > Orbs {
		after = Orbs
	}
	t.charges[characterID] = after
	t.mu.Unlock()
	t.told(characterID, before, after, k.Source)
	return after - before
}

// EnsureSeeded installs a character's STORED orb count the first time the
// character is seen, clamped to the legal range, and does nothing afterwards.
//
// Seeding is lazy because a session has no single "entered the world" moment --
// it resolves a character per request -- and seed-once matters: the live count
// is the authority once play has started, so a later re-seed from a stale row
// would undo orbs earned since.
//
// It does not touch the active window, which is not persisted.
func (t *Tracker) EnsureSeeded(characterID int64, stored int) {
	if stored < 0 {
		stored = 0
	}
	if stored > Orbs {
		stored = Orbs
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	if _, seen := t.charges[characterID]; seen {
		return
	}
	t.charges[characterID] = stored
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

// PotionCharges is what a berserk potion adds: the literal 5 CGItemExpendable
// slot 308 hands AddHwanCount for TypeID 3/3/1/8 (0x0049b9d1 `mov esi,0x5`,
// then 0x49b9d6 `call 0x4e4d00`), READ from srv.asm (round 632). It is not
// the row's Param1, although every 3/3/1/8 row in Media.pk2's itemdata
// carries 5 there too; the composite-item path (CUsedItemLimit::FUN_004a0600,
// 0x4a062b `movzx esi,BYTE [esp+0x14]`) is the one that reads Param1.
const PotionCharges = 5

// Add is GObjPC::AddHwanCount (0x004e4d00): delta orbs, refused outright when
// positive while berserk is active (the GetBodyMode()==1 test at its head),
// the result clamped to [0, Orbs]. It returns the orbs actually added.
func (t *Tracker) Add(characterID int64, delta int) int {
	t.mu.Lock()
	if delta == 0 {
		t.mu.Unlock()
		return 0
	}
	if delta > 0 && time.Now().Before(t.activeUntil[characterID]) {
		t.mu.Unlock()
		return 0
	}
	before := t.charges[characterID]
	after := before + delta
	if after < 0 {
		after = 0
	} else if after > Orbs {
		after = Orbs
	}
	t.charges[characterID] = after
	t.mu.Unlock()
	t.told(characterID, before, after, 0)
	return after - before
}

// SetCharges puts the character's orb count at n, clamped to 0..Orbs -- the
// GM console's /hwan (OURS, a test tool; round 629's review). It does not
// touch an active berserk.
func (t *Tracker) SetCharges(characterID int64, n int) int {
	if n < 0 {
		n = 0
	}
	if n > Orbs {
		n = Orbs
	}
	t.mu.Lock()
	before := t.charges[characterID]
	t.charges[characterID] = n
	t.mu.Unlock()
	t.told(characterID, before, n, 0)
	return n
}

// Activate goes berserk if all Orbs charges are held, spending all of them
// (the handler's FUN_004e4d00(-5)) and returning true. Fewer charges leave
// the count untouched and return false (the handler's error 1). A berserk
// already running is refused first, count untouched: READ,
// GObjPC_HandleBerserkMsg_0a7 (0x515b30) sends error 3 when GetBodyMode()
// answers 1 for an activation request -- before it looks at the count -- and
// also for body modes 3 and 4, which OpenSRO never sets. Its error 4 for
// body mode 2 (the invincible spell after a revive or a world entry) is not
// modelled: OpenSRO has no body mode 2 (OPEN).
func (t *Tracker) Activate(characterID int64) bool {
	t.mu.Lock()
	now := time.Now()
	if now.Before(t.activeUntil[characterID]) {
		t.mu.Unlock()
		return false
	}
	before := t.charges[characterID]
	if before < Orbs {
		t.mu.Unlock()
		return false
	}
	t.charges[characterID] = 0
	d := Duration
	if b, ok := t.durationBonus[characterID]; ok && now.Before(b.until) {
		d += time.Duration(b.seconds) * time.Second
	}
	t.activeUntil[characterID] = now.Add(d)
	t.mu.Unlock()
	// The handler's AddHwanCount(-5) (round 860): 0x304E {4, 0, 0}.
	t.told(characterID, before, 0, 0)
	return true
}

// ActiveUntil is when the character's current (or last) berserk ends; the
// zero time for one never activated. The end push compares it, so a berserk
// that was started again is not ended by the older one's timer.
func (t *Tracker) ActiveUntil(characterID int64) time.Time {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.activeUntil[characterID]
}

// End ends a running berserk now and reports whether one was running; the
// orbs are left as they are. GObjPC::Revive (0x4df290) ends it by setting
// body mode 2 (SetBodyMode(2, 0, 6.0 or 11.0 s, 0), 0x4df46c..0x4df484), and
// the world entry CGObjPC::vslot_391 (0x4df9e0, run by CGame::EnterWorld
// 0x417240) by setting body mode 2 or 4 -- any mode but 1 is the end of a
// berserk. The end timer of the activation it ends then stands down, as
// ActiveUntil no longer matches.
func (t *Tracker) End(characterID int64) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	until, ok := t.activeUntil[characterID]
	if !ok || !time.Now().Before(until) {
		return false
	}
	delete(t.activeUntil, characterID)
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

// Forget drops a character's state (on disconnect).
func (t *Tracker) Forget(characterID int64) {
	t.mu.Lock()
	defer t.mu.Unlock()
	delete(t.charges, characterID)
	delete(t.activeUntil, characterID)
	// A RUNNING durationBonus is kept: it is a timed job, which the engine
	// keeps across a relog (its jobs carry __time32_t stamps), and its own
	// timer (SetDurationBonus) deletes it when it runs out. An expired one
	// goes now. OpenSRO keeps it in memory, so a restart loses it --
	// disclosed.
	if b, ok := t.durationBonus[characterID]; ok && !time.Now().Before(b.until) {
		delete(t.durationBonus, characterID)
	}
	// The turn goes too (composite review), unless someone holds it -- a
	// request still in flight for this character keeps the mutex it locked.
	t.turnsMu.Lock()
	if m, ok := t.turns[characterID]; ok && m.TryLock() {
		delete(t.turns, characterID)
		m.Unlock()
	}
	t.turnsMu.Unlock()
}
