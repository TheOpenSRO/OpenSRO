extends RefCounted
class_name LoadTimings

## Where a world load's main-thread time goes -- per cell, per phase and per
## frame: the numbers every map and loading change is measured on (round
## 561; the benchmark is client/tools/README.md, "Load benchmark").
##
## Three records:
## - A cell. `begin_cell`, then the phase groups measured around them by
##   the caller (`group`: terrain, objects, npcs -- World3D._note_cell_built's
##   stopwatches, the same three numbers the `region grid loaded` split has
##   summed since round 156) and the sub-phases inside them (`phase` /
##   `lap`: the archive read, the parse, the lightmap, the textures, the
##   mesh, the trimesh, ...). `end_cell` closes it, adds it to the drain's
##   totals and returns the `World3D: cell x/y built in` line.
## - A frame. `note_frame` sums the main-thread WORK noted against one drawn
##   frame -- each cell's build (from end_cell) and World3D._physics_process's
##   own step -- keeping the longest, the count over HITCH_MS and every
##   frame's total for a p95. Work time and not `delta`: qa_shot.sh runs
##   the client under `--write-movie`, which forces `--fixed-fps` (Godot
##   4.2, "Command line reference": "Force a fixed number of frames per
##   second. This setting disables real-time synchronization"; the
##   ProjectSettings reference, `editor/movie_writer/fps`, default 60 and
##   not overridden in project.godot: "Simulation speed will adjust to
##   always match the specified framerate"), so `delta` is 1/60 s on every
##   frame of every benchmark however long the frame took. The wall clock
##   between physics steps goes beside it (`note_wall`), the movie writer's
##   own per-frame floor included (about 0.33 s a frame on the render box,
##   AGENTS.md, "Looking at the world").
## - Off the main thread (round 565). `offthread` records a sub-phase a cell
##   had done on a WorkerThreadPool task -- World3D prepares a streamed
##   cell's terrain there and commits it on the main thread. It is printed
##   after the cell's groups and summed into the drain's `offthread_ms`, and
##   never counted in the cell's `built in` total or its frame's work: the
##   main thread did not pay it.
## - A drain. `begin_drain` zeroes the grid totals where a drain's clock
##   starts (a world entry, a zone change), so a second entry's split is its
##   own and not the sum of both -- until this round World3D's three
##   accumulators were never reset (round 559's review).
##
## `summary()` reports the window since the previous summary and the run's
## longest frame, then starts a new window: the summary at the end of the
## entry drain reports the entry, and the one 600 ticks later reports the
## play after it (a boundary crossing), each on its own.

## Frames whose work is longer than this are counted in summary(). A
## reporting bucket for the log, not a game value: nothing in the game
## reads it.
const HITCH_MS := 100.0

## The drain's grid totals: cells closed since begin_drain(), and their
## phase-group time, group name -> ms.
var cells := 0
var group_ms := {}
## The drain's off-the-main-thread totals, group name -> ms (offthread).
var offthread_ms := {}
## Every closed cell's whole time in usec, for the frame accounting: a
## caller timing a frame that built cells inside it subtracts what end_cell
## has already noted (World3D._physics_process).
var cell_work_usec := 0

# The open cell.
var _cell_open := false
var _cell_name := ""
var _group_order: Array[String] = []
var _group_usec := {}
var _phase_order := {} # group -> Array of names, in first-seen order
var _phase_usec := {} # group -> {name: usec}
var _off_order: Array[String] = [] # groups with off-thread phases, first seen first
var _off_phase_order := {} # group -> Array of names, in first-seen order
var _off_phase_usec := {} # group -> {name: usec}

# The open frame, the window since the last summary, and the run.
var _frame_open := false
var _frame := 0
var _frame_usec := 0
var _frame_label := ""
var _win_ms := PackedFloat32Array()
var _win_longest_ms := 0.0
var _win_longest_frame := -1
var _win_longest_label := ""
var _win_hitches := 0
var _win_wall_ms := 0.0
var _win_wall_frame := -1
var _wall_last_usec := -1
var longest_ms := 0.0
var longest_frame := -1
var longest_label := ""
var hitches := 0

