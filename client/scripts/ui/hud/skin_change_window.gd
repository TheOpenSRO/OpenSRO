extends HudWindow
class_name SkinChangeWindow

## CIFChangePlayerModel, the window the character skin change scroll opens
## (round 838; ITEM_MALL_CHAR_SKIN_CHANGE_SCROLL, 3/3/13/9). READ from
## sro_client.exe unless a line says otherwise; the choices themselves are
## SkinChangeModel's.
##
## - **Opening** (IFSlotWithHelp::FUN_00676570): a bag item of 3/3/13 whose
##   `tid >> 11` is 9 (0x676b87) calls GInterfaceWndRelation::FUN_0079b790(1,
##   slot), which builds GInterface child 0x36 from resinfo\ginterface.txt's
##   "ChangePlayerModel" section -- GDR_CHANGE_PLAYER_MODEL, 372 x 400,
##   `interface\messagebox\msgbox2_window_` -- keeps the slot (+0xa1c) and
##   shows it. No packet goes yet.
## - **Its children** (vslot_010 0x7eeca0): resinfo\ifchangeplayermodel.txt's
##   "Create", plus a caption static (id 201, (10, 12, w - 21, 12), text
##   UIIT_PAG_CHAR_SKIN_CHANGE) and a drag area (id 202) of its own -- no
##   close button (so the generic one is hidden here). The three
##   CIFSliderCtrl (FIGURE 33, HEIGHT 34, VOLUME 35) take their arrows and
##   thumb from the file's "SliderBtn" section (71 prev, 72 next, 73 thumb).
## - **The message map** (.data 0xec10c0): 17 Confirm (0x7edcf0), 18 Cancel
##   (0x7edd30), 31 Male, 32 Female, 41/42/43 turn left / reset / turn right,
##   and the sliders' 0x806b: 33 the body (0x7ee620), 34 height (0x7ee3f0), 35
##   weight (0x7ee410).
## - **The preview** (FUN_007ee450, vslot_015): the chosen body, dressed in
##   the player's worn items -- 6 and 7 always, 0..5 and 8 only when the shown
##   sex is the player's -- and its avatars, at the scale byte. Here World3D
##   builds it (preview_builder) into a PaperDoll at the equipment window's
##   camera (OURS: this window's camera was not read).
## - **Closing**: Confirm sends (SendItem_HandleUseItem case 9) and closes;
##   Cancel and Escape (vslot_043) close.
##
## OURS: the slider's track (the thumb from its authored x to the next arrow's
## left edge; CIFSliderCtrl's own draw and drag are not read, as for
## CharCreateSlider) and the turn speed of the rotate buttons (a fixed step a
## frame held; READ only that it is frame time times a constant, 0xda6fa8).

## Confirm pressed with the choice passing the pre-check: the body and scale.
signal confirmed(slot: int, ref_obj_id: int, scale: int)
## The pre-check refused (UIIT_MSG_CHAR_SKIN_ERR_ARMOR's text).
signal refused(text: String)

const LAYOUT := "resinfo\\ifchangeplayermodel.txt"
const REGISTRY := {"name": "GDR_CHANGE_PLAYER_MODEL"}
const TITLE_KEY := "UIIT_PAG_CHAR_SKIN_CHANGE"
const TITLE_FALLBACK := "Character skin change"
const ARMOR_FALLBACK := "To transgend your character, you must first unarm and empty your equipment and extended equipment slots(avatar slots)."

const N_VIEW := "GDR_CHANGE_PLAYER_MODEL_VIEW"
const N_MALE := "GDR_CHANGE_PLAYER_MODEL_INFO_BTN_MALE"
const N_FEMALE := "GDR_CHANGE_PLAYER_MODEL_INFO_BTN_FEMALE"
const N_FIGURE := "GDR_CHANGE_PLAYER_MODEL_INFO_SLI_FIGURE"
const N_HEIGHT := "GDR_CHANGE_PLAYER_MODEL_INFO_SLI_HEIGHT"
const N_VOLUME := "GDR_CHANGE_PLAYER_MODEL_INFO_SLI_VOLUME"
const N_OK := "GDR_CHANGE_PLAYER_MODEL_INFO_BTN_OK"
const N_CANCEL := "GDR_CHANGE_PLAYER_MODEL_INFO_BTN_CANCEL"
const N_LEFT := "GDR_CHANGE_PLAYER_MODEL_VIEW_BTN_LEFT"
const N_RESET := "GDR_CHANGE_PLAYER_MODEL_VIEW_BTN_RESET"
const N_RIGHT := "GDR_CHANGE_PLAYER_MODEL_VIEW_BTN_RIGHT"
const N_THUMB := "GDR_SLIDER_CTRL_BTN_THUMB"
const N_PREV := "GDR_SLIDER_CTRL_BTN_PREV"
const N_NEXT := "GDR_SLIDER_CTRL_BTN_NEXT"

## The rotate buttons' step, radians a frame held (OURS, header).
const TURN_STEP := 0.05

