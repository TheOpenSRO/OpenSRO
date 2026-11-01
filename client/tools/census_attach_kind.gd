extends SceneTree

## Round 850: the attachable `kind` (the word at CResAttachable +0x318, the
## trailing block's second word, BsrReader.Attachable.kind) of every model an
## item is drawn from. CCompChar's slot 22 (0x00c29bd0, READ) hides a worn
## part by this word: kind 6, 7, 14 or 15 for its "all" mode. This counts, per
## TypeID3/TypeID4, which kinds the item models carry, so the rule can be
## stated in terms of the items the client knows.
##
##   remote_godot.sh script res://tools/census_attach_kind.gd -- --pk2dir=/opt/sro-files/client [--verbose]
##
## Prints `KIND t3/t4 -> {kind: models}` and `KIND total` lines.

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
		printerr("census_attach_kind: no Data.pk2 / Media.pk2 under %s" % dir)
		quit(2)
		return
	var rows := ItemTableReader.load_all(media)
	var seen := {}
	var by_type := {} # "t1/t2/t3/t4" -> {kind: count}
	var totals := {}
	var examples := {} # kind -> [paths]
	var ids := rows.keys()
	ids.sort()
	for id in ids:
		var item: ItemTableReader.Item = rows[id]
		if item.model_path == "" or item.type_ids.size() < 4:
			continue
		var t := "%d/%d/%d/%d" % [item.type_ids[0], item.type_ids[1], item.type_ids[2], item.type_ids[3]]
		var base := item.model_path.substr(0, item.model_path.length() - 4)
		for p in [item.model_path, base + "_l.bsr", base + "_r.bsr", base + "_f.bsr"]:
			var key := String(p).to_lower()
			if seen.has(key):
				continue
			seen[key] = true
			var e := ObjectLoader.find_file(data, p)
			if e == null:
				e = ObjectLoader.find_file(data, "res\\" + p)
			if e == null:
				continue
			var bytes := data.read_file(e)
			var blk := BsrReader.attachable_block(bytes)
			var k: int = blk.kind if blk != null else -1
			var w0: int = blk.word0 if blk != null else -1
			var kk := "%d" % k
			if not by_type.has(t):
				by_type[t] = {}
			by_type[t][kk] = int(by_type[t].get(kk, 0)) + 1
			totals[kk] = int(totals.get(kk, 0)) + 1
			if not examples.has(kk):
				examples[kk] = []
			if (examples[kk] as Array).size() < 6:
				(examples[kk] as Array).append("%s (word0 %d, %s)" % [p, w0, item.code_name])
			if verbose:
				print("MODEL %s kind %d word0 %d %s %s" % [t, k, w0, item.code_name, p])
	var ts := by_type.keys()
	ts.sort()
	for t in ts:
		print("KIND %s -> %s" % [t, str(by_type[t])])
	print("KIND total %s" % str(totals))
	for kk in examples:
		print("KIND example %s: %s" % [kk, "; ".join(PackedStringArray(examples[kk]))])
	quit(0)
