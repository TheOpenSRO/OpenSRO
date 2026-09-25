package ai

import (
	"math/rand"
	"testing"
)

// Two seats, the engine's credit codes, the hate formula with its clamp, and
// the drop when a target's hate falls below 1.
func TestThreatCredit(t *testing.T) {
	var tt ThreatTable
	code, drop := tt.Credit(7, 45, 51, 0, 1000)
	if code != CreditTarget || drop || tt.Target.ID != 7 || tt.Target.Hate != 51 || tt.Target.Damage != 45 || tt.Target.Hits != 1 || tt.TotalDamage != 45 {
		t.Fatalf("first blow: code %d drop %v %+v", code, drop, tt)
	}
	code, _ = tt.Credit(8, 10, 10, 0, 1100)
	if code != CreditChallenger || tt.Challenger.ID != 8 || tt.Challenger.Hate != 10 {
		t.Fatalf("second attacker takes the challenger seat: code %d %+v", code, tt)
	}
	code, _ = tt.Credit(9, 10, 10, 0, 1200)
	if code != CreditUntracked || tt.TotalDamage != 65 {
		t.Fatalf("a third attacker is untracked (but its damage counts): code %d total %d", code, tt.TotalDamage)
	}
	// A taunt: +50 % of the seat's hate plus 20 flat -> 51 + 25 + 20 = 96.
	tt.Credit(7, 0, 20, 50, 1300)
	if tt.Target.Hate != 96 || tt.Target.Hits != 2 {
		t.Fatalf("percent then flat: hate %d hits %d", tt.Target.Hate, tt.Target.Hits)
	}
	// A hate-reducing blow that empties the seat drops the target.
	if _, drop := tt.Credit(7, 0, -200, 0, 1400); !drop || tt.Target.Hate != 0 {
		t.Fatalf("hate below 1 drops the target: drop=%v hate=%d", drop, tt.Target.Hate)
	}
	// The clamp's top.
	tt.Credit(7, 0, 0x7ffffff0, 0, 1500)
	tt.Credit(7, 0, 0x7ffffff0, 0, 1600)
	if tt.Target.Hate != 0x7fffffff {
		t.Fatalf("hate clamps at INT_MAX: %d", tt.Target.Hate)
	}
}

// Rule 2: the challenger overtakes on more hate, or on two idle intervals; a
// farther third attacker takes the seat, a nearer one does not.
func TestThreatResolveByHate(t *testing.T) {
	var tt ThreatTable
	tt.Credit(7, 45, 51, 0, 0)
	code, _ := tt.Credit(8, 10, 10, 0, 100)
	if got := tt.Resolve(code, 8, true, 0, 0, 100, 3000); got != 7 {
		t.Fatalf("a weaker challenger does not overtake: facing %d", got)
	}
	code, _ = tt.Credit(8, 60, 60, 0, 200) // challenger hate 70 > 51
	if got := tt.Resolve(code, 8, true, 0, 0, 200, 3000); got != 8 || tt.Challenger.ID != 7 {
		t.Fatalf("more hate overtakes and the seats swap: facing %d, challenger %d", got, tt.Challenger.ID)
	}
	// Idle: the target (8, last hit 200) goes quiet; at 200 + 6000 the
	// challenger (7) takes over even with less hate.
	code, _ = tt.Credit(7, 1, 1, 0, 6200)
	if got := tt.Resolve(code, 7, true, 0, 0, 6200, 3000); got != 7 {
		t.Fatalf("two idle intervals hand the target over: facing %d", got)
	}
	// An untracked attacker: nearer keeps the target, farther takes it.
	if got := tt.Resolve(CreditUntracked, 9, true, 5, 10, 6300, 3000); got != 7 {
		t.Fatalf("a nearer third attacker is ignored: facing %d", got)
	}
	if got := tt.Resolve(CreditUntracked, 9, true, 12, 10, 6400, 3000); got != 9 || tt.Challenger.ID != 7 || tt.Target.Hits != 1 {
		t.Fatalf("a farther third attacker takes the seat: facing %d, challenger %d, hits %d", got, tt.Challenger.ID, tt.Target.Hits)
	}
	// An invalid target is replaced by the challenger outright.
	tt = ThreatTable{}
	tt.Credit(7, 1, 1, 0, 0)
	code, _ = tt.Credit(8, 1, 1, 0, 10)
	if got := tt.Resolve(code, 8, false, 0, 0, 10, 3000); got != 8 || !tt.Challenger.empty() {
		t.Fatalf("promotion: facing %d, challenger %+v", got, tt.Challenger)
	}
}

