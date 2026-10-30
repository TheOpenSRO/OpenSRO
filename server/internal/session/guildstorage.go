package session

import (
	"context"
	"encoding/binary"
	"log/slog"
	"sync"
	"sync/atomic"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/guild"
	"github.com/TheOpenSRO/OpenSRO/server/internal/guildstorage"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/trade"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// The guild storage (round 844, lane H; docs/protocol/guild_storage.md). All
// READ from SR_GameServer.exe and sro_client.exe:
//
//	0x7250 {u32 npc} open   -> Guild_HandleWarehouseUse s:0x5178b0 -> FUN_005c7440,
//	                           the ShardManager's job 0x24 type 1; 0xB250 {1}
//	                           (s:0x5c96aa) or {2, u16 code}, 0x4c48 followed by
//	                           the holder's name (s:0x5ccec3..0x5ccf37)
//	0x7251 {u32 npc} close  -> s:0x517980 -> FUN_005c74d0, job 0x24 type 2; 0xB251 {1}
//	0x7252 {u32 npc} list   -> s:0x517a50: the holder only (0x4c49); the chest
//	                           loaded (FUN_004c7da0, AQ type 5) and sent by
//	                           GObjPC::FUN_004e1cb0: 0x3253 {u64 gold}, 0x3255
//	                           {bytes}..., 0x3254 {}; the bytes {u8 size, u8 n,
//	                           n x {u8 slot, item record}} (c:0x88d240)
//	0x7034 types 0x1d (inside), 0x1e (bag -> storage), 0x1f (storage -> bag),
//	0x20 (gold in), 0x21 (gold out): ItemOpHandler routes them here
//	(guildStorageMove).
//
// OURS: the ShardManager's lock is guildstorage.Locks in this process; the
// 0xB252 {1} after a list (the client reads it and does nothing,
// c:0x88d390).
const (
	OpGuildStorageOpen        uint16 = 0x7250
	OpGuildStorageOpenResult  uint16 = 0xB250
	OpGuildStorageClose       uint16 = 0x7251
	OpGuildStorageCloseResult uint16 = 0xB251
	OpGuildStorageList        uint16 = 0x7252
	OpGuildStorageListResult  uint16 = 0xB252
	OpGuildStorageBegin       uint16 = 0x3253
	OpGuildStorageEnd         uint16 = 0x3254
	OpGuildStorageData        uint16 = 0x3255

	ItemMoveGuildInside   byte = 0x1d
	ItemMoveGuildDeposit  byte = 0x1e
	ItemMoveGuildWithdraw byte = 0x1f
	ItemMoveGuildGoldIn   byte = 0x20
	ItemMoveGuildGoldOut  byte = 0x21
)

// isGuildStorageMove reports a 0x7034 type that is the guild storage's.
func isGuildStorageMove(t byte) bool {
	return t >= ItemMoveGuildInside && t <= ItemMoveGuildGoldOut
}

// GuildStorageDeps is what the guild storage needs.
type GuildStorageDeps struct {
	Guilds guild.Store
	Svc    *guildstorage.Service
	Locks  *guildstorage.Locks
	Hub    *world.Hub
	Chars  character.Store
	Items  ItemLookup
	Trades *trade.Hub

	mu sync.Mutex
	// loaded is each character's loaded chest (the PC's +0x1fd8, its +0x1fec
	// set): the guild whose list it was sent. The moves need it (3
	// otherwise, s:0x524523).
	loaded map[int64]int64
}

var guildStorageRT atomic.Pointer[GuildStorageDeps]

// GuildStorageHandler returns the handler for 0x7250..0x7252; the moves come
// through ItemOpHandler.
func GuildStorageHandler(d *GuildStorageDeps) gateway.Handler {
	if d.Locks == nil {
		d.Locks = guildstorage.NewLocks()
	}
	d.loaded = map[int64]int64{}
	guildStorageRT.Store(d)
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		switch p.Opcode {
		case OpGuildStorageOpen:
			d.open(ctx, sess, p.Data)
		case OpGuildStorageClose:
			d.close(ctx, sess, p.Data)
		case OpGuildStorageList:
			d.list(ctx, sess, p.Data)
		}
		return nil
	}
}

