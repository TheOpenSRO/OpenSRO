extends SceneTree

const UiBuilder = preload("res://scripts/ui/ui_builder.gd")
const UiLayoutParser = preload("res://scripts/ui/ui_layout_parser.gd")
const UiTextTable = preload("res://scripts/ui/ui_text_table.gd")

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _init() -> void:
	var text_data := "1\tUIIT_STT_TEST\t테스트\t\t\t\t\t\tTestButton\n".to_utf16_buffer()
	var text_table := UiTextTable.parse(text_data)

	var layout_text := """
Interface Text

Section = Create,"0,0,200,100","0"
{
	GDR_BTN:CIFButton
	{
		Rect=RECT,"10,20,80,30"
		Text=STRING,"UIIT_STT_TEST"
	}
	GDR_LBL:CIFStatic
	{
		Rect=RECT,"100,20,90,30"
		Text=STRING,"StaticLabel"
		HAlign=INTEGER,"1"
	}
	GDR_GAUGE:CIFGauge
	{
		Rect=RECT,"10,60,180,10"
	}
	GDR_TILE:CIFNormalTile
	{
		Rect=RECT,"0,0,200,24"
	}
	GDR_FRAME:CIFFrame
	{
		Rect=RECT,"0,0,200,100"
	}
}
"""
	var layout := UiLayoutParser.parse(layout_text)
	var builder := UiBuilder.new(null, text_table)
	var root := builder.build_section(layout, "Create")

	_check(root != null, "root is non-null")
	_check(root.name == "Create", "root name is Create")
	_check(root.get_child_count() == 5, "root has 5 children")

	# **Draw order.** A section lists its controls front to back -- the frame
	# is always last -- and Godot draws children in tree order, so they go in
	# reversed. Built the other way round, a window's frame and background
	# tiles cover its own contents.
	_check(root.get_child(0).name == "GDR_FRAME",
		"the last-declared control is the first child, i.e. the backmost")
	_check(root.get_child(root.get_child_count() - 1).name == "GDR_BTN",
		"the first-declared control is the last child, i.e. the frontmost")

	var btn := root.get_node_or_null("GDR_BTN") as TextureButton
	_check(btn != null, "found GDR_BTN as TextureButton")
	_check(btn.position == Vector2(10, 20), "btn position is (10, 20)")
	_check(btn.size == Vector2(80, 30), "btn size is (80, 30)")
	var btn_lbl := btn.get_node_or_null("ButtonLabel") as Label
	_check(btn_lbl != null and btn_lbl.text == "TestButton", "btn label translated to TestButton")

	var lbl := root.get_node_or_null("GDR_LBL") as Label
	_check(lbl != null, "found GDR_LBL as Label")
	_check(lbl.position == Vector2(100, 20), "lbl position is (100, 20)")
	_check(lbl.text == "StaticLabel", "lbl text is StaticLabel")
	_check(lbl.horizontal_alignment == HORIZONTAL_ALIGNMENT_CENTER, "lbl alignment is center")

	var gauge := root.get_node_or_null("GDR_GAUGE") as TextureProgressBar
	_check(gauge != null, "found GDR_GAUGE as TextureProgressBar")
	_check(gauge.position == Vector2(10, 60), "gauge position is (10, 60)")
	_check(gauge.size == Vector2(180, 10), "gauge size is (180, 10)")

	root.free()

	_check_section_size()
	_check_lattice()
	_check_slice_base_beats_the_type_name()
	_check_font_table()
	_check_frame_pieces_at_own_size()
	_check_six_piece_edges_rotated()
	_check_edit_halign_and_client_rect()
	_check_section_size_measures_what_is_drawn()
	_check_text_overrun_follows_alignment()
	_check_client_rect_style_and_captions()

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		push_error("%d failure(s)" % _failures)
		quit(1)

## A window is its frame *plus* anything hanging off it. ifinventory's gold
## row sits below the frame's bottom edge, and sizing to the frame alone
## left it outside the window.
func _check_section_size() -> void:
	var layout := UiLayoutParser.parse("""
Interface Text

Section = Create,"0,0,0,0","0"
{
	GDR_MONEY:CIFStatic
	{
		Rect=RECT,"0,305,176,28"
		DDJ=STRING,"interface\\inventory\\int_window_downbox.ddj"
	}
	GDR_TEXT_OVERRUN:CIFStatic
	{
		Rect=RECT,"153,144,228,11"
	}
	GDR_FRAME:CIFFrame
	{
		Rect=RECT,"0,0,176,308"
	}
}
""")
	var sec := layout.get_section("Create")
	_check(sec != null, "section parsed for the size check")
	if sec == null:
		return
	_check(UiBuilder.section_size(sec) == Vector2(176, 333),
		"window size covers the frame and the art below it, and is not widened by a text field that overruns (got %s)" % str(UiBuilder.section_size(sec)))

