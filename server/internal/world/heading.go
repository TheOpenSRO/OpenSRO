package world

import "math"

// The heading a character faces, as the retail client keeps it on an object
// (+0x8c, radians in [0, 2 pi)) -- round 637's review follow-up. The client's
// own code is READ (docs/protocol/opcodes/movement.md, "How the client turns
// a moved object"); keeping one per character on the server is srrevamp's
// own, since srrevamp's movement is client-authoritative positions, not
// retail's 0x7021 destinations.
//
// The frame: srrevamp's positions are the client's world coordinates, whose z
// is the region-local z mirrored (client World3D.minimap_facing). The client's
// FUN_009ed130 heading of a region-local vector v is acos(-v.z/|v|) for
// v.x >= 0 and 2 pi minus that otherwise, and -v.z_local is world z -- so in
// srrevamp's frame a heading h faces (sin h, cos h) in (x, z).

// headingMinLength is FUN_009ed130's early return: a vector no longer than
// the float at 0xe1b848 (1e-6 as read) leaves the heading as it was.
const headingMinLength = 9.999999974752427e-07

// HeadingToward is FUN_009ed130 for a ground move of (dx, dz) in srrevamp's
// frame: the heading of the vector, or current when it is too short to have
// one. The y is ignored, as the client's FUN_009ecc70 zeroes it first.
func HeadingToward(current, dx, dz float64) float64 {
	length := math.Hypot(dx, dz)
	if !(length > headingMinLength) {
		return current
	}
	c := dz / length
	if c > 1 {
		c = 1
	} else if c < -1 {
		c = -1
	}
	a := math.Acos(c)
	if dx >= 0 {
		return a
	}
	return 2*math.Pi - a
}

// WireAngle is the u16 a retail spawn or angle message carries for heading h:
// the client adds pi/2 to the wire angle it reads (FUN_009c40b0, 0xe1b8f0) to
// make its heading, so the wire angle is h - pi/2 in [0, 2 pi), in the
// 65535-per-turn units of docs/protocol/opcodes/movement.md.
func WireAngle(h float64) float64 {
	a := math.Mod(h-math.Pi/2, 2*math.Pi)
	if a < 0 {
		a += 2 * math.Pi
	}
	return a
}
