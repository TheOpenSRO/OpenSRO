package worldmap

import "testing"

// The id packing, checked against the same row the client's own npc table
// test pins: 25257 is region 98/169.
func TestRegionXY(t *testing.T) {
	for _, tc := range []struct {
		id   int
		x, y int
	}{
		{25257, 98, 169},
		{25001, 97, 169},
		{24744, 96, 168}, // the region the real Mangyang spawns below are in
	} {
		x, y := RegionXY(tc.id)
		if x != tc.x || y != tc.y {
			t.Errorf("RegionXY(%d) = %d/%d, want %d/%d", tc.id, x, y, tc.x, tc.y)
		}
		if got := RegionID(tc.x, tc.y); got != tc.id {
			t.Errorf("RegionID(%d, %d) = %d, want %d", tc.x, tc.y, got, tc.id)
		}
	}
}

// Every column measured on the render box, reproduced exactly.
//
// These are not derived numbers. Each row is a reading printed by the real
// client's own region group node (World3D.gd's _qa_columns_report) in a
// headless run centred on Jangan's real region 97/168. Two of them --
// (960, 1800) and (1300, 1300) -- are the positions this project's monsters
// already stood on, arrived at by an unrelated route in an earlier session,
// so the formula agreeing with them is an independent check rather than a
// restatement.
//
// The cross-region rows are the ones that matter most. A transform derived
// from the region layout alone gets the z SIGN wrong across a region
// boundary -- local z is mirrored, and so is the region-to-region step, so
// the two cancel into a single consistently mirrored axis. Predicting
// (130, -1560) for the first of these and measuring (130, 2280) is what
// caught it; shipping the prediction would have put a monster 3,840 units
// away, on the far side of the town.
func TestToWorldMatchesTheMeasuredColumns(t *testing.T) {
	const ox, oy = 97, 168
	for _, tc := range []struct {
		name           string
		rx, ry         int
		localX, localZ float64
		wantX, wantZ   float64
	}{
		{"the zone spawn", 97, 168, 1002, 1020, 42, -60},
		{"monster anchor A", 97, 168, 960, 1800, 0, -840},
		{"monster anchor B", 97, 168, 1300, 1300, 340, -340},
		{"Mangyang 1", 96, 168, 1090, 600, 130, 2280},
		{"Mangyang 2", 96, 168, 1842, 601, 882, 2279},
		{"Mangyang 3", 96, 168, 554, 471, -406, 2409},
		{"Mangyang 4", 96, 168, 1261, 23, 301, 2857},
		{"one region +y", 97, 169, 960, 960, 1920, 0},
		{"one region -y", 97, 167, 960, 960, -1920, 0},
		{"one region +x", 98, 168, 960, 960, 0, -1920},
		{"one region -x", 96, 168, 960, 960, 0, 1920},
	} {
		t.Run(tc.name, func(t *testing.T) {
			x, z := ToWorld(tc.rx, tc.ry, tc.localX, tc.localZ, ox, oy)
			if x != tc.wantX || z != tc.wantZ {
				t.Errorf("ToWorld(%d/%d, %g, %g) = (%g, %g), want (%g, %g)",
					tc.rx, tc.ry, tc.localX, tc.localZ, x, z, tc.wantX, tc.wantZ)
			}
		})
	}
}

// The centre region is its own origin: its geometric centre is (0, 0), which
// is where the server puts every character that has no zone landing spot.
func TestCentreRegionCentreIsTheOrigin(t *testing.T) {
	x, z := ToWorld(97, 168, halfSpan, halfSpan, 97, 168)
	if x != 0 || z != 0 {
		t.Errorf("centre of the origin region = (%g, %g), want (0, 0)", x, z)
	}
}

// Adjacent regions tile without a gap or an overlap: stepping one region and
// subtracting one span lands back on the same world point.
func TestAdjacentRegionsTile(t *testing.T) {
	for _, d := range []struct{ dx, dy int }{{1, 0}, {-1, 0}, {0, 1}, {0, -1}} {
		x0, z0 := ToWorld(97, 168, 10, 20, 97, 168)
		x1, z1 := ToWorld(97+d.dx, 168+d.dy, 10, 20, 97, 168)
		gotX, gotZ := x1-x0, z1-z0
		wantX, wantZ := float64(d.dy)*RegionSpan, float64(-d.dx)*RegionSpan
		if gotX != wantX || gotZ != wantZ {
			t.Errorf("stepping (%d, %d) moved (%g, %g), want (%g, %g)",
				d.dx, d.dy, gotX, gotZ, wantX, wantZ)
		}
	}
}

