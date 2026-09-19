package spawn

import (
	"strings"
	"testing"
)

func TestReadGroupsPlacementsBySpecies(t *testing.T) {
	in := "ObjectID,RegionID,LocalX,LocalY,LocalZ\n" +
		"1933,24744,1089.65,0,600.09003\n" +
		"1933,24744,1842.3,0,600.94\n" +
		"1943,25000,100.5,0,200.25\n"
	tbl, err := Read(strings.NewReader(in))
	if err != nil {
		t.Fatal(err)
	}
	if len(tbl.Rows(1933)) != 2 || len(tbl.Rows(1943)) != 1 || tbl.Rows(1) != nil {
		t.Fatalf("grouping: %+v", tbl)
	}
	p := tbl.Rows(1933)[1]
	if p.RegionID != 24744 || p.LocalX != 1842.3 || p.LocalZ != 600.94 {
		t.Errorf("row kept in the table's own terms: %+v", p)
	}
}

func TestReadRefusesTheWrongTable(t *testing.T) {
	if _, err := Read(strings.NewReader("ID,MaxStack\n1,2\n")); err == nil {
		t.Error("an items CSV must not load as npcpos")
	}
	if _, err := Read(strings.NewReader("ObjectID,RegionID,LocalX,LocalY,LocalZ\nx,1,2,3,4\n")); err == nil {
		t.Error("a bad id must be an error, not a silent skip")
	}
}
