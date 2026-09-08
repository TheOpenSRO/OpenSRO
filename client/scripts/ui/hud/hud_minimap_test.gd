extends SceneTree

const HudMinimap = preload("res://scripts/ui/hud/hud_minimap.gd")
const UiBuilder = preload("res://scripts/ui/ui_builder.gd")
const UiTextTable = preload("res://scripts/ui/ui_text_table.gd")

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

Section = Create,"0,0,150,180","0"
{
	GDR_MINIMAP_TEXT_POS_X:CIFStatic
	{
		Rect=RECT,"8,32,56,11"
		Text=STRING,"X:0"
	}
	GDR_MINIMAP_TEXT_POS_Y:CIFStatic
	{
		Rect=RECT,"67,32,56,11"
		Text=STRING,"Y:0"
	}
	GDR_MINIMAP_TEXT_AREANAME:CIFStatic
	{
		Rect=RECT,"12,9,104,12"
		Text=STRING,"Zone"
	}
	GDR_MINIMAP_ZOOMIN:CIFButton
	{
		Rect=RECT,"107,136,20,20"
	}
	GDR_MINIMAP_ZOOMOUT:CIFButton
	{
		Rect=RECT,"90,152,20,20"
	}
}
"""
	var builder := UiBuilder.new(null, null)
	var minimap := HudMinimap.new(builder, null, null)
	minimap.setup(layout_text)

	# Test coordinate conversion from recovered formula (docs/WORLD_ISSUES.md):
	# Dragon fountain at region 97/168, local (1010, 690) -> X:6437, Y:1029
	minimap.update_player(97, 168, Vector3(1010, 0, 690), 45.0)

	var lbl_x := minimap.get_node_or_null("Create/GDR_MINIMAP_TEXT_POS_X") as Label
	var lbl_y := minimap.get_node_or_null("Create/GDR_MINIMAP_TEXT_POS_Y") as Label
	var lbl_area := minimap.get_node_or_null("Create/GDR_MINIMAP_TEXT_AREANAME") as Label

	_check(lbl_x != null and lbl_x.text == "X:6437", "X coord formatted as X:6437 (got %s)" % (lbl_x.text if lbl_x != null else "null"))
	_check(lbl_y != null and lbl_y.text == "Y:1029", "Y coord formatted as Y:1029 (got %s)" % (lbl_y.text if lbl_y != null else "null"))

	minimap.set_area_name("Jangan")
	_check(lbl_area != null and lbl_area.text == "Jangan", "area name set to Jangan")

	# Palace gate at 98/168 (960, 320) -> X:6432, Y:1184
	minimap.update_player(98, 168, Vector3(960, 0, 320), 90.0)
	_check(lbl_x.text == "X:6432", "Palace gate X is 6432 (got %s)" % lbl_x.text)
	_check(lbl_y.text == "Y:1184", "Palace gate Y is 1184 (got %s)" % lbl_y.text)

	minimap.free()

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		push_error("%d failure(s)" % _failures)
		quit(1)
