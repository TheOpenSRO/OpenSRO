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

// The class-to-floor mapping, read in assembly on 2026-09-17. The boundaries
// are the point: the engine compares `cmp dl,0x28 ; jbe` and `cmp dl,0x3c ; ja`,
// so 40 fails and 41 passes for class 2, and 60 fails and 61 passes for class 1.
func TestMembershipLevelFloorByClass(t *testing.T) {
	for _, tc := range []struct {
		class, level int
		want         bool
	}{
		{MemberClass2, 40, false}, {MemberClass2, 41, true},
		{MemberClass1, 60, false}, {MemberClass1, 61, true},
		// A class the check does not test has no floor at all.
		{0, 1, true}, {3, 1, true},
	} {
		if got := MeetsMembershipLevel(tc.class, tc.level); got != tc.want {
			t.Errorf("MeetsMembershipLevel(class %d, level %d) = %v, want %v",
				tc.class, tc.level, got, tc.want)
		}
	}
	// The two classes must not share a floor; swapping them is the likeliest
	// regression, and it would pass any test that only checked the set {41, 61}.
	if f2, _ := MembershipLevelFloor(MemberClass2); f2 != 41 {
		t.Errorf("class 2 floor = %d, want 41", f2)
	}
	if f1, _ := MembershipLevelFloor(MemberClass1); f1 != 61 {
		t.Errorf("class 1 floor = %d, want 61", f1)
	}
}

// 0x6818 is not in the client's error table; the check pushes 0x6822.
func TestMembershipRefusalCode(t *testing.T) {
	if ErrMembershipLevel != 0x6822 {
		t.Errorf("ErrMembershipLevel = %#x, want 0x6822 (TC_ERROR_POSIBLE_41L)", ErrMembershipLevel)
	}
}