var model := SkinChangeModel.new()
var slot := -1
## Builds the preview body: (ref_obj_id, scale, keep_gear) -> Skeleton3D.
var preview_builder: Callable
## What the pre-check reads: () -> [worn equip slots (Array), avatars held (int)].
var gear_reader: Callable
var doll: PaperDoll = null
var yaw := 0.0
var _view: TextureRect = null
var _sliders: Dictionary = {}
var _turn := 0
var _ok: BaseButton = null

func setup(builder: UiBuilder) -> bool:
	var title := builder.resolve_text(TITLE_KEY) if builder != null else TITLE_FALLBACK
	if title == TITLE_KEY or title == "":
		title = TITLE_FALLBACK
	if not build(builder, LAYOUT, title, PackedStringArray(), PackedStringArray(), false, REGISTRY):
		return false
	var close := get_node_or_null("CloseButton") as Control
	if close != null:
		close.visible = false
	var slider_sec := builder.load_layout(LAYOUT).get_section("SliderBtn")
	for n in [N_FIGURE, N_HEIGHT, N_VOLUME]:
		var host := node(n) as Control
		if host != null:
			_sliders[n] = _make_slider(host, slider_sec, builder)
	_wire(N_MALE, func() -> void: _set_sex(SkinChangeModel.SEX_MAN))
	_wire(N_FEMALE, func() -> void: _set_sex(SkinChangeModel.SEX_WOMAN))
	_wire(N_OK, confirm)
	_wire(N_CANCEL, close_window)
	_wire(N_RESET, func() -> void: _set_yaw(0.0))
	for pair in [[N_LEFT, -1], [N_RIGHT, 1]]:
		var b := node(pair[0]) as BaseButton
		if b != null:
			var dir: int = pair[1]
			b.focus_mode = Control.FOCUS_NONE
			b.button_down.connect(func() -> void: _turn = dir)
			b.button_up.connect(func() -> void: _turn = 0)
	_ok = node(N_OK) as BaseButton
	var host_view := node(N_VIEW) as Control
	if host_view != null:
		_view = TextureRect.new()
		_view.name = "SkinPreview"
		_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_view.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_view.set_anchors_preset(Control.PRESET_FULL_RECT)
		host_view.add_child(_view)
	visible = false
	return true

func _wire(control_name: String, f: Callable) -> void:
	var b := node(control_name) as BaseButton
	if b == null:
		return
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(f)

## One CIFSliderCtrl: the host keeps its authored rect and track art; the
## SliderBtn section's three buttons go in it.
func _make_slider(host: Control, sec: UiLayoutParser.SectionDef, builder: UiBuilder) -> SkinSlider:
	var s := SkinSlider.new()
	s.name = "Slider"
	s.set_anchors_preset(Control.PRESET_FULL_RECT)
	host.add_child(s)
	if sec != null:
		for n in [N_PREV, N_NEXT, N_THUMB]:
			var def: UiLayoutParser.ControlDef = sec.control_by_name.get(n)
			if def == null:
				continue
			var b := builder.build_control(def) as BaseButton
			if b == null:
				continue
			b.position = Vector2(def.rect.position)
			b.focus_mode = Control.FOCUS_NONE
			# Named after its slider (OURS): three sliders share the section.
			b.name = "%s_%s" % [host.name, n.trim_prefix("GDR_SLIDER_CTRL_BTN_")]
			s.add_child(b)
			match n:
				N_PREV: s.prev_button = b
				N_NEXT: s.next_button = b
				N_THUMB: s.thumb = b
	s.wire()
	s.value_changed.connect(func(_v: int) -> void: _slider_moved(host.name))
	return s

## Opens for the scroll in bag slot `at`, on the player's own body.
func open_for(at: int, player_id: int, player_sex: int, player_scale: int) -> void:
	slot = at
	model.start(player_id, player_sex, player_scale)
	yaw = 0.0
	_refresh_sliders()
	_refresh_preview()
	centre()
	visible = true
	if doll != null:
		doll.set_active(true)

func close_window() -> void:
	visible = false
	_turn = 0
	if doll != null:
		doll.set_active(false)

func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if visible and key != null and key.pressed and not key.echo and key.keycode == KEY_ESCAPE:
		close_window()
		get_viewport().set_input_as_handled()

func _process(_delta: float) -> void:
	if visible and _turn != 0:
		_set_yaw(yaw + TURN_STEP * _turn)

func _set_yaw(v: float) -> void:
	yaw = v
	if doll != null:
		doll.set_yaw(yaw)

func _set_sex(sex: int) -> void:
	model.set_sex(sex)
	_refresh_sliders()
	_refresh_preview()

func _slider_moved(host_name: String) -> void:
	var s: SkinSlider = _sliders.get(host_name)
	if s == null:
		return
	match host_name:
		N_FIGURE: model.set_figure(s.value)
		N_HEIGHT: model.set_height(s.value)
		N_VOLUME: model.set_weight(s.value)
	_refresh_preview()

