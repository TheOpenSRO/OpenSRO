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
}
"""
	var layout := UiLayoutParser.parse(layout_text)
	var builder := UiBuilder.new(null, text_table)
	var root := builder.build_section(layout, "Create")

	_check(root != null, "root is non-null")
	_check(root.name == "Create", "root name is Create")
	_check(root.get_child_count() == 3, "root has 3 children")

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

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		push_error("%d failure(s)" % _failures)
		quit(1)
