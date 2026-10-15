extends Control
class_name CharacterLockWindow

## The Character Lock window (round 788, lane P): the account PIN at
## character select. The feature is OURS -- the retail game has none, so no
## layout of its own exists (docs/protocol/pin.md) -- and the window is a
## reskin of a private server's addon the user showed: the entry box, the
## message box and Remove Pin on the left, a 3x4 keypad on the right, the
## remember box along the bottom, a close button. Its proportions follow that
## picture; its pixels are this archive's own generic window art, built the
## way docs/UI_TODO.md's recipe builds a window, through UiBuilder:
##
## - the frame `interface\messagebox\msgbox2_window_` (8-slice: 40 top,
##   16 sides and bottom) -- the small dialog's frame (CIFSetPartyMode's,
##   READ 0x6d61e0; PartySettingsDialog), with its caption where that dialog
##   puts it (10, 11, width - 21, 12);
## - the body `com_bg_tile_b` from (16, 40) inside the frame, as
##   ifmessagebox.txt's GDR_MSGBOX_BG;
## - each box a `com_blacksquare_` stretch window over `com_bg_tile_e`
##   inset 2, as ifcheckconfirmwnd.txt's GDR_GUILD_POSITION_GRANT_BLACKSQUARE
##   and _TILE_1;
## - Remove Pin `com_button.ddj` (76x24, every ifmessagebox button);
## - the check box `com_checkbutton_off` with `com_checkbutton_on` drawn over
##   it when checked (UiBuilder.make_checkbox, ifcheckbox.txt);
## - the close button `com_windowclose.ddj`, the client's hardcoded
##   CIFCloseButton art, at (width - 26, 10) (UI_TODO rule 12).
##
## The keypad tiles are OURS: the archive has no keypad art (MEASURED, round
## 788's research). Each is a button of the archive's own -- the ten digits
## `com_blu_button` (40x24, with _focus and _press), C and < `com_red_button`
## (56x24) -- drawn square at 40x40 with its 5-pixel border kept and the
## middle stretched, the digit in the client's font at size index 4, and <
## the archive's `com_left_arrow.ddj`. Every size and gap below is OURS.

## A request to send: kind is CharacterLockPad.SUBMIT_*.
signal submitted(kind: String, pin: String, remember: bool)
## The close button (or Escape): the action that opened the window is off.
signal closed

const FRAME := "interface\\messagebox\\msgbox2_window_"
const BODY_TILE := "interface\\ifcommon\\bg_tile\\com_bg_tile_b.ddj"
const BOX_FRAME := "interface\\ifcommon\\com_blacksquare_"
const BOX_TILE := "interface\\ifcommon\\bg_tile\\com_bg_tile_e.ddj"
const BUTTON := "interface\\ifcommon\\com_button.ddj"
const CHECK_OFF := "interface\\ifcommon\\com_checkbutton_off.ddj"
const DIGIT_BUTTON := "interface\\ifcommon\\com_blu_button"
const KEY_BUTTON := "interface\\ifcommon\\com_red_button"
const BACK_ICON := "interface\\ifcommon\\com_left_arrow.ddj"

## The geometry (OURS; see the header).
const SIZE := Vector2(318, 294)
const TILE := 40.0
const GAP := 6.0
const TILE_MARGIN := 5
const LEFT := Rect2(24, 48, 120, 190)
const PAD := Rect2(150, 48, 144, 190)
const ENTRY := Rect2(8, 8, 104, 26)      # in LEFT
const MESSAGE := Rect2(8, 40, 104, 104)  # in LEFT
const REMOVE := Rect2(22, 158, 76, 24)   # in LEFT
const REMEMBER := Rect2(24, 244, 270, 26)
const CAPTION := "Character Lock"
const REMOVE_TEXT := "Remove Pin"
const REMEMBER_TEXT := "Remember this PC and don't ask for pin"

var pad := CharacterLockPad.new()
var _builder: UiBuilder = null
var _entry: Label = null
var _message: Label = null
var _remove: BaseButton = null
var _remember_row: Control = null
var remember_box: TextureButton = null
## Cell -> its Button.
var tiles: Array[Button] = []

