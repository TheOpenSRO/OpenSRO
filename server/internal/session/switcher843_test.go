package session

import (
	"bytes"
	"context"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gm"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Round 843 (OURS): a 0x3038 of an item drawn as a model switcher's row
// carries the item's own id after the plus; every other 0x3038 is retail's
// bytes (TestEquipBroadcastGoldenBytes).
func TestRound843EquipBroadcastOwnTrailer(t *testing.T) {
	b := &EquipBroadcast{UID: 0x11223344, Slot: 6, RefItemID: 62220, Plus: 12, HasPlus: true, Own: 62652}
	got := b.Encode()
	want := []byte{0x44, 0x33, 0x22, 0x11, 0x06, 0x0c, 0xf3, 0x00, 0x00, 0x0c, 0xbc, 0xf4, 0x00, 0x00}
	if !bytes.Equal(got, want) {
		t.Fatalf("0x3038 % x, want % x", got, want)
	}
	back, err := DecodeEquipBroadcast(got)
	if err != nil || back.RefItemID != 62220 || back.Plus != 12 || back.Own != 62652 {
		t.Fatalf("round trip %+v (%v)", back, err)
	}
	// No model, or the model is the item itself: retail's ten bytes.
	for _, own := range []uint32{0, 62220} {
		plain := (&EquipBroadcast{UID: 1, Slot: 6, RefItemID: 62220, Plus: 12, HasPlus: true, Own: own}).Encode()
		if len(plain) != 10 {
			t.Errorf("Own %d: %d bytes, want 10", own, len(plain))
		}
	}
	// A 0x3039 never carries it.
	if off := (&EquipBroadcast{UID: 1, Slot: 6, RefItemID: 62220, Own: 62652}).Encode(); len(off) != 9 {
		t.Errorf("0x3039 %d bytes", len(off))
	}
	if switchedOwn(62652, 0) != 0 || switchedOwn(62652, 62220) != 62652 || switchedOwn(62652, 62652) != 0 {
		t.Error("switchedOwn")
	}
}

// The spawn record names the model's row (round 838); the spawn's after
// frames add a 0x3038 with the item's own id for that slot, and none for a
// character with no switched item.
func TestRound843SpawnFollowsWithOwnID(t *testing.T) {
	ctx := context.Background()
	SetSpawnItemRefs(nil)
	inv := inventory.NewMemStore(nil)
	eq := equipment.NewMemStore(inv)
	chars := character.NewMemStore()
	c, _ := chars.Create(ctx, 1, "Switched")
	plain, _ := chars.Create(ctx, 1, "Plain")
	// The user's own item (prod, MEASURED): ITEM_EU_TSWORD_11_A_RARE_ACTIVE
	// 62652 +12 with model ITEM_EU_TSWORD_11_A_RARE_SWITCH13 62220.
	if err := inv.AddItemInstance(ctx, c.ID, 62652, 1, inventory.Instance{OptLevel: 12, Model: 62220}); err != nil {
		t.Fatal(err)
	}
	if err := inv.AddItemInstance(ctx, plain.ID, 62652, 1, inventory.Instance{OptLevel: 12}); err != nil {
		t.Fatal(err)
	}
	for _, id := range []int64{c.ID, plain.ID} {
		slots, _ := inv.List(ctx, id)
		if err := eq.Equip(ctx, id, equipment.SlotWeapon, slots[0].Index); err != nil {
			t.Fatal(err)
		}
		invalidateLook(id)
		t.Cleanup(func() { invalidateLook(id) })
	}
	d := viewDeps{ctx: ctx, eq: eq, chars: chars}
	lk := lookOf(ctx, d, c.ID)
	if len(lk.items) != 1 || lk.items[0].RefItemID != 62220 || lk.items[0].Plus != 12 {
		t.Fatalf("the record's items %+v, want the model 62220 at +12", lk.items)
	}
	frames := switchedWornFrames(d, c.ID)
	if len(frames) != 1 {
		t.Fatalf("%d after frames, want 1", len(frames))
	}
	b, err := DecodeEquipBroadcast(frames[0].Payload())
	if err != nil || frames[0].Opcode() != OpEquipBroadcast || b.UID != uint32(c.ID) || b.Slot != uint8(equipment.SlotWeapon) ||
		b.RefItemID != 62220 || b.Plus != 12 || b.Own != 62652 {
		t.Fatalf("after frame %+v (%v)", b, err)
	}
	if n := len(switchedWornFrames(d, plain.ID)); n != 0 {
		t.Errorf("a character with no switched item: %d after frames", n)
	}
}

// Equipping a switched item tells the observers the model's row and the
// item's own id; a re-equip after the Default switcher tells them retail's
// bytes again.
func TestRound843EquipBroadcastCarriesOwn(t *testing.T) {
	ctx := context.Background()
	inv := inventory.NewMemStore(nil)
	eq := equipment.NewMemStore(inv)
	f := startDeadWorldFixtureWith(t, func(chars character.Store, hub *world.Hub) gateway.Handler {
		deps := &gm.Deps{Chars: chars, Inv: inv, Equip: eq, World: hub}
		return gateway.Chain(
			EquipmentHandlerWithBroadcast(chars, eq, inv, nil, nil, hub),
			GMCommandHandler(chars, gm.ParseAccounts("alice"), deps, hub, nil))
	})
	if err := inv.AddItemInstance(ctx, f.aria, 62652, 1, inventory.Instance{OptLevel: 12, Model: 62220}); err != nil {
		t.Fatal(err)
	}
	slots, _ := inv.List(ctx, f.aria)
	f.send(t, f.connA, OpEquip, (&EquipRequest{CharacterName: "Aria", Slot: equipment.SlotWeapon, InventorySlot: slots[0].Index}).Encode())
	if p := f.read(t, f.connA, f.rA); p.Opcode != OpEquipmentResult {
		t.Fatalf("Aria got %#04x, want her equipment result", p.Opcode)
	}
	_ = f.read(t, f.connA, f.rA) // her own 0x3038
	p := f.read(t, f.connB, f.rB)
	b, err := DecodeEquipBroadcast(p.Data)
	if p.Opcode != OpEquipBroadcast || err != nil || b.RefItemID != 62220 || b.Plus != 12 || b.Own != 62652 {
		t.Fatalf("Bram got %#04x %+v (%v)", p.Opcode, b, err)
	}
}
