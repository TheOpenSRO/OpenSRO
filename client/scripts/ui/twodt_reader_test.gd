extends SceneTree

## TwoDtReader and TwoDtBuilder on synthetic `.2dt` bytes built here: no
## game data (docs/LEGAL.md). docs/protocol/2DT_FORMAT.md is the format.
##
## The scripts are reached through load() rather than their class names, so
## that a tree without them FAILS here instead of failing to compile:
##   godot4 --headless --path client --script res://scripts/ui/twodt_reader_test.gd

const READER_PATH := "res://scripts/ui/twodt_reader.gd"
const BUILDER_PATH := "res://scripts/ui/twodt_builder.gd"
const RECORD := 0x3d0

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _init() -> void:
	_run()
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)

## One 976-byte record, laid out at the loader's offsets.
func _rec(f: Dictionary) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(RECORD)
	b.fill(0)
	_put_str(b, 0x000, f.get("name", ""))
	_put_str(b, 0x040, f.get("base", ""))
	_put_str(b, 0x140, f.get("tex", ""))
	_put_str(b, 0x240, f.get("textid", ""))
	_put_str(b, 0x2c0, f.get("desc", ""))
	_put_str(b, 0x300, f.get("sample", ""))
	b.encode_u32(0x340, f.get("type", 5))
	b.encode_u32(0x344, f.get("id", 0))
	b.encode_u32(0x348, f.get("parent", 0))
	b.encode_u32(0x34c, f.get("gp", 0))
	b.encode_u32(0x358, f.get("color", 0xffffffff))
	var r: Rect2i = f.get("rect", Rect2i())
	b.encode_s32(0x35c, r.position.x)
	b.encode_s32(0x360, r.position.y)
	b.encode_s32(0x364, r.size.x)
	b.encode_s32(0x368, r.size.y)
	var uv := [0.0, 0.0, 1.0, 0.0, 1.0, 1.0, 0.0, 1.0]
	for k in 8:
		b.encode_float(0x36c + 4 * k, uv[k])
	b.encode_u32(0x38c, f.get("group", 0))
	b.encode_u32(0x390, f.get("pane", 0xffffffff))
	b.encode_u32(0x394, 1 if f.get("root", false) else 0)
	b[0x39b] = f.get("font", 0)
	b[0x3cd] = f.get("halign", 1)
	b[0x3ce] = f.get("valign", 1)
	return b

func _put_str(b: PackedByteArray, at: int, s: String) -> void:
	var bytes := s.to_ascii_buffer()
	for i in bytes.size():
		b[at + i] = bytes[i]

func _file(records: Array) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(4)
	out.encode_u32(0, records.size())
	for r in records:
		out.append_array(_rec(r))
	return out

## A small window with the shapes the real files have: a root frame at a
## screen position, two panes whose children repeat ids (5 under both), a
## grandchild that only its grandparent id can place, a record with parent 0
## one naming a parent that does not exist, and a second id 5 under pane 10,
## which the linker's GetChild guard leaves under the root.
func _sample() -> Array:
	return [
		{"type": 0, "id": 100, "rect": Rect2i(50, 60, 300, 200), "root": true, "name": "CNIFTestWnd"},
		{"type": 2, "id": 42, "parent": 100, "base": "t\\tile.ddj", "rect": Rect2i(52, 62, 296, 196)},
		{"type": 16, "id": 72, "parent": 100, "tex": "t\\tab_a_off.ddj", "group": 10, "pane": 10, "rect": Rect2i(60, 70, 72, 24)},
		{"type": 16, "id": 73, "parent": 100, "tex": "t\\tab_b_off.ddj", "group": 10, "pane": 20, "rect": Rect2i(140, 70, 72, 24)},
		{"type": 1, "id": 10, "parent": 100, "base": "t\\win_", "rect": Rect2i(60, 100, 200, 100)},
		{"type": 1, "id": 20, "parent": 100, "base": "t\\win_", "rect": Rect2i(60, 100, 200, 100)},
		{"type": 5, "id": 5, "parent": 10, "gp": 100, "rect": Rect2i(70, 110, 50, 15), "textid": "UIIT_T_LABEL", "color": 0xffefdaa4, "halign": 2, "valign": 0},
		{"type": 15, "id": 5, "parent": 20, "gp": 100, "tex": "t\\bar_left.ddj", "rect": Rect2i(70, 120, 150, 24)},
		{"type": 5, "id": 7, "parent": 5, "gp": 20, "rect": Rect2i(75, 124, 40, 15), "sample": "SAMPLE-TEXT", "desc": "comment"},
		{"type": 4, "id": 30, "parent": 100, "tex": "t\\btn.ddj", "textid": "UIIT_T_BUTTON", "rect": Rect2i(250, 230, 60, 24), "color": 0xfffff7ca},
		{"type": 5, "id": 31, "parent": 0, "rect": Rect2i(60, 250, 10, 10)},
		{"type": 5, "id": 32, "parent": 999, "gp": 100, "rect": Rect2i(80, 250, 10, 10)},
		{"type": 11, "id": 33, "parent": 10, "gp": 100, "tex": "t\\check_on.ddj", "rect": Rect2i(200, 110, 14, 14)},
		{"type": 0, "id": 34, "parent": 100, "rect": Rect2i(60, 60, 200, 180)},
		{"type": 5, "id": 5, "parent": 10, "gp": 100, "rect": Rect2i(70, 140, 20, 15)},
	]

