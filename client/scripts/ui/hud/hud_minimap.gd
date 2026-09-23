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

## The circular aperture in the minimap frame, and the mask that shapes it.
## Both come from resinfo\\ifminimap.txt's GDR_MINIMAP_ALPHA, whose rect is
## 14,57,105,105 and whose artwork is mm_alpha.ddj.
const APERTURE_RECT := Rect2(14, 57, 105, 105)
const MASK_TEXTURE_PATH := "interface\\minimap\\mm_alpha.ddj"
const MASK_SHADER := preload("res://scripts/ui/minimap_mask.gdshader")

## Emitted when the layout's own map button is pressed.
signal world_map_requested

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

## The client's own sign artwork for what stands around the player, from
## `interface\minimap\`. Quest-NPC and party signs also exist there
## (mm_sign_questnpc, mm_sign_party) but nothing the client receives yet says
## which NPC carries a quest or who is in the party, so they are not drawn.
const SIGN_TEXTURES := {
	"npc": "interface\\minimap\\mm_sign_npc.ddj",
	"monster": "interface\\minimap\\mm_sign_monster.ddj",
	"other": "interface\\minimap\\mm_sign_otherplayer.ddj",
}
## The aperture is a circle; a sign whose centre falls outside it is hidden
## rather than left for the frame to cover.
const APERTURE_RADIUS := 105.0 / 2.0

var _signs_root: Control
var _sign_textures := {}   # kind -> Texture2D
var _sign_pools := {}      # kind -> Array[TextureRect]
var _last_sign_report := Vector2i(-1, -1)  # (drawn, total), so the log speaks only on change

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
	# The minimap consumes the clicks on it (round 529). Its rect is the
	# frame's (MinimapFrame below is placed at 0,0 with this size). It was
	# IGNORE, like every node under it, so a click on the map reached
	# World3D._unhandled_input (measured by round 522's re-review), which
	# treats it as a click on the world: it walks the character and takes the
	# keyboard back from a focused text line. Nothing on the map takes a click
	# today, so nothing here has to pass one to the world. STOP, as HudWindow
	# uses (its comment has the reasoning): Godot 4.2 hit-tests the deepest
	# control first, so the zoom and map buttons still get their clicks.
	mouse_filter = Control.MOUSE_FILTER_STOP

	# 1. Circular map clipping viewport (authored rect is 14, 57, 105, 105)
	_map_clip = Control.new()
	_map_clip.name = "MapClip"
	_map_clip.position = APERTURE_RECT.position
	_map_clip.size = APERTURE_RECT.size
	_map_clip.clip_contents = true
	_map_clip.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(_map_clip)

	# Region map image
	_map_rect = TextureRect.new()
	_map_rect.name = "RegionMap"
	_map_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_map_rect.stretch_mode = TextureRect.STRETCH_SCALE
	_map_rect.mouse_filter = MOUSE_FILTER_IGNORE
	# Round the map off to the frame's circular aperture, using the client's
	# own mask artwork. Without this the square clip above leaves the map
	# filling corners the real frame does not cover.
	if _ui_builder != null:
		var mask := _ui_builder.load_texture(MASK_TEXTURE_PATH)
		if mask != null:
			var mat := ShaderMaterial.new()
			mat.shader = MASK_SHADER
			mat.set_shader_parameter("mask_texture", mask)
			mat.set_shader_parameter("aperture_size", APERTURE_RECT.size)
			_map_rect.material = mat
	_map_clip.add_child(_map_rect)

	# Entity signs sit over the map and under the player's own arrow.
	_signs_root = Control.new()
	_signs_root.name = "Signs"
	_signs_root.mouse_filter = MOUSE_FILTER_IGNORE
	_map_clip.add_child(_signs_root)
	if _ui_builder != null:
		for kind in SIGN_TEXTURES:
			var tex := _ui_builder.load_texture(SIGN_TEXTURES[kind])
			if tex != null:
				_sign_textures[kind] = tex
			_sign_pools[kind] = []

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

		# `GDR_MINIMAP_ALPHA` is a **mask**, not art: its mm_alpha.ddj is
		# black everywhere with alpha 255 inside a circle and 0 outside.
		# Drawn as an ordinary texture it is a solid black disc covering the
		# whole map. It is consumed above as the map's clip shader instead,
		# so the layout's own copy of it must not be drawn.
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
	# GDR_MINIMAP_BTN_TOG_MAP, on mm_map_button.ddj, is the authored way in
	# to the world map -- no hotkey had to be invented for it.
	if _btn_toggle_map != null:
		_btn_toggle_map.pressed.connect(func() -> void: world_map_requested.emit())

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

	# Position the map texture so the player sits at the aperture's centre.
	var map_size: float = 256.0 * _zoom_level
	_map_rect.size = Vector2(map_size, map_size)

	var norm_x := clampf(local_pos.x / REGION_SPAN, 0.0, 1.0)
	var norm_y := clampf(local_pos.z / REGION_SPAN, 0.0, 1.0)

	var centre := APERTURE_RECT.size / 2.0
	_map_rect.position = Vector2(centre.x - norm_x * map_size, centre.y - norm_y * map_size)

	# The clip shader samples the mask in aperture space, so it needs the
	# map quad's rect every time the quad moves.
	if _map_rect.material is ShaderMaterial:
		var mat := _map_rect.material as ShaderMaterial
		mat.set_shader_parameter("map_offset", _map_rect.position)
		mat.set_shader_parameter("map_size", _map_rect.size)

	# Heading arrow
	if _player_arrow != null:
		_player_arrow.rotation_degrees = yaw_degrees

