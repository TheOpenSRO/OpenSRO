extends SceneTree

## Far other players drawn as GPU instances (round 747, CrowdGpu; crowd scale
## A5, docs/protocol/crowd_gpu.md). Run headless on the render box:
## `client/tools/remote_godot.sh tests`. Synthetic data only: a hand-made
## skeleton, a shared-skin mesh, a rigid piece on a BoneAttachment3D, a
## hand-made clip. The real-archive parity (every vertex of real Figures, and
## the drawn pixels under both renderers) is client/tools/crowd_gpu_probe.gd's.
##
## What it holds the client to:
## - the shader twin: CROWD_GPU and the crowd's head after render_mode, the
##   skin at the top of vertex() (or in object.gdshaderinc's own);
## - the arithmetic the vertex shader makes from the textures (CrowdGpu.cpu_skin)
##   puts every vertex where the near path's skin does, at several clip times,
##   for a plain body, a Volume variant, a Height scale and a rigid piece;
## - the frame the shader takes is CrowdAnim.frame_index's, across the
##   clock's rebase;
## - instances come and go with their bodies (a removed body's slot draws
##   nothing; a group's instances stay packed);
## - in the world: the K nearest in view stay near, the rest go far with their
##   entries out of the clip tick; a one-shot, a loop the GPU has not baked, a
##   body leaving the tree, and A5 switched off each bring a body back, with
##   its entry and its skeleton shown.
##
## NEGATIVE, on the base (daeb1b0c): CrowdGpu does not exist, so the suite
## does not parse (INFERRED, not run).

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	var watchdog := create_timer(120.0)
	watchdog.timeout.connect(func() -> void:
		print("FAIL the suite never reported (a script error stopped it)")
		quit(1))
	await process_frame
	var path := "res://scripts/world/crowd_gpu.gd"
	_check(ResourceLoader.exists(path), "CrowdGpu exists")
	if ResourceLoader.exists(path):
		_test_twin_code()
		await _test_parity()
		_test_frames_and_rebase()
		_test_review_fixes()
		_test_light_texel()
		_test_glow_rows()
		_test_half_custom()
		_test_collect_cap()
		_test_aabb_spread()
		_test_rigid_slices()
		var world := _make_world()
		if world != null:
			await process_frame
			_test_world(world)
			root.remove_child(world)
			world.free()
	CrowdGpu.enabled = true
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

# --- the shader twin ----------------------------------------------------------------

func _test_twin_code() -> void:
	var obj := ObjectLoader.object_shader("solid").code
	var t := CrowdGpu.twin_code(obj)
	var lines := t.split("\n")
	var rm := -1
	for i in range(lines.size()):
		if lines[i].begins_with("render_mode"):
			rm = i
			break
	_check(rm >= 0 and lines[rm + 1] == "#define CROWD_GPU" and lines[rm + 2].contains(CrowdGpu.HEAD_INCLUDE),
		"an object shader's twin defines CROWD_GPU and includes the crowd's head right after its render_mode")
	_check(t.find("#define CROWD_GPU") < t.find("object.gdshaderinc") and not t.contains(CrowdGpu.VERTEX_INCLUDE),
		"... before object.gdshaderinc, whose own vertex() includes the skin")
	var inc := FileAccess.get_file_as_string("res://scripts/assets/object.gdshaderinc")
	var v := inc.find("void vertex() {")
	_check(v >= 0 and inc.find("#ifdef CROWD_GPU", v) > v and inc.find(CrowdGpu.VERTEX_INCLUDE, v) < inc.find("srr_od0 =", v),
		"object.gdshaderinc skins a CROWD_GPU twin first thing in its vertex()")
	var mod := ObjectLoader._mod_shader("back", "mix", true).code
	var tm := CrowdGpu.twin_code(mod)
	var mv := tm.find("void vertex() {")
	_check(mv >= 0 and tm.find(CrowdGpu.VERTEX_INCLUDE) > mv and tm.find(CrowdGpu.VERTEX_INCLUDE) < tm.find("srr_od0", mv),
		"a mod shader's twin includes the skin at the top of its own vertex()")
	var bare := "shader_type spatial;\nvoid fragment() {\n\tALBEDO = vec3(1.0);\n}\n"
	var tb := CrowdGpu.twin_code(bare)
	_check(tb.contains("void vertex() {\n#include \"%s\"" % CrowdGpu.VERTEX_INCLUDE) and tb.find("#define CROWD_GPU") > tb.find("shader_type"),
		"a shader with no vertex() is given one")
	_check(CrowdGpu.twin_code("shader_type canvas_item;\n") == "", "a non-spatial shader has no twin")

# --- parity -------------------------------------------------------------------------

## A body skeleton: Bip01, a spine turned 90 degrees about Z, a thigh, a calf
## (crowd_anim_test's).
func _body() -> Skeleton3D:
	var s := Skeleton3D.new()
	s.add_bone("Bip01")
	s.set_bone_rest(0, Transform3D(Basis(Vector3.UP, 0.3), Vector3(0, 1, 0)))
	s.add_bone("Bip01 Spine")
	s.set_bone_parent(1, 0)
	s.set_bone_rest(1, Transform3D(Basis(Vector3(0, 0, 1), PI / 2.0), Vector3(0, 10, 0)))
	s.add_bone("Bip01 L Thigh")
	s.set_bone_parent(2, 0)
	s.set_bone_rest(2, Transform3D(Basis(Vector3(1, 0, 0), PI), Vector3(2, 8, 0)))
	s.add_bone("Bip01 L Calf")
	s.set_bone_parent(3, 2)
	s.set_bone_rest(3, Transform3D(Basis(Vector3(0, 0, 1), 0.2), Vector3(0, 6, 0)))
	for i in range(s.get_bone_count()):
		s.reset_bone_pose(i)
	Skeleton3DBuilder.refresh_global_poses(s)
	return s

## A skinned mesh whose palette is [calf, spine], with single, shared and
## object-space influences (crowd_anim_test's).
func _mesh() -> BmsReader.ParsedMesh:
	var m := BmsReader.ParsedMesh.new()
	m.bone_names = PackedStringArray(["Bip01 L Calf", "Bip01 Spine"])
	var verts: Array[BmsReader.Vertex] = []
	var specs := [[Vector3(2, 3, 0), 0, -1, 1.0], [Vector3(0, 12, 1), 1, -1, 1.0], [Vector3(1, 9, 0.5), 0, 1, 0.3],
		[Vector3(-1, 2, 2), BmsReader.OBJECT_SPACE, 1, 0.6]]
	for sp in specs:
		var v := BmsReader.Vertex.new()
		v.position = sp[0]
		v.normal = Vector3.UP
		v.bone0 = sp[1]
		v.bone1 = sp[2]
		v.weight0 = sp[3]
		v.weight1 = 1.0 - float(sp[3]) if int(sp[2]) != -1 else 0.0
		verts.append(v)
	m.vertices = verts
	m.object_space_vertices = 1
	m.indices = PackedInt32Array([0, 1, 2, 1, 2, 3])
	return m

var _shared_skin: Skin = null
var _mat: ShaderMaterial = null

