package main

import (
	"encoding/binary"
	"strings"
	"testing"

	"github.com/OpenSRO/srrevamp/server/internal/leveldata"
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

// A synthetic leveldata.txt with real-shaped columns: level, exp-to-next, then
// filler columns (the real file has ten). Level 9's exp is the real 17978, so
// this pins the column choice to the verified value from docs/LEVELING.md.
const synthLeveldata = "1\t118\t1\t0\t0\t24\t15000000\n" +
	"2\t470\t1\t0\t0\t47\t20000000\n" +
	"9\t17978\t1\t0\t0\t71\t99\n"

func TestToRecordsPicksLevelAndExp(t *testing.T) {
	rows, err := readRowsFromBytes(utf16le(synthLeveldata))
	if err != nil {
		t.Fatalf("readRows: %v", err)
	}
	records := toRecords(rows)
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
	records := toRecords(rows)
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
