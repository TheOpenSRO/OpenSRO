extends SceneTree
## Dev tool (round 828): which body bone every weapon and shield hangs from,
## as CharacterAppearance builds it from the archives, one body per item. For
## each model of the item it prints the BoneAttachment3D's bone, and for the
## body which side its right hand is on, raw and with the world's mirror
## (BodyMirror) -- a measurement, not a render.
##
##   godot4 --headless --path client --script res://tools/probe_weapon_hands.gd -- \
##     --pk2-dir=/opt/sro-files/client [--body=CHAR_EU_MAN_NOBLE] \
##     [--items=ITEM_EU_TSWORD_01_A_DEF,...]

func _arg(flag: String, fallback: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return fallback

const DEFAULT_ITEMS := "ITEM_CH_SWORD_01_A,ITEM_CH_BLADE_01_A,ITEM_CH_SPEAR_01_A,ITEM_CH_TBLADE_01_A,ITEM_CH_BOW_01_A,ITEM_CH_SHIELD_01_A," \
	+ "ITEM_EU_SWORD_01_A_DEF,ITEM_EU_TSWORD_01_A_DEF,ITEM_EU_AXE_01_A_DEF,ITEM_EU_DARKSTAFF_01_A_DEF,ITEM_EU_TSTAFF_01_A_DEF," \
	+ "ITEM_EU_CROSSBOW_01_A_DEF,ITEM_EU_DAGGER_01_A_DEF,ITEM_EU_HARP_01_A_DEF,ITEM_EU_STAFF_01_A_DEF,ITEM_EU_SHIELD_01_A_DEF"

func _initialize() -> void:
	var dir := _arg("--pk2-dir", "/opt/sro-files/client")
	var data := Pk2Reader.open(dir.path_join("Data.pk2"))
	var media := Pk2Reader.open(dir.path_join("Media.pk2"))
	if data == null or media == null:
		print("PROBE no archives under %s" % dir)
		quit(1)
		return
	var a := CharacterAppearance.from_archives(data, media)
	var by_code := {}
	for id in a._catalog.entries:
		var e: CharCatalog.Entry = a._catalog.entries[id]
		by_code[e.code.to_upper()] = id
	var bodies := _arg("--body", "CHAR_CH_MAN_ADVENTURER,CHAR_EU_MAN_NOBLE").split(",")
	for code in _arg("--items", DEFAULT_ITEMS).split(","):
		var item_id := int(by_code.get(code.to_upper(), 0))
		if item_id == 0:
			print("PROBE %s: not in the catalogue" % code)
			continue
		var body_code: String = bodies[1] if code.contains("_EU_") and bodies.size() > 1 else bodies[0]
		var body_id := int(by_code.get(body_code.to_upper(), 0))
		var body := a.build(body_id, CharacterAppearance.DEFAULT_SCALE, [{"id": item_id, "plus": 0}])
		if body == null:
			print("PROBE %s: body %s did not build" % [code, body_code])
			continue
		root.add_child(body)
		var sk := body.skeleton
		# Raw (as the world drew bodies before round 828), then mirrored as the
		# world puts them in now (BodyMirror on the body's own x).
		for mirrored in [false, true]:
			if mirrored:
				BodyMirror.apply(body)
			sk.force_update_all_bone_transforms()
			# Composed here: a tool's _initialize runs before the tree does.
			var frame := body.transform * sk.transform
			var rp := (frame * sk.get_bone_global_pose(sk.find_bone("Bip01 R Hand"))).origin
			var lp := (frame * sk.get_bone_global_pose(sk.find_bone("Bip01 L Hand"))).origin
			# Handedness: forward from the right foot to its toe, up the world's;
			# right = forward x up. The right hand should lie on that side.
			var foot := (frame * sk.get_bone_global_pose(sk.find_bone("Bip01 R Foot"))).origin
			var toe := (frame * sk.get_bone_global_pose(sk.find_bone("Bip01 R Toe0"))).origin
			var fwd := Vector3(toe.x - foot.x, 0, toe.z - foot.z).normalized()
			var right := fwd.cross(Vector3.UP)
			print("PROBE body %s %s: forward %s, (R hand - L hand) . right = %.2f (%s)" % [body_code,
				"mirrored" if mirrored else "raw", fwd, (rp - lp).dot(right), "right hand on the right" if (rp - lp).dot(right) > 0.0 else "right hand on the LEFT"])
		for w in body.worn:
			var slot := int(w["slot"])
			if slot != CharacterAppearance.SLOT_WEAPON and slot != CharacterAppearance.SLOT_SHIELD:
				continue
			var models: Array = w["models"]
			var nodes: Array = w["nodes"]
			for i in nodes.size():
				var n := nodes[i] as Node3D
				var att: Node = n
				while att != null and not (att is BoneAttachment3D):
					att = att.get_parent()
				var bone := (att as BoneAttachment3D).bone_name if att != null else "(none)"
				print("PROBE %-28s %-6s %-44s on %s" % [
					code, "shield" if slot == CharacterAppearance.SLOT_SHIELD else "weapon",
					String(models[i]) if i < models.size() else "?", bone])
		body.queue_free()
	quit(0)
