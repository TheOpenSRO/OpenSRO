package statuseffect

// A target's own resistance to the abnormal states (round 881). Every rule is
// READ in SR_GameServer.exe; docs/protocol/status_resist.md has the chain.
//
// # The seventeen non-elemental states: a level, a probability and a percent
//
// A character carries, at +0xa30, one resist record per non-elemental state
// (17 of them, 24 bytes each, the first at +0x14): a map keyed by a LEVEL
// whose values are sets of (probability, buff id), and a list of (source,
// percent) entries.
//
//   - A buff or a passive whose row carries 'real' [mask, probability, level]
//     (CRefSkill +0x300) files (level -> probability) in the record of every
//     state its mask names (FUN_0059df20 s:0x59df20 -> FUN_00599840
//     s:0x599840, from ApplySkillParamsToChar s:0x595818; taken out again at
//     the buff's end, SkillAction_BuffEnd s:0x582cbd). The mask is the
//     client's state mask (bit 6 sleep ... bit 24 incubation).
//   - A worn item's 'rsli', 'rfei', 'rsti', 'rdii' or 'rcsi' option files its
//     value in the list of sleep, fear, stun, disease or combustion, and a
//     'rals' option in those of combustion, disease, sleep and fear
//     (Stat_ApplyTaggedModifier s:0x498690 -> Char_InsertResistEntry
//     s:0x59de70, the category in EAX: s:0x498fef..0x499018 and
//     s:0x49905e..0x4990f0).
//
// Each state's block in Combat_ApplyStatusEffects asks for its record
// (FUN_0059de50 s:0x59de50 -> FUN_005999e0 s:0x5999e0, the category in EAX)
// and gets three numbers: B, the HIGHEST level filed; A, the highest
// probability filed at that level; C, the sum of the list. Then (the sleep
// block, s:0x591013..0x59107a; the other sixteen are the same code):
//
//	if B != 0 {
//	    n = value[2] - B            ; the state's level less the resist's
//	    if n > 0: A is halved n times (cdq; sub eax,edx; sar eax,1 -- toward 0)
//	}
//	chance = chance - A + param 169 ; the level-scaled chance, the disease bonus
//	if C != 0 && chance > 0 { chance = ftol((1 - C/100) x chance) }
//	roll(chance)
//
// So a resist at or above the state's level takes its whole probability off
// the chance, and each level the state stands above it halves what it takes.
// Only the highest level filed counts: a second buff of a lower level adds
// nothing.
//
// # A chance of zero or less
//
// The dice (FUN_00599cc0 s:0x599cc0) return 0 at once for a chance of exactly
// 0, but a NEGATIVE chance is clamped to 0 and still rolled against the
// caster's accumulator: it comes up when the accumulator is at or above
// rand() % 101. A caster that has never rolled the state has 0 there, and a
// failed roll adds the clamped chance, 0, so every roll of a fully resisted
// state still lands about once in 101; having landed once, the accumulator
// stands at -100 and, with nothing added, that caster never lands it again.
// Roller implementations must keep that (session's statusRoller does).
//
// # The six elemental states: params 27..32 and 145..150
//
// strength = ftol((100 - p[27+i]) / 100 x value[0]) - ftol(p[145+i]); a
// percent of 100 or a strength of 0 or less lands nothing, and the duration
// is the strength times the state's unit (apply.go). p27..32 are written by
// a row's 'bgra' [mask, percent] (s:0x595698..0x5957ea) and by the worn
// items' options -- 'fz' writes 27 AND 28 (freezing and frostbite), 'es' 29,
// 'bu' 30, 'ps' 31, 'zb' 32, 'rals' all six (s:0x49871a..0x49886e,
// s:0x498f46) -- and capped at 100; p145..150 by a row's 'reat' [mask, value]
// (s:0x595542..0x595689). The mask bit is the state's client bit.

// ResistCategories is how many per-state resist records a character has.
const ResistCategories = 17

// resistCategoryOfBit maps a client state bit to its resist record (the
// order FUN_0059df20 walks its mask in: 0x40, 0x80, 0x100, 0x200, 0x400,
// 0x800, 0x2000, 0x4000, 0x8000, 0x10000, 0x20000, 0x40000, 0x80000,
// 0x100000, 0x200000, 0x400000, 0x1000000). READ.
var resistCategoryOfBit = map[int]int{
	6: 0, 7: 1, 8: 2, 9: 3, 10: 4, 11: 5, 13: 6, 14: 7, 15: 8, 16: 9,
	17: 10, 18: 11, 19: 12, 20: 13, 21: 14, 22: 15, 24: 16,
}

// The categories the item options name.
const (
	ResistCatSleep      = 0
	ResistCatFear       = 3
	ResistCatStun       = 7
	ResistCatDisease    = 8
	ResistCatCombustion = 15
)

// ResistCategory is the resist record a state's client bit reads, and
// whether it has one (the elemental six and bits 12 and 23 have none).
func ResistCategory(bit int) (int, bool) {
	c, ok := resistCategoryOfBit[bit]
	return c, ok
}

// ResistCategoriesOfMask lists the records a 'real' mask names, low bit
// first.
func ResistCategoriesOfMask(mask uint32) []int {
	var out []int
	for bit := 0; bit < 32; bit++ {
		if mask&(1<<uint(bit)) == 0 {
			continue
		}
		if c, ok := resistCategoryOfBit[bit]; ok {
			out = append(out, c)
		}
	}
	return out
}

// CatResist is one state's resist record as the block reads it.
type CatResist struct {
	// Level is B: the highest level any buff or passive filed. 0: none.
	Level int
	// Prob is A: the highest probability filed at that level.
	Prob int
	// Cut is C: the sum of the worn items' percent entries.
	Cut int
}

// File adds one 'real' entry (level -> probability) to the record, keeping
// what FUN_005999e0 would read back: the highest level, and the highest
// probability at it.
func (c *CatResist) File(level, prob int) {
	if level > c.Level || (level == c.Level && prob > c.Prob) {
		c.Level, c.Prob = level, prob
	}
}

// ResistedChance is what a non-elemental block rolls: the level-scaled
// chance less the resist's probability (halved once per level the state
// stands above the resist), plus the disease bonus, then cut by the items'
// percent. It may be 0 or negative; see "A chance of zero or less" above.
func ResistedChance(chance, stateLevel int, r CatResist, disease int) int {
	a := r.Prob
	if r.Level != 0 {
		for n := stateLevel - r.Level; n > 0 && a != 0; n-- {
			a /= 2 // cdq; sub eax,edx; sar eax,1: toward zero
		}
	}
	chance = chance - a + disease
	if r.Cut != 0 && chance > 0 {
		chance = int((1 - float64(r.Cut)/100) * float64(chance))
	}
	return chance
}

// ElementalStrength is an elemental state's strength after the target's
// resists, and whether the state lands at all: value[0] cut by the percent
// (p27..32; 100 or more refuses) less the flat (p145..150).
func ElementalStrength(value0, percent, flat int) (int, bool) {
	if percent >= 100 {
		return 0, false
	}
	s := int(float64(100-percent)/100.0*float64(value0)) - flat
	return s, s > 0
}

// MaxResistPercent is the cap params 27..32 have (param_registry.md).
const MaxResistPercent = 100
