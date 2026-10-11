package magicopt

import (
	"strings"
	"testing"
)

type seq struct {
	t    *testing.T
	vals []int
}

func (s *seq) Intn(n int) int {
	s.t.Helper()
	if len(s.vals) == 0 {
		s.t.Fatalf("rand(): nothing left for Intn(%d)", n)
	}
	v := s.vals[0]
	s.vals = s.vals[1:]
	if v >= n {
		s.t.Fatalf("rand(): %d outside Intn(%d)", v, n)
	}
	return v
}

// The table in file order: STR level 7 first (MEASURED: lines 316-317 come
// before levels 1-6), and a 30/30/30/10 bless option.
func dropTables(t *testing.T) (*Table, *AssignTable) {
	tbl, err := LoadCSV(strings.NewReader(strings.Join([]string{
		"68,MATTR_STR,7,1,7566450,65538,196612,327680,0,weapon|armor,+",
		"11,MATTR_STR,1,1,7566450,65538,196608,0,0,weapon|armor,+",
		"30,MATTR_LUCK,1,0.3,1819632491,65538,196612,327686,0,weapon,+",
		"31,MATTR_LUCK,2,0.3,1819632491,65538,196612,327686,0,weapon,+",
		"40,MATTR_DEC_MAXDUR,1,0.5,1685418593,0,36,50,0,weapon,-",
		"50,MATTR_BLOCKRATE,1,1,6451817,65538,0,0,0,shield,+",
	}, "\n") + "\n"))
	if err != nil {
		t.Fatal(err)
	}
	a, err := LoadAssignCSV(strings.NewReader("0,6,2,MATTR_STR|MATTR_LUCK|MATTR_DEC_MAXDUR|MATTR_BLOCKRATE\n"))
	if err != nil {
		t.Fatal(err)
	}
	return tbl, a
}

var cnSword = DropItem{Equip: true, Race: 0, TypeID3: 6, TypeID4: 2, MaxOptions: 9}

func TestRollDropChance(t *testing.T) {
	tbl, a := dropTables(t)
	// 31 > 30: no options, and nothing more is drawn.
	r := &seq{t: t, vals: []int{31}}
	if got := RollDrop(tbl, a, cnSword, r); got != nil || len(r.vals) != 0 {
		t.Fatalf("got %v", got)
	}
}

func TestRollDropPicksTheFirstRowOfAnEqualGroup(t *testing.T) {
	tbl, a := dropTables(t)
	// 30: options; four count draws, least 0 -> 1 option; name 0 (STR, the
	// pool is the '+' options STR, LUCK, BLOCKRATE); the level roll; the
	// value (the third of {1..5}).
	r := &seq{t: t, vals: []int{30, 3, 0, 5, 2, 0, 1234, 0, 2}}
	got := RollDrop(tbl, a, cnSword, r)
	if len(got) != 1 || got[0] != (Rolled{ID: 68, Value: 3}) {
		t.Fatalf("got %+v, want STR id 68 (the first row, level 7) = 3", got)
	}
}

func TestRollDropWeightedLevelsAndWastedDraws(t *testing.T) {
	tbl, a := dropTables(t)
	// A Seal item: no chance roll. Count draws least 1 -> 2 options. Draw 1:
	// LUCK (idx 1), r = 400000 -> the second row (300000 < r <= 600000), its
	// value. Draw 2: LUCK again -> wasted, no level roll.
	seal := cnSword
	seal.Rarity = 2
	r := &seq{t: t, vals: []int{1, 3, 4, 5, 1, 400000 & 0x7fff, 400000 >> 15, 0, 1}}
	got := RollDrop(tbl, a, seal, r)
	if len(got) != 1 || got[0].ID != 31 {
		t.Fatalf("got %+v, want one LUCK option of the second row (id 31)", got)
	}
	if len(r.vals) != 0 {
		t.Fatalf("draws left %v", r.vals)
	}
	// BLOCKRATE is not allowed on a sword: wasted, and nothing added.
	r = &seq{t: t, vals: []int{0, 0, 0, 0, 0, 2, 0, 0}}
	if got := RollDrop(tbl, a, cnSword, r); len(got) != 0 {
		t.Fatalf("got %+v, want nothing (a shield option on a sword)", got)
	}
}

func TestOnlyPlusOptionsDrop(t *testing.T) {
	tbl, _ := dropTables(t)
	if tbl.GroupDrops("MATTR_DEC_MAXDUR") || !tbl.GroupDrops("MATTR_STR") {
		t.Fatal("a '-' option must not drop, a '+' one must")
	}
}
