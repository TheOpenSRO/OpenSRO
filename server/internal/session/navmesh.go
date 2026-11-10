package session

import (
	"log/slog"
	"math"
	"os"
	"sync/atomic"

	"github.com/TheOpenSRO/OpenSRO/server/internal/navmesh"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// The server's navigation mesh (round 812, internal/navmesh): cmd/server's
// -navmesh-dir. READ (docs/protocol/opcodes/movement.md): the original
// server steps every mover -- a player's 0x7021 leg, a monster's -- on its
// own copy of the navigation mesh and stops it at a blocking edge
// (CGObjMoverByDest, CRegionManagerBody::vslot_012). Without the flag
// nothing is walked here and movers keep their straight legs.
var navWorld atomic.Pointer[navmesh.World]

// moveTrace is OPENSRO_MOVE_TRACE (QA, round 812): every player leg's start,
// destination and wall, every stop claim and whether it was taken, and
// every wall arrival, at INFO.
var moveTrace = os.Getenv("OPENSRO_MOVE_TRACE") != ""

func traceMove(msg string, args ...any) {
	if moveTrace {
		slog.Info(msg, args...)
	}
}

// SetNavmesh installs the navigation mesh (nil: none), and with it the hub's
// walked heights (world.SetGroundFunc, round 822).
func SetNavmesh(w *navmesh.World) {
	navWorld.Store(w)
	if w == nil {
		world.SetGroundFunc(nil)
		world.SetWallFunc(nil)
		return
	}
	world.SetGroundFunc(navGround)
	world.SetWallFunc(navRunWall)
}

// navRunWall is world.WallFunc on the navigation mesh (round 857): a heading
// run walked `length` on from `from` with no slide, as every mover's step is
// (READ: CGObjMoverByCmd steps through slot 305 to the collision query,
// s:0x485740 -> CRegionManagerBody::vslot_012 s:0x98b300, and a blocking
// edge ends the movement). Before round 857 the server never walked a heading
// run (round 812's list): an arrow-key or sky-click run went through every
// wall, and its stop (0x7023's 0xB023) put the mover where the line had it --
// inside or beyond a building.
func navRunWall(zone string, from world.Position, dirX, dirZ, length float64) (world.Position, bool, bool) {
	r, ok := navWalk(zone, from.X, from.Y, from.Z, from.X+dirX*length, from.Z+dirZ*length)
	if !ok || math.IsNaN(r.Y) {
		return world.Position{}, false, false
	}
	return world.Position{X: r.X, Y: r.Y, Z: r.Z}, r.Blocked, true
}

// groundWalkLimit is the longest stretch navGround walks (OURS): about 17 ms
// of walking at the 1.7 us a unit MEASURED on Jangan's west bridge (round
// 822), past a minute of a horse's heading run. A leg longer than that keeps
// its straight-line height.
const groundWalkLimit = 10000.0

// navGround is world.GroundFunc on the navigation mesh (round 822, OURS): the
// height a no-slide walk from `from` toward (x, z) carries the mover at --
// its footing settled at `from` (SurfaceAt) and carried edge by edge, as the
// client's walk carries it frame to frame. A walk a wall stops short (a
// heading run the server does not clip) answers the surface at (x, z) under
// the wall's height. ok false with no mesh there, a dungeon, or past
// groundWalkLimit.
func navGround(zone string, from world.Position, x, z float64) (float64, bool) {
	if math.Hypot(x-from.X, z-from.Z) > groundWalkLimit {
		return 0, false
	}
	w := navWorld.Load()
	if w == nil {
		return 0, false
	}
	r, ok := navWalk(zone, from.X, from.Y, from.Z, x, z)
	if !ok || !r.Checked || math.IsNaN(r.Y) {
		return 0, false
	}
	if !r.Blocked {
		return r.Y, true
	}
	ox, oy, ok := entityFrame(zone)
	if !ok {
		return 0, false
	}
	if y := w.Height(ox, oy, x, z, r.Y); !math.IsNaN(y) {
		return y, true
	}
	return 0, false
}

// navArrivalHeight is the height an arrival at pos in zone stands at: the
// surface nearest pos.Y under the point (SurfaceAt's rule). READ (round 870,
// CGObj::EnterWorld s:0x485360): an object entering a world with no cell yet
// is resolved through the region manager's ResolveCellAndHeight (its log
// line names it) before it is placed, so an arrival point above a floor
// stands on that floor rather than falling to it. ok is false with no mesh
// there (a dungeon: the server walks no dungeon yet).
func navArrivalHeight(zone string, pos world.Position) (float64, bool) {
	w := navWorld.Load()
	if w == nil {
		return 0, false
	}
	ox, oy, ok := entityFrame(zone)
	if !ok {
		return 0, false
	}
	y := w.Height(ox, oy, pos.X, pos.Z, pos.Y)
	if math.IsNaN(y) {
		return 0, false
	}
	return y, true
}

// navFrameAnchor is the height the client anchors zone's frame on: the frame
// region's terrain at its block 0's vertex 8, local (160, 0) -- the client's
// MapmTerrainBuilder.near_row_middle_height of the frame's .m (World3D.
// _frame_anchor_height, round 570). MEASURED on the server's navigation mesh
// equal to the client's: Jangan's 97/168 -2.49, Togui's 126/228 833.58.
func navFrameAnchor(zone string) (float64, bool) {
	w := navWorld.Load()
	if w == nil {
		return 0, false
	}
	rx, ry, ok := entityFrame(zone)
	if !ok {
		return 0, false
	}
	g := w.Graph(rx<<8 | ry)
	if g == nil || g.Region == nil {
		return 0, false
	}
	h := g.Region.SampleHeight(160, 0)
	if math.IsNaN(h) {
		return 0, false
	}
	return h, true
}

// restoredHeight is a saved position's height read both ways (round 870):
// as the wire's region-local height (saved since round 870) and as the
// client's frame-anchored scene height plus the frame's anchor (saved
// before: the client sent scene heights). Each reading is resolved onto the
// surface nearest it (surfaceNear) and the one that lies nearer its surface
// is taken -- a saved height is within a step of the ground it stood on, the
// other reading is the anchor away (MEASURED 80..834 in the towns' and the
// Forgotten World's frames, -1800 in the Wrecked Ship's). No surface: saved.
func restoredHeight(saved, anchor float64, surfaceNear func(refY float64) (float64, bool)) float64 {
	h1, ok1 := surfaceNear(saved)
	h2, ok2 := surfaceNear(saved + anchor)
	switch {
	case ok1 && ok2:
		if math.Abs(h2-(saved+anchor)) < math.Abs(h1-saved) {
			return h2
		}
		return h1
	case ok1:
		return h1
	case ok2:
		return h2
	}
	return saved
}

// navRestoredHeight is restoredHeight on the navigation mesh for pos in zone.
func navRestoredHeight(zone string, pos world.Position) world.Position {
	a, ok := navFrameAnchor(zone)
	if !ok {
		return pos
	}
	pos.Y = restoredHeight(pos.Y, a, func(refY float64) (float64, bool) {
		p := pos
		p.Y = refY
		return navArrivalHeight(zone, p)
	})
	return pos
}

// navWalk walks from (x, y, z) toward (tx, tz) in zone's frame with no
// slide (the walk every mover uses, READ round 653). ok is false without a
// navigation mesh or a frame for the zone (a dungeon: OURS, the server walks
// no dungeon yet): the caller keeps its straight leg.
func navWalk(zone string, x, y, z, tx, tz float64) (navmesh.WalkResult, bool) {
	w := navWorld.Load()
	if w == nil {
		return navmesh.WalkResult{}, false
	}
	if _, dungeon := dungeonOf(zone); dungeon {
		return navmesh.WalkResult{}, false
	}
	ox, oy, ok := entityFrame(zone)
	if !ok {
		return navmesh.WalkResult{}, false
	}
	return w.Walk(ox, oy, x, y, z, tx, tz), true
}

// claimReachSlack is how far short of a client's claimed point the server's
// own walk may stop and still reach it (OURS, round 857): a wall stop's
// ContactPush and terrain nudge (0.2, READ) and the wire's float rounding.
const claimReachSlack = 0.5

// claimWalkLimit is the longest claim walked (OURS): past a second of the
// fastest run (/speed 10 is 1,075 a second) a claim is not one the
// allowance can take anyway.
const claimWalkLimit = 1200.0

// claimUnreached is whether a client's claim that e stands at pos lies past a
// wall from where the server has e (round 857): the server walks there on its
// own mesh, from e's walked height (world.LegGround) or its stored one, and a
// wall that stops the walk more than claimReachSlack short refuses the claim
// (world.Bound.Unreached; the caller corrects the client). Without a mesh, or
// with nothing to walk, false.
func claimUnreached(e world.Entity, pos world.Position) bool {
	if math.Hypot(pos.X-e.Pos.X, pos.Z-e.Pos.Z) > claimWalkLimit {
		return false // the claim's allowance refuses it, or a named point takes it
	}
	y := e.Pos.Y
	if wy, ok := world.LegGround(e); ok {
		y = wy
	}
	r, ok := navWalk(e.Zone, e.Pos.X, y, e.Pos.Z, pos.X, pos.Z)
	if !ok || !r.Checked || !r.Blocked {
		return false
	}
	return math.Hypot(r.X-pos.X, r.Z-pos.Z) > claimReachSlack
}

// navBlocked is the wander's probe (READ, ai.PickWanderLeg's note: the
// world's slot 12 walk from the position to 30 ahead, blocked on bit 0):
// whether a walk from (x, z) to (tx, tz) meets a wall.
func navBlocked(zone string, x, y, z, tx, tz float64) bool {
	r, ok := navWalk(zone, x, y, z, tx, tz)
	return ok && r.Blocked
}

// HatchFooting is where a hatch of a nest at (x, y, z) lands when its offset
// puts it at (tx, tz) (round 879, READ Nest_Hatch's placement GObjPC::
// FUN_005f6eb0): the world's line test from the nest's point to the hatch
// point (DAT_00cc387c slot 0x30 with the nest's position as the source,
// s:0x5f704f..0x5f7068) answers bit 0 for a wall in between, and then no
// monster is made and the nest's out-flag is set (s:0x5f712e..0x5f7133; the
// nest halves its delay, Nest_Hatch s:0x5607b0). Otherwise the monster
// enters the world at the walk's end, its height the surface the walk
// carried it on from the nest's (CGObj::EnterWorld s:0x485360 resolves an
// object's cell and height). OpenSRO's walk is the no-slide one every mover
// uses (navWalk). Without a mesh there (no navigation mesh, a dungeon) the
// nest's own height is kept.
func HatchFooting(zone string, x, y, z, tx, tz float64) (ty float64, blocked bool) {
	r, ok := navWalk(zone, x, y, z, tx, tz)
	if !ok || !r.Checked || math.IsNaN(r.Y) {
		return y, false
	}
	if r.Blocked {
		return y, true
	}
	return r.Y, false
}

// SurfaceNear is the walkable surface nearest height y at (x, z) in zone
// (navArrivalHeight's rule: an object entering the world stands on its
// cell), y itself without a mesh there (round 879: a trigger's LOAD_MONSTER
// at a player in an instance).
func SurfaceNear(zone string, x, y, z float64) float64 {
	if h, ok := navArrivalHeight(zone, world.Position{X: x, Y: y, Z: z}); ok {
		return h
	}
	return y
}

// navLegEnd is a leg's end after the walk (round 812: where the first wall
// stops it, or the destination) and the height the walk ends at (round 879,
// for a monster that carries its height): NaN when no mesh walked it.
func navLegEnd(zone string, x, y, z, tx, tz float64) (ex, ez, ey float64, clipped bool) {
	r, ok := navWalk(zone, x, y, z, tx, tz)
	if !ok || !r.Checked {
		return tx, tz, math.NaN(), false
	}
	if !r.Blocked {
		return tx, tz, r.Y, false
	}
	return r.X, r.Z, r.Y, true
}

// navMinLeg is the shortest clipped leg worth walking (OURS): a wall closer
// than this ahead leaves the mover standing.
const navMinLeg = 0.5
