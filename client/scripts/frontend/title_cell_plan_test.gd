extends SceneTree

## Round 680: the title preloads its whole scene (TitleCellPlan) and the
## camera does not move until it is built -- the user's "preload the scene
## entirely" against pop-in.
##   - the plan holds every cell any moment of the path needs: the region
##     window around the camera's target, sampled five times more densely
##     than the plan samples it; and, with a draw distance, every cell
##     Godot's own Camera3D frustum meets at that distance;
##   - its cells are the region grid's (RegionGridState.cell_at), first
##     needed first;
##   - TitleIntro: the first view alone does not start the fly, the whole
##     scene does; a scene held by Connect is never flown; a scene that
##     takes longer than SCENE_TIMEOUT_S is flown anyway.
## Synthetic keyframes only (ours).
##
## NEGATIVE: before round 680 there is no TitleCellPlan and no scene_ready --
## this suite does not parse; and round 678's TitleIntro flew on the first
## view (`_on_first_view_ready` set FLYING).

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

static func kf(t: float, pos: Vector3, pitch: float, yaw: float, dist: float) -> IntroScript.Keyframe:
	var k := IntroScript.Keyframe.new()
	k.time = t
	k.pos = pos
	k.pitch = pitch
	k.yaw = yaw
	k.distance = dist
	return k

