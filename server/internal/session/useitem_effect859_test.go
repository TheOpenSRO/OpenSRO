package session

import (
	"bufio"
	"bytes"
	"context"
	"net"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/mana"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Round 859: 0x305C is retail's two u32s, the user's uid then the RefItemID
// (Item_HandleUseItem s:0x5110a0..0x5110b4, READ).
func TestItemUseEffectGoldenBytes(t *testing.T) {
	m := &ItemUseEffect{UID: 0x01020304, RefItemID: 55}
	want := []byte{0x04, 0x03, 0x02, 0x01, 55, 0, 0, 0}
	if got := m.Encode(); !bytes.Equal(got, want) {
		t.Fatalf("encoded % x, want % x", got, want)
	}
	back, err := DecodeItemUseEffect(want)
	if err != nil || *back != *m {
		t.Fatalf("decoded %+v (%v), want %+v", back, err, m)
	}
	if _, err := DecodeItemUseEffect(want[:7]); err == nil {
		t.Fatal("a short payload decoded")
	}
}

// Round 859: an accepted use reaches the user and the player beside her as a
// 0x305C, after her own reply (retail sends 0xB04C first); a refused use sends
// none. Aria drinks an HP potion (ITEM_ETC_HP_POTION_01, 4, 3/3/1/1) and a
// universal pill (ITEM_ETC_CURE_ALL_01, 55, 3/3/2/6); then a potion whose
// re-use lock is still armed is refused and nobody hears of it.
func TestAcceptedUseIsBroadcastAsItemUseEffect(t *testing.T) {
	ctx := context.Background()
	const hpPotion = 4
	rows := append(curePillRows(), refdata.Item{ID: hpPotion, CodeName: "ITEM_ETC_HP_POTION_01", MaxStack: 50,
		TypeID1: 3, TypeID2: 3, TypeID3: 1, TypeID4: 1, RestoreHP: 120, CanUse: true})
	items := refdata.NewMemStore()
	if err := items.ImportItems(ctx, rows); err != nil {
		t.Fatal(err)
	}
	inv := inventory.NewMemStore(items)
	f := startDeadWorldFixtureWith(t, func(chars character.Store, hub *world.Hub) gateway.Handler {
		return UseItemHandler(chars, inv, items, mana.NewTracker(), nil, nil, hub, nil, nil, nil, nil)
	})
	for _, id := range []int64{hpPotion, pillUniversal} {
		if err := inv.AddItem(ctx, f.aria, id, 5); err != nil {
			t.Fatal(err)
		}
	}
	slotOf := func(id int64) int32 {
		slots, _ := inv.List(ctx, f.aria)
		for _, s := range slots {
			if s.ItemID == id {
				return int32(s.Index)
			}
		}
		t.Fatalf("no stack of %d", id)
		return -1
	}
	use := func(id int64) *UseItemResult {
		t.Helper()
		f.send(t, f.connA, OpUseItem, (&UseItemRequest{CharacterName: "Aria", InventorySlot: slotOf(id)}).Encode())
		p := f.read(t, f.connA, f.rA)
		if p.Opcode != OpUseItemResult {
			t.Fatalf("Aria got %#04x before her reply", p.Opcode)
		}
		r, err := DecodeUseItemResult(p.Data)
		if err != nil {
			t.Fatal(err)
		}
		return r
	}
	expectEffect := func(conn net.Conn, r *bufio.Reader, ref int64, who string) {
		t.Helper()
		p := f.read(t, conn, r)
		if p.Opcode != OpItemUseEffect {
			t.Fatalf("%s got %#04x, want 0x305C", who, p.Opcode)
		}
		m, err := DecodeItemUseEffect(p.Data)
		if err != nil || m.UID != uint32(f.aria) || m.RefItemID != uint32(ref) {
			t.Fatalf("%s got %+v (%v), want Aria's uid %d and item %d", who, m, err, uint32(f.aria), ref)
		}
	}

	if r := use(hpPotion); r.Error != "" {
		t.Fatalf("the potion was refused: %q", r.Error)
	}
	expectEffect(f.connA, f.rA, hpPotion, "Aria")
	expectEffect(f.connB, f.rB, hpPotion, "Bram")

	if r := use(pillUniversal); r.Error != "" {
		t.Fatalf("the pill was refused: %q", r.Error)
	}
	expectEffect(f.connA, f.rA, pillUniversal, "Aria")
	expectEffect(f.connB, f.rB, pillUniversal, "Bram")

	// The HP potion's own lock (potionReuseBit) is armed: refused, no 0x305C.
	if r := use(hpPotion); r.Error == "" {
		t.Fatal("a second potion inside its lock was accepted")
	}
	if !f.nothing(t, f.connA, f.rA) || !f.nothing(t, f.connB, f.rB) {
		t.Fatal("a refused use was broadcast")
	}
}
