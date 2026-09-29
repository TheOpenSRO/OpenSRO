package worldmap

import (
	"math"
	"testing"
)

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
// (round 569) from /var/tmp/tables: npcpos.txt's first column (the NPC's id)
// joined to characterdata's second (its ID; characterdata's first is the
// Service flag), counted by the town's NPC code, against teleportdata.txt's
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

// ParseRegionLabel reads the project's own "x/y" region notation and nothing
// else: a real region id carries each coordinate in one byte (RegionXY), so a
// part outside 0..255 is not a region.
func TestParseRegionLabel(t *testing.T) {
	for _, tc := range []struct {
		label string
		x, y  int
		ok    bool
	}{
		{"97/168", 97, 168, true},
		{"0/0", 0, 0, true},
		{"255/255", 255, 255, true},
		{"100/100", 100, 100, true},
		{"jangan", 0, 0, false},
		{"", 0, 0, false},
		{"97", 0, 0, false},
		{"97/", 0, 0, false},
		{"/168", 0, 0, false},
		{"97/168/1", 0, 0, false},
		{"97\\168", 0, 0, false},
		{"256/1", 0, 0, false},
		{"-1/5", 0, 0, false},
		{"a/b", 0, 0, false},
	} {
		x, y, ok := ParseRegionLabel(tc.label)
		if ok != tc.ok || x != tc.x || y != tc.y {
			t.Errorf("ParseRegionLabel(%q) = %d, %d, %v; want %d, %d, %v", tc.label, x, y, ok, tc.x, tc.y, tc.ok)
		}
	}
}

// The frame the server names on the wire (round 570) is every named zone's own
// centre and the region an "x/y" label names -- the frame each zone's
// coordinates were already in, so naming it changes nothing. A label with
// neither (a capitalised town, a typo) has no frame: the client then keeps its
// own case-insensitive reading of the label, which lands on the same centre.
//
// The named-zone loop holds FrameFor to its construction (it returns
// ZoneCentre's entry), so it only guards against FrameFor stopping to read
// ZoneCentre; the "x/y" and no-frame rows are the discriminating ones. The
// cross-side guard -- the server's frame for each label equal to the grid the
// client builds -- is the six hard-coded rows on each side: session's
// TestFrameForNamesEachZonesCentre and region_grid_state_test.gd's
// server_frames, checked against World3D._resolve_zone_region (round 570's
// review; said here since round 574).
func TestFrameForIsEveryZonesOwnCentre(t *testing.T) {
	for _, zone := range ZoneNames() {
		rx, ry, ok := FrameFor(zone)
		if !ok || [2]int{rx, ry} != ZoneCentre[zone] {
			t.Errorf("FrameFor(%q) = %d/%d, %v; want its ZoneCentre %d/%d", zone, rx, ry, ok, ZoneCentre[zone][0], ZoneCentre[zone][1])
		}
	}
	if rx, ry, ok := FrameFor("100/100"); !ok || rx != 100 || ry != 100 {
		t.Errorf(`FrameFor("100/100") = %d/%d, %v; want 100/100`, rx, ry, ok)
	}
	for _, zone := range []string{"nowhere", "Jangan", ""} {
		if _, _, ok := FrameFor(zone); ok {
			t.Errorf("FrameFor(%q) named a frame; want none", zone)
		}
	}
}

