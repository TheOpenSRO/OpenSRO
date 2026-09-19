extends SceneTree

## Dev tool: prints the six 2-float (FloatGraph) channels of environment.ifo's
## records -- file channels 7, 8, 10, 11, 12, 15 -- as (value, time) pairs.
## Written for round 229 to tell which pair the client scales by its view
## distance (fog near/far) and which pair it maps from [-1, 1] to [0, 1].
##
##   godot4 --headless --path client --script res://tools/dump_environment_floats.gd -- --pk2=<Map.pk2> [--limit=n]

func _arg(flag: String, fallback: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return fallback

func _init() -> void:
	var pk2_path := _arg("--pk2")
	var limit := int(_arg("--limit", "6"))
	if pk2_path == "":
		printerr("usage: --pk2=<Map.pk2> [--limit=n]")
		quit(2)
		return
	var archive := Pk2Reader.open(pk2_path)
	if archive == null:
		printerr("could not open ", pk2_path)
		quit(1)
		return
	var entry := ObjectLoader.find_file(archive, "environment.ifo")
	if entry == null:
		printerr("environment.ifo not found in ", pk2_path)
		quit(1)
		return
	var table := EnvironmentReader.parse(archive.read_file(entry))
	if table == null:
		quit(1)
		return
	print("records: %d" % table.records.size())
	var float_channels := [7, 8, 10, 11, 12, 15]
	var shown := 0
	for rec in table.records:
		if shown >= limit:
			break
		shown += 1
		print("record key=%d name=%s" % [rec.key, rec.name1])
		for ch in float_channels:
			var groups: Array = rec.channels[ch]
			var parts := PackedStringArray()
			for g in groups:
				parts.append("(%.3f @ %.3f)" % [g[0], g[1]])
			print("  ch%-2d n=%d  %s" % [ch, groups.size(), " ".join(parts)])
	# Ranges over every record, per channel.
	for ch in float_channels:
		var lo := INF
		var hi := -INF
		for rec in table.records:
			for g in rec.channels[ch]:
				lo = minf(lo, g[0])
				hi = maxf(hi, g[0])
		print("channel %d value range over all records: [%.3f, %.3f]" % [ch, lo, hi])
	quit(0)
