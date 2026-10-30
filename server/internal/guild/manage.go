package guild

import (
	"context"
	"errors"
)

// Round 844: the guild window's and the guild manager's own changes -- the
// notice, the members' permission bits and the master's hand-over -- as the
// original's GameServer makes them (docs/protocol/guild_census.md, lane G).
// A store that keeps them implements ManageStore; the session layer asks for
// it with a type assertion, as it does for UnionStore, so the four guild
// lanes of round 844 do not all grow the one Store interface.

// ManageStore is the stores' side of the notice, the permissions and the
// hand-over. Each returns the guild as it is after the change.
type ManageStore interface {
	// SetNotice stores guildID's notice (title and body as given; the
	// caller has checked them).
	SetNotice(ctx context.Context, guildID int64, title, body string) (*Guild, error)
	// SetPermissions sets each listed member's permission mask. A member
	// not in guildID is refused with ErrNotInGuild and the master with
	// ErrIsMaster; nothing changes unless every change applies.
	SetPermissions(ctx context.Context, guildID int64, changes []PermissionChange) (*Guild, error)
	// TransferMaster makes toID guildID's master: toID takes RoleLeader,
	// PermAll and SiegeCommander, the old master RoleMember,
	// MasterHandOverPermission and SiegeNone.
	// ErrNotInGuild when toID is not a member, ErrIsMaster when toID is the
	// master already.
	TransferMaster(ctx context.Context, guildID, toID int64) (*Guild, error)
}

// PermissionChange is one row of 0x7104: a member and the mask it gets.
type PermissionChange struct {
	CharacterID int64
	Permission  Permission
}

// PermUnionChat is bit 0x04: the union chat (round 844, READ c:0x5abf90 counts
// the members holding it for the permission pane's union column tooltip,
// UIIT_MSG_GUILD_UNION_CHAT_TOOLTIP; the pane's third check, header
// UIIT_STT_GUILD_RESPECT_ALLY).
const PermUnionChat Permission = 1 << 2

// MasterHandOverPermission is the mask the old master keeps after a
// hand-over: 0 (READ s:0x5c46e0, the hand-over notification: the new master
// class 0, mask 0xffffffff, siege role 1; the old one class 10, mask 0, role
// 0).
const MasterHandOverPermission Permission = 0

// The siege roles a hand-over writes (s:0x5c46e0, READ): the new master
// becomes the commander (UIIT_STT_FORT_GUILD_COMMANDER), the old one none.
const (
	SiegeCommander uint8 = 1
	SiegeNone      uint8 = 0
)

// CheckNotice is the GameServer's length test (s:0x5c6480, READ): the title
// 1..NoticeTitleMaxBytes bytes else 0x4c22 (ErrNoticeTitle), the body
// 1..NoticeBodyMaxBytes else 0x4c23 (ErrNoticeBody). The write window
// refuses an empty one itself (c:0x70b7b0) and caps the edits at 0x7f and
// 0x3ff characters (c:0x70bbe8 / 0x70bbf5).
func CheckNotice(title, body string) error {
	if len(title) == 0 || len(title) > NoticeTitleMaxBytes {
		return ErrNoticeTitle
	}
	if len(body) == 0 || len(body) > NoticeBodyMaxBytes {
		return ErrNoticeBody
	}
	return nil
}

// ErrNoticeTitle and ErrNoticeBody are 0x4c22
// GUILDERR_INVALID_MASTER_COMMENT_TITLE and 0x4c23
// GUILDERR_INVALID_MASTER_COMMENT.
var (
	ErrNoticeTitle = errors.New("guild: the notice's title must be 1 to 128 bytes")
	ErrNoticeBody  = errors.New("guild: the notice's body must be 1 to 2048 bytes")
)
