extends RefCounted
class_name OptionVideoPage

## The Option window's Video tab (round 694): the controls of
## `res_ui\optionwnd.2dt`'s pane 78, wired to a VideoOptions being edited.
## OptionWindow owns one; VideoOptions holds what each row means and what the
## original does. Labels: **READ** (sro_client.exe), **MEASURED**,
## **INFERRED**, **OURS**.
##
## **The controls (READ, the GetChild chains at the top of 0x5fef70; MEASURED
## in the archive's file, 208 records):**
##   78 -> 14 -> 15      Resolution combo (this+0x79c), label 162
##   78 -> 462 -> 15     Set Brightness combo (+0x7a0), label 163
##   78 -> 465           the list's scroll bar (+0x7a4)
##   78 -> 204 / 203     Window screen / Full screen check boxes (+0x7a8 / +0x7ac)
##   78 -> 207 / 208 / 209  Free / Third Person / Quarter Angle (+0x7b0..+0x7b8)
##   78 -> 24 / 25       the Graphic 1 / Graphic 2 tabs (group 11)
##   78 -> 215, 218 .. 248  twelve CNIFVideoOptionSlot rows, two a line, each
##                       a label 216 and a combo 217
## The list shows six lines of two; its scroll bar moves a line at a time
## (INFERRED: the step was not read). A row's tooltip is its
## UIIT_STT_VIDIO_TTDESC_* text (READ: each row's second push in 0x5fef70).
##
## **The combo (READ in part).** CNIFComboBox's create (vslot_010, 0x486d30)
## loads `interface\ifcommon\com_qst_downarrow_button.ddj` for its button and
## `interface\ifcommon\com_blacksquare_` for its list's frame. How it draws
## its field and list is not read; here (OURS) it is a Godot OptionButton
## with that arrow, the client's font, centred white text and no field art of
## its own -- the row's own texture (opt_key2_long.ddj,
## opt_video_control_box2.ddj) draws the field behind it.
##
## **The buttons.** Default on this tab (0x5fc340, READ) sets Middle, Normal
## brightness, the 1280 x 1024 mode when listed, FULL SCREEN and the Free
## view. OURS: Default puts back this client's defaults (VideoOptions.DEFAULTS:
## the look before round 694, in a window), and keeps the resolution.
## Apply / Confirm store the record (0x5fdae0, READ) and apply it -- nothing
## on this tab changes the screen before then (INFERRED: the store calls the
## game's apply, CGame::FUN_00835000; the combo handlers were not read).
## Cancel and the close button leave the record in force as it was.

const ID_PANE := 78
const ID_RES_BOX := 14
const ID_BRIGHT_BOX := 462
const ID_COMBO := 15
const ID_SCROLL := 465
const ID_WINDOWED := 204
const ID_FULLSCREEN := 203
const ID_VIEW_FREE := 207
const ID_VIEW_THIRD := 208
const ID_VIEW_QUARTER := 209
const ID_TAB_G1 := 24
const ID_TAB_G2 := 25
const SLOT_IDS := [215, 218, 221, 224, 227, 230, 233, 236, 239, 242, 245, 248]
const ID_SLOT_LABEL := 216
const ID_SLOT_COMBO := 217
const VIEWS := ["free", "third_person", "quarter"]

## The rows the list shows, in order: retail's 0..13 and 15 (READ), then SSAO
## and the renderer (OURS).
const LIST := [VideoOptions.QUALITY, VideoOptions.SHADOW, VideoOptions.SCENERY,
	VideoOptions.CHARACTER, VideoOptions.WATER_REFLECTION, VideoOptions.WATER_DETAIL,
	VideoOptions.METAL, VideoOptions.LIGHT, VideoOptions.FILTERING, VideoOptions.TEXTURE,
	VideoOptions.LENS_FLARE, VideoOptions.BLOOM, VideoOptions.DYNAMIC_ANIMATION,
	VideoOptions.EFFECT, VideoOptions.FRIEND_ENEMY, VideoOptions.SSAO, VideoOptions.RENDERER]
const COLUMNS := 2

