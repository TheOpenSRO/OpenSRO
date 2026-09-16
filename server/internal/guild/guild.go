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

// MaxNameLength caps a guild's name length. Own design choice.
const MaxNameLength = 32

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
	// and leader. Returns ErrNameTaken or ErrAlreadyInGuild as appropriate.
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
