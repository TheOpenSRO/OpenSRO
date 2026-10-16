package testnpc

import (
	"fmt"
	"os"
	"reflect"
	"strings"
	"testing"

	"github.com/OpenSRO/OpenSRO/server/internal/npcspawn"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
)

// item builds a synthetic item (OURS test fixture: invented ids, code names
// shaped like the archive's so the rules have something to bite on; no row of
// any real table).
func item(id int64, code string, typ [4]int, itemClass int) *refdata.Item {
	return &refdata.Item{ID: id, CodeName: code, TypeID1: typ[0], TypeID2: typ[1], TypeID3: typ[2], TypeID4: typ[3], ItemClass: itemClass}
}

// The embedded definition parses, keeps to the store's four tabs, names the
// in-game name the user chose and Thiara's body.
func TestBuiltinDefinition(t *testing.T) {
	d, err := Builtin()
	if err != nil {
		t.Fatal(err)
	}
	if d.Name != "Test Items" {
		t.Fatalf("name %q, want exactly \"Test Items\" (the user's choice)", d.Name)
	}
	if d.Model != "NPC_SD_T_AREA_POTION" {
		t.Fatalf("model %q", d.Model)
	}
	if d.Region != 25000 {
		t.Fatalf("region %d, want Jangan's 97/168 (25000)", d.Region)
	}
	if len(d.Lines) != 11 {
		t.Fatalf("%d lines, want 11 (8, and round 789's three avatar lines)", len(d.Lines))
	}
	for i, l := range d.Lines {
		if len(l.Tabs) > MaxTabs {
			t.Fatalf("line %d: %d tabs", i, len(l.Tabs))
		}
	}
}

func TestParseRefuses(t *testing.T) {
	for _, bad := range []string{
		`{}`,
		`{"name":"x","model":"m","lines":[]}`,
		`{"name":"x","model":"m","lines":[{"label":"a","tabs":[{"label":"t","rules":[]}]}]}`,
		`{"name":"x","model":"m","lines":[{"label":"a","tabs":[{"label":"1","rules":[{}]},{"label":"2","rules":[{}]},{"label":"3","rules":[{}]},{"label":"4","rules":[{}]},{"label":"5","rules":[{}]}]}]}`,
		`{"name":"x","model":"m","lines":[{"label":"a","tabs":[{"label":"t","rules":[{"type":"3/x"}]}]}]}`,
	} {
		if _, err := Parse([]byte(bad)); err == nil {
			t.Fatalf("Parse(%s) accepted", bad)
		}
	}
}

// nova builds a synthetic Seal of Nova row with its required level (OURS
// fixture; the LOCKED rows ask 111, the UNLOCKED _ACTIVE ones 101, as the
// player's itemdata has them -- round 786).
func nova(id int64, code string, typ [4]int, itemClass, level int) *refdata.Item {
	it := item(id, code, typ, itemClass)
	it.ReqLevelType1, it.ReqLevel1 = 1, level
	return it
}

