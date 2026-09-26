extends SceneTree

## Round 531: two HUD click routes that round 529 broke when it made the
## minimap, the player-info block and the target window MOUSE_FILTER_STOP.
## Real events go through the live viewport (Viewport.push_input: _input, the
## GUI, then _unhandled_input), and a recorder node stands in for World3D's
## handlers, so "reaches the world" is measured, not read off a filter value.
##
##   (a) The developer Hide UI button (World3D.tscn, UI/HideUIButton) takes a
##       click at its centre over anything in UI/Control, and sits clear of
##       the minimap as World3D places it.
##   (b) A middle press on the minimap, the player-info block or the target
##       window fires the hotbar's first quickslot once, through
##       World3D._relay_middle_button_to_hotbar, as a press over the world does.
##
## Everything is built without an archive: the surfaces' own rects, not their
## art. Not driven: a real click in a running client.
##   godot4 --headless --path client --script res://scripts/ui/hud/hud_click_routing_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## One mouse button event at a viewport point, through the live viewport the
## way the OS delivers it.
func _push_button(at: Vector2, button: MouseButton, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = button
	ev.pressed = pressed
	ev.position = at
	ev.global_position = at
	root.push_input(ev, true)

## A press and its release at a point; true when the press reached the
## recorder's _unhandled_input, which is where World3D reads a world click.
func _click_reaches_world(recorder: Node, at: Vector2, button: MouseButton = MOUSE_BUTTON_LEFT) -> bool:
	var unhandled := recorder.get("unhandled") as Array
	unhandled.clear()
	_push_button(at, button, true)
	_push_button(at, button, false)
	for e in unhandled:
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed:
			return true
	return false

func _make_recorder() -> Node:
	var recorder_script := GDScript.new()
	recorder_script.source_code = "\n".join([
		"extends Node",
		"var unhandled: Array = []",
		"func _unhandled_input(event: InputEvent) -> void:",
		"\tunhandled.append(event)",
		""])
	_check(recorder_script.reload() == OK, "the recorder script compiles")
	var recorder := Node.new()
	recorder.set_script(recorder_script)
	return recorder

## (a) The Hide UI button. World3D.tscn is instantiated but World3D never
## enters the tree (its _ready would open archives and the network); only its
## UI CanvasLayer is moved into the live viewport.
func _test_hide_ui_button(world: Node, recorder: Node) -> void:
	var ui := world.get_node_or_null("UI") as CanvasLayer
	var control := world.get_node_or_null("UI/Control") as Control
	var button := world.get_node_or_null("UI/HideUIButton") as Button
	_check(ui != null and control != null and button != null,
		"World3D.tscn has UI, UI/Control and UI/HideUIButton")
	if ui == null or control == null or button == null:
		return
	# NEGATIVE (fails before round 531: the button was Control's EARLIER
	# sibling, and Godot 4.2 hit-tests a later sibling first).
	_check(button.get_index() > control.get_index(),
		"HideUIButton comes after UI/Control (index %d, Control %d)" % [button.get_index(), control.get_index()])
	world.remove_child(ui)
	# The nodes leave World3D's scene, so they drop it as their owner.
	for n in ui.find_children("*", "", true, false):
		n.owner = null
	ui.owner = null
	root.add_child(ui)

	# The minimap, placed where World3D places it.
	var minimap := HudMinimap.new()
	minimap.setup()
	control.add_child(minimap)
	var has_place := world.has_method("place_minimap")
	# NEGATIVE (fails before round 531: the placement was inline).
	_check(has_place, "World3D has place_minimap")
	if has_place:
		world.call("place_minimap", minimap)
	else:
		# The same offsets, by hand, so the hit tests below still run.
		minimap.set_anchors_preset(Control.PRESET_TOP_RIGHT)
		minimap.offset_left = -150.0
		minimap.offset_right = -14.0
		minimap.offset_top = 10.0
		minimap.offset_bottom = 185.0
	var view := root.get_visible_rect()
	var map_rect := minimap.get_global_rect()
	var button_rect := button.get_global_rect()
	# The probes: both rects are real and on screen, and the minimap is STOP
	# (round 529), so it can take a click from the button.
	_check(map_rect.size == Vector2(136, 175) and view.encloses(map_rect),
		"the probe: the minimap is 136x175 on screen (%s in %s)" % [map_rect, view])
	_check(button_rect.size.x > 0 and button_rect.size.y > 0 and view.encloses(button_rect),
		"the probe: the button has a rect on screen (%s)" % [button_rect])
	_check(minimap.mouse_filter == Control.MOUSE_FILTER_STOP, "the probe: the minimap is STOP")
	# NEGATIVE (fails before round 531: the button sat under the minimap's
	# top-right corner, over its area-name line).
	_check(not button_rect.intersects(map_rect),
		"the button is clear of the minimap (button %s, minimap %s)" % [button_rect, map_rect])

	var presses: Array = []
	button.pressed.connect(func() -> void: presses.append(1))
	var centre := button_rect.get_center()
	# NEGATIVE (fails before round 531: the minimap took the click).
	_check(not _click_reaches_world(recorder, centre) and presses.size() == 1,
		"a click at the button's centre presses it (presses %d)" % presses.size())
	# Nothing in UI/Control can cover it: a full-screen STOP control added
	# last to UI/Control still loses the button's centre.
	var cover := Control.new()
	cover.mouse_filter = Control.MOUSE_FILTER_STOP
	control.add_child(cover)
	cover.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_check(not _click_reaches_world(recorder, view.get_center()),
		"the probe: the full-screen cover takes a click anywhere else")
	presses.clear()
	# NEGATIVE (fails before round 531).
	_check(not _click_reaches_world(recorder, centre) and presses.size() == 1,
		"the button wins its centre over a full-screen STOP control in UI/Control (presses %d)" % presses.size())
	# Hidden with the developer tools (Ctrl+F1), it takes nothing.
	button.visible = false
	presses.clear()
	_click_reaches_world(recorder, centre)
	_check(presses.is_empty(), "a hidden button takes no click")
	ui.free()

## (b) The middle button over the three STOP surfaces.
func _test_middle_button(world: Node, recorder: Node) -> void:
	var hud := Control.new()
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE  # as World3D.tscn's UI/Control
	root.add_child(hud)
	_check(_click_reaches_world(recorder, Vector2(600, 300), MOUSE_BUTTON_MIDDLE),
		"the probe: a middle press on no control reaches _unhandled_input")

	var bar := HudUnderbar.new(UiBuilder.new(null, null), null, null)
	bar.setup()
	hud.add_child(bar)
	bar.position = Vector2(100, 560)
	var fired: Array = []
	bar.quickslot_activated.connect(func(idx: int) -> void: fired.append(idx))

	var minimap := HudMinimap.new()
	minimap.setup()
	hud.add_child(minimap)
	minimap.position = Vector2(900, 10)
	var pmi := HudPlayerInfo.new(null)
	pmi.setup()
	hud.add_child(pmi)
	pmi.position = Vector2(4, 7)
	# Without an archive the target window builds no piece; it is given a
	# rect and shown, as _select and show_target do with one.
	var target := HudTarget.new(null)
	target.setup()
	hud.add_child(target)
	target.position = Vector2(400, 10)
	target.size = Vector2(100, 40)
	target.visible = true

	world.set("_hud_underbar", bar)
	world.set("_hud_minimap", minimap)
	world.set("_hud_player_info", pmi)
	world.set("_hud_target", target)
	var has_relay := world.has_method("_relay_middle_button_to_hotbar")
	# NEGATIVE (fails before round 531).
	_check(has_relay, "World3D has _relay_middle_button_to_hotbar")
	if has_relay:
		world.call("_relay_middle_button_to_hotbar")

	var surfaces := [["minimap", minimap], ["player-info block", pmi], ["target window", target]]
	for pair in surfaces:
		var label: String = pair[0]
		var surface: Control = pair[1]
		var centre := surface.get_global_rect().get_center()
		_check(surface.size.x > 0 and surface.size.y > 0 and surface.mouse_filter == Control.MOUSE_FILTER_STOP,
			"the probe: the %s is STOP with a rect (%s)" % [label, surface.get_global_rect()])
		fired.clear()
		var reached := _click_reaches_world(recorder, centre, MOUSE_BUTTON_MIDDLE)
		# NEGATIVE (fails before round 531: the STOP surface swallowed it).
		_check(fired == [0], "a middle press on the %s fires the \"m\" slot, quick slot 0, once (fired %s)" % [label, fired])
		_check(not reached, "a middle press on the %s does not also reach the world" % label)
		fired.clear()
		_click_reaches_world(recorder, centre, MOUSE_BUTTON_LEFT)
		_check(fired.is_empty(), "a left click on the %s fires no quickslot (fired %s)" % [label, fired])

	# Relayed twice, a surface still fires once per press.
	if has_relay:
		world.call("_relay_middle_button_to_hotbar")
	fired.clear()
	_click_reaches_world(recorder, minimap.get_global_rect().get_center(), MOUSE_BUTTON_MIDDLE)
	_check(fired == [0], "relaying again does not double the quickslot (fired %s)" % [fired])
	# The hotbar's own body goes through the same relay and still fires once.
	fired.clear()
	var body_reached := _click_reaches_world(recorder, bar.get_global_rect().get_center(), MOUSE_BUTTON_MIDDLE)
	_check(fired == [0] and not body_reached,
		"a middle press on the hotbar's body fires the \"m\" slot once (fired %s)" % [fired])
	# A hidden target window takes nothing: the press goes to the world,
	# where World3D fires it (not here).
	target.visible = false
	fired.clear()
	_check(_click_reaches_world(recorder, Vector2(450, 30), MOUSE_BUTTON_MIDDLE) and fired.is_empty(),
		"a middle press where a hidden target window sits reaches the world instead (fired %s)" % [fired])
	world.set("_hud_underbar", null)
	world.set("_hud_minimap", null)
	world.set("_hud_player_info", null)
	world.set("_hud_target", null)
	hud.free()

func _initialize() -> void:
	# The root of a --script suite enters the tree only after _initialize
	# returns, and Viewport.push_input refuses a viewport outside it
	# (measured here: `!is_inside_tree()`, as npc_service_reader_test's check
	# (m) found for focus). So the suite waits a frame. A watchdog fails it,
	# rather than hanging it, if a script error stops it before it reports.
	var watchdog := create_timer(60.0)
	watchdog.timeout.connect(func() -> void:
		print("FAIL the suite never reported (a script error stopped it)")
		quit(1))
	await process_frame
	_check(root.is_inside_tree(), "the probe: after one frame the root is in the tree")
	# Headless, the root window is 64x64 (measured on the render box), which
	# puts the right-anchored HUD at negative x. It is given Godot's default
	# window size, 1152x648 (project.godot sets none), as a player's is.
	root.size = Vector2i(1152, 648)
	var recorder := _make_recorder()
	root.add_child(recorder)
	# A press finds the control under the cursor only while the mouse is in
	# the viewport (Godot 4.2.2 Viewport::_gui_input_event), which only the
	# OS's enter event sets; headless, it is sent here.
	root.notification(Node.NOTIFICATION_VP_MOUSE_ENTER)

	# World3D.tscn's root carries World3D.gd, whose script names the NetClient
	# autoload, registered only after _init; hence _initialize.
	var scene := load("res://scenes/World3D.tscn") as PackedScene
	_check(scene != null, "World3D.tscn loads")
	var world: Node = scene.instantiate() if scene != null else null
	_check(world != null and world.get_script() != null, "World3D.tscn instantiates with its script")
	if world != null:
		_test_hide_ui_button(world, recorder)
		_test_middle_button(world, recorder)
		world.free()
	recorder.free()

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
