extends Node
class_name TitleIntro

## The title screen's intro (round 678): the theme's (or option.txt's) intro
## script flown over a FrontEndBackdrop, the letterbox frame's fades, and the
## login window faded in when the path ends or the player clicks or presses a
## key -- what CPSTitle does (READ, docs/protocol/intro_script.md):
##
##   OnCreate (0x86b190): a random hour -- rand() & 3 (0x86b278) picks
##     0.2083333, 0.5833333, 0.75 or 0.9583333 (the floats at 0xdd8ef4,
##     0xdd8ef0, 0xdd8eec, 0xdd8ee8: 5, 14, 18 and 23 o'clock over 24) for
##     SWorld::vslot_020, the day phase the environment is read at; the
##     camera on the intro's LAST keyframe (FUN_0056be40) in its region
##     (FUN_004fb510); the black covers (windows 3, 4) at alpha 255; the
##     title music; then, with +0xe8 == 0, FUN_00869b50 -- the fly.
##   FUN_00869b50, the fly: the title text (5), logo (8), login window (9),
##     Connect (11) and Exit (12) hidden; the big logo (7) faded 0 -> 255 over
##     3.0 s starting 15.0 s in (FUN_006526e0(0, 0xff, 3.0, -15.0), the
##     floats at 0xd8adc4 and 0xdd81c8); the keyframes loaded into the path.
##   CPSTitle::vslot_012, each frame: the path advanced by the frame's time
##     and copied to the camera while its length is non-zero; once the
##     path's clock equals its length and the login is not up yet,
##     FUN_00865630.
##   FUN_00865630, the login: covers 3 and 4 and the big logo faded to 0, the
##     title text to 255, over 0.5 s (the float at 0xe1b7e0), then
##     CPSTitle::FUN_00864870 fades the logo, the login window, Connect and
##     Exit to 255 over 0.5 s; +0xe4 = 1. The camera keeps flying to the end.
##   A left button press (vslot_017: message 0x201, while +0xe4 == 0) or any
##     key (FUN_0086ae50, its first test, for every key) calls
##     FUN_00865630 early: the skip.
##
## OURS around that: the theme decides the intro (FrontEndTheme); the clock
## starts once the backdrop's whole scene is built (round 680: every cell
## the camera's path needs, TitleCellPlan -- the user's "preload the scene
## entirely" against pop-in), a 2D still covering the load until then
## (retail loads its regions at startup, before the title exists:
## FUN_00840670 -> CGWorld::FUN_00aa2190, READ, TitleCellPlan's header); a
## click or key during that load brings the login in at once, as during the
## fly, and the scene keeps loading behind it; a script, archive or region
## that cannot back a 3D intro leaves the still up and brings the login
## window in at once, with the reason in the log.

signal login_shown
## The intro could not run; the 2D still stays (why, for the log).
signal fell_back(why: String)

## READ: the four title hours as day phases (see the header).
const TITLE_PHASES := [0.2083333283662796, 0.5833333134651184, 0.75, 0.9583333134651184]
const BIG_LOGO_FADE_S := 3.0 # READ, 0xd8adc4
const BIG_LOGO_DELAY_S := 15.0 # READ, -(-15.0) at 0xdd81c8
const LOGIN_FADE_S := 0.5 # READ, 0xe1b7e0
## OURS: the region window at the title (World3D.title_begin).
const TITLE_RADIUS := 1
## OURS: how long the title waits for its first region before giving up
## on the 3D intro and showing the login on the still.
const FIRST_VIEW_TIMEOUT_S := 30.0
## OURS (round 680): how long the title waits for its WHOLE scene, once the
## first view is in, before it flies anyway -- a slow disk must not hold the
## still up for good; the cells still queued then build during the fly
## (and may pop, as round 678's did), with a log line saying how many.
const SCENE_TIMEOUT_S := 60.0
## OURS (round 680): the planned scene is the union of the region window
## (TITLE_RADIUS) around every sample of the path -- the cells round 678's
## streaming would have built at some point of the fly, all built first.
## A distance > 0 adds every cell the view frustum meets within it
## (TitleCellPlan); 0 keeps the scene to the window, which costs least --
## the measured trade-off is in the round 680 WORLD_ISSUES entry.
## SRREVAMP_QA_TITLE_DRAW=<units> overrides it for a measurement.
const PLAN_DRAW_DISTANCE := 0.0
## OURS: the still's fade-out once the 3D view is ready.
const STILL_FADE_S := 0.5