// The rows client/scripts/world/region_grid_state_test.gd holds its port of
// ToWorld (RegionGridState.frame_world) and the terrain placement
// (World3D._group_position of _cell_offset) to. They were generated by ToWorld
// in round 570 and copied there, so this test is what keeps the client's
// literals ToWorld's: the measured rows of TestToWorldMatchesTheMeasuredColumns
// in the frame of 97/168, and the same points in the frame of 98/157.
//
// The SIGN RULE (the batch-22 plan wrote the shift as (21120, -1920) and was
// wrong): moving a point from the frame of 97/168 into the frame of 98/157
// shifts it by the negation of 98/157's own middle in the 97/168 frame --
// ToWorld(98, 157, 960, 960, 97, 168) is (-21120, -1920), so the shift is
// (+21120, +1920). Derived here from ToWorld, never typed from prose.
func TestFrameTableTheClientReproduces(t *testing.T) {
	for _, tc := range []struct {
		rx, ry         int
		localX, localZ float64
		fx, fy         int
		wantX, wantZ   float64
	}{
		{97, 168, 1002, 1020, 97, 168, 42, -60},
		{97, 169, 960, 960, 97, 168, 1920, 0},
		{97, 167, 960, 960, 97, 168, -1920, 0},
		{98, 168, 960, 960, 97, 168, 0, -1920},
		{96, 168, 960, 960, 97, 168, 0, 1920},
		{98, 157, 960, 960, 97, 168, -21120, -1920},
		{102, 153, 960, 960, 97, 168, -28800, -9600},
		{97, 168, 1002, 1020, 98, 157, 21162, 1860},
		{97, 169, 960, 960, 98, 157, 23040, 1920},
		{97, 167, 960, 960, 98, 157, 19200, 1920},
		{98, 168, 960, 960, 98, 157, 21120, 0},
		{96, 168, 960, 960, 98, 157, 21120, 3840},
		{98, 157, 960, 960, 98, 157, 0, 0},
		{102, 153, 960, 960, 98, 157, -7680, -7680},
	} {
		x, z := ToWorld(tc.rx, tc.ry, tc.localX, tc.localZ, tc.fx, tc.fy)
		if x != tc.wantX || z != tc.wantZ {
			t.Errorf("ToWorld(%d/%d, %g, %g in %d/%d) = (%g, %g), want (%g, %g)",
				tc.rx, tc.ry, tc.localX, tc.localZ, tc.fx, tc.fy, x, z, tc.wantX, tc.wantZ)
		}
	}
	middleX, middleZ := ToWorld(98, 157, halfSpan, halfSpan, 97, 168)
	for _, p := range []struct {
		rx, ry         int
		localX, localZ float64
	}{{97, 168, 1002, 1020}, {97, 169, 960, 960}, {98, 168, 960, 960}, {102, 153, 10, 1900}} {
		x0, z0 := ToWorld(p.rx, p.ry, p.localX, p.localZ, 97, 168)
		x1, z1 := ToWorld(p.rx, p.ry, p.localX, p.localZ, 98, 157)
		if x1-x0 != -middleX || z1-z0 != -middleZ {
			t.Errorf("%d/%d (%g, %g) moved (%g, %g) from the 97/168 frame into 98/157's, want (%g, %g)",
				p.rx, p.ry, p.localX, p.localZ, x1-x0, z1-z0, -middleX, -middleZ)
		}
	}
	if -middleX <= 0 || -middleZ <= 0 {
		t.Errorf("the shift into 98/157's frame is (%g, %g); both terms are positive (the frame's y, 157, is below 168, which moves every point +X; its x, 98, is above 97, which moves every point +Z)",
			-middleX, -middleZ)
	}
}

// The one world frame of -single-frame (round 571) is Jangan's own centre, so
// Jangan's coordinates are the same with the flag on or off.
func TestWorldOriginIsJangansCentre(t *testing.T) {
	if WorldOrigin != ZoneCentre["jangan"] {
		t.Fatalf("WorldOrigin = %v, want jangan's centre %v", WorldOrigin, ZoneCentre["jangan"])
	}
	if _, _, ok := FrameFor(WorldBucket); ok {
		t.Fatalf("the bucket's name %q parses as a frame; it must not name a zone of its own", WorldBucket)
	}
}

