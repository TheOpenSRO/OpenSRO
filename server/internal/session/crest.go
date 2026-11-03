package session

// Round 824: guild and union crests (emblems). READ unless marked; the
// layouts and addresses are docs/protocol/guild.md, "Crests (round 824)".
//
// The four crest items (itemdata 9268..9271, TypeID 3/3/12/2) are told apart
// by their Param1 (ref +0x2a0: 1 guild, 2 union) and Param2 (ref +0x2c0: 1
// register, 2 delete), which GObjPC::FUN_0049afe0 switches on (GS 0x49b272 /
// 0x49b27c) -- this export's RestoreHP and RestoreHPPct (MEASURED: 9268 1/1,
// 9269 1/2, 9270 2/1, 9271 2/2). A register's use carries 256 palette
// indices the client built from guildmark.bmp (c:0x4f9d70, 0x7974a2).
//
// GS's checks, in order (0x5c7600 register, 0x5c7690 delete): not in a guild
// 0x4c0d; guild level < 4 0x4c4a (FUN_005d0e80, the byte the level-up handler
// caps at 5); not the master 0x4c1e (0x5d0f50); a crest already 0x4c4e /
// none 0x4c4f. A union's (0x5c7710 / 0x5c77d0): level < 5 0x4c4a, not the
// master 0x4c1e, no union 0x4c2f -- OpenSRO forms no unions, so a union crest
// is always refused there. The client shows the item result's refusals
// through category 1 (Item_OnUseItemResult c:0x87b689 -> 0x778190(1, code)),
// which has no row for any of these: retail shows nothing. OURS: the reply's
// Error says why, and the client shows that.
//
// On success the original's ShardManager bumps the revision, writes the .crb
// and FTP-uploads it, and the GS broadcasts 0x3257 {u8 1, u32 guild, str
// name, u32 rev} (0x5cc330 -> 0x5c4350); the client downloads the .crb from
// the FTP host in Media.pk2's type.txt. OURS: the store keeps the bytes and
// the client asks this server for them (OpCrestGet / OpCrestData) -- an FTP
// server is not OpenSRO's to run.

