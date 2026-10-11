package magicopt

import (
	"strings"
	"testing"
)

type fixed int

func (f fixed) Intn(n int) int {
	if int(f) >= n {
		return n - 1
	}
	return int(f)
}

// The STR level-8 row's MEASURED fields: 65538 / 196612 / 327680 hold the
// halves 1,2 / 3,4 / 5,0 -> {1,2,3,4,5}; tag 7566450 is 'str'.
const strRow = "69,MATTR_STR,8,1,7566450,65538,196612,327680,1949131624,weapon|armor|shield|accessory\n"

func TestLoadCSVAndTheSixValues(t *testing.T) {
	tbl, err := LoadCSV(strings.NewReader(strRow))
	if err != nil {
		t.Fatal(err)
	}
	r := tbl.Record("mattr_str", 8)
	if r == nil || r.ID != 69 || r.Tag != PackTag("str") || r.Generator() != GenSixValues {
		t.Fatalf("row %+v", r)
	}
	got := r.Values()
	if len(got) != 5 || got[0] != 1 || got[4] != 5 {
		t.Fatalf("values %v, want 1..5", got)
	}
	if v := r.Generate(fixed(4)); v != 5 {
		t.Errorf("Generate: %d, want the fifth value 5", v)
	}
	if tbl.Record("MATTR_STR", 7) != nil || tbl.Group("MATTR_INT") != nil {
		t.Error("a missing level or group must be nil")
	}
}

func TestRangeAndSingleGenerators(t *testing.T) {
	rng := &Row{Tag: PackTag("dura"), Params: [4]uint32{0, 36, 50, 0}}
	if rng.Generator() != GenRange || rng.Generate(fixed(0)) != 36 || rng.Generate(fixed(RandMax)) != 50 {
		t.Errorf("range: %d..%d", rng.Generate(fixed(0)), rng.Generate(fixed(RandMax)))
	}
	one := &Row{Tag: PackTag("nrep"), Params: [4]uint32{0, 400, 0, 0}}
	if one.Generator() != GenSingle || one.Generate(fixed(0)) != 400 {
		t.Errorf("single: %d", one.Generate(fixed(0)))
	}
	if (&Row{Tag: PackTag("zzzz")}).Generate(fixed(0)) != 0 {
		t.Error("an unknown tag has no value")
	}
}

func TestKindsMatchTheBinarysRule(t *testing.T) {
	tbl, err := LoadCSV(strings.NewReader(
		"1,A,1,1,1,0,0,0,0,weapon\n" +
			"2,B,1,1,1,0,0,0,0,helm\n" +
			"3,C,1,1,1,0,0,0,0,shield\n" +
			"4,D,1,1,1,0,0,0,0,ITEM_SPECIAL\n" +
			"5,E,1,1,1,0,0,0,0,armor|accessory\n"))
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		id         uint16
		tid3, tid4 int
		code       string
		want       bool
	}{
		{1, 6, 2, "", true}, {1, 4, 1, "", false},
		// helm is 2/1 and 10/1; an entry of TypeID3 2 matches every armour
		// TypeID3 (and 13) with TypeID4 1.
		{2, 1, 1, "", true}, {2, 9, 1, "", true}, {2, 13, 1, "", true}, {2, 1, 3, "", false}, {2, 6, 1, "", false},
		{3, 4, 2, "", true}, {3, 4, 3, "", false},
		{4, 6, 2, "item_special", true}, {4, 6, 2, "OTHER", false},
		{5, 11, 6, "", true}, {5, 12, 3, "", true}, {5, 6, 1, "", false},
	} {
		if got := tbl.ByID(c.id).AllowedOn(c.tid3, c.tid4, c.code); got != c.want {
			t.Errorf("row %d on %d/%d %q: %v, want %v", c.id, c.tid3, c.tid4, c.code, got, c.want)
		}
	}
}

func TestLoadCSVRefusesBadRows(t *testing.T) {
	for _, bad := range []string{"x,A,1,1,1,0,0,0,0,\n", "1,A,1,1,1,0,0,0\n", "70000,A,1,1,1,0,0,0,0,\n"} {
		if _, err := LoadCSV(strings.NewReader(bad)); err == nil {
			t.Errorf("%q loaded", bad)
		}
	}
}
