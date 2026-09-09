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