// GuildStorageHolder is who uses guildID's storage now (0 none): for the
// guild's other requests, which refuse while it is used -- the leave and the
// expel of the holder and the disband 0x4c48 (s:0x5c60e6, s:0x5c68b6), a
// permission change taking bit 0x08 from the holder 0x4c4c (s:0x5c6a48).
func GuildStorageHolder(guildID int64) (int64, string) {
	d := guildStorageRT.Load()
	if d == nil {
		return 0, ""
	}
	if h, ok := d.Locks.HolderOf(guildID); ok {
		return h.CharacterID, h.Name
	}
	return 0, ""
}

// DropGuildStorage empties a disbanded guild's storage (the disband's own
// warning, UIIT_MSG_GUILD_BREAK_ANOTHER_EXPLAIN).
func DropGuildStorage(ctx context.Context, guildID int64) {
	d := guildStorageRT.Load()
	if d == nil || d.Svc == nil {
		return
	}
	if err := d.Svc.Drop(ctx, guildID); err != nil {
		slog.Warn("guild storage: emptying a disbanded guild's storage failed", "guild_id", guildID, "err", err)
	}
}

// GuildStorageDisconnectHandler releases what a leaving character holds.
func GuildStorageDisconnectHandler(hub *world.Hub) func(sess *gateway.Session) {
	return func(sess *gateway.Session) {
		d := guildStorageRT.Load()
		if d == nil || hub == nil {
			return
		}
		if e, ok := hub.EntityBySession(sess.ID()); ok {
			d.release(e.CharacterID)
		}
	}
}

func (d *GuildStorageDeps) release(characterID int64) {
	d.Locks.ReleaseCharacter(characterID)
	d.mu.Lock()
	delete(d.loaded, characterID)
	d.mu.Unlock()
}

func (d *GuildStorageDeps) loadedGuild(characterID int64) (int64, bool) {
	d.mu.Lock()
	defer d.mu.Unlock()
	g, ok := d.loaded[characterID]
	return g, ok
}

func guildStorageSend(sess *gateway.Session, op uint16, data []byte) {
	if sess != nil {
		_ = sess.Send(&proto.Packet{Opcode: op, Data: data})
	}
}

func guildStorageFail(code uint16) []byte {
	return binary.LittleEndian.AppendUint16([]byte{2}, code)
}

// EncodeGuildStorageInUse is 0xB250's 0x4c48 with the holder's name.
func EncodeGuildStorageInUse(name string) []byte {
	out := guildStorageFail(guildstorage.CodeInUse)
	out = binary.LittleEndian.AppendUint16(out, uint16(len(name)))
	return append(out, name...)
}

// npcGate is FUN_004e72a0 and the NPC's interaction 0xf: 0 when the NPC the
// request names is in reach and is a guild manager, else the code.
func guildStorageNPCGate(e world.Entity, npc uint32) uint16 {
	pl, code := npcTarget(e, npc)
	if code != 0 {
		return code
	}
	if pl.npc == nil {
		return guildstorage.CodeNoTarget
	}
	for _, id := range pl.npc.Interact {
		if id == guildNPCInteraction {
			return 0
		}
	}
	return guildstorage.CodeNoTarget
}