func build(builder: UiBuilder) -> void:
	_builder = builder
	name = "CharacterLockWindow"
	size = SIZE
	custom_minimum_size = SIZE
	mouse_filter = Control.MOUSE_FILTER_STOP
	_add(_control("CIFFrame", "Frame", FRAME, Rect2(Vector2.ZERO, SIZE)))
	_add(_control("CIFNormalTile", "Body", BODY_TILE, Rect2(16, 40, SIZE.x - 32, SIZE.y - 56)))
	var caption := Label.new()
	caption.name = "Caption"
	caption.text = CAPTION
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
	caption.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[0])
	add_child(caption)
	UiBuilder.place_label(caption, Rect2(10, 11, SIZE.x - 21, 12))
	var close := _add(_control("CIFCloseButton", "Close", "", Rect2(SIZE.x - 26, 10, 16, 16))) as BaseButton
	if close != null:
		close.pressed.connect(close_window)

	var left := _box("Left", LEFT)
	_box("EntryBox", Rect2(LEFT.position + ENTRY.position, ENTRY.size))
	_entry = _label("Entry", Rect2(LEFT.position + ENTRY.position, ENTRY.size), 4)
	_box("MessageBox", Rect2(LEFT.position + MESSAGE.position, MESSAGE.size))
	_message = _label("Message", Rect2(LEFT.position + MESSAGE.position + Vector2(4, 4), MESSAGE.size - Vector2(8, 8)), 0)
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_message.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var remove_def := _control("CIFButton", "RemovePin", BUTTON, Rect2(LEFT.position + REMOVE.position, REMOVE.size))
	_remove = _add(remove_def) as BaseButton
	if _remove != null:
		_builder.set_button_text(_remove, REMOVE_TEXT)
		_remove.pressed.connect(press_remove)
	left.mouse_filter = Control.MOUSE_FILTER_IGNORE

	_box("Pad", PAD)
	for cell in 12:
		var b := _tile(cell)
		tiles.append(b)
		add_child(b)

	_remember_row = _box("RememberRow", REMEMBER)
	var holder := Control.new()
	holder.name = "RememberHolder"
	holder.position = REMEMBER.position + Vector2(6, 5)
	holder.size = Vector2(16, 16)
	add_child(holder)
	remember_box = _builder.make_checkbox(holder, CHECK_OFF, false)
	var remember_label := _label("RememberText", Rect2(REMEMBER.position + Vector2(28, 5), Vector2(REMEMBER.size.x - 32, 16)), 0)
	remember_label.text = REMEMBER_TEXT
	remember_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_remember_row.set_meta("parts", [holder, remember_label])
	refresh()

## A def for the builder, as a layout line would give it.
func _control(type: String, node_name: String, ddj: String, rect: Rect2) -> UiLayoutParser.ControlDef:
	var d := UiLayoutParser.ControlDef.new()
	d.type = type
	d.name = node_name
	d.ddj = ddj
	d.rect = Rect2i(rect)
	d.font_color = Color(1, 0.996, 0.984, 0.847) if type == "CIFButton" else Color.WHITE
	d.halign = 1
	return d

func _add(d: UiLayoutParser.ControlDef) -> Control:
	var n := _builder.build_control(d) if _builder != null else null
	if n != null:
		add_child(n)
	return n

## A black box: the stretch window over its tile, inset 2.
func _box(node_name: String, rect: Rect2) -> Control:
	_add(_control("CIFNormalTile", node_name + "Tile", BOX_TILE, rect.grow(-2)))
	var f := _add(_control("CIFStretchWnd", node_name, BOX_FRAME, rect))
	return f if f != null else Control.new()

func _label(node_name: String, rect: Rect2, font_index: int) -> Label:
	var l := Label.new()
	l.name = node_name
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[font_index])
	l.add_theme_color_override("font_color", Color.WHITE)
	l.position = rect.position
	l.size = rect.size
	l.custom_minimum_size = Vector2(rect.size.x, 0)
	add_child(l)
	return l

## Cell `cell`'s tile, at its place in the 3x4 grid.
func _tile(cell: int) -> Button:
	var b := Button.new()
	b.name = "Key%d" % cell
	b.focus_mode = Control.FOCUS_NONE
	b.position = PAD.position + Vector2(6, 6) + Vector2(cell % 3, cell / 3) * (TILE + GAP)
	b.size = Vector2(TILE, TILE)
	b.custom_minimum_size = b.size
	b.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[4])
	b.add_theme_color_override("font_color", Color(0.1, 0.1, 0.12))
	b.add_theme_color_override("font_hover_color", Color(0.1, 0.1, 0.12))
	b.add_theme_color_override("font_pressed_color", Color(0.1, 0.1, 0.12))
	b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.pressed.connect(press_cell.bind(cell))
	return b

