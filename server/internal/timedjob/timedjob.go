// Package timedjob holds the timed-job machinery recovered from
// SR_GameServer.exe: the engine's general mechanism for "this expires at a
// time", which it uses for premium periods, skill cooldowns, death penalties,
// market tickets and more.
//
// OpenSRO has none of it, and several things it does have -- the death
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
// __purecall -- so three methods every job kind must implement. What those
// three ARE is read (round 274, 2026-09-20), from the manager's sweep and
// from CTJ_PenaltyKeeper's and CTJ_CoolTimeKeeper's overrides:
//
//	slot 8   Tick(elapsedSeconds float) -> keep?   the countdown AND the test
//	slot 10  Release()                             slot 9, then back to the pool
//	slot 12  Apply()                               run over every job on demand
const (
	SlotDestructor = 0
	SlotCreate     = 3 // named by the engine on CTJ_OpenMarketTicketKeeper
	SlotPersist    = 6 // builds and runs the _ADDTIMEDJOB call
	SlotTick       = 8
	SlotRelease    = 10
	SlotApply      = 12
	SlotCount      = 15

	// The placeholder names these three carried before round 274 read them.
	SlotPureA = SlotTick
	SlotPureB = SlotRelease
	SlotPureC = SlotApply
)

// The record a job persists. FUN_00650980 (vtable slot 6) builds the call
// literal
//
//	{?=CALL _ADDTIMEDJOB (%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%I64d,%d)}
//
// and fills it by calling fourteen consecutive getters -- vtable offsets 0x64
// through 0x98, slots 25 through 38 -- NOT on the job, but on the object the
// job holds at +8 (`piVar2 = *(int **)(param_1 + 8)`). That is the correction
// round 274 made: CTimedJob is a FIFTEEN-slot base and cannot have a slot 38,
// while the three common-data carriers have 39 slots each, which is exactly
// enough. The same object answers the category and id the lookup matches on.
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

// How a job fires -- READ 2026-09-20 (round 274), from the manager's sweep
// (0x6560c0), CTJ_PenaltyKeeper::Tick (0x652080) and CTJ_PenaltyKeeper::Create
// (0x651b20).
//
// A character's manager is EMBEDDED IN GObjPC at +0x1dfc -- the call site
// passes `param_1 + 0x77f` on an int*, which is that byte offset -- and the
// pet's at +0x1ce4 of its owner. Once a second (CGObjPC::vslot_415, the PC's
// periodic update, grounded at one second in round 223) the sweep walks the
// list and calls each job's slot 8 with the elapsed time as a float: the call
// site pushes 0x3f800000, which is 1.0f. A job that answers 0 is handed to
// manager slot 4, unlinked, and released through slot 10.
//
// There are two expiry styles, chosen by the job's own id:
//
//   - a COUNTDOWN in the record (penalty id 0): the dword the carrier's slot 28
//     returns and its slot 13 writes is reduced by the elapsed seconds each
//     tick, rounded. The field is read UNSIGNED (the `+ 2^32` fixup at
//     0xb45ba4 on a negative int).
//   - an ABSOLUTE __time32_t (every other penalty id): Create stores
//     `_time32(NULL) + span` through the same slot-13 setter, and the tick
//     compares it with the clock only every WallClockPollSeconds.
//
// The presence of the entry IS the penalty: the checks (GObjPC::HasTimedJob,
// 0x411440) do no clock arithmetic at all, they match category and id.
const (
	// TickSeconds is what the sweep passes each job: one second, the literal
	// 1.0f at the call site.
	TickSeconds = 1.0

	// WallClockPollSeconds is how often a job whose expiry is an absolute
	// timestamp actually reads the clock. It accumulates the per-tick elapsed
	// seconds at job+0xc and checks when the total reaches 10.0
	// (`fcomp ds:0xb45b44`), then SUBTRACTS 10.0 (`fsub QWORD ds:0xb45c60`,
	// a double) rather than resetting -- so the poll is periodic and does not
	// drift. A timestamp job can therefore outlive its expiry by up to ten
	// seconds.
	WallClockPollSeconds = 10.0

	// PenaltyPointsRearmSeconds is 0x2a300 = 48 hours: when the penalty-points
	// job (id 0) runs its counter out while the character still has points, it
	// re-arms for another 48 hours instead of expiring.
	PenaltyPointsRearmSeconds = 172800
)

// Where the pieces sit, as byte offsets and vtable slots.
const (
	// ManagerOffsetInPC is where CTimedJobManagerForPC lives inside GObjPC.
	ManagerOffsetInPC = 0x1dfc
	// JobOwnerOffset holds the owning character; the persist path checks it
	// with slot 7 (IsPC) before building the SQL.
	JobOwnerOffset = 4
	// JobDataOffset holds the common-data carrier the getters belong to.
	JobDataOffset = 8

	// On the carrier: the two fields a lookup matches, and the expiry pair.
	CategoryGetterSlot = 26 // +0x68
	IDGetterSlot       = 27 // +0x6c
	ExpiryGetterSlot   = 28 // +0x70
	ExpirySetterSlot   = 13 // +0x34
)

// PollAccumulator is the engine's periodic gate for a timestamp expiry: each
// tick's elapsed seconds are added, and the clock is read only once the total
// reaches WallClockPollSeconds, which is then subtracted rather than cleared.
type PollAccumulator struct{ total float64 }

// Add books one tick and reports whether the wall clock should be read now.
func (p *PollAccumulator) Add(elapsedSeconds float64) bool {
	p.total += elapsedSeconds
	if p.total < WallClockPollSeconds {
		return false
	}
	p.total -= WallClockPollSeconds
	return true
}

// Pending is the accumulated time not yet spent on a poll.
func (p *PollAccumulator) Pending() float64 { return p.total }

// Countdown is the other style: the seconds left in the record, reduced by one
// tick. It returns the value to write back and whether the job survives --
// `param_2 < remaining` keeps it, anything else expires it.
func Countdown(remainingSeconds uint32, elapsedSeconds float64) (uint32, bool) {
	if elapsedSeconds < float64(remainingSeconds) {
		left := float64(remainingSeconds) - elapsedSeconds
		return uint32(left + 0.5), true
	}
	return 0, false
}
