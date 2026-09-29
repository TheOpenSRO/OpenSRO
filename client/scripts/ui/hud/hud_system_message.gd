extends Control
class_name HudSystemMessage

## The system message window, bottom right (round 639;
## docs/protocol/system_message.md has every address).
##
## READ. Interface child 0x44 (68) is ginterface.txt's
## `GDR_SYSTEM_MESSAGE_VIEW`, a `CIFSystemMessage` (rect 0,552,350,126).
## Its Create (0x7bc150) loads `resinfo\ifsystemmessage.txt` and keeps
##
##   +0x378  GDR_SYETEM_MESSAGE_CHATOPTION_BTN  (ID 13, chat_filter_button.ddj, 337,0)
##   +0x37c  GDR_SYETEM_MESSAGE_SIZE_BTN        (ID 15, chat_zoom.ddj, 337,265)
##   +0x380  GDR_SYETEM_MESSAGE_OPTBOARD        (ID 50, a CIFChatOptionBoard)
##   +0x388  GDR_SYETEM_MESSAGE_VSCROLL         (ID 24, 337,37,16,195)
##   +0x384  GDR_SYETEM_MESSAGE_TEXTBOX         (ID 19, a CIFTextBox, 10,15,316,252)
##
## (the layout's own spelling, SYETEM) over three bands of `chat_window.ddj`
## (IDs 5, 6, 7), the chat's art. The text box gets the chat's settings: a
## 14-pixel pitch (0x638c20(0xe)), 100 lines (+0x3a0), lines stacked from
## the bottom (0x638b50(1)), wrapped with the hanging indent (0x64e380(1));
## its scroll bar starts at the bottom (0x65a5c0(999)). Create sets no hover
## colour (the chat's 0x638cf0 call has no counterpart here), so no hover
## bar is drawn (INFERRED that none shows without it).
##
## **Size modes (0x7b87a0).** The constructor (0x7b8450) starts at mode m = 2
## (+0x370 = 2) with m * 3 = 6 rows (+0x374). The size button's handler
## (0x7b89c0, the message map at 0xebf330: ID 15) steps m by one and wraps 7
## to 1, so the modes are 1..6. For mode m, with the screen W x H:
##
##   window     x = W - 0x165 (357), y = H - 0x177 (375) + (6 - m) * 42,
##              height (H - 0x5a) - y = 285 - (6 - m) * 42 -- its bottom at H - 90
##   text box   316 x m * 42, m * 3 rows
##   scroll bar length m * 42 - 57, hidden in mode 1 (0x7b888e)
##   BG_MID     335 x m * 42 + 25; BG_DOWN right under it; the size button
##              bottom-aligned to BG_DOWN.
##
## Mode 6 is the layout's own geometry (285 = 4 + 277 + 4; the scroll bar's
## 195 = 6 * 42 - 57).
##
## **The add (0x7781b0(type, text)).** A line is dropped unless 0x7b85f0
## passes its type: types 0 and 6 always; 1..5 and 7 by the filter board's
## five checkboxes (CIFChatOptionBoard +0x36c..+0x37c, IDs 10..14: GAIN,
## FIGHT, STATUS, PARTY, GAME, with 7 sharing GAME's); any other type never
## (the switch's default returns 0). Its colour is 0xffbacff2 for type 6 and
## 0xffdbc99b for everything else. The checkboxes start checked (the CIFCheckBox
## constructor 0x656c70 sets +0x36c = 1) and the board's Create (0x7a95f0)
## loads them from `Setting\chop.dat` (5 bytes), and with no file unchecks
## only FIGHT. The board itself is not built here (OPEN): the filter button
## does nothing, and the filters stay at those defaults.

const UiBuilder = preload("res://scripts/ui/ui_builder.gd")

const LAYOUT_PATH := "resinfo\\ifsystemmessage.txt"
const REGISTRY_NAME := "GDR_SYSTEM_MESSAGE_VIEW"
## Fallback width (the registry's 350) when the registry is unreadable.
const SIZE_WIDTH := 350.0

# --- The message types (READ: 0x7b85f0, 0x7781b0, the callers) -------------

