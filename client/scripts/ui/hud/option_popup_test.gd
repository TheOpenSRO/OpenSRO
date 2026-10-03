extends SceneTree

## The Option window's open combo list (round 697; ComboList from round 700):
## the READ values of CNIFComboBox / CNIFPopupListCtrl / CNIFListCtrl, the
## MEASURED geometry of the user's 2x reference picture, and the list's
## behaviour -- opens on a press, picks, closes on Escape and an outside click,
## moves with the keys and the wheel. No game data: the frame pieces are plain
## 4 x 4 images here.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _piece(c: Color) -> Texture2D:
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img.fill(c)
	return ImageTexture.create_from_image(img)

func _test_values() -> void:
	_check(ComboList.FILL == Color8(0, 0, 0, 0xb4) and OptionVideoPage.POPUP_FILL == ComboList.FILL, "fill 0xb4000000: black at alpha 0xb4")
	_check(ComboList.TEXT == Color8(255, 255, 255), "text 0xffffffff")
	_check(ComboList.TEXT_HOVER == Color8(255, 255, 128), "hover text 0xffffff80")
	_check(ComboList.BAR == Color8(128, 128, 255), "hover bar 0xff8080ff")
	_check(ComboList.TOP == 20 and ComboList.INSET == 4 and ComboList.LINE_EXTRA == 4,
		"placed 20 below the combo's top, list inset 4, line = font + 4")
	_check(ComboList.FONT_POINTS == UiBuilder.FONT_POINT_SIZES[0] and ComboList.line_height() == 13,
		"the line is font index 0's 9 points + 4 = 13 (READ), the reference's 26 px at 2x (MEASURED)")

## The reference: Graphic Quality (a 150 x 20 record), five items, at 2x --
## the list's frame from y 152 to 297 and x 348 to 607 against the field's
## top row at y 112 and x 348 (MEASURED).
func _test_geometry() -> void:
	var r := ComboList.rect_for(Vector2(150, 20), 5)
	_check(r == Rect2(0, 20, 130, 73), "a 150 x 20 combo with 5 items: the list at (0, 20), 130 x 73 = the field's width, 5 x 13 + 8 tall (got %s)" % str(r))
	_check(r.position * 2.0 == Vector2(0, 40) and r.size * 2.0 == Vector2(260, 146),
		"at 2x: 40 below the field's top, 260 wide, 146 tall -- the reference's 152 - 112, 608 - 348, 298 - 152")
	_check(ComboList.rect_for(Vector2(156, 18), 3) == Rect2(0, 20, 136, 47), "Resolution's 156 x 18 record: 136 wide, 3 x 13 + 8")
	_check(ComboList.row_rect(r.size, 0) == Rect2(4, 4, 122, 13) and ComboList.row_rect(r.size, 4) == Rect2(4, 56, 122, 13),
		"rows 13 apart from 4 in")
	_check(ComboList.row_at(r.size, 5, Vector2(60, 4)) == 0 and ComboList.row_at(r.size, 5, Vector2(60, 16.9)) == 0
		and ComboList.row_at(r.size, 5, Vector2(60, 17)) == 1 and ComboList.row_at(r.size, 5, Vector2(60, 68.9)) == 4,
		"the row under a point")
	_check(ComboList.row_at(r.size, 5, Vector2(60, 3)) == -1 and ComboList.row_at(r.size, 5, Vector2(60, 69)) == -1
		and ComboList.row_at(r.size, 5, Vector2(2, 30)) == -1 and ComboList.row_at(r.size, 5, Vector2(127, 30)) == -1,
		"none on the frame or the inset")
	_check(ComboList.text_x(130, 22) == 54.0 and ComboList.text_x(130, 23) == 53.0,
		"text centred in the row: 4 + floor((122 - w) / 2)")
	# Centred on the field's centre, as the value text: the field text rect is
	# {5, 0, W-30, H}, centre (W-20)/2 = 65, the list's centre 130 / 2 = 65.
	var w := 40.0
	_check(is_equal_approx(ComboList.text_x(130, w) + w / 2.0, OptionVideoPage.combo_text_rect(Vector2(150, 20)).get_center().x),
		"the list's text is centred where the field's value is (65 of a 150-wide combo)")
	_check(ComboList.fit_y(500, 73, 600) == 500 and ComboList.fit_y(560, 73, 600) == 527 and ComboList.fit_y(10, 700, 600) == 0,
		"a list that would run off the bottom moves up to fit (OURS)")

