extends SceneTree

## Dev probe: which way each roster monster's body faces, in the space its
## Skeleton3D is placed in (World3D._spawn_or_update_monster adds the
## assembled skeleton to the body node with no turn of its own).
##
## World3D faces a moving monster along its path (MonsterMotion.facing_yaw),
## and that needs the body's own front axis. A guessed axis is exactly the
## failure round 506 recorded for map objects (a positive yaw "confirmed" by a
## picture), so this measures it from the skeleton instead:
##
##   - feet: the mean (toe - foot) vector over every bone whose name contains
##     "toe", each paired with its nearest ancestor whose name contains
##     "foot" -- toes point forward;
##   - head: the mean head bone position minus the mean pelvis bone position,
##     horizontally -- a four-legged body carries its head ahead of its hips.
##
## Both are read at the BIND pose, and again after posing the species' own
## walk clip (type 1 of its `default` group) at t=0, since that is the pose a
## walking monster is drawn in.
##
## THE CONTROL: CHAR_CH_MAN_FIGHTER, the player's body, whose front is its
## local -Z -- World3D._try_apply_real_player_character turns it by PI so its
## front meets the node's +Z (the "runs backwards on click" playtest fix).
## The probe counts only if the control reads -Z; it says so on its last line.
##
## A reading is an axis when its larger horizontal component is at least
## twice the smaller and at least 0.5 units long (the probe's own threshold);
## a weaker one names no axis and abstains -- an upright body's head sits over
## its pelvis, so the head reading cannot speak for a biped. A model is
## SETTLED when at least one reading names an axis and no two named axes
## disagree; otherwise it is UNSETTLED and stays unrotated in the client
## ("facing unmeasured").
##
## The facing is the MODEL's (its .bsr), not the code's: four roster rows
## (the `_CLON` species) carry `xxx` for a model; until round 655 the client
## drew them through the display-name join (World3D._monster_model_path,
## NpcTableReader.parse_models_by_name), which is how the probe resolves
## them. Since round 655 they take their Org row's model
## (NpcTableReader.model_with_org, docs/protocol/characterdata.md).
##
## Usage (render box only -- never run Godot on the developer's machine):
##   client/tools/remote_godot.sh sync
##   client/tools/remote_godot.sh script res://tools/probe_monster_front.gd -- \
##     --pk2=/opt/sro-files/client/Data.pk2 --media=/opt/sro-files/client/Media.pk2 [--all=1]
##
## --all=1 (round 673) measures every MOB_ row's model instead of the roster,
## and ends with a TALLY line: how many models read each front.

## The eleven roster species as [code, the name the server sends]
## (server/cmd/server/main.go monsterSpecs), then the control.
const ROSTER := [
	["MOB_CH_MANGNYANG", "Mangyang"], ["MOB_CH_BIGEYEGHOST_CLON", "Small-eyed Ghost"],
	["MOB_CH_BIGEYEGHOST", "Big-eyed Ghost"], ["MOB_CH_GYO_CLON", "Old Weasel"],
	["MOB_CH_GYO", "Weasel"], ["MOB_CH_WATERGHOST_CLON", "Water Ghost slave"],
	["MOB_CH_WATERGHOST", "Water Ghost"], ["MOB_CH_TOMBSTONE_CLON", "Tomb Stone Ghost"],
	["MOB_CH_STONEGHOST", "Stone Ghost"], ["MOB_CH_YEOHA", "Yeoha"],
	["MOB_WC_EARTHGHOST", "Earth Ghost"],
]
const CONTROL := "CHAR_CH_MAN_FIGHTER"
const MIN_LENGTH := 0.5
const DOMINANCE := 2.0

