package guild

import (
	"context"
	"encoding/binary"
	"errors"
)

// Round 844 (lane U): the players' own union flow -- the request, the
// answer, leave, expel, the union broken, union chat and the union's crest
// -- as SR_GameServer (s:) and its ShardManager (sm:) do it. READ unless a
// line says otherwise; docs/protocol/guild_union.md has the whole reading.
//
//   - 0x70FB {u32 target uid} (GObjPC_HandleGuildMsg_0fb s:0x5170b0): the
//     target in reach (else 3), then Guild_ValidateAllianceRequest
//     (s:0x5c6550, ValidateUnionRequest below); 1 opens the target's request
//     box -- 0x3080 {6, u32 requester uid} (s:0x5c66dc `mov bl,0x6` into the
//     wait-response maker s:0x4ea0d0) -- and nothing goes to the requester;
//     any other code is 0xB0FB {2, code}.
//   - The answer (trs_wait_response s:0x5c8510 kind 6): either side gone 2;
//     a "no" 0x4c2e to the requester (the client shows nothing for it: its
//     category 0x10 has no row, c:0x7ba32b); a "yes" is the ShardManager's
//     job 0xb (sm:0x438f..: the requester's guild gone 0x4c0d, the target's
//     0x4c25, the target in a union 0x4c28, the target's master 0x4c24, the
//     requester's union full 0x4c29 -- so ALLIANCE_FULL IS raised, by the
//     ShardManager), which forms the union (the requester's guild, then the
//     target's: sm _AllianceCreate, the GS's s:0x5ca5a0 puts the first in
//     slot 0) or adds the target's guild to the requester's. No 0xB0FB on a
//     success (s:0x5c8990 case 0xb does nothing). The wait is 30 s; then
//     0xB0FB {2, 0x4c10} to the requester (s:0x46ce51), which shows nothing.
//   - 0x70FC (no body; s:0x5171d0 -> s:0x5c6710): no guild 0x4c0d, not the
//     master 0x4c1e, no union 0x4c2f; the ShardManager's job 0x10 (sm:0x4391d0)
//     -> 0x38F5 {0x12, 1, u32 guild} to every guild of the union (the leaver's
//     too, s:0x5b8cf0), 0xB0FC {1}; and when the leaver was the union's first
//     guild or fewer than two are left (sm:0x4369f0: `leader == guild ||
//     count < 2` -> 3) the union is broken: 0x38F5 {0x12, 3} to the guilds
//     left (sm:0x43d290 -> s:0x5b8dd0).
//   - 0x70FD {u32 guild id} (s:0x517250 -> s:0x5c67a0): no guild 0x4c0d, not
//     the master 0x4c1e, no union 0x4c2f, not the union's first guild 0x4c1e,
//     the guild not in the union 0x4c30; the ShardManager's job 0x11
//     (sm:0x439350, the guild gone 0x4c25) -> {0x12, 2, u32 guild} to every
//     guild, 0xB0FD {1}, and the union broken as above.
//   - Union chat (GObjPC::FUN_004b1750 case 0xb): no guild 0x200b, no union
//     0x200c, neither the master nor a member with permission bit 0x04
//     (CGuild::HasPermission(4) s:0x5d0f80, `perm & 4 == 4`) 0x200e; else the
//     line goes to every union guild's members (s:0x5c36c0 -> 0x78fe to the
//     ShardManager), and each client drops the copy with its own name
//     (c:0x8780f1).

// The union's opcodes (the client's senders c:0x8201b0 / 0x8202f0 /
// 0x820390, its handlers c:0x881dd0 / 0x881e20 / 0x881e70).
const (
	OpUnionRequest       uint16 = 0x70FB // {u32 target uid}
	OpUnionRequestResult uint16 = 0xB0FB // {2, u16} only: a success has none
	OpUnionLeave         uint16 = 0x70FC // no body
	OpUnionLeaveResult   uint16 = 0xB0FC // {1} | {2, u16}
	OpUnionExpel         uint16 = 0x70FD // {u32 guild id}
	OpUnionExpelResult   uint16 = 0xB0FD // {1} | {2, u16}
	// RequestUnion is 0x3080's kind for a union request (the client's box
	// 0x1d, c:0x88b00d).
	RequestUnion byte = 6
)

// The union refusals not in alliance.go.
const (
	// CodeUnionRefused is the target's "no" (s:0x5c8510); no client text.
	CodeUnionRefused uint16 = 0x4c2e
	// CodeNoUnion is "not in a union" (s:0x5c6710, 0x5c67a0, the crest's
	// s:0x5c7710); no client text in category 0x10.
	CodeNoUnion uint16 = 0x4c2f
	// CodeNotInUnion is the expelled guild not in the expeller's union
	// (s:0x5c67a0, sm:0x439350); no client text either.
	CodeNotInUnion uint16 = 0x4c30
	// CodeHostile is UIIT_MSG_QUESTION_GUILD_RESPECT_ALLY_NOTALLY "Cannot
	// propose an alliance to a hostile guild." (s:0x5c6550's vslot 0x1c test
	// on the target's guild; that the test is hostility is INFERRED from the
	// message).
	CodeHostile uint16 = 0x4c42
	// CodeUnionChatFull (wire_manage.go, 0x4c4b UIIT_MSG_GUILD_UNION_CHAT_FULL):
	// more than UnionChatHolders members of a guild with the union chat
	// permission (s:0x5c49a0's `count < 0xd`, raised by the permission update
	// s:0x5c69f0).
)

