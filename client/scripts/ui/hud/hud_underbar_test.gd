extends SceneTree

const HudUnderbar = preload("res://scripts/ui/hud/hud_underbar.gd")
const UiBuilder = preload("res://scripts/ui/ui_builder.gd")

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _init() -> void:
	var layout_text := """
Interface Text

Section = Create,"0,0,800,60","0"
{
	GDR_GAUGE_SP:CIFGauge
	{
		Rect=RECT,"17,11,144,8"
	}
	GDR_STATIC_SP:CIFStatic
	{
		Rect=RECT,"167,9,48,12"
		Text=STRING,"0/0"
	}
	GDR_STATIC_EXP:CIFStatic
	{
		Rect=RECT,"18,31,198,12"
		Text=STRING,"EXP: 0%"
	}
	GDR_STATIC_QUICKSLOT:CIFStatic
	{
		Rect=RECT,"700,10,20,12"
		Text=STRING,"1"
	}
	GDR_TMPQS_0:CIFSlotWithHelp
	{
		Rect=RECT,"250,10,32,32"
	}
	GDR_BTN_QUICKSLOTUP:CIFButton
	{
		Rect=RECT,"720,5,15,10"
	}
	GDR_BTN_QUICKSLOTDOWN:CIFButton
	{
		Rect=RECT,"720,18,15,10"
	}
}
"""
	var builder := UiBuilder.new(null, null)
	var underbar := HudUnderbar.new(builder, null, null)
	underbar.setup(layout_text)

	underbar.set_sp(500, 1000)
	var lbl_sp := underbar.get_node_or_null("Create/GDR_STATIC_SP") as Label
	_check(lbl_sp != null and lbl_sp.text == "500/1000", "SP text formatted as 500/1000")

	underbar.set_exp(42.5)
	var lbl_exp := underbar.get_node_or_null("Create/GDR_STATIC_EXP") as Label
	_check(lbl_exp != null and lbl_exp.text == "EXP: 42.50%", "EXP text formatted as EXP: 42.50%")

	var lbl_page := underbar.get_node_or_null("Create/GDR_STATIC_QUICKSLOT") as Label
	_check(lbl_page != null and lbl_page.text == "1", "default page is 1")

	underbar._next_page()
	_check(lbl_page.text == "2", "next page is 2")

	underbar._prev_page()
	_check(lbl_page.text == "1", "prev page is 1")

	underbar.free()

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		push_error("%d failure(s)" % _failures)
		quit(1)
