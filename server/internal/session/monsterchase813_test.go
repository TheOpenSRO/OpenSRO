package session

import (
	"math"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/ai"
	"github.com/OpenSRO/OpenSRO/server/internal/combat"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// Round 813: the step's closest approach. A monster that ends its leg 0.04 s
// into a 0.1 s step stands while the target runs on: the closest is at its
// arrival, not at either end of the step.
func TestRound813ReachedDuringStep(t *testing.T) {
	// Monster 40 -> 35 at 120 u/s (arrives at 0.0417 s); the target 5 -> 0
	// at 50 u/s, away from it.
	got := reachedDuringStep(40, 0, 35, 0, false, 120, 5, 0, 0, 0, 0.1)
	want := 35 - (5 - 50*(5.0/120))
	if math.Abs(got-want) > 1e-9 {
		t.Fatalf("closest approach %.4f, want %.4f (at the arrival)", got, want)
	}
	if end := math.Hypot(0-35, 0); got >= end {
		t.Fatalf("closest %.3f is not under the step's end %.3f", got, end)
	}
	// Still walking all step: the end is the closest when closing.
	if got := reachedDuringStep(40, 0, 28, 0, true, 120, 5, 0, 0, 0, 0.1); math.Abs(got-28) > 1e-9 {
		t.Errorf("a closing walk's closest %.4f, want the end 28", got)
	}
	// A target put more than a step away (a teleport) is not interpolated.
	if got := reachedDuringStep(40, 0, 35, 0, false, 120, 500, 0, 0, 0, 0.1); math.Abs(got-35) > 1e-9 {
		t.Errorf("a teleported target's closest %.4f, want the pass's own 35", got)
	}
}

// Round 813: a monster chasing a target that runs straight away swings when
// it reaches the band between two passes. A 120 u/s chaser (BCRadius 15,
// range 9: stop 26, in reach at int(dist) <= 30) behind a 50 u/s runner
// reaches its leg's end mid-pass about 30 from the runner; by the pass's end
// the runner is 31+ away again. Before, the pass-end test alone re-aimed it
// for ever and it never swung (the user's video, 2026-10-23); the original
// tests the reach every frame (Tick_UseSkill 0x4ae590 phase 1 ->
// Action_IsTargetWithinReach 0x4ad4a0). Then it stands through its swing and
// chases again.
func TestRound813ChaserSwingsAtARunner(t *testing.T) {
	battleForTest(t, true)
	f := startBattleFixture(t, 813, 0, 0)
	sp := testMangyang
	sp.BCRadius, sp.WalkSpeed, sp.RunSpeed = 15, 16, 120
	sp.Skills = []combat.MonsterSkill{{ID: 182, ReuseMs: 1500, Range: 9, AttMin: 1, AttMax: 1, Chance: 100, ActionMs: 600}}
	m := f.monsters.SpawnSpecies("jangan", sp, 40, 0, 0, 1000, 0, 15, 0)
	now := aiT0
	monsterAITick(now)
	now = now.Add(MonsterAITick)
	noteStruck(f.monsters, m.ID, f.aria)
	f.rec.reset()
	px := 0.0
	swungAt := -1
	for i := 0; i < 30 && swungAt < 0; i++ {
		monsterAITick(now)
		now = now.Add(MonsterAITick)
		if st := stateOf(t, f.a, m.ID); st != ai.StateBattle {
			t.Fatalf("pass %d: state %v, want BATTLE", i, st)
		}
		if waitFor(t, 50*time.Millisecond, func() bool { return len(f.rec.strikesOf(m.ID)) > 0 }) {
			swungAt = i
		}
		px -= 5 // 50 u/s, straight away from the monster
		f.hub.Relocate(f.ariaSession(t), world.Position{X: px}, world.MoveRelocate, 0)
	}
	if swungAt < 0 {
		t.Fatal("a 120 u/s chaser never swung at a 50 u/s runner in 3 s")
	}
	cur, _ := f.monsters.Get(m.ID)
	if cur.Moving {
		t.Errorf("the monster swung on the move (dest %.1f)", cur.DestX)
	}
	// It stands through the swing's action, then follows again.
	for i := 0; i < 12; i++ {
		monsterAITick(now)
		now = now.Add(MonsterAITick)
		px -= 5
		f.hub.Relocate(f.ariaSession(t), world.Position{X: px}, world.MoveRelocate, 0)
	}
	if cur, _ := f.monsters.Get(m.ID); !cur.Moving && cur.X > px+40 {
		t.Errorf("after the swing the monster stands at %.1f with the runner at %.1f: no chase", cur.X, px)
	}
}
