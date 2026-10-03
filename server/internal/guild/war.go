package guild

// Guild war. RECOVERED 2026-09-17 from FUN_005c6b60 (1,102 bytes), the
// declaration handler, which docs/protocol/guild.md listed under "What is not
// recovered". Nothing in OpenSRO declares a war yet; this is the rule set it
// would need.
//
// Located the same way the alliance rules were: every code the function raises
// belongs to one vocabulary, which is what made it one of the 62 unambiguous
// candidates the widened error-code scan produced.

// MaxHostileGuilds is how many guilds one guild may be at war with.
//
// **READ FROM THE DISASSEMBLY, NOT THE DECOMPILER**, and the difference is the
// value itself. Ghidra renders the check as
//
//	if (0x31 < (byte)guild[0x11]) return 0x4c3e;
//
// which reads as a cap of 49. The instructions say otherwise:
//
//	005c6ddd  mov eax,DWORD PTR [esi+0x44]
//	005c6de0  cmp al,0x32                  ; 50
//	005c6de2  jb  0x5c6dfe                 ; proceed only while count < 50
//	005c6df5  mov ax,0x4c3e                ; GUILDWARERR_MAX_HOSTILE_GUILD
//
// so a guild may declare while it holds FEWER than 50 wars, and 50 is the cap.
// `0x31 <` is Ghidra's rewriting of `< 0x32`; the engine's own constant is 50.
// This is the second time a `limit-1 < value` shape has had to be read in
// assembly to get the limit right -- see MaxAllianceGuilds, where the same
// idiom appears as `7 < index` for an array of 8.
//
// The check is applied to BOTH guilds, at the same offset, with two different
// refusals -- GUILDWARERR_MAX_HOSTILE_GUILD (0x4c3e) for the declarer and
// GUILDWARERR_TARGET_MAX_HOSTILE_GUILD (0x4c3f) for the target -- which is the
// same construction the alliance level check uses, and the same reason it is
// safe to read: the client's names say which side each comparison is about.
const MaxHostileGuilds = 50

// The hostile-guild count lives at `guild + 0x44` as a BYTE. Two refusals name
// it, and neither is consistent with the field being a state enum:
//
//	FUN_005c6b60  count >= 50  -> GUILDWARERR_MAX_HOSTILE_GUILD
//	FUN_005c6870  count != 0   -> GUILD_ERROR_BREAK_WAR (0x4c46)
//
// A state would not be compared against 50, and a flag would not need a byte.
// **No writer was found**: every access to that offset inside the guild module
// is a comparison, so the count is maintained somewhere this pass did not
// reach -- most likely from the `_GUILDWAR` rows on load. That is a gap in the
// reading, stated rather than papered over.

// The guild-war refusal codes, with the branch each guards in FUN_005c6b60.
const (
	// ErrWarCantFindTargetGuild -- the target resolves to no guild.
	ErrWarCantFindTargetGuild = 0x4c25
	// ErrWarPermissionDenied -- the declarer is not the guild master.
	ErrWarPermissionDenied = 0x4c1e
	// ErrWarEnemyGuild -- already at war with this guild.
	ErrWarEnemyGuild = 0x4c3a
	// ErrWarMaxHostileGuild / ErrWarTargetMaxHostileGuild -- see
	// MaxHostileGuilds.
	ErrWarMaxHostileGuild       = 0x4c3e
	ErrWarTargetMaxHostileGuild = 0x4c3f
	// ErrWarAllyGuild -- the two guilds share an alliance.
	ErrWarAllyGuild = 0x4c41
	// ErrWarTooFar -- ERR_COMMON_TOO_FAR. A war is declared in person, and
	// there is a range limit; its VALUE is not recovered, the distance being
	// computed by a helper rather than compared against a literal.
	ErrWarTooFar = 0x4c60
	// ErrWarInBattleArena -- declaring is refused inside the battle arena.
	ErrWarInBattleArena = 0x4c7a
	// ErrWarBreakWar is not raised by the declaration handler. FUN_005c6870
	// raises it when the guild's hostile count is non-zero, i.e. an operation
	// that a standing war blocks.
	ErrWarBreakWar = 0x4c46
)

// CanDeclareWar reproduces FUN_005c6b60's ladder for the part OpenSRO can
// express. It has no distance, no guild-master enforcement and no arena, so
// what survives is the target's existence, the two caps and the two
// exclusions -- in the engine's order, because a validator returning the right
// set of refusals in the wrong order shows the player the wrong message.
//
// Returns 0 to allow.
func CanDeclareWar(declarerHostiles, targetHostiles int, targetGuildID int64, alreadyAtWar, sameAlliance bool) int {
	if targetGuildID == 0 {
		return ErrWarCantFindTargetGuild
	}
	if declarerHostiles >= MaxHostileGuilds {
		return ErrWarMaxHostileGuild
	}
	if targetHostiles >= MaxHostileGuilds {
		return ErrWarTargetMaxHostileGuild
	}
	if alreadyAtWar {
		return ErrWarEnemyGuild
	}
	if sameAlliance {
		return ErrWarAllyGuild
	}
	return 0
}

// A war is a wagered, timed contest, not a flag. Its record's columns are in
// docs/protocol/db_columns.md, bound by DB_Bind__GUILDWAR (0x0084dd90):
//
//	WarType  VictoryPointIndex  LodgedGold  WarEndTime  Guild x2
//	PointGain x2  Data1  Data2
//
// so a war has a TYPE, a victory-point index, **staked gold**, an end time, the
// two guilds and a per-side point total. OpenSRO models none of this; it is
// recorded because the shape rules out the simplest reading -- a war is not a
// boolean between two guilds, and any implementation that starts there will
// have to be undone.
