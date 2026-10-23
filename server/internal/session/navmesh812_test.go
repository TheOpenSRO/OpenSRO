package session

import (
	"math"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/ai"
	"github.com/TheOpenSRO/OpenSRO/server/internal/navmesh"
	"github.com/TheOpenSRO/OpenSRO/server/internal/worldmap"
)

// wallRegion is a flat synthetic region with a wall (flag 3) along local
// x = wallX, the tiles left of it cell 0 and right of it cell 1.
func wallRegion(wallX float32) *navmesh.Region {
	split := int(wallX / navmesh.TileSize)
	r := &navmesh.Region{
		Cells: []navmesh.Cell{
			{MinX: 0, MinZ: 0, MaxX: wallX, MaxZ: navmesh.RegionSpan},
			{MinX: wallX, MinZ: 0, MaxX: navmesh.RegionSpan, MaxZ: navmesh.RegionSpan},
		},
		Tiles:        make([]navmesh.Tile, navmesh.TileCount),
		Heights:      make([]float32, navmesh.HeightCount),
		PlaneTypes:   make([]byte, navmesh.PlaneCount),
		PlaneHeights: make([]float32, navmesh.PlaneCount),
		InternalEdges: []navmesh.Edge{{AX: wallX, AZ: 0, BX: wallX, BZ: navmesh.RegionSpan, Flags: 3,
			CellFrom: 0, CellTo: 1, RegionFrom: -1, RegionTo: -1}},
	}
	for i := range r.Tiles {
		if i%navmesh.TileMapSide >= split {
			r.Tiles[i].Cell = 1
		}
	}
	return r
}

// Round 812: with the navigation mesh a monster's chase stops at the wall
// between it and its target (READ: the server's mover stops at a blocking
// edge), where before it ran straight through.
func TestRound812ChaseStopsAtAWall(t *testing.T) {
	battleForTest(t, true)
	f := startBattleFixture(t, 8121, 0, 0)
	// Jangan's frame: world (0, 0) is region 97/168's local (960, 960); a
	// wall at local x 990 is world x 30.
	SetNavmesh(navmesh.NewWorld(nil, map[int]*navmesh.Region{worldmap.RegionID(97, 168): wallRegion(990)}))
	t.Cleanup(func() { SetNavmesh(nil) })
	m := f.monsters.SpawnSpecies("jangan", chaseMangyang, 60, 0, 0, 1000, 0, 15, 0)
	now := aiT0
	monsterAITick(now)
	now = now.Add(MonsterAITick)
	noteStruck(f.monsters, m.ID, f.aria)
	f.rec.reset()
	monsterAITick(now)
	if st := stateOf(t, f.a, m.ID); st != ai.StateBattle {
		t.Fatalf("state %v, want BATTLE", st)
	}
	moves := f.rec.of(m.ID)
	if len(moves) != 1 {
		t.Fatalf("%d moves, want the chase leg: %+v", len(moves), moves)
	}
	// Stopped 0.2 short of the wall toward its own cell's centre (READ
	// FUN_009c1050), not at the stop distance 10 from Aria.
	if d := moves[0].DestX; math.Abs(float64(d)-30.2) > 0.05 || math.Abs(float64(moves[0].DestZ)) > 0.2 {
		t.Fatalf("the chase leg ends at (%.2f, %.2f), want the wall at x 30.2", moves[0].DestX, moves[0].DestZ)
	}
	// The wander's probe: a wall within 30 ahead is blocked.
	if !navBlocked("jangan", 60, 0, 0, 10, 0) || navBlocked("jangan", 60, 0, 0, 90, 0) {
		t.Error("the probe: toward the wall blocked, away from it clear")
	}
	// No mesh: nothing is clipped.
	SetNavmesh(nil)
	if _, _, clipped := navClipLeg("jangan", 60, 0, 0, 10, 0); clipped {
		t.Error("clipped with no navigation mesh")
	}
}
