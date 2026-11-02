extends Control
class_name HudPetMiniInfo

## The growth pet's strip under the player block (round 795): the client's
## CIFPetMiniInfo, child 100 of GDR_PLAYER_MINI_INFO. READ from sro_client.exe
## and Media.pk2 unless a line says otherwise (client_ui.md section 1b).
##
## - The control is `GDR_PMI_PET_MINI_INFO` in `resinfo\ifplayerminiinfo.txt`:
##   CIFPetMiniInfo, ID 100, Rect 53,55,154,40 relative to the player block,
##   its art the `interface\ifcommon\window_all.ddj` slice UV 0.846679,0.138671
##   -> 0.997070,0.216796 (atlas pixels 867,71 - 1021,111, 154x40, MEASURED
##   1:1). CIFPlayerMiniInfo::Create hides it (0x7b5d65).
## - Its children are `resinfo\ifpetminiinfo.txt` "Create": the picture
##   (id 20, 4,4,32,32) clipped by `pmi_pet_face.ddj` (Create 0x7b4490), the
##   name (15), the level (16, yellow), the HP and HGP gauges (10, 11), the
##   buff row (30) and the HP caution effect (100).
## - Fill (FUN_007b4800): the picture is the COS icon (characterdata column
##   54); the name the record's or UIIT_STT_COSNEWUI_TITLE "No name"; the
##   level UIIT_STT_LV_LEVEL "Lv. %d".
## - Each frame (vslot_012 0x7b41f0): HGP = HGP / 10000.0 (kind 3 only), HP =
##   the record's HP over the row's MaxHP; the caution effect shown while
##   0 < HP ratio <= 0.3 (the float 0.3 at 0xd82f00).
## - Shown with a kind 3 summon (0x811500 -> 0x7b5420(1, id)), hidden with its
##   removal (0x8116f0); refilled by 0x30C9 cases 3 (level-up), 5 and 7.
##
## The picture clip is CIFStaticWithPictureClip's draw (HudPlayerInfo's
## portrait reads it: both textures over the control's rect at full UV, the
## colour from the picture and the alpha from the mask).
##
## OPEN (client_ui.md 6.1): the caution effect's animation (frame step and
## count) -- the authored first frame (UV 0..0.20898 x 0..0.5) is drawn still.
## OPEN: the buff row (30) is the pet object's buff list, which this client
## does not keep; it is left empty.

const PARENT_LAYOUT := "resinfo\\ifplayerminiinfo.txt"
const PARENT_CONTROL := "GDR_PMI_PET_MINI_INFO"
const LAYOUT := "resinfo\\ifpetminiinfo.txt"
## GDR_PMI_PET_MINI_INFO's own rect and art (READ above), used when the
## parent layout is not at hand.
const RECT := Rect2(53, 55, 154, 40)
const ATLAS := "interface\\ifcommon\\window_all.ddj"
const UV_LT := Vector2(0.846679, 0.138671)
const UV_RB := Vector2(0.997070, 0.216796)
const FACE_MASK := "interface\\playerminiinfo\\pmi_pet_face.ddj"
## The caution threshold (0xd82f00).
const CAUTION_RATIO := 0.3

const PICTURE := "GDR_PET_MINI_PICTURE"
const TXT_NAME := "GDR_PET_MINI_TXT_NAME"
const TXT_LEVEL := "GDR_PET_MINI_TXT_LEVEL"
const GAUGE_HP := "GDR_PET_MINI_GAUGE_HP"
const GAUGE_HGP := "GDR_PET_MINI_GAUGE_HGP"
const EFFECT_HP := "GDR_PET_MINI_EFFECT_HP"
const BUFF := "GDR_PET_MINI_BUFF"

const MASK_SHADER := """
shader_type canvas_item;
// CIFStaticWithPictureClip: colour from the picture, alpha from the mask.
uniform sampler2D mask_tex : filter_linear;
varying vec4 modulate;
void vertex() {
	modulate = COLOR;
}
void fragment() {
	vec4 c = texture(TEXTURE, UV);
	COLOR = vec4(c.rgb, c.a * texture(mask_tex, UV).a) * modulate;
}
"""

var _builder: UiBuilder
var _text: Callable
var root: Control
var name_label: Label
var level_label: Label
var hp_gauge: TextureProgressBar
var hgp_gauge: TextureProgressBar
var effect: CanvasItem
var picture: TextureRect
var uid := 0
## Control 100's rect as read in build() (RECT without the layout).
var authored_rect := RECT

func _init(builder: UiBuilder = null, text: Callable = Callable()) -> void:
	_builder = builder
	_text = text
	name = "PetMiniInfo"
	position = RECT.position
	size = RECT.size
	custom_minimum_size = RECT.size
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false