const ARROW_DDJ := "interface\\ifcommon\\com_qst_downarrow_button.ddj"
const SCROLL_BAR_DDJ := "interface\\ifcommon\\com_scroll_bar.ddj"
const SCROLL_UP_DDJ := "interface\\chattingwnd\\chat_arrow_up.ddj"
const SCROLL_DOWN_DDJ := "interface\\chattingwnd\\chat_arrow_down.ddj"
const SCROLL_THUMB_DDJ := "interface\\ifcommon\\com_scroll_button.ddj"
## Text greyed for a row this renderer cannot draw (OURS).
const DISABLED_TEXT := Color(0.55, 0.55, 0.55)

var _window: Control
var _builder: UiBuilder
var _root: Control
var edit: VideoOptions
## The screen size the resolution list is built for.
var _screen := Vector2i.ZERO
var _resolutions: Array = []
var _res_combo: OptionButton
var _bright_combo: OptionButton
var _windowed: BaseButton
var _fullscreen: BaseButton
var _views: Array = []
var _tabs: Array = []
## Per visible slot: [label: Label, combo: OptionButton].
var _slots: Array = []
var _scroll_line := 0
var _scroll_track: Control
var _scroll_thumb: Control
## The renderer recorded for the next start, as the window shows it.
var renderer_choice := ""

signal changed

func _init(window: Control, builder: UiBuilder, root: Control) -> void:
	_window = window
	_builder = builder
	_root = root

## Builds the page's pieces over the file's controls and loads `options`.
func build(options: VideoOptions, view: String, screen: Vector2i, window_size: Vector2i) -> void:
	edit = options.duplicate_options()
	edit.camera_view = view
	_screen = screen
	var pane := at([ID_PANE])
	if pane == null:
		return
	_res_combo = _make_combo(at([ID_PANE, ID_RES_BOX, ID_COMBO]))
	_bright_combo = _make_combo(at([ID_PANE, ID_BRIGHT_BOX, ID_COMBO]))
	_resolutions = VideoOptions.resolution_choices(screen, window_size)
	if _res_combo != null:
		for r in _resolutions:
			_res_combo.add_item("%d x %d" % [r.x, r.y])
		_res_combo.item_selected.connect(func(i: int) -> void:
			edit.resolution = _resolutions[i]
			changed.emit())
	if _bright_combo != null:
		for i in VideoOptions.BRIGHTNESS_KEYS.size():
			_bright_combo.add_item(text(VideoOptions.BRIGHTNESS_KEYS[i], VideoOptions.BRIGHTNESS_FALLBACK[i]))
		_bright_combo.item_selected.connect(func(i: int) -> void:
			edit.current().brightness = i
			changed.emit())
		_bright_combo.tooltip_text = text("UIIT_STT_VIDIO_TTDESC_02", "")
	if _res_combo != null:
		_res_combo.tooltip_text = text("UIIT_STT_VIDIO_TTDESC_01", "")
	_windowed = at([ID_PANE, ID_WINDOWED]) as BaseButton
	_fullscreen = at([ID_PANE, ID_FULLSCREEN]) as BaseButton
	for b in [_windowed, _fullscreen]:
		if b != null:
			var full: bool = b == _fullscreen
			b.toggled.connect(func(_on: bool) -> void:
				edit.fullscreen = full
				_show_shared())
	_views = [at([ID_PANE, ID_VIEW_FREE]), at([ID_PANE, ID_VIEW_THIRD]), at([ID_PANE, ID_VIEW_QUARTER])]
	for i in _views.size():
		var b := _views[i] as BaseButton
		if b != null:
			var v: String = VIEWS[i]
			b.toggled.connect(func(_on: bool) -> void:
				edit.camera_view = v
				_show_shared())
	_tabs = [at([ID_PANE, ID_TAB_G1]), at([ID_PANE, ID_TAB_G2])]
	for i in _tabs.size():
		var t := _tabs[i] as BaseButton
		if t != null:
			var idx: int = i
			# After TwoDtBuilder.click_tab (connected first): the record
			# shown switches (READ, NIFOption 0x5fd5f0).
			t.pressed.connect(func() -> void: select_profile(idx))
	for id in SLOT_IDS:
		var slot := at([ID_PANE, id])
		var label := _slot_label(slot)
		var combo := _make_combo(at([ID_PANE, id, ID_SLOT_COMBO]))
		_slots.append([label, combo, slot])
		if combo != null:
			var n: int = _slots.size() - 1
			combo.item_selected.connect(func(i: int) -> void: _on_slot_chosen(n, i))
	_build_scroll(at([ID_PANE, ID_SCROLL]), pane)
	var rc := VideoOptions.renderer_choice_script()
	if rc != null:
		renderer_choice = str(rc.call("chosen"))
	if renderer_choice == "":
		renderer_choice = "forward_plus" if VideoOptions.forward_plus_running() else "gl_compatibility"
	show_values()