## A body as CharacterAppearance builds one: its skeleton with the
## object-space bone, one shared skin, a remapped skinned piece, and a rigid
## piece on a BoneAttachment3D of the spine; Volume `scales` if given.
func _make_body(scales: Dictionary = {}) -> Skeleton3D:
	var s := _body()
	Skeleton3DBuilder._object_space_bone(s)
	if _shared_skin == null:
		_shared_skin = Skeleton3DBuilder.canonical_skin(s)
		CharacterAppearance._mark_canonical(_shared_skin)
		_mat = ShaderMaterial.new()
		_mat.shader = ObjectLoader.OBJECT_SHADER
	var m := _mesh()
	var palette := Skeleton3DBuilder.build_skin(s, m.bone_names, true)
	var mi := MeshInstance3D.new()
	mi.name = "Piece"
	mi.mesh = Skeleton3DBuilder.canonical_mesh(m, palette)
	mi.material_override = _mat
	s.add_child(mi)
	mi.skin = _shared_skin
	mi.skeleton = mi.get_path_to(s)
	var att := BoneAttachment3D.new()
	att.bone_name = "Bip01 Spine"
	s.add_child(att)
	var item := MeshInstance3D.new()
	item.name = "Item"
	item.mesh = BoxMesh.new()
	item.position = Vector3(0.0, 1.5, 0.5)
	item.rotation = Vector3(0.2, 0.0, 0.4)
	item.material_override = _mat
	att.add_child(item)
	# A weapon's own skeleton on the attachment (EquipFx's host), no mesh.
	var isk := Skeleton3D.new()
	isk.name = "ItemSkeleton"
	isk.add_bone("i0")
	isk.transform = Transform3D(Basis(Vector3.UP, 0.4), Vector3(0.3, 0.2, 0.1))
	att.add_child(isk)
	if not scales.is_empty():
		CharacterAppearance.apply_volume(s, scales)
	s.set_meta(MonsterCrowd.META_LAYOUT, "crowd_gpu_test|%d" % s.get_bone_count())
	# Round 828: mirrored, as every body the world puts in (BodyMirror).
	BodyMirror.apply(s)
	return s

## A loop over the body's bones, every channel moving.
func _clip(duration: int, keys: int, salt: float = 0.0) -> BanReader.ParsedAnimation:
	var clip := BanReader.ParsedAnimation.new()
	clip.duration_ms = duration
	clip.cyclic = true
	var times := PackedInt32Array()
	for k in range(keys):
		times.append(int(float(duration) * float(k) / float(keys)))
	clip.key_times = times
	var names := ["Bip01", "Bip01 Spine", "Bip01 L Thigh", "Bip01 L Calf"]
	var rests := [Transform3D(Basis(Vector3.UP, 0.3), Vector3(0, 1, 0)), Transform3D(Basis(Vector3(0, 0, 1), PI / 2.0), Vector3(0, 10, 0)),
		Transform3D(Basis(Vector3(1, 0, 0), PI), Vector3(2, 8, 0)), Transform3D(Basis(Vector3(0, 0, 1), 0.2), Vector3(0, 6, 0))]
	for b in range(names.size()):
		var track := BanReader.Bone.new()
		track.bone_name = names[b]
		for k in range(keys):
			var kf := BanReader.Keyframe.new()
			var r: Transform3D = rests[b]
			kf.rotation = r.basis.get_rotation_quaternion() * Quaternion(Vector3(1.0, float(b % 3), float(k) + salt).normalized(), 0.25 * float(k + b))
			kf.position = r.origin + Vector3(0.1 * float(k), 0.2 * float(b), 0.0)
			track.keyframes.append(kf)
		clip.bones.append(track)
	return clip

## The near path's vertices, in the world: the skinned piece from the body's
## own skin at the skeleton's transform, the rigid piece at its own.
func _near_vertices(skel: Skeleton3D) -> Array:
	Skeleton3DBuilder.flush_attachments(skel)  # the weapons follow now (round 754)
	var out: Array = []
	for n in skel.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		var arr := mi.mesh.surface_get_arrays(0)
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var pts := PackedVector3Array()
		if mi.skin != null:
			var bones: PackedInt32Array = arr[Mesh.ARRAY_BONES]
			var weights: PackedFloat32Array = arr[Mesh.ARRAY_WEIGHTS]
			var per := bones.size() / v.size()
			for k in range(v.size()):
				var p := Vector3.ZERO
				for j in range(per):
					var w := weights[k * per + j]
					if w > 0.0:
						var b := bones[k * per + j]
						p += (skel.get_bone_global_pose(mi.skin.get_bind_bone(b)) * mi.skin.get_bind_pose(b) * v[k]) * w
				pts.append(skel.global_transform * p)
		else:
			for k in range(v.size()):
				pts.append(mi.global_transform * v[k])
		out.append(pts)
	return out