func _skin(b: Button, base: String) -> void:
	for pair in [["normal", ""], ["hover", "_focus"], ["pressed", "_press"], ["disabled", ""]]:
		var tex := _builder.load_texture(base + str(pair[1]) + ".ddj") if _builder != null else null
		if tex == null:
			continue
		var sb := StyleBoxTexture.new()
		sb.texture = tex
		sb.texture_margin_left = TILE_MARGIN
		sb.texture_margin_right = TILE_MARGIN
		sb.texture_margin_top = TILE_MARGIN
		sb.texture_margin_bottom = TILE_MARGIN
		b.add_theme_stylebox_override(str(pair[0]), sb)

# --- Modes ----------------------------------------------------------------------

func open_create(required: bool = false) -> void:
	pad.open_create(required)
	refresh()

func open_verify(rng: RandomNumberGenerator = null) -> void:
	if rng == null:
		rng = secure_rng()
	pad.open_verify(rng)
	if remember_box != null:
		remember_box.button_pressed = false
	refresh()

func open_locked(until_unix: int) -> void:
	pad.open_locked(until_unix)
	refresh()

## A generator seeded from the OS's random source (Crypto), not the clock.
static func secure_rng() -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = Crypto.new().generate_random_bytes(8).decode_u64(0)
	return rng

## Draws the pad's state: the keys, the masked entry, the message, which of
## Remove Pin and the remember box show.
func refresh() -> void:
	for cell in tiles.size():
		var b := tiles[cell]
		var key: int = pad.layout[cell]
		b.text = ""
		b.icon = null
		if key == CharacterLockPad.KEY_CLEAR:
			b.text = "C"
			_skin(b, KEY_BUTTON)
		elif key == CharacterLockPad.KEY_BACK:
			b.icon = _builder.load_texture(BACK_ICON) if _builder != null else null
			if b.icon == null:
				b.text = "<"
			_skin(b, KEY_BUTTON)
		else:
			b.text = str(key)
			_skin(b, DIGIT_BUTTON)
		b.disabled = pad.mode == CharacterLockPad.Mode.LOCKED
	if _entry != null:
		_entry.text = pad.masked()
	if _message != null:
		_message.text = pad.message
	var has_pin := pad.mode in [CharacterLockPad.Mode.VERIFY, CharacterLockPad.Mode.REMOVE, CharacterLockPad.Mode.LOCKED]
	if _remove != null:
		_remove.visible = has_pin
		_remove.disabled = pad.mode == CharacterLockPad.Mode.LOCKED
	var show_remember := pad.mode == CharacterLockPad.Mode.VERIFY
	if _remember_row != null:
		_remember_row.visible = show_remember
		for part in _remember_row.get_meta("parts", []):
			(part as Control).visible = show_remember
		var tile := get_node_or_null("RememberRowTile") as Control
		if tile != null:
			tile.visible = show_remember

# --- Input ----------------------------------------------------------------------

func press_cell(cell: int) -> void:
	var kind := pad.press_cell(cell)
	if kind != CharacterLockPad.SUBMIT_NONE:
		var remember := kind == CharacterLockPad.SUBMIT_VERIFY and remember_box != null and remember_box.button_pressed
		submitted.emit(kind, pad.pin(), remember)
	refresh()

func press_remove() -> void:
	pad.begin_remove()
	refresh()

## The server's answer; true when the window's job is done.
func apply_reply(reply: CharacterLockNet.Reply) -> bool:
	var done := pad.on_reply(reply.code, reply.attempts_left, reply.locked_seconds, int(Time.get_unix_time_from_system()))
	refresh()
	return done

func close_window() -> void:
	closed.emit()

## Escape closes; keyboard digits do not type (CharacterLockPad's header).
func _unhandled_key_input(event: InputEvent) -> void:
	if visible and event is InputEventKey and event.pressed and (event as InputEventKey).keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		close_window()