enum State { IDLE, PRELOADING, LOADING, FLYING, FALLBACK }

var state := State.IDLE
var login_up := false
var parsed: IntroScript.Parsed = null
var path: IntroCameraPath = null
var backdrop: FrontEndBackdrop = null
var intro_source := ""
var _origin := Vector2i(-1, -1)
var day_phase := 0.5
var _frame: FrontEndFrame = null
var _still: CanvasItem = null
var _login_nodes: Array = []
var _started_ms := 0
var _loading_s := 0.0
## The scene plan (TitleCellPlan), computed on a worker while the world's
## scene compiles; the task id until it is done, then -1. Empty when the
## plan passed TitleCellPlan.PLAN_MAX_CELLS: the backdrop then streams.
var plan: Array[Vector2i] = []
var _plan_task := -1
var _plan_job: PlanJob = null
var _plan_ms := 0.0
var _plan_over_cap := false

## The scene plan's worker job (round 680's review): it owns its own copy of
## the path and its result, so nothing on the worker touches this node --
## the screen can go while it runs, `cancel` ending it at its next sample.
class PlanJob extends RefCounted:
	var path: IntroCameraPath = null
	var radius := 1
	var draw := 0.0
	var max_cells := TitleCellPlan.PLAN_MAX_CELLS
	var cancel := false
	var cells: Array[Vector2i] = []
	var over_cap := false
	var ms := 0.0

	func run() -> void:
		var sw := Time.get_ticks_usec()
		var stop := func() -> bool: return cancel
		if draw > 0.0:
			cells = TitleCellPlan.cells(path, radius, draw, TitleCellPlan.MIN_ASPECT, TitleCellPlan.SAMPLE_STEP_S, max_cells, stop)
		else:
			cells = TitleCellPlan.window_cells(path, radius, TitleCellPlan.SAMPLE_STEP_S, max_cells, stop)
		over_cap = cells.size() > max_cells
		ms = (Time.get_ticks_usec() - sw) / 1000.0
var _first_view := false
## Connect was pressed (hold_backdrop): the scene stops loading for good.
var _held := false
var _qa_skip_at := -1.0
var _qa_shots: PackedFloat32Array = PackedFloat32Array()
## SRREVAMP_QA_TITLE_SEEK=<t,t,...> (OURS, QA): instead of flying, stand the
## camera at each time in turn, wait for the window's cells, and print a
## `QA TITLE SHOT` line naming the frame -- a render's few viewpoints
## without recording the whole flight.
var _qa_seek: PackedFloat32Array = PackedFloat32Array()
var _qa_seek_frames := 0
var _qa_login_shot := false
## SRREVAMP_QA_TITLE_POPS (round 680, QA): the pop-in measurement.
var _pop_probe: TitlePopProbe = null
## The archive's logo held back while the 2D still (which carries its own)
## is up.
var _logo_waiting := false
## Round 679: set while the server list is open (it hides the logo); a
## reveal that comes due then waits for release_logo().
var logo_held := false

