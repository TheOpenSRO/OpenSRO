extends SceneTree

## Round 645: map objects that move, played the way retail plays them --
## the `default` group's type-0 clip, looped by the `.ban`'s own IsCyclic
## word, from t = 0, paused out of range -- through ObjectLoader's own
## prepare and commit, on a synthetic tree built below (never real game
## data: docs/LEGAL.md).
## `godot4 --headless --path client --script res://scripts/world/map_animation_test.gd`
##
## MapAnimation is reached through load() rather than by name, so on a base
## without it this suite still runs and prints its FAIL lines.

const MA_PATH := "res://scripts/world/map_animation.gd"

var _failures := 0

## The named static function's argument count on `script`, or -1 when it
## has none -- so this suite reports a missing or older API as FAIL lines
## instead of stopping on a script error.
func _args(script, fname: String) -> int:
	for m in (script as GDScript).get_script_method_list():
		if m["name"] == fname:
			return (m["args"] as Array).size()
	return -1

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _u32(buf: PackedByteArray, v: int) -> void:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_u32(0, v & 0xFFFFFFFF)
	buf.append_array(b)

func _f32(buf: PackedByteArray, v: float) -> void:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_float(0, v)
	buf.append_array(b)

func _lp(buf: PackedByteArray, s: String) -> void:
	var sb := s.to_ascii_buffer()
	_u32(buf, sb.size())
	buf.append_array(sb)

## A type-4 nature `.bsr` through the section table, the way a swaying tree
## is written (round 625): the 0x2C flag word with bit 0 and a word after
## each mesh path, a skeleton, animations and the `default` group's
## `entries` ([action type, animation index] pairs).
func _build_bsr(meshes: Array, anims: Array, skel: String, entries: Array) -> PackedByteArray:
	var buf := PackedByteArray()
	buf.resize(BsrReader.PREAMBLE_END)
	var magic := BsrReader.MAGIC.to_ascii_buffer()
	for i in range(magic.size()):
		buf[i] = magic[i]
	buf.encode_u32(BsrReader.OFF_TYPE, (2 << 16) | BsrReader.TYPE_NATURE)
	buf.encode_u32(0x2C, 1)
	_lp(buf, "tre_synth")
	var pad := PackedByteArray()
	pad.resize(112)
	buf.append_array(pad)
	# One material, never shipped: the pieces load untextured (a missing
	# .bmt is reported, not fatal), which is all this suite looks at.
	buf.encode_u32(BsrReader.OFF_PTR_MATERIAL, buf.size())
	_u32(buf, 1)
	_u32(buf, 0)
	_lp(buf, "prim\\sway.bmt")
	buf.encode_u32(BsrReader.OFF_PTR_MESH, buf.size())
	_u32(buf, meshes.size())
	for m in meshes:
		_lp(buf, m)
		_u32(buf, 1)
	buf.encode_u32(BsrReader.OFF_PTR_ANIMATION, buf.size())
	_u32(buf, 4096)
	_u32(buf, 0)
	_u32(buf, anims.size())
	for a in anims:
		_lp(buf, a)
	buf.encode_u32(BsrReader.OFF_PTR_SKELETON, buf.size())
	_u32(buf, 1 if skel != "" else 0)
	if skel != "":
		_lp(buf, skel)
		_lp(buf, "")
	buf.encode_u32(BsrReader.OFF_PTR_MESH_GROUP, buf.size())
	_u32(buf, 1)
	_lp(buf, "default")
	_u32(buf, meshes.size())
	for i in range(meshes.size()):
		_u32(buf, i)
	buf.encode_u32(BsrReader.OFF_PTR_ANIMATION_GROUP, buf.size())
	_u32(buf, 1 if not entries.is_empty() else 0)
	if not entries.is_empty():
		_lp(buf, "default")
		_u32(buf, entries.size())
		for e in entries:
			_u32(buf, e[0])
			_u32(buf, e[1])
			_u32(buf, 0) # no events
			_u32(buf, 2) # two walk points, as every real entry
			for v in [0.0, 0.0, 0.0, 1.0]:
				_f32(buf, v)
			_f32(buf, 1.0)
	buf.encode_u32(BsrReader.OFF_PTR_SOUND, buf.size())
	_u32(buf, 0)
	_u32(buf, 0)
	return buf

