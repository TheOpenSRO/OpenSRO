package guild

// Guild alliances -- the game calls them unions. RECOVERED 2026-09-17, from
// FUN_005c6550 (the request validator) and the three functions that maintain
// the member array. Nothing in OpenSRO forms an alliance yet; this is the rule
// set it would have to implement, and the cap below settles a claim this
// project has carried unverified for a long time.
//
// HOW IT WAS FOUND. docs/protocol/guild.md listed FUN_005c6550 under "What is
// not recovered". It surfaced as one of the 62 single-vocabulary functions the
// widened error-code scan located (client/tools/re/errsites.py) -- every code it
// raises is a GUILDERR_, and the names tell you what each branch is.

// MaxAllianceGuilds is how many guilds one alliance holds.
//
// **This CONFIRMS a long-standing note.** docs/protocol/guild.md recorded
// "Unions holding eight guilds is a long-standing note in this project that no
// read has confirmed." It is now read, four ways, and none of them is a curve:
//
//  1. The slot setter (CMainProcess::FUN_005b8c70) asserts the index:
//     `if (7 < index) Assert_BreakIfDebugger();` before writing
//     `alliance[+0x1c + index*4]`.
//  2. The slot clearer (FUN_005b8cf0) carries the same assert.
//  3. That same function's loop runs `local_9 = 0 .. 7` inclusive, exiting on
//     `if (7 < local_9) return 1` -- a traversal, not just a guard.
//  4. The membership scan (FUN_005b8e90) is a literal `do { ... } while (i < 8)`
//     over the same array.
//
// So the alliance record holds a fixed array of EIGHT guild ids at `+0x1c`, and
// 2 and 4 are bounds the code actually walks rather than defensive asserts. The
// `7 < index` form is the engine's usual `limit-1 < value` idiom.
//
// It is a fixed array, not a list: the setter refuses an occupied index with
// its own log line -- "Anohter Alliance guild is set in that index!!", the
// engine's typo -- so a guild occupies a SLOT, and leaving one frees that slot
// rather than compacting the array.
const MaxAllianceGuilds = 8

// MinLevelForAlliance is the guild level both sides need.
//
// FUN_005c6550 checks it twice against two different guilds, and the client's
// names for the two refusals are what make the reading safe rather than
// symmetric guesswork: the requester's failure is
// GUILDERR_TOO_LOW_CREATOR_ALLIANCE (0x4c2a) and the target's is
// GUILDERR_TOO_LOW_JOINER_ALLIANCE (0x4c2b). Each name matches the object its
// GetLevel() was called on.
const MinLevelForAlliance = 2

// The alliance refusal codes, from docs/protocol/error_codes.md, with the
// branch each one guards in FUN_005c6550.
const (
	// ErrAllianceImDead is raised when GetLifeState() != 1.
	ErrAllianceImDead = 0x4c07
	// ErrAllianceNoGuild is raised when the requester has no guild.
	ErrAllianceNoGuild = 0x4c0d
	// ErrAlliancePermissionDenied is raised when the requester is not the
	// guild master -- and again on a second, separate check further down.
	ErrAlliancePermissionDenied = 0x4c1e
	// ErrAllianceTargetMasterAbsent is raised when the TARGET guild's master
	// is not the character being asked.
	ErrAllianceTargetMasterAbsent = 0x4c24
	// ErrAllianceCantFindTargetGuild is raised when the target has no guild.
	ErrAllianceCantFindTargetGuild = 0x4c25
	// ErrAllianceCantAllyToOwnGuild is raised when both ids are the same guild.
	ErrAllianceCantAllyToOwnGuild = 0x4c26
	// ErrAllianceAlreadyAllied and ErrAllianceFull are in the client's message
	// table but are NOT raised anywhere in SR_GameServer.exe -- see
	// docs/protocol/guild.md. They are listed so the vocabulary is complete and
	// so nobody re-derives their absence.
	ErrAllianceAlreadyAllied = 0x4c27
	ErrAllianceFull          = 0x4c29
	// ErrAllianceTargetHasAlliance is raised when the target guild already
	// belongs to one.
	ErrAllianceTargetHasAlliance = 0x4c28
	// ErrAllianceCreatorTooLow / ErrAllianceJoinerTooLow are the two level
	// checks -- see MinLevelForAlliance.
	ErrAllianceCreatorTooLow = 0x4c2a
	ErrAllianceJoinerTooLow  = 0x4c2b
)

// CanRequestAlliance reproduces FUN_005c6550's ladder for the part of it this
// project can express: OpenSRO has no life state, no permission enforcement
// and no pending-request flow, so the checks that survive are the two guild
// levels, the same-guild test and the target's existing alliance.
//
// It returns 0 to allow. The order is the engine's, because a validator that
// returns the right SET of refusals in the wrong order still shows the player
// the wrong message.
func CanRequestAlliance(requesterGuildID, targetGuildID int64, requesterLevel, targetLevel int, targetAllied bool) int {
	if requesterGuildID == 0 {
		return ErrAllianceNoGuild
	}
	if requesterLevel < MinLevelForAlliance {
		return ErrAllianceCreatorTooLow
	}
	if targetGuildID == 0 {
		return ErrAllianceCantFindTargetGuild
	}
	if requesterGuildID == targetGuildID {
		return ErrAllianceCantAllyToOwnGuild
	}
	if targetLevel < MinLevelForAlliance {
		return ErrAllianceJoinerTooLow
	}
	if targetAllied {
		return ErrAllianceTargetHasAlliance
	}
	return 0
}
