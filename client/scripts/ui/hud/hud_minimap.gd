extends Control
class_name HudMinimap

## HudMinimap renders Silkroad Online's minimap using authored layout (resinfo\ifminimap.txt),
## region art (minimap\<y>x<x>.ddj), and recovered coordinate formulas from docs/WORLD_ISSUES.md.

const DdjReader = preload("res://scripts/ddj/ddj_reader.gd")
const ObjectLoader = preload("res://scripts/assets/object_loader.gd")
const UiBuilder = preload("res://scripts/ui/ui_builder.gd")
const UiLayoutParser = preload("res://scripts/ui/ui_layout_parser.gd")
const UiTextTable = preload("res://scripts/ui/ui_text_table.gd")

const REGION_SPAN := 1920.0

var _ui_builder: UiBuilder
var _media_pk2: Pk2Reader
var _text_table: UiTextTable

var _lbl_pos_x: Label
var _lbl_pos_y: Label
var _lbl_area: Label
var _btn_zoom_in: TextureButton
var _btn_zoom_out: TextureButton
var _btn_toggle_map: TextureButton

var _map_clip: Control
var _map_rect: TextureRect
var _player_arrow: TextureRect
var _frame_rect: TextureRect

var _current_region_x: int = -1
var _current_region_y: int = -1
var _zoom_level: float = 1.0

func _init(builder: UiBuilder = null, media_pk2: Pk2Reader = null, text_table: UiTextTable = null) -> void:
	_ui_builder = builder
	_media_pk2 = media_pk2
	_text_table = text_table

func _ready() -> void:
	if get_child_count() == 0:
		setup()

func setup(layout_data: Variant = null) -> void:
	custom_minimum_size = Vector2(136, 175)
	size = Vector2(136, 175)
	# The root is a transparent container, so it must not swallow mouse
	# input: Godot's default MOUSE_FILTER_STOP made this panel eat every
	# click over its whole rectangle, and World3D drives click-to-move from
	# _unhandled_input, which a consumed event never reaches. IGNORE applies
	# to this node only -- the buttons and slots inside keep their own
	# filters and still receive clicks.
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	# 1. Circular map clipping viewport (authored rect is 14, 57, 105, 105)
	_map_clip = Control.new()
	_map_clip.name = "MapClip"
	_map_clip.position = Vector2(14, 57)
	_map_clip.size = Vector2(105, 105)
	_map_clip.clip_contents = true
	_map_clip.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(_map_clip)

	# Region map image
	_map_rect = TextureRect.new()
	_map_rect.name = "RegionMap"
	_map_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_map_rect.stretch_mode = TextureRect.STRETCH_SCALE
	_map_rect.mouse_filter = MOUSE_FILTER_IGNORE
	_map_clip.add_child(_map_rect)

	# Player heading marker (mm_sign_character.ddj)
	_player_arrow = TextureRect.new()
	_player_arrow.name = "PlayerArrow"
	_player_arrow.size = Vector2(16, 16)
	_player_arrow.pivot_offset = Vector2(8, 8)
	_player_arrow.position = Vector2(105 / 2.0 - 8, 105 / 2.0 - 8)
	_player_arrow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_player_arrow.stretch_mode = TextureRect.STRETCH_SCALE
	_player_arrow.mouse_filter = MOUSE_FILTER_IGNORE
	if _ui_builder != null:
		_player_arrow.texture = _ui_builder.load_texture("interface\\minimap\\mm_sign_character.ddj")
	_map_clip.add_child(_player_arrow)

	# 2. Outer decorative frame (mm_window.ddj)
	_frame_rect = TextureRect.new()
	_frame_rect.name = "MinimapFrame"
	_frame_rect.position = Vector2(0, 0)
	_frame_rect.size = Vector2(136, 175)
	_frame_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_frame_rect.stretch_mode = TextureRect.STRETCH_SCALE
	_frame_rect.mouse_filter = MOUSE_FILTER_IGNORE
	if _ui_builder != null:
		_frame_rect.texture = _ui_builder.load_texture("interface\\minimap\\mm_window.ddj")
	add_child(_frame_rect)

	# 3. Layout root (buttons and text labels authored in resinfo\ifminimap.txt)
	var layout: UiLayoutParser.LayoutDef = null
	if layout_data != null:
		layout = UiLayoutParser.parse(layout_data)
	elif _media_pk2 != null:
		var entry := ObjectLoader.find_file(_media_pk2, "resinfo\\ifminimap.txt")
		if entry != null:
			var bytes := _media_pk2.read_file(entry)
			layout = UiLayoutParser.parse(bytes)

	var layout_root: Control = null
	if layout != null and _ui_builder != null:
		layout_root = _ui_builder.build_section(layout, "Create")

	if layout_root != null:
		add_child(layout_root)

		# `GDR_MINIMAP_ALPHA` is a **mask**, not art. The authored layout
		# places it at exactly the map rect (14,57,105,105) carrying
		# `mm_alpha.ddj`, which is an opaque circle inside a transparent
		# square (7,999 opaque / 2,817 transparent texels, measured with
		# dump_ddj.gd) -- the real client uses it to clip the region map to
		# a circle. Drawn as an ordinary texture it is a solid black disc
		# that covers the map completely and spills over the frame's own
		# artwork, which is exactly what the first render of this HUD
		# showed.
		#
		# Hiding it restores the map. It does **not** implement the real
		# circular clip -- the map is currently clipped to the square
		# `_map_clip` instead, so it fills the corners the real client
		# leaves empty. Doing it properly needs the texture applied as a
		# mask (a CanvasGroup or a shader), which is left to the UI lane;
		# see docs/TODO.md.
		var alpha_mask := layout_root.get_node_or_null("GDR_MINIMAP_ALPHA") as CanvasItem
		if alpha_mask != null:
			alpha_mask.visible = false

		_lbl_pos_x = layout_root.get_node_or_null("GDR_MINIMAP_TEXT_POS_X") as Label
		_lbl_pos_y = layout_root.get_node_or_null("GDR_MINIMAP_TEXT_POS_Y") as Label
		_lbl_area = layout_root.get_node_or_null("GDR_MINIMAP_TEXT_AREANAME") as Label
		_btn_zoom_in = layout_root.get_node_or_null("GDR_MINIMAP_ZOOMIN") as TextureButton
		_btn_zoom_out = layout_root.get_node_or_null("GDR_MINIMAP_ZOOMOUT") as TextureButton
		_btn_toggle_map = layout_root.get_node_or_null("GDR_MINIMAP_BTN_TOG_MAP") as TextureButton

	# Connect zoom buttons if present
	if _btn_zoom_in != null:
		_btn_zoom_in.pressed.connect(_on_zoom_in_pressed)
	if _btn_zoom_out != null:
		_btn_zoom_out.pressed.connect(_on_zoom_out_pressed)