## Picks the intro and starts loading its backdrop. `login_nodes` are the
## login window's pieces in FUN_00864870's order (logo first). Returns false
## and emits fell_back when there is no 3D intro to fly.
func start(media: Pk2Reader, theme: FrontEndTheme, custom_dir: String, frame: FrontEndFrame, still: CanvasItem, login_nodes: Array) -> bool:
	_started_ms = Time.get_ticks_msec()
	_frame = frame
	_still = still
	_login_nodes = login_nodes
	var qa_skip := OS.get_environment("SRREVAMP_QA_TITLE_SKIP_AT")
	if qa_skip != "":
		_qa_skip_at = qa_skip.to_float()
	for part in OS.get_environment("SRREVAMP_QA_TITLE_SHOTS").split(",", false):
		_qa_shots.append(part.to_float())
	for part in OS.get_environment("SRREVAMP_QA_TITLE_SEEK").split(",", false):
		_qa_seek.append(part.to_float())
	if TitlePopProbe.enabled():
		_pop_probe = TitlePopProbe.new()
	# The fly's opening state (FUN_00869b50), whatever happens next.
	if _frame != null:
		_frame.set_alpha(_frame.cover_top, 255)
		_frame.set_alpha(_frame.cover_bottom, 255)
		_frame.set_alpha(_frame.title_art, 0)
		_frame.set_alpha(_frame.big_logo, 0)
		if _frame.copyright_label != null:
			_frame.set_alpha(_frame.copyright_label, 0)
	for n in _login_nodes:
		_hide_login_node(n)
	var picked := resolve_intro(media, theme.intro if theme != null else "", custom_dir)
	if not picked.has("parsed"):
		return _fall_back(str(picked.get("error", "no intro")))
	parsed = picked["parsed"]
	intro_source = picked["source"]
	if not IntroScript.single_region(parsed):
		print("TITLE: %s's keyframes name more than one region -- the path uses the last one's, as retail's does" % intro_source)
	var origin := IntroScript.origin_region(parsed)
	path = IntroCameraPath.from_keyframes(parsed.keyframes)
	day_phase = pick_day_phase()
	print("TITLE: intro %s -- %d keyframe(s), %.1f s, region %d/%d%s; %d [SCRIPT] line(s) not run (OPEN); title hour phase %.4f" % [
		intro_source, parsed.keyframes.size(), path.length, origin.x, origin.y,
		", AREA=%s not built (OPEN)" % parsed.area if parsed.area != "" else "",
		parsed.script_lines.size(), day_phase])
	_origin = origin
	state = State.PRELOADING
	FrontEndBackdrop.preload_world()
	_start_plan(parsed.keyframes)
	return true

## Starts the scene plan on a worker (PlanJob), over its own copy of the path.
func _start_plan(keyframes: Array, max_cells: int = TitleCellPlan.PLAN_MAX_CELLS) -> void:
	_plan_job = PlanJob.new()
	_plan_job.max_cells = max_cells
	_plan_job.path = IntroCameraPath.from_keyframes(keyframes)
	_plan_job.radius = TITLE_RADIUS
	_plan_job.draw = PLAN_DRAW_DISTANCE
	var qa := OS.get_environment("SRREVAMP_QA_TITLE_DRAW")
	if qa != "" and qa.is_valid_float():
		_plan_job.draw = qa.to_float()
	_plan_task = WorkerThreadPool.add_task(_plan_job.run, true, "title scene plan")

## Whether the plan's task has finished (and been disposed of); its result
## is in `plan` then -- empty when it passed the cap.
func _plan_done() -> bool:
	if _plan_task < 0:
		return true
	if not WorkerThreadPool.is_task_completed(_plan_task):
		return false
	WorkerThreadPool.wait_for_task_completion(_plan_task)
	_plan_task = -1
	_plan_ms = _plan_job.ms
	_plan_over_cap = _plan_job.over_cap
	plan.clear()
	if not _plan_over_cap:
		plan.assign(_plan_job.cells)
	return true

## Ends a plan still computing without blocking on it: the job stops at its
## next sample (microseconds), then the task is disposed of.
func _cancel_plan() -> void:
	if _plan_task < 0:
		return
	_plan_job.cancel = true
	WorkerThreadPool.wait_for_task_completion(_plan_task)
	_plan_task = -1

