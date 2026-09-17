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

// The two level thresholds in FUN_00519770's membership check, which refuses
// with TC_ERROR_POSIBLE_41L:
//
//	if ((a != 0 && level < 0x29) || (b() != 0 && level < 0x3d))
//	    -> 0x6818
//
// Two branches, two different minimums, one shared refusal. The error name
// carries 41, which matches the first.
//
// WHICH BRANCH IS WHICH ROLE IS NOT RECOVERED. A training camp has a master and
// apprentices and it is tempting to map them onto these two numbers, but
// nothing read so far says which predicate selects which, so this package names
// them by their values rather than by a role.
const (
	MembershipLevelA = 41
	MembershipLevelB = 61
)

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