func _test_parity() -> void:
	var crowd := CrowdGpu.new(root.find_world_3d().scenario)
	var clip := _clip(1000, 5)
	var cases := [[{}, 1.0, "a plain body"], [{"Bip01 Spine": 1.15, "Bip01 L Thigh": 0.9}, 1.0, "a Volume variant"],
		[{}, 1.06, "a body at Height 1.06"]]
	var worst := 0.0
	var moved := 0.0
	var rigid_seen := false
	var i := 0
	for c in cases:
		var skel := _make_body(c[0])
		var holder := Node3D.new()
		holder.set_meta("character_id", 100 + i)
		holder.position = Vector3(30.0 * float(i), 0.0, -40.0)
		holder.rotation.y = 0.7 * float(i)
		skel.scale = BodyMirror.SCALE * float(c[1])
		skel.rotation.y = PI
		holder.add_child(skel)
		root.add_child(holder)
		skel.set_meta(CrowdAnim.META_CACHED, true)
		var entry := [skel, clip, 5, 0.37 * float(i), true, 0.0, null]
		if i == 0:
			_check(not crowd.can_draw(skel, entry), "%s: a clip not baked yet is not drawn far, and is queued" % c[2])
		else:
			_check(crowd.can_draw(skel, entry), "%s: the clip baked for the layout serves this body too" % c[2])
		crowd.bake_all()
		var case_worst := 0.0
		var frame_worst := 0.0
		var compared := 0
		var rest := _near_vertices(skel)
		for t in [0.0, 0.29, 0.733, 1.51]:
			crowd.remove(skel)
			MonsterCrowd.pose_at(skel, clip, t + float(entry[3]), true)
			var near := _near_vertices(skel)
			var isk := skel.find_child("ItemSkeleton", true, false) as Skeleton3D
			var near_item := isk.global_transform
			_check(crowd.add(holder, skel, entry, t), "%s: drawn far at t=%.2f" % [c[2], t])
			crowd.flush(t)
			var far := crowd.cpu_skin(skel, t)
			var far_item = crowd.item_frame(isk)
			if far_item == null:
				frame_worst = INF
			else:
				var fi: Transform3D = far_item
				frame_worst = maxf(frame_worst, fi.origin.distance_to(near_item.origin))
				for ax in range(3):
					frame_worst = maxf(frame_worst, (fi.basis[ax] - near_item.basis[ax]).length())
			if far.size() != near.size():
				_check(false, "%s: %d parts far, %d near" % [c[2], far.size(), near.size()])
				continue
			rigid_seen = rigid_seen or far.size() == 2
			for p in range(near.size()):
				var a: PackedVector3Array = near[p]
				var b: PackedVector3Array = far[p]
				for k in range(a.size()):
					case_worst = maxf(case_worst, a[k].distance_to(b[k]))
					moved = maxf(moved, a[k].distance_to((rest[p] as PackedVector3Array)[k]))
					compared += 1
		_check(compared > 0 and case_worst < 1e-4, "%s: every vertex lands where the near path's skin puts it (%d compared, worst %s)" % [c[2], compared, str(case_worst)])
		_check(frame_worst < 1e-4, "%s: a weapon's item skeleton is where its BoneAttachment3D puts it near (item_frame, worst %s)" % [c[2], str(frame_worst)])
		worst = maxf(worst, case_worst)
		_check(not (skel.get_node("Piece") as MeshInstance3D).visible and skel.visible and skel.has_meta(CrowdGpu.META_FAR),
			"%s: a far body's meshes are hidden, its skeleton (and what else hangs from it) not" % c[2])
		i += 1
	_check(rigid_seen, "the rigid piece on its BoneAttachment3D is drawn far too")
	_check(moved > 1.0, "the clip moves the vertices (%.2f), so the parity is not of a rest pose" % moved)
	# Instances come and go with their bodies.
	var bodies := crowd.skeletons()
	var before := int(crowd.stats["instances"])
	var gone: Skeleton3D = bodies[0]
	var entry_back := crowd.remove(gone)
	crowd.flush(2.0)
	_check(not entry_back.is_empty() and (gone.get_node("Piece") as MeshInstance3D).visible and not gone.has_meta(CrowdGpu.META_FAR),
		"a removed body gives its entry back and is shown")
	_check(int(crowd.stats["instances"]) == before - 2, "... and its two instances leave their groups (%d -> %d)" % [before, int(crowd.stats["instances"])])
	var still: Skeleton3D = bodies[1]
	var ok := true
	for t in [2.0, 2.4]:
		MonsterCrowd.pose_at(still, clip, 0.0, true)
		var e2: Array = crowd.entry_of(still)
		crowd.remove(still)
		MonsterCrowd.pose_at(still, clip, t + float(e2[3]), true)
		var near := _near_vertices(still)
		crowd.add(still.get_parent(), still, e2, t)
		crowd.flush(t)
		var far := crowd.cpu_skin(still, t)
		for p in range(near.size()):
			for k in range((near[p] as PackedVector3Array).size()):
				if (near[p] as PackedVector3Array)[k].distance_to((far[p] as PackedVector3Array)[k]) > 1e-4:
					ok = false
	_check(ok, "a body still far after another left its group is still skinned right (the group stays packed)")
	# A loop it has baked: swapped on the GPU; one it has not: refused.
	var other_clip := _clip(800, 4, 0.5)
	_check(not crowd.set_clip(still, other_clip, 4, 2.5), "a loop not baked is refused (the caller brings the body near)")
	crowd.bake_all()
	_check(crowd.set_clip(still, other_clip, 4, 2.5) and crowd.entry_of(still)[1] == other_clip, "once baked, the loop is swapped in the body's entry")
	for s in crowd.skeletons():
		crowd.remove(s)
	for c in root.get_children():
		if c is Node3D and c.has_meta("character_id"):
			root.remove_child(c)
			c.free()
	crowd.flush(3.0)
	await process_frame

## Round 759: a character's light levels share one group per mesh. Each
## level is ObjectLight's copy of the material near; far, its part draws with
## the base's twin, flagged (the lit bit of INSTANCE_CUSTOM.y), and the body's
## level goes in its fifth texel (MEASURED live before: 6,587 groups for 1,678
## meshes, a group per (mesh, level)).
func _test_light_texel() -> void:
	var crowd := CrowdGpu.new(root.find_world_3d().scenario)
	var clip := _clip(900, 4)
	var levels := [0.45, 0.55, ObjectLight.OBJECT_COLOR]
	var skels: Array = []
	for i in range(levels.size()):
		var skel := _make_body()
		# One kind: the same meshes, as a template's bodies share them.
		if not skels.is_empty():
			for nm in ["Piece", "Item"]:
				(skel.find_child(nm, true, false) as MeshInstance3D).mesh = ((skels[0] as Node).find_child(nm, true, false) as MeshInstance3D).mesh
		var holder := Node3D.new()
		holder.set_meta("character_id", 300 + i)
		holder.position = Vector3(10.0 * float(i), 0.0, -20.0)
		holder.add_child(skel)
		root.add_child(holder)
		CharacterLight.set_on(holder, float(levels[i]))
		var entry := [skel, clip, 4, 0.1, true, 0.0, null]
		crowd.can_draw(skel, entry)
		crowd.bake_all()
		_check(crowd.add(holder, skel, entry, 0.0), "light %.2f: drawn far" % levels[i])
		skels.append(skel)
	crowd.flush(0.0)
	var piece0 := (skels[0] as Skeleton3D).get_node("Piece") as MeshInstance3D
	_check(ObjectLight.base_of(piece0.material_override) == _mat and piece0.material_override != _mat,
		"near, a body at 0.45 draws with ObjectLight's level copy of the material")
	var groups := {}
	var flags_ok := true
	var texels_ok := true
	for i in range(skels.size()):
		var b: CrowdGpu.Body = crowd.body_of(skels[i])
		var want := float(roundi(float(levels[i]) * ObjectLight.VARIANT_STEPS)) / ObjectLight.VARIANT_STEPS
		if absf(float(levels[i]) - ObjectLight.OBJECT_COLOR) < 0.001:
			want = ObjectLight.OBJECT_COLOR
		if not is_equal_approx(b.objc, want) or not is_equal_approx(crowd._body_data[b.slot * CrowdGpu.FLOATS_PER_BODY + 16], want):
			texels_ok = false
		for rec in b.parts:
			var g: CrowdGpu.Group = rec[0]
			groups[g] = true
			var y: float = g.buf[int(rec[1]) * CrowdGpu.INSTANCE_FLOATS + 13]
			if not bool(CrowdGpu.unpack_y(y)[1]):
				flags_ok = false
	_check(texels_ok, "each body's level (0.45, 0.55, 0.6) is its fifth texel, the value its level copy carries")
	_check(flags_ok, "every lit part's INSTANCE_CUSTOM.y carries the lit bit")
	_check(groups.size() == 2, "three levels draw from 2 groups (the piece and the item), not 6 (%d)" % groups.size())
	var twin_ok := true
	for g in groups:
		if crowd._twin_sources.get((g as CrowdGpu.Group).twin_key) == null or (crowd._twin_sources[(g as CrowdGpu.Group).twin_key] as WeakRef).get_ref() != _mat:
			twin_ok = false
	_check(twin_ok, "... each the base material's twin")
	# A level change while far: the texel, the same groups.
	var holder0: Node3D = (skels[0] as Skeleton3D).get_parent()
	CharacterLight.set_on(holder0, 0.5)
	crowd.refresh(holder0)
	var b0: CrowdGpu.Body = crowd.body_of(skels[0])
	var same := true
	for rec in b0.parts:
		if not groups.has(rec[0]):
			same = false
	_check(same and is_equal_approx(b0.objc, float(roundi(0.5 * ObjectLight.VARIANT_STEPS)) / ObjectLight.VARIANT_STEPS),
		"a level change while far rewrites the texel (%.4f) and keeps its groups" % b0.objc)
	# The shaders: object.gdshaderinc's oD0 and a mod shader's take srr_cg_objc.
	var inc := FileAccess.get_file_as_string("res://scripts/assets/object.gdshaderinc")
	_check(inc.contains("srr_cg_objc >= 0.0 ? vec3(srr_cg_objc) : object_color"), "object.gdshaderinc's twin takes the body's colour")
	var tm := CrowdGpu.twin_code(ObjectLoader._mod_shader("back", "mix", true).code)
	_check(tm.contains("srr_cg_objc >= 0.0 ? vec3(srr_cg_objc) : object_color") and tm.find(CrowdGpu.VERTEX_INCLUDE) < tm.find("srr_cg_objc >= 0.0"),
		"a mod shader's twin too, after the skin declares it")
	for sk in skels:
		crowd.remove(sk)
		var h: Node = (sk as Node).get_parent()
		root.remove_child(h)
		h.free()
	crowd.flush(1.0)

