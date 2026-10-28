package gacha

import (
	"bytes"
	"reflect"
	"testing"
)

// The archive's rows (MEASURED, gachaitemset.txt / gachanpcmap.txt), a few
// of set 1 and all of set 2.
func archive() *Table {
	rows := []Row{
		{Set: 1, RefItemID: 49046, Ratio: 50, Count: 1, GachaID: 4934},
		{Set: 1, RefItemID: 3705, Ratio: 120, Count: 1, GachaID: 3916},
		{Set: 2, RefItemID: 3679, Ratio: 1200, Count: 1, GachaID: 3880},
		{Set: 2, RefItemID: 3680, Ratio: 2400, Count: 1, GachaID: 3881},
		{Set: 2, RefItemID: 3681, Ratio: 1800, Count: 1, GachaID: 3882},
		{Set: 2, RefItemID: 3682, Ratio: 2100, Count: 1, GachaID: 3883},
	}
	return Build(rows, []NPCMap{{NPCRefID: 9251, WinSet: 1, LoseSet: 2}})
}

func TestLoseSharesNormalised(t *testing.T) {
	if got := archive().shares(2); !reflect.DeepEqual(got, []int{1600, 4800, 7200, 10000}) {
		t.Fatalf("set 2's running totals %v, want 1600/4800/7200/10000", got)
	}
	// An uneven set gives the remainder to its last row.
	if got := Build([]Row{{Set: 3, Ratio: 1}, {Set: 3, Ratio: 1}, {Set: 3, Ratio: 1}}, nil).shares(3); !reflect.DeepEqual(got, []int{3333, 6666, 10000}) {
		t.Fatalf("thirds %v", got)
	}
}

// fixed answers each call to rand() % n with the next value.
func fixed(v ...int) func(int) int {
	return func(n int) int {
		x := v[0]
		v = v[1:]
		return x % n
	}
}

func TestDraw(t *testing.T) {
	tb := archive()
	m, ok := tb.Machine(9251)
	if !ok {
		t.Fatal("NPC 9251 is not a machine")
	}
	// Win when roll < Ratio: 119 wins the elixir (Ratio 120), 120 does not.
	if o, code := tb.Draw(m, 3916, fixed(119)); code != 0 || !o.Win || o.Row.RefItemID != 3705 {
		t.Fatalf("roll 119: %+v code %d", o, code)
	}
	// A loss: roll2 by lower_bound -- 1600 is still the first row, 1601 the second.
	for _, tc := range []struct {
		roll2 int
		want  int64
	}{{0, 3679}, {1600, 3679}, {1601, 3680}, {4800, 3680}, {7201, 3682}, {9999, 3682}} {
		o, code := tb.Draw(m, 3916, fixed(120, tc.roll2))
		if code != 0 || o.Win || o.Row.RefItemID != tc.want {
			t.Fatalf("roll2 %d: %+v code %d, want the consolation %d", tc.roll2, o, code, tc.want)
		}
	}
	if _, code := tb.Draw(m, 9999, fixed(0)); code != CodeNoRow {
		t.Fatalf("an unknown GachaID: code %d, want 2", code)
	}
}

func TestCSVRoundTrip(t *testing.T) {
	var buf bytes.Buffer
	if err := WriteCSV(&buf, archive()); err != nil {
		t.Fatal(err)
	}
	back, err := ReadCSV(&buf)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(back.Rows(), archive().Rows()) || !reflect.DeepEqual(back.maps, archive().maps) {
		t.Fatalf("round trip lost rows: %+v %+v", back.Rows(), back.maps)
	}
}

func TestFromTextdataSkipsService0(t *testing.T) {
	tb, err := FromTextdata([][]string{
		{"1", "1", "3705", "120", "1", "3916", "0"},
		{"0", "2", "3679", "1200", "1", "3880", "0"},
		{"//Copyright"},
	}, [][]string{{"1", "9251", "1", "2"}})
	if err != nil {
		t.Fatal(err)
	}
	if n, m := tb.Len(); n != 1 || m != 1 {
		t.Fatalf("%d rows %d maps, want 1 and 1", n, m)
	}
}
