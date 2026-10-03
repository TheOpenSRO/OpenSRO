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
## **The combo (READ, round 696).** CNIFComboBox's create (vslot_010,
## 0x486d30; its asm 0x486d6e..0x486ee1) makes three children of the combo's
## own W x H rect (every combo here is 156 x 18 or 150 x 20, MEASURED):
##   1  the arrow button {W-20, 0, 20, H}, com_qst_downarrow_button.ddj (20 x 20)
##   2  the value field  {0, 0, W-20, H}, a CNIFStretchWnd on
##      `interface\ifcommon\com_blacksquare_` (four corners, left_side and
##      right_side, 0x49b040) with its fill colour +0x1c4 = 0xff000000
##   3  the value text   {5, 0, W-30, H}, a CNIFStatic
## The field is the black box: CNIFStretchWnd's draw (0x49aeb0) fills its
## whole rect with the +0x1c4 colour (0x46d2a0, opaque black) and draws the
## frame pieces over it. Round 694 read the second child as the list's frame
## and drew no field, so each value sat on the row's grey art (the user's
## report, 2026-10-02). See `_make_combo` for what is READ and what MEASURED.
## The open list (round 700) is ComboList, retail's CNIFPopupListCtrl drawn
## in the game's canvas -- see attach_list and ComboList for what is READ.
##
## **The buttons.** Default on this tab (0x5fc340, READ) sets Middle, Normal
## brightness, the 1280 x 1024 mode when listed, FULL SCREEN and the Free
## view. Here: Middle (the user's decision, 2026-10-02), Normal brightness and
## the Free view; the window mode and the resolution are left as they are.
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

