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
		_finish()
		return
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

	# Every panel HudPanels offers must have a layout path, a title and a
	# hotkey slot, or open() will fail on a malformed entry at runtime.
	for panel_id in HudPanels.PANELS:
		var spec: Array = HudPanels.PANELS[panel_id]
		if spec.size() != 3 or not (spec[0] as String).begins_with("resinfo\\"):
			_check(false, "panel %s has a malformed spec" % panel_id)
	_check(true, "all %d panel specs are well formed" % HudPanels.PANELS.size())

	# Every id the MENU offers must be a panel that exists, or the menu has
	# an entry that can never open anything.
	for item in HudPanels.MENU_ITEMS:
		if not HudPanels.PANELS.has(item[0]):
			_check(false, "MENU item %s is not a known panel" % item[0])
	_check(true, "all %d MENU items map to real panels" % HudPanels.MENU_ITEMS.size())

	_finish()

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
