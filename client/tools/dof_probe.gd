extends SceneTree

## Dev tool (round 773): every dungeon dungeoninfo.txt names, parsed by
## DofReader from the player's own Data.pk2, with each file's counts -- the
## measurement that the reader walks the real files. Prints only counts and
## names (no game data is written):
##   godot --headless --path client --script res://tools/dof_probe.gd -- --pk2=/opt/sro-files/client/Data.pk2

func _arg(flag: String, fallback: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return fallback

func _initialize() -> void:
	var data := Pk2Reader.open(_arg("--pk2", "/opt/sro-files/client/Data.pk2"))
	if data == null:
		printerr("no Data.pk2")
		quit(1)
		return
	var e := ObjectLoader.find_file(data, "Dungeon\\dungeoninfo.txt")
	if e == null:
		printerr("no dungeoninfo.txt")
		quit(1)
		return
	var info := DofReader.parse_info(data.read_file(e))
	print("DOF dungeoninfo: %d dungeons" % info.size())
	var ok := 0
	var ids := info.keys()
	ids.sort()
	for rid in ids:
		var path: String = info[rid]
		var fe := ObjectLoader.find_file(data, path)
		if fe == null:
			print("DOF 0x%x %s: MISSING" % [rid, path])
			continue
		var d := DofReader.parse(data.read_file(fe))
		if d == null:
			print("DOF 0x%x %s: DID NOT PARSE" % [rid, path])
			continue
		ok += 1
		var objs := 0
		var lights := 0
		var entrances := 0
		var missing_bsr := 0
		for b in d.blocks:
			objs += (b as DofReader.Block).objects.size()
			lights += (b as DofReader.Block).lights.size()
			if (b as DofReader.Block).flags & 1:
				entrances += 1
			if ObjectLoader.find_file(data, (b as DofReader.Block).path) == null:
				missing_bsr += 1
		print("DOF 0x%x %s: %d blocks, %d objects, %d lights, %d entrances, %d floors, aabb %s, room bsr missing %d" % [
			rid, path, d.blocks.size(), objs, lights, entrances, d.floor_names.size(), d.aabb, missing_bsr])
	print("DOF parsed %d of %d" % [ok, info.size()])
	# --stitch=<rid,...>: the room transform's measurement (DungeonWorld's
	# class comment): linked outline edges meeting a neighbour's, under the
	# block yaw as read and under the opposite sign.
	var stitch := _arg("--stitch", "")
	for tok in stitch.split(",", false):
		var rid := int(tok)
		var built := DungeonWorld.build(data, rid)
		if built == null:
			print("STITCH 0x%x: no dungeon" % rid)
			continue
		var as_read := DungeonWorld.stitch_census(built.graph)
		var flipped: Array[NavGraph.PlacedObject] = []
		for i in built.dof.blocks.size():
			var b: DofReader.Block = built.dof.blocks[i]
			var coll := NavObjectSource.load_collision(data, b.path)
			if coll != null:
				flipped.append(NavGraph.place(coll, i, b.position, -b.yaw))
		var other := DungeonWorld.stitch_census(NavGraph.build_dungeon(flipped))
		print("STITCH 0x%x: %d rooms (%d without a navmesh); linked edges met: as read %d/%d, yaw negated %d/%d" % [
			rid, built.dof.blocks.size(), built.rooms_without_nav, as_read["met"], as_read["linked"], other["met"], other["linked"]])
	# --blocks=<rid>: each block's colours and fog (the light and fog
	# World3D._apply_dungeon_block applies), distinct values counted.
	var bl := _arg("--blocks", "")
	for tok in bl.split(",", false):
		var rid := int(tok)
		var path: String = info.get(rid, "")
		var fe := ObjectLoader.find_file(data, path) if path != "" else null
		if fe == null:
			continue
		var d := DofReader.parse(data.read_file(fe))
		var seen := {}
		for b in d.blocks:
			var k := "a=%08x b=%08x fog=%s" % [(b as DofReader.Block).color_a, (b as DofReader.Block).color_b, (b as DofReader.Block).fog]
			seen[k] = int(seen.get(k, 0)) + 1
		for k in seen:
			print("BLOCKS 0x%x: %d x %s" % [rid, seen[k], k])
	quit(0)
