package session

import (
	"math"
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/ai"
	"github.com/OpenSRO/srrevamp/server/internal/combat"
)

// Round 661: a unique's summons and triggers in the running AI, on synthetic
// species. Everything of the round's new API goes through
// summon661_shim_test.go, so this file runs against the base revision with a
// stub shim: the round's negative.

// tigerGirl661 is a Summon_A unique: one attack skill, and four summon slots
// whose tuples name minion ids 1000+slot (so a summon's slot is read off what
// it spawned), each 2..3 of a minion of radius 12.
func tigerGirl661() uniqueSpec661 {
	u := uniqueSpec661{attacks: []combat.MonsterSkill{{ID: 196, ReuseMs: 3000, Range: 10, AttMin: 1, AttMax: 1, Chance: 100}}}
	for k := 0; k < 4; k++ {
		u.summons = append(u.summons, summonSpec661{
			skill:  combat.MonsterSkill{ID: int64(3049 + k), ReuseMs: 500, Chance: []int{80, 60, 40, 0}[k]},
			tuples: []tuple661{{id: int64(1000 + k), min: 2, max: 3, bc: 12, level: 30}},
		})
	}
	return u
}

// engage puts the unique in BATTLE with Aria and returns the clock.
func engage661(t *testing.T, f *battleFixture, id int64) time.Time {
	t.Helper()
	now := aiT0
	monsterAITick(now)
	now = now.Add(MonsterAITick)
	noteStruck(f.monsters, id, f.aria)
	monsterAITick(now)
	now = now.Add(MonsterAITick)
	if st := stateOf(t, f.a, id); st != ai.StateBattle {
		t.Fatalf("the struck unique is %v, want BATTLE", st)
	}
	return now
}

// tickUntilSummons ticks until the runtime has fired want summons or 30 s
// pass.
func tickUntilSummons(f *battleFixture, now time.Time, want int64) (time.Time, bool) {
	for i := 0; i < 300; i++ {
		if summons661(f.a) >= want {
			return now, true
		}
		monsterAITick(now)
		now = now.Add(MonsterAITick)
	}
	return now, summons661(f.a) >= want
}

// A unique that has lost a tenth of its MaxHP summons: the skill of its HP
// bucket's slot (above 80 %: the first), its tuple's 2..3 minions, each
// standing exactly its radius + 30 + the minion's radius from it, bound to
// it -- and nothing before the tenth.
func TestUniqueSummonsAtATenthOfItsHP(t *testing.T) {
	battleForTest(t, true)
	f := startBattleFixture(t, 6611, 0, 0)
	u := spawnUnique661(f.monsters, 5, 0, 100000, tigerGirl661())
	now := engage661(t, f, u.ID)
	f.monsters.ApplyDamage(u.ID, 9999)
	for i := 0; i < 100; i++ {
		monsterAITick(now)
		now = now.Add(MonsterAITick)
	}
	if n := summons661(f.a); n != 0 || len(minionsOf661(f.monsters, u.ID)) != 0 {
		t.Fatalf("9.999 %% of its HP lost: %d summons, want none", n)
	}
	f.monsters.ApplyDamage(u.ID, 1)
	now, ok := tickUntilSummons(f, now, 1)
	if !ok {
		t.Fatal("no summon within 30 s of losing a tenth of its HP")
	}
	minions := minionsOf661(f.monsters, u.ID)
	if len(minions) < 2 || len(minions) > 3 {
		t.Fatalf("%d minions, want the tuple's 2..3", len(minions))
	}
	cur, _ := f.monsters.Get(u.ID)
	for _, m := range minions {
		if m.RefObjID != 1000 {
			t.Fatalf("a minion of species %d, want 1000: the first slot's (HP %d%%, bucket 4)", m.RefObjID, cur.HP*100/cur.MaxHP)
		}
		if d := math.Hypot(m.X-cur.X, m.Z-cur.Z); math.Abs(d-70) > 0.01 {
			t.Fatalf("a minion stands %.3f from the unique, want 28 + 30 + 12 = 70", d)
		}
	}
	for i := 0; i < 100; i++ {
		monsterAITick(now)
		now = now.Add(MonsterAITick)
	}
	if n := summons661(f.a); n != 1 {
		t.Fatalf("%d summons with no more damage taken, want 1: the total is zeroed at each", n)
	}
}

