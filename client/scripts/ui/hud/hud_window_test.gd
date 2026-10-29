extends SceneTree

## Exercises HudWindow and HudPanels against a synthetic layout (never real
## game data), run headless:
##   godot4 --headless --path client --script res://scripts/ui/hud/hud_window_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## A layout in the real `resinfo` shape: a frame at the origin carrying the
## window's size, plus a couple of controls. Mirrors ifinventory.txt, whose
## GDR_INVENTORY_FRAME is `0,0,176,308` with an 8-slice base ending in "_".
func _synthetic_layout() -> String:
	return """Interface Text

Section = Create,"0,0,0,0","0"
{
	TEST_FRAME:CIFFrame
	{
		ClientRect=RECT,"0,0,0,0"
		Color=COLOR,"255,51,191,68"
		DDJ=STRING,"interface\\\\test\\\\test_window_"
		FontColor=COLOR,"255,255,255,255"
		Rect=RECT,"0,0,176,308"
		Text=STRING,""
	}
	TEST_LABEL:CIFStatic
	{
		ClientRect=RECT,"0,0,0,0"
		Color=COLOR,"255,91,102,218"
		DDJ=STRING,""
		FontColor=COLOR,"255,255,255,255"
		Rect=RECT,"10,40,120,12"
		Text=STRING,""
	}
	TEST_LATTICE:CIFLattice
	{
		ClientRect=RECT,"0,0,0,0"
		Color=COLOR,"255,64,213,106"
		DDJ=STRING,""
		FontColor=COLOR,"255,255,255,255"
		Rect=RECT,"18,13,144,288"
		Text=STRING,""
	}
}
"""

func _init() -> void:
	var layout := UiLayoutParser.parse(_synthetic_layout())
	_check(layout != null, "synthetic layout parses")
	if layout == null:
		return  # _initialize still runs, and reports the failure
	var sec := layout.get_section("Create")
	_check(sec != null and sec.controls.size() == 3, "3 controls parsed (got %d)" % (sec.controls.size() if sec != null else -1))

	# The window's size comes from the frame at the origin, not from the
	# bounding box of everything -- that is what makes a window the size the
	# artist drew rather than the size its contents happen to reach.
	var size := UiBuilder.section_size(sec)
	_check(size == Vector2(176, 308), "section_size reads the frame's rect (got %s)" % size)

	# A window CONSUMES mouse input. It was MOUSE_FILTER_PASS, which delivers
	# the event and then keeps propagating it, so every click on window chrome
	# reached World3D._unhandled_input and walked the character, and every
	# wheel over a window zoomed the camera (playtest 2026-09-20, items 5 and
	# 13). STOP does not steal from children -- Godot hit-tests the deepest
	# control first -- it only catches what they did not take.
	var win := HudWindow.new()
	_check(win.mouse_filter == Control.MOUSE_FILTER_STOP,
		"a window consumes mouse input (filter %d, want STOP=%d)" % [win.mouse_filter, Control.MOUSE_FILTER_STOP])
	win.free()

	# A CIFStatic with no artwork and no text is still a text field. Building
	# it as a plain Control is what made every live readout in the HUD --
	# the player block's name and HP/MP among them -- unable to show
	# anything.
	var builder := UiBuilder.new(null, null)
	var label_def: UiLayoutParser.ControlDef = sec.control_by_name["TEST_LABEL"]
	var label := builder.build_control(label_def)
	_check(label is Label, "an empty CIFStatic builds as a Label (got %s)" % label.get_class())

	# A gauge with no artwork of its own still has to draw.
	var gauge_def := UiLayoutParser.ControlDef.new()
	gauge_def.name = "TEST_GAUGE"
	gauge_def.type = "CIFGauge"
	gauge_def.rect = Rect2i(0, 0, 100, 12)
	var gauge := builder.build_control(gauge_def)
	_check(gauge is TextureProgressBar, "a CIFGauge builds as a TextureProgressBar")
	if gauge is TextureProgressBar:
		_check((gauge as TextureProgressBar).texture_progress != null,
			"a gauge with no DDJ still gets a fill texture, so it is visible")

	# A lattice is a grid of slots derived from its pixel rect and the size of
	# its own cell artwork: 144x288 at the 36-pixel pitch of `com_lattice_`
	# is 4 columns by 8 rows. Every one of the archive's 14 lattices divides
	# by 36 exactly and none divides by 32, which is what this once assumed.
	var lattice := builder.build_control(sec.control_by_name["TEST_LATTICE"])
	_check(lattice != null and lattice.get_child_count() == 32,
		"a 144x288 lattice builds 4x8 = 32 cells (got %d)" % (lattice.get_child_count() if lattice != null else -1))

	# Colour is a per-control editor id, not a tint -- see docs/UI_TODO.md.
	# Every control above carries a different one; none may reach modulate.
	_check(label.modulate == Color.WHITE, "Color is not applied as a tint (got %s)" % label.modulate)

	# The HudPanels checks are in _initialize, below, which also reports.

