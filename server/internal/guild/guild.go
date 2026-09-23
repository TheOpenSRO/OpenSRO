// Package guild implements this project's own guild system: unlike party
// (in-memory, session-scoped, meant to dissolve on restart), guild
// membership is persistent -- guilds are a long-lived social structure, not
// a live grouping formed for one dungeon run. Entirely own design; no real
// guild data to RE (the original's guild system involves large amounts of
// unrelated infrastructure -- guild wars, storage, skills -- none of which
// is in scope here).
package guild

import (
	"context"
	"errors"
)

// MaxMembersByLevel is how many characters a guild may hold, by guild level.
// **RECOVERED**: 15, 20, 25, 35, 50 for levels 1 to 5.
//
// The engine's join path calls a predicate (0x005d0fb0) that answers "is this
// guild full", and it is short enough to read whole:
//
//	level = *(char *)(*(int *)(guild + 4) + 0x38);
//	if (level == 0)          { Assert; level = 1; }
//	if (4 < (byte)(level-1))   Assert;              // levels are 1..5
//	return table[level-1] <= *(uint *)(guild + 0x24);   // <- member count
//
// The caller pushes `0x4c13` when that returns 1, and the client names `0x4c13`
// `UIIT_MSG_GUILDERR_MEMBER_FULL` (docs/protocol/error_codes.md), which is what
// ties the predicate to the cap rather than to some other fullness.
//
// The table is five dwords at .rdata 0x00ade8dc, and five is exactly the range
// the assert above allows. The three dwords that follow it (5400, 50400,
// 135000) look like a guild-experience curve and are NOT claimed here -- nothing
// read so far uses them.
var MaxMembersByLevel = [5]int{15, 20, 25, 35, 50}

// MaxMembers is the cap that applies to srrevamp today: **15**, the level-1
// entry. srrevamp's guilds have no level -- Guild is {ID, Name, LeaderID,
// Members} -- so every guild is a level-1 guild, and taking a larger entry would
// be granting a capacity the game makes you earn.
const MaxMembers = 15

// MaxMembersFor returns the cap for a guild level, clamped to the range the
// engine's own assert allows. It exists so that adding guild levels later has
// the rule already written; nothing calls it with a level above 1 yet.
func MaxMembersFor(level int) int {
	if level < 1 {
		level = 1
	}
	if level > len(MaxMembersByLevel) {
		level = len(MaxMembersByLevel)
	}
	return MaxMembersByLevel[level-1]
}

// ErrGuildFull is returned by Store.Join when the guild already holds
// MaxMembers characters. The engine's own refusal is
// UIIT_MSG_GUILDERR_MEMBER_FULL.
var ErrGuildFull = errors.New("guild: guild is full")

// Permission is a guild member's permission bitmask. RECOVERED, and richer than
// the Role this package models.
//
// The engine keeps a 32-bit mask on each member's record and tests it with
// FUN_005d0f80, which is four lines:
//
//	member = FindMember(characterID);
//	if (member == 0) return false;
//	if (member->rec == 0) Assert;
//	return (*(uint *)(member->rec + 0x54) & required) == required;
//
// so a caller passes the mask it needs and every bit in it must be set. The
// refusal is UIIT_MSG_GUILDERR_PERMISSION_DENIED (docs/protocol/error_codes.md).
//
// Seven call sites carry a required mask, and what each gates is read from the
// errors its own handler raises rather than from the bit's position:
//
//	bit 0 (0x01)  invite       FUN_00514f10, the join path -- it also raises
//	                           GUILDERR_MEMBER_FULL
//	bit 3 (0x08)  warehouse    FUN_005c7440 / FUN_005c74d0, which raise
//	                           GUILD_WAREHOUSE_LIMIT
//	bit 4 (0x10)  notice       FUN_005c6480, which raises
//	                           GUILDERR_INVALID_MASTER_COMMENT and _TITLE
//
// BIT 2 (0x04) IS NOT NAMED. Two call sites require it and neither handler
// raises an error code, so nothing says what it gates. Bits 1 and 5-31 are not
// observed at any call site at all -- that is an absence of evidence, not
// evidence they are unused.
type Permission uint32

