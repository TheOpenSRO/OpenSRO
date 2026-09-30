package nest

import (
	"math"
	"math/rand"
)

// The READ hatch rules, pure: each takes its dice from a Dice standing in for
// the engine's MSVC rand() (0..32767), drawn in the engine's order, so a test
// can script every throw.

// CRandMax is the largest value the engine's rand() returns.
const CRandMax = 32767

// Dice is one throw of the engine's rand(): 0..CRandMax.
type Dice func() int

// RandDice is a Dice over rng.
func RandDice(rng *rand.Rand) Dice { return func() int { return rng.Intn(CRandMax + 1) } }

// GiantMonsterSpawnRatio is GiantMonster_SpawnRatio's default: the engine's
// own config key (.rdata 0xae0a04, read by CMainProcess::FUN_00427050 as
// atol(value)/100), 14 when absent or zero -- READ (monster_ai.md, "The
// _RefNest row", col 11). The shard's DB sets no such key (round 658), so the
// default stands.
const GiantMonsterSpawnRatio = 14

// HatchDelayMs is NestSlot_RollHatchDelay (0x560380), reached from
// AI::CNest::RollHatchDelay (0x560e40) with the nest row's columns 12 and 13
// in seconds:
//
//	lo = min * 1000 ; hi = max * 1000
//	interval = hi > lo ? lo + rand()/32767.0 * (hi - lo) : lo
//	part = (int)(interval * pct / 100.0)          ; pct: the hive's rate (0 here)
//	base = interval - part
//
// READ. pct is the percentage AIHive::AdjustHatchRateByPopulation sets from a
// region population sample that is not read (round 241); the scheduler passes
// 0, which is also what a hive without population scaling leaves.
func HatchDelayMs(dice Dice, minS, maxS int, pct float64) int {
	lo, hi := float64(minS)*1000, float64(maxS)*1000
	interval := lo
	if hi > lo {
		interval = lo + float64(dice())/CRandMax*(hi-lo)
	}
	part := int(interval * pct / 100.0)
	return int(interval) - part
}

// HalvedDelayMs is NestSlot_HalveHatchDelay (0x560e10): a hatch whose
// placement failed with out-flag 1 halves the nest's base, with a floor of
// 1000 ms, so it retries sooner. READ (round 239).
func HalvedDelayMs(base int) int {
	base /= 2
	if base < 1000 {
		base = 1000
	}
	return base
}

// HatchOffset is where a hatch lands relative to its nest, GObjPC::
// FUN_00531240, called by the spawn routine GObjPC::FUN_005f6eb0 (0x5f6f1b)
// with the nest row's column 10 (nGenerateRadius, pushed as a float by
// Nest_Hatch: `fild [esi+0x24]` at 0x560c51) and a minimum of 0.0 (`fldz` at
// 0x560c37). READ, asm and constants:
//
//	r <= 1e-6 (float 0xb45c84 = 358637bd)   -> no offset
//	r = max(r, 1.0) ; third = r / 3.0          ; `fdiv QWORD 0xb45ab8` = 3.0
//	roll = rand() % 101
//	base = roll < 70 ? 2*third : roll > 89 ? 0 : third   ; `cmp edx,0x46`, `cmp edx,0x5a`
//	d = rand()/32767.0 * third + base          ; 0xb45af8 = 32767.0
//	d = max(d, minimum)
//	a = rand()/32767.0 * 2pi + 0.0             ; 0xb45c18 = float32(2pi), 0xb45ab0 = 0.0
//	x += f(a) * d ; z += g(a) * d               ; FUN_00489490 / FUN_004894b0
//
// so 70 of 101 hatches land in the outer third of the circle, 20 in the
// middle third and 11 in the inner third. f and g are taken as cos and sin
// (INFERRED from the pair and their use; with a uniform angle the spread is
// the same either way).
func HatchOffset(dice Dice, radius float64) (dx, dz float64) {
	if radius <= 1e-6 {
		return 0, 0
	}
	r := math.Max(radius, 1.0)
	third := r / 3.0
	var base float64
	switch roll := dice() % 101; {
	case roll < 70:
		base = third + third
	case roll > 89:
		base = 0
	default:
		base = third
	}
	d := float64(dice())/CRandMax*third + base
	if d < 0 {
		d = 0
	}
	a := float64(dice())/CRandMax*float64(float32(2*math.Pi)) + 0.0
	return math.Cos(a) * d, math.Sin(a) * d
}

// Class is the monster class byte Nest_Hatch hands the spawn: the rank in the
// low nibble (0 normal, 1 champion, 4 giant, and a species' own 3/5/6/7/8)
// and the party flag 0x10 in the high one -- the byte the engine keeps at
// +0x1cd8 (GetMonsterClass slot 75 the low nibble, IsPartySupportMonster slot
// 193 `(byte & 0xf0) == 0x10`; combat/rarity.go).
type Class uint8

