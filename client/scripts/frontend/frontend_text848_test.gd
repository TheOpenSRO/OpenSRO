extends SceneTree

## Round 848, lane R: the front end's own text as the original draws it.
##   godot4 --headless --path client --script res://scripts/frontend/frontend_text848_test.gd
##
## - FrontEndUi.apply_font: the screen's theme carries font 0's 12 px as its
##   default size (READ, CIFWnd's constructor gives every window's text font
##   0), so a Label with no size of its own draws at 12, not Godot's 16.
## - FrontEndFrame: the version line is a CIFStatic's text (READ): 12 px, the
##   colour 0xffff8080, centred both ways in its 80 x 20 rect at (5, H - 25),
##   no outline; the operator's copyright line (OURS) 12 px, white, centred.
## - The title's message line draws with a 1 px black shadow and no outline
##   (READ, style 1 of its CIFTextBox line): FrontEndUi.text_shadow.
## - The select screen's name label (READ, SCharacterInfo +0x2dc): 12 px,
##   white, no outline; centred on its point, the item 14 rows; the box
##   0x40000000 under it, 16 rows from one row above the cell, 2 px either
##   side; the fade is the glyphs' alone and the box shows while it is not 0.
## - The image-code window's explanation (READ, CIFPML): built from its record
##   (a holder with the record and a PmlText in its FontColor / HAlign), and
##   CIFPML's VAlign: the content moved down by half the room left.
## - NPC_NAME_COLOUR is white (READ).
##
## NEGATIVE (fails before lane R): the theme had no default size (16), the
## version line had no size and was left / top aligned, the name label was
## 20 px with an outline of 3 and no box, the explanation a bare Label,
## FrontEndUi.apply_font / text_shadow, CaptchaWindow.valign_pml and
## CharSelectNameLabel did not exist (the suite does not parse).


var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	var watchdog := create_timer(60.0)
	watchdog.timeout.connect(func() -> void:
		print("FAIL the suite never reported (a script error stopped it)")
		quit(1))
	await process_frame
	await _theme_size()
	await _frame_lines()
	_message_shadow()
	await _name_label()
	await _captcha_explain()
	var world := load("res://scripts/World3D.gd") as GDScript
	_check(world != null and world.get_script_constant_map().get("NPC_NAME_COLOUR") == Color(1, 1, 1),
		"an NPC's name is white (READ)")
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES %d" % _failures)
	quit()

func _theme_size() -> void:
	var host := Control.new()
	host.size = Vector2(400, 200)
	root.add_child(host)
	var l := Label.new()
	l.text = "Ver 0.1.612"
	host.add_child(l)
	await process_frame
	var before := l.get_theme_font_size(&"font_size")
	FrontEndUi.apply_font(host, ThemeDB.fallback_font)
	await process_frame
	_check(host.theme != null and host.theme.default_font_size == UiBuilder.FONT_SIZES[0],
		"the screen's theme: font 0's %d px as the default size" % UiBuilder.FONT_SIZES[0])
	_check(before == 16 and l.get_theme_font_size(&"font_size") == 12,
		"a Label with no size of its own: %d px -> %d px" % [before, l.get_theme_font_size(&"font_size")])
	var r := RichTextLabel.new()
	r.text = "x"
	host.add_child(r)
	_check(r.get_theme_font_size(&"normal_font_size") == 12, "a RichTextLabel's too")
	host.queue_free()
	await process_frame

func _frame_lines() -> void:
	var host := Control.new()
	host.size = Vector2(1280, 720)
	root.add_child(host)
	FrontEndUi.apply_font(host, ThemeDB.fallback_font)
	var layout := UiLayoutParser.LayoutDef.new()
	var title := UiLayoutParser.SectionDef.new()
	title.name = "Title"
	var down := UiLayoutParser.ControlDef.new()
	down.id = FrontEndFrame.ID_SCREENDOWN
	down.rect = Rect2i(0, 1028, 1600, 172)
	title.controls.append(down)
	layout.sections["Title"] = title
	var theme := FrontEndTheme.new()
	theme.copyright = "(c) An Operator"
	var f := FrontEndFrame.new()
	host.add_child(f)
	f.size = host.size
	_check(f.build(null, theme, "", "Ver 0.1.612", layout), "the frame builds from a layout")
	f.relayout()
	await process_frame
	var v := f.version_label
	_check(v != null and v.get_theme_font_size(&"font_size") == 12 and v.has_theme_font_size_override(&"font_size"),
		"the version line: font 0, 12 px (READ, CIFStatic's text)")
	_check(v.get_theme_color(&"font_color") == Color8(255, 128, 128, 255), "its colour 0xffff8080 (READ)")
	_check(v.horizontal_alignment == HORIZONTAL_ALIGNMENT_CENTER and v.vertical_alignment == VERTICAL_ALIGNMENT_CENTER,
		"centred both ways in its rect (READ, CTextBoard's HAlign 1 / VAlign 1)")
	_check(v.get_theme_constant(&"outline_size") == 0, "no outline")
	_check(v.position == Vector2(5, 720 - 25) and v.size == Vector2(80, 20),
		"at (5, H - 25), 80 x 20: %s %s" % [v.position, v.size])
	var c := f.copyright_label
	_check(c != null and c.visible and c.get_theme_font_size(&"font_size") == 12, "the operator's line: 12 px (OURS)")
	_check(c.get_theme_color(&"font_color") == Color.WHITE and c.horizontal_alignment == HORIZONTAL_ALIGNMENT_CENTER,
		"white, centred")
	host.queue_free()
	await process_frame

