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
