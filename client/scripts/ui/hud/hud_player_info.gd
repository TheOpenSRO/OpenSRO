extends Control
class_name HudPlayerInfo

## The top-left block: portrait, name, level, and the HP and MP bars.
##
## Unlike the panel windows, this one *is* in the client's window registry:
## `GDR_PLAYER_MINI_INFO` in resinfo\ginterface.txt gives it
## `interface\ifcommon\window_all.ddj` and the rect `4,7,212,70`. Its 53
## child controls come from resinfo\ifplayerminiinfo.txt, of which the ones
## that matter here are GDR_PMI_PICTURE, GDR_PMI_TXT_ID, GDR_PMI_TXT_LEVEL,
## and the HP/MP gauge and text pairs. The rest of that file is the
## expandable character panel (GDR_PMI_STA_CINFOBG and the GDR_PMI_TXT_*DAT
## stat rows) and the Hwan decorations, which the Character window covers
## instead.
##
## **window_all.ddj is a 1024x512 atlas**, and the registry entry's own
## `UV_LT`/`UV_RB` name this window's slice of it: `0.723633,0` to
## `0.930664,0.136719`, which is atlas pixels (741,0)-(953,70) -- exactly
## the 212x70 the rect declares. That slice is the SRO player block: a
## circular portrait socket on the left and two horizontal bar slots for HP
## and MP on the right.
##
## An earlier version of this file said those UV fields were always
## `0,0`-`1,1` and so the background could not be placed. That was read off
## three layout files; across the 229 real `resinfo` layouts there are 18
## distinct `UV_LT` values.

const UiBuilder = preload("res://scripts/ui/ui_builder.gd")
const UiLayoutParser = preload("res://scripts/ui/ui_layout_parser.gd")

const LAYOUT_PATH := "resinfo\\ifplayerminiinfo.txt"
const REGISTRY_NAME := "GDR_PLAYER_MINI_INFO"

## Fallback size, used only if the registry can't be read. From
## GDR_PLAYER_MINI_INFO's own rect.
const SIZE_WIDTH := 212
const SIZE_HEIGHT := 70

## The only controls from ifplayerminiinfo.txt drawn as part of the
## always-on block. Everything else in that layout belongs to the character
## panel or to decorations this project does not drive yet.
const SHOWN_CONTROLS := [
	"GDR_PMI_PICTURE",
	"GDR_PMI_TXT_ID",
	"GDR_PMI_TXT_LEVEL",
	"GDR_PMI_GAUGE_HP",
	"GDR_PMI_GAUGE_MP",
	"GDR_PMI_TXT_HP",
	"GDR_PMI_TXT_MP",
]

var _builder: UiBuilder
var _name_label: Label
var _level_label: Label
var _hp_gauge: TextureProgressBar
var _mp_gauge: TextureProgressBar
var _hp_text: Label
var _mp_text: Label

func _init(builder: UiBuilder = null) -> void:
	_builder = builder

func setup() -> void:
	var panel_size := Vector2(SIZE_WIDTH, SIZE_HEIGHT)
	if _builder != null:
		var reg := _builder.window_def(REGISTRY_NAME)
		if reg != null and reg.rect.size.x > 0:
			panel_size = Vector2(reg.rect.size)
	custom_minimum_size = panel_size
	size = panel_size
	# Transparent container over the world: must not swallow clicks.
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	if _builder == null:
		return

	# The frame, from the registry's own atlas slice, behind everything.
	var reg_def := _builder.window_def(REGISTRY_NAME)
	if reg_def != null and reg_def.ddj != "":
		var frame := TextureRect.new()
		frame.name = "Frame"
		frame.texture = _builder.load_texture_region(reg_def.ddj, reg_def.uv_lt, reg_def.uv_rb)
		frame.position = Vector2.ZERO
		frame.size = panel_size
		frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		frame.stretch_mode = TextureRect.STRETCH_SCALE
		frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(frame)

	var layout := _builder.load_layout(LAYOUT_PATH)
	if layout == null:
		return
	var root := _builder.build_section(layout, "Create")
	if root == null:
		return
	add_child(root)

	# Show only the always-on block, and hide everything else the layout
	# carries. That file is 53 controls: the expandable character panel
	# (GDR_PMI_STA_CINFOBG plus every GDR_PMI_TXT_*DAT stat row), the
	# Hwan/jahwan level decorations and their glow, the pet strip, the
	# selection highlight and the PK/fortress status icons. Rendered
	# together they are a pile of overlapping artwork sitting on top of the
	# world -- which is exactly what the first render of this panel showed.
	#
	# An allow-list rather than a deny-list, so a control nobody has
	# accounted for stays hidden instead of appearing unannounced.
	for child in root.get_children():
		if child is CanvasItem:
			(child as CanvasItem).visible = child.name in SHOWN_CONTROLS

	_name_label = root.find_child("GDR_PMI_TXT_ID", true, false) as Label
	_level_label = root.find_child("GDR_PMI_TXT_LEVEL", true, false) as Label
	_hp_text = root.find_child("GDR_PMI_TXT_HP", true, false) as Label
	_mp_text = root.find_child("GDR_PMI_TXT_MP", true, false) as Label
	_hp_gauge = root.find_child("GDR_PMI_GAUGE_HP", true, false) as TextureProgressBar
	_mp_gauge = root.find_child("GDR_PMI_GAUGE_MP", true, false) as TextureProgressBar
	_tint(_hp_gauge, Color(0.78, 0.15, 0.15))
	_tint(_mp_gauge, Color(0.16, 0.36, 0.86))

## Neither gauge names any artwork: `GDR_PMI_GAUGE_HP` and `_MP` have an
## empty `DDJ`, and the atlas slice above supplies the *slot* they sit in,
## not a fill. So the client draws the fill itself, and these two colours
## are read off the reference screenshots -- a red HP bar over a blue MP
## bar -- rather than out of the data. Searched for and not found: nothing
## under `pmi_`, `com_bar0N` (those are list-row bars, near-black) or any
## `gauge` name is an HP/MP fill; the only `gauge.dat` files are the
## launcher's. Flagged as the invented values they are.
func _tint(gauge: TextureProgressBar, colour: Color) -> void:
	if gauge == null:
		return
	gauge.tint_progress = colour
	gauge.min_value = 0
	gauge.max_value = 100
	gauge.value = 100

func set_character(character_name: String, level: int) -> void:
	if _name_label != null:
		_name_label.text = character_name
	if _level_label != null:
		_level_label.text = "Lv %d" % level

func set_hp(current: int, maximum: int) -> void:
	_set_bar(_hp_gauge, _hp_text, current, maximum)

func set_mp(current: int, maximum: int) -> void:
	_set_bar(_mp_gauge, _mp_text, current, maximum)

func _set_bar(gauge: TextureProgressBar, label: Label, current: int, maximum: int) -> void:
	if maximum <= 0:
		return
	if gauge != null:
		gauge.value = clampf(float(current) / float(maximum) * 100.0, 0.0, 100.0)
	if label != null:
		label.text = "%d / %d" % [current, maximum]
