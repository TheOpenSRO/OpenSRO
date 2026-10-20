package jobs

import (
	"math"
	"strings"
)

// The NPC thieves' and hunters' waves round a caravan (round 804;
// docs/protocol/jobs.md "NPC thieves and hunters"). READ in
// SR_GameServer.exe unless a line says otherwise. Each rule takes its dice
// from a function standing in for the engine's MSVC rand() (0..32767), drawn
// in the engine's order, so a test can script every throw.

// RandMax is the largest value the engine's rand() returns.
const RandMax = 32767

// WaveDelayMs is FUN_0060bd00 (s:0x60bd00): the next wave's delay,
// 60000 + ftol(float32(rand() / 32767.0) x 60000.0) -- 60 to 120 s.
func WaveDelayMs(dice func() int) int {
	f := float32(float64(dice()) / RandMax)
	return int(float64(f)*60000.0) + 60000
}

// WaveCountBase is FUN_0060c160 (s:0x60c160): from the trade value v (the
// trade scale's amount, s:0x60c1f0): 0 for no goods; with a bargain good
// (3/3/8/2) in the transport (COS vslot 188, +0x2f0) ftol((v x 1.55 - 1) /
// factor + 1) (1.55 the double 0xb46128); else 1 up to t1 (TRADESCALE's
// second threshold, 0xc826c4) and (v - 1) / factor + 1 above it. factor is
// TRADE_MON_FACTOR (0xc826d8, default 306).
func WaveCountBase(v uint32, t1, factor uint32, bargain bool) int {
	if v == 0 {
		return 0
	}
	if factor == 0 {
		factor = 306
	}
	if bargain {
		return int(math.Trunc((float64(v)*float64(float32(1.55))-1)/float64(factor) + 1))
	}
	if v <= t1 {
		return 1
	}
	return int((v-1)/factor + 1)
}

// WaveCount is FUN_0060c460 (s:0x60c460) on the base: 0 counts as 1; one
// more when float32(rand()/32767.0) >= 0.5; doubled when rand() % 100 < 2.
func WaveCount(base int, dice func() int) int {
	n := base
	if n == 0 {
		n = 1
	}
	if float32(float64(dice())/RandMax) >= 0.5 {
		n++
	}
	if dice()%100 < 2 {
		n *= 2
	}
	return n
}

// WaveTacticsID is the tactics row the wave's monsters run under (s:0x60bf9a
// .. 0x60c004): k = 3 when rand() is even, else rand() & 3; 2001 + k for a
// trader's caravan (NPC thieves), 2011 + k for anyone else's (NPC hunters).
// The shard's rows (MEASURED): aggressive, sight 250, 542 / 666 flags.
func WaveTacticsID(ownerJob byte, dice func() int) int64 {
	k := int64(3)
	if dice()%2 != 0 {
		k = int64(dice() & 3)
	}
	base := int64(2001)
	if ownerJob != StateTrader {
		base += 10
	}
	return base + k
}

// WaveMobKind is the wave's kind (s:0x60c03a): NPC thieves round a
// trader's caravan, NPC hunters round anyone else's.
func WaveMobKind(ownerJob byte) int {
	if ownerJob == StateTrader {
		return MobNPCThief
	}
	return MobNPCHunter
}

// WaveLevel is FUN_0060c4b0 (s:0x60c4b0): one wave monster's level from the
// trade scale index scale and the owner's level (the larger of his level and
// FUN_0059e870(+0xa30), a list's highest byte +0x20 -- OPEN which list;
// OpenSRO passes the character level for both): p = max(scale, 1), doubled
// when rand() % 100 < 2; then max(level - 4, 16) - ftol(float32(rand() /
// 32767.0) x -4.0) - 1 + p, i.e. max(level - 4, 16) - 1 + p + 0..3 (4 only at
// rand() == 32767).
func WaveLevel(scale, level int, dice func() int) int {
	p := scale
	if p < 1 {
		p = 1
	}
	if dice()%100 < 2 {
		p *= 2
	}
	base := level - 4
	if base < 16 {
		base = 16
	}
	f := float32(float64(dice()) / RandMax)
	k := int(float64(f) * -4.0) // ftol truncates toward zero
	return base - k - 1 + p
}

// WaveGroup is FUN_0060bdd0 (s:0x60bdd0): the region's ContinentName picks
// the monster table's group -- 0 CHINA, West_China, Oasis_Kingdom, Roc (the
// MOB_THIEF / MOB_HUNTER rows); 1 Eu, Am, Ca, DELTA, SD, KingsValley (the
// MOB_EU_ rows); anything else 2 (with an assert).
func WaveGroup(continent string) int {
	for _, c := range []string{"CHINA", "West_China", "Oasis_Kingdom", "Roc"} {
		if strings.EqualFold(continent, c) {
			return 0
		}
	}
	for _, c := range []string{"Eu", "Am", "Ca", "DELTA", "SD", "KingsValley"} {
		if strings.EqualFold(continent, c) {
			return 1
		}
	}
	return 2
}

// MobGroup is the table builders' grouping (s:0x6bb8a0 thieves, s:0x6bc5a0
// hunters): a code name starting MOB_THIEF / MOB_HUNTER is group 0,
// MOB_EU_THIEF / MOB_EU_HUNTER 1, any other 2.
func MobGroup(code string, kind int) int {
	up := strings.ToUpper(code)
	switch kind {
	case MobNPCThief:
		if strings.HasPrefix(up, "MOB_THIEF") {
			return 0
		}
		if strings.HasPrefix(up, "MOB_EU_THIEF") {
			return 1
		}
	case MobNPCHunter:
		if strings.HasPrefix(up, "MOB_HUNTER") {
			return 0
		}
		if strings.HasPrefix(up, "MOB_EU_HUNTER") {
			return 1
		}
	}
	return 2
}

// MobLevels is one kind's table: [group][level-1] the reference ids of that
// level's rows (levels 1..140).
type MobLevels [3][140][]int64

// Add files a row (s:0x6bb8a0: a level outside 1..140 is skipped with an
// assert).
func (t *MobLevels) Add(group, level int, id int64) {
	if group < 0 || group > 2 || level < 1 || level > 140 {
		return
	}
	t[group][level-1] = append(t[group][level-1], id)
}

// Pick is FUN_006bc4b0 / FUN_006bc760 (s:0x6bc4b0, s:0x6bc760): level 1 or
// below picks nothing; above 140 is 140; then the nearest filled level at or
// below it down to level 2 (the walk's `while (0 < idx)` never looks at
// level 1's rows), and a uniform rand() % n row of it. 0 when none.
func (t *MobLevels) Pick(group, level int, dice func() int) int64 {
	if group < 0 || group > 2 {
		return 0
	}
	idx := level - 1
	if idx < 1 {
		return 0
	}
	if idx > 139 {
		idx = 139
	}
	for ; idx > 0; idx-- {
		if rows := t[group][idx]; len(rows) > 0 {
			return rows[dice()%len(rows)]
		}
	}
	return 0
}

// WaveRadius is the spawn routine's ring radius for a wave monster (the
// float 0xb45f04 pushed at s:0x60c113): 150.0, its minimum 0.0 (fldz,
// s:0x60c105) -- nest.HatchOffset's ring.
const WaveRadius = 150.0

// WaveChampion is the class flag of a wave monster (s:0x60c0b1..0x60c0e6):
// rand() % 100 < 2 sets the low nibble 1 (champion), which the field world
// then clamps by level (nest.ClampClassByLevel).
func WaveChampion(dice func() int) bool { return dice()%100 < 2 }
