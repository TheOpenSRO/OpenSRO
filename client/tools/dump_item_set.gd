extends SceneTree

## Dev tool: dumps real wearable item rows from the player's own Media.pk2 item
## table, so a QA equipment loadout (OPENSRO_QA_EQUIP) is built from real item
## ids the server could actually send -- never invented ones.
##
## Prints, for every item that has a worn model, its id, code name, display
## name, the equipment TypeIDs, the required gender/level, and the .bsr model
## path. Filter with --grep=<substr> (matched against the code name, case-
## insensitive) to narrow to one family, e.g. a China man armour set and swords.
##
## Usage (headless is fine -- it reads tables, renders nothing):
##   godot4 --headless --path client --script res://tools/dump_item_set.gd -- \
##     --media=/opt/sro-files/client/Media.pk2 --grep=_ca_m_
##
## TypeIDs printed are [TID1,TID2,TID3,TID4]; World3D keys the weapon animation
## group off TID4 (index 3) and the worn slot follows the armour family.

func _arg(flag: String, fallback: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return fallback

func _initialize() -> void:
	var media_path := _arg("--media")
	var needle := _arg("--grep").to_lower()
	var only_gender := _arg("--gender")  # "man", "woman", or empty for any
	if media_path == "":
		printerr("usage: --media=<Media.pk2> [--grep=<code-substr>] [--gender=man|woman]")
		quit(2)
		return

	var media := Pk2Reader.open(media_path)
	if media == null:
		printerr("could not open ", media_path)
		quit(1)
		return

	var rows := 0
	var shown := 0
	for path in ItemTableReader.table_paths(media):
		var entry := ObjectLoader.find_file(media, path)
		if entry == null:
			continue
		var parsed := ItemTableReader.parse(media.read_file(entry))
		for item in parsed.values():
			rows += 1
			if item.model_path == "":
				continue
			var code_l: String = String(item.code_name).to_lower()
			if needle != "" and not code_l.contains(needle):
				continue
			if only_gender == "man" and item.req_gender == 2:
				continue  # 2 = woman-only
			if only_gender == "woman" and item.req_gender == 1:
				continue  # 1 = man-only
			var tids: PackedInt32Array = item.type_ids
			var lvl := ""
			if item.req_levels.size() > 0 and item.req_levels[0] > 0:
				lvl = "lvl>=%d" % item.req_levels[0]
			print("%6d  %-34s  tids=%s  g%d %-8s  %s" % [
				item.id, item.code_name, str(tids), item.req_gender, lvl, item.model_path])
			shown += 1
	print("-- %d item rows, %d shown --" % [rows, shown])
	quit(0)
