package teleport

import "testing"

// Reach follows IsWithinInteractionRange (0x4a8e10) and FUN_00430ba0 /
// FUN_00430ce0 (round 642's review): same or neighbouring field regions only,
// the region-byte difference times 1920 on the axis it drives (the low byte,
// region y, on x; the high byte, region x, on z), and a length <= the limit.
func TestReach(t *testing.T) {
	jangan := regionIDFor(97, 168)
	cases := []struct {
		name       string
		from, to   Place
		limit      float64
		horizontal bool
		want       int
	}{
		{"on the spot", Place{jangan, 100, 0, 100}, Place{jangan, 100, 0, 100}, RangeNPC, true, 1},
		{"exactly the limit", Place{jangan, 100, 0, 100}, Place{jangan, 400, 0, 100}, RangeNPC, true, 1},
		{"just past it", Place{jangan, 100, 0, 100}, Place{jangan, 400.5, 0, 100}, RangeNPC, true, ErrTooFar},
		// Across the region edge in y (world x): local 1900 in 97/168 to local
		// 20 in 97/169 is 40 apart, not 1880.
		{"across a region edge", Place{jangan, 1900, 0, 500}, Place{regionIDFor(97, 169), 20, 0, 500}, RangeNPC, true, 1},
		// And in x (world z): local z 10 in 97/168 to 1900 in 96/168 is 30.
		{"across the other edge", Place{jangan, 500, 0, 10}, Place{regionIDFor(96, 168), 500, 0, 1900}, RangeNPC, true, 1},
		{"two regions over", Place{jangan, 1919, 0, 500}, Place{regionIDFor(97, 170), 0, 0, 500}, RangeStructure, true, ErrInteractionTarget},
		{"a dungeon and a field", Place{jangan, 0, 0, 0}, Place{-32767, 0, 0, 0}, RangeStructure, true, ErrInteractionTarget},
		{"two dungeons compare plainly", Place{-32767, 0, 0, 0}, Place{-32767, 100, 0, 0}, RangeNPC, true, 1},
		// The height counts in retail's 3-D length and not in OpenSRO's
		// horizontal mode (OURS, Reach's doc).
		{"3-D: a tower above", Place{jangan, 100, 0, 100}, Place{jangan, 100, 350, 100}, RangeNPC, false, ErrTooFar},
		{"horizontal: the same tower", Place{jangan, 100, 0, 100}, Place{jangan, 100, 350, 100}, RangeNPC, true, 1},
		{"a structure's limit", Place{jangan, 100, 0, 100}, Place{jangan, 890, 0, 100}, RangeStructure, true, 1},
	}
	for _, tc := range cases {
		if got := Reach(tc.from, tc.to, tc.limit, tc.horizontal); got != tc.want {
			t.Errorf("%s: Reach = %d; want %d", tc.name, got, tc.want)
		}
	}
}

// regionIDFor packs a region's x and y as the tables do, (x << 8) | y.
func regionIDFor(x, y int) int { return x<<8 | y }