import (
	"context"
	"encoding/binary"
	"errors"
	"log/slog"

	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/guild"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

const (
	// UseOptionCrest marks a use request that carries a crest's 256 bytes
	// after the option byte (OURS: retail's 0x704C appends them after the
	// slot and type word).
	UseOptionCrest byte = 0xC6

	// OpGuildCrestUpdate is 0x3257 (the client's FUN_00895810).
	OpGuildCrestUpdate uint16 = 0x3257
	// OpCrestGet asks for a crest's bytes: {u8 kind, u32 id, u32 rev} (OURS,
	// in place of the original's FTP download).
	OpCrestGet uint16 = 0x0130
	// OpCrestData answers it: {u8 kind, u32 id, u32 rev, u8 ok, [256 bytes
	// when ok]} (OURS).
	OpCrestData uint16 = 0x0131

	CrestKindGuild byte = 1
	CrestKindUnion byte = 2

	crestErrNotInGuild = 0x4c0d
	crestErrLevel      = 0x4c4a
	crestErrPermission = 0x4c1e
	crestErrExists     = 0x4c4e
	crestErrNone       = 0x4c4f
	crestErrNoUnion    = 0x4c2f

	// crestGuildLevel and crestUnionLevel are the levels the checks ask for
	// (0x5c7629 `cmp al,0x4`; 0x5c7710's level 5).
	crestGuildLevel = 4
	crestUnionLevel = 5
)

// crestItem says whether it is a crest item, and which: a union's (else a
// guild's), and a register (else a delete).
func crestItem(it *refdata.Item) (union, register, ok bool) {
	if it == nil || it.TypeID1 != 3 || it.TypeID2 != 3 || it.TypeID3 != 12 || it.TypeID4 != 2 {
		return false, false, false
	}
	if (it.RestoreHP != 1 && it.RestoreHP != 2) || (it.RestoreHPPct != 1 && it.RestoreHPPct != 2) {
		return false, false, false
	}
	return it.RestoreHP == 2, it.RestoreHPPct == 1, true
}

// crestRefusals are OURS words for the codes retail shows nothing for.
var crestRefusals = map[uint16]string{
	crestErrNotInGuild: "You are not in a guild.",
	crestErrLevel:      "The guild's level is too low for an emblem.",
	crestErrPermission: "Only the guild master can do that.",
	crestErrExists:     "Emblem is already registered. Please delete the existing emblem and register a new one.",
	crestErrNone:       "No guild emblem to be deleted.",
	crestErrNoUnion:    "Your guild is in no union.",
}

// useCrestItem is the use of a crest item in held (have of it).
func useCrestItem(ctx context.Context, sess *gateway.Session, inv inventory.Store, characterID int64,
	it *refdata.Item, held inventory.Slot, have int, req *UseItemRequest) error {
	union, register, _ := crestItem(it)
	refuse := func(code uint16) error {
		return sendUseResult(sess, &UseItemResult{Error: crestRefusals[code], Code: code, Remaining: int32(have)})
	}
	d := guildOps.Load()
	if d == nil {
		return sendUseResult(sess, &UseItemResult{Error: "guilds are not available", Remaining: int32(have)})
	}
	g, err := d.guilds.GetByCharacter(ctx, characterID)
	if errors.Is(err, guild.ErrNotInGuild) {
		return refuse(crestErrNotInGuild)
	}
	if err != nil {
		return sendUseResult(sess, &UseItemResult{Error: "lookup failed", Remaining: int32(have)})
	}
	need := crestGuildLevel
	if union {
		need = crestUnionLevel
	}
	if g.Level < need {
		return refuse(crestErrLevel)
	}
	if g.LeaderID != characterID {
		return refuse(crestErrPermission)
	}
	if union {
		// Round 844 (unionops_crest.go): unions exist now.
		return useUnionCrest(ctx, sess, inv, d, g, characterID, it, held, have, req, register, refuse)
	}
	if register {
		if g.CrestRev != 0 {
			return refuse(crestErrExists)
		}
		if req.Option != UseOptionCrest || len(req.Pixels) != guild.CrestBytes {
			return sendUseResult(sess, &UseItemResult{Error: "malformed request", Remaining: int32(have)})
		}
	} else if g.CrestRev == 0 {
		return refuse(crestErrNone)
	}
	var rev uint32
	if register {
		rev, err = d.guilds.SetCrest(ctx, g.ID, req.Pixels)
	} else {
		err = d.guilds.ClearCrest(ctx, g.ID)
	}
	if err != nil {
		slog.Warn("crest: storing failed", "guild", g.ID, "err", err)
		return sendUseResult(sess, &UseItemResult{Error: "using failed", Remaining: int32(have)})
	}
	if err := inv.RemoveItem(ctx, characterID, held.Index, 1); err != nil {
		slog.Warn("crest: the item was not taken", "character_id", characterID, "err", err)
	}
	guildCrestChanged(d.hub, uint32(g.ID), g.Name, rev)
	return sendUseResult(sess, &UseItemResult{Remaining: int32(have - 1), ItemID: uint32(it.ID)})
}

// EncodeGuildCrestUpdate is 0x3257's type 1 (GS 0x5cc330; the client reads
// it at 0x895886..0x895948): {u8 1, u32 guild, str name, u32 rev}. Rev 0
// clears the crest (the client's 0x9a48f0).
func EncodeGuildCrestUpdate(guildID uint32, name string, rev uint32) []byte {
	b := []byte{CrestKindGuild}
	b = binary.LittleEndian.AppendUint32(b, guildID)
	b = appendWireString(b, name)
	return binary.LittleEndian.AppendUint32(b, rev)
}

// guildCrestChanged files guildID's new revision in the plate cache (so a
// spawn record carries it) and broadcasts 0x3257 to everyone in the world
// (0x5c4350: the GS sends it to every player, INFERRED from its callers).
func guildCrestChanged(hub *world.Hub, guildID uint32, name string, rev uint32) {
	guildPlates.Range(func(k, v any) bool {
		if p := v.(guildPlate); p.ID == guildID {
			p.CrestRev = rev
			guildPlates.Store(k, p)
		}
		return true
	})
	if hub == nil {
		return
	}
	msg := &proto.Packet{Opcode: OpGuildCrestUpdate, Data: EncodeGuildCrestUpdate(guildID, name, rev)}
	for _, e := range hub.AllEntities() {
		if e.Session != nil {
			e.Session.Send(msg)
		}
	}
}

// handleCrestGet answers OpCrestGet with the crest's bytes when the
// revision asked for is the guild's current one (OURS).
func handleCrestGet(ctx context.Context, sess *gateway.Session, guilds guild.Store, data []byte) error {
	if len(data) < 9 {
		return nil
	}
	kind := data[0]
	id := binary.LittleEndian.Uint32(data[1:5])
	rev := binary.LittleEndian.Uint32(data[5:9])
	reply := append([]byte{kind}, data[1:9]...)
	// Round 844: a union's crest (unionops_crest.go).
	if kind == CrestKindUnion {
		if px := unionCrestBytes(ctx, int64(id), rev); px != nil {
			return sess.Send(&proto.Packet{Opcode: OpCrestData, Data: append(append(reply, 1), px...)})
		}
		return sess.Send(&proto.Packet{Opcode: OpCrestData, Data: append(reply, 0)})
	}
	if kind == CrestKindGuild && guilds != nil {
		cur, pixels, err := guilds.Crest(ctx, int64(id))
		if err == nil && cur == rev && rev != 0 && len(pixels) == guild.CrestBytes {
			reply = append(append(reply, 1), pixels...)
			return sess.Send(&proto.Packet{Opcode: OpCrestData, Data: reply})
		}
	}
	return sess.Send(&proto.Packet{Opcode: OpCrestData, Data: append(reply, 0)})
}
