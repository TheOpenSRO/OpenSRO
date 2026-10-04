extends SceneTree

## Dev tool (round 721): what binding a map object's skins to the `.bsk`'s
## STORED world binds (the client's rule, READ: BSK_FORMAT.md "How the
## client skins with those three matrices") moves, against binding them to
## the inverse of the rest this client composes from the locals (round
## 645..720). For every model Map.pk2's `object.ifo` names that animates
## (built as the world builds it, ObjectLoader.load_object), it poses the
## clip at --seconds (default 0) and prints the largest distance any vertex
## moves between the two binds, and the bone it hangs on. A model whose
## stored binds chain from its locals moves 0.
##
## Lines: `BIND <path> max <d> bone <name> verts <n> | mean off the mesh:
## old bind <a>, stored bind <b>` (the mean vertex distance from the
## authored mesh at the posed time under each bind) for every animated
## model (sorted, largest first), then `TALLY`.
##
## Usage (headless, on the render box):
##   godot4 --headless --path client --script res://tools/probe_map_bind.gd -- \
##     --pk2=/opt/sro-files/client/Data.pk2 --map=/opt/sro-files/client/Map.pk2 [--match=alex] [--seconds=0]

var _data: Pk2Reader
var _results: Array = []
var _queue: Array = []
var _seconds := 0.0
var _frames := 0

func _arg(flag: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return ""

func _initialize() -> void:
	_data = Pk2Reader.open(_arg("--pk2"))
	var map := Pk2Reader.open(_arg("--map"))
	if _data == null or map == null:
		printerr("usage: --pk2=<Data.pk2> --map=<Map.pk2>")
		quit(2)
		return
	if _arg("--seconds") != "":
		_seconds = float(_arg("--seconds"))
	var table := ObjidxReader.parse(AssetSource.read_bytes("object.ifo", map))
	var key := _arg("--match").to_lower()
	var seen := {}
	for e in table.entries:
		var p := (e.path as String).to_lower()
		if seen.has(p) or (key != "" and not p.contains(key)):
			continue
		seen[p] = true
		_queue.append(e.path)
	print("probe_map_bind: %d model(s) to try" % _queue.size())

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < 2:
		return false
	for path in _queue:
		_probe(path)
	_results.sort_custom(func(a, b): return a[1] > b[1])
	var moved := 0
	for r in _results:
		if float(r[1]) > 0.01:
			moved += 1
		print("BIND %s max %.3f bone %s verts %d | mean off the mesh: old bind %.3f, stored bind %.3f" % r)
	print("TALLY %d animated model(s); %d move more than 0.01 between the binds" % [_results.size(), moved])
	quit(0)
	return true

func _probe(path: String) -> void:
	# A `.bsr` with no `default` type-0 clip never animates: skip it unbuilt.
	if path.to_lower().ends_with(".bsr"):
		var entry := ObjectLoader.find_file(_data, path)
		if entry == null or MapAnimation.clip_entry(BsrReader.parse(_data.read_file(entry))) == null:
			return
	var node := ObjectLoader.load_object(_data, path)
	if node == null:
		return
	root.add_child(node)
	var holders: Array = []
	if node.has_meta(MapAnimation.META_ANIMATED):
		holders.append(node)
	for c in node.find_children("*", "Node3D", true, false):
		if c.has_meta(MapAnimation.META_ANIMATED):
			holders.append(c)
	if holders.is_empty():
		root.remove_child(node)
		node.free()
		return
	var worst := 0.0
	var worst_bone := ""
	var verts_n := 0
	# How far the pose lands from the authored mesh under each bind: the mean
	# vertex distance from the mesh's own (still) position.
	var dev_new := 0.0
	var dev_old := 0.0
	for h in holders:
		var skeleton := (h as Node).get_node_or_null(MapAnimation.SKELETON_NODE) as Skeleton3D
		var player := (h as Node).get_node_or_null(MapAnimation.PLAYER_NODE) as AnimationPlayer
		if skeleton == null or player == null:
			continue
		player.play(MapAnimation.CLIP_NAME)
		player.seek(_seconds, true)
		skeleton.force_update_all_bone_transforms()
		for mi in (h as Node).find_children("*", "MeshInstance3D", true, false):
			var m := mi as MeshInstance3D
			if m.skin == null or m.mesh == null:
				continue
			var arrays: Array = m.mesh.surface_get_arrays(0)
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
			var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
			verts_n += verts.size()
			for i in range(verts.size()):
				var now := Vector3.ZERO
				var before := Vector3.ZERO
				var heavy := -1
				var heavy_w := 0.0
				for s in range(4):
					var w := weights[i * 4 + s]
					if w == 0.0:
						continue
					var k := bones[i * 4 + s]
					var bone := m.skin.get_bind_bone(k)
					var pose := skeleton.get_bone_global_pose(bone)
					now += w * (pose * m.skin.get_bind_pose(k) * verts[i])
					var old_bind := Transform3D.IDENTITY
					if Skeleton3DBuilder.is_skeleton_bone(skeleton, bone):
						old_bind = skeleton.get_bone_global_rest(bone).affine_inverse()
					before += w * (pose * old_bind * verts[i])
					if w > heavy_w:
						heavy_w = w
						heavy = bone
				dev_new += now.distance_to(verts[i])
				dev_old += before.distance_to(verts[i])
				var d := now.distance_to(before)
				if d > worst:
					worst = d
					worst_bone = skeleton.get_bone_name(heavy) if heavy >= 0 else ""
	var n := maxf(float(verts_n), 1.0)
	_results.append([path, worst, worst_bone, verts_n, dev_old / n, dev_new / n])
	root.remove_child(node)
	node.free()
