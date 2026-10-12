package magicopt

import (
	"strings"
	"testing"
)

// A sword's full blue: STR at its degree's row and that row's best value,
// DUR's range max, no special stone, no '-' option, no shield-only option,
// and the item's option cap.
func TestFullBlue(t *testing.T) {
	tbl, err := LoadCSV(strings.NewReader(strings.Join([]string{
		"72,MATTR_STR,11,1,7566450,65538,196612,393223,0,weapon|armor,+",
		"73,MATTR_STR,12,1,7566450,65538,196612,393224,0,weapon|armor,+",
		"11,MATTR_STR,1,1,7566450,65538,196608,0,0,weapon|armor,+",
		"90,MATTR_DUR,10,1,1685418613,655380,1966140,6553760,0,weapon,+",
		"91,MATTR_DUR,12,1,1685418613,655380,1966140,6553760,0,weapon,+",
		"30,MATTR_LUCK,12,0.3,1819632491,65538,196612,327686,0,weapon,+",
		"40,MATTR_DEC_MAXDUR,12,0.5,1685418593,0,36,50,0,weapon,-",
		"50,MATTR_BLOCKRATE,12,1,6451817,65538,0,0,0,shield,+",
		"60,MATTR_HR,1,1,26738,65538,0,0,0,weapon,+",
	}, "\n") + "\n"))
	if err != nil {
		t.Fatal(err)
	}
	a, err := LoadAssignCSV(strings.NewReader(
		"0,6,2,MATTR_STR|MATTR_LUCK|MATTR_DEC_MAXDUR|MATTR_BLOCKRATE|MATTR_DUR|MATTR_HR\n"))
	if err != nil {
		t.Fatal(err)
	}
	sword := DropItem{Equip: true, Race: 0, TypeID3: 6, TypeID4: 2, MaxOptions: 9}
	got := FullBlue(tbl, a, sword, 11)
	// STR level 11 (pool 1..7): 7. DUR: no level 11 row, so level 10's,
	// GenSixValues tag 'duru' -> pool 10,20,30,60,100,160: 160. HR: level 1,
	// the only row at or below 11: 2.
	want := []Rolled{{72, 7}, {90, 160}, {60, 2}}
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("got %v, want %v", got, want)
		}
	}
	sword.MaxOptions = 2
	if got := FullBlue(tbl, a, sword, 12); len(got) != 2 || got[0] != (Rolled{73, 8}) {
		t.Fatalf("capped at 2: got %v", got)
	}
	sword.MaxOptions = 0
	if got := FullBlue(tbl, a, sword, 12); got != nil {
		t.Fatalf("an item with no option room got %v", got)
	}
}