## A `.bsk`: the root, BoneB under it and BoneC one unit up under BoneB,
## all with an identity rotation.
func _build_bsk() -> PackedByteArray:
	var buf := PackedByteArray()
	buf.append_array(BskReader.MAGIC.to_ascii_buffer())
	_u32(buf, 0)
	buf.append(0)
	_lp(buf, "[root]")
	var root := PackedByteArray()
	root.resize(BskReader.ROOT_TRANSFORM_LEN)
	root.encode_float(0x10, 1.0) # w of the rotation at 0x04
	buf.append_array(root)
	for bone in [["BoneB", "[root]", Vector3.ZERO], ["BoneC", "BoneB", Vector3(0, 1, 0)]]:
		_lp(buf, bone[0])
		_lp(buf, bone[0])
		_lp(buf, bone[1])
		var t := PackedByteArray()
		t.resize(BskReader.BONE_TRANSFORM_LEN)
		t.encode_float(0x0c, 1.0) # w
		t.encode_float(0x10, bone[2].x)
		t.encode_float(0x14, bone[2].y)
		t.encode_float(0x18, bone[2].z)
		buf.append_array(t)
	var trailer := PackedByteArray()
	trailer.resize(8)
	buf.append_array(trailer)
	return buf

## A `.ban` of `duration` ms keyed at 0, duration/2, duration: BoneB turns
## about Y (0, 90, 0 degrees) and BoneC holds one pose throughout.
func _build_ban(duration: int, cyclic: bool) -> PackedByteArray:
	var buf := PackedByteArray()
	buf.append_array(BanReader.MAGIC.to_ascii_buffer())
	_u32(buf, 0)
	_u32(buf, 0)
	_lp(buf, "synth_sway")
	_u32(buf, duration)
	_u32(buf, 30)
	_u32(buf, 1 if cyclic else 0)
	_u32(buf, 3)
	for t in [0, duration / 2, duration]:
		_u32(buf, t)
	_u32(buf, 2)
	var turn := Quaternion(Vector3.UP, PI / 2.0)
	var held := Quaternion(Vector3.RIGHT, 0.25)
	for bone in [["BoneB", [Quaternion.IDENTITY, turn, Quaternion.IDENTITY], Vector3.ZERO],
			["BoneC", [held, held, held], Vector3(0, 1, 0)]]:
		_lp(buf, bone[0])
		_u32(buf, 3)
		for q in bone[1]:
			for v in [q.x, q.y, q.z, q.w, bone[2].x, bone[2].y, bone[2].z]:
				_f32(buf, v)
	return buf

## A skinned `.bms` triangle weighted to BoneB and BoneC (the skin section
## as bms_reader_test.gd writes it).
func _build_bms() -> PackedByteArray:
	var buf := PackedByteArray()
	buf.resize(BmsReader.PREAMBLE_END)
	var magic := BmsReader.MAGIC.to_ascii_buffer()
	for i in range(magic.size()):
		buf[i] = magic[i]
	_lp(buf, "leaf")
	_lp(buf, "leaf")
	_u32(buf, 1)
	_u32(buf, 3)
	for p in [Vector3(0, 0, 0), Vector3(1, 1, 0), Vector3(0, 2, 1)]:
		var rec := PackedByteArray()
		rec.resize(44)
		rec.encode_float(0, p.x)
		rec.encode_float(4, p.y)
		rec.encode_float(8, p.z)
		rec.encode_float(0x10, 1.0)
		rec.encode_u32(0x24, 0xFFFFFFFF)
		buf.append_array(rec)
	buf.encode_u32(BmsReader.HEADER_PTRS_BASE, buf.size())
	_u32(buf, 2)
	_lp(buf, "BoneB")
	_lp(buf, "BoneC")
	buf.append_array(PackedByteArray([0, 0xFF, 0xFF, BmsReader.NO_BONE, 0, 0,
		0, 253, 127, 1, 253, 127,
		1, 0xFF, 0xFF, BmsReader.NO_BONE, 0, 0]))
	buf.encode_u32(BmsReader.HEADER_PTRS_BASE + 4, buf.size())
	_u32(buf, 1)
	buf.append_array(PackedByteArray([0, 0, 1, 0, 2, 0]))
	buf.encode_u32(BmsReader.HEADER_PTRS_BASE + 16, buf.size())
	for v in [0.0, 0.0, 0.0, 1.0, 2.0, 1.0]:
		_f32(buf, v)
	return buf

