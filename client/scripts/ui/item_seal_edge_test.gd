extends SceneTree

## The seal star round an item slot (ItemSealEdge, docs/protocol/item_seal_edge.md):
## 0x66bcf0's timer-3 step, 0x67cfb0's cell and UV arithmetic, 0x666610's
## random phase, 0xb933d0's once-a-tick firing, and the node's life on an
## icon (added on a seal item, hidden on anything else, phase kept for the
## same item). Pure arithmetic and a synthetic icon; no archive:
##   godot4 --headless --path client --script res://scripts/ui/item_seal_edge_test.gd

const EDGE_PATH := "res://scripts/ui/item_seal_edge.gd"

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	var edge_script := load(EDGE_PATH) as GDScript
	if edge_script == null:
		_check(false, "item_seal_edge.gd loads")
		quit(1)
		return
	_arithmetic_checks(edge_script)
	_node_checks(edge_script)
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

func _arithmetic_checks(e: GDScript) -> void:
	_check(int(e.get_script_constant_map().get("INTERVAL_MS", -1)) == 40, "timer 3 runs at 0x28 = 40 ms (0x666610)")
	_check(e.call("step", 32) == 31 and e.call("step", 2) == 1, "a step counts down (0x66bcf0 case 3)")
	_check(e.call("step", 1) == 32 and e.call("step", 0) == 32, "below 1 it wraps to 0x20")
	_check(e.call("frame_for", 0) == -1, "a counter of 0 draws nothing (0x67cfb0 needs > 0)")
	_check(e.call("frame_for", 32) == 0 and e.call("frame_for", 1) == 31, "cell = 32 - counter")
	# One full lap from any phase visits every cell once, in order.
	var c := 32
	var seen: Array = []
	for i in range(32):
		seen.append(e.call("frame_for", c))
		c = e.call("step", c)
	var in_order := true
	for i in range(32):
		in_order = in_order and int(seen[i]) == i
	_check(in_order and c == 32, "32 steps from 32 draw cells 0..31 in order and come back")
	# The doubles: 32.0 x 1/256 across, 32.0 x 1/128 down.
	var uv0: Rect2 = e.call("cell_uv", 0)
	_check(uv0 == Rect2(0, 0, 0.125, 0.25), "cell 0 is UV (0,0)-(0.125,0.25) (got %s)" % uv0)
	var uv9: Rect2 = e.call("cell_uv", 9)
	_check(uv9 == Rect2(0.125, 0.25, 0.125, 0.25), "cell 9 is column 1, row 1 (got %s)" % uv9)
	var uv31: Rect2 = e.call("cell_uv", 31)
	_check(uv31 == Rect2(0.875, 0.75, 0.125, 0.25), "cell 31 is the last column of the last row (got %s)" % uv31)
	var px := Rect2(uv31.position * Vector2(256, 128), uv31.size * Vector2(256, 128))
	_check(px == Rect2(224, 96, 32, 32), "on the 256x128 sheet a cell is 32x32 pixels (got %s)" % px)

func _node_checks(e: GDScript) -> void:
	var icon := TextureRect.new()
	icon.size = Vector2(32, 32)
	root.add_child(icon)
	e.call("show_on", icon, null, false, 5)
	_check(icon.get_node_or_null("SealEdge") == null, "no edge is added for an item that is not a seal")
	e.call("show_on", icon, null, true, 5)
	var edge := icon.get_node_or_null("SealEdge") as Control
	_check(edge != null and edge.visible, "a seal item gets the edge on its icon")
	if edge == null:
		return
	_check(edge.mouse_filter == Control.MOUSE_FILTER_IGNORE, "the edge takes no clicks")
	_check(edge.anchor_right == 1.0 and edge.anchor_bottom == 1.0 and edge.offset_right == 0.0,
		"the edge fills the icon's rect (the slot's quad)")
	var c0 := int(edge.get("counter"))
	_check(c0 >= 0 and c0 <= 31, "the phase is rand() & 31 (got %d)" % c0)
	# 0xb933d0: once a tick when now - last >= 40, then last = now.
	edge.set("_last_ms", 1000)
	edge.set("counter", 10)
	edge.call("tick", 1039)
	_check(int(edge.get("counter")) == 10, "39 ms after the last step: no step")
	edge.call("tick", 1040)
	_check(int(edge.get("counter")) == 9, "40 ms: one step")
	edge.call("tick", 1500)
	_check(int(edge.get("counter")) == 8, "460 ms late: still one step, not caught up")
	_check(int(edge.get("_last_ms")) == 1500, "... and the timer restarts from that tick")
	# The same item set again (a panel refill) keeps the phase; a new one rolls.
	e.call("show_on", icon, null, true, 5)
	_check(int(edge.get("counter")) == 8, "the same item set again keeps its phase (OURS)")
	var rolled := false
	for i in range(20):
		e.call("show_on", icon, null, true, 100 + i)
		rolled = rolled or int(edge.get("counter")) != 8
	_check(rolled, "a different item takes a new random phase")
	e.call("show_on", icon, null, false, -1)
	_check(not edge.visible and not edge.is_processing(), "an emptied or non-seal slot hides the edge and stops ticking")
	e.call("show_on", icon, null, true, 7)
	_check(edge.visible and edge.is_processing() and icon.get_child_count() == 1,
		"a seal item again shows the same node, not a second one")
	# The held icon takes the slot's phase (copy_phase).
	var ghost := TextureRect.new()
	root.add_child(ghost)
	e.call("show_on", ghost, null, true, 7)
	edge.set("counter", 21)
	edge.set("_last_ms", 4321)
	e.call("copy_phase", icon, ghost)
	var gedge := ghost.get_node_or_null("SealEdge")
	_check(gedge != null and int(gedge.get("counter")) == 21 and int(gedge.get("_last_ms")) == 4321,
		"a copy of the slot (the held icon) keeps the slot's phase and timer")
	e.call("show_on", icon, null, false, -1)
	gedge.set("counter", 3)
	e.call("copy_phase", icon, ghost)
	_check(int(gedge.get("counter")) == 3, "a hidden source edge leaves the copy's phase alone")
	ghost.queue_free()
	icon.queue_free()
