package session

// The caster's move (round 785): Ghost Walk ('tele'), the Europe Teleport
// ('tel2') and the Warrior's Sprint ('tel3'), as FUN_005862e0 builds them --
// docs/protocol/skill_hit_block.md "Ghost Walk, Teleport and Sprint".

import (
	"math"

	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// groundMove is the move a 'tele' or 'tel2' row makes toward a ground point:
// its distance limit (value[1], world units) and the action flag it sets
// (8 for 'tele', 2 for 'tel2'; FUN_005862e0 0x58638b / 0x586473, READ). ok
// is false for a row with neither. FUN_005862e0 is called with EAX = 'tele'
// and tests EAX first (0x586ba4..0x586bd4), so a row with both is 'tele'.
func groundMove(ref *refdata.Skill) (limit float64, flag uint8, ok bool) {
	if ref == nil {
		return 0, 0, false
	}
	if ref.HasParams() {
		r := ref.Runs()
		if v, has := r.Values("tele"); has {
			return float64(uint32(valueAt(v, 1))), ActionFlagMove, true
		}
		if v, has := r.Values("tel2"); has {
			return float64(uint32(valueAt(v, 1))), ActionFlagSnap, true
		}
		return 0, 0, false
	}
	// An export before the Params column: only 'tele' was exported.
	if ref.HasTele() {
		return float64(uint32(int32(ref.Tele1))), ActionFlagMove, true
	}
	return 0, 0, false
}

// sprintLimit is a 'tel3' row's limit (value[1]); ok false without one.
func sprintLimit(ref *refdata.Skill) (float64, bool) {
	if ref == nil || !ref.HasParams() {
		return 0, false
	}
	v, has := ref.Runs().Values("tel3")
	if !has {
		return 0, false
	}
	return float64(uint32(valueAt(v, 1))), true
}

func valueAt(v []int32, i int) int32 {
	if i < 0 || i >= len(v) {
		return 0
	}
	return v[i]
}

// teleportDestination is FUN_005862e0's clamp for a ground point (READ,
// 0x5864e0..0x5865a0): within limit world units of from -- the full 3-D
// length, x²+y²+z² -- the point itself; beyond it, from + unit(offset) x
// limit. A nearer point is a shorter move: nothing pushes it to the limit.
func teleportDestination(from, to world.Position, limit float64) world.Position {
	dx, dy, dz := to.X-from.X, to.Y-from.Y, to.Z-from.Z
	dist := math.Sqrt(dx*dx + dy*dy + dz*dz)
	if dist <= limit || dist == 0 {
		return to
	}
	k := limit / dist
	return world.Position{X: from.X + dx*k, Y: from.Y + dy*k, Z: from.Z + dz*k}
}

// sprintDestination is FUN_005862e0's 'tel3' branch (param_2 != 0, READ):
// the point is the target's position; within the limit the caster lands
// short of it by the two bodies' radii (vslot 0x560 of each) along the
// horizontal line from the target back toward the caster -- the y term is
// multiplied by the constant at 0xb45ab0 (INFERRED 0: a ground landing) --
// and beyond it at from + unit(offset) x limit.
func sprintDestination(from, target world.Position, radii, limit float64) world.Position {
	dx, dy, dz := target.X-from.X, target.Y-from.Y, target.Z-from.Z
	dist := math.Sqrt(dx*dx + dy*dy + dz*dz)
	if dist == 0 {
		return from
	}
	ux, uy, uz := dx/dist, dy/dist, dz/dist
	if dist <= limit {
		_ = uy
		return world.Position{X: target.X - ux*radii, Y: target.Y, Z: target.Z - uz*radii}
	}
	return world.Position{X: from.X + ux*limit, Y: from.Y + uy*limit, Z: from.Z + uz*limit}
}

// truncatedLanding is the landing as FUN_005862e0 stores it: region-local,
// each coordinate truncated toward zero (_ftol2, 0x5866c1..0x5866ea, READ),
// and the world position that truncated point is.
func truncatedLanding(zone string, p world.Position) (world.Position, uint16, int32, int32, int32) {
	region, ix, iy, iz := regionPoint(zone, p)
	x, z := worldOfRegionLocal(zone, region, float64(ix), float64(iz))
	return world.Position{X: x, Y: float64(iy), Z: z}, region, ix, iy, iz
}

// moveAction is the action block of a cast that moved its caster.
func moveAction(casterUID uint32, flag uint8, region uint16, ix, iy, iz int32) *ActionBlock {
	return &ActionBlock{Target: casterUID, TargetKind: ActionTargetCharacter, Flags: flag,
		MoveRegion: region, MoveX: ix, MoveY: iy, MoveZ: iz}
}
