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

	// ErrNotDisorganization7D is TC_ERROR_NOT_DISORGANIZATION_7D, the disband
	// window refusal. The validator never contains the literal: it computes
	// `(-(remaining != 0) & 0x681c) + 1`, so a grep for 0x681d finds only the
	// handler that compares against it.
	ErrNotDisorganization7D = 0x681d

	// ErrOrderWorkNoMember is 0x6815. The client shows it with the same
	// TC_ERROR_ORDER_WORK text as 0x6816 (0x6813-0x6816 all map there), but the
	// server keeps it apart: both ban and leave send 0x6815 exactly when a
	// member lookup comes back empty, and 0x6816 for a permission failure.
	ErrOrderWorkNoMember = 0x6815
	ErrNotBan24T         = 0x6820 // TC_ERROR_NOT_BAN_24T
	ErrNotOut24T         = 0x6821 // TC_ERROR_NOT_OUT_24T
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

	// ReopenCooldownDays is 7, and **it rests on the refusal's name alone**.
	//
	// CORRECTED 2026-09-17. This comment used to tie it to the literal: "the
	// check is FUN_004114d0(2, 7) ... the literal 7 is the second argument, and
	// the error name carries the same number, which is what ties the two
	// together." Reading FUN_004114d0 and every call site of it and its twin
	// FUN_00411440 shows the second argument is an **id**, not a duration:
	//
	//	FUN_00411440/4114d0 walk a per-character list at +0x1dfc and match each
	//	entry on a category byte (vtable slot 0x68) and an id (slot 0x6c).
	//
	//	category 2, id 7   -> TC_ERROR_NOT_OPEN_7D     (founding)
	//	category 2, id 8   -> TC_ERROR_NOT_INVITE_24T  (0x004e4862)
	//	category 2, id 9   -> TC_ERROR_NOT_ENTRY_24T   (0x004e48d1)
	//	category 2, id 10  -> checked beside id 9, unread
	//	category 2, ids 1, 2 -> the JOB GUILD's own checks (0x00514b20, 0x005121fe)
	//
	// If the id were a day count, invite would be 8 days and entry 9 days, and
	// both names say 24 hours. The same category also serves another system
	// with ids 1 and 2. So 7 agreeing with "7D" was a coincidence.
	//
	// The value stays 7 because the engine's own refusal is named
	// NOT_OPEN_**7D**, which is a fact about the engine's vocabulary. It is
	// disclosed on that basis, not grounded in a read comparison. The length
	// lives wherever these entries are created, which is not read.
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
// slot 0x124, on the target), and REFUSES anyone above the second-guardian band:
//
//	005192ce  cmp al,0x27 ; ja    ; <= 39 -> student, capped by MaxStudents
//	00519303  cmp al,0x3b ; ja    ; 40..59 -> second guardian
//	0051937f  push 0x3 ; call send(0xb472) ; ret   ; >= 60 -> REFUSED
//
// CORRECTED 2026-09-17, same day. The previous version of this comment called
// the >= 60 path "a third branch, NOT read" and left its role unnamed. It is not
// a role at all: `00519305 ja 0x51937f` is the only way into that block, and the
// block sends result 3 and returns. There are exactly two invitable roles.
//
// Result 3 is GENERIC, not level-specific: the same routine sends 3 when the
// target fails vtable slot 0x1c -- IsPC, slot 7 -- i.e. is not a player. It is a
// small integer rather than a TC_ERROR code, so the client's error dispatcher
// has no name for it.
//
// A STRUCTURAL FACT, both halves read: the founder floor is 60
// (MinFounderLevel, `GetLevel() < 0x3c`) and the invite ceiling is 59. The two
// meet at one boundary -- a character is either old enough to found a camp or
// young enough to be invited into one, never both. What role the founder holds,
// and whether "second" guardian implies the founder is the first, is NOT read.
const (
	StudentMaxInviteLevel        = 39
	SecondGuardianMaxInviteLevel = 59
	// InviteMaxLevel is the highest level that can be invited at all.
	InviteMaxLevel = SecondGuardianMaxInviteLevel
	// InviteRefused is the result the invite handler sends on opcode 0xb472 for
	// an invitee above InviteMaxLevel -- and for a target that is not a player.
	InviteRefused = 3
)

