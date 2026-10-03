extends SceneTree

## The Option window's open combo list (round 697): the PopupMenu wears the
## values read from CNIFComboBox / CNIFPopupListCtrl / CNIFListCtrl. No game
## data: the frame pieces are plain 4 x 4 images here.

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
	_check(OptionVideoPage.POPUP_FILL == Color8(0, 0, 0, 0xb4), "fill 0xb4000000: black at alpha 0xb4")
	_check(OptionVideoPage.POPUP_TEXT == Color8(255, 255, 255), "text 0xffffffff")
	_check(OptionVideoPage.POPUP_TEXT_HOVER == Color8(255, 255, 128), "hover text 0xffffff80")
	_check(OptionVideoPage.POPUP_HOVER_BAR == Color8(128, 128, 255), "hover bar 0xff8080ff")
	_check(OptionVideoPage.POPUP_TOP == 20 and OptionVideoPage.POPUP_INSET == 4 and OptionVideoPage.POPUP_LINE_EXTRA == 4,
		"placed 20 below the combo's top, list inset 4, line = font + 4")

func _test_style() -> void:
	var combo := OptionButton.new()
	for i in 5:
		combo.add_item("Item %d" % i)
	OptionVideoPage.style_popup(combo, {}, null)
	var pm := combo.get_popup()
	var panel := pm.get_theme_stylebox("panel")
	_check(panel is StyleBoxTexture, "the panel is a texture box")
	var tex := (panel as StyleBoxTexture).texture
	var img := tex.get_image() if tex != null else null
	_check(img != null and img.get_pixel(6, 6).is_equal_approx(OptionVideoPage.POPUP_FILL), "no pieces: the panel is the fill")
	_check(is_equal_approx(panel.content_margin_left, 4.0) and is_equal_approx(panel.content_margin_right, 4.0), "4 px in at the sides")
	_check(is_equal_approx(panel.content_margin_top, 2.0) and is_equal_approx(panel.content_margin_bottom, 10.0),
		"2 + half the line gap = 4 to the first text; rows x line + 8 tall")
	var bar := pm.get_theme_stylebox("hover")
	_check(bar is StyleBoxFlat and (bar as StyleBoxFlat).bg_color == OptionVideoPage.POPUP_HOVER_BAR, "hover bar colour")
	_check(is_equal_approx((bar as StyleBoxFlat).expand_margin_top, -2.0) and is_equal_approx((bar as StyleBoxFlat).expand_margin_bottom, -2.0),
		"the bar is the text's height, not the row's")
	_check(pm.get_theme_constant("v_separation") == 4, "line gap 4")
	_check(pm.get_theme_color("font_color") == OptionVideoPage.POPUP_TEXT and pm.get_theme_color("font_hover_color") == OptionVideoPage.POPUP_TEXT_HOVER,
		"text colours")
	_check(pm.get_theme_icon("radio_checked").get_width() == 1 and pm.get_theme_icon("radio_unchecked").get_width() == 1, "no radio marks")
	combo.free()

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
	_check(img.get_pixel(6, 6).is_equal_approx(OptionVideoPage.POPUP_FILL), "the fill inside")
	_check(is_equal_approx(sb.get_texture_margin(SIDE_LEFT), 4.0), "4-pixel margins")

func _init() -> void:
	_test_values()
	_test_style()
	_test_frame()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