## Round 759: an item worn at several pluses draws from one group per mesh,
## each instance's glow row from the glow table (MEASURED live before: the
## glow's colours, period and scroll split most of the far groups).
## A float through a GLES3 half (Compatibility's custom data).
static func _half(f: float) -> float:
	var b := PackedByteArray()
	b.resize(2)
	b.encode_half(0, f)
	return b.decode_half(0)

## Round 760 (round 759's review, F2): under Compatibility INSTANCE_CUSTOM is
## half floats; the slot and the glow row ride in the instance origin (full
## floats) there, and everything left in the custom data is a half exactly.
func _test_half_custom() -> void:
	var exact := true
	var fwd_lost := 0
	for slot in [0, 1, 2047, 2048, 2049, 3001, 5001, 7000, 9999, 65001]:
		for glow in [-1, 0, 62, 63, 3000]:
			for vl in [[-1, false], [0, false], [510, true]]:
				if glow >= 0 and (int(vl[0]) >= 0 or bool(vl[1])):
					continue
				var h := CrowdGpu.instance_ints(slot, int(vl[0]), bool(vl[1]), glow, true)
				var buf := PackedFloat32Array()
				buf.resize(CrowdGpu.INSTANCE_FLOATS)
				buf[3] = h[0]
				buf[7] = h[1]
				buf[12] = _half(h[2])
				buf[13] = _half(h[3])
				if CrowdGpu.instance_read(buf, 0) != [slot, int(vl[0]), bool(vl[1]), glow]:
					exact = false
				var f := CrowdGpu.instance_ints(slot, int(vl[0]), bool(vl[1]), glow, false)
				if _half(f[2]) != f[2] or _half(f[3]) != f[3]:
					fwd_lost += 1
	_check(exact, "Compatibility's layout: every slot to 65001 and glow row to 3000 survives the half-float custom data exactly")
	_check(fwd_lost > 0, "probe: Forward+'s layout through half floats loses %d of those (the review's F2)" % fwd_lost)
	# A crowd past 2,048 bodies, drawn the Compatibility way: each part reads back its own body's slot and row.
	CrowdGpu.half_custom_override = 1
	var crowd := CrowdGpu.new(root.find_world_3d().scenario)
	for k in range(3000):
		crowd._take_slot()
	var clip := _clip(900, 4)
	var glow := ShaderMaterial.new()
	glow.shader = EquipGlow.glow_shader("back", true)
	glow.set_shader_parameter("glow_texture", ImageTexture.create_from_image(Image.create(4, 4, false, Image.FORMAT_RGBA8)))
	glow.set_shader_parameter("alpha_scissor", 1.0 / 255.0)
	glow.set_meta(EquipGlow.PLAIN_META, _mat)
	var ok := true
	var n := 0
	for i in range(3):
		var skel := _make_body()
		(skel.find_child("Item", true, false) as MeshInstance3D).material_override = glow
		var holder := Node3D.new()
		holder.set_meta("character_id", 700 + i)
		holder.position = Vector3(10.0 * float(i), 0.0, -30.0)
		holder.add_child(skel)
		root.add_child(holder)
		var entry := [skel, clip, 4, 0.1, true, 0.0, null]
		crowd.can_draw(skel, entry)
		crowd.bake_all()
		if not crowd.add(holder, skel, entry, 0.0):
			ok = false
			continue
		var b: CrowdGpu.Body = crowd.body_of(skel)
		for rec in b.parts:
			var g: CrowdGpu.Group = rec[0]
			var o := int(rec[1]) * CrowdGpu.INSTANCE_FLOATS
			var got: Array = CrowdGpu.instance_read(g.buf, o)
			n += 1
			if int(got[0]) != b.slot or b.slot < 2048 or _half(g.buf[o + 12]) != g.buf[o + 12] or _half(g.buf[o + 13]) != g.buf[o + 13]:
				ok = false
	_check(ok and n >= 6, "a crowd past 2,048 bodies (slots 3000+): %d parts carry their body's slot exactly, the half channels exact" % n)
	var shader_code := FileAccess.get_file_as_string(CrowdGpu.VERTEX_INCLUDE)
	_check(shader_code.contains("int srr_cg_slot = int(MODEL_MATRIX[3].x + 0.5);") and shader_code.contains("VERTEX -= MODEL_MATRIX[3].xyz;")
		and shader_code.contains("#if CURRENT_RENDERER == RENDERER_COMPATIBILITY"), "the vertex include reads them from the origin under Compatibility and takes it back off")
	CrowdGpu.half_custom_override = -1

