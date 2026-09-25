extends SceneTree

## Exercises LoadTimings -- the per-cell, per-phase and per-frame load
## record World3D prints (round 561) -- run headless:
## `godot4 --headless --path client --script res://scripts/world/load_timings_test.gd`
##
## What is held to account is the arithmetic and the wording the benchmark
## greps for (client/tools/README.md, "Load benchmark"): a cell's line from
## its groups and sub-phases, a cell with nothing in it, the drain totals
## and their reset, and the frame record -- that the longest frame is the
## longest and not the last (a note_frame that overwrote would pass a
## one-frame check and fails here), that one frame's notes add up and keep
## the cell's label, the p95, the hitch count, the wall gap, and the window
## a summary closes while the run's longest stands. And, from World3D.gd's
## own source (round 564), that the terrain laps are exhaustive and the
## README's cell-line template names them -- since round 565 across the
## job, the prepare and the commit -- and that work done off the main thread
## (LoadTimings.offthread, round 565) is on the cell line but in no frame's
## work.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _test_cell_line() -> void:
	var t := LoadTimings.new()
	t.begin_cell(97, 169)
	t.group("terrain", 310_000)
	t.phase("terrain", "read", 12_000)
	t.phase("terrain", "parse", 88_000)
	t.group("objects", 180_000)
	t.phase("objects", "templates", 70_000)
	t.phase("objects", "templates", 50_000) # a second build adds up
	t.group("npcs", 22_000)
	var line := t.end_cell(88)
	_check(line == "World3D: cell 97/169 built in 512 ms at frame 88 (terrain 310 [read 12, parse 88], objects 180 [templates 120], npcs 22)",
		"the cell line: groups in order, sub-phases in brackets, repeats summed (got: %s)" % line)
	_check(t.cells == 1 and is_equal_approx(t.total_ms("terrain"), 310.0)
		and is_equal_approx(t.total_ms("objects"), 180.0) and is_equal_approx(t.total_ms("npcs"), 22.0),
		"the drain totals took the cell (%d cells, terrain %.1f objects %.1f npcs %.1f)" % [
			t.cells, t.total_ms("terrain"), t.total_ms("objects"), t.total_ms("npcs")])
	_check(t.cell_work_usec == 512_000, "cell_work_usec is the cell's whole time (got %d)" % t.cell_work_usec)

func _test_empty_cell() -> void:
	var t := LoadTimings.new()
	t.phase("terrain", "read", 5_000) # no cell open: dropped
	t.begin_cell(1, 2)
	var line := t.end_cell(5)
	_check(line == "World3D: cell 1/2 built in 0 ms at frame 5", "a cell with no phases: 0 ms (got: %s)" % line)
	_check(not line.contains("["), "... and no bracket list")
	_check(t.end_cell(6) == "", "end_cell with no cell open returns nothing")
	_check(t.cells == 1 and t.total_ms("terrain") == 0.0, "the dropped phase reached no total")

func _test_lap_and_phase_usec() -> void:
	var t := LoadTimings.new()
	t.begin_cell(3, 4)
	var since := Time.get_ticks_usec() - 5_000
	var now := t.lap("terrain", "mesh", since)
	_check(now >= since + 5_000, "lap returns now")
	_check(t.phase_usec("terrain", "mesh") >= 5_000, "lap recorded the time since (got %d usec)" % t.phase_usec("terrain", "mesh"))
	_check(t.phase_usec("terrain", "none") == 0 and t.phase_usec("nope", "x") == 0, "an unknown phase is 0")

func _test_begin_drain_resets_totals() -> void:
	var t := LoadTimings.new()
	for i in range(2):
		t.begin_cell(i, 0)
		t.group("terrain", 100_000)
		t.end_cell(i)
	_check(t.cells == 2 and is_equal_approx(t.total_ms("terrain"), 200.0), "two cells summed")
	t.begin_drain()
	_check(t.cells == 0 and t.total_ms("terrain") == 0.0, "begin_drain zeroes the grid totals")
	var s := t.summary()
	_check(s.ends_with("grid 0 cells terrain 0 objects 0 npcs 0 ms"), "... which the summary shows (got: %s)" % s)