const (
	// PermInvite is required to bring a character into the guild.
	PermInvite Permission = 1 << 0
	// PermWarehouse is required to use the guild warehouse.
	PermWarehouse Permission = 1 << 3
	// PermNotice is required to edit the guild's notice and title.
	PermNotice Permission = 1 << 4
)

// Has reproduces the engine's test: EVERY bit of required must be set, which is
// why it is an equality against the mask and not a non-zero check.
func (p Permission) Has(required Permission) bool {
	return p&required == required
}

// NOTHING ENFORCES PERMISSIONS YET, and that is a statement about scope rather
// than an oversight: this package has no operation that needs one. Its Store is
// Create/Join/Leave/Get -- there is no kick, no disband, and no invite.
//
// The divergence worth recording is Join. In the engine a character is brought
// in by a member holding PermInvite; here Join is self-service, so anyone may
// join any guild by id, uninvited. Building an invite flow is the missing
// feature, and when it is built PermInvite is the bit it checks.

// Guild name length. **RECOVERED 2026-09-17**, having been own design until
// then -- the previous comment read "Own design choice" and the value was 32.
//
// The create handler (FUN_00514ce0) validates the name with one unsigned
// comparison against the std::string's own size field:
//
//	if (len - 2u < 0xb) { ...create... }
//	else FUN_004e7250(0x4c18);      // GUILDERR_INVALID_GUILDNAME_LEN
//
// so the accepted range is 2 through 12 inclusive. The same compiler shape as
// the fortress tax check in internal/siege: a symmetric bound written as one
// unsigned subtract-and-compare rather than two signed tests.
//
// srrevamp had NO minimum at all, which is the more consequential half: a
// one-character guild name was legal here and is not in the engine.
//
// **ENFORCED since round 481**: both stores' Create refuse a name outside the
// range with ErrInvalidNameLength, in the engine's order (see Store.Create).
// Before that the constants and ValidName existed and nothing called them.
//
// ONE KNOWN DIVERGENCE, in what is counted. The engine's name is a narrow
// std::string -- the handler initialises it with capacity 0xf, the MSVC
// small-string buffer of a char string -- so its size field counts bytes in the
// client's codepage. Go's len() counts UTF-8 bytes. The two agree for ASCII
// names; for non-ASCII they do not (a CJK character is 3 UTF-8 bytes, typically
// 2 in a double-byte codepage), so such a name can be refused here that the
// engine would accept. srrevamp's client sends the name as UTF-8
// (client/scripts/net/guild.gd, to_utf8_buffer), and which codepage the
// engine's client used is not established here, so there is no faithful byte
// count to take instead.
const (
	MinNameLength = 2
	MaxNameLength = 12
)

// ValidName reproduces the engine's check rather than the range it accepts, so
// the two cannot drift.
func ValidName(name string) bool {
	return uint(len(name)-MinNameLength) < uint(MaxNameLength-MinNameLength+1)
}

// ErrInvalidNameLength is the refusal a name outside that range earns.
// GUILDERR_INVALID_GUILDNAME_LEN.
var ErrInvalidNameLength = errors.New("guild: name must be 2 to 12 characters")

