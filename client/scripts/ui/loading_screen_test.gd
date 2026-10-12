extends SceneTree

## The loading screen before the centre cell (round 562), run headless:
##   godot4 --headless --path client --script res://scripts/ui/loading_screen_test.gd
##
## Three things World3D relies on since round 562, each checked on the
## screen itself rather than on a picture:
##   (1) a screen handed the Media.pk2 the world already holds reads its
##       backdrop through THAT handle and opens no reader of its own;
##   (2) `cover_siblings` puts a screen created before the HUD back over the
##       HUD's later siblings (CanvasItem draw order is child order);
##   (3) World3D._ready puts the screen up before the centre cell, covers
##       the HUD before the drain, and every screen World3D builds is given
##       the held handle. _ready cannot run here (it needs the scene, a
##       server and the archives), so this reads the script's own source --
##       the same order the box run's log confirms (`LoadingScreen: up at
##       frame` before the centre cell's `ground textures for` line).
##
## NEGATIVE (fails before round 562): LoadingScreen had a one-argument
## _init and no cover_siblings, media_source or media_open_ms; World3D._ready
## had no _show_loading_screen call ahead of _load_initial_region_neighborhood
## and built every screen with a bare `LoadingScreen.new()`.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## A Media.pk2 stand-in: a Pk2Reader that owns no file and answers an empty
## root directory, counting how often it was asked. No archive is ever
## shipped (docs/LEGAL.md); the question here is only which reader the
## screen consults.
class StubMedia extends Pk2Reader:
	var dir_reads := 0
	func read_dir() -> Array[Pk2Reader.Entry]:
		dir_reads += 1
		var none: Array[Pk2Reader.Entry] = []
		return none

## Whether the script declares a method or a property of that name. Asked
## before anything below is called: on a pre-562 LoadingScreen the two-argument
## _init and the members below are runtime errors, and a runtime error in
## _initialize aborts it before _finish's quit() -- a headless Godot that
## never exits, holding the box lock. A missing member is a FAIL line instead.
func _declares(script: Script, name: String) -> bool:
	for m in script.get_script_method_list():
		if m.name == name:
			return true
	for p in script.get_script_property_list():
		if p.name == name:
			return true
	return false

## World3D.gd needs the NetClient autoload registered before it compiles,
## which is the case in _initialize and not in _init (hud_window_test.gd's
## pattern, world3d_reentry_test.gd's too).
func _initialize() -> void:
	# The root of a --script suite enters the tree only after _initialize
	# returns (hud_click_routing_test.gd measured it), and a node added under
	# it before then gets no _ready -- measured here too: the screen's
	# media_source stayed '' until this wait was added. A watchdog fails the
	# suite, rather than hanging it, if a script error stops it before it
	# reports.
	var watchdog := create_timer(60.0)
	watchdog.timeout.connect(func() -> void:
		print("FAIL the suite never reported (a script error stopped it)")
		quit(1))
	await process_frame
	_check(root.is_inside_tree(), "the probe: after one frame the root is in the tree")
	var complete := true
	for name in ["cover_siblings", "media_source", "media_open_ms"]:
		var has := _declares(LoadingScreen, name)
		_check(has, "LoadingScreen declares %s" % name)
		complete = complete and has
	if complete:
		_test_reused_handle()
		_test_no_handle()
		_test_cover_siblings()
	else:
		print("FAIL LoadingScreen lacks round 562's members -- its runtime checks skipped rather than errored")
		_failures += 1
	_test_world3d_order()
	_finish()

func _test_reused_handle() -> void:
	var media := StubMedia.new()
	var screen := LoadingScreen.new(LoadingScreen.DEFAULT_BACKDROP, media)
	root.add_child(screen)
	_check(screen.media_source == "reused",
		"a screen given a handle reports media reused (got '%s')" % screen.media_source)
	_check(media.dir_reads >= 1,
		"the screen looked its backdrop up through the handle it was given (%d directory read(s))" % media.dir_reads)
	_check(screen.media_open_ms == 0, "a reused handle costs no open (%d ms)" % screen.media_open_ms)
	# The stub has no art, so the screen builds without a backdrop and still
	# works as a gauge.
	screen.set_progress(0.5)
	_check(screen.progress == 0.5 and absf(screen.fill_width() - 0.5 * screen._bar_width) < 0.01,
		"the gauge fills without a backdrop")
	screen.set_progress(1.7)
	_check(screen.progress == 1.0, "the gauge clamps at full (%.2f)" % screen.progress)
	screen.set_caption("Loading")
	_check(screen._caption != null and screen._caption.text == "Loading",
		"the caption is settable without a backdrop")
	_test_paint(screen)
	root.remove_child(screen)
	screen.free()