## Always shown, tan: errors (0x778190's error codes), notices, the chat's
## own refusals from the server (0x877340), the camera-view line (0x780420).
const TYPE_ALWAYS := 0
## The GAIN checkbox: experience, skill experience, gold and item pickups
## (Client_ApplyExpAndLevelUp 0x8a97c0, 0x87ba20, 0x8a70d0).
const TYPE_GAIN := 1
## The FIGHT (battle) checkbox; unchecked with no chop.dat.
const TYPE_FIGHT := 2
## The STATUS checkbox (UI_STATE 0x7836d0's curse release, for one).
const TYPE_STATUS := 3
## The PARTY checkbox: party joins and leaves (UI_PARTY 0x886b10) and the
## chat's party/guild/academy refusals (0x7ad400).
const TYPE_PARTY := 4
## The GAME checkbox (equip refusals, deals, job guild, ...).
const TYPE_GAME := 5
## Always shown, blue: the one caller is the guide line CGInterface's vslot 5
## writes (0x789e53), gated by an option.
const TYPE_GUIDE := 6
## Filtered with GAME (0x7b85f0's case 7).
const TYPE_GAME2 := 7

const COLOR_DEFAULT := 0xffdbc99b
const COLOR_GUIDE := 0xffbacff2

## The filter checkboxes' defaults with no Setting\chop.dat (0x7a95f0):
## every one checked but FIGHT.
const FILTER_DEFAULTS := {TYPE_GAIN: true, TYPE_FIGHT: false, TYPE_STATUS: true, TYPE_PARTY: true,
	TYPE_GAME: true}

# --- Geometry (READ: 0x7b87a0, 0x7b89c0, the constructor 0x7b8450) ---------

const MODE_DEFAULT := 2
const MODE_MIN := 1
const MODE_MAX := 6
const MODE_STEP := 42
const ROWS_PER_MODE := 3
const RIGHT_INSET := 0x165
const TOP_FROM_BOTTOM := 0x177
const BOTTOM_INSET := 0x5a
const LIST_WIDTH := 316.0
const SCROLL_TOP := Vector2(337, 37)
const SCROLL_BUTTON := Vector2(16, 16)
const MAX_LINES := 100
const LINE_PITCH := 14

const BG_MID := "GDR_SYETEM_MESSAGE_BG_MID"
const BG_DOWN := "GDR_SYETEM_MESSAGE_BG_DOWN"
const BG_UP := "GDR_SYETEM_MESSAGE_BG_UP"
const TEXTBOX := "GDR_SYETEM_MESSAGE_TEXTBOX"
const VSCROLL := "GDR_SYETEM_MESSAGE_VSCROLL"
const SIZE_BTN := "GDR_SYETEM_MESSAGE_SIZE_BTN"
const FILTER_BTN := "GDR_SYETEM_MESSAGE_CHATOPTION_BTN"
const OPTBOARD := "GDR_SYETEM_MESSAGE_OPTBOARD"

var _builder: UiBuilder
var _root: Control
var _list: HudChat.ChatList
var _scroll: HudChat.ChatScroll
var _font: Font
var _font_size := 12
## The size mode, 1..6.
var mode := MODE_DEFAULT
## The filter checkboxes: type -> shown (FILTER_DEFAULTS).
var filters := FILTER_DEFAULTS.duplicate()
## Every line added and every line dropped, for the log and the tests:
## {type, text, shown}.
var history: Array = []

func _init(builder: UiBuilder = null) -> void:
	_builder = builder

func setup() -> void:
	var w := SIZE_WIDTH
	if _builder != null:
		var reg := _builder.window_def(REGISTRY_NAME)
		if reg != null and reg.rect.size.x > 0:
			w = float(reg.rect.size.x)
	size = Vector2(w, float(mode_geometry(mode)["height"]))
	custom_minimum_size = size
	# Clicks on the window stay in it (the chat's rule, HudChat.setup).
	mouse_filter = Control.MOUSE_FILTER_STOP
	if _builder != null:
		_font = _builder.font_at(0)
		_font_size = UiBuilder.FONT_SIZES[0]
	if _font == null:
		_font = ThemeDB.fallback_font
	if _builder != null:
		# The file has no #ifdef branches, so it is read as it stands.
		var layout := _builder.load_layout(LAYOUT_PATH)
		if layout != null:
			_root = _builder.build_section(layout, "Create")
	if _root == null:
		# No archive: a bare list, so lines are still kept (tests).
		_root = Control.new()
		_root.name = "Create"
		_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)
	UiBuilder.settle_authored_rects(_root)
	_install_list()
	_install_scroll()
	var size_btn := _root.get_node_or_null(SIZE_BTN) as BaseButton
	if size_btn != null:
		size_btn.pressed.connect(cycle_mode)
		size_btn.focus_mode = Control.FOCUS_NONE
	var filter_btn := _root.get_node_or_null(FILTER_BTN) as BaseButton
	if filter_btn != null:
		filter_btn.focus_mode = Control.FOCUS_NONE
		# 0x7b8680 shows or hides the option board; the board is not built
		# (OPEN), so the click is only logged.
		filter_btn.pressed.connect(func() -> void:
			print("HudSystemMessage: filter board not built (OPEN)"))
	# The layout's scroll control is a plain container; ChatScroll draws and
	# takes the input (HudChat's reason: at its layout height it would lie
	# over the size button in the small modes).
	var vscroll := _root.get_node_or_null(VSCROLL) as Control
	if vscroll != null:
		vscroll.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_apply_mode(mode)