# --- the pieces -------------------------------------------------------------------

## The text of a table key, or `fallback` when the table has none.
func text(key: String, fallback: String) -> String:
	if key == "":
		return fallback
	var table := _builder.text_table() if _builder != null else null
	if table == null or not table.has(key):
		return fallback if fallback != "" else key
	return table.get_text(key)

## A combo over a ComboBox record's (unbuilt) node: see the header.
func _make_combo(host: Control) -> OptionButton:
	if host == null:
		return null
	var combo := OptionButton.new()
	combo.name = "Combo"
	combo.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	combo.focus_mode = Control.FOCUS_NONE
	combo.alignment = HORIZONTAL_ALIGNMENT_CENTER
	combo.fit_to_longest_item = false
	combo.clip_text = true
	for st in ["normal", "hover", "pressed", "disabled", "focus", "hover_pressed"]:
		combo.add_theme_stylebox_override(st, StyleBoxEmpty.new())
	var arrow := _builder.load_texture(ARROW_DDJ) if _builder != null else null
	if arrow != null:
		combo.add_theme_icon_override("arrow", arrow)
	var font := _builder.font_at(0) if _builder != null else null
	if font != null:
		combo.add_theme_font_override("font", font)
	combo.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[0])
	for c in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]:
		combo.add_theme_color_override(c, Color.WHITE)
	combo.add_theme_color_override("font_disabled_color", DISABLED_TEXT)
	UiBuilder.guard_button_font(combo)
	host.mouse_filter = Control.MOUSE_FILTER_PASS
	host.add_child(combo)
	return combo

func _slot_label(slot: Control) -> Label:
	if slot == null:
		return null
	var host := TwoDtBuilder.child(slot, ID_SLOT_LABEL)
	if host == null:
		return null
	var label := host.get_node_or_null(TwoDtBuilder.TEXT_NODE) as Label
	if label == null:
		label = Label.new()
		label.name = TwoDtBuilder.TEXT_NODE
		label.set_anchors_preset(Control.PRESET_FULL_RECT)
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		var font := _builder.font_at(0) if _builder != null else null
		if font != null:
			label.add_theme_font_override("font", font)
		label.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[0])
		label.add_theme_color_override("font_color", Color.WHITE)
		UiBuilder.crisp_text(label)
		host.add_child(label)
	# The tooltip is the slot's; the label host passes the mouse to it.
	host.mouse_filter = Control.MOUSE_FILTER_PASS
	return label

