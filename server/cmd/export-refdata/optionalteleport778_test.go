package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/OpenSRO/OpenSRO/server/internal/teleport"
)

// Round 778: refoptionalteleport.txt, when given, goes out as the fifth CSV
// and loads back as the reverse return scroll's map points. A synthetic table
// in the real 19-field shape: a service-0 row repeating an id (skipped, as the
// client's loader skips it), a town, a group flag, a dungeon floor.
func TestExportTeleportOptionalTable(t *testing.T) {
	src, out := t.TempDir(), filepath.Join(t.TempDir(), "teleport")
	paths := writeTeleportFixture(t, src)
	row := func(service, id, zone, region, x, y, z, world, group, mapPoint, lmin, lmax string) string {
		return strings.Join([]string{service, id, "????", zone, region, x, y, z, world, group, mapPoint, lmin, lmax,
			"-1", "xxx", "-1", "xxx", "-1", "xxx", ""}, "\t")
	}
	body := row("0", "1", "SN_ZONE_SKIPPED", "1", "2", "3", "4", "1", "-1", "1", "0", "0") + "\n" +
		row("1", "1", "SN_ZONE_TEST_TOWN", "26959", "1030", "80", "512", "1", "-1", "1", "0", "0") + "\n" +
		row("1", "29", "xxx", "27027", "1814", "452", "1834", "1", "1", "1", "0", "0") + "\n" +
		row("1", "30", "SN_ZONE_TEST_CAVE", "-32767", "1115", "0", "-935", "1", "1", "0", "50", "999") + "\n" +
		"//Copyright test\n"
	opt := filepath.Join(src, "refoptionalteleport.txt")
	if err := os.WriteFile(opt, utf16le(body), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := exportTeleport(out, append(paths, opt)); err != nil {
		t.Fatalf("exportTeleport: %v", err)
	}
	tb, err := teleport.Load(out)
	if err != nil {
		t.Fatal(err)
	}
	if len(tb.Optional) != 3 {
		t.Fatalf("%d map points, want 3", len(tb.Optional))
	}
	town, _ := tb.OptionalByID(1)
	if town.ZoneName != "SN_ZONE_TEST_TOWN" || town.Region != 26959 || town.X != 1030 || town.Group != teleport.NoGroup || !town.MapPoint {
		t.Errorf("town = %+v", town)
	}
	cave, _ := tb.OptionalByID(30)
	want := teleport.OptionalPoint{ID: 30, ZoneName: "SN_ZONE_TEST_CAVE", Region: -32767, X: 1115, Y: 0, Z: -935,
		WorldID: 1, Group: 1, MapPoint: false, LevelMin: 50, LevelMax: 999}
	if cave != want {
		t.Errorf("cave = %+v, want %+v", cave, want)
	}
	// A later export without the table leaves no stale fifth file behind.
	if err := exportTeleport(out, paths); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(out, teleport.OptionalFile)); !os.IsNotExist(err) {
		t.Errorf("the stale %s survived: %v", teleport.OptionalFile, err)
	}
}
