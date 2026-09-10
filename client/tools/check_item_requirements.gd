extends SceneTree

## Dev tool: characterises the item table's equipment rows -- what wears
## where, who may wear it, and whether every worn model is really in the
## archive.
##
## The claims this checks, each of which the reader and the server's equip
## rules depend on:
##
##   * column 52 names the model an item is worn as, and the file exists
##     under `res\` in Data.pk2 -- for every equipment row, not five
##   * the two-letter slot in the code name (`..._01_BA_...`) and TypeID4
##     agree on which slot the item goes in
##   * the race letters in the code name (`ITEM_CH_`/`ITEM_EU_`) agree with
##     Country, and `_M_`/`_W_` with ReqGender
##   * what the requirement type column asks for: type 1 is the
##     character's own level; the others are counted here rather than
##     assumed away
##
## Usage:
##   godot4 --headless --path client --script res://tools/check_item_requirements.gd -- \
##     --media=/path/to/Media.pk2 [--data=/path/to/Data.pk2]

func _arg(flag: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return ""

func _count(d: Dictionary, key) -> void:
	d[key] = int(d.get(key, 0)) + 1

func _print_counts(title: String, d: Dictionary, limit := 40) -> void:
	print(title)
	var keys := d.keys()
	keys.sort_custom(func(a, b): return d[a] > d[b])
	for i in range(mini(limit, keys.size())):
		print("     %-40s %d" % [str(keys[i]), d[keys[i]]])

func _init() -> void:
	var media_path := _arg("--media")
	if media_path == "":
		printerr("usage: --media=<Media.pk2> [--data=<Data.pk2>]")
		quit(2)
		return
	var media := Pk2Reader.open(media_path)
	if media == null:
		printerr("could not open ", media_path)
		quit(1)
		return
	var data: Pk2Reader = null
	if _arg("--data") != "":
		data = Pk2Reader.open(_arg("--data"))

	var items := {}
	for path in ItemTableReader.TABLE_PATHS:
		var entry := ObjectLoader.find_file(media, path)
		if entry != null:
			items = ItemTableReader.parse(media.read_file(entry), items)
	print("%d item row(s) across the parts" % items.size())

	var equipment := 0
	var by_type := {}
	var slot_vs_type4 := {}
	var race_vs_country := {}
	var gender_vs_req := {}
	var req_types := {}
	var req_by_type := {}
	var models_present := 0
	var models_missing := 0
	var missing_examples: Array[String] = []
	var model_dirs := {}
	for value in items.values():
		var item: ItemTableReader.Item = value
		if not item.is_equipment():
			continue
		equipment += 1
		var t1: int = item.type_ids[0] if item.type_ids.size() > 0 else -1
		var t2: int = item.type_ids[1] if item.type_ids.size() > 1 else -1
		var t3: int = item.type_ids[2] if item.type_ids.size() > 2 else -1
		var t4: int = item.type_ids[3] if item.type_ids.size() > 3 else -1
		_count(by_type, "%d/%d/%d" % [t1, t2, t3])
		_count(model_dirs, item.model_path.get_base_dir())

		# ITEM_CH_M_CLOTHES_01_BA_A_RARE -> race CH, gender M, slot BA.
		var parts: PackedStringArray = item.code_name.split("_")
		if parts.size() >= 6 and parts[0] == "ITEM":
			_count(race_vs_country, "%s -> country %d" % [parts[1], item.country])
			_count(gender_vs_req, "%s -> req_gender %d" % [parts[2], item.req_gender])
			# The slot code is the two-letter word after the degree number.
			for i in range(3, parts.size() - 1):
				if parts[i].is_valid_int() and parts[i + 1].length() == 2:
					_count(slot_vs_type4, "%s -> type4 %d (type2/3 %d/%d)" % [parts[i + 1], t4, t2, t3])
					break

		for i in range(item.req_level_types.size()):
			var rt: int = item.req_level_types[i]
			if rt <= 0:
				continue
			_count(req_types, "pair %d type %d" % [i, rt])
			_count(req_by_type, "type %d -> levels %s" % [rt, "1-10" if item.req_levels[i] <= 10 else ("11-50" if item.req_levels[i] <= 50 else "51+")])

		if data != null:
			var present := ObjectLoader.find_file(data, item.model_path) != null \
				or ObjectLoader.find_file(data, "res\\" + item.model_path) != null
			if present:
				models_present += 1
			else:
				models_missing += 1
				if missing_examples.size() < 6:
					missing_examples.append("%d %s %s" % [item.id, item.code_name, item.model_path])

	print("%d equipment row(s) (a worn model named)" % equipment)
	_print_counts("--- by TypeID1/2/3:", by_type, 30)
	_print_counts("--- model directories:", model_dirs, 30)
	_print_counts("--- code-name slot letters against TypeID4:", slot_vs_type4, 60)
	_print_counts("--- code-name race against Country:", race_vs_country)
	_print_counts("--- code-name gender against ReqGender:", gender_vs_req)
	_print_counts("--- requirement pairs in use:", req_types)
	_print_counts("--- requirement type against the level it asks for:", req_by_type)
	if data != null:
		print("--- worn models in Data.pk2: %d present, %d missing" % [models_present, models_missing])
		for line in missing_examples:
			print("     missing: " + line)
	quit(0)
