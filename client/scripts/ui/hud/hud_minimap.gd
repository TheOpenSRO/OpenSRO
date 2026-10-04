extends Control
class_name HudMinimap

## HudMinimap renders Silkroad Online's minimap using authored layout (resinfo\ifminimap.txt),
## region art (minimap\<y>x<x>.ddj), and CIFMinimap's own draw, read in round 630
## (docs/protocol/minimap.md).

const DdjReader = preload("res://scripts/ddj/ddj_reader.gd")
const ObjectLoader = preload("res://scripts/assets/object_loader.gd")
const UiBuilder = preload("res://scripts/ui/ui_builder.gd")
const UiLayoutParser = preload("res://scripts/ui/ui_layout_parser.gd")
const UiTextTable = preload("res://scripts/ui/ui_text_table.gd")

const REGION_SPAN := 1920.0

## The window: GDR_MINIMAP in resinfo\\ginterface.txt is 140x184, and its
## artwork interface\\minimap\\mm_window.ddj is 140x184 (measured, round 630).
## It was stretched to 136x175, which slid every circle and bar of the art
## up and left of the children laid on it at their authored rects -- the
## zoom buttons sat outside their circles and the coordinates low on their bar.
const FRAME_SIZE := Vector2(140, 184)

## The circular aperture in the minimap frame, and the mask that shapes it.
## Both come from resinfo\\ifminimap.txt's GDR_MINIMAP_ALPHA, whose rect is
## 14,57,105,105 and whose artwork is mm_alpha.ddj. CIFMinimap::Create
## (0x660f70) keeps that child's texture at +0x370 and hides the child
## (0x66145e: vslot 0x5c with 0); the draw (vslot_013, 0x662bd0) reads the
## child's rect back and lays the map, the signs and the arrow in it, with
## the mask as the first texture stage.
const APERTURE_RECT := Rect2(14, 57, 105, 105)
const MASK_TEXTURE_PATH := "interface\\minimap\\mm_alpha.ddj"
const MASK_SHADER := preload("res://scripts/ui/minimap_mask.gdshader")

## How many pixels one region (REGION_SPAN units) covers: CIFMinimap's +0x3fc
## (drawn) and +0x400 (target). Both start at 160.0 (0x660c42 loads 0xda0b6c,
## 160.0f). The zoom-in button (id 5; the message map at 0xeb7780 sends it to
## 0x660620) adds 19.2 (0xda0b60) to the target, capped at 256.0 (0xda0b5c);
## zoom-out (id 6, 0x660660) takes 19.2 off, floored at 64.0 (0xda0b68). So
## there are eleven levels, 64 to 256, five either side of 160. Each frame
## (vslot_012, 0x662510) the drawn size walks toward the target by the
## frame's elapsed count at 0x110f7f8 times 0.05 (0xda0ee0), and stops on it.
## 0x110f7f8 is copied from the frame timer's +0x98 and capped at 3000
## (0xba40fb..0xba410d); that it counts milliseconds is INFERRED (the cap and
## its use as a per-frame step), so the step here is 0.05 px per ms.
const TILE_PX_START := 160.0
const TILE_PX_STEP := 19.2
const TILE_PX_MAX := 256.0
const TILE_PX_MIN := 64.0
const TILE_PX_PER_MS := 0.05

## The arrow and the signs are fixed quads, whatever their artwork's size:
## the arrow is +-8 (0xd99a70 -8.0, 0xd89240 8.0) about the aperture centre,
## a sign +-4 (0xe1b860 4.0) about its point (vslot_013).
const ARROW_SIZE := Vector2(16, 16)
const SIGN_SIZE := Vector2(8, 8)

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
var _dungeon_floor: CanvasItem

var _map_clip: Control
## The 3x3 region tiles around the player, [i][j] flattened as i * 3 + j,
## i the column (west to east), j the row (north to south) -- CIFMinimap's
## nine texture slots at +0x378, filled in that order by 0x661ce0.
var _tiles: Array[TextureRect] = []
var _player_arrow: TextureRect
var _frame_rect: TextureRect

var _current_region_x: int = -1
var _current_region_y: int = -1
var _local := Vector3.ZERO
var _tile_px: float = TILE_PX_START
var _tile_px_target: float = TILE_PX_START