## A lattice's grid comes from its artwork, not from a fixed cell size.
## With no archive to read art from the fallback pitch applies, which is the
## real one: every lattice in the archive divides by 36 exactly, and none
## divides by 32.
func _check_lattice() -> void:
	var layout := UiLayoutParser.parse("""
Interface Text

Section = Create,"0,0,0,0","0"
{
	GDR_LAT:CIFLattice
	{
		Rect=RECT,"18,13,144,288"
		DDJ=STRING,"interface\\ifcommon\\lattice_window\\com_lattice_"
	}
}
""")
	var builder := UiBuilder.new(null, null)
	var root := builder.build_section(layout, "Create")
	var grid := root.get_node_or_null("GDR_LAT")
	_check(grid != null, "lattice built")
	if grid == null:
		root.free()
		return
	_check(grid.get_child_count() == 32,
		"the inventory lattice is 4x8 = 32 cells, not 4x9 (got %d)" % grid.get_child_count())
	var cell := grid.get_node_or_null("Cell0") as Control
	_check(cell != null and cell.size == Vector2(36, 36),
		"a cell is 36x36 (got %s)" % (str(cell.size) if cell != null else "-"))
	var last := grid.get_node_or_null("Cell31") as Control
	_check(last != null and last.position == Vector2(3 * 36, 7 * 36),
		"the last cell sits at the far corner of the grid (got %s)" % (str(last.position) if last != null else "-"))
	root.free()

## A control whose `ddj` ends in an underscore names an 8-slice base and is
## built as a frame whatever its type is called. 496 controls across the
## archive do, spread over 220 type names -- matching on the name reached
## four of them and left the rest as empty Controls, which is what made the
## skill, quest and guild windows see-through.
func _check_slice_base_beats_the_type_name() -> void:
	var layout := UiLayoutParser.parse("""
Interface Text

Section = Create,"0,0,0,0","0"
{
	GDR_BOARD:CIFSkillBoard
	{
		Rect=RECT,"6,29,351,270"
		DDJ=STRING,"interface\\inventory\\int_window_"
	}
	GDR_PLAIN:CIFSomethingElse
	{
		Rect=RECT,"0,0,10,10"
	}
}
""")
	var builder := UiBuilder.new(null, null)
	var root := builder.build_section(layout, "Create")
	var board := root.get_node_or_null("GDR_BOARD")
	_check(board != null and board.get_class() == "Control",
		"an unknown type with an 8-slice base still builds (got %s)" % (board.get_class() if board != null else "-"))
	_check(board != null and board.position == Vector2(6, 29) and board.size == Vector2(351, 270),
		"it keeps its authored rect (got %s)" % (str(board.size) if board != null else "-"))
	var plain := root.get_node_or_null("GDR_PLAIN")
	_check(plain != null, "an unknown type with no artwork still builds")
	root.free()

	# The decision itself, which is what routes those 496 controls.
	_check(UiBuilder.is_slice_base("interface\\inventory\\int_window_"),
		"a trailing underscore marks an 8-slice base")
	_check(not UiBuilder.is_slice_base("interface\\ifcommon\\com_windowclose.ddj"),
		"a .ddj path is a texture, not a base")
	_check(not UiBuilder.is_slice_base(""),
		"no artwork is not a base")