// PermUnionChat (manage.go, bit 0x04) is the member permission union chat
// asks for (READ above: HasPermission(4)).

// UnionChatHolders is how many members of one guild may hold PermUnionChat
// (s:0x5c49a0: the set's size must stay under 0xd).
const UnionChatHolders = 12

// UnionRequest is what Guild_ValidateAllianceRequest (s:0x5c6550) reads.
type UnionRequest struct {
	RequesterAlive    bool
	RequesterGuildID  int64
	RequesterIsMaster bool
	// RequesterUnion is the requester's guild's union, nil for none.
	RequesterUnion *Union
	RequesterLevel int
	// TargetFound is the target a live player (s:0x485d90 and its life
	// state).
	TargetFound    bool
	TargetGuildID  int64
	TargetHostile  bool
	TargetLevel    int
	TargetInUnion  bool
	TargetIsMaster bool
}

// ValidateUnionRequest is s:0x5c6550's ladder, in its order: 1 to send the
// request box, else the refusal. A requester in a union must be its first
// guild's master (0x4c1e otherwise): only the union's leader asks more
// guilds in.
func ValidateUnionRequest(r UnionRequest) uint16 {
	switch {
	case !r.RequesterAlive:
		return ErrAllianceImDead
	case r.RequesterGuildID == 0:
		return ErrAllianceNoGuild
	case !r.RequesterIsMaster:
		return ErrAlliancePermissionDenied
	case r.RequesterUnion != nil && r.RequesterUnion.LeaderGuildID() != r.RequesterGuildID:
		return ErrAlliancePermissionDenied
	case r.RequesterLevel < MinLevelForAlliance:
		return ErrAllianceCreatorTooLow
	case !r.TargetFound:
		return CodeNotInRange
	case r.TargetGuildID == 0:
		return ErrAllianceCantFindTargetGuild
	case r.TargetHostile:
		return CodeHostile
	case r.RequesterGuildID == r.TargetGuildID:
		return ErrAllianceCantAllyToOwnGuild
	case r.TargetLevel < MinLevelForAlliance:
		return ErrAllianceJoinerTooLow
	case r.TargetInUnion:
		return ErrAllianceTargetHasAlliance
	case !r.TargetIsMaster:
		return ErrAllianceTargetMasterAbsent
	}
	return 1
}

// UnionBroken says whether a union is broken when guildID leaves (or is
// expelled from) before: sm:0x4369f0 answers 3 when the guild is the union's
// first or fewer than two guilds are left.
func UnionBroken(before *Union, guildID int64) bool {
	if before == nil {
		return false
	}
	if before.LeaderGuildID() == guildID {
		return true
	}
	left := before.Count()
	if before.Has(guildID) {
		left--
	}
	return left < MinUnionGuilds
}

// UnionBreaker dissolves a union outright (its first guild left). MemStore
// and SQLStore implement it.
type UnionBreaker interface {
	// BreakUnion dissolves unionID: every guild leaves it. A union that
	// does not exist is no error.
	BreakUnion(ctx context.Context, unionID int64) error
}

// UnionCrestStore keeps a union's crest (round 844). MemStore and SQLStore
// implement it.
type UnionCrestStore interface {
	// SetUnionCrest stores unionID's crest (CrestBytes palette indices) and
	// returns its new revision (one past its last, as the guild's).
	SetUnionCrest(ctx context.Context, unionID int64, pixels []byte) (uint32, error)
	// ClearUnionCrest deletes it: the revision becomes 0.
	ClearUnionCrest(ctx context.Context, unionID int64) error
	// UnionCrest is unionID's revision and bytes (0, nil for none).
	UnionCrest(ctx context.Context, unionID int64) (uint32, []byte, error)
}

// ErrNoSuchUnion is a union id the store does not have.
var ErrNoSuchUnion = errors.New("guild: no such union")

// EncodeUnionRequestBox is 0x3080 kind 6: {6, u32 requester uid}; the
// client names the guild from the requester's own guild line (c:0x88afd2).
func EncodeUnionRequestBox(requesterUID uint32) []byte {
	return binary.LittleEndian.AppendUint32([]byte{RequestUnion}, requesterUID)
}

// EncodeUnionCrestUpdate is 0x3257 type 2 (the client's c:0x8958e3): {u8 2,
// u32 union id, u8 n, n x str guild name, u32 rev}.
func EncodeUnionCrestUpdate(unionID uint32, guildNames []string, rev uint32) []byte {
	b := binary.LittleEndian.AppendUint32([]byte{2}, unionID)
	b = append(b, byte(min(len(guildNames), 255)))
	for i, n := range guildNames {
		if i == 255 {
			break
		}
		b = appendString(b, n)
	}
	return binary.LittleEndian.AppendUint32(b, rev)
}
