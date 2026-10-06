extends SceneTree

## Round 741: what reading every part the archive's own index names adds, for
## itemdata and characterdata, against the seven-path lists the client used
## before (ItemTableReader.LEGACY_TABLE_PATHS, NpcTableReader's old list).
## Headless, on the render box; prints counts and timings, commits nothing:
##
##   client/tools/remote_godot.sh script res://tools/probe_table_parts.gd -- --pk2-dir=/opt/sro-files/client
##
## Prints, per table: parts and bytes read, rows parsed, ids that only the
## index's parts define, ids defined in more than one part whose winning row
## differs between the two orders, and the parse time (median of REPS) of
## the reader the world runs at boot. Then whether item 62607 resolves its
## model, icon and name.

const REPS := 3
const T := "server_dep\\silkroad\\textdata\\"
const OLD_ITEMS := [
	T + "itemdata.txt", T + "itemdata_5000.txt", T + "itemdata_10000.txt", T + "itemdata_15000.txt",
	T + "itemdata_20000.txt", T + "itemdata_25000.txt", T + "itemdata_30000.txt",
]
const OLD_CHARS := [
	T + "characterdata.txt", T + "characterdata_5000.txt", T + "characterdata_10000.txt",
	T + "characterdata_15000.txt", T + "characterdata_20000.txt", T + "characterdata_25000.txt",
	T + "characterdata_30000.txt",
]

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
	print("PARTS native %s" % ("ON" if NativeAssets.available() else "OFF"))
	var read := func(paths: Array) -> Array:
		var out := []
		for p in paths:
			var e := ObjectLoader.find_file(media, p)
			if e != null:
				out.append(media.read_file(e))
		return out
	var bytes_of := func(parts: Array) -> int:
		var n := 0
		for d in parts:
			n += (d as PackedByteArray).size()
		return n
	# --- itemdata
	var old_items: Array = read.call(OLD_ITEMS)
	var new_items: Array = CharCatalog.index_parts(media, CharCatalog.ITEM_INDEX)
	var parse_all := func(parts: Array) -> Dictionary:
		var into := {}
		for d in parts:
			ItemTableReader.parse(d, into)
		return into
	var a: Dictionary = parse_all.call(old_items)
	var b: Dictionary = parse_all.call(new_items)
	var only_new := 0
	var winner_changed := 0
	for id in b:
		if not a.has(id):
			only_new += 1
		elif (a[id] as ItemTableReader.Item).code_name != (b[id] as ItemTableReader.Item).code_name \
				or (a[id] as ItemTableReader.Item).model_path != (b[id] as ItemTableReader.Item).model_path:
			winner_changed += 1
	var lost := 0
	for id in a:
		if not b.has(id):
			lost += 1
	print("PARTS itemdata old: %d part(s), %d bytes, %d row(s), parse %.1f ms" % [
		old_items.size(), bytes_of.call(old_items), a.size(), _ms(func(): parse_all.call(old_items))])
	print("PARTS itemdata index: %d part(s), %d bytes, %d row(s), parse %.1f ms" % [
		new_items.size(), bytes_of.call(new_items), b.size(), _ms(func(): parse_all.call(new_items))])
	print("PARTS itemdata: %d id(s) only the index's parts define, %d old id(s) lost, %d shared id(s) whose winning row differs" % [
		only_new, lost, winner_changed])
	var t_cached := Time.get_ticks_usec()
	var shared := ItemTableReader.load_all(media)
	print("PARTS itemdata load_all first %.1f ms (%d rows)" % [(Time.get_ticks_usec() - t_cached) / 1000.0, shared.size()])
	t_cached = Time.get_ticks_usec()
	shared = ItemTableReader.load_all(media)
	print("PARTS itemdata load_all again %.3f ms (cached)" % [(Time.get_ticks_usec() - t_cached) / 1000.0])
	for id in [62607, 4118]:
		var it: ItemTableReader.Item = b.get(id)
		if it == null:
			print("PARTS item %d: MISSING (old list has it: %s)" % [id, str(a.has(id))])
			continue
		var icon_ok := ObjectLoader.find_file(media, it.icon_path) != null
		print("PARTS item %d: code %s model %s icon %s (in Media.pk2: %s) name_strid %s, old list has it: %s" % [
			id, it.code_name, it.model_path, it.icon_path, str(icon_ok), it.name_strid, str(a.has(id))])
	# --- characterdata
	var old_chars: Array = read.call(OLD_CHARS)
	var new_chars: Array = CharCatalog.index_parts(media, CharCatalog.CHAR_INDEX)
	var codes := func(parts: Array) -> Dictionary:
		var into := {}
		for d in parts:
			NpcTableReader.parse_models_by_code(d, into, "")
		return into
	var ca: Dictionary = codes.call(old_chars)
	var cb: Dictionary = codes.call(new_chars)
	var c_only := 0
	var c_mob_only := 0
	for k in cb:
		if not ca.has(k):
			c_only += 1
			if String(k).begins_with("MOB_"):
				c_mob_only += 1
	var boot := func(parts: Array) -> void:
		var s := {}
		var r := {}
		var dd := {}
		var cc := {}
		for d in parts:
			s = NpcTableReader.parse_speeds_by_code(d, s)
			r = NpcTableReader.parse_bc_radius_by_code(d, r)
			dd = NpcTableReader.parse_decay_by_code(d, dd)
			cc = NpcTableReader.parse_country_by_code(d, cc)
	print("PARTS characterdata old: %d part(s), %d bytes, %d code(s) with a model, boot readers %.1f ms" % [
		old_chars.size(), bytes_of.call(old_chars), ca.size(), _ms(func(): boot.call(old_chars))])
	print("PARTS characterdata index: %d part(s), %d bytes, %d code(s) with a model, boot readers %.1f ms" % [
		new_chars.size(), bytes_of.call(new_chars), cb.size(), _ms(func(): boot.call(new_chars))])
	print("PARTS characterdata: %d code(s) only the index's parts define (%d MOB_)" % [c_only, c_mob_only])
	quit()