## The NEGATIVE: an implementation that overwrote the longest frame with
## the latest would report 50 here.
func _test_longest_frame_is_kept() -> void:
	var t := LoadTimings.new()
	t.note_frame(300.0, 10, "cell 97/169")
	t.note_frame(50.0, 11, "")
	t.note_wall(10, 1_000_000)
	t.note_wall(11, 1_400_000)
	var s := t.summary()
	_check(s == "World3D: longest work frame 300 ms at frame 10 (cell 97/169) over 2 frames since the last summary; p95 300 ms; 1 over 100 ms; longest wall gap 400 ms at frame 11; run longest 300 ms at frame 10 (cell 97/169); grid 0 cells terrain 0 objects 0 npcs 0 ms",
		"a later, shorter frame does not replace the longest (got: %s)" % s)
	_check(t.longest_ms == 300.0 and t.longest_frame == 10 and t.longest_label == "cell 97/169" and t.hitches == 1,
		"the run record: 300 ms at frame 10, the cell, one hitch")

func _test_frame_notes_add_up_and_keep_the_label() -> void:
	var t := LoadTimings.new()
	t.note_frame(30.0, 20, "")
	t.note_frame(80.0, 20, "cell 1/1")
	t.note_frame(5.0, 20, "") # an empty label keeps the cell's
	t.note_frame(1.0, 21, "")
	var s := t.summary()
	_check(s.begins_with("World3D: longest work frame 115 ms at frame 20 (cell 1/1) over 2 frames"),
		"one frame's notes add up and keep the cell label (got: %s)" % s)

func _test_p95_and_window() -> void:
	var t := LoadTimings.new()
	for i in range(1, 101):
		t.note_frame(float(i), i, "")
	var s := t.summary()
	_check(s.contains("over 100 frames since the last summary; p95 95 ms; 0 over 100 ms;"),
		"p95 of 1..100 ms is 95, none over 100 (got: %s)" % s)
	_check(s.contains("longest work frame 100 ms at frame 100 over"), "the longest is 100 at frame 100")
	t.note_frame(40.0, 200, "")
	var s2 := t.summary()
	_check(s2.begins_with("World3D: longest work frame 40 ms at frame 200 over 1 frames since the last summary"),
		"the window restarts after a summary (got: %s)" % s2)
	_check(s2.contains("; run longest 100 ms at frame 100;"), "... while the run's longest stands")
	var s3 := t.summary()
	_check(s3.begins_with("World3D: no frames since the last summary; run longest 100 ms at frame 100;"),
		"an empty window says so (got: %s)" % s3)

func _test_end_cell_notes_the_frame() -> void:
	var t := LoadTimings.new()
	t.begin_cell(96, 167)
	t.group("terrain", 400_000)
	t.end_cell(12)
	t.note_frame(2.0, 12, "") # the physics step of the same frame
	var s := t.summary()
	_check(s.begins_with("World3D: longest work frame 402 ms at frame 12 (cell 96/167)"),
		"a closed cell is that frame's work, labelled, and the step adds to it (got: %s)" % s)

## The terrain laps World3D records, in order -- the cell line's `terrain
## [..]` list and, for a streamed cell, its `off the main thread: terrain
## [..]` list. Held from the script's own source, the way
## loading_screen_test.gd holds _ready's order, because the functions cannot
## run headless against a real archive (terrain_prepare_test.gd runs the
## prepare on synthetic ones). Since round 565 the terrain is a job built on
## the main thread (_terrain_job: the one-time tables and the cache
## snapshot), a prepare that may run on a WorkerThreadPool task
## (_terrain_prepare_read, _terrain_prepare_build: its laps go into the job
## through _job_lap, since LoadTimings is the main thread's) and a commit on
## the main thread (_terrain_commit). A synchronous cell -- the grid's centre,
## or every cell under SRREVAMP_SYNC_LOAD=1 -- lists all of them in one
## `terrain [..]` in that order, with the centre's `env` (in
## _try_load_real_terrain) between `parse` and `lightmap`; a streamed cell
## lists the commit's as its main-thread terrain and the prepare's off the
## main thread (the job's snapshot then ran between cells, in no cell).
## Every stopwatch is a named lap and none is reset unnamed (round 564's
## rule), so the laps add up to the group less each lap's whole-ms
## truncation and the little outside them: the path check before the job,
## the log prints at the commit's start and its closing print.
const TERRAIN_JOB_LAPS := ["tiletable", "objindex", "snapshot"]
const TERRAIN_PREPARE_LAPS := ["read", "parse", "lightmap", "textures", "mesh", "faces", "navmesh", "walls", "navgraph"]
const TERRAIN_COMMIT_LAPS := ["images", "upload", "setup", "collision", "wallshape", "water", "graph"]