// ClassParty is the party flag.
const ClassParty Class = 0x10

// Rank is the low nibble.
func (c Class) Rank() int { return int(c & 0x0f) }

// Party reports the party flag.
func (c Class) Party() bool { return c&0xf0 == ClassParty }

// HatchInput is what the class roll reads of a nest and its species.
type HatchInput struct {
	// Rarity is the species' characterdata col 15 (refChar+0x89).
	Rarity int
	// TypeID4 is the species' fourth TypeID (the TID word's bits 11-15).
	TypeID4 int
	// PartyArmed is the nest's +0x30.
	PartyArmed bool
	// HasChampionTactics is the tactics row's col 41 (+0x8c) non-zero.
	HasChampionTactics bool
	// ChampionPct is the nest row's col 11 (+0x28).
	ChampionPct int
}

// HatchRoll is the class roll's outcome.
type HatchRoll struct {
	Class Class
	// Champion is true when the champion roll came up (champion or giant):
	// the monster then runs under the tactics row's col 41.
	Champion bool
}

// RollClass is Nest_Hatch's class decision (0x5607b0, READ from the
// decompile): for the monster TypeID shape (every species here), a species
// whose rarity is 5, 3, 8, 6, 7, 4 or 1 keeps it; any other (0) rolls, in
// this order --
//
//   - the party roll, only while the nest is armed (+0x30 == 1): rand() % 101
//     < 50 and the species' TID word is not the (…,4) shape (FUN_00561020:
//     `(w & 0xf800) == 0x2000`, TypeID4 4) -> the party flag 0x10;
//   - the champion roll, only when the tactics row names a champion row
//     (+0x8c non-zero): rand() % 101 < the nest's col 11, then rand() % 101 >
//     GiantMonster_SpawnRatio -> champion (| 1), else giant (| 4); the two OR
//     with the party flag.
//
// The engine then looks the champion row up and, when it does not exist,
// asserts and clears the rank (keeping the party flag) and runs the monster
// under its own row; the caller does that (Champion stays true only for a row
// that exists). giantRatio is GiantMonster_SpawnRatio.
func RollClass(dice Dice, in HatchInput, giantRatio int) HatchRoll {
	switch in.Rarity {
	case 1, 3, 4, 5, 6, 7, 8:
		return HatchRoll{Class: Class(in.Rarity)}
	}
	var c Class
	if in.PartyArmed && dice()%101 < 50 && in.TypeID4 != 4 {
		c = ClassParty
	}
	out := HatchRoll{}
	if in.HasChampionTactics && dice()%101 < in.ChampionPct {
		if dice()%101 > giantRatio {
			c |= 1
		} else {
			c |= 4
		}
		out.Champion = true
	}
	out.Class = c
	return out
}

// ClampClassByLevel is the field world's spawn (CGameWorld_Default slot 6,
// 0x5eb9a0, the unstripped base the field world runs -- round 658), which
// corrects the class by the species' level before the monster is made. READ
// from the asm, 0x5eb9f3..0x5eba7e (a switch on level/10 whose cases fall
// through):
//
//	level <= 10 and rank 4 (giant)  -> rank 1 (champion), party kept   ; `and bl,0xf1; or bl,1`
//	level  0..9 : party dropped, always                                ; `and bl,0xf`
//	level  0..19: party dropped when the rank is not 0
//	level  0..29: party dropped when the rank is not 0 or 1
//	level  0..39: party dropped when the rank is not 0, 1, 4 or 6
//	level 40+   : unchanged
//
// So no giant hatches below level 11, and no party monster below level 10.
func ClampClassByLevel(c Class, level int) Class {
	if level <= 10 && c&0x0f == 4 {
		c = c&0xf1 | 1
	}
	if level < 0 {
		level = 0
	}
	switch level / 10 {
	case 0:
		c &= 0x0f
		fallthrough
	case 1:
		if c&0x0f != 0 {
			c &= 0x0f
		}
		fallthrough
	case 2:
		if r := c & 0x0f; r != 0 && r != 1 {
			c = r
		}
		fallthrough
	case 3:
		if r := c & 0x0f; r != 0 && r != 1 && r != 4 && r != 6 {
			c = r
		}
	}
	return c
}

// PartyArmCount is the number of a party's members a kill must find to arm
// its nest: CAIState slot 7 (FUN_00558f20, the death command) sets the nest's
// +0x30 when the count it is handed is above 1 (`if (1 < param_3)`). The count
// is GObjPC::FUN_005bca60's: the exp-sharing party's members that are alive
// and within 1000.0 units (the double at 0xb45c68 = 408f400000000000). READ.
const PartyArmCount = 2

// PartyArmRange is that 1000.0.
const PartyArmRange = 1000.0
