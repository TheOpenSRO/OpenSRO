package session

import (
	"context"
	"strings"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/leveldata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/mana"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Round 874: the death penalty as the original's -- capped at the level's
// share, able to take a level away (one at most), the max level kept, and a
// resurrection scroll's EXP bringing the level back without paying its stat
// points twice. The level table rows are the client's own (levels 19 and 20,
// the MEASURED death's).
const death874Levels = "level,exp,mastery_sp,exp_unit\n19,238878,47,447\n20,282000,53,470\n21,351231,60,498\n"

func death874Table(t *testing.T) {
	t.Helper()
	tbl, err := leveldata.ParseCSV(strings.NewReader(death874Levels))
	if err != nil {
		t.Fatal(err)
	}
	prev := levelTable
	SetLevelTable(tbl)
	t.Cleanup(func() { SetLevelTable(prev) })
}

func TestDeathTakesALevelAndTheScrollGivesItBack(t *testing.T) {
	far := world.Position{X: 700, Z: 700}
	battleForTest(t, true)
	deadStateForTest(t, true)
	death874Table(t)
	ctx := context.Background()
	f := startBattleFixture(t, 874, far.X, far.Z)
	c, _ := f.chars.GetByID(ctx, f.aria)
	const points, str, intel = 57, 39, 39
	if err := f.chars.SetLeveling(ctx, f.aria, 20, 1000, points, str, intel); err != nil {
		t.Fatal(err)
	}
	_ = c
	f.hub.SetLevel(f.aria, 20)
	m := f.monsters.SpawnSpecies("jangan", chaseMangyang, far.X+8, 0, far.Z, 100000, 0, 100000, 0)
	f.a.runStrike(m.ID, strikeJob{m: *m, target: f.aria})
	t.Cleanup(func() { lastDeathLoss.Delete(f.aria) })

	// A monster's kill at 20: 470 x 100 capped to trunc(282,000 x float32
	// 0.02) = 5,639, more than the 1,000 there -- one level down, the lower
	// level's requirement added back.
	const loss = 5639
	dead, _ := f.chars.GetByID(ctx, f.aria)
	if dead.Level != 19 || dead.Exp != 1000-loss+238878 {
		t.Fatalf("after the death: level %d exp %d, want 19 at %d", dead.Level, dead.Exp, 1000-loss+238878)
	}
	if dead.HighestLevel() != 20 || dead.StatPoints != points || dead.Str != str || dead.Int != intel {
		t.Errorf("after the death: max level %d, points %d, Str %d, Int %d; want 20, %d, %d, %d (a level down touches none)",
			dead.HighestLevel(), dead.StatPoints, dead.Str, dead.Int, points, str, intel)
	}
	if e, _ := f.hub.EntityByCharacterID(f.aria); e.Life != world.LifeDead || e.Level != 19 {
		t.Errorf("the entity: life %d level %d, want dead at 19", e.Life, e.Level)
	}
	if got := deathLossOf(f.aria); got != loss {
		t.Errorf("the death's record = %d, want the loss %d (pc+0x1ce0)", got, loss)
	}
	if dead.MaxHP() >= character.MaxHPWith(str, 20, character.BonusOf(f.aria)) {
		t.Errorf("max HP %d at 19 should be below level 20's", dead.MaxHP())
	}

	// The 100 % scroll: alive where it lies, the 5,639 back, level 20 again
	// at its 1,000 -- and no stat points, Str or Int paid for a level
	// regained.
	deps := RegenDeps{Mana: mana.NewTracker()}
	after, _, ret, err := reviveByScroll(ctx, f.chars, deps, f.hub, f.aria, 100, 100)
	if err != nil {
		t.Fatal(err)
	}
	if ret.added != loss || ret.levelUp == nil || ret.levelUp.NewLevel != 20 {
		t.Fatalf("the scroll: %+v, want %d back and the level-up to 20", ret, loss)
	}
	if after.Level != 20 || after.Exp != 1000 || after.StatPoints != points || after.Str != str || after.Int != intel {
		t.Errorf("after the scroll: level %d exp %d points %d Str %d Int %d; want 20 at 1000, %d / %d / %d unchanged",
			after.Level, after.Exp, after.StatPoints, after.Str, after.Int, points, str, intel)
	}
	if after.HP != after.MaxHP() {
		t.Errorf("after the scroll HP %d/%d, want full", after.HP, after.MaxHP())
	}
	if deathLossOf(f.aria) != 0 {
		t.Errorf("the record survives the revive (%d); Revive clears it (s:0x4df2e8)", deathLossOf(f.aria))
	}
	if e, _ := f.hub.EntityByCharacterID(f.aria); e.Life != world.LifeAlive || e.Level != 20 {
		t.Errorf("the entity after the scroll: life %d level %d, want alive at 20", e.Life, e.Level)
	}
}

// A level above the max pays; one regained does not (GObjPC_SetLevel's
// `MaxLevel < new`, READ s:0x4e4d90).
func TestLevelsRewardedOnlyAboveTheMaxLevel(t *testing.T) {
	for _, tc := range []struct{ from, to, max, want int }{
		{19, 20, 20, 0},
		{19, 21, 20, 1},
		{20, 21, 20, 1},
		{5, 8, 5, 3},
		{20, 20, 20, 0},
		{19, 20, 0, 1}, // a row from before round 874: its level is the max
	} {
		if got := character.LevelsRewarded(tc.from, tc.to, max(tc.max, tc.from)); got != tc.want {
			t.Errorf("LevelsRewarded(%d, %d, %d) = %d, want %d", tc.from, tc.to, tc.max, got, tc.want)
		}
	}
	// The store keeps the max level through a level down.
	ctx := context.Background()
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatal(err)
	}
	for _, lv := range []int{20, 19, 18} {
		if err := chars.SetLeveling(ctx, c.ID, lv, 0, 0, 20, 20); err != nil {
			t.Fatal(err)
		}
	}
	got, _ := chars.GetByID(ctx, c.ID)
	if got.Level != 18 || got.HighestLevel() != 20 {
		t.Errorf("level %d max %d, want 18 with max 20", got.Level, got.HighestLevel())
	}
}