func _test_frame() -> void:
	var pieces := {"left_up": _piece(Color8(1, 0, 0)), "right_up": _piece(Color8(2, 0, 0)),
		"left_down": _piece(Color8(3, 0, 0)), "right_down": _piece(Color8(4, 0, 0)),
		"left_side": _piece(Color8(5, 0, 0)), "right_side": _piece(Color8(6, 0, 0))}
	var sb := OptionVideoPage.popup_panel(pieces) as StyleBoxTexture
	var img := sb.texture.get_image()
	_check(img.get_width() == 12 and img.get_height() == 12, "a 12 x 12 nine-patch")
	_check(img.get_pixel(0, 0).is_equal_approx(Color8(1, 0, 0)) and img.get_pixel(11, 11).is_equal_approx(Color8(4, 0, 0)), "corners in their corners")
	_check(img.get_pixel(0, 6).is_equal_approx(Color8(5, 0, 0)) and img.get_pixel(11, 6).is_equal_approx(Color8(6, 0, 0)), "left_side / right_side down the sides")
	_check(img.get_pixel(6, 0).is_equal_approx(Color8(5, 0, 0)) and img.get_pixel(6, 11).is_equal_approx(Color8(6, 0, 0)), "and transposed along the top / bottom")
	_check(img.get_pixel(6, 6).is_equal_approx(ComboList.FILL), "the translucent fill inside")
	_check(is_equal_approx(sb.get_texture_margin(SIDE_LEFT), 4.0), "4-pixel margins")
	var bare := OptionVideoPage.popup_panel({}) as StyleBoxTexture
	_check(bare.texture.get_image().get_pixel(6, 6).is_equal_approx(ComboList.FILL), "no pieces: the panel is the fill")

func _press(button: int, at: Vector2, pressed: bool = true) -> InputEventMouseButton:
	var e := InputEventMouseButton.new()
	e.button_index = button
	e.pressed = pressed
	e.position = at
	e.global_position = at
	return e

func _key(k: Key) -> InputEventKey:
	var e := InputEventKey.new()
	e.keycode = k
	e.pressed = true
	return e

