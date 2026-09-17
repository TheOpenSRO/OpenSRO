// Package siege holds the fortress-war rules recovered from SR_GameServer.exe.
//
// srrevamp has no fortress war and is not about to grow one; this package is
// the recovered rule set, with the numbers the engine actually enforces, so
// that building one later starts from the game's own behaviour instead of a
// guess. Every constant below is a literal in the binary, cited to the check
// that reads it.
//
// The refusal codes are the engine's, and their names come from
// docs/protocol/error_codes.md, which decoded them from the client's own
// message switch. That is what makes each check's MEANING recoverable rather
// than just its shape -- a branch returning 0x280c is not "the fifth test", it
// is TOOLESSGUILDLV.
//
// See docs/protocol/siege.md.
package siege

// The fortress-war refusal codes this package covers, with the client's name
// for each.
const (
	ErrOnlyGuildMaster    = 0x2807 // FORT_ETC_ERROR_ONLYGUILDMASTER_ACTION
	ErrTaxUnavailable     = 0x2808 // FORT_MANAGER_TAX_ERROR_01
	ErrNotInGuild         = 0x280b // FORT_ETC_ERROR_NOTJOINGUILD
	ErrGuildLevelTooLow   = 0x280c // FORT_ETC_ERROR_TOOLESSGUILDLV
	ErrTooFewGuildMembers = 0x280d // FORT_ETC_ERROR_TOOLESSGUILDMB
	ErrNotEnoughMoney     = 0x280f // INTERACTION_FAIL_NOT_ENOUGH_MONEY
	ErrAlreadyApplied     = 0x2810 // FORT_OFFICIAL_FORTWAR_APPLY_ERROR_03
	ErrAlreadyPossessFort = 0x2811 // FORT_ETC_ERROR_ALREADYPOSSESSFORT
	ErrWrongAlliance      = 0x2812 // FORT_ETC_ERROR_WRONGALLIANCE
	ErrTaxUnchanged       = 0x2838 // FORT_MANAGER_TAX_ERROR_03
	ErrTaxRejected        = 0x2815 // FORT_MANAGER_TAX_ERROR_02
	ErrCannotAttackAlly   = 0x303c // FORT_BATTLE_ERR_CANT_ATTACK_ALLYGUILD
	ErrCannotAttackFort   = 0x3020 // SKILL_USE_FAIL_CANT_ATTACK_FORTRESS
	ErrOnlyDuringWar      = 0x3043 // FORT_BATTLE_ERR_CAN_ONLYPERIODFORT
)

// ResponseOpcode is the opcode the fortress handlers answer on, `0xb05e`. Four
// separate handlers send it -- the registration path (0x00633910), the tax path
// (0x0062f640), and two inside AQ_Siege -- each as
// `(*(this + 0x278))(0xb05e)`, the server's send-header call.
const ResponseOpcode = 0xb05e

// Registration -----------------------------------------------------------

// The requirements a guild must meet to register for a fortress war, read from
// FUN_00633910 in the order that function tests them.
const (
	// MinGuildLevel is 3: `if (GuildLevel() < 3) return 0x280c`.
	MinGuildLevel = 3

	// MinGuildMembers is 7: `if (*(byte *)(guild + 0x24) < 7) return 0x280d`.
	//
	// The offset is worth noting on its own. `guild + 0x24` is the member
	// count, which is what internal/guild already concluded from a completely
	// different function -- the "is this guild full" predicate at 0x005d0fb0,
	// which compares the per-level cap table against the same field. Two
	// unrelated checks reading the same offset as a member count is the
	// confirmation.
	MinGuildMembers = 7
)

// RegistrationRequest is what FUN_00633910 has to work with.
type RegistrationRequest struct {
	InGuild       bool
	IsGuildMaster bool
	GuildLevel    int
	GuildMembers  int
	// AlreadyOwnsFortress covers both of the function's two paths to
	// ALREADYPOSSESSFORT -- the guild already holding one, and the fortress
	// already being held.
	AlreadyOwnsFortress bool
	// AllianceMatches is the comparison between the applicant's alliance and
	// the fortress's; a mismatch is WRONGALLIANCE.
	AllianceMatches bool
	EnoughGold      bool
	AlreadyApplied  bool
}

// CheckRegistration returns 0 when the request would be accepted, or the
// engine's refusal code.
//
// The ORDER is the binary's, and it is observable: a guild that is both below
// level 3 and below seven members is told about the level, because that test
// comes first. A reimplementation that validated in a different order would
// show players a different message for the same guild.
func CheckRegistration(r RegistrationRequest) int {
	switch {
	case !r.InGuild:
		return ErrNotInGuild
	case r.AlreadyOwnsFortress:
		return ErrAlreadyPossessFort
	case !r.AllianceMatches:
		return ErrWrongAlliance
	case !r.IsGuildMaster:
		return ErrOnlyGuildMaster
	case r.GuildLevel < MinGuildLevel:
		return ErrGuildLevelTooLow
	case r.GuildMembers < MinGuildMembers:
		return ErrTooFewGuildMembers
	case !r.EnoughGold:
		return ErrNotEnoughMoney
	case r.AlreadyApplied:
		return ErrAlreadyApplied
	}
	return 0
}

