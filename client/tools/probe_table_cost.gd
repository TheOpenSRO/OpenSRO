extends SceneTree

## Where a text table's GDScript time goes, phase by phase, and what the
## native port (round 671; native/src/core/tables.rs) costs for the same call
## -- on the REAL tables the world reads at boot and entry. Headless, on the
## render box; prints a table, commits nothing:
##
##   client/tools/remote_godot.sh script res://tools/probe_table_cost.gd -- --pk2-dir=/opt/sro-files/client
##
## For each table, summed over its parts (characterdata and itemdata have
## seven): `decode` (strip FF FE + get_string_from_utf16), `lines`
## (replace("\r", "") + split("\n")), `tabs` (split("\t") on every line) --
## the three steps every reader repeats -- and then each reader called the
## way World3D calls it, once forced to GDScript and once native. Each figure
## is the median of REPS runs, in ms.

const REPS := 3
const T := "server_dep\\silkroad\\textdata\\"

func _ms(f: Callable) -> float:
	var runs: Array[float] = []
	for _r in REPS:
		var t := Time.get_ticks_usec()
		f.call()
		runs.append((Time.get_ticks_usec() - t) / 1000.0)
	runs.sort()
	return runs[REPS / 2]

func _init() -> void:
	var pk2_dir := "/opt/sro-files/client"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--pk2-dir="):
			pk2_dir = a.substr(10)
	var media := Pk2Reader.open(pk2_dir.path_join("Media.pk2"))
	var read := func(paths: Array) -> Array:
		var out := []
		for p in paths:
			var e := ObjectLoader.find_file(media, p)
			if e != null:
				out.append(media.read_file(e))
		return out
	var chars: Array = read.call(NpcTableReader.MODEL_TABLE_PATHS)
	var items: Array = read.call(Array(ItemTableReader.table_paths(media)))
	var obj: Array = read.call([NpcTableReader.OBJECT_NAME_TABLE_PATH])
	NativeAssets.force_gdscript = true
	var names := UiTextTable.parse(obj[0])
	NativeAssets.force_gdscript = false
	var tables := [
		["characterdata", chars, [
			["models_by_code CHAR_ (boot)", func(d): NpcTableReader.parse_models_by_code(d, {})],
			["speeds_by_code (boot)", func(d): NpcTableReader.parse_speeds_by_code(d, {})],
			["bc_radius_by_code (boot)", func(d): NpcTableReader.parse_bc_radius_by_code(d, {})],
			["country_by_code (boot)", func(d): NpcTableReader.parse_country_by_code(d, {})],
			["models (entry)", func(d): NpcTableReader.parse_models(d, {})],
			["codes (entry)", func(d): NpcTableReader.parse_codes(d, {})],
			["names (entry)", func(d): NpcTableReader.parse_names(d, names, {})],
			["name_keys (entry, worker)", func(d): NpcTableReader.parse_name_keys(d, {})],
			["models_by_code '' (mobs)", func(d): NpcTableReader.parse_models_by_code(d, {}, "")],
			["org_codes (mobs)", func(d): NpcTableReader.parse_org_codes(d, {})],
			["models_by_name (mobs)", func(d): NpcTableReader.parse_models_by_name(d, names, {})],
		]],
		["itemdata", items, [["items (boot)", func(d): ItemTableReader.parse(d, {})]]],
		["textdata_object", obj, [["ui_table (entry)", func(d): UiTextTable.parse(d)]]],
		["textuisystem", read.call([T + "textuisystem.txt"]), [["ui_table (entry)", func(d): UiTextTable.parse(d)]]],
		["textquest_speechname", read.call([T + "textquest_speechname.txt"]), [["ui_table (entry)", func(d): UiTextTable.parse(d)]]],
		["npcpos", read.call([NpcTableReader.POSITION_TABLE_PATH]), [["positions (entry)", func(d): NpcTableReader.parse_positions(d)]]],
		["skilleffect", read.call([SkillEffectReader.TABLE]), [["parse_all (entry, worker)", func(d): SkillEffectReader.parse_all(d)]]],
	]
	print("TABLECOST table / reader: bytes, decode, lines, tabs | GDScript ms -> native ms (native %s)" % ("ON" if NativeAssets.available() else "OFF"))
	for t in tables:
		var parts: Array = t[1]
		var size := 0
		for d in parts:
			size += (d as PackedByteArray).size()
		var decode := _ms(func():
			for d in parts:
				(d as PackedByteArray).slice(2).get_string_from_utf16())
		var texts := []
		for d in parts:
			texts.append((d as PackedByteArray).slice(2).get_string_from_utf16())
		var lines := _ms(func():
			for x in texts:
				(x as String).replace("\r", "").split("\n"))
		var all_lines := []
		for x in texts:
			all_lines.append((x as String).replace("\r", "").split("\n"))
		var tabs := _ms(func():
			for ls in all_lines:
				for line in ls:
					line.split("\t"))
		print("TABLECOST %s (%d parts): %d bytes, decode %.1f, lines %.1f, tabs %.1f" % [t[0], parts.size(), size, decode, lines, tabs])
		for r in t[2]:
			var run: Callable = r[1]
			NativeAssets.force_gdscript = true
			var g := _ms(func():
				for d in parts:
					run.call(d))
			NativeAssets.force_gdscript = false
			var n := _ms(func():
				for d in parts:
					run.call(d))
			print("TABLECOST   %s: %.1f -> %.1f" % [r[0], g, n])
	quit(0)