// InviteRole is the role an invitee of the given level is invited into. ok is
// false when the engine refuses the invite outright, which it does for every
// level above InviteMaxLevel (sending InviteRefused).
func InviteRole(level int) (class int, ok bool) {
	switch {
	case level <= StudentMaxInviteLevel:
		return MemberClassStudent, true
	case level <= InviteMaxLevel:
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
	// WrongState is the validator's first test, `char[0xc]+4 == 1` -> 0x6808.
	// What that byte means is not read. The disband validator opens with the
	// same test, and this field was missing here until that was read on
	// 2026-09-17: the order below was the binary's minus its first step.
	WrongState    bool
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
	if r.WrongState {
		return ErrWrongState
	}
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

// Disbanding a camp -- TrainingCamp_CheckCanDisband (FUN_004e4780), reached
// only from TrainingCamp_HandleDisband (FUN_00519120). See academy.md.
const (
	// DisbandWindowSeconds is 604,800, read as a literal the decompiler drops:
	//
	//	005dd36a  mov  ecx,0x93a80    ; the span, 604800
	//	005dd373  call 0x9753f0       ; span = ecx
	//	005dd3a7  call 0x9755e0       ; stamp from the camp record's TIMESTAMP_STRUCT
	//	005dd3b2  call 0x975540       ; stamp.t += span
	//	005dd3bb  call 0x9755c0       ; now = _time32(NULL)
	//	005dd3ca  call 0x975530       ; span = stamp.t - now.t
	//
	// It is SECONDS because the field it is added to is written from
	// _time32(NULL) (0x009dd35a, a library match). 604800 is 7 * 24 * 3600, the
	// "7D" in the refusal's name -- the literal and the name agree, which is
	// the same pair of facts that grounds ReopenCooldownDays.
	//
	// WHICH timestamp is not read: it is a TIMESTAMP_STRUCT at +0x1c on the
	// camp's record, but no column layout of _TRAININGCAMP is recovered.
	DisbandWindowSeconds = 0x93a80

	// DisbandNotInCamp is what the validator returns when the caller is in no
	// camp: the bare integer 3, the same generic result InviteRefused is, not
	// a TC_ERROR code. (The job request that follows re-tests the same field
	// and would say 0x680b, but it cannot be reached with it empty.)
	DisbandNotInCamp = 3

	// MemberClass0 is the only class TrainingCamp_IsMemberClass0 admits, and so
	// the only class that may disband. It is named by value on purpose: class 1
	// is the second guardian and class 2 the student, each read from a count
	// function behind an engine refusal, but nothing read yet says what class
	// 0 is. "The founder" is the obvious guess and is not recorded as a fact.
	MemberClass0 = 0
)

// DisbandRequest is what TrainingCamp_CheckCanDisband decides about.
type DisbandRequest struct {
	WrongState bool // char[0xc]+4 == 1, as in CreateRequest
	Alive      bool
	InCamp     bool
	// HasMemberRecord and MemberClass are TrainingCamp_IsMemberClass0's two
	// halves: the member lookup (a miss returns 0) and the class byte (+0x50).
	HasMemberRecord bool
	MemberClass     int
	// SinceStamp is now minus the camp record's timestamp, in seconds.
	SinceStamp int64
}

// CheckDisband returns 0 when a camp may be disbanded, or the refusal code. On
// ErrNotDisorganization7D, remaining is the seconds left in the window, which
// the engine sends as the reply's extra 4-byte field. The order is the
// binary's.
func CheckDisband(r DisbandRequest) (code int, remaining int64) {
	if r.WrongState {
		return ErrWrongState, 0
	}
	if !r.Alive {
		return ErrDeadOrBusy, 0
	}
	if !r.InCamp {
		return DisbandNotInCamp, 0
	}
	if !r.HasMemberRecord || r.MemberClass != MemberClass0 {
		return ErrOrderWork, 0
	}
	// `setle cl ; sub ecx,1 ; and eax,ecx`: a difference of 0 or less is 0, so
	// the window closes AT 604800 seconds, not after it.
	if left := DisbandWindowSeconds - r.SinceStamp; left > 0 {
		return ErrNotDisorganization7D, left
	}
	return 0, 0
}

// Banning and leaving -- TrainingCamp_HandleBan (FUN_005193a0) and
// TrainingCamp_HandleLeave (FUN_00519510), read in assembly.

// MemberWindowSeconds is 86,400, the window behind both NOT_BAN_24T and
// NOT_OUT_24T. It is one function, reached two ways:
//
//	005194a7  call 0x5dd3f0             ; HandleBan, on the TARGET member
//	005195b3  call 0x5dd490             ; HandleLeave, on the caller's own member
//	005dd490  jmp  0x5dd3f0             ; ...a thunk to the same function
//
//	005dd40e  mov  ecx,0x15180          ; 86400
//	005dd417  call 0x9753f0             ; span = ecx
//	          ...                        ; stamp = TIMESTAMP_STRUCT at record+0x40,
//	          ...                        ; stamp.t += span; span = stamp.t - _time32(NULL)
//	005dd47c  setle cl ; mov eax,ecx    ; 1 once the window has passed
//
// It is seconds for the same reason DisbandWindowSeconds is: the field it is
// added to comes from _time32. 86400 is 24 * 3600, the "24T" in both refusal
// names. Which timestamp +0x40 is on the member record (joining is the obvious
// guess) is not read.
//
// NOT covered here: TC_ERROR_NOT_INVITE_24T and NOT_ENTRY_24T. Those are not
// clock arithmetic at the check. They look up an entry (category 2, id 8 or 9)
// in a per-character list at +0x1dfc, as the founding check does for id 7, so
// their durations are set wherever the entries are created, which is not read.
const MemberWindowSeconds = 0x15180

// BanRequest is what TrainingCamp_HandleBan decides about before it calls
// TrainingCamp_RemoveMember.
type BanRequest struct {
	InCamp bool
	// HasMemberRecord and MemberClass are the CALLER's, through the same
	// TrainingCamp_IsMemberClass0 gate disband uses: only class 0 may ban.
	HasMemberRecord bool
	MemberClass     int
	// TargetFound is TrainingCamp_FindMemberByName (FUN_005e42c0): the name
	// from the packet compared with each member's by CompareStringA with
	// NORM_IGNORECASE | NORM_IGNOREKANATYPE, and any name under 2 characters
	// (lstrlenA < 2) found as nobody.
	TargetFound bool
	// TargetIsCaller is TrainingCampMember_GetKey(target) == the caller's key.
	TargetIsCaller bool
	// TargetSinceStamp is now minus the TARGET's member-record timestamp.
	TargetSinceStamp int64
}

// CheckBan returns 0 when the ban goes ahead, or the refusal code, in the
// binary's order.
func CheckBan(r BanRequest) int {
	if !r.InCamp {
		return ErrNoCamp
	}
	if !r.HasMemberRecord || r.MemberClass != MemberClass0 {
		return ErrOrderWork
	}
	if !r.TargetFound {
		return ErrOrderWorkNoMember
	}
	if r.TargetIsCaller {
		return ErrOrderWork
	}
	if r.TargetSinceStamp < MemberWindowSeconds {
		return ErrNotBan24T
	}
	return 0
}

// LeaveRequest is what TrainingCamp_HandleLeave decides about.
type LeaveRequest struct {
	InCamp          bool
	HasMemberRecord bool
	MemberClass     int
	SinceStamp      int64 // now minus the caller's own member-record timestamp
}

// CheckLeave returns 0 when the caller may leave, or the refusal code, in the
// binary's order. The class gate is the INVERSE of ban's: `cmp eax,0x1 ; jne`
// after TrainingCamp_IsMemberClass0, so class 0 is the one member who cannot
// leave. A missing member passes that gate (it answers 0) and is refused by
// the lookup that follows instead.
func CheckLeave(r LeaveRequest) int {
	if !r.InCamp {
		return ErrNoCamp
	}
	if r.HasMemberRecord && r.MemberClass == MemberClass0 {
		return ErrOrderWork
	}
	if !r.HasMemberRecord {
		return ErrOrderWorkNoMember
	}
	if r.SinceStamp < MemberWindowSeconds {
		return ErrNotOut24T
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
