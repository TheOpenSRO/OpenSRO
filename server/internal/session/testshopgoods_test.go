package session

import (
	"bytes"
	"context"
	"fmt"
	"strings"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/magicopt"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
)

// installTestShopOptions installs a synthetic magic option table and assign
// table (OURS fixture rows: STR level 11 tops at 7, DUR at 160%) over refs.
func installTestShopOptions(t *testing.T, refs ItemLookup) {
	t.Helper()
	optTable, err := magicopt.LoadCSV(strings.NewReader(
		"72,MATTR_STR,11,1,7566450,65538,196612,393223,0,weapon|armor,+\n" +
			"90,MATTR_DUR,11,1,1685418613,655380,1966140,6553760,0,weapon|armor,+\n"))
	if err != nil {
		t.Fatal(err)
	}
	assign, err := magicopt.LoadAssignCSV(strings.NewReader("0,6,2,MATTR_STR|MATTR_DUR\n"))
	if err != nil {
		t.Fatal(err)
	}
	SetMagicOptions(optTable)
	SetDropOptions(refs, assign)
	t.Cleanup(func() { SetMagicOptions(nil); SetDropOptions(nil, nil) })
}

// OpNpcShopGoods' bytes, pinned (round 786): the uid, then the block -- one
// entry, the sword's item id and its record (+12, every variance group at
// 31, STR 7 and DUR 160, no durability range so 0, the two empty binding
// blocks). The stone, not equipment, is not listed. The client's
// npc_shop_def_test.gd decodes these same bytes.
func TestShopGoodsPayloadBytes(t *testing.T) {
	ctx := context.Background()
	refs := refdata.NewMemStore()
	if err := refs.ImportItems(ctx, []refdata.Item{
		{ID: 901, CodeName: "ITEM_CH_SWORD_11_A_RARE_ACTIVE", TypeID1: 3, TypeID2: 1, TypeID3: 6, TypeID4: 2, ItemClass: 31, MaxStack: 1, MaxMagicOptions: 9},
		{ID: 903, CodeName: "ITEM_ETC_ARCHEMY_MAGICSTONE_STR_11", TypeID1: 3, TypeID2: 3, TypeID3: 11, TypeID4: 1, MaxStack: 500},
	}); err != nil {
		t.Fatal(err)
	}
	installTestShopOptions(t, refs)
	got := TestShopGoodsPayloads(ctx, 0x7f000123, []int64{903, 901})
	want := []byte{
		0x23, 0x01, 0x00, 0x7f, // uid
		1, 0, // one entry
		0x85, 0x03, 0, 0, // the good's item id, 901
		0, 0, 0, 0, // rent block: none
		0x85, 0x03, 0, 0, // RefItemID 901
		12,                                             // OptLevel
		0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x0f, // Variance: twelve 5-bit groups at 31
		0, 0, 0, 0, // Durability
		2,                       // MagParamNum
		72, 0, 0, 0, 7, 0, 0, 0, // STR 7
		90, 0, 0, 0, 160, 0, 0, 0, // DUR 160
		1, 0, 2, 0, // the socket and advanced elixir blocks, empty
	}
	if len(got) != 1 || !bytes.Equal(got[0], want) {
		t.Fatalf("payloads %d\n% x\nwant\n% x", len(got), got, want)
	}
	uid, m, err := DecodeShopGoods(got[0])
	if err != nil || uid != 0x7f000123 || len(m) != 1 || m[901].OptLevel != 12 || m[901].Variance != fullVariance {
		t.Fatalf("decode: %#x %+v %v", uid, m, err)
	}
	if _, _, err := DecodeShopGoods(got[0][:len(got[0])-1]); err == nil {
		t.Fatal("a truncated payload decoded")
	}
	// No item table: no listing (and no instance at the buy either).
	SetDropOptions(nil, nil)
	if p := TestShopGoodsPayloads(ctx, 1, []int64{901}); p != nil {
		t.Fatalf("listing with no item table: %d messages", len(p))
	}
}

// More goods than one frame holds split across messages, each inside a
// frame, every good listed once.
func TestShopGoodsPayloadSplits(t *testing.T) {
	ctx := context.Background()
	refs := refdata.NewMemStore()
	var rows []refdata.Item
	var ids []int64
	for i := 0; i < 1000; i++ {
		id := int64(10000 + i)
		rows = append(rows, refdata.Item{ID: id, CodeName: fmt.Sprintf("ITEM_CH_SWORD_11_A_RARE_ACTIVE_%d", i),
			TypeID1: 3, TypeID2: 1, TypeID3: 6, TypeID4: 2, ItemClass: 31, MaxStack: 1, MaxMagicOptions: 9})
		ids = append(ids, id)
	}
	if err := refs.ImportItems(ctx, rows); err != nil {
		t.Fatal(err)
	}
	installTestShopOptions(t, refs)
	msgs := TestShopGoodsPayloads(ctx, 7, ids)
	if len(msgs) < 2 {
		t.Fatalf("%d messages for 1000 goods, want a split", len(msgs))
	}
	seen := map[int64]bool{}
	for _, m := range msgs {
		if len(m) > proto.MaxPayload {
			t.Fatalf("a message of %d bytes", len(m))
		}
		_, goods, err := DecodeShopGoods(m)
		if err != nil {
			t.Fatal(err)
		}
		for id, ii := range goods {
			if seen[id] || ii.OptLevel != TestShopPlus || len(ii.MagParams) != 2 ||
				inventory.MagParamOption(ii.MagParams[0]) != 72 {
				t.Fatalf("good %d: seen %v, %+v", id, seen[id], ii)
			}
			seen[id] = true
		}
	}
	if len(seen) != 1000 {
		t.Fatalf("%d goods listed, want 1000", len(seen))
	}
}