// The Seal of Nova rules take the UNLOCKED 11th degree rows, _A_RARE_ACTIVE
// (round 786: level 101), and leave the look-alikes: the locked _A_RARE row
// (level 111), the _SWITCHnn and _SWITCHnn_ACTIVE variants, the ITEM_EVENT_
// copies, the Asue/Azus set rows (_SET_A_RARE), the 10th degree and other
// ItemClass.
func TestSealOfNovaRules(t *testing.T) {
	d, err := Builtin()
	if err != nil {
		t.Fatal(err)
	}
	items := []*refdata.Item{
		nova(1, "ITEM_CH_SWORD_11_A_RARE_ACTIVE", [4]int{3, 1, 6, 2}, 31, 101),
		nova(2, "ITEM_CH_SWORD_11_A_RARE_SWITCH01", [4]int{3, 1, 6, 2}, 31, 111),
		nova(3, "ITEM_CH_SWORD_11_A_RARE", [4]int{3, 1, 6, 2}, 31, 111),
		nova(4, "ITEM_EVENT_CH_SWORD_11_A_RARE_ACTIVE", [4]int{3, 1, 6, 2}, 31, 101),
		nova(5, "ITEM_CH_SWORD_11_SET_A_RARE", [4]int{3, 1, 6, 2}, 31, 101),
		nova(6, "ITEM_CH_SWORD_10_A_RARE_ACTIVE", [4]int{3, 1, 6, 2}, 28, 91),
		nova(7, "ITEM_CH_SWORD_11_B_RARE_ACTIVE", [4]int{3, 1, 6, 2}, 32, 101),
		nova(8, "ITEM_CH_BOW_11_A_RARE_ACTIVE", [4]int{3, 1, 6, 6}, 31, 101),
		nova(9, "ITEM_CH_SHIELD_11_A_RARE_ACTIVE", [4]int{3, 1, 4, 1}, 31, 101),
		nova(10, "ITEM_CH_RING_11_A_RARE_ACTIVE", [4]int{3, 1, 5, 3}, 31, 101),
		nova(11, "ITEM_EU_RING_11_A_RARE_ACTIVE", [4]int{3, 1, 12, 3}, 31, 101),
		nova(12, "ITEM_CH_W_HEAVY_11_FA_A_RARE_ACTIVE", [4]int{3, 1, 3, 6}, 31, 101),
		nova(13, "ITEM_CH_W_HEAVY_11_HA_A_RARE_ACTIVE", [4]int{3, 1, 3, 1}, 31, 101),
		nova(14, "ITEM_CH_W_HEAVY_11_HA_SET_A_RARE", [4]int{3, 1, 3, 1}, 31, 101),
		nova(15, "ITEM_EU_W_CLOTHES_11_BA_A_RARE_ACTIVE", [4]int{3, 1, 9, 3}, 31, 101),
		nova(16, "ITEM_EU_M_CLOTHES_11_BA_A_RARE_ACTIVE", [4]int{3, 1, 9, 3}, 31, 101),
		nova(17, "ITEM_CH_SWORD_11_A_RARE_SWITCH01_ACTIVE", [4]int{3, 1, 6, 2}, 31, 101),
		nova(18, "ITEM_CH_W_HEAVY_11_HA_A_RARE", [4]int{3, 1, 3, 1}, 31, 111),
		nova(19, "ITEM_EU_W_CLOTHES_11_BA_A_RARE_SWITCH03_ACTIVE", [4]int{3, 1, 9, 3}, 31, 101),
		nova(20, "ITEM_CH_RING_11_A_RARE", [4]int{3, 1, 5, 3}, 31, 111),
	}
	s := d.Resolve(items)
	got := func(line, tab int) []uint32 { return s.Lines[line].Tabs[tab].ItemIDs }
	// Line 3, the Chinese weapons: the sword and the bow, by TypeID4.
	if want := []uint32{1, 8}; !reflect.DeepEqual(got(2, 0), want) {
		t.Fatalf("CH weapons %v, want %v", got(2, 0), want)
	}
	if want := []uint32{9}; !reflect.DeepEqual(got(2, 1), want) {
		t.Fatalf("CH shields %v", got(2, 1))
	}
	if want := []uint32{10}; !reflect.DeepEqual(got(2, 2), want) {
		t.Fatalf("CH accessories %v", got(2, 2))
	}
	if want := []uint32{11}; !reflect.DeepEqual(got(3, 2), want) {
		t.Fatalf("EU accessories %v", got(3, 2))
	}
	// The Chinese female armour, head (TypeID4 1) before the foot (6).
	if want := []uint32{13, 12}; !reflect.DeepEqual(got(5, 0), want) {
		t.Fatalf("CH female armor %v, want %v", got(5, 0), want)
	}
	if len(got(4, 0)) != 0 {
		t.Fatalf("CH male armor %v: a woman's piece leaked", got(4, 0))
	}
	// The European robes: the man's in line 7, the woman's in line 8.
	if want := []uint32{16}; !reflect.DeepEqual(got(6, 2), want) {
		t.Fatalf("EU male garment %v", got(6, 2))
	}
	if want := []uint32{15}; !reflect.DeepEqual(got(7, 2), want) {
		t.Fatalf("EU female garment %v", got(7, 2))
	}
	if n := assertEquipmentLevel101(t, s, items); n != 9 {
		t.Fatalf("%d equipment goods, want the 9 _A_RARE_ACTIVE rows", n)
	}
}

// assertEquipmentLevel101 checks that every equipment good (TypeID 3/1) the
// shop resolved asks level 101 -- the unlocked Seal of Nova, round 786 -- and
// is a plain _A_RARE_ACTIVE row (no locked or _SWITCHnn row). It returns how
// many equipment goods there were.
func assertEquipmentLevel101(t *testing.T, s *Shop, items []*refdata.Item) int {
	t.Helper()
	byID := map[int64]*refdata.Item{}
	for _, it := range items {
		byID[it.ID] = it
	}
	n := 0
	for id := range s.Goods() {
		it := byID[id]
		if it == nil || it.TypeID1 != 3 || it.TypeID2 != 1 {
			continue
		}
		n++
		if it.ReqLevel1 != 101 {
			t.Errorf("good %d %s asks level %d, want 101 (the unlocked Seal of Nova)", id, it.CodeName, it.ReqLevel1)
		}
		if !strings.HasSuffix(it.CodeName, "_A_RARE_ACTIVE") || strings.Contains(it.CodeName, "_SWITCH") {
			t.Errorf("good %d %s is not a plain _A_RARE_ACTIVE row", id, it.CodeName)
		}
	}
	return n
}

