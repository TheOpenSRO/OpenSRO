extends SceneTree

## Round 758: every weapon and shield item's worn models against the archive.
## For each item the item table names (ItemTableReader.load_all) with a
## weapon or shield visual slot (CharacterAppearance.visual_slot) and a model,
## on a Europe man and a Europe woman (the sex picks a harp's `_f`):
##
## - DRAW: the models build() hangs (CharacterAppearance.item_models, each
##   `_r` / `_f` that is not in Data.pk2 replaced by its plain fallback, as
##   build() does): a miss is a model with neither in the archive. Split by
##   whether ANY of the item's own files (plain, `_l`, `_r`, `_f`) exists --
##   the round's target is 0 misses for items whose files exist.
## - ASK: the item's paths the look-ahead asks the archive for
##   (template_paths, the character template task's list): one not in the
##   archive is a `SkinnedBsrAssembler: item ... not found in archive` error
##   in the log.
##
## Counts per TypeID3/TypeID4, then the totals as `CENSUS` lines. Headless:
##   remote_godot.sh script res://tools/census_weapon_models.gd -- --pk2dir=/opt/sro-files/client

func _initialize() -> void:
	var dir := "/opt/sro-files/client"
	var verbose := false
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--pk2dir="):
			dir = a.substr(9)
		elif a == "--verbose":
			verbose = true
	var data := Pk2Reader.open(dir.path_join("Data.pk2"))
	var media := Pk2Reader.open(dir.path_join("Media.pk2"))
	if data == null or media == null:
		printerr("census_weapon_models: no Data.pk2 / Media.pk2 under %s" % dir)
		quit(2)
		return
	var rows := ItemTableReader.load_all(media)
	var app := CharacterAppearance.from_archives(data, media, rows)
	var cat := app.catalog()
	var bodies := {}
	for sex in [CharCatalog.SEX_MAN, CharCatalog.SEX_WOMAN]:
		var figs := cat.figures(CharCatalog.RACE_EUROPE, sex)
		if not figs.is_empty():
			bodies[sex] = figs[0].id
	if bodies.size() != 2:
		printerr("census_weapon_models: no Europe man and woman in the catalogue")
		quit(2)
		return
	var exists := {}
	var has_file := func(p: String) -> bool:
		var k := p.to_lower()
		if not exists.has(k):
			exists[k] = ObjectLoader.find_file(data, p) != null or ObjectLoader.find_file(data, "res\\" + p) != null
		return exists[k]
	var by_kind := {} # "t3/t4" -> [items, draw misses (files exist), draw misses (no file), asks for a missing file]
	var draw_exist := 0
	var draw_none := 0
	var ask_missing := 0
	var ask_paths := {}
	var items := 0
	var ids := rows.keys()
	ids.sort()
	for id in ids:
		var item: ItemTableReader.Item = rows[id]
		var slot := CharacterAppearance.visual_slot(item.type_ids)
		if slot != CharacterAppearance.SLOT_WEAPON and slot != CharacterAppearance.SLOT_SHIELD:
			continue
		if item.model_path == "":
			continue
		var kind := "%d/%d" % [item.type_ids[2], item.type_ids[3]]
		if not by_kind.has(kind):
			by_kind[kind] = [0, 0, 0, 0]
		var base := item.model_path.substr(0, item.model_path.length() - 4)
		var own_any := false
		for v in [item.model_path, base + "_l.bsr", base + "_r.bsr", base + "_f.bsr"]:
			if has_file.call(v):
				own_any = true
		for sex in bodies:
			var woman: bool = sex == CharCatalog.SEX_WOMAN
			items += 1
			by_kind[kind][0] += 1
			var missed := PackedStringArray()
			for m in CharacterAppearance.item_models(item.model_path, item.type_ids, woman):
				var fb := CharacterAppearance._fallback_of(m)
				if not has_file.call(m) and not (fb != "" and has_file.call(fb)):
					missed.append(m)
			if not missed.is_empty():
				if own_any:
					draw_exist += 1
					by_kind[kind][1] += 1
				else:
					draw_none += 1
					by_kind[kind][2] += 1
				if verbose:
					print("DRAW MISS %d %s %s (%s): %s%s" % [id, item.code_name, kind, "woman" if woman else "man",
						", ".join(missed), "" if own_any else " -- no file of the item's at all"])
			var tp: Array = app.template_paths(int(bodies[sex]), [{"id": id, "plus": 0}])
			for p in tp[0]:
				var low := String(p).to_lower()
				if not low.begins_with(base.to_lower()):
					continue # the body's default wear, not this item's
				if not has_file.call(p):
					ask_missing += 1
					by_kind[kind][3] += 1
					ask_paths[low] = true
	var kinds := by_kind.keys()
	kinds.sort()
	for k in kinds:
		var c: Array = by_kind[k]
		print("CENSUS kind %s: %d item-sex(es), draw misses %d with files / %d without, look-ahead asks for a missing file %d" % [k, c[0], c[1], c[2], c[3]])
	if verbose:
		var ap := ask_paths.keys()
		ap.sort()
		for p in ap:
			print("ASK MISSING %s" % p)
	print("CENSUS total: %d item-sex(es); draw misses %d for items whose files exist, %d for items with no file; look-ahead asks for a missing file %d (%d distinct path(s))" % [
		items, draw_exist, draw_none, ask_missing, ask_paths.size()])
	# --build=<id>,..: each item built alone on the Europe man the world's
	# way (prepare -> the template task -> build), what it hung.
	for a in OS.get_cmdline_user_args():
		if not a.begins_with("--build="):
			continue
		for s in a.substr(8).split(",", false):
			var kit := [{"id": int(s), "plus": 0}]
			app.prepare(int(bodies[CharCatalog.SEX_MAN]), kit)
			app.wait_prepared()
			var b := app.build(int(bodies[CharCatalog.SEX_MAN]), 0x22, kit)
			if b == null:
				print("BUILD %s: no body" % s)
				continue
			for w in b.worn:
				var meshes := 0
				for n in w.get("nodes", []):
					meshes += (n as Node).find_children("*", "MeshInstance3D", true, false).size()
				print("BUILD %s %s: models %s, drawn %s, %d mesh(es), group %s" % [s, String(w.get("code", "(default wear)")), str(w.get("models", [])), str(w.get("drawn", [])), meshes, b.weapon_group])
			b.free()
	app.free_templates()
	quit(0)