// Each further tenth summons again, the slot by the HP bucket at the time:
// 90 and 80 % the first slot, 70 and 60 % the second, 50 and 40 % the third,
// below 40 % the fourth -- not once per bucket.
func TestUniqueSummonsEachTenthByBucket(t *testing.T) {
	battleForTest(t, true)
	f := startBattleFixture(t, 6612, 0, 0)
	u := spawnUnique661(f.monsters, 5, 0, 100000, tigerGirl661())
	now := engage661(t, f, u.ID)
	want := []int64{1000, 1000, 1001, 1001, 1002, 1002, 1003, 1003, 1003}
	seen := map[int64]bool{}
	for k, sp := range want {
		f.monsters.ApplyDamage(u.ID, 10000)
		var ok bool
		now, ok = tickUntilSummons(f, now, int64(k+1))
		if !ok {
			t.Fatalf("tenth %d: no summon", k+1)
		}
		fresh := 0
		for _, m := range minionsOf661(f.monsters, u.ID) {
			if seen[m.ID] {
				continue
			}
			seen[m.ID] = true
			fresh++
			if m.RefObjID != sp {
				t.Fatalf("tenth %d (HP %d%%): a minion of %d, want %d", k+1, 100-10*(k+1), m.RefObjID, sp)
			}
		}
		if fresh < 2 || fresh > 3 {
			t.Fatalf("tenth %d: %d new minions", k+1, fresh)
		}
	}
}

// The executor's cap: a tuple asking 60 spawns 50. Its class is the tuple's
// (a champion here, x2 HP) through the world's level clamp.
func TestSummonCountCapOf50(t *testing.T) {
	battleForTest(t, true)
	f := startBattleFixture(t, 6613, 0, 0)
	u := tigerGirl661()
	u.summons[0].tuples = []tuple661{{id: 1000, class: 1, min: 60, max: 60, bc: 12, level: 30}}
	m := spawnUnique661(f.monsters, 5, 0, 100000, u)
	now := engage661(t, f, m.ID)
	f.monsters.ApplyDamage(m.ID, 10000)
	if _, ok := tickUntilSummons(f, now, 1); !ok {
		t.Fatal("no summon")
	}
	minions := minionsOf661(f.monsters, m.ID)
	if len(minions) != 50 {
		t.Fatalf("%d minions, want the cap 50", len(minions))
	}
	if minions[0].Rarity != 1 || minions[0].MaxHP != 2000 {
		t.Fatalf("a minion of rank %d, %d HP: want the champion's rank 1 and twice 1000", minions[0].Rarity, minions[0].MaxHP)
	}
}

// Nothing unbinds or removes a minion when its unique dies (READ: the only
// sender of the unbinding command is the pets' path, and the executor keeps no
// list): the minions stay, still bound, as ordinary monsters.
func TestMinionsOutliveTheirUnique(t *testing.T) {
	battleForTest(t, true)
	f := startBattleFixture(t, 6614, 0, 0)
	u := spawnUnique661(f.monsters, 5, 0, 100000, tigerGirl661())
	now := engage661(t, f, u.ID)
	f.monsters.ApplyDamage(u.ID, 10000)
	now, ok := tickUntilSummons(f, now, 1)
	if !ok {
		t.Fatal("no summon")
	}
	before := minionsOf661(f.monsters, u.ID)
	if len(before) == 0 {
		t.Fatal("no minions")
	}
	if _, died, _ := f.monsters.ApplyDamage(u.ID, 1000000); !died {
		t.Fatal("the unique did not die")
	}
	for i := 0; i < 50; i++ {
		monsterAITick(now)
		now = now.Add(MonsterAITick)
	}
	after := minionsOf661(f.monsters, u.ID)
	if len(after) != len(before) {
		t.Fatalf("%d minions before the unique's death, %d after: they stay", len(before), len(after))
	}
}

// A _RefAISkill trigger of type 0 fires its skill once when the HP drops to
// its threshold, ahead of the draw, and never again that life -- and its
// skill is not on the attack list, so it is never drawn.
func TestHPTriggerFiresOnceAtItsThreshold(t *testing.T) {
	battleForTest(t, true)
	f := startBattleFixture(t, 6615, 0, 0)
	u := uniqueSpec661{
		attacks:  []combat.MonsterSkill{{ID: 12080, ReuseMs: 1000, Range: 10, AttMin: 1, AttMax: 1, Chance: 100}},
		triggers: []trigger661{{skill: combat.MonsterSkill{ID: 12087, ReuseMs: 1000, Range: 10, AttMin: 1, AttMax: 1, Chance: 100}, typ: 0, data: 50}},
	}
	m := spawnUnique661(f.monsters, 5, 0, 100000, u)
	now := engage661(t, f, m.ID)
	arms := func(ticks int) int {
		n, was := 0, false
		for i := 0; i < ticks; i++ {
			monsterAITick(now)
			now = now.Add(MonsterAITick)
			f.a.mu.Lock()
			b := f.a.brains[m.ID]
			is := b != nil && b.hasArmed && b.armed.ID == 12087
			f.a.mu.Unlock()
			if is && !was {
				n++
			}
			was = is
		}
		return n
	}
	f.monsters.ApplyDamage(m.ID, 49999)
	if n := arms(100); n != 0 {
		t.Fatalf("the trigger skill armed %d times at 50.001 %% HP, want 0", n)
	}
	f.monsters.ApplyDamage(m.ID, 1)
	if n := arms(200); n != 1 {
		t.Fatalf("the trigger skill armed %d times over 20 s at 50 %% HP, want exactly once", n)
	}
}
