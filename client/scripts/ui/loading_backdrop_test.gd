extends SceneTree

## The loading screen's art (round 785's follow-up), run headless:
##   godot4 --headless --path client --script res://scripts/ui/loading_backdrop_test.gd
##
## (1) LoadingBackdrop is FUN_0084b6e0's choice (READ): mode 0 the two
##     loading_europe arts, mode 1 rebirth, modes 2/3 by region id with the
##     table read off the image (a sample of it, its default, its edges);
## (2) World3D.region_at_world inverts region_local_to_world: every region in
##     a 5 x 5 window round two frames, at corners and middles of its ground;
## (3) World3D (read from its source, the scene cannot run here) raises a zone
##     change's screen with the arrival's region, sets the rebirth mode on
##     death and mode 2 at every lift.
## NEGATIVE (fails before): LoadingBackdrop and region_at_world did not exist,
## and every screen was built with LoadingScreen.DEFAULT_BACKDROP.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	var watchdog := create_timer(60.0)
	watchdog.timeout.connect(func() -> void:
		print("FAIL the suite never reported (a script error stopped it)")
		quit(1))
	await process_frame
	_test_table()
	_test_region_inverse()
	_test_world3d_source()
	print("ALL PASS" if _failures == 0 else "FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)

func _test_table() -> void:
	var dir := LoadingBackdrop.DIR
	_check(LoadingBackdrop.region_id(97, 168) == 25000, "region 97/168 is the WORD 25000 (x high byte, y low)")
	_check(LoadingBackdrop.for_region(25000) == dir + "loading_zangan.ddj", "Jangan's region shows loading_zangan.ddj")
	_check(LoadingBackdrop.for_region(LoadingBackdrop.region_id(92, 135)) == dir + "loading_hotan.ddj", "Hotan's 92/135 shows loading_hotan.ddj")
	_check(LoadingBackdrop.for_region(LoadingBackdrop.region_id(106, 108)) == dir + "loading_samarkand.ddj", "Samarkand's 106/108 shows loading_samarkand.ddj")
	_check(LoadingBackdrop.for_region(0x8001) == dir + "loading_dungeons_donwhang.ddj", "the Donwhang cave (0x8001)")
	for rid in range(0x8002, 0x8008):
		_check(LoadingBackdrop.for_region(rid) == dir + "loading_royalmausoleum.ddj", "the tomb's 0x%x shows loading_royalmausoleum.ddj" % rid)
	_check(LoadingBackdrop.for_region(0x8008) == dir + "loading_china_1.ddj", "0x8008, past the tomb's range: the default")
	_check(LoadingBackdrop.for_region(LoadingBackdrop.region_id(97, 167)) == dir + "loading_china_1.ddj", "a town's neighbour region is not the town: the default")
	_check(LoadingBackdrop.for_region(-1) == dir + "loading_china_1.ddj", "an unknown region: the default")
	_check(LoadingBackdrop.REGION_ART.size() == 45, "45 regions pick their own art (%d)" % LoadingBackdrop.REGION_ART.size())
	_check(LoadingBackdrop.path(0, 25000, 0) == dir + "loading_europe_1.ddj" and LoadingBackdrop.path(0, 25000, 1) == dir + "loading_europe_2.ddj"
		and LoadingBackdrop.path(0, 0x8002, 7) == dir + "loading_europe_2.ddj", "mode 0 (the first entry): loading_europe_1 or _2 by the draw, whatever the region")
	_check(LoadingBackdrop.path(1, 25000, 0) == dir + "loading_rebirth.ddj", "mode 1 (after a death): loading_rebirth.ddj")
	_check(LoadingBackdrop.path(2, 0x8003, 0) == dir + "loading_royalmausoleum.ddj" and LoadingBackdrop.path(3, 25000, 0) == dir + "loading_zangan.ddj", "modes 2 and 3 pick by region")
	_check(LoadingBackdrop.path(6, 25000, 0) == "", "a mode past 5 changes no art")

func _test_region_inverse() -> void:
	var S := load("res://scripts/World3D.gd") as GDScript
	_check(S != null, "World3D.gd loads")
	if S == null:
		return
	var bad := 0
	var n := 0
	for frame in [Vector2i(97, 168), Vector2i(102, 153)]:
		for dx in range(-2, 3):
			for dy in range(-2, 3):
				for local in [Vector2(1, 1), Vector2(960, 960), Vector2(1919, 1), Vector2(1, 1919), Vector2(1919, 1919)]:
					var rx: int = frame.x + dx
					var ry: int = frame.y + dy
					var w: Vector2 = S.region_local_to_world(rx, ry, local.x, local.y, frame.x, frame.y)
					var back: Vector2i = S.region_at_world(w.x, w.y, frame.x, frame.y)
					n += 1
					if back != Vector2i(rx, ry):
						bad += 1
						if bad <= 3:
							print("  %d/%d local %s -> world %s -> %s" % [rx, ry, str(local), str(w), str(back)])
	_check(bad == 0, "region_at_world inverts region_local_to_world (%d of %d points back in their region)" % [n - bad, n])

func _body(src: String, header: String) -> String:
	var at := src.find(header)
	if at < 0:
		return ""
	return src.substr(at, src.find("\nfunc ", at + 1) - at)

func _test_world3d_source() -> void:
	var src := (load("res://scripts/World3D.gd") as GDScript).source_code
	_check(_body(src, "\nfunc _on_change_zone_result(").find("await _show_loading_screen(_arrival_region_id(result))") >= 0,
		"a zone change raises its screen with the arrival's region")
	_check(_body(src, "\nfunc _enter_dead_state(").find("_loading_mode = LoadingBackdrop.MODE_REBIRTH") >= 0,
		"a death sets the rebirth mode")
	var drain := _body(src, "\nfunc _drain_initial_load(")
	_check(drain.find("_loading_mode = LoadingBackdrop.MODE_ZONE") > drain.find("LoadingScreen: lifted"),
		"the lift leaves the mode at 2")
	_check(src.find("var _loading_mode := LoadingBackdrop.MODE_FIRST") >= 0, "a new world starts in mode 0 (the first entry)")
	_check(src.find("LoadingScreen.new(LoadingScreen.DEFAULT_BACKDROP") < 0, "no screen is built with the default art outright")
