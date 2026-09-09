extends RefCounted
class_name UiBuilder

## Constructs Godot Control node hierarchies from parsed Silkroad Online UI layout definitions
## (UiLayoutParser.LayoutDef) and textures loaded from Media.pk2 via DdjReader.

const DdjReader = preload("res://scripts/ddj/ddj_reader.gd")
const ObjectLoader = preload("res://scripts/assets/object_loader.gd")
const UiLayoutParser = preload("res://scripts/ui/ui_layout_parser.gd")
const UiTextTable = preload("res://scripts/ui/ui_text_table.gd")

## The client's top-level window registry. Each HUD window is declared here
## with its background artwork and its screen rect -- information that is
## *not* in the per-window layout files. `resinfo\\ifunderbar.txt` lists the
## bar's 76 child controls but never names the bar's own background;
## `GDR_UNDERBAR` in this file does (`ub_window_01.ddj`, 800x52 at 112,684).
const WINDOW_REGISTRY_PATH := "resinfo\\ginterface.txt"

var _media_pk2: Pk2Reader
var _text_table: UiTextTable
var _texture_cache: Dictionary = {} # String -> Texture2D
var _window_registry: UiLayoutParser.LayoutDef = null
var _window_registry_loaded: bool = false

func _init(media_pk2: Pk2Reader = null, text_table: UiTextTable = null) -> void:
	_media_pk2 = media_pk2
	_text_table = text_table

## Returns the top-level declaration of a HUD window (e.g. "GDR_UNDERBAR",
## "GDR_MINIMAP") from the client's own window registry, or null if the
## registry or the entry is missing. The returned def carries the window's
## background `ddj` and its authored `rect`.
##
## The registry's rect is `x, y, width, height` -- confirmed by every
## authored size matching its artwork's real dimensions exactly
## (ub_window_01 800x52, ub_deco_left 64x52, ub_menu_button 60x56,
## ub_sp_bar 144x8, mm_window 140x184), which also shows the art is drawn
## 1:1 rather than stretched.
func window_def(window_name: String) -> UiLayoutParser.ControlDef:
	if not _window_registry_loaded:
		_window_registry_loaded = true
		if _media_pk2 != null:
			var entry := ObjectLoader.find_file(_media_pk2, WINDOW_REGISTRY_PATH)
			if entry != null:
				_window_registry = UiLayoutParser.parse(_media_pk2.read_file(entry))
	if _window_registry == null:
		return null
	var sec := _window_registry.get_section("Create")
	if sec == null:
		return null
	return sec.control_by_name.get(window_name)

## Builds a Godot Control containing all controls defined in the specified section.
func build_section(layout: UiLayoutParser.LayoutDef, section_name: String = "Create") -> Control:
	var sec := layout.get_section(section_name)
	if sec == null:
		return null

	var root := Control.new()
	root.name = sec.name
	# Transparent container: it must not eat mouse input meant for the world
	# behind it. IGNORE applies to this node alone, so the controls inside
	# keep their own filters.
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if sec.rect.size.x > 0 and sec.rect.size.y > 0:
		root.position = Vector2(sec.rect.position)
		root.size = Vector2(sec.rect.size)
		root.custom_minimum_size = Vector2(sec.rect.size)

	for ctrl_def in sec.controls:
		var node := build_control(ctrl_def)
		if node != null:
			root.add_child(node)

	return root

## Builds a single Godot node corresponding to a ControlDef.
func build_control(def: UiLayoutParser.ControlDef) -> Control:
	var node: Control = null

	match def.type:
		"CIFButton":
			node = _build_button(def)
		"CIFStatic":
			node = _build_static(def)
		"CIFGauge":
			node = _build_gauge(def)
		"CIFFrame", "CIFStretchWnd":
			node = _build_frame(def)
		"CIFEdit", "CIFEInputChatBox":
			node = _build_edit(def)
		"CIFSlotWithHelp", "CIFSlot", "CIFExtQuickSlotSlot":
			node = _build_slot(def)
		_:
			# Generic container for unhandled or compound control types
			node = _build_generic(def)

	if node != null:
		node.name = def.name
		node.position = Vector2(def.rect.position)
		if def.rect.size.x > 0 and def.rect.size.y > 0:
			node.size = Vector2(def.rect.size)
			node.custom_minimum_size = Vector2(def.rect.size)
		else:
			# A zero-size rect means "use the artwork's own size". Real
			# layouts do this (`GDR_DECORATE_3` in ifunderbar.txt is
			# `Rect=RECT,"677,-40,0,0"` carrying ub_window_02.ddj), and
			# leaving the node at zero size made it invisible. Every authored
			# rect that *does* carry a size matches its texture's dimensions
			# exactly -- ub_window_01 800x52, ub_deco_left 64x52,
			# ub_menu_button 60x56, ub_sp_bar 144x8, mm_window 140x184 --
			# so the art is authored 1:1 and its own size is the right
			# fallback.
			var natural := _natural_size(def)
			if natural != Vector2.ZERO:
				node.size = natural
				node.custom_minimum_size = natural

	return node

