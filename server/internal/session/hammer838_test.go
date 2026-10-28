package session

import (
	"bufio"
	"context"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/durability"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/mana"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
)

// Round 838: the repair hammer (3/3/13/7), UseByKind case 7 -- every worn and
// carried item with a durability below its max is mended for free, one
// 0x3052 each, and one hammer spent; with nothing to mend 0x1888 and the
// hammer kept.
func TestRepairHammerMendsEverything(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	acc, err := accounts.Add("alice", "hunter2")
	if err != nil {
		t.Fatal(err)
	}
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, acc.ID, "Aria")
	if err != nil {
		t.Fatal(err)
	}
	const (
		hammer = 3784
		sword  = 100
		mail   = 200
		potion = 300
	)
	items := refdata.NewMemStore()
	eqp := func(id int64, t3, t4 int) refdata.Item {
		return refdata.Item{ID: id, MaxStack: 1, DurabilityMin: 40, DurabilityMax: 40, RepairCost: 100,
			TypeID1: equipment.TypeItem, TypeID2: equipment.TypeEquipment, TypeID3: t3, TypeID4: t4}
	}
	if err := items.ImportItems(ctx, []refdata.Item{
		{ID: hammer, CodeName: "ITEM_MALL_REPAIR_HAMMER", MaxStack: 50, TypeID1: 3, TypeID2: 3, TypeID3: 13, TypeID4: 7, RestoreHP: 2, CanUse: true},
		eqp(sword, 6, 2), eqp(mail, 1, 3),
		{ID: potion, MaxStack: 50, TypeID1: 3, TypeID2: 3, TypeID3: 1, TypeID4: 1, RestoreHP: 100, CanUse: true},
	}); err != nil {
		t.Fatal(err)
	}
	inv := inventory.NewMemStore(items)
	eq := equipment.NewMemStore(inv)
	// A broken sword worn, a worn-down mail in the bag, a potion, two hammers.
	if err := inv.AddItemInstance(ctx, c.ID, sword, 1, inventory.Instance{Durability: 0}); err != nil {
		t.Fatal(err)
	}
	if err := eq.Equip(ctx, c.ID, equipment.SlotWeapon, 0); err != nil {
		t.Fatal(err)
	}
	if err := inv.AddItemInstance(ctx, c.ID, mail, 1, inventory.Instance{Durability: 12}); err != nil {
		t.Fatal(err)
	}
	if err := inv.AddItem(ctx, c.ID, potion, 3); err != nil {
		t.Fatal(err)
	}
	if err := inv.AddItem(ctx, c.ID, hammer, 2); err != nil {
		t.Fatal(err)
	}
	SetUseItemEquipment(eq)
	t.Cleanup(func() { SetUseItemEquipment(nil) })

	handle := gateway.Chain(LoginHandler(accounts), UseItemHandler(chars, inv, items, mana.NewTracker(), nil, nil, nil, nil, nil, nil, nil))
	addr, cleanup := startTestServer(t, handle)
	defer cleanup()
	conn := dialTestServer(t, addr)
	defer conn.Close()
	r := bufio.NewReader(conn)
	write := func(op uint16, data []byte) {
		t.Helper()
		if err := proto.Write(conn, &proto.Packet{Opcode: op, Data: data}, nil, nil); err != nil {
			t.Fatal(err)
		}
	}
	read := func() *proto.Packet {
		t.Helper()
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		p, err := proto.Read(r, nil, nil)
		if err != nil {
			t.Fatal(err)
		}
		return p
	}
	write(OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode())
	if lr, err := DecodeLoginResult(read().Data); err != nil || !lr.OK {
		t.Fatalf("login: %v %+v", err, lr)
	}
	hammerSlot := func() (int, int) {
		slots, _ := inv.List(ctx, c.ID)
		for _, s := range slots {
			if s.ItemID == hammer {
				return s.Index, s.Quantity
			}
		}
		return -1, 0
	}
	mailSlot := func() inventory.Slot {
		slots, _ := inv.List(ctx, c.ID)
		for _, s := range slots {
			if s.ItemID == mail {
				return s
			}
		}
		t.Fatal("the mail left the bag")
		return inventory.Slot{}
	}
	at, _ := hammerSlot()
	write(OpUseItem, (&UseItemRequest{CharacterName: "Aria", InventorySlot: int32(at)}).Encode())
	res, err := DecodeUseItemResult(read().Data)
	if err != nil || res.Error != "" || res.Remaining != 1 || res.ItemID != hammer {
		t.Fatalf("the hammer: %+v, %v; want success, 1 left, ItemID %d", res, err, hammer)
	}
	// Two 0x3052s: the worn sword (slot 6) and the bag's mail (13 + its slot).
	want := map[int]bool{int(equipment.SlotWeapon): true, RepairBagSlotBase + mailSlot().Index: true}
	for i := 0; i < 2; i++ {
		p := read()
		if p.Opcode != OpDurabilityChanged || len(p.Data) != 5 {
			t.Fatalf("packet %d: %#x %x, want 0x3052", i, p.Opcode, p.Data)
		}
		slot, d := int(p.Data[0]), int(int32(uint32(p.Data[1])|uint32(p.Data[2])<<8|uint32(p.Data[3])<<16|uint32(p.Data[4])<<24))
		if !want[slot] || d != 40 {
			t.Errorf("0x3052 slot %d durability %d, want one of %v at 40", slot, d, want)
		}
		delete(want, slot)
	}
	worn, _ := eq.Get(ctx, c.ID)
	if len(worn) != 1 || worn[0].Durability != 40 {
		t.Errorf("the worn sword: %+v, want durability 40", worn)
	}
	if got := mailSlot().Durability; got != 40 {
		t.Errorf("the bag's mail at %d, want 40", got)
	}
	if got := mailSlot().Durability; durability.IsBroken(got) {
		t.Errorf("the mail is still broken")
	}

	// Nothing left to mend: 0x1888, the hammer kept.
	at, n := hammerSlot()
	write(OpUseItem, (&UseItemRequest{CharacterName: "Aria", InventorySlot: int32(at)}).Encode())
	res, err = DecodeUseItemResult(read().Data)
	if err != nil || res.Code != ErrNoItemToRepair || res.Error == "" {
		t.Fatalf("a hammer with nothing to mend: %+v, %v; want code 0x1888", res, err)
	}
	if _, after := hammerSlot(); after != n {
		t.Errorf("the refused hammer was spent: %d -> %d", n, after)
	}
}
