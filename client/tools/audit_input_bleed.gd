extends SceneTree

## Dev tool (round 818): which parts of each game window let the mouse through
## to the world. Builds every window the way the HUD does (as
## dump_visible_panels.gd does), and over every visible control of each one
## pushes a mouse motion and a wheel step through the viewport at points 4 px
## apart; a sink at the root's end records each event that reaches
## _unhandled_input -- the handler World3D walks and zooms in. A point that
## leaks is printed with the control drawn there.
##
## Retail sends the world nothing under a window: a window under the mouse
## that is not the interface itself takes the message (FUN_00b9dc00 !=
## CGInterface, READ, round 697).
##
## Usage:
##   godot4 --headless --path client --script res://tools/audit_input_bleed.gd -- \
##     --pk2=/path/to/Media.pk2 [--panel=quest ...] [--step=4]

const PANELS := ["inventory", "character", "skill", "action", "party", "academy",
	"quest", "guild", "community", "storage", "store", "exchange", "system",
	"partymatch", "autopotion", "npctalk", "alchemy", "option", "worldmap", "help"]

class Sink extends Node:
	var seen := 0
	func _unhandled_input(_event: InputEvent) -> void:
		seen += 1

func _args(flag: String) -> PackedStringArray:
	var out := PackedStringArray()
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			out.append(a.substr(flag.length() + 1))
	return out

func _initialize() -> void:
	var watchdog := create_timer(900.0)
	watchdog.timeout.connect(func() -> void:
		print("=== watchdog: stopped")
		quit(1))
	await process_frame
	var pk2 := _args("--pk2")
	if pk2.is_empty():
		printerr("usage: --pk2=<Media.pk2> [--panel=<id> ...] [--step=4]")
		quit(2)
		return
	var step := 4
	_wheel = not _args("--wheel").is_empty() and _args("--wheel")[0] == "1"
	_world_script = load("res://scripts/World3D.gd") as GDScript
	if not _args("--step").is_empty():
		step = maxi(1, int(_args("--step")[0]))
	var archive := Pk2Reader.open(pk2[0])
	if archive == null:
		printerr("could not open ", pk2[0])
		quit(1)
		return
	var table: UiTextTable = null
	var entry := ObjectLoader.find_file(archive, "server_dep\\silkroad\\textdata\\textuisystem.txt")
	if entry != null:
		table = UiTextTable.parse(archive.read_file(entry))
	var builder := UiBuilder.new(archive, table)
	var wanted := _args("--panel")
	if wanted.is_empty():
		wanted = PackedStringArray(PANELS)
	var panels_script := load("res://scripts/ui/hud/hud_panels.gd") as GDScript
	var map_script := load("res://scripts/ui/hud/hud_worldmap.gd") as GDScript
	root.size = Vector2i(1920, 1080)
	var sink := Sink.new()
	get_root().add_child(sink)
	var panels: Control = panels_script.new(builder)
	get_root().add_child(panels)
	await process_frame
	# A headless window never hears the mouse come in, and a viewport that
	# has not routes no mouse event to its controls.
	root.notification(Window.NOTIFICATION_WM_MOUSE_ENTER)
	root.notification(Viewport.NOTIFICATION_VP_MOUSE_ENTER)
	# The probe proves itself first: a STOP square takes its point, a bare
	# point leaks.
	var probe := ColorRect.new()
	probe.position = Vector2(4, 4)
	probe.size = Vector2(20, 20)
	probe.mouse_filter = Control.MOUSE_FILTER_STOP
	get_root().add_child(probe)
	await process_frame
	var got := [0]
	probe.gui_input.connect(func(_e: InputEvent) -> void: got[0] += 1)
	var b0 := sink.seen
	var m := InputEventMouseMotion.new()
	m.position = Vector2(10, 10)
	m.global_position = m.position
	root.push_input(m)
	var b1 := sink.seen
	var w := InputEventMouseButton.new()
	w.position = Vector2(10, 10)
	w.global_position = w.position
	w.button_index = MOUSE_BUTTON_WHEEL_DOWN
	w.pressed = true
	root.push_input(w)
	print("probe detail: motion leaked %d, wheel leaked %d, control got %d, hovered %s" % [b1 - b0, sink.seen - b1, got[0], str(root.gui_get_hovered_control())])
	print("probe: root %s visible %s; STOP square leaks %s; bare point leaks %s" % [
		str(root.size), str(root.get_visible_rect()), str(_leaks(Vector2(10, 10), sink)), str(_leaks(Vector2(600, 5), sink))])
	probe.queue_free()
	var total_leaks := 0
	for id in wanted:
		var window: Control = null
		if id == "worldmap":
			var map: Control = map_script.new(builder)
			get_root().add_child(map)
			if map.call("build_worldmap"):
				map.call("open")
				window = map
		elif id == "help":
			var help: Control = (load("res://scripts/ui/help_window.gd") as GDScript).new()
			get_root().add_child(help)
			help.call("setup", builder, [], false)
			help.show()
			window = help.get_node_or_null("HelpFrame") as Control
		elif id == "option":
			window = panels.call("toggle_option")
		else:
			window = panels.call("open", id)
		if window == null:
			print("=== %s: not built" % id)
			continue
		# HudWindow places its overhang catchers 3 frames after a show.
		for i in 6:
			await process_frame
		var leaks := _audit(window, sink, step)
		total_leaks += leaks.size()
		print("=== %s: %d leaking point(s), window rect %s" % [id, leaks.size(), str(window.get_global_rect())])
		var by_control := {}
		for l in leaks:
			by_control[l[1]] = by_control.get(l[1], 0) + 1
		for k in by_control:
			print("%s | leaks %d over %s" % [id, by_control[k], k])
		if id == "worldmap":
			window.queue_free()
		elif id == "help":
			window.get_parent().queue_free()
		elif id == "option":
			panels.call("close_option")
		else:
			window.hide()
		await process_frame
	print("TOTAL leaking points: %d" % total_leaks)
	quit(0)