// The present point (option 2) and the empty request's choice follow the max
// level, not the current one (IGObj::GetMaxLevel +0x128): a level-11
// character a death took to 10 has no present point.
func TestPresentPointFollowsTheMaxLevel(t *testing.T) {
	ctx := context.Background()
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatal(err)
	}
	_ = chars.SetLeveling(ctx, c.ID, 11, 0, 0, 20, 20)
	_ = chars.SetLeveling(ctx, c.ID, 10, 0, 0, 20, 20)
	row, _ := chars.GetByID(ctx, c.ID)
	if got := ReviveOption(nil, row.HighestLevel()); got != ReviveOptionReturnPoint {
		t.Errorf("the empty request at level 10 (max 11) = option %d, want the return point", got)
	}
}

// The resurrection skill gives back its share of the death's loss (resu[1]
// percent, rounded up as the scroll's), fixed when the offer is made.
func TestResurrectionSkillShare(t *testing.T) {
	for _, tc := range []struct {
		lost int64
		pct  int
		want int64
	}{
		{16919, 100, 16919},
		{16919, 50, 8460}, // MEASURED as a murderer's scroll: ceil(8459.5)
		{66380, 100, 66380},
		{1000, 0, 0},
	} {
		if got := resurrectionExp(tc.lost, tc.pct); got != tc.want {
			t.Errorf("resurrectionExp(%d, %d) = %d, want %d", tc.lost, tc.pct, got, tc.want)
		}
	}
}

// The offer box's answer is {01, result} (READ c:0x798101): {01, 00} is a no.
func TestResurrectAnswerIsTheSecondByte(t *testing.T) {
	for _, tc := range []struct {
		data  []byte
		first bool
		want  bool
	}{
		{[]byte{1, 1}, true, true},
		{[]byte{1, 0}, true, false},
		{[]byte{2, 0x0c, 0x2c}, false, false},
		{[]byte{1}, true, true},
	} {
		if got := resurrectAnswerAccepts(tc.data, tc.first); got != tc.want {
			t.Errorf("resurrectAnswerAccepts(%v) = %v, want %v", tc.data, got, tc.want)
		}
	}
}