## The font table's two halves that need no archive: every pixel size is the
## client's own `-MulDiv(points, 96, 72)` of its point size (nearest
## rounding, as MulDiv does), and the face name falls back to the binary's
## own default when there is neither a text table nor an archive to ask.
func _check_font_table() -> void:
	_check(UiBuilder.FONT_POINT_SIZES.size() == 5 and UiBuilder.FONT_SIZES.size() == 5,
		"five FontIndex entries, as FUN_00469350 registers")
	for i in range(UiBuilder.FONT_POINT_SIZES.size()):
		var pt: int = UiBuilder.FONT_POINT_SIZES[i]
		var px: int = int(round(pt * 96.0 / 72.0))
		_check(UiBuilder.FONT_SIZES[i] == px,
			"FontIndex %d: %dpt -> %dpx em (table says %d)" % [i, pt, px, UiBuilder.FONT_SIZES[i]])
	_check(UiBuilder.FONT_SIZES[0] == 12, "index 0, the common one, is a 12px em")
	var bare := UiBuilder.new(null, null)
	_check(bare.ui_face_name() == UiBuilder.FONT_NAME_BINARY_DEFAULT,
		"no table, no archive: the binary's default face '%s'" % UiBuilder.FONT_NAME_BINARY_DEFAULT)
	_check(bare.font_at(0) == null and bare.font_count() == 0,
		"no archive: no font (Godot's default), not a crash")
	var with_name := UiTextTable.parse("1\tUIC_STT_FONTNAME\t굴림체\t0\t0\t0\t0\t0\t0\tTahoma\n".to_utf16_buffer())
	_check(UiBuilder.new(null, with_name).ui_face_name() == "Tahoma",
		"the text table's UIC_STT_FONTNAME English column names the face")

## A builder with no archive, holding synthetic pieces in its texture cache
## under `test\<base>_<suffix>.ddj`, each a blank texture of the given size.
func _synthetic_builder(pieces: Dictionary) -> UiBuilder:
	var builder := UiBuilder.new(null, null)
	for key in pieces:
		var sz: Vector2i = pieces[key]
		var img := Image.create(sz.x, sz.y, false, Image.FORMAT_RGBA8)
		builder._texture_cache[String(key).to_lower()] = ImageTexture.create_from_image(img)
	return builder

## The eight pieces of a frame built from `base` at `rect`, keyed by suffix.
func _frame_pieces(builder: UiBuilder, base: String, rect: String) -> Dictionary:
	var layout := UiLayoutParser.parse("""
Interface Text

Section = Create,"0,0,0,0","0"
{
	GDR_FRAME:CIFFrame
	{
		Rect=RECT,"%s"
		DDJ=STRING,"%s"
	}
}
""" % [rect, base])
	var root := builder.build_section(layout, "Create")
	var by_tex := {}
	for key in builder._texture_cache:
		var parts := String(key).split("\\")[-1].trim_suffix(".ddj").split("_")
		by_tex[builder._texture_cache[key].get_instance_id()] = parts[-2] + "_" + parts[-1]
	var out := {}
	var frame := root.get_node_or_null("GDR_FRAME")
	if frame != null:
		for child in frame.get_children():
			if child is TextureRect and (child as TextureRect).texture != null:
				out[by_tex.get((child as TextureRect).texture.get_instance_id(), "?")] = Rect2(child.position, child.size)
	root.free()
	return out

func _check_piece(pieces: Dictionary, suffix: String, want: Rect2, what: String) -> void:
	var got: Variant = pieces.get(suffix)
	_check(got == want, "%s: %s at %s (got %s)" % [what, suffix, str(want), str(got)])

