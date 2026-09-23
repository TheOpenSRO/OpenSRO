package session

import (
	"bufio"
	"context"
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/account"
	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/equipment"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/inventory"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/refdata"
)

func TestEquipRequestRoundTrip(t *testing.T) {
	want := &EquipRequest{CharacterName: "Aria", Slot: equipment.SlotWeapon, InventorySlot: 3}
	got, err := DecodeEquipRequest(want.Encode())
	if err != nil {
		t.Fatalf("DecodeEquipRequest: %v", err)
	}
	if *got != *want {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

func TestEquipmentResultRoundTrip(t *testing.T) {
	want := &EquipmentResult{Items: []EquippedSnapshot{{Slot: 0, ItemID: 100}}}
	got, err := DecodeEquipmentResult(want.Encode())
	if err != nil {
		t.Fatalf("DecodeEquipmentResult: %v", err)
	}
	if len(got.Items) != 1 || got.Items[0] != want.Items[0] {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

// TestEquipmentFullFlow logs in, creates a character, gives it an item via
// inventory, equips it, confirms via OpEquipmentList, then unequips and
// confirms the item is back in the inventory -- all through the real
// server stack over TCP.
func TestEquipmentFullFlow(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("creating character: %v", err)
	}

	invStore, err := inventory.OpenSQLStore(inventoryTestDSN(), stubMaxStacks{100: 1})
	if err != nil {
		t.Fatalf("inventory.OpenSQLStore: %v (is postgres running?)", err)
	}
	defer invStore.Close()
	if err := invStore.TruncateForTest(ctx); err != nil {
		t.Fatalf("truncating inventory: %v", err)
	}
	if err := invStore.AddItem(ctx, c.ID, 100, 1); err != nil {
		t.Fatalf("seeding inventory: %v", err)
	}

	eqStore, err := equipment.OpenSQLStore(inventoryTestDSN(), invStore)
	if err != nil {
		t.Fatalf("equipment.OpenSQLStore: %v", err)
	}
	defer eqStore.Close()
	if err := eqStore.TruncateForTest(ctx); err != nil {
		t.Fatalf("truncating equipment: %v", err)
	}

	handle := gateway.Chain(LoginHandler(accounts), EquipmentHandler(chars, eqStore))
	addr, cleanup := startTestServer(t, handle)
	defer cleanup()

	conn := dialTestServer(t, addr)
	defer conn.Close()
	r := bufio.NewReader(conn)

	send := func(opcode uint16, data []byte) *proto.Packet {
		if err := proto.Write(conn, &proto.Packet{Opcode: opcode, Data: data}, nil, nil); err != nil {
			t.Fatalf("Write: %v", err)
		}
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		resp, err := proto.Read(r, nil, nil)
		if err != nil {
			t.Fatalf("Read: %v", err)
		}
		return resp
	}

	resp := send(OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode())
	if lr, err := DecodeLoginResult(resp.Data); err != nil || !lr.OK {
		t.Fatalf("login failed: err=%v result=%+v", err, lr)
	}

	resp = send(OpEquip, (&EquipRequest{CharacterName: "Aria", Slot: equipment.SlotWeapon, InventorySlot: 0}).Encode())
	eqResult, err := DecodeEquipmentResult(resp.Data)
	if err != nil || eqResult.Error != "" {
		t.Fatalf("equip failed: err=%v result=%+v", err, eqResult)
	}

	resp = send(OpEquipmentList, (&CharacterNameRequest{Name: "Aria"}).Encode())
	listResult, err := DecodeEquipmentResult(resp.Data)
	if err != nil {
		t.Fatalf("DecodeEquipmentResult: %v", err)
	}
	if len(listResult.Items) != 1 || listResult.Items[0].ItemID != 100 {
		t.Fatalf("got %+v, want weapon slot with item 100", listResult.Items)
	}

	resp = send(OpUnequip, (&UnequipRequest{CharacterName: "Aria", Slot: equipment.SlotWeapon}).Encode())
	unequipResult, err := DecodeEquipmentResult(resp.Data)
	if err != nil || unequipResult.Error != "" {
		t.Fatalf("unequip failed: err=%v result=%+v", err, unequipResult)
	}

	invList, err := invStore.List(ctx, c.ID)
	if err != nil {
		t.Fatalf("inv.List: %v", err)
	}
	if len(invList) != 1 || invList[0].ItemID != 100 {
		t.Fatalf("expected item back in inventory after unequip, got %+v", invList)
	}
}

// TestEquipRefusesWhatTheItemTableForbids exercises the wearing rules
// through the handler: a woman's suit on a man, a suit in the helm slot,
// and an item above the character's level are all refused with a reason,
// while the Cotton Suit a level-1 man may wear goes on -- and an item the
// reference data does not know is refused too, because a typed slot needs
// an item positively shown to belong in it.
func TestEquipRefusesWhatTheItemTableForbids(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("creating character: %v", err)
	}

	items := refdata.NewMemStore()
	if err := items.ImportItems(ctx, []refdata.Item{
		{ID: 4842, MaxStack: 1, TypeID1: equipment.TypeItem, TypeID2: equipment.TypeEquipment, TypeID3: equipment.FamilyChinaGarment, TypeID4: equipment.PieceMail,
			Country: equipment.CountryChina, ReqGender: equipment.ReqGenderMan, ReqLevelType1: equipment.ReqLevelTypeCharacter, ReqLevel1: 1},
		{ID: 3652, MaxStack: 1, TypeID1: equipment.TypeItem, TypeID2: equipment.TypeEquipment, TypeID3: equipment.FamilyChinaGarment, TypeID4: equipment.PieceMail,
			Country: equipment.CountryChina, ReqGender: equipment.ReqGenderWoman, ReqLevelType1: equipment.ReqLevelTypeCharacter, ReqLevel1: 1},
		{ID: 4796, MaxStack: 1, TypeID1: equipment.TypeItem, TypeID2: equipment.TypeEquipment, TypeID3: equipment.FamilyChinaGarment, TypeID4: equipment.PieceHelm,
			Country: equipment.CountryChina, ReqGender: equipment.ReqGenderMan, ReqLevelType1: equipment.ReqLevelTypeCharacter, ReqLevel1: 79},
		// The real HP potion (ITEM_ETC_HP_POTION_01, id 4): TypeID2 is the
		// ETC/consumable family, not equipment. Reported from a live session
		// worn in an armour slot -- a consumable must never be equippable.
		{ID: 4, MaxStack: 5000, TypeID1: equipment.TypeItem, TypeID2: 3, TypeID3: 1, TypeID4: 1,
			Country: equipment.CountryChina},
	}); err != nil {
		t.Fatalf("importing items: %v", err)
	}
	inv := inventory.NewMemStore(items)
	eq := equipment.NewMemStore(inv)
	// Slot 0 the man's suit, 1 the woman's, 2 the level-79 hood, 3 an id
	// with no reference row at all, 4 an HP potion.
	for _, id := range []int64{4842, 3652, 4796, 900001, 4} {
		if err := inv.AddItem(ctx, c.ID, id, 1); err != nil {
			t.Fatalf("seeding item %d: %v", id, err)
		}
	}

	handle := gateway.Chain(LoginHandler(accounts), EquipmentHandlerWithRules(chars, eq, inv, items, nil))
	addr, cleanup := startTestServer(t, handle)
	defer cleanup()
	conn := dialTestServer(t, addr)
	defer conn.Close()
	r := bufio.NewReader(conn)
	send := func(opcode uint16, data []byte) *proto.Packet {
		if err := proto.Write(conn, &proto.Packet{Opcode: opcode, Data: data}, nil, nil); err != nil {
			t.Fatalf("Write: %v", err)
		}
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		resp, err := proto.Read(r, nil, nil)
		if err != nil {
			t.Fatalf("Read: %v", err)
		}
		return resp
	}
	resp := send(OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode())
	if lr, err := DecodeLoginResult(resp.Data); err != nil || !lr.OK {
		t.Fatalf("login failed: err=%v result=%+v", err, lr)
	}
	equip := func(slot equipment.Slot, inventorySlot int) string {
		resp := send(OpEquip, (&EquipRequest{CharacterName: "Aria", Slot: slot, InventorySlot: inventorySlot}).Encode())
		res, err := DecodeEquipmentResult(resp.Data)
		if err != nil {
			t.Fatalf("DecodeEquipmentResult: %v", err)
		}
		return res.Error
	}

	if got := equip(equipment.SlotMail, 1); got != "that is for the other gender" {
		t.Errorf("a woman's suit on a man: got %q", got)
	}
	if got := equip(equipment.SlotHelm, 0); got != "that does not go in that slot" {
		t.Errorf("a suit in the helm slot: got %q", got)
	}
	if got := equip(equipment.SlotHelm, 2); got != "your level is too low" {
		t.Errorf("a level-79 hood at level 1: got %q", got)
	}
	if got := equip(equipment.SlotMail, 0); got != "" {
		t.Errorf("the Cotton Suit on a level-1 man: refused with %q", got)
	}
	// An item the reference data does not know is REFUSED. Removal frees the
	// index without compacting, so the unknown id is still at index 3.
	// This used to equip ("unknown" was read as "not forbidden"), which is
	// how an HP potion ended up worn in an armour slot on a server whose
	// refdata lacked the ETC consumables -- a slot is typed, so an item has
	// to be positively shown to belong in it.
	if got := equip(equipment.SlotWeapon, 3); got != "that cannot be equipped" {
		t.Errorf("an item with no reference row: got %q, want refusal", got)
	}
	// The reported bug: an HP potion is a consumable, not armour.
	if got := equip(equipment.SlotMail, 4); got != "that cannot be equipped" {
		t.Errorf("an HP potion in the mail slot: got %q, want refusal", got)
	}
	if got := equip(equipment.SlotWeapon, 4); got != "that cannot be equipped" {
		t.Errorf("an HP potion in the weapon slot: got %q, want refusal", got)
	}
}