// The alchemy rules: degree 11 by the code's _11, the plain elixirs, the
// powders, and nothing of the 10th degree or the event copies.
func TestAlchemyRules(t *testing.T) {
	d, err := Builtin()
	if err != nil {
		t.Fatal(err)
	}
	items := []*refdata.Item{
		item(1, "ITEM_ETC_ARCHEMY_REINFORCE_RECIPE_WEAPON_A", [4]int{3, 3, 10, 1}, 0),
		item(2, "ITEM_EVENT_ARCHEMY_REINFORCE_RECIPE_WEAPON_B", [4]int{3, 3, 10, 1}, 0),
		item(3, "ITEM_ETC_ARCHEMY_UPPER_REINFORCE_RECIPE_WE_A_11", [4]int{3, 3, 10, 4}, 0),
		item(4, "ITEM_ETC_ARCHEMY_UPPER_REINFORCE_RECIPE_WE_A_10", [4]int{3, 3, 10, 4}, 0),
		item(5, "ITEM_ETC_ARCHEMY_REINFORCE_PROB_UP_A_11", [4]int{3, 3, 10, 2}, 0),
		item(6, "ITEM_ETC_ARCHEMY_MAGICSTONE_STR_11", [4]int{3, 3, 11, 1}, 0),
		item(7, "ITEM_ETC_ARCHEMY_MAGICSTONE_LUCK_11", [4]int{3, 3, 11, 7}, 0),
		item(8, "ITEM_EVENT_ARCHEMY_MAGICSTONE_LUCK_11", [4]int{3, 3, 11, 7}, 0),
		item(9, "ITEM_ETC_ARCHEMY_MAGICSTONE_STR_10", [4]int{3, 3, 11, 1}, 0),
		item(10, "ITEM_ETC_ARCHEMY_ATTRSTONE_PA_11", [4]int{3, 3, 11, 2}, 0),
		item(11, "ITEM_ETC_ARCHEMY_MAGICTABLET_STR_11", [4]int{3, 3, 11, 3}, 0),
		item(12, "ITEM_ETC_ARCHEMY_ATTRTABLET_PA_11", [4]int{3, 3, 11, 3}, 0),
		item(13, "ITEM_ETC_ARCHEMY_POTIONTABLET_SPEED_11", [4]int{3, 3, 11, 3}, 0),
		item(14, "ITEM_ETC_ARCHEMY_ELEMENT_FIRE_11", [4]int{3, 3, 11, 5}, 0),
		item(15, "ITEM_ETC_ARCHEMY_MATERIAL_KK_ISYUTARU1", [4]int{3, 3, 11, 4}, 0),
	}
	s := d.Resolve(items)
	want := [][]uint32{{1, 5, 3}, {6, 7}, {10}, {11}, {12}, {14}}
	var have [][]uint32
	for _, l := range s.Lines[:2] {
		for _, tb := range l.Tabs {
			have = append(have, tb.ItemIDs)
		}
	}
	// The elixir tab is rule order: the plain elixirs, the advanced, the
	// powders -- so 1 (plain), 3 (advanced), 5 (powder).
	want[0] = []uint32{1, 3, 5}
	if !reflect.DeepEqual(have, want) {
		t.Fatalf("alchemy tabs %v, want %v", have, want)
	}
}

// A tab keeps the store's 30 cells and counts the rest.
func TestTabCap(t *testing.T) {
	d, err := Parse([]byte(`{"name":"N","model":"M","lines":[{"label":"L","tabs":[{"label":"T","rules":[{"prefix":"X_"}]}]}]}`))
	if err != nil {
		t.Fatal(err)
	}
	var items []*refdata.Item
	for i := 1; i <= 35; i++ {
		items = append(items, item(int64(i), fmt.Sprintf("X_%02d", i), [4]int{3, 3, 1, 1}, 0))
	}
	s := d.Resolve(items)
	if n := len(s.Lines[0].Tabs[0].ItemIDs); n != MaxGoodsPerTab || s.Lines[0].Tabs[0].Dropped != 5 {
		t.Fatalf("kept %d dropped %d", n, s.Lines[0].Tabs[0].Dropped)
	}
	if !strings.Contains(s.Summary(), "(+5 dropped)") {
		t.Fatalf("summary %q", s.Summary())
	}
}