## **Every frame piece at its own size.** The client's CNIFFrame
## (FUN_00474d00 / FUN_004736a0) draws each corner at that corner's own
## width and height and tiles each edge at its own thickness across the gap
## between the corners it meets. Sizing all eight from left_up stretched
## sframe_wnd_'s 16-tall bottom corners to 36 and drew its bottom edge 36
## tall; setting the size before EXPAND_IGNORE_SIZE clamped a 65-tall side
## rail up to its 128-tall texture.
func _check_frame_pieces_at_own_size() -> void:
	# sframe_wnd_'s real piece sizes: 36-tall top, 16-tall bottom.
	var s := _synthetic_builder({
		"test\\sf_left_up.ddj": Vector2i(16, 36), "test\\sf_mid_up.ddj": Vector2i(128, 36),
		"test\\sf_right_up.ddj": Vector2i(16, 36), "test\\sf_left_side.ddj": Vector2i(16, 128),
		"test\\sf_right_side.ddj": Vector2i(16, 128), "test\\sf_left_down.ddj": Vector2i(16, 16),
		"test\\sf_mid_down.ddj": Vector2i(128, 16), "test\\sf_right_down.ddj": Vector2i(16, 16)})
	# The Action window's GDR_ACTION_BG_CTRL: 364x117, shorter than the side piece.
	var p := _frame_pieces(s, "test\\sf_", "0,0,364,117")
	_check(p.size() == 8, "all eight pieces are built (got %d)" % p.size())
	_check_piece(p, "left_up", Rect2(0, 0, 16, 36), "sframe 364x117")
	_check_piece(p, "mid_up", Rect2(16, 0, 332, 36), "sframe 364x117")
	_check_piece(p, "right_up", Rect2(348, 0, 16, 36), "sframe 364x117")
	_check_piece(p, "left_side", Rect2(0, 36, 16, 65), "sframe 364x117, not clamped to the 128-tall texture")
	_check_piece(p, "right_side", Rect2(348, 36, 16, 65), "sframe 364x117, not clamped to the 128-tall texture")
	_check_piece(p, "left_down", Rect2(0, 101, 16, 16), "sframe 364x117, bottom corner at its own 16")
	_check_piece(p, "mid_down", Rect2(16, 101, 332, 16), "sframe 364x117, bottom edge at its own 16")
	_check_piece(p, "right_down", Rect2(348, 101, 16, 16), "sframe 364x117, bottom corner at its own 16")

	# game_window_'s shape: 42x42 corners around 8-thick edges.
	var g := _synthetic_builder({
		"test\\gw_left_up.ddj": Vector2i(42, 42), "test\\gw_mid_up.ddj": Vector2i(56, 8),
		"test\\gw_right_up.ddj": Vector2i(42, 42), "test\\gw_left_side.ddj": Vector2i(8, 160),
		"test\\gw_right_side.ddj": Vector2i(8, 160), "test\\gw_left_down.ddj": Vector2i(42, 42),
		"test\\gw_mid_down.ddj": Vector2i(56, 8), "test\\gw_right_down.ddj": Vector2i(42, 42)})
	p = _frame_pieces(g, "test\\gw_", "0,0,200,150")
	_check_piece(p, "mid_up", Rect2(42, 0, 116, 8), "game_window 200x150, top edge 8 thick")
	_check_piece(p, "left_side", Rect2(0, 42, 8, 66), "game_window 200x150, left edge 8 wide, not clamped to 160")
	_check_piece(p, "right_side", Rect2(192, 42, 8, 66), "game_window 200x150, right edge flush right")
	_check_piece(p, "mid_down", Rect2(42, 142, 116, 8), "game_window 200x150, bottom edge flush bottom")
	_check_piece(p, "right_down", Rect2(158, 108, 42, 42), "game_window 200x150")

	# opt_inner_box_'s shape: an edge thicker than the corners it meets.
	var o := _synthetic_builder({
		"test\\ob_left_up.ddj": Vector2i(20, 24), "test\\ob_mid_up.ddj": Vector2i(64, 28),
		"test\\ob_right_up.ddj": Vector2i(20, 24), "test\\ob_left_side.ddj": Vector2i(20, 64),
		"test\\ob_right_side.ddj": Vector2i(20, 64), "test\\ob_left_down.ddj": Vector2i(20, 24),
		"test\\ob_mid_down.ddj": Vector2i(64, 12), "test\\ob_right_down.ddj": Vector2i(20, 24)})
	p = _frame_pieces(o, "test\\ob_", "0,0,120,100")
	_check_piece(p, "mid_up", Rect2(20, 0, 80, 28), "opt_inner_box 120x100, top edge its own 28")
	_check_piece(p, "mid_down", Rect2(20, 88, 80, 12), "opt_inner_box 120x100, bottom edge its own 12")
	_check_piece(p, "left_side", Rect2(0, 24, 20, 52), "opt_inner_box 120x100, side spans corner to corner")

	# Every edge spans exactly the gap between the corners it meets.
	p = _frame_pieces(s, "test\\sf_", "0,0,236,241")
	var lu: Rect2 = p.get("left_up", Rect2()); var ru: Rect2 = p.get("right_up", Rect2())
	var ld: Rect2 = p.get("left_down", Rect2()); var rd: Rect2 = p.get("right_down", Rect2())
	var mu: Rect2 = p.get("mid_up", Rect2()); var md: Rect2 = p.get("mid_down", Rect2())
	var ls: Rect2 = p.get("left_side", Rect2()); var rs: Rect2 = p.get("right_side", Rect2())
	_check(mu.position.x == lu.end.x and mu.end.x == ru.position.x, "top edge spans left_up..right_up (%s)" % str(mu))
	_check(md.position.x == ld.end.x and md.end.x == rd.position.x, "bottom edge spans left_down..right_down (%s)" % str(md))
	_check(ls.position.y == lu.end.y and ls.end.y == ld.position.y, "left edge spans left_up..left_down (%s)" % str(ls))
	_check(rs.position.y == ru.end.y and rs.end.y == rd.position.y, "right edge spans right_up..right_down (%s)" % str(rs))

