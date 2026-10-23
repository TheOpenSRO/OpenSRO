extends RefCounted
class_name SlopeTilt

## Round 813: monsters and COS (pets, horses, transports) lean with the ground
## they stand on; players, NPCs and guards stay upright. Everything here is
## READ from `sro_client.exe` (decompile /var/tmp/decomp_client, asm
## /var/tmp/sro_client.asm on the render box; docs/protocol/slope_tilt.md has
## every address) unless it says otherwise.
##
## - **Who.** At its appear (`GlobalDataManager::FUN_009d17e0`, CICharactor
##   slot 27, and `CICMonster::vslot_025`) a character that IsKindOf CICMonster
##   (0xef1a84, monsters and CICMonsterNPC) or CICCos (0xeef6f0) copies its
##   characterdata column 80 to `+0x74c` and fills a table of two factor pairs
##   from its bytes, each / 100 (`FUN_009c78f0`): pair 0 = (byte 3, byte 2),
##   pair 1 = (byte 1, byte 0); pair 0 is chosen (`FUN_009c9350(0)`, the only
##   index any caller passes). A player (CICPlayer), an NPC or a guard
##   (CICGuard : CICNPC) never does, so `+0x74c` stays 0 and nothing tilts it.
##   MEASURED: 0x64146414 (1.0, 0.2) on every horse, tiger, pet and transport,
##   0x14141414 (0.2, 0.2) on most monsters, 0x64646464 on 412 ghosts, 0 on
##   621 monsters (never tilted: `+0x74c` 0 never marks the normal stale).
## - **When.** Slot 15's position (2) and heading (3) events mark the normal
##   stale while `+0x74c` is not 0 (0x9cf23c..0x9cf245). The next update
##   (`FUN_009d1d60`) asks the cell under the character for its normal
##   (NavGraph.ground_normal_at; straight up in a dungeon) and eases toward it
##   from where it is: a linear lerp over NORMAL_EASE_S (`FUN_009c8ac0`,
##   `FUN_009c8b30`), restarted at every stale mark -- so while it moves, every
##   frame. The factors ease from (0, 0) to the pair over 1 / FACTOR_SPEED
##   (`FUN_009c8c40`), starting at the first normal.
## - **The matrix** (`FUN_009c9400`, rebuilt only on a frame either ease moved):
##   with D the flat heading and n the eased normal, side = n x D, forward =
##   side x n; forward's height times factor 0, side's times factor 1; both
##   normalised; up = forward x side, normalised. The rows (side, up, forward)
##   replace the model's rotation; its origin, the feet, stays. Pitch and roll
##   are scaled separately, so the matrix is not quite orthogonal; it is
##   written as it is.

## The normal's ease (READ: 0.3 at 0xd82f00, CICharactor's constructor
## 0x9d2d0a; speed 1 / 0.3 in `FUN_009c96c0`).
const NORMAL_EASE_S := 0.3
## The factors' ease (READ: 10.0 at 0xd81a88, stored as the speed at
## 0x9d2d61; 0.1 s at 0xe1b7fc as its duration).
const FACTOR_SPEED := 10.0
## Each column-80 byte over 100 (READ: 100.0 at 0xe1b7d8).
const FACTOR_DIVISOR := 100.0

## Factor pair 0 of a characterdata column-80 value: (forward, side).
static func factors(value: int) -> Vector2:
	var u := value & 0xFFFFFFFF
	return Vector2(float((u >> 24) & 0xFF) / FACTOR_DIVISOR, float((u >> 16) & 0xFF) / FACTOR_DIVISOR)

## One character's tilt: its two eases and what it was last drawn with.
class State:
	## The eased normal, in the region's own (un-mirrored) frame.
	var n := Vector3.UP
	var n_from := Vector3.UP
	var n_to := Vector3.UP
	var n_t := 1.0
	var n_done := true
	var k := Vector2.ZERO
	var k_from := Vector2.ZERO
	var k_to := Vector2.ZERO
	var k_t := 0.0
	var k_done := true
	## Set by the first normal (`+0x2e4`); before it nothing is rebuilt.
	var enabled := false
	## A position or heading change not yet answered with a normal.
	var stale := true
	var last_pos := Vector3.INF
	var last_front := Vector3.INF
	## The model node's own transform under its body before any tilt.
	var rest := Transform3D.IDENTITY
	var has_rest := false
	## The tilt last applied, in the body's frame.
	var applied := Basis.IDENTITY
	## The region frame's map to the world (the terrain group's basis) the
	## normal was read in.
	var region_basis := Basis.IDENTITY

	## The appear: pair 0 is chosen (`FUN_009c9350(0)` from (0, 0)).
	func _init(value: int = 0) -> void:
		k_to = SlopeTilt.factors(value)
		k_done = false
		k_t = 0.0

	## A new normal to ease to, from where it is (`FUN_009c93e0`).
	func retarget(normal: Vector3) -> void:
		enabled = true
		n_from = n
		n_to = normal
		n_t = 0.0
		n_done = false

	## Both eases over `dt` seconds; true when either moved (`FUN_009c9400`'s
	## test, 0x9c9446).
	func advance(dt: float) -> bool:
		if not enabled:
			return false
		var moved := false
		if not n_done:
			n_t += dt / SlopeTilt.NORMAL_EASE_S
			if n_t > 1.0:
				n_t = 1.0
				n = n_to
				n_done = true
			else:
				n = n_from + (n_to - n_from) * n_t
			moved = true
		if not k_done:
			k_t += dt * SlopeTilt.FACTOR_SPEED
			if k_t > 1.0:
				k_t = 1.0
				k = k_to
				k_done = true
			else:
				k = k_from + (k_to - k_from) * k_t
			moved = true
		return moved

## The model's rotation for flat heading `d` on normal `n` with factors `k`,
## in the region's frame, as the columns of a basis: the images of the model's
## X, Y and Z axes (`FUN_009c9400`'s rows; D3D row vectors).
static func frame(n: Vector3, d: Vector3, k: Vector2) -> Basis:
	var side := n.cross(d)
	var fwd := side.cross(n)
	fwd.y *= k.x
	side.y *= k.y
	if side.length_squared() == 0.0 or fwd.length_squared() == 0.0:
		return frame(Vector3.UP, d, Vector2.ZERO)
	fwd = fwd.normalized()
	side = side.normalized()
	return Basis(side, fwd.cross(side).normalized(), fwd)

## The tilt as a map of the region's frame: the tilted frame times the upright
## one's inverse (the upright frame, n straight up, is orthonormal). Identity
## on flat ground whatever the factors.
static func tilt(n: Vector3, d: Vector3, k: Vector2) -> Basis:
	var flat := Vector3(d.x, 0.0, d.z)
	if flat.length_squared() == 0.0:
		return Basis.IDENTITY
	flat = flat.normalized()
	return frame(n, flat, k) * frame(Vector3.UP, flat, Vector2.ZERO).transposed()

## The tilt in the scene: `region_basis` maps the region's frame to the world
## (the terrain group's, mirrored on z), `body_basis` is the body's own; the
## result is the model node's transform under the body, before its rest
## transform. `front_world` is any horizontal-ish direction along the model's
## front-back axis (its sign does not matter: the tilt of D and of -D is the
## same map).
static func in_body(n_region: Vector3, front_world: Vector3, k: Vector2, region_basis: Basis, body_basis: Basis) -> Basis:
	var to_region := region_basis.inverse()
	var t := tilt(n_region, to_region * front_world, k)
	var world := region_basis * t * to_region
	return body_basis.inverse() * world * body_basis
