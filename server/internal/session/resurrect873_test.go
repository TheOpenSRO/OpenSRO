package session

import (
	"context"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/mana"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// TestResurrectionScrollInsideALayer (round 873): a resurrection scroll used
// from the bag while dead inside an instanced world revives the character
// where it lies, in the layer (MEASURED: the same spot, the same layer, full
// pools with a 100 % scroll), and spends one. Alive, it is refused with
// 0x1887's line; any other item is refused while dead.
func TestResurrectionScrollInsideALayer(t *testing.T) {
	ctx := context.Background()
	items := refdata.NewMemStore()
	scroll := refdata.Item{ID: 8731, CodeName: "ITEM_MALL_RESURRECTION_100P_SCROLL", TypeID1: equipment.TypeItem,
		TypeID2: equipment.TypeExpendable, TypeID3: 13, TypeID4: 6, CanUse: true, MaxStack: 50, RestoreHPPct: 100, RestoreMP: 100}
	potion := refdata.Item{ID: 8732, CodeName: "ITEM_ETC_HP_POTION_01", TypeID1: equipment.TypeItem,
		TypeID2: equipment.TypeExpendable, TypeID3: 1, TypeID4: 1, CanUse: true, MaxStack: 50, RestoreHP: 100}
	if err := items.ImportItems(ctx, []refdata.Item{scroll, potion}); err != nil {
		t.Fatal(err)
	}
	inv := inventory.NewMemStore(items)
	tracker := mana.NewTracker()
	gwRigExtra = func(rig *gwRig) []gateway.Handler {
		return []gateway.Handler{UseItemHandler(rig.chars, inv, items, tracker, nil, nil, rig.hub, nil, nil, nil, nil)}
	}
	rig := newGWRig(t, nil, map[string]int{"Aria": 40})
	gwRigExtra = nil
	SetResurrectDeps(RegenDeps{Mana: tracker})
	t.Cleanup(func() { SetResurrectDeps(RegenDeps{}) })
	aria := rig.players["Aria"]
	for _, id := range []int64{scroll.ID, potion.ID} {
		if err := inv.AddItem(ctx, aria.charID, id, 2); err != nil {
			t.Fatal(err)
		}
	}
	slotOf := func(id int64) (int, int) {
		slots, _ := inv.List(ctx, aria.charID)
		for _, sl := range slots {
			if sl.ItemID == id {
				return sl.Index, sl.Quantity
			}
		}
		return -1, 0
	}
	w := rig.open(t)
	if err := EnterInstance(ctx, aria.sess, w, "test"); err != nil {
		t.Fatal(err)
	}
	rig.until("Aria", OpChangeZoneResult)
	use := func(id int64) *UseItemResult {
		t.Helper()
		slot, _ := slotOf(id)
		rig.send("Aria", OpUseItem, (&UseItemRequest{CharacterName: "Aria", InventorySlot: int32(slot)}).Encode())
		r, err := DecodeUseItemResult(rig.until("Aria", OpUseItemResult).Data)
		if err != nil {
			t.Fatal(err)
		}
		return r
	}
	if r := use(scroll.ID); r.Error != resurrectionOnlyDeadRefusal {
		t.Errorf("alive: %+v, want %q", r, resurrectionOnlyDeadRefusal)
	}
	before, _ := w.Hub.EntityByCharacterID(aria.charID)
	if _, _, err := rig.chars.ApplyDamage(ctx, aria.charID, 1<<30); err != nil {
		t.Fatal(err)
	}
	w.Hub.SetLifeState(aria.charID, world.LifeAlive, world.LifeDead, time.Now())
	if r := use(potion.ID); r.Error != deadRefusal {
		t.Errorf("a potion while dead: %+v, want %q", r, deadRefusal)
	}
	if r := use(scroll.ID); r.Error != "" || r.Remaining != 1 {
		t.Fatalf("the scroll while dead: %+v, want accepted with 1 left", r)
	}
	res, err := DecodeReviveResult(rig.until("Aria", OpReviveResult).Data)
	if err != nil || res.Error != "" {
		t.Fatalf("revive result %+v %v", res, err)
	}
	c, _ := rig.chars.GetByID(ctx, aria.charID)
	if res.HP != int32(c.MaxHP()) || c.HP != c.MaxHP() {
		t.Errorf("HP %d (stored %d), want full %d", res.HP, c.HP, c.MaxHP())
	}
	after, in := w.Hub.EntityByCharacterID(aria.charID)
	if !in || after.Life != world.LifeAlive || after.Pos != before.Pos {
		t.Errorf("after the scroll: in the layer %v, life %d, at %+v, want alive on %+v", in, after.Life, after.Pos, before.Pos)
	}
	if _, q := slotOf(scroll.ID); q != 1 {
		t.Errorf("%d scroll(s) left, want 1", q)
	}
}