## A Data.pk2 stand-in serving the files from memory (hud_buff_icon_test.gd's
## StubMedia shape).
class StubArchive extends Pk2Reader:
	var tree := {}
	var files := {}
	var dirs := {}
	func add(path: String, data: PackedByteArray) -> void:
		var parts := path.split("\\")
		var at := ""
		for i in parts.size():
			if not tree.has(at):
				var none: Array[Pk2Reader.Entry] = []
				tree[at] = none
			var name := parts[i]
			var next := name if at == "" else at + "\\" + name
			var found: Pk2Reader.Entry = null
			for e in tree[at]:
				if e.name == name:
					found = e
			if found == null:
				found = Pk2Reader.Entry.new()
				found.name = name
				found.is_dir = i < parts.size() - 1
				tree[at].append(found)
				if found.is_dir:
					dirs[found] = next
				else:
					files[found] = data
					found.size = data.size()
			at = next
	func read_dir() -> Array[Pk2Reader.Entry]:
		var none: Array[Pk2Reader.Entry] = []
		return tree.get("", none)
	func read_dir_at(dir: Pk2Reader.Entry) -> Array[Pk2Reader.Entry]:
		var none: Array[Pk2Reader.Entry] = []
		return tree.get(dirs.get(dir, "?"), none)
	func read_file(file: Pk2Reader.Entry) -> PackedByteArray:
		return files.get(file, PackedByteArray())

func _archive() -> StubArchive:
	var a := StubArchive.new()
	a.add("res\\sway.bsr", _build_bsr(["prim\\leaf.bms"], ["prim\\sway.ban"], "prim\\sway.bsk", [[0, 0]]))
	a.add("res\\sway_once.bsr", _build_bsr(["prim\\leaf.bms"], ["prim\\once.ban"], "prim\\sway.bsk", [[0, 0]]))
	# Only a type-60 entry, as rok_key03_01 and euro_esteuro_viking20 carry:
	# the map asks for type 0 and nothing else (READ, AniMixer::FUN_00c551a0).
	a.add("res\\type60.bsr", _build_bsr(["prim\\leaf.bms"], ["prim\\sway.ban"], "prim\\sway.bsk", [[60, 0]]))
	# A skeleton-less building: still, as ever.
	a.add("res\\still.bsr", _build_bsr(["prim\\leaf.bms"], [], "", []))
	a.add("prim\\leaf.bms", _build_bms())
	a.add("prim\\sway.bsk", _build_bsk())
	a.add("prim\\sway.ban", _build_ban(2000, true))
	a.add("prim\\once.ban", _build_ban(2000, false))
	return a

