package inventory

import (
	"context"
	"testing"

	"github.com/OpenSRO/OpenSRO/server/internal/durability"
)

// a lookup that gives one item id a durability range and everything else none.
type durLookup struct {
	id       int64
	min, max float64
}

func (d durLookup) DurabilityRange(_ context.Context, itemID int64) (float64, float64, bool, error) {
	if itemID == d.id {
		return d.min, d.max, true, nil
	}
	return 0, 0, false, nil
}

func (d durLookup) GetMaxStack(_ context.Context, _ int64) (int, error) { return 1, nil }

func TestFreshItemRollsDurability(t *testing.T) {
	ctx := context.Background()
	look := durLookup{id: 100, min: 62, max: 76}
	m := NewMemStore(look)
	m.SetDurabilityLookup(look)

	if err := m.AddItem(ctx, 1, 100, 1); err != nil { // a sword: has a range
		t.Fatalf("AddItem sword: %v", err)
	}
	if err := m.AddItem(ctx, 1, 200, 1); err != nil { // a potion: no range
		t.Fatalf("AddItem potion: %v", err)
	}
	slots, err := m.List(ctx, 1)
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	byItem := map[int64]Slot{}
	for _, s := range slots {
		byItem[s.ItemID] = s
	}
	sword := byItem[100]
	if sword.Durability < 62 || sword.Durability > 76 {
		t.Errorf("sword durability %d, want in [62,76]", sword.Durability)
	}
	if sword.Durability != durability.MaxDurability(62, 76, sword.Variance) {
		t.Errorf("a fresh item starts at its max: got %d, max %d", sword.Durability, durability.MaxDurability(62, 76, sword.Variance))
	}
	if byItem[200].Durability != durability.Untracked {
		t.Errorf("an item with no range is Untracked, got %d", byItem[200].Durability)
	}
}

func TestAddItemInstancePreservesInstance(t *testing.T) {
	ctx := context.Background()
	look := durLookup{id: 100, min: 62, max: 76}
	m := NewMemStore(look)
	m.SetDurabilityLookup(look)
	inst := Instance{Variance: 0x1234, Durability: 40}
	if err := m.AddItemInstance(ctx, 1, 100, 1, inst); err != nil {
		t.Fatalf("AddItemInstance: %v", err)
	}
	slots, _ := m.List(ctx, 1)
	if slots[0].Durability != 40 || slots[0].Variance != 0x1234 {
		t.Errorf("instance not preserved: got dur %d var %#x, want 40 / 0x1234", slots[0].Durability, slots[0].Variance)
	}
}

func TestSetDurability(t *testing.T) {
	ctx := context.Background()
	look := durLookup{id: 100, min: 62, max: 76}
	m := NewMemStore(look)
	m.SetDurabilityLookup(look)
	m.AddItem(ctx, 1, 100, 1)
	if err := m.SetDurability(ctx, 1, 0, 5); err != nil {
		t.Fatalf("SetDurability: %v", err)
	}
	slots, _ := m.List(ctx, 1)
	if slots[0].Durability != 5 {
		t.Errorf("durability after set = %d, want 5", slots[0].Durability)
	}
	if err := m.SetDurability(ctx, 1, 40, 5); err != ErrSlotEmpty {
		t.Errorf("SetDurability on an empty slot = %v, want ErrSlotEmpty", err)
	}
}

// A legacy row (added before the lookup was set) reads as Untracked from a
// store with no lookup, and gets a real instance once one is present.
func TestLegacyRowInitialisedOnRead(t *testing.T) {
	ctx := context.Background()
	look := durLookup{id: 100, min: 62, max: 76}
	m := NewMemStore(look) // no durability lookup yet
	if err := m.AddItem(ctx, 1, 100, 1); err != nil {
		t.Fatalf("AddItem: %v", err)
	}
	slots, _ := m.List(ctx, 1)
	if slots[0].Durability != durability.Untracked {
		t.Fatalf("without a lookup the item is Untracked, got %d", slots[0].Durability)
	}
	m.SetDurabilityLookup(look)
	slots, _ = m.List(ctx, 1)
	if slots[0].Durability < 62 || slots[0].Durability > 76 {
		t.Errorf("legacy row not initialised on read: durability %d", slots[0].Durability)
	}
}
