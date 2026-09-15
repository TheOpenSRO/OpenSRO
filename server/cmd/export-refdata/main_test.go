package main

import (
	"strings"
	"testing"

	"github.com/OpenSRO/srrevamp/server/internal/refdata"
)

// A synthetic itemdata row with the Copper Sword's real, verified values at
// the columns itemRecord maps, run through export's itemRecord and then the
// importer's own LoadItemsCSV -- so the two tools are pinned to the same
// column mapping. The values are the ones a real Copper Sword (+5) tooltip
// confirmed (see the package doc and ITEM_FORMAT.md).
func TestItemRecordRoundTripsThroughTheImporter(t *testing.T) {
	cols := make([]string, 120)
	for i := range cols {
		cols[i] = "0"
	}
	set := func(i int, v string) { cols[i] = v }
	set(fID, "3632")
	set(fTypeID1, "3")
	set(fTypeID1+1, "1")
	set(fTypeID1+2, "6") // weapon family
	set(fTypeID1+3, "2") // sword
	set(fCountry, "0")
	set(fReqGender, "2")
	set(fReqLevelType1, "1")
	set(fReqLevel1, "1")
	set(fReqStr, "20")
	set(fReqInt, "0")
	set(fDurabilityMin, "62")
	set(fDurabilityMin+1, "76")
	set(fPhysAttackMin, "15")
	set(fPhysAttackMax, "16")
	set(fMagAttackMin, "25")
	set(fMagAttackMax, "28")
	set(fHitRate, "24")
	set(fHitRate+1, "30")
	set(fCritical, "3")
	set(fCritical+1, "15")
	set(fPrice, "890")     // the Copper Sword's real buy price
	set(fSellPrice, "427") // and its real buy-back price
	// A sentinel (a real sword is 1) so this fails if MaxStack is hardcoded
	// again instead of read from its column.
	set(fMaxStack, "99")

	rec, ok := itemRecord(cols)
	if !ok {
		t.Fatal("itemRecord rejected a valid row")
	}
	// The width grows as verified columns are appended -- 30 before the
	// Param-block restore amounts, 34 before the shield block ratio. The
	// importer takes each addition as an optional suffix, so every older
	// export still loads; this only pins that the exporter and importer agree
	// on the CURRENT width, which is the half that would otherwise drift.
	if len(rec) != 36 {
		t.Fatalf("record has %d fields, want the importer's 36", len(rec))
	}

	items, err := refdata.LoadItemsCSV(strings.NewReader(strings.Join(rec, ",") + "\n"))
	if err != nil {
		t.Fatalf("the importer rejected export's own output: %v", err)
	}
	if len(items) != 1 {
		t.Fatalf("parsed %d items, want 1", len(items))
	}
	it := items[0]
	if it.ID != 3632 {
		t.Errorf("ID = %d, want 3632", it.ID)
	}
	if it.PhysAttackMax != 16 {
		t.Errorf("PhysAttackMax = %v, want 16 (the value combat reads)", it.PhysAttackMax)
	}
	if it.PhysAttackMin != 15 || it.MagAttackMin != 25 || it.MagAttackMax != 28 {
		t.Errorf("attack = %v..%v phys / %v..%v mag, want 15..16 / 25..28",
			it.PhysAttackMin, it.PhysAttackMax, it.MagAttackMin, it.MagAttackMax)
	}
	if it.Price != 890 || it.SellPrice != 427 {
		t.Errorf("price = %d buy / %d sell, want 890 / 427", it.Price, it.SellPrice)
	}
	if it.MaxStack != 99 {
		t.Errorf("MaxStack = %d, want 99 (read from its column, not hardcoded)", it.MaxStack)
	}
	if it.DurabilityMin != 62 || it.DurabilityMax != 76 {
		t.Errorf("durability = %v/%v, want 62/76", it.DurabilityMin, it.DurabilityMax)
	}
	if it.TypeID3 != 6 || it.TypeID4 != 2 {
		t.Errorf("typeids = %d/%d, want family 6, sword 2", it.TypeID3, it.TypeID4)
	}
	if it.Country != 0 || it.ReqGender != 2 || it.ReqLevel1 != 1 {
		t.Errorf("country/gender/reqlevel = %d/%d/%d, want 0/2/1", it.Country, it.ReqGender, it.ReqLevel1)
	}
}

