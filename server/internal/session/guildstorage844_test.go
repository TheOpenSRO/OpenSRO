package session

import (
	"bufio"
	"context"
	"encoding/binary"
	"errors"
	"math"
	"net"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/guild"
	"github.com/TheOpenSRO/OpenSRO/server/internal/guildstorage"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/npcspawn"
	"github.com/TheOpenSRO/OpenSRO/server/internal/npctalk"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/trade"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Round 844 lane H: the guild storage end to end over the wire (guildstorage.go
// has the READ addresses).

type gsItems struct{}

func (gsItems) GetItem(_ context.Context, id int64) (*refdata.Item, error) {
	switch id {
	case 100:
		return &refdata.Item{ID: id, MaxStack: 50, KeepingFee: 8, CanTrade: true, TypeID1: 3, TypeID2: 3, TypeID3: 1, TypeID4: 1}, nil
	case 300:
		return &refdata.Item{ID: id, MaxStack: 1, CanTrade: true, TypeID1: 3, TypeID2: 3, TypeID3: 9}, nil
	}
	return nil, errors.New("no such item")
}

func (gsItems) GetMaxStack(ctx context.Context, id int64) (int, error) {
	it, err := gsItems{}.GetItem(ctx, id)
	if err != nil {
		return 0, nil
	}
	return it.MaxStack, nil
}

type gsFixture struct {
	*deadWorldFixture
	guilds *guild.MemStore
	inv    *inventory.MemStore
	chest  *inventory.MemStore
	deps   *GuildStorageDeps
	npc    uint32
	gid    int64
}

func startGuildStorage(t *testing.T) *gsFixture {
	t.Helper()
	ctx := context.Background()
	guilds := guild.NewMemStore()
	inv := inventory.NewMemStore(gsItems{})
	chest := inventory.NewMemStore(gsItems{})
	chest.SetCapacity(guildstorage.MaxSlots)
	keeper := npcAt(9, 100, 0, npcspawn.FromNest)
	keeper.Code = "NPC_T_GUILD"
	keeper.Flags, keeper.Interact = npcspawn.FlagInteractions, []byte{1, guildNPCInteraction}
	installNPCsForTest(t, keeper)
	var deps *GuildStorageDeps
	f := startDeadWorldFixtureWith(t, func(chars character.Store, hub *world.Hub) gateway.Handler {
		trades := trade.NewHub()
		deps = &GuildStorageDeps{Guilds: guilds, Hub: hub, Chars: chars, Items: gsItems{}, Trades: trades,
			Svc: &guildstorage.Service{Bag: inv, Chest: chest, Purse: chars, Vault: guildstorage.NewMemGold(), Items: gsItems{}}}
		return gateway.Chain(testGuildHandler(t, chars, guilds, hub), GuildStorageHandler(deps),
			ItemOpHandler(ItemOpDeps{Hub: hub, Inv: inv, Trades: trades, Items: gsItems{}, Chars: chars}),
			NPCTalkHandler(hub, trades))
	})
	t.Cleanup(func() { guildStorageRT.Store(nil) })
	ea, _ := f.hub.FindByName("Aria")
	if ea.Zone != "jangan" {
		t.Skipf("the test NPC stands in the jangan frame; the world put Aria in %q", ea.Zone)
	}
	eb, _ := f.hub.FindByName("Bram")
	f.hub.Relocate(ea.Session, world.Position{X: 50, Z: 0}, world.MoveRelocate, 0)
	f.hub.Relocate(eb.Session, world.Position{X: 55, Z: 0}, world.MoveRelocate, 0)
	g, err := guilds.Create(ctx, "Verizon", f.aria, "Aria")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := guilds.Join(ctx, g.ID, f.bram, "Bram"); err != nil {
		t.Fatal(err)
	}
	return &gsFixture{deadWorldFixture: f, guilds: guilds, inv: inv, chest: chest, deps: deps, npc: keeper.UID, gid: g.ID}
}

func (f *gsFixture) levelTo(t *testing.T, n int) {
	t.Helper()
	ctx := context.Background()
	for {
		g, _ := f.guilds.Get(ctx, f.gid)
		if g.Level >= n {
			return
		}
		_, gp, _ := guild.LevelUpCost(g.Level)
		f.guilds.AddPoints(ctx, f.gid, f.aria, gp)
		if _, err := f.guilds.LevelUp(ctx, f.aria, true, math.MaxInt64, nil); err != nil {
			t.Fatal(err)
		}
	}
}

func (f *gsFixture) req(op uint16, conn net.Conn, t *testing.T) {
	f.send(t, conn, op, binary.LittleEndian.AppendUint32(nil, f.npc))
}

// openTalk opens the NPC's interaction 0xf (INTERACTMODE 6), the talk line
// 0x1d's 0x7046.
func (f *gsFixture) openTalk(t *testing.T, conn net.Conn, r *bufio.Reader) {
	t.Helper()
	f.send(t, conn, npctalk.OpSelect, npctalk.EncodeEntity(f.npc))
	nextOp(t, conn, r, npctalk.OpSelectResult)
	f.send(t, conn, npctalk.OpOpen, npctalk.EncodeOpen(f.npc, guildNPCInteraction))
	if got := nextOp(t, conn, r, npctalk.OpOpenResult).Data; len(got) < 2 || got[0] != 1 || got[1] != guildNPCInteraction {
		t.Fatalf("0xB046 % x", got)
	}
}

// readList reads 0x3253 .. 0x3254 and the 0xB252 after it.
func readList(t *testing.T, conn net.Conn, r *bufio.Reader) (gold int64, capacity int, slots map[int][]byte) {
	t.Helper()
	begin := nextOp(t, conn, r, OpGuildStorageBegin).Data
	gold = int64(binary.LittleEndian.Uint64(begin))
	var body []byte
	for {
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		p, err := proto.Read(r, nil, nil)
		if err != nil {
			t.Fatalf("reading the list: %v", err)
		}
		if p.Opcode == OpGuildStorageData {
			body = append(body, p.Data...)
			continue
		}
		if p.Opcode == OpGuildStorageEnd {
			break
		}
	}
	if res := nextOp(t, conn, r, OpGuildStorageListResult).Data; len(res) != 1 || res[0] != 1 {
		t.Fatalf("0xB252 % x", res)
	}
	capacity = int(body[0])
	slots = map[int][]byte{}
	at := 2
	for i := 0; i < int(body[1]); i++ {
		slot := int(body[at])
		at++
		// The test items are expendables: rent u32, ref u32, count u16.
		slots[slot] = body[at : at+10]
		at += 10
	}
	return
}

func TestGuildStorageWire(t *testing.T) {
	f := startGuildStorage(t)
	ctx := context.Background()

	// Level 1: 0x4c4a.
	f.req(OpGuildStorageOpen, f.connA, t)
	if got := nextOp(t, f.connA, f.rA, OpGuildStorageOpenResult).Data; string(got) != string([]byte{2, 0x4a, 0x4c}) {
		t.Fatalf("a level-1 guild's open % x", got)
	}
	f.levelTo(t, 2)
	// Bram without bit 0x08: 0x4c1e.
	f.req(OpGuildStorageOpen, f.connB, t)
	if got := nextOp(t, f.connB, f.rB, OpGuildStorageOpenResult).Data; string(got) != string([]byte{2, 0x1e, 0x4c}) {
		t.Fatalf("a member without the permission % x", got)
	}
	// Aria, the master: {1}; then Bram, given 0x08, finds her using it.
	f.openTalk(t, f.connA, f.rA)
	f.req(OpGuildStorageOpen, f.connA, t)
	if got := nextOp(t, f.connA, f.rA, OpGuildStorageOpenResult).Data; string(got) != string([]byte{1}) {
		t.Fatalf("the master's open % x", got)
	}
	f.guilds.SetMemberPermission(ctx, f.gid, f.bram, guild.PermWarehouse)
	f.req(OpGuildStorageOpen, f.connB, t)
	want := append([]byte{2, 0x48, 0x4c, 4, 0}, "Aria"...)
	if got := nextOp(t, f.connB, f.rB, OpGuildStorageOpenResult).Data; string(got) != string(want) {
		t.Fatalf("the open while Aria uses it % x, want % x", got, want)
	}
	// Bram cannot list it either (0x4c49), nor leave, and nobody can disband.
	f.req(OpGuildStorageList, f.connB, t)
	if got := nextOp(t, f.connB, f.rB, OpGuildStorageListResult).Data; string(got) != string([]byte{2, 0x49, 0x4c}) {
		t.Fatalf("a list by a non-holder % x", got)
	}
	f.send(t, f.connA, guild.OpDisband, uidBytes(int64(f.npc)))
	if got := nextOp(t, f.connA, f.rA, guild.OpDisbandResult).Data; string(got) != string([]byte{2, 0x48, 0x4c}) {
		t.Fatalf("a disband while the storage is used % x", got)
	}

	// Aria's list: empty, 30 slots, no gold.
	f.req(OpGuildStorageList, f.connA, t)
	gold, capacity, slots := readList(t, f.connA, f.rA)
	if gold != 0 || capacity != 30 || len(slots) != 0 {
		t.Fatalf("the first list: gold %d capacity %d slots %v", gold, capacity, slots)
	}
	// She deposits 20 potions from bag slot 0 into storage slot 4: the whole
	// stack, half of 8 x 20 = 80 gold.
	if err := f.inv.AddItem(ctx, f.aria, 100, 20); err != nil {
		t.Fatal(err)
	}
	if err := f.chars.AddGold(ctx, f.aria, 1000); err != nil {
		t.Fatal(err)
	}
	before, _ := f.chars.GetByID(ctx, f.aria)
	f.send(t, f.connA, OpItemMove, binary.LittleEndian.AppendUint32([]byte{ItemMoveGuildDeposit, 13, 4}, f.npc))
	if got := nextOp(t, f.connA, f.rA, OpItemMoveResult).Data; string(got) != string([]byte{1, 0x1e, 13, 4}) {
		t.Fatalf("the deposit % x", got)
	}
	after, _ := f.chars.GetByID(ctx, f.aria)
	if before.Gold-after.Gold != 80 {
		t.Fatalf("the deposit cost %d, want 80", before.Gold-after.Gold)
	}
	// A quest item: 0x1843; an equipment slot: 5.
	f.inv.AddItem(ctx, f.aria, 300, 1)
	f.send(t, f.connA, OpItemMove, binary.LittleEndian.AppendUint32([]byte{ItemMoveGuildDeposit, 13, 0}, f.npc))
	if got := nextOp(t, f.connA, f.rA, OpItemMoveResult).Data; string(got) != string([]byte{2, 0x43, 0x18}) {
		t.Fatalf("a quest item's deposit % x", got)
	}
	f.send(t, f.connA, OpItemMove, binary.LittleEndian.AppendUint32([]byte{ItemMoveGuildDeposit, 6, 0}, f.npc))
	if got := nextOp(t, f.connA, f.rA, OpItemMoveResult).Data; string(got) != string([]byte{2, 5, 0}) {
		t.Fatalf("an equipment slot's deposit % x", got)
	}
	// Gold in: 500, {1, 0x20, u64 500}.
	f.send(t, f.connA, OpItemMove, binary.LittleEndian.AppendUint64([]byte{ItemMoveGuildGoldIn}, 500))
	if got := nextOp(t, f.connA, f.rA, OpItemMoveResult).Data; string(got) != string(binary.LittleEndian.AppendUint64([]byte{1, 0x20}, 500)) {
		t.Fatalf("the gold deposit % x", got)
	}
	// Inside: slot 4 to 9, the whole 20.
	b := []byte{ItemMoveGuildInside, 4, 9}
	b = binary.LittleEndian.AppendUint16(b, 20)
	f.send(t, f.connA, OpItemMove, binary.LittleEndian.AppendUint32(b, f.npc))
	if got := nextOp(t, f.connA, f.rA, OpItemMoveResult).Data; string(got) != string([]byte{1, 0x1d, 4, 9, 20, 0}) {
		t.Fatalf("the move inside % x", got)
	}
	// She closes: {1}.
	f.req(OpGuildStorageClose, f.connA, t)
	if got := nextOp(t, f.connA, f.rA, OpGuildStorageCloseResult).Data; string(got) != string([]byte{1}) {
		t.Fatalf("the close % x", got)
	}
	// Moves after the close: 3.
	f.send(t, f.connA, OpItemMove, binary.LittleEndian.AppendUint64([]byte{ItemMoveGuildGoldIn}, 5))
	if got := nextOp(t, f.connA, f.rA, OpItemMoveResult).Data; string(got) != string([]byte{2, 3, 0}) {
		t.Fatalf("a move with the storage closed % x", got)
	}

	// Bram opens it now and sees her potions and gold.
	f.openTalk(t, f.connB, f.rB)
	f.req(OpGuildStorageOpen, f.connB, t)
	if got := nextOp(t, f.connB, f.rB, OpGuildStorageOpenResult).Data; string(got) != string([]byte{1}) {
		t.Fatalf("Bram's open % x", got)
	}
	f.req(OpGuildStorageList, f.connB, t)
	gold, _, slots = readList(t, f.connB, f.rB)
	rec := slots[9]
	if gold != 500 || len(slots) != 1 || rec == nil || binary.LittleEndian.Uint32(rec[4:]) != 100 || binary.LittleEndian.Uint16(rec[8:]) != 20 {
		t.Fatalf("Bram's list: gold %d slots % x", gold, slots)
	}
	// He takes 200 gold and the potions into his bag slot 2 (wire 15).
	f.send(t, f.connB, OpItemMove, binary.LittleEndian.AppendUint64([]byte{ItemMoveGuildGoldOut}, 200))
	if got := nextOp(t, f.connB, f.rB, OpItemMoveResult).Data; string(got) != string(binary.LittleEndian.AppendUint64([]byte{1, 0x21}, 200)) {
		t.Fatalf("the gold withdraw % x", got)
	}
	f.send(t, f.connB, OpItemMove, binary.LittleEndian.AppendUint32([]byte{ItemMoveGuildWithdraw, 9, 15}, f.npc))
	if got := nextOp(t, f.connB, f.rB, OpItemMoveResult).Data; string(got) != string([]byte{1, 0x1f, 9, 15}) {
		t.Fatalf("the withdraw % x", got)
	}
	if bag, _ := f.inv.List(ctx, f.bram); len(bag) != 1 || bag[0].Index != 2 || bag[0].Quantity != 20 {
		t.Fatalf("Bram's bag %+v", bag)
	}
	// Holding it, he cannot leave (0x4c48); his logout releases it.
	f.send(t, f.connB, guild.OpLeave, uidBytes(int64(f.npc)))
	if got := nextOp(t, f.connB, f.rB, guild.OpLeaveResult).Data; string(got) != string([]byte{2, 0x48, 0x4c}) {
		t.Fatalf("the holder's leave % x", got)
	}
	eb, _ := f.hub.FindByName("Bram")
	GuildStorageDisconnectHandler(f.hub)(eb.Session)
	if h, _ := GuildStorageHolder(f.gid); h != 0 {
		t.Fatalf("the storage is still held by %d after the holder left", h)
	}
}