// Who may found a guild. **RECOVERED, round 487**, from FUN_00514b20: the
// pre-check CGuildManager::HandleCreateGuild (0x00514ce0) calls first, before
// it reads the name. in_EAX is the founder's GObjPC; the whole ladder, in the
// engine's order:
//
//	if (*(char *)(in_EAX[0xc] + 4) == '\x01') return 0x4c09;   // char lock
//	if ((*in_EAX + 0xf8)() != '\x01')         return 0x4c07;   // GUILDERR_IM_DEAD
//	if ((*in_EAX + 0x124)() < 0x14)           return 0x4c0a;   // GUILDERR_TOO_LOW_CREATOR_LEVEL
//	iVar1 = *(int *)(in_EAX[0xd] + 0x7c);
//	if ((iVar1 < 1) && ((iVar1 < 0 ||
//	    (*(uint *)(in_EAX[0xd] + 0x78) < 500000)))) return 0x4c0c; // GUILDERR_NOT_ENOUGH_GOLD
//	if ((*in_EAX + 0x11c)() != '\x04')        return 0x4c57;   // UIIT_CTL_GUILD_CREATE_JOB_ERROR
//	if (GObjPC::FindTimedJob(2,1) != 0)       return 0x4c3c;   // GUILDWARERR_GUILD_CREATE_PENALTY
//	return (-(uint)(in_EAX[0x72f] != 0) & 0x4c16) + 1;       // 0x4c17 MEMBER_OF_ANOTHER_GUILD, else 1
//
// Vtable +0xf8 is IGObj::GetLifeState, +0x124 IGObj::GetLevel and +0x11c
// IGObj::GetJobState (docs/protocol/igobj_vtable.md); the codes' names are the
// client's (docs/protocol/error_codes.md). CheckCreator is steps 2-4. The last
// step is the stores' ErrAlreadyInGuild. Steps 1, 5 and 6 are not modelled:
// srrevamp's character mutations are synchronous, so there is no lock to hold
// (docs/protocol/char_lock.md, "For srrevamp"), and it has no job state and no
// guild-war penalty timer.
const (
	// MinCreatorLevel is the `bVar3 < 0x14` -> 0x4c0a test: a founder must be
	// level 20 or above.
	MinCreatorLevel = 20

	// CreateGoldRequired is the 500000 FUN_00514b20 compares the founder's
	// 64-bit gold against -- in_EAX[0xd]+0x78 low, +0x7c high, the same +0x34
	// object CGuild::CheckLevelUpCost (0x005c6240) reads a character's gold
	// from -- refusing with 0x4c0c when it is less.
	//
	// It is ALSO WHAT FOUNDING COSTS. The check does not spend it: the create
	// job (FUN_005c5f90 -> SendOlappedGuildJobReqToSM(pc, 0, 0)) goes out, and
	// its reply, case 0 of trs_sm_guildjob::FUN_005c8990, is
	// trs_sm_guildjob::FUN_005c8bf0. That reads the gold at +0x78/+0x7c, calls
	// GObjPC::FUN_004e4140, logs "Gold: %I64d ==> %I64d" under event 0x3d and
	// sends 0xb0f0, the guild-create response. FUN_004e4140 is the deduction,
	// and FUN_005c8bf0 is its only caller:
	//
	//	4e4148  push 0x0
	//	4e414a  push 0x1
	//	4e414c  push 0x4
	//	4e414e  push 0xffffffff        ; high dword
	//	4e4150  push 0xfff85ee0        ; low dword: the int64 is -500000
	//	4e4157  call [vtable+0x16c]    ; IGObj::OffsetGold
	//
	// then IGObj::BackupData(0x80, 0) through +0x274. So the gold is taken
	// after the guild exists, once uniqueness is settled -- the order
	// session.handleGuildCreate keeps.
	//
	// Not to be confused with FUN_005d0e00's 500000, which FUN_005c7900 reads
	// only after refusing a guild below level 4 (0x4c52): a guild service, not
	// creation.
	CreateGoldRequired int64 = 500_000
)

// The three refusals CheckCreator can return, named by the client
// (docs/protocol/error_codes.md).
var (
	// ErrCreatorDead is 0x4c07 UIIT_MSG_GUILDERR_IM_DEAD.
	ErrCreatorDead = errors.New("guild: a dead character cannot found a guild")
	// ErrCreatorLevelTooLow is 0x4c0a UIIT_MSG_GUILDERR_TOO_LOW_CREATOR_LEVEL.
	ErrCreatorLevelTooLow = errors.New("guild: founder is below the minimum level")
	// ErrNotEnoughGold is 0x4c0c UIIT_MSG_GUILDERR_NOT_ENOUGH_GOLD.
	ErrNotEnoughGold = errors.New("guild: not enough gold to found a guild")
)

