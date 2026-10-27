extends HudWindow
class_name OptionWindow

## The retail Option window, `CNIFOption`, built from `res_ui\optionwnd.2dt`
## (round 615). Every address is sro_client.exe's; docs/protocol/
## SOUND_FORMAT.md ("The Option window") has the record. Labels: **read**,
## **measured**, **inferred**, **ours**.
##
## **Which window (read).** The System window's Option button is id 10 of
## resinfo\ifsystemwnd.txt; CIFSystemWnd's message map (0xeba938) sends a
## click on id 10 to 0x6f5190, which asks the `.2dt` window manager for
## window 0x62: if it exists 0x6f5100(0) destroys it, else 0x6f5100(1) loads
## `res_ui\optionwnd.2dt` (string 0xdac480), centres window 0x62 (0x798c50),
## brings it forward (vslot 0x50) and hides the System window (vslot 0x5c(0)).
## No sound on either path. The older `resinfo\ifoption.txt` family
## (CIFOption, with CIFOption_Audio's ifoption_audio.txt) is declared in
## ifsystemwnd.txt as GDR_OPTION (id 98) but the button does not open it;
## CIFOption's close (0x6ee3b0) only destroys the .2dt window.
##
## **The file (measured, 208 records).** Root 98 (CNIFOption, 700x500,
## caption UIIT_CTL_OPTION); four tabs in group 10 -- 10 video (pane 78),
## 14 audio (pane 269), 15 input (pane 109), 16 game (pane 149); buttons
## 5 Default, 6 Confirm, 8 Cancel, 9 Apply. The audio pane holds three frames,
## 250 (UIIT_STT_BGMSETTING), 259 (UIIT_STT_EFFSETTING), 264
## (UIIT_STT_ENVIRONMENT), each with a CNIFSliderCtrl 258 on
## `interface\option\opt_volume2.ddj`, a check box 254 and its label 255
## (UIIT_STT_SOUND_ELEMINATE).
##
## **The audio page (read, 0x5f7680).** Its setup fetches 269 -> 250/259/264
## -> 254 (the mute boxes, +0x10ec/f0/f4) and -> 258 (the sliders,
## +0x10f8/fc/+0x1100), clears the boxes, gives each slider the range 0..100,
## step 1 (0x489600(0, 100, 1, 1)) and a travel of 452 pixels (0x489470(0x1c4)),
## then loads the saved values into them (0x5f66c0: slider = option struct
## +0/+4/+8, box = +0xc/+0xd/+0xe). Order BGM, Effect, Environment.
## - A box's click (id 254 -> 0x5f6800) applies at once: checked sends
##   -10000 to its row, unchecked the slider's volume (read).
## - A slider is pushed to the sound manager by 0x5f6570 whenever it differs
##   from the saved value and its box is clear (read); that this runs as the
##   slider moves is **inferred**, so here a move applies at once.
## - Confirm (6 -> 0x5fe5a0) and Apply (9 -> 0x5fe670 on the audio tab) store
##   the values (0x5f6750 -> 0x4f9d10) (read); this client saves them in
##   ClientSettings (AudioOptions.save, ours). Confirm then closes.
## - Default (5 -> 0x5fda90) on the audio tab runs 0x5f6660: all three
##   sliders to 50 and the boxes cleared (read). (Not 30/50/50: those are the
##   option struct's constructor defaults, 0x848cb0.) On the other tabs it
##   resets their pages, which are not wired here.
## - Cancel (8), the close button and Escape close without storing. What the
##   sound manager keeps after that is not read; **ours:** the saved values
##   are put back.
## **The first tab (read, 0x600850, the window's 0x8065 message):** video is
## checked and audio, input and game cleared, so the window opens on Video.
## The Video tab is wired since round 694 (OptionVideoPage, VideoOptions);
## the input and game panes are built as the file draws them and are not
## wired (ours).
##
## **The slider (read, CNIFSliderCtrl).** Its create (vslot_010, 0x4886e0)
## makes three buttons, ids 10 prev, 11 next, 12 thumb; the texture setter
## (0x489090) names them after the slider's texture plus `_prev`, `_next`,
## `_thumb` (the archive has opt_volume2_prev/next/thumb.ddj, measured), sizes
## each to its texture, puts prev at the slider's origin, next against its
## right edge, and the thumb at prev's right + 1, y + 4 (0x4891e0..0x4891f4).
## The thumb's offset is (value - min) * travel / span, through _ftol
## (0x4894c0; truncation is **inferred** from the helper's name). What a drag
## or a click on the track does is not read: **ours**, the value under the
## pointer, and prev/next step by 1 (the step the range was given).

