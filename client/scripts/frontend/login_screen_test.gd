extends SceneTree

## Round 679: the login screen's fixes.
##   - The logo clears the login box with retail's padding at 1024x768,
##     1920x1080, 2560x1440 and 3840x2160, at UI scales 1.0 and 1.95, and
##     stays where retail puts it where retail's own placement does not
##     overlap (FrontEndFrame on a synthetic layout carrying pstitle's READ
##     rects -- numbers only, no archive data).
##   - The ID / PW / Server fields are centred (pstitle's HAlign=1, READ
##     CIFEdit FUN_00637b70) and the password shows '*' (READ, FUN_00636330).
##   - The Server field shows a listed server's name read-only, and stays an
##     editable host:port without a list.
##
## NEGATIVE: before round 679 the logo reaches into the box at every canvas
## taller than 837 (FAIL lines with the numbers), and Login.gd has no
## style_login_edit / show_server_field (FAIL lines).

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## pstitle.txt's READ rects for the controls these checks place (Title: the
## two bands, the logo, the login window; Login: the three slots and LIST),
## with the HAlign values the Login section carries.
const LAYOUT := """Section = Title,"0,0,0,0","0"
{
	GDR_STA_SCREENUP:CIFStatic
	{
		ID=INTEGER,"1"
		Rect=RECT,"0,0,1600,172"
	}
	GDR_STA_SCREENDOWN:CIFStatic
	{
		ID=INTEGER,"2"
		Rect=RECT,"0,1030,1600,172"
	}
	GDR_STA_LOGO:CIFStatic
	{
		ID=INTEGER,"8"
		Rect=RECT,"540,403,508,172"
	}
	GDR_STA_LOGINWINDOW:CIFStatic
	{
		ID=INTEGER,"9"
		Rect=RECT,"0,0,288,140"
	}
}
Section = Login,"0,0,0,0","0"
{
	GDR_EDIT_ID:CIFEdit
	{
		HAlign=INTEGER,"1"
		ID=INTEGER,"41"
		Rect=RECT,"110,32,135,20"
	}
	GDR_EDIT_PASS:CIFEdit
	{
		HAlign=INTEGER,"1"
		ID=INTEGER,"42"
		Rect=RECT,"110,60,135,20"
	}
	GDR_STA_SERVER:CIFStatic
	{
		HAlign=INTEGER,"1"
		ID=INTEGER,"43"
		Rect=RECT,"110,88,86,20"
	}
}
"""

func _initialize() -> void:
	# The root (and the autoloads' _ready) are in the tree after a frame.
	await process_frame
	_logo()
	_fields()
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES %d" % _failures)
	quit()

# --- The logo ------------------------------------------------------------------

func _logo() -> void:
	var layout := UiLayoutParser.parse(LAYOUT)
	var frame := FrontEndFrame.new()
	root.add_child(frame)
	frame.build(null, null, "", "Ver test", layout)
	# Sized by hand below, not by the root (build anchors it full-rect).
	frame.set_anchors_preset(Control.PRESET_TOP_LEFT)
	for res in [Vector2(1024, 768), Vector2(1920, 1080), Vector2(2560, 1440), Vector2(3840, 2160)]:
		for scale in [1.0, 1.95]:
			# The canvas a UI scale gives: the window's pixels over the scale
			# (ClientSettings.apply_ui_scale, content_scale_factor).
			var canvas := Vector2(floorf(res.x / scale), floorf(res.y / scale))
			frame.size = canvas
			frame.relayout()
			var c := frame.centre_line()
			var box_top := c.y + 6 # READ, FUN_00866760: the login window at mid + 6
			var logo_bottom := frame.logo.position.y + frame.logo.size.y
			var gap := box_top - logo_bottom
			var what := "%dx%d at %.2f (canvas %dx%d): logo %d..%d, box top %d, gap %d" % [
				res.x, res.y, scale, canvas.x, canvas.y, frame.logo.position.y, logo_bottom, box_top, gap]
			# 10: retail's own clearance at the reference's 1024x768 (FrontEndFrame.LOGO_GAP).
			_check(gap >= 10.0 - 0.01, "the logo clears the box by 10 -- " + what)
			var retail_y := c.y + 6 - 0x78
			if retail_y + frame.logo.size.y <= box_top - 10:
				_check(is_equal_approx(frame.logo.position.y, retail_y), "where retail's placement fits it is kept (y %d) -- %s" % [retail_y, what])
			_check(frame.logo.position.y >= 172.0 * canvas.y / 1200.0 - 1.0, "the logo stays below the top band -- " + what)
			_check(is_equal_approx(frame.logo.position.x + frame.logo.size.x * 0.5, c.x) or absf(frame.logo.position.x + frame.logo.size.x * 0.5 - c.x) <= 1.0,
				"the logo stays centred -- " + what)
	# The reference resolution exactly as retail: 325x110 at (cx - 162, mid - 114).
	frame.size = Vector2(1024, 768)
	frame.relayout()
	var c768 := frame.centre_line()
	_check(frame.logo.size == Vector2(325, 110) and frame.logo.position == Vector2(c768.x - 162, c768.y - 114),
		"1024x768: retail's own size and place, %s at %s" % [frame.logo.size, frame.logo.position])
	frame.queue_free()

