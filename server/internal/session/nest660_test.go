package session

import (
	"testing"

	"github.com/OpenSRO/OpenSRO/server/internal/ai"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// Round 660: a monster runs its own tactics row (a _RefTactics row, EXTERNAL,
// with its nest's radius) in place of the stand-ins. Every test here fails
// against the base revision, whose monsters are all aggressive, see 100 units
// and give up at 400 (the round's negative).

// A PASSIVE monster (column 7 = 1: AITactics_AcquireTarget scans only while
// the aggression byte is 0 or 3) never notices a player standing well inside
// its sight -- but a blow still engages it (CAIState::OnAttacked has no
// aggression test). An aggressive one (0) notices her on its first scan.
func TestPassiveMonsterDoesNotNoticeButFightsBack(t *testing.T) {
	battleForTest(t, true)
	deadStateForTest(t, true)
	aggroForTest(t, true)
	f := startBattleFixture(t, 660, 50, 0)
	passive := spawnWithTactics660(f.monsters, standingMangyang, 0, 0, 100, 1, 500, 700)
	aggressive := spawnWithTactics660(f.monsters, standingMangyang, 0, 60, 100, 0, 500, 700)
	now := aiT0
	for i := 0; i < 40; i++ {
		monsterAITick(now)
		now = now.Add(MonsterAITick)
		if st := stateOf(t, f.a, passive.ID); st == ai.StateBattle {
			t.Fatalf("tick %d: the passive monster noticed Aria 50 units off", i)
		}
	}
	if st := stateOf(t, f.a, aggressive.ID); st != ai.StateBattle {
		t.Fatalf("the aggressive monster 78 units from Aria is %v, want BATTLE", st)
	}
	noteStruck(f.monsters, passive.ID, f.aria)
	monsterAITick(now)
	if st := stateOf(t, f.a, passive.ID); st != ai.StateBattle {
		t.Fatalf("the struck passive monster is %v, want BATTLE: it fights back", st)
	}
	f.a.mu.Lock()
	target := f.a.brains[passive.ID].target
	f.a.mu.Unlock()
	if target != f.aria {
		t.Fatalf("the struck passive monster targets %d, want Aria %d", target, f.aria)
	}
}

// The sight is column 6: a monster whose row sees 200 notices a player 150
// units off, which the stand-in's 100 would not.
func TestSightRangeFromTactics(t *testing.T) {
	battleForTest(t, true)
	deadStateForTest(t, true)
	aggroForTest(t, true)
	f := startBattleFixture(t, 661, 150, 0)
	m := spawnWithTactics660(f.monsters, standingMangyang, 0, 0, 200, 0, 500, 700)
	if _, noticed := tickUntilBattle(t, f.a, m.ID, aiT0, 16); !noticed {
		t.Fatalf("a monster seeing 6 + 200 did not notice Aria 150 units off; state %v", stateOf(t, f.a, m.ID))
	}
}

// The leash is column 36 (TraceData): a monster whose row gives up at 150
// lets go of a target that steps 160 away (the reach test's nest path:
// ai.ChaseRange(150, radius 700, 0 from home) = 150), where the stand-in's
// 400 would keep chasing.
func TestLeashFromTactics(t *testing.T) {
	battleForTest(t, true)
	deadStateForTest(t, true)
	aggroForTest(t, false)
	f := startBattleFixture(t, 662, 100, 0)
	m := spawnWithTactics660(f.monsters, standingMangyang, 0, 0, 100, 0, 150, 700)
	now := aiT0
	monsterAITick(now) // the brain
	now = now.Add(MonsterAITick)
	noteStruck(f.monsters, m.ID, f.aria)
	monsterAITick(now)
	now = now.Add(MonsterAITick)
	if st := stateOf(t, f.a, m.ID); st != ai.StateBattle {
		t.Fatalf("struck from 100 units: %v, want BATTLE", st)
	}
	f.hub.Move(f.ariaSession(t), world.Position{X: 160, Z: 0})
	for i := 0; i < 3; i++ {
		monsterAITick(now)
		now = now.Add(MonsterAITick)
	}
	if st := stateOf(t, f.a, m.ID); st == ai.StateBattle {
		t.Fatalf("still in BATTLE with its target 160 units off and a give-up distance of 150")
	}
}
