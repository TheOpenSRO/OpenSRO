extends SceneTree

## Round 648: an animated map object whose `.bsk` root was never set -- the
## Dunhuang reeds' `[root]` stores a local translation of 3.7e24 -- is drawn
## where it stands, not smeared 1e24 units away. The user saw the reeds by
## every Donwhang-region teleport as dotted, hatched streaks across the sand
## and read them as broken water; the water was measured innocent (a pixel
## diff with the water off leaves the streaks, one with the reeds hidden
## removes them: docs/WORLD_ISSUES.md, round 648).
##
## Everything here is synthetic (docs/LEGAL.md): a two-bone skeleton under
## an unset root, a clip that keys the root at the origin, and a skinned
## triangle, served from memory, loaded through ObjectLoader and played by
## MapAnimation exactly as the world does.
## `godot4 --headless --path client --script res://scripts/world/map_animation_root_test.gd`
##
## The builder's new helpers are reached through the script's method list,
## so on a base without them this suite still runs and prints FAIL lines.

const F := preload("res://scripts/world/map_animation_fixture.gd")
const BUILDER_PATH := "res://scripts/assets/skeleton3d_builder.gd"

## The kind of value the real files hold in an unset root (the reeds' is
## (3.68e24, 2.54e17, 4.50e24)); synthetic, not copied.
const GARBAGE := Vector3(3.0e24, 2.0e17, 4.0e24)

var _failures := 0
var _node: Node3D

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _has(script: GDScript, fname: String) -> bool:
	for m in script.get_script_method_list():
		if m["name"] == fname:
			return true
	return false

## A `.bsk` in the fixture's layout, with each record's WORLD bind written
## too: the root's local translation `root_local`, BoneB on the root at
## `b_local` (world bind `b_world`), BoneC one unit above BoneB.
static func build_bsk(root_local: Vector3, b_local: Vector3, b_world: Vector3) -> PackedByteArray:
	var buf := PackedByteArray()
	buf.append_array(BskReader.MAGIC.to_ascii_buffer())
	F.u32(buf, 0)
	buf.append(0)
	F.lp(buf, "[root]")
	var root := PackedByteArray()
	root.resize(BskReader.ROOT_TRANSFORM_LEN)
	root.encode_float(0x10, 1.0) # w of the local rotation at 0x04
	root.encode_float(0x14, root_local.x)
	root.encode_float(0x18, root_local.y)
	root.encode_float(0x1c, root_local.z)
	root.encode_float(0x2c, 1.0) # w of the world rotation at 0x20
	buf.append_array(root)
	for bone in [["BoneB", "[root]", b_local, b_world], ["BoneC", "BoneB", Vector3(0, 1, 0), b_world + Vector3(0, 1, 0)]]:
		F.lp(buf, bone[0])
		F.lp(buf, bone[0])
		F.lp(buf, bone[1])
		var t := PackedByteArray()
		t.resize(BskReader.BONE_TRANSFORM_LEN)
		t.encode_float(0x0c, 1.0) # local w
		t.encode_float(0x10, bone[2].x)
		t.encode_float(0x14, bone[2].y)
		t.encode_float(0x18, bone[2].z)
		t.encode_float(0x28, 1.0) # world w
		t.encode_float(0x2c, bone[3].x)
		t.encode_float(0x30, bone[3].y)
		t.encode_float(0x34, bone[3].z)
		buf.append_array(t)
	var trailer := PackedByteArray()
	trailer.resize(8)
	buf.append_array(trailer)
	return buf

## A cyclic `.ban` keying `[root]` at the origin (as the reeds' clip does)
## and BoneB/BoneC at their rest, then BoneB turned, so t = 0 is the rest.
static func build_ban() -> PackedByteArray:
	var buf := PackedByteArray()
	buf.append_array(BanReader.MAGIC.to_ascii_buffer())
	F.u32(buf, 0)
	F.u32(buf, 0)
	F.lp(buf, "synth_reed")
	F.u32(buf, 2000)
	F.u32(buf, 30)
	F.u32(buf, 1)
	F.u32(buf, 3)
	for t in [0, 1000, 2000]:
		F.u32(buf, t)
	F.u32(buf, 3)
	var turn := Quaternion(Vector3.UP, 0.3)
	for bone in [["[root]", [Quaternion.IDENTITY, Quaternion.IDENTITY, Quaternion.IDENTITY], Vector3.ZERO],
			["BoneB", [Quaternion.IDENTITY, turn, Quaternion.IDENTITY], Vector3.ZERO],
			["BoneC", [Quaternion.IDENTITY, Quaternion.IDENTITY, Quaternion.IDENTITY], Vector3(0, 1, 0)]]:
		F.lp(buf, bone[0])
		F.u32(buf, 3)
		for q in bone[1]:
			for v in [q.x, q.y, q.z, q.w, bone[2].x, bone[2].y, bone[2].z]:
				F.f32(buf, v)
	return buf

