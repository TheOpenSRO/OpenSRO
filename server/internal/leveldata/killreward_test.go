package leveldata

import (
	"math"
	"testing"
)

func near(a, b float64) bool { return math.Abs(a-b) < 1e-6 }

// party_rules.md "Worked examples": a Chinese party, every member in range,
// an ordinary monster, each member's multiplier on the base B.
func TestPartyShareWorkedExamples(t *testing.T) {
	for _, c := range []struct {
		name   string
		levels []int
		bonus  float64
		want   []float64
	}{
		{"2 x 50", []int{50, 50}, 1.1, []float64{0.55, 0.55}},
		{"4 x 50", []int{50, 50, 50, 50}, 1.3, []float64{0.325, 0.325, 0.325, 0.325}},
		{"8 x 50", []int{50, 50, 50, 50, 50, 50, 50, 50}, 1.7, []float64{0.2125, 0.2125, 0.2125, 0.2125, 0.2125, 0.2125, 0.2125, 0.2125}},
		// The 80 takes s = 0.8 > 0.7 in a party of three whose top level is
		// 21+: its bonus is damped to (1.2-1)*0.5+1 = 1.1.
		{"80, 10, 10", []int{80, 10, 10}, 1.2, []float64{0.88, 0.12, 0.12}},
	} {
		bonus := PartyShareBonus(len(c.levels), 0)
		if !near(bonus, c.bonus) {
			t.Fatalf("%s: bonus %v, want %v", c.name, bonus, c.bonus)
		}
		got := PartyShareMultipliers(c.levels, bonus, 1)
		for i := range got {
			if math.Abs(got[i]-c.want[i]) > 1e-6 {
				t.Errorf("%s: member %d multiplier %v, want %v", c.name, i, got[i], c.want[i])
			}
		}
	}
	// "4 free-for-all members, each kills alone": 1.09 to each killer.
	if m := FreeForAllMultiplier(4, false); !near(m, 1.09) {
		t.Fatalf("free-for-all 4/4: %v, want 1.09", m)
	}
	if m := FreeForAllMultiplier(0, false); m != 1 {
		t.Fatalf("no party: %v, want 1", m)
	}
	if m := FreeForAllMultiplier(4, true); !near(m, 0.545) {
		t.Fatalf("free-for-all 4/4 on a party monster below the receiver: %v, want 0.545", m)
	}
}

// The damping needs all three conditions: s > 0.7, three or more eligible,
// top level 21 or more.
func TestPartyShareDampingConditions(t *testing.T) {
	// Two members: no damping even at s = 0.8.
	got := PartyShareMultipliers([]int{80, 20}, 1.1, 1)
	if !near(got[0], 0.8*1.1) {
		t.Fatalf("party of two: %v, want undamped 0.88", got[0])
	}
	// Top level 20: no damping.
	got = PartyShareMultipliers([]int{20, 2, 2}, 1.2, 1)
	s := float64(float32(20) / float32(24))
	if !near(got[0], s*1.2) {
		t.Fatalf("top level 20: %v, want undamped %v", got[0], s*1.2)
	}
	// Exactly 0.7 is not above it: 70, 15, 15.
	got = PartyShareMultipliers([]int{70, 15, 15}, 1.2, 1)
	s = float64(float32(70) / float32(100))
	want := s * 1.2
	if s > PartyShareDampThreshold {
		want = s * 1.1
	}
	if !near(got[0], want) {
		t.Fatalf("s = 0.7: %v, want %v", got[0], want)
	}
}

func TestPartyShareBonusCountries(t *testing.T) {
	for _, c := range []struct {
		chinese, others int
		want            float64
	}{
		{0, 0, 1}, {1, 0, 1}, {8, 0, 1.7}, {0, 8, 2.4}, {0, 1, 1}, {3, 1, 1.3}, {2, 2, 1.4},
	} {
		if got := PartyShareBonus(c.chinese, c.others); !near(got, c.want) {
			t.Errorf("bonus(%d china, %d other) = %v, want %v", c.chinese, c.others, got, c.want)
		}
	}
}

func TestPartySharePenalty(t *testing.T) {
	if p := PartySharePenalty(false, 1, []int{50, 50}); p != 1 {
		t.Fatalf("ordinary monster: %v", p)
	}
	// Average (50+51)/2 = 50 by integer division: level 50 is not below it.
	if p := PartySharePenalty(true, 50, []int{50, 51}); p != 1 {
		t.Fatalf("party monster at the average: %v, want 1", p)
	}
	if p := PartySharePenalty(true, 49, []int{50, 51}); p != 0.5 {
		t.Fatalf("party monster below the average: %v, want 0.5", p)
	}
}

