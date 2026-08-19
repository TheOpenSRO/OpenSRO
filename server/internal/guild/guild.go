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