## The world's scene has loaded (FrontEndBackdrop.preload_world): build the
## backdrop and point it where the fly begins.
func _begin_backdrop() -> void:
	var origin := _origin
	backdrop = FrontEndBackdrop.new()
	backdrop.name = "TitleBackdrop"
	add_child(backdrop)
	print("TITLE: world scene ready at %d ms" % (Time.get_ticks_msec() - _started_ms))
	if _plan_over_cap:
		print("TITLE: the scene plan passed %d cells (computed in %.1f ms on a worker) -- not preloaded; round 678's window streams instead, unloading as it goes, and may pop" % [
			TitleCellPlan.PLAN_MAX_CELLS, _plan_ms])
	else:
		print("TITLE: scene plan -- %d cell(s) for the whole path, computed in %.1f ms on a worker" % [plan.size(), _plan_ms])
	if not backdrop.begin(origin, TITLE_RADIUS, day_phase, plan):
		backdrop.queue_free()
		backdrop = null
		_fall_back("the backdrop for region %d/%d could not start" % [origin.x, origin.y])
		return
	# READ: retail's camera stands on the last keyframe until the path's
	# first frame (OnCreate, FUN_0056be40). Here that pose would never be
	# seen -- the still covers the load and the path starts on its first
	# view -- so the region window is pointed at where the fly BEGINS
	# (OURS): loading the last keyframe's regions first would build the
	# wrong end of the path while the player waits.
	backdrop.show_pose(path.sample(0.0))
	backdrop.first_view_ready.connect(_on_first_view_ready, CONNECT_ONE_SHOT)
	backdrop.scene_ready.connect(_on_scene_ready, CONNECT_ONE_SHOT)
	state = State.LOADING

## The intro's parsed script and where it came from, or {"error": why}: the
## named intro (custom/intro/<name>.txt first, then Media.pk2's
## script\intro), else option.txt's IntroName (READ: retail's only choice),
## each failure logged.
static func resolve_intro(media: Pk2Reader, name: String, custom_dir: String) -> Dictionary:
	var tried := PackedStringArray()
	if name != "":
		var custom := FrontEndTheme.custom_intro_path(custom_dir, name)
		if custom != "":
			var p := IntroScript.parse(FileAccess.get_file_as_bytes(custom))
			if p.ok():
				return {"parsed": p, "source": "custom " + custom}
			print("TITLE: custom intro %s did not parse (%s) -- trying the archive" % [custom, p.error])
			tried.append(custom)
		var archive_path := FrontEndTheme.archive_intro_path(name)
		if archive_path == "":
			print("TITLE: intro name '%s' is not acceptable -- option.txt's IntroName instead" % name)
		else:
			var got := _parse_from_archive(media, archive_path)
			if got.has("parsed"):
				return got
			print("TITLE: intro '%s' -- %s -- option.txt's IntroName instead" % [name, got["error"]])
			tried.append(archive_path)
	var option_name := option_intro_name(media)
	if option_name == "":
		return {"error": "option.txt names no IntroName (tried: %s)" % ", ".join(tried)}
	var fallback := _parse_from_archive(media, option_name)
	if fallback.has("parsed"):
		fallback["source"] = str(fallback["source"]) + " (option.txt)"
	return fallback

static func _parse_from_archive(media: Pk2Reader, archive_path: String) -> Dictionary:
	if media == null:
		return {"error": "no Media.pk2"}
	var entry := ObjectLoader.find_file(media, archive_path)
	if entry == null:
		return {"error": "%s is not in Media.pk2" % archive_path}
	var p := IntroScript.parse(media.read_file(entry))
	if not p.ok():
		return {"error": "%s did not parse (%s)" % [archive_path, p.error]}
	return {"parsed": p, "source": "Media.pk2 " + archive_path}

## option.txt's IntroName (READ: the client's own choice), or "".
static func option_intro_name(media: Pk2Reader) -> String:
	if media == null:
		return ""
	var entry := ObjectLoader.find_file(media, EnvSoundTable.OPTION_PATH)
	if entry == null:
		return ""
	return IntroScript.parse_option_intro_name(media.read_file(entry))

## READ: rand() & 3 over the four phases. SRREVAMP_QA_TITLE_HOUR=<0..3>
## pins it for a render (OURS).
static func pick_day_phase() -> float:
	var pinned := OS.get_environment("SRREVAMP_QA_TITLE_HOUR")
	if pinned != "" and pinned.is_valid_int():
		return TITLE_PHASES[clampi(pinned.to_int(), 0, 3)]
	return TITLE_PHASES[randi() & 3]

