extends SceneTree

## Dev tool (round 689): every creatable Figure's animations and feet, measured
## against the real archives, headless.
##
## For each of the 52 Figures (CharCatalog) it builds the bare body through
## CharacterAppearance and, for every core action (stand, walk, run, attack,
## hit, die, sit down, sit, stand up) in every weapon group the body's race can
## hold, resolves the clip through the given lookup and checks it:
##   none     -- the lookup names no clip (the T-pose: the body holds its bind)
##   missing  -- the clip it names is not in Data.pk2 or does not parse
##   nobones  -- the clip parses but drives none of the skeleton's bones
##   ok       -- it plays
## and prints one `TPOSE <figure> <group> <action>` line per clip that is not ok.
##
## Feet: the bare body posed at its stand clip's first frame, its CPU-skinned
## vertices' lowest point (the same sum the GPU does) against the body's
## origin, which the world stands on the ground. Printed as `FEET`.
##
##   godot4 --headless --path client --script res://tools/body_anim_probe.gd -- \
##     --pk2=/opt/sro-files/client/Data.pk2 --media=/opt/sro-files/client/Media.pk2 \
##     [--lookup=old|world] [--feet-tolerance=0.5] [--only=<code part>] [--dump=1]
##
## --lookup=old is the lookup World3D used until round 689: the FIRST entry of
## the type in the weapon group, even one naming no file, else `default`.
## --lookup=world (the default) is BodyAnimations, the client's rule (READ,
## round 689: the last entry wins and a null clip falls back to `default`).
## A clip that is not ok prints PARITY FAIL; feet further than the tolerance
## from the ground print a FEET line.

const CORE := {
	"stand": 0, "walk": 1, "run": 7, "attack": 2, "hit": 3, "die": 4,
	"sit_down": 13, "sit": 14, "stand_up": 15,
	# The world's plain-attack combo (World3D.ATTACK_SEQUENCE: types 2, 5, 16,
	# 17, OURS order): each swing must play too.
	"attack_2": 5, "attack_3": 16, "attack_4": 17,
}

var _fails := 0