// Rules 0 and 1, and the seat history rule 1 carries over.
func TestThreatFaceAfterHit(t *testing.T) {
	var tt ThreatTable
	tt.Credit(7, 45, 51, 0, 0)
	code, _ := tt.Credit(8, 10, 10, 0, 100)
	if got := tt.FaceAfterHit(RetargetKeepFirst, code, 8, true, 0, 0, 100, 3000); got != 7 {
		t.Fatalf("rule 0 keeps the first attacker: %d", got)
	}
	if got := tt.FaceAfterHit(RetargetLatest, code, 8, true, 0, 0, 100, 3000); got != 8 || tt.Target.Hate != 51 {
		t.Fatalf("rule 1 faces the latest, keeping the seat's history: %d hate %d", got, tt.Target.Hate)
	}
}

// The attack interval's window: ReuseDelay plus a jitter of a fifth of the
// previous interval, clamped to 500..2000 ms -- for a Mangyang (3000) whose
// previous interval was 3000, the window is 3000..3600 ms. This pins the
// window's range, which feeds the threat table's idle window
// (ThreatIdleIntervals); it is NOT the swing cadence: round 545's timer read
// found every first-table arming fires at once (0x53d6c7), so the swings are
// spaced by the action machine's ReuseDelay alone. Round 259's "swings every
// 3000..3600 ms" wording stood here until round 547; threat.go and
// docs/protocol/monster_ai.md were corrected in round 545.
func TestAttackIntervalJitter(t *testing.T) {
	if j := AttackJitterMs(3000); j != 600 {
		t.Fatalf("3000/5 = %d; want 600", j)
	}
	if j := AttackJitterMs(0); j != 500 {
		t.Fatalf("the floor is 500: %d", j)
	}
	if j := AttackJitterMs(20000); j != 2000 {
		t.Fatalf("the ceiling is 2000: %d", j)
	}
	if lo, hi := AttackIntervalRange(3000, 3000); lo != 3000 || hi != 3600 {
		t.Fatalf("range %d..%d; want 3000..3600", lo, hi)
	}
}

// The draw weight is AI_AttackChance plus HALF the reach margin in whole
// units (round 554: the fmul 5.0 / fdiv 10.0 at 0x561c93..0x561c99 that
// round 260's "whole margin" missed); a zero chance never draws; the HP
// trigger fires at or below the threshold.
func TestSkillChoice(t *testing.T) {
	// Mangyang (BC 6) attacking a player (BC 4) with a Range-10 skill from
	// 12.5 units away: margin 10 + 6 + 4 - 12.5 = 7.5, x 5 / 10 = 3.75 -> 3.
	if w := SkillWeight(30, 10, 6, 4, 12.5); w != 33 {
		t.Fatalf("weight %d; want 30 + 3", w)
	}
	// Yeoha (BC 11) against a player (BC 4) 60 units away: its
	// MSKILL_CH_YEOHA_ATTACK01 (range 7, chance 100) weighs its chance
	// alone; its ATTACK03 (range 100, chance 100) weighs 100 + trunc((100 +
	// 11 + 4 - 60) x 5 / 10) = 100 + 27. Round 260's reading would have
	// given 155 here.
	if w := SkillWeight(100, 7, 11, 4, 60); w != 100 {
		t.Fatalf("ATTACK01 at 60: weight %d; want the chance alone, 100", w)
	}
	if w := SkillWeight(100, 100, 11, 4, 60); w != 127 {
		t.Fatalf("ATTACK03 at 60: weight %d; want 100 + 27", w)
	}
	if w := SkillWeight(30, 10, 6, 4, 25); w != 30 {
		t.Fatalf("out of reach adds nothing: %d", w)
	}
	if w := SkillWeight(30, 10, 6, 4, 20); w != 30 {
		t.Fatalf("a margin of exactly 0 adds nothing (test ah,0x41 takes equal): %d", w)
	}
	if w := SkillWeight(0, 10, 6, 4, 0); w != 0 {
		t.Fatalf("AI_AttackChance 0 never draws: %d", w)
	}
	if !TriggerHPBelowHolds(30, 100, 30) || TriggerHPBelowHolds(31, 100, 30) || TriggerHPBelowHolds(1, 0, 30) {
		t.Fatal("the HP trigger holds at or below the threshold, never with MaxHP 0")
	}
}

