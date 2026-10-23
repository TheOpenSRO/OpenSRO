package session

import (
	"context"
	"encoding/binary"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
)

// Round 732 review fixes.

// The rent block's branches (c:0x8bb130): bit 0 adds u16, u32, u32; bit 1
// adds u16, u32. A record behind either still reads.
func TestItemRecordReadsTheRentBranches(t *testing.T) {
	plain := AppendItemRecord(nil, ItemInfo{RefItemID: 71, OptLevel: 3, Durability: 9})
	for _, c := range []struct {
		rent  uint32
		extra int
	}{{1, 10}, {2, 8}, {3, 16}} {
		rec := binary.LittleEndian.AppendUint32(nil, c.rent)
		rec = append(rec, make([]byte, c.extra)...)
		rec = append(rec, plain[4:]...)
		ii, rest, err := ReadItemRecord(rec)
		if err != nil || ii.RefItemID != 71 || ii.OptLevel != 3 || ii.Durability != 9 || len(rest) != 0 {
			t.Errorf("rent %d: %+v rest %d %v", c.rent, ii, len(rest), err)
		}
		if _, _, err := ReadItemRecord(rec[:4+c.extra-1]); err == nil {
			t.Errorf("rent %d: a cut rent block read without error", c.rent)
		}
	}
}

// The advanced elixir entry as gs:0x825a40 writes it: u8 nSlot, then the
// u64 with nOptID | nOptLvl<<16 low and nOptValue high.
func TestAdvancedElixirEntryLayout(t *testing.T) {
	rec := AppendItemRecord(nil, ItemInfo{RefItemID: 1, AdvElixir: 4})
	tail := rec[len(rec)-13:]
	want := []byte{BindingAdvElixir, 1, 0, 0, 0, 0, 0, 4, 0, 0, 0}
	if string(tail[2:]) != string(want) || tail[0] != BindingSocket || tail[1] != 0 {
		t.Fatalf("binding blocks % x", tail)
	}
	// A u8 add on the client: 200 + 100 wraps.
	two := append([]byte(nil), rec[:len(rec)-11]...)
	two = append(two, BindingAdvElixir, 2, 0, 0, 0, 0, 0, 200, 0, 0, 0, 1, 0, 0, 0, 0, 100, 0, 0, 0)
	ii, _, err := ReadItemRecord(two)
	if err != nil || ii.AdvElixir != 44 {
		t.Fatalf("two elixir entries: %+v %v, want the u8 sum 44", ii, err)
	}
}

// Time-limited gear (TypeID3 14) carries the period word in place of
// durability (gs:0x42fd30): 0 -- "not active" -- until its expiry is set;
// round 789 keeps the expiry in the instance's Durability (the Data word),
// so a set one is bit 31 with the seconds left (internal/avatar).
func TestTimeLimitedGearSendsThePeriodWord(t *testing.T) {
	items := refdata.NewMemStore()
	if err := items.ImportItems(context.Background(), []refdata.Item{
		{ID: 900, MaxStack: 1, TypeID1: 3, TypeID2: 1, TypeID3: 14, TypeID4: 1, DurabilityMin: 50, DurabilityMax: 62},
	}); err != nil {
		t.Fatal(err)
	}
	for _, never := range []int{0, -1} {
		ii, ok := itemInfoFor(context.Background(), items, 0, 900, inventory.Instance{Durability: never})
		if !ok || ii.Durability != 0 {
			t.Fatalf("a time-limited item never awakened (%d): %+v %v, want the period word 0", never, ii, ok)
		}
	}
	ii, ok := itemInfoFor(context.Background(), items, 0, 900, inventory.Instance{Durability: 40})
	if !ok || ii.Durability != 1<<31 {
		t.Fatalf("a time-limited item expired long ago: %+v %v, want bit 31 and 0 seconds", ii, ok)
	}
}

// The worst warehouse splits across frames: 210 slots, each equipment with 12
// options and an advanced elixir, with every durability entry.
func TestWorstCaseStorageListSplits(t *testing.T) {
	var r StorageListResult
	r.Capacity = inventory.MaxStorageExpansionSlots
	params := make([]uint64, inventory.MaxMagParams)
	for i := range params {
		params[i] = inventory.MagParam(uint16(i+1), 0xffffffff)
	}
	for s := 0; s < inventory.MaxStorageExpansionSlots; s++ {
		r.Slots = append(r.Slots, InventorySlotSnapshot{Slot: s, ItemID: 3645, Quantity: 1})
		r.Durabilities = append(r.Durabilities, DurabilitySnapshot{Slot: s, Durability: 62, MaxDurability: 62})
		r.Infos = append(r.Infos, ItemInfo{Slot: s, RefItemID: 3645, OptLevel: 255, Variance: ^uint64(0),
			Durability: 62, MagParams: params, AdvElixir: 255})
	}
	all := r.Infos
	rest := r.splitInfos()
	data := r.Encode()
	if len(data) > proto.MaxPayload {
		t.Fatalf("worst-case warehouse list %d bytes, over one frame's %d", len(data), proto.MaxPayload)
	}
	got, err := DecodeStorageListResult(data)
	if err != nil || len(got.Slots) != inventory.MaxStorageExpansionSlots {
		t.Fatalf("worst case: %d slots, %v", len(got.Slots), err)
	}
	if len(rest) == 0 {
		t.Fatal("the worst case was expected to overflow one frame; if it no longer does, drop the split")
	}
	seen := len(got.Infos)
	for _, more := range EncodeItemInfoMore(ItemInfoWarehouse, rest) {
		if len(more) > proto.MaxPayload {
			t.Fatalf("an OpItemInfoMore payload of %d bytes", len(more))
		}
		c, infos, err := DecodeItemInfoMore(more)
		if err != nil || c != ItemInfoWarehouse {
			t.Fatalf("more: %d %v", c, err)
		}
		seen += len(infos)
	}
	if seen != len(all) {
		t.Fatalf("list + more carried %d entries, want %d", seen, len(all))
	}
	t.Logf("worst-case warehouse: list %d bytes with %d entries, %d more in OpItemInfoMore", len(data), len(got.Infos), len(rest))
}
