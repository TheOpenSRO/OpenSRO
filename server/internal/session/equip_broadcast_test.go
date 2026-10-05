package session

import (
	"bytes"
	"context"
	"testing"

	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/equipment"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/gm"
	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// The 0x3038 bytes, against the READ handlers: the server's 0x4e9de2 writes
// u32 uid, u8 slot, then CInstanceItem::vslot_010 mode 2's u32 RefItemID and
// u8 plus; the client's FUN_008a9260 reads exactly that. 0x3039 (0x4e9d03,
// FUN_008a9560) stops after the RefItemID.
func TestEquipBroadcastGoldenBytes(t *testing.T) {
	on := (&EquipBroadcast{UID: 0x11223344, Slot: 6, RefItemID: 0x0000_0e8f, Plus: 7, HasPlus: true}).Encode()
	want := []byte{0x44, 0x33, 0x22, 0x11, 0x06, 0x8f, 0x0e, 0x00, 0x00, 0x07}
	if !bytes.Equal(on, want) {
		t.Fatalf("0x3038 % x, want % x", on, want)
	}
	off := (&EquipBroadcast{UID: 0x11223344, Slot: 7, RefItemID: 0x1234}).Encode()
	want = []byte{0x44, 0x33, 0x22, 0x11, 0x07, 0x34, 0x12, 0x00, 0x00}
	if !bytes.Equal(off, want) {
		t.Fatalf("0x3039 % x, want % x", off, want)
	}
	back, err := DecodeEquipBroadcast(on)
	if err != nil || back.UID != 0x11223344 || back.Slot != 6 || back.RefItemID != 0xe8f || !back.HasPlus || back.Plus != 7 {
		t.Fatalf("round trip %+v (%v)", back, err)
	}
	if _, err := DecodeEquipBroadcast(off[:8]); err == nil {
		t.Fatal("a cut 0x3039 decoded")
	}
}

// The effective plus is OptLevel + the advanced elixir in a byte, as the
// server's mode-2 writer sums them.
func TestEffectivePlusSumsInAByte(t *testing.T) {
	if p := (equipment.Equipped{OptLevel: 7, AdvElixir: 3}).EffectivePlus(); p != 10 {
		t.Fatalf("7 + 3 = %d", p)
	}
	if p := (equipment.Equipped{OptLevel: 250, AdvElixir: 10}).EffectivePlus(); p != 4 {
		t.Fatalf("250 + 10 in a byte = %d, want 4", p)
	}
}

func plusSnapshot() EntitySnapshot {
	return EntitySnapshot{CharacterID: 9, Name: "Aria", X: 1, Y: 2, Z: 3, Gender: character.GenderChinaWoman,
		Equipped: []EquippedSnapshot{{Slot: 1, ItemID: 4842}, {Slot: 6, ItemID: 3727, Plus: 7}, {Slot: 7, ItemID: 3850, Plus: 13}}}
}

// OpEntityEntered: the pluses block follows the model, and an older decoder
// -- one that reads the snapshot, the angle and the model -- reads what it
// always did.
func TestEntityEnteredPlusesTail(t *testing.T) {
	s := plusSnapshot()
	s.RefObjID, s.Scale, s.HasModel = 1907, 0x44, true
	data := s.EncodeEntered()
	// The tail: count 2, slot 6 +7, slot 7 +13.
	if tail := data[len(data)-5:]; !bytes.Equal(tail, []byte{2, 6, 7, 7, 13}) {
		t.Fatalf("pluses tail % x", tail)
	}
	back, err := DecodeEntityEntered(data)
	if err != nil {
		t.Fatal(err)
	}
	if back.Equipped[0].Plus != 0 || back.Equipped[1].Plus != 7 || back.Equipped[2].Plus != 13 || back.RefObjID != 1907 {
		t.Fatalf("decoded %+v", back)
	}
	// The older decoder: the snapshot, two bytes of angle, five of model.
	_, rest, err := decodeEntitySnapshot(data)
	if err != nil || len(rest) != 2+5+5 {
		t.Fatalf("older decoder left %d bytes (%v)", len(rest), err)
	}
	// No model: a 0/0 one is written for the pluses after it, and read back
	// as no model.
	s.HasModel = false
	back, err = DecodeEntityEntered(s.EncodeEntered())
	if err != nil || back.HasModel || back.Equipped[1].Plus != 7 {
		t.Fatalf("no model: %+v (%v)", back, err)
	}
	// No plus anywhere: byte for byte the round-689 payload.
	s = plusSnapshot()
	for i := range s.Equipped {
		s.Equipped[i].Plus = 0
	}
	s.RefObjID, s.Scale, s.HasModel = 1907, 0x44, true
	if _, rest, _ := decodeEntitySnapshot(s.EncodeEntered()); len(rest) != 7 {
		t.Fatalf("a plus-less snapshot carries %d trailing bytes, want 7", len(rest))
	}
}

// EnterWorldResult and ChangeZoneResult: the pluses tail follows the models
// tail and forces it (and everything before it) written.
func TestResultsPlusesTail(t *testing.T) {
	plain := plusSnapshot()
	plain.Equipped = plain.Equipped[:1]
	others := []EntitySnapshot{plain, plusSnapshot()}

	r := &EnterWorldResult{OK: true, Zone: "jangan", Gender: character.GenderChinaMan, HP: 1, MaxHP: 1, Others: others}
	back, err := DecodeEnterWorldResult(r.Encode())
	if err != nil {
		t.Fatal(err)
	}
	if back.Others[1].Equipped[1].Plus != 7 || back.Others[1].Equipped[2].Plus != 13 || back.Others[0].Equipped[0].Plus != 0 {
		t.Fatalf("enter world pluses %+v", back.Others)
	}
	if !back.HasHeading || back.HasModel {
		t.Fatalf("forced tails: heading %v model %v", back.HasHeading, back.HasModel)
	}

	z := &ChangeZoneResult{OK: true, Zone: "jangan", Others: others}
	zb, err := DecodeChangeZoneResult(z.Encode())
	if err != nil {
		t.Fatal(err)
	}
	if zb.Others[1].Equipped[2].Plus != 13 {
		t.Fatalf("change zone pluses %+v", zb.Others)
	}

	// An older decoder (round 689's, which stops after the models tail) is
	// left exactly the pluses tail: 2 bytes of count, then 1 and 1+2*2.
	enc := z.Encode()
	if tail := enc[len(enc)-8:]; !bytes.Equal(tail, []byte{2, 0, 0, 2, 6, 7, 7, 13}) {
		t.Fatalf("change zone pluses tail % x", tail)
	}
}

// equipObservers: the others in the mover's zone, never the mover, never
// another zone.
func TestEquipObserversAreTheZone(t *testing.T) {
	hub := world.NewHub()
	hub.Enter(gateway.NewTestSession(1), 100, "a", 1, "jangan", world.Position{})
	hub.Enter(gateway.NewTestSession(2), 200, "b", 1, "jangan", world.Position{X: 500})
	hub.Enter(gateway.NewTestSession(3), 300, "c", 1, "donwhang", world.Position{})
	got := equipObservers(hub, 100)
	if len(got) != 1 || got[0].CharacterID != 200 {
		t.Fatalf("observers %+v, want only 200", got)
	}
	if equipObservers(hub, 999) != nil || equipObservers(nil, 100) != nil {
		t.Fatal("observers of a character not in the hub")
	}
}

// An equip, a plus change by the GM and an unequip, end to end: Bram, beside
// Aria, hears 0x3038 with the +7, 0x3038 with the +13, then 0x3039; Aria
// hears only her own equipment results.
func TestEquipBroadcastReachesObservers(t *testing.T) {
	ctx := context.Background()
	inv := inventory.NewMemStore(nil)
	eq := equipment.NewMemStore(inv)
	var aria int64
	f := startDeadWorldFixtureWith(t, func(chars character.Store, hub *world.Hub) gateway.Handler {
		deps := &gm.Deps{Chars: chars, Inv: inv, Equip: eq, World: hub}
		return gateway.Chain(
			EquipmentHandlerWithBroadcast(chars, eq, inv, nil, nil, hub),
			GMCommandHandler(chars, gm.ParseAccounts("alice"), deps, hub, nil))
	})
	aria = f.aria
	if err := inv.AddItemInstance(ctx, aria, 3727, 1, inventory.Instance{OptLevel: 7}); err != nil {
		t.Fatal(err)
	}
	expect := func(p *proto.Packet, op uint16, plus int) {
		t.Helper()
		if p.Opcode != op {
			t.Fatalf("Bram got %#04x, want %#04x", p.Opcode, op)
		}
		b, err := DecodeEquipBroadcast(p.Data)
		if err != nil || b.UID != uint32(aria) || b.Slot != uint8(equipment.SlotWeapon) || b.RefItemID != 3727 {
			t.Fatalf("Bram got %+v (%v)", b, err)
		}
		if (plus >= 0) != b.HasPlus || (plus >= 0 && int(b.Plus) != plus) {
			t.Fatalf("Bram's plus %+v, want %d", b, plus)
		}
	}
	slots, _ := inv.List(ctx, aria)
	f.send(t, f.connA, OpEquip, (&EquipRequest{CharacterName: "Aria", Slot: equipment.SlotWeapon, InventorySlot: slots[0].Index}).Encode())
	if p := f.read(t, f.connA, f.rA); p.Opcode != OpEquipmentResult {
		t.Fatalf("Aria got %#04x, want her equipment result", p.Opcode)
	}
	expect(f.read(t, f.connB, f.rB), OpEquipBroadcast, 7)

	f.send(t, f.connA, OpGMCommand, (&GMCommandRequest{Name: "Aria", Line: "/item worn 6 plus 13"}).Encode())
	if p := f.read(t, f.connA, f.rA); p.Opcode != OpGMCommandResult {
		t.Fatalf("Aria got %#04x, want the GM result", p.Opcode)
	}
	expect(f.read(t, f.connB, f.rB), OpEquipBroadcast, 13)

	f.send(t, f.connA, OpUnequip, (&UnequipRequest{CharacterName: "Aria", Slot: equipment.SlotWeapon}).Encode())
	if p := f.read(t, f.connA, f.rA); p.Opcode != OpEquipmentResult {
		t.Fatalf("Aria got %#04x, want her equipment result", p.Opcode)
	}
	expect(f.read(t, f.connB, f.rB), OpUnequipBroadcast, -1)
	if !f.nothing(t, f.connA, f.rA) {
		t.Fatal("Aria heard her own change")
	}
}

// The snapshots that show other players take each worn item's effective
// plus from the store.
func TestEquippedItemsCarryEffectivePlus(t *testing.T) {
	ctx := context.Background()
	inv := inventory.NewMemStore(nil)
	eq := equipment.NewMemStore(inv)
	if err := inv.AddItemInstance(ctx, 1, 3727, 1, inventory.Instance{OptLevel: 7, AdvElixir: 2}); err != nil {
		t.Fatal(err)
	}
	slots, _ := inv.List(ctx, 1)
	if err := eq.Equip(ctx, 1, equipment.SlotWeapon, slots[0].Index); err != nil {
		t.Fatal(err)
	}
	got := equippedItems(ctx, eq, 1)
	if len(got) != 1 || got[0].Plus != 9 {
		t.Fatalf("equippedItems %+v, want the weapon at +9", got)
	}
}
