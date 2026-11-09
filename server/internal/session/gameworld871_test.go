package session

import (
	"context"
	"math"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/navmesh"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
	"github.com/TheOpenSRO/OpenSRO/server/internal/worldmap"
)

// TestInstanceKeepsItsOwnFrameUnderSingleFrame (round 871): prod runs
// -full-map, so -single-frame; an instanced world's start was named in
// Jangan's frame (the open world's one frame), and the Wrecked Ship's deck
// reached the client at scene height -776.63, under its void line. A layer
// keeps its first start's zone, frame and bucket whatever the flag, as it has
// without it (round 870's runs): 0x7EE4 (1063, 693, 1125) is (103, -165) in
// frame 126/228.
func TestInstanceKeepsItsOwnFrameUnderSingleFrame(t *testing.T) {
	for _, single := range []bool{false, true} {
		SetSingleFrame(single)
		rig := newGWRig(t, nil, map[string]int{"Aria": 40})
		w := rig.open(t)
		bucket, fx, fy, ok := InstanceFrame(w)
		if !ok || bucket != "126/228" || fx != 126 || fy != 228 {
			t.Errorf("single %v: InstanceFrame = %q %d/%d %v, want 126/228 in frame 126/228", single, bucket, fx, fy, ok)
		}
		aria := rig.players["Aria"]
		if err := EnterInstance(context.Background(), aria.sess, w, "test"); err != nil {
			t.Fatal(err)
		}
		czr, err := DecodeChangeZoneResult(rig.until("Aria", OpChangeZoneResult).Data)
		if err != nil || !czr.OK {
			t.Fatalf("single %v: zone change %+v %v", single, czr, err)
		}
		if czr.Zone != "126/228" || czr.FrameRegion != "126/228" || czr.X != 103 || czr.Z != -165 {
			t.Errorf("single %v: zone %q frame %q at (%.1f, %.1f), want 126/228 in 126/228 at (103, -165)",
				single, czr.Zone, czr.FrameRegion, czr.X, czr.Z)
		}
		e, ok := w.Hub.EntityByCharacterID(aria.charID)
		if !ok || e.Zone != "126/228" {
			t.Errorf("single %v: in the layer's hub %v, bucket %q", single, ok, e.Zone)
		}
	}
	SetSingleFrame(false)
}

// TestGateStandsFiftyAhead (round 871, READ s:0x601eb0 / s:0xb46288): the
// gate stands 50 units before its maker along its facing; a wall on the way,
// or no navigation mesh, keeps the maker's spot.
func TestGateStandsFiftyAhead(t *testing.T) {
	// Jangan's frame: world (0, 0) is 97/168's local (960, 960); the wall at
	// local x 990 is world x 30.
	SetNavmesh(navmesh.NewWorld(nil, map[int]*navmesh.Region{worldmap.RegionID(97, 168): wallRegion(990)}))
	t.Cleanup(func() { SetNavmesh(nil) })
	e := world.Entity{Zone: "jangan", Pos: world.Position{X: 0, Y: 0, Z: 0}, Heading: 0}
	if p := gatePlace(e); math.Abs(p.X) > 1e-9 || math.Abs(p.Z-50) > 1e-9 {
		t.Errorf("facing +z: %+v, want (0, 50)", p)
	}
	e.Heading = math.Pi
	if p := gatePlace(e); math.Abs(p.X) > 1e-9 || math.Abs(p.Z+50) > 1e-9 {
		t.Errorf("facing -z: %+v, want (0, -50)", p)
	}
	e.Heading = math.Pi / 2 // toward the wall at x 30
	if p := gatePlace(e); p != e.Pos {
		t.Errorf("a wall 30 ahead: %+v, want the maker's spot %+v", p, e.Pos)
	}
	e.Heading = 3 * math.Pi / 2
	if p := gatePlace(e); math.Abs(p.X+50) > 1e-9 || math.Abs(p.Z) > 1e-9 {
		t.Errorf("facing -x, away from the wall: %+v, want (-50, 0)", p)
	}
	SetNavmesh(nil)
	if p := gatePlace(e); p != e.Pos {
		t.Errorf("no navigation mesh: %+v, want the maker's spot", p)
	}
}

// TestUnstuckInsideALayerIsItsStart (round 871, OURS): /unstuck inside an
// instanced world puts the character at the layer's start, as the entry
// places it -- not at the zone's landing, the middle of its centre region,
// which on the Wrecked Ship is open sea over the sea floor (prod).
func TestUnstuckInsideALayerIsItsStart(t *testing.T) {
	for _, single := range []bool{false, true} {
		SetSingleFrame(single)
		rig := newGWRig(t, nil, map[string]int{"Aria": 40})
		w := rig.open(t)
		aria := rig.players["Aria"]
		if err := EnterInstance(context.Background(), aria.sess, w, "test"); err != nil {
			t.Fatal(err)
		}
		rig.until("Aria", OpChangeZoneResult)
		e, ok := w.Hub.EntityByCharacterID(aria.charID)
		if !ok {
			t.Fatal("not in the layer")
		}
		zone, at, ok := unstuckTarget(aria.sess, e)
		if !ok || zone != "126/228" || at.X != 103 || at.Y != 693 || at.Z != -165 {
			t.Errorf("single %v: unstuck target %q %+v %v, want the start 126/228 (103, 693, -165)", single, zone, at, ok)
		}
		// The warp itself stays in the layer (warpTarget reads the region in
		// the warp's bucket): under -single-frame the label's bucket is the
		// open world's frame, and the region read there (by Jangan) took the
		// character out of its layer -- the exit NPC then answered code 3.
		if got := warpTarget(w.Hub, e.Zone, at); got != w.Hub {
			t.Errorf("single %v: the warp to the start leaves the layer", single)
		}
		d := gameWorldDeps()
		p, _ := placeOf(aria.sess)
		if _, err := warpVia(context.Background(), aria.sess, d.Equipment, d.Chars, rig.hub, nil, zone, e.Zone, at, p.frame, "/unstuck"); err != nil {
			t.Fatal(err)
		}
		rig.until("Aria", OpChangeZoneResult)
		if _, in := w.Hub.EntityByCharacterID(aria.charID); !in {
			t.Errorf("single %v: after the /unstuck warp the character is not in its layer", single)
		}
		if _, out := rig.hub.EntityByCharacterID(aria.charID); out {
			t.Errorf("single %v: after the /unstuck warp the character is in the open world", single)
		}
	}
	SetSingleFrame(false)
}
