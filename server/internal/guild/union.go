package guild

import (
	"context"
	"encoding/binary"
	"errors"
)

// Unions (round 842): the guilds allied with one another, kept so the
// client can colour a union member's guild line green (docs/protocol/
// guild_plate.md, "Colour"). The record is the original's alliance:
// a fixed array of MaxAllianceGuilds guild ids (alliance.go), slot 0 its
// first guild (READ s:0x5b9260 returns alliance+0x1c, the array's first
// slot; INFERRED the leader), an id and a crest revision.
//
// Round 844: the players' own flow -- 0x70FB..0x70FD, FUN_005c6550's
// ladder, the union broken -- is union844.go and session/unionops.go; the
// GM's /union stays a test tool (OURS).

// Union is one alliance.
type Union struct {
	ID int64
	// CrestRev is the union's crest revision (0 none; OpenSRO has no union
	// crests, round 824).
	CrestRev uint32
	// Slots are the member guilds' ids, 0 for a free slot. A guild keeps
	// its slot; leaving frees it without compacting the array (the
	// original's setter refuses an occupied index, alliance.go).
	Slots [MaxAllianceGuilds]int64
	// crest and crestLast are the MemStore's union crest bytes and last
	// revision (round 844, union844.go).
	crest     []byte
	crestLast uint32
}

// LeaderGuildID is slot 0's guild (INFERRED the union's leader: the first
// guild, the one asked to ally).
func (u *Union) LeaderGuildID() int64 {
	if u == nil {
		return 0
	}
	return u.Slots[0]
}

// GuildIDs are the member guilds in slot order.
func (u *Union) GuildIDs() []int64 {
	if u == nil {
		return nil
	}
	var out []int64
	for _, id := range u.Slots {
		if id != 0 {
			out = append(out, id)
		}
	}
	return out
}

// Has reports whether guildID is one of its guilds.
func (u *Union) Has(guildID int64) bool {
	if u == nil || guildID == 0 {
		return false
	}
	for _, id := range u.Slots {
		if id == guildID {
			return true
		}
	}
	return false
}

// Count is how many guilds it holds (s:0x5b9240: the non-zero slots).
func (u *Union) Count() int { return len(u.GuildIDs()) }

// MinUnionGuilds is the fewest guilds a union stands with. INFERRED: the
// client clears its union when a leave leaves fewer than two
// (c:0x887ecc `cmp eax,0x2; setl` on 0x988a60's count, 0x38F5 type 0x12),
// so OpenSRO dissolves it then.
const MinUnionGuilds = 2

// The union store's refusals (the alliance request's codes, alliance.go).
var (
	ErrNoUnion            = errors.New("guild: not in a union")
	ErrUnionSameGuild     = errors.New("guild: a guild cannot ally with itself")
	ErrUnionAlreadyMember = errors.New("guild: the guild is in a union already")
	ErrUnionFull          = errors.New("guild: the union is full")
)

// UnionCode is err's alliance code (0 for an error that has none).
func UnionCode(err error) int {
	switch {
	case errors.Is(err, ErrUnionSameGuild):
		return ErrAllianceCantAllyToOwnGuild
	case errors.Is(err, ErrUnionAlreadyMember):
		return ErrAllianceTargetHasAlliance
	case errors.Is(err, ErrUnionFull):
		return ErrAllianceFull
	case errors.Is(err, ErrGuildNotFound):
		return ErrAllianceCantFindTargetGuild
	}
	return 0
}

// UnionStore keeps the unions. MemStore and SQLStore implement it.
type UnionStore interface {
	// UnionOf is guildID's union, nil (and no error) when it has none.
	UnionOf(ctx context.Context, guildID int64) (*Union, error)
	// JoinUnion puts guildID into hostGuildID's union, forming one with
	// hostGuildID in slot 0 when the host has none. Refusals: either guild
	// missing (ErrGuildNotFound), the same guild (ErrUnionSameGuild),
	// guildID in a union already (ErrUnionAlreadyMember), the host's union
	// full (ErrUnionFull). Returns the union after.
	JoinUnion(ctx context.Context, guildID, hostGuildID int64) (*Union, error)
	// LeaveUnion takes guildID out of its union (ErrNoUnion without one),
	// freeing its slot; a union left with fewer than MinUnionGuilds guilds is
	// dissolved. Returns the union as it was before and as it is after (nil
	// when dissolved).
	LeaveUnion(ctx context.Context, guildID int64) (before, after *Union, err error)
	// GuildByName is the guild named name, any case (ErrGuildNotFound).
	GuildByName(ctx context.Context, name string) (*Guild, error)
}

// OpUnionInfo is the union record the client keeps (READ: the client's
// 0x3102 handler FUN_0087fd00 -> FUN_0099a810; the server's
// CMainProcess::FUN_005c4550 -> FUN_005b8eb0, broadcast to each member
// guild's members in the world).
const OpUnionInfo uint16 = 0x3102