const OPTION_2DT := "res_ui\\optionwnd.2dt"
const ID_TAB_VIDEO := 10
const ID_TAB_AUDIO := 14
const ID_TAB_INPUT := 15
const ID_TAB_GAME := 16
## Round 832 (OURS): the Extra tab, private-server add-ons switched by a check
## mark. Built from the Game tab's own records: its tab button one tab step
## (125, the four tabs' spacing) to the right -- inside the window, whose
## inner frame ends at 740 --, and a pane holding the Game pane's frame (104)
## and its CNIFGameOptionSlot rows (label + check box, two columns).
const ID_TAB_EXTRA := 17
const ID_PANE_EXTRA := 900
const ID_PANE_GAME := 149
const ID_GAME_FRAME := 104
const GAME_SLOT_CLASS := "CNIFGameOptionSlot"
const TAB_STEP := 125.0
const EXTRA_TAB_TEXT := "Extra Settings"
## The Extra rows, in slot order (left column first): [settings key, label
## text or text id]. The ping counter and the exchange's portraits are OURS. (Retail's "Activate action
## short cut" sat here in round 832; from round 834 the target menu is always
## on and the option is gone.)
## The rows' defaults where not off (Default on the Extra tab).
const EXTRA_DEFAULTS := {"exchange_portraits": true}
const EXTRA_ROWS := [
	["ping_fps", "Show the Ping / FPS counter"],
	["exchange_portraits", "Show portraits and a log in the exchange window"],
]
const ID_PANE_AUDIO := 269
const ID_FRAME_BGM := 250
const ID_FRAME_EFFECT := 259
const ID_FRAME_ENV := 264
const ID_SLIDER := 258
const ID_MUTE := 254
const ID_DEFAULT := 5
const ID_CONFIRM := 6
const ID_CANCEL := 8
const ID_APPLY := 9
const ROWS := [ID_FRAME_BGM, ID_FRAME_EFFECT, ID_FRAME_ENV]

const SLIDER_MIN := 0
const SLIDER_MAX := 100
const SLIDER_TRAVEL := 452
const THUMB_Y := 4
## 0x5f6660: the audio page's Default.
const DEFAULT_VALUE := 50
## Sizes used only when a piece's texture is not in the archive (ours).
const FALLBACK_BUTTON := Vector2(24, 24)
const FALLBACK_THUMB := Vector2(16, 16)

var _twodt: TwoDtBuilder
var _file: TwoDtReader.TwoDtFile
## The values being edited, and the saved ones they started from.
var _edit: AudioOptions
var _saved: AudioOptions
var _sliders: Array = []   # per row: the slider node
var _thumbs: Array = []
var _thumb_x0: Array = []
var _mutes: Array = []
var _stored := false
var _dragging_row := -1
## The Video tab (round 694).
var video: OptionVideoPage
## The Key Map tab (round 833).
var keymap_page: OptionKeyPage
## Round 832: the Extra tab's values being edited, and its check boxes.
var _extra_edit := {}
var _extra_boxes := {}

signal applied(options: AudioOptions)
## Apply / Confirm on any tab store the Video tab's record too; it is handed
## to whoever applies it (HudPanels -> World3D).
signal video_applied(options: VideoOptions)
## Round 832: the Extra tab's values on Apply / Confirm, {key: bool}.
signal extra_applied(values: Dictionary)
## Round 833: the mouse mode (GI+0x4f9) put in force -- by the Key Map tab's
## Apply / Confirm, or at once by its Default (0x5fcda0, READ).
signal mouse_mode_changed(mode: int)