// guildGate is FUN_005c7440 / FUN_005c74d0's own tests: a guild (0x4c0d),
// level 2 (0x4c4a), the master or bit 0x08 (0x4c1e).
func (d *GuildStorageDeps) guildGate(ctx context.Context, characterID int64) (*guild.Guild, uint16) {
	g, err := d.Guilds.GetByCharacter(ctx, characterID)
	if err != nil || g == nil {
		return nil, guildstorage.CodeNotInGuild
	}
	if g.Level < guildstorage.MinLevel {
		return g, guildstorage.CodeLevel
	}
	if g.LeaderID != characterID && !memberPerm(g, characterID).Has(guild.PermWarehouse) {
		return g, guildstorage.CodePermission
	}
	return g, 0
}

func readNPC(data []byte) (uint32, bool) {
	if len(data) < 4 {
		return 0, false
	}
	return binary.LittleEndian.Uint32(data), true
}

// open is 0x7250.
func (d *GuildStorageDeps) open(ctx context.Context, sess *gateway.Session, data []byte) {
	npc, ok := readNPC(data)
	if !ok {
		return
	}
	e, ok := d.Hub.EntityBySession(sess.ID())
	if !ok {
		return
	}
	if code := guildStorageNPCGate(e, npc); code != 0 {
		guildStorageSend(sess, OpGuildStorageOpenResult, guildStorageFail(code))
		return
	}
	g, code := d.guildGate(ctx, e.CharacterID)
	if code != 0 {
		guildStorageSend(sess, OpGuildStorageOpenResult, guildStorageFail(code))
		return
	}
	if h, ok := d.Locks.Acquire(g.ID, guildstorage.Holder{CharacterID: e.CharacterID, Name: e.Name}); !ok {
		guildStorageSend(sess, OpGuildStorageOpenResult, EncodeGuildStorageInUse(h.Name))
		return
	}
	guildStorageSend(sess, OpGuildStorageOpenResult, []byte{1})
}

// close is 0x7251: the same tests, the lock released when this character
// holds it (CMainProcess::FUN_005c5510 type 2), {1}.
func (d *GuildStorageDeps) close(ctx context.Context, sess *gateway.Session, data []byte) {
	npc, ok := readNPC(data)
	if !ok {
		return
	}
	e, ok := d.Hub.EntityBySession(sess.ID())
	if !ok {
		return
	}
	if code := guildStorageNPCGate(e, npc); code != 0 {
		// Out of reach or another NPC: the storage is released all the same
		// (OURS: the window is gone on the client, and a lock no one can
		// close would keep the guild out until the holder logs off).
		d.release(e.CharacterID)
		guildStorageSend(sess, OpGuildStorageCloseResult, guildStorageFail(code))
		return
	}
	g, code := d.guildGate(ctx, e.CharacterID)
	if code != 0 {
		d.release(e.CharacterID)
		guildStorageSend(sess, OpGuildStorageCloseResult, guildStorageFail(code))
		return
	}
	d.Locks.Release(g.ID, e.CharacterID)
	d.mu.Lock()
	delete(d.loaded, e.CharacterID)
	d.mu.Unlock()
	guildStorageSend(sess, OpGuildStorageCloseResult, []byte{1})
}

// list is 0x7252: the holder's storage, as 0x3253 / 0x3255... / 0x3254.
func (d *GuildStorageDeps) list(ctx context.Context, sess *gateway.Session, data []byte) {
	npc, ok := readNPC(data)
	if !ok {
		return
	}
	e, ok := d.Hub.EntityBySession(sess.ID())
	if !ok {
		return
	}
	if code := guildStorageNPCGate(e, npc); code != 0 {
		guildStorageSend(sess, OpGuildStorageListResult, guildStorageFail(guildstorage.CodeNoTarget))
		return
	}
	g, err := d.Guilds.GetByCharacter(ctx, e.CharacterID)
	if err != nil || g == nil {
		guildStorageSend(sess, OpGuildStorageListResult, guildStorageFail(guildstorage.CodeNotInGuild))
		return
	}
	if g.Level < guildstorage.MinLevel {
		guildStorageSend(sess, OpGuildStorageListResult, guildStorageFail(guildstorage.CodeLevel))
		return
	}
	if !d.Locks.Holds(g.ID, e.CharacterID) {
		guildStorageSend(sess, OpGuildStorageListResult, guildStorageFail(guildstorage.CodeNotHolder))
		return
	}
	slots, gold, err := d.Svc.List(ctx, g.ID)
	if err != nil {
		slog.Warn("guild storage: loading failed", "guild_id", g.ID, "err", err)
		guildStorageSend(sess, OpGuildStorageListResult, guildStorageFail(guildstorage.CodeDB))
		return
	}
	d.mu.Lock()
	d.loaded[e.CharacterID] = g.ID
	d.mu.Unlock()
	for _, p := range EncodeGuildStorageList(ctx, d.Items, guildstorage.Capacity(g.Level), slots, gold) {
		_ = sess.Send(p)
	}
	guildStorageSend(sess, OpGuildStorageListResult, []byte{1})
}

