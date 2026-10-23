package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/safezone"
)

// A SYNTHETIC refregion.txt in the real file's shape (21 tab-separated fields:
// wRegionID, X, Z, ContinentName, AreaName, IsBattleField, Climate,
// MaxCapacity, AssocObjID, AssocServer, AssocFile256, LinkedRegion_1..10), with
// the test's own ids and names, UTF-16LE with a byte-order mark as the
// Media.pk2 tables are stored.
func refregionRow(id, x, z, continent, area, battlefield string) string {
	cols := []string{id, x, z, continent, area, battlefield, "1001", "-1", "0", "0", "xxx"}
	for i := 0; i < 10; i++ {
		cols = append(cols, "NULL")
	}
	return strings.Join(cols, "\t")
}

func TestExportRegionsKeepsTheBattlefieldColumn(t *testing.T) {
	dir := t.TempDir()
	in := filepath.Join(dir, "refregion.txt")
	text := refregionRow("25000", "168", "97", "TEST", "TEST_TOWN", "0") + "\n" +
		refregionRow("24744", "168", "96", "TEST", "TEST_FIELD", "1") + "\n" +
		refregionRow("-32767", "0", "0", "TEST", "TEST_DUNGEON", "1") + "\n"
	if err := os.WriteFile(in, utf16le(text), 0o644); err != nil {
		t.Fatal(err)
	}
	out := filepath.Join(dir, "regions.csv")
	if err := exportRegions(out, []string{in}); err != nil {
		t.Fatal(err)
	}
	tab, err := safezone.Load(out)
	if err != nil {
		t.Fatal(err)
	}
	if tab.Len() != 3 || tab.SafeCount() != 1 {
		t.Fatalf("Len %d SafeCount %d, want 3 regions and 1 town", tab.Len(), tab.SafeCount())
	}
	if r, ok := tab.SafeAt(25000); !ok || r.Area != "TEST_TOWN" || r.Continent != "TEST" {
		t.Errorf("SafeAt(25000) = %+v, %v: want the town row, column 5 (IsBattleField) 0", r, ok)
	}
	if _, ok := tab.SafeAt(24744); ok {
		t.Error("the field row came out a town: the export read the wrong column")
	}
}

func TestExportRegionsRefusesABrokenRow(t *testing.T) {
	dir := t.TempDir()
	in := filepath.Join(dir, "refregion.txt")
	for name, text := range map[string]string{
		"short":     "25000\t168\t97\tTEST\tTEST_TOWN\n",
		"bad id":    refregionRow("x", "168", "97", "TEST", "TEST_TOWN", "0") + "\n",
		"bad flag":  refregionRow("25000", "168", "97", "TEST", "TEST_TOWN", "no") + "\n",
		"no region": "//Copyright test\n",
	} {
		if err := os.WriteFile(in, utf16le(text), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := exportRegions(filepath.Join(dir, "regions.csv"), []string{in}); err == nil {
			t.Errorf("%s: exported without an error", name)
		}
	}
	if err := exportRegions(filepath.Join(dir, "regions.csv"), []string{filepath.Join(dir, "teleportdata.txt")}); err == nil {
		t.Error("a file that is not refregion.txt was exported")
	}
}
