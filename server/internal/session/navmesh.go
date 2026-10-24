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
		return
	}
	world.SetGroundFunc(navGround)
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

// navBlocked is the wander's probe (READ, ai.PickWanderLeg's note: the
// world's slot 12 walk from the position to 30 ahead, blocked on bit 0):
// whether a walk from (x, z) to (tx, tz) meets a wall.
func navBlocked(zone string, x, y, z, tx, tz float64) bool {
	r, ok := navWalk(zone, x, y, z, tx, tz)
	return ok && r.Blocked
}

// navMinLeg is the shortest clipped leg worth walking (OURS): a wall closer
// than this ahead leaves the mover standing.
const navMinLeg = 0.5

// navClipLeg is a leg's destination after the walk: where the first wall
// stops it, or the destination. NaN height: the walk settles it.
func navClipLeg(zone string, x, y, z, tx, tz float64) (float64, float64, bool) {
	r, ok := navWalk(zone, x, y, z, tx, tz)
	if !ok || !r.Blocked {
		return tx, tz, false
	}
	return r.X, r.Z, true
}
