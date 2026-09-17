package academy

import (
	"strings"
	"testing"
)

func okReq() CreateRequest {
	return CreateRequest{Alive: true, Level: MinFounderLevel, Gold: FoundingGold}
}

func TestCreateAcceptsTheMinimum(t *testing.T) {
	if got := CheckCreate(okReq()); got != 0 {
		t.Errorf("a founder at exactly the minimum was refused with %#x", got)
	}
}

// `< 0x3c` and `< 100000`, so 60 and 100,000 exactly pass.
func TestCreateThresholds(t *testing.T) {
	r := okReq()
	r.Level = MinFounderLevel - 1
	if got := CheckCreate(r); got != ErrOpenLevel {
		t.Errorf("level %d gave %#x, want OPEN_LEVEL %#x", r.Level, got, ErrOpenLevel)
	}
	r = okReq()
	r.Gold = FoundingGold - 1
	if got := CheckCreate(r); got != ErrOpenGold {
		t.Errorf("gold %d gave %#x, want OPEN_GOLD %#x", r.Gold, got, ErrOpenGold)
	}
	if MinFounderLevel != 0x3c {
		t.Errorf("MinFounderLevel is %d; the comparison is `< 0x3c`", MinFounderLevel)
	}
}

// The order is the binary's and a player sees it: a dead, under-levelled,
// broke character is told they are dead.
func TestCreateOrderIsTheBinarys(t *testing.T) {
	if got := CheckCreate(CreateRequest{}); got != ErrDeadOrBusy {
		t.Errorf("an empty request gave %#x, want %#x", got, ErrDeadOrBusy)
	}
	r := CreateRequest{Alive: true, Level: 1, Gold: 0, AlreadyInCamp: true}
	if got := CheckCreate(r); got != ErrOpenLevel {
		t.Errorf("got %#x, want OPEN_LEVEL %#x -- the level is tested before the gold "+
			"and before the membership", got, ErrOpenLevel)
	}
	r = okReq()
	r.AlreadyInCamp = true
	r.WithinReopenCooldown = true
	if got := CheckCreate(r); got != ErrAlreadyInCamp {
		t.Errorf("got %#x, want ALREADY %#x -- membership is tested before the cooldown",
			got, ErrAlreadyInCamp)
	}
}

// The two membership levels share one refusal, and which role each belongs to
// is deliberately not claimed. This test exists so a later pass that DOES map
// them has to change the constants rather than quietly reinterpret them.
func TestMembershipLevelsAreRecordedByValueNotRole(t *testing.T) {
	if MembershipLevelA != 41 || MembershipLevelB != 61 {
		t.Errorf("membership levels are %d and %d, want 41 and 61",
			MembershipLevelA, MembershipLevelB)
	}
	if MembershipLevelA >= MembershipLevelB {
		t.Error("A should be the lower of the two; the error name carries 41")
	}
}

func TestRefusalCodesAreDistinct(t *testing.T) {
	seen := map[int]bool{}
	for _, c := range []int{
		ErrDeadOrBusy, ErrWrongState, ErrOpenLevel, ErrOpenGold, ErrNoCamp,
		ErrInviteRejection, ErrAlreadyInCamp, ErrOrderWork, ErrNotOpen7D, ErrNotInvite24T,
	} {
		if seen[c] {
			t.Errorf("code %#x listed twice", c)
		}
		seen[c] = true
		if c < 0x6800 || c > 0x68ff {
			t.Errorf("code %#x is outside the 0x68xx training-camp range", c)
		}
	}
	if len(seen) != 10 {
		t.Errorf("%d distinct codes, want 10", len(seen))
	}
}

// One class per table, and the names line up.
func TestClassesAndTablesCorrespond(t *testing.T) {
	if len(Classes) != len(Tables) {
		t.Fatalf("%d classes but %d tables", len(Classes), len(Tables))
	}
	for _, c := range Classes {
		if !strings.HasPrefix(c, "CInstanceTrainingCamp") {
			t.Errorf("%s is not a training-camp class", c)
		}
	}
	for _, tbl := range Tables {
		if !strings.HasPrefix(tbl, "_TRAININGCAMP") {
			t.Errorf("%s is not a training-camp table", tbl)
		}
	}
}
