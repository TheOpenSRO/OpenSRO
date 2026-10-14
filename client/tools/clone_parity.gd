extends SceneTree

## Round 786: MonsterDraw.clone_tree against duplicate() on the player's own
## monster templates -- every MOB_ model with a row of its own (up to
## --limit), assembled as World3D assembles them -- node by node: class, name,
## metas, transform, bones and poses, meshes, skins, materials, draw settings,
## children. Prints one line a model and `CLONE PARITY PASS` or
## `CLONE PARITY FAIL` (remote_godot.sh exits 1 on the latter's PARITY FAIL).
##
##   remote_godot.sh script res://tools/clone_parity.gd -- \
##     --pk2=/opt/sro-files/client/Data.pk2 --media=/opt/sro-files/client/Media.pk2 [--limit=60]

var _diffs := 0
var _checked := 0

func _arg(flag: String, fallback: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return fallback

func _diff(model: String, what: String) -> void:
	_diffs += 1
	if _diffs <= 40:
		print("CLONE DIFF %s: %s" % [model, what])

func _same(model: String, a: Node, b: Node, path: String) -> void:
	_checked += 1
	if a.get_class() != b.get_class():
		_diff(model, "%s class %s vs %s" % [path, a.get_class(), b.get_class()])
		return
	if a.name != b.name:
		_diff(model, "%s name %s vs %s" % [path, a.name, b.name])
	if a.get_meta_list() != b.get_meta_list():
		_diff(model, "%s metas %s vs %s" % [path, a.get_meta_list(), b.get_meta_list()])
	else:
		for k in a.get_meta_list():
			if a.get_meta(k) != b.get_meta(k):
				_diff(model, "%s meta %s" % [path, k])
	if a is Node3D and not a is BoneAttachment3D:
		if not (a as Node3D).transform.is_equal_approx((b as Node3D).transform):
			_diff(model, "%s transform" % path)
		if (a as Node3D).visible != (b as Node3D).visible:
			_diff(model, "%s visible" % path)
	if a is Skeleton3D:
		var sa := a as Skeleton3D
		var sb := b as Skeleton3D
		if sa.get_bone_count() != sb.get_bone_count():
			_diff(model, "%s bone count" % path)
		else:
			for i in sa.get_bone_count():
				if sa.get_bone_name(i) != sb.get_bone_name(i) or sa.get_bone_parent(i) != sb.get_bone_parent(i) \
						or not sa.get_bone_rest(i).is_equal_approx(sb.get_bone_rest(i)) or sa.is_bone_enabled(i) != sb.is_bone_enabled(i) \
						or not sa.get_bone_pose_position(i).is_equal_approx(sb.get_bone_pose_position(i)) \
						or not sa.get_bone_pose_rotation(i).is_equal_approx(sb.get_bone_pose_rotation(i)) \
						or not sa.get_bone_pose_scale(i).is_equal_approx(sb.get_bone_pose_scale(i)):
					_diff(model, "%s bone %d" % [path, i])
	if a is MeshInstance3D:
		var ma := a as MeshInstance3D
		var mb := b as MeshInstance3D
		if ma.mesh != mb.mesh or ma.skin != mb.skin or ma.skeleton != mb.skeleton:
			_diff(model, "%s mesh/skin/skeleton path" % path)
		if ma.material_override != mb.material_override or ma.material_overlay != mb.material_overlay:
			_diff(model, "%s material" % path)
		for i in ma.get_surface_override_material_count():
			if ma.get_surface_override_material(i) != mb.get_surface_override_material(i):
				_diff(model, "%s surface %d material" % [path, i])
		if ma.cast_shadow != mb.cast_shadow or ma.layers != mb.layers or ma.sorting_offset != mb.sorting_offset \
				or ma.extra_cull_margin != mb.extra_cull_margin or ma.gi_mode != mb.gi_mode or ma.transparency != mb.transparency \
				or ma.visibility_range_end != mb.visibility_range_end or ma.custom_aabb != mb.custom_aabb:
			_diff(model, "%s draw settings" % path)
	if a is BoneAttachment3D:
		var aa := a as BoneAttachment3D
		var ab := b as BoneAttachment3D
		if aa.bone_name != ab.bone_name or aa.override_pose != ab.override_pose:
			_diff(model, "%s attachment" % path)
	if a.get_child_count() != b.get_child_count():
		_diff(model, "%s children %d vs %d" % [path, a.get_child_count(), b.get_child_count()])
		return
	for i in a.get_child_count():
		_same(model, a.get_child(i), b.get_child(i), "%s/%s" % [path, a.get_child(i).name])

func _initialize() -> void:
	var data := Pk2Reader.open(_arg("--pk2"))
	var media := Pk2Reader.open(_arg("--media"))
	if data == null or media == null:
		printerr("usage: --pk2=<Data.pk2> --media=<Media.pk2> [--limit=60]")
		quit(2)
		return
	var limit := int(_arg("--limit", "60"))
	var models := {}
	for path in NpcTableReader.model_table_paths(media):
		var entry := ObjectLoader.find_file(media, path)
		if entry != null:
			models = NpcTableReader.parse_models_by_code(media.read_file(entry), models, "")
	var seen := {}
	var codes: Array = []
	for code in models:
		if String(code).begins_with("MOB_"):
			codes.append(code)
	codes.sort()
	var done := 0
	for code in codes:
		var model := String(models[code])
		if seen.has(model) or done >= limit:
			continue
		seen[model] = true
		var t := SkinnedBsrAssembler.assemble_from_archive(data, model, true)
		if t == null:
			continue
		done += 1
		var before := _diffs
		var dup := t.skeleton.duplicate()
		var cl := MonsterDraw.clone_tree(t.skeleton)
		_same(model, dup, cl, String(t.skeleton.name))
		print("CLONE %s: %d bones, %d pieces, %s" % [model, t.skeleton.get_bone_count(), t.skeleton.get_child_count(),
			"same" if _diffs == before else "DIFFERS"])
		dup.free()
		cl.free()
		t.skeleton.free()
	print("CLONE PARITY %s: %d models, %d nodes compared, %d difference(s)" % ["PASS" if _diffs == 0 and done > 0 else "FAIL", done, _checked, _diffs])
	quit(0)
