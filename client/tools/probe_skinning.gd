extends SceneTree

## Dev tool: says exactly where a skinned character's vertices go under a real
## .ban pose, by replicating the GPU's skinning on the CPU -- so "the legs
## vanish when the idle plays" becomes numbers, not a screenshot.
##
## Two reports, headless (no GL):
##   A. bones: for the spine, arm and leg chains, the .bsk rest (local rotation
##      + translation, global origin), the .ban keyframe-0 value for that bone,
##      and the global origin after the pose is applied.
##   B. pieces: for every skinned mesh piece, the palette it names and the
##      Y-range/centroid of its vertices at rest and after the pose, computed as
##      sum_k w_k * (bone_global_pose_k * skin_bind_k) * v -- the same maths the
##      vertex shader does. A piece whose posed range leaves the body is the one
##      the animation eats.
##
## Usage:
##   godot4 --headless --path client --script res://tools/probe_skinning.gd -- \
##     --pk2=/opt/sro-files/client/Data.pk2 [--body=char\china\chinaman_fighter.bsr]
##     [--group=sword] [--seconds=0.0] [--ban=<explicit .ban path>]

const CHAIN := [
	"Bip01", "Bip01 Pelvis", "Bip01 Spine", "Bip01 Spine1", "Bip01 Neck", "Bip01 Head",
	"Bip01 L Clavicle", "Bip01 L UpperArm", "Bip01 L Forearm", "Bip01 L Hand",
	"Bip01 R Clavicle", "Bip01 R UpperArm", "Bip01 R Forearm", "Bip01 R Hand",
	"Bip01 L Thigh", "Bip01 L Calf", "Bip01 L Foot", "Bip01 L Toe0",
	"Bip01 R Thigh", "Bip01 R Calf", "Bip01 R Foot", "Bip01 R Toe0",
]