## **A six-piece set's top and bottom are its sides laid on their side**
## (round 718). com_blacksquare_'s right_side is a 4x4 tile with a grey
## column 3; tiled upright along the bottom it drew the vertical ticks the
## user reported under party matching's boxes. CNIFStretchWnd's edge mode 3
## (0x49a410 -> 0x49a6b0) maps the top and bottom quads TL (0,1), TR (0,0),
## BR (1,0), BL (1,1): the texture turned 90 degrees clockwise, a column
## becoming a row.
func _check_six_piece_edges_rotated() -> void:
	var builder := UiBuilder.new(null, null)
	var grey := Color8(0x7B, 0x79, 0x7B)
	var red := Color(1, 0, 0)
	for suffix in ["left_up", "right_up", "left_down", "right_down", "left_side", "right_side"]:
		var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
		img.fill(Color(0, 0, 0))
		for y in 4:
			if suffix == "right_side":
				img.set_pixel(3, y, grey)
			elif suffix == "left_side":
				img.set_pixel(0, y, red)
		builder._texture_cache[("test\\bs_%s.ddj" % suffix).to_lower()] = ImageTexture.create_from_image(img)
	var layout := UiLayoutParser.parse("""
Interface Text

Section = Create,"0,0,0,0","0"
{
	GDR_BOX:CIFStretchWnd
	{
		Rect=RECT,"0,0,40,20"
		DDJ=STRING,"test\\bs_"
	}
}
""")
	var root := builder.build_section(layout, "Create")
	var box := root.get_node_or_null("GDR_BOX")
	var top: TextureRect = null
	var bottom: TextureRect = null
	if box != null:
		for child in box.get_children():
			if child is TextureRect and child.size.x > 4:
				if child.position.y == 0:
					top = child
				elif child.position.y == 16:
					bottom = child
	_check(bottom != null and bottom.size == Vector2(32, 4), "the bottom strip spans 4..36 at y 16, 4 tall (got %s)" % (str(Rect2(bottom.position, bottom.size)) if bottom != null else "none"))
	if bottom != null:
		var bi := bottom.texture.get_image()
		var row3 := true
		var col3 := true
		for i in 4:
			row3 = row3 and bi.get_pixel(i, 3).is_equal_approx(grey)
			col3 = col3 and bi.get_pixel(3, i).is_equal_approx(grey)
		_check(row3 and not col3, "the bottom draws right_side's grey column as its last ROW, not a column of ticks")
	if top != null:
		var ti := top.texture.get_image()
		var row0 := true
		for i in 4:
			row0 = row0 and ti.get_pixel(i, 0).is_equal_approx(red)
		_check(row0 and not ti.get_pixel(0, 3).is_equal_approx(red), "the top draws left_side's column 0 as its first row")
	else:
		_check(false, "the top strip is built")
	# Its edges are stretched with point sampling, not tiled (review F4: mode
	# 3's 0/1 UVs, the draw's SetSamplerState).
	if bottom != null:
		_check(bottom.stretch_mode == TextureRect.STRETCH_SCALE and bottom.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST,
			"a six-piece edge is stretched and point-sampled")
	root.free()