## The size of a control's own artwork, or zero if it has none.
func _natural_size(def: UiLayoutParser.ControlDef) -> Vector2:
	if def.ddj == "":
		return Vector2.ZERO
	var tex := load_texture(def.ddj)
	if tex == null:
		return Vector2.ZERO
	return tex.get_size()

func _build_button(def: UiLayoutParser.ControlDef) -> TextureButton:
	var btn := TextureButton.new()
	btn.ignore_texture_size = true
	btn.stretch_mode = TextureButton.STRETCH_SCALE

	if def.ddj != "":
		btn.texture_normal = load_texture(def.ddj)

		# State textures convention: _focus, _press, _disable
		var focus_path := _insert_suffix(def.ddj, "_focus")
		var press_path := _insert_suffix(def.ddj, "_press")
		var disable_path := _insert_suffix(def.ddj, "_disable")

		btn.texture_hover = load_texture(focus_path)
		btn.texture_focused = btn.texture_hover
		btn.texture_pressed = load_texture(press_path)
		btn.texture_disabled = load_texture(disable_path)

	if def.text != "":
		var label := Label.new()
		label.name = "ButtonLabel"
		label.text = _resolve_text(def.text)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.set_anchors_preset(Control.PRESET_FULL_RECT)
		if def.font_color != Color.WHITE:
			label.add_theme_color_override("font_color", def.font_color)
		btn.add_child(label)

	return btn

func _build_static(def: UiLayoutParser.ControlDef) -> Control:
	if def.ddj != "":
		var rect := TextureRect.new()
		rect.texture = load_texture(def.ddj)
		rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		rect.stretch_mode = TextureRect.STRETCH_SCALE
		# `Color` is deliberately NOT applied as a tint. It looks like one,
		# but it is a per-control editor id: across ifunderbar.txt's 76
		# controls there are 64 distinct values, scattered
		# (255,51,191,68 / 255,91,102,218 / 255,64,213,106 ...), whereas
		# `FontColor` -- a field that really is a colour -- is pure white on
		# 74 of those same 76. Modulating by it tinted every piece of
		# artwork a different random colour.

		if def.text != "":
			var label := Label.new()
			label.name = "Text"
			label.text = _resolve_text(def.text)
			label.horizontal_alignment = _map_halign(def.halign)
			label.vertical_alignment = _map_valign(def.valign)
			label.set_anchors_preset(Control.PRESET_FULL_RECT)
			if def.font_color != Color.WHITE:
				label.add_theme_color_override("font_color", def.font_color)
			rect.add_child(label)

		return rect
	elif def.text != "":
		var label := Label.new()
		label.text = _resolve_text(def.text)
		label.horizontal_alignment = _map_halign(def.halign)
		label.vertical_alignment = _map_valign(def.valign)
		if def.font_color != Color.WHITE:
			label.add_theme_color_override("font_color", def.font_color)
		return label
	else:
		return _build_generic(def)

func _build_gauge(def: UiLayoutParser.ControlDef) -> TextureProgressBar:
	var gauge := TextureProgressBar.new()
	gauge.min_value = 0
	gauge.max_value = 100
	gauge.value = 100
	gauge.nine_patch_stretch = true

	if def.ddj != "":
		gauge.texture_progress = load_texture(def.ddj)

	return gauge

