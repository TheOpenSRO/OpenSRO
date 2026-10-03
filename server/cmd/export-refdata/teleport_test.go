package main

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"unicode/utf16"

	"github.com/OpenSRO/OpenSRO/server/internal/teleport"
)

// utf16le encodes text the way the Media.pk2 tables are stored: UTF-16LE with
// an FF FE byte-order mark, CRLF line ends.
func utf16le(text string) []byte {
	units := utf16.Encode([]rune(strings.ReplaceAll(text, "\n", "\r\n")))
	out := []byte{0xFF, 0xFE}
	for _, u := range units {
		out = append(out, byte(u), byte(u>>8))
	}
	return out
}

// A SYNTHETIC set of the three client tables in their real shape (own ids,
// codes and positions -- never an archive's rows): 14 teleportdata fields with
// the codename space-padded as the real file pads it, 23 teleportlink fields
// with blank data words in some empty slots and zero in others (the retail
// table has both), 59 teleportbuilding fields. Each file ends with the tables'
// comment line, and each first row carries the byte-order mark.
//
// Each of teleportdata and teleportlink also has a service-0 row that repeats
// an id the file already has (point 1; link 1 -> 2), so the loader refuses the
// export if the row is not skipped. teleportdata's is its FIRST row: its "0"
// reads as 0 only if the byte-order mark was stripped, so that row is what
// tests the mark. On the other two files the mark lands in column 0, which
// the exporter does not read for teleportbuilding and reads only to find a 0
// for teleportlink, so their first rows come through whether or not the mark
// is stripped.
func writeTeleportFixture(t *testing.T, dir string) []string {
	t.Helper()
	building := func(id, code, name, region, x, y, z, fortress string) string {
		cols := make([]string, 59)
		for i := range cols {
			cols[i] = "0"
		}
		cols[0], cols[1], cols[2], cols[5] = "1", id, code, name
		cols[3], cols[4], cols[6] = "????", "xxx", "xxx"
		cols[tbRegion], cols[42], cols[tbX], cols[tbY], cols[tbZ] = region, "0", x, y, z
		cols[tbFortress], cols[58] = fortress, ""
		return strings.Join(cols, "\t")
	}
	files := map[string]string{
		"teleportdata.txt": "0\t1\tGATE_TEST_SKIPPED\t9002\tSN_ZONE_TEST_B\t12600\t999\t0\t999\t70\t0\t1\t4\t\n" +
			"1\t1\tGATE_TEST_A          \t9001\tSN_ZONE_TEST_A\t12345\t100\t5\t200\t70\t1\t0\t3\t\n" +
			"1\t2\tGATE_TEST_B\t9002\tSN_ZONE_TEST_B\t12600\t300\t0\t400\t70\t1\t1\t4\t\n" +
			"//Copyright test\n",
		"teleportlink.txt": "1\t1\t2\t5000\t0\t0\t0\t1\t1\t110\t2\t0\t0\t0\t\t\t0\t\t\t0\t\t\t\n" +
			"1\t2\t1\t500\t0\t0\t0\t2\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t\n" +
			"0\t1\t2\t7\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t\n" +
			"//Copyright test\n",
		"teleportbuilding.txt": building("9001", "STORE_TEST_A_GATE", "SN_NPC_TEST_A_GATE", "12345", "110", "4", "210", "FORTRESS_TEST") + "\n" +
			building("9002", "STORE_TEST_B_GATE", "SN_NPC_TEST_B_GATE", "12600", "310", "-6", "410", "xxx") + "\n" +
			"//Copyright test\n",
	}
	var paths []string
	for name, body := range files {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, utf16le(body), 0o644); err != nil {
			t.Fatal(err)
		}
		paths = append(paths, p)
	}
	return paths
}

