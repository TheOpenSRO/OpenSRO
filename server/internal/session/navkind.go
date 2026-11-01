package session

import (
	"math"

	"github.com/TheOpenSRO/OpenSRO/server/internal/navmesh"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Collision per kind of mover (round 851; docs/protocol/opcodes/movement.md,
// "Collision per kind of mover"). READ, SR_GameServer.exe:
//
//   - Every mobile object steps through one function, CGObjMobile::Update
//     (s:0x48b8c0) -> its mover's step (CGObjMoverByDest::vslot_003
//     s:0x48c4e0, CGObjMoverByCmd for a heading) -> slot 305 -> slot 231
//     (s:0x48b660) -> s:0x485740, which asks the region manager's collision
//     query CRegionManagerBody::vslot_012 (s:0x98b300) with two inputs that
//     come from the mover: a flag, 1 when the object IsPC (IGObj slot 7,
//     s:0x482560) or IsCOS (slot 11, s:0x4827b0) and 0 otherwise, and the
//     object's +0x38.
//   - +0x38 is 1 on every object (CGObj::vslot_000, s:0x48492a); a scan of
//     every store to +0x38 in the binary found no other writer on a game
//     object (MEASURED). It is the in-object walk's "walls apply" argument:
//     an outline edge with bit 0 blocks a mover from outside only when it is
//     1 (s:0x9b51e9), one with 0x02 or 0x10 blocks leaving only when it is
//     not 0 (s:0x9b55ac).
//   - The flag gates only the terrain walk's re-checks of the cell's objects
//     (FUN_009a05a0) after an object stopped the step (s:0x9a0a43), at a
//     cell crossing (s:0x9a0bd2) and at a region crossing (s:0x9a0eb8); the
//     object walk (CRTNavMeshObj::vslot_002 s:0x9b5a80) never reads it, and
//     the terrain wall's own stop (s:0x9a0c7e) re-checks for every mover.
//     A blocking edge is its flag byte & 3 (s:0x9a7810) for every mover.
//   - Nothing else of the mover reaches the walk: no radius, no BCRadius, no
//     characterdata column, no model's collision. A ridden COS is the mover
//     (s:0x4d2b20 steps the COS, then sets its rider on it; a riding PC does
//     not step, s:0x4ef300), so a rider is walked as its COS.
//
// So a player on foot, a horse, a trade transport and a pet -- ridden or
// following -- are blocked by exactly the same edges and stop the same way:
// at the first blocking edge, with no slide (navWalk; READ round 653, the
// terrain stop nudged at most 0.2 toward the cell's centre). A trade
// transport sticks on a tree or a wall exactly where a player on foot would;
// it is not the collision that differs but that a following COS walks a
// straight line to its owner's side and stops at whatever is in the way.
// Monsters and NPCs differ only in the flag: their walk takes an object's
// stop without walking the terrain up to it and skips the re-checks at cell
// and region crossings. INFERRED to change a stop only where a terrain wall
// and an object wall fall within one step of each other; not modelled (every
// kind walks navWalk), OPEN against the original running.

// MoverKind is what moves, for the collision query (READ s:0x485740).
type MoverKind int

const (
	// MoverPlayer is a player character on foot (IsPC).
	MoverPlayer MoverKind = iota
	// MoverCOS is a COS: a pet, a horse, a trade transport, a guard --
	// following its owner or ridden (IsCOS; a rider is walked as its COS).
	MoverCOS
	// MoverMonster is a monster (neither IsPC nor IsCOS).
	MoverMonster
	// MoverNPC is a town NPC (neither IsPC nor IsCOS).
	MoverNPC
)

// Collider is the two inputs the original's collision query takes from a
// mover (READ s:0x485740): RecheckObjects is the flag (IsPC || IsCOS) and
// ObjectWalls its +0x38 (1 on every object, s:0x48492a).
type Collider struct {
	RecheckObjects bool
	ObjectWalls    bool
}

// Collider is k's collision profile.
func (k MoverKind) Collider() Collider {
	return Collider{RecheckObjects: k == MoverPlayer || k == MoverCOS, ObjectWalls: true}
}

func (k MoverKind) String() string {
	switch k {
	case MoverPlayer:
		return "player"
	case MoverCOS:
		return "cos"
	case MoverMonster:
		return "monster"
	case MoverNPC:
		return "npc"
	}
	return "unknown"
}

// navWalkKind walks a mover of kind k from (x, y, z) toward (tx, tz) in
// zone's frame, with the original's collision for its kind: the no-slide
// walk to the first blocking edge (navWalk). Every kind is blocked by the
// same edges (see the note above); the kind is carried so a leg says what
// it walks, and so the profile is in one place. ok false: no navigation mesh
// or no frame for the zone (a dungeon), and the caller keeps its straight
// leg. y NaN: the landing height at (x, z).
func navWalkKind(k MoverKind, zone string, x, y, z, tx, tz float64) (navmesh.WalkResult, bool) {
	return navWalk(zone, x, y, z, tx, tz)
}

// MoverLeg is where a leg of a mover ends on the navigation mesh.
type MoverLeg struct {
	// End is the destination, or where the first blocking edge stops the
	// walk (its height the walk's when Walked).
	End world.Position
	// Wall: a blocking edge stops the walk short of the destination; the
	// mover stops there and its 0xB023 goes to the 3 x 3 (READ: a blocked
	// step ends the movement and sends 0xB023, movement.md).
	Wall bool
	// Stuck: the wall is closer than navMinLeg ahead -- the mover stays
	// where it stands (OURS: the original would take the step and be
	// nudged back toward its cell's centre, a standing mover in effect).
	Stuck bool
	// Walked: a navigation mesh covered the walk (false: no mesh, a
	// dungeon -- End is the destination, straight).
	Walked bool
}

// moverLeg is the leg a mover of kind k walks from `from` toward `to` in
// zone: the call a COS's leg makes (round 851: a following pet, horse or
// transport stops at the first wall or tree in its way, as a player on foot
// does). from.Y is the mover's height (NaN: the landing height).
func moverLeg(k MoverKind, zone string, from, to world.Position) MoverLeg {
	r, ok := navWalkKind(k, zone, from.X, from.Y, from.Z, to.X, to.Z)
	if !ok {
		return MoverLeg{End: to}
	}
	leg := MoverLeg{End: to, Walked: true}
	if r.Checked && !math.IsNaN(r.Y) {
		leg.End.Y = r.Y
	}
	if !r.Blocked {
		return leg
	}
	leg.Wall = true
	leg.End = world.Position{X: r.X, Y: r.Y, Z: r.Z}
	if math.IsNaN(leg.End.Y) {
		leg.End.Y = from.Y
	}
	if math.Hypot(r.X-from.X, r.Z-from.Z) < navMinLeg {
		leg.Stuck = true
	}
	return leg
}

// cosLegEnd is a COS leg's end (round 851, the hook in cosRuntime.tick):
// the destination, or where the first wall or tree stops the walk (moverLeg,
// MoverCOS). nil: no leg -- the wall is right ahead (the COS stands stuck
// there), or the COS is already walking to a wall stop within cosReaim of
// this one (OURS: FOLLOW's re-aim fires every tick while the leg's end, the
// wall, is far from the owner, and the side point's rand()%10 moves the stop
// along the trunk each time -- MEASURED round 851, 11 legs in 1.2 s before
// this rule). Called under cosWorld.mu.
func cosLegEnd(o *cosObj, pos, dest world.Position) *world.Position {
	leg := moverLeg(MoverCOS, o.zone, pos, dest)
	traceMove("move: cos leg", "cos", o.uid, "from_x", pos.X, "from_z", pos.Z, "to_x", dest.X, "to_z", dest.Z,
		"wall", leg.Wall, "stuck", leg.Stuck, "end_x", leg.End.X, "end_z", leg.End.Z)
	switch {
	case leg.Stuck:
		return nil
	case leg.Wall && o.moving && cosDistance(o.to, leg.End) < cosReaim:
		return nil
	}
	end := leg.End
	return &end
}