func _install_list() -> void:
	var box := _root.get_node_or_null(TEXTBOX) as Control
	_list = HudChat.ChatList.new()
	_list.name = "Messages"
	_list.font = _font
	_list.font_size = _font_size
	_list.hover_enabled = false
	_list.max_lines = MAX_LINES
	_list.mouse_filter = Control.MOUSE_FILTER_PASS
	_list.changed.connect(_sync_scroll)
	if box != null:
		_list.set_anchors_preset(Control.PRESET_FULL_RECT)
		box.add_child(_list)
	else:
		_list.position = Vector2(10, 15)
		_list.size = Vector2(LIST_WIDTH, MODE_DEFAULT * MODE_STEP)
		_root.add_child(_list)

func _install_scroll() -> void:
	_scroll = HudChat.ChatScroll.new()
	_scroll.name = "SystemScroll"
	if _builder != null:
		_scroll.up_texture = _builder.load_texture(HudChat.ARROW_UP_DDJ)
		_scroll.down_texture = _builder.load_texture(HudChat.ARROW_DOWN_DDJ)
		_scroll.bar_texture = _builder.load_texture(HudChat.SCROLL_BAR_DDJ)
		_scroll.thumb_texture = _builder.load_texture(HudChat.SCROLL_THUMB_DDJ)
	_scroll.position = SCROLL_TOP - Vector2(0, SCROLL_BUTTON.y)
	_scroll.moved.connect(func(pos: int) -> void: _list.set_first(pos))
	_root.add_child(_scroll)

# --- Geometry ---------------------------------------------------------------

## Mode m's geometry, window-local (0x7b87a0; see the class comment).
static func mode_geometry(m: int) -> Dictionary:
	var mm := clampi(m, MODE_MIN, MODE_MAX)
	return {
		"height": 285 - (MODE_MAX - mm) * MODE_STEP,
		"list_h": mm * MODE_STEP,
		"rows": mm * ROWS_PER_MODE,
		"scroll_len": mm * MODE_STEP - 57,
		"scroll_shown": mm != 1,
		"mid_h": mm * MODE_STEP + 25,
		"down_y": mm * MODE_STEP + 29,
	}

## Where 0x7b87a0 puts the window on a W x H screen: x = W - 357, y =
## H - 375 + (6 - m) * 42, the height up to H - 90.
static func screen_rect(m: int, screen: Vector2) -> Rect2:
	var g := mode_geometry(m)
	var y := screen.y - TOP_FROM_BOTTOM + (MODE_MAX - clampi(m, MODE_MIN, MODE_MAX)) * MODE_STEP
	return Rect2(screen.x - RIGHT_INSET, y, SIZE_WIDTH, float(g["height"]))

## Anchors the window to the screen's bottom-right corner at 0x7b87a0's
## offsets: its left edge 357 in from the right, its bottom 90 up from the
## bottom, whatever the screen size (the function runs again on a resolution
## change, 0x79f030).
func anchor_bottom_right() -> void:
	# Taken first: each anchor change keeps the window where it is on screen
	# by moving its offsets, which changes `size` until all four are set.
	var w := size.x
	var h := size.y
	anchor_left = 1.0
	anchor_right = 1.0
	anchor_top = 1.0
	anchor_bottom = 1.0
	grow_horizontal = Control.GROW_DIRECTION_BEGIN
	grow_vertical = Control.GROW_DIRECTION_BEGIN
	offset_left = -RIGHT_INSET
	offset_right = -RIGHT_INSET + w
	offset_bottom = -BOTTOM_INSET
	offset_top = -BOTTOM_INSET - h
	_apply_mode(mode)

## The size button (0x7b89c0): the next mode, 6 wrapping to 1.
func cycle_mode() -> void:
	var m := mode + 1
	if m > MODE_MAX:
		m = MODE_MIN
	print("SYSTEM WINDOW MODE %d -> %d" % [mode, m])
	_apply_mode(m)

func set_mode(m: int) -> void:
	_apply_mode(clampi(m, MODE_MIN, MODE_MAX))

