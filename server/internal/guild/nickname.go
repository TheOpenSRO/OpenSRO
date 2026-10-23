package guild

import "errors"

// A member's grant name (round 814) -- the "nickname" the original shows on a
// character's guild line, `[Guild * Grant]` (docs/protocol/guild_plate.md),
// and stores in _GUILDMEMBER.Nickname (docs/protocol/db_columns.md, member
// record +0x64). READ: the game server's request 0x7256
// (GObjPC_HandleGuildMsg_256 0x517b70: u32 target character id, then the
// name) validated by FUN_005c7560 in this order -- in a guild (else 0x4c0d),
// the guild's level at least 4 (else 0x4c51; dropped, round 815), the guild master (else 0x4c1e
// PERMISSION_DENIED), the name's byte length under 13 and the name filter
// FUN_004184a0 (else 0x4c4d GUILD_ERROR_NAME_GRANT_SPECIAL_LETTER) -- then
// ShardManager job 0x25.
//
// OURS (the user, round 814: "let me set my grant name instead of the guild
// leader, that's an old feature we don't want"): a member sets only their own
// grant name; the master's grant over others is gone. The third test is
// therefore "the target is the sender" (refused with the same 0x4c1e).
// Everything else is the original's, in its order. An empty name clears it
// (OURS: the original's handler takes any length under 13, 0 included,
// INFERRED to clear).

// MaxNicknameBytes is the longest grant name: `*(uint *)(name + 0x14) < 0xd`
// (FUN_005c7560, READ), the narrow string's byte count. The client's input box
// takes 12 too (FUN_00641f40 case 3, FUN_00634f80(0xc), READ).
const MaxNicknameBytes = 12

// The guild level gate (READ: FUN_005c7560's `GetLevel() < 4` -> 0x4c51) is
// gone: the user (round 815) -- "Grant name can now be any guild level" --
// OURS. A grant name is open to a guild of any level.

// The grant-name refusals besides ErrNotInGuild (0x4c0d); NicknameCode gives
// each one's engine code.
var (
	// ErrNicknameNotSelf is 0x4c1e UIIT_MSG_GUILDERR_PERMISSION_DENIED: the
	// original's master test, here "only your own" (OURS).
	ErrNicknameNotSelf = errors.New("guild: a member can only set their own grant name")
	// ErrNicknameInvalid is 0x4c4d UIIT_MSG_GUILD_ERROR_NAME_GRANT_SPECIAL_LETTER:
	// too long, or refused by the name filter.
	ErrNicknameInvalid = errors.New("guild: that grant name is not allowed")
)

// CheckNickname is FUN_005c7560's ladder with OpenSRO's self-only rule:
// inGuild (the guild's level no longer matters, round 815), actor == target, then the name (its byte length,
// then allowed -- the name filter; nil allows every name). A nil error means
// the name may be stored.
func CheckNickname(inGuild bool, level int, actorID, targetID int64, nickname string, allowed func(string) bool) error {
	if !inGuild {
		return ErrNotInGuild
	}
	if actorID != targetID {
		return ErrNicknameNotSelf
	}
	if len(nickname) > MaxNicknameBytes {
		return ErrNicknameInvalid
	}
	if nickname != "" && allowed != nil && !allowed(nickname) {
		return ErrNicknameInvalid
	}
	return nil
}

// NicknameCode is the engine's code for a grant-name refusal, or 0 for an
// error that is OpenSRO's own (a database failure).
func NicknameCode(err error) int {
	switch {
	case errors.Is(err, ErrNotInGuild):
		return 0x4c0d
	case errors.Is(err, ErrNicknameNotSelf):
		return 0x4c1e
	case errors.Is(err, ErrNicknameInvalid):
		return 0x4c4d
	}
	return 0
}