func _test_glow_rows() -> void:
	# The packing of INSTANCE_CUSTOM.y.
	var ok := true
	for vol in [-1, 0, 7, 510]:
		for lit in [false, true]:
			for glow in [-1, 0, 5, 3000]:
				var u := CrowdGpu.unpack_y(CrowdGpu.pack_y(vol, lit, glow))
				if int(u[0]) != vol or bool(u[1]) != lit or int(u[2]) != glow:
					ok = false
	_check(ok, "INSTANCE_CUSTOM.y packs the Volume row, the lit bit and the glow row exactly")
	var crowd := CrowdGpu.new(root.find_world_3d().scenario)
	var clip := _clip(900, 4)
	var rows := [[Color(1, 0.2, 0.1), Color(0.3, 0.3, 1), 2.0, 2.0, 0.0, Vector2(0.1, 0.0)],
		[Color(0.2, 1, 0.1), Color(1, 1, 1), 1.4, 1.0, 1.0, Vector2(0.0, 0.25)]]
	var opt := ImageTexture.create_from_image(Image.create(4, 4, false, Image.FORMAT_RGBA8))
	var opt2 := ImageTexture.create_from_image(Image.create(8, 8, false, Image.FORMAT_RGBA8))
	var glows: Array = []
	for r in rows:
		var g := ShaderMaterial.new()
		g.shader = EquipGlow.glow_shader("back", true)
		g.set_shader_parameter("glow_texture", opt if glows.is_empty() else opt2)
		g.set_shader_parameter("glow_c1", r[0])
		g.set_shader_parameter("glow_c2", r[1])
		g.set_shader_parameter("glow_period", r[2])
		g.set_shader_parameter("glow_mul0", r[3])
		g.set_shader_parameter("glow_signed2x", r[4])
		g.set_shader_parameter("glow_uv_speed", r[5])
		g.set_shader_parameter("alpha_scissor", 1.0 / 255.0)
		g.set_meta(EquipGlow.PLAIN_META, _mat)
		glows.append(g)
	var skels: Array = []
	for i in range(3):
		var skel := _make_body()
		if not skels.is_empty():
			for nm in ["Piece", "Item"]:
				(skel.find_child(nm, true, false) as MeshInstance3D).mesh = ((skels[0] as Node).find_child(nm, true, false) as MeshInstance3D).mesh
		# The item glows at the body's row (two bodies at the first, one at the second).
		(skel.find_child("Item", true, false) as MeshInstance3D).material_override = glows[0 if i < 2 else 1]
		var holder := Node3D.new()
		holder.set_meta("character_id", 400 + i)
		holder.position = Vector3(10.0 * float(i), 0.0, -30.0)
		holder.add_child(skel)
		root.add_child(holder)
		var entry := [skel, clip, 4, 0.1, true, 0.0, null]
		crowd.can_draw(skel, entry)
		crowd.bake_all()
		_check(crowd.add(holder, skel, entry, 0.0), "glow body %d: drawn far" % i)
		skels.append(skel)
	crowd.flush(0.0)
	var item_groups := {}
	var got_rows: Array = []
	for sk in skels:
		var b: CrowdGpu.Body = crowd.body_of(sk)
		for rec in b.parts:
			var g: CrowdGpu.Group = rec[0]
			var y: float = g.buf[int(rec[1]) * CrowdGpu.INSTANCE_FLOATS + 13]
			var glow_row: int = CrowdGpu.unpack_y(y)[2]
			if glow_row >= 0:
				item_groups[g] = true
				got_rows.append(glow_row)
	_check(item_groups.size() == 1, "the item at two glow rows, two option textures, draws from ONE group (%d)" % item_groups.size())
	_check(got_rows.size() == 3 and got_rows[0] == got_rows[1] and got_rows[2] != got_rows[0],
		"each instance carries its own row: %s" % str(got_rows))
	var table_ok := got_rows.size() == 3
	if table_ok:
		for k in range(2):
			var row: int = got_rows[0] if k == 0 else got_rows[2]
			var o := row * CrowdGpu.GLOW_TEXELS * 4
			var r: Array = rows[k]
			var want := [r[0].r, r[0].g, r[0].b, r[2], r[1].r, r[1].g, r[1].b, r[3], r[5].x, r[5].y, r[4], float(k + 1)]
			for i in range(want.size()):
				if not is_equal_approx(crowd._glow_data[o + i], float(want[i])):
					table_ok = false
	_check(table_ok, "the glow table holds each row's c1, period, c2, mul0, scroll, signed2x and texture slot + 1")
	var twin: ShaderMaterial = (item_groups.keys()[0] as CrowdGpu.Group).material if not item_groups.is_empty() else null
	_check(twin != null and twin.get_shader_parameter("crowd_glow") == crowd._glow_tex and twin.get_shader_parameter("crowd_glow_t0") == opt
		and twin.get_shader_parameter("crowd_glow_t1") == opt2,
		"the group's twin reads the glow table and holds both option textures in its slots")
	# The shader's row arithmetic is srr_glow's, the uniforms read from the row.
	var inc := FileAccess.get_file_as_string("res://scripts/assets/object.gdshaderinc")
	var a := inc.find("vec3 srr_glow(vec3 srr_item")
	var a_body := inc.substr(inc.find("{", a), inc.find("\n}", a) - inc.find("{", a))
	var bpos := inc.find("vec3 srr_glow_row(")
	var b_body := inc.substr(inc.find("{", bpos), inc.find("\n}", bpos) - inc.find("{", bpos))
	var subst := a_body
	for pair in [["glow_c1", "srr_g1.rgb"], ["glow_period", "srr_g1.a"], ["glow_c2", "srr_g2.rgb"], ["glow_mul0", "srr_g2.a"],
			["glow_uv_speed", "srr_g3.xy"], ["glow_signed2x", "srr_g3.z"],
			["texture(glow_texture, srr_uv + fract(srr_g3.xy * srr_time)).rgb", "srr_glow_opt(srr_uv + fract(srr_g3.xy * srr_time), srr_g3.w)"]]:
		subst = subst.replace(pair[0], pair[1])
	var strip := func(t: String) -> String:
		var out := PackedStringArray()
		for line in t.split("\n"):
			var ln := String(line).strip_edges()
			if ln != "" and not ln.begins_with("//"):
				out.append(ln)
		return "\n".join(out)
	_check(a >= 0 and bpos >= 0 and strip.call(subst) == strip.call(b_body), "srr_glow_row is srr_glow with the row's values for the uniforms")
	var oi := inc.find("vec3 srr_glow_opt(")
	var o_body := inc.substr(oi, inc.find("\n}", oi) - oi)
	_check(oi >= 0 and o_body.contains("texture(crowd_glow_t0, srr_at).rgb") and o_body.contains("texture(crowd_glow_t3, srr_at).rgb")
		and o_body.contains("return texture(glow_texture, srr_at).rgb;")
		and inc.contains("uniform sampler2D crowd_glow_t0 : hint_default_black, filter_linear_mipmap, repeat_enable;")
		and inc.contains("uniform sampler2D glow_texture : hint_default_black, filter_linear_mipmap, repeat_enable;"),
		"the row's option texture is sampled as glow_texture is (the same hints), slot 0 the twin's own")
	for sk in skels:
		crowd.remove(sk)
		var h: Node = (sk as Node).get_parent()
		root.remove_child(h)
		h.free()
	crowd.flush(1.0)

## Round 759: collect() frees at most COLLECT_MAX groups a call (MEASURED
## before: an arrival's thousands of emptied groups collected together made
## frames of 400-723 ms), the rest on the next calls.
func _test_collect_cap() -> void:
	var crowd := CrowdGpu.new(root.find_world_3d().scenario)
	var b := CrowdGpu.Body.new()
	b.slot = 0
	var mesh := BoxMesh.new()
	var n := CrowdGpu.COLLECT_MAX + 40
	for i in range(n):
		var m := ShaderMaterial.new()
		m.shader = ObjectLoader.OBJECT_SHADER
		crowd._add_part(b, {"mesh": mesh, "material": m, "layers": 1, "sort": 0.0, "vol": -1, "centre": 0.0, "twin_key": "cap%d" % i})
	crowd._push_groups()
	_check(crowd._groups.size() == n and int(crowd.stats["instances"]) == n, "%d one-instance groups made (%d instances)" % [n, int(crowd.stats["instances"])])
	for rec in b.parts.duplicate():
		crowd._remove_part(rec)
	b.parts.clear()
	crowd._push_groups()
	for c in range(CrowdGpu.GROUP_EMPTY_CYCLES - 1):
		crowd.collect()
	var first := crowd.collect()
	var second := crowd.collect()
	_check(first == CrowdGpu.COLLECT_MAX and second == 40 and crowd._groups.is_empty() and int(crowd.stats["instances"]) == 0,
		"emptied, they are freed %d a call at most (%d, then %d), all of them in the end" % [CrowdGpu.COLLECT_MAX, first, second])

