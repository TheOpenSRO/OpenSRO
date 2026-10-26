extends RefCounted
class_name MonsterRide

## A monster's ride (round 809): the second object skilleffect.txt's
## `#section characterInfo` gives some monsters -- Ishade's ice crystal,
## Tiger Woman's blue tiger, Uruchi's dragon, Tahomet's devil -- and the
## die model and death effects of the same rows. docs/protocol/monster_ride.md
## has every address; in short (READ, sro_client.exe):
##
## - **Made** by the monster's spawn (CICMonster::vslot_025, 0x9d3a85..
##   0x9d3c51) when the row's ride column names a `.bsr`: a CICRide of its
##   own, its model the ride `.bsr` (FUN_009c4ec0), no scale call (INFERRED
##   scale 1), no material index (INFERRED material 0), started on group
##   "cart" type 0 (falling back to `default`), faded in over 2.0 s.
## - **Placed** every frame at the monster's position (CICRide::vslot_009,
##   0x9dabd0), by the row's Ride Type:
##   - none (0): turned with the monster's heading, and the monster's body
##     sits on the ride's `saddle` bone (ICharactor::FUN_009d05d0: the body's
##     world = saddle x the ride's world) -- the COS riders' rule;
##   - RT_FIXED (1): the identity rotation: it never turns, the monster stays
##     where it stands;
##   - RT_DUMMY (2): the monster's whole world transform (FUN_009d0660).
## - **Animated** with the monster: every play and stop on the monster
##   (0x9cfb40 / 0x9cfc10) is passed to the ride with the same type, fades and
##   speed; a type the ride lacks leaves its clip playing (INFERRED,
##   FUN_00a5b550's miss).
## - **Gone** with the monster: the same 1.5 s disappear (FUN_009d3c90).
##
## OURS: the ride is a child node of the monster's body (it fades, culls and
## frees with it); its skeleton is a clip-tick body of its own, so the
## monster's clip changes are mirrored where they are made
## (World3D._ride_mirror from _play_once and _set_monster_gait), never polled.

const NODE := "Ride"
const SADDLE_BONE := "saddle"
## READ: the group the ride's clips are played in (0xec62f0, "cart", from the
## initialiser 0xd77708); BsrReader falls back to `default`.
const GROUP := "cart"

var monster_id := -1
var body: Node3D = null
## The monster's own skeleton (the rider) and its own transform under the body.
var rider: Skeleton3D = null
var rider_rest := Transform3D.IDENTITY
var root: Node3D = null
var assembled: SkinnedBsrAssembler.AssembledCharacter = null
var ride_type := SoundTable.RIDE_NONE
var model := ""
var _saddle := -2
## Round 809's perf gate (OURS): a ride is posed with its monster, in the
## clip tick's own pass (World3D._pose_ride), not as a clip-tick body of its
## own -- 263 Tiger Women among 2,500 monsters cost +2.5 ms a frame that way,
## every ride's entry culled and tested each frame. The ride's clip: the one
## of the monster's clip's action type (`src` -> `clip`, cached per clip in
## `_clips`); a type the ride lacks leaves its clip running on its own clock
## (`follows` false). READ: the mirror itself (0x9cfb40); the ride's own
## crossfades are not drawn (OURS).
var src: Object = null
var clip: BanReader.ParsedAnimation = null
var clip_loop := true
var clip_start := 0.0
var follows := false
var _clips := {}
## How often (frames) World3D checks every ride's visibility and life.
const SYNC_EVERY := 10

func valid() -> bool:
	return is_instance_valid(body) and is_instance_valid(rider) and is_instance_valid(root) \
		and assembled != null and is_instance_valid(assembled.skeleton)

## The rider's world transform on the saddle (FUN_009d05d0): the saddle bone's
## pose times the ride's world, keeping the rider's own scale (OURS: the
## class scale, champion 1.5 etc., READ on the body by CICMonster::vslot_025;
## whether the seat's matrix carries it is OPEN).
static func seat(ride_world: Transform3D, saddle_pose: Transform3D, rider_scale: Vector3) -> Transform3D:
	var t := ride_world * saddle_pose
	t.basis = t.basis * Basis.from_scale(rider_scale)
	return t

## Puts the ride (and, for type none, its rider) where this frame wants them.
## Round 809's perf gate (+3.8 ms a frame over 2,500 monsters, 263 of them
## riding): every frame rewrote both transforms, waking each skinned subtree,
## and read the saddle pose of rides nobody posed. Both the ride's root and
## the rider are the body's children, so the seat is worked out in the body's
## frame (the same transform as FUN_009d05d0's world one) and written only
## when it changed, and only for a ride on view (its skeleton shown).
func place() -> void:
	match ride_type:
		SoundTable.RIDE_FIXED:
			# World yaw 0 whatever the body's heading: the root takes the
			# body's turn off.
			var want := Basis.IDENTITY
			if body.is_inside_tree():
				want = body.global_basis.orthonormalized().inverse()
			if not root.transform.basis.is_equal_approx(want) or root.transform.origin != Vector3.ZERO:
				root.transform = Transform3D(want, Vector3.ZERO)
		SoundTable.RIDE_DUMMY:
			# The rider's whole transform as it is now -- round 813: with its
			# slope tilt (SlopeTilt), which rider_rest does not carry.
			# Round 828: less the rider's mirror, which the ride's own
			# skeleton carries (BodyMirror).
			var want_root := BodyMirror.unmirrored(rider.transform)
			if not root.transform.is_equal_approx(want_root):
				root.transform = want_root
		SoundTable.RIDE_NONE:
			if root.transform != Transform3D.IDENTITY:
				root.transform = Transform3D.IDENTITY
			var skel := assembled.skeleton
			if _saddle == -2:
				_saddle = skel.find_bone(SADDLE_BONE)
			if _saddle < 0 or not skel.visible:
				return
			# Round 828: the saddle's pose carries the ride's mirror, so the
			# rider takes its size alone (get_scale is negative on a mirror).
			var t := seat(skel.transform, skel.get_bone_global_pose(_saddle), rider_rest.basis.get_scale().abs())
			if not rider.transform.is_equal_approx(t):
				rider.transform = t
		_:
			# Any other Ride Type: retail sets no matrix (0x9dabd0); OURS, the
			# body's own place.
			if root.transform != Transform3D.IDENTITY:
				root.transform = Transform3D.IDENTITY

## Puts the rider back on its own place under the body (the ride is gone).
func unseat() -> void:
	if is_instance_valid(rider):
		rider.transform = rider_rest

## Whether a dying monster's body is swapped for its row's die model (READ,
## the DEAD state's enter 0xa59cc0): unless the client's option byte
## (+0x12e, set to the inverse of the shard entry's flag at 0x868bb3..0x868bd9)
## is 0 AND the body has a type-36 clip of its own.
static func die_swaps(option_on: bool, has_own_36: bool) -> bool:
	return option_on or not has_own_36

## The key (ms) of the first type-1 event of `entry` (BsrReader.AnimationEntry),
## or -1: the DEAD state's animation event (0xa59e30) fires the row's Die
## Effect and Dead Effect on it.
static func first_hit_key(entry) -> int:
	if entry == null:
		return -1
	var best := -1
	for e in entry.events:
		var ev := e as PackedInt32Array
		if ev.size() >= 2 and ev[1] == BsrReader.AnimationEntry.EVENT_HIT and (best < 0 or ev[0] < best):
			best = ev[0]
	return best
