package skill

import "math"

// Skill withdrawal -- the engine's skill reset -- recovered 2026-09-17 from
// SR_GameServer.exe. Nothing in OpenSRO offers the feature yet; this is the
// rule set it would have to implement, with the cost formula exact.
//
// See docs/protocol/skill_withdraw.md for the refusal ladder and the
// disassembly.
//
// HOW IT WAS FOUND. Not by reading functions: the widened error-code scan
// (client/tools/re/errsites.py) attributes 362 server functions to a named
// refusal, and four contiguous unnamed ones -- 0x0059f410, 0x0059f610,
// 0x0059f8b0, 0x0059fd60 -- raise nothing but WITHDRAW_SKILL_*. A whole system
// sitting in one address range, found by its vocabulary.

// The withdrawal refusal codes. 0x7800 is SUCCESS and is deliberately included:
// FUN_0059f410 returns it as the pass value and compares its helper's result
// against it, so it is part of the vocabulary rather than an absent code. It is
// not in docs/protocol/error_codes.md because that table lists refusals.
const (
	WithdrawOK                = 0x7800
	WithdrawFailNotLearn      = 0x7801
	WithdrawFailInvalidLevel  = 0x7802
	WithdrawFailUnknown       = 0x7803
	WithdrawFailNotEnoughGold = 0x7804
	WithdrawFailNotEnoughItem = 0x7805 // NOT_ENOUGH_POTION, the engine's word
	WithdrawFailDependency    = 0x7806
)

// WithdrawCostGoldScale and WithdrawCostMasteryDivisor are the two numbers in
// the cost formula, both read out of `.rdata`.
//
// The engine spells the scale as `(base / 0.8) * 80.0` -- `0x00b45bd0` = 0.8 and
// `0x00b45c58` = 80.0, both doubles -- which is base * 100. It is written here
// as the 100 it evaluates to, and the two constants are cited so a later reader
// can check the arithmetic rather than take it on trust.
const (
	WithdrawCostGoldScale      = 100
	WithdrawCostMasteryDivisor = 10.0 // `.rdata 0x00b45c60`
)

// WithdrawCost is what refunding one skill level costs in gold.
//
// RECOVERED from Formulae `0x00410c80`, which sums this term over the links of a
// skill's chain (each link at `skill + 0x59c`):
//
//	scale = (goldMin / 0.8) * 80.0                    ; = goldMin * 100
//	term  = __ftol2((masteryLevel/10.0 + 1.0) * scale + 0.5)
//
// `+ 0.5` before `__ftol2` -- which truncates, being the C cast -- is
// round-half-up, not a constant of the game.
//
// masteryLevel is the required mastery level of the link: the engine scans the
// skill's two mastery-requirement slots (ids at `+0xa0`/`+0xa4`) and takes the
// level byte (`+0xa8`/`+0xa9`) belonging to the FIRST slot with a non-zero id.
// A skill requiring no mastery contributes the bare `1.0` term.
//
// goldMin is the PER-LEVEL GOLD TABLE's minimum at the character's MaxLevel
// (vtable slot 74, `0x128`), not the current level: `0x00410c80` calls slot
// 0x128 and hands the result to `GObjPC::FUN_007243e0`, which looks the level up
// in the level-table manager's `+0x268` array and returns field `+4`. That the
// array is the gold table is settled by its other reader, `FUN_00724330`, which
// rolls `rand()%101 <= entry[0]` and then a range between `entry[1]` and
// `entry[2]` to fund `ITEM_ETC_GOLD_03` -- so `+0` is a chance percent and
// `+4`/`+8` are a min/max pair.
//
// THE INHERITED CAVEAT, stated rather than buried: this project believes that
// array is filled by the client's `levelgold.txt`, and that linkage is INFERRED,
// not proven -- the server references no refdata filename at all, loading from
// its database. See combat.RollGold, which carries the same caveat for the same
// table. The formula above is exact; the number you get out of it is only as
// good as that join.
func WithdrawCost(goldMin int64, masteryLevel int) int64 {
	if goldMin <= 0 {
		return 0
	}
	if masteryLevel < 0 {
		masteryLevel = 0
	}
	scale := float64(goldMin) * WithdrawCostGoldScale
	term := (float64(masteryLevel)/WithdrawCostMasteryDivisor + 1.0) * scale
	// math.Trunc, not math.Round: the engine adds 0.5 itself and then casts
	// through __ftol2. Doing both would round twice.
	return int64(math.Trunc(term + 0.5))
}

// WithdrawCostForLevels sums WithdrawCost over the levels being refunded.
//
// The engine walks the skill chain and stops at the first link whose own level
// is at or below the target -- `if (skill[+0x64] <= target) break` -- so a
// withdrawal to level `target` pays for every link ABOVE it and nothing else. A
// target of 0 is a full reset and pays for the whole chain, which is the other
// branch of the same function.
//
// masteryLevels must hold one entry per link being refunded, highest link
// first; the engine's per-link term depends on that link's own mastery
// requirement, not on a single value for the skill.
func WithdrawCostForLevels(goldMin int64, masteryLevels []int) int64 {
	var total int64
	for _, m := range masteryLevels {
		total += WithdrawCost(goldMin, m)
	}
	return total
}
