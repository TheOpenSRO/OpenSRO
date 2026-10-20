package main

import (
	"encoding/binary"
	"strings"
	"testing"

	"github.com/OpenSRO/OpenSRO/server/internal/leveldata"
)

// utf16le encodes a string as UTF-16LE with a BOM, the form the Media text
// tables use -- so the test exercises the real decode path.
func utf16le(s string) []byte {
	out := []byte{0xFF, 0xFE}
	for _, r := range s {
		var b [2]byte
		binary.LittleEndian.PutUint16(b[:], uint16(r))
		out = append(out, b[:]...)
	}
	return out
}

// A synthetic leveldata.txt with real-shaped columns: level, exp-to-next,
// mastery cost, two always-zero columns, the kill EXP unit, then the job caps
// (the real file has ten). Every value below except the trailing caps is the
// REAL one from the original client's leveldata.txt, so this pins each column
// choice to verified data: level 9's exp is 17978 (docs/LEVELING.md) and the
// exp units are 24/47/212.
const synthLeveldata = "1\t118\t1\t0\t0\t24\t15000000\n" +
	"2\t470\t1\t0\t0\t47\t20000000\n" +
	"9\t17978\t7\t0\t0\t212\t99\n"

func TestToRecordsPicksLevelAndExp(t *testing.T) {
	rows, err := readRowsFromBytes(utf16le(synthLeveldata))
	if err != nil {
		t.Fatalf("readRows: %v", err)
	}
	records := toRecords(rows, nil)
	// header + 3 rows
	if len(records) != 4 {
		t.Fatalf("got %d records, want 4 (header + 3)", len(records))
	}
	if records[0][0] != "level" || records[0][1] != "exp" {
		t.Errorf("header = %v, want [level exp]", records[0])
	}
	// The level-9 row must carry the verified 17978, from column 1.
	found := false
	for _, r := range records[1:] {
		if r[0] == "9" {
			found = true
			if r[1] != "17978" {
				t.Errorf("level 9 exp = %s, want 17978 (the verified value)", r[1])
			}
		}
	}
	if !found {
		t.Error("level 9 row missing")
	}
}

// The exporter's output must load straight into the server's own leveldata
// parser, pinning the two to the same CSV shape.
func TestExportRoundTripsThroughServerParser(t *testing.T) {
	rows, err := readRowsFromBytes(utf16le(synthLeveldata))
	if err != nil {
		t.Fatalf("readRows: %v", err)
	}
	records := toRecords(rows, nil)
	var csv strings.Builder
	for _, r := range records {
		csv.WriteString(strings.Join(r, ","))
		csv.WriteByte('\n')
	}
	tbl, err := leveldata.ParseCSV(strings.NewReader(csv.String()))
	if err != nil {
		t.Fatalf("server ParseCSV rejected export output: %v", err)
	}
	if got, ok := tbl.ExpToNext(9); !ok || got != 17978 {
		t.Errorf("ExpToNext(9) = %d, %v; want 17978, true", got, ok)
	}
	if got, ok := tbl.ExpToNext(1); !ok || got != 118 {
		t.Errorf("ExpToNext(1) = %d, %v; want 118, true", got, ok)
	}
}

// TestToRecordsPicksExpUnit pins column 5 -- the kill EXP unit -- against the
// original client's real values. A column shift is the dangerous failure here:
// it would not crash, it would quietly change the game's levelling pace, and
// picking column 7 instead would make a level-1 kill worth 15,000,000 exp.
func TestToRecordsPicksExpUnit(t *testing.T) {
	rows, err := readRowsFromBytes(utf16le(synthLeveldata))
	if err != nil {
		t.Fatalf("readRows: %v", err)
	}
	records := toRecords(rows, nil)
	if got := records[0]; len(got) != 8 || got[3] != "exp_unit" || got[4] != "job_trader" || got[7] != "gold_min" {
		t.Fatalf("header = %v, want exp_unit 4th, the job columns, gold_min last", got)
	}
	want := map[string]string{"1": "24", "2": "47", "9": "212"}
	for _, r := range records[1:] {
		if w, ok := want[r[0]]; ok {
			if r[3] != w {
				t.Errorf("level %s exp_unit = %s, want %s (the real column-5 value)", r[0], r[3], w)
			}
			delete(want, r[0])
		}
	}
	if len(want) != 0 {
		t.Errorf("rows missing from the export: %v", want)
	}

	// And the mastery cost still comes from column 2, not shifted.
	for _, r := range records[1:] {
		if r[0] == "9" && r[2] != "7" {
			t.Errorf("level 9 mastery_sp = %s, want 7 (column 2)", r[2])
		}
	}
}

// TestRound799JobColumns: leveldata.txt columns 6..8 (the client's
// "15000000" level-1 value, MEASURED in the r794 archive) and levelgold's
// minimum land in the job columns; -1 stays -1.
func TestRound799JobColumns(t *testing.T) {
	rows := [][]string{{"1", "118", "1", "0", "0", "24", "15000000", "15000000", "15000000"},
		{"21", "351231", "62", "0", "0", "498", "-1", "-1", "-1"}}
	gold := goldMins([][]string{{"1", "28", "59"}, {"21", "200", "300"}})
	recs := toRecords(rows, gold)
	if got := recs[1]; got[4] != "15000000" || got[6] != "15000000" || got[7] != "28" {
		t.Fatalf("level 1: %v", got)
	}
	if got := recs[2]; got[5] != "-1" || got[7] != "200" {
		t.Fatalf("level 21: %v", got)
	}
}