## The HudPanels constant checks, and the report.
##
## These run here and not in _init: hud_panels.gd names the NetClient
## autoload, which a --script suite registers only after _init (round 514's
## measurement, recorded in npc_service_reader_test.gd's check (j)). Naming
## HudPanels by its class_name from _init compiled the script before the
## autoload existed, so every run printed `SCRIPT ERROR: Compile Error:
## Identifier not found: NetClient` and still passed (round 522 found it;
## round 556's harness counts that line as a failure). The script is loaded
## by path, so that nothing compiles it before the autoload exists.
func _initialize() -> void:
	var panels_script := load("res://scripts/ui/hud/hud_panels.gd") as GDScript
	var compiled := panels_script != null and panels_script.can_instantiate()
	_check(compiled, "HudPanels compiles in _initialize, once the NetClient autoload is registered")
	var consts: Dictionary = panels_script.get_script_constant_map() if compiled else {}
	var panels: Dictionary = consts.get("PANELS", {})
	# The underbar's buttons and menu items name panels here (its
	# menu_action); the map is HudUnderbar's since the bar is the client's
	# own CNIFUnderMenuBar (round 598), and HudPanels has no menu of its own.
	var bar_script := load("res://scripts/ui/hud/hud_underbar.gd") as GDScript
	var menu_actions: Dictionary = bar_script.get_script_constant_map().get("MENU_ACTIONS", {}) if bar_script else {}
	# Read by name off the constant map, so a renamed constant fails here
	# rather than letting the two loops below pass over nothing.
	_check(not panels.is_empty() and not menu_actions.is_empty(),
		"HudPanels.PANELS and HudUnderbar.MENU_ACTIONS are non-empty constants (got %d and %d)" % [panels.size(), menu_actions.size()])

	# Every panel HudPanels offers must have a layout path and a title, or
	# open() will fail on a malformed entry at runtime. (The keys left the
	# spec for the key table in round 608; checked against it below.) The
	# path is a `resinfo\*.txt` layout, or a `res_ui\*.2dt` window file for
	# the windows built from those (the guild window's two views, GuildWindow).
	# The `all N` summaries are gated: an empty map (the script did not
	# compile, or a constant was renamed) already FAILs above and must not
	# also print `ok  all 0 ...`, nor may a malformed entry be followed by
	# `all ... are well formed`.
	var bad_specs := 0
	for panel_id in panels:
		var spec: Array = panels[panel_id]
		var path := str(spec[0]) if spec.size() > 0 else ""
		var layout_ok := path.begins_with("resinfo\\") and path.ends_with(".txt")
		var twodt_ok := path.begins_with("res_ui\\") and path.ends_with(".2dt")
		if spec.size() != 2 or not (layout_ok or twodt_ok):
			_check(false, "panel %s has a malformed spec" % panel_id)
			bad_specs += 1
	if not panels.is_empty() and bad_specs == 0:
		_check(true, "all %d panel specs are well formed" % panels.size())

	# Every window key in the key table (KeyMap's "panel:<id>" slots) must
	# open a panel HudPanels has, or the key opens nothing.
	var keymap := load("res://scripts/ui/keymap.gd") as GDScript
	var slots: Array = keymap.get_script_constant_map().get("SLOTS", []) if keymap else []
	var bad_keys := 0
	var window_keys := 0
	for slot in slots:
		var action := str((slot as Dictionary).get("action", ""))
		if action.begins_with("panel:"):
			window_keys += 1
			if not panels.has(action.substr(6)):
				_check(false, "key slot %s opens %s, which is not a known panel" % [slot.get("slot"), action])
				bad_keys += 1
	_check(window_keys > 0, "the key table has window keys (got %d)" % window_keys)
	if window_keys > 0 and bad_keys == 0:
		_check(true, "all %d window keys open real panels" % window_keys)

	# Every panel the underbar's buttons and menu items open must exist, or
	# the bar has an entry that can never open anything.
	var bad_items := 0
	for id in menu_actions:
		# Round 837: the item mall button opens its entry box, not a panel;
		# round 840: item 120 the stall network window (StallNetworkController).
		if not panels.has(menu_actions[id]) and menu_actions[id] != "itemmall_entry" and menu_actions[id] != "stallnetwork":
			_check(false, "underbar item %s opens %s, which is not a known panel" % [id, menu_actions[id]])
			bad_items += 1
	if not menu_actions.is_empty() and bad_items == 0:
		_check(true, "all %d underbar buttons and menu items map to real panels" % menu_actions.size())

	_finish()

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