## A drain's clock starts: the grid totals are this drain's alone.
func begin_drain() -> void:
	cells = 0
	group_ms = {}
	offthread_ms = {}

func begin_cell(region_x: int, region_y: int) -> void:
	_cell_open = true
	_cell_name = "%d/%d" % [region_x, region_y]
	_group_order.clear()
	_group_usec.clear()
	_phase_order.clear()
	_phase_usec.clear()
	_off_order.clear()
	_off_phase_order.clear()
	_off_phase_usec.clear()

## A phase group's whole time, measured around it by the caller.
func group(name: String, usec: int) -> void:
	if not _cell_open:
		return
	if not _group_usec.has(name):
		_group_order.append(name)
	_group_usec[name] = int(_group_usec.get(name, 0)) + usec

## A sub-phase inside a group; repeats add up (templates are built one at a
## time). Nothing is kept while no cell is open, so the standalone
## single-region paths record nothing.
func phase(group_name: String, name: String, usec: int) -> void:
	if not _cell_open:
		return
	if not _phase_usec.has(group_name):
		_phase_usec[group_name] = {}
		_phase_order[group_name] = []
	var usecs: Dictionary = _phase_usec[group_name]
	if not usecs.has(name):
		(_phase_order[group_name] as Array).append(name)
	usecs[name] = int(usecs.get(name, 0)) + usec

## Records the time since `since_usec` as a sub-phase and returns now, so a
## chain of stopwatches is one line per phase.
func lap(group_name: String, name: String, since_usec: int) -> int:
	var now := Time.get_ticks_usec()
	phase(group_name, name, now - since_usec)
	return now

## A sub-phase of the open cell done OFF the main thread (round 565), in
## usec; repeats add up. On the cell line after its groups -- `; off the main
## thread: terrain 214 [read 1, parse 15, ...]` -- and in the drain's
## `offthread_ms`, never in the cell's total or its frame's work. Nothing is
## kept while no cell is open, like phase().
func offthread(group_name: String, name: String, usec: int) -> void:
	if not _cell_open:
		return
	if not _off_phase_usec.has(group_name):
		_off_order.append(group_name)
		_off_phase_usec[group_name] = {}
		_off_phase_order[group_name] = []
	var usecs: Dictionary = _off_phase_usec[group_name]
	if not usecs.has(name):
		(_off_phase_order[group_name] as Array).append(name)
	usecs[name] = int(usecs.get(name, 0)) + usec

func offthread_total_ms(group_name: String) -> float:
	return float(offthread_ms.get(group_name, 0.0))

func phase_usec(group_name: String, name: String) -> int:
	if not _phase_usec.has(group_name):
		return 0
	return int((_phase_usec[group_name] as Dictionary).get(name, 0))

func total_ms(group_name: String) -> float:
	return float(group_ms.get(group_name, 0.0))

## Closes the cell: adds it to the drain's totals, notes its whole time as
## work on `frame`, and returns its line -- `World3D: cell 97/169 built in
## 512 ms at frame 88 (terrain 310 [read 12, parse 88, ...], objects 180
## [...], npcs 22)`, then `; off the main thread: terrain 214 [read 1, ...]`
## when offthread() recorded any (round 565). A cell with no groups is
## `built in 0 ms` with no list.
func end_cell(frame: int) -> String:
	if not _cell_open:
		return ""
	var total_usec := 0
	var parts: Array[String] = []
	for g in _group_order:
		var usec: int = _group_usec[g]
		total_usec += usec
		group_ms[g] = float(group_ms.get(g, 0.0)) + usec / 1000.0
		var text := "%s %d" % [g, int(usec / 1000.0)]
		if _phase_order.has(g):
			var subs: Array[String] = []
			for p in _phase_order[g]:
				subs.append("%s %d" % [p, int(int(_phase_usec[g][p]) / 1000.0)])
			text += " [" + ", ".join(subs) + "]"
		parts.append(text)
	cells += 1
	cell_work_usec += total_usec
	var name := _cell_name
	_cell_open = false
	note_frame(total_usec / 1000.0, frame, "cell " + name)
	var line := "World3D: cell %s built in %d ms at frame %d" % [name, int(total_usec / 1000.0), frame]
	if not parts.is_empty():
		line += " (" + ", ".join(parts) + ")"
	var off_parts: Array[String] = []
	for g in _off_order:
		var off_usec := 0
		var subs: Array[String] = []
		for p in _off_phase_order[g]:
			var usec: int = _off_phase_usec[g][p]
			off_usec += usec
			subs.append("%s %d" % [p, int(usec / 1000.0)])
		offthread_ms[g] = float(offthread_ms.get(g, 0.0)) + off_usec / 1000.0
		off_parts.append("%s %d [%s]" % [g, int(off_usec / 1000.0), ", ".join(subs)])
	if not off_parts.is_empty():
		line += "; off the main thread: " + ", ".join(off_parts)
	return line