// 0x38F5's union types (READ, the client's FUN_00887330 switch: the byte
// table at 0x888b00 sends type 0x0d to the case at 0x887ae9 and 0x12 to
// 0x887e3b).
const (
	// UpdateUnionJoined adds a guild to the union: one union entry
	// (FUN_00580650 -> CharacterDependentData::FUN_00999120, then
	// UIIT_MSG_GUILD_ALLY_JOIN_RESULT with its name).
	UpdateUnionJoined = 0x0d
	// UpdateUnionOut takes one out: u8 how (UnionOut*), then u32 the guild
	// for UnionOutLeft and UnionOutExpelled.
	UpdateUnionOut = 0x12
)

// UpdateUnionOut's kinds (READ c:0x887e53 / 0x887f8b / 0x88809f).
const (
	// UnionOutLeft: UIIT_MSG_GUILD_ALLY_EXIT_RESULT "[%s]guild has left the
	// alliance."
	UnionOutLeft = 1
	// UnionOutExpelled: UIIT_MSG_GUILD_RESPECT_ALLY_EXPEL_RESULT.
	UnionOutExpelled = 2
	// UnionOutBroken: UIIT_MSG_QUESTION_GUILD_RESPECT_ALLY_BREAKUP "Guild
	// alliance has been broken.", no body; the union is cleared.
	UnionOutBroken = 3
)

// UnionEntry is one guild as the union record carries it.
type UnionEntry struct {
	GuildID    int64
	Name       string
	Level      int
	MasterName string
	// MasterModel is the u32 after the master's name: the server writes its
	// master object's +0x80 (s:0x5d0bc0 flag 4); INFERRED the master's
	// RefObjID (the union window's race mark), the client keeps it at the
	// entry's +0x40.
	MasterModel uint32
	// Members is the last byte: the server's guild record +0x24
	// (s:0x5d0bc0 flag 8), INFERRED the member count.
	Members int
}

// EntryOf is g's union entry; model answers the master's model.
func EntryOf(g *Guild, model func(characterID int64) uint32) UnionEntry {
	e := UnionEntry{GuildID: g.ID, Name: g.Name, Level: g.Level, Members: len(g.Members)}
	for _, m := range g.Members {
		if m.Role == RoleLeader || m.CharacterID == g.LeaderID {
			e.MasterName = m.Name
			if model != nil {
				e.MasterModel = model(m.CharacterID)
			}
			break
		}
	}
	return e
}

// appendUnionEntry writes one entry (s:0x5d0bc0 with every flag, 0xff at
// s:0x5b8f5e; the client's FUN_0099a810 loop reads the same): u32 guild id,
// str name, u8 level, str master name, u32 master model, u8 members.
func appendUnionEntry(b []byte, e UnionEntry) []byte {
	b = binary.LittleEndian.AppendUint32(b, uint32(e.GuildID))
	b = appendString(b, e.Name)
	b = append(b, byte(min(max(e.Level, 0), 255)))
	b = appendString(b, e.MasterName)
	b = binary.LittleEndian.AppendUint32(b, e.MasterModel)
	return append(b, byte(min(max(e.Members, 0), 255)))
}

// EncodeUnionInfo is 0x3102 (s:0x5b8eb0): u32 the union's id (alliance
// +0x18; the client's CDD+0x248), u32 its crest revision (alliance +0x40,
// the client's +0x244 -- both handed to the crest cache 0x9a4780 as the
// union's id and revision), u32 slot 0's guild (s:0x5b9260; the client's
// +0x240), u8 the count (s:0x5b9240), the entries in slot order. An empty
// union (id 0, no entries) tells the client it has none (OURS: the
// original's client keeps its list then; OpenSRO's clears it).
func EncodeUnionInfo(u *Union, entries []UnionEntry) []byte {
	var id, leader int64
	var crest uint32
	if u != nil {
		id, leader, crest = u.ID, u.LeaderGuildID(), u.CrestRev
	}
	b := binary.LittleEndian.AppendUint32(nil, uint32(id))
	b = binary.LittleEndian.AppendUint32(b, crest)
	b = binary.LittleEndian.AppendUint32(b, uint32(leader))
	b = append(b, byte(len(entries)))
	for _, e := range entries {
		b = appendUnionEntry(b, e)
	}
	return b
}

// EncodeUnionJoined is 0x38F5 type 0x0d: the joining guild's entry.
func EncodeUnionJoined(e UnionEntry) []byte {
	return appendUnionEntry([]byte{UpdateUnionJoined}, e)
}

// EncodeUnionOut is 0x38F5 type 0x12 of kind how about guildID (no guild
// for UnionOutBroken).
func EncodeUnionOut(how byte, guildID int64) []byte {
	b := []byte{UpdateUnionOut, how}
	if how == UnionOutBroken {
		return b
	}
	return binary.LittleEndian.AppendUint32(b, uint32(guildID))
}
