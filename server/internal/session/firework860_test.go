package session

import (
	"bufio"
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

// Round 860: a firework (3/3/6/1) is accepted as CGItemExpendable::DoJob's
// TypeID3 6 case accepts it (s:0x49ae83..0x49aeb5, READ): one is spent, the
// user gets her 0xB04C, and both she and the player beside her get the 0x305C
// that makes every client draw it. The fortress shock bomb (3/3/6/2, slot
// 0x524) stays refused, and nobody hears of it.
func TestFireworkIsUsedAndAnnounced(t *testing.T) {
	ctx := context.Background()
	const firework, shockBomb = 3834, 10593
	rows := []refdata.Item{
		{ID: firework, CodeName: "ITEM_ETC_FIREWORK_STAR_SHOWER", MaxStack: 10, TypeID1: 3, TypeID2: 3, TypeID3: 6, TypeID4: 1, CanUse: true},
		{ID: shockBomb, CodeName: "ITEM_FORT_SHOCK_BOMB", MaxStack: 10, TypeID1: 3, TypeID2: 3, TypeID3: 6, TypeID4: 2, CanUse: true},
	}
	items := refdata.NewMemStore()
	if err := items.ImportItems(ctx, rows); err != nil {
		t.Fatal(err)
	}
	inv := inventory.NewMemStore(items)
	f := startDeadWorldFixtureWith(t, func(chars character.Store, hub *world.Hub) gateway.Handler {
		return UseItemHandler(chars, inv, items, mana.NewTracker(), nil, nil, hub, nil, nil, nil, nil)
	})
	for _, id := range []int64{firework, shockBomb} {
		if err := inv.AddItem(ctx, f.aria, id, 3); err != nil {
			t.Fatal(err)
		}
	}
	slotOf := func(id int64) (int32, int) {
		slots, _ := inv.List(ctx, f.aria)
		for _, s := range slots {
			if s.ItemID == id {
				return int32(s.Index), s.Quantity
			}
		}
		return -1, 0
	}
	use := func(id int64) *UseItemResult {
		t.Helper()
		slot, _ := slotOf(id)
		f.send(t, f.connA, OpUseItem, (&UseItemRequest{CharacterName: "Aria", InventorySlot: slot}).Encode())
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
	expectEffect := func(conn net.Conn, r *bufio.Reader, who string) {
		t.Helper()
		p := f.read(t, conn, r)
		if p.Opcode != OpItemUseEffect {
			t.Fatalf("%s got %#04x, want 0x305C", who, p.Opcode)
		}
		m, err := DecodeItemUseEffect(p.Data)
		if err != nil || m.UID != uint32(f.aria) || m.RefItemID != firework {
			t.Fatalf("%s got %+v (%v), want Aria's uid and the firework", who, m, err)
		}
	}

	r := use(firework)
	if r.Error != "" {
		t.Fatalf("the firework was refused: %q", r.Error)
	}
	if r.Remaining != 2 {
		t.Fatalf("the reply says %d left, want 2", r.Remaining)
	}
	if _, n := slotOf(firework); n != 2 {
		t.Fatalf("the bag holds %d fireworks after one use, want 2", n)
	}
	expectEffect(f.connA, f.rA, "Aria")
	expectEffect(f.connB, f.rB, "Bram")

	// No reuse delay (no COOLTIME descriptor): the next one goes at once.
	if r := use(firework); r.Error != "" {
		t.Fatalf("a second firework was refused: %q", r.Error)
	}
	expectEffect(f.connA, f.rA, "Aria")
	expectEffect(f.connB, f.rB, "Bram")

	if r := use(shockBomb); r.Error == "" {
		t.Fatal("the fortress shock bomb was accepted")
	}
	if _, n := slotOf(shockBomb); n != 3 {
		t.Fatalf("the refused shock bomb was spent: %d left", n)
	}
	if !f.nothing(t, f.connA, f.rA) || !f.nothing(t, f.connB, f.rB) {
		t.Fatal("a refused use was broadcast")
	}
}