## Every point (step apart) inside a visible control of `window` whose motion or
## wheel reaches _unhandled_input: [point, the deepest visible control there].
func _audit(window: Control, sink: Sink, step: int) -> Array:
	var rects: Array = []
	# Only what is on the screen: windows park unused controls far off it.
	_rects(window, rects, root.get_visible_rect())
	var seen_points := {}
	var out: Array = []
	for pair in rects:
		var r: Rect2 = pair[0]
		var y := r.position.y + 1.0
		while y < r.end.y - 0.5:
			var x := r.position.x + 1.0
			while x < r.end.x - 0.5:
				var p := Vector2(floorf(x), floorf(y))
				if not seen_points.has(p):
					seen_points[p] = true
					if _leaks(p, sink):
						out.append([p, _deepest(window, p)])
				x += step
			y += step
	return out

func _rects(node: Node, out: Array, clip: Rect2 = Rect2(-1e6, -1e6, 2e6, 2e6)) -> void:
	if node is CanvasItem and not (node as CanvasItem).is_visible_in_tree():
		return
	if node is Control:
		var c := node as Control
		var r := c.get_global_rect().abs().intersection(clip)
		if r.size.x >= 2.0 and r.size.y >= 2.0 and _draws(c):
			out.append([r, c])
		# What a clipping control cuts off is not drawn.
		if c.clip_contents:
			clip = clip.intersection(c.get_global_rect().abs())
	for child in node.get_children():
		_rects(child, out, clip)

## Whether `c` draws anything a player would take for the window (the
## window's own rule, HudWindow.draws_something).
func _draws(c: Control) -> bool:
	return HudWindow.draws_something(c)

func _leaks(p: Vector2, sink: Sink) -> bool:
	var before := sink.seen
	var motion := InputEventMouseMotion.new()
	motion.position = p
	motion.global_position = p
	root.push_input(motion)
	if sink.seen > before:
		return true
	if not _wheel:
		return false
	# Asked before the GUI has the step, as World3D._input asks it.
	var on_window := bool(_world_script.call("wheel_over_window", root.gui_get_hovered_control()))
	var wheel := InputEventMouseButton.new()
	wheel.position = p
	wheel.global_position = p
	wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
	wheel.pressed = true
	wheel.factor = 1.0
	root.push_input(wheel)
	# No release: Godot hands a release with no control holding the mouse to
	# _unhandled_input wherever it is, and the world acts on presses only.
	# The press reaches _unhandled_input under any window (force-pass); it
	# leaks when the world's own test would still zoom.
	return sink.seen > before and not on_window

## --wheel=1 pushes a wheel step after each motion. Godot (4.3 on) passes a
## wheel event up through a STOP control while its
## mouse_force_pass_scroll_events is set, the default, so the wheel reaches
## _unhandled_input under every window; the world's own test decides it
## (World3D.wheel_over_window). Without it the motion alone is the probe,
## routed as a click is.
var _wheel := false
var _world_script: GDScript = null

## The last-drawn visible control whose rect holds `p`, as a path.
func _deepest(window: Control, p: Vector2) -> String:
	var hit: Array = [null]
	_deepest_walk(window, p, hit)
	var c := hit[0] as Control
	if c == null:
		return "(nothing)"
	return "%s <%s> filter %d rect %s" % [str(window.get_path_to(c)), c.get_class(), c.mouse_filter, str(c.get_global_rect())]

func _deepest_walk(node: Node, p: Vector2, hit: Array) -> void:
	if node is CanvasItem and not (node as CanvasItem).is_visible_in_tree():
		return
	if node is Control and (node as Control).get_global_rect().abs().has_point(p) and _draws(node as Control):
		hit[0] = node
	for child in node.get_children():
		_deepest_walk(child, p, hit)