func _refresh_sliders() -> void:
	var f: SkinSlider = _sliders.get(N_FIGURE)
	if f != null:
		f.set_range(1, maxi(1, model.figure_count()))
		f.set_value_quiet(model.figure)
	var h: SkinSlider = _sliders.get(N_HEIGHT)
	if h != null:
		h.set_range(0, SkinChangeModel.SCALE_MAX)
		h.set_value_quiet(model.height())
	var v: SkinSlider = _sliders.get(N_VOLUME)
	if v != null:
		v.set_range(0, SkinChangeModel.SCALE_MAX)
		v.set_value_quiet(model.weight())

func _refresh_preview() -> void:
	if _ok != null:
		_ok.disabled = not model.can_confirm()
	if not preview_builder.is_valid() or model.chosen_id() == 0:
		return
	if doll == null:
		doll = PaperDoll.new()
		doll.name = "SkinChangeDoll"
		add_child(doll)
		doll.use_equipment_view()
		if _view != null:
			doll.size = Vector2i(maxi(1, int(_view.get_parent().size.x)), maxi(1, int(_view.get_parent().size.y)))
			_view.texture = doll.get_texture()
		doll.set_active(visible)
	var skel = preview_builder.call(model.chosen_id(), model.scale, not model.changes_sex())
	if skel is Node3D:
		doll.set_character(skel)
		doll.set_yaw(yaw)

## Confirm (0x7edcf0 -> SendItem_HandleUseItem case 9): the pre-check, then
## the use and the window closed.
func confirm() -> void:
	if not model.can_confirm():
		return
	var worn: Array = []
	var avatars := 0
	if gear_reader.is_valid():
		var got: Array = gear_reader.call()
		if got.size() >= 2:
			worn = got[0]
			avatars = int(got[1])
	if model.precheck(worn, avatars) != 0:
		var text := _builder.resolve_text(SkinChangeModel.ERR_ARMOR_KEY) if _builder != null else ""
		if text == "" or text == SkinChangeModel.ERR_ARMOR_KEY:
			text = ARMOR_FALLBACK
		refused.emit(text)
		return
	confirmed.emit(slot, model.chosen_id(), model.scale)
	close_window()

## The window's slider (CIFSliderCtrl): prev / next step by one, the thumb
## drags over the track (OURS, header).
class SkinSlider extends Control:
	signal value_changed(value: int)
	var prev_button: BaseButton
	var next_button: BaseButton
	var thumb: BaseButton
	var min_value := 0
	var max_value := 0
	var value := 0
	var _dragging := false
	var _track_x := 0.0

	func wire() -> void:
		mouse_filter = Control.MOUSE_FILTER_PASS
		if thumb != null:
			_track_x = thumb.position.x
		if prev_button != null:
			prev_button.pressed.connect(func() -> void: _user_set(value - 1))
		if next_button != null:
			next_button.pressed.connect(func() -> void: _user_set(value + 1))
		if thumb != null:
			thumb.button_down.connect(func() -> void: _dragging = true)
			thumb.button_up.connect(func() -> void: _dragging = false)
		_place_thumb()

	## The thumb's travel: (start x, length) -- from its authored x to the
	## next arrow's left edge less its own width (OURS, header).
	func track() -> Vector2:
		if thumb == null:
			return Vector2.ZERO
		var end := next_button.position.x if next_button != null else size.x
		var w := thumb.size.x
		if thumb.has_meta(UiBuilder.AUTHORED_RECT_META):
			w = (thumb.get_meta(UiBuilder.AUTHORED_RECT_META) as Rect2).size.x
		return Vector2(_track_x, maxf(0.0, end - w - _track_x))

	func set_range(lo: int, hi: int) -> void:
		min_value = lo
		max_value = maxi(hi, lo)
		set_value_quiet(value)

	func set_value_quiet(v: int) -> void:
		value = clampi(v, min_value, max_value)
		_place_thumb()

	func _user_set(v: int) -> void:
		v = clampi(v, min_value, max_value)
		if v == value:
			return
		value = v
		_place_thumb()
		value_changed.emit(value)

	func _place_thumb() -> void:
		if thumb == null:
			return
		var t := track()
		var u := 0.0 if max_value <= min_value else float(value - min_value) / float(max_value - min_value)
		thumb.position.x = t.x + t.y * u
		# The settling pass puts a control back on its authored rect: the
		# thumb's moves with it.
		if thumb.has_meta(UiBuilder.AUTHORED_RECT_META):
			var r: Rect2 = thumb.get_meta(UiBuilder.AUTHORED_RECT_META)
			thumb.set_meta(UiBuilder.AUTHORED_RECT_META, Rect2(Vector2(thumb.position.x, r.position.y), r.size))

	func _input(event: InputEvent) -> void:
		if not _dragging or thumb == null:
			return
		if event is InputEventMouseMotion:
			var t := track()
			var x := get_local_mouse_position().x - thumb.size.x * 0.5
			var u := 0.0 if t.y <= 0.0 else clampf((x - t.x) / t.y, 0.0, 1.0)
			_user_set(min_value + int(roundf(u * float(max_value - min_value))))
		elif event is InputEventMouseButton and not (event as InputEventMouseButton).pressed:
			_dragging = false
