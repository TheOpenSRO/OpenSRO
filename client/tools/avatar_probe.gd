extends SceneTree

## Dev tool (round 789, lane AC): avatars against the real archives. It
## measures, and optionally renders:
##
## - the census the research made (AVATAR_RESEARCH.md 6.1/9): how many avatar
##   rows (TypeID 3/1/13) find a charactervisualchange ConditionID-2 row by
##   their TypeID word and Param7 (READ c:0x4ec260; the research MEASURED
##   1,346 of 1,354), by TypeID4, and that no devil's spirit (3/1/14) has a
##   ConditionID-1 row (it draws nothing);
## - which hats' own .bsr attachable block already hides the body's hair
##   (piece key 0, flag 1) -- the question behind the INFERRED hair rule
##   (CharacterAppearance.hide_hair_by_mask);
## - builds of one body per race and sex with a full armour set and a hat, a
##   dress, an attachment and a flag through CharacterAppearance, with the
##   arbitration on and off, printing what each draws (`AVATAR BUILD` lines):
##   the worn ids, the body meshes hidden, the default wear.
##
## Renders (with --out, a GL context): each body with the arbitration off
## (left) and on (right), front and back.
##
##   xvfb-run -a -s "-screen 0 1600x1200x24" vglrun -d egl0 godot --path client \
##     --rendering-driver opengl3 --resolution 1600x1200 --script res://tools/avatar_probe.gd -- \
##     --pk2=/opt/sro-files/client/Data.pk2 --media=/opt/sro-files/client/Media.pk2 [--out=/var/tmp/ac789/shots] \
##     [--hats=40] [--hat=<id> --dress=<id> --attach=<id> --flag=<id>] [--race=china|europe|both]
## Headless without --out (remote_godot.sh script). A failed check prints
## `PARITY FAIL`.

var _fails := 0