## Main-thread work on a drawn frame, in ms: a cell's build (end_cell) or a
## physics step (World3D._physics_process). Notes for one frame add up; a
## note for another frame closes the open one. A non-empty label names what
## the frame built; an empty one leaves the label alone.
func note_frame(work_ms: float, frame: int, label: String) -> void:
	if _frame_open and frame != _frame:
		_close_frame()
	if not _frame_open:
		_frame_open = true
		_frame = frame
		_frame_usec = 0
		_frame_label = ""
	_frame_usec += int(work_ms * 1000.0)
	if label != "":
		_frame_label = label

## The wall clock at the end of a physics step; the gap from the previous
## one is that frame's wall time, movie-writer floor included.
func note_wall(frame: int, now_usec: int) -> void:
	if _wall_last_usec >= 0:
		var gap_ms := (now_usec - _wall_last_usec) / 1000.0
		if gap_ms > _win_wall_ms:
			_win_wall_ms = gap_ms
			_win_wall_frame = frame
	_wall_last_usec = now_usec

func _close_frame() -> void:
	var ms := _frame_usec / 1000.0
	_win_ms.append(ms)
	if ms > _win_longest_ms:
		_win_longest_ms = ms
		_win_longest_frame = _frame
		_win_longest_label = _frame_label
	if ms > longest_ms:
		longest_ms = ms
		longest_frame = _frame
		longest_label = _frame_label
	if ms > HITCH_MS:
		_win_hitches += 1
		hitches += 1
	_frame_open = false

static func _at(ms: float, frame: int, label: String) -> String:
	var text := "%.0f ms at frame %d" % [ms, frame]
	if label != "":
		text += " (%s)" % label
	return text

## The window since the last summary, the run's longest frame and the
## drain's grid totals -- then a new window. The p95 is the window's
## frames sorted, the one at ceil(0.95 n).
func summary() -> String:
	if _frame_open:
		_close_frame()
	var line := "World3D: "
	var n := _win_ms.size()
	if n == 0:
		line += "no frames since the last summary"
	else:
		var sorted := _win_ms.duplicate()
		sorted.sort()
		var p95: float = sorted[maxi(int((n * 95 + 99) / 100.0) - 1, 0)]
		line += "longest work frame %s over %d frames since the last summary; p95 %.0f ms; %d over %.0f ms" % [
			_at(_win_longest_ms, _win_longest_frame, _win_longest_label), n, p95, _win_hitches, HITCH_MS]
		if _win_wall_frame >= 0:
			line += "; longest wall gap %.0f ms at frame %d" % [_win_wall_ms, _win_wall_frame]
	line += "; run longest %s; grid %d cells terrain %.0f objects %.0f npcs %.0f ms" % [
		_at(longest_ms, longest_frame, longest_label), cells,
		total_ms("terrain"), total_ms("objects"), total_ms("npcs")]
	for g in offthread_ms:
		line += " + %s %.0f ms off the main thread" % [g, offthread_ms[g]]
	_win_ms = PackedFloat32Array()
	_win_longest_ms = 0.0
	_win_longest_frame = -1
	_win_longest_label = ""
	_win_hitches = 0
	_win_wall_ms = 0.0
	_win_wall_frame = -1
	return line
