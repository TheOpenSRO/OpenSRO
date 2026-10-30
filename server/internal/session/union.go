package session

import (
	"context"
	"errors"
	"fmt"
	"log/slog"

	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/guild"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
)

// Round 842: unions as the client needs them to colour a union member's
// guild line (docs/protocol/guild_plate.md, "Colour"). The client keeps the
// union's guilds (READ: CharacterDependentData+0x148's map at +0x94, which
// FUN_00996d60 tests a guild name against for the green 0xffa0fe68) from
// 0x3102 and 0x38F5 types 0x0d / 0x12, and recolours every guild line after
// each (FUN_009a4450). The server sends:
//   - 0x3102 with the guild block (world entry, a join to the guild), and to
//     every member guild's members in the world when a guild joins
//     (s:0x5c4550 broadcasts it to a guild's local members);
//   - 0x38F5 type 0x0d (a guild joined) to the members of the guilds that
//     were in it, type 0x12 (left) to every member of the union as it was;
//   - each member's 0x30FF again (its union id), through refreshGuildPlate.
// OURS: the union is formed and left only through the GM's /union (a test
// tool, UnionCommands); the original's request flow is OPEN.

// unionStore is the plate store as a guild.UnionStore, nil when it keeps
// none.
func unionStore() guild.UnionStore {
	box := guildPlateStore.Load()
	if box == nil {
		return nil
	}
	us, _ := box.s.(guild.UnionStore)
	return us
}

// unionOfGuild is guildID's union, nil for none (or a store error, logged).
func unionOfGuild(ctx context.Context, guildID int64) *guild.Union {
	us := unionStore()
	if us == nil || guildID == 0 {
		return nil
	}
	u, err := us.UnionOf(ctx, guildID)
	if err != nil {
		slog.Warn("union lookup failed", "guild_id", guildID, "err", err)
		return nil
	}
	return u
}

// unionEntries are u's guilds as 0x3102 carries them, in slot order (a
// guild the store no longer has is left out).
func unionEntries(ctx context.Context, u *guild.Union) []guild.UnionEntry {
	box := guildPlateStore.Load()
	if u == nil || box == nil {
		return nil
	}
	var out []guild.UnionEntry
	for _, id := range u.GuildIDs() {
		g, err := box.s.Get(ctx, id)
		if err != nil || g == nil {
			continue
		}
		out = append(out, guild.EntryOf(g, func(characterID int64) uint32 { return masterModel(ctx, characterID) }))
	}
	return out
}

// masterModel is characterID's RefObjID (0 unknown).
func masterModel(ctx context.Context, characterID int64) uint32 {
	d := guildBlockBox.Load()
	if d == nil || d.chars == nil {
		return 0
	}
	c, err := d.chars.GetByID(ctx, characterID)
	if err != nil || c == nil {
		return 0
	}
	ref, _ := modelOf(c)
	return ref
}

// unionInfoPacket is g's union as 0x3102, nil when g has none.
func unionInfoPacket(ctx context.Context, g *guild.Guild) *proto.Packet {
	if g == nil {
		return nil
	}
	u := unionOfGuild(ctx, g.ID)
	if u == nil {
		return nil
	}
	return &proto.Packet{Opcode: guild.OpUnionInfo, Data: guild.EncodeUnionInfo(u, unionEntries(ctx, u))}
}

// sendUnionInfo sends g's union to sess (nothing without one).
func sendUnionInfo(ctx context.Context, sess *gateway.Session, g *guild.Guild) {
	if sess == nil {
		return
	}
	if p := unionInfoPacket(ctx, g); p != nil {
		_ = sess.Send(p)
	}
}

// unionGuilds are ids' guilds as the store has them now.
func unionGuilds(ctx context.Context, ids []int64) []*guild.Guild {
	box := guildPlateStore.Load()
	if box == nil {
		return nil
	}
	var out []*guild.Guild
	for _, id := range ids {
		if g, err := box.s.Get(ctx, id); err == nil && g != nil {
			out = append(out, g)
		}
	}
	return out
}

// toGuildMembers sends one message to every member in the world of each guild.
func toGuildMembers(gs []*guild.Guild, op uint16, data []byte) {
	d := guildBlockBox.Load()
	if d == nil || d.hub == nil {
		return
	}
	for _, g := range gs {
		for _, m := range g.Members {
			if e, ok := entityOf(d.hub, m.CharacterID); ok {
				sendGuild(e.Session, op, data)
			}
		}
	}
}

// refreshUnionPlates re-files every member's guild line of gs (their union
// id), telling their viewers when it changed.
func refreshUnionPlates(gs []*guild.Guild) {
	d := guildBlockBox.Load()
	if d == nil {
		return
	}
	for _, g := range gs {
		for _, m := range g.Members {
			refreshGuildPlate(d.hub, m.CharacterID, g)
		}
	}
}

