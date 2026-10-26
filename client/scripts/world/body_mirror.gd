extends RefCounted
class_name BodyMirror

## Round 828: a body in the world is drawn as the original draws it, not as
## its mirror image.
##
## The original is Direct3D, left-handed; Godot is right-handed, and the
## readers keep the files' coordinates as written (BmsReader, BskReader,
## BanReader). Round 61 put the world right with one z -> -z on the terrain
## group (scale.z = -1), which carries every placed object. Bodies hang
## outside that group (the player, other players, NPCs, monsters, pets, rides)
## and were drawn raw: a body's front is its own -Z, and turning it PI to face
## the node's +Z (round 31) turns it, it does not un-mirror it. MEASURED
## (tools/probe_weapon_hands.gd): an unmirrored CHAR_EU_MAN_NOBLE faces -Z
## (right foot to right toe) with `Bip01 R Hand` at x -6.96 -- on its LEFT
## side, (R hand - L hand) . right = -13.92. So every weapon on `Bip01 R
## HandMid` (the files' own bone, READ CCompChar::FUN_00c4fc70 via
## SkinnedBsrAssembler) showed in the left hand, every shield (`Bip01 L
## Hand`) on the right arm -- the user's report: "the two handed sword in the
## original game is held in the right hand not the left like ours". The
## screens that draw a body in their own D3D space (the paper doll, the
## portrait, the select and create stages: their `D3DSpace` node, scale.z =
## -1) were right already.
##
## OURS: the skeleton's own x is negated in the world. An x mirror in the
## body's frame is the z -> -z of the world composed with a turn of PI, and it
## leaves the body's -Z front (and every heading read off it:
## SkillEffects.heading_of, MonsterMotion.facing_yaw) where it was. Godot
## flips a mirrored instance's face culling itself (round 61); CrowdGpu, whose
## far instances are the identity, flips its twin shaders' cull instead.

## The mirror on a body skeleton (or a ghost's local transform): x negated.
const SCALE := Vector3(-1.0, 1.0, 1.0)

## Mirrors `skel`, a body's skeleton put in the world. Idempotent. Read a
## mirrored node's size with absf: Godot hands a reflection's scale back with
## every component negative once its transform is set whole (Basis.get_scale).
static func apply(skel: Node3D) -> void:
	if skel != null and not is_mirrored(skel):
		var s := skel.scale.abs()
		skel.scale = Vector3(-s.x, s.y, s.z)

## Whether `skel` carries the mirror.
static func is_mirrored(skel: Node3D) -> bool:
	return skel != null and skel.transform.basis.determinant() < 0.0

## `t` with a body's mirror taken off its right (a node that holds a mirrored
## skeleton and copies a mirrored body's transform: a dummy ride's root).
static func unmirrored(t: Transform3D) -> Transform3D:
	return Transform3D(t.basis * Basis.from_scale(SCALE), t.origin)