// A row too short to hold the mapped columns, or with a non-numeric id, is
// not an item and is skipped rather than mis-parsed.
func TestItemRecordSkipsNonItemRows(t *testing.T) {
	if _, ok := itemRecord([]string{"1", "not-a-number", "x"}); ok {
		t.Error("a short row was accepted as an item")
	}
	long := make([]string, 120)
	for i := range long {
		long[i] = "0"
	}
	long[fID] = "xxx"
	if _, ok := itemRecord(long); ok {
		t.Error("a row with a non-numeric id was accepted")
	}
}

// The armour defence and shield block columns are exported, not zeroed.
//
// Until 2026-09-15 this exporter emitted a literal "0" for both defences,
// carrying a note that they were "armour, not verified" -- which stopped being
// true when docs/protocol/ITEM_FORMAT.md grounded them three ways (the real DB
// column order, heavy-vs-cloth behaviour, and a real +5 tooltip). Every
// deployment importing through this tool gave armour no defence at all. This
// test is the thing that would have caught it.
func TestItemRecordCarriesArmourDefenceAndBlock(t *testing.T) {
	cols := make([]string, fMax+2)
	for i := range cols {
		cols[i] = "0"
	}
	set := func(i int, v string) { cols[i] = v }
	set(fID, "11")
	set(fMaxStack, "1")
	// A Cotton garment's real readings, and a shield's real block ratio.
	set(fPhysDefenseMin, "2")
	set(fPhysDefenseMin+1, "2.5")
	set(fMagDefenseMin, "4.3")
	set(fMagDefenseMin+1, "5.2")
	set(fBlockRatio, "10")
	set(fBlockRatio+1, "20")
	set(fTwoHanded, "1")
	set(fItemClass, "7")

	rec, ok := itemRecord(cols)
	if !ok {
		t.Fatal("itemRecord rejected a valid row")
	}
	items, err := refdata.LoadItemsCSV(strings.NewReader(strings.Join(rec, ",") + "\n"))
	if err != nil {
		t.Fatalf("the importer rejected export's own output: %v", err)
	}
	if len(items) != 1 {
		t.Fatalf("got %d items, want 1", len(items))
	}
	it := items[0]
	for _, tc := range []struct {
		name string
		got  float64
		want float64
	}{
		{"PhysDefenseMin", it.PhysDefenseMin, 2},
		{"PhysDefenseMax", it.PhysDefenseMax, 2.5},
		{"MagDefenseMin", it.MagDefenseMin, 4.3},
		{"MagDefenseMax", it.MagDefenseMax, 5.2},
		{"BlockRatioMin", it.BlockRatioMin, 10},
		{"BlockRatioMax", it.BlockRatioMax, 20},
	} {
		if tc.got != tc.want {
			t.Errorf("%s = %v, want %v", tc.name, tc.got, tc.want)
		}
	}
	// TwoHanded travels the same route, and nearly did not: the edit that
	// was supposed to map it in v0.1.169 silently matched nothing, so the
	// column constant was defined and never used and the equipment rule that
	// depends on it was inert in production. Nothing caught it, because the
	// round-trip test only checked the record's WIDTH and this test only
	// checked defence and block. It checks TwoHanded now.
	if !it.TwoHanded {
		t.Error("TwoHanded = false, want true -- column 93 is not reaching the importer")
	}
	// ItemClass reaches the client through the shop listing, so a zero here
	// is visible, not just internal. The server's own deserialiser asserts
	// "m_btItemClass > 0", which is what identifies column 61.
	if it.ItemClass != 7 {
		t.Errorf("ItemClass = %d, want 7 -- column 61 is not reaching the importer", it.ItemClass)
	}
}