// OpNpcShopDef's bytes, pinned, and its round trip.
func TestEncodeDecode(t *testing.T) {
	s := &Shop{Greeting: "Hi", Lines: []ResolvedLine{
		{Label: "L", Tabs: []ResolvedTab{{Label: "SN_TAB_WEAPON", ItemIDs: []uint32{4044, 0x01020304}}}},
	}}
	b := s.Encode(0x7f000123)
	want := []byte{
		0x23, 0x01, 0x00, 0x7f, // uid
		2, 0, 'H', 'i', // greeting
		1,         // lines
		1, 0, 'L', // label
		1,                                                                      // tabs
		13, 0, 'S', 'N', '_', 'T', 'A', 'B', '_', 'W', 'E', 'A', 'P', 'O', 'N', // tab label
		2, 0, 0xcc, 0x0f, 0, 0, 0x04, 0x03, 0x02, 0x01, // goods
	}
	if !reflect.DeepEqual(b, want) {
		t.Fatalf("% x\nwant % x", b, want)
	}
	uid, got, err := Decode(b)
	if err != nil || uid != 0x7f000123 || !reflect.DeepEqual(got, s) {
		t.Fatalf("decode: %d %+v %v", uid, got, err)
	}
	if _, _, err := Decode(b[:len(b)-1]); err == nil {
		t.Fatal("a truncated message decoded")
	}
}

// The spawn record: the name in the record's own name field (flag bit 0),
// the store (interaction 1) alone, the definition's spot and angle, and the
// NPC's own source so no facing stand-in is asked for.
func TestNPCRecord(t *testing.T) {
	d, err := Builtin()
	if err != nil {
		t.Fatal(err)
	}
	n := d.NPC(26823, npcspawn.UIDBase+7)
	if n.Flags != npcspawn.FlagName|npcspawn.FlagInteractions || n.Name != "Test Items" ||
		!reflect.DeepEqual(n.Interact, []byte{1}) || !n.Shop || n.Source != npcspawn.FromDefinition {
		t.Fatalf("%+v", n)
	}
	b := npcspawn.AppendRecord(nil, n.Record)
	dec, rest, err := npcspawn.DecodeRecord(b)
	if err != nil || len(rest) != 0 || dec.Name != "Test Items" || dec.RefID != 26823 || dec.Angle != d.Angle {
		t.Fatalf("decoded %+v rest %d err %v", dec, len(rest), err)
	}
	table := npcspawn.Table{26823: {ID: 26823, Code: "NPC_SD_T_AREA_POTION"}, 2013: {ID: 2013, Code: "NPC_CH_WAREHOUSE_M"}}
	if id := ModelRefID(table, d.Model); id != 26823 {
		t.Fatalf("ModelRefID %d", id)
	}
	if id := ModelRefID(table, "NPC_NOBODY"); id != 0 {
		t.Fatalf("ModelRefID of nobody %d", id)
	}
}

// Against the player's own items.csv (EXTERNAL, never committed): the counts
// each tab resolves to. Set OPENSRO_TEST_ITEMS_CSV to run it.
func TestBuiltinAgainstItemsCSV(t *testing.T) {
	path := os.Getenv("OPENSRO_TEST_ITEMS_CSV")
	if path == "" {
		t.Skip("OPENSRO_TEST_ITEMS_CSV not set")
	}
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	rows, err := refdata.LoadItemsCSV(f)
	if err != nil {
		t.Fatal(err)
	}
	items := make([]*refdata.Item, len(rows))
	for i := range rows {
		items[i] = &rows[i]
	}
	d, err := Builtin()
	if err != nil {
		t.Fatal(err)
	}
	s := d.Resolve(items)
	t.Logf("%d items -> %d goods: %s", len(items), len(s.Goods()), s.Summary())
	for i, l := range s.Lines {
		for j, tb := range l.Tabs {
			if len(tb.ItemIDs) == 0 || tb.Dropped > 0 {
				t.Errorf("line %d tab %d (%s): %d goods, %d dropped", i+1, j+1, tb.Label, len(tb.ItemIDs), tb.Dropped)
			}
		}
	}
	// Round 786: every equipment good is an unlocked Seal of Nova, level
	// 101. The retail itemdata has 94 such rows (MEASURED, the prod refdata
	// database, 2026-10-13): Chinese 5 weapons, a shield, 3 accessories and
	// 36 armour pieces; European 9 weapons, a shield, 3 accessories and 36
	// armour pieces.
	if n := assertEquipmentLevel101(t, s, items); n != 94 {
		t.Errorf("%d equipment goods, want 94", n)
	}
	if want := os.Getenv("OPENSRO_TEST_ITEMS_SUMMARY"); want != "" && s.Summary() != want {
		t.Errorf("summary\n%s\nwant\n%s", s.Summary(), want)
	}
}

