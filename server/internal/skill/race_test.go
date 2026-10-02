package skill

import "testing"

// TestDefaultMasteriesByRace pins _RefCharDefault_SkillMastery (READ, the
// retail shard's 13 rows): China holds 257-259 and 273-276, Europe 513-518, and
// neither holds any of the other's.
func TestDefaultMasteriesByRace(t *testing.T) {
	china := DefaultMasteries(0)
	europe := DefaultMasteries(1)
	if len(china) != 7 || len(europe) != 6 {
		t.Fatalf("DefaultMasteries: China %v, Europe %v; want 7 and 6 ids", china, europe)
	}
	for _, id := range []int64{257, 258, 259, 273, 274, 275, 276} {
		if !HoldsMastery(0, id) || HoldsMastery(1, id) {
			t.Errorf("mastery %d: China holds %v, Europe holds %v; want true, false", id, HoldsMastery(0, id), HoldsMastery(1, id))
		}
	}
	for _, id := range []int64{MasteryWarrior, MasteryWizard, MasteryRogue, MasteryWarlock, MasteryBard, MasteryCleric} {
		if !HoldsMastery(1, id) || HoldsMastery(0, id) {
			t.Errorf("mastery %d: Europe holds %v, China holds %v; want true, false", id, HoldsMastery(1, id), HoldsMastery(0, id))
		}
	}
	// Countries with no row hold nothing (the table has no Race 2 or 3 row).
	for _, c := range []int{2, 3, 255} {
		if DefaultMasteries(c) != nil || HoldsMastery(c, 257) || HoldsMastery(c, 513) {
			t.Errorf("country %d: holds %v, want nothing", c, DefaultMasteries(c))
		}
	}
	// A copy, not the table.
	europe[0] = 1
	if DefaultMasteries(1)[0] != MasteryWarrior {
		t.Fatal("DefaultMasteries returned the table itself; a caller's write changed it")
	}
}

// TestLearnRaceAllows pins FUN_0059e450's race clause: ReqLearn_Race 3 is
// anyone's, otherwise it must equal the Country.
func TestLearnRaceAllows(t *testing.T) {
	cases := []struct {
		race, country int
		want          bool
	}{
		{0, 0, true}, {0, 1, false}, {1, 1, true}, {1, 0, false}, {3, 0, true}, {3, 1, true}, {2, 0, false},
	}
	for _, c := range cases {
		if got := LearnRaceAllows(c.race, c.country); got != c.want {
			t.Errorf("LearnRaceAllows(race %d, country %d) = %v, want %v", c.race, c.country, got, c.want)
		}
	}
}
