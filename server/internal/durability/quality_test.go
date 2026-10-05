package durability

import "testing"

// The (+x%) cases; client/scripts/items/item_quality_test.gd checks the GD
// mirror against the same table.
func TestQualityPercent(t *testing.T) {
	// A defence line: L 10, U 20, 1.5 a plus, +3 (c:0x8bd980 case 3).
	pd := func(q int) float32 { return FloatStat(10, 20, q, 1.5, 3) }
	// An attack end: L 10, U 20, 2.5 a plus, +3: TRUNC(7.5) = 7.
	atk := func(q int) int32 { return IntStat(10, 20, q, 2.5, 3) }
	cases := []struct {
		name string
		got  int
		want int
	}{
		{"int stat, top", int(atk(31)), 27},
		{"int stat, q 15", int(atk(15)), 21},
		{"int stat, bottom", int(atk(0)), 17},
		{"int stat, no plus", int(IntStat(10, 20, 31, 2.5, 0)), 20},
		{"single, top roll", QualitySingle(pd(31), 10, 20, 1.5, 3), 100},
		{"single, bottom roll", QualitySingle(pd(0), 10, 20, 1.5, 3), 0},
		{"single, q 15", QualitySingle(pd(15), 10, 20, 1.5, 3), 48},
		{"single, empty range", QualitySingle(7, 7, 7, 0, 0), 100},
		{"single, no plus off (hit, parry ...)", QualitySingle(15, 10, 20, 9, 0), 50},
		{"range, top and q 15", QualityRangeInt(atk(31), IntStat(30, 40, 15, 2.5, 3), 10, 20, 30, 40, 2.5, 3), 70}, // the stat truncates: 41, f 0.4
		{"range, top and middle", QualityRangeInt(27, 42, 10, 20, 30, 40, 2.5, 3), 75},
		{"range, both bottom", QualityRangeInt(17, 37, 10, 20, 30, 40, 2.5, 3), 0},
		// +1 of 2.7 is TRUNC(2.7) = 2, not 3.
		{"range, the plus bonus truncates", QualityRangeInt(22, 42, 10, 20, 30, 40, 2.7, 1), 100},
		{"range, an empty end counts 1", QualityRangeInt(5, 30, 5, 5, 30, 40, 0, 0), 50},
		{"range float (reinforce)", QualityRangeFloat(1.5, 3.0, 1, 2, 2, 4), 50},
		{"durability q 31 shows 99", QualityDurability(31), 99},
		{"durability q 0", QualityDurability(0), 0},
		{"durability q 15", QualityDurability(15), 48},
	}
	for _, c := range cases {
		if c.got != c.want {
			t.Errorf("%s: %d, want %d", c.name, c.got, c.want)
		}
	}
}
