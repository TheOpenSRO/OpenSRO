extends SceneTree

## Dev tool (round 859): the animation events of every body's die clip.
##
## The DEAD state's event callback (READ c:0xa59e30) fires the death effects
## on an event of type 1 and the kill orbs (FUN_009cb7c0) on one of type 100.
## This walks every `.bsr` under res\ in Data.pk2, takes the die clip (action
## type 4 in `default`, BsrReader.animation_entry_for) and counts its events
## by type, printing one summary and, with --each, one line a body:
##
##   DIE<TAB>path<TAB>clip ms<TAB>type:key,...
##
##   godot4 --headless --path client --script res://tools/census_die_events.gd -- \
##     --pk2=/path/Data.pk2 [--each] [--prefix=res\npc\]

func _arg(flag: String, fallback: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
		if a == flag:
			return "1"
	return fallback

func _initialize() -> void:
	var archive := Pk2Reader.open(_arg("--pk2"))
	if archive == null:
		printerr("usage: --pk2=<Data.pk2> [--each] [--prefix=res\\npc\\]")
		quit(2)
		return
	var prefix := _arg("--prefix", "res\\").to_lower()
	var each := _arg("--each") != ""
	var bodies := 0
	var with_die := 0
	var by_type := {}
	var with_100 := 0
	var with_1 := 0
	var keys_100: Array = []
	for p in archive.file_paths():
		var path := String(p).to_lower().replace("/", "\\")
		if not path.ends_with(".bsr") or not path.begins_with(prefix):
			continue
		var data := SkinnedBsrAssembler._read(archive, path)
		if data.is_empty():
			continue
		var parsed := BsrReader.parse(data)
		if parsed == null:
			continue
		bodies += 1
		var entry = parsed.animation_entry_for(BsrReader.AnimationEntry.TYPE_DIE, "default")
		if entry == null:
			continue
		with_die += 1
		var seen := {}
		var cells: PackedStringArray = []
		for e in entry.events:
			var ev := e as PackedInt32Array
			if ev.size() < 2:
				continue
			cells.append("%d:%d" % [ev[1], ev[0]])
			if not seen.has(ev[1]):
				seen[ev[1]] = true
				by_type[ev[1]] = int(by_type.get(ev[1], 0)) + 1
				if ev[1] == 100:
					keys_100.append(ev[0])
		if seen.has(100):
			with_100 += 1
		if seen.has(1):
			with_1 += 1
		if each:
			print("DIE\t%s\t%s" % [path, ",".join(cells)])
	keys_100.sort()
	var med := int(keys_100[keys_100.size() / 2]) if not keys_100.is_empty() else -1
	print("DIE SUMMARY bodies=%d with_die_clip=%d with_type1=%d with_type100=%d by_type=%s type100_key_ms min=%d median=%d max=%d" % [
		bodies, with_die, with_1, with_100, str(by_type),
		int(keys_100[0]) if not keys_100.is_empty() else -1, med,
		int(keys_100[-1]) if not keys_100.is_empty() else -1])
	quit(0)