## **A CIFEdit** (round 718 review F2/F6): HAlign 2 is right-aligned 2 px in
## (0x637cad, 2.0 at 0xe1b898); ClientRect's insets are the text margins.
func _check_edit_halign_and_client_rect() -> void:
	var builder := UiBuilder.new(null, null)
	var text := "Interface Text\n\nSection = Create,\"0,0,0,0\",\"0\"\n{\n\tGDR_E:CIFEdit\n\t{\n\t\tRect=RECT,\"0,0,81,11\"\n\t\tClientRect=RECT,\"7,5,7,5\"\n\t\tHAlign=INTEGER,\"2\"\n\t}\n}\n"
	var root := builder.build_section(UiLayoutParser.parse(text), "Create")
	var e := root.get_node_or_null("GDR_E") as LineEdit
	_check(e != null and e.alignment == HORIZONTAL_ALIGNMENT_RIGHT, "HAlign 2 right-aligns the edit")
	if e != null:
		var sb := e.get_theme_stylebox("normal")
		_check(sb is StyleBoxEmpty and sb.content_margin_left == 7 and sb.content_margin_top == 5
			and sb.content_margin_right == 9 and sb.content_margin_bottom == 5,
			"ClientRect 7,5,7,5 plus the 2 px right inset (got %s)" % str([sb.content_margin_left, sb.content_margin_top, sb.content_margin_right, sb.content_margin_bottom]))
	root.free()

## **A window is sized from what it draws.** A zero-size rect draws its art at
## the art's own size, so it counts at that size (ifparty's buttons at
## y=339, 24 tall, below a 303-tall frame); a control parked at x=9999, as 13
## of ifexchange's are, is not drawn in the window and does not count.
func _check_section_size_measures_what_is_drawn() -> void:
	var layout := UiLayoutParser.parse("""
Interface Text

Section = Create,"0,0,0,0","0"
{
	GDR_TEXT_BOX_FRAME_BG:CIFNormalTile
	{
		Rect=RECT,"9999,342,337,87"
		DDJ=STRING,"test\\tile.ddj"
	}
	GDR_USER_LINE:CIFStatic
	{
		Rect=RECT,"9999,61,8,116"
		DDJ=STRING,"test\\line.ddj"
	}
	GDR_BTN_MATCH:CIFButton
	{
		Rect=RECT,"230,339,0,0"
		DDJ=STRING,"test\\button.ddj"
	}
	GDR_FRAME:CIFFrame
	{
		Rect=RECT,"0,0,364,303"
	}
}
""")
	var sec := layout.get_section("Create")
	_check(sec != null, "section parsed for the drawn-size check")
	if sec == null:
		return
	# No builder: nothing can say how big the zero-size button is (it counts
	# as the point at its origin, y=339), but the parked controls are already
	# excluded.
	_check(UiBuilder.section_size(sec) == Vector2(364, 339),
		"controls parked at x=9999 do not widen the window (got %s)" % str(UiBuilder.section_size(sec)))
	var b := _synthetic_builder({"test\\button.ddj": Vector2i(76, 24),
		"test\\tile.ddj": Vector2i(64, 64), "test\\line.ddj": Vector2i(8, 116)})
	_check(UiBuilder.section_size(sec, b) == Vector2(364, 363),
		"a zero-size button counts at its art's 76x24, so the window reaches y=363 (got %s)" % str(UiBuilder.section_size(sec, b)))
	_check(UiBuilder.is_parked(Rect2i(9999, 70, 100, 104)) and not UiBuilder.is_parked(Rect2i(800, 0, 64, 52)),
		"x=9999 is parked; ifunderbar's 800,0 is not")

## Round 630: a label taller or wider than its rect overruns it the way
## CIFStatic's 0x64d9b0 lays text out -- evenly when centred, toward the top
## or left when bottom- or right-aligned, from the truncated point -- not
## right and down from the rect's corner. The text's size is stood in for by
## a minimum size, so the check does not depend on a font.
func _check_text_overrun_follows_alignment() -> void:
	# (Text sizes taller than Godot's default font's line, which is the
	# floor of any Label's height here, since this builder has no archive.)
	var cases := [
		# [halign, valign, rect, text size, where the label must start]
		[0, 0, Rect2(10, 20, 60, 4), Vector2(40, 30), Vector2(10, 20)],
		[1, 1, Rect2(10, 20, 60, 4), Vector2(40, 30), Vector2(10, 7)],
		[2, 2, Rect2(10, 20, 60, 4), Vector2(40, 30), Vector2(10, -6)],
		[1, 1, Rect2(10, 20, 30, 12), Vector2(41, 31), Vector2(4, 10)],
		[2, 0, Rect2(143, 314, 24, 12), Vector2(26, 30), Vector2(141, 314)],
	]
	var builder := UiBuilder.new(null, null)
	var script := load("res://scripts/ui/ui_builder.gd") as GDScript
	var has_rule := false
	for m in script.get_script_method_list():
		if m["name"] == "place_label":
			has_rule = true
	if not has_rule:
		_check(false, "the builder lays an overrunning label by its alignment (UiBuilder.place_label)")
		return
	for c in cases:
		var label := Label.new()
		label.horizontal_alignment = builder._map_halign(int(c[0]))
		label.vertical_alignment = builder._map_valign(int(c[1]))
		label.custom_minimum_size = c[3]
		script.call("place_label", label, c[2])
		_check(label.position == c[4],
			"align (%d,%d): a %s text in %s starts at %s (got %s)" % [c[0], c[1], c[3], c[2], c[4], label.position])
		label.free()

