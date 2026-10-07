extends SceneTree

## Dev tool (round 648): where an animated MAP object's vertices go, as this
## client draws it. Builds the object exactly as the world does
## (ObjectLoader.load_object -> MapAnimation.prepare/commit), plays its
## `default` clip through its own AnimationPlayer, and CPU-skins every
## skinned piece -- sum_k w_k * (bone_global_pose_k * bind_k) * v, the vertex
## shader's maths -- printing each piece's bounding box unposed (the mesh's
## own vertices, what a still object draws) against posed. At the clip's
## first key the two should match; the Dunhuang reeds before round 648 were
## (154, 22, 104) still and 3.7e24 wide posed -- a skin bound to an unset
## root.
##
## It also prints, per bone, the .bsk rest (local) against the clip's first
## key, since a track whose key is a DIFFERENT kind of value from the rest
## (a delta, another handedness) is what flattens a body.
##
## Usage (headless, on the render box):
##   godot4 --headless --path client --script res://tools/probe_map_anim_pose.gd -- \
##     --pk2=/opt/sro-files/client/Data.pk2 --file='res\nature\china\dunhuang\reed\fw_cd_reeds_l.bsr' \
##     [--seconds=0.0,0.5]

var _root: Node3D
var _frames := 0
var _times: PackedFloat32Array = [0.0]
var _path := ""
## Round 721: the `.bsk`'s stored binds (Skeleton3DBuilder.stored_world_binds)
## and the bones the clip keys, printed beside each bone's rest and pose.
var _binds := {}
var _keyed := {}

func _arg(flag: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return ""

func _v(v: Vector3) -> String:
	return "(%.2f, %.2f, %.2f)" % [v.x, v.y, v.z]

func _q(q: Quaternion) -> String:
	return "(%.3f, %.3f, %.3f, %.3f)" % [q.x, q.y, q.z, q.w]

func _initialize() -> void:
	var archive := Pk2Reader.open(_arg("--pk2"))
	_path = _arg("--file").replace("/", "\\")
	if archive == null or _path == "":
		print("usage: --pk2=Data.pk2 --file=<.bsr>")
		quit(1)
		return
	if _arg("--seconds") != "":
		_times = PackedFloat32Array()
		for s in _arg("--seconds").split(","):
			_times.append(float(s))
	_root = ObjectLoader.load_object(archive, _path)
	if _root == null:
		print("could not load %s" % _path)
		quit(1)
		return
	root.add_child(_root)
	var entry := MapAnimation.clip_entry(BsrReader.parse(archive.read_file(ObjectLoader.find_file(archive, _path))))
	print("object %s: clip %s, animated %s" % [_path, entry.path if entry != null else "(none)", str(_root.has_meta(MapAnimation.META_ANIMATED))])
	var skeleton := _root.get_node_or_null(MapAnimation.SKELETON_NODE) as Skeleton3D
	if skeleton == null:
		print("no map skeleton -- the object is drawn still")
		quit(0)
		return
	var clip := BanReader.parse(archive.read_file(ObjectLoader.find_file(archive, entry.path)))
	var key0 := {}
	for track in clip.bones:
		if not track.keyframes.is_empty():
			key0[track.bone_name] = track.keyframes[0]
			_keyed[track.bone_name] = true
	var bsr := BsrReader.parse(archive.read_file(ObjectLoader.find_file(archive, _path)))
	var bsk_entry := ObjectLoader.find_file(archive, bsr.skeleton_path)
	if bsk_entry != null:
		_binds = Skeleton3DBuilder.stored_world_binds(BskReader.parse(archive.read_file(bsk_entry)))
	print("bones (%d)  rest local rot / pos | key0 rot / pos" % skeleton.get_bone_count())
	for i in range(skeleton.get_bone_count()):
		var name := skeleton.get_bone_name(i)
		var r := skeleton.get_bone_rest(i)
		var k := "(no track)"
		if key0.has(name):
			var kf: BanReader.Keyframe = key0[name]
			k = "%s / %s" % [_q(kf.rotation.normalized()), _v(kf.position)]
		print("  %-24s parent %-3d rest %s / %s | key0 %s" % [name, skeleton.get_bone_parent(i), _q(r.basis.get_rotation_quaternion()), _v(r.origin), k])

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < 2 or _root == null:
		return false
	var skeleton := _root.get_node(MapAnimation.SKELETON_NODE) as Skeleton3D
	var player := _root.get_node(MapAnimation.PLAYER_NODE) as AnimationPlayer
	for t in _times:
		player.play(MapAnimation.CLIP_NAME)
		player.seek(t, true)
		Skeleton3DBuilder.refresh_global_poses(skeleton)
		print("t = %.2f s" % t)
		# Round 721: every bone's global rest against its global pose, so a
		# bone whose pose leaves its rest at t = 0 (a track that is not the
		# rest's kind of value) shows by name.
		for b in range(skeleton.get_bone_count()):
			var stored := "-"
			if _binds.has(skeleton.get_bone_name(b)):
				stored = _v((_binds[skeleton.get_bone_name(b)] as Transform3D).origin)
			print("  bone %-24s global rest %s  global pose %s  stored bind %s  keyed %s" % [skeleton.get_bone_name(b),
				_v(skeleton.get_bone_global_rest(b).origin), _v(skeleton.get_bone_global_pose(b).origin), stored,
				str(_keyed.has(skeleton.get_bone_name(b)))])
		for mi in _root.find_children("*", "MeshInstance3D", true, false):
			var m := mi as MeshInstance3D
			if m.mesh == null:
				continue
			if m.skin == null:
				print("  still piece %-22s centre %s size %s" % [m.name, _v(m.mesh.get_aabb().get_center()), _v(m.mesh.get_aabb().size)])
				continue
			var arrays: Array = m.mesh.surface_get_arrays(0)
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
			var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
			var still := AABB(verts[0], Vector3.ZERO)
			var posed := AABB()
			for i in range(verts.size()):
				var q := Vector3.ZERO
				for s in range(4):
					var w := weights[i * 4 + s]
					if w == 0.0:
						continue
					var k := bones[i * 4 + s]
					q += w * (skeleton.get_bone_global_pose(m.skin.get_bind_bone(k)) * m.skin.get_bind_pose(k) * verts[i])
				still = still.expand(verts[i])
				posed = AABB(q, Vector3.ZERO) if i == 0 else posed.expand(q)
			var bound := PackedStringArray()
			for k in range(m.skin.get_bind_count()):
				bound.append(skeleton.get_bone_name(m.skin.get_bind_bone(k)))
			print("  piece %-28s %5d verts  still size %s centre %s  posed size %s  posed centre %s  bones %s" % [
				m.name, verts.size(), _v(still.size), _v(still.get_center()), _v(posed.size), _v(posed.get_center()), ",".join(bound)])
	quit(0)
	return true