func _message_shadow() -> void:
	var l := Label.new()
	l.add_theme_constant_override("outline_size", 3)
	FrontEndUi.text_shadow(l)
	_check(l.get_theme_constant(&"outline_size") == 0 and l.get_theme_constant(&"shadow_offset_x") == 1
		and l.get_theme_constant(&"shadow_offset_y") == 1 and l.get_theme_constant(&"shadow_outline_size") == 0
		and l.get_theme_color(&"font_shadow_color") == Color(0, 0, 0, 1),
		"the message line: a black shadow at (+1, +1), no outline (READ, style 1)")
	l.free()
	var src := FileAccess.get_file_as_string("res://scripts/Login.gd")
	var at := src.find("status_label = Label.new()")
	var block := src.substr(at, 1600) if at >= 0 else ""
	_check(block.contains("FrontEndUi.text_shadow(status_label)") and not block.contains("\"outline_size\", 3"),
		"Login's message line takes the shadow, not an outline of 3")

func _name_label() -> void:
	var host := Control.new()
	host.size = Vector2(1280, 720)
	root.add_child(host)
	FrontEndUi.apply_font(host, ThemeDB.fallback_font)
	var l: Label = CharSelectNameLabel.make()
	l.text = "QA_Aria"
	host.add_child(l)
	await process_frame
	_check(l.get_theme_font_size(&"font_size") == 12, "the name: font 0's 12 px, not font 4's 20 (READ, 0x8b3bd0)")
	_check(l.get_theme_color(&"font_color") == Color.WHITE and l.get_theme_constant(&"outline_size") == 0,
		"white, no outline (READ, the item's constructor)")
	var box := l.get_node("Box") as ColorRect
	_check(box != null and box.color == Color(0, 0, 0, 64.0 / 255.0) and box.show_behind_parent,
		"the box 0x40000000 behind it (READ, 0x8b3bf3)")
	_check(not box.visible and l.self_modulate.a == 0.0, "hidden at alpha 0 (vslot_013 draws it only while the byte is not 0)")
	CharSelectNameLabel.set_alpha(l, 0.5)
	_check(box.visible and l.self_modulate.a == 0.5 and l.modulate.a == 1.0 and is_equal_approx(box.color.a, 64.0 / 255.0),
		"mid-fade: the glyphs at 0.5, the box at its own 64/255 (READ, 0x8b4909): %s %s %s %s" % [box.visible,
			l.self_modulate.a, l.modulate.a, box.color.a])
	var at := Vector2(640.6, 300.9)
	CharSelectNameLabel.place(l, at)
	var font := l.get_theme_font(&"font")
	var w := ceilf(font.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x)
	var item := Vector2(float(int(at.x - float(int(w) >> 1))), float(int(at.y - 7.0)))
	var cell_top := l.position.y + font.get_ascent(12) - NamePlates.cell_ascent(font, 12)
	_check(l.position.x == item.x and absf(cell_top - item.y) < 0.01,
		"the item centred on the point: cell top-left %s, expected %s" % [Vector2(l.position.x, cell_top), item])
	var box_global := l.position + box.position
	_check(box.size == Vector2(w + 4.0, 16.0) and absf(box_global.y - (item.y - 1.0)) < 0.01 and box_global.x == item.x - 2.0,
		"the box: 16 rows from one above the cell, 2 px either side: %s %s" % [box_global, box.size])
	CharSelectNameLabel.set_alpha(l, 0.0)
	_check(not box.visible, "faded out: no box")
	var src := FileAccess.get_file_as_string("res://scripts/CharacterSelect.gd")
	_check(not src.contains("UiBuilder.FONT_SIZES[4])\n\t\tl.add_theme_color_override(\"font_outline_color\""),
		"the select screen no longer makes its names at font 4 with an outline")
	host.queue_free()
	await process_frame

func _captcha_explain() -> void:
	var w := CaptchaWindow.new()
	w.build(UiBuilder.new(null, null))
	root.add_child(w)
	await process_frame
	var ex := w.explain
	_check(ex != null and not (ex is Label) and ex.has_meta(UiBuilder.PML_DEF_META),
		"the explanation is built from its CIFPML record, not a Label of our own")
	var p := ex.get_node_or_null("PmlText") as PmlText if ex != null else null
	_check(p != null and p.base_align == PmlText.TAG_CENTER and p.default_color == Color.WHITE,
		"a PmlText in the record's FontColor and HAlign 1")
	_check(p != null and p.plain_lines().size() >= 1 and "".join(p.plain_lines()).contains("Type the characters"),
		"showing the notice")
	w.queue_free()
	var q := PmlText.new()
	root.add_child(q)
	q.size = Vector2(336, 40)
	q.setup(ThemeDB.fallback_font, 12, Color.WHITE)
	q.set_markup("<sml2>One line.</sml2>")
	var h := q.content_height
	CaptchaWindow.valign_pml(q, 1, 40)
	_check(h > 0 and h < 40 and q.position.y == float((40 - h) >> 1) and q.size.y == 40.0 - float((40 - h) >> 1),
		"VAlign 1: the content moved down by (40 - %d) >> 1 = %d (READ, 0x64b3b1..0x64b3da)" % [h, int(q.position.y)])
	CaptchaWindow.valign_pml(q, 2, 40)
	_check(q.position.y == float(40 - h), "VAlign 2: by all the room")
	CaptchaWindow.valign_pml(q, 0, 40)
	_check(q.position.y == 0.0, "VAlign 0: from the top")
	q.set_markup("<sml2>a<br>b<br>c<br>d</sml2>")
	CaptchaWindow.valign_pml(q, 1, 40)
	_check(q.content_height >= 40 and q.position.y == 0.0, "content as tall as the rect: not moved")
	q.queue_free()
	await process_frame
