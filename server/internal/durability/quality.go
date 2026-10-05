package durability

import "math"

// The tooltip's "(+x%)": how far up its white-stat range an item rolled
// (round 732; docs/protocol/item_tooltip.md "The (+x%) formula"). READ from
// the client's equipment-stat line builder FUN_0066c5b0 and its x87 code;
// the client mirror is client/scripts/items/item_quality.gd, and both are
// checked against the same cases.
//
// The plus taken off first is the item's effective plus: the OptLevel the
// record carries (+0x8c, the advanced elixir already added on by c:0x8bb070)
// plus the byte at item +0x70 (FUN_008ba4d0 + FUN_008ba570).

// QualityRangeInt is a min~max line of whole-number stats (phys/mag
// attack, 0x66c6xx-0x66c841): for each end, f = (v - ROUND(inc*plus) - L) /
// (U - L) as a float, 1 when U == L; the percent is trunc((f_lo + f_hi) *
// 0.5 * 100) -- 0xe1b7d0 is 0.5, 0xe1b7d8 is 100.0, FUN_00b42d10 truncates
// (cvttsd2si). ROUND is x87 fistp: to nearest, ties to even. A v that goes
// negative after the plus comes off is converted as unsigned (the +2^32 at
// _DAT_00e1b7c8), exactly as the client does.
func QualityRangeInt(vLo, vHi, lLo, uLo, lHi, uHi int32, inc float32, plus int) int {
	off := int32(0)
	if plus != 0 {
		off = int32(math.RoundToEven(float64(inc * float32(plus))))
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
// physical/magical specialize ranges, 0x66dc12 and 0x66df22): the same
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
// parry, critical, block, a single specialize; 0x66cd4a, 0x66d5a0,
// 0x66d6cf, ...): trunc((v - inc*plus - L) / (U - L) * 100) in double, and
// 100 outright when U == L (`mov ebx,0x64`, 0x66cd66). The client takes the
// plus off only on the four defence/absorption lines (inc at ref +0x1e8,
// +0x214, +0x200, +0x220); the hit, parry, critical, block and specialize
// lines pass plus 0. A whole-number stat comes in as float32(v).
func QualitySingle(v, l, u, inc float32, plus int) int {
	if float64(u)-float64(l) == 0 {
		return 100
	}
	if plus != 0 {
		v -= inc * float32(plus)
	}
	return int(math.Trunc((float64(v) - float64(l)) / (float64(u) - float64(l)) * 100.0))
}

// QualityDurability is the durability line's percent: the durability's
// 5-bit variance group q divided by 0.31 (0x66d316: the byte at +0x57,
// fdiv by the double at 0xda1aa0, which holds the float 0.31 widened --
// 0.3100000023841858), truncated. A perfect q = 31 therefore shows 99, not
// 100: that is the arithmetic as READ, not a choice.
func QualityDurability(q int) int {
	return int(math.Trunc(float64(q) / float64(float32(0.31))))
}