// unionJoined tells everyone that guildID joined u (u as it is after): the
// guilds already in it 0x38F5 type 0x0d with the joiner's entry, the
// joiner's members the whole union (0x3102), every member's line again.
func unionJoined(ctx context.Context, u *guild.Union, guildID int64) {
	all := unionGuilds(ctx, u.GuildIDs())
	var joiner *guild.Guild
	var others []*guild.Guild
	for _, g := range all {
		if g.ID == guildID {
			joiner = g
		} else {
			others = append(others, g)
		}
	}
	if joiner == nil {
		return
	}
	entry := guild.EntryOf(joiner, func(id int64) uint32 { return masterModel(ctx, id) })
	if u.Count() == guild.MinUnionGuilds {
		// A union just formed: its first guild has no union to add to yet
		// (the client asserts !IsAllianceGuild before an add, c:0x999120),
		// so both sides get the whole record.
		toGuildMembers(all, guild.OpUnionInfo, guild.EncodeUnionInfo(u, unionEntries(ctx, u)))
	} else {
		toGuildMembers(others, guild.OpUpdate, guild.EncodeUnionJoined(entry))
		toGuildMembers([]*guild.Guild{joiner}, guild.OpUnionInfo, guild.EncodeUnionInfo(u, unionEntries(ctx, u)))
	}
	refreshUnionPlates(all)
}

// unionLeft tells everyone that guildID left `before` (how: UnionOutLeft or
// UnionOutExpelled): 0x38F5 type 0x12 to every member of the union as it
// was -- the leaver's client clears its union (the guild is its own), and a
// union left under two guilds is cleared by every client (c:0x887ecc) --
// and every member's line again. gone is the guild itself when it no longer
// exists (a disband), whose members are told nothing more.
func unionLeft(ctx context.Context, before *guild.Union, guildID int64, how byte, gone *guild.Guild) {
	// Round 844: and the union broken when its first guild went or fewer
	// than two are left (unionops.go).
	unionOut(ctx, before, guildID, how, gone, nil)
}

// unionBeforeDisband is guildID's union read before the guild goes (the
// store frees the slot itself), for unionLeft after.
func unionBeforeDisband(ctx context.Context, guildID int64) *guild.Union {
	return unionOfGuild(ctx, guildID)
}

// UnionCommands is the GM's /union (round 842, OURS, a test tool: the
// original's union request flow is not built). It runs on the plate store.
type UnionCommands struct{}

// Join puts the GM's guild into the union of the guild named host (forming
// one when that guild has none).
func (UnionCommands) Join(ctx context.Context, characterID int64, host string) (string, error) {
	box := guildPlateStore.Load()
	us := unionStore()
	if box == nil || us == nil {
		return "", errors.New("no union store")
	}
	mine, err := box.s.GetByCharacter(ctx, characterID)
	if err != nil {
		return "", errors.New("you are not in a guild")
	}
	h := guildByName(ctx, host)
	if h == nil {
		return "", fmt.Errorf("no guild named %s", host)
	}
	u, err := us.JoinUnion(ctx, mine.ID, h.ID)
	if err != nil {
		return "", fmt.Errorf("the union refused it (0x%x): %w", guild.UnionCode(err), err)
	}
	unionJoined(ctx, u, mine.ID)
	return fmt.Sprintf("%s joined union %d (%d guilds)", mine.Name, u.ID, u.Count()), nil
}

// Leave takes the GM's guild out of its union (UnionOutLeft), or, with
// expel, the named guild out of the GM's (UnionOutExpelled).
func (UnionCommands) Leave(ctx context.Context, characterID int64, expel string) (string, error) {
	box := guildPlateStore.Load()
	us := unionStore()
	if box == nil || us == nil {
		return "", errors.New("no union store")
	}
	mine, err := box.s.GetByCharacter(ctx, characterID)
	if err != nil {
		return "", errors.New("you are not in a guild")
	}
	target, how := mine, byte(guild.UnionOutLeft)
	if expel != "" {
		target = guildByName(ctx, expel)
		if target == nil {
			return "", fmt.Errorf("no guild named %s", expel)
		}
		if u := unionOfGuild(ctx, mine.ID); u == nil || !u.Has(target.ID) {
			return "", fmt.Errorf("%s is not in your union", expel)
		}
		how = guild.UnionOutExpelled
	}
	before, after, err := us.LeaveUnion(ctx, target.ID)
	if err != nil {
		return "", err
	}
	unionLeft(ctx, before, target.ID, how, nil)
	if after == nil {
		return fmt.Sprintf("%s left union %d, which is dissolved", target.Name, before.ID), nil
	}
	return fmt.Sprintf("%s left union %d (%d guilds left)", target.Name, before.ID, after.Count()), nil
}

// guildByName is the guild named name (any case), nil when none.
func guildByName(ctx context.Context, name string) *guild.Guild {
	us := unionStore()
	if us == nil {
		return nil
	}
	g, err := us.GuildByName(ctx, name)
	if err != nil {
		return nil
	}
	return g
}