## The list's scroll bar (CNIFVerticalScroll, READ art: the track
## com_scroll_bar.ddj, chat_arrow_up / chat_arrow_down.ddj, the thumb
## com_scroll_button.ddj -- 0x478e90..0x478ff8). Its layout -- arrows at the
## ends, the thumb between -- and a line a click are OURS.
func _build_scroll(host: Control, pane: Control) -> void:
	if host == null:
		return
	host.mouse_filter = Control.MOUSE_FILTER_STOP
	var track := TextureRect.new()
	track.name = "Track"
	track.texture = _builder.load_texture(SCROLL_BAR_DDJ) if _builder != null else null
	track.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	track.stretch_mode = TextureRect.STRETCH_SCALE
	track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var w := host.size.x
	track.position = Vector2(0, w)
	track.size = Vector2(w, maxf(host.size.y - 2.0 * w, 0.0))
	host.add_child(track)
	_scroll_track = track
	var up := _scroll_button(SCROLL_UP_DDJ, Vector2.ZERO, Vector2(w, w))
	up.name = "Up"
	up.pressed.connect(func() -> void: scroll_to(_scroll_line - 1))
	host.add_child(up)
	var down := _scroll_button(SCROLL_DOWN_DDJ, Vector2(0, host.size.y - w), Vector2(w, w))
	down.name = "Down"
	down.pressed.connect(func() -> void: scroll_to(_scroll_line + 1))
	host.add_child(down)
	var thumb := TextureRect.new()
	thumb.name = "Thumb"
	thumb.texture = _builder.load_texture(SCROLL_THUMB_DDJ) if _builder != null else null
	thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	thumb.stretch_mode = TextureRect.STRETCH_SCALE
	thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	thumb.size = Vector2(w, w)
	host.add_child(thumb)
	_scroll_thumb = thumb
	host.gui_input.connect(func(e: InputEvent) -> void: _scroll_input(e, host))
	# The wheel over the list scrolls it too (OURS).
	pane.gui_input.connect(func(e: InputEvent) -> void: _wheel(e))
	for s in _slots:
		var slot := s[2] as Control
		if slot != null:
			slot.gui_input.connect(func(e: InputEvent) -> void: _wheel(e))

func _scroll_button(ddj: String, pos: Vector2, sz: Vector2) -> TextureButton:
	var b := TextureButton.new()
	b.ignore_texture_size = true
	b.stretch_mode = TextureButton.STRETCH_SCALE
	b.focus_mode = Control.FOCUS_NONE
	if _builder != null:
		b.texture_normal = _builder.load_texture(ddj)
		var base := ddj.substr(0, ddj.length() - 4)
		b.texture_hover = _builder.load_texture(base + "_focus.ddj")
		b.texture_pressed = _builder.load_texture(base + "_press.ddj")
	b.position = pos
	b.size = sz
	return b

func _scroll_input(e: InputEvent, host: Control) -> void:
	var mb := e as InputEventMouseButton
	if mb == null or not mb.pressed:
		_wheel(e)
		return
	if mb.button_index == MOUSE_BUTTON_LEFT and _scroll_track != null:
		var y := mb.position.y - _scroll_track.position.y
		var f := clampf(y / maxf(_scroll_track.size.y, 1.0), 0.0, 1.0)
		scroll_to(roundi(f * float(max_line())))
		host.accept_event()
		return
	_wheel(e)

func _wheel(e: InputEvent) -> void:
	var mb := e as InputEventMouseButton
	if mb == null or not mb.pressed:
		return
	if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
		scroll_to(_scroll_line - 1)
	elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		scroll_to(_scroll_line + 1)

func lines() -> int:
	return (LIST.size() + COLUMNS - 1) / COLUMNS

func max_line() -> int:
	return maxi(lines() - _slots.size() / COLUMNS, 0)

func scroll_line() -> int:
	return _scroll_line

func scroll_to(line: int) -> void:
	_scroll_line = clampi(line, 0, max_line())
	show_values()

# --- values -----------------------------------------------------------------------

## The row a visible slot shows now, or -1.
func entry_at_slot(n: int) -> int:
	var i := _scroll_line * COLUMNS + n
	return LIST[i] if i >= 0 and i < LIST.size() else -1

## The slot showing `entry` now, or -1 when it is scrolled out of view.
func slot_of(entry: int) -> int:
	for n in _slots.size():
		if entry_at_slot(n) == entry:
			return n
	return -1

func combo_of(entry: int) -> OptionButton:
	var n := slot_of(entry)
	return _slots[n][1] if n >= 0 else null

## Whether a row can do anything in this build under the running renderer.
## Texture Filtering (MSAA) and Texture Detail (mipmap bias) are Forward+'s
## too: MEASURED in round 694 on the box, a test scene's edges and a
## mipmapped checker are pixel-identical with msaa_3d 2x / bias 2 under 4.2.2
## Compatibility, and change under Forward+ (edge pixels 12455 -> 12727,
## checker contrast 0.356 -> 0.257).
static func available(entry: int) -> bool:
	if entry in [VideoOptions.SSAO, VideoOptions.BLOOM, VideoOptions.FILTERING, VideoOptions.TEXTURE]:
		return VideoOptions.post_effects_available()
	if entry == VideoOptions.RENDERER:
		return VideoOptions.renderer_choice_script() != null
	return true