// CheckCreator is FUN_00514b20's steps 2 to 4, in its order: alive, then level,
// then gold. alive is the caller's reading of IGObj::GetLifeState == 1.
func CheckCreator(alive bool, level int, gold int64) error {
	if !alive {
		return ErrCreatorDead
	}
	if level < MinCreatorLevel {
		return ErrCreatorLevelTooLow
	}
	if gold < CreateGoldRequired {
		return ErrNotEnoughGold
	}
	return nil
}

// MaxLevel is 5, and the check is `cmp al,0x5; jb` in the level-up handler
// (FUN_005c63d0): a guild at level 5 is refused with
// ERROR_GUILD_LEVEL_UP_FULL (0x4c21).
//
// This is an independent confirmation of MaxMembersByLevel having exactly five
// entries -- that table's length came from a bounds assert in a different
// function, and this cap agrees with it.
const MaxLevel = 5

// LevelUpGold is what it costs to advance FROM each level, read from the
// 64-bit table at .rdata 0x00ade918 that FUN_005c6240 indexes as
// `&DAT_00ade910 + level*8`. The high dword is zero for all four, so the values
// fit comfortably in an int64 and the engine's 64-bit compare never needs it.
//
// Index 0 is unused: the function's switch accepts only levels 1 through 4, and
// the dwords that would be index 0 hold 3 and 6, which are not gold.
var LevelUpGold = [MaxLevel]int64{0, 3_000_000, 9_000_000, 15_000_000, 21_000_000}

// LevelUpGuildPoints is the other half of the cost, from the dword table at
// .rdata 0x00ade8f0 indexed as `&DAT_00ade8ec + level*4`.
//
// THIS SETTLES A QUESTION THIS FILE USED TO LEAVE OPEN. The comment on
// MaxMembersByLevel said of the dwords following the capacity table: "The three
// dwords that follow it (5400, 50400, 135000) look like a guild-experience
// curve and are NOT claimed here -- nothing read so far uses them." They are
// the guild-point costs, there are FOUR of them rather than three (378,000 was
// past where that pass looked), and FUN_005c6240 is what uses them.
//
// Declining to claim them was right. A guild-experience curve and a level-up
// cost table are the same numbers in the same place, and only the use-site
// separates them.
var LevelUpGuildPoints = [MaxLevel]int{0, 5_400, 50_400, 135_000, 378_000}

// LevelUpCost returns what advancing from the given level costs. ok is false
// for a level the engine's switch would reject -- anything outside 1..4, which
// includes level 5, the cap.
func LevelUpCost(fromLevel int) (gold int64, guildPoints int, ok bool) {
	if fromLevel < 1 || fromLevel >= MaxLevel {
		return 0, 0, false
	}
	return LevelUpGold[fromLevel], LevelUpGuildPoints[fromLevel], true
}

// ErrNameTaken is returned by Store.Create when the guild name is already
// in use.
var ErrNameTaken = errors.New("guild: name already taken")

// ErrAlreadyInGuild is returned by Store.Create/Join when the character is
// already in a guild (leave it first).
var ErrAlreadyInGuild = errors.New("guild: already in a guild")

// ErrNotInGuild is returned by Store.Leave when the character isn't in any
// guild.
var ErrNotInGuild = errors.New("guild: not in a guild")

// ErrGuildNotFound is returned by Store.Join/Get when guildID doesn't
// exist.
var ErrGuildNotFound = errors.New("guild: no such guild")

// Role distinguishes a guild's leader from its rank-and-file members.
type Role int

const (
	RoleMember Role = 0
	RoleLeader Role = 1
)

// Member is one guild member.
type Member struct {
	CharacterID int64
	Name        string
	Role        Role
}

