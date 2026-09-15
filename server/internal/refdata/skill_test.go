package refdata

import "testing"

// TestHitsForReadsTheEngineDefault pins that a skill with no 'mc' parameter,
// or one carrying a value the engine itself rejects, strikes exactly once.
//
// The engine initialises the count to 1 and asserts it is non-zero, so 0 is a
// bug state rather than "no attack" -- 35 real skill rows carry (2, 0) and
// would trip that assert.
func TestHitsForReadsTheEngineDefault(t *testing.T) {
	for _, tc := range []struct {
		name string
		sk   *Skill
		want int
	}{
		{"an export predating the column", &Skill{}, 1},
		{"the engine's own default", &Skill{HitCount: 1}, 1},
		{"a two-hit skill", &Skill{HitCount: 2}, 2},
		{"the highest in the real table", &Skill{HitCount: 5}, 5},
		{"a value the engine asserts against", &Skill{HitCount: 0}, 1},
		{"a negative never means no attack", &Skill{HitCount: -3}, 1},
		{"a nil skill", nil, 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := tc.sk.HitsFor(); got != tc.want {
				t.Errorf("HitsFor() = %d, want %d", got, tc.want)
			}
		})
	}
}