func _initialize() -> void:
	var archive = F.archive()
	archive.add("res\\reed.bsr", F.build_bsr(["prim\\leaf.bms"], ["prim\\reed.ban"], "prim\\reed.bsk", [[0, 0]]))
	archive.add("prim\\reed.bsk", build_bsk(GARBAGE, Vector3.ZERO, Vector3.ZERO))
	archive.add("prim\\reed.ban", build_ban())

	# --- the builder: an unset root takes the rest its children imply ---
	var skel := BskReader.parse(build_bsk(GARBAGE, Vector3.ZERO, Vector3.ZERO))
	_check(skel != null and skel.bones.size() == 2, "r648: the synthetic skeleton parses (2 bones under [root])")
	if skel != null:
		var s := Skeleton3DBuilder.build_skeleton3d(skel)
		var root_rest := s.get_bone_rest(s.find_bone("[root]"))
		_check(root_rest.origin.length() < 0.001,
			"r648: an unset root (local translation %s) rests at the origin its children's world binds imply (got %s)" % [GARBAGE, root_rest.origin])
		var c := s.get_bone_global_rest(s.find_bone("BoneC")).origin
		_check(c.is_equal_approx(Vector3(0, 1, 0)), "r648: so BoneC's composed rest is its stored world bind (0, 1, 0) (got %s)" % c)
		s.free()
	# A root that IS set keeps its own rest, whatever its children say: 376
	# real skeletons have a set root their children's binds disagree with,
	# and they animate correctly from it (round 645) -- this round touches
	# only the unset ones.
	var sane := BskReader.parse(build_bsk(Vector3(0, 10, 0), Vector3.ZERO, Vector3(3, 0, 0)))
	if sane != null:
		var s2 := Skeleton3DBuilder.build_skeleton3d(sane)
		var r2 := s2.get_bone_rest(s2.find_bone("[root]")).origin
		_check(r2.is_equal_approx(Vector3(0, 10, 0)), "r648: a set root keeps its stored local translation (0, 10, 0) (got %s)" % r2)
		s2.free()
	var B := load(BUILDER_PATH) as GDScript
	_check(_has(B, "root_rest_usable") and _has(B, "root_rest_from_children"),
		"r648: Skeleton3DBuilder.root_rest_usable / root_rest_from_children exist")
	if _has(B, "root_rest_usable"):
		_check(B.call("root_rest_usable", Quaternion.IDENTITY, Vector3(0, 4767, 0)),
			"r648: the largest real set root, 4,767 units, is usable")
		_check(not B.call("root_rest_usable", Quaternion.IDENTITY, GARBAGE), "r648: 4e24 is not")
		_check(not B.call("root_rest_usable", Quaternion.IDENTITY, Vector3(0, NAN, 0)), "r648: NaN is not")
	if _has(B, "root_rest_from_children"):
		var off := BskReader.parse(build_bsk(GARBAGE, Vector3(5, 0, 0), Vector3(5, 2, 0)))
		var implied: Transform3D = B.call("root_rest_from_children", off)
		_check(implied.origin.is_equal_approx(Vector3(0, 2, 0)),
			"r648: a child at local (5, 0, 0) with world bind (5, 2, 0) implies the root at (0, 2, 0) (got %s)" % implied.origin)

	# --- through ObjectLoader and MapAnimation: where the vertices go ---
	_node = ObjectLoader.load_object(archive, "res\\reed.bsr")
	_check(_node != null and _node.get_node_or_null("MapSkeleton") != null, "r648: the synthetic reed loads animated")
	if _node == null or _node.get_node_or_null("MapSkeleton") == null:
		_finish()
		return
	root.add_child(_node)

var _frames := 0

func _process(_delta: float) -> bool:
	if _node == null:
		return false
	_frames += 1
	if _frames < 2:
		return false
	var skeleton := _node.get_node("MapSkeleton") as Skeleton3D
	var player := _node.get_node("MapAnimation") as AnimationPlayer
	var leaf := _node.get_node_or_null("leaf") as MeshInstance3D
	_check(leaf != null and leaf.skin != null, "r648: the leaf is skinned")
	if leaf == null or leaf.skin == null:
		_finish()
		return true
	for t in [0.0, 1.0]:
		player.play("default")
		player.seek(t, true)
		Skeleton3DBuilder.refresh_global_poses(skeleton)
		var arrays: Array = leaf.mesh.surface_get_arrays(0)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
		var worst := 0.0
		for i in range(verts.size()):
			var q := Vector3.ZERO
			for s in range(4):
				var w := weights[i * 4 + s]
				if w != 0.0:
					var k := bones[i * 4 + s]
					q += w * (skeleton.get_bone_global_pose(leaf.skin.get_bind_bone(k)) * leaf.skin.get_bind_pose(k) * verts[i])
			var d := q.distance_to(verts[i])
			worst = maxf(worst, d if is_finite(d) else INF)
		if t == 0.0:
			_check(worst < 0.001,
				"r648: at t = 0 (the rest) every skinned vertex is drawn where the still mesh has it (worst %s units off)" % str(worst))
		else:
			_check(worst > 0.001 and worst < 3.0,
				"r648: mid-clip the leaf sways by its bone's turn, a unit or two, not 1e24 (worst %s units)" % str(worst))
	_finish()
	return true

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