## The rows the list shows, in order: retail's 0..13 and 15 (READ), then SSAO,
## the temporary fog toggle (round 702) and the renderer (OURS).
const LIST := [VideoOptions.QUALITY, VideoOptions.SHADOW, VideoOptions.SCENERY,
	VideoOptions.CHARACTER, VideoOptions.WATER_REFLECTION, VideoOptions.WATER_DETAIL,
	VideoOptions.METAL, VideoOptions.LIGHT, VideoOptions.FILTERING, VideoOptions.TEXTURE,
	VideoOptions.LENS_FLARE, VideoOptions.BLOOM, VideoOptions.DYNAMIC_ANIMATION,
	VideoOptions.EFFECT, VideoOptions.FRIEND_ENEMY, VideoOptions.SSAO, VideoOptions.FOG,
	VideoOptions.RENDERER]
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
	# Only sizes whose view at the UI scale is at least retail's 800 x 600
	# (VideoOptions.MIN_VIEW, round 696 review M1).
	_resolutions = VideoOptions.resolution_choices(screen, window_size, _ui_scale())
	if _res_combo != null:
		for r in _resolutions:
			_res_combo.add_item("%d x %d" % [r.x, r.y])
		# Picking the shown size again counts (round 696 review, L1): it is
		# how a maximised window gets its stored size back.
		_res_combo.allow_reselect = true
		_res_combo.item_selected.connect(func(i: int) -> void:
			edit.resolution = _resolutions[i]
			edit.resolution_touched = true
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
## The combo's pieces (READ, CNIFComboBox::vslot_010 -- see the header).
const COMBO_ARROW_W := 20
const COMBO_TEXT_INSET := 5
## READ: the field's fill, CNIFStretchWnd +0x1c4 = 0xff000000 (ARGB).
const COMBO_FIELD_FILL := Color(0, 0, 0, 1)
const COMBO_FIELD_BASE := "interface\\ifcommon\\com_blacksquare_"
const COMBO_FIELD_PIECES := ["left_up", "right_up", "left_down", "right_down", "left_side", "right_side"]

## The field and arrow rects in a combo of `size` (READ, see the header).
static func combo_field_rect(size: Vector2) -> Rect2:
	return Rect2(0, 0, maxf(size.x - COMBO_ARROW_W, 0.0), size.y)

static func combo_arrow_rect(size: Vector2) -> Rect2:
	return Rect2(maxf(size.x - COMBO_ARROW_W, 0.0), 0, minf(COMBO_ARROW_W, size.x), size.y)

## The value text's rect: {5, 0, W-30, H} (READ).
static func combo_text_rect(size: Vector2) -> Rect2:
	return Rect2(COMBO_TEXT_INSET, 0, maxf(size.x - COMBO_ARROW_W - 2 * COMBO_TEXT_INSET, 0.0), size.y)

## The combo over the file's record `host`: the field (black fill and
## com_blacksquare_ frame), the arrow at its rect, and on top a Godot
## OptionButton covering the whole record (OURS: a click anywhere on it opens
## the list) that draws only the value text, centred in the text rect. Its
## own arrow icon is a transparent 20-wide image so the button keeps the
## arrow's width out of the text's room; its style margins (5 each side, no
## separation) leave exactly the READ text rect. The text keeps round 672's
## crisp (NEAREST) sampling: the button draws nothing else, and the field and
## arrow are its siblings, so they keep the UI art's filter.
func _make_combo(host: Control) -> OptionButton:
	if host == null:
		return null
	var size := host.size
	var field := Control.new()
	field.name = "ComboField"
	field.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var fr := combo_field_rect(size)
	field.position = fr.position
	field.size = fr.size
	var pieces := {}
	for p in COMBO_FIELD_PIECES:
		pieces[p] = _builder.load_texture(COMBO_FIELD_BASE + p + ".ddj") if _builder != null else null
	field.draw.connect(func() -> void: OptionVideoPage.draw_combo_field(field, pieces))
	host.add_child(field)
	var arrow_tex := _builder.load_texture(ARROW_DDJ) if _builder != null else null
	var arrow := TextureRect.new()
	arrow.name = "ComboArrow"
	arrow.texture = arrow_tex
	# READ: the button's rect is 20 x H; the 20 x 20 texture fills it (an 18
	# tall combo draws it 18 tall: MEASURED in the reference picture, 36
	# pixels at its 2x).
	arrow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	arrow.stretch_mode = TextureRect.STRETCH_SCALE
	arrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ar := combo_arrow_rect(size)
	arrow.position = ar.position
	arrow.size = ar.size
	host.add_child(arrow)
	var combo := OptionButton.new()
	combo.name = "Combo"
	combo.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	combo.focus_mode = Control.FOCUS_NONE
	combo.alignment = HORIZONTAL_ALIGNMENT_CENTER
	combo.fit_to_longest_item = false
	combo.clip_text = true
	for st in ["normal", "hover", "pressed", "disabled", "focus", "hover_pressed"]:
		var empty := StyleBoxEmpty.new()
		empty.content_margin_left = COMBO_TEXT_INSET
		empty.content_margin_right = COMBO_TEXT_INSET
		combo.add_theme_stylebox_override(st, empty)
	combo.add_theme_icon_override("arrow", _blank_arrow())
	combo.add_theme_constant_override("arrow_margin", 0)
	combo.add_theme_constant_override("h_separation", 0)
	var font := _builder.font_at(0) if _builder != null else null
	if font != null:
		combo.add_theme_font_override("font", font)
	combo.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[0])
	for c in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]:
		combo.add_theme_color_override(c, Color.WHITE)
	combo.add_theme_color_override("font_disabled_color", DISABLED_TEXT)
	UiBuilder.guard_button_font(combo)
	UiBuilder.crisp_text(combo)
	attach_list(combo, pieces, font)
	host.mouse_filter = Control.MOUSE_FILTER_PASS
	host.add_child(combo)
	return combo

