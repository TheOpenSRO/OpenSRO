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

	rec, ok := itemRecord(cols)
	if !ok {
		t.Fatal("itemRecord rejected a valid row")
	}
	if len(rec) != 28 {
		t.Fatalf("record has %d fields, want the importer's 28", len(rec))
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
	if it.DurabilityMin != 62 || it.DurabilityMax != 76 {
		t.Errorf("durability = %v/%v, want 62/76", it.DurabilityMin, it.DurabilityMax)
	}
	if it.TypeID3 != 6 || it.TypeID4 != 2 {
		t.Errorf("typeids = %d/%d, want family 6, sword 2", it.TypeID3, it.TypeID4)
	}
	if it.Country != 0 || it.ReqGender != 2 || it.ReqLevel1 != 1 {
		t.Errorf("country/gender/reqlevel = %d/%d/%d, want 0/2/1", it.Country, it.ReqGender, it.ReqLevel1)
	}
	if it.MaxStack != 1 {
		t.Errorf("MaxStack = %d, want the safe default 1", it.MaxStack)
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