## The client's own sign artwork for what stands around the player, from
## `interface\minimap\`. The quest-NPC sign also exists there
## (mm_sign_questnpc) but nothing the client receives yet says which NPC
## carries a quest, so it is not drawn. The party's signs are update_party's
## (round 717).
const SIGN_TEXTURES := {
	"npc": "interface\\minimap\\mm_sign_npc.ddj",
	"monster": "interface\\minimap\\mm_sign_monster.ddj",
	"other": "interface\\minimap\\mm_sign_otherplayer.ddj",
}
## vslot_013 draws a monster, NPC or player sign only when its distance from
## the centre, in map pixels, is under half the aperture width less 8
## (0x663759..0x66377a: the distance against [w * 0.5] - 8.0): 44.5 here.
## A sign further out is not drawn, rather than left for the frame to cover.
const SIGN_RADIUS := 105.0 / 2.0 - 8.0

var _signs_root: Control
var _sign_textures := {}   # kind -> Texture2D
var _sign_pools := {}      # kind -> Array[TextureRect]
var _last_sign_report := Vector2i(-1, -1)  # (drawn, total), so the log speaks only on change

## The party's marks (round 717): each member is the dot or the rim arrow by
## PartyMapMarks.is_arrow, from two pools, both in MapMarks over the frame
## (setup, 2b): the dots, then the arrows, then the player's arrow.
var _marks_root: Control
var _party_root: Control
var _party_arrow_root: Control
var _party_dot_tex: Texture2D
var _party_arrow_tex: Texture2D
var _party_dots: Array[TextureRect] = []
var _party_arrows: Array[TextureRect] = []

func _init(builder: UiBuilder = null, media_pk2: Pk2Reader = null, text_table: UiTextTable = null) -> void:
	_ui_builder = builder
	_media_pk2 = media_pk2
	_text_table = text_table

## Whether setup() has run. It builds once: World3D adds the minimap to the
## tree, whose _ready runs setup, and it used to call setup again after
## placing it, which built a second map, frame and layout stacked exactly on
## the first (the audit's node dumps, round 585). A later call now does
## nothing.
var _built := false

func _ready() -> void:
	setup()