## **The open list (round 700).** Round 697 styled the OptionButton's own
## PopupMenu with the READ values; a PopupMenu is a Window whose viewport is
## opaque, so its translucent fill showed as solid grey (the user's report,
## 2026-10-03), and it can neither centre its items nor keep retail's 13-unit
## line. The list is now ComboList, drawn in the game's canvas: see its header
## for what is READ and MEASURED. The OptionButton stays for the value text
## and the item API (add_item / select / item_selected); a left press on it
## opens ComboList instead of the PopupMenu (the press is accepted in the
## gui_input signal, which runs before OptionButton's own handling).
const POPUP_FILL := ComboList.FILL
const POPUP_INSET := ComboList.INSET
## Set on a combo wired to ComboList (tests read it).
const LIST_META := "combo_list"

static func attach_list(combo: OptionButton, pieces: Dictionary, font: Font) -> void:
	if combo == null:
		return
	var box := popup_panel(pieces)
	combo.set_meta(LIST_META, true)
	combo.gui_input.connect(func(e: InputEvent) -> void:
		var mb := e as InputEventMouseButton
		if mb == null or mb.button_index != MOUSE_BUTTON_LEFT:
			return
		combo.accept_event()
		if mb.pressed and not combo.disabled:
			ComboList.open_for(combo, box, font, UiBuilder.FONT_SIZES[0]))

## The list's frame and fill as one StyleBoxTexture: a 12 x 12 image of the
## four corner pieces, left_side / right_side down the sides and transposed
## along the top / bottom, over the READ fill, with 4-pixel margins. Without
## the pieces (no Media.pk2), the fill alone.
static func popup_panel(pieces: Dictionary) -> StyleBox:
	var img := Image.create(12, 12, false, Image.FORMAT_RGBA8)
	img.fill(POPUP_FILL)
	var got := 0
	var spots := {"left_up": Vector2i(0, 0), "right_up": Vector2i(8, 0),
		"left_down": Vector2i(0, 8), "right_down": Vector2i(8, 8),
		"left_side": Vector2i(0, 4), "right_side": Vector2i(8, 4)}
	for name in spots:
		var piece := _piece_image(pieces.get(name) as Texture2D)
		if piece == null:
			continue
		img.blend_rect(piece, Rect2i(0, 0, 4, 4), spots[name])
		got += 1
	var ls := _piece_image(pieces.get("left_side") as Texture2D)
	var rs := _piece_image(pieces.get("right_side") as Texture2D)
	if ls != null:
		img.blend_rect(_transposed(ls), Rect2i(0, 0, 4, 4), Vector2i(4, 0))
	if rs != null:
		img.blend_rect(_transposed(rs), Rect2i(0, 0, 4, 4), Vector2i(4, 8))
	var sb := StyleBoxTexture.new()
	sb.texture = ImageTexture.create_from_image(img)
	for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
		sb.set_texture_margin(side, 4.0 if got > 0 else 0.0)
	sb.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_TILE
	sb.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_TILE
	for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
		sb.set_content_margin(side, POPUP_INSET)
	return sb

## A piece's 4 x 4 image in RGBA8, or null.
static func _piece_image(tex: Texture2D) -> Image:
	if tex == null:
		return null
	var img := tex.get_image()
	if img == null or img.is_empty():
		return null
	img = img.duplicate() as Image
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	if img.get_width() != 4 or img.get_height() != 4:
		img.resize(4, 4, Image.INTERPOLATE_NEAREST)
	return img

static func _transposed(img: Image) -> Image:
	var out := Image.create(img.get_height(), img.get_width(), false, Image.FORMAT_RGBA8)
	for y in img.get_height():
		for x in img.get_width():
			out.set_pixel(y, x, img.get_pixel(x, y))
	return out

static var _blank_arrow_tex: ImageTexture = null

## A transparent COMBO_ARROW_W x 1 image: the OptionButton's arrow slot,
## drawn invisibly (the real arrow is its own TextureRect).
static func _blank_arrow() -> ImageTexture:
	if _blank_arrow_tex == null:
		_blank_arrow_tex = ImageTexture.create_from_image(Image.create(COMBO_ARROW_W, 1, false, Image.FORMAT_RGBA8))
	return _blank_arrow_tex