func TestToZoneWorldRejectsAnUnknownZone(t *testing.T) {
	if _, _, ok := ToZoneWorld("nowhere", 96, 168, 100, 100); ok {
		t.Fatal("an unknown zone must not convert -- there is no frame to convert into")
	}
	x, z, ok := ToZoneWorld("jangan", 96, 168, 1090, 600)
	if !ok {
		t.Fatal("jangan must convert")
	}
	if x != 130 || z != 2280 {
		t.Errorf("jangan (96/168, 1090, 600) = (%g, %g), want (130, 2280)", x, z)
	}
}

// Every named zone's centre is the region the game's own tables put the town
// in, and the same region the client's World3D.gd builds for the label
// (_resolve_zone_region; client/scripts/world/zone_centres_test.gd pins the
// client side to these same rows). Measured on the render box on 2026-09-25
// (round 569) from /var/tmp/tables: npcpos.txt joined to characterdata on the
// first column, counted by the town's NPC code, against teleportdata.txt's
// GATE_<code> row:
//
//	NPC_CH_ 97/168 18 of 67, GATE_CH (SN_ZONE_22001 "Jangan")         97/168
//	NPC_WC_ 102/153 15 of 26, GATE_WC (SN_ZONE_22002 "Donwhang")      102/153
//	NPC_EU_ 105/79 10 of 33, GATE_EU (SN_ZONE_22004 "Constantinople") 105/79
//	NPC_KT_ 92/135 6 of 29, GATE_KT (SN_ZONE_22003 "Hotan")           92/135
//
// Samarkand's rows and gate do not agree (NPC_CA_ 5/4/4/3 over
// 107/108, 106/108, 107/107, 106/107; GATE_CA, SN_ZONE_22005 "Samarkand", in
// 106/108), so its row is the client's own SAMARKAND_ZONE_REGION, disclosed as
// unresolved rather than chosen between the tables.
//
// Until round 569 the server said dunhuang/donwhang 98/157 (textzonename:
// "Donwhang Ferry"), constantinople 100/98, hotan 87/118 and samarkand 88/130,
// and every one of those rows fails here.
func TestZoneCentresAreTheTownsOwnRegions(t *testing.T) {
	want := map[string][2]int{
		"jangan":         {97, 168},
		"dunhuang":       {102, 153},
		"donwhang":       {102, 153},
		"constantinople": {105, 79},
		"hotan":          {92, 135},
		"samarkand":      {106, 107},
	}
	for zone, w := range want {
		got, ok := ZoneCentre[zone]
		if !ok {
			t.Errorf("ZoneCentre has no %q", zone)
			continue
		}
		if got != w {
			t.Errorf("ZoneCentre[%q] = %d/%d, want %d/%d", zone, got[0], got[1], w[0], w[1])
		}
	}
	if len(ZoneCentre) != len(want) {
		t.Errorf("ZoneCentre has %d zones, want %d -- a new zone needs its row here, from the tables",
			len(ZoneCentre), len(want))
	}
}

// Moving a zone's centre moves its whole frame: a real placement converts to
// ToWorld of its own row against the new centre, never the old one. The
// expected value is derived from ToWorld, not written as a literal, with the
// axes as TestToWorldMatchesTheMeasuredColumns measured them: region y drives
// world X, region x drives world Z, and Z is mirrored.
func TestDonwhangConvertsInTheTownsFrame(t *testing.T) {
	// A real MOB_WC_EARTHGHOST (1963) row, the first npcpos.txt gives it:
	// region 26007 = 101/151, local (460.51, 1023.06).
	rx, ry := RegionXY(26007)
	x, z, ok := ToZoneWorld("donwhang", rx, ry, 460.51, 1023.06)
	if !ok {
		t.Fatal("donwhang must convert")
	}
	wantX, wantZ := ToWorld(rx, ry, 460.51, 1023.06, 102, 153)
	if x != wantX || z != wantZ {
		t.Errorf("donwhang (101/151, 460.51, 1023.06) = (%g, %g), want ToWorld against 102/153 = (%g, %g)",
			x, z, wantX, wantZ)
	}
	// And not in the old frame, 98/157 ("Donwhang Ferry"), which puts the
	// same row somewhere else.
	if oldX, oldZ := ToWorld(rx, ry, 460.51, 1023.06, 98, 157); x == oldX && z == oldZ {
		t.Errorf("donwhang (101/151) still converts against the old centre 98/157, to (%g, %g)", x, z)
	}
}
