package session

import (
	"bytes"
	"context"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/stall"
	"github.com/TheOpenSRO/OpenSRO/server/internal/trade"
)

// Round 842, lane T: the stall network's item tooltips need the listed
// item's whole record. Each 0xB461 record opens with the item record the
// stall's own list (0xB0B3 / 0xB0BA, appendStallList) and the exchange
// carry (exchangeRecord: SOItem::FUN_008be4f0(stream, 1) on the client,
// c:0x6c993d): the plus, the variance, the durability, the blue options and
// the binding blocks for equipment, the count for an expendable.
func TestStallNetRecordCarriesTheWholeItem(t *testing.T) {
	f := setupNetTest(t, nil)
	ctx := context.Background()
	const owner = int64(200_001)
	sword := inventory.Instance{OptLevel: 7, Variance: 0x0fff_ffff_ffff_ffff, Durability: 20,
		MagParams: []uint64{uint64(3)<<32 | 0x12, uint64(2)<<32 | 0x13}, AdvElixir: 2}
	if _, err := f.stalls.Open(stall.Member{CharacterID: owner, Name: "SellA"}, "s", 0); err != nil {
		t.Fatal(err)
	}
	f.stalls.Do(owner, func(s *stall.Stall) {
		s.Open, s.Network = true, true
		s.Slots[0] = stall.Listing{Used: true, BagSlot: 4, ItemID: 100, Quantity: 1, Price: 7000, Group: 7,
			Inst: sword, Seq: f.stalls.NextSeq()}
		s.Slots[1] = stall.Listing{Used: true, BagSlot: 5, ItemID: 200, Quantity: 30, Price: 900, Group: 7,
			Seq: f.stalls.NextSeq()}
	})
	res := f.search(t, "B", StallNetSearch{Mode: StallNetModeEnter, Group: 7})
	if !res.OK || len(res.Records) != 2 {
		t.Fatalf("the search: %+v", res)
	}
	byRef := map[uint32]StallNetRecord{}
	for _, r := range res.Records {
		byRef[r.Item.RefItemID] = r
	}
	got := byRef[100].Item
	if got.OptLevel != 7 || got.Variance != sword.Variance || got.Durability != 20 || len(got.MagParams) != 2 ||
		got.MagParams[0] != sword.MagParams[0] || got.MagParams[1] != sword.MagParams[1] || got.AdvElixir != 2 {
		t.Fatalf("the sword's record lost a field: %+v", got)
	}
	if c := byRef[200]; c.Count != 30 || len(c.Item.Tail) != 2 || c.Item.Tail[0] != 30 {
		t.Fatalf("the potions' record: count %d, tail % x", c.Count, c.Item.Tail)
	}
	// The record's item bytes are the stall list's, byte for byte.
	raw := f.searchRaw(t, "B", StallNetSearch{Mode: StallNetModeNew, Group: 7})
	var s stall.Stall
	f.stalls.Do(owner, func(st *stall.Stall) { s = *st })
	for _, slot := range []int{0, 1} {
		l := s.Slots[slot]
		want := exchangeRecord(ctx, f.netItems(), trade.Item{Slot: l.BagSlot, ItemID: l.ItemID, Quantity: l.Quantity, Inst: l.Inst})
		if !bytes.Contains(raw, want) {
			t.Fatalf("slot %d's item record % x is not in 0xB461 % x", slot, want, raw)
		}
		if list := appendStallList(ctx, f.netItems(), nil, s.Slots); !bytes.Contains(list, want) {
			t.Fatalf("slot %d's record is not the stall list's", slot)
		}
	}
}

// searchRaw is search's 0xB461 body as it came.
func (f *netFixture) searchRaw(t *testing.T, who string, r StallNetSearch) []byte {
	t.Helper()
	f.tick(stallNetSearchGap)
	f.send(t, who, OpStallNetSearch, r.Encode())
	return f.next(t, who, OpStallNetSearchResult)
}

func (f *netFixture) netItems() ItemLookup { return newNetTestItems() }