func _arg(flag: String, fallback: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return fallback

func _q(q: Quaternion) -> String:
	return "(%.3f,%.3f,%.3f,%.3f)" % [q.x, q.y, q.z, q.w]

func _v(v: Vector3) -> String:
	return "(%.2f,%.2f,%.2f)" % [v.x, v.y, v.z]

func _initialize() -> void:
	var pk2_path := _arg("--pk2")
	var body := _arg("--body", "char\\china\\chinaman_fighter.bsr")
	var group := _arg("--group", "sword")
	var seconds := float(_arg("--seconds", "0.0"))
	var ban_override := _arg("--ban")
	if pk2_path == "":
		printerr("usage: --pk2=<Data.pk2> [--body=..] [--group=..] [--seconds=..] [--ban=..]")
		quit(2)
		return
	var data := Pk2Reader.open(pk2_path)
	if data == null:
		printerr("could not open ", pk2_path)
		quit(1)
		return
	var assembled := SkinnedBsrAssembler.assemble_from_archive(data, body, false)
	if assembled == null:
		printerr("could not assemble ", body)
		quit(1)
		return
	var skeleton := assembled.skeleton
	var parsed: BsrReader.ParsedObject = assembled.parsed

	var ban_path := ban_override
	if ban_path == "":
		ban_path = parsed.animation_for(BsrReader.AnimationEntry.TYPE_STAND, group)
	var bytes := AssetSource.read_bytes(ban_path, data)
	if bytes.is_empty():
		bytes = AssetSource.read_bytes("res\\" + ban_path, data)
	var anim := BanReader.parse(bytes) if not bytes.is_empty() else null
	if anim == null:
		printerr("could not read animation ", ban_path)
		quit(1)
		return
	print("body %s  bones %d  pieces %d" % [body.get_file(), skeleton.get_bone_count(), assembled.skinned_pieces])
	print("clip %s  tracks %d  keys %d  duration %d ms  at %.2fs" % [
		ban_path.get_file(), anim.bones.size(), anim.key_times.size(), anim.duration_ms, seconds])

	# Which skeleton bones have no track, and which tracks have no bone.
	var tracks := {}
	for track in anim.bones:
		tracks[track.bone_name] = track
	var untracked := PackedStringArray()
	for i in range(skeleton.get_bone_count()):
		if not tracks.has(skeleton.get_bone_name(i)):
			untracked.append(skeleton.get_bone_name(i))
	var orphan := PackedStringArray()
	for name in tracks:
		if skeleton.find_bone(name) == -1:
			orphan.append(name)
	print("bones without a track: %s" % str(untracked))
	print("tracks without a bone: %s" % str(orphan))

	# --- A. bones: rest, keyframe 0, posed ---
	skeleton.reset_bone_poses()
	Skeleton3DBuilder.refresh_global_poses(skeleton)
	var rest_global := {}
	var rest_local := {}
	for i in range(skeleton.get_bone_count()):
		rest_global[skeleton.get_bone_name(i)] = skeleton.get_bone_global_rest(i).origin
		rest_local[skeleton.get_bone_name(i)] = skeleton.get_bone_rest(i)
	Skeleton3DBuilder.apply_ban_pose_at(skeleton, anim, seconds, true)
	print("")
	print("A. bones  (rest local rot / pos | key0 rot / pos | global rest -> global posed)")
	for name in CHAIN:
		var idx := skeleton.find_bone(name)
		if idx == -1:
			print("  %-18s (not in skeleton)" % name)
			continue
		var rl: Transform3D = rest_local[name]
		var k0 := "(no track)"
		if tracks.has(name):
			var t: BanReader.Bone = tracks[name]
			if not t.keyframes.is_empty():
				var kf: BanReader.Keyframe = t.keyframes[0]
				k0 = "%s / %s" % [_q(kf.rotation), _v(kf.position)]
		var parent := skeleton.get_bone_parent(idx)
		var pname := skeleton.get_bone_name(parent) if parent != -1 else "-"
		print("  %-18s parent=%-16s rest %s / %s | key0 %s | %s -> %s" % [
			name, pname, _q(rl.basis.get_rotation_quaternion()), _v(rl.origin), k0,
			_v(rest_global[name]), _v(skeleton.get_bone_global_pose(idx).origin)])

	# --- B. pieces: CPU skinning at rest and posed ---
	var mesh_paths := parsed.all_mesh_paths()
	var pieces: Array = []
	for child in skeleton.get_children():
		if child is MeshInstance3D and (child as MeshInstance3D).skin != null:
			pieces.append(child)
	print("")
	print("B. pieces (%d skinned)  Y-range and centroid: rest -> posed" % pieces.size())
	# Posed globals are current; capture them, then rest globals from the rest table.
	var posed_global := {}
	for i in range(skeleton.get_bone_count()):
		posed_global[i] = skeleton.get_bone_global_pose(i)
	var rest_global_t := {}
	for i in range(skeleton.get_bone_count()):
		rest_global_t[i] = skeleton.get_bone_global_rest(i)
	for p in range(pieces.size()):
		var mi := pieces[p] as MeshInstance3D
		var label: String = String(mesh_paths[p]).get_file() if p < mesh_paths.size() else String(mi.name)
		var arrays: Array = mi.mesh.surface_get_arrays(0)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
		var skin := mi.skin
		var palette := PackedStringArray()
		for k in range(skin.get_bind_count()):
			palette.append(skeleton.get_bone_name(skin.get_bind_bone(k)))
		var rest_min := INF; var rest_max := -INF; var rest_c := Vector3.ZERO
		var posed_min := INF; var posed_max := -INF; var posed_c := Vector3.ZERO
		var bad_weight := 0
		for i in range(verts.size()):
			var v := verts[i]
			var r := Vector3.ZERO
			var q := Vector3.ZERO
			var wsum := 0.0
			for s in range(4):
				var w := weights[i * 4 + s]
				if w == 0.0:
					continue
				wsum += w
				var k := bones[i * 4 + s]
				var bone := skin.get_bind_bone(k)
				var bind: Transform3D = skin.get_bind_pose(k)
				r += w * ((rest_global_t[bone] as Transform3D) * bind * v)
				q += w * ((posed_global[bone] as Transform3D) * bind * v)
			if absf(wsum - 1.0) > 0.01:
				bad_weight += 1
			rest_min = minf(rest_min, r.y); rest_max = maxf(rest_max, r.y); rest_c += r
			posed_min = minf(posed_min, q.y); posed_max = maxf(posed_max, q.y); posed_c += q
		var n := maxf(float(verts.size()), 1.0)
		print("  %-32s %5d verts  palette %s" % [label, verts.size(), str(palette)])
		print("      rest  y %.2f..%.2f  c %s" % [rest_min, rest_max, _v(rest_c / n)])
		print("      posed y %.2f..%.2f  c %s   %s" % [posed_min, posed_max, _v(posed_c / n),
			("(%d verts with weights not summing to 1)" % bad_weight) if bad_weight > 0 else ""])
	quit(0)