## The skip: a click or a key while the login is not up yet (READ).
func skip(why: String) -> void:
	if login_up:
		return
	print("TITLE: skipped by %s at %d ms (path %.2f / %.2f s)" % [why, Time.get_ticks_msec() - _started_ms,
		path.time if path != null else 0.0, path.length if path != null else 0.0])
	show_login()

## FUN_00865630 + FUN_00864870: the covers, big logo and title, then the
## login window (READ).
func show_login() -> void:
	if login_up:
		return
	login_up = true
	if _frame != null:
		_frame.fade(_frame.cover_top, _alpha(_frame.cover_top), 0, LOGIN_FADE_S)
		_frame.fade(_frame.cover_bottom, _alpha(_frame.cover_bottom), 0, LOGIN_FADE_S)
		_frame.fade(_frame.big_logo, _alpha(_frame.big_logo), 0, LOGIN_FADE_S)
		_frame.fade(_frame.title_art, _alpha(_frame.title_art), 255, LOGIN_FADE_S)
		# The operator's line comes in with the band art it sits on (round
		# 678's review: it showed over the black covers during the fly).
		if _frame.copyright_label != null and _frame.copyright_label.text != "":
			_frame.copyright_label.visible = true
			_frame.fade(_frame.copyright_label, _alpha(_frame.copyright_label), 255, LOGIN_FADE_S)
	for n in _login_nodes:
		if _frame != null and n == _frame.logo and _still_covers():
			# The 2D still has the logo in its own art (round 678's review):
			# the archive's logo is not drawn over it -- an operator's is.
			_logo_waiting = true
			continue
		_show_login_node(n)
	print("TITLE: login window shown at %d ms" % (Time.get_ticks_msec() - _started_ms))
	login_shown.emit()

## Whether the 2D still is (still) what the player sees, and the logo
## drawn now would be the archive's over the still's own.
func _still_covers() -> bool:
	return _still != null and _still.visible and _still.modulate.a > 0.0 and _still.get_child_count() > 1 \
		and state != State.FLYING and not (_frame != null and _frame.custom_logo)

## Round 679: the server list closed -- the logo's held reveal, if it came
## due meanwhile.
func release_logo() -> void:
	logo_held = false
	if _logo_waiting and _frame != null and not _still_covers():
		_logo_waiting = false
		_show_login_node(_frame.logo)

## Stops the backdrop from starting new cells (the screen is about to be
## left: Connect was pressed). Round 678's review: leaving waited ~0.8 s for
## cells still preparing.
func hold_backdrop(why: String) -> void:
	_held = true
	_cancel_plan()
	if backdrop != null and backdrop.world != null:
		backdrop.world.call("title_hold")
		print("TITLE: backdrop holds its cells (%s)" % why)

func _alpha(n: CanvasItem) -> int:
	return int(roundf(n.modulate.a * 255.0)) if n != null else 0

func _hide_login_node(n: Control) -> void:
	n.modulate.a = 0.0
	n.visible = false

func _show_login_node(n: Control) -> void:
	n.visible = true
	if _frame != null:
		_frame.fade(n, _alpha(n), 255, LOGIN_FADE_S)
	else:
		n.modulate.a = 1.0

## A plan still computing when the screen goes is cancelled, not waited
## out (round 680's review: a custom path planned for 7.9 s).
func _exit_tree() -> void:
	_cancel_plan()

func _fall_back(why: String) -> bool:
	state = State.FALLBACK
	print("TITLE: no 3D intro -- %s; the 2D still stays and the login comes in at once" % why)
	fell_back.emit(why)
	show_login()
	return false

func _on_first_view_ready() -> void:
	_first_view = true

## The whole planned scene is built: the camera may move (round 680).
func _on_scene_ready() -> void:
	_start_flying("the whole scene is built")