func _init(builder: UiBuilder = null) -> void:
	super._init()
	_builder = builder

## Builds the window as 0x6f5100(1) loads it. False, with nothing built, if
## the file is missing or does not parse.
func build_option() -> bool:
	if _builder == null:
		return false
	_file = _builder.load_2dt(OPTION_2DT)
	if _file == null or _file.records.is_empty():
		return false
	_twodt = TwoDtBuilder.new(_builder)
	panel_root = _twodt.build(_file, OPTION_2DT)
	var window_size := Vector2(_file.root().rect.size)
	custom_minimum_size = window_size
	size = window_size
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(panel_root)
	# The caption is the chrome's (CNIFMainFrame), as for the other .2dt
	# windows; the root's own text would draw it twice.
	var root_text := panel_root.get_node_or_null(TwoDtBuilder.TEXT_NODE)
	if root_text != null:
		root_text.queue_free()
	_add_title_bar(_builder.resolve_text(_file.root().text_id))
	var bar := get_node_or_null("TitleBar") as Label
	if bar != null:
		bar.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	# 0x600850: video checked, the rest cleared.
	for id in [ID_TAB_AUDIO, ID_TAB_INPUT, ID_TAB_GAME]:
		TwoDtBuilder.set_tab_checked(_at([id]), false)
	TwoDtBuilder.set_tab_checked(_at([ID_TAB_VIDEO]), true)
	_build_audio_page()
	video = OptionVideoPage.new(self, _builder, panel_root)
	var win := get_window() if is_inside_tree() else null
	var screen := DisplayServer.screen_get_size() if DisplayServer.get_name() != "headless" else Vector2i.ZERO
	video.build(VideoOptions.in_force(), ClientSettings.camera_view(), screen, win.size if win != null else Vector2i.ZERO)
	keymap_page = OptionKeyPage.new(_builder, panel_root)
	keymap_page.build(KeyMap.live_keys(), ClientSettings.mouse_mode())
	KeyMap.capture = _capture_key
	_build_extra_tab()
	_wire_buttons()
	_settle()
	var svc := AudioService.instance()
	_saved = svc.options.duplicate_options() if svc != null and svc.options != null else AudioOptions.load_saved()
	_edit = _saved.duplicate_options()
	_show_values()
	return true

# --- the audio page -------------------------------------------------------------

func _build_audio_page() -> void:
	for row in ROWS.size():
		var slider := _at([ID_PANE_AUDIO, ROWS[row], ID_SLIDER])
		var mute := _at([ID_PANE_AUDIO, ROWS[row], ID_MUTE]) as BaseButton
		_sliders.append(slider)
		_mutes.append(mute)
		_thumbs.append(null)
		_thumb_x0.append(0.0)
		if slider != null:
			_build_slider_pieces(row, slider)
		if mute != null:
			var r: int = row
			mute.toggled.connect(func(on: bool) -> void: _on_mute(r, on))

## The three pieces of CNIFSliderCtrl (see the header).
func _build_slider_pieces(row: int, slider: Control) -> void:
	var base := _slider_texture_base(row)
	var prev := _piece_button(base + "_prev", FALLBACK_BUTTON)
	prev.name = "Prev"
	prev.position = Vector2.ZERO
	slider.add_child(prev)
	var next := _piece_button(base + "_next", FALLBACK_BUTTON)
	next.name = "Next"
	next.position = Vector2(slider.size.x - next.size.x, 0.0)
	slider.add_child(next)
	var thumb := _piece_button(base + "_thumb", FALLBACK_THUMB)
	thumb.name = "Thumb"
	thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slider.add_child(thumb)
	_thumbs[row] = thumb
	_thumb_x0[row] = prev.size.x + 1.0
	var r: int = row
	prev.pressed.connect(func() -> void: set_value(r, value_of(r) - 1, true))
	next.pressed.connect(func() -> void: set_value(r, value_of(r) + 1, true))
	slider.mouse_filter = Control.MOUSE_FILTER_STOP
	slider.gui_input.connect(func(event: InputEvent) -> void: _slider_input(r, event))