func setup(layout_data: Variant = null) -> void:
	if _built:
		return
	_built = true
	custom_minimum_size = FRAME_SIZE
	size = FRAME_SIZE
	# The minimap consumes the clicks on it (round 529). Its rect is the
	# frame's (MinimapFrame below is placed at 0,0 with this size). It was
	# IGNORE, like every node under it, so a click on the map reached
	# World3D._unhandled_input (measured by round 522's re-review), which
	# treats it as a click on the world: it walks the character and takes the
	# keyboard back from a focused text line. Nothing on the map takes a click
	# today, so nothing here has to pass one to the world. STOP, as HudWindow
	# uses (its comment has the reasoning): Godot 4.2 hit-tests the deepest
	# control first, so the zoom and map buttons still get their clicks.
	# STOP also keeps a middle press from reaching World3D, which fires the
	# first quickslot on it; World3D hands this root to the hotbar's relay
	# (HudUnderbar.relay_middle_button, round 531) so it fires here too.
	mouse_filter = Control.MOUSE_FILTER_STOP

	# 1. The map, clipped to the aperture (authored rect 14, 57, 105, 105).
	_map_clip = Control.new()
	_map_clip.name = "MapClip"
	_map_clip.position = APERTURE_RECT.position
	_map_clip.size = APERTURE_RECT.size
	_map_clip.clip_contents = true
	_map_clip.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(_map_clip)

	# The nine region tiles. Each is rounded off to the frame's circular
	# aperture with the client's own mask artwork (the draw's first texture
	# stage is the mask, 0x662bd0); without it the square clip above leaves
	# the map filling corners the real frame does not cover.
	var mask: Texture2D = null
	if _ui_builder != null:
		mask = _ui_builder.load_texture(MASK_TEXTURE_PATH)
	_tiles.clear()
	for i in 3:
		for j in 3:
			var tile := TextureRect.new()
			tile.name = "RegionMap_%d_%d" % [i, j]
			tile.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tile.stretch_mode = TextureRect.STRETCH_SCALE
			tile.mouse_filter = MOUSE_FILTER_IGNORE
			if mask != null:
				var mat := ShaderMaterial.new()
				mat.shader = MASK_SHADER
				mat.set_shader_parameter("mask_texture", mask)
				mat.set_shader_parameter("aperture_size", APERTURE_RECT.size)
				tile.material = mat
			_map_clip.add_child(tile)
			_tiles.append(tile)

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

	if _ui_builder != null:
		_party_dot_tex = _ui_builder.load_texture(PartyMapMarks.DOT_DDJ)
		_party_arrow_tex = _ui_builder.load_texture(PartyMapMarks.ARROW_DDJ)

	# The player's arrow (mm_sign_character.ddj, CIFMinimap +0x374): a 16x16
	# quad about the aperture's centre, turned by arrow_rotation. It sits in
	# MapMarks (below), over the frame, last of the marks.
	_player_arrow = TextureRect.new()
	_player_arrow.name = "PlayerArrow"
	_player_arrow.size = ARROW_SIZE
	_player_arrow.pivot_offset = ARROW_SIZE / 2.0
	_player_arrow.position = APERTURE_RECT.size / 2.0 - ARROW_SIZE / 2.0
	_player_arrow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_player_arrow.stretch_mode = TextureRect.STRETCH_SCALE
	_player_arrow.mouse_filter = MOUSE_FILTER_IGNORE
	if _ui_builder != null:
		_player_arrow.texture = _ui_builder.load_texture("interface\\minimap\\mm_sign_character.ddj")

	# 2. The window's own artwork (mm_window.ddj), 1:1 at its 140x184.
	_frame_rect = TextureRect.new()
	_frame_rect.name = "MinimapFrame"
	_frame_rect.position = Vector2(0, 0)
	_frame_rect.size = FRAME_SIZE
	_frame_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_frame_rect.stretch_mode = TextureRect.STRETCH_SCALE
	_frame_rect.mouse_filter = MOUSE_FILTER_IGNORE
	if _ui_builder != null:
		_frame_rect.texture = _ui_builder.load_texture("interface\\minimap\\mm_window.ddj")
	add_child(_frame_rect)

	# 2b. The marks vslot_013 draws after the map (round 717 review): over the
	# frame, unclipped, in its order -- the party's dots, the party's arrows
	# (the quest marks would come here), then the player's arrow -- and under
	# the layout's buttons, which the window's render (0xb8f210: slot 13, then
	# the child list through slot 14) draws after them (READ). That the frame
	# is under vslot_013 is INFERRED: vslot_013 never binds mm_window, the
	# tiles are rounded by the mm_alpha mask (needless under a frame), and the
	# user's screenshot (map_JXHQtcH.png) shows the rim arrow whole over the
	# ring. The NPC/monster/player signs stay in the map's clip, under the
	# frame, for now (docs/TODO.md).
	_marks_root = Control.new()
	_marks_root.name = "MapMarks"
	_marks_root.position = APERTURE_RECT.position
	_marks_root.size = APERTURE_RECT.size
	_marks_root.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(_marks_root)
	_party_root = Control.new()
	_party_root.name = "PartyMarks"
	_party_root.mouse_filter = MOUSE_FILTER_IGNORE
	_marks_root.add_child(_party_root)
	_party_arrow_root = Control.new()
	_party_arrow_root.name = "PartyArrows"
	_party_arrow_root.mouse_filter = MOUSE_FILTER_IGNORE
	_marks_root.add_child(_party_arrow_root)
	_marks_root.add_child(_player_arrow)

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
		UiBuilder.settle_authored_rects(layout_root)

		# `GDR_MINIMAP_ALPHA` is a **mask**, not art: its mm_alpha.ddj is
		# black everywhere with alpha 255 inside a circle and 0 outside.
		# Drawn as an ordinary texture it is a solid black disc covering the
		# whole map. It is consumed above as the map's clip shader instead,
		# and CIFMinimap::Create hides the child (0x66145e).
		var alpha_mask := layout_root.get_node_or_null("GDR_MINIMAP_ALPHA") as CanvasItem
		if alpha_mask != null:
			alpha_mask.visible = false

		# GDR_MINIMAP_DUNGEON_FLOOR_INFO (id 10, mm_dungeonfloor.ddj at
		# 1,42 32x32) is the black ring the user saw left of the globe. Its
		# Style is 64, so the builder hides it at creation, as the client's
		# does (0x8b5710..0x8b5726; UiBuilder.STYLE_HIDDEN_AT_CREATION).
		# 0x661ce0 shows child 10 only in a dungeon region: 0x6620db..0x662101
		# calls its vslot 0x5c with (region id >> 15) != 0, the region id's
		# top bit (0x661d70, 0x661de6..0x661def), which also switches the
		# tiles to `minimap_d\`. This client has no dungeon regions, so it
		# stays hidden.
		_dungeon_floor = layout_root.get_node_or_null("GDR_MINIMAP_DUNGEON_FLOOR_INFO") as CanvasItem

		_lbl_pos_x = layout_root.get_node_or_null("GDR_MINIMAP_TEXT_POS_X") as Label
		_lbl_pos_y = layout_root.get_node_or_null("GDR_MINIMAP_TEXT_POS_Y") as Label
		_lbl_area = layout_root.get_node_or_null("GDR_MINIMAP_TEXT_AREANAME") as Label
		_btn_zoom_in = layout_root.get_node_or_null("GDR_MINIMAP_ZOOMIN") as TextureButton
		_btn_zoom_out = layout_root.get_node_or_null("GDR_MINIMAP_ZOOMOUT") as TextureButton
		_btn_toggle_map = layout_root.get_node_or_null("GDR_MINIMAP_BTN_TOG_MAP") as TextureButton

	# Connect zoom buttons if present
	if _btn_zoom_in != null:
		_btn_zoom_in.pressed.connect(zoom_in)
	if _btn_zoom_out != null:
		_btn_zoom_out.pressed.connect(zoom_out)
	# GDR_MINIMAP_BTN_TOG_MAP, on mm_map_button.ddj, is the authored way in
	# to the world map -- no hotkey had to be invented for it.
	if _btn_toggle_map != null:
		_btn_toggle_map.pressed.connect(func() -> void: world_map_requested.emit())