func _text_table() -> UiTextTable:
	var rows := PackedStringArray()
	for pair in [["UIIT_T_LABEL", "tt leader :"], ["UIIT_T_BUTTON", "tt invite"]]:
		rows.append("1\t%s\t\t\t\t\t\t\t%s" % pair)
	return UiTextTable.parse(("\n".join(rows)).to_utf16_buffer())

func _tex(builder: UiBuilder, path: String, size: Vector2i) -> Texture2D:
	var img := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.4, 0.3, 0.2, 1.0))
	var t := ImageTexture.create_from_image(img)
	(builder.get("_texture_cache") as Dictionary)[path.to_lower()] = t
	return t

func _run() -> void:
	var Reader = load(READER_PATH)
	var Builder = load(BUILDER_PATH)
	_check(Reader != null, "the .2dt reader exists (%s)" % READER_PATH)
	_check(Builder != null, "the .2dt builder exists (%s)" % BUILDER_PATH)
	if Reader == null or Builder == null:
		return

	# --- the container -------------------------------------------------------
	var bytes := _file(_sample())
	_check(bytes.size() == 4 + 15 * 976, "the fixture is 4 + 15 * 976 bytes (got %d)" % bytes.size())
	var file = Reader.parse(bytes)
	_check(file != null and file.records.size() == 15, "a well-formed file parses into its 15 records")
	if file == null:
		return
	var long := bytes.duplicate()
	long.append(0)
	_check(Reader.parse(long) == null, "one trailing byte is refused (not 4 + n*976)")
	_check(Reader.parse(bytes.slice(0, bytes.size() - 1)) == null, "one missing byte is refused")
	_check(Reader.parse(PackedByteArray([1, 0])) == null, "a file shorter than its count is refused")
	var lying := bytes.duplicate()
	lying.encode_u32(0, 16)
	_check(Reader.parse(lying) == null, "a count that disagrees with the size is refused")
	var empty := PackedByteArray([0, 0, 0, 0])
	var none = Reader.parse(empty)
	_check(none != null and none.records.is_empty(), "a zero count with no records parses, empty")

	# --- the fields ----------------------------------------------------------
	var r0 = file.records[0]
	_check(r0.name == "CNIFTestWnd" and r0.type == 0 and r0.id == 100 and r0.is_root,
		"record 0: class name, type, id and the root flag")
	_check(r0.rect == Rect2i(50, 60, 300, 200), "record 0's rect is x, y, w, h at 0x35c")
	var lbl = file.records[6]
	_check(lbl.text_id == "UIIT_T_LABEL" and lbl.color == 0xffefdaa4 and lbl.halign == 2 and lbl.valign == 0,
		"text id at 0x240, colour at 0x358, alignment bytes at 0x3cd / 0x3ce")
	var tab = file.records[2]
	_check(tab.tab_group == 10 and tab.tab_pane == 10, "a tab's group (0x38c) and pane (0x390)")
	_check(file.records[1].tab_pane == Reader.NO_PANE, "0xffffffff at 0x390 reads as no pane")
	var grand = file.records[8]
	_check(grand.sample_bytes == "SAMPLE-TEXT".to_ascii_buffer() and grand.text_id == "",
		"the sample text at 0x300 is kept as bytes, apart from the text id")

	# --- parents: ids repeat, so (parent, grandparent) decides ---------------
	_check(file.records[4].parent_index == 0 and file.records[5].parent_index == 0,
		"both panes hang under the root (grandparent 0 = the load parent)")
	_check(file.records[6].parent_index == 4, "static 5 with grandparent 100 goes under pane 10 (record 4)")
	_check(file.records[7].parent_index == 5, "bar 5 goes under pane 20 (record 5)")
	_check(grand.parent_index == 7,
		"id 7 names parent 5 twice over; grandparent 20 picks the bar (record 7), not the static (got %d)" % grand.parent_index)
	_check(file.records[10].parent_index == 0 and file.unresolved.has(10), "parent 0 stays under the root")
	_check(file.records[11].parent_index == 0 and file.unresolved.has(11), "a parent that does not exist stays under the root")
	_check(file.unresolved.size() == 2 and file.ambiguous.is_empty(), "two unresolved, none ambiguous")
	var kept: Array = Array(file.get("kept_under_root")) if "kept_under_root" in file else []
	_check(file.records[14].parent_index == 0 and kept == [14] and not (14 in file.records[4].children),
		"a second id 5 under pane 10 is not re-linked (GetChild guard, 0x48cbf7): it stays under the root (got %s, parent %d)" % [kept, file.records[14].parent_index])
	_check(Array(file.records[4].children) == [6, 12], "children are kept in file order (got %s)" % [file.records[4].children])
	_check(file.local_rect(8) == Rect2i(5, 4, 40, 15),
		"a record's rect is its root-relative rect less its parent's (got %s)" % file.local_rect(8))
	_check(file.rect_in_root(8) == Rect2i(25, 64, 40, 15), "the root-relative rect is authored less record 0's")

	# --- the builder ---------------------------------------------------------
	var ui := UiBuilder.new(null, _text_table())
	for piece in ["left_up", "mid_up", "right_up", "left_side", "right_side", "left_down", "mid_down", "right_down"]:
		_tex(ui, "t\\win_" + piece + ".ddj", Vector2i(16, 16))
		_tex(ui, "interface\\frame\\mframe_wnd_" + piece + ".ddj", Vector2i(40, 68 if piece.ends_with("up") else (48 if piece.ends_with("down") else 128)))
	_tex(ui, "t\\tile.ddj", Vector2i(128, 128))
	var tab_on := _tex(ui, "t\\tab_a_on.ddj", Vector2i(72, 24))
	var tab_off := _tex(ui, "t\\tab_a_off.ddj", Vector2i(72, 24))
	_tex(ui, "t\\tab_b_on.ddj", Vector2i(72, 24))
	_tex(ui, "t\\tab_b_off.ddj", Vector2i(72, 24))
	var bar_l := _tex(ui, "t\\bar_left.ddj", Vector2i(4, 24))
	var bar_m := _tex(ui, "t\\bar_mid.ddj", Vector2i(24, 24))
	var bar_r := _tex(ui, "t\\bar_right.ddj", Vector2i(4, 24))
	var btn_n := _tex(ui, "t\\btn.ddj", Vector2i(60, 24))
	var btn_f := _tex(ui, "t\\btn_focus.ddj", Vector2i(60, 24))
	var btn_p := _tex(ui, "t\\btn_press.ddj", Vector2i(60, 24))
	var chk_on := _tex(ui, "t\\check_on.ddj", Vector2i(14, 14))
	var chk_off := _tex(ui, "t\\check_off.ddj", Vector2i(14, 14))
	var builder = Builder.new(ui)
	var root: Control = builder.build(file, "sample")
	_check(root != null, "the file builds")
	if root == null:
		return
	get_root().add_child(root)
	_check(root.position == Vector2.ZERO and root.size == Vector2(300, 200),
		"the root is left at (0, 0) at its own size (got %s %s)" % [root.position, root.size])
	var pane10: Control = Builder.child(root, 10)
	var pane20: Control = Builder.child(root, 20)
	_check(pane10 != null and pane10.position == Vector2(10, 40) and pane10.size == Vector2(200, 100),
		"pane 10 at its authored rect less the root's: (10, 40) 200x100")
	var s5: Control = Builder.child(pane10, 5)
	var b5: Control = Builder.child(pane20, 5)
	_check(s5 != null and b5 != null and s5 != b5, "id 5 is found once under each pane (GetChild is direct children only)")
	var s7: Control = Builder.find_path(root, [20, 5, 7])
	_check(s7 != null and s7.position == Vector2(5, 4), "20 -> 5 -> 7 sits (5, 4) inside the bar (got %s)" % (s7.position if s7 else null))
	_check(Builder.child(root, 31) != null and Builder.child(root, 32) != null, "the two unresolved records are the root's children")

	# Back to front, in file order: the tile first, the panes after it.
	var order := root.get_children().filter(func(c): return c.has_meta("twodt_id")).map(func(c): return int(c.get_meta("twodt_id")))
	_check(order == [42, 72, 73, 10, 20, 30, 31, 32, 34, 5], "children in file order, the tile backmost (got %s)" % [order])

	# Text: the text id through the table; the sample text and comment never drawn.
	_check(Builder.text_of(s5) == "tt leader :", "the text id resolves through the text table (got '%s')" % Builder.text_of(s5))
	var label := s5.get_node_or_null("Text") as Label
	_check(label != null and label.get_theme_color("font_color") == Color8(0xef, 0xda, 0xa4, 0xff),
		"the record's colour is the text colour")
	_check(s5.modulate == Color.WHITE and s5.self_modulate == Color.WHITE, "and never a tint")
	_check(label != null and label.horizontal_alignment == HORIZONTAL_ALIGNMENT_RIGHT and label.vertical_alignment == VERTICAL_ALIGNMENT_TOP,
		"halign 2 / valign 0 give right / top (the inferred mapping)")
	var drawn := PackedStringArray()
	for n in root.find_children("*", "Label", true, false):
		drawn.append((n as Label).text)
	_check(not ("SAMPLE-TEXT" in drawn) and not ("comment" in drawn), "no sample text or comment is drawn anywhere (drawn: %s)" % [drawn])
	_check(s7.get_node_or_null("Text") == null, "a record with no text id gets no label")

	# Per-type pieces.
	var tile := Builder.child(root, 42) as TextureRect
	_check(tile != null and tile.stretch_mode == TextureRect.STRETCH_TILE, "type 2 is one tiled texture")
	var main_pieces := root.get_children().filter(func(c): return c is TextureRect and not c.has_meta("twodt_id"))
	_check(main_pieces.size() == 8, "the root MainFrame with no base draws mframe_wnd_'s eight pieces (got %d)" % main_pieces.size())
	var bar_tex := b5.find_children("*", "TextureRect", true, false).map(func(t): return (t as TextureRect).texture)
	_check(bar_tex == [bar_l, bar_m, bar_r], "a bar naming bar_left.ddj draws bar_left / bar_mid / bar_right")
	var btn := Builder.child(root, 30) as TextureButton
	_check(btn != null and btn.texture_normal == btn_n and btn.texture_hover == btn_f and btn.texture_pressed == btn_p and btn.texture_disabled == null,
		"a button takes _focus / _press, and no _disable when the archive has none")
	_check(Builder.text_of(btn) == "tt invite", "a button's caption is its text id")
	var chk := Builder.find_path(root, [10, 33]) as TextureButton
	var mark := chk.get_node_or_null("Mark") as TextureRect if chk != null else null
	_check(chk != null and chk.texture_normal == chk_off and mark != null and mark.texture == chk_on and not mark.visible,
		"a check box: off is the box, on the mark drawn over it, unchecked at first")
	if chk != null and mark != null:
		chk.button_pressed = true
		_check(mark.visible and chk.texture_normal == chk_off, "checked, the mark shows over the box")
	var mf34: Control = Builder.child(root, 34)
	_check(mf34 != null and mf34.get_children().filter(func(c): return c is TextureRect).size() == 8,
		"a nested MainFrame with an empty base takes mframe_wnd_ too")

	# Tabs: SetCheck and a click.
	var t72 := Builder.child(root, 72) as TextureButton
	var t73 := Builder.child(root, 73) as TextureButton
	Builder.set_tab_checked(t72, true)
	Builder.set_tab_checked(t73, false)
	_check(t72.texture_normal == tab_on and Builder.is_checked(t72), "a checked tab shows its on piece")
	_check(pane10.visible and not pane20.visible, "SetCheck shows the checked tab's pane and hides the other's")
	Builder.click_tab(t73)
	_check(Builder.is_checked(t73) and not Builder.is_checked(t72) and t72.texture_normal == tab_off,
		"clicking the other tab checks it and unchecks the first")
	_check(pane20.visible and not pane10.visible, "and swaps the panes")
	t72.pressed.emit()
	_check(Builder.is_checked(t72) and pane10.visible and not pane20.visible, "the button's own press runs the same click")