func _initialize() -> void:
	# A synthetic fly: out of the frame region to the south-west, turning,
	# then climbing -- four regions crossed, as roc's path does.
	var keys := [
		kf(0.0, Vector3(900.0, 120.0, 900.0), 0.10, 3.80, 100.0),
		kf(3.0, Vector3(-600.0, 150.0, -400.0), 0.00, 4.40, 90.0),
		kf(6.0, Vector3(-1500.0, 400.0, -2600.0), -0.20, 2.90, 100.0),
		kf(9.0, Vector3(-900.0, 900.0, -4300.0), -0.35, 3.10, 60.0),
		kf(10.0, Vector3(-700.0, 1100.0, -5100.0), -0.40, 3.20, 100.0),
	]
	var path := IntroCameraPath.from_keyframes(keys)

	# --- the cells are the region grid's ---
	for p in [Vector3(10, 0, 10), Vector3(-10, 0, 10), Vector3(1930, 5, -1), Vector3(-3900, 0, -5000)]:
		var grid := RegionGridState.cell_at(Vector3(p.x, p.y, -p.z))
		_check(TitleCellPlan.cell_of(p) == grid, "cell_of(%s) = %s is the grid's cell_at of its world position (%s)" % [p, TitleCellPlan.cell_of(p), grid])

	# --- the window plan covers every sample's window, sampled 5x denser ---
	var window := TitleCellPlan.window_cells(path, 1)
	var missing := 0
	var t := 0.0
	while t <= path.length:
		var c := TitleCellPlan.cell_of(path.sample(t).target)
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				if not window.has(c + Vector2i(dx, dy)):
					missing += 1
		t += TitleCellPlan.SAMPLE_STEP_S / 5.0
	_check(missing == 0, "the window plan holds the 3x3 window of every sample at %.3f s (%d cell(s), %d missing)" % [
		TitleCellPlan.SAMPLE_STEP_S / 5.0, window.size(), missing])
	_check(window.size() >= 9 + 3 * 3, "the fly crosses regions, so the plan is more than one window (%d cells)" % window.size())
	_check(window[0] == TitleCellPlan.cell_of(keys[0].pos), "the first cell built is the one under the fly's opening target (%s)" % window[0])
	var dup := {}
	for c in window:
		dup[c] = true
	_check(dup.size() == window.size(), "no cell is planned twice")

	# --- the frustum plan, against Godot's own Camera3D frustum ---
	var draw := 2500.0
	var full := TitleCellPlan.cells(path, 1, draw)
	# A 21:9-ish window (2.3), the widest the plan is meant to cover: the
	# camera in a SubViewport of that shape (the headless root's is fixed).
	var vp := SubViewport.new()
	vp.size = Vector2i(2300, 1000)
	root.add_child(vp)
	var cam := Camera3D.new()
	vp.add_child(cam)
	# The tree is live only once the first frame runs (get_frustum needs it).
	await process_frame
	cam.fov = IntroCameraPath.FOV_Y_DEGREES
	cam.near = TitleCellPlan.NEAR
	cam.far = draw
	var aspect := float(vp.size.x) / float(vp.size.y)
	var seen_missing := 0
	var tested := 0
	t = 0.0
	while t <= path.length:
		cam.global_transform = TitleCellPlan.camera_transform(path.sample(t))
		var planes := cam.get_frustum()
		var eye := TitleCellPlan.cell_of(Vector3(cam.global_position.x, 0, -cam.global_position.z))
		for dx in range(eye.x - 3, eye.x + 4):
			for dy in range(eye.y - 3, eye.y + 4):
				var c := Vector2i(dx, dy)
				if TitlePopProbe.aabb_in_frustum(TitleCellPlan.cell_box(c), planes):
					tested += 1
					if not full.has(c):
						seen_missing += 1
		t += TitleCellPlan.SAMPLE_STEP_S / 5.0
	_check(tested > 0 and seen_missing == 0, "every cell Godot's frustum (aspect %.2f, far %.0f) meets at any moment is planned (%d cell views, %d missing; plan %d cells)" % [
		aspect, draw, tested, seen_missing, full.size()])
	for c in window:
		if not full.has(c):
			seen_missing += 1
	_check(seen_missing == 0, "the frustum plan holds the window plan too")
	vp.free()

	# --- TitleIntro: the fly waits for the whole scene ---
	var intro := TitleIntro.new()
	var stub := StubBackdrop.new()
	intro.path = path
	intro.backdrop = stub
	intro.state = TitleIntro.State.LOADING
	intro._on_first_view_ready()
	_check(intro.state == TitleIntro.State.LOADING, "the first view alone does not start the fly (round 678 flew here)")
	stub.pending = 0
	intro._on_scene_ready()
	_check(intro.state == TitleIntro.State.FLYING, "the whole scene built: the camera flies")
	_check(is_zero_approx(intro.path.time), "and the path starts at its beginning")

	var held := TitleIntro.new()
	held.path = IntroCameraPath.from_keyframes(keys)
	held.backdrop = stub
	held.state = TitleIntro.State.LOADING
	held.hold_backdrop("the test's Connect")
	held._on_first_view_ready()
	held._on_scene_ready()
	_check(held.state == TitleIntro.State.LOADING, "a scene held by Connect before it was built is not flown")

	var slow := TitleIntro.new()
	slow.path = IntroCameraPath.from_keyframes(keys)
	slow.backdrop = stub
	slow.state = TitleIntro.State.LOADING
	slow._on_first_view_ready()
	slow._process(TitleIntro.FIRST_VIEW_TIMEOUT_S + 1.0)
	_check(slow.state == TitleIntro.State.LOADING, "with the first view in, the scene is waited for past the first-view timeout")
	slow._process(TitleIntro.SCENE_TIMEOUT_S)
	_check(slow.state == TitleIntro.State.FLYING, "past SCENE_TIMEOUT_S it flies anyway, the rest building during the fly")

	intro.free()
	held.free()
	slow.free()
	stub.free()

	await _review_checks(keys)
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit()

