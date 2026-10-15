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

	# --- #ifdef branch selection --------------------------------------------
	var guarded := """
Section = Create,"0,0,0,0","0"
{
#ifdef FEATURE_A
	GDR_A:CIFStatic
	{
		ID=INTEGER,"1"
	}
#else
	GDR_B:CIFStatic
	{
		ID=INTEGER,"2"
	}
#endif
	GDR_ALWAYS:CIFStatic
	{
		ID=INTEGER,"3"
	}
#ifdef FEATURE_C
	GDR_C:CIFStatic
	{
		ID=INTEGER,"4"
	}
#endif
}
"""
	# Default: directives ignored, both branches read (the behaviour every
	# window built so far relies on).
	var both := UiLayoutParser.parse(guarded).get_section("Create")
	_check(both.controls.size() == 4, "ifdef off: both branches + always + C read (got %d)" % both.controls.size())

	# Nothing defined: #else of A, and C skipped.
	var none := UiLayoutParser.parse(guarded, true, PackedStringArray()).get_section("Create")
	_check(none.controls.size() == 2, "ifdef on, none defined: 2 controls (got %d)" % none.controls.size())
	_check(none.control_by_name.has("GDR_B"), "the #else branch (GDR_B) is taken")
	_check(not none.control_by_name.has("GDR_A"), "the #ifdef branch (GDR_A) is dropped")
	_check(not none.control_by_name.has("GDR_C"), "an unguarded-symbol #ifdef (GDR_C) is dropped")
	_check(none.control_by_name.has("GDR_ALWAYS"), "an unguarded control is always kept")

	# A and C defined: the #ifdef branches taken, #else dropped.
	var ac := UiLayoutParser.parse(guarded, true, PackedStringArray(["FEATURE_A", "FEATURE_C"])).get_section("Create")
	_check(ac.controls.size() == 3, "ifdef on, A+C defined: 3 controls (got %d)" % ac.controls.size())
	_check(ac.control_by_name.has("GDR_A"), "GDR_A taken when FEATURE_A defined")
	_check(not ac.control_by_name.has("GDR_B"), "the #else (GDR_B) is dropped when FEATURE_A defined")
	_check(ac.control_by_name.has("GDR_C"), "GDR_C taken when FEATURE_C defined")

	# Round 788: a rect short of four numbers keeps what it has (the archive's
	# one, ifextquickslotoption.txt's OK button, reads "63,185,0").
	var short := UiLayoutParser.parse("Section = Create,\"0,0,0,0\",\"0\"\n{\n\tGDR_OK:CIFButton\n\t{\n\t\tRect=RECT,\"63,185,0\"\n\t}\n\tGDR_SPACED:CIFButton\n\t{\n\t\tRect=RECT,\"340, 153, 52, 24\"\n\t}\n}\n").get_section("Create")
	_check(short.control_by_name["GDR_OK"].rect == Rect2i(63, 185, 0, 0),
		"a three-number rect keeps x and y (got %s)" % short.control_by_name["GDR_OK"].rect)
	_check(short.control_by_name["GDR_SPACED"].rect == Rect2i(340, 153, 52, 24), "a spaced four-number rect is unchanged")

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		push_error("%d failure(s)" % _failures)
		quit(1)
