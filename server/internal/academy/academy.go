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
// WHICH ROLE EACH CLASS IS REMAINS NOT RECOVERED, and deliberately so. Two other
// functions (FUN_005e0790, FUN_005e0a30) test `class == 1` and SKIP that member
// inside a loop over the camp's members, which is the shape of "everyone except
// the master". That is suggestive, and this package has already recorded that
// 61 sitting one above the founder level of 60 is suggestive too. Neither is a
// use-site that names a role, so the constants below are still named by value
// and the class codes by number.
const (
	MembershipLevelA = 41 // the class-2 floor
	MembershipLevelB = 61 // the class-1 floor

	// MemberClass1 and MemberClass2 are the two values of the member record's
	// class byte (+0x50) that the membership check distinguishes. Numbers, not
	// roles -- see above.
	MemberClass1 = 1
	MemberClass2 = 2

	// ErrMembershipLevel is TC_ERROR_POSIBLE_41L. Not 0x6818.
	ErrMembershipLevel = 0x6822
)

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
