package session

import (
	"testing"

	"github.com/OpenSRO/srrevamp/server/internal/ai"
	"github.com/OpenSRO/srrevamp/server/internal/combat"
)

// Round 660's review: the brain must run the NEST's radius and the row's
// reach rule, not the stand-ins.

// spawnHomed660 spawns sp at (x, 0) with its home at the origin, under a row
// with the given roam radius and reach rule.
func spawnHomed660(monsters *combat.Hub, sp combat.Species, x float64, roam float64, flee uint8) combat.Monster {
	return *monsters.SpawnHatched("jangan", sp, x, 0, 0, 1000, 0, 15, 0, combat.Hatch{HomeX: 0, HomeZ: 0,
		Tactics: &combat.Tactics{ID: 7, SightRange: 100, AggressType: 1, TraceBoundary: 1, TraceData: 500, FleeType: flee, RoamRadius: roam}})
}

// A monster 300 from its nest is inside a 700 nest radius (col 9): IDLE, not
// HOMING -- the stand-in's 200 would send it home. The control with a 200
// radius does go home.
func TestBrainRunsTheNestRadius(t *testing.T) {
	battleForTest(t, false)
	aggroForTest(t, false)
	f := startBattleFixture(t, 663, 5000, 0)
	wide := spawnHomed660(f.monsters, chaseMangyang, 300, 700, 0)
	narrow := spawnHomed660(f.monsters, chaseMangyang, -300, 200, 0)
	monsterAITick(aiT0)
	if st := stateOf(t, f.a, wide.ID); st == ai.StateHoming {
		t.Fatalf("300 from its nest with a 700 radius: %v, want no HOMING", st)
	}
	if st := stateOf(t, f.a, narrow.ID); st != ai.StateHoming {
		t.Fatalf("control: 300 from its nest with a 200 radius: %v, want HOMING", st)
	}
}

// A row whose reach rule (col 40, btFleeType) is 1 lets go of its target at
// once (AITactics_TargetOutOfReach: 1 or 2 -> out of reach), where rule 0
// keeps a target 50 units off.
func TestBrainRunsTheReachRule(t *testing.T) {
	battleForTest(t, true)
	deadStateForTest(t, true)
	aggroForTest(t, false)
	f := startBattleFixture(t, 664, 50, 0)
	flees := spawnHomed660(f.monsters, standingMangyang, 0, 700, 1)
	stays := spawnHomed660(f.monsters, standingMangyang, 1, 700, 0)
	now := aiT0
	monsterAITick(now)
	now = now.Add(MonsterAITick)
	noteStruck(f.monsters, flees.ID, f.aria)
	noteStruck(f.monsters, stays.ID, f.aria)
	monsterAITick(now)
	now = now.Add(MonsterAITick)
	monsterAITick(now)
	if st := stateOf(t, f.a, flees.ID); st == ai.StateBattle {
		t.Fatalf("reach rule 1: still in BATTLE, want out of reach at once")
	}
	if st := stateOf(t, f.a, stays.ID); st != ai.StateBattle {
		t.Fatalf("control, reach rule 0: %v with the target 50 off, want BATTLE", st)
	}
}
