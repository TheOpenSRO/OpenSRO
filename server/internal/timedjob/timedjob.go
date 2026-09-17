// Package timedjob holds the timed-job machinery recovered from
// SR_GameServer.exe: the engine's general mechanism for "this expires at a
// time", which it uses for premium periods, skill cooldowns, death penalties,
// market tickets and more.
//
// srrevamp has none of it, and several things it does have -- the death
// penalty, berserk's duration -- are the kind of thing this mechanism exists
// to hold.
//
// See docs/protocol/timed_jobs.md.
package timedjob

// Kinds are the thirteen concrete job classes deriving from CTimedJob, with
// their vtable addresses and slot counts. The name of each is the engine's,
// and between them they say what the mechanism is for.
var Kinds = []struct {
	Name   string
	VTable uint32
	Slots  int
}{
	{"CTJ_PenaltyKeeper", 0x00b0504c, 19},
	{"CTJ_PremiumKeeper", 0x00b04fbc, 16},
	{"CTJ_CoolTimeKeeper", 0x00b05004, 16},
	{"CTJ_CompositeItemKeeper", 0x00b050fc, 16},
	{"CTJ_CharParamKeeper", 0x00b051ec, 16},
	{"CTJ_CompositeItemKeeperForPet", 0x00b0541c, 16},
	{"CTJ_SkillKeeper", 0x00b04f2c, 15},
	{"CTJ_NoneSkillExpDateJob", 0x00b04f7c, 15},
	{"CTJ_SpecialTradeKeeper", 0x00b0509c, 15},
	{"CTJ_OpenMarketTicketKeeper", 0x00b05234, 15},
	{"CTJ_EnterWorldGroupKeeper", 0x00b05274, 15},
	{"CTJ_SkillKeeperForPet", 0x00b053dc, 15},
}

// The CTimedJob interface. Fifteen slots, of which 8, 10 and 12 are
// __purecall -- so three methods every job kind must implement.
const (
	SlotDestructor = 0
	SlotCreate     = 3 // named by the engine on CTJ_OpenMarketTicketKeeper
	SlotPersist    = 6 // builds and runs the _ADDTIMEDJOB call
	SlotPureA      = 8
	SlotPureB      = 10
	SlotPureC      = 12
	SlotCount      = 15
)

// The record a job persists. FUN_00650980 (vtable slot 6) builds the call
// literal
//
//	{?=CALL _ADDTIMEDJOB (%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%I64d,%d)}
//
// and fills it by calling fourteen consecutive getters on the job object,
// vtable offsets 0x64 through 0x98 -- slots 25 through 38.
//
// THE MAPPING CONFIRMS ITSELF. Arguments are pushed right-to-left, so the
// first getter evaluated (slot 38) supplies the last argument and slot 25
// supplies the first. Argument 13 is the only `%I64d`, and slot 37 (`+0x94`)
// is the only getter whose result the decompiler types as 64-bit. The one
// wide field and the one wide getter land on each other.
const (
	// FieldCount is the number of columns in a character's timed-job row.
	FieldCount = 14
	// FirstGetterSlot is the vtable slot supplying field 1.
	FirstGetterSlot = 25
	// WideFieldIndex is the 1-based index of the `%I64d` column, which is
	// supplied by slot 37 and reads as the expiry timestamp.
	WideFieldIndex = 13
)

// GetterSlotFor returns the vtable slot that supplies a 1-based field index of
// the character timed-job record, and whether the index exists.
func GetterSlotFor(field int) (int, bool) {
	if field < 1 || field > FieldCount {
		return 0, false
	}
	return FirstGetterSlot + field - 1, true
}

// PetFieldCount is 13. FUN_0065fc60 builds
//
//	{?=CALL _ADDTIMEDJOBFORPET (%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%I64d)}
//
// from offsets 0x68 through 0x94 -- slots 26 through 37. That is the character
// run with slot 25 removed and nothing added, so **the pet record is the
// character record without its first field**, and the `%I64d` is last rather
// than second-to-last because the trailing `%d` is the one that went.
const (
	PetFieldCount      = 13
	PetFirstGetterSlot = 26
)

// Managers are the three manager classes, each a ten-slot vtable: a general
// one and one each for characters and pets.
var Managers = []string{
	"CTimedJobManager",
	"CTimedJobManagerForPC",
	"CTimedJobManagerForPet",
}

// CommonData are the three 39-slot classes that carry a job's data across the
// instance boundary.
var CommonData = []string{
	"ITimedJobCommonData",
	"CInstanceTimedJob",
	"CInstanceTimedJobForPet",
}

// Tables and Procs are the persistence surface.
var (
	Tables = []string{"_TIMEDJOB", "_TIMEDJOBFORPET"}
	Procs  = map[string]int{"_ADDTIMEDJOB": 14, "_ADDTIMEDJOBFORPET": 13}
)
