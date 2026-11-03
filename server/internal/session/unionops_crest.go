package session

import (
	"context"
	"log/slog"

	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/guild"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Round 844 (lane U): the union's crest, now that unions exist. READ: the
// register (GObjPC::FUN_005c7710) and the delete (s:0x5c77d0) after round
// 824's guild level < 5 0x4c4a and master 0x4c1e: no union 0x4c2f, the
// guild not the union's first 0x4c1e, a crest already 0x4c4e / none 0x4c4f;
// then the ShardManager's job 0x28 / 0x29. The client reads 0x3257 type 2
// {u32 union id, u8 n, n x str guild name, u32 rev} (c:0x8958e3): each named
// guild's crest cache entry takes the union's crest, and the own union's
// revision is kept (c:0x895a3b). OURS as for the guild's: the bytes are this
// server's (OpCrestGet kind 2), not an FTP host's.

// useUnionCrest is a union crest item's use (crest.go's union branch).
func useUnionCrest(ctx context.Context, sess *gateway.Session, inv inventory.Store, d *guildOpsDeps, g *guild.Guild,
	characterID int64, it *refdata.Item, held inventory.Slot, have int, req *UseItemRequest, register bool,
	refuse func(code uint16) error) error {
	u := unionOfGuild(ctx, g.ID)
	if u == nil {
		return refuse(crestErrNoUnion)
	}
	if u.LeaderGuildID() != g.ID {
		return refuse(crestErrPermission)
	}
	cs, ok := unionStore().(guild.UnionCrestStore)
	if !ok {
		return sendUseResult(sess, &UseItemResult{Error: "union crests are not available", Remaining: int32(have)})
	}
	if register {
		if u.CrestRev != 0 {
			return refuse(crestErrExists)
		}
		if req.Option != UseOptionCrest || len(req.Pixels) != guild.CrestBytes {
			return sendUseResult(sess, &UseItemResult{Error: "malformed request", Remaining: int32(have)})
		}
	} else if u.CrestRev == 0 {
		return refuse(crestErrNone)
	}
	var rev uint32
	var err error
	if register {
		rev, err = cs.SetUnionCrest(ctx, u.ID, req.Pixels)
	} else {
		err = cs.ClearUnionCrest(ctx, u.ID)
	}
	if err != nil {
		slog.Warn("union crest: storing failed", "union", u.ID, "err", err)
		return sendUseResult(sess, &UseItemResult{Error: "using failed", Remaining: int32(have)})
	}
	if err := inv.RemoveItem(ctx, characterID, held.Index, 1); err != nil {
		slog.Warn("union crest: the item was not taken", "character_id", characterID, "err", err)
	}
	slog.Info("union crest", "union", u.ID, "rev", rev)
	unionCrestChanged(ctx, d.hub, u, rev)
	return sendUseResult(sess, &UseItemResult{Remaining: int32(have - 1), ItemID: uint32(it.ID)})
}

// unionCrestChanged files the union's new revision in the plate cache of
// every member of its guilds (a spawn record carries it) and sends 0x3257
// type 2 to everyone in the world, as the guild's (crest.go).
func unionCrestChanged(ctx context.Context, hub *world.Hub, u *guild.Union, rev uint32) {
	gs := unionGuilds(ctx, u.GuildIDs())
	names := make([]string, 0, len(gs))
	for _, g := range gs {
		names = append(names, g.Name)
	}
	guildPlates.Range(func(k, v any) bool {
		if p := v.(guildPlate); p.UnionID == uint32(u.ID) {
			p.UnionCrestRev = rev
			guildPlates.Store(k, p)
		}
		return true
	})
	if hub == nil {
		return
	}
	msg := &proto.Packet{Opcode: OpGuildCrestUpdate, Data: guild.EncodeUnionCrestUpdate(uint32(u.ID), names, rev)}
	for _, e := range hub.AllEntities() {
		if e.Session != nil {
			e.Session.Send(msg)
		}
	}
}

// unionCrestBytes is union id's crest when rev is its current one (nil else).
func unionCrestBytes(ctx context.Context, id int64, rev uint32) []byte {
	cs, ok := unionStore().(guild.UnionCrestStore)
	if !ok || rev == 0 {
		return nil
	}
	cur, px, err := cs.UnionCrest(ctx, id)
	if err != nil || cur != rev || len(px) != guild.CrestBytes {
		return nil
	}
	return px
}