// Guild is a persistent group of characters, one of whom is the leader.
type Guild struct {
	ID       int64
	Name     string
	LeaderID int64
	Members  []Member
}

// Store persists guilds and their membership.
type Store interface {
	// Create starts a new guild named name with leader as its sole member
	// and leader. Returns ErrAlreadyInGuild, ErrInvalidNameLength or
	// ErrNameTaken as appropriate, checked in that order -- the engine's:
	// CGuildManager::HandleCreateGuild (0x00514ce0) first calls its
	// pre-check FUN_00514b20, whose last test refuses a character already in
	// a guild (pc[0x72f] != 0 -> 0x4c17 GUILDERR_MEMBER_OF_ANOTHER_GUILD),
	// then tests `len - 2u < 0xb` itself (else 0x4c18
	// GUILDERR_INVALID_GUILDNAME_LEN). 0x4c1a GUILDERR_SAME_GUILDNAME_EXIST
	// is raised by no function in the game-server dump, so uniqueness is
	// settled after both, by the job the handler sends on.
	Create(ctx context.Context, name string, leaderID int64, leaderName string) (*Guild, error)

	// Join adds (characterID, characterName) to guildID. Returns
	// ErrGuildNotFound or ErrAlreadyInGuild as appropriate. On success,
	// returns the full guild roster including the new member.
	Join(ctx context.Context, guildID, characterID int64, characterName string) (*Guild, error)

	// Leave removes characterID from its guild. If they were the leader,
	// leadership passes to the longest-standing remaining member. If they
	// were the last member, the guild is disbanded. Returns the guild ID
	// left (for notification even if disbanded) and the guild as it looks
	// after leaving (nil if disbanded).
	Leave(ctx context.Context, characterID int64) (guildID int64, remaining *Guild, err error)

	// GetByCharacter returns the guild characterID currently belongs to,
	// if any.
	GetByCharacter(ctx context.Context, characterID int64) (*Guild, error)

	// Get returns a guild by ID. Returns ErrGuildNotFound if it doesn't
	// exist.
	Get(ctx context.Context, guildID int64) (*Guild, error)
}

// Where guild points come from -- read 2026-09-19 (round 272,
// docs/protocol/guild.md "Where guild points come from"). They are the SKILL
// POINTS a member earns: GObjPC_GainExpAndLevel (0x4e5250), right after it
// converts skill experience into whole points at 400:1 and grants them
// (slot 93), adds the same count to the character's accumulator (pc+0x2184)
// when the character is in a guild, and once the accumulator exceeds 9 hands
// it to CGuildManager::RequestAddGuildPoints (0x5c62e0): a PC in a guild below
// level 6 sends 0x78F7 {guild, member, points} to the global server, which
// answers 0x38F5 and CGuild::AddPoints (0x5c4110) adds the count to the
// guild's total (guild+0x3c) AND to the member's own contribution
// (member+0x40). So a member's guild points are exactly the skill points they
// gain, delivered in batches of at least ten.
const (
	// GuildPointsPerSkillPoint is the 1:1 the accumulator carries over.
	GuildPointsPerSkillPoint = 1
	// PointBatchThreshold is the `9 < acc` test: the batch goes out once the
	// accumulated points reach ten.
	PointBatchThreshold = 10
)

// PointAccumulator is one character's pending guild points -- the engine's
// pc+0x2184. Add books skill points just earned and returns the batch to
// credit, or 0 while the threshold is not yet reached. A character with no
// guild never accumulates: callers only Add while the member is in one.
type PointAccumulator struct{ pending int }

// Add books sp skill points and returns the guild points to credit now.
func (a *PointAccumulator) Add(sp int) int {
	if sp <= 0 {
		return 0
	}
	a.pending += sp * GuildPointsPerSkillPoint
	if a.pending < PointBatchThreshold {
		return 0
	}
	out := a.pending
	a.pending = 0
	return out
}

// Pending is what has accumulated below the threshold.
func (a *PointAccumulator) Pending() int { return a.pending }
