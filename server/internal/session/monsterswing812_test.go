package session

import (
	"math"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/ai"
	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Round 812: a monster's swing is a skill command whose action holds it for
// the skill's PreparingTime + CastingTime + ActionDuration (READ: Handler_0e8
// 0x5472a0 posts 0x7070; phase 3 waits CastingTime + ActionDuration). A target
// that steps out of reach mid-swing is followed only once the action ends:
// stop, one swing, then the chase -- not a run that cuts the swing short.
func TestRound812SwingHoldsTheMonsterUntilItsActionEnds(t *testing.T) {
	battleForTest(t, true)
	f := startBattleFixture(t, 812, 0, 0)
	sp := chaseMangyang
	// Round 880: the hold is D + rand % D with D the action time (HoldMs); the
	// tests' randomness is off, so it is the 2400 ms it was here.
	sp.Skills = []combat.MonsterSkill{{ID: 160, ReuseMs: 3000, Range: 10, AttMin: 15, AttMax: 15, Chance: 100, ActionMs: 2400, HoldMs: 2400}}
	m := f.monsters.SpawnSpecies("jangan", sp, 10, 0, 0, 1000, 0, 15, 0)
	now := aiT0
	monsterAITick(now)
	now = now.Add(MonsterAITick)
	noteStruck(f.monsters, m.ID, f.aria)
	f.rec.reset()
	monsterAITick(now) // BATTLE, in reach: the first swing at once
	now = now.Add(MonsterAITick)
	if !waitFor(t, 2*time.Second, func() bool { return len(f.rec.strikesOf(m.ID)) == 1 }) {
		t.Fatalf("no swing in reach (%d)", len(f.rec.strikesOf(m.ID)))
	}
	// The target steps 50 units away just after the swing.
	f.hub.Relocate(f.ariaSession(t), world.Position{X: -50, Z: 0}, world.MoveRelocate, 0)
	// 2.4 s of action from the swing's tick: no leg before it ends.
	for i := 0; i < 22; i++ {
		monsterAITick(now)
		now = now.Add(MonsterAITick)
		if n := len(f.rec.of(m.ID)); n != 0 {
			t.Fatalf("a move pushed %d ms into the 2400 ms swing: %+v", (i+2)*100, f.rec.of(m.ID))
		}
	}
	for i := 0; i < 4; i++ {
		monsterAITick(now)
		now = now.Add(MonsterAITick)
	}
	moves := f.rec.of(m.ID)
	if len(moves) != 1 || moves[0].Mode != 1 {
		t.Fatalf("after the action: %d move(s) %+v, want the one chase leg", len(moves), moves)
	}
	if st := stateOf(t, f.a, m.ID); st != ai.StateBattle {
		t.Fatalf("state %v, want BATTLE", st)
	}
}

// Round 812: the chase keeps its leg while the walk points under 15 degrees
// off the line to the target (READ 0x4b0490, 0.2618 at 0xb462b8).
func TestRound812ChaseOffLine(t *testing.T) {
	cases := []struct {
		deg  float64
		want bool
	}{{0, false}, {10, false}, {14.9, false}, {15.1, true}, {90, true}, {180, true}}
	for _, c := range cases {
		r := c.deg * math.Pi / 180
		got := ChaseOffLine(0, 0, 100, 0, 100*math.Cos(r), 100*math.Sin(r))
		if got != c.want {
			t.Errorf("walk 0 deg, target at %g deg: off %v, want %v", c.deg, got, c.want)
		}
	}
	if !ChaseOffLine(0, 0, 0, 0, 10, 0) {
		t.Error("a walker with no leg is re-aimed")
	}
}

// Round 812: the back-off (READ 0x4b0490): closer than the two radii less 4,
// with the stop beyond the radii.
func TestRound812BackOff(t *testing.T) {
	// Radii 10 + 4 = 14, stop 23.
	if !BackOff(5, 14, 23) {
		t.Error("5 units inside radii 14 (stop 23) does not back off")
	}
	if BackOff(10, 14, 23) || BackOff(12, 14, 23) {
		t.Error("10 or more (radii - 4) backs off")
	}
	if BackOff(5, 14, 14) {
		t.Error("a stop not beyond the radii backs off")
	}
	if BackOff(0, 14, 23) {
		t.Error("a target exactly on the monster has no way back")
	}
}
