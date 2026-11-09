// Package academy holds the training-camp rules recovered from
// SR_GameServer.exe.
//
// "Training camp" is the engine's name for it -- every class and table says
// TRAININGCAMP and every error code says TC_. The client calls it the academy.
// This package uses the engine's word in the identifiers and the player-facing
// word in the package name, which is the same split internal/cos makes.
//
// OpenSRO has no academy. This is the rule set one would be built from.
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
	// InviteRefusedCode is what a refused invitation answers both sides
	// (round 866, MEASURED twice: B472 {02 00 00} and 3C80 {0a 02 00 00},
	// no text either side). READ s:0x5df910 sends ErrInviteRejection for an
	// answer byte other than 1; the measured behaviour is followed (the
	// user's decision, round 866).
	InviteRefusedCode = 0
	ErrAlreadyInCamp  = 0x6812 // TC_ERROR_OTHER_TRAININGCAMP_ENTRY
	ErrOrderWork      = 0x6816 // TC_ERROR_ORDER_WORK
	ErrNotOpen7D      = 0x681c // TC_ERROR_NOT_OPEN_7D
	ErrNotInvite24T   = 0x681f // TC_ERROR_NOT_INVITE_24T

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

	// ReopenCooldownDays is 7, now read from the penalty's own duration:
	// PenaltySeconds(PenaltyIDOpen) is 604,800. It stays a constant (a const
	// cannot call a function), and TestReopenCooldownComesFromThePenalty holds
	// the two together.
	//
	// TWICE CORRECTED, both on 2026-09-17, and the trail is the point.
	// This comment first said the value was grounded because "the literal 7 is
	// the second argument [of FUN_004114d0(2, 7)], and the error name carries
	// the same number". That was wrong: the second argument is an **id**, and
	// the same helper is called with id 8 for NOT_INVITE_24T and id 9 for
	// NOT_ENTRY_24T, neither of which is a day count. The citation was
	// withdrawn and the value kept, disclosed from the engine's own
	// NOT_OPEN_7D.
	//
	// Then the place where those entries are CREATED was read, and id 7's
	// duration is 604,800 seconds. The value was right, both readings that
	// reached it were wrong, and it is now grounded on the third.
	ReopenCooldownDays = 7
)

// The timed penalties the academy checks. A character carries a list at
// +0x1dfc; FUN_00411440 and FUN_004114d0 walk it and match an entry on a
// category byte (vtable slot 0x68) and an id (slot 0x6c). Each check site
// refuses when its entry is present:
//
//	id 7  -> TC_ERROR_NOT_OPEN_7D      CInstanceTrainingCamp::CheckCanCreate
//	id 8  -> TC_ERROR_NOT_INVITE_24T   TrainingCamp_CheckCanInvite (the INVITER)
//	id 9  -> TC_ERROR_NOT_ENTRY_24T    TrainingCamp_CheckCanEnter  (the TARGET)
//	id 10 -> TC_ERROR_NOT_ENTRY_24T    the same check, the branch straight after
//
// The durations are set where the entries are created, not where they are
// checked, which is why no literal is visible at any check. CTJ_PenaltyKeeper::
// Create switches on the same id (slot 0x6c) and builds each span. Read from the
// jump table at 0x00651d00 rather than from block order:
//
//	case 7      0x00651c5b  mov ecx,0x93a80   604800 s
//	case 8, 9   0x00651c81  mov ecx,0x15180    86400 s   (one block, both ids)
//	case 10     0x00651ca3  mov ecx,0x3f480   259200 s
//	case 1      0x00651bb7  span(days=3)                 the JOB GUILD's, not ours
//	case 2      0x00651bed  span(days=7)                 likewise
//	case 3,4,5  0x00651c23  span(seconds=vt+0x70())      data-driven, unread
//
// A backward scan by address finds only the 259,200: cases 7, 8 and 9 reach the
// shared tail by `jmp`. Following jumps is what makes the table complete.
const (
	// PenaltyCategory is the category byte all four academy entries carry.
	PenaltyCategory  = 2
	PenaltyIDOpen    = 7
	PenaltyIDInvite  = 8
	PenaltyIDEnter   = 9
	PenaltyIDEnter3D = 10
)

// PenaltySeconds is how long each academy penalty lasts, from
// CTJ_PenaltyKeeper::Create. ok is false for an id this package has not read.
//
// NOTE the last row. Both entry penalties refuse with the message named
// NOT_ENTRY_**24T**, and one of them lasts three days. A player told "24 hours"
// by that string may be waiting three times as long. Anyone tempted to take a
// window from an engine string's name should read this row first.
func PenaltySeconds(id int) (seconds int, ok bool) {
	switch id {
	case PenaltyIDOpen:
		return 604800, true // 7 days
	case PenaltyIDInvite, PenaltyIDEnter:
		return 86400, true // 24 hours
	case PenaltyIDEnter3D:
		return 259200, true // 3 days
	}
	return 0, false
}