func _arg(flag: String, fallback: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return fallback

func _expect(cond: bool, msg: String) -> void:
	if cond:
		print("ok   " + msg)
	else:
		print("PARITY FAIL " + msg)
		_fails += 1

func _initialize() -> void:
	var data := Pk2Reader.open(_arg("--pk2"))
	var media := Pk2Reader.open(_arg("--media"))
	if data == null or media == null:
		printerr("usage: --pk2=<Data.pk2> --media=<Media.pk2> [--out=<dir>]")
		quit(2)
		return
	var rows := ItemTableReader.load_all(media)
	var app := CharacterAppearance.from_archives(data, media, rows)
	var vc := app.visual_change
	_expect(vc != null and not vc.is_empty(), "charactervisualchange.txt read (%d rows)" % (vc.rows.size() if vc != null else 0))
	_census(rows, vc)
	var picks := {}
	for who in _bodies():
		picks[who[2]] = _pick(app, rows, vc, who)
	await _hair_census(app, rows, vc, int(_arg("--hats", "40")))
	var out := _arg("--out")
	var world: Node3D = null
	var cam: Camera3D = null
	if out != "":
		DirAccess.make_dir_recursive_absolute(out)
		world = Node3D.new()
		get_root().add_child(world)
		_lights(world)
		cam = Camera3D.new()
		cam.projection = Camera3D.PROJECTION_ORTHOGONAL
		cam.current = true
		world.add_child(cam)
	for who in _bodies():
		var p: Dictionary = picks[who[2]]
		if p.is_empty():
			continue
		await _builds(app, who, p, world, cam, out)
	if world != null:
		world.free()
	app.free_templates()
	print("RESULT: %s (%d failing)" % ["PASS" if _fails == 0 else "FAIL", _fails])
	quit(0)

func _bodies() -> Array:
	var all := [[CharCatalog.RACE_CHINA, CharCatalog.SEX_MAN, "china_man"], [CharCatalog.RACE_EUROPE, CharCatalog.SEX_WOMAN, "europe_woman"]]
	match _arg("--race", "both"):
		"china":
			return [all[0]]
		"europe":
			return [all[1]]
	return all

# --- census ----------------------------------------------------------------------

func _census(rows: Dictionary, vc: CharacterVisualChange) -> void:
	var by_kind := {}
	var hit_kind := {}
	var spirits := 0
	var spirit_rows := 0
	for id in rows:
		var it: ItemTableReader.Item = rows[id]
		if it.is_avatar():
			var k := it.type_ids[3]
			by_kind[k] = int(by_kind.get(k, 0)) + 1
			if vc.row_for(it.type_word(), it.param7) != null:
				hit_kind[k] = int(hit_kind.get(k, 0)) + 1
		elif it.is_devil_spirit():
			spirits += 1
			if vc.row_for(it.type_word(), it.param7) != null:
				spirit_rows += 1
	var total := 0
	var hits := 0
	var parts := PackedStringArray()
	for k in [1, 2, 3, 4]:
		total += int(by_kind.get(k, 0))
		hits += int(hit_kind.get(k, 0))
		parts.append("13/%d %d of %d" % [k, int(hit_kind.get(k, 0)), int(by_kind.get(k, 0))])
	print("AVATAR CENSUS %d of %d avatar ids find a ConditionID-2 row (%s); %d devil's spirit(s), %d with a ConditionID-1 row" % [
		hits, total, ", ".join(parts), spirits, spirit_rows])
	_expect(total > 0 and hits * 100 >= total * 95, "most avatars find their row by word and Param7 (%d of %d)" % [hits, total])
	_expect(spirit_rows == 0, "no devil's spirit has a ConditionID-1 row (it draws nothing)")

## A full armour set's ids from a chest piece's code name (its HA/SA/BA/LA/AA/FA
## siblings), then the avatars: the ones named on the command line, else the
## first id of each kind that fits the body (gender, race) and has a row.
func _pick(app: CharacterAppearance, rows: Dictionary, vc: CharacterVisualChange, who: Array) -> Dictionary:
	var cat := app.catalog()
	var figs := cat.figures(who[0], who[1])
	if figs.is_empty():
		return {}
	var body: CharCatalog.Entry = figs[0]
	var by_code := {}
	for id in rows:
		by_code[(rows[id] as ItemTableReader.Item).code_name] = int(id)
	var armour: Array = []
	var sets := cat.all_armour_sets(who[0], who[1])
	var chest_code := ""
	for s in sets:
		if s.chest != null and s.name == "heavy":
			chest_code = (rows[s.chest.id] as ItemTableReader.Item).code_name if rows.has(s.chest.id) else ""
	if chest_code == "" and not sets.is_empty() and sets[sets.size() - 1].chest != null:
		chest_code = (rows[sets[sets.size() - 1].chest.id] as ItemTableReader.Item).code_name
	# The starter kit's pieces carry a suffix (..._BA_A_DEF) its helm and
	# shoulders lack: the set's own pieces are ..._HA_A and so on.
	var at := chest_code.find("_BA_")
	var base := chest_code.substr(0, at + 5) if at >= 0 and chest_code.length() >= at + 5 else chest_code
	for part in ["_HA_", "_SA_", "_BA_", "_LA_", "_AA_", "_FA_"]:
		var code := base.replace("_BA_", part)
		if by_code.has(code):
			armour.append(int(by_code[code]))
		elif by_code.has(chest_code.replace("_BA_", part)):
			armour.append(int(by_code[chest_code.replace("_BA_", part)]))
	var weapons := cat.weapons(who[0], who[1])
	if not weapons.is_empty():
		armour.append(weapons[0].id)
	var gender := 0 if who[1] == CharCatalog.SEX_WOMAN else 1
	var avatars := {}
	var ids := rows.keys()
	ids.sort()
	for k in [1, 2, 3, 4]:
		var named := int(_arg(["", "--hat", "--dress", "--attach", "--flag"][k], "0"))
		if named > 0:
			avatars[k] = named
			continue
		for id in ids:
			var it: ItemTableReader.Item = rows[id]
			if not it.is_avatar() or it.type_ids[3] != k or it.req_gender != gender or it.model_path == "":
				continue
			if it.country != 3 and it.country != who[0]:
				continue
			# A dress that takes an attachment, for the attachment to show.
			if k == 2 and it.child_item_count == 0:
				continue
			if vc.row_for(it.type_word(), it.param7) == null:
				continue
			avatars[k] = int(id)
			break
	var names := PackedStringArray()
	for k in avatars:
		var it: ItemTableReader.Item = rows.get(avatars[k])
		names.append("13/%d %d %s Param7 0x%x" % [k, avatars[k], it.code_name if it != null else "?", it.param7 if it != null else 0])
	print("AVATAR PICK %s body %d (%s): armour %s; avatars %s" % [who[2], body.id, body.code, str(armour), "; ".join(names)])
	return {"body": body.id, "armour": armour, "avatars": avatars}

func _hair_census(app: CharacterAppearance, rows: Dictionary, vc: CharacterVisualChange, limit: int) -> void:
	var cat := app.catalog()
	var figs := cat.figures(CharCatalog.RACE_CHINA, CharCatalog.SEX_MAN)
	if figs.is_empty() or limit <= 0:
		return
	var body := figs[0].id
	var ids := rows.keys()
	ids.sort()
	var seen := 0
	var hides := 0
	var no_block := 0
	for id in ids:
		var it: ItemTableReader.Item = rows[id]
		if not it.is_avatar() or it.type_ids[3] != 1 or it.req_gender != 1 or it.model_path == "" \
				or vc.row_for(it.type_word(), it.param7) == null:
			continue
		app.hide_hair_by_mask = false
		var b := app.build(body, 0x22, [{"id": int(id), "plus": 0}])
		app.hide_hair_by_mask = true
		if b == null:
			continue
		var own := false
		var any := false
		for w in b.worn:
			if int(w["slot"]) != CharacterAppearance.SLOT_AVATAR:
				continue
			for blk in w.get("attachables", []):
				if blk == null:
					continue
				any = true
				var a := blk as BsrReader.Attachable
				if a.hides_body() and a.keys().has(CharacterAppearance.HAIR_PIECE_KEY):
					own = true
		b.free()
		seen += 1
		if own:
			hides += 1
		if not any:
			no_block += 1
		if seen >= limit:
			break
	print("AVATAR HAIR %d of %d men's hats with a row hide the hair by their own attachable block (key 0, flag 1); %d have no block" % [
		hides, seen, no_block])

# --- builds and pictures -----------------------------------------------------------

## What a build draws: "AVATAR BUILD" with the worn ids, the hidden body meshes,
## the default wear and whether the hair piece is hidden.
func _describe(label: String, b: CharacterAppearance.Body) -> Dictionary:
	var ids := []
	var defaults := 0
	for w in b.worn:
		if w.get("default", false):
			defaults += 1
		elif not (w["nodes"] as Array).is_empty():
			ids.append(int(w["id"]))
	ids.sort()
	var hair_hidden := false
	var parsed: BsrReader.ParsedObject = b.assembled.parsed if b.assembled != null else null
	if parsed != null and parsed.attachable != null:
		var hair_idx := parsed.attachable.values_for(CharacterAppearance.HAIR_PIECE_KEY)
		for n in b.skeleton.get_children():
			if n.has_meta(SkinnedBsrAssembler.BODY_MESH_META) and hair_idx.has(int(n.get_meta(SkinnedBsrAssembler.BODY_MESH_META))):
				hair_hidden = hair_hidden or not (n as Node3D).visible
	print("AVATAR BUILD %s: draws %s, %d body mesh(es) hidden, %d default wear(s), hair hidden %s" % [
		label, str(ids), b.hidden_body_meshes, defaults, str(hair_hidden)])
	return {"ids": ids, "defaults": defaults, "hair": hair_hidden}

func _builds(app: CharacterAppearance, who: Array, p: Dictionary, world: Node3D, cam: Camera3D, out: String) -> void:
	var name: String = who[2]
	var items: Array = []
	for id in p["armour"]:
		items.append({"id": int(id), "plus": 0})
	var avatars: Dictionary = p["avatars"]
	var hat := int(avatars.get(1, 0))
	var dress := int(avatars.get(2, 0))
	var attach := int(avatars.get(3, 0))
	var flag := int(avatars.get(4, 0))
	var dressed := items.duplicate()
	for id in [hat, dress, attach]:
		if id > 0:
			dressed.append({"id": id, "plus": 0})
	var vc := app.visual_change
	var armour_only := app.build(int(p["body"]), 0x22, items)
	var a := _describe("%s armour" % name, armour_only)
	var after := app.build(int(p["body"]), 0x22, dressed)
	var b := _describe("%s armour+hat+dress+attachment (arbitration on)" % name, after)
	app.visual_change = null
	var before := app.build(int(p["body"]), 0x22, dressed)
	var c := _describe("%s armour+hat+dress+attachment (arbitration off)" % name, before)
	app.visual_change = vc
	var with_flag := dressed.duplicate()
	if flag > 0:
		with_flag.append({"id": flag, "plus": 0})
	var flagged := app.build(int(p["body"]), 0x22, with_flag)
	var d := _describe("%s ... + flag (arbitration on)" % name, flagged)
	# The checks the arbitration's rows imply for this loadout.
	var weapon := int(p["armour"][p["armour"].size() - 1]) if not (p["armour"] as Array).is_empty() else 0
	if hat > 0 and dress > 0:
		_expect((b["ids"] as Array).has(hat) and (b["ids"] as Array).has(dress), "%s: the hat and the dress are drawn" % name)
		_expect((b["ids"] as Array).size() < (c["ids"] as Array).size(), "%s: the arbitration hides armour under them (%d drawn against %d)" % [
			name, (b["ids"] as Array).size(), (c["ids"] as Array).size()])
		_expect(weapon == 0 or (b["ids"] as Array).has(weapon), "%s: the weapon stays" % name)
		_expect(int(b["defaults"]) == 0, "%s: no default wear under the dress" % name)
	if attach > 0 and flag > 0:
		_expect((d["ids"] as Array).has(attach) and not (d["ids"] as Array).has(flag), "%s: the flag is hidden while the attachment is worn" % name)
	if world != null:
		for pair in [[before, -8.0], [after, 8.0]]:
			var body: CharacterAppearance.Body = pair[0]
			var idle := app.animation_for(body, BsrReader.AnimationEntry.TYPE_STAND)
			body.pose(idle, 0.0)
			body.position = Vector3(float(pair[1]), 0, 0)
			world.add_child(body)
		for view in [["front", PI], ["back", 0.0]]:
			before.rotation.y = view[1]
			after.rotation.y = view[1]
			cam.size = 26.0
			cam.look_at_from_position(Vector3(0, 10.0, 200), Vector3(0, 10.0, 0), Vector3.UP)
			cam.far = 1000.0
			for _i in range(4):
				await process_frame
			var path := out.path_join("%s_avatars_%s_off_left_on_right.png" % [name, view[0]])
			get_root().get_texture().get_image().save_png(path)
			print("saved " + path)
	for n in [armour_only, after, before, flagged]:
		if n.get_parent() != null:
			n.get_parent().remove_child(n)
		n.free()

func _lights(world: Node3D) -> void:
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-35, 25, 0)
	world.add_child(key)
	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.16, 0.17, 0.21)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.62, 0.62, 0.66)
	env_node.environment = env
	world.add_child(env_node)