## Why a row is greyed, for its tooltip.
static func unavailable_reason(entry: int) -> String:
	if entry in [VideoOptions.SSAO, VideoOptions.BLOOM, VideoOptions.FILTERING, VideoOptions.TEXTURE]:
		var what := {VideoOptions.SSAO: "ambient occlusion pass", VideoOptions.BLOOM: "glow pass",
			VideoOptions.FILTERING: "multisampling (it draws the same picture)", VideoOptions.TEXTURE: "texture mipmap bias (it draws the same picture)"}
		return "Needs the Forward+ renderer: the Compatibility renderer running now has no %s." % what[entry]
	if entry == VideoOptions.RENDERER:
		return "This build cannot record a renderer choice yet (round 693's RendererChoice); running: %s." % ("Forward+" if VideoOptions.forward_plus_running() else "Compatibility")
	return ""

## The tooltip of a row: its own text from the table, and what this client
## does with it where that differs (OURS lines).
func tooltip_of(entry: int) -> String:
	var row := VideoOptions.row_of(entry)
	var tip := text(String(row.get("tip", "")), "")
	var ours := ""
	match entry:
		VideoOptions.BLOOM:
			ours = "Godot glow."
		VideoOptions.SSAO:
			ours = "Screen-space ambient occlusion (this client's own option)."
		VideoOptions.FILTERING:
			ours = "Multisample anti-aliasing (2x)."
		VideoOptions.RENDERER:
			ours = "Forward+ (Vulkan) or Compatibility (OpenGL). Takes effect at the next start."
		VideoOptions.WATER_REFLECTION:
			ours = "Takes effect at the next login."
		VideoOptions.METAL, VideoOptions.LIGHT, VideoOptions.DYNAMIC_ANIMATION, VideoOptions.FRIEND_ENEMY:
			ours = "Kept, but this client does not draw it yet."
	if not available(entry):
		ours = (ours + " " if ours != "" else "") + unavailable_reason(entry)
	return (tip + ("\n" if tip != "" and ours != "" else "") + ours).strip_edges()

func _label_of(entry: int) -> String:
	var row := VideoOptions.row_of(entry)
	var fb: Array = row.get("fallback", [])
	var s := text(String(row.get("label", "")), fb[0] if fb.size() > 0 else "")
	s = s.strip_edges().trim_suffix(":")
	if entry == VideoOptions.BLOOM:
		s += " (Glow)"
	return s

func _choices_of(entry: int) -> PackedStringArray:
	var row := VideoOptions.row_of(entry)
	var keys: Array = row.get("choices", [])
	var fb: Array = row.get("fallback", [])
	var out := PackedStringArray()
	for i in keys.size():
		var f: String = fb[i + 1] if i + 1 < fb.size() else ""
		var k: String = keys[i]
		out.append(f if k == "" or k.is_valid_int() else text(k, f))
	return out

## The value a row shows.
func shown_value(entry: int) -> int:
	if entry == VideoOptions.QUALITY:
		return edit.current().quality
	if entry == VideoOptions.RENDERER:
		return 1 if renderer_choice == "gl_compatibility" else 0
	return edit.current().value(entry)

## Every control from `edit` (READ: 0x5fe330 loads the record into the page).
func show_values() -> void:
	for n in _slots.size():
		var label := _slots[n][0] as Label
		var combo := _slots[n][1] as OptionButton
		var slot := _slots[n][2] as Control
		var entry := entry_at_slot(n)
		if slot != null:
			slot.visible = entry >= 0
			slot.tooltip_text = tooltip_of(entry) if entry >= 0 else ""
		if entry < 0:
			continue
		if label != null:
			label.text = _label_of(entry)
			label.add_theme_color_override("font_color", Color.WHITE if available(entry) else DISABLED_TEXT)
		if combo != null:
			combo.clear()
			for c in _choices_of(entry):
				combo.add_item(c)
			combo.select(clampi(shown_value(entry), 0, combo.item_count - 1))
			combo.disabled = not available(entry)
			combo.tooltip_text = tooltip_of(entry)
	_show_shared()
	_place_thumb()