func _arg(flag: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return ""

func _init() -> void:
	var data := Pk2Reader.open(_arg("--pk2"))
	var media := Pk2Reader.open(_arg("--media"))
	if data == null or media == null:
		printerr("usage: --pk2=<Data.pk2> --media=<Media.pk2>")
		quit(2)
		return
	# Resolved exactly as World3D._monster_model_path resolves a body: by
	# code first, then by the lowercased display name.
	var models := {}
	var by_name := {}
	var names: UiTextTable = null
	var names_entry := ObjectLoader.find_file(media, NpcTableReader.OBJECT_NAME_TABLE_PATH)
	if names_entry != null:
		names = UiTextTable.parse(media.read_file(names_entry))
	for path in NpcTableReader.MODEL_TABLE_PATHS:
		var entry := ObjectLoader.find_file(media, path)
		if entry != null:
			var bytes := media.read_file(entry)
			models = NpcTableReader.parse_models_by_code(bytes, models, "")
			by_name = NpcTableReader.parse_models_by_name(bytes, names, by_name)
	var control_axis := ""
	var rows: Array = ROSTER.duplicate()
	# --all (round 673): every MOB_ row's own model once (the field monsters
	# round 660 put on the map, not only the round-533 roster), each distinct
	# .bsr measured once, under the first code that names it.
	if _arg("--all") != "":
		rows = []
		var seen := {}
		var codes: Array = models.keys()
		codes.sort()
		for code in codes:
			var path := String(models[code])
			if not String(code).begins_with("MOB_") or path == "" or seen.has(path.to_lower()):
				continue
			seen[path.to_lower()] = true
			rows.append([code, ""])
	rows.append([CONTROL, ""])
	var fronts := {}
	for row in rows:
		var code: String = row[0]
		var bsr: String = models.get(code, "")
		if bsr == "" and String(row[1]) != "":
			bsr = by_name.get(String(row[1]).to_lower(), "")
			if bsr != "":
				print("%-26s no model on its own row; drawn by name '%s' -> %s" % [code, row[1], bsr])
		if bsr == "":
			print("%-26s no model by code or by name -- drawn as the capsule, nothing to face" % code)
			continue
		var assembled := SkinnedBsrAssembler.assemble_from_archive(data, bsr, false)
		if assembled == null or assembled.skeleton == null:
			print("%-26s %s did not assemble" % [code, bsr])
			continue
		var skeleton := assembled.skeleton
		var readings: Array = []
		var bind := _measure(skeleton, true)
		readings.append_array(_report(code, "bind", bind))
		var walk := SkinnedBsrAssembler.animation_for(data, assembled, BsrReader.AnimationEntry.TYPE_WALK)
		if walk != null:
			Skeleton3DBuilder.apply_ban_pose_at(skeleton, walk, 0.0, true)
			readings.append_array(_report(code, "walk t=0", _measure(skeleton, false)))
		else:
			print("%-26s walk      no type-1 clip" % code)
		var verdict := _verdict(readings)
		print("%-26s FRONT %s  (%s)" % [code, verdict if verdict != "" else "UNSETTLED", bsr])
		if code == CONTROL:
			control_axis = verdict
		else:
			fronts[bsr] = verdict if verdict != "" else "UNSETTLED"
		# Each mesh is cleared before the skeleton is freed. Freed with its mesh
		# still set, every skinned MeshInstance3D made Godot's headless (dummy)
		# renderer print 'ERROR: Parameter "m" is null.' from
		# mesh_get_surface_count -- 25 lines over the roster, measured on the
		# render box (round 534); cleared first, none. Clearing the skin instead,
		# or freeing the children before the skeleton, left all 25. The readings
		# above are taken before this and do not change.
		for mi in skeleton.find_children("*", "MeshInstance3D", true, false):
			(mi as MeshInstance3D).mesh = null
		skeleton.free()
	var tally := {}
	for bsr in fronts:
		print("MODEL %s %s" % [bsr, fronts[bsr]])
		tally[fronts[bsr]] = int(tally.get(fronts[bsr], 0)) + 1
	print("TALLY %s over %d model(s)" % [str(tally), fronts.size()])
	print("CONTROL %s reads %s -- the probe %s" % [CONTROL, control_axis if control_axis != "" else "nothing",
		"COUNTS" if control_axis == "-Z" else "DOES NOT COUNT"])
	quit(0)

## {"feet": Vector2 or null, "head": Vector2 or null, "toes": n, "heads": n,
## "pelvises": n}, horizontal (x, z) in skeleton space.
func _measure(skeleton: Skeleton3D, rest: bool) -> Dictionary:
	var pos := func(i: int) -> Vector3:
		return skeleton.get_bone_global_rest(i).origin if rest else skeleton.get_bone_global_pose(i).origin
	var toe_sum := Vector3.ZERO
	var toes := 0
	var heads: Array = []
	var pelvises: Array = []
	for i in range(skeleton.get_bone_count()):
		var bone := skeleton.get_bone_name(i).to_lower()
		if bone.contains("toe"):
			var foot := skeleton.get_bone_parent(i)
			while foot != -1 and not skeleton.get_bone_name(foot).to_lower().contains("foot"):
				foot = skeleton.get_bone_parent(foot)
			if foot != -1:
				toe_sum += pos.call(i) - pos.call(foot)
				toes += 1
		if bone.contains("head"):
			heads.append(pos.call(i))
		if bone.contains("pelvis"):
			pelvises.append(pos.call(i))
	var out := {"toes": toes, "heads": heads.size(), "pelvises": pelvises.size(), "feet": null, "head": null}
	if toes > 0:
		out["feet"] = Vector2(toe_sum.x, toe_sum.z) / float(toes)
	if not heads.is_empty() and not pelvises.is_empty():
		var h := Vector3.ZERO
		for p in heads:
			h += p
		var pv := Vector3.ZERO
		for p in pelvises:
			pv += p
		var d: Vector3 = h / float(heads.size()) - pv / float(pelvises.size())
		out["head"] = Vector2(d.x, d.z)
	return out

## Prints both readings of one pose and returns the axes they name.
func _report(code: String, pose: String, m: Dictionary) -> Array:
	var axes: Array = []
	for key in ["feet", "head"]:
		var v = m[key]
		if v == null:
			print("%-26s %-9s %-4s none (toes %d, heads %d, pelvises %d)" % [code, pose, key, m["toes"], m["heads"], m["pelvises"]])
			continue
		var axis := _axis(v)
		print("%-26s %-9s %-4s (%.2f, %.2f) -> %s" % [code, pose, key, v.x, v.y, axis if axis != "" else "no axis"])
		axes.append(axis)
	return axes

## "+X", "-X", "+Z" or "-Z" for a clearly dominant horizontal vector, else "".
func _axis(v: Vector2) -> String:
	var ax := absf(v.x)
	var az := absf(v.y)
	if maxf(ax, az) < MIN_LENGTH:
		return ""
	if az >= DOMINANCE * ax:
		return "+Z" if v.y > 0.0 else "-Z"
	if ax >= DOMINANCE * az:
		return "+X" if v.x > 0.0 else "-X"
	return ""

## The one axis the readings name, or "" when two disagree or none named one.
## A reading that names no axis abstains.
func _verdict(axes: Array) -> String:
	var found := ""
	for a in axes:
		if a == "":
			continue
		if found == "":
			found = a
		elif a != found:
			return ""
	return found
