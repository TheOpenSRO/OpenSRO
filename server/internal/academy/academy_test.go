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
		ErrNotDisorganization7D, ErrOrderWorkNoMember, ErrNotBan24T, ErrNotOut24T,
	} {
		if seen[c] {
			t.Errorf("code %#x listed twice", c)
		}
		seen[c] = true
		if c < 0x6800 || c > 0x68ff {
			t.Errorf("code %#x is outside the 0x68xx training-camp range", c)
		}
	}
	if len(seen) != 14 {
		t.Errorf("%d distinct codes, want 14", len(seen))
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

// Both validators open with the same `char[0xc]+4 == 1 -> 0x6808` test. It was
// missing from CheckCreate until the disband validator was read beside it.
func TestCreateWrongStateComesFirst(t *testing.T) {
	r := CreateRequest{WrongState: true}
	if got := CheckCreate(r); got != ErrWrongState {
		t.Errorf("a wrong-state, dead request gave %#x, want %#x -- the state is "+
			"tested before IsAlive", got, ErrWrongState)
	}
}

func okDisband() DisbandRequest {
	return DisbandRequest{
		Alive: true, InCamp: true, HasMemberRecord: true,
		MemberClass: MemberClass0, SinceStamp: DisbandWindowSeconds,
	}
}

func TestDisbandAcceptsTheMinimum(t *testing.T) {
	if code, left := CheckDisband(okDisband()); code != 0 || left != 0 {
		t.Errorf("a class-0 member exactly at the window gave (%#x, %d), want (0, 0)", code, left)
	}
}

// The order is FUN_004e4780's: state, alive, camp, class, window.
func TestDisbandOrderIsTheBinarys(t *testing.T) {
	for _, tc := range []struct {
		name string
		r    DisbandRequest
		want int
	}{
		{"everything wrong", DisbandRequest{WrongState: true}, ErrWrongState},
		{"dead, no camp", DisbandRequest{}, ErrDeadOrBusy},
		{"no camp, no record, in window", DisbandRequest{Alive: true}, DisbandNotInCamp},
		{"student, in window", DisbandRequest{Alive: true, InCamp: true,
			HasMemberRecord: true, MemberClass: MemberClassStudent}, ErrOrderWork},
	} {
		if got, _ := CheckDisband(tc.r); got != tc.want {
			t.Errorf("%s: got %#x, want %#x", tc.name, got, tc.want)
		}
	}
}

// Only class 0 passes the gate, and a member lookup that misses fails it even
// though the zero class byte would have passed.
func TestDisbandNeedsClass0(t *testing.T) {
	for _, class := range []int{MemberClassSecondGuardian, MemberClassStudent} {
		r := okDisband()
		r.MemberClass = class
		if got, _ := CheckDisband(r); got != ErrOrderWork {
			t.Errorf("class %d gave %#x, want ORDER_WORK %#x", class, got, ErrOrderWork)
		}
	}
	r := okDisband()
	r.HasMemberRecord = false
	if got, _ := CheckDisband(r); got != ErrOrderWork {
		t.Errorf("a missing member record gave %#x, want ORDER_WORK %#x", got, ErrOrderWork)
	}
}

// `setle cl ; sub ecx,1 ; and eax,ecx`: the remaining time is returned only
// while it is positive, so one second short refuses with 1 left and the full
// 604800 passes.
func TestDisbandWindowBoundary(t *testing.T) {
	r := okDisband()
	r.SinceStamp = DisbandWindowSeconds - 1
	if code, left := CheckDisband(r); code != ErrNotDisorganization7D || left != 1 {
		t.Errorf("one second short gave (%#x, %d), want (%#x, 1)", code, left, ErrNotDisorganization7D)
	}
	r.SinceStamp = 0
	if _, left := CheckDisband(r); left != DisbandWindowSeconds {
		t.Errorf("a fresh stamp left %d seconds, want the whole window %d", left, DisbandWindowSeconds)
	}
}

// The literal is 0x93a80 and the refusal's name says 7D; they agree only if the
// unit is seconds.
func TestDisbandWindowIsSevenDaysOfSeconds(t *testing.T) {
	const literal = 0x93a80 // `mov ecx,0x93a80` at 0x005dd36a
	if DisbandWindowSeconds != literal {
		t.Errorf("DisbandWindowSeconds = %d, want %d", DisbandWindowSeconds, literal)
	}
	if day := 24 * 3600; literal%day != 0 || literal/day != 7 {
		t.Errorf("%d seconds is not 7 whole days, so the unit reading is wrong", literal)
	}
	if DisbandNotInCamp != 3 || MemberClass0 != 0 {
		t.Errorf("DisbandNotInCamp = %d, MemberClass0 = %d; want 3 and 0", DisbandNotInCamp, MemberClass0)
	}
	if ErrNotDisorganization7D != ErrNotOpen7D+1 {
		t.Errorf("0x681d is computed as 0x681c + 1 in the validator; got %#x", ErrNotDisorganization7D)
	}
}

// One literal, one function, two refusals: ban reaches 0x5dd3f0 directly and
// leave through the thunk at 0x5dd490.
func TestMemberWindowIsOneDayOfSeconds(t *testing.T) {
	const literal = 0x15180 // `mov ecx,0x15180` at 0x005dd40e
	if MemberWindowSeconds != literal {
		t.Errorf("MemberWindowSeconds = %d, want %d", MemberWindowSeconds, literal)
	}
	if hour := 3600; literal%hour != 0 || literal/hour != 24 {
		t.Errorf("%d seconds is not 24 whole hours, so the unit reading is wrong", literal)
	}
}

func okBan() BanRequest {
	return BanRequest{InCamp: true, HasMemberRecord: true, MemberClass: MemberClass0,
		TargetFound: true, TargetSinceStamp: MemberWindowSeconds}
}

func TestBanAcceptsTheMinimum(t *testing.T) {
	if got := CheckBan(okBan()); got != 0 {
		t.Errorf("a class-0 ban of a member exactly 24h in gave %#x, want 0", got)
	}
}

func TestBanOrderIsTheBinarys(t *testing.T) {
	for _, tc := range []struct {
		name string
		r    BanRequest
		want int
	}{
		{"nothing right", BanRequest{}, ErrNoCamp},
		{"student banning a missing name", BanRequest{InCamp: true, HasMemberRecord: true,
			MemberClass: MemberClassStudent}, ErrOrderWork},
		{"class 0, missing name, fresh", BanRequest{InCamp: true, HasMemberRecord: true}, ErrOrderWorkNoMember},
		{"class 0 banning themself, fresh", BanRequest{InCamp: true, HasMemberRecord: true,
			TargetFound: true, TargetIsCaller: true}, ErrOrderWork},
	} {
		if got := CheckBan(tc.r); got != tc.want {
			t.Errorf("%s: got %#x, want %#x", tc.name, got, tc.want)
		}
	}
}

func TestBanWindowBoundary(t *testing.T) {
	r := okBan()
	r.TargetSinceStamp = MemberWindowSeconds - 1
	if got := CheckBan(r); got != ErrNotBan24T {
		t.Errorf("a target one second short of 24h gave %#x, want NOT_BAN_24T %#x", got, ErrNotBan24T)
	}
	for _, class := range []int{MemberClassSecondGuardian, MemberClassStudent} {
		r := okBan()
		r.MemberClass = class
		if got := CheckBan(r); got != ErrOrderWork {
			t.Errorf("a class-%d caller gave %#x, want ORDER_WORK %#x", class, got, ErrOrderWork)
		}
	}
}

func TestLeaveOrderIsTheBinarys(t *testing.T) {
	for _, tc := range []struct {
		name string
		r    LeaveRequest
		want int
	}{
		{"not in a camp", LeaveRequest{HasMemberRecord: true}, ErrNoCamp},
		{"class 0, fresh", LeaveRequest{InCamp: true, HasMemberRecord: true, MemberClass: MemberClass0}, ErrOrderWork},
		{"no member record", LeaveRequest{InCamp: true}, ErrOrderWorkNoMember},
		{"student, fresh", LeaveRequest{InCamp: true, HasMemberRecord: true,
			MemberClass: MemberClassStudent, SinceStamp: MemberWindowSeconds - 1}, ErrNotOut24T},
		{"student, exactly 24h", LeaveRequest{InCamp: true, HasMemberRecord: true,
			MemberClass: MemberClassStudent, SinceStamp: MemberWindowSeconds}, 0},
		{"second guardian, long in", LeaveRequest{InCamp: true, HasMemberRecord: true,
			MemberClass: MemberClassSecondGuardian, SinceStamp: 10 * MemberWindowSeconds}, 0},
	} {
		if got := CheckLeave(tc.r); got != tc.want {
			t.Errorf("%s: got %#x, want %#x", tc.name, got, tc.want)
		}
	}
}

// The one class that may ban and disband is the one class that may not leave.
func TestClass0GatesAreInverse(t *testing.T) {
	leave := CheckLeave(LeaveRequest{InCamp: true, HasMemberRecord: true,
		MemberClass: MemberClass0, SinceStamp: MemberWindowSeconds})
	ban := CheckBan(okBan())
	disband, _ := CheckDisband(okDisband())
	if leave != ErrOrderWork || ban != 0 || disband != 0 {
		t.Errorf("class 0: leave %#x (want ORDER_WORK), ban %#x and disband %#x (want 0)",
			leave, ban, disband)
	}
}

// The founding cooldown is 7 because the penalty CTJ_PenaltyKeeper::Create
// builds for id 7 is 604,800 seconds -- NOT because FUN_004114d0's second
// argument is 7. That argument is an id: the same helper takes id 8 for
// NOT_INVITE_24T and id 9 for NOT_ENTRY_24T, and 24 hours is neither 8 nor 9
// days. The value was right through two wrong readings; this test pins it to
// the one that is read.
func TestReopenCooldownComesFromThePenalty(t *testing.T) {
	sec, ok := PenaltySeconds(PenaltyIDOpen)
	if !ok || sec != ReopenCooldownDays*24*3600 {
		t.Errorf("penalty id %d lasts %d s (ok=%v), but ReopenCooldownDays says %d days (%d s)",
			PenaltyIDOpen, sec, ok, ReopenCooldownDays, ReopenCooldownDays*24*3600)
	}
	if ReopenCooldownDays != 7 {
		t.Errorf("ReopenCooldownDays = %d, want 7 (TC_ERROR_NOT_OPEN_7D)", ReopenCooldownDays)
	}
	// The disband window happens to be the same length (604800 s = 7 days), but
	// it is read from a literal and this one is not. Keeping both spellings --
	// seconds there, days here -- is deliberate: it stops the grounded value
	// from lending its authority to the disclosed one.
	if DisbandWindowSeconds != int(ReopenCooldownDays)*24*3600 {
		t.Logf("the two 7-day windows have drifted apart: disband %d s, reopen %d d. "+
			"That is allowed -- they are separate mechanisms -- but check it was meant",
			DisbandWindowSeconds, ReopenCooldownDays)
	}
}

// The durations read from CTJ_PenaltyKeeper::Create's jump table.
func TestPenaltyDurations(t *testing.T) {
	for _, tc := range []struct {
		id, want int
	}{
		{PenaltyIDOpen, 604800},
		{PenaltyIDInvite, 86400},
		{PenaltyIDEnter, 86400},
		{PenaltyIDEnter3D, 259200},
	} {
		got, ok := PenaltySeconds(tc.id)
		if !ok || got != tc.want {
			t.Errorf("PenaltySeconds(%d) = (%d, %v), want (%d, true)", tc.id, got, ok, tc.want)
		}
	}
	// Ids this package has not read must say so rather than answer 0.
	for _, id := range []int{0, 1, 2, 3, 4, 5, 6, 11} {
		if _, ok := PenaltySeconds(id); ok {
			t.Errorf("PenaltySeconds(%d) claims to know an id the academy does not check", id)
		}
	}
}

// The trap this table exists to stop: both entry penalties refuse with the
// message named NOT_ENTRY_24T, and they are not the same length. A window read
// off an engine string's name would be wrong for one of them.
func TestBothEntryPenaltiesShareAMessageButNotALength(t *testing.T) {
	short, _ := PenaltySeconds(PenaltyIDEnter)
	long, _ := PenaltySeconds(PenaltyIDEnter3D)
	if short == long {
		t.Errorf("both entry penalties are %d s; the jump table has them at 86400 and 259200", short)
	}
	if short != 24*3600 {
		t.Errorf("the 24T-named penalty is %d s, which is not 24 hours", short)
	}
	if long != 3*24*3600 {
		t.Errorf("the second entry penalty is %d s, which is not 3 days", long)
	}
}

// Invite and entry are both a day, from one shared block in that switch.
func TestInviteAndEntryShareTheirLength(t *testing.T) {
	inv, _ := PenaltySeconds(PenaltyIDInvite)
	ent, _ := PenaltySeconds(PenaltyIDEnter)
	if inv != ent || inv != MemberWindowSeconds {
		t.Errorf("invite %d s, entry %d s, ban/leave %d s: case 8 and case 9 are one block "+
			"at 0x00651c81 and 86400 is also the ban/leave window", inv, ent, MemberWindowSeconds)
	}
}
