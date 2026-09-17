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
// This test used to be TestMembershipLevelsAreRecordedByValueNotRole, and its
// job was to force a later pass that mapped the floors onto roles to change the
// constants deliberately rather than reinterpret them quietly. That pass is
// 2026-09-17: the roles are read from the count functions behind the engine's
// STUDENT_COUNT_OVER and SECOND_GUARDIAN_COUNT_OVER refusals.
func TestMembershipLevelsByRole(t *testing.T) {
	if MembershipLevelA != 41 || MembershipLevelB != 61 {
		t.Errorf("membership levels are %d and %d, want 41 and 61",
			MembershipLevelA, MembershipLevelB)
	}
	if f, _ := MembershipLevelFloor(MemberClassStudent); f != 41 {
		t.Errorf("student floor = %d, want 41", f)
	}
	if f, _ := MembershipLevelFloor(MemberClassSecondGuardian); f != 61 {
		t.Errorf("second guardian floor = %d, want 61", f)
	}
}

// The class codes are named by what the engine COUNTS, not by a guess. Swapping
// them is the regression this pins, and it is the exact mistake a "class 1 is
// the master" reading would have shipped.
func TestRoleClassCodes(t *testing.T) {
	if MemberClassStudent != 2 {
		t.Errorf("student class = %d, want 2 (FUN_005e4460 counts class 2)", MemberClassStudent)
	}
	if MemberClassSecondGuardian != 1 {
		t.Errorf("second guardian class = %d, want 1 (FUN_005e43e0 counts class 1)", MemberClassSecondGuardian)
	}
}

func TestRoleCaps(t *testing.T) {
	for _, tc := range []struct {
		class, count int
		want         bool
	}{
		{MemberClassStudent, 4, false}, {MemberClassStudent, 5, true},
		{MemberClassSecondGuardian, 1, false}, {MemberClassSecondGuardian, 2, true},
		{0, 99, false},
	} {
		if got := RoleFull(tc.class, tc.count); got != tc.want {
			t.Errorf("RoleFull(class %d, count %d) = %v, want %v", tc.class, tc.count, got, tc.want)
		}
	}
}

func TestInviteRoleByLevel(t *testing.T) {
	for _, tc := range []struct {
		level, class int
		ok           bool
	}{
		{1, MemberClassStudent, true}, {39, MemberClassStudent, true},
		{40, MemberClassSecondGuardian, true}, {59, MemberClassSecondGuardian, true},
		{60, 0, false}, {110, 0, false}, // refused outright: `ja 0x51937f` sends 3
	} {
		class, ok := InviteRole(tc.level)
		if class != tc.class || ok != tc.ok {
			t.Errorf("InviteRole(%d) = (%d, %v), want (%d, %v)", tc.level, class, ok, tc.class, tc.ok)
		}
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

// The founder floor and the invite ceiling are two separately read constants
// that meet at one boundary: no level is both foundable and invitable, and none
// is neither. If either drifts, this fails.
func TestFounderFloorMeetsInviteCeiling(t *testing.T) {
	if MinFounderLevel != InviteMaxLevel+1 {
		t.Errorf("founder floor %d and invite ceiling %d do not meet: the engine "+
			"refuses invitees above 59 and founders below 60", MinFounderLevel, InviteMaxLevel)
	}
	if InviteRefused != 3 {
		t.Errorf("InviteRefused = %d, want 3 (pushed at 0x0051937f)", InviteRefused)
	}
}