func _start_flying(why: String) -> void:
	if state != State.LOADING:
		return
	if _held:
		# Connect stopped the load before the scene was whole (round 680):
		# a part-built scene is not flown -- the still stays, as the screen
		# is about to be left.
		print("TITLE: the scene was held before it was built (%d cell(s) built) -- the still stays" % backdrop.cells_loaded())
		return
	state = State.FLYING
	print("TITLE: flying from %d ms (load %.2f s; %s; %d cell(s) built, %d pending)" % [
		Time.get_ticks_msec() - _started_ms, _loading_s, why, backdrop.cells_loaded(), backdrop.cells_pending()])
	if _still != null and _frame != null:
		_frame.fade(_still, _alpha(_still), 0, STILL_FADE_S)
	elif _still != null:
		_still.visible = false
	if _logo_waiting and _frame != null and not logo_held:
		_logo_waiting = false
		_show_login_node(_frame.logo)
	# READ, FUN_00869b50: the big logo's slow fade-in, unless the login is up.
	if _frame != null and not login_up:
		_frame.fade(_frame.big_logo, 0, 255, BIG_LOGO_FADE_S, BIG_LOGO_DELAY_S)

func _process(delta: float) -> void:
	var since_s := (Time.get_ticks_msec() - _started_ms) / 1000.0
	if _qa_skip_at >= 0.0 and since_s >= _qa_skip_at and not login_up:
		_qa_skip_at = -1.0
		skip("SRREVAMP_QA_TITLE_SKIP_AT")
	match state:
		State.PRELOADING:
			_loading_s += delta
			# Connect before the world's scene was ready (round 680's
			# review): the screen is about to go -- nothing is built.
			if not _held and FrontEndBackdrop.world_loaded() and _plan_done():
				_begin_backdrop()
		State.LOADING:
			_loading_s += delta
			if not _first_view and _loading_s > FIRST_VIEW_TIMEOUT_S:
				_fall_back("no region built within %.0f s" % FIRST_VIEW_TIMEOUT_S)
			elif _first_view and not _held and _loading_s > SCENE_TIMEOUT_S:
				_start_flying("the scene was not built within %.0f s -- the rest builds during the fly" % SCENE_TIMEOUT_S)
		State.FLYING:
			if not _qa_seek.is_empty():
				_qa_seek_step()
			elif path.length != 0.0:
				var before := path.time
				var pose := path.advance(delta)
				backdrop.show_pose(pose)
				for t in _qa_shots:
					if before < t and path.time >= t:
						print("QA TITLE SHOT t=%.2f frame %d" % [t, Engine.get_frames_drawn()])
			if not login_up and path.finished():
				print("TITLE: the path ended (%.2f s)" % path.length)
				show_login()
	if _pop_probe != null and backdrop != null and backdrop.world != null and path != null:
		_pop_probe.tick(backdrop.world, backdrop.camera(), path.time, state == State.FLYING, Time.get_ticks_msec() - _started_ms)
		if state == State.FLYING and path.finished():
			_pop_probe.summary(intro_source, path.time, get_tree())
	if login_up and not _qa_login_shot and _qa_seek.is_empty() and _frame != null and _frame.fades_running() == 0 \
			and (OS.get_environment("SRREVAMP_QA_TITLE_SKIP_AT") != "" or OS.get_environment("SRREVAMP_QA_TITLE_SEEK") != ""):
		_qa_login_shot = true
		print("QA LOGIN SHOT frame %d" % Engine.get_frames_drawn())

func _qa_seek_step() -> void:
	var t := _qa_seek[0]
	if _qa_seek_frames == 0:
		path.time = minf(t, path.length)
		backdrop.show_pose(path.sample(path.time))
	_qa_seek_frames += 1
	if _qa_seek_frames >= 30 and backdrop.cells_pending() == 0:
		var pose := path.sample(path.time)
		print("QA TITLE SHOT t=%.2f frame %d target (%.1f, %.1f, %.1f) pitch %.3f yaw %.3f dist %.1f cells %d" % [
			t, Engine.get_frames_drawn(), pose.target.x, pose.target.y, pose.target.z, pose.pitch, pose.yaw,
			pose.distance, backdrop.cells_loaded()])
		_qa_seek.remove_at(0)
		_qa_seek_frames = 0
		if _qa_seek.is_empty():
			print("QA TITLE SEEK done")
			skip("the end of SRREVAMP_QA_TITLE_SEEK")