## Round 785: `paint` is the client's FUN_00ba3fc0 -- it sets the gauge every
## time and repaints only when more than PAINT_INTERVAL_MS have passed since
## the last repaint, or when forced. (The repaint itself is RenderingServer.
## force_draw, a no-op under --headless; what is checked is when it is asked
## for.)
func _test_paint(screen: LoadingScreen) -> void:
	_check(LoadingScreen.PAINT_INTERVAL_MS == 50, "the repaint interval is the client's 50 ms (0x32)")
	var before := screen.paints
	var first := screen.paint(0.25)
	_check(first and screen.paints == before + 1, "the first paint repaints (%s, %d)" % [str(first), screen.paints - before])
	_check(screen.progress == 0.25, "a paint sets the gauge (%.2f)" % screen.progress)
	var second := screen.paint(0.5)
	_check(not second and screen.paints == before + 1,
		"a paint within 50 ms of the last sets the gauge but does not repaint (%s)" % str(second))
	_check(screen.progress == 0.5, "the skipped paint still set the gauge (%.2f)" % screen.progress)
	var forced := screen.paint(1.0, true)
	_check(forced and screen.paints == before + 2, "a forced paint repaints at once (%s)" % str(forced))
	OS.delay_msec(LoadingScreen.PAINT_INTERVAL_MS + 5)
	_check(screen.paint(1.0), "a paint more than 50 ms after the last repaints")
	_check(not root.disable_3d, "the viewport's 3D is as it was after a paint")
	var loose := LoadingScreen.new()
	_check(not loose.paint(0.5, true) and loose.progress == 0.5,
		"a screen out of the tree sets its gauge and never repaints")
	loose.free()

func _test_no_handle() -> void:
	# The pre-562 path, kept for a caller without a handle: the screen opens
	# its own Media.pk2 or has none, and never claims a reuse.
	var bare := LoadingScreen.new()
	root.add_child(bare)
	_check(bare.media_source == "opened" or bare.media_source == "none",
		"a screen given no handle opens its own or has none (got '%s')" % bare.media_source)
	_check(bare.media_source != "reused", "a screen given no handle never reports a reuse")
	root.remove_child(bare)
	bare.free()

func _test_cover_siblings() -> void:
	var ui := Control.new()
	root.add_child(ui)
	var early := LoadingScreen.new(LoadingScreen.DEFAULT_BACKDROP, StubMedia.new())
	ui.add_child(early)
	# The HUD World3D builds after the screen: later siblings of it.
	var minimap := Control.new()
	var underbar := Control.new()
	ui.add_child(minimap)
	ui.add_child(underbar)
	_check(early.get_index() < underbar.get_index(),
		"the premise: a HUD added after the screen is a later sibling (screen %d, underbar %d)" % [
			early.get_index(), underbar.get_index()])
	early.cover_siblings()
	_check(early.get_index() == ui.get_child_count() - 1,
		"cover_siblings makes the screen the last child, drawn over the HUD (index %d of %d)" % [
			early.get_index(), ui.get_child_count()])
	_check(minimap.get_index() < early.get_index() and underbar.get_index() < early.get_index(),
		"the HUD's controls all come before the screen after cover_siblings")
	_check(ui.get_child_count() == 3, "cover_siblings moves, never adds or removes (%d children)" % ui.get_child_count())
	# Without a parent it is a no-op rather than an error.
	var loose := LoadingScreen.new()
	loose.cover_siblings()
	loose.free()
	root.remove_child(ui)
	ui.free()