func _initialize() -> void:
	var MA = load(MA_PATH)
	_check(MA != null, "r645: MapAnimation exists (%s)" % MA_PATH)
	var archive := _archive()

	# --- which clip, READ: `default`, type 0, no fallback ---
	var tree_obj := BsrReader.parse(archive.read_file(ObjectLoader.find_file(archive, "res\\sway.bsr")))
	var t60_obj := BsrReader.parse(archive.read_file(ObjectLoader.find_file(archive, "res\\type60.bsr")))
	var still_obj := BsrReader.parse(archive.read_file(ObjectLoader.find_file(archive, "res\\still.bsr")))
	_check(tree_obj != null and tree_obj.skeleton_path == "prim\\sway.bsk" and tree_obj.animation_paths.size() == 1,
		"r645: the synthetic tree parses with its skeleton and clip")
	if MA != null:
		var e = MA.clip_entry(tree_obj)
		_check(e != null and e.path == "prim\\sway.ban", "r645: the tree plays its default type-0 clip")
		_check(MA.clip_entry(t60_obj) == null, "r645: a model with only a type-60 entry does not move (no fallback to clip 0)")
		_check(MA.clip_entry(still_obj) == null, "r645: a model with no skeleton does not move")

	# --- through ObjectLoader: the template ---
	var node := ObjectLoader.load_object(archive, "res\\sway.bsr")
	_check(node != null, "r645: the tree loads")
	if node == null:
		_finish()
		return
	var skel := node.get_node_or_null("MapSkeleton") as Skeleton3D
	var player := node.get_node_or_null("MapAnimation") as AnimationPlayer
	var leaf := node.get_node_or_null("leaf") as MeshInstance3D
	_check(skel != null and skel.find_bone("BoneB") != -1 and skel.find_bone("BoneC") != -1,
		"r645: the tree gets its skeleton (got %s)" % [skel])
	_check(leaf != null and leaf.skin != null and leaf.skeleton == NodePath("../MapSkeleton"),
		"r645: the skinned leaves are bound to it, not drawn in bind pose (skin %s, skeleton '%s')" % [
			leaf.skin if leaf != null else null, leaf.skeleton if leaf != null else ""])
	_check(player != null and player.has_animation("default"), "r645: the tree gets a player with its clip")
	if skel == null or player == null or leaf == null:
		_finish()
		return
	var anim := player.get_animation("default")
	_check(anim.loop_mode == Animation.LOOP_LINEAR and is_equal_approx(anim.length, 2.0),
		"r645: a cyclic .ban loops over its Duration, in ms (loop %d, length %.3f)" % [anim.loop_mode, anim.length])
	_check(anim.get_track_count() == 1 and anim.track_get_type(0) == Animation.TYPE_ROTATION_3D
			and String(anim.track_get_path(0)) == "MapSkeleton:BoneB",
		"r645: only the moving bone is a track; held poses are baked (got %d tracks)" % anim.get_track_count())
	var held := Quaternion(Vector3.RIGHT, 0.25)
	_check(skel.get_bone_pose_rotation(skel.find_bone("BoneC")).is_equal_approx(held),
		"r645: BoneC's one pose is the template's pose (got %s)" % skel.get_bone_pose_rotation(skel.find_bone("BoneC")))
	_check(is_equal_approx(anim.track_get_key_time(0, 1), 1.0), "r645: key times are the file's ms (1000 ms -> 1.0 s)")

	var once := ObjectLoader.load_object(archive, "res\\sway_once.bsr")
	var once_player := once.get_node_or_null("MapAnimation") as AnimationPlayer if once != null else null
	_check(once_player != null and once_player.get_animation("default").loop_mode == Animation.LOOP_NONE,
		"r645: a .ban with IsCyclic 0 plays once (CRTAniOneShot)")
	var t60 := ObjectLoader.load_object(archive, "res\\type60.bsr")
	_check(t60 != null and t60.get_node_or_null("MapAnimation") == null and t60.get_node_or_null("MapSkeleton") == null,
		"r645: the type-60-only model stays still")

	# --- placed copies share the clip and skin; each has its own skeleton ---
	var a := node.duplicate() as Node3D
	var b := node.duplicate() as Node3D
	var pa := a.get_node("MapAnimation") as AnimationPlayer
	var pb := b.get_node("MapAnimation") as AnimationPlayer
	_check(pa.get_animation("default") == pb.get_animation("default") and pa.get_animation("default") == anim,
		"r645: every placed copy shares the one Animation")
	_check((a.get_node("leaf") as MeshInstance3D).skin == leaf.skin, "r645: and the one Skin")
	_check(a.get_node("MapSkeleton") != b.get_node("MapSkeleton"), "r645: each copy owns its skeleton")
	var ask := a.get_node("MapSkeleton") as Skeleton3D
	_check(ask.get_bone_pose_rotation(ask.find_bone("BoneC")).is_equal_approx(held),
		"r645: a copy keeps the baked pose")

	# --- the clock: t = 0 at placement, hidden and paused until visited ---
	root.add_child(a)
	# The tree is live only once the first frame runs.
	await process_frame
	var cam := Camera3D.new()
	root.add_child(cam)
	await process_frame
	if MA != null:
		var driver = MA.Driver.new()
		_check(driver.add(a, false) == 1, "r645: the driver registers the copy's clip")
		_check(pa.current_animation == "default" and is_zero_approx(pa.current_animation_position) and not pa.active and not a.visible,
			"r645: it starts at t = 0 (READ: no random phase), paused and hidden (fade state 0)")
		# The copy stands at the origin, in the sector cell 0..320 x 0..320.
		# A camera at (160, 0, 600) looks down -Z, across that cell.
		cam.position = Vector3(160, 0, 600)
		driver.tick(cam.global_position, cam.get_frustum())
		_check(pa.active and a.visible and driver.running == 1, "r645: its sector in view and in range, it runs and is drawn")
		# Half a second in: BoneB is half way from 0 to 90 degrees
		# -- the same pose the character path's apply_ban_pose_at gives.
		pa.advance(0.5)
		var ref := Skeleton3DBuilder.build_skeleton3d(BskReader.parse(_build_bsk()))
		Skeleton3DBuilder.apply_ban_pose_at(ref, BanReader.parse(_build_ban(2000, true)), 0.5, true)
		var got: Quaternion = ask.get_bone_pose_rotation(ask.find_bone("BoneB"))
		var want: Quaternion = ref.get_bone_pose_rotation(ref.find_bone("BoneB"))
		_check(got.is_equal_approx(want) and not got.is_equal_approx(Quaternion.IDENTITY),
			"r645: at 0.5 s the pose is the character path's (got %s, want %s)" % [got, want])
		pa.advance(2.0)
		got = ask.get_bone_pose_rotation(ask.find_bone("BoneB"))
		_check(got.is_equal_approx(want), "r645: and it wraps at the Duration (2.5 s == 0.5 s)")
		ref.free()
		# Turned away: the sector is not visited -- its clock stops, and its
		# fade state (drawn) stays as it was (READ, the +0xba2 walk).
		cam.rotation_degrees = Vector3(0, 180, 0)
		driver.tick(cam.global_position, cam.get_frustum())
		_check(not pa.active and a.visible and driver.running == 0,
			"r645 review: a sector out of view pauses its clocks and leaves them drawn")
		# Facing it again from past the range: paused AND hidden.
		cam.rotation_degrees = Vector3.ZERO
		cam.position = Vector3(0, 0, 2100)
		driver.tick(cam.global_position, cam.get_frustum())
		_check(not pa.active and not a.visible, "r645 review: out of range it is paused and not drawn (retail draws a state-0 object not at all)")
		cam.position = Vector3(0, 0, 2020)
		driver.tick(cam.global_position, cam.get_frustum())
		_check(pa.active and a.visible, "r645 review: 2020 from its origin, less its 0.71 radius, is in range")

		# --- the range test, READ: dist - radius < 2500 - 480, strictly ---
		_check(is_equal_approx(MA.OBJECT_RANGE, 2020.0), "r645 review: the range is DAT_00ec54b0 - 480 = 2020 (got %s)" % MA.OBJECT_RANGE)
		# --- READ: the LAST type-0 entry wins (FUN_00c0f470 overwrites in
		# place), and a last entry with no clip plays nothing ---
		var two := BsrReader.parse(_build_bsr(["prim\\leaf.bms"], ["prim\\sway.ban", "prim\\once.ban"], "prim\\sway.bsk", [[0, 0], [0, 1]]))
		var e2 = MA.clip_entry(two)
		_check(e2 != null and e2.path == "prim\\once.ban", "r645 review: of two type-0 entries the last plays (got %s)" % (e2.path if e2 != null else "none"))
		var none_last := BsrReader.parse(_build_bsr(["prim\\leaf.bms"], ["prim\\sway.ban"], "prim\\sway.bsk", [[0, 0], [0, -1]]))
		_check(MA.clip_entry(none_last) == null, "r645 review: a last type-0 entry with no clip plays nothing")

		var review: bool = _args(MA, "in_range") == 4 and _args(MA, "sector_of") == 2 and "_sectors" in driver \
			and typeof(MA.get("disabled")) == TYPE_BOOL
		_check(review, "r645 review: in_range(origin, radius, eye), sector_of, the per-sector driver and the NO_MAP_ANIM switch exist")
		if not review:
			a.free()
			cam.free()
			b.free()
			node.free()
			once.free()
			t60.free()
			_finish()
			return
		_check(MA.in_range(Vector3.ZERO, 10.0, Vector3(2029.9, 0, 0)), "r645 review: 2029.9 away with radius 10 is in range")
		_check(not MA.in_range(Vector3.ZERO, 10.0, Vector3(2030, 0, 0)), "r645 review: 2030 away with radius 10 is not (strict <)")
		_check(not MA.in_range(Vector3.ZERO, 10.0, Vector3(2505, 0, 0)), "r645 review: 2505 away is out (it was in at 2500)")
		_check(MA.in_range(Vector3(0, 100, 0), 0.0, Vector3(0, 2119, 0)), "r645 review: the distance is 3D, from the placement origin")
		var entry_origin: Vector3 = (driver._sectors.values()[0][1] as Array)[0][2]
		_check(entry_origin.is_equal_approx(a.global_position), "r645 review: measured from the placement origin, not the mesh centre")
		_check(is_equal_approx(MA.xz_radius(AABB(Vector3.ZERO, Vector3(6, 100, 8))), 5.0),
			"r645: the radius is half the X-Z diagonal, height ignored (READ, asm 0xa389f0)")

		# --- the view test is per sector, so a clip that travels from its
		# placement is not frozen while its sector is in view ---
		var sector: Array = MA.sector_of(Vector3(300, 0, 10), Transform3D.IDENTITY)
		_check((sector[1] as Vector3).is_equal_approx(Vector3(160, 0, 160)), "r645 review: a placement's sector is its 320-unit cell")
		cam.position = Vector3(160, 0, 1000)
		_check(MA.sector_in_view(sector[1], cam.get_frustum()), "r645 review: a sector in front of the camera is in view")
		cam.rotation_degrees = Vector3(0, 180, 0)
		_check(not MA.sector_in_view(sector[1], cam.get_frustum()), "r645 review: behind it, it is not")

		# --- object.ifo flag bit 0: runs and is drawn at any range ---
		var driver2 = MA.Driver.new()
		driver2.add(b, true)
		root.add_child(b)
		await process_frame
		driver2.tick(Vector3(9000, 0, 0), cam.get_frustum())
		_check(pb.active and b.visible, "r645: object.ifo flag bit 0 runs at any range")

		# The cost probe (QA only): entries() lists what the driver holds,
		# and a halted driver leaves the objects as the probe set them.
		_check(driver.entries().size() == 1 and driver.entries()[0][0] == pa, "r645 cost: entries() lists the registered clip")
		driver.halted = true
		cam.position = Vector3(0, 0, 9000)
		driver.tick(cam.global_position, cam.get_frustum())
		_check(pa.active and a.visible, "r645 cost: a halted driver changes nothing")
		driver.halted = false
		cam.position = Vector3(160, 0, 600)
		# A freed copy is dropped, not ticked.
		cam.rotation_degrees = Vector3.ZERO
		cam.position = Vector3(160, 0, 600)
		a.free()
		driver.tick(cam.global_position, cam.get_frustum())
		_check(driver.size() == 0, "r645: a freed object leaves the driver")

		# --- SRREVAMP_NO_MAP_ANIM builds the pre-645 object: no skeleton,
		# no skin, no player -- a clean A/B baseline ---
		MA.disabled = true
		var plain := ObjectLoader.load_object(archive, "res\\sway.bsr")
		MA.disabled = false
		var plain_leaf := plain.get_node_or_null("leaf") as MeshInstance3D if plain != null else null
		_check(plain != null and plain.get_node_or_null("MapSkeleton") == null and plain.get_node_or_null("MapAnimation") == null
				and plain_leaf != null and plain_leaf.skin == null,
			"r645 review: SRREVAMP_NO_MAP_ANIM builds the object as before 645")
		if plain != null:
			plain.free()
	else:
		a.free()
	cam.free()
	b.free()
	node.free()
	once.free()
	t60.free()
	_finish()

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)