func _arg(flag: String, fallback: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return fallback

func _initialize() -> void:
	var data := Pk2Reader.open(_arg("--pk2"))
	var media := Pk2Reader.open(_arg("--media"))
	if data == null or media == null:
		printerr("usage: --pk2=<Data.pk2> --media=<Media.pk2> [--lookup=old|world]")
		quit(2)
		return
	var lookup := _arg("--lookup", "world")
	var tolerance := float(_arg("--feet-tolerance", "0.5"))
	var app := CharacterAppearance.from_archives(data, media)
	var cat := app.catalog()
	var anims := BodyAnimations.new(data)
	var tposes := 0
	var checked := 0
	var only := _arg("--only")
	var dump := _arg("--dump") != ""
	for r in [CharCatalog.RACE_CHINA, CharCatalog.RACE_EUROPE]:
		for s in [CharCatalog.SEX_MAN, CharCatalog.SEX_WOMAN]:
			for f in cat.figures(r, s):
				if only != "" and not String(f.code).contains(only):
					continue
				var b := app.build(f.id, 0x22, [])
				if b == null:
					print("PARITY FAIL %s %d does not build" % [f.code, f.id])
					_fails += 1
					continue
				var parsed: BsrReader.ParsedObject = b.assembled.parsed
				if dump:
					_dump(f.code, parsed)
				var groups := ["default"]
				groups.append_array(BodyAnimations.race_groups(r))
				var bad := []
				for g in groups:
					for action_name in CORE:
						var t: int = CORE[action_name]
						checked += 1
						var status := ""
						var anim: BanReader.ParsedAnimation = null
						var path := ""
						if lookup == "old":
							path = _old_lookup(parsed, t, g)
							anim = _read_clip(data, path)
						else:
							path = anims.path_for(b.assembled, t, g)
							anim = anims.clip_for(b.assembled, t, g)
						if path == "":
							status = "none"
						elif anim == null:
							status = "missing"
						else:
							var matched := 0
							for track in anim.bones:
								if b.skeleton.find_bone(track.bone_name) != -1:
									matched += 1
							status = "ok" if matched > 0 else "nobones"
						if status != "ok":
							tposes += 1
							bad.append("%s/%s=%s" % [g, action_name, status])
							print("TPOSE %-26s %-14s %-9s %s %s" % [f.code, g, action_name, status, path])
				var feet := _feet(b, anims, lookup, data)
				print("FIGURE %-26s %5d groups %s  bad %d  feet bind %+.3f stand %+.3f (clip %s)" % [
					f.code, f.id, str(parsed.animation_groups.keys()), bad.size(), feet[0], feet[1], feet[2]])
				if absf(feet[1]) > tolerance:
					print("FEET %s stands %+.3f off the ground (tolerance %.2f)" % [f.code, feet[1], tolerance])
				b.free()
	print("clips checked: %d, not playing: %d (lookup %s)" % [checked, tposes, lookup])
	if tposes > 0:
		print("PARITY FAIL %d clip(s) resolve to no playing animation (lookup %s)" % [tposes, lookup])
		_fails += 1
	app.free_templates()
	print("RESULT: %s (%d failing)" % ["PASS" if _fails == 0 else "FAIL", _fails])
	quit(0)

## The pre-round-689 lookup (World3D and BsrReader until then): the first entry
## of the type in the group, whatever its path, else the same in `default`.
func _old_lookup(parsed: BsrReader.ParsedObject, t: int, group: String) -> String:
	for name in [group, "default"]:
		for e in parsed.animation_groups.get(name, []):
			if e.action_type == t:
				return e.path
	return ""

func _read_clip(data: Pk2Reader, path: String) -> BanReader.ParsedAnimation:
	if path == "":
		return null
	var bytes := AssetSource.read_bytes(path, data)
	if bytes.is_empty():
		bytes = AssetSource.read_bytes("res\\" + path, data)
	var anim: BanReader.ParsedAnimation = BanReader.parse(bytes) if not bytes.is_empty() else null
	return anim if anim != null and not anim.bones.is_empty() else null

func _dump(code: String, parsed: BsrReader.ParsedObject) -> void:
	print("DUMP %s skeleton %s, %d clips" % [code, parsed.skeleton_path, parsed.animation_paths.size()])
	for g in parsed.animation_groups:
		var types := []
		for e in parsed.animation_groups[g]:
			types.append("%d:%s" % [e.action_type, String(e.path).get_file()])
		print("DUMP   group %s (%d): %s" % [g, types.size(), ", ".join(types)])

## [lowest skinned point at bind, at the stand clip's first frame, the clip].
func _feet(b: CharacterAppearance.Body, anims: BodyAnimations, lookup: String, data: Pk2Reader) -> Array:
	var bind_y := _lowest(b.skeleton)
	var stand: BanReader.ParsedAnimation = null
	var path := ""
	if lookup == "old":
		path = _old_lookup(b.assembled.parsed, 0, "default")
		stand = _read_clip(data, path)
	else:
		path = anims.path_for(b.assembled, 0, "default")
		stand = anims.clip_for(b.assembled, 0, "default")
	if stand == null:
		return [bind_y, bind_y, "none"]
	Skeleton3DBuilder.apply_ban_pose_at(b.skeleton, stand, 0.0, true)
	return [bind_y, _lowest(b.skeleton), path.get_file()]

func _lowest(skel: Skeleton3D) -> float:
	Skeleton3DBuilder.refresh_global_poses(skel)
	var lo := INF
	for mi in CharacterAppearance._skinned_to(skel):
		if String(mi.name).ends_with("_front") or not mi.visible:
			continue
		var skin: Skin = mi.skin
		var xf: Array[Transform3D] = []
		for i in range(skin.get_bind_count()):
			xf.append(skel.get_bone_global_pose(skin.get_bind_bone(i)) * skin.get_bind_pose(i))
		var mesh: Mesh = mi.mesh
		for sidx in range(mesh.get_surface_count()):
			var arr := mesh.surface_get_arrays(sidx)
			var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var bones = arr[Mesh.ARRAY_BONES]
			var weights = arr[Mesh.ARRAY_WEIGHTS]
			if bones == null or weights == null or v.is_empty():
				continue
			var per := int(bones.size() / v.size())
			for k in range(v.size()):
				var p := Vector3.ZERO
				var wsum := 0.0
				for j in range(per):
					var w: float = weights[k * per + j]
					if w <= 0.0:
						continue
					var bi: int = bones[k * per + j]
					if bi < xf.size():
						p += (xf[bi] * v[k]) * w
						wsum += w
				if wsum > 0.0:
					lo = minf(lo, (p / wsum).y)
	return lo