func _test_world3d_order() -> void:
	var S := load("res://scripts/World3D.gd") as GDScript
	_check(S != null, "World3D.gd loads")
	if S == null:
		return
	var src := S.source_code
	var ready_header := "\nfunc _ready() -> void:"
	var ready_at := src.find(ready_header)
	_check(ready_at >= 0, "World3D.gd has _ready")
	if ready_at < 0:
		return
	# The body ends at the next function header. The search starts past
	# _ready's own header: in multiline mode `^` also matches right at an
	# offset that follows a newline, which is _ready itself.
	var next_func := RegEx.new()
	next_func.compile("(?m)^(?:static )?func ")
	var after := next_func.search(src, ready_at + ready_header.length())
	var ready_end := after.get_start() if after != null else src.length()
	var body := src.substr(ready_at, ready_end - ready_at)
	var show := body.find("await _show_loading_screen()")
	var centre := body.find("_load_initial_region_neighborhood()")
	var hud := body.find("_try_initialize_pk2_ui()")
	var cover := body.find(".cover_siblings()")
	var drain := body.find("_drain_initial_load(")
	_check(centre >= 0 and drain >= 0 and hud >= 0, "_ready builds the centre cell, the HUD and drains")
	_check(show >= 0 and show < centre,
		"_ready puts the loading screen up before the centre cell (screen at %d, centre at %d)" % [show, centre])
	_check(cover >= 0 and hud < cover and cover < drain,
		"_ready covers the HUD with the screen after building it and before the drain (hud %d, cover %d, drain %d)" % [
			hud, cover, drain])
	# Every screen World3D builds is given the archive it already holds.
	var builds := 0
	var with_handle := 0
	var at := src.find("LoadingScreen.new(")
	while at >= 0:
		builds += 1
		var eol := src.find("\n", at)
		var construction := src.substr(at, (eol if eol >= 0 else src.length()) - at)
		if construction.find("_open_media_pk2_if_set()") >= 0:
			with_handle += 1
		at = src.find("LoadingScreen.new(", at + 1)
	_check(builds >= 2 and with_handle == builds,
		"every LoadingScreen World3D builds is given _open_media_pk2_if_set() (%d of %d)" % [with_handle, builds])
	_test_world3d_round785(src)

## Round 785, read from World3D.gd's source (the scene cannot run here): the
## caption never changes (until then the drain's last frame turned it to
## "Entering the world..." for one frame), a dungeon's build reports its
## progress to the screen and ends with a forced repaint, and the drain's end
## keeps the gauge full for one frame before the lift.
## NEGATIVE (fails before round 785): World3D called set_caption("Entering the
## world...") in _drain_initial_load, DungeonWorld.build took no progress
## callable and _load_dungeon never painted.
func _test_world3d_round785(src: String) -> void:
	_check(src.find("set_caption(") < 0, "World3D never changes the loading screen's caption")
	var load_at := src.find("\nfunc _load_dungeon(")
	_check(load_at >= 0, "World3D.gd has _load_dungeon")
	if load_at < 0:
		return
	var body := src.substr(load_at, src.find("\nfunc ", load_at + 1) - load_at)
	_check(body.find("_loading_paint(f * DUNGEON_BUILD_SHARE)") >= 0,
		"_load_dungeon hands DungeonWorld.build a progress callable that paints the gauge")
	_check(body.find("_loading_paint(1.0, true)") >= 0, "_load_dungeon ends with a forced repaint at 100 %")
	# The effects' attach repaints nothing (a repaint there cost the tomb's
	# lv.2 ~1 s on the box, MEASURED); the build's end paints 100 %.
	var attach_at := src.find("\nfunc _attach_dungeon_effects(")
	var attach := src.substr(attach_at, src.find("\nfunc ", attach_at + 1) - attach_at)
	_check(attach_at >= 0 and attach.find("_loading_paint(") < 0 and attach.find(".paint(") < 0,
		"the effects' attach makes no repaint")
	var drain_at := src.find("\nfunc _drain_initial_load(")
	var drain := src.substr(drain_at, src.find("\nfunc ", drain_at + 1) - drain_at)
	var full := drain.rfind("_loading_screen.set_progress(1.0)")
	var lift := drain.find("_loading_screen.queue_free()")
	_check(full >= 0 and lift > full and drain.substr(full, lift - full).count("await get_tree().process_frame") == 1,
		"the drain's end: the gauge full, one frame, then the lift")
	var takes_progress := false
	for m in (load("res://scripts/dungeon/dungeon_world.gd") as GDScript).get_script_method_list():
		if m.name == "build":
			for a in m.args:
				if a.name == "progress":
					takes_progress = true
	_check(takes_progress, "DungeonWorld.build takes a progress callable")

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)
