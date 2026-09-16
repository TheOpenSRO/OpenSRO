package leveldata

import "testing"

// The dispatch switch in GObjPC::FUN_004e6ec0 sends exactly 3, 4 and 5 to the
// death handler. Everything else routes elsewhere or nowhere, and must not be
// charged a penalty.
func TestOnlyDispatchedCausesCarryAPenalty(t *testing.T) {
	carries := map[DeathCause]bool{
		DeathCauseNone:      false,
		DeathCauseJobSuit:   false,
		DeathCauseNoPenalty: false,
		DeathCauseMonster:   true,
		DeathCauseOther:     true,
		DeathCausePlayer:    true,
		DeathCauseZone:      false,
	}
	for cause, want := range carries {
		if got := cause.CarriesExpPenalty(); got != want {
			t.Errorf("DeathCause(%d).CarriesExpPenalty() = %v, want %v", cause, got, want)
		}
		_, _, ok := DeathPenaltyFactorFor(cause, false)
		if ok != want {
			t.Errorf("DeathPenaltyFactorFor(%d) ok = %v, want %v", cause, ok, want)
		}
	}
}

// The engine's test is `byte != 5`, not `byte == 3`, so cause 4 takes the
// not-a-player branch alongside cause 3. Writing it the other way would give
// cause 4 the player multipliers.
func TestFactorsFollowTheEngineNotEqualFiveTest(t *testing.T) {
	cases := []struct {
		cause     DeathCause
		pkFlagged bool
		exp, sp   int
	}{
		{DeathCauseMonster, false, DeathPenaltyKilledByMonster, 0},
		{DeathCauseMonster, true, DeathPenaltyKilledByMonsterFlagged, DeathPenaltySkillPointsMonsterFlagged},
		{DeathCauseOther, false, DeathPenaltyKilledByMonster, 0},
		{DeathCauseOther, true, DeathPenaltyKilledByMonsterFlagged, DeathPenaltySkillPointsMonsterFlagged},
		{DeathCausePlayer, false, DeathPenaltyKilledByPlayer, 0},
		{DeathCausePlayer, true, DeathPenaltyKilledByPlayerFlagged, DeathPenaltySkillPointsPlayerFlagged},
	}
	for _, c := range cases {
		exp, sp, ok := DeathPenaltyFactorFor(c.cause, c.pkFlagged)
		if !ok {
			t.Fatalf("cause %d should carry a penalty", c.cause)
		}
		if exp != c.exp || sp != c.sp {
			t.Errorf("DeathPenaltyFactorFor(%d, pk=%v) = (%d, %d), want (%d, %d)",
				c.cause, c.pkFlagged, exp, sp, c.exp, c.sp)
		}
	}
}

// An ordinary death costs no skill points at all -- the SP loss exists only on
// the PK-flagged branches.
func TestUnflaggedDeathCostsNoSkillPoints(t *testing.T) {
	for _, cause := range []DeathCause{DeathCauseMonster, DeathCausePlayer} {
		if _, sp, _ := DeathPenaltyFactorFor(cause, false); sp != 0 {
			t.Errorf("cause %d unflagged cost %d skill points, want 0", cause, sp)
		}
	}
}

// A monster kill must cost MORE than a player kill. This is the check that the
// enum was read the right way round: if 3 and 5 were swapped, the cheaper
// branch would be the monster one.
func TestMonsterDeathCostsMoreThanPlayerDeath(t *testing.T) {
	mob, _, _ := DeathPenaltyFactorFor(DeathCauseMonster, false)
	pc, _, _ := DeathPenaltyFactorFor(DeathCausePlayer, false)
	if mob <= pc {
		t.Errorf("monster death %dx should exceed player death %dx", mob, pc)
	}
	mobF, _, _ := DeathPenaltyFactorFor(DeathCauseMonster, true)
	pcF, _, _ := DeathPenaltyFactorFor(DeathCausePlayer, true)
	if mobF <= pcF {
		t.Errorf("flagged monster death %dx should exceed flagged player death %dx", mobF, pcF)
	}
}

// The multiplier a cause resolves to must be the same constant DeathPenaltyExp
// is called with, or the cause path and the table path would drift apart.
func TestFactorMatchesDeathPenaltyExpInput(t *testing.T) {
	cases := []struct {
		cause     DeathCause
		pkFlagged bool
		want      int
	}{
		{DeathCauseMonster, false, DeathPenaltyKilledByMonster},
		{DeathCauseMonster, true, DeathPenaltyKilledByMonsterFlagged},
		{DeathCausePlayer, false, DeathPenaltyKilledByPlayer},
		{DeathCausePlayer, true, DeathPenaltyKilledByPlayerFlagged},
	}
	for _, c := range cases {
		got, _, ok := DeathPenaltyFactorFor(c.cause, c.pkFlagged)
		if !ok || got != c.want {
			t.Errorf("DeathPenaltyFactorFor(%d, pk=%v) = %d (ok=%v), want %d",
				c.cause, c.pkFlagged, got, ok, c.want)
		}
	}
}
