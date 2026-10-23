package session

import (
	"bytes"
	"context"
	"reflect"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/durability"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
)

// The record's bytes, field by field, against the client's parser
// (SOItem::FUN_008be4f0's equipment branch, c:0x8bcdf0, c:0x8bb070).
func TestItemRecordGoldenBytes(t *testing.T) {
	cases := []struct {
		name string
		ii   ItemInfo
		want []byte
	}{
		{
			"+5, two blue options, advanced elixir +3",
			ItemInfo{RefItemID: 3645, OptLevel: 5, Variance: 0x7c1f, Durability: 62,
				MagParams: []uint64{inventory.MagParam(1, 7), inventory.MagParam(16, 100)}, AdvElixir: 3},
			[]byte{
				0x00, 0x00, 0x00, 0x00, // rent block: none (c:0x8bb130)
				0x3d, 0x0e, 0x00, 0x00, // RefItemID
				0x05,                                           // OptLevel
				0x1f, 0x7c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // Variance
				0x3e, 0x00, 0x00, 0x00, // Durability
				0x02,                                           // MagParamNum
				0x01, 0x00, 0x00, 0x00, 0x07, 0x00, 0x00, 0x00, // option 1, value 7
				0x10, 0x00, 0x00, 0x00, 0x64, 0x00, 0x00, 0x00, // option 16, value 100
				0x01, 0x00, // binding block: sockets, none
				0x02, 0x01, // binding block: advanced elixir, one entry
				0x00,                                           // its slot
				0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, // high u32: +3
			},
		},
		{
			"plain",
			ItemInfo{RefItemID: 3645, Durability: 62},
			[]byte{
				0, 0, 0, 0,
				0x3d, 0x0e, 0x00, 0x00, 0x00,
				0, 0, 0, 0, 0, 0, 0, 0,
				0x3e, 0x00, 0x00, 0x00,
				0x00,
				0x01, 0x00, 0x02, 0x00,
			},
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := AppendItemRecord(nil, c.ii)
			if !bytes.Equal(got, c.want) {
				t.Fatalf("record\n got % x\nwant % x", got, c.want)
			}
			back, rest, err := ReadItemRecord(append(got, 0xaa))
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(back, c.ii) || !bytes.Equal(rest, []byte{0xaa}) {
				t.Fatalf("round trip: %+v rest % x, want %+v", back, rest, c.ii)
			}
		})
	}
}

func TestItemRecordCapsAndRefusals(t *testing.T) {
	many := make([]uint64, 14)
	for i := range many {
		many[i] = inventory.MagParam(uint16(i+1), 1)
	}
	rec := AppendItemRecord(nil, ItemInfo{RefItemID: 1, MagParams: many})
	if rec[21] != inventory.MaxMagParams {
		t.Fatalf("MagParamNum %d, want the cap %d", rec[21], inventory.MaxMagParams)
	}
	bad := append([]byte(nil), rec...)
	bad[21] = 13
	if _, _, err := ReadItemRecord(bad); err == nil {
		t.Error("MagParamNum 13 should be refused, as the client's assert does")
	}
	for n := 0; n < len(rec); n++ {
		if _, _, err := ReadItemRecord(rec[:n]); err == nil {
			t.Errorf("a record cut at %d bytes read without error", n)
		}
	}
}

func testItemTable(t *testing.T) *refdata.MemStore {
	t.Helper()
	items := refdata.NewMemStore()
	if err := items.ImportItems(context.Background(), []refdata.Item{
		{ID: 3645, MaxStack: 1, TypeID1: 3, TypeID2: 1, TypeID3: 6, TypeID4: 2, DurabilityMin: 50, DurabilityMax: 62},
		{ID: 10, MaxStack: 50, TypeID1: 3, TypeID2: 3},
	}); err != nil {
		t.Fatal(err)
	}
	return items
}