func _test_behaviour() -> void:
	# The headless window is 64 x 64: fit the list into a real screen's
	# height, or it is moved up (fit_y) and the clicks below miss.
	ComboList.view_height_for_test = 720.0
	var host := Control.new()
	host.position = Vector2(100, 50)
	host.size = Vector2(150, 20)
	root.add_child(host)
	var combo := OptionButton.new()
	combo.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	host.add_child(combo)
	# The tree runs its first frame before a node counts as inside it.
	await process_frame
	_check(combo.is_inside_tree(), "the combo is in the tree")
	for t in ["Low", "Middle", "High", "Large scale battle", "User control"]:
		combo.add_item(t)
	combo.select(1)
	OptionVideoPage.attach_list(combo, {}, null)
	var picked: Array = []
	combo.item_selected.connect(func(i: int) -> void: picked.append(i))
	_check(combo.has_meta(OptionVideoPage.LIST_META), "the combo is wired to ComboList")
	combo.gui_input.emit(_press(MOUSE_BUTTON_LEFT, Vector2(10, 10)))
	var list := ComboList.current()
	_check(list != null and list.is_open(), "a left press opens the list")
	_check(not combo.get_popup().visible, "and not Godot's PopupMenu")
	if list == null:
		host.free()
		return
	_check(list.get_parent() is CanvasLayer and (list.get_parent() as CanvasLayer).layer == ComboList.LAYER
		and list.get_parent().get_parent() == root, "on its own CanvasLayer over the game, in the game's window (not a Window of its own)")
	_check(list.items.size() == 5 and list.items[3] == "Large scale battle", "the combo's items")
	# Canvas placement: host at (100, 50), the list at y + 20.
	_check(list.to_canvas * list.list_rect.position == Vector2(100, 70), "drawn at the combo's x and 20 below its top (got %s)" % str(list.to_canvas * list.list_rect.position))
	# Hover by motion, over row 2.
	var mm := InputEventMouseMotion.new()
	mm.position = Vector2(100 + 60, 70 + 4 + 13 * 2 + 5)
	list._gui_input(mm)
	_check(list.hover == 2, "the mouse over row 2 lights it (got %d)" % list.hover)
	# Keys and the wheel.
	list._input(_key(KEY_DOWN))
	_check(list.hover == 3, "Down moves the bar a row")
	list._gui_input(_press(MOUSE_BUTTON_WHEEL_UP, Vector2(0, 0)))
	_check(list.hover == 2, "the wheel moves it back")
	list._input(_key(KEY_ENTER))
	_check(ComboList.current() == null and combo.selected == 2 and picked == [2], "Enter picks the lit row: selected and item_selected (got %s %s)" % [combo.selected, str(picked)])
	# A click on a row.
	combo.gui_input.emit(_press(MOUSE_BUTTON_LEFT, Vector2(10, 10)))
	list = ComboList.current()
	list._gui_input(_press(MOUSE_BUTTON_LEFT, Vector2(160, 70 + 4 + 13 * 4 + 6)))
	_check(ComboList.current() == null and combo.selected == 4 and picked == [2, 4], "a click on a row picks it")
	# Re-picking the shown row: no signal unless allow_reselect.
	combo.gui_input.emit(_press(MOUSE_BUTTON_LEFT, Vector2(10, 10)))
	ComboList.current()._gui_input(_press(MOUSE_BUTTON_LEFT, Vector2(160, 70 + 4 + 13 * 4 + 6)))
	_check(picked == [2, 4], "the shown row again: nothing (allow_reselect off)")
	combo.allow_reselect = true
	combo.gui_input.emit(_press(MOUSE_BUTTON_LEFT, Vector2(10, 10)))
	ComboList.current()._gui_input(_press(MOUSE_BUTTON_LEFT, Vector2(160, 70 + 4 + 13 * 4 + 6)))
	_check(picked == [2, 4, 4], "with allow_reselect: item_selected again")
	# Outside click, Escape.
	combo.gui_input.emit(_press(MOUSE_BUTTON_LEFT, Vector2(10, 10)))
	ComboList.current()._gui_input(_press(MOUSE_BUTTON_LEFT, Vector2(600, 400)))
	_check(ComboList.current() == null and combo.selected == 4, "a click outside closes it, nothing picked")
	combo.gui_input.emit(_press(MOUSE_BUTTON_LEFT, Vector2(10, 10)))
	ComboList.current()._input(_key(KEY_ESCAPE))
	_check(ComboList.current() == null, "Escape closes it")
	# Greyed rows are skipped and cannot be picked; a disabled combo does not open.
	combo.set_item_disabled(3, true)
	combo.gui_input.emit(_press(MOUSE_BUTTON_LEFT, Vector2(10, 10)))
	list = ComboList.current()
	list.hover = 2
	list.step(1)
	_check(list.hover == 4, "Down skips a greyed row")
	list.choose(3)
	_check(ComboList.current() != null and combo.selected == 4, "a greyed row is not picked")
	list.close()
	combo.disabled = true
	combo.gui_input.emit(_press(MOUSE_BUTTON_LEFT, Vector2(10, 10)))
	_check(ComboList.current() == null, "a disabled combo does not open")
	combo.disabled = false
	# The combo going away takes the list with it.
	combo.gui_input.emit(_press(MOUSE_BUTTON_LEFT, Vector2(10, 10)))
	list = ComboList.current()
	host.hide()
	list._process(0.0)
	_check(ComboList.current() == null, "hiding the window closes the list")
	ComboList.view_height_for_test = 0.0
	host.free()