// EncodeGuildStorageList is the list as GObjPC::FUN_004e1cb0 sends it: 0x3253
// {u64 gold}, the bytes in 0x3255 pieces, 0x3254 {}.
func EncodeGuildStorageList(ctx context.Context, items ItemLookup, capacity int, slots []inventory.Slot, gold int64) []*proto.Packet {
	body := []byte{byte(capacity), 0}
	n := 0
	for _, sl := range slots {
		if sl.Quantity <= 0 || sl.Index < 0 || sl.Index > 0xff {
			continue
		}
		body = append(body, byte(sl.Index))
		body = append(body, exchangeRecord(ctx, items, trade.Item{Slot: sl.Index, ItemID: sl.ItemID, Quantity: sl.Quantity, Inst: sl.Instance()})...)
		n++
	}
	body[1] = byte(n)
	out := []*proto.Packet{{Opcode: OpGuildStorageBegin, Data: binary.LittleEndian.AppendUint64(nil, uint64(gold))}}
	for _, chunk := range guild.BlockChunks(body) {
		out = append(out, &proto.Packet{Opcode: OpGuildStorageData, Data: chunk})
	}
	return append(out, &proto.Packet{Opcode: OpGuildStorageEnd})
}

// guildStorageMove is 0x7034 types 0x1d..0x21 (s:0x5248a0, 0x524510,
// 0x5247d0, 0x5243d0).
func guildStorageMove(ctx context.Context, sess *gateway.Session, data []byte) error {
	fail := func(code uint16) error {
		return sess.Send(&proto.Packet{Opcode: OpItemMoveResult, Data: EncodeItemFail(code)})
	}
	d := guildStorageRT.Load()
	if d == nil || d.Svc == nil {
		return fail(guildstorage.CodeDB)
	}
	e, ok := d.Hub.EntityBySession(sess.ID())
	if !ok {
		return fail(guildstorage.CodeDB)
	}
	if d.Trades != nil && d.Trades.Busy(e.CharacterID) {
		return fail(ItemErrBusy)
	}
	t := data[0]
	b := data[1:]
	gid, loaded := d.loadedGuild(e.CharacterID)
	// The chest loaded (pc +0x1fec, +0x1ff0), else 3 -- and the holder still.
	if !loaded || !d.Locks.Holds(gid, e.CharacterID) {
		return fail(guildstorage.CodeNoTarget)
	}
	g, err := d.Guilds.GetByCharacter(ctx, e.CharacterID)
	if err != nil || g == nil || g.ID != gid {
		return fail(guildstorage.CodeNoTarget)
	}
	capacity := guildstorage.Capacity(g.Level)
	switch t {
	case ItemMoveGuildGoldIn, ItemMoveGuildGoldOut:
		if len(b) < 8 {
			return fail(guildstorage.CodeDB)
		}
		// INTERACTMODE 6 (s:0x5243f8), else 0x1834.
		if _, mode := NPCInteractionMode(sess.ID()); mode != 6 {
			return fail(guildstorage.CodeBlocked)
		}
		amount := int64(binary.LittleEndian.Uint64(b))
		if amount <= 0 {
			return fail(guildstorage.CodeCount)
		}
		if t == ItemMoveGuildGoldIn {
			err = d.Svc.DepositGold(ctx, e.CharacterID, gid, amount)
		} else {
			err = d.Svc.WithdrawGold(ctx, e.CharacterID, gid, amount)
		}
		if err != nil {
			return fail(guildstorage.CodeOf(err))
		}
		// OffsetGold (reason 0x1d in, 0x27 out): 0x304E, unshown.
		tellGold(ctx, d.Chars, d.Hub, e.CharacterID, false)
		return sess.Send(&proto.Packet{Opcode: OpItemMoveResult, Data: binary.LittleEndian.AppendUint64([]byte{itemOpOK, t}, uint64(amount))})
	case ItemMoveGuildInside:
		if len(b) < 8 {
			return fail(guildstorage.CodeDB)
		}
		src, dst := int(b[0]), int(b[1])
		count := int(int16(binary.LittleEndian.Uint16(b[2:])))
		if code := guildStorageNPCGate(e, binary.LittleEndian.Uint32(b[4:])); code != 0 {
			return fail(code)
		}
		m, err := d.Svc.Move(ctx, gid, capacity, src, dst, count)
		if err != nil {
			return fail(guildstorage.CodeOf(err))
		}
		out := []byte{itemOpOK, t, byte(m.Src), byte(m.Dst)}
		return sess.Send(&proto.Packet{Opcode: OpItemMoveResult, Data: binary.LittleEndian.AppendUint16(out, uint16(m.Count))})
	case ItemMoveGuildDeposit, ItemMoveGuildWithdraw:
		if len(b) < 6 {
			return fail(guildstorage.CodeDB)
		}
		src, dst := int(b[0]), int(b[1])
		npc := binary.LittleEndian.Uint32(b[2:])
		bagCap := inventory.PlacementCapacityOf(ctx, d.Svc.Bag, e.CharacterID)
		if t == ItemMoveGuildDeposit {
			if src < ItemWireBagOffset {
				return fail(guildstorage.CodeWrongPlace)
			}
			if code := guildStorageNPCGate(e, npc); code != 0 {
				return fail(code)
			}
			if cosItemOut(ctx, e.CharacterID, src-ItemWireBagOffset) {
				return fail(guildstorage.CodePetOut)
			}
			used, _, err := d.Svc.Deposit(ctx, e.CharacterID, gid, capacity, src-ItemWireBagOffset, dst)
			if err != nil {
				return fail(guildstorage.CodeOf(err))
			}
			tellGold(ctx, d.Chars, d.Hub, e.CharacterID, false)
			return sess.Send(&proto.Packet{Opcode: OpItemMoveResult, Data: []byte{itemOpOK, t, byte(src), byte(used)}})
		}
		if dst < ItemWireBagOffset {
			return fail(guildstorage.CodeWrongPlace)
		}
		if code := guildStorageNPCGate(e, npc); code != 0 {
			return fail(code)
		}
		used, err := d.Svc.Withdraw(ctx, e.CharacterID, gid, capacity, src, bagCap, dst-ItemWireBagOffset)
		if err != nil {
			return fail(guildstorage.CodeOf(err))
		}
		return sess.Send(&proto.Packet{Opcode: OpItemMoveResult, Data: []byte{itemOpOK, t, byte(src), byte(used + ItemWireBagOffset)}})
	}
	return fail(guildstorage.CodeDB)
}

// guildStorageRefuses is the holder test the leave, the expel and the
// disband make first (0x4c48): target is the member going, or 0 for the
// disband (any holder).
func guildStorageRefuses(guildID, target int64) bool {
	holder, _ := GuildStorageHolder(guildID)
	if holder == 0 {
		return false
	}
	return target == 0 || holder == target
}
