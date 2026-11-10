package gameworld

import (
	"context"
	"math"
	"testing"
)

// TestDoorStopsAtItsFootprint (round 879): "it let me through the gate
// anyways". A closed door with a footprint stops a leg 0.2 short of the
// first outline edge it crosses, over the door's whole width; the block
// follows the frame point, not the region-local one; an open door stops
// nothing.
func TestDoorStopsAtItsFootprint(t *testing.T) {
	m := NewManager(ManagerConfig{Ref: doorRef(t)})
	// Region-local (500, 500); the layer's frame puts the same spot at
	// (-1200, 3000) (any point far from 500, 500 shows the difference).
	m.SetZonePlaces(map[string]ZonePlace{"POS_STRUCTURE_GOD_BIG_GATE_TOGUI_3": {Region: 0x7EE4, X: 500, Z: 500}})
	w, err := m.Open(context.Background(), 63, 1, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer w.Close(CloseManual)
	z := w.Zone("POS_STRUCTURE_GOD_BIG_GATE_TOGUI_3")
	// Round 869's rule read the region-local point as a frame point: a walk
	// across the door's frame spot passed, one across nothing at the local
	// spot was stopped.
	if doorBlocks(w, -1300, 3000, -1100, 3000) || !doorBlocks(w, 400, 500, 600, 500) {
		t.Fatal("the round 869 rule (no footprint) changed")
	}
	// A slab 150 wide along x and 30 deep along z at the frame point.
	z.Block = &DoorBlock{X: -1200, Z: 3000, Segs: [][4]float64{
		{-1275, 2985, -1125, 2985}, {-1125, 2985, -1125, 3015}, {-1125, 3015, -1275, 3015}, {-1275, 3015, -1275, 2985},
	}}
	if doorBlocks(w, 400, 500, 600, 500) {
		t.Fatal("the region-local point still blocks")
	}
	// Across the passage at the door's edge, 70 off its middle (the 40-unit
	// disc let this through).
	sx, sz, blocked := w.DoorStop(-1130, 2900, -1130, 3100)
	if !blocked || math.Abs(sx+1130) > 1e-9 || math.Abs(sz-(2985-0.2)) > 1e-9 {
		t.Fatalf("stop (%.2f, %.2f) blocked %v, want (-1130, 2984.8)", sx, sz, blocked)
	}
	// From the far side.
	if _, sz, blocked := w.DoorStop(-1200, 3100, -1200, 2900); !blocked || math.Abs(sz-3015.2) > 1e-9 {
		t.Fatalf("from the far side: z %.2f blocked %v, want 3015.2", sz, blocked)
	}
	// Beside the door: free.
	if _, _, blocked := w.DoorStop(-1300, 2900, -1300, 3100); blocked {
		t.Fatal("a leg beside the door was stopped")
	}
	w.Post(func() { w.SwitchEventZone("POS_STRUCTURE_GOD_BIG_GATE_TOGUI_3", true) })
	w.Sync()
	if _, _, blocked := w.DoorStop(-1200, 2900, -1200, 3100); blocked {
		t.Fatal("the open door still stops")
	}
}
