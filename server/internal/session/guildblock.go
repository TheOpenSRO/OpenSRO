package session

import (
	"context"
	"sync/atomic"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/guild"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// The retail guild block (round 821): what the client's guild window, its
// member rows, level, member count, GP and notice are drawn from
// (guild.EncodeBlock, READ CharacterDependentData::FUN_009965e0). The
// original's server sends it at world entry and to a member who joins
// (s:0x5c8d40); OpenSRO does both, and sends it again to every online member
// after a change it has no finer message for yet.

// guildBlockDeps is what a block needs besides the guild: the character store
// (each member's level and model) and the hub (who is online).
type guildBlockDeps struct {
	chars character.Store
	hub   *world.Hub
}

var guildBlockBox atomic.Pointer[guildBlockDeps]

// setGuildBlockDeps names them (GuildHandler); nil chars clears them.
func setGuildBlockDeps(chars character.Store, hub *world.Hub) {
	if chars == nil {
		guildBlockBox.Store(nil)
		return
	}
	guildBlockBox.Store(&guildBlockDeps{chars: chars, hub: hub})
}

// guildBlockPackets is g's block as the three messages, in order.
func guildBlockPackets(ctx context.Context, g *guild.Guild) []*proto.Packet {
	return guildBlockPacketsWith(ctx, g, 0, false)
}

// guildBlockPacketsWith is guildBlockPackets with one member's presence
// given (a character entering or leaving, whose hub entry may not have
// caught up); override 0 gives none.
func guildBlockPacketsWith(ctx context.Context, g *guild.Guild, override int64, online bool) []*proto.Packet {
	d := guildBlockBox.Load()
	live := func(characterID int64) guild.MemberLive {
		var l guild.MemberLive
		if d == nil {
			return l
		}
		if d.chars != nil {
			if c, err := d.chars.GetByID(ctx, characterID); err == nil && c != nil {
				l.Level = uint8(min(max(c.Level, 0), 255))
				l.RefObjID, _ = modelOf(c)
			}
		}
		_, l.Online = reachOf(d.hub, characterID)
		if override != 0 && characterID == override {
			l.Online = online
		}
		return l
	}
	out := []*proto.Packet{{Opcode: guild.OpBlockBegin}}
	// Round 844 part 2: a running master-release vote in the block's tail.
	for _, chunk := range guild.BlockChunks(appendVoteTail(guild.EncodeBlock(g, live), g.ID)) {
		out = append(out, &proto.Packet{Opcode: guild.OpBlockChunk, Data: chunk})
	}
	return append(out, &proto.Packet{Opcode: guild.OpBlockEnd})
}

// sendGuildBlock sends g's block to sess.
func sendGuildBlock(ctx context.Context, sess *gateway.Session, g *guild.Guild) {
	if sess == nil || g == nil {
		return
	}
	for _, p := range guildBlockPackets(ctx, g) {
		_ = sess.Send(p)
	}
	// Round 842: and its union (0x3102), which the client colours union
	// members' guild lines by.
	sendUnionInfo(ctx, sess, g)
	// Round 844 (lane V): and its wars (0x3109), which turn the enemies'
	// lines red.
	sendHostileList(ctx, sess, g)
}

// sendOwnGuildBlock is the world entry's: characterID's guild, if any.
func sendOwnGuildBlock(ctx context.Context, sess *gateway.Session, characterID int64) {
	box := guildPlateStore.Load()
	if box == nil || sess == nil {
		return
	}
	g, err := box.s.GetByCharacter(ctx, characterID)
	if err != nil || g == nil {
		return
	}
	sendGuildBlock(ctx, sess, g)
}

// broadcastGuildBlock sends g's block to every member in the world.
func broadcastGuildBlock(ctx context.Context, g *guild.Guild) {
	d := guildBlockBox.Load()
	if g == nil || d == nil || d.hub == nil {
		return
	}
	pkts := guildBlockPackets(ctx, g)
	for _, m := range g.Members {
		e, ok := reachOf(d.hub, m.CharacterID)
		if !ok || e.Session == nil {
			continue
		}
		for _, p := range pkts {
			_ = e.Session.Send(p)
		}
	}
}

// guildMemberPresence tells characterID's fellow members in the world that
// it came or went: 0x38F5 type 6 with the online bit (READ, the client's
// FUN_005bb1b0: "Guild member [%s] has logged on." / "... logged off.").
func guildMemberPresence(ctx context.Context, characterID int64, online bool) {
	box := guildPlateStore.Load()
	d := guildOps.Load()
	if box == nil || d == nil || d.hub == nil {
		return
	}
	g, err := box.s.GetByCharacter(ctx, characterID)
	if err != nil || g == nil {
		return
	}
	for _, m := range g.Members {
		if m.CharacterID != characterID {
			continue
		}
		live := d.guildLive(ctx, characterID)
		live.Online = online
		if !online {
			// Round 844 part 2: the vote's day counts (_CHAR.LastLogout).
			guildMemberLoggedOut(ctx, box.s, characterID)
		}
		d.toMembers(g, guild.OpUpdate, guild.EncodeMemberFields(guild.MemberFieldOffline|guild.MemberFieldLevel, m, live), characterID)
	}
}

// guildMemberLevelChanged tells characterID's guild in the world its new
// level (round 874): 0x38F5 type 6, field 0x01, to every member in the world,
// the character included. READ: GObjPC_SetLevel (s:0x4e4d90) calls
// FUN_005c3540(guild, name, level) whenever the PC has a guild (+0x72f),
// whichever way the level went. MEASURED on a death that took level 20 to 19:
// 0x38F5 {06, id, 01, 13} to the character itself, 30 ms after the dead
// window. Until this round no level change reached the guild window live.
func guildMemberLevelChanged(characterID int64, _ int) {
	box := guildPlateStore.Load()
	d := guildOps.Load()
	if box == nil || d == nil || d.hub == nil {
		return
	}
	ctx := context.Background()
	g, err := box.s.GetByCharacter(ctx, characterID)
	if err != nil || g == nil {
		return
	}
	for _, m := range g.Members {
		if m.CharacterID != characterID {
			continue
		}
		d.toMembers(g, guild.OpUpdate, guild.EncodeMemberFields(guild.MemberFieldLevel, m, d.guildLive(ctx, characterID)), 0)
		return
	}
}

// guildPointsChanged tells the members in the world a GP credit: the
// guild's GP (0x38F5 type 5, bit 0x08) and the earner's donation (type 6,
// bit 0x08).
func guildPointsChanged(ctx context.Context, g *guild.Guild, earner int64) {
	d := guildOps.Load()
	if d == nil || g == nil {
		return
	}
	d.toMembers(g, guild.OpUpdate, guild.EncodeGuildFields(guild.GuildFieldGP, g), 0)
	for _, m := range g.Members {
		if m.CharacterID == earner {
			d.toMembers(g, guild.OpUpdate, guild.EncodeMemberFields(guild.MemberFieldGP, m, guild.MemberLive{}), 0)
		}
	}
}

// guildLevelChanged tells the members in the world a level-up: 0x38F5 type
// 5 with the level and the GP the level-up spent ("Guild level has been
// increased to %d.", FUN_005b7b80).
func guildLevelChanged(ctx context.Context, g *guild.Guild) {
	d := guildOps.Load()
	if d == nil || g == nil {
		return
	}
	d.toMembers(g, guild.OpUpdate, guild.EncodeGuildFields(guild.GuildFieldLevel|guild.GuildFieldGP, g), 0)
}