// The two level thresholds in FUN_00519770's membership check
// (CInstanceTrainingCamp::CheckMembershipLevel), which refuses with
// TC_ERROR_POSIBLE_41L -- code **0x6822**.
//
// ROUND 865: this function is the handler of request 0x7476, the GUARDIAN
// graduating another member by name (READ from the server's message map; the
// client sends it from the slot's "Graduate" button, c:0x825100). So these are
// FORCED-GRADUATION floors, not membership floors: an apprentice can be made to
// graduate from max level 41, an assistant guardian from 61, matching the text
// "Forced graduation is possible from level 41." The names below are kept so
// the recovery stays additive; ForcedGraduationLevel says what they are.
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
	// Round 865: that byte is the character lock (docs/protocol/char_lock.md),
	// held while a DB query or transaction is in flight. The disband validator opens with the
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
	// WHICH timestamp: +0x1c is CreationDate (round 865, READ from the
	// _TRAININGCAMP binder; docs/protocol/academy.md). MEASURED: 20 min 11 s
	// after a founding the refusal carried 603,589 s, which is 604,800 less
	// the time since the minute-rounded CreationDate.
	DisbandWindowSeconds = 0x93a80

	// DisbandNotInCamp is what the validator returns when the caller is in no
	// camp: the bare integer 3, the same generic result InviteRefused is, not
	// a TC_ERROR code. (The job request that follows re-tests the same field
	// and would say 0x680b, but it cannot be reached with it empty.)
	DisbandNotInCamp = 3

	// MemberClass0 is the only class TrainingCamp_IsMemberClass0 admits, and so
	// the only class that may disband.
	//
	// Round 865: class 0 is the GUARDIAN, the founder. READ: the client titles
	// a class-0 member UIIT_STT_TC_GUARDIAN (c:0x6e8ed0) and gives it grade 7
	// (c:0x98e120). MEASURED: the founder's member record carries class 0, a
	// stored member with a max level of 60 or more is class 0, and the honor
	// ranking names each camp by its class-0 member.
	MemberClass0 = 0

	// MemberClassGuardian is MemberClass0 by its role.
	MemberClassGuardian = MemberClass0
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
// names. Round 865: +0x40 on the member record is JoinDate (READ from the
// _TRAININGCAMPMEMBER binder); MEASURED, a member who joined minutes earlier
// is refused both leave (0x6821) and ban (0x6820).
//
// TC_ERROR_NOT_INVITE_24T and NOT_ENTRY_24T are timed penalties instead (ids 8,
// 9 and 10; PenaltySeconds).
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

// Graduation -- round 865 (docs/protocol/academy.md, "Graduation").
//
// A member graduates itself with 0x7475 {u8 evaluation} once its MAX level
// (GetMaxLevel) reaches SelfGraduationLevel: 40 for an apprentice, 60 for an
// assistant guardian; below that the server refuses with 0x681a
// (TC_ERROR_GRADUATION_LEVER, READ s:0x5196e3). The guardian graduates another
// member with 0x7476 {str name} from ForcedGraduationLevel (the member record's
// stored CharMaxLevel: 41 / 61, else 0x6822).
const (
	ErrGraduationLevel = 0x681a // TC_ERROR_GRADUATION_LEVER

	// GraduationExp is what a self-graduating APPRENTICE gains (READ
	// s:0x5dfc69 `push 0x1e8480`). A forced graduation and an assistant's
	// graduation gain nothing.
	GraduationExp = 2_000_000

	// HonorJoinLevelCeiling: only an apprentice who JOINED at this level or
	// below earns the camp honor points and evaluation (READ s:0x5e3730 in
	// the game server; MEASURED as the stored graduation rule).
	HonorJoinLevelCeiling = 30
)

// SelfGraduationLevel is the max level a member needs to graduate itself.
// ok is false for the guardian, who cannot graduate (the server answers 5).
func SelfGraduationLevel(class int) (level int, ok bool) {
	switch class {
	case MemberClassStudent:
		return 40, true
	case MemberClassSecondGuardian:
		return 60, true
	}
	return 0, false
}

// ForcedGraduationLevel is the stored max level the guardian's 0x7476 needs.
func ForcedGraduationLevel(class int) (level int, ok bool) {
	return MembershipLevelFloor(class)
}

// EvaluationPoints maps the evaluation byte an apprentice sends with 0x7475
// (0 very disappointed .. 4 very satisfied; the client's judge window,
// c:0x80867c) to the camp's EvaluationPoint delta: the table at s:0xade9a4. A
// byte above 4 is refused with 5. An assistant sends 0 and the server passes 0
// for it; a forced graduation passes 1 (s:0x5198a7).
var EvaluationPoints = [5]int{-3, -1, 1, 3, 5}

// GraduationHonor is what an apprentice's graduation pays: the guardian gains
// 40 - joinLevel honor points and EACH assistant guardian a tenth of that,
// truncated -- only when the apprentice joined at HonorJoinLevelCeiling or
// below (READ: s:0x5e3730 with the double 0.1 at s:0xb45ec0; MEASURED as the
// stored graduation rule). An assistant's graduation pays nothing.
func GraduationHonor(joinLevel int) (guardian, assistant int) {
	if joinLevel > HonorJoinLevelCeiling {
		return 0, 0
	}
	guardian = 40 - joinLevel
	return guardian, guardian / 10
}

// The invitation (round 865). The invitee gets 0x3080 kind 9 and has
// InviteWaitSeconds to answer (READ: the float 30.0 at s:0xb45b48; MEASURED
// 30.4 s and 30.5 s from 0x7472 to the refusal). On a timeout the engine
// truncates its code 0x680e to the low byte (s:0x46cf0f `movzx ax,bl`), so
// both sides receive 0x000E -- MEASURED on 0xB472 and on 0x3C80 {0x0a, 2}.
const (
	InviteKind        = 9
	InviteWaitSeconds = 30
	ErrInviteTimeout  = 0x000e
)