## The slider record's texture without `.ddj` (the setter appends the piece
## name and the extension).
func _slider_texture_base(row: int) -> String:
	var tex := ""
	for r in _file.records:
		if r.id == ID_SLIDER and r.parent_id == ROWS[row]:
			tex = r.texture
			break
	if tex == "":
		tex = "interface\\option\\opt_volume2.ddj"
	return tex.substr(0, tex.length() - 4) if tex.to_lower().ends_with(".ddj") else tex

func _piece_button(base: String, fallback: Vector2) -> TextureButton:
	var btn := TextureButton.new()
	btn.ignore_texture_size = true
	btn.stretch_mode = TextureButton.STRETCH_SCALE
	btn.focus_mode = Control.FOCUS_NONE
	btn.texture_normal = _builder.load_texture(base + ".ddj")
	btn.texture_hover = _builder.load_texture(base + "_focus.ddj")
	btn.texture_pressed = _builder.load_texture(base + "_press.ddj")
	btn.texture_disabled = _builder.load_texture(base + "_disable.ddj")
	btn.size = Vector2(btn.texture_normal.get_size()) if btn.texture_normal != null else fallback
	return btn

## Ours: a press or drag on the track sets the value under the pointer.
func _slider_input(row: int, event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.button_index == MOUSE_BUTTON_LEFT:
		if mb.pressed:
			_dragging_row = row
			set_value(row, value_at(row, mb.position.x), true)
		else:
			_dragging_row = -1
		accept_event()
		return
	var mm := event as InputEventMouseMotion
	if mm != null and _dragging_row == row and (mm.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		set_value(row, value_at(row, mm.position.x), true)
		accept_event()

## The value whose thumb would sit under slider-local x (ours).
func value_at(row: int, local_x: float) -> int:
	var thumb := _thumbs[row] as Control
	var half := thumb.size.x * 0.5 if thumb != null else 0.0
	var off := local_x - float(_thumb_x0[row]) - half
	return clampi(roundi(off * float(SLIDER_MAX - SLIDER_MIN) / float(SLIDER_TRAVEL)) + SLIDER_MIN, SLIDER_MIN, SLIDER_MAX)

## 0x4894c0's thumb offset: (value - min) * travel / span, truncated.
static func thumb_offset(value: int) -> int:
	return int(float(value - SLIDER_MIN) * float(SLIDER_TRAVEL) / float(SLIDER_MAX - SLIDER_MIN))

func value_of(row: int) -> int:
	match row:
		0: return _edit.bgm
		1: return _edit.effect
	return _edit.env

func is_muted(row: int) -> bool:
	match row:
		0: return _edit.bgm_muted
		1: return _edit.effect_muted
	return _edit.env_muted

## Sets a row's slider and, when `live`, applies it to the buses unsaved.
func set_value(row: int, v: int, live: bool) -> void:
	v = clampi(v, SLIDER_MIN, SLIDER_MAX)
	match row:
		0: _edit.bgm = v
		1: _edit.effect = v
		_: _edit.env = v
	_place_thumb(row)
	if live:
		_apply_live()

func _on_mute(row: int, on: bool) -> void:
	match row:
		0: _edit.bgm_muted = on
		1: _edit.effect_muted = on
		_: _edit.env_muted = on
	_apply_live()

func _place_thumb(row: int) -> void:
	var thumb := _thumbs[row] as Control
	if thumb == null:
		return
	thumb.position = Vector2(float(_thumb_x0[row]) + float(thumb_offset(value_of(row))), float(THUMB_Y))

## 0x5f66c0: the saved values into the sliders and boxes.
func _show_values() -> void:
	for row in ROWS.size():
		_place_thumb(row)
		var mute := _mutes[row] as BaseButton
		if mute != null:
			mute.set_pressed_no_signal(is_muted(row))
			var mark := mute.get_node_or_null(TwoDtBuilder.MARK_NODE) as CanvasItem
			if mark != null:
				mark.visible = is_muted(row)

func _apply_live() -> void:
	var svc := AudioService.instance()
	if svc != null:
		svc.set_options(_edit, false)

# --- the Extra tab (round 832, OURS) -------------------------------------------------

func _record_index(id: int, parent_id: int) -> int:
	for r in _file.records:
		if r.id == id and r.parent_id == parent_id:
			return r.index
	return -1

func _build_extra_tab() -> void:
	var root_id := _file.root().id
	var tab_i := _record_index(ID_TAB_GAME, root_id)
	var pane_i := _record_index(ID_PANE_GAME, root_id)
	var frame_i := _record_index(ID_GAME_FRAME, ID_PANE_GAME)
	if tab_i < 0 or pane_i < 0 or frame_i < 0:
		return
	var tab := _twodt.build_record(_file, tab_i)
	tab.name = "Tab%d" % ID_TAB_EXTRA
	tab.set_meta(TwoDtBuilder.META_ID, ID_TAB_EXTRA)
	tab.set_meta(TwoDtBuilder.META_TAB_PANE, ID_PANE_EXTRA)
	tab.position.x += TAB_STEP
	# The settling pass places every node at its authored rect: the copy's
	# moves with it.
	var authored: Rect2 = tab.get_meta(UiBuilder.AUTHORED_RECT_META)
	tab.set_meta(UiBuilder.AUTHORED_RECT_META, Rect2(authored.position + Vector2(TAB_STEP, 0.0), authored.size))
	_twodt.set_text(tab, EXTRA_TAB_TEXT, _file.records[tab_i])
	panel_root.add_child(tab)
	var pane := _twodt.build_record(_file, pane_i)
	pane.name = "Wnd%d" % ID_PANE_EXTRA
	pane.set_meta(TwoDtBuilder.META_ID, ID_PANE_EXTRA)
	panel_root.add_child(pane)
	var frame := _twodt.build_record(_file, frame_i)
	pane.add_child(frame)
	var slots: Array[int] = []
	for r in _file.records:
		if r.parent_id == ID_GAME_FRAME and r.name == GAME_SLOT_CLASS:
			slots.append(r.index)
	for k in mini(EXTRA_ROWS.size(), slots.size()):
		var key := String(EXTRA_ROWS[k][0])
		var slot := _twodt.build_record(_file, slots[k])
		frame.add_child(slot)
		for ci in _file.records[slots[k]].children:
			var c := _twodt.build_record(_file, ci)
			slot.add_child(c)
			if c is BaseButton:
				_extra_boxes[key] = c
				(c as BaseButton).toggled.connect(func(on: bool) -> void: _extra_edit[key] = on)
			elif _file.records[ci].type == TwoDtReader.TYPE_STATIC:
				var label_text := String(EXTRA_ROWS[k][1])
				_twodt.set_text(c, _builder.resolve_text(label_text) if label_text.begins_with("UIIT_") else label_text, _file.records[ci])
		_extra_edit[key] = extra_saved(key)
	TwoDtBuilder.set_tab_checked(tab, false)
	for key in _extra_boxes:
		set_extra(key, bool(_extra_edit[key]))

## The stored value of an Extra row.
static func extra_saved(key: String) -> bool:
	match key:
		"ping_fps":
			return ClientSettings.ping_fps_shown()
		"exchange_portraits":
			return ClientSettings.exchange_portraits_shown()
	return false

## Sets an Extra row's check box (and its edit value).
func set_extra(key: String, on: bool) -> void:
	_extra_edit[key] = on
	var box := _extra_boxes.get(key) as BaseButton
	if box != null:
		box.button_pressed = on

func extra_value(key: String) -> bool:
	return bool(_extra_edit.get(key, false))

func extra_box(key: String) -> BaseButton:
	return _extra_boxes.get(key) as BaseButton

## Apply / Confirm: the Extra rows stored and handed on.
func store_extra() -> void:
	if _extra_edit.is_empty():
		return
	ClientSettings.set_value(ClientSettings.SECTION_EXTRA, ClientSettings.KEY_PING_FPS, extra_value("ping_fps"))
	ClientSettings.set_value(ClientSettings.SECTION_EXTRA, ClientSettings.KEY_EXCHANGE_PORTRAITS, extra_value("exchange_portraits"))
	extra_applied.emit(_extra_edit.duplicate())

# --- the buttons ------------------------------------------------------------------

func _wire_buttons() -> void:
	var wiring := {ID_DEFAULT: press_default, ID_CONFIRM: press_confirm,
		ID_CANCEL: press_cancel, ID_APPLY: press_apply}
	for id in wiring:
		var btn := _at([id]) as BaseButton
		if btn != null:
			btn.pressed.connect(wiring[id])

## Which top tab is checked (10, 14, 15, 16 or the Extra tab's 17), or 0.
func current_tab() -> int:
	for id in [ID_TAB_VIDEO, ID_TAB_AUDIO, ID_TAB_INPUT, ID_TAB_GAME, ID_TAB_EXTRA]:
		if TwoDtBuilder.is_checked(_at([id])):
			return id
	return 0

## 0x5fda90: the checked tab's defaults; on the audio tab 0x5f6660, on the
## video tab 0x5fc340 (OptionVideoPage.press_default).
func press_default() -> void:
	if current_tab() == ID_TAB_INPUT and keymap_page != null:
		# 0x5fcda0: the rows to the defaults (in force on Apply), radio 110,
		# and mode 0 in force at once.
		keymap_page.press_default()
		ClientSettings.set_value(ClientSettings.SECTION_UI, ClientSettings.KEY_MOUSE_MODE, 0)
		mouse_mode_changed.emit(0)
		return
	if current_tab() == ID_TAB_EXTRA:
		# OURS: every add-on back to its own default -- off, but for the
		# exchange's portraits and log, which are on (round 836).
		for key in _extra_edit:
			set_extra(key, bool(EXTRA_DEFAULTS.get(key, false)))
		return
	if current_tab() == ID_TAB_VIDEO and video != null:
		video.press_default()
		return
	if current_tab() != ID_TAB_AUDIO:
		return
	_edit.bgm = DEFAULT_VALUE
	_edit.effect = DEFAULT_VALUE
	_edit.env = DEFAULT_VALUE
	_edit.bgm_muted = false
	_edit.effect_muted = false
	_edit.env_muted = false
	_show_values()
	_apply_live()

## Apply: store the values (0x5f6750), saved to ClientSettings (ours).
func press_apply() -> void:
	var svc := AudioService.instance()
	if svc != null:
		svc.set_options(_edit, true)
	else:
		_edit.save()
	_saved = _edit.duplicate_options()
	_stored = true
	applied.emit(_saved)
	if video != null and video.edit != null:
		video_applied.emit(video.store())
	store_extra()
	# Round 833: Apply stores the current tab (0x5fe670's table, READ); the
	# Key Map tab's keys and mouse mode only from that tab, or on Confirm.
	if current_tab() == ID_TAB_INPUT:
		store_keys()

## Confirm: store, then close.
func press_confirm() -> void:
	press_apply()
	# 0x5fe5a0 stores every tab, the Key Map's included (0x5f6970).
	if current_tab() != ID_TAB_INPUT:
		store_keys()
	_on_close_pressed()

## 0x5f6970: the radios' mode into GI+0x4f9 and the rows' keys into the live
## table, then saved (0x5f7ce0).
func store_keys() -> void:
	if keymap_page == null or keymap_page.keys.size() != KeyMap.SLOTS.size():
		return
	KeyMap.set_keys(keymap_page.keys)
	ClientSettings.set_value(ClientSettings.SECTION_UI, ClientSettings.KEY_MOUSE_MODE, keymap_page.mouse_mode)
	mouse_mode_changed.emit(keymap_page.mouse_mode)

## KeyMap.capture while this window lives: a key-down for the Key Map tab's
## selected row (0x5fb460 answers only while +0x798 is that tab, READ).
func _capture_key(keycode: int) -> bool:
	if keymap_page == null or not is_visible_in_tree() or current_tab() != ID_TAB_INPUT:
		return false
	keymap_page.tab_shown = true
	if not keymap_page.wants_key(keycode):
		return false
	keymap_page.take_key(keycode)
	return true

## Cancel: close without storing.
func press_cancel() -> void:
	_on_close_pressed()

## Closing without storing puts the saved values back (ours; see the header).
func restore_saved() -> void:
	var svc := AudioService.instance()
	if svc != null and _saved != null:
		svc.set_options(_saved, false)

## CNIFOption::vslot_043 (0x5f63b0): hidden, then 0x6f5100(0) destroys it;
## HudPanels does that on `closed`. No sound (read).
func _on_close_pressed() -> void:
	restore_saved()
	closed.emit()

## Round 696 (OURS): centred again whenever the view changes size while the
## window is open. The Video tab's own Apply resizes the game window under it
## (VideoOptions.apply_display); left where it was, the window kept its old
## position -- MEASURED on the box: after 1920 x 1056 -> 1024 x 768 its
## right half and its Cancel / Apply buttons were off the screen. Retail
## tells its UI the new size after a resolution change (message 0x80a with
## w, h from CGFXVideo3d::vslot_020, 0xbad590); what its windows do with it
## is not read.
func _notification(what: int) -> void:
	if what == NOTIFICATION_ENTER_TREE:
		var vp := get_viewport()
		if vp != null and not vp.size_changed.is_connected(_on_view_resized):
			vp.size_changed.connect(_on_view_resized)
	elif what == NOTIFICATION_EXIT_TREE:
		if KeyMap.capture == Callable(self, "_capture_key"):
			KeyMap.capture = Callable()
		var vp := get_viewport()
		if vp != null and vp.size_changed.is_connected(_on_view_resized):
			vp.size_changed.disconnect(_on_view_resized)

func _on_view_resized() -> void:
	if visible:
		place_centred()

## 0x798c50(0x62): centred.
func place_centred() -> void:
	var view := get_viewport_rect().size
	position = Vector2(maxi(0, (int(view.x) >> 1) - (int(size.x) >> 1)),
		maxi(0, (int(view.y) >> 1) - (int(size.y) >> 1)))

## CNIFMainFrame's chrome, as AlchemyWindow places it.
func _place_title_bar(bar: Control) -> void:
	var rect := Rect2(Vector2(MAINFRAME_CAPTION_X, MAINFRAME_CAPTION_Y),
		Vector2(size.x - MAINFRAME_STRIP_WIDTH_LESS, MAINFRAME_CAPTION_HEIGHT))
	bar.set_meta(UiBuilder.AUTHORED_RECT_META, rect)
	bar.position = rect.position
	bar.size = rect.size

func _close_position() -> Vector2:
	return Vector2(size.x - MAINFRAME_CLOSE_INSET, MAINFRAME_CLOSE_Y)

func in_drag_strip(local: Vector2) -> bool:
	return Rect2(MAINFRAME_CAPTION_X, 0.0, size.x - MAINFRAME_STRIP_WIDTH_LESS,
		MAINFRAME_DRAG_HEIGHT).has_point(local)

## A control by its GetChild path from the window's root.
func control(path: Array) -> Control:
	return _at(path)

## The slider node of a row (0 BGM, 1 Effect, 2 Env).
func slider(row: int) -> Control:
	return _sliders[row] if row < _sliders.size() else null

func thumb(row: int) -> Control:
	return _thumbs[row] if row < _thumbs.size() else null

func mute_box(row: int) -> BaseButton:
	return _mutes[row] if row < _mutes.size() else null

func _at(path: Array) -> Control:
	return TwoDtBuilder.find_path(panel_root, path) if panel_root != null else null