func _show_shared() -> void:
	if _bright_combo != null:
		_bright_combo.select(edit.current().brightness)
	if _res_combo != null:
		var r := edit.resolution if edit.resolution.x > 0 else _window_size()
		var i := _resolutions.find(r)
		_res_combo.select(i)
		# Godot's full screen keeps the desktop's size (VideoOptions.apply_display).
		_res_combo.disabled = edit.fullscreen
		_res_combo.tooltip_text = text("UIIT_STT_VIDIO_TTDESC_01", "") + ("\nFull screen uses the desktop's resolution." if edit.fullscreen else "")
	_set_check(_fullscreen, edit.fullscreen)
	_set_check(_windowed, not edit.fullscreen)
	for i in _views.size():
		_set_check(_views[i] as BaseButton, edit.camera_view == VIEWS[i])
	for i in _tabs.size():
		var t := _tabs[i] as Control
		if t != null and TwoDtBuilder.is_checked(t) != (i == edit.active):
			TwoDtBuilder.set_tab_checked(t, i == edit.active)

func _window_size() -> Vector2i:
	return _window.get_window().size if _window != null and _window.is_inside_tree() else Vector2i.ZERO

static func _set_check(b: BaseButton, on: bool) -> void:
	if b == null:
		return
	b.set_pressed_no_signal(on)
	var mark := b.get_node_or_null(TwoDtBuilder.MARK_NODE) as CanvasItem
	if mark != null:
		mark.visible = on

func _place_thumb() -> void:
	if _scroll_thumb == null or _scroll_track == null:
		return
	var span := maxf(_scroll_track.size.y - _scroll_thumb.size.y, 0.0)
	var f := float(_scroll_line) / float(maxi(max_line(), 1))
	_scroll_thumb.position = Vector2(0, _scroll_track.position.y + span * f)

func _on_slot_chosen(n: int, i: int) -> void:
	var entry := entry_at_slot(n)
	if entry < 0:
		return
	set_row(entry, i)

## Sets a row as a choice in its combo does (VideoOptions.set_row), and
## shows the result (a quality fills every row).
func set_row(entry: int, v: int) -> void:
	if entry == VideoOptions.RENDERER:
		renderer_choice = "gl_compatibility" if v == 1 else "forward_plus"
	else:
		VideoOptions.set_row(edit.current(), entry, v)
	show_values()
	changed.emit()

## The Graphic 1 / Graphic 2 tab: the record shown and, once stored, in force.
func select_profile(i: int) -> void:
	edit.active = clampi(i, 0, 1)
	show_values()
	changed.emit()

## Default on this tab (see the header; OURS values).
func press_default() -> void:
	var p := edit.current()
	p.quality = VideoOptions.DEFAULT_QUALITY
	p.brightness = VideoOptions.DEFAULT_BRIGHTNESS
	p.user = VideoOptions.DEFAULTS.duplicate()
	edit.fullscreen = false
	edit.camera_view = VIEWS[0]
	show_values()
	changed.emit()

## Apply / Confirm: the record is saved (the renderer through round 693's
## RendererChoice when this build has it). Returns the record stored.
func store() -> VideoOptions:
	edit.save()
	var rc := VideoOptions.renderer_choice_script()
	if rc != null:
		var current := str(rc.call("chosen"))
		var effective := current if current != "" else str(rc.get_script_constant_map().get("PROJECT_DEFAULT", "forward_plus"))
		if renderer_choice != effective:
			rc.call("choose", renderer_choice)
	var stored := edit.duplicate_options()
	VideoOptions.set_in_force(stored)
	return stored

func at(path: Array) -> Control:
	return TwoDtBuilder.find_path(_root, path) if _root != null else null

## Tests and tools.
func slot_combo(n: int) -> OptionButton:
	return _slots[n][1] if n >= 0 and n < _slots.size() else null

func slot_label(n: int) -> Label:
	return _slots[n][0] if n >= 0 and n < _slots.size() else null

func slot_count() -> int:
	return _slots.size()

func resolution_combo() -> OptionButton:
	return _res_combo

func brightness_combo() -> OptionButton:
	return _bright_combo
