package safezone

import (
	"strings"
	"testing"
)

// The rows here are SYNTHETIC: the shape of refregion's export, with the
// test's own ids and names (docs/LEGAL.md).
const sample = `RegionID,ContinentName,AreaName,IsBattleField
25000,TEST,TEST_TOWN,0
24744,TEST,TEST_FIELD,1
-32767,TEST,TEST_DUNGEON,1
25001,TEST,TEST_TWICE,1
25001,TEST,TEST_TWICE,0
`

func TestReadTellsTownsFromFields(t *testing.T) {
	tab, err := Read(strings.NewReader(sample))
	if err != nil {
		t.Fatal(err)
	}
	if tab.Len() != 4 || tab.SafeCount() != 2 {
		t.Fatalf("Len %d SafeCount %d, want 4 regions (one id twice) and 2 towns", tab.Len(), tab.SafeCount())
	}
	if r, ok := tab.SafeAt(25000); !ok || r.Area != "TEST_TOWN" || r.Battlefield {
		t.Errorf("SafeAt(25000) = %+v, %v: want the town (IsBattleField 0 is a town: CGObjMob::SetCurRegion's == 0)", r, ok)
	}
	if _, ok := tab.SafeAt(24744); ok {
		t.Error("an IsBattleField 1 region reads as a town")
	}
	if _, ok := tab.SafeAt(-32767); ok {
		t.Error("the dungeon row reads as a town")
	}
	if _, ok := tab.SafeAt(25001); !ok {
		t.Error("the later of two rows for one id did not win")
	}
	if _, ok := tab.SafeAt(12345); ok {
		t.Error("a region the table does not list reads as a town (OURS: unlisted is not safe)")
	}
	var none *Table
	if _, ok := none.SafeAt(25000); ok || none.Len() != 0 {
		t.Error("a nil table names a town")
	}
}

func TestReadRefusesABrokenFile(t *testing.T) {
	for name, text := range map[string]string{
		"empty":       "",
		"header only": "RegionID,ContinentName,AreaName,IsBattleField\n",
		"bad header":  "RegionID,Continent,AreaName,IsBattleField\n25000,A,B,0\n",
		"bad id":      "RegionID,ContinentName,AreaName,IsBattleField\nx,A,B,0\n",
		"bad flag":    "RegionID,ContinentName,AreaName,IsBattleField\n25000,A,B,yes\n",
		"short row":   "RegionID,ContinentName,AreaName,IsBattleField\n25000,A,B\n",
	} {
		if _, err := Read(strings.NewReader(text)); err == nil {
			t.Errorf("%s: read without an error", name)
		}
	}
}
