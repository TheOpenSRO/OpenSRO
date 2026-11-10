package main

import (
	"io"
	"log/slog"
	"math"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/navmesh"
	"github.com/TheOpenSRO/OpenSRO/server/internal/nest"
	"github.com/TheOpenSRO/OpenSRO/server/internal/session"
	"github.com/TheOpenSRO/OpenSRO/server/internal/worldmap"
)

// TestRound879InstanceHatchStandsOnItsDeck: an instance's field nest on a
// deck ~960 over the terrain hatches its monsters on the deck, carrying the
// height (before: y 0, which the client stood on the sea floor's terrain --
// counted by the hive, never seen), and a hatch offset past the deck's wall
// fails and is tried again, as the original's (READ s:0x5f704f).
func TestRound879InstanceHatchStandsOnItsDeck(t *testing.T) {
	deck := &navmesh.CollisionMesh{
		Vertices: []navmesh.CVertex{{X: -100, Y: 0, Z: -100}, {X: 100, Y: 0, Z: -100}, {X: 100, Y: 0, Z: 100}, {X: -100, Y: 0, Z: 100}},
		Cells:    []navmesh.CCell{{A: 0, B: 1, C: 2}, {A: 0, B: 2, C: 3}},
		Outline: []navmesh.CEdge{
			{V0: 0, V1: 1, CellFrom: 0, CellTo: navmesh.NoCell, Flags: 3},
			{V0: 1, V1: 2, CellFrom: 0, CellTo: navmesh.NoCell, Flags: 3},
			{V0: 2, V1: 3, CellFrom: 1, CellTo: navmesh.NoCell, Flags: 3},
			{V0: 3, V1: 0, CellFrom: 1, CellTo: navmesh.NoCell, Flags: 3},
		},
		Internal: []navmesh.CEdge{{V0: 0, V1: 2, CellFrom: 0, CellTo: 1, Flags: 4}},
	}
	r := &navmesh.Region{
		Cells:        []navmesh.Cell{{MinX: 0, MinZ: 0, MaxX: navmesh.RegionSpan, MaxZ: navmesh.RegionSpan, Objects: []uint16{0}}},
		Tiles:        make([]navmesh.Tile, navmesh.TileCount),
		Heights:      make([]float32, navmesh.HeightCount),
		PlaneTypes:   make([]byte, navmesh.PlaneCount),
		PlaneHeights: make([]float32, navmesh.PlaneCount),
		Objects:      []navmesh.MapObject{{ResourceID: 879, X: 960, Y: -842, Z: 960}},
	}
	for i := range r.Heights {
		r.Heights[i] = -1800
	}
	session.SetNavmesh(navmesh.NewWorld(map[uint32]*navmesh.CollisionMesh{879: deck}, map[int]*navmesh.Region{worldmap.RegionID(97, 168): r}))
	t.Cleanup(func() { session.SetNavmesh(nil) })
	hub := combat.NewHub()
	rs := &respawnScheduler{monsters: hub, logger: slog.New(slog.NewTextHandler(io.Discard, nil)), quiet: true}
	spec := monsterSpec{Name: "Ghost", Zone: "jangan", Level: 101, MaxHP: 100}
	d := hatchDataOf(spec)
	d.homeY, d.footing = -800, true
	sl := &nest.Slot{ID: 1, Cap: 7, Budget: 7, Active: true, Data: d}
	id, ok, failed := rs.hatch(sl, nest.HatchRoll{}, 40, -30)
	m, alive := hub.Get(id)
	if !ok || failed || !alive || math.Abs(m.Y+842) > 1e-6 || !m.HasHeight {
		t.Fatalf("a hatch on the deck: ok %v failed %v, monster %+v; want y -842 with its height", ok, failed, m)
	}
	if _, ok, failed := rs.hatch(sl, nest.HatchRoll{}, 160, 0); ok || !failed {
		t.Fatalf("a hatch past the deck's wall: ok %v failed %v, want a failed placement", ok, failed)
	}
	// The open world's nests keep their y 0 and no height.
	d2 := hatchDataOf(spec)
	id2, _, _ := rs.hatch(&nest.Slot{ID: 2, Cap: 1, Budget: 1, Active: true, Data: d2}, nest.HatchRoll{}, 40, -30)
	if m2, _ := hub.Get(id2); m2.Y != 0 || m2.HasHeight {
		t.Fatalf("an open-world hatch %+v, want y 0 and no height", m2)
	}
	// A nest whose every offset meets the wall hatches on its own point at
	// last (OURS: a hive that cannot fill never fires its trigger).
	d.fails = 0
	for i := 0; i < hatchFailLimit-1; i++ {
		if _, ok, _ := rs.hatch(sl, nest.HatchRoll{}, 160, 0); ok {
			t.Fatalf("placed after %d failures", i)
		}
	}
	id3, ok, _ := rs.hatch(sl, nest.HatchRoll{}, 160, 0)
	if m3, _ := hub.Get(id3); !ok || m3.X != 0 || m3.Z != 0 || math.Abs(m3.Y+842) > 1e-6 {
		t.Fatalf("after %d failures: ok %v monster %+v, want the nest's point on the deck", hatchFailLimit, ok, m3)
	}
}