## Where the nine tiles are drawn, READ from 0x661ce0 and vslot_013:
##
##   +0x404 = S * x / 1920            (S = the drawn tile size, +0x3fc)
##   +0x408 = S * (1920 - z) / 1920   (image rows run north to south)
##   tile (i, j) at ((i - 1) * S - +0x404 + w / 2, (j - 1) * S - +0x408 + h / 2)
##
## in the aperture's own pixels (w, h its 105x105), with x, z the player's
## region-local position (+0x80, +0x88). Tile (i, j) is the region
## (region y - 1 + i) x (region x + 1 - j): column i runs west to east and
## row j north to south (the filename loop at 0x662271..0x6622a3, `%s%dx%d.ddj`,
## with +0x424 the region id's low byte and +0x428 its high byte). So the
## player's own point of its region is always the aperture's centre.
##
## The v axis was the bug the user saw: this drew row z / 1920 of the image
## under the player, so the map was mirrored north-south about the middle of
## each region, and only the region's middle row was ever right.
static func tile_position(i: int, j: int, local_pos: Vector3, tile_px: float,
		aperture: Vector2 = APERTURE_RECT.size) -> Vector2:
	var off := Vector2(tile_px * local_pos.x / REGION_SPAN,
		tile_px * (REGION_SPAN - local_pos.z) / REGION_SPAN)
	return Vector2((i - 1) * tile_px, (j - 1) * tile_px) - off + aperture / 2.0

## Tile (i, j)'s rect with whole-pixel edges. At a size that is not whole
## (every zoom level but 64, 160 and 256 is a multiple of 19.2) the tiles'
## float rects left a pixel column between neighbours uncovered once each
## was snapped on its own -- the review's magenta probe saw the window
## behind through it (round 630 review). Each edge is floored here, so a
## tile's right edge is its neighbour's left edge exactly. OURS: the client
## draws float quads that share their edge vertices, which leaves no gap.
static func tile_rect(i: int, j: int, local_pos: Vector3, tile_px: float,
		aperture: Vector2 = APERTURE_RECT.size) -> Rect2:
	var a := tile_position(i, j, local_pos, tile_px, aperture)
	var lo := Vector2(floorf(a.x), floorf(a.y))
	var hi := Vector2(floorf(a.x + tile_px), floorf(a.y + tile_px))
	return Rect2(lo, hi - lo)

## The region tile (i, j) shows, as (region_x, region_y) -- this project's
## naming, where the file is minimap\<region_y>x<region_x>.ddj.
static func tile_region(region_x: int, region_y: int, i: int, j: int) -> Vector2i:
	return Vector2i(region_x + 1 - j, region_y - 1 + i)

