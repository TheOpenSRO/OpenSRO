extends SceneTree

## Round 657 review (L3): what the unique notice's name-key lookup costs on the
## real archive. Times, on this thread, (1) the per-notice scan the first
## version did -- NpcTableReader.find_name_key over the characterdata parts
## until the id is found -- for a known id and for an id no row has (every
## part scanned), and (2) building the whole {id -> SN_ key} index once, which
## World3D now does on a WorkerThreadPool task at load, and a lookup in it.
##
## Usage (render box):
##   godot4 --headless --path client --script res://tools/probe_name_key_cost.gd -- \
##     --pk2=/opt/sro-files/client/Media.pk2 --known=1954 --unknown=999999

func _arg(flag: String, def: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return def

func _scan(pk2: Pk2Reader, id: int) -> Array:
	var t := Time.get_ticks_usec()
	var key := ""
	var parts := 0
	for path in NpcTableReader.MODEL_TABLE_PATHS:
		var entry := ObjectLoader.find_file(pk2, path)
		if entry == null:
			continue
		parts += 1
		key = NpcTableReader.find_name_key(pk2.read_file(entry), id)
		if key != "":
			break
	return [key, parts, (Time.get_ticks_usec() - t) / 1000.0]

func _init() -> void:
	var pk2 := Pk2Reader.open(_arg("--pk2", ""))
	if pk2 == null:
		printerr("no archive"); quit(1); return
	var known := int(_arg("--known", "1954"))
	var unknown := int(_arg("--unknown", "999999"))
	var k := _scan(pk2, known)
	print("NAME KEY COST: scan known %d -> '%s' over %d part(s) in %.1f ms" % [known, k[0], k[1], k[2]])
	var u := _scan(pk2, unknown)
	print("NAME KEY COST: scan unknown %d -> '%s' over %d part(s) in %.1f ms" % [unknown, u[0], u[1], u[2]])
	var t := Time.get_ticks_usec()
	var index := {}
	var bytes := 0
	for path in NpcTableReader.MODEL_TABLE_PATHS:
		var entry := ObjectLoader.find_file(pk2, path)
		if entry != null:
			var data := pk2.read_file(entry)
			bytes += data.size()
			NpcTableReader.parse_name_keys(data, index)
	var build := (Time.get_ticks_usec() - t) / 1000.0
	t = Time.get_ticks_usec()
	var a: String = index.get(known, "")
	var b: String = index.get(unknown, "")
	var look := (Time.get_ticks_usec() - t) / 1000.0
	print("NAME KEY COST: index of %d ids from %d bytes built in %.1f ms; lookups '%s' '%s' in %.3f ms" % [
		index.size(), bytes, build, a, b, look])
	quit(0)
