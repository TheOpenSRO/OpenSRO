// Package academy holds the training-camp rules recovered from
// SR_GameServer.exe.
//
// "Training camp" is the engine's name for it -- every class and table says
// TRAININGCAMP and every error code says TC_. The client calls it the academy.
// This package uses the engine's word in the identifiers and the player-facing
// word in the package name, which is the same split internal/cos makes.
//
// srrevamp has no academy. This is the rule set one would be built from.
//
// See docs/protocol/academy.md.
package academy

// The refusal codes, with the client's name for each.
const (
	ErrDeadOrBusy      = 0x6807 // the IsAlive() check
	ErrWrongState      = 0x6808
	ErrOpenLevel       = 0x6809 // TC_ERROR_OPEN_LEVEL
	ErrOpenGold        = 0x680a // TC_ERROR_OPEN_GOLD
	ErrNoCamp          = 0x680b // TC_ERROR_TRAININGCAMP_NOTHING
	ErrInviteRejection = 0x6811 // TC_ERROR_INVITE_REJECTION
	ErrAlreadyInCamp   = 0x6812 // TC_ERROR_OTHER_TRAININGCAMP_ENTRY
	ErrOrderWork       = 0x6816 // TC_ERROR_ORDER_WORK
	ErrNotOpen7D       = 0x681c // TC_ERROR_NOT_OPEN_7D
	ErrNotInvite24T    = 0x681f // TC_ERROR_NOT_INVITE_24T
)

// Creating a camp -- FUN_004e4680, in the order it tests.
const (
	// MinFounderLevel is 60: `if (GetLevel() < 0x3c) return 0x6809`.
	MinFounderLevel = 60

	// FoundingGold is 100,000, compared with the same 64-bit pattern the guild
	// level-up cost uses:
	//
	//	iVar1 = *(int *)(inv + 0x7c);                        // the high dword
	//	if (iVar1 < 1 && (iVar1 < 0 || *(uint *)(inv + 0x78) < 100000))
	//	    return 0x680a;
	//
	// which is the third place in this project's recovery where a character's
	// gold is read as 64-bit at +0x78 / +0x7c.
	FoundingGold = 100_000

	// ReopenCooldownDays is 7. The check is a call to FUN_004114d0(2, 7) whose
	// non-null result refuses with TC_ERROR_NOT_OPEN_7D -- the literal 7 is the
	// second argument, and the error name carries the same number, which is
	// what ties the two together.
	ReopenCooldownDays = 7
)

// The two level thresholds in FUN_00519770's membership check
// (CInstanceTrainingCamp::CheckMembershipLevel), which refuses with
// TC_ERROR_POSIBLE_41L -- code **0x6822**.
//
// CORRECTED 2026-09-17. This comment, docs/protocol/academy.md and the
// function's Ghidra comment all gave the code as 0x6818. **0x6818 is not in the
// client's error table at all**; the branch pushes `0x6822`, and 0x6822 is
// UIIT_MSG_TC_ERROR_POSIBLE_41L. The name was right and the number was wrong.
//
// The predicates were recorded as `a != 0` and `b() != 0`. They are now read,
// in assembly:
//
//	00519872  mov edx,[edi+0x34]       ; the MEMBER's record
//	00519875  mov dl,[edx+0x53]         ; the member's LEVEL byte
//	0051987a  call 0x5e36e0             ; [+0x34][+0x50] == 2 ?
//	00519883  cmp dl,0x28 ; jbe refuse  ; class 2 needs level >= 41
//	0051988a  call 0x5e36c0             ; [+0x34][+0x50] == 1 ?
//	00519893  cmp dl,0x3c ; ja  pass    ; class 1 needs level >= 61
//	00519898  push 0x6822
//
// So a member record carries a CLASS byte at +0x50 and a LEVEL byte at +0x53,
// and the floor depends on the class: **class 2 -> 41, class 1 -> 61**. The level
// tested is the looked-up member's stored level, not the caller's.
//
// WHICH ROLE EACH CLASS IS -- RECOVERED 2026-09-17, from use-sites only.
//
// The roles are named by the engine's own refusals, and each one reaches the
// class byte through a chain of calls with no inference in it:
//
//	TC_ERROR_STUDENT_COUNT_OVER (0x6828)
//	  <- cap   FUN_005e44d0: count >= 5
//	  <- count FUN_005e4460: counts members where FUN_005e36e0() -- class == 2
//
//	TC_ERROR_SECOND_GUARDIAN_COUNT_OVER (0x6810)
//	  <- cap   FUN_005e4450: count >= 2
//	  <- count FUN_005e43e0: counts members where FUN_005e36c0() -- class == 1
//
// So **class 2 is a STUDENT and class 1 is a SECOND GUARDIAN**.
//
// A PREVIOUS READING HERE WAS WRONG, and declining to promote it was right.
// This comment used to note that two functions skip `class == 1` inside a loop
// over the members, "the shape of 'everyone except the master'", and that 61
// sits one above the founder level of 60 -- two suggestive readings pointing at
// class 1 being the master. Class 1 is the second guardian. And "master" and
// "apprentice" were never the engine's words at all; they came from outside
// knowledge of the game. Its words are student and guardian.
const (
	MembershipLevelA = 41 // the STUDENT floor (class 2)
	MembershipLevelB = 61 // the SECOND GUARDIAN floor (class 1)

	// MemberClassStudent and MemberClassSecondGuardian are the member
	// record's class byte (+0x50) values, named by the count functions above.
	MemberClassSecondGuardian = 1
	MemberClassStudent        = 2

	// MemberClass1 and MemberClass2 are the value-named aliases this package
	// used before the roles were read. Kept so the recovery is additive.
	MemberClass1 = MemberClassSecondGuardian
	MemberClass2 = MemberClassStudent

	// ErrMembershipLevel is TC_ERROR_POSIBLE_41L. Not 0x6818.
	ErrMembershipLevel = 0x6822
)

