package session

import "testing"

// The warehouse list carries its capacity after the durability block, so a
// client that stops at the block still reads the list and a new one reads the
// capacity -- whether or not any durability entries were sent.
func TestStorageListResultCarriesCapacityAfterTheDurabilityBlock(t *testing.T) {
	cases := []struct {
		name   string
		result StorageListResult
	}{
		{"no slots, no durabilities", StorageListResult{Capacity: 50}},
		{"slots without durabilities", StorageListResult{
			InventoryListResult: InventoryListResult{Slots: []InventorySlotSnapshot{{Slot: 2, ItemID: 3645, Quantity: 1}, {Slot: 31, ItemID: 10, Quantity: 7}}},
			Capacity:            112,
		}},
		{"slots with durabilities", StorageListResult{
			InventoryListResult: InventoryListResult{
				Slots:        []InventorySlotSnapshot{{Slot: 2, ItemID: 3645, Quantity: 1}},
				Durabilities: []DurabilitySnapshot{{Slot: 2, Durability: 40, MaxDurability: 62}},
			},
			Capacity: 50,
		}},
		{"an error and no capacity of note", StorageListResult{InventoryListResult: InventoryListResult{Error: "not authenticated"}}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			data := c.result.Encode()
			got, err := DecodeStorageListResult(data)
			if err != nil {
				t.Fatalf("decode: %v", err)
			}
			if got.Capacity != c.result.Capacity {
				t.Errorf("capacity %d, want %d", got.Capacity, c.result.Capacity)
			}
			if got.Error != c.result.Error || len(got.Slots) != len(c.result.Slots) || len(got.Durabilities) != len(c.result.Durabilities) {
				t.Errorf("list did not round-trip: %+v", got)
			}
			// An older client's decoder reads the same bytes as a plain list.
			old, err := DecodeInventoryListResult(data)
			if err != nil {
				t.Fatalf("old decoder: %v", err)
			}
			if len(old.Slots) != len(c.result.Slots) || len(old.Durabilities) != len(c.result.Durabilities) {
				t.Errorf("old decoder misread the list: %+v", old)
			}
		})
	}

	// A payload from an older server -- no tail at all -- decodes with
	// capacity 0, which the client treats as "unknown, one page".
	plain := (&InventoryListResult{Slots: []InventorySlotSnapshot{{Slot: 0, ItemID: 1, Quantity: 1}}}).Encode()
	got, err := DecodeStorageListResult(plain)
	if err != nil {
		t.Fatalf("decoding an old payload: %v", err)
	}
	if got.Capacity != 0 || len(got.Slots) != 1 {
		t.Errorf("old payload: got capacity %d, %d slots", got.Capacity, len(got.Slots))
	}
}
