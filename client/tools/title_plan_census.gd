extends SceneTree

## Round 680: the title's preload plan (TitleCellPlan) for every intro in the
## player's own Media.pk2 -- how many region cells the camera can see along
## the whole path at a few draw distances, against the cells round 678's
## 3x3 streaming window touched and retail's own preload (each
## FUN_0056c870 region and its eight neighbours, CGWorld::FUN_00aa2190),
## and how long the plan takes to compute. MEASURED on the box; no game data
## in the repo.
##
##   remote_godot.sh script res://tools/title_plan_census.gd -- --media=/opt/sro-files/client/Media.pk2

const NAMES := ["roc", "constantinople", "china_wharf", "jupiter_login", "rm", "ruby_baghdad"]

func _initialize() -> void:
	var media_path := ""
	var map_path := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--media="):
			media_path = a.substr(8)
		if a.begins_with("--map="):
			map_path = a.substr(6)
	var map := Pk2Reader.open(map_path) if map_path != "" else null
	var media := Pk2Reader.open(media_path)
	if media == null:
		print("CENSUS FAIL cannot open Media.pk2 at '%s'" % media_path)
		quit(1)
		return
	for name in NAMES:
		var entry := ObjectLoader.find_file(media, "script\\intro\\%s.txt" % name)
		if entry == null:
			print("%s: not in this archive" % name)
			continue
		var p := IntroScript.parse(media.read_file(entry))
		var path := IntroCameraPath.from_keyframes(p.keyframes)
		var origin := IntroScript.origin_region(p)
		var window := {}
		TitleCellPlan.for_each_sample(path, TitleCellPlan.SAMPLE_STEP_S, func(_t: float, pose: IntroCameraPath.Pose) -> void:
			var c := TitleCellPlan.cell_of(pose.target)
			for dx in range(-1, 2):
				for dy in range(-1, 2):
					window[c + Vector2i(dx, dy)] = true)
		var retail := {}
		for r in IntroScript.preload_regions(p):
			for dx in range(-1, 2):
				for dy in range(-1, 2):
					retail[Vector2i(r.x - origin.x + dx, r.y - origin.y + dy)] = true
		var with_terrain := func(cells: Array) -> int:
			if map == null:
				return -1
			return cells.filter(func(c): return ObjectLoader.find_file(map, "%d\\%d.m" % [origin.x + c.x, origin.y + c.y]) != null).size()
		var line := "%s: %.1f s, frame %d/%d; 3x3 window union %d cells (%d with terrain); retail preload (3x3 per region) %d cells (%d with terrain), %d of the window's missing" % [
			name, path.length, origin.x, origin.y, window.size(), with_terrain.call(window.keys()), retail.size(),
			with_terrain.call(retail.keys()), window.keys().filter(func(c): return not retail.has(c)).size()]
		print(line)
		# How fast the camera moves: the target's speed and the yaw/pitch
		# rates, sampled every 0.01 s -- what SAMPLE_STEP_S must resolve.
		var top_speed := 0.0
		var top_turn := 0.0
		var prev := path.sample(0.0)
		var tt := 0.01
		while tt <= path.length:
			var cur := path.sample(tt)
			top_speed = maxf(top_speed, cur.target.distance_to(prev.target) / 0.01)
			top_turn = maxf(top_turn, maxf(absf(cur.yaw - prev.yaw), absf(cur.pitch - prev.pitch)) / 0.01)
			prev = cur
			tt += 0.01
		print("  camera: target up to %.0f units/s, yaw or pitch up to %.2f rad/s" % [top_speed, top_turn])
		var plan_w := TitleCellPlan.window_cells(path, 1)
		print("  window plan (TitleCellPlan.window_cells): %d cells (%d with terrain)" % [plan_w.size(), with_terrain.call(plan_w)])
		for d in [2500.0, 3840.0, 5760.0, 7680.0]:
			var t0 := Time.get_ticks_usec()
			var plan := TitleCellPlan.cells(path, 1, d)
			var ms := (Time.get_ticks_usec() - t0) / 1000.0
			var span_x := Vector2i(999, -999)
			var span_y := Vector2i(999, -999)
			for c in plan:
				span_x = Vector2i(mini(span_x.x, c.x), maxi(span_x.y, c.x))
				span_y = Vector2i(mini(span_y.x, c.y), maxi(span_y.y, c.y))
			print("  draw %.0f: %d cells (%d with terrain; dx %d..%d, dy %d..%d) in %.1f ms" % [d, plan.size(), with_terrain.call(plan),
				span_x.x, span_x.y, span_y.x, span_y.y, ms])
	quit()