// Tax --------------------------------------------------------------------

// The fortress tax ratio bounds. FUN_0062f640 validates the value straight off
// the packet, before anything else:
//
//	62f68c  mov ebx,DWORD PTR [esp+0x10]   ; the ratio, 16-bit
//	62f690  lea ecx,[ebx+0x14]             ; + 20
//	62f693  cmp cx,0x28                    ; against 40
//	62f697  ja  reject                     ; UNSIGNED above
//
// Read as a signed 16-bit value that accepts exactly -20 through +20. The test
// is written as one unsigned comparison rather than two signed ones, which is
// the usual compiler shape for a symmetric range and is why this looks stranger
// than it is.
const (
	TaxRatioMin = -20
	TaxRatioMax = 20

	// TaxRatioBias and TaxRatioSpan are the literals, kept so ValidTaxRatio can
	// be checked against the instruction rather than against a restatement.
	TaxRatioBias = 20
	TaxRatioSpan = 40
)

// ValidTaxRatio reproduces the engine's check exactly, including its unsigned
// 16-bit wraparound, rather than the range it happens to accept.
func ValidTaxRatio(ratio int16) bool {
	return uint16(ratio+TaxRatioBias) <= TaxRatioSpan
}

// TaxChangeAccepted reports whether a tax change would be applied. Beyond the
// range, FUN_0062f640 refuses two more things: setting the ratio to the value
// it already has (TAX_ERROR_03), and anyone but the guild master asking.
func TaxChangeAccepted(current, next int16, isGuildMaster bool) int {
	if !ValidTaxRatio(next) {
		return ErrTaxRejected
	}
	if next == current {
		return ErrTaxUnchanged
	}
	if !isGuildMaster {
		return ErrOnlyGuildMaster
	}
	return 0
}

// Attacking --------------------------------------------------------------

// AttackTarget is what CGObjSiegeStruct::vslot_395 (0x0052c500) and its sibling
// on CGObjSiegeObject (0x0052c6a0) decide about. Both return 1 to permit and 0
// with a refusal code.
type AttackTarget struct {
	// WarPeriodActive is the FIRST thing either function tests, before the
	// target is even looked at. Outside the war period nothing about a
	// fortress structure can be attacked.
	WarPeriodActive bool
	// SameGuild and AlliedGuild both produce CANT_ATTACK_ALLYGUILD; the
	// function reaches that label from two different comparisons.
	SameGuild   bool
	AlliedGuild bool
	// ImmuneBodyMode is true when the attacker's or the target's body-mode
	// byte (vtable slot 64, `+0x100`) is 2, 3 or 4. Any of those refuses with
	// CANT_ATTACK_FORTRESS. What the three modes are is NOT recovered -- only
	// that these three are the ones the check rejects.
	ImmuneBodyMode bool
}

// CanAttack returns 0 when the attack is permitted, or the refusal code.
func CanAttack(t AttackTarget) int {
	if !t.WarPeriodActive {
		return ErrOnlyDuringWar
	}
	if t.ImmuneBodyMode {
		return ErrCannotAttackFort
	}
	if t.SameGuild || t.AlliedGuild {
		return ErrCannotAttackAlly
	}
	return 0
}

// The database surface --------------------------------------------------

// Procs are the nine stored procedures the fortress war calls, with the
// argument count from each call literal. See internal/persistence for the full
// catalogue and how these were read.
var Procs = map[string]int{
	"_SiegeFortressRequestSiege":    4,
	"_AddSiegeFortressObject":       10,
	"_SiegeFortressHireNPC":         5,
	"_SiegeFortressTaxCollect":      3,
	"_SiegeFortressEngageBlessBuff": 3,
	"_SiegeFortressEntryDungeon":    2,
	"_UpdateSiegeFortressTaxRatio":  2,
	"_SiegeFortressFinished":        1,
	"_SiegeFortressTempFinished":    1,
}

// ReferenceTables are the eleven _REFSIEGE* tables, plus the two runtime tables
// the war writes. None has a column layout recovered.
var ReferenceTables = []string{
	"_REFSIEGEBLESSBUFF",
	"_REFSIEGEDUNGEON",
	"_REFSIEGEFORTRESS",
	"_REFSIEGEFORTRESSBATTLERANK",
	"_REFSIEGEFORTRESSGUARD",
	"_REFSIEGEFORTRESSITEMFORGE",
	"_REFSIEGEFORTRESSREWARDS",
	"_REFSIEGELVLSUMMONMONSTER",
	"_REFSIEGEQUEST",
	"_REFSIEGEQUESTREWARD",
	"_REFSIEGESTRUCTUPGRADE",
}

// RuntimeTables are the two the war writes to.
var RuntimeTables = []string{
	"_SIEGEFORTRESSSTRUCT",
	"_LOGEVENTSIEGEFORTRESS",
}