## Updates the minimap with the player's current region, local coordinates, and yaw.
## Uses the exact recovered coordinate formulas:
## displayed X = (region_y - 135) * 192 + local_x / 10
## displayed Y = (region_x - 92) * 192 + local_z / 10
func update_player(region_x: int, region_y: int, local_pos: Vector3, yaw_degrees: float) -> void:
	# Update coordinate text
	var disp_x: int = (region_y - 135) * 192 + int(local_pos.x / 10.0)
	var disp_y: int = (region_x - 92) * 192 + int(local_pos.z / 10.0)

	if _lbl_pos_x != null:
		_lbl_pos_x.text = "X:%d" % disp_x
	if _lbl_pos_y != null:
		_lbl_pos_y.text = "Y:%d" % disp_y

	# Update region texture if region changed
	if region_x != _current_region_x or region_y != _current_region_y:
		_current_region_x = region_x
		_current_region_y = region_y
		_load_region_map(region_x, region_y)

	# Position the map texture so player position is centered inside aperture (52.5, 52.5)
	var map_size: float = 256.0 * _zoom_level
	_map_rect.size = Vector2(map_size, map_size)

	var norm_x := clampf(local_pos.x / REGION_SPAN, 0.0, 1.0)
	var norm_y := clampf(local_pos.z / REGION_SPAN, 0.0, 1.0)

	var center_x := 105.0 / 2.0
	var center_y := 105.0 / 2.0
	_map_rect.position = Vector2(center_x - norm_x * map_size, center_y - norm_y * map_size)

	# Heading arrow
	if _player_arrow != null:
		_player_arrow.rotation_degrees = yaw_degrees

func set_area_name(area_name: String) -> void:
	if _lbl_area != null:
		_lbl_area.text = area_name

func _load_region_map(rx: int, ry: int) -> void:
	if _ui_builder == null:
		return
	# Minimap filename convention is minimap\<y>x<x>.ddj (see AGENTS.md)
	var path := "minimap\\%dx%d.ddj" % [ry, rx]
	var tex := _ui_builder.load_texture(path)
	if tex != null:
		_map_rect.texture = tex

func _on_zoom_in_pressed() -> void:
	_zoom_level = clampf(_zoom_level * 1.25, 0.5, 3.0)

func _on_zoom_out_pressed() -> void:
	_zoom_level = clampf(_zoom_level / 1.25, 0.5, 3.0)