## The arrow's turn, in radians clockwise on screen, for the way the player
## faces as a region-local ground vector (x east, z north).
##
## READ: vslot_013 turns the arrow's 16x16 quad by -(+0x3ec) (0x665366:
## fmul by -1.0, 0xe1b8e8) through 0x8b5c50, which is x cos - y sin,
## x sin + y cos with 0xb44a10 the cos (fcos) and 0xb44b40 the sin (fsin) --
## clockwise on a y-down screen. 0x661ce0 sets +0x3ec to the player's
## heading (+0x8c) less pi / 2 (0xe1b8f0). The world map turns its marker
## the same way (0x6200de..0x620236, +0x97c8 = heading - pi / 2).
## MEASURED: mm_sign_character.ddj points right (+x): its tip is at column
## 15, row 7 of 16 (round 630's dump). So an unturned arrow points east, and
## the turn that points it along the facing is the angle of (x, -z) on the
## y-down screen. READ (round 630 review): 0x9ed130 / 0x9c4260 store the
## heading at +0x8c in [0, 2 pi), and 0x9ec850 turns it into the facing
## (sin h, 0, -cos h) -- 0xb44b40 the sin, 0xb44a10 the cos -- so h counts
## from south (-z) toward east, and the client's -(h - pi/2) is exactly the
## angle of (x, -z): atan2(cos h, sin h) = pi/2 - h.
## The minimap passed Godot's rotation.y straight through before, which
## pointed the arrow right when the player faced south and down when facing
## east: only a heading of 45 degrees came out right.
static func arrow_rotation(local_facing: Vector2) -> float:
	if local_facing.is_zero_approx():
		return 0.0
	return atan2(-local_facing.y, local_facing.x)

## Updates the minimap with the player's current region, local coordinates
## and facing (a region-local ground vector, x east and z north).
## The coordinate text uses the recovered formulas
##   displayed X = (region_y - 135) * 192 + local_x / 10
##   displayed Y = (region_x - 92) * 192 + local_z / 10
## formatted "X:%3d" / "Y:%3d" as 0x661ce0 does.
func update_player(region_x: int, region_y: int, local_pos: Vector3, local_facing: Vector2) -> void:
	var disp_x: int = (region_y - 135) * 192 + int(local_pos.x / 10.0)
	var disp_y: int = (region_x - 92) * 192 + int(local_pos.z / 10.0)

	if _lbl_pos_x != null:
		_lbl_pos_x.text = "X:%3d" % disp_x
	if _lbl_pos_y != null:
		_lbl_pos_y.text = "Y:%3d" % disp_y

	if region_x != _current_region_x or region_y != _current_region_y:
		_current_region_x = region_x
		_current_region_y = region_y
		_load_region_tiles(region_x, region_y)

	_local = local_pos
	_layout_tiles()

	if _player_arrow != null:
		_player_arrow.rotation = arrow_rotation(local_facing)

## Lays the nine tiles at the drawn size and the player's position.
func _layout_tiles() -> void:
	for i in 3:
		for j in 3:
			var tile: TextureRect = _tiles[i * 3 + j] if i * 3 + j < _tiles.size() else null
			if tile == null:
				continue
			var r := tile_rect(i, j, _local, _tile_px)
			tile.position = r.position
			tile.size = r.size
			# The clip shader samples the mask in aperture space, so it needs
			# the tile's rect every time the tile moves.
			if tile.material is ShaderMaterial:
				var mat := tile.material as ShaderMaterial
				mat.set_shader_parameter("map_offset", tile.position)
				mat.set_shader_parameter("map_size", tile.size)

## The drawn tile size (+0x3fc) and the size it is walking toward (+0x400).
func tile_px() -> float:
	return _tile_px

func tile_px_target() -> float:
	return _tile_px_target

func _process(delta: float) -> void:
	step_zoom(delta * 1000.0)

## One frame of vslot_012's walk toward the target, `elapsed_ms` long.
func step_zoom(elapsed_ms: float) -> void:
	if is_equal_approx(_tile_px, _tile_px_target):
		return
	var step := elapsed_ms * TILE_PX_PER_MS
	if _tile_px > _tile_px_target:
		_tile_px = maxf(_tile_px - step, _tile_px_target)
	else:
		_tile_px = minf(_tile_px + step, _tile_px_target)
	_layout_tiles()

func set_area_name(area_name: String) -> void:
	if _lbl_area != null:
		_lbl_area.text = area_name