## Round 762: new bounds go to the groups AABB_PUSH_GROUPS a flush, not all
## in one (each is a culling-tree update on the render thread), and a group
## freed meanwhile is skipped; a group's two instances are shown and hidden by
## their layer mask, not their visibility.
## NEGATIVE: a push to every group at once fails "spread over".
func _test_aabb_spread() -> void:
	var crowd := CrowdGpu.new(root.find_world_3d().scenario)
	var b := CrowdGpu.Body.new()
	b.slot = 0
	var mesh := BoxMesh.new()
	var n := CrowdGpu.AABB_PUSH_GROUPS * 2 + 10
	for i in range(n):
		var m := ShaderMaterial.new()
		m.shader = ObjectLoader.OBJECT_SHADER
		crowd._add_part(b, {"mesh": mesh, "material": m, "layers": 1, "sort": 0.0, "vol": -1, "centre": 0.0, "twin_key": "aabb%d" % i})
	crowd._push_groups()
	crowd._grow_aabb(Vector3(500, 0, 500))
	crowd._push_groups()
	var pushes := 1
	_check(crowd._aabb_push_at == CrowdGpu.AABB_PUSH_GROUPS, "round 762: new bounds spread over the flushes, %d groups the first (%d)" % [CrowdGpu.AABB_PUSH_GROUPS, crowd._aabb_push_at])
	# A group freed before its turn is skipped (its instance RID cleared).
	var victim: CrowdGpu.Group = crowd._aabb_push[crowd._aabb_push.size() - 1]
	RenderingServer.free_rid(victim.inst)
	victim.inst = RID()
	while crowd._aabb_push_at > 0 and pushes < 10:
		crowd._push_groups()
		pushes += 1
	_check(pushes == 3 and crowd._aabb_push.is_empty(), "... all of them in %d flushes (%d)" % [3, pushes])
	var g: CrowdGpu.Group = crowd._groups.values()[0]
	_check(g.shown_o and g.inst.is_valid(), "a group's opaque instance is shown (its mask) while a body in it does not fade")

