extends Node
class_name FrameSplit

## QA only (round 748): where a rendered frame's wall time goes, for the crowd
## probe (QaCrowdProbe's `QA CROWD split` line). Never made in play: the probe
## adds it, and every timer it feeds is behind `FrameSplit.on`.
##
## **Why not `Performance.TIME_PROCESS`.** READ, Godot 4.2.2 `main/main.cpp`
## (Main::iteration, l. 3679-3736): `process_ticks` runs from before
## SceneTree::process to after `RenderingServer::draw`, so it holds every
## `_process` callback, the message queue's flush AND the whole render on the
## CPU; and the monitor is set once a second to the MAXIMUM of those (the
## `process_max` reset at l. 3734), not their mean. `TIME_PHYSICS_PROCESS` is
## likewise the longest single physics step of the second. So "TIME_PROCESS
## 56 ms" was the worst frame's process-plus-render, not script time.
##
## **The phases** (MEASURED by two marker nodes, the first and the last of the
## tree's process and physics order: SceneTree sorts a group by
## process_priority, then tree order):
##   phys_cb      first to last `_physics_process` of a step, summed over the
##                frame's steps (GDScript; World3D's own split is in its parts)
##   phys_engine  the rest of each step: NavigationServer3D.process, the
##                message queue (deferred skeleton updates of a pose made in a
##                physics callback), PhysicsServer3D.step, and the next step's
##                sync -- up to the next step or the process callbacks
##   proc_cb      first to last `_process` callback
##   post_flush   from the last `_process` to RenderingServer's
##                `frame_pre_draw`: the message queue flush (what the process
##                callbacks deferred) and RenderingServer::sync
##   draw         `frame_pre_draw` to `frame_post_draw`: RenderingServer::draw
##                -- the scene update (dirty instances, skinned AABBs; the
##                probe's `setup` is RenderingServer.get_frame_setup_time_cpu),
##                every viewport's render on the CPU, the canvas
##   post_tail    `frame_post_draw` to the next frame's first callback: audio,
##                ScriptServer::frame, input, the frame timer
## `usec` holds those and every label the instrumented code adds.

static var on := false
static var usec: Dictionary = {}

## Round 757: whether the RenderingServer draws on its own thread (the
## project's rendering/driver/threads/thread_model 2, or `--render-thread
## separate` on the command line, which main.cpp l. 1201-1209 reads first).
## Then RenderingServer's frame_pre_draw / frame_post_draw are emitted on the
## render thread (rendering_server_default.cpp l. 71-120, READ, 4.2.2), so the
## split does not listen to them, and a script getter on the server waits for
## the render thread (command_queue push_and_ret).
static func render_threaded() -> bool:
	var args := OS.get_cmdline_args()
	var i := args.find("--render-thread")
	if i >= 0 and i + 1 < args.size():
		return args[i + 1] == "separate"
	return int(ProjectSettings.get_setting("rendering/driver/threads/thread_model", 1)) == 2

static func add(label: String, us: int) -> void:
	usec[label] = int(usec.get(label, 0)) + us

## Round 759: each received opcode's count and dispatch time
## (NetClient._process): opcode -> [packets, usec].
static var ops: Dictionary = {}

static func op(opcode: int, us: int) -> void:
	var got = ops.get(opcode)
	if got == null:
		ops[opcode] = [1, us]
	else:
		got[0] += 1
		got[1] += us

## The `n` opcodes with the most dispatch time since `before` (a duplicate of
## `ops` taken earlier, deep), as "0xNNNN:packets/ms ..." over `seconds`.
static func ops_line(before: Dictionary, n: int = 8) -> String:
	var rows: Array = []
	for k in ops:
		var b = before.get(k, [0, 0])
		var d_n := int(ops[k][0]) - int(b[0])
		var d_us := int(ops[k][1]) - int(b[1])
		if d_n > 0:
			rows.append([k, d_n, d_us])
	rows.sort_custom(func(a, b) -> bool: return int(a[2]) > int(b[2]))
	var parts := PackedStringArray()
	for r in rows.slice(0, n):
		parts.append("0x%04x:%d/%.1fms" % [int(r[0]), int(r[1]), float(r[2]) / 1000.0])
	return " ".join(parts)

## A snapshot of the counters, for a step's deltas.
static func snapshot() -> Dictionary:
	return usec.duplicate()

const PRIORITY := 1000000

var _first: Mark
var _last: Mark
var _prev := ""
var _prev_us := 0

class Mark extends Node:
	var split: FrameSplit
	var tag_physics := ""
	var tag_process := ""
	func _physics_process(_d: float) -> void:
		split.event(tag_physics)
	func _process(_d: float) -> void:
		split.event(tag_process)

## Puts the two markers at the ends of `root`'s order and switches the
## counters on.
func install(root: Node) -> void:
	on = true
	_first = Mark.new()
	_first.name = "FrameSplitFirst"
	_first.split = self
	_first.tag_physics = "P0"
	_first.tag_process = "R0"
	_first.process_priority = -PRIORITY
	_first.process_physics_priority = -PRIORITY
	_last = Mark.new()
	_last.name = "FrameSplitLast"
	_last.split = self
	_last.tag_physics = "P1"
	_last.tag_process = "R1"
	_last.process_priority = PRIORITY
	_last.process_physics_priority = PRIORITY
	root.add_child(_first)
	root.add_child(_last)
	# Round 757: with the render on its own thread these signals come from
	# that thread; `post_flush` is then everything from the last _process to
	# the next frame's first callback (the flush, the wait for the previous
	# frame's draw in RenderingServer.sync, the draw's push, the tail).
	if not render_threaded():
		RenderingServer.frame_pre_draw.connect(func() -> void: event("D0"))
		RenderingServer.frame_post_draw.connect(func() -> void: event("D1"))

## The segment between two events, by (previous, this).
static func segment(prev: String, cur: String) -> String:
	match prev:
		"P0":
			return "phys_cb" if cur == "P1" else ""
		"P1":
			return "phys_engine" if cur == "P0" or cur == "R0" else ""
		"R0":
			return "proc_cb" if cur == "R1" else ""
		"R1":
			if cur == "D0":
				return "post_flush"
			return "post_flush" if cur == "P0" or cur == "R0" else ""
		"D0":
			return "draw" if cur == "D1" else ""
		"D1":
			return "post_tail" if cur == "P0" or cur == "R0" else ""
	return ""

func event(tag: String) -> void:
	var now := Time.get_ticks_usec()
	if _prev != "":
		var seg := segment(_prev, tag)
		if seg != "":
			add(seg, now - _prev_us)
	_prev = tag
	_prev_us = now