## Where an entity's sign goes, in aperture pixels from the aperture centre.
##
## READ (vslot_013, 0x6636f1..0x663887): dx = (entity x - player x) / 1920,
## dz = (entity z - player z) / 1920 in region-local units, and the sign's
## centre is (w / 2 + S dx, h / 2 - S dz) -- the tiles' own rule, north up.
## Both positions here are Godot WORLD positions, whose z is the region's z
## negated (the world's one global z -> -z mirror, World3D._group_position),
## so -S dz is +S times the world z difference. Pure, so it can be tested
## without a scene.
static func sign_offset(player_world: Vector3, entity_world: Vector3, map_size: float) -> Vector2:
	var d := entity_world - player_world
	return Vector2(d.x, d.z) / REGION_SPAN * map_size

## Marks the entities around the player on the map with the client's own
## sign artwork, at their real positions. Each list holds world positions;
## a sign further out than SIGN_RADIUS is not drawn. Pools the TextureRects
## so a frame's update allocates nothing once the counts have settled.
func update_signs(player_world: Vector3, npcs: Array, monsters: Array, others: Array) -> void:
	if _signs_root == null:
		return
	# Nothing is allocated here once the pools have grown: no per-kind
	# dictionary, and the log line is only built when the counts change
	# (round 630 review).
	var drawn := _place_signs("npc", player_world, npcs) + _place_signs("monster", player_world, monsters) \
		+ _place_signs("other", player_world, others)
	var total := npcs.size() + monsters.size() + others.size()
	if drawn != _last_sign_report.x or total != _last_sign_report.y:
		_last_sign_report = Vector2i(drawn, total)
		var placed: PackedStringArray = []
		var centre := APERTURE_RECT.size / 2.0
		for kind in SIGN_TEXTURES:
			for sign in _sign_pools.get(kind, []):
				var node := sign as TextureRect
				if node.visible:
					var off := node.position + SIGN_SIZE / 2.0 - centre
					placed.append("%s@(%d,%d)" % [kind, roundi(off.x), roundi(off.y)])
		print("HudMinimap: signs drawn %d of %d entities (npc %d, monster %d, other %d): %s" % [
			drawn, total, npcs.size(), monsters.size(), others.size(), " ".join(placed)])

## Places one kind's signs from its pool; returns how many were drawn.
func _place_signs(kind: String, player_world: Vector3, positions: Array) -> int:
	var tex: Texture2D = _sign_textures.get(kind, null)
	var pool: Array = _sign_pools.get(kind, [])
	var used := 0
	if tex != null:
		var centre := APERTURE_RECT.size / 2.0
		for pos in positions:
			var off := sign_offset(player_world, pos, _tile_px)
			if off.length() >= SIGN_RADIUS:
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
				sign.size = SIGN_SIZE
				_signs_root.add_child(sign)
				pool.append(sign)
			sign.position = centre + off - SIGN_SIZE / 2.0
			sign.visible = true
			used += 1
	for i in range(used, pool.size()):
		(pool[i] as TextureRect).visible = false
	return used

## Marks each party member (round 717): `members_local` holds each drawn
## member's region-local ground position (x east, y north) in the player's
## region, `player_local` the player's. Under PartyMapMarks.ARROW_RADIUS map
## pixels from the centre a member is the 8x8 dot at its offset; at or past it,
## the 16x16 arrow on that radius, turned toward it. Pooled: a frame with a
## settled party allocates nothing.
func update_party(player_local: Vector2, members_local: PackedVector2Array) -> void:
	if _party_root == null or _party_arrow_root == null:
		return
	var centre := APERTURE_RECT.size / 2.0
	var dots := 0
	var arrows := 0
	for i in members_local.size():
		var off := PartyMapMarks.minimap_offset(player_local, members_local[i], _tile_px)
		if PartyMapMarks.is_arrow(off):
			var mark := _party_mark(_party_arrows, _party_arrow_root, arrows, "arrow", _party_arrow_tex,
				PartyMapMarks.ARROW_SIZE)
			arrows += 1
			mark.rotation = PartyMapMarks.arrow_rotation(off) + PartyMapMarks.TRANSPOSE_TURN
			mark.position = centre + PartyMapMarks.arrow_centre(off) - PartyMapMarks.ARROW_SIZE / 2.0
		else:
			var mark := _party_mark(_party_dots, _party_root, dots, "dot", _party_dot_tex, PartyMapMarks.DOT_SIZE)
			dots += 1
			mark.rotation = PartyMapMarks.TRANSPOSE_TURN
			mark.position = centre + off - PartyMapMarks.DOT_SIZE / 2.0
	for i in range(dots, _party_dots.size()):
		_party_dots[i].visible = false
	for i in range(arrows, _party_arrows.size()):
		_party_arrows[i].visible = false