## Round 762: a ghost's rigid piece is made a slice at a time (rigid_mesh_sliced
## + step_rigid_jobs) -- the same mesh, vertex for vertex, as rigid_mesh in
## one call; while it is made the recipe waits (RECIPE_PENDING), it is not
## refused.
## NEGATIVE: a slice that skips the vertex where the last stopped fails "the
## same vertices".
func _test_rigid_slices() -> void:
	var crowd := CrowdGpu.new(root.find_world_3d().scenario)
	var mi := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radial_segments = 64
	sphere.rings = 32
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, sphere.get_mesh_arrays())
	mi.mesh = am
	var to_bone := Transform3D(Basis(Vector3(0.3, 1.0, 0.2).normalized(), 0.7), Vector3(1.0, 2.0, 3.0))
	var whole := crowd.rigid_mesh(mi, "L|whole", 3, to_bone)
	crowd.rigid_pending = false
	_check(crowd.rigid_mesh_sliced(mi, "L|sliced", 3, to_bone) == null and crowd.rigid_pending,
		"round 762: a rigid piece not made yet is pending, not refused")
	var steps := 0
	while steps < 100000:
		crowd.step_rigid_jobs(1)
		steps += 1
		var job = crowd._rigid_jobs.values()[0] if not crowd._rigid_jobs.is_empty() else null
		if job == null or int(job["k"]) >= int(job["n"]):
			break
	var sliced := crowd.rigid_mesh_sliced(mi, "L|sliced", 3, to_bone)
	var a: Array = whole.surface_get_arrays(0) if whole != null else []
	var b: Array = sliced.surface_get_arrays(0) if sliced != null else []
	var same: bool = not a.is_empty() and not b.is_empty() and a[Mesh.ARRAY_VERTEX] == b[Mesh.ARRAY_VERTEX] \
		and a[Mesh.ARRAY_NORMAL] == b[Mesh.ARRAY_NORMAL] and a[Mesh.ARRAY_BONES] == b[Mesh.ARRAY_BONES]
	_check(same and steps > 1, "... made over %d slices, the same vertices, normals and bones as in one call (%d vertices)" % [steps,
		(a[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() if not a.is_empty() else 0])
	_check(crowd.rigid_mesh_sliced(mi, "L|sliced", 3, to_bone) == sliced, "... and kept")
	mi.free()

func _test_frames_and_rebase() -> void:
	var crowd := CrowdGpu.new(root.find_world_3d().scenario)
	var clip := _clip(1166, 6)
	var skel := _make_body()
	var holder := Node3D.new()
	holder.set_meta("character_id", 7)
	holder.add_child(skel)
	root.add_child(holder)
	var entry := [skel, clip, 6, 1.85, true, 0.0, null]
	crowd.can_draw(skel, entry)
	crowd.bake_all()
	crowd.add(holder, skel, entry, 0.0)
	var fr := CrowdAnim.frames_for(skel, clip)
	var bad := 0
	var checked := 0
	var t := 0.0
	# 0 to 200 s in uneven steps: past three of the clock's rebases.
	while t < 200.0:
		crowd.flush(t)
		var want := CrowdAnim.frame_index(clip, t + 1.85, true, fr.count)
		if crowd.frame_of(skel, t) != want:
			bad += 1
		checked += 1
		t += 0.0173 + 0.31 * fposmod(t * 7.0, 1.0)
	_check(bad == 0, "the shader's frame is CrowdAnim.frame_index's at %d times over 200 s, across the clock's rebase (%d differ)" % [checked, bad])
	crowd.remove(skel)
	root.remove_child(holder)
	holder.free()

## Round 747's review: F3 (pages), F7 (empty groups go), F8 (a blended part
## keeps the body near), F9 (an unmirrored body stays near, round 828), F11 (the switch).
func _test_review_fixes() -> void:
	var crowd := CrowdGpu.new(root.find_world_3d().scenario)
	var skel := _make_body()
	var holder := Node3D.new()
	holder.set_meta("character_id", 900)
	holder.add_child(skel)
	root.add_child(holder)
	skel.set_meta(CrowdAnim.META_CACHED, true)
	# F3: a short clip, then a 12 s one, so the long one's rows run past the
	# first page; a frame in the second page lands where the near skin does.
	var short := _clip(900, 4, 0.1)
	crowd.can_draw(skel, [skel, short, 4, 0.0, true, 0.0, null])
	var long := _clip(12000, 9, 0.2)
	var entry := [skel, long, 9, 0.0, true, 0.0, null]
	crowd.can_draw(skel, entry)
	crowd.bake_all()
	var t := 11.0
	MonsterCrowd.pose_at(skel, long, t, true)
	var near := _near_vertices(skel)
	_check(crowd.add(holder, skel, entry, t), "F3: a body on a clip baked past the first page is drawn far")
	crowd.flush(t)
	var row := crowd.frame_of(skel, t)
	var far := crowd.cpu_skin(skel, t)
	var worst := 0.0
	for p in range(mini(near.size(), far.size())):
		for k in range((near[p] as PackedVector3Array).size()):
			worst = maxf(worst, (near[p] as PackedVector3Array)[k].distance_to((far[p] as PackedVector3Array)[k]))
	var l: CrowdGpu.Layout = crowd.body_of(skel).layout
	var clip_rows: Vector3i = l.clips[crowd.body_of(skel).frames]
	_check(clip_rows.x + row >= CrowdGpu.PAGE_ROWS and l.pages.size() == 2 and l.tex != null and l.tex.get_layers() == 2,
		"F3: its frame is in the second page (row %d), two pages, a two-layer texture" % (clip_rows.x + row))
	_check(far.size() == near.size() and worst < 1e-4, "F3: and it is skinned where the near path skins it (worst %s)" % str(worst))
	# F7: emptied groups go after GROUP_EMPTY_CYCLES cycles, with their twins.
	var groups_before := crowd.describe()
	crowd.remove(skel)
	for c in range(CrowdGpu.GROUP_EMPTY_CYCLES - 1):
		crowd.collect()
	_check(crowd._groups.size() > 0, "F7: an empty group is kept for a while (%d)" % crowd._groups.size())
	crowd.collect()
	_check(crowd._groups.is_empty() and crowd._twins.is_empty(), "F7: then freed, its twin with it (%s, then %d groups, %d twins)" % [groups_before, crowd._groups.size(), crowd._twins.size()])
	# F8: a blended part keeps the body near.
	var piece := skel.get_node("Piece") as MeshInstance3D
	var plain := piece.material_override
	var blend := ShaderMaterial.new()
	blend.shader = ObjectLoader._mod_shader("back", "mix", true)
	piece.material_override = blend
	_check(not crowd.add(holder, skel, entry, t) and crowd.refusals.has("blended"), "F8: a body with a blended part is not drawn far")
	piece.material_override = plain
	# Round 828: a twin culls the other face (the far instance is the identity).
	_check(CrowdGpu.mirrored_cull("render_mode blend_mix, cull_back;") == "render_mode blend_mix, cull_front;"
		and CrowdGpu.mirrored_cull("render_mode cull_front, unshaded;") == "render_mode cull_back, unshaded;"
		and CrowdGpu.mirrored_cull("render_mode unshaded, cull_disabled;") == "render_mode unshaded, cull_disabled;"
		and CrowdGpu.mirrored_cull("render_mode unshaded;") == "render_mode unshaded, cull_front;",
		"a twin's cull: back <-> front, disabled kept, none (back) -> front")
	_check(CrowdGpu.twin_code("shader_type spatial;\nvoid fragment() {}").contains("render_mode cull_front;"),
		"a shader naming no render_mode gets cull_front")
	# F9, round 828: the twins cull for a mirrored body, so one that is not
	# mirrored (here a holder mirroring it back) stays near.
	holder.scale = Vector3(-1.0, 1.0, 1.0)
	_check(not crowd.add(holder, skel, entry, t) and crowd.refusals.has("unmirrored"), "F9: an unmirrored body is not drawn far")
	holder.scale = Vector3.ONE
	_check(crowd.add(holder, skel, entry, t), "... and the same body, mirrored as the world's are, is")
	crowd.remove(skel)
	root.remove_child(holder)
	holder.free()
	# F11: the player's switch round-trips through the settings file.
	var path := "user://crowd_gpu_test_settings.cfg"
	var o := VideoOptions.new()
	_check(o.gpu_crowd, "F11: the far crowd on the GPU is on by default")
	o.gpu_crowd = false
	o.save(path)
	_check(not VideoOptions.load_saved(path).gpu_crowd and not o.duplicate_options().gpu_crowd, "F11: off is saved, loaded and copied")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

# --- the world ---------------------------------------------------------------------

func _make_world() -> Node:
	var sub := GDScript.new()
	sub.source_code = "\n".join(PackedStringArray([
		"extends \"res://scripts/World3D.gd\"",
		"func _ready() -> void:",
		"\tpass",
		"func _physics_process(_delta: float) -> void:",
		"\tpass",
		"func _process(_delta: float) -> void:",
		"\tpass",
		"func _input(_event: InputEvent) -> void:",
		"\tpass",
		"func _unhandled_input(_event: InputEvent) -> void:",
		"\tpass",
		""]))
	_check(sub.reload() == OK and sub.can_instantiate(), "a quiet subclass of World3D.gd compiles")
	var scene := load("res://scenes/World3D.tscn") as PackedScene
	if not sub.can_instantiate() or scene == null:
		return null
	var world: Node = scene.instantiate()
	world.set_script(sub)
	root.add_child(world)
	return world

## Round 747's review, F2: a far body within 600 of the listener plays its
## clip sounds from the CPU, advanced only when its clock passes the clip's
## next key; out of hearing it is rested and fires nothing.
func _test_far_sounds(world: Node, skel: Skeleton3D, clip: BanReader.ParsedAnimation) -> void:
	var crowd: CrowdGpu = world.get("_crowd_gpu")
	_check(crowd.has(skel), "the sound body is far")
	var sounds = world.get("_anim_sounds")
	var stub = load("res://scripts/audio_anim/anim_sound_stub.gd").new()
	AnimSoundSeam.set_sink(stub)
	var obj := BsrReader.ParsedObject.new()
	var set := BsrReader.SoundSet.new()
	for k in [100, 600]:
		var tr := BsrReader.SoundTrack.new()
		tr.key_ms = k
		tr.name = "snd_run1"
		set.tracks.append(tr)
	obj.sound_sets_by_type["7:default"] = set
	clip.set_meta(BsrReader.CLIP_META, [7, "default"])
	var owner := AnimSounds.Owner.new()
	owner.label = "far body"
	owner.token = "MOB_TEST"
	owner.parsed = obj
	owner.node = skel.get_parent()
	owner.material = func() -> int: return 0
	sounds.register(skel, owner)
	sounds.print_lines = false
	var b: CrowdGpu.Body = crowd.body_of(skel)
	b.sound_due = -INF
	var player := world.get("player") as Node3D
	if player != null:
		player.global_position = Vector3.ZERO
	var adv0 := int(crowd.stats.get("sound_advances", 0))
	sounds.fired.clear()
	var t0: float = world.get("_idle_anim_time")
	# Two seconds at 60 frames: the 1000 ms loop passes 100 and 600 twice.
	for f in range(120):
		world.set("_idle_anim_time", t0 + float(f + 1) / 60.0)
		world._crowd_gpu_step()
	var mine := 0
	for e in sounds.fired:
		if String(e[2]) == "far body":
			mine += 1
	var advances := int(crowd.stats.get("sound_advances", 0)) - adv0
	# What a body advanced every frame would fire over the same frames (the
	# near tick's way): the keys crossed from the first frame's clip time on.
	var want := 0
	var phase := float(b.entry[3])
	var prev := fposmod((t0 + 1.0 / 60.0 + phase) * 1000.0, 1000.0)
	for f in range(1, 120):
		var now := fposmod((t0 + float(f + 1) / 60.0 + phase) * 1000.0, 1000.0)
		want += AnimSounds.crossed(set.tracks, prev, now, 1000.0, true).size()
		prev = now
	_check(b.heard and want >= 3 and mine == want, "a far body within hearing fires its loop's keys from the CPU, as a body advanced every frame would: %d of %d" % [mine, want])
	_check(advances <= 8, "... advanced only at its keys, not every frame (%d advances in 120 frames)" % advances)
	# Out of hearing: rested, silent.
	if player != null:
		player.global_position = Vector3(5000.0, 0.0, 0.0)
	for f in range(CrowdGpu.RESELECT_FRAMES * 2):
		world._crowd_gpu_step()
	sounds.fired.clear()
	var t1: float = world.get("_idle_anim_time")
	for f in range(120):
		world.set("_idle_anim_time", t1 + float(f + 1) / 60.0)
		world._crowd_gpu_step()
	_check(not b.heard and sounds.fired.is_empty(), "past 600 of the listener it is not heard and fires nothing (%d)" % sounds.fired.size())
	if player != null:
		player.global_position = Vector3.ZERO
	for f in range(CrowdGpu.RESELECT_FRAMES * 2):
		world._crowd_gpu_step()
	sounds.unregister(skel)
	AnimSoundSeam.set_sink(null)
	clip.remove_meta(BsrReader.CLIP_META)

func _piece(s) -> MeshInstance3D:
	return (s as Skeleton3D).get_node("Piece") as MeshInstance3D

func _test_world(world: Node) -> void:
	var cam := Camera3D.new()
	world.add_child(cam)
	cam.global_position = Vector3(0.0, 5.0, 0.0)
	cam.look_at(Vector3(0.0, 5.0, -100.0))
	cam.far = 4000.0
	cam.make_current()
	CrowdGpu.near_count = 4
	var clip := _clip(1000, 5)
	var holder := Node3D.new()
	world.add_child(holder)
	var bodies: Dictionary = world.get("_other_bodies")
	var gaits: Dictionary = world.get("_other_gaits")
	var animated: Array = world.get("_animated")
	# Eleven ahead at 10, 20 .. 110 units, one behind the camera.
	var spots: Array = []
	for k in range(11):
		spots.append(Vector3(0.0, 0.0, -10.0 * float(k + 1)))
	spots.append(Vector3(0.0, 0.0, 35.0))
	var skels: Array = []
	for k in range(spots.size()):
		var node := Node3D.new()
		node.position = spots[k]
		node.set_meta("character_id", 500 + k)
		var skel := _make_body()
		skel.rotation.y = PI
		node.add_child(skel)
		holder.add_child(node)
		bodies[500 + k] = node
		gaits[500 + k] = {"skeleton": skel, "body": "", "group": "default", "moving": false}
		animated.append([skel, clip, 5, 0.37 * float(k), true, 0.0, null])
		skels.append(skel)
	var total_before: int = world._animated_total()
	for f in range(CrowdGpu.RESELECT_FRAMES * 4):
		world._crowd_gpu_step()
	var crowd: CrowdGpu = world.get("_crowd_gpu")
	_check(crowd != null, "the world made its CrowdGpu")
	if crowd == null:
		return
	var far_ids: Array = []
	for k in range(skels.size()):
		if crowd.has(skels[k]):
			far_ids.append(k)
	# Near from the start: the five nearest (NEAR_HYSTERESIS x 4 by rank:
	# 10..40 ahead and the one 35 behind the camera, out of view but among
	# the nearest, so heard) stay near; 50 and on go far.
	_check(far_ids == [4, 5, 6, 7, 8, 9, 10], "the nearest stay near, in view or not, the rest go far (far: %s)" % str(far_ids))
	# A far body is not among the 4 nearest: it does not come back; once one
	# of them goes, the 5th nearest... stays near either way, and a far body
	# moved among the nearest comes back.
	var mover: Node3D = (skels[10] as Skeleton3D).get_parent()
	mover.position = Vector3(0.0, 0.0, -5.0)
	for f in range(CrowdGpu.RESELECT_FRAMES * 2):
		world._crowd_gpu_step()
	_check(not crowd.has(skels[10]) and _piece(skels[10]).visible, "a far body that comes among the nearest comes back to the full path")
	mover.position = spots[10]
	for f in range(CrowdGpu.RESELECT_FRAMES * 2):
		world._crowd_gpu_step()
	_check(crowd.has(skels[10]), "... and goes far again when it walks away")
	var in_tick := 0
	for e in world.get("_animated"):
		if skels.has(e[0]):
			in_tick += 1
	_check(in_tick == skels.size() - crowd.body_count() and crowd.body_count() >= 7 and world._animated_total() == total_before,
		"a far body's entry leaves the clip tick (%d left in it), the total stays (%d)" % [in_tick, world._animated_total()])
	_check(not _piece(skels[6]).visible and _piece(skels[0]).visible, "far bodies' meshes are hidden, near ones shown")
	_test_far_sounds(world, skels[7], clip)
	# A one-shot brings a far body back.
	var hit := _clip(400, 3, 0.25)
	hit.cyclic = false
	world._play_once(skels[6], hit)
	var found := false
	for e in world.get("_animated"):
		if e[0] == skels[6] and e[1] == hit:
			found = true
	_check(not crowd.has(skels[6]) and _piece(skels[6]).visible and found,
		"a one-shot on a far body brings it back to the full path and plays there")
	# A loop it has baked keeps a far body far; one it has not brings it back.
	world._swap_other_loop(skels[7], clip)
	_check(crowd.has(skels[7]), "a loop already baked keeps the body far")
	var run := _clip(700, 4, 0.75)
	world._swap_other_loop(skels[8], run)
	var swapped := false
	for e in world.get("_animated"):
		if e[0] == skels[8] and e[1] == run:
			swapped = true
	_check(not crowd.has(skels[8]) and swapped, "a loop not baked brings the body back, swapped there")
	# A far body leaving the tree comes off the instances, its entry back.
	var leaving: Node3D = (skels[9] as Skeleton3D).get_parent()
	holder.remove_child(leaving)
	var back := false
	for e in world.get("_animated"):
		if e[0] == skels[9]:
			back = true
	_check(not crowd.has(skels[9]) and back, "a far body leaving the tree is taken off the instances, its entry back in the tick")
	holder.add_child(leaving)
	# A5 off: every body back.
	CrowdGpu.enabled = false
	world._crowd_gpu_step()
	_check(crowd.body_count() == 0, "A5 switched off brings every body back")
	var shown := true
	for s in skels:
		shown = shown and _piece(s).visible
	_check(shown and world._animated_total() == world.get("_animated").size(), "... shown, every entry in the clip tick")
	CrowdGpu.enabled = true
	CrowdGpu.near_count = 64