// Landing is the middle of the zone's centre region: (0, 0) in the zone's own
// frame -- spawnPos, where every zone change has always landed -- and the same
// place in any other frame. Every expected value is ToWorld's own, derived
// here rather than written from prose.
func TestLandingIsTheCentresMiddleInAnyFrame(t *testing.T) {
	for zone, centre := range ZoneCentre {
		if x, z, ok := Landing(zone, centre[0], centre[1]); !ok || x != 0 || z != 0 {
			t.Errorf("Landing(%q) in its own frame = (%g, %g, %v), want (0, 0) -- spawnPos", zone, x, z, ok)
		}
		wantX, wantZ := ToWorld(centre[0], centre[1], halfSpan, halfSpan, WorldOrigin[0], WorldOrigin[1])
		if x, z, ok := Landing(zone, WorldOrigin[0], WorldOrigin[1]); !ok || x != wantX || z != wantZ {
			t.Errorf("Landing(%q) in 97/168's frame = (%g, %g, %v), want ToWorld(%d/%d middle) = (%g, %g)",
				zone, x, z, ok, centre[0], centre[1], wantX, wantZ)
		}
	}
	// Donwhang's 102/153 is 15 regions below Jangan in y (world X negative)
	// and 5 above in x (world Z negative: the mirror). Derived, then checked
	// for sign against the axes AGENTS.md records.
	x, z, _ := Landing("donwhang", WorldOrigin[0], WorldOrigin[1])
	if wantX, wantZ := ToWorld(102, 153, 960, 960, 97, 168); x != wantX || z != wantZ || x >= 0 || z >= 0 {
		t.Errorf("Donwhang's landing in the one frame = (%g, %g), want ToWorld = (%g, %g), both negative", x, z, wantX, wantZ)
	}
	// An "x/y" label's centre is its own region; a label with no frame has
	// no landing.
	if x, z, ok := Landing("100/100", 97, 168); !ok {
		t.Error("an x/y label has no landing")
	} else if wantX, wantZ := ToWorld(100, 100, 960, 960, 97, 168); x != wantX || z != wantZ {
		t.Errorf("Landing(100/100) = (%g, %g), want (%g, %g)", x, z, wantX, wantZ)
	}
	for _, zone := range []string{"nowhere", "Jangan", WorldBucket, ""} {
		if _, _, ok := Landing(zone, 97, 168); ok {
			t.Errorf("Landing(%q) is ok for a label with no frame", zone)
		}
	}
}

// Rebase names the same place in another frame: a real point's coordinates
// in one frame, rebased, are ToWorld's in the other -- among them round 570's
// "(+21120, +1920) into 98/157's frame" and a real Earth Ghost row.
func TestRebaseIsTheSamePlaceInTheOtherFrame(t *testing.T) {
	frames := [][2]int{{97, 168}, {102, 153}, {98, 157}, {105, 79}, {92, 135}, {106, 107}}
	points := []struct {
		rx, ry         int
		localX, localZ float64
	}{{97, 168, 1002, 1020}, {101, 151, 460.51, 1023.06}, {102, 153, 10, 1900}, {106, 108, 270, 1421}}
	for _, from := range frames {
		for _, to := range frames {
			for _, p := range points {
				x0, z0 := ToWorld(p.rx, p.ry, p.localX, p.localZ, from[0], from[1])
				wantX, wantZ := ToWorld(p.rx, p.ry, p.localX, p.localZ, to[0], to[1])
				x, z := Rebase(x0, z0, from[0], from[1], to[0], to[1])
				// A float64 sum of region offsets and a fractional local: equal
				// to the last few ulps, not bit for bit.
				if math.Abs(x-wantX) > 1e-6 || math.Abs(z-wantZ) > 1e-6 {
					t.Errorf("%d/%d (%g, %g) rebased from %v into %v = (%g, %g), want (%g, %g)",
						p.rx, p.ry, p.localX, p.localZ, from, to, x, z, wantX, wantZ)
				}
			}
		}
	}
}

// FromWorld inverts ToWorld (round 642's review): every local point of a
// region comes back as the same region and local x/z, in two frames, and the
// local coordinates stay in [0, RegionSpan) on the region's edges.
func TestFromWorldInvertsToWorld(t *testing.T) {
	frames := [][2]int{{97, 168}, {102, 153}}
	for _, f := range frames {
		for _, r := range [][2]int{{97, 168}, {97, 161}, {100, 161}, {95, 118}, {93, 48}} {
			for _, l := range [][2]float64{{0, 0}, {636, 1482}, {1919.5, 1919.5}, {960, 0}, {0, 1919}} {
				x, z := ToWorld(r[0], r[1], l[0], l[1], f[0], f[1])
				rx, ry, lx, lz := FromWorld(x, z, f[0], f[1])
				if rx != r[0] || ry != r[1] || math.Abs(lx-l[0]) > 1e-6 || math.Abs(lz-l[1]) > 1e-6 {
					t.Fatalf("frame %v: ToWorld(%v, %v) = (%v, %v) -> FromWorld %d/%d (%v, %v)",
						f, r, l, x, z, rx, ry, lx, lz)
				}
			}
		}
	}
}