## The `index`th mark of `pool`, made on first use (a frame with a settled
## party allocates nothing), shown when it has art.
func _party_mark(pool: Array[TextureRect], parent: Control, index: int, kind: String, tex: Texture2D,
		mark_size: Vector2) -> TextureRect:
	if index >= pool.size():
		var made := TextureRect.new()
		made.name = "%s_%d" % [kind, index]
		made.texture = tex
		made.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		made.stretch_mode = TextureRect.STRETCH_SCALE
		made.mouse_filter = MOUSE_FILTER_IGNORE
		made.size = mark_size
		made.pivot_offset = mark_size / 2.0
		made.flip_h = true  # with TRANSPOSE_TURN, the quad's transposed texture
		parent.add_child(made)
		pool.append(made)
	var mark := pool[index]
	if mark.texture != tex:
		mark.texture = tex
	mark.visible = tex != null
	return mark

## Each shown party mark as "dot@(x,y)" or "arrow@(x,y)r<deg>" (the turn the
## original gives, without the transpose's), its centre in aperture pixels
## from the aperture's centre, dots first (the QA log and the tests).
func party_marks_report() -> String:
	var out: PackedStringArray = []
	var centre := APERTURE_RECT.size / 2.0
	for mark in _party_dots:
		if mark.visible:
			var c := mark.position + mark.size / 2.0 - centre
			out.append("dot@(%.1f,%.1f)" % [c.x, c.y])
	for mark in _party_arrows:
		if mark.visible:
			var c := mark.position + mark.size / 2.0 - centre
			out.append("arrow@(%.1f,%.1f)r%.0f" % [c.x, c.y,
				rad_to_deg(mark.rotation - PartyMapMarks.TRANSPOSE_TURN)])
	return " ".join(out)

## Loads the 3x3 tiles around the player's region.
##
## A region with no minimap file is drawn black: 0x661ce0 stores the null
## the loader returns and vslot_013 draws that tile's quad with no texture
## bound, which Direct3D 9 samples as black (the review's reading). It was
## left see-through, showing the window behind (round 630 review).
##
## The tiles are kept here, not in the builder's cache (which keeps every
## texture for its life): the last TILE_CACHE_MAX used, and a set of the
## names that have no file, so a crossing reads only the new column or row.
## OURS: the bound (25, a 5x5 around the player) is our choice.
const TILE_CACHE_MAX := 25
var _tile_cache := {}          # path -> Texture2D, in use order (oldest first)
var _tile_absent := {}         # path -> true
static var _black: ImageTexture = null

static func black_texture() -> ImageTexture:
	if _black == null:
		var img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
		img.fill(Color(0, 0, 0, 1))
		_black = ImageTexture.create_from_image(img)
	return _black

func _load_region_tiles(rx: int, ry: int) -> void:
	for i in 3:
		for j in 3:
			var tile: TextureRect = _tiles[i * 3 + j] if i * 3 + j < _tiles.size() else null
			if tile == null:
				continue
			var r := tile_region(rx, ry, i, j)
			# minimap\<y>x<x>.ddj (AGENTS.md; 0x661ce0's `%s%dx%d.ddj` with
			# the region id's low byte first).
			var tex := _tile_texture("minimap\\%dx%d.ddj" % [r.y, r.x])
			tile.texture = tex if tex != null else black_texture()

func _tile_texture(path: String) -> Texture2D:
	if _tile_cache.has(path):
		var hit: Texture2D = _tile_cache[path]
		_tile_cache.erase(path)
		_tile_cache[path] = hit
		return hit
	if _tile_absent.has(path) or _ui_builder == null:
		return null
	var tex := _ui_builder.load_texture(path, false)
	if tex == null:
		_tile_absent[path] = true
		return null
	_tile_cache[path] = tex
	while _tile_cache.size() > TILE_CACHE_MAX:
		_tile_cache.erase(_tile_cache.keys()[0])
	return tex

## The zoom buttons' handlers, 0x660620 and 0x660660.
func zoom_in() -> void:
	_tile_px_target = minf(_tile_px_target + TILE_PX_STEP, TILE_PX_MAX)

func zoom_out() -> void:
	_tile_px_target = maxf(_tile_px_target - TILE_PX_STEP, TILE_PX_MIN)