## Lays the window out for mode m; the bottom edge stays where it is (the
## client puts it at H - 90 in every mode). Anchored bottom-right by
## World3D, so the height grows upward through offset_top.
func _apply_mode(m: int) -> void:
	mode = clampi(m, MODE_MIN, MODE_MAX)
	var g := mode_geometry(mode)
	var h := float(g["height"])
	if anchor_bottom == 1.0:
		# Anchored (anchor_bottom_right): the bottom stays, the top moves.
		custom_minimum_size = Vector2(offset_right - offset_left, h)
		offset_top = offset_bottom - h
	else:
		custom_minimum_size = Vector2(size.x, h)
		size = Vector2(size.x, h)
	_place(BG_MID, -1, float(g["mid_h"]))
	_place(BG_DOWN, float(g["down_y"]))
	_place(TEXTBOX, -1, float(g["list_h"]))
	var btn := _root.get_node_or_null(SIZE_BTN) as Control if _root != null else null
	if btn != null:
		var bh := btn.size.y
		if btn.has_meta(UiBuilder.AUTHORED_RECT_META):
			bh = (btn.get_meta(UiBuilder.AUTHORED_RECT_META) as Rect2).size.y
		_place(SIZE_BTN, float(g["down_y"]) + 4.0 - bh)
	if _list != null:
		_list.rows = int(g["rows"])
		if _list.get_parent() == _root:
			_list.size.y = float(g["list_h"])
	var shown := bool(g["scroll_shown"])
	var vscroll := _root.get_node_or_null(VSCROLL) as Control if _root != null else null
	if vscroll != null:
		vscroll.visible = shown
		if shown:
			_place(VSCROLL, -1, float(g["scroll_len"]))
	if _scroll != null:
		_scroll.visible = shown
		_scroll.length = maxf(0.0, float(g["scroll_len"]))
		_scroll.size = Vector2(SCROLL_BUTTON.x, SCROLL_BUTTON.y * 3 + _scroll.length)
		_scroll.queue_redraw()
	# 0x7b87a0 ends by scrolling to 999, the bottom.
	if _list != null:
		_list.scroll_to_bottom()
	_sync_scroll()

func _place(control_name: String, y: float, h: float = -1.0) -> void:
	if _root == null:
		return
	var c := _root.get_node_or_null(control_name) as Control
	if c == null:
		return
	var r := Rect2(c.position, c.size)
	if c.has_meta(UiBuilder.AUTHORED_RECT_META):
		r = c.get_meta(UiBuilder.AUTHORED_RECT_META)
	if y >= 0.0:
		r.position.y = y
	if h >= 0.0:
		r.size.y = h
	c.set_meta(UiBuilder.AUTHORED_RECT_META, r)
	c.position = r.position
	c.size = r.size

# --- Lines ------------------------------------------------------------------

## Whether 0x7b85f0 lets a line of `type` in.
func passes(type: int) -> bool:
	match type:
		TYPE_ALWAYS, TYPE_GUIDE:
			return true
		TYPE_GAIN, TYPE_FIGHT, TYPE_STATUS, TYPE_PARTY, TYPE_GAME:
			return bool(filters.get(type, true))
		TYPE_GAME2:
			return bool(filters.get(TYPE_GAME, true))
	return false

## 0x7781b0's colour: blue for type 6, tan for the rest.
static func color_for(type: int) -> Color:
	return HudChat.argb(COLOR_GUIDE if type == TYPE_GUIDE else COLOR_DEFAULT)

## 0x7781b0(type, text): the line is added when the filter passes it. Line
## breaks inside the text are dropped (OURS: the text box's handling of one
## was not read; the chat drops them, 0x876930).
func add_message(type: int, text: String) -> bool:
	var line := text.replace("\r", "").replace("\n", " ")
	var shown := passes(type) and line != ""
	history.append({"type": type, "text": line, "shown": shown})
	while history.size() > MAX_LINES * 4:
		history.pop_front()
	print("SYSLOG [%d]%s %s" % [type, "" if shown else " (filtered)", line])
	if shown and _list != null:
		_list.add_line(line, color_for(type))
	return shown

## The messages the window holds, oldest first: {text, color}.
func messages() -> Array:
	return _list.messages.duplicate() if _list != null else []

## The wrapped lines, oldest first: {text, color}.
func lines() -> Array:
	return _list.lines.duplicate() if _list != null else []

func list() -> HudChat.ChatList:
	return _list

func scroll_bar() -> HudChat.ChatScroll:
	return _scroll

func _sync_scroll() -> void:
	if _scroll != null and _list != null:
		_scroll.set_range(_list.max_first(), _list.first)

## One line per wheel notch, as the chat (OURS there too).
func _gui_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb == null or not mb.pressed or _list == null:
		return
	if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
		_list.set_first(_list.first - 1)
		accept_event()
	elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		_list.set_first(_list.first + 1)
		accept_event()