## Round 700 review, H1: through the viewport, as a player's mouse arrives --
## a press that picks a row or closes the list from outside, then its
## release: the release must not reach any node's _unhandled_input (World3D
## takes an unhandled left release as a world click and repeats it).
func _test_release_does_not_leak() -> void:
	ComboList.view_height_for_test = 720.0
	var probe_script := GDScript.new()
	probe_script.source_code = "extends Node\nvar seen: Array = []\nfunc _unhandled_input(e: InputEvent) -> void:\n\tif e is InputEventMouseButton:\n\t\tseen.append([(e as InputEventMouseButton).button_index, (e as InputEventMouseButton).pressed])\n"
	probe_script.reload()
	var probe := Node.new()
	probe.set_script(probe_script)
	root.add_child(probe)
	var host := Control.new()
	# Everything inside the headless window's 64 x 64: the combo at (2, 2),
	# a two-item list from y 22 to 56, "outside" at (30, 60).
	host.position = Vector2(2, 2)
	host.size = Vector2(150, 20)
	root.add_child(host)
	var combo := OptionButton.new()
	combo.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	host.add_child(combo)
	for t in ["Low", "Middle"]:
		combo.add_item(t)
	OptionVideoPage.attach_list(combo, {}, null)
	await process_frame
	var picked: Array = []
	combo.item_selected.connect(func(i: int) -> void: picked.append(i))
	var at_combo := Vector2(30, 10)
	var row1 := Vector2(30, 2 + 20 + 4 + 13 + 6)
	# Open: press and release on the combo.
	root.push_input(_press(MOUSE_BUTTON_LEFT, at_combo))
	root.push_input(_press(MOUSE_BUTTON_LEFT, at_combo, false))
	_check(ComboList.current() != null, "through the viewport: a click on the combo opens the list")
	_check(probe.get("seen").is_empty(), "and neither its press nor its release reaches _unhandled_input (%s)" % str(probe.get("seen")))
	# Pick row 1: the press picks, the release must be eaten.
	root.push_input(_press(MOUSE_BUTTON_LEFT, row1))
	_check(picked == [1] and ComboList.current() == null, "the press on row 1 picks it (%s)" % str(picked))
	root.push_input(_press(MOUSE_BUTTON_LEFT, row1, false))
	_check(probe.get("seen").is_empty(), "the row click's release does not reach _unhandled_input (%s)" % str(probe.get("seen")))
	await process_frame
	# Close from outside: the same.
	root.push_input(_press(MOUSE_BUTTON_LEFT, at_combo))
	root.push_input(_press(MOUSE_BUTTON_LEFT, at_combo, false))
	var outside := Vector2(30, 60)
	root.push_input(_press(MOUSE_BUTTON_LEFT, outside))
	_check(ComboList.current() == null, "a press outside closes it")
	root.push_input(_press(MOUSE_BUTTON_LEFT, outside, false))
	_check(probe.get("seen").is_empty(), "the outside click's release does not reach _unhandled_input (%s)" % str(probe.get("seen")))
	await process_frame
	await process_frame
	var layers := 0
	for c in root.get_children():
		if c is CanvasLayer and (c as CanvasLayer).layer == ComboList.LAYER:
			layers += 1
	_check(layers == 0, "the layer is gone after the release (%d left)" % layers)
	# And after it, a world click is the world's again.
	root.push_input(_press(MOUSE_BUTTON_LEFT, outside))
	root.push_input(_press(MOUSE_BUTTON_LEFT, outside, false))
	_check(probe.get("seen").size() == 2, "with the list gone the next click reaches _unhandled_input (%s)" % str(probe.get("seen")))
	ComboList.view_height_for_test = 0.0
	host.free()
	probe.free()

func _initialize() -> void:
	_test_values()
	_test_geometry()
	_test_frame()
	await _test_behaviour()
	await _test_release_does_not_leak()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