func set_area_name(area_name: String) -> void:
	if _lbl_area != null:
		_lbl_area.text = area_name

## Where an entity's sign goes, in aperture pixels from the aperture centre.
##
## The map tile is laid so the player sits at the centre and one region
## (REGION_SPAN world units) spans `map_size` pixels, with world X along the
## tile's u axis and world Z along its v axis -- the same convention
## update_player positions the tile by, so a sign lands where the map's own
## pixel for that spot is. Pure, so it can be tested without a scene.
static func sign_offset(player_world: Vector3, entity_world: Vector3, map_size: float) -> Vector2:
	var d := entity_world - player_world
	return Vector2(d.x, d.z) / REGION_SPAN * map_size

## Marks the entities around the player on the map with the client's own
## sign artwork, at their real positions. Each list holds world positions;
## a sign outside the circular aperture is hidden. Pools the TextureRects
## so a frame's update allocates nothing once the counts have settled.
func update_signs(player_world: Vector3, npcs: Array, monsters: Array, others: Array) -> void:
	if _signs_root == null:
		return
	var map_size: float = 256.0 * _zoom_level
	var centre := APERTURE_RECT.size / 2.0
	var drawn := 0
	var total := 0
	var placed: PackedStringArray = []  # kind@(dx,dy) per drawn sign, for the log
	var lists := {"npc": npcs, "monster": monsters, "other": others}
	for kind in lists:
		var positions: Array = lists[kind]
		var pool: Array = _sign_pools.get(kind, [])
		var tex: Texture2D = _sign_textures.get(kind, null)
		var used := 0
		if tex != null:
			var sign_size := tex.get_size()
			for pos in positions:
				total += 1
				var at: Vector2 = centre + sign_offset(player_world, pos, map_size)
				if at.distance_to(centre) > APERTURE_RADIUS:
					continue
				var sign: TextureRect
				if used < pool.size():
					sign = pool[used]
				else:
					sign = TextureRect.new()
					sign.name = "%s_%d" % [kind, used]
					sign.texture = tex
					sign.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
					sign.stretch_mode = TextureRect.STRETCH_SCALE
					sign.mouse_filter = MOUSE_FILTER_IGNORE
					sign.size = sign_size
					_signs_root.add_child(sign)
					pool.append(sign)
				sign.position = at - sign_size / 2.0
				sign.visible = true
				used += 1
				drawn += 1
				var off := at - centre
				placed.append("%s@(%d,%d)" % [kind, roundi(off.x), roundi(off.y)])
		else:
			total += positions.size()
		for i in range(used, pool.size()):
			(pool[i] as TextureRect).visible = false
		_sign_pools[kind] = pool
	var report := Vector2i(drawn, total)
	if report != _last_sign_report:
		_last_sign_report = report
		print("HudMinimap: signs drawn %d of %d entities (npc %d, monster %d, other %d): %s" % [
			drawn, total, npcs.size(), monsters.size(), others.size(), " ".join(placed)])

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
