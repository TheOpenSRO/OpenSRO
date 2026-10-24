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
		_, l.Online = entityOf(d.hub, characterID)
		if override != 0 && characterID == override {
			l.Online = online
		}
		return l
	}
	out := []*proto.Packet{{Opcode: guild.OpBlockBegin}}
	for _, chunk := range guild.BlockChunks(guild.EncodeBlock(g, live)) {
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
		e, ok := entityOf(d.hub, m.CharacterID)
		if !ok || e.Session == nil {
			continue
		}
		for _, p := range pkts {
			_ = e.Session.Send(p)
		}
	}
}

// guildMemberPresence tells characterID's fellow members in the world that
// it came or went: the original's member update (0x38F5, its online bit),
// sent here as the whole block again until that message is built (OURS,
// round 821).
func guildMemberPresence(ctx context.Context, characterID int64, online bool) {
	box := guildPlateStore.Load()
	d := guildBlockBox.Load()
	if box == nil || d == nil || d.hub == nil {
		return
	}
	g, err := box.s.GetByCharacter(ctx, characterID)
	if err != nil || g == nil {
		return
	}
	var pkts []*proto.Packet
	for _, m := range g.Members {
		if m.CharacterID == characterID {
			continue
		}
		e, ok := entityOf(d.hub, m.CharacterID)
		if !ok || e.Session == nil {
			continue
		}
		if pkts == nil {
			pkts = guildBlockPacketsWith(ctx, g, characterID, online)
		}
		for _, p := range pkts {
			_ = e.Session.Send(p)
		}
	}
}
