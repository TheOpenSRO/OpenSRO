// Package arena holds the battle-arena structure recovered from
// SR_GameServer.exe.
//
// OpenSRO has no arena. What this package records is the SHAPE of the system --
// its modes, its scoring kinds and its currency -- which is what the class
// family and the vtable index give up without reading the match logic.
//
// See docs/protocol/battle_arena.md.
package arena

// Mode is one of the four ways a match is entered. Each has a paired
// "Participation" class, and both halves of every pair carry the same 11-slot
// vtable, so the pairing is structural rather than inferred from the names.
type Mode string

const (
	ModeRandom Mode = "Random"
	ModeParty  Mode = "Party"
	ModeGuild  Mode = "Guild"
	ModeJob    Mode = "Job"
)

// Modes are the four, with the vtable of each half of the pair.
var Modes = []struct {
	Mode        Mode
	MatchVTable uint32
	EntryVTable uint32
}{
	{ModeRandom, 0x00b075e8, 0x00b075b8},
	{ModeParty, 0x00b07648, 0x00b07618},
	{ModeGuild, 0x00b076a8, 0x00b07678},
	{ModeJob, 0x00b07708, 0x00b076d8},
}

// Scoring is how a match is won. Three classes derive from CBattleArenaInfo,
// which is a ten-slot base of which three slots the derived classes override.
type Scoring string

const (
	// ScoringOccupy is CBattleArenaInfoOccupy -- holding ground.
	ScoringOccupy Scoring = "Occupy"
	// ScoringPoint is CBattleArenaInfoPoint -- accumulated points.
	ScoringPoint Scoring = "Point"
	// ScoringFlag is CBattleArenaInfoFlag -- a flag objective. It is the only
	// one of the three to override slot 5, and the function there carries its
	// name, so the flag mode has behaviour the other two do not.
	ScoringFlag Scoring = "Flag"
)

// Scorings are the three, with their vtables.
var Scorings = map[Scoring]uint32{
	ScoringOccupy: 0x00b058c4,
	ScoringPoint:  0x00b058f0,
	ScoringFlag:   0x00b0591c,
}

// The refusal codes.
const (
	// ErrNotEnoughArenaCoin is UIIT_MGS_ARENA_NOT_ENOUGH_COIN.
	ErrNotEnoughArenaCoin = 0x184d
	// ErrNotEnoughCoin is the neighbouring STRGERR_NOT_ENOUGH_COIN, raised by
	// the same function for a different currency kind.
	ErrNotEnoughCoin = 0x184a
	// ErrCantPartyWithOpponent is
	// UIIT_MGS_ARENA_ERR_CANT_PARTY_WITH_OPPONENT_*, raised from the PARTY
	// system rather than this one -- CParty::CheckCanCreateForMatch refuses to
	// form a party with someone you are matched against.
	ErrCantPartyWithOpponent = 0x2c28
)

// ArenaCoinItemKind is 10. GObjPC::FUN_00617360 checks currency requirements by
// bit, and the arena's branch is:
//
//	if ((flags & 0x400) != 0) {
//	    if (!FindItems(inv, 10, 1)) return 0x184d;
//	    total = sum of `+8` over the matching slots;
//	    if (total < requirement[0x14]) return 0x184d;
//	}
//
// so **arena coins are ordinary inventory items of kind 10**, counted by
// summing a per-slot quantity, not a scalar on the character. The neighbouring
// branch, bit `0x200`, does the same for kind 9 and refuses with 0x184a.
const (
	ArenaCoinItemKind = 10
	ArenaCoinFlagBit  = 0x400
	OtherCoinItemKind = 9
	OtherCoinFlagBit  = 0x200
)

// WorldClass is the arena's own game world. Like the siege war, a match runs in
// a separate CGameWorld rather than in the open world.
const (
	WorldClass        = "CGameWorld_BattleArena"
	WorldVTable       = 0x00aff6f4
	WorldSlots        = 55
	ContextController = "CBattleArenaContextController"
)