// vslot_359: 7.5 for a party monster, times the rank's factor; a rank outside
// the table drops even the party factor.
func TestMonsterExpFactor(t *testing.T) {
	for _, c := range []struct {
		party bool
		rank  int
		want  float64
	}{
		{false, 0, 1}, {true, 0, 7.5}, {true, 1, 15}, {false, 1, 2}, {true, 4, 112.5}, {false, 4, 15},
		{false, 5, 60}, {true, 6, 30}, {false, 7, 30}, {true, 3, 7.5}, {true, 8, 7.5}, {true, 2, 1}, {true, 9, 1},
	} {
		if got := MonsterExpFactor(c.party, c.rank); !near(got, c.want) {
			t.Errorf("factor(party %v, rank %d) = %v, want %v", c.party, c.rank, got, c.want)
		}
	}
}

func TestContributorShare(t *testing.T) {
	if s := ContributorShare(500, 1000); s != 0.5 {
		t.Fatalf("half: %v", s)
	}
	if s := ContributorShare(5000, 1000); s != 1 {
		t.Fatalf("overkill clamps to 1: %v", s)
	}
	if s := ContributorShare(1, 1e9); s != ContributorShareFloor {
		t.Fatalf("a scratch clamps to 1e-6: %v", s)
	}
	if s := ContributorShare(0, 1000); s != 0 {
		t.Fatalf("no damage: %v", s)
	}
}

// The two contributor formulas on a same-level kill: EXP = base x factor x
// share x 1 x lag x Diff, where Diff at a gap of 0 is 1 + 3*0.03 = 1.09.
func TestContributorFormulas(t *testing.T) {
	in := RewardInput{Base: 1000, MonsterFactor: 1, Share: 1, ReceiverLevel: 20, VictimLevel: 20,
		ExpLag: 1, SPLag: 1, ExpUnitReceiver: 1000}
	if got := ContributorExp(in); got != 1090 {
		t.Fatalf("EXP %d, want 1090", got)
	}
	// SP = 1000 * 100 / 1000 * 1.09 = 109.
	if got := ContributorSP(in); got != 109 {
		t.Fatalf("SP %d, want 109", got)
	}
	// Half the damage, a party monster (x7.5): 1000*7.5*0.5*1.09 = 4087.5 -> 4087.
	in.Share, in.MonsterFactor = 0.5, 7.5
	if got := ContributorExp(in); got != 4087 {
		t.Fatalf("party monster half share EXP %d, want 4087", got)
	}
	// Floors: a tiny result is 1, not 0.
	in = RewardInput{Base: 1, MonsterFactor: 1, Share: ContributorShareFloor, ReceiverLevel: 20, VictimLevel: 20,
		ExpLag: 1, SPLag: 1, ExpUnitReceiver: 1000}
	if ContributorExp(in) != 1 || ContributorSP(in) != 1 {
		t.Fatalf("floors: EXP %d SP %d, want 1 and 1", ContributorExp(in), ContributorSP(in))
	}
}

// vslot_420: float32 then multiply then truncate; the rate bonus only from
// 1.01, additive, SP too.
func TestRewardMultiplierAndRate(t *testing.T) {
	if e, s := ApplyRewardMultiplier(1000, 100, 0.55); e != 550 || s != 55 {
		t.Fatalf("x0.55: %d %d", e, s)
	}
	// float32 rounding first: 16777217 is not a float32, it becomes 16777216.
	if e, _ := ApplyRewardMultiplier(16777217, 0, 1); e != 16777216 {
		t.Fatalf("float32 rounding: %d", e)
	}
	if e, s := ApplyRateBonus(1000, 100, 1.0); e != 1000 || s != 100 {
		t.Fatalf("rate 1: %d %d", e, s)
	}
	if e, s := ApplyRateBonus(1000, 100, 1.005); e != 1000 || s != 100 {
		t.Fatalf("rate 1.005 is below the floor: %d %d", e, s)
	}
	if e, s := ApplyRateBonus(1000, 100, 0.5); e != 1000 || s != 100 {
		t.Fatalf("rate 0.5 lowers nothing: %d %d", e, s)
	}
	if e, s := ApplyRateBonus(1000, 100, 2.0); e != 2000 || s != 200 {
		t.Fatalf("rate 2: %d %d", e, s)
	}
}

func TestMasterySPScale(t *testing.T) {
	if s := MasterySPScale(40, 40); s != 1 {
		t.Fatalf("level with mastery: %v", s)
	}
	if s := MasterySPScale(40, 30); !near(s, 2) {
		t.Fatalf("ten levels of lag: %v, want 2 (unclamped)", s)
	}
	if s := MasterySPScale(130, 121); s != 1 {
		t.Fatalf("reference above 120: %v", s)
	}
}