// The per-camp caps, read in assembly rather than off the decompiler:
//
//	005e44d5  cmp eax,0x5 ; sbb eax,eax ; add eax,0x1 ; ret   ; full at 5
//	005e4455  cmp eax,0x2 ; sbb eax,eax ; add eax,0x1 ; ret   ; full at 2
//
// Ghidra renders these as `4 < count` and `1 < count`. They mean the same, but
// the engine's constants are 5 and 2, and this project has had a decompiler-
// rendered bound read as one-too-few before (guild.MaxHostileGuilds).
const (
	MaxStudents        = 5
	MaxSecondGuardians = 2
)

// The invite handler assigns the role by the INVITEE's level (GetLevel, vtable
// slot 0x124, on the target):
//
//	005192ce  cmp al,0x27 ; ja    ; <= 39 -> student, capped by MaxStudents
//	00519303  cmp al,0x3b ; ja    ; 40..59 -> second guardian
//	                              ; >= 60 -> a third branch, NOT read
//
// The >= 60 branch is left unnamed: its refusal was not read, so what role an
// invitee of 60 or more takes is not recovered. The membership floors above sit
// one level past each band's top (41 past 39, 61 past 59), which is suggestive
// of those checks being about outgrowing the band -- and, per the correction
// above, suggestive is not recovered.
const (
	StudentMaxInviteLevel        = 39
	SecondGuardianMaxInviteLevel = 59
)

// InviteRole is the role an invitee of the given level is invited into, and ok
// is false for a level the read branches do not cover (60 and above).
func InviteRole(level int) (class int, ok bool) {
	switch {
	case level <= StudentMaxInviteLevel:
		return MemberClassStudent, true
	case level <= SecondGuardianMaxInviteLevel:
		return MemberClassSecondGuardian, true
	}
	return 0, false
}

// RoleFull reproduces the two cap functions: a role is full once its count
// reaches the cap, so the invite is refused when count >= cap.
func RoleFull(class, count int) bool {
	switch class {
	case MemberClassStudent:
		return count >= MaxStudents
	case MemberClassSecondGuardian:
		return count >= MaxSecondGuardians
	}
	return false
}

// MembershipLevelFloor is the minimum member level FUN_00519770 accepts for a
// member of the given class, and ok is false for a class the check does not
// test -- such a member passes without any level requirement.
func MembershipLevelFloor(class int) (floor int, ok bool) {
	switch class {
	case MemberClass2:
		return MembershipLevelA, true
	case MemberClass1:
		return MembershipLevelB, true
	}
	return 0, false
}

// MeetsMembershipLevel reproduces the check's comparisons exactly:
// `cmp dl,0x28 ; jbe refuse` and `cmp dl,0x3c ; ja pass`, i.e. strictly above
// 40 and strictly above 60.
func MeetsMembershipLevel(class, level int) bool {
	floor, ok := MembershipLevelFloor(class)
	return !ok || level >= floor
}

// CreateRequest is what FUN_004e4680 decides about.
type CreateRequest struct {
	Alive         bool
	Level         int
	Gold          int64
	AlreadyInCamp bool
	// WithinReopenCooldown is the FUN_004114d0(2, 7) result: a camp closed
	// less than ReopenCooldownDays ago blocks a new one.
	WithinReopenCooldown bool
}

// CheckCreate returns 0 when a camp may be founded, or the refusal code.
// The order is the binary's.
func CheckCreate(r CreateRequest) int {
	if !r.Alive {
		return ErrDeadOrBusy
	}
	if r.Level < MinFounderLevel {
		return ErrOpenLevel
	}
	if r.Gold < FoundingGold {
		return ErrOpenGold
	}
	if r.AlreadyInCamp {
		return ErrAlreadyInCamp
	}
	if r.WithinReopenCooldown {
		return ErrNotOpen7D
	}
	return 0
}

// Classes are the four training-camp instance classes, each with a nine-slot
// vtable.
var Classes = []string{
	"CInstanceTrainingCamp",
	"CInstanceTrainingCampMember",
	"CInstanceTrainingCampHonorRank",
	"CInstanceTrainingCampBuffStatus",
}

// Tables are the four runtime tables, one per class. No column layout is
// recovered for any of them.
var Tables = []string{
	"_TRAININGCAMP",
	"_TRAININGCAMPMEMBER",
	"_TRAININGCAMPHONORRANK",
	"_TRAININGCAMPBUFFSTATUS",
}