// The draw itself (round 554). pickByWeight is the engine's: r runs
// 0..total (the modulus is total + 1) and the first entry whose cumulative
// weight is >= r is the pick, so with weights 100 and 127 the first skill
// takes r = 0..100 (101 outcomes) and the second 101..227 (127).
func TestPickByWeight(t *testing.T) {
	w := []int{100, 127}
	for r := 0; r <= 100; r++ {
		if got := pickByWeight(r, w); got != 0 {
			t.Fatalf("r=%d picks %d; want the first skill through r = 100 (cumulative 100 >= r)", r, got)
		}
	}
	for r := 101; r <= 227; r++ {
		if got := pickByWeight(r, w); got != 1 {
			t.Fatalf("r=%d picks %d; want the second skill from r = 101", r, got)
		}
	}
	if got := pickByWeight(228, w); got != 0 {
		t.Fatalf("r wraps at total + 1 = 228: r=228 is 0 and picks %d; want 0", got)
	}
	// A skill with no chance is not entered: its weight is skipped, never
	// picked, and does not shift the others' cumulative values.
	if got := pickByWeight(0, []int{0, 5}); got != 1 {
		t.Fatalf("a zero-weight skill is skipped: picked %d, want 1", got)
	}
	if got := pickByWeight(3, []int{0, 5, 0}); got != 1 {
		t.Fatalf("zero-weight skills around the only entry: picked %d, want 1", got)
	}
	if got := pickByWeight(7, nil); got != -1 {
		t.Fatalf("no skill entered: picked %d, want -1", got)
	}
	if got := pickByWeight(7, []int{0, 0}); got != -1 {
		t.Fatalf("no skill with a chance: picked %d, want -1", got)
	}
}

// PickSkill over seeded draws: a Yeoha 60 units from a player draws both
// its skills, and the second -- weight 127 against the first's 100 -- more
// often; a Chance-0 skill is never drawn however the dice fall; and a species
// with one skill always draws it (the CONTROL: a single-skill species is
// unchanged by the draw).
func TestPickSkillDraws(t *testing.T) {
	rng := rand.New(rand.NewSource(554))
	yeoha := []AttackSkill{{Chance: 100, Range: 7}, {Chance: 100, Range: 100}}
	var counts [2]int
	const draws = 20000
	for i := 0; i < draws; i++ {
		got := PickSkill(rng, yeoha, 11, 4, 60)
		if got < 0 || got > 1 {
			t.Fatalf("draw %d picked %d", i, got)
		}
		counts[got]++
	}
	// 101/228 and 127/228 of the draws: 44.3 % and 55.7 %, held to +-3 %.
	if lo, hi := draws*41/100, draws*47/100; counts[0] < lo || counts[0] > hi {
		t.Fatalf("ATTACK01 drawn %d of %d, want about 101/228 (%d..%d)", counts[0], draws, lo, hi)
	}
	if counts[1] == 0 {
		t.Fatal("ATTACK03 never drawn")
	}
	// A Chance-0 skill is never drawn, whatever its reach.
	noChance := []AttackSkill{{Chance: 100, Range: 7}, {Chance: 0, Range: 100}}
	for i := 0; i < 5000; i++ {
		if got := PickSkill(rng, noChance, 11, 4, 60); got != 0 {
			t.Fatalf("draw %d picked the Chance-0 skill (%d)", i, got)
		}
	}
	// CONTROL: one skill, always drawn -- from any distance.
	for i := 0; i < 1000; i++ {
		if got := PickSkill(rng, yeoha[:1], 11, 4, float64(i)); got != 0 {
			t.Fatalf("draw %d of the single skill picked %d", i, got)
		}
	}
	// No skill with a chance: no pick.
	if got := PickSkill(rng, []AttackSkill{{Chance: 0, Range: 7}}, 11, 4, 5); got != -1 {
		t.Fatalf("a list with no chance picked %d, want -1", got)
	}
	if got := PickSkill(rng, nil, 11, 4, 5); got != -1 {
		t.Fatalf("an empty list picked %d, want -1", got)
	}
}