## Round 630 review: a control's text is laid out inside its ClientRect
## (0x652800 insets the rect by +0x18c..+0x198, set by 0x6527d0 from the
## parsed ClientRect), a CIFButton's caption by its own HAlign / VAlign
## (its draw is CIFStatic's), and a Style-0x40 control starts hidden
## (0x8b5710).
func _check_client_rect_style_and_captions() -> void:
	var layout_text := """
Interface Text

Section = Create,"0,0,260,320","0"
{
	GDR_STORAGE_TXT_MONEY_TITLE:CIFStatic
	{
		ClientRect=RECT,"8,4,174,3"
		HAlign=INTEGER,"1"
		VAlign=INTEGER,"1"
		Rect=RECT,"9,283,236,24"
		Text=STRING,"Title"
	}
	GDR_CAPTIONED:CIFButton
	{
		ClientRect=RECT,"5,3,0,0"
		HAlign=INTEGER,"0"
		VAlign=INTEGER,"0"
		Rect=RECT,"10,10,120,40"
		Text=STRING,"Go"
	}
	GDR_HIDDEN_AT_CREATION:CIFStatic
	{
		Rect=RECT,"1,42,32,32"
		Style=INTEGER,"64"
	}
	GDR_ART_STATIC:CIFStatic
	{
		ClientRect=RECT,"36,7,39,5"
		DDJ=STRING,"interface\\inventory\\int_window_downbox.ddj"
		HAlign=INTEGER,"2"
		VAlign=INTEGER,"1"
		Rect=RECT,"0,305,176,28"
		Text=STRING,""
	}
}
"""
	var builder := UiBuilder.new(null, null)
	var section := builder.build_section(UiLayoutParser.parse(layout_text), "Create")
	# A plain label: its text rect is the rect inset by (8, 4) and (174, 3):
	# x 17..71, y 287..304 -- 54 wide. The text ("Title") fits that width, so
	# the label takes it and centres the word inside.
	var title := section.get_node_or_null("GDR_STORAGE_TXT_MONEY_TITLE") as Label
	UiBuilder.apply_authored_rects(section)
	_check(title != null and title.position.x == 17.0 and title.size.x == 54.0,
		"the title's text is laid in its ClientRect, x 17..71 (got %s)" % (Rect2(title.position, title.size) if title else null))
	# A button's caption: HAlign 0 / VAlign 0 put it at its ClientRect's
	# top-left (5, 3) in the button, not centred.
	var btn := section.get_node_or_null("GDR_CAPTIONED") as Control
	var caption := btn.get_node_or_null("ButtonLabel") as Label if btn != null else null
	_check(caption != null and caption.position == Vector2(5, 3) and caption.horizontal_alignment == HORIZONTAL_ALIGNMENT_LEFT,
		"a button's caption follows its HAlign/VAlign in its ClientRect, at (5, 3) (got %s)" % (caption.position if caption else null))
	var hidden := section.get_node_or_null("GDR_HIDDEN_AT_CREATION") as CanvasItem
	_check(hidden != null and not hidden.visible, "a Style-64 control starts hidden (visible %s)" % (hidden.visible if hidden else null))
	# Text put on an art static the layout gave none (the purse's amount).
	var art := section.get_node_or_null("GDR_ART_STATIC") as Control
	if builder.has_method("set_static_text"):
		var amount: Label = builder.call("set_static_text", art, "1,234")
		_check(amount != null and amount.text == "1,234" and amount.get_parent() == art
			and absf(amount.position.x + amount.size.x - 137.0) < 0.01,
			"set_static_text writes an art static's text, right-aligned to its ClientRect's x 137 (got %s)" % (Rect2(amount.position, amount.size) if amount else null))
	else:
		_check(false, "the builder can put text on an art static (set_static_text)")
	section.free()
