package siege

import (
	"testing"
)

func ok() RegistrationRequest {
	return RegistrationRequest{
		InGuild: true, IsGuildMaster: true,
		GuildLevel: MinGuildLevel, GuildMembers: MinGuildMembers,
		AllianceMatches: true, EnoughGold: true,
	}
}

func TestRegistrationAcceptsTheMinimum(t *testing.T) {
	if got := CheckRegistration(ok()); got != 0 {
		t.Errorf("a guild at exactly the minimum was refused with %#x", got)
	}
}

// The thresholds are `< 3` and `< 7`, so three and seven pass and two and six
// do not. Off-by-one here would be invisible without a test.
func TestRegistrationThresholdsAreInclusive(t *testing.T) {
	r := ok()
	r.GuildLevel = MinGuildLevel - 1
	if got := CheckRegistration(r); got != ErrGuildLevelTooLow {
		t.Errorf("level %d gave %#x, want %#x", r.GuildLevel, got, ErrGuildLevelTooLow)
	}
	r = ok()
	r.GuildLevel = MinGuildLevel
	if got := CheckRegistration(r); got != 0 {
		t.Errorf("level %d was refused with %#x", r.GuildLevel, got)
	}
	r = ok()
	r.GuildMembers = MinGuildMembers - 1
	if got := CheckRegistration(r); got != ErrTooFewGuildMembers {
		t.Errorf("%d members gave %#x, want %#x", r.GuildMembers, got, ErrTooFewGuildMembers)
	}
	r = ok()
	r.GuildMembers = MinGuildMembers
	if got := CheckRegistration(r); got != 0 {
		t.Errorf("%d members was refused with %#x", r.GuildMembers, got)
	}
}

// The order is the binary's and it is observable to a player: a guild failing
// two tests is told about whichever the engine reaches first.
func TestRegistrationOrderIsTheBinarys(t *testing.T) {
	// Not in a guild beats everything, including having no guild level.
	r := RegistrationRequest{}
	if got := CheckRegistration(r); got != ErrNotInGuild {
		t.Errorf("an empty request gave %#x, want NOTJOINGUILD %#x", got, ErrNotInGuild)
	}
	// Guild-master is checked BEFORE level and member count.
	r = ok()
	r.IsGuildMaster = false
	r.GuildLevel = 1
	r.GuildMembers = 1
	if got := CheckRegistration(r); got != ErrOnlyGuildMaster {
		t.Errorf("got %#x, want ONLYGUILDMASTER %#x -- it is tested before the level",
			got, ErrOnlyGuildMaster)
	}
	// Level is checked BEFORE member count.
	r = ok()
	r.GuildLevel = 1
	r.GuildMembers = 1
	if got := CheckRegistration(r); got != ErrGuildLevelTooLow {
		t.Errorf("got %#x, want TOOLESSGUILDLV %#x -- it is tested before the member count",
			got, ErrGuildLevelTooLow)
	}
	// Alliance is checked before guild-master.
	r = ok()
	r.AllianceMatches = false
	r.IsGuildMaster = false
	if got := CheckRegistration(r); got != ErrWrongAlliance {
		t.Errorf("got %#x, want WRONGALLIANCE %#x", got, ErrWrongAlliance)
	}
}

// `(uint16)(ratio + 20) <= 40`, written as one unsigned comparison. The range
// it accepts is -20..+20, and the boundaries are what a restatement gets wrong.
func TestValidTaxRatioMatchesTheUnsignedCheck(t *testing.T) {
	for r := TaxRatioMin; r <= TaxRatioMax; r++ {
		if !ValidTaxRatio(int16(r)) {
			t.Errorf("ratio %d was rejected", r)
		}
	}
	for _, r := range []int16{-21, -22, -100, 21, 22, 100, 1000, -32768, 32767} {
		if ValidTaxRatio(r) {
			t.Errorf("ratio %d was accepted", r)
		}
	}
	// And the property, checked against the instruction rather than the range.
	for i := -32768; i <= 32767; i++ {
		r := int16(i)
		want := uint16(r+TaxRatioBias) <= TaxRatioSpan
		if got := ValidTaxRatio(r); got != want {
			t.Fatalf("ratio %d: got %v want %v", r, got, want)
		}
	}
}

