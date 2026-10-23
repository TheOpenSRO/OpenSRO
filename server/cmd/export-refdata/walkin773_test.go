package main

import (
	"math"
	"os"
	"path/filepath"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/teleport"
)

// A synthetic objectstring.ifo (own names and positions): the bits of 960.5,
// 150.25, 1841.75 and of -100, 0, 250 in a dungeon (rz 128).
func writeWalkInFixture(t *testing.T, dir string) []string {
	t.Helper()
	ez := "1\t1\tGATE_TEST_A\tTELEPORT\t0\t0\t0\t0\t0\tGATE_TEST_A\txxx\txxx\txxx\txxx\t\n" +
		"1\t2\tGATE_TEST_B\tTELEPORT\t0\t0\t0\t0\t0\tGATE_TEST_B\txxx\txxx\txxx\txxx\t\n" +
		"1\t3\tGATE_TEST_NOPLACE\tTELEPORT\t0\t0\t0\t0\t0\tGATE_TEST_A\txxx\txxx\txxx\txxx\t\n" +
		"1\t4\tSOME_OBJECT\tOBJECT\t0\t0\t0\t0\t0\txxx\txxx\txxx\txxx\txxx\t\n" +
		"0\t5\tGATE_TEST_B\tTELEPORT\t0\t0\t0\t0\t0\tGATE_TEST_B\txxx\txxx\txxx\txxx\t\n" +
		"//Copyright test\n"
	bits := func(f float32) string { return "0x" + hex32(math.Float32bits(f)) }
	ifo := "JMXVOBJI1000\r\n2\r\n" +
		"0xffff0001 0x00000000 172 102 " + bits(960.5) + " " + bits(150.25) + " " + bits(1841.75) + " 0x00000000 \"GATE_TEST_A\"\r\n" +
		"0xffff0002 0x00000000 7 128 " + bits(-100) + " " + bits(0) + " " + bits(250) + " 0xbfc90fdb \"GATE_TEST_B\"\r\n"
	ezPath, ifoPath := filepath.Join(dir, "eventzonedata.txt"), filepath.Join(dir, "objectstring.ifo")
	if err := os.WriteFile(ezPath, utf16le(ez), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(ifoPath, []byte(ifo), 0o644); err != nil {
		t.Fatal(err)
	}
	return []string{ezPath, ifoPath}
}

func hex32(v uint32) string {
	const digits = "0123456789abcdef"
	out := make([]byte, 8)
	for i := 7; i >= 0; i-- {
		out[i] = digits[v&0xf]
		v >>= 4
	}
	return string(out)
}

// The walk-in zones: one row per serviced TELEPORT zone whose codename is a
// point and which objectstring places, region (rz << 8) | rx, the centre as
// the floats' bits say; back through the server's loader.
func TestRound773ExportWalkIns(t *testing.T) {
	src, out := t.TempDir(), filepath.Join(t.TempDir(), "teleport")
	paths := append(writeTeleportFixture(t, src), writeWalkInFixture(t, src)...)
	if err := exportTeleport(out, paths); err != nil {
		t.Fatalf("exportTeleport: %v", err)
	}
	tb, err := teleport.Load(out)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if len(tb.WalkIns) != 2 {
		t.Fatalf("%d walk-in zones; want 2: %+v", len(tb.WalkIns), tb.WalkIns)
	}
	a, b := tb.WalkIns[0], tb.WalkIns[1]
	if a.Code != "GATE_TEST_A" || a.PointID != 1 || a.Region != 102<<8|172 || a.X != 960.5 || a.Y != 150.25 || a.Z != 1841.75 {
		t.Errorf("zone A %+v", a)
	}
	if b.Code != "GATE_TEST_B" || b.PointID != 2 || b.Region != 0x8007 || b.X != -100 || b.Z != 250 {
		t.Errorf("zone B %+v", b)
	}
	// Without the two tables there is no walkin.csv, and one left from an
	// earlier export goes.
	if err := exportTeleport(out, paths[:3]); err != nil {
		t.Fatalf("exportTeleport without walk-ins: %v", err)
	}
	if _, err := os.Stat(filepath.Join(out, "walkin.csv")); !os.IsNotExist(err) {
		t.Fatalf("walkin.csv after an export without walk-ins: %v", err)
	}
	// One of the two alone is refused.
	if err := exportTeleport(out, paths[:4]); err == nil {
		t.Fatal("eventzonedata.txt without objectstring.ifo was taken")
	}
}
