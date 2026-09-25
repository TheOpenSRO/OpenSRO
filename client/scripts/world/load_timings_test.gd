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
## a summary closes while the run's longest stands.

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

func _init() -> void:
	_test_cell_line()
	_test_empty_cell()
	_test_lap_and_phase_usec()
	_test_begin_drain_resets_totals()
	_test_longest_frame_is_kept()
	_test_frame_notes_add_up_and_keep_the_label()
	_test_p95_and_window()
	_test_end_cell_notes_the_frame()

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