func _build_frame(def: UiLayoutParser.ControlDef) -> Control:
	var container := Control.new()
	container.mouse_filter = Control.MOUSE_FILTER_PASS

	if def.ddj != "" and def.ddj.ends_with("_"):
		# 8-slice border: left_up, mid_up, right_up, left_side, right_side, left_down, mid_down, right_down
		var lu := load_texture(def.ddj + "left_up.ddj")
		var mu := load_texture(def.ddj + "mid_up.ddj")
		var ru := load_texture(def.ddj + "right_up.ddj")
		var ls := load_texture(def.ddj + "left_side.ddj")
		var rs := load_texture(def.ddj + "right_side.ddj")
		var ld := load_texture(def.ddj + "left_down.ddj")
		var md := load_texture(def.ddj + "mid_down.ddj")
		var rd := load_texture(def.ddj + "right_down.ddj")

		var corner_w := lu.get_width() if lu != null else 10
		var corner_h := lu.get_height() if lu != null else 10

		_add_slice(container, lu, Rect2(0, 0, corner_w, corner_h))
		_add_slice(container, mu, Rect2(corner_w, 0, def.rect.size.x - corner_w * 2, corner_h), true)
		_add_slice(container, ru, Rect2(def.rect.size.x - corner_w, 0, corner_w, corner_h))

		_add_slice(container, ls, Rect2(0, corner_h, corner_w, def.rect.size.y - corner_h * 2), true)
		_add_slice(container, rs, Rect2(def.rect.size.x - corner_w, corner_h, corner_w, def.rect.size.y - corner_h * 2), true)

		_add_slice(container, ld, Rect2(0, def.rect.size.y - corner_h, corner_w, corner_h))
		_add_slice(container, md, Rect2(corner_w, def.rect.size.y - corner_h, def.rect.size.x - corner_w * 2, corner_h), true)
		_add_slice(container, rd, Rect2(def.rect.size.x - corner_w, def.rect.size.y - corner_h, corner_w, corner_h))

	return container

func _add_slice(parent: Control, tex: Texture2D, rect: Rect2, tile: bool = false) -> void:
	if tex == null or rect.size.x <= 0 or rect.size.y <= 0:
		return
	var tr := TextureRect.new()
	tr.texture = tex
	tr.position = rect.position
	tr.size = rect.size
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_TILE if tile else TextureRect.STRETCH_SCALE
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(tr)

func _build_edit(def: UiLayoutParser.ControlDef) -> LineEdit:
	var edit := LineEdit.new()
	if def.text != "":
		edit.placeholder_text = _resolve_text(def.text)
	return edit

func _build_slot(def: UiLayoutParser.ControlDef) -> Control:
	var slot := Control.new()
	slot.mouse_filter = Control.MOUSE_FILTER_PASS

	if def.ddj != "":
		var bg := TextureRect.new()
		bg.name = "SlotBg"
		bg.texture = load_texture(def.ddj)
		bg.set_anchors_preset(Control.PRESET_FULL_RECT)
		bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(bg)

	var icon := TextureRect.new()
	icon.name = "ItemIcon"
	icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.add_child(icon)

	var count_lbl := Label.new()
	count_lbl.name = "CountLabel"
	count_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	count_lbl.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	count_lbl.set_anchors_preset(Control.PRESET_FULL_RECT)
	count_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.add_child(count_lbl)

	return slot

func _build_generic(def: UiLayoutParser.ControlDef) -> Control:
	var ctrl := Control.new()
	ctrl.mouse_filter = Control.MOUSE_FILTER_PASS
	return ctrl

## Loads a .ddj texture from Media.pk2, using an in-memory cache to avoid duplicate decodes.
func load_texture(ddj_path: String) -> Texture2D:
	if ddj_path.is_empty():
		return null
	var key := ddj_path.to_lower().replace("/", "\\")
	if _texture_cache.has(key):
		return _texture_cache[key]

	if _media_pk2 == null:
		return null

	var entry := ObjectLoader.find_file(_media_pk2, key)
	if entry == null:
		return null
	var data := _media_pk2.read_file(entry)
	if data.is_empty():
		return null
	var parsed := DdjReader.parse(data)
	if parsed == null:
		return null
	var tex := DdjReader.to_texture(parsed)
	if tex != null:
		_texture_cache[key] = tex
	return tex

func _resolve_text(key_or_text: String) -> String:
	if _text_table != null:
		return _text_table.get_text(key_or_text)
	return key_or_text

func _insert_suffix(path: String, suffix: String) -> String:
	var dot := path.rfind(".")
	if dot == -1:
		return path + suffix
	return path.substr(0, dot) + suffix + path.substr(dot)

func _map_halign(h: int) -> HorizontalAlignment:
	match h:
		1: return HORIZONTAL_ALIGNMENT_CENTER
		2: return HORIZONTAL_ALIGNMENT_RIGHT
		_: return HORIZONTAL_ALIGNMENT_LEFT

func _map_valign(v: int) -> VerticalAlignment:
	match v:
		1: return VERTICAL_ALIGNMENT_CENTER
		2: return VERTICAL_ALIGNMENT_BOTTOM
		_: return VERTICAL_ALIGNMENT_TOP