# --- The fields ----------------------------------------------------------------

func _fields() -> void:
	var layout := UiLayoutParser.parse(LAYOUT)
	var login := load("res://scripts/Login.gd") as GDScript
	_check(login != null and login.can_instantiate(), "Login.gd compiles")
	if login == null:
		return
	var methods := login.get_script_method_list().map(func(m: Dictionary) -> String: return m["name"])
	_check(methods.has("style_login_edit") and methods.has("show_server_field"), "Login.gd has style_login_edit and show_server_field")
	if not (methods.has("style_login_edit") and methods.has("show_server_field")):
		return
	var pw := LineEdit.new()
	var id := LineEdit.new()
	var defs := {}
	for c in layout.sections["Login"].controls:
		defs[c.id] = c
	login.call("style_login_edit", pw, defs[42], true)
	login.call("style_login_edit", id, defs[41], false)
	pw.text = "secret12"
	_check(pw.secret and pw.secret_character == "*", "the password is masked with '*' (secret_character '%s')" % pw.secret_character)
	_check(pw.alignment == HORIZONTAL_ALIGNMENT_CENTER and id.alignment == HORIZONTAL_ALIGNMENT_CENTER, "ID and PW are centred (HAlign=1)")
	_check(not id.secret, "the ID is not masked")

	var server := LineEdit.new()
	login.call("style_login_edit", server, defs[43], false)
	_check(server.alignment == HORIZONTAL_ALIGNMENT_CENTER, "the Server field is centred")
	# ClientConfig through load(), so this suite still parses where it does not
	# exist (round 679's negative).
	var config_script := load("res://scripts/setting/client_config.gd") as GDScript
	_check(config_script != null, "ClientConfig exists")
	if config_script == null:
		return
	var cfg = config_script.call("from_text", "servers:\n  FirstServer:\n    gateway: { address: login.example.com }\n  Second:\n    gateway: { address: 192.0.2.5, port: 1234 }\n", "t", PackedStringArray())
	var entry = cfg.pick_server("Second")
	login.call("show_server_field", server, entry, "127.0.0.1:15779")
	_check(server.text == "Second" and not server.editable and server.focus_mode == Control.FOCUS_NONE,
		"with servers listed: the vanity name, read-only ('%s', editable %s)" % [server.text, server.editable])
	_check(server.tooltip_text == "192.0.2.5:1234", "its address is the tooltip")
	var plain := LineEdit.new()
	login.call("style_login_edit", plain, defs[43], false)
	login.call("show_server_field", plain, null, "192.168.1.23:15779")
	_check(plain.text == "192.168.1.23:15779" and plain.editable and plain.focus_mode == Control.FOCUS_ALL,
		"without servers: the typed host:port, editable")
	_check(plain.caret_column == plain.text.length(), "a long address shows its end (round 678)")
	for n in [pw, id, server, plain]:
		n.free()

	# Round 679's review: a slot's field, styled into a window in the tree, is
	# the slot's 20 tall -- sized outside the tree it was clamped to the
	# default theme's minimum, 31, its text 5.5 low -- and its text's middle
	# is the slot's (retail centres vertically: VAlign=1, FUN_00637b70). The
	# text's place is LineEdit's own (Godot 4.2.2 scene/gui/line_edit.cpp,
	# DRAW: offset.y + (height - style minimum - text height) / 2).
	var window := Control.new()
	root.add_child(window)
	for id_ in [41, 42, 43]:
		var f := LineEdit.new()
		login.call("style_login_edit", f, defs[id_], id_ == 42, window)
		var d: UiLayoutParser.ControlDef = defs[id_]
		f.text = "tester"
		var sb := f.get_theme_stylebox("normal")
		var fs := f.get_theme_font_size("font_size")
		var th := f.get_theme_font("font").get_height(fs)
		var text_mid := f.position.y + sb.get_offset().y + (f.size.y - sb.get_minimum_size().y - th) * 0.5 + th * 0.5
		var slot_mid := d.rect.position.y + d.rect.size.y * 0.5
		_check(f.size == Vector2(d.rect.size), "slot %d: the field is the slot's %s once in the tree (got %s)" % [id_, Vector2(d.rect.size), f.size])
		_check(absf(text_mid - slot_mid) <= 1.0, "slot %d: the text's middle %.1f is the slot's %.1f" % [id_, text_mid, slot_mid])
	window.queue_free()