func _source_of(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text()

## One function's body, from its header to the next top-level func.
func _body_of(src: String, header: String) -> String:
	var at := src.find(header)
	if at < 0:
		return ""
	var next_func := RegEx.new()
	next_func.compile("(?m)^(?:static )?func ")
	var after := next_func.search(src, at + header.length())
	return src.substr(at, (after.get_start() if after != null else src.length()) - at)

## The names a body's laps record, in order: `pattern` captures the name.
func _laps_in(body: String, pattern: String) -> Array:
	var re := RegEx.new()
	re.compile(pattern)
	var names := []
	for m in re.search_all(body):
		names.append(m.get_string(1))
	return names

## Round 564's rule, held to round 565's split: every terrain lap is where
## the cell lines say, in order, and none is reset outside a lap. The
## NEGATIVE of round 564 still holds (a bare reset fails the last check);
## round 565's is that before it none of the split functions existed.
func _test_world3d_terrain_laps_are_exhaustive() -> void:
	var src := _source_of("res://scripts/World3D.gd")
	_check(src != "", "World3D.gd reads")
	if src == "":
		return
	var main_lap := "_load_timings\\.lap\\(\"terrain\", \"([a-z]+)\""
	var job_lap := "_job_lap\\(job, \"([a-z]+)\""
	var bodies := {
		"_terrain_job": _body_of(src, "\nfunc _terrain_job("),
		"_try_load_real_terrain": _body_of(src, "\nfunc _try_load_real_terrain("),
		"_terrain_prepare_read": _body_of(src, "\nstatic func _terrain_prepare_read("),
		"_terrain_prepare_build": _body_of(src, "\nstatic func _terrain_prepare_build("),
		"_terrain_commit": _body_of(src, "\nfunc _terrain_commit("),
	}
	for name in bodies:
		_check(bodies[name] != "", "World3D.gd has %s" % name)
	var got_job := _laps_in(bodies["_terrain_job"], main_lap)
	_check(got_job == TERRAIN_JOB_LAPS, "_terrain_job's laps, in order, are %s (got %s)" % [str(TERRAIN_JOB_LAPS), str(got_job)])
	var got_env := _laps_in(bodies["_try_load_real_terrain"], main_lap)
	_check(got_env == ["env"], "_try_load_real_terrain records `env` alone, between the two prepare halves (got %s)" % str(got_env))
	var sync_body: String = bodies["_try_load_real_terrain"]
	_check(sync_body.find("_terrain_prepare_read(job)") < sync_body.find("\"env\"")
			and sync_body.find("\"env\"") < sync_body.find("_terrain_prepare_build(job)"),
		"_try_load_real_terrain applies the environment after the read and before the build")
	var got_prepare := _laps_in(bodies["_terrain_prepare_read"], job_lap) + _laps_in(bodies["_terrain_prepare_build"], job_lap)
	_check(got_prepare == TERRAIN_PREPARE_LAPS,
		"the prepare's laps, in order, are %s (got %s)" % [str(TERRAIN_PREPARE_LAPS), str(got_prepare)])
	var got_commit := _laps_in(bodies["_terrain_commit"], main_lap)
	_check(got_commit == TERRAIN_COMMIT_LAPS,
		"_terrain_commit's laps, in order, are %s (got %s)" % [str(TERRAIN_COMMIT_LAPS), str(got_commit)])
	for name in bodies:
		_check((bodies[name] as String).find("\tsw = Time.get_ticks_usec()") < 0,
			"no stopwatch in %s is reset outside a lap (a bare `sw = Time.get_ticks_usec()` drops the time since the previous lap)" % name)
	# The prepare half may not touch _load_timings: it can run off the main thread.
	for name in ["_terrain_prepare_read", "_terrain_prepare_build"]:
		_check((bodies[name] as String).find("_load_timings") < 0,
			"%s records no lap in _load_timings (it can run on a WorkerThreadPool task)" % name)
	var readme := _source_of("res://tools/README.md")
	_check(readme != "", "client/tools/README.md reads (shipped with the working copy)")
	if readme == "":
		return
	var flat := RegEx.new()
	flat.compile("\\s+")
	var text := flat.sub(readme, " ", true)
	var centre: Array = TERRAIN_JOB_LAPS + TERRAIN_PREPARE_LAPS.slice(0, 2) + ["env"] \
		+ TERRAIN_PREPARE_LAPS.slice(2) + TERRAIN_COMMIT_LAPS
	var centre_template := "terrain T [" + ", ".join(PackedStringArray(centre)) + "]"
	_check(text.find(centre_template) >= 0,
		"the README's synchronous cell-line template names the laps: `%s`" % centre_template)
	var streamed_template := "terrain T [" + ", ".join(PackedStringArray(TERRAIN_COMMIT_LAPS)) + "]"
	_check(text.find(streamed_template) >= 0,
		"the README's streamed cell-line template names the commit's laps: `%s`" % streamed_template)
	var off_template := "off the main thread: terrain P [" + ", ".join(PackedStringArray(TERRAIN_PREPARE_LAPS)) + "]"
	_check(text.find(off_template) >= 0,
		"the README's streamed cell-line template names the prepare's laps: `%s`" % off_template)

## Round 565: work a cell had done off the main thread is on its line and in
## the drain's off-thread total, and NOT in its `built in` total, its group
## totals or its frame's work -- the main thread did not pay it.
func _test_offthread_phases() -> void:
	var t := LoadTimings.new()
	t.begin_cell(97, 165)
	t.group("terrain", 80_000)
	t.phase("terrain", "upload", 20_000)
	t.offthread("terrain", "read", 1_000)
	t.offthread("terrain", "mesh", 120_000)
	t.offthread("terrain", "mesh", 5_000) # repeats add up, like phase()
	t.group("objects", 50_000)
	var line := t.end_cell(160)
	_check(line == "World3D: cell 97/165 built in 130 ms at frame 160 (terrain 80 [upload 20], objects 50); off the main thread: terrain 126 [read 1, mesh 125]",
		"the off-thread phases follow the groups and are not in `built in` (got: %s)" % line)
	_check(is_equal_approx(t.total_ms("terrain"), 80.0) and is_equal_approx(t.offthread_total_ms("terrain"), 126.0),
		"the group total is the main thread's 80 ms; the off-thread total is 126 ms")
	var s := t.summary()
	_check(s.begins_with("World3D: longest work frame 130 ms at frame 160 (cell 97/165)"),
		"the frame's work is the main thread's 130 ms, not 256 (got: %s)" % s)
	_check(s.ends_with("grid 1 cells terrain 80 objects 50 npcs 0 ms + terrain 126 ms off the main thread"),
		"the summary names the off-thread total after the grid's (got: %s)" % s)
	t.offthread("terrain", "read", 9_000) # no cell open: nothing kept
	t.begin_drain()
	_check(t.offthread_ms.is_empty(), "begin_drain zeroes the off-thread totals too")
	t.begin_cell(97, 166)
	var plain := t.end_cell(161)
	_check(plain == "World3D: cell 97/166 built in 0 ms at frame 161", "a cell with no off-thread phase has no suffix (got: %s)" % plain)

func _init() -> void:
	_test_cell_line()
	_test_empty_cell()
	_test_lap_and_phase_usec()
	_test_begin_drain_resets_totals()
	_test_longest_frame_is_kept()
	_test_frame_notes_add_up_and_keep_the_label()
	_test_p95_and_window()
	_test_end_cell_notes_the_frame()
	_test_world3d_terrain_laps_are_exhaustive()
	_test_offthread_phases()

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