## Draws the value field on `ci` over its whole rect: the READ black fill,
## then the com_blacksquare_ pieces -- each corner at its own size in its
## corner, left_side tiled down the left and right_side down the right
## (READ: the loader 0x49b040 passes left_side twice and right_side twice;
## round 584 read the pairing as left + top, right + bottom), and the same
## two pieces along the top and bottom TRANSPOSED, so their outer column is
## the edge's outer row. The transposition is MEASURED, not read: the
## reference picture's top edge is one continuous row of 0x080808..0x100c10
## and its bottom one row of 0x7b797b -- the outer columns of left_side and
## right_side -- where the pieces tiled untransposed would draw a dot every
## 4 pixels; the six-piece class's UVs (0x49a140 / 0x49a7d0) were not read.
## Every piece in the archive is 4 x 4 (MEASURED). The bottom row matches the
## reference pixel for pixel (0x7b797b); the top row here is left_side's
## column 0, 0x080808 with every fourth pixel 0x000400, where the reference
## shows 0x080808 throughout -- the top's exact source is not established
## (every value within 8 levels; MEASURED, round 696).
static func draw_combo_field(ci: CanvasItem, pieces: Dictionary) -> void:
	var size: Vector2 = (ci as Control).size if ci is Control else Vector2.ZERO
	if size.x <= 0 or size.y <= 0:
		return
	ci.draw_rect(Rect2(Vector2.ZERO, size), COMBO_FIELD_FILL)
	var lu := pieces.get("left_up") as Texture2D
	var ru := pieces.get("right_up") as Texture2D
	var ld := pieces.get("left_down") as Texture2D
	var rd := pieces.get("right_down") as Texture2D
	var ls := pieces.get("left_side") as Texture2D
	var rs := pieces.get("right_side") as Texture2D
	var lu_s := lu.get_size() if lu != null else Vector2.ZERO
	var ru_s := ru.get_size() if ru != null else Vector2.ZERO
	var ld_s := ld.get_size() if ld != null else Vector2.ZERO
	var rd_s := rd.get_size() if rd != null else Vector2.ZERO
	if ls != null:
		var w := ls.get_size().x
		_tile(ci, ls, Rect2(0, lu_s.y, w, size.y - lu_s.y - ld_s.y), false)
		# The top: the piece transposed, its width now the edge's height.
		_tile(ci, ls, Rect2(lu_s.x, 0, size.x - lu_s.x - ru_s.x, w), true)
	if rs != null:
		var w := rs.get_size().x
		_tile(ci, rs, Rect2(size.x - w, ru_s.y, w, size.y - ru_s.y - rd_s.y), false)
		_tile(ci, rs, Rect2(ld_s.x, size.y - w, size.x - ld_s.x - rd_s.x, w), true)
	for c in [[lu, Vector2.ZERO], [ru, Vector2(size.x - ru_s.x, 0)],
			[ld, Vector2(0, size.y - ld_s.y)], [rd, size - rd_s]]:
		if c[0] != null:
			ci.draw_texture(c[0], c[1])

## Tiles `tex` over `rect`, its axes swapped when `transpose`. READ, Godot
## 4.2.2 (servers/rendering/renderer_canvas_cull.cpp,
## canvas_item_add_texture_rect): a transposed rect has its SIZE swapped as
## well as its UVs, so the size goes in swapped to come out as `rect` --
## passed as is, the top edge drew as a 4-wide column hanging down from the
## field (this round's first live shots).
static func _tile(ci: CanvasItem, tex: Texture2D, rect: Rect2, transpose: bool) -> void:
	if rect.size.x > 0 and rect.size.y > 0:
		var r := Rect2(rect.position, Vector2(rect.size.y, rect.size.x)) if transpose else rect
		ci.draw_texture_rect(tex, r, true, Color.WHITE, transpose)

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
	if entry in [VideoOptions.SSAO, VideoOptions.FILTERING, VideoOptions.TEXTURE]:
		return VideoOptions.post_effects_available()
	if entry == VideoOptions.RENDERER:
		var rc := VideoOptions.renderer_choice_script()
		return rc != null and bool(rc.call("applies_here"))
	return true