func TestTaxChange(t *testing.T) {
	for _, c := range []struct {
		name      string
		cur, next int16
		master    bool
		want      int
	}{
		{"accepted", 5, 10, true, 0},
		{"out of range", 5, 50, true, ErrTaxRejected},
		{"unchanged", 5, 5, true, ErrTaxUnchanged},
		{"not the master", 5, 10, false, ErrOnlyGuildMaster},
		{"range beats unchanged", 50, 50, true, ErrTaxRejected},
		{"unchanged beats permission", 5, 5, false, ErrTaxUnchanged},
		{"negative is fine", 0, -20, true, 0},
	} {
		if got := TaxChangeAccepted(c.cur, c.next, c.master); got != c.want {
			t.Errorf("%s: got %#x, want %#x", c.name, got, c.want)
		}
	}
}

// The war period is tested FIRST, before anything about the target. Outside it,
// a fortress structure cannot be attacked at all -- not by an enemy, not by
// anyone.
func TestAttackRequiresTheWarPeriodFirst(t *testing.T) {
	if got := CanAttack(AttackTarget{}); got != ErrOnlyDuringWar {
		t.Errorf("got %#x outside the war period, want ONLYPERIODFORT %#x", got, ErrOnlyDuringWar)
	}
	// Even a perfectly valid enemy target is refused outside the period.
	if got := CanAttack(AttackTarget{SameGuild: false, AlliedGuild: false}); got != ErrOnlyDuringWar {
		t.Errorf("got %#x, want ONLYPERIODFORT %#x", got, ErrOnlyDuringWar)
	}
}

func TestAttackRules(t *testing.T) {
	for _, c := range []struct {
		name string
		in   AttackTarget
		want int
	}{
		{"enemy during the war", AttackTarget{WarPeriodActive: true}, 0},
		{"own guild", AttackTarget{WarPeriodActive: true, SameGuild: true}, ErrCannotAttackAlly},
		{"ally", AttackTarget{WarPeriodActive: true, AlliedGuild: true}, ErrCannotAttackAlly},
		{"immune body mode", AttackTarget{WarPeriodActive: true, ImmuneBodyMode: true}, ErrCannotAttackFort},
	} {
		if got := CanAttack(c.in); got != c.want {
			t.Errorf("%s: got %#x, want %#x", c.name, got, c.want)
		}
	}
}

func TestRefusalCodesAreDistinct(t *testing.T) {
	codes := map[int]string{
		ErrOnlyGuildMaster: "ErrOnlyGuildMaster", ErrTaxUnavailable: "ErrTaxUnavailable",
		ErrNotInGuild: "ErrNotInGuild", ErrGuildLevelTooLow: "ErrGuildLevelTooLow",
		ErrTooFewGuildMembers: "ErrTooFewGuildMembers", ErrNotEnoughMoney: "ErrNotEnoughMoney",
		ErrAlreadyApplied: "ErrAlreadyApplied", ErrAlreadyPossessFort: "ErrAlreadyPossessFort",
		ErrWrongAlliance: "ErrWrongAlliance", ErrTaxUnchanged: "ErrTaxUnchanged",
		ErrTaxRejected: "ErrTaxRejected", ErrCannotAttackAlly: "ErrCannotAttackAlly",
		ErrCannotAttackFort: "ErrCannotAttackFort", ErrOnlyDuringWar: "ErrOnlyDuringWar",
	}
	if len(codes) != 14 {
		t.Errorf("%d distinct codes, want 14 -- two constants collided", len(codes))
	}
	if ResponseOpcode != 0xb05e {
		t.Errorf("ResponseOpcode is %#x, want 0xb05e", ResponseOpcode)
	}
}

func TestTheDatabaseSurfaceIsRecorded(t *testing.T) {
	if len(Procs) != 9 {
		t.Errorf("%d procedures, want the 9 harvested from the call literals", len(Procs))
	}
	if len(ReferenceTables) != 11 {
		t.Errorf("%d reference tables, want 11 _REFSIEGE* tables", len(ReferenceTables))
	}
	for _, tbl := range ReferenceTables {
		if len(tbl) < 10 || tbl[:9] != "_REFSIEGE" {
			t.Errorf("%s is in ReferenceTables but is not a _REFSIEGE table", tbl)
		}
	}
	for name, args := range Procs {
		if args < 1 || args > 32 {
			t.Errorf("%s takes %d arguments", name, args)
		}
	}
}
