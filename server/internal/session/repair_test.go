package session

import (
	"bufio"
	"context"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
)

func TestRepairResultRoundTrip(t *testing.T) {
	in := &RepairResult{Code: 0, GoldSpent: 297, Durabilities: []DurabilitySnapshot{
		{Slot: 6, Durability: 76, MaxDurability: 76},
	}}
	out, err := DecodeRepairResult(in.Encode())
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if out.Code != 0 || out.GoldSpent != 297 || len(out.Durabilities) != 1 || out.Durabilities[0] != in.Durabilities[0] {
		t.Errorf("round trip mismatch: %+v", out)
	}
}

// The durability block is additive: a client that stops after the counted
// slots (an older build) still reads every slot; only the trailing block is
// invisible to it. Encoding with a block and decoding the pre-block prefix
// must yield the same slots.
func TestInventoryListDurabilityBlockIsAdditive(t *testing.T) {
	full := &InventoryListResult{
		Slots: []InventorySlotSnapshot{{Slot: 0, ItemID: 100, Quantity: 1}},
		Durabilities: []DurabilitySnapshot{
			{Slot: 0, Durability: 40, MaxDurability: 76},
		},
	}
	// A new client reads both.
	got, err := DecodeInventoryListResult(full.Encode())
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(got.Slots) != 1 || got.Slots[0].ItemID != 100 {
		t.Fatalf("slots not decoded: %+v", got.Slots)
	}
	if len(got.Durabilities) != 1 || got.Durabilities[0].Durability != 40 {
		t.Errorf("durability block not decoded: %+v", got.Durabilities)
	}
	// The slots (error + count + records) come first and are byte-identical
	// whether or not a durability block follows, so a client that reads only
	// them is unaffected. The empty-block encoding's own trailing 2-byte
	// count marks where that prefix ends.
	empty := (&InventoryListResult{Slots: full.Slots}).Encode()
	slotPrefix := empty[:len(empty)-2] // drop the empty block's count
	withBlock := full.Encode()
	if len(withBlock) <= len(slotPrefix) {
		t.Fatal("the block should add bytes after the slots")
	}
	for i := range slotPrefix {
		if withBlock[i] != slotPrefix[i] {
			t.Fatalf("the block changed a slot byte at %d: an old client would misread", i)
		}
	}
}

// End to end: a nearly-broken worn weapon is repaired for gold, and the
// result reports it back at full durability.
func TestRepairHandlerRestoresAndCharges(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("create: %v", err)
	}

	items := refdata.NewMemStore()
	// ITEM_CH_SWORD_01_A: Dur_L 62, Dur_U 76, full-repair cost 297.
	if err := items.ImportItems(ctx, []refdata.Item{
		{ID: 100, MaxStack: 1, DurabilityMin: 62, DurabilityMax: 76, RepairCost: 198,
			TypeID1: equipment.TypeItem, TypeID2: equipment.TypeEquipment, Country: equipment.CountryChina},
	}); err != nil {
		t.Fatalf("import: %v", err)
	}
	inv := inventory.NewMemStore(items)
	inv.SetDurabilityLookup(items)
	eq := equipment.NewMemStore(inv)

	if err := inv.AddItem(ctx, c.ID, 100, 1); err != nil {
		t.Fatalf("add: %v", err)
	}
	if err := eq.Equip(ctx, c.ID, equipment.SlotWeapon, 0); err != nil {
		t.Fatalf("equip: %v", err)
	}
	// Batter it down to 1 point.
	if err := eq.SetDurability(ctx, c.ID, equipment.SlotWeapon, 1); err != nil {
		t.Fatalf("set durability: %v", err)
	}

	before, _ := chars.GetByID(ctx, c.ID)
	goldBefore := before.Gold

	handle := gateway.Chain(LoginHandler(accounts), RepairHandler(chars, eq, items, nil))
	addr, cleanup := startTestServer(t, handle)
	defer cleanup()
	conn := dialTestServer(t, addr)
	defer conn.Close()
	r := bufio.NewReader(conn)
	send := func(op uint16, data []byte) *proto.Packet {
		if err := proto.Write(conn, &proto.Packet{Opcode: op, Data: data}, nil, nil); err != nil {
			t.Fatalf("write: %v", err)
		}
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		resp, err := proto.Read(r, nil, nil)
		if err != nil {
			t.Fatalf("read: %v", err)
		}
		return resp
	}
	if lr, err := DecodeLoginResult(send(OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode()).Data); err != nil || !lr.OK {
		t.Fatalf("login: %v %+v", err, lr)
	}

	resp := send(OpRepair, (&RepairRequest{CharacterName: "Aria", Slot: int32(equipment.SlotWeapon)}).Encode())
	res, err := DecodeRepairResult(resp.Data)
	if err != nil {
		t.Fatalf("decode result: %v", err)
	}
	if res.Code != 0 {
		t.Fatalf("repair refused with 0x%x", res.Code)
	}
	if res.GoldSpent <= 0 {
		t.Errorf("repair charged nothing")
	}
	after, _ := chars.GetByID(ctx, c.ID)
	if after.Gold != goldBefore-res.GoldSpent {
		t.Errorf("gold %d, want %d", after.Gold, goldBefore-res.GoldSpent)
	}
	worn, _ := eq.Get(ctx, c.ID)
	var dur, max int
	for _, e := range worn {
		if e.Slot == equipment.SlotWeapon {
			dur = e.Durability
			max = durabilityMaxForTest(e.Variance)
		}
	}
	if dur != max {
		t.Errorf("weapon repaired to %d, want its max %d", dur, max)
	}
	// The result's block reports the same.
	if len(res.Durabilities) != 1 || res.Durabilities[0].Durability != res.Durabilities[0].MaxDurability {
		t.Errorf("result block does not show a full weapon: %+v", res.Durabilities)
	}
}

func durabilityMaxForTest(variance uint64) int {
	// mirrors durability.MaxDurability(62, 76, variance)
	q := float64(int((variance)&0x1f)) / 31
	m := int(62 + q*(76-62) + 0.5)
	if m < 1 {
		m = 1
	}
	return m
}
