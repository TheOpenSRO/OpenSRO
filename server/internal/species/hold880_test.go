package species

import (
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
)

// Round 880: a skill row's hold base and blow count as the monster AI reads
// them (READ s:0x5a1a40: Basic_Activity 2 with an ActionDuration takes
// PreparingTime + CastingTime + ActionDuration, any other row its ReuseDelay).
func TestSkillRowHoldAndHits(t *testing.T) {
	rows := map[int64]*refdata.Skill{
		// An attack with a cast and an action: 947 + 1119 = 2066.
		880401: {ID: 880401, Activity: 2, CastingTimeMs: 947, ActionDurationMs: 1119, ReuseDelayMs: 2066, HitCount: 2, AIAttackChance: 100},
		// Action 2000, ReuseDelay 2500: the action time.
		880402: {ID: 880402, Activity: 2, ActionDurationMs: 2000, ReuseDelayMs: 2500, AIAttackChance: 100},
		// No ActionDuration: the ReuseDelay.
		880403: {ID: 880403, Activity: 2, CastingTimeMs: 500, ReuseDelayMs: 3000, AIAttackChance: 100},
		// Not Basic_Activity 2: the ReuseDelay.
		880404: {ID: 880404, Activity: 1, PreparingTimeMs: 100, CastingTimeMs: 200, ActionDurationMs: 700, ReuseDelayMs: 4000, AIAttackChance: 100},
	}
	lookup := RefdataLookup(func(id int64) (*refdata.Skill, error) { return rows[id], nil })
	for id, want := range map[int64][2]int{880401: {2066, 2}, 880402: {2000, 1}, 880403: {3000, 1}, 880404: {4000, 1}} {
		r, ok := lookup(id)
		if !ok || r.HoldMs != want[0] || r.Hits != want[1] {
			t.Errorf("skill %d: hold %d hits %d (ok %v), want %d and %d", id, r.HoldMs, r.Hits, ok, want[0], want[1])
		}
	}
	row := Row{Skills: [10]int64{880401}}
	a := row.Attacks(lookup)
	if !a.HasPrimary || a.Primary.HoldMs != 2066 || a.Primary.Hits != 2 {
		t.Errorf("the attack list's skill %+v, want hold 2066 and 2 blows", a.Primary)
	}
}
