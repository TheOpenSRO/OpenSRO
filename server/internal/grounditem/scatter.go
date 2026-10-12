package grounditem

import "math"

// Where a dropped stack lands (round 785). READ in SR_GameServer.exe: every
// drop -- a monster's (CGObjChar::ForceDropItem 0x004aa680, reached through
// the dropper's vtable slot 149 from the kill path, e.g.
// CGObjMob_DropRank7GoldPiles 0x009348f0), a player's item
// (CGStorage::DropItem 0x004b2ab0) and a player's gold (FUN_00526b00) -- hands
// the new CGItem the DROPPER'S OWN position (its +0x7c..+0x90: region, x, y,
// z) and calls the item's vtable slot 311, FUN_0048fdf0, which scatters it:
//
//	angle  = rand() / 32767.0 * 2 pi + 0.0   (.rdata 0xb45af8, 0xb45c18, 0xb45ab0)
//	radius = min + (max - min) * rand() / 32767.0
//	x += f1(angle) * radius;  z += f2(angle) * radius   (0x48ff2d .. 0x48ff70)
//	heading = rand() / 32767.0 * 2 pi        (a third rand, the item's own yaw)
//
// with [min, max] = [8.0, 20.0] (.rdata 0xb45e14, 0xb45b20) by default. So a
// drop lands on a RING around the dropper, never closer than 8 units, and the
// radius is uniform in [8, 20] (not uniform over the ring's area). f1/f2 are
// the CRT's cos and sin (FUN_00489490 -> 0x9fc0b0, FUN_004894b0 -> 0x9fbf80);
// which is which was not settled and does not matter for a uniform angle.
//
// The function then enters the item into the world at that point
// (CGItemMonsterCapsule::EnterWorld 0x0048fa30 -> CGObj::EnterWorld
// 0x00485360), which resolves the navmesh cell and its height
// ("CGObj::EnterWorld Failed!!! at ResolveCellAndHeight()"); when that fails
// -- the point is off the walkable mesh -- FUN_0048fdf0 enters it again at the
// dropper's own position, unscattered. Nothing in it looks at the items
// already lying there: two stacks CAN land on one spot, as often as two
// random points on the ring coincide. (OpenSRO's server has no navmesh, so it
// cannot make the off-mesh retry, and no height; the client grounds each
// stack under the server's x, z -- GroundItems.spawn.)
//
// A wider band applies when the object at the item's +0x14c is a monster
// (vtable slot 10, IsMonster) of class (CGObjMob::GetMonsterClass 0x004c1c60,
// +0x1cd8 & 0xf; jump table 0x49018c): 3 and 8 [10, 30], 4 [10, 40], 5
// [20, 100], anything else the default. But +0x14c is written only by the
// CGItem constructor (zero, 0x48f8b2) and by the setter FUN_0048f990 (CGItem
// slot 321, reached only through `[vtable+0x504]` calls: the pick, this
// scatter's own clear, the inventory and market moves) -- none of them on the
// drop path between ForceDropItem's creation of the item (FUN_00489730) and
// the scatter. So a monster's drop is scattered over the DEFAULT band; when the
// class bands are reached was not found (OPEN), and OpenSRO does not use them.
const (
	ScatterMinRadius = 8.0  // .rdata 0xb45e14
	ScatterMaxRadius = 20.0 // .rdata 0xb45b20
)

// randMax is the MSVC CRT's RAND_MAX, the divisor FUN_0048fdf0 uses
// (.rdata 0xb45af8 = 32767.0); rand() answers 0..32767 inclusive.
const randMax = 32767

// Scatter is FUN_0048fdf0's placement: the point a stack dropped by something
// standing at (x, z) lands on, given two rand() draws in [0, 32767] -- the
// angle's, then the radius's, in the engine's order. The radius is
// ScatterMinRadius + (ScatterMaxRadius - ScatterMinRadius) * r / 32767, at
// angle a / 32767 * 2 pi, x along its cosine and z along its sine.
func Scatter(x, z float64, angleDraw, radiusDraw int) (float64, float64) {
	angle := float64(clampDraw(angleDraw)) / randMax * 2 * math.Pi
	radius := ScatterMinRadius + (ScatterMaxRadius-ScatterMinRadius)*float64(clampDraw(radiusDraw))/randMax
	return x + math.Cos(angle)*radius, z + math.Sin(angle)*radius
}

func clampDraw(d int) int {
	if d < 0 {
		return 0
	}
	if d > randMax {
		return randMax
	}
	return d
}

// ScatterDraw is one rand() as the engine's CRT returns it: uniform over
// 0..32767, from intn (math/rand's Intn, or a test's).
func ScatterDraw(intn func(int) int) int { return intn(randMax + 1) }