// avatarItem builds a synthetic avatar row (OURS fixture: invented ids and
// code names shaped like the archive's).
func avatarItem(id int64, code string, typ [4]int, gender int) *refdata.Item {
	it := item(id, code, typ, 1)
	it.ReqGender = gender
	return it
}

// Round 789: the avatar lines split by gender (the rule's "gender", the row's
// ReqGender) and kind; the hat, dress and attachment tabs take the item mall
// family only; the devil's spirit and flag tabs every row of their kind; a
// tab keeps its first 30 and counts the rest.
func TestAvatarRules(t *testing.T) {
	d, err := Builtin()
	if err != nil {
		t.Fatal(err)
	}
	items := []*refdata.Item{
		avatarItem(100, "ITEM_MALL_AVATAR_M_WEDDING_HAT", [4]int{3, 1, 13, 1}, 1),
		avatarItem(101, "ITEM_MALL_AVATAR_W_WEDDING_HAT", [4]int{3, 1, 13, 1}, 0),
		avatarItem(102, "ITEM_AVATAR_M_PLAIN_HAT", [4]int{3, 1, 13, 1}, 1),
		avatarItem(103, "ITEM_MALL_AVATAR_M_WEDDING", [4]int{3, 1, 13, 2}, 1),
		avatarItem(104, "ITEM_MALL_AVATAR_M_ANGEL_WING", [4]int{3, 1, 13, 3}, 1),
		avatarItem(105, "ITEM_EVENT_AVATAR_M_NASRUN_RED", [4]int{3, 1, 14, 1}, 1),
		avatarItem(106, "ITEM_EVENT_AVATAR_W_NASRUN_RED", [4]int{3, 1, 14, 1}, 0),
		avatarItem(107, "ITEM_ETC_E050815_FLAG_M", [4]int{3, 1, 13, 4}, 1),
		avatarItem(108, "ITEM_MALL_NASRUN_EXTENSION", [4]int{3, 3, 13, 16}, 2),
	}
	for i := 0; i < 35; i++ {
		items = append(items, avatarItem(int64(200+i), fmt.Sprintf("ITEM_MALL_AVATAR_W_SET%02d_HAT", i), [4]int{3, 1, 13, 1}, 0))
	}
	s := d.Resolve(items)
	got := func(line, tab int) []uint32 { return s.Lines[line].Tabs[tab].ItemIDs }
	if want := []uint32{100}; !reflect.DeepEqual(got(8, 0), want) {
		t.Fatalf("men's hats %v, want %v (the item mall family, the man's)", got(8, 0), want)
	}
	if want := []uint32{103}; !reflect.DeepEqual(got(8, 1), want) {
		t.Fatalf("men's dresses %v", got(8, 1))
	}
	if want := []uint32{104}; !reflect.DeepEqual(got(8, 2), want) {
		t.Fatalf("men's attachments %v", got(8, 2))
	}
	if want := []uint32{105}; !reflect.DeepEqual(got(8, 3), want) {
		t.Fatalf("men's devil's spirits %v", got(8, 3))
	}
	if n := len(got(9, 0)); n != MaxGoodsPerTab || s.Lines[9].Tabs[0].Dropped != 6 || got(9, 0)[0] != 101 {
		t.Fatalf("women's hats: %d listed, %d dropped, first %d", n, s.Lines[9].Tabs[0].Dropped, got(9, 0)[0])
	}
	if want := []uint32{106}; !reflect.DeepEqual(got(9, 3), want) {
		t.Fatalf("women's devil's spirits %v", got(9, 3))
	}
	if want := []uint32{107}; !reflect.DeepEqual(got(10, 0), want) {
		t.Fatalf("men's flags %v", got(10, 0))
	}
	if want := []uint32{108}; !reflect.DeepEqual(got(10, 2), want) {
		t.Fatalf("extensions %v", got(10, 2))
	}
}