## Why a row is greyed, for its tooltip.
static func unavailable_reason(entry: int) -> String:
	if entry in [VideoOptions.SSAO, VideoOptions.BLOOM, VideoOptions.FILTERING, VideoOptions.TEXTURE]:
		var what := {VideoOptions.SSAO: "ambient occlusion pass", VideoOptions.BLOOM: "glow pass",
			VideoOptions.FILTERING: "multisampling (it draws the same picture)", VideoOptions.TEXTURE: "texture mipmap bias (it draws the same picture)"}
		return "Needs the Forward+ renderer: the Compatibility renderer running now has no %s." % what[entry]
	if entry == VideoOptions.RENDERER:
		var running := "Forward+" if VideoOptions.forward_plus_running() else "Compatibility"
		if VideoOptions.renderer_choice_script() == null:
			return "This build cannot record a renderer choice (round 693's RendererChoice); running: %s." % running
		return "Only an exported game reads the renderer choice (override.cfg beside it); running: %s." % running
	return ""

## The tooltip of a row: its own text from the table, and what this client
## does with it where that differs (OURS lines).
func tooltip_of(entry: int) -> String:
	var row := VideoOptions.row_of(entry)
	var tip := text(String(row.get("tip", "")), "")
	var ours := ""
	match entry:
		VideoOptions.BLOOM:
			ours = "The original's bloom: the bright parts blurred over a slightly darkened picture."
		VideoOptions.SSAO:
			ours = "Screen-space ambient occlusion (this client's own option). A light effect here: the ground and most buildings are drawn with their own lighting, which ambient occlusion cannot darken."
		VideoOptions.FILTERING:
			ours = "Multisample anti-aliasing (2x); a small change on screen."
		VideoOptions.TEXTURE:
			ours = "A mipmap bias: it reaches only textures with mipmaps, and most world textures here have none yet, so it changes little."
		VideoOptions.FOG:
			ours = "Temporary, for comparing: On draws the original's distance fog (its own start, end and colour for the zone); Off draws none. The original always has it."
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

func _ui_scale() -> float:
	return _window.get_window().content_scale_factor if _window != null and _window.is_inside_tree() else 1.0

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

## Default on this tab (see the header): Middle, Normal, the Free view; the
## window mode untouched.
func press_default() -> void:
	var p := edit.current()
	p.quality = VideoOptions.DEFAULT_QUALITY
	p.brightness = VideoOptions.DEFAULT_BRIGHTNESS
	p.user = VideoOptions.DEFAULTS.duplicate()
	edit.camera_view = VIEWS[0]
	show_values()
	changed.emit()

## Apply / Confirm: the record is saved (the renderer through round 693's
## RendererChoice when this build has it). Returns the record stored.
func store() -> VideoOptions:
	edit.save()
	var rc := VideoOptions.renderer_choice_script()
	var notice := ""
	# Only an exported build reads override.cfg (RendererChoice.applies_here);
	# a run from source would write beside the editor binary for nothing.
	if rc != null and bool(rc.call("applies_here")):
		var current := str(rc.call("chosen"))
		var effective := current if current != "" else str(rc.get_script_constant_map().get("PROJECT_DEFAULT", "forward_plus"))
		if renderer_choice != effective:
			var err: int = int(rc.call("choose", renderer_choice))
			var name := "Compatibility" if renderer_choice == "gl_compatibility" else "Forward+"
			if err == OK:
				notice = "Renderer: %s from the next start." % name
			else:
				notice = "Renderer: could not record %s for the next start (%s, error %d) -- the game's folder may be read-only." % [
					name, str(rc.call("override_path")), err]
	var stored := edit.duplicate_options()
	stored.notice = notice
	# Handed on once: the next Apply resizes only if the row is picked again.
	stored.resolution_touched = edit.resolution_touched
	edit.resolution_touched = false
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