// Only equipment is listed; an untracked durability goes out as the max the
// variance gives.
func TestSlotItemInfosListsEquipmentOnly(t *testing.T) {
	ctx := context.Background()
	items := testItemTable(t)
	var sword inventory.Slot
	sword.Index, sword.ItemID, sword.Quantity = 4, 3645, 1
	sword.SetInstance(inventory.Instance{Variance: 0x1f << 20, Durability: durability.Untracked, OptLevel: 5,
		MagParams: []uint64{inventory.MagParam(2, 9)}})
	potions := inventory.Slot{Index: 5, ItemID: 10, Quantity: 30}
	infos := slotItemInfos(ctx, []inventory.Slot{sword, potions}, items)
	if len(infos) != 1 {
		t.Fatalf("infos %+v, want the sword only", infos)
	}
	ii := infos[0]
	wantDur := durability.MaxDurability(50, 62, sword.Variance)
	if ii.Slot != 4 || ii.RefItemID != 3645 || ii.OptLevel != 5 || ii.Durability != uint32(wantDur) || len(ii.MagParams) != 1 {
		t.Fatalf("sword info %+v (want durability %d)", ii, wantDur)
	}
	if slotItemInfos(ctx, []inventory.Slot{sword}, nil) != nil {
		t.Error("no item table should list nothing")
	}
	var worn equipment.Equipped
	worn.Slot, worn.ItemID = equipment.SlotWeapon, 3645
	worn.SetInstance(inventory.Instance{Durability: 40, AdvElixir: 2})
	w := wornItemInfos(ctx, []equipment.Equipped{worn}, items)
	if len(w) != 1 || w[0].Slot != int(equipment.SlotWeapon) || w[0].Durability != 40 || w[0].AdvElixir != 2 {
		t.Fatalf("worn infos %+v", w)
	}
}

// The block rides after the warehouse/bag list's capacity and after the
// equipment list's durability block; an older decoder still reads the list.
func TestListsCarryTheItemInfoBlock(t *testing.T) {
	infos := []ItemInfo{
		{Slot: 2, RefItemID: 3645, OptLevel: 5, Variance: 0x3ff, Durability: 62,
			MagParams: []uint64{inventory.MagParam(1, 7), inventory.MagParam(16, 100)}, AdvElixir: 1},
		{Slot: 9, RefItemID: 3645, Durability: 10},
	}
	list := StorageListResult{
		InventoryListResult: InventoryListResult{
			Slots:        []InventorySlotSnapshot{{Slot: 2, ItemID: 3645, Quantity: 1}, {Slot: 9, ItemID: 3645, Quantity: 1}},
			Durabilities: []DurabilitySnapshot{{Slot: 2, Durability: 62, MaxDurability: 62}},
		},
		Capacity: 45,
		Infos:    infos,
	}
	data := list.Encode()
	got, err := DecodeStorageListResult(data)
	if err != nil {
		t.Fatal(err)
	}
	if got.Capacity != 45 || !reflect.DeepEqual(got.Infos, infos) {
		t.Fatalf("storage list: capacity %d infos %+v", got.Capacity, got.Infos)
	}
	if old, err := DecodeInventoryListResult(data); err != nil || len(old.Slots) != 2 {
		t.Fatalf("an older decoder: %+v %v", old, err)
	}
	if _, err := DecodeStorageListResult(data[:len(data)-3]); err == nil {
		t.Error("a truncated block should be an error")
	}

	eq := EquipmentResult{
		Items:        []EquippedSnapshot{{Slot: int(equipment.SlotWeapon), ItemID: 3645}},
		Durabilities: []DurabilitySnapshot{{Slot: int(equipment.SlotWeapon), Durability: 30, MaxDurability: 62}},
		Infos:        []ItemInfo{{Slot: int(equipment.SlotWeapon), RefItemID: 3645, OptLevel: 7, Durability: 30}},
	}
	back, err := DecodeEquipmentResult(eq.Encode())
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(back.Infos, eq.Infos) || len(back.Durabilities) != 1 {
		t.Fatalf("equipment list: %+v", back)
	}
	eq.Infos = nil
	plain := eq.Encode()
	if back, err := DecodeEquipmentResult(plain); err != nil || back.Infos != nil {
		t.Fatalf("an equipment list without the block: %+v %v", back, err)
	}
}
