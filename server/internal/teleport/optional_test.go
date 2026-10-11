package teleport

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Synthetic rows shaped like refoptionalteleport's (round 778): a town, a
// group flag with one dungeon floor under it, and a level-bounded field
// point. No archive data.
const optionalCSV = `ID,ZoneName,Region,X,Y,Z,WorldID,Group,MapPoint,LevelMin,LevelMax
1,SN_ZONE_TOWN,26959,1030,80,512,1,-1,1,0,0
29,xxx,27027,1814,452,1834,1,1,1,0,0
30,SN_ZONE_CAVE_1F,-32767,1115,0,-935,1,1,0,50,999
39,SN_ZONE_FIELD,23088,663.0,863.5,526,1,-1,1,90,999
`

func TestReadOptional(t *testing.T) {
	tab := &Table{}
	if err := tab.ReadOptional(strings.NewReader(optionalCSV)); err != nil {
		t.Fatal(err)
	}
	if len(tab.Optional) != 4 {
		t.Fatalf("read %d rows, want 4", len(tab.Optional))
	}
	cave, ok := tab.OptionalByID(30)
	if !ok {
		t.Fatal("id 30 not found")
	}
	if cave.Region != -32767 || cave.X != 1115 || cave.Y != 0 || cave.Z != -935 || cave.Group != 1 || cave.MapPoint {
		t.Errorf("cave floor = %+v", cave)
	}
	flag, _ := tab.OptionalByID(29)
	if !flag.MapPoint || flag.Group != 1 || flag.ZoneName != "xxx" {
		t.Errorf("flag = %+v", flag)
	}
	// A float field is the server's word, truncated (the client parses floats).
	field, _ := tab.OptionalByID(39)
	if field.X != 663 || field.Y != 863 {
		t.Errorf("field = %+v", field)
	}
	if _, ok := tab.OptionalByID(31); ok {
		t.Error("id 31 should be absent")
	}
}

// FUN_004a1ed0: the range applies only when both bounds are non-zero.
func TestOptionalLevelAllows(t *testing.T) {
	cases := []struct {
		min, max, level int
		want            bool
	}{
		{0, 0, 1, true},
		{50, 0, 1, true},
		{50, 999, 49, false},
		{50, 999, 50, true},
		{50, 999, 999, true},
		{50, 60, 61, false},
	}
	for _, c := range cases {
		p := OptionalPoint{LevelMin: c.min, LevelMax: c.max}
		if got := p.LevelAllows(c.level); got != c.want {
			t.Errorf("LevelAllows(%d) with [%d,%d] = %v, want %v", c.level, c.min, c.max, got, c.want)
		}
	}
}

func TestReadOptionalRefusesDuplicates(t *testing.T) {
	csv := optionalCSV + "1,SN_ZONE_TOWN,26959,1,2,3,1,-1,1,0,0\n"
	if err := (&Table{}).ReadOptional(strings.NewReader(csv)); err == nil {
		t.Fatal("a duplicate id was accepted")
	}
}

// A teleport directory without the fifth file loads with no map points, and
// one with it loads them.
func TestLoadOptionalFile(t *testing.T) {
	dir := t.TempDir()
	write := func(name, body string) {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write(PointsFile, strings.Join(PointCSVColumns, ",")+"\n")
	write(LinksFile, strings.Join(LinkCSVColumns, ",")+"\n")
	write(BuildingsFile, strings.Join(BuildingCSVColumns, ",")+"\n")
	tab, err := Load(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(tab.Optional) != 0 {
		t.Fatalf("no file, %d map points", len(tab.Optional))
	}
	write(OptionalFile, optionalCSV)
	tab, err = Load(dir)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := tab.OptionalByID(30); !ok || len(tab.Optional) != 4 {
		t.Fatalf("with the file: %d map points", len(tab.Optional))
	}
}