## Round 680's review: a custom intro's plan is bounded, cheap and
## cancellable; Connect during PRELOADING builds nothing.
func _review_checks(keys: Array) -> void:
	# --- the forward walk is the same path ---
	var path := IntroCameraPath.from_keyframes(keys)
	var walker := IntroCameraPath.from_keyframes(keys)
	var worst := 0.0
	var times: Array = []
	var t := -0.5
	while t <= path.length + 0.5:
		times.append(t)
		t += 0.037
	times.append(2.0) # backwards: the walk starts over
	times.append(9.99)
	for tt in times:
		var a := path.sample(tt)
		var b := walker.sample_forward(tt)
		worst = maxf(worst, a.target.distance_to(b.target) + absf(a.pitch - b.pitch) + absf(a.yaw - b.yaw)
			+ absf(a.roll - b.roll) + absf(a.distance - b.distance))
	_check(worst == 0.0, "sample_forward gives sample's pose exactly, forward and after a step back (worst %.9f)" % worst)

	# --- a straight line far past the cap stops at cap + 1 ---
	var line := IntroCameraPath.from_keyframes([
		kf(0.0, Vector3(900, 100, 900), 0.1, 0.0, 100.0),
		kf(600.0, Vector3(900 + 40 * 1920.0, 100, 900), 0.1, 0.0, 100.0)])
	var full_line := TitleCellPlan.window_cells(line, 1)
	var capped := TitleCellPlan.window_cells(line, 1, TitleCellPlan.SAMPLE_STEP_S, TitleCellPlan.PLAN_MAX_CELLS)
	_check(full_line.size() > 3 * TitleCellPlan.PLAN_MAX_CELLS and capped.size() > TitleCellPlan.PLAN_MAX_CELLS
			and capped.size() <= TitleCellPlan.PLAN_MAX_CELLS + 9,
		"a 40-region line plans %d cells; with the cap the walk stops in the sample that passes it, at %d (PLAN_MAX_CELLS %d, one window more at most)" % [
		full_line.size(), capped.size(), TitleCellPlan.PLAN_MAX_CELLS])
	_check(TitleCellPlan.PLAN_MAX_CELLS >= 28, "the cap holds the archive's largest plan (28 cells)")

	# --- the walk's cost: 1024 keys over 600 s, O(samples + keys) ---
	var many: Array = []
	for i in range(1024):
		many.append(kf(i * 600.0 / 1023.0, Vector3(900 + (i % 2) * 10.0, 100, 900), 0.1, 0.0, 100.0))
	var long_path := IntroCameraPath.from_keyframes(many)
	var sw := Time.get_ticks_msec()
	var still := TitleCellPlan.window_cells(long_path, 1)
	var ms := Time.get_ticks_msec() - sw
	_check(still.size() == 9 and ms < 5000, "a 1024-key, 600 s path plans its 9 cells in %d ms (under 5 s; the key search per sample made it O(samples x keys))" % ms)

	# --- TitleIntro: past the cap the plan is dropped and the title streams ---
	var capped_intro := TitleIntro.new()
	capped_intro._start_plan([
		kf(0.0, Vector3(900, 100, 900), 0.1, 0.0, 100.0),
		kf(600.0, Vector3(900 + 40 * 1920.0, 100, 900), 0.1, 0.0, 100.0)])
	var waited := 0
	while not capped_intro._plan_done() and waited < 600:
		await process_frame
		waited += 1
	_check(capped_intro._plan_over_cap and capped_intro.plan.is_empty(),
		"a plan past PLAN_MAX_CELLS is not preloaded (over cap %s, plan %d cells): round 678's streaming instead" % [
		str(capped_intro._plan_over_cap), capped_intro.plan.size()])
	capped_intro.free()

	# --- leaving during a big plan does not wait it out ---
	var sweep: Array = []
	for i in range(1024):
		sweep.append(kf(i * 3600.0 / 1023.0, Vector3(900 + (i % 32) * 1920.0, 100, 900 + int(i / 32.0) * 1920.0), 0.1, 0.0, 100.0))
	var leaving := TitleIntro.new()
	leaving._start_plan(sweep, 1 << 30) # as if uncapped: minutes of work
	await process_frame
	sw = Time.get_ticks_msec()
	leaving._exit_tree()
	ms = Time.get_ticks_msec() - sw
	_check(ms < 200 and leaving._plan_task == -1, "leaving the screen during a big plan returns in %d ms (cancelled, not waited out)" % ms)
	leaving.free()

	# --- Connect during PRELOADING: nothing is built ---
	var early := TitleIntro.new()
	early.path = IntroCameraPath.from_keyframes(keys)
	early.state = TitleIntro.State.PRELOADING
	early.hold_backdrop("the test's early Connect")
	early._process(0.1)
	_check(early.backdrop == null and early.state == TitleIntro.State.PRELOADING,
		"Connect before the world's scene is ready: no backdrop is begun (backdrop %s, state %d)" % [early.backdrop, early.state])
	early.free()

## A backdrop with no world: only the counts TitleIntro reads.
class StubBackdrop extends FrontEndBackdrop:
	var pending := 5
	func cells_loaded() -> int:
		return 3
	func cells_pending() -> int:
		return pending
