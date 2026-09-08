extends SceneTree

const UiLayoutParser = preload("res://scripts/ui/ui_layout_parser.gd")

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _init() -> void:
	var sample := """
Interface Text

Section = Create,"0,0,0,0","0"
{
	GDR_MINIMAP_ALPHA:CIFStatic
	{
		ClientRect=RECT,"0,0,0,0"
		Color=COLOR,"255,223,58,95"
		DDJ=STRING,"interface\\minimap\\mm_alpha.ddj"
		FontColor=COLOR,"255,255,255,255"
		FontIndex=INTEGER,"0"
		HAlign=INTEGER,"1"
		ID=INTEGER,"1"
		Rect=RECT,"14,57,105,105"
		Style=INTEGER,"0"
		Text=STRING,""
		UV_LB=POINT,"0,1"
		UV_LT=POINT,"0,0"
		UV_RB=POINT,"1,1"
		UV_RT=POINT,"1,0"
		VAlign=INTEGER,"0"
	}
	GDR_MINIMAP_BTN_TOG_MAP:CIFButton
	{
		ClientRect=RECT,"0,0,0,0"
		Color=COLOR,"255,43,74,119"
		DDJ=STRING,"interface\\minimap\\mm_map_button.ddj"
		FontColor=COLOR,"255,255,255,255"
		FontIndex=INTEGER,"0"
		HAlign=INTEGER,"1"
		ID=INTEGER,"8"
		Rect=RECT,"99,47,24,24"
		Style=INTEGER,"0"
		Text=STRING,"UIIT_STT_MAP"
	}
}
"""

	var layout := UiLayoutParser.parse(sample)
	_check(layout.sections.has("Create"), "has section Create")
	var sec := layout.get_section("Create")
	_check(sec != null, "get_section returns non-null")
	_check(sec.controls.size() == 2, "sec has 2 controls (got %d)" % sec.controls.size())

	var alpha_ctrl := sec.control_by_name.get("GDR_MINIMAP_ALPHA") as UiLayoutParser.ControlDef
	_check(alpha_ctrl != null, "found GDR_MINIMAP_ALPHA")
	_check(alpha_ctrl.type == "CIFStatic", "type is CIFStatic")
	_check(alpha_ctrl.id == 1, "id is 1")
	_check(alpha_ctrl.rect == Rect2i(14, 57, 105, 105), "rect is (14, 57, 105, 105)")
	_check(alpha_ctrl.ddj == "interface\\minimap\\mm_alpha.ddj", "ddj is correct (got %s)" % alpha_ctrl.ddj)
	_check(is_equal_approx(alpha_ctrl.color.a, 1.0), "color alpha is 1.0")

	var btn_ctrl := sec.control_by_name.get("GDR_MINIMAP_BTN_TOG_MAP") as UiLayoutParser.ControlDef
	_check(btn_ctrl != null, "found GDR_MINIMAP_BTN_TOG_MAP")
	_check(btn_ctrl.type == "CIFButton", "type is CIFButton")
	_check(btn_ctrl.id == 8, "id is 8")
	_check(btn_ctrl.rect == Rect2i(99, 47, 24, 24), "btn rect is (99, 47, 24, 24)")
	_check(btn_ctrl.text == "UIIT_STT_MAP", "btn text is UIIT_STT_MAP")

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		push_error("%d failure(s)" % _failures)
		quit(1)
