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
	// Round 877: worded by the client's own 0x186c key (MEASURED: the banner
	// and the system line say the level is too low).
	if got := equip(equipment.SlotHelm, 2); got != "UIIT_MSG_STRGERR_HIGHER_LEVEL_REQUIRED_TO_USE_THISITEM" {
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

// TestEquipTwoHandedClearsTheOtherHand (round 829): a two-handed weapon put
// on while a shield is worn takes the shield off into the bag, and a shield
// put on under a two-handed weapon takes the weapon off -- the original
// server's CGObjPC::AttachEquipItem (INFERRED), where ours used to refuse.
func TestEquipTwoHandedClearsTheOtherHand(t *testing.T) {
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
		{ID: 3632, MaxStack: 1, TypeID1: equipment.TypeItem, TypeID2: equipment.TypeEquipment, TypeID3: equipment.FamilyWeapon, TypeID4: 2,
			Country: equipment.CountryChina, ReqGender: equipment.ReqGenderAny},
		{ID: 3640, MaxStack: 1, TypeID1: equipment.TypeItem, TypeID2: equipment.TypeEquipment, TypeID3: equipment.FamilyWeapon, TypeID4: 5,
			Country: equipment.CountryChina, ReqGender: equipment.ReqGenderAny, TwoHanded: true},
		{ID: 3650, MaxStack: 1, TypeID1: equipment.TypeItem, TypeID2: equipment.TypeEquipment, TypeID3: equipment.FamilyShield, TypeID4: 1,
			Country: equipment.CountryChina, ReqGender: equipment.ReqGenderAny},
	}); err != nil {
		t.Fatalf("importing items: %v", err)
	}
	inv := inventory.NewMemStore(items)
	eq := equipment.NewMemStore(inv)
	// Bag 0 a sword, 1 a glaive (two-handed), 2 a shield.
	for _, id := range []int64{3632, 3640, 3650} {
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
	if lr, err := DecodeLoginResult(send(OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode()).Data); err != nil || !lr.OK {
		t.Fatalf("login failed: err=%v result=%+v", err, lr)
	}
	equip := func(slot equipment.Slot, bagSlot int) string {
		res, err := DecodeEquipmentResult(send(OpEquip, (&EquipRequest{CharacterName: "Aria", Slot: slot, InventorySlot: bagSlot}).Encode()).Data)
		if err != nil {
			t.Fatalf("DecodeEquipmentResult: %v", err)
		}
		return res.Error
	}
	worn := func() map[equipment.Slot]int64 {
		out := map[equipment.Slot]int64{}
		list, _ := eq.Get(ctx, c.ID)
		for _, w := range list {
			out[w.Slot] = w.ItemID
		}
		return out
	}
	bagHas := func(id int64) bool {
		slots, _ := inv.List(ctx, c.ID)
		for _, s := range slots {
			if s.ItemID == id {
				return true
			}
		}
		return false
	}
	if got := equip(equipment.SlotWeapon, 0); got != "" {
		t.Fatalf("the sword: %q", got)
	}
	if got := equip(equipment.SlotShield, 2); got != "" {
		t.Fatalf("the shield beside the sword: %q", got)
	}
	// The glaive (bag 1) for the sword: the shield comes off into the bag.
	if got := equip(equipment.SlotWeapon, 1); got != "" {
		t.Fatalf("the glaive over a shield: refused with %q", got)
	}
	if w := worn(); w[equipment.SlotWeapon] != 3640 || w[equipment.SlotShield] != 0 || !bagHas(3650) || !bagHas(3632) {
		t.Errorf("after the glaive: worn %v, shield in bag %v, sword in bag %v", w, bagHas(3650), bagHas(3632))
	}
	// The shield back on under the glaive: the glaive comes off.
	shieldAt := -1
	slots, _ := inv.List(ctx, c.ID)
	for _, s := range slots {
		if s.ItemID == 3650 {
			shieldAt = s.Index
		}
	}
	if got := equip(equipment.SlotShield, shieldAt); got != "" {
		t.Fatalf("the shield under a glaive: refused with %q", got)
	}
	if w := worn(); w[equipment.SlotShield] != 3650 || w[equipment.SlotWeapon] != 0 || !bagHas(3640) {
		t.Errorf("after the shield: worn %v, glaive in bag %v", w, bagHas(3640))
	}
}