## Builds the strip: its own art from the parent layout's control, then
## ifpetminiinfo.txt. False without the layout.
func build() -> bool:
	if _builder == null:
		return false
	var rect := RECT
	var ddj := ATLAS
	var lt := UV_LT
	var rb := UV_RB
	var parent_layout := _builder.load_layout(PARENT_LAYOUT)
	if parent_layout != null:
		for sec_name in parent_layout.sections:
			var sec: UiLayoutParser.SectionDef = parent_layout.sections[sec_name]
			if sec.control_by_name.has(PARENT_CONTROL):
				var d: UiLayoutParser.ControlDef = sec.control_by_name[PARENT_CONTROL]
				rect = Rect2(d.rect)
				ddj = d.ddj
				lt = d.uv_lt
				rb = d.uv_rb
				break
	authored_rect = rect
	position = rect.position
	size = rect.size
	custom_minimum_size = rect.size
	var bg := TextureRect.new()
	bg.name = "Frame"
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.texture = _builder.load_texture_region(ddj, lt, rb)
	bg.size = rect.size
	add_child(bg)
	var layout := _builder.load_layout(LAYOUT)
	if layout == null:
		return false
	root = _builder.build_section(layout, "Create")
	if root == null:
		return false
	add_child(root)
	name_label = root.get_node_or_null(TXT_NAME) as Label
	level_label = root.get_node_or_null(TXT_LEVEL) as Label
	hp_gauge = root.get_node_or_null(GAUGE_HP) as TextureProgressBar
	hgp_gauge = root.get_node_or_null(GAUGE_HGP) as TextureProgressBar
	effect = root.get_node_or_null(EFFECT_HP) as CanvasItem
	for g in [hp_gauge, hgp_gauge]:
		if g != null:
			(g as TextureProgressBar).max_value = 1.0
			(g as TextureProgressBar).step = 0.0
			(g as TextureProgressBar).value = 0.0   # both start at 0 (READ)
	var pic := root.get_node_or_null(PICTURE) as Control
	if pic != null:
		picture = TextureRect.new()
		picture.name = "Picture"
		picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		picture.stretch_mode = TextureRect.STRETCH_SCALE
		picture.mouse_filter = Control.MOUSE_FILTER_IGNORE
		picture.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		var mat := ShaderMaterial.new()
		var sh := Shader.new()
		sh.code = MASK_SHADER
		mat.shader = sh
		mat.set_shader_parameter("mask_tex", _builder.load_texture(FACE_MASK))
		picture.material = mat
		pic.add_child(picture)
		pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if effect != null:
		effect.visible = false
	UiBuilder.settle_authored_rects(root)
	return true

## Hangs the strip on the player block as child 100 of GDR_PLAYER_MINI_INFO:
## in control 100's own place among the block's children, at its authored
## rect (53,55 of the block). Round 855: it was appended after the whole
## block, so it drew over the portrait ring, the race mark and the stat
## button, which the original draws over it.
##
## The original's order (READ, round 855; docs/protocol/player_mini_info.md
## "Draw order"): a window draws its children in its child list's order
## (0xba0300), and ifplayerminiinfo.txt's controls join that list in
## REVERSE file order -- CIFTSection::vslot_000 (0xb3dcb0) lists a section's
## controls from the last (+0x88, via +0x50) back, the records keep that
## order (0x82c1d0) and 0x8b5580 creates them in it, each appended by its
## parent's AddChild (0xb90a80, a push_back; called from 0xba20b0). So the
## file's first control is drawn last, on top. Control 100 is the file's
## 52nd of 53, so only GDR_PMI_SELECT (id 200, the 53rd) is drawn under it;
## everything else of the block -- the portrait, the ring's orbs and ready
## circle, the race mark, the stat button, the gauges and their text -- is
## drawn over it. Showing it (0x7b5420 -> vtable +0x5c, 0x652b70) does not
## move it in the list. UiBuilder.build_section builds the same order (the
## file reversed into Godot's tree order), with the layout's own control 100
## as a hidden placeholder (HudPlayerInfo's allow-list); the strip goes in
## right above it, which is exactly control 100's place.
func attach_to(player_info: Control) -> void:
	if player_info == null:
		return
	if get_parent() != null:
		get_parent().remove_child(self)
	var slot := player_info.find_child(PARENT_CONTROL, true, false) as Control
	if slot == null or slot.get_parent() == null:
		# No layout (no archives): nothing of the block to draw over.
		player_info.add_child(self)
		position = authored_rect.position
		return
	var holder := slot.get_parent()
	holder.add_child(self)
	holder.move_child(self, slot.get_index() + 1)
	position = slot.position

## FUN_007b4800: the pet's picture, name and level.
func fill(cos_uid: int, pet_name: String, level: int, icon: Texture2D) -> void:
	uid = cos_uid
	if name_label != null:
		name_label.text = name_text(pet_name, _text)
	if level_label != null:
		level_label.text = level_text(level, _text)
	if picture != null:
		picture.texture = icon

## The name row: the record's, or "No name" (UIIT_STT_COSNEWUI_TITLE).
static func name_text(pet_name: String, text: Callable) -> String:
	if pet_name != "":
		return pet_name
	return _t(text, "UIIT_STT_COSNEWUI_TITLE", "No name")

## The level row: UIIT_STT_LV_LEVEL "Lv. %d".
static func level_text(level: int, text: Callable) -> String:
	var fmt := _t(text, "UIIT_STT_LV_LEVEL", "Lv. %d")
	return fmt.replace("%d", str(level)) if fmt.contains("%d") else "%s %d" % [fmt, level]

static func _t(text: Callable, key: String, fallback: String) -> String:
	if text.is_valid():
		return String(text.call(key, fallback))
	return fallback

## Whether the caution effect shows at `hp_ratio` (vslot_012: 0 < r <= 0.3).
static func caution_on(hp_ratio: float) -> bool:
	return hp_ratio > 0.0 and hp_ratio <= CAUTION_RATIO

## The per-frame gauges (vslot_012). HGP is drawn only for a growth pet,
## which is the only kind this strip is shown for.
func set_ratios(hp_ratio: float, hgp_ratio: float) -> void:
	if hp_gauge != null:
		hp_gauge.value = clampf(hp_ratio, 0.0, 1.0)
	if hgp_gauge != null:
		hgp_gauge.value = clampf(hgp_ratio, 0.0, 1.0)
	if effect != null:
		effect.visible = caution_on(hp_ratio)
