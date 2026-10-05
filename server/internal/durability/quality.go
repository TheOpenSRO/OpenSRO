package durability

import "math"

// The tooltip's "(+x%)": how far up its white-stat range an item rolled,
// and the instance stats it is taken from (round 732;
// docs/protocol/item_tooltip.md "The (+x%) formula"). READ from the
// client's equipment-stat line builder FUN_0066c5b0, its stat builder
// FUN_008bd980 and their x87 code; the client mirror is
// client/scripts/items/item_quality.gd, and both are checked against the
// same cases.
//
// plus is the item's effective plus, FUN_008ba570 + FUN_008ba4d0: the byte
// at +0x8c (the record's OptLevel, the advanced elixir already added on by
// c:0x8bb070) and the byte at +0x70 (whose writer is OPEN; OpenSRO sends 0).
// The stat builder adds the +0x70 byte only when ref +0x1d4 is non-zero
// (0x8bd99b); the line builder always adds it.

// IntStat is a whole-number instance stat (attack, hit, parry, block,
// critical): trunc((U - L) * (q / 31.0) + L + trunc(inc * plus)), READ at
// 0x8bdb75-0x8bdbd2 (fild U-L, q fdiv 31.0 at 0xddf2c8, fiadd L, inc *
// plus through FUN_00b42d10, faddp, FUN_00b42d10). Durability is the same
// with no plus term (0x8bdfdc).
func IntStat(l, u int32, q int, inc float32, plus int) int32 {
	bonus := 0.0
	if plus != 0 {
		bonus = math.Trunc(float64(inc) * float64(plus))
	}
	return int32(math.Trunc(float64(u-l)*(float64(q)/GroupMax) + float64(l) + bonus))
}

// FloatStat is a fractional instance stat (defence, absorption, the
// reinforce %): plus * inc + (q / 31) * (U - L) + L, stored as a float (the
// armour case 3 at c:0x8bd980; the reinforce ranges carry no plus term).
func FloatStat(l, u float32, q int, inc float32, plus int) float32 {
	// (U-L)*(q/31.0) in extended precision, + L, + inc*plus, rounded to a
	// float once at the store (c:0x8bde5e-0x8bde99; round 732 review F7).
	return float32((float64(u)-float64(l))*(float64(q)/GroupMax) + float64(l) + float64(inc)*float64(plus))
}

// QualityRangeInt is a min~max line of whole-number stats (phys/mag
// attack, 0x66c66f-0x66c841): for each end, f = (v - TRUNC(inc*plus) - L) /
// (U - L) as a float, 1 when U == L; the percent is trunc((f_lo + f_hi) *
// 0.5 * 100) -- 0xe1b7d0 is 0.5, 0xe1b7d8 is 100.0, FUN_00b42d10 truncates
// (cvttsd2si). The plus bonus is TRUNCATED, not rounded: the fistp at
// 0x66c6b6 runs under a control word or'd with 0xc00 (round toward zero),
// the same truncation IntStat applies. A v that goes negative after the
// plus comes off is converted as unsigned (the +2^32 at _DAT_00e1b7c8),
// exactly as the client does.
func QualityRangeInt(vLo, vHi, lLo, uLo, lHi, uHi int32, inc float32, plus int) int {
	off := int32(0)
	if plus != 0 {
		off = int32(math.Trunc(float64(inc) * float64(plus)))
	}
	return int(math.Trunc((float64(rangeEndInt(vLo-off, lLo, uLo)) + float64(rangeEndInt(vHi-off, lHi, uHi))) * 0.5 * 100.0))
}

func rangeEndInt(v, l, u int32) float32 {
	if float64(u)-float64(l) == 0 {
		return 1
	}
	fv := float32(v)
	if v < 0 {
		fv = float32(float64(uint32(v)))
	}
	return float32((float64(fv) - float64(l)) / (float64(u) - float64(l)))
}

// QualityRangeFloat is a min~max line of fractional stats (the
// physical/magical reinforce ranges, 0x66dc12 and 0x66df22): the same
// average; the client takes no plus off these.
func QualityRangeFloat(vLo, vHi, lLo, uLo, lHi, uHi float32) int {
	return int(math.Trunc((float64(rangeEndFloat(vLo, lLo, uLo)) + float64(rangeEndFloat(vHi, lHi, uHi))) * 0.5 * 100.0))
}

func rangeEndFloat(v, l, u float32) float32 {
	if float64(u)-float64(l) == 0 {
		return 1
	}
	return float32((float64(v) - float64(l)) / (float64(u) - float64(l)))
}

// QualitySingle is a one-value line (phys/mag defence and absorption, hit,
// parry, critical, block, a single reinforce; 0x66cd4a, 0x66d5a0,
// 0x66d6cf, ...): trunc((v - inc*plus - L) / (U - L) * 100) in double, and
// 100 outright when U == L (`mov ebx,0x64`, 0x66cd66). The client takes the
// plus off only on the four defence/absorption lines (inc at ref +0x1e8,
// +0x214, +0x200, +0x220), unrounded; the hit, parry, critical, block and
// reinforce lines pass plus 0 -- even where the stat itself carries a plus
// term. A whole-number stat comes in as float32(v).
func QualitySingle(v, l, u, inc float32, plus int) int {
	if float64(u)-float64(l) == 0 {
		return 100
	}
	if plus != 0 {
		// The unrounded product comes off, rounded once (c:0x66cd25-0x66cd33).
		v = float32(float64(v) - float64(inc)*float64(plus))
	}
	return int(math.Trunc((float64(v) - float64(l)) / (float64(u) - float64(l)) * 100.0))
}

// QualityDurability is the durability line's percent: the durability's
// variance group q (the byte at item +0x137, which c:0x8bd980 case 0
// stores) divided by 0.31 (0x66d316: fdiv by the double at 0xda1aa0, which
// holds the float 0.31 widened -- 0.3100000023841858), truncated. A
// perfect q = 31 therefore shows 99, not 100: that is the arithmetic as
// READ, not a choice.
func QualityDurability(q int) int {
	return int(math.Trunc(float64(q) / float64(float32(0.31))))
}
