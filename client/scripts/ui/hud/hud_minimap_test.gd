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

## Drives update_player through each tree's own contract: the facing as a
## region-local vector (round 630), or -- for the base's float parameter, so
## the negative run reaches its assertions -- the degrees World3D passed
## before, player.rotation_degrees.y, which for a facing (x, z) is
## atan2(x, -z) (World3D faces +Z along atan2(dir.x, dir.z), and world z is
## local z negated).
func _update(minimap: Control, rx: int, ry: int, local: Vector3, facing: Vector2) -> void:
	var float_param := false
	for m in minimap.get_method_list():
		if m["name"] == "update_player" and m["args"].size() >= 4 and int(m["args"][3]["type"]) == TYPE_FLOAT:
			float_param = true
	if float_param:
		minimap.call("update_player", rx, ry, local, rad_to_deg(atan2(facing.x, -facing.y)))
	else:
		minimap.call("update_player", rx, ry, local, facing)

## The map tile whose rect covers the aperture's centre: its name, size and
## the texture (u, v) at the centre.
func _tile_under_centre(minimap: Control) -> Dictionary:
	var clip := minimap.get_node_or_null("MapClip") as Control
	if clip == null:
		return {}
	var centre := clip.size / 2.0
	for c in clip.get_children():
		if c is TextureRect and String(c.name).begins_with("RegionMap"):
			var r := Rect2((c as Control).position, (c as Control).size)
			if r.has_point(centre):
				return {"name": String(c.name), "size": r.size, "uv": (centre - r.position) / r.size}
	return {}

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
	GDR_MINIMAP_DUNGEON_FLOOR_INFO:CIFStatic
	{
		Rect=RECT,"1,42,32,32"
		Style=INTEGER,"64"
	}
}
"""
	var builder := UiBuilder.new(null, null)
	var minimap := HudMinimap.new(builder, null, null)
	minimap.setup(layout_text)

	# Test coordinate conversion from recovered formula (docs/WORLD_ISSUES.md):
	# Dragon fountain at region 97/168, local (1010, 690) -> X:6437, Y:1029
	_update(minimap, 97, 168, Vector3(1010, 0, 690), Vector2(0, 1))

	var lbl_x := minimap.get_node_or_null("Create/GDR_MINIMAP_TEXT_POS_X") as Label
	var lbl_y := minimap.get_node_or_null("Create/GDR_MINIMAP_TEXT_POS_Y") as Label
	var lbl_area := minimap.get_node_or_null("Create/GDR_MINIMAP_TEXT_AREANAME") as Label

	_check(lbl_x != null and lbl_x.text == "X:6437", "X coord formatted as X:6437 (got %s)" % (lbl_x.text if lbl_x != null else "null"))
	_check(lbl_y != null and lbl_y.text == "Y:1029", "Y coord formatted as Y:1029 (got %s)" % (lbl_y.text if lbl_y != null else "null"))

	minimap.set_area_name("Jangan")
	_check(lbl_area != null and lbl_area.text == "Jangan", "area name set to Jangan")

	# Palace gate at 98/168 (960, 320) -> X:6432, Y:1184
	_update(minimap, 98, 168, Vector3(960, 0, 320), Vector2(0, 1))
	_check(lbl_x.text == "X:6432", "Palace gate X is 6432 (got %s)" % lbl_x.text)
	_check(lbl_y.text == "Y:1184", "Palace gate Y is 1184 (got %s)" % lbl_y.text)

	# Entity signs: one region (1920 units) spans S pixels, world X along
	# the screen's x and world -Z (region-local +z, north) up -- the tiles'
	# own rule, so a sign lands on the map's pixel for that spot.
	var p := Vector3(1002, -52, 917)
	_check(HudMinimap.sign_offset(p, p + Vector3(192, 0, 0), 256.0).is_equal_approx(Vector2(25.6, 0)),
		"192 units east is 25.6 px right at 256 px a region")
	_check(HudMinimap.sign_offset(p, p + Vector3(0, 0, -960), 256.0).is_equal_approx(Vector2(0, -128)),
		"half a region north (-Z) is 128 px up")
	_check(HudMinimap.sign_offset(p, p + Vector3(0, 30, 0), 256.0) == Vector2.ZERO,
		"height does not move a sign")
	# With no archive there is no sign artwork: the update must count the
	# entities and draw none, not fail.
	minimap.update_signs(p, [p + Vector3(50, 0, 0)], [p + Vector3(0, 0, 50)], [])
	var signs := minimap.get_node_or_null("MapClip/Signs")
	_check(signs != null and signs.get_child_count() == 0,
		"no artwork, no sign nodes (got %d)" % (signs.get_child_count() if signs != null else -1))

	# --- round 630 -------------------------------------------------------
	# The window is mm_window.ddj's own 140x184 (ginterface.txt's
	# GDR_MINIMAP), not 136x175: the stretch slid every circle of the art
	# off the buttons laid on it.
	_check(minimap.size == Vector2(140, 184), "the minimap window is 140x184 (got %s)" % minimap.size)
	var frame := minimap.get_node_or_null("MinimapFrame") as Control
	_check(frame != null and frame.size == Vector2(140, 184), "the frame art is drawn 1:1 at 140x184 (got %s)" % (frame.size if frame else null))
	# The black ring left of the globe: Style 64, hidden at creation
	# (0x8b5710) and shown only in a dungeon region (0x6620db).
	var floor_info := minimap.get_node_or_null("Create/GDR_MINIMAP_DUNGEON_FLOOR_INFO") as CanvasItem
	_check(floor_info != null and not floor_info.visible,
		"the dungeon-floor ring is hidden outside a dungeon (visible %s)" % (floor_info.visible if floor_info else null))

	# The tile under the aperture's centre, and the image row it shows there.
	# The user's spot: 96/168, local (1140, 1230), a dirt road south of
	# Jangan's wall. The READ rule (0x661ce0): the image's rows run north to
	# south, so the centre shows row (1920 - z) / 1920 of region 96/168's
	# own tile, 0.359; the old rule showed row z / 1920, 0.641 -- the point
	# mirrored about the region's middle, which is grass.
	_update(minimap, 96, 168, Vector3(1140, 0, 1230), Vector2(0, 1))
	var hit := _tile_under_centre(minimap)
	# (Within a pixel of the 160-px tile: its edges are whole pixels.)
	var want_uv := Vector2(1140.0 / 1920.0, 690.0 / 1920.0)
	_check(not hit.is_empty() and absf(hit["uv"].x - want_uv.x) <= 1.0 / 160.0 and absf(hit["uv"].y - want_uv.y) <= 1.0 / 160.0,
		"the aperture centre shows (u, v) = (x, 1920 - z) / 1920 of the player's tile, within a pixel (got %s, want %s)" % [hit.get("uv"), want_uv])
	_check(not hit.is_empty() and hit["name"] == "RegionMap_1_1",
		"and that tile is the middle of the 3x3, the player's own region (got %s)" % [hit.get("name")])
	# 160 pixels a region to start with (0x660c42, 160.0f).
	_check(not hit.is_empty() and hit["size"] == Vector2(160, 160), "a region is 160 px across at the start (got %s)" % [hit.get("size")])
	# The 3x3 neighbourhood (0x662271): column i west to east, row j north
	# to south.
	# (Called on the instance, so the base tree -- which has neither --
	# reaches this line and fails it rather than failing to compile.)
	if minimap.has_method("tile_region") and minimap.has_method("tile_position"):
		_check(minimap.call("tile_region", 96, 168, 0, 0) == Vector2i(97, 167) and minimap.call("tile_region", 96, 168, 2, 2) == Vector2i(95, 169),
			"tile (0,0) is north-west (97/167) and (2,2) south-east (95/169)")
		var north: Vector2 = minimap.call("tile_position", 1, 0, Vector3(1140, 0, 1230), 160.0)
		var own: Vector2 = minimap.call("tile_position", 1, 1, Vector3(1140, 0, 1230), 160.0)
		_check(north.is_equal_approx(own - Vector2(0, 160)), "the region north of the player's is drawn one tile above it")
	else:
		_check(false, "the minimap lays the client's 3x3 of region tiles (tile_region / tile_position)")

	# Round 630 review: at a fractional size the nine tiles share their edges
	# exactly (whole-pixel edges), and a region with no minimap file is drawn
	# black, not see-through.
	if minimap.has_method("tile_rect"):
		var gaps := 0
		for s_px in [64.0, 83.2, 102.4, 121.6, 140.8, 160.0, 179.2, 198.4, 217.6, 236.8, 256.0]:
			for spot in [Vector3(1915, 0, 960), Vector3(3, 0, 2), Vector3(1140, 0, 1230), Vector3(1919.9, 0, 0.1)]:
				for i in 2:
					for j in 3:
						var a: Rect2 = minimap.call("tile_rect", i, j, spot, s_px)
						var b: Rect2 = minimap.call("tile_rect", i + 1, j, spot, s_px)
						var c: Rect2 = minimap.call("tile_rect", j, i, spot, s_px)
						var d: Rect2 = minimap.call("tile_rect", j, i + 1, spot, s_px)
						if a.end.x != b.position.x or c.end.y != d.position.y or a.position.x != floorf(a.position.x):
							gaps += 1
		_check(gaps == 0, "at every zoom level the tiles' whole-pixel edges meet (%d gaps)" % gaps)
	else:
		_check(false, "the tiles are laid on whole-pixel edges (tile_rect)")
	var black := 0
	for c in (minimap.get_node("MapClip") as Node).get_children():
		if c is TextureRect and String(c.name).begins_with("RegionMap"):
			var t := (c as TextureRect).texture
			if t != null and t.get_size() == Vector2(1, 1) and t.get_image().get_pixel(0, 0) == Color(0, 0, 0, 1):
				black += 1
	_check(black == 9, "with no archive every tile is a missing region, drawn black (got %d of 9)" % black)

	# The arrow: north up, east right, south down, west left -- the angle of
	# the facing's (x, -z) on the y-down screen, the arrow's art pointing
	# right (+x) unturned.
	var arrow := minimap.get_node_or_null("MapClip/PlayerArrow") as Control
	var facings := {"north": [Vector2(0, 1), Vector2(0, -1)], "east": [Vector2(1, 0), Vector2(1, 0)],
		"south": [Vector2(0, -1), Vector2(0, 1)], "west": [Vector2(-1, 0), Vector2(-1, 0)]}
	for name in facings:
		_update(minimap, 96, 168, Vector3(1140, 0, 1230), facings[name][0])
		var tip := Vector2.RIGHT.rotated(arrow.rotation) if arrow != null else Vector2.ZERO
		_check(tip.is_equal_approx(facings[name][1]),
			"facing %s, the arrow points %s on screen (got %s)" % [name, facings[name][1], tip])
	_check(arrow != null and arrow.size == Vector2(16, 16) and arrow.position + arrow.size / 2.0 == HudMinimap.APERTURE_RECT.size / 2.0,
		"the arrow is 16x16 about the aperture's centre (got %s)" % (Rect2(arrow.position, arrow.size) if arrow else null))

	# Zoom (0x660620 / 0x660660): 19.2 px a step, 64..256, walking at 0.05
	# px a millisecond.
	if minimap.has_method("zoom_in"):
		for i in 7:
			minimap.call("zoom_in")
		_check(is_equal_approx(float(minimap.call("tile_px_target")), 256.0), "zoom-in stops at 256 (got %s)" % minimap.call("tile_px_target"))
		minimap.call("step_zoom", 100.0)
		_check(is_equal_approx(float(minimap.call("tile_px")), 165.0), "100 ms later the map is 5 px larger (got %s)" % minimap.call("tile_px"))
		minimap.call("step_zoom", 10000.0)
		_check(is_equal_approx(float(minimap.call("tile_px")), 256.0), "and stops on the target (got %s)" % minimap.call("tile_px"))
		for i in 12:
			minimap.call("zoom_out")
		_check(is_equal_approx(float(minimap.call("tile_px_target")), 64.0), "zoom-out stops at 64 (got %s)" % minimap.call("tile_px_target"))
	else:
		_check(false, "the minimap has the client's zoom (zoom_in / zoom_out / tile_px)")

	minimap.free()

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		push_error("%d failure(s)" % _failures)
		quit(1)