// The three tables go out as the three CSVs and come back through the
// server's own loader, so the exporter's column map and internal/teleport are
// pinned to each other.
func TestExportTeleportRoundTripsThroughTheLoader(t *testing.T) {
	src, out := t.TempDir(), filepath.Join(t.TempDir(), "teleport")
	paths := writeTeleportFixture(t, src)
	if err := exportTeleport(out, paths); err != nil {
		t.Fatalf("exportTeleport: %v", err)
	}
	tb, err := teleport.Load(out)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if len(tb.Points) != 2 || len(tb.Links) != 2 || len(tb.Buildings) != 2 {
		t.Fatalf("got %d points, %d links, %d buildings; want 2, 2, 2", len(tb.Points), len(tb.Links), len(tb.Buildings))
	}
	// Point 1 is the service-1 row, not the service-0 row before it that
	// carried the byte-order mark; link 1 -> 2 keeps its fee, not the
	// service-0 row's 7.
	p, ok := tb.PointByBuildingCode("STORE_TEST_A_GATE")
	want := teleport.Point{ID: 1, Code: "GATE_TEST_A", ObjectID: 9001, ZoneName: "SN_ZONE_TEST_A", Region: 12345,
		X: 100, Y: 5, Z: 200, Radius: 70, Interaction7: true, WorldID: 3}
	if !ok || p != want {
		t.Errorf("PointByBuildingCode(STORE_TEST_A_GATE) = %+v, %v; want %+v", p, ok, want)
	}
	l, ok := tb.LinkBetween(1, 2)
	if !ok || l.Fee != 5000 || !reflect.DeepEqual(l.Rules, []teleport.Rule{{Type: 1, D1: 1, D2: 110}, {Type: 2}}) {
		t.Errorf("LinkBetween(1, 2) = %+v, %v", l, ok)
	}
	b := tb.Buildings[1]
	if b.ID != 9002 || b.NameStrID != "SN_NPC_TEST_B_GATE" || b.Region != 12600 || b.X != 310 || b.Y != -6 || b.Z != 410 || b.Fortress != "" {
		t.Errorf("building 9002 = %+v", b)
	}
}

func TestExportTeleportNeedsAllThreeTablesAndADirectory(t *testing.T) {
	src := t.TempDir()
	paths := writeTeleportFixture(t, src)
	if err := exportTeleport("-", paths); err == nil {
		t.Error("exportTeleport accepted stdout for three files")
	}
	var two []string
	for _, p := range paths {
		if filepath.Base(p) != "teleportlink.txt" {
			two = append(two, p)
		}
	}
	if err := exportTeleport(filepath.Join(t.TempDir(), "out"), two); err == nil {
		t.Error("exportTeleport accepted the inputs without teleportlink.txt")
	}
}

// A row shorter than the columns the export reads stops the export with an
// error naming the file, instead of being skipped: skipped silently, a
// truncated table loses gates or links and still loads. Nothing is written.
func TestExportTeleportRefusesAShortRow(t *testing.T) {
	short := map[string]string{
		"teleportdata.txt":     "1\t3\tGATE_TEST_SHORT\t0\tSN_ZONE_TEST_C\t12345\t1\t0\t1\n",
		"teleportlink.txt":     "1\t2\t1\t500\t0\t0\t0\t2\t0\t0\n",
		"teleportbuilding.txt": "1\t9003\tSTORE_TEST_SHORT\t????\txxx\tSN_NPC_TEST_SHORT\n",
	}
	for name, row := range short {
		src := t.TempDir()
		out := filepath.Join(t.TempDir(), "teleport")
		paths := writeTeleportFixture(t, src)
		p := filepath.Join(src, name)
		raw, err := os.ReadFile(p)
		if err != nil {
			t.Fatal(err)
		}
		// Insert the short row before the comment line; the fixture's own
		// rows are all full width.
		text := decode(raw)
		cut := strings.LastIndex(text, "//")
		text = text[:cut] + strings.ReplaceAll(row, "\n", "\r\n") + text[cut:]
		if err := os.WriteFile(p, utf16le(strings.ReplaceAll(text, "\r\n", "\n")), 0o644); err != nil {
			t.Fatal(err)
		}
		err = exportTeleport(out, paths)
		if err == nil {
			t.Errorf("%s: exportTeleport accepted a row with too few fields", name)
			continue
		}
		if !strings.Contains(err.Error(), name) || !strings.Contains(err.Error(), "fewer than") {
			t.Errorf("%s: the error does not name the file and the short row: %v", name, err)
		}
		if _, statErr := os.Stat(out); !os.IsNotExist(statErr) {
			t.Errorf("%s: the refused export still created %s", name, out)
		}
	}
}
