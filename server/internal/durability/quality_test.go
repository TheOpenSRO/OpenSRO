package durability

import "testing"

// The (+x%) cases; client/scripts/items/item_quality_test.gd checks the GD
// mirror against the same table.
func TestQualityPercent(t *testing.T) {
	// A defence line: L 10, U 20, 1.5 a plus, +3, so v = 4.5 + q/31*10 + 10
	// as the client builds it (c:0x8bd980 case 3).
	pd := func(q int) float32 { return float32(3)*1.5 + (float32(q)/31)*(20-10) + 10 }
	cases := []struct {
		name string
		got  int
		want int
	}{
		{"single, top roll", QualitySingle(pd(31), 10, 20, 1.5, 3), 100},
		{"single, bottom roll", QualitySingle(pd(0), 10, 20, 1.5, 3), 0},
		{"single, q 15", QualitySingle(pd(15), 10, 20, 1.5, 3), 48},
		{"single, empty range", QualitySingle(7, 7, 7, 0, 0), 100},
		{"single, no plus off (hit, parry ...)", QualitySingle(15, 10, 20, 9, 0), 50},
		// Attack: low end L 10 U 20, high end L 30 U 40, 2.5 a plus, +3:
		// ROUND(7.5) = 8 (ties to even).
		{"range, top and middle", QualityRangeInt(28, 43, 10, 20, 30, 40, 2.5, 3), 75},
		{"range, both bottom", QualityRangeInt(18, 38, 10, 20, 30, 40, 2.5, 3), 0},
		// +1 of 2.5 is ROUND(2.5) = 2, not 3.
		{"range, a tie rounds to even", QualityRangeInt(22, 42, 10, 20, 30, 40, 2.5, 1), 100},
		{"range, an empty end counts 1", QualityRangeInt(5, 30, 5, 5, 30, 40, 0, 0), 50},
		{"range float (specialize)", QualityRangeFloat(1.5, 3.0, 1, 2, 2, 4), 50},
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
