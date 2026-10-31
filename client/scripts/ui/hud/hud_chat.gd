extends Control
class_name HudChat

## The in-world chat window, built from `resinfo\ifchatviewer.txt` and
## CIFChatViewer's own code (round 634; docs/protocol/chat.md has every
## address).
##
## The registry places it bottom-left: `GDR_CHAT_BOARD` is a `CIFChatViewer`
## at `0,546,399,398` in the registry's own 1600x1200 reference screen. The
## width and height are the window's; the corner it sits in is what the
## anchor below reproduces, the same way the underbar's horizontal centring
## is authored and its flush-to-the-bottom is a choice.
##
## The layout gives:
##
##   GDR_CHAT_BG_UP/_MID/_DOWN   three bands of `chat_window.ddj`, sliced by
##                               UV into thirds and stretched -- a 3-slice
##   GDR_LIST_CHATTING ...       the five message lists, all 365x343 at 27,28:
##                               IDs 16 (all), 17 (party), 18 (guild), 19
##                               (alliance) and 30 (apprentice)
##   GDR_STATIC_*LAMP            the five tab lamps
##   GDR_CHAT_VSCROLL            the scroll bar, 16x308 at 0,36
##   GDR_CHAT_INPUTBOX           the input line, 360x20 at 38,378
##   GDR_CHAT_MODE_BTN           the channel selector left of it, 20x20 at
##                               18,378
##
## **The tabs are built in code** (CIFChatViewer::Create, 0x7ab920): five
## CIFSelectableAreas, IDs 100..104, each `chat_long_tab.ddj` at
## (45 + 70 i, 0, 71, 20), captioned UIIT_CTL_CHAT_ALL,
## UIIT_CTL_CHATMENU_PARTY / _GUILD / _ALLY / _TRAININGCAMP; tab 0 starts
## selected (0x64cc30(1), which sets the font style 2 -- the bold variant,
## 0x8b2cc0 -- where the others get 0x64cc30(0)). Create then moves the lamps
## to (48 + 70 i, 6) (vslot 0x98 at 0x7ac098..0x7ac0f5), one per tab, and the
## tab switch (0x7aa690) shows only the selected tab's lamp and list.
##
## **What each tab shows** is 0x7aca30's routing (the chat-add function):
## every line goes to the All list; a party line (type 4) also to #Party,
## guild (5) to @Guild, union (0x0b) to %Union, academy (0x10) to &Academy;
## and a whisper (2), a GM line (3, which a notice becomes), type 10 and a
## system line (0xff) go to all five. Each list keeps 100 lines (+0x3a0 =
## 100, 0x7abed8; 0x64f8a0 drops the oldest past it).
##
## **The input line picks its channel from its first character** (0x7ad400):
## `#` party, `@` guild, `%` union, `&` academy, `$name text` a whisper
## (0x7ab230 splits the name at the first space), `/` a command, anything
## else ordinary chat -- type 3 when the player is a GM (0x9d4c40). See
## parse_line.
##
## Read with UI_UPDATE_2009_FIRST defined (round 585): the same Create
## fetches IDs 30, 31, 41 and 42, which the layout declares only under that
## define.

const UiBuilder = preload("res://scripts/ui/ui_builder.gd")
const UiLayoutParser = preload("res://scripts/ui/ui_layout_parser.gd")

## Emitted when the player presses Enter on a non-empty line the chat sends:
## a command (it starts with "/") or a chat line; World3D turns a chat line
## into its request through request_for.
signal message_submitted(text: String)
## Round 844: the own guild's name for a union line's prefix (UnionWorld sets it).
var union_guild: Callable
## The selected tab changed (0..4).
signal tab_changed(index: int)

const LAYOUT_PATH := "resinfo\\ifchatviewer.txt"
const REGISTRY_NAME := "GDR_CHAT_BOARD"
const LAYOUT_DEFINES := ["UI_UPDATE_2009_FIRST"]

## Fallback size if the registry is unreadable; the registry's own is used
## when it is there.
const SIZE_WIDTH := 399.0
const SIZE_HEIGHT := 398.0

# --- The chat types (READ: 0x7ad400, 0x877810, 0x876810) ------------------

const TYPE_ALL := 0x01
const TYPE_WHISPER := 0x02
const TYPE_ALL_GM := 0x03
const TYPE_PARTY := 0x04
const TYPE_GUILD := 0x05
const TYPE_GLOBAL := 0x06
const TYPE_NOTICE := 0x07
const TYPE_STALL := 0x09
const TYPE_ASK := 0x0a
const TYPE_UNION := 0x0b
const TYPE_NPC := 0x0d
const TYPE_ACADEMY := 0x10
const TYPE_SYSTEM := 0xff
## Not a chat type: a line this client could not send (lone prefix, a
## whisper with no text) -- 0x7ad400 ends the input without sending.
const TYPE_INCOMPLETE := -1
## Not a chat type: a "/" command, handled by the console.
const TYPE_COMMAND := -2

## The line colour per type, ARGB: 0x876810's switch (0x876a61..0x876a99).
## Types it does not list are white.
const TYPE_COLORS := {
	TYPE_WHISPER: 0xff9ffffe,
	TYPE_ASK: 0xff9ffffe,
	TYPE_ALL_GM: 0xffffaec3,
	TYPE_NOTICE: 0xffffaec3,
	TYPE_PARTY: 0xff9affd0,
	TYPE_GUILD: 0xffffb541,
	TYPE_GLOBAL: 0xffffff00,
	TYPE_UNION: 0xffc2f573,
	TYPE_NPC: 0xffdbadf8,
	TYPE_ACADEMY: 0xff64c7ff,
}
## A refusal's line: 0x7781b0 colours its messages 0xffdbc99b. Retail writes
## them to the system message window (interface child 0x44, HudSystemMessage,
## round 639) through system_sink; with no sink (the tests) they go to the
## All list in that colour instead.
const REFUSAL_COLOR := 0xffdbc99b
## The system-window types the refusals are written with (READ): 0x7ad400's
## party, guild and academy refusals share one `push 0x4` (0x7ad866; the
## guild and academy branches jump back to it), 0x877340's result errors one
## `push 0x0` (0x877798).
const REFUSAL_TYPE_GROUP := 4
const REFUSAL_TYPE_RESULT := 0

## The five tabs, in order: their lists' layout names, lamps' names,
## captions and the channel mark each puts in an empty input line
## (0x7aa690's switch: "", "#", "@", "%", "&").
const LIST_NAMES := ["GDR_LIST_CHATTING", "GDR_LIST_CHATPARTY", "GDR_LIST_CHATGUILD",
	"GDR_LIST_CHATALLIACNE", "GDR_LIST_APPRENTICE"]
const LAMP_NAMES := ["GDR_STATIC_ALLLAMP", "GDR_STATIC_PARTYLAMP", "GDR_STATIC_GUILDLAMP",
	"GDR_STATIC_ALLYLAMP", "GDR_STATIC_APPRENTICE"]
const TAB_CAPTIONS := ["UIIT_CTL_CHAT_ALL", "UIIT_CTL_CHATMENU_PARTY", "UIIT_CTL_CHATMENU_GUILD",
	"UIIT_CTL_CHATMENU_ALLY", "UIIT_CTL_CHATMENU_TRAININGCAMP"]
## Used when the archive has no text table (the English column's own words,
## textuisystem.txt).
const TAB_FALLBACKS := ["All", "#Party", "@Guild", "%Union", "&Academy"]
## Rows a private server's archive puts FIRST for a key, which the client's
## first-row-wins loader (UiTextTable, round 634's review) would show. The
## box's archive has UIIT_CTL_CHATMENU_TRAININGCAMP "&Team" first and
## "&Academy" after it; the vanilla archive has only "&Academy", and the user
## asked for Academy ("Job/Team is another private server modification").
## So these captions fall back to the vanilla word (OURS, a labelled
## override).
const PRIVATE_SERVER_CAPTIONS := {"UIIT_CTL_CHATMENU_TRAININGCAMP": ["&Team", "Job/Team", "&Job/Team"]}
const TAB_PREFIX := ["", "#", "@", "%", "&"]
## The characters 0x7aa690 treats as "only a channel mark" when it swaps the
## mark on a tab switch (its jump table at 0x7aa9dc: index 0 for these).
const LONE_MARKS := "#$%&/@^~"

const TAB_DDJ := "interface\\chattingwnd\\chat_long_tab.ddj"
const TAB_X0 := 45.0
const TAB_STEP := 70.0
const TAB_SIZE := Vector2(71, 20)
const LAMP_X0 := 48.0
const LAMP_Y := 6.0

## Continuation lines are indented by as many spaces as fit in 20 pixels,
## at least one (0x64e930: `local_a8 = 0x14 / space_width`, the space's
## advance from 0x8b2cc0's high word; enabled by +0x3cc, which Create sets
## through 0x64e380(1)).
const WRAP_INDENT_PX := 20.0
## Lines per list (+0x3a0 = 100 at 0x7abed8).
const MAX_LINES := 100
## The line pitch: +0x39c = 14, set by 0x638c20(0xe) at 0x7abeb8 and added
## per line by the draw (0x639ab0).
const LINE_PITCH := 14
## A list's hover row is drawn under a 40%-white bar (+0x3c8 = 0x66ffffff,
## 0x638cf0 at 0x7abf37; the draw 0x639ab0 -> 0x63b0e0, the row from the
## mouse-move slot 17 0x63ad10, enabled by +0x3aa and +0x386).
const HOVER_COLOR := 0x66ffffff
## An unselected tab's caption is text state 3 (0x8b4750(3) at 0x7aa79d),
## the grey 0xffb4b4b4 the CIFStatic constructor sets for it (0x64d64f); the
## selected one is state 0, white.
const TAB_TEXT_SELECTED := 0xffffffff
const TAB_TEXT_UNSELECTED := 0xffb4b4b4

## The window's size modes (0x7aac20). The constructor starts at mode 2
## (+0x428 = 2 at 0x7ad385); GDR_BTN_CHAT_SIZE (ID 15, its event-map entry
## at 0xebebf0) runs 0x7ac2a0, which steps the mode 0..6 and back to 0. For a
## mode m > 0: the lists are m * 56 + 7 tall and show m * 4 rows, the scroll
## bar's length is m * 56 - 28, the middle band m * 56 + 12, and the window
## is placed at y = screen height - 0x1d3 + (6 - m) * 56 with its bottom on
## the bar (height (H - 0x44) - y, so 399 - (6 - m) * 56). Mode 0 is the
## input row alone, 0x15 tall at H - 0x59, the tabs hidden (0x7a9a80(1)).
## Mode 6 is the layout's own geometry.
const MODE_DEFAULT := 2
const MODE_MAX := 6
const MODE_STEP := 56
const ROWS_PER_MODE := 4
const MODE0_HEIGHT := 21

## The scroll bar (GDR_CHAT_VSCROLL, a CIFVerticalScroll): its layout,
## ifverticalscroll.txt, is the up arrow at (0,-16), the down arrow and the
## 16x16 thumb `com_scroll_button.ddj`; the bar's own art is
## `com_scroll_bar.ddj` (0x65a9c0). Create gives it a length of 308 (0x134,
## 0x7abf60 into 0x65a390) -- mode 6's; the size mode then sets m * 56 - 28
## (0x7aac20, see MODE_DEFAULT). The length puts the thumb's travel at the bar's top
## plus 0..308 (0x659150: `(pos - min) * length / (max - min)`) and the down
## arrow at the bar's top + 308 + 16 (0x65a40f).
const SCROLL_TOP := Vector2(0, 36)
const SCROLL_LENGTH := 308.0
const SCROLL_BUTTON := Vector2(16, 16)
const ARROW_UP_DDJ := "interface\\chattingwnd\\chat_arrow_up.ddj"
const ARROW_DOWN_DDJ := "interface\\chattingwnd\\chat_arrow_down.ddj"
const SCROLL_BAR_DDJ := "interface\\ifcommon\\com_scroll_bar.ddj"
const SCROLL_THUMB_DDJ := "interface\\ifcommon\\com_scroll_button.ddj"

## MEASURED from the retail screenshot (docs/protocol/chat.md): every glyph
## pixel's lower-right neighbour is black -- a one-pixel drop shadow.
const SHADOW_OFFSET := Vector2(1, 1)

# --- Auto-hide (round 641; docs/protocol/chat.md "Auto-hide") -------------
#
# READ. CGInterface's update (CGInterface::vslot_012, 0x77b3e2..0x77b41c)
# runs every frame, fetches child 1 (this window) and asks 0x7a9d10 whether
# the frame is wanted: the mouse inside the window's rect (0xb8f3d0, a rect
# test with both edges inclusive), or the input line holding the keyboard
# (0x634ea0 on +0x4a0: GetFocus() is its edit control and it is the UI's
# focused control), or the mouse inside the whisper list's rect (+0x498, ID
# 51 -- a rect test, so its hidden rect above the window counts too). Not
# wanted, the frame is set to the lock byte +0x48c (0x7a9d00); wanted, it is
# shown unless the lock already shows it. So: shown = locked or wanted,
# decided every frame -- no delay and no fade (0x7a9bd0 calls each child's
# show, vslot 0x5c; CIFWnd's 0x652b70 only flips the flag).
#
# 0x7a9bd0(show) sets IDs 12 and 14 (the two top-left buttons), the size
# button (15, +0x464), the input box (11, +0x4a0) and the chat-mode button
# (41, +0x490) to `show`; hiding also hides the whisper list (51) and the
# chat-mode viewer (42). In mode 0 (+0x428 == 0) it then hides 12, 14 and 42
# and stops; otherwise the three bands (5, 6, 7), the scroll bar (24, +0x49c)
# follow `show`, and 0x7a9a80(!show) shows or hides the five tabs and shows
# only the selected tab's lamp. The lists (16..19, 30) are never touched:
# their lines stay, with their shadow and no background.
#
# The lock is GDR_BUTTON_CHATTABHIDE (ID 12, `chat_hide_button.ddj` at
# 30,0): its message-map entry (0xebebb0, filled at 0xd7188a) runs 0x7a99b0,
# which only flips +0x48c. The constructor sets +0x48c = 0 (0x7ad3e4, ebx
# zeroed at 0x7ad305): auto-hide is on by default. Nothing else writes the
# byte and nothing saves it (no Setting file): every new window starts
# unlocked. Nothing reads it but the update, so the button's art does not
# change with the state. Create gives it the tooltip
# UIIT_STT_CHATING_VIEW_AUTO_OFF (0x7ac168 -> +0x444).
const LOCK_BUTTON := "GDR_BUTTON_CHATTABHIDE"
## The three buttons' tooltips, set by Create (0x7ac157..0x7ac21f): ID 12
## (+0x444), ID 14 (+0x448) and ID 15 (+0x464), with the English rows'
## words as the fallback.
const BUTTON_TOOLTIPS := {
	"GDR_BUTTON_CHATTABHIDE": ["UIIT_STT_CHATING_VIEW_AUTO_OFF", "Lock Chat window/Auto hide"],
	"GDR_BUTTON_WHISPERLIST": ["UIIT_CTL_WHISPER_LIST", "Whisper list"],
	"GDR_BTN_CHAT_SIZE": ["UIIT_STT_TOGGLE_CHATING_WINDOW_SETING", "Extend/lessen chatting window"],
}
## Shown with the frame in every mode (0x7a9bd0's first five calls, less the
## two buttons mode 0 hides again).
const FRAME_ROW := ["GDR_BTN_CHAT_SIZE", "GDR_CHAT_MODE_BTN", "GDR_CHAT_INPUTBOX"]
## Shown with the frame in modes 1..6 only.
const FRAME_OPEN := ["GDR_CHAT_BG_UP", "GDR_CHAT_BG_MID", "GDR_CHAT_BG_DOWN", "GDR_BUTTON_WHISPERLIST",
	"GDR_BUTTON_CHATTABHIDE", "GDR_CHAT_VSCROLL"]
## Hidden when the frame hides, never shown by it.
const FRAME_HIDE_ONLY := ["GDR_WHISPERLIST", "GDR_CHAT_MODE_VIEW_WND"]

var _builder: UiBuilder
var _input: CifEdit
var _root: Control
var _lists: Array = []
## What each list's visibility is switched on: its authored box, or the list
## itself when the layout had none.
var _list_boxes: Array = []
var _lamps: Array = []
var _tabs: Array = []
var _scroll: ChatScroll
var _tab := 0
## The size mode (0..6); see MODE_DEFAULT.
var mode := MODE_DEFAULT
## Whether the player is in the group a channel needs: called with TYPE_PARTY,
## TYPE_GUILD or TYPE_ACADEMY. Unset, every line goes to the server, which
## refuses it itself.
var group_check: Callable
var _font: Font
var _bold: Font
var _font_size := 12

## The player's own name, for the lines a sent message echoes.
var own_name := ""
## Where 0x7781b0's lines go: called with (type, text) -- World3D hands it
## the system message window's add (round 639). Unset, they go to the All
## list.
var system_sink: Callable
## Whether the player is a GM, so an unmarked line goes out as type 3.
var is_gm := false

## Sent lines waiting for the server's answer, by index (0x787c10 keeps them
## for 0xB025's handler, which looks them up through 0x787db0).
var _pending := {}
var _next_index := 0

## The lock (+0x48c): true keeps the frame shown; false (the constructor's)
## lets it hide whenever the mouse is off the window and the line is not
## being typed in. Not saved.
var locked := false
## Whether the frame is shown now (see "Auto-hide" above).
var frame_shown := true

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
	# The window blocks the world behind it -- clicking on chat should not
	# also walk the character -- while its own children keep their filters,
	# so the input line, the tabs and the scroll bar still work. STOP, as
	# HudWindow uses: Godot hit-tests the deepest control first, and STOP
	# only catches what the children did not want (round 522's review).
	mouse_filter = Control.MOUSE_FILTER_STOP

	if _builder != null:
		_font = _builder.font_at(0)
		_font_size = UiBuilder.FONT_SIZES[0]
	if _font == null:
		_font = ThemeDB.fallback_font
	# The client's bold variant is the same face at weight 600 (UiBuilder's
	# FONT_SIZES note); Godot's embolden stands in for it (OURS), at 4.2.2's
	# weight at every UI scale (FontOversampling, round 760).
	_bold = FontOversampling.bold(_font, 0.6)

	if _builder == null:
		_apply_mode(mode, false)
		return
	var layout := _builder.load_layout(LAYOUT_PATH, PackedStringArray(LAYOUT_DEFINES), true)
	if layout == null:
		return
	_root = _builder.build_section(layout, "Create")
	if _root == null:
		return
	add_child(_root)
	UiBuilder.settle_authored_rects(_root)

	# The whisper list is authored *above* the window (y=-152) and is a
	# pop-up, not part of the resting window. Hidden until there is
	# something to put in it (not built yet -- OPEN).
	var whisper := _root.get_node_or_null("GDR_WHISPERLIST")
	if whisper is CanvasItem:
		(whisper as CanvasItem).visible = false

	_install_lists()
	_install_lamps()
	_install_tabs()
	_install_scroll()
	_install_input()
	var size_btn := _root.get_node_or_null("GDR_BTN_CHAT_SIZE") as BaseButton
	print("HudChat: size button %s" % ("GDR_BTN_CHAT_SIZE (%s)" % size_btn.get_class() if size_btn != null else "missing"))
	if size_btn != null:
		size_btn.pressed.connect(cycle_mode)
		# No keyboard focus on buttons (the client has none; round 606).
		size_btn.focus_mode = Control.FOCUS_NONE
	var lock_btn := _root.get_node_or_null(LOCK_BUTTON) as BaseButton
	if lock_btn != null:
		lock_btn.pressed.connect(toggle_lock)
		lock_btn.focus_mode = Control.FOCUS_NONE
	for n in BUTTON_TOOLTIPS:
		var b := _root.get_node_or_null(n) as Control
		if b != null:
			b.tooltip_text = _text(BUTTON_TOOLTIPS[n][0], BUTTON_TOOLTIPS[n][1])
	var watch := FrameWatch.new()
	watch.name = "FrameWatch"
	watch.target = self
	add_child(watch)
	_apply_mode(mode, false)

# --- Auto-hide (0x77b3e2, 0x7a9d10, 0x7a9bd0, 0x7a99b0) -------------------

## The update's frame test, every frame: the real mouse against the window.
func _process(_delta: float) -> void:
	update_frame(get_global_mouse_position())

## OURS: a mouse event runs the same test at once, at the event's own
## position, so a click that arrives with the move into the window finds the
## frame (and the input line) already shown. Retail runs the test only in the
## per-frame update; with a real mouse the move comes first either way. It
## also lets pushed events (the headless tests, whose viewport reports its
## centre as the mouse) reach the line. A child node carries the `_input`
## callback, since this class's `_input` is the line edit.
class FrameWatch extends Node:
	var target: Control

	func _input(event: InputEvent) -> void:
		var m := event as InputEventMouse
		if m != null and target != null and target.is_visible_in_tree():
			target.call("update_frame", m.position)

## One pass of CGInterface's update for this window, with the mouse at
## `point` (global): the frame shown when locked or wanted, hidden otherwise.
func update_frame(point: Vector2) -> void:
	var want := locked or frame_wanted(point)
	if want != frame_shown:
		set_frame_shown(want)

## 0x7a9d10: the mouse inside the window's rect, or the input line holding
## the keyboard, or the mouse inside the whisper list's rect (shown or not).
func frame_wanted(point: Vector2) -> bool:
	if _inside(get_global_rect(), point):
		return true
	if _input != null and _input.has_focus():
		return true
	var whisper := _root.get_node_or_null("GDR_WHISPERLIST") as Control if _root != null else null
	return whisper != null and _inside(whisper.get_global_rect(), point)

## 0xb8f3d0's test: both edges inclusive (`x0 <= x <= x0 + w`). The insets
## it adds (+0x50..+0x5c) are zero here: GDR_CHAT_BOARD's ClientRect is
## 0,0,0,0 (INFERRED that those fields are the ClientRect).
static func _inside(r: Rect2, p: Vector2) -> bool:
	return p.x >= r.position.x and p.x <= r.end.x and p.y >= r.position.y and p.y <= r.end.y

## The window keeps a click on its inclusive right and bottom edges too, as
## 0xb8f3d0 does. Godot's own hit test is half-open (x < end.x), which let a
## click on x = end.x through to the world.
func _has_point(point: Vector2) -> bool:
	return _inside(Rect2(Vector2.ZERO, size), point)

## OPENSRO_QA_FRAME_LOG set: each frame change is logged with the window's
## rect (the round-641 e2e's measurement). Off by default: hovering would
## otherwise write a line on every pass over a window.
static func frame_log() -> bool:
	return OS.get_environment("OPENSRO_QA_FRAME_LOG") != ""

## 0x7a9bd0(show).
func set_frame_shown(show: bool) -> void:
	if show != frame_shown and is_inside_tree() and frame_log():
		print("CHAT FRAME %s rect=%s" % ["shown" if show else "hidden", get_global_rect()])
	frame_shown = show
	if _root != null and not show:
		for n in FRAME_HIDE_ONLY:
			var c := _root.get_node_or_null(n) as CanvasItem
			if c != null:
				c.visible = false
	_apply_visibility()

## The lock button (0x7a99b0): flips +0x48c. The frame follows on the next
## update.
func toggle_lock() -> void:
	locked = not locked
	print("CHAT LOCK %s (auto-hide %s)" % ["on" if locked else "off", "off" if locked else "on"])

## What the mode and the frame together show: the input row with the frame;
## the tabs, the selected tab's lamp, the bands, the two top-left buttons
## and the scroll bar with the frame in modes 1..6 (0x7a9bd0, 0x7aac20).
func _apply_visibility() -> void:
	if _root == null:
		return
	var framed := mode > 0 and frame_shown
	for t in _tabs:
		(t as Control).visible = framed
	for n in FRAME_OPEN:
		var c := _root.get_node_or_null(n) as CanvasItem
		if c != null:
			c.visible = framed
	if _scroll != null:
		_scroll.visible = framed
	for n in FRAME_ROW:
		var c := _root.get_node_or_null(n) as CanvasItem
		if c != null:
			c.visible = frame_shown
	for i in _lamps.size():
		if _lamps[i] != null:
			(_lamps[i] as CanvasItem).visible = framed and i == _tab

## A ChatList over each authored list box, at exactly its rect.
##
## The five `GDR_LIST_*` are `CIFTextBox`es, which UiBuilder builds as plain
## containers; each gets a ChatList child that draws its lines.
func _install_lists() -> void:
	for i in LIST_NAMES.size():
		var box := _root.get_node_or_null(LIST_NAMES[i]) as Control
		var list := ChatList.new()
		list.name = "Messages" if i == 0 else "Messages%d" % i
		list.font = _font
		list.font_size = _font_size
		list.set_anchors_preset(Control.PRESET_FULL_RECT)
		# PASS: the list sees the mouse move for its hover bar; clicks and the
		# wheel carry on to the window.
		list.mouse_filter = Control.MOUSE_FILTER_PASS
		list.changed.connect(_on_list_changed.bind(list))
		if box != null:
			box.add_child(list)
			_list_boxes.append(box)
		else:
			# No layout box (an archive without the #ifdef branch): keep the
			# list so lines are not lost, at the authored rect.
			list.position = Vector2(27, 28)
			list.size = Vector2(365, 343)
			_root.add_child(list)
			_list_boxes.append(list)
		_lists.append(list)

func _install_lamps() -> void:
	for i in LAMP_NAMES.size():
		var lamp := _root.get_node_or_null(LAMP_NAMES[i]) as Control
		if lamp != null:
			# The settle pass re-applies the authored rect, so the moved one
			# becomes the authored one.
			var sz := lamp.size
			if lamp.has_meta(UiBuilder.AUTHORED_RECT_META):
				sz = (lamp.get_meta(UiBuilder.AUTHORED_RECT_META) as Rect2).size
			var rect := Rect2(Vector2(LAMP_X0 + TAB_STEP * i, LAMP_Y), sz)
			lamp.set_meta(UiBuilder.AUTHORED_RECT_META, rect)
			lamp.position = rect.position
		_lamps.append(lamp)

func _install_tabs() -> void:
	var tex: Texture2D = _builder.load_texture(TAB_DDJ) if _builder != null else null
	for i in TAB_CAPTIONS.size():
		var tab := ChatTab.new()
		tab.name = "ChatTab%d" % i
		tab.texture = tex
		tab.caption = caption_for(TAB_CAPTIONS[i], _text(TAB_CAPTIONS[i], TAB_FALLBACKS[i]), TAB_FALLBACKS[i])
		tab.font = _font
		tab.bold_font = _bold
		tab.font_size = _font_size
		tab.position = Vector2(TAB_X0 + TAB_STEP * i, 0)
		tab.size = TAB_SIZE
		tab.pressed.connect(select_tab.bind(i))
		_root.add_child(tab)
		# Under the layout's controls: the lamps (and the two buttons at the
		# left) draw over the tab art, as the retail screenshot shows.
		_root.move_child(tab, i)
		_tabs.append(tab)

func _install_scroll() -> void:
	_scroll = ChatScroll.new()
	_scroll.name = "ChatScroll"
	if _builder != null:
		_scroll.up_texture = _builder.load_texture(ARROW_UP_DDJ)
		_scroll.down_texture = _builder.load_texture(ARROW_DOWN_DDJ)
		_scroll.bar_texture = _builder.load_texture(SCROLL_BAR_DDJ)
		_scroll.thumb_texture = _builder.load_texture(SCROLL_THUMB_DDJ)
	_scroll.length = SCROLL_LENGTH
	# The up arrow sits 16 above the bar's top (its layout rect 0,-16).
	_scroll.position = SCROLL_TOP - Vector2(0, SCROLL_BUTTON.y)
	_scroll.size = Vector2(SCROLL_BUTTON.x, SCROLL_BUTTON.y * 3 + SCROLL_LENGTH)
	_scroll.moved.connect(_on_scroll_moved)
	_root.add_child(_scroll)

## Puts a real editable line over the authored input box.
##
## `GDR_CHAT_INPUTBOX` is a `CIFEInputChatBox` carrying an atlas slice of
## `window_all.ddj` for its own background, which UiBuilder already draws.
## What it needs is somewhere to type.
## CIFEInputChatBox's limit (READ: 0x65cf46 push 0x64 -> 0x634f80, the edit's
## +0x3fc, which CIFEdit's WM_CHAR compares before taking a character).
const INPUT_MAX := 100

func _install_input() -> void:
	var box := _root.get_node_or_null("GDR_CHAT_INPUTBOX") as Control
	if box == null:
		return
	# Round 848: a CifEdit -- CIFEInputChatBox shares CIFEdit's draw and
	# handlers (0x637b70, 0x637290: the 2 px caret in the line's colour, 200 ms
	# blink, no selection, menu or paste; CifEdit's header). Round 754's Enter
	# and Escape rules come with it (KeyInput.line_edit_as_42).
	_input = CifEdit.new()
	_input.name = "Input"
	_input.set_anchors_preset(Control.PRESET_FULL_RECT)
	_input.flat = true
	# No box of Godot's own, the focus one included: the box's own art is
	# the authored control's (UiBuilder._build_edit).
	for style in ["normal", "focus", "read_only"]:
		_input.add_theme_stylebox_override(style, StyleBoxEmpty.new())
	# The line's FontColor is the authored control's.
	_input.set_colour((box as CifEdit).colour() if box is CifEdit else Color.WHITE)
	# CIFEInputChatBox's Create (0x65cf30): 0x634f80(100), the edit's limit.
	_input.max_length = INPUT_MAX
	if box is LineEdit:
		box.focus_mode = Control.FOCUS_NONE
	if _font != null:
		_input.add_theme_font_override("font", _font)
	_input.add_theme_font_size_override("font_size", _font_size)
	_input.text_submitted.connect(_on_submitted)
	box.add_child(_input)

## A tab's caption: the text table's, unless it is a known private-server
## row (PRIVATE_SERVER_CAPTIONS), which gives way to the vanilla word.
static func caption_for(key: String, resolved: String, vanilla: String) -> String:
	if (PRIVATE_SERVER_CAPTIONS.get(key, []) as Array).has(resolved):
		return vanilla
	return resolved

func _text(key: String, fallback: String) -> String:
	if _builder == null:
		return fallback
	var s := _builder.resolve_text(key)
	return fallback if s == "" or s == key else s

# --- Tabs ----------------------------------------------------------------

## Switches to tab `index` (0x7aa690): only its list and its lamp shown, the
## scroll bar bound to it and at the bottom (0x65a5c0(999)), its caption
## bold; and an input line that is empty or holds only a channel mark gets
## this tab's mark.
func select_tab(index: int) -> void:
	if index < 0 or index >= LIST_NAMES.size():
		return
	_tab = index
	for i in _list_boxes.size():
		(_list_boxes[i] as Control).visible = i == index and mode > 0
	for i in _lamps.size():
		if _lamps[i] != null:
			(_lamps[i] as CanvasItem).visible = i == index and mode > 0 and frame_shown
	for i in _tabs.size():
		(_tabs[i] as ChatTab).selected = i == index
	if index < _lists.size():
		(_lists[index] as ChatList).scroll_to_bottom()
		_sync_scroll()
	if _input != null:
		var t := _input.text
		if t == "" or (t.length() == 1 and LONE_MARKS.contains(t)):
			_input.text = TAB_PREFIX[index]
			_input.caret_column = _input.text.length()
	tab_changed.emit(index)

func current_tab() -> int:
	return _tab

# --- Size modes (0x7aac20) ------------------------------------------------

## The geometry of mode `m`, in window-local pixels (see MODE_DEFAULT).
static func mode_geometry(m: int) -> Dictionary:
	if m <= 0:
		return {"height": MODE0_HEIGHT, "row_y": 0, "rows": 0}
	return {
		"height": 399 - (MODE_MAX - m) * MODE_STEP,
		"list_h": m * MODE_STEP + 7,
		"rows": m * ROWS_PER_MODE,
		"scroll_len": m * MODE_STEP - 28,
		"mid_h": m * MODE_STEP + 12,
		"down_y": m * MODE_STEP + 37,
		"row_y": m * MODE_STEP + 42,
	}

## The size button (0x7ac2a0): the next mode, 6 wrapping to 0.
func cycle_mode() -> void:
	var m := mode + 1
	if m > MODE_MAX:
		m = 0
	print("CHAT MODE %d -> %d" % [mode, m])
	_apply_mode(m, true)

func set_mode(m: int) -> void:
	_apply_mode(clampi(m, 0, MODE_MAX), true)

## Lays the window out for mode `m`. With `keep_bottom` the window's bottom
## edge stays where it is (the client places it on the bar in every mode).
func _apply_mode(m: int, keep_bottom: bool) -> void:
	mode = m
	var g := mode_geometry(m)
	var bottom := position.y + size.y
	var h := float(g["height"])
	custom_minimum_size = Vector2(size.x, h)
	size = Vector2(size.x, h)
	if keep_bottom:
		position.y = bottom - h
	if _root == null:
		return
	var open := m > 0
	# 0x7a9a80: the tabs shown unless mode 0; the bands, the two top-left
	# buttons and the scroll bar with them -- all while the frame is shown
	# (the auto-hide, _apply_visibility).
	_apply_visibility()
	# The authored scroll control is a plain container here (ChatScroll
	# draws and takes the input); at its layout height, 308, it lay over the
	# size button in the smaller modes and ate its click (found on the live
	# run). It follows the mode's length, as the real one does (0x65a500).
	var vscroll := _root.get_node_or_null("GDR_CHAT_VSCROLL") as Control
	if vscroll != null:
		vscroll.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vscroll.visible = open and frame_shown
		if open:
			_place("GDR_CHAT_VSCROLL", -1, float(g["scroll_len"]))
	var row_y := float(g["row_y"])
	for n in ["GDR_BTN_CHAT_SIZE", "GDR_CHAT_MODE_BTN", "GDR_CHAT_INPUTBOX"]:
		_place(n, row_y)
	# The penalty line (ID 52, +0x468) at the size button's y + 3, its own x
	# kept (0x7ab1b0..0x7ab1d6: `add ecx,0x3` on +0x464's y) -- not its
	# authored 380, 2 below the button's 378.
	_place("GDR_CHAT_STA_PENALTY", row_y + 3)
	if not open:
		for b in _list_boxes:
			(b as Control).visible = false
		for l in _lamps:
			if l != null:
				(l as CanvasItem).visible = false
		return
	_place("GDR_CHAT_BG_MID", -1, float(g["mid_h"]))
	_place("GDR_CHAT_BG_DOWN", float(g["down_y"]))
	for i in _lists.size():
		(_lists[i] as ChatList).rows = int(g["rows"])
		var box: Control = _list_boxes[i]
		if box != _lists[i]:
			_place(String(box.name), -1, float(g["list_h"]))
		else:
			box.size.y = float(g["list_h"])
	if _scroll != null:
		_scroll.length = float(g["scroll_len"])
		_scroll.size = Vector2(SCROLL_BUTTON.x, SCROLL_BUTTON.y * 3 + _scroll.length)
		_scroll.queue_redraw()
	# 0x7aac20 ends with the tab switch.
	select_tab(_tab)

## Moves (y >= 0) and sizes (h >= 0) one layout control, keeping its settling
## rect in step (UiBuilder.settle_authored_rects re-applies it).
func _place(control_name: String, y: float, h: float = -1.0) -> void:
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

func _current_list() -> ChatList:
	return _lists[_tab] if _tab < _lists.size() else null

# --- Lines ---------------------------------------------------------------

## Which lists a line of `type` goes to (0x7aca30), as tab indices.
static func lists_for(type: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	match type:
		TYPE_ALL, TYPE_WHISPER, TYPE_ALL_GM, TYPE_GLOBAL, TYPE_ASK, TYPE_NPC, TYPE_SYSTEM, \
				TYPE_PARTY, TYPE_GUILD, TYPE_UNION, 0x08, TYPE_ACADEMY:
			out.append(0)
		_:
			# 0x7aca30's default: nothing is added anywhere.
			return out
	match type:
		TYPE_PARTY:
			out.append(1)
		TYPE_GUILD:
			out.append(2)
		TYPE_UNION:
			out.append(3)
		TYPE_ACADEMY:
			out.append(4)
		TYPE_WHISPER, TYPE_SYSTEM, TYPE_ASK, TYPE_ALL_GM:
			out.append_array(PackedInt32Array([1, 2, 3, 4]))
	return out

static func color_for(type: int) -> Color:
	return argb(int(TYPE_COLORS.get(type, 0xffffffff)))

static func argb(v: int) -> Color:
	return Color8((v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff, (v >> 24) & 0xff)

## The line 0x876810 shows for one message, as {type, text, color}: the type
## is the one the line is FILED under (a notice goes out as type 3, a GM's
## ";" line as type 1), or TYPE_INCOMPLETE for a type the dispatcher shows
## nothing for.
##
##   name + ":" + text                      1, 6, 9 (and 0xd, 3)
##   name + "(" + FROM|TO + "):" + text     2 -- TO for the sender's own echo
##   name + "(Party):" + text               4   (UIIT_CTL_PARTY)
##   name + "(Guild):" + text               5   (UIIT_CTL_GUILD)
##   "(Notice):" + text                     7   (UIIT_MSG_NOTIFY), filed as 3
##   name + "(ASK):" + text                 0x0a
##   name + "(Union" + text                 0x0b (the sender's client puts
##                                           "-<guild>): " in the text,
##                                           0x7ada5a)
##   name + "(Academy):" + text             0x10 (UIIT_CTL_TC_TRAININGCAMP)
##
## A type-3 line whose text starts with ";" loses the ";" and is shown as an
## ordinary white line (0x876cc4). Line breaks in the text -- a real one or a
## written "\n" -- are dropped first (0x876930's two loops).
func format_line(type: int, name: String, message: String, sent: bool = false) -> Dictionary:
	var text := message.replace("\\n", "").replace("\n", "").replace("\r", "")
	var filed := type
	var color := color_for(type)
	var suffix := ""
	match type:
		TYPE_ALL, TYPE_GLOBAL, TYPE_STALL, TYPE_NPC:
			suffix = ":"
		TYPE_ALL_GM:
			suffix = ":"
			if text.begins_with(";"):
				text = text.substr(1)
				filed = TYPE_ALL
				color = argb(0xffffffff)
		TYPE_WHISPER:
			suffix = "(%s):" % (_text("UIIT_CHATERR_WHISPER_TO_MESSAGE", "TO") if sent
				else _text("UIIT_CHATERR_WHISPER_FROM_MESSAGE", "FROM"))
		TYPE_PARTY:
			suffix = "(%s):" % _text("UIIT_CTL_PARTY", "Party")
		TYPE_GUILD:
			suffix = "(%s):" % _text("UIIT_CTL_GUILD", "Guild")
		TYPE_NOTICE:
			return {"type": TYPE_ALL_GM, "color": color,
				"text": "(%s):%s" % [_text("UIIT_MSG_NOTIFY", "Notice"), text]}
		TYPE_ASK:
			suffix = "(ASK):"
		TYPE_UNION:
			suffix = "(%s" % _text("UIIT_STT_GUILD_RESPECT_ALLY", "Union")
		TYPE_ACADEMY:
			suffix = "(%s):" % _text("UIIT_CTL_TC_TRAININGCAMP", "Academy")
		TYPE_SYSTEM:
			return {"type": TYPE_SYSTEM, "color": argb(0xffffffff), "text": text}
		_:
			return {"type": TYPE_INCOMPLETE, "color": color, "text": ""}
	return {"type": filed, "color": color, "text": name + suffix + text}

## Adds one message of `type` from `name` to the lists 0x7aca30 files it in.
## `sent` marks the sender's own echo (a whisper then reads "(TO)").
## `color_argb` (round 838) overrides the type's colour: a coloured global
## chatting item's line (ChatNet.Update.color, OURS); 0 keeps the type's.
func add_chat(type: int, name: String, message: String, sent: bool = false, color_argb: int = 0) -> void:
	var line := format_line(type, name, message, sent)
	if int(line["type"]) == TYPE_INCOMPLETE:
		return
	var color: Color = line["color"]
	if color_argb != 0:
		color = argb(color_argb)
	_add_to(lists_for(int(line["type"])), String(line["text"]), color)

## Adds one line to the All list only, the way CIFChatViewer's vslot 49
## (0x7aaa50) does. `speaker` empty makes it a speakerless line; this
## client's system lines go to the system message window instead (round 639,
## HudSystemMessage).
func add_message(speaker: String, text: String, color: Color = Color.WHITE) -> void:
	var line := text
	if speaker != "":
		line = "%s:%s" % [speaker, text]
	_add_to(PackedInt32Array([0]), line, color)

## Kept for callers of the old API: a received whisper.
func add_whisper(speaker: String, text: String) -> void:
	add_chat(TYPE_WHISPER, speaker, text)

func _add_to(targets: PackedInt32Array, text: String, color: Color) -> void:
	for i in targets:
		if i < _lists.size():
			(_lists[i] as ChatList).add_line(text, color)

## The lines a list holds now, wrapped, for tests and the QA dump.
func list_lines(index: int) -> Array:
	if index < 0 or index >= _lists.size():
		return []
	return (_lists[index] as ChatList).lines.duplicate()

func list_messages(index: int) -> Array:
	if index < 0 or index >= _lists.size():
		return []
	return (_lists[index] as ChatList).messages.duplicate()

# --- Scrolling -----------------------------------------------------------

func _on_list_changed(list: ChatList) -> void:
	if list == _current_list():
		_sync_scroll()

func _sync_scroll() -> void:
	var list := _current_list()
	if _scroll == null or list == null:
		return
	_scroll.set_range(list.max_first(), list.first)

func _on_scroll_moved(pos: int) -> void:
	var list := _current_list()
	if list != null:
		list.set_first(pos)

## One line per wheel notch (OURS: the list's wheel step was not read; the
## arrows' step is 1, 0x6592a0's fourth argument at 0x7abf51).
func _gui_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb == null or not mb.pressed:
		return
	var list := _current_list()
	if list == null:
		return
	if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
		list.set_first(list.first - 1)
		_sync_scroll()
		accept_event()
	elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		list.set_first(list.first + 1)
		_sync_scroll()
		accept_event()

func scroll_by(lines: int) -> void:
	var list := _current_list()
	if list != null:
		list.set_first(list.first + lines)
		_sync_scroll()

func scroll_position() -> int:
	var list := _current_list()
	return list.first if list != null else 0

func scroll_max() -> int:
	var list := _current_list()
	return list.max_first() if list != null else 0

func scroll_bar() -> ChatScroll:
	return _scroll

# --- Input ---------------------------------------------------------------

## What a typed line asks for (0x7ad400), as {type, target, message}:
##
##   ""                 TYPE_INCOMPLETE (the input just ends)
##   "/..."             TYPE_COMMAND
##   "#text"            party      "@text"  guild
##   "%text"            union      "&text"  academy
##   "$name text"       whisper (0x7ab230: the name runs to the first
##                      space; "$name" or "$" alone is TYPE_INCOMPLETE)
##   anything else      ordinary chat, type 3 for a GM
##
## A channel mark with nothing after it is TYPE_INCOMPLETE (the length-1
## test at 0x7ad7dc). The mark is not sent as part of the text (INFERRED:
## 0x7ad904 copies the raw line when the split left the message empty;
## whether retail's server strips it was not read -- OpenSRO's client does).
static func parse_line(text: String, gm: bool = false) -> Dictionary:
	var out := {"type": TYPE_INCOMPLETE, "target": "", "message": ""}
	if text == "":
		return out
	var first := text[0]
	match first:
		"/":
			out["type"] = TYPE_COMMAND
			out["message"] = text
			return out
		"#", "@", "%", "&":
			if text.length() == 1:
				return out
			out["type"] = {"#": TYPE_PARTY, "@": TYPE_GUILD, "%": TYPE_UNION, "&": TYPE_ACADEMY}[first]
			out["message"] = text.substr(1)
			return out
		"$":
			var body := text.substr(1)
			var space := body.find(" ")
			if space <= 0:
				return out
			var target := body.substr(0, space)
			var message := body.substr(space + 1)
			if message == "":
				return out
			out["type"] = TYPE_WHISPER
			out["target"] = target
			out["message"] = message
			return out
	out["type"] = TYPE_ALL_GM if gm else TYPE_ALL
	out["message"] = text
	return out

## The line the input box holds after `sent` went out (0x7add04..0x7ade70):
## empty after ordinary chat or a global, ";" after a GM's ";" line, the
## whisper's "$name " again, the channel's own mark after a channel line --
## and then, on any tab but All, that tab's mark instead.
static func line_after_send(sent: Dictionary, tab: int) -> String:
	var t := ""
	match int(sent.get("type", TYPE_ALL)):
		TYPE_ALL_GM:
			t = ";" if String(sent.get("message", "")).begins_with(";") else ""
		TYPE_WHISPER:
			t = "$%s " % String(sent.get("target", ""))
		TYPE_PARTY:
			t = "#"
		TYPE_GUILD:
			t = "@"
		TYPE_UNION:
			t = "%"
		TYPE_ACADEMY:
			t = "&"
	if tab >= 1 and tab < TAB_PREFIX.size():
		t = TAB_PREFIX[tab]
	return t

## Enter in the line (round 606): an empty box ends the input -- 0x7ad400's
## length test at 0x7ad544 gives the focus back to the game (0x7a9a40); a
## line of spaces is not empty (no trim) and is sent. A line with only a
## channel mark, or a whisper with no text, ends the input the same way
## without sending (0x7ad7e2). A line that goes out leaves the box focused
## with the line line_after_send gives. Escape ends the input too (0x7ad4dd;
## LineEdit releases its focus on ui_cancel). The flood block (0x7a9bb0 after
## four lines in 4 s or six in 10 s) is not built.
func _on_submitted(text: String) -> void:
	if text == "":
		_input.release_focus()
		return
	var parsed := parse_line(text, is_gm)
	var type := int(parsed["type"])
	if type == TYPE_INCOMPLETE:
		_input.release_focus()
		return
	# 0x7ad400 refuses a party, guild or academy line itself when the player
	# is in no such group (0x987070 / 0x9870e0 / 0x987140), shows the refusal
	# (0x7781b0) and empties the box (SetText "" at 0x7ad875).
	if type in [TYPE_PARTY, TYPE_GUILD, TYPE_ACADEMY] and group_check.is_valid() \
			and not bool(group_check.call(type)):
		_system_line(REFUSAL_TYPE_GROUP, group_refusal(type))
		_input.text = ""
		return
	_input.clear()
	message_submitted.emit(text)
	var after := "" if type == TYPE_COMMAND else line_after_send(parsed, _tab)
	if type == TYPE_COMMAND and _tab >= 1:
		after = TAB_PREFIX[_tab]
	_input.text = after
	_input.caret_column = after.length()

## The request for a chat line World3D sends (OpChatSend), with the index the
## server's answer carries back; {} for a command or a line that is not sent.
## The line is kept until that answer (on_result).
func request_for(text: String) -> Dictionary:
	var parsed := parse_line(text, is_gm)
	var type := int(parsed["type"])
	if type == TYPE_INCOMPLETE or type == TYPE_COMMAND:
		return {}
	# Round 844: a union line carries "-<own guild>): " before its text
	# (0x7ada5a, L"-%s): "), which every reader shows after "name(Union".
	if type == TYPE_UNION and union_guild.is_valid():
		parsed["message"] = "-%s): %s" % [String(union_guild.call()), String(parsed["message"])]
	_next_index = (_next_index % 255) + 1
	parsed["index"] = _next_index
	_pending[_next_index] = parsed
	return parsed

## The server's answer to a sent line (0xB025, 0x877340): on success the
## player's own line appears -- their name, or the whisper's target read
## "(TO)" -- and on failure the refusal, in the client's own words.
func on_result(ok: bool, type: int, index: int, code: int, target: String) -> void:
	var sent: Dictionary = _pending.get(index, {})
	_pending.erase(index)
	if ok:
		if sent.is_empty():
			return
		var t := int(sent["type"])
		if t == TYPE_WHISPER:
			add_chat(t, String(sent["target"]), String(sent["message"]), true)
		else:
			add_chat(t, own_name, String(sent["message"]), true)
		return
	var line := refusal_text(code, target if target != "" else String(sent.get("target", "")))
	if line != "":
		_system_line(REFUSAL_TYPE_RESULT, line)

## A 0x7781b0 line: to the system window when there is one.
func _system_line(type: int, text: String) -> void:
	if system_sink.is_valid():
		system_sink.call(type, text)
	else:
		add_message("", text, argb(REFUSAL_COLOR))

## The line 0x7ad400 shows for a channel line with no group behind it.
func group_refusal(type: int) -> String:
	match type:
		TYPE_PARTY:
			return _text("UIIT_MSG_PARTYERR_CANT_FIND_PARTY", "Cannot find the corresponding party.")
		TYPE_GUILD:
			return _text("UIIT_MSG_GUILD_NON_EXISTING",
				"Cannot carry this function out because you do not belong to the guild.")
		TYPE_ACADEMY:
			return _text("UIIT_MSG_TC_ERROR_NOT_POSITION", "You do not belong to an Academy.")
	return ""

## The refusal line for a result code (0x877340's switch; the guild and
## academy ones are 0x7ad400's own client-side refusals, which OpenSRO's
## server answers -- see server/internal/session/chat.go).
func refusal_text(code: int, target: String) -> String:
	match code:
		0x0003:
			return _text("UIIT_CHATERR_CANT_FIND_TARGET", "Cannot find [%s].").replace("%s", target)
		0x2006:
			return _text("UIIT_CHATERR_YOU_ARE_SQUELCHED", "[%s]'s whisper function is turn off.").replace("%s", target)
		0x2008:
			return _text("UIIT_CHATERR_INVALID_COMMAND", "Invalid chat command.")
		0x200a:
			return _text("UIIT_CHATERR_NOT_A_PARTY_MEMBER", "Not in the party status.")
		0x200b, 0x200c:
			return _text("UIIT_CHATERR_ALLIANCE_PERMISSION_DENIED",
				"Cannot use the Ally Chat because the selected guild is not your ally.")
		0x200d:
			return _text("UIIT_STT_CANT_CHATTING", "Chat Restricted: %d seconds").replace("%d", "10")
		0x200e:
			return _text("UIIT_MSG_GUILD_UNION_CHAT_LIMIT", "You do not have union chatting authority, so you cannot chat.")
		0xf001:
			return group_refusal(TYPE_GUILD)
		0xf002:
			return group_refusal(TYPE_ACADEMY)
		0xf003:
			return "No global chatting item in that slot."
	return ""

## Whether the player is typing, so the world should not treat their keys as
## movement.
func is_typing() -> bool:
	return _input != null and _input.has_focus() and _input.is_visible_in_tree()

## Puts the caret in the input line, for the Enter-to-chat convention.
##
## With the frame auto-hidden the line is hidden too; retail gives it the
## focus anyway (0x7a9a70 -> 0xb9d9f0) and the next update shows the frame
## because the line holds the keyboard (0x7a9d10). Godot will not focus a
## hidden control, so the frame is shown first -- the same frame, one update
## early.
func focus_input() -> void:
	if _input == null:
		return
	if not frame_shown:
		set_frame_shown(true)
	_input.grab_focus()

## Whether Enter or R can open the line: the window is on screen, whether or
## not its frame is auto-hidden.
func can_open() -> bool:
	return _input != null and is_visible_in_tree()

## R's reply (round 608, KeyMap.reply_line): the input line opened with
## `text` in it and the caret after it. False when there is no line to open
## (not built, or the chat hidden), as Enter opens nothing then.
func open_with(text: String) -> bool:
	if not can_open():
		return false
	_input.text = text
	focus_input()
	_input.caret_column = text.length()
	return true

## The input line's current text (tests, the QA dump).
func input_text() -> String:
	return _input.text if _input != null else ""

## Enter with no text line holding the keyboard opens the chat line (round
## 606), read from the client's in-game key handler 0x78b660: a key the key
## table does not bind (0x778310 returns -1) that is 0x0d first offers the
## focus to the window at DAT_00eed374 (0x537ce0: if it is shown, its +0x370
## gets the focus; which window that is was not identified, and this client
## builds nothing for it), and otherwise fetches the interface's child 1,
## GDR_CHAT_BOARD (0x8b51f0 with 1), and gives the focus to its +0x4a0
## (0x7a9a70 -> 0xb9d9f0) -- GetChild(0x0b) in CIFChatViewer::Create
## (0x7abc6f..0x7abc7a), ifchatviewer.txt's GDR_CHAT_INPUTBOX (id 11). Two
## gates come first in 0x78b660 and are not built here: the interface's
## +0x7ba == 1 drops every key, and +0x7ec != 0 hands the key to 0x78ae00,
## which acts on Escape only (neither state identified).
##
## **Ours:** an Enter with Shift, Ctrl, Alt or Meta held does not open the
## line (the client tests only the key code, 0x0d). And a focused button does
## not keep Enter: measured (round 606's review, Godot 4.2.2, push_input), a
## FOCUS_ALL TextureButton in the default release action mode leaves Enter's
## press unhandled and fires on its release, so this handler takes the press,
## the focus moves to the line, and the button never fires -- after a click on
## a UiBuilder button (the popup's panes, storage, exchange), Enter opens the
## chat instead of pressing the button again, which is what the client does
## (it has no keyboard focus on buttons). A focused text line does keep it
## (LineEdit submits on the press). Not while the chat is hidden.
func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo or key.ctrl_pressed or key.alt_pressed \
			or key.shift_pressed or key.meta_pressed:
		return
	if key.keycode != KEY_ENTER and key.keycode != KEY_KP_ENTER:
		return
	if not can_open():
		return
	focus_input()
	get_viewport().set_input_as_handled()


## One message list: CIFTextBox's lines, laid out the way 0x64e930 lays them
## out -- each message wrapped to the box's width, every continuation line
## starting with as many spaces as fit in WRAP_INDENT_PX -- and drawn from the
## scroll position down, one line per font height, with a one-pixel shadow.
class ChatList extends Control:
	signal changed

	var font: Font
	var font_size := 12
	## The messages, oldest first: {text, color}.
	var messages: Array = []
	## The wrapped lines drawn, oldest first: {text, color}.
	var lines: Array = []
	## The first line drawn (the scroll position).
	var first := 0
	## The rows the list shows (+0x3a4, the mode's m * 4).
	var rows := HudChat.MODE_DEFAULT * HudChat.ROWS_PER_MODE:
		set(v):
			var follow := at_bottom()
			rows = maxi(1, v)
			first = max_first() if follow else clampi(first, 0, max_first())
			queue_redraw()
			changed.emit()
	## The row under the mouse, or -1 (0x63ad10 sets it on a mouse move).
	var hover := -1
	## Whether the hover bar is drawn: the chat's Create sets its colour
	## (0x638cf0); the system window's (0x7bc150) does not (round 639).
	var hover_enabled := true
	## Lines kept (+0x3a0): 100 in both the chat and the system window.
	var max_lines := HudChat.MAX_LINES
	## +0x3a8, lines stacked from the bottom (0x638b50(1)); the chat and the
	## system window set it. The exchange's log does not (round 836, READ:
	## its Create calls only 0x638c20(0xe) and 0x638d30(1), c:0x7b29ed..),
	## so its lines start at the top.
	var stack_from_bottom := true
	## The hanging indent of a continuation line (0x64e380(1)); off for the
	## exchange's log, which does not set it.
	var hanging_indent := true
	var _laid_width := -1.0

	# Text and the untextured hover bar only: glyphs drawn unfiltered, as
	# every text node is (UiBuilder.crisp_text, round 672).
	func _init() -> void:
		set_meta(UiBuilder.TEXT_NODE_META, true)
		UiBuilder.crisp_text(self)

	func _ready() -> void:
		mouse_exited.connect(func() -> void:
			hover = -1
			queue_redraw())

	func line_height() -> float:
		return float(HudChat.LINE_PITCH)

	func visible_lines() -> int:
		return rows

	func max_first() -> int:
		return maxi(0, lines.size() - visible_lines())

	func at_bottom() -> bool:
		return first >= max_first()

	## Where the first drawn line's top sits: with fewer lines than rows they
	## stack from the bottom -- 0x639ab0 adds pitch * (rows - count) when
	## +0x3a8 is set (0x639d20..0x639d52), which Create sets (0x638b50(1) at
	## 0x7abeee).
	func top_offset() -> float:
		var n := lines.size()
		return line_height() * float(rows - n) if n < rows and stack_from_bottom else 0.0

	## The line under local y, or -1 (0x63ad10's row: (y - top) / pitch,
	## shifted for the bottom stacking, plus the scroll position).
	func line_at(y: float) -> int:
		var rel := y - top_offset()
		if rel < 0.0:
			return -1
		var row := int(floor(rel / line_height()))
		if row >= rows:
			return -1
		var idx := first + row
		return idx if idx < lines.size() else -1

	func set_first(pos: int) -> void:
		var clamped := clampi(pos, 0, max_first())
		if clamped != first:
			first = clamped
			queue_redraw()
		changed.emit()

	func scroll_to_bottom() -> void:
		first = max_first()
		queue_redraw()
		changed.emit()

	## Every line gone (round 836: the exchange's log at each new exchange).
	func clear() -> void:
		messages.clear()
		lines.clear()
		first = 0
		queue_redraw()
		changed.emit()

	func add_line(text: String, color: Color) -> void:
		var follow := at_bottom()
		messages.append({"text": text, "color": color})
		while messages.size() > max_lines:
			messages.pop_front()
		_relayout()
		if follow:
			first = max_first()
		else:
			first = clampi(first, 0, max_first())
		queue_redraw()
		changed.emit()

	func _notification(what: int) -> void:
		if what == NOTIFICATION_RESIZED and size.x != _laid_width:
			var follow := at_bottom()
			_relayout()
			first = max_first() if follow else clampi(first, 0, max_first())
			queue_redraw()
			changed.emit()

	func _gui_input(event: InputEvent) -> void:
		var mm := event as InputEventMouseMotion
		if mm != null and hover_enabled:
			var h := line_at(mm.position.y)
			if h != hover:
				hover = h
				queue_redraw()

	func _relayout() -> void:
		_laid_width = size.x
		lines.clear()
		for m in messages:
			for l in HudChat.wrap(String(m["text"]), font, font_size, size.x, hanging_indent):
				lines.append({"text": l, "color": m["color"]})

	func _draw() -> void:
		if font == null:
			return
		var h := line_height()
		var ascent := font.get_ascent(font_size)
		var y0 := top_offset()
		for i in visible_lines():
			var idx := first + i
			if idx >= lines.size():
				break
			var l: Dictionary = lines[idx]
			var top := y0 + i * h
			if idx == hover:
				# The bar is the line's text height (+0x384 unset: 0x639ab0
				# takes the extent's height, not the pitch).
				draw_rect(Rect2(0, top, size.x, font.get_height(font_size)), HudChat.argb(HudChat.HOVER_COLOR))
			var at := Vector2(0, top + ascent)
			draw_string(font, at + HudChat.SHADOW_OFFSET, String(l["text"]), HORIZONTAL_ALIGNMENT_LEFT, -1,
				font_size, Color(0, 0, 0, (l["color"] as Color).a))
			draw_string(font, at, String(l["text"]), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, l["color"])

## Splits one message into the lines 0x64e930 draws: as much as fits in
## `width`, broken at a space where there is one (MEASURED from the retail
## screenshot: every wrapped line there breaks between words); a
## continuation line starts with floor(20 / space width) spaces (at least
## one) and has that much less room.
static func wrap(text: String, font: Font, font_size: int, width: float, indent_lines: bool = true) -> PackedStringArray:
	var out := PackedStringArray()
	if font == null or width <= 0.0:
		out.append(text)
		return out
	var space_w := font.get_string_size(" ", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var indent_n := maxi(1, int(WRAP_INDENT_PX / space_w)) if space_w > 0.0 else 1
	var indent := " ".repeat(indent_n) if indent_lines else ""
	var rest := text
	var first_line := true
	while true:
		var prefix := "" if first_line else indent
		var line := prefix + rest
		if font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x <= width:
			out.append(line)
			break
		# The longest head of `rest` that fits after the prefix.
		var lo := 1
		var hi := rest.length()
		while lo < hi:
			var mid := (lo + hi + 1) / 2
			if font.get_string_size(prefix + rest.substr(0, mid), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x <= width:
				lo = mid
			else:
				hi = mid - 1
		var cut := lo
		var brk := rest.substr(0, cut + 1).rfind(" ")
		if brk > 0:
			out.append(prefix + rest.substr(0, brk))
			rest = rest.substr(brk + 1)
		else:
			out.append(prefix + rest.substr(0, cut))
			rest = rest.substr(cut)
		first_line = false
		if rest == "":
			break
	return out


## One tab: `chat_long_tab.ddj` stretched over 71x20 with its caption
## centred on it (the centring is MEASURED from the retail screenshot), bold
## and white while selected (0x64cc30(1), text state 0), grey 0xffb4b4b4
## otherwise (text state 3, 0x8b4750(3)).
class ChatTab extends Control:
	signal pressed

	var texture: Texture2D
	var caption := ""
	var font: Font
	var bold_font: Font
	var font_size := 12
	var selected := false:
		set(v):
			selected = v
			queue_redraw()

	## The caption, drawn on its own unfiltered layer over the tab's art
	## (UiBuilder.TextLayer, round 672).
	var _text_layer: UiBuilder.TextLayer

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		_text_layer = UiBuilder.TextLayer.new(_draw_caption)
		add_child(_text_layer)

	func _draw() -> void:
		if texture != null:
			draw_texture_rect(texture, Rect2(Vector2.ZERO, size), false)
		if _text_layer != null:
			_text_layer.queue_redraw()

	func _draw_caption(on: CanvasItem) -> void:
		var f := bold_font if selected and bold_font != null else font
		if f == null or caption == "":
			return
		var w := f.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		var y := (size.y - f.get_height(font_size)) / 2.0 + f.get_ascent(font_size)
		on.draw_string(f, Vector2(round((size.x - w) / 2.0), round(y)), caption, HORIZONTAL_ALIGNMENT_LEFT, -1,
			font_size, text_color())

	func text_color() -> Color:
		return HudChat.argb(HudChat.TAB_TEXT_SELECTED if selected else HudChat.TAB_TEXT_UNSELECTED)

	func _gui_input(event: InputEvent) -> void:
		var mb := event as InputEventMouseButton
		if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			pressed.emit()
			accept_event()


## The chat's scroll bar: up arrow, the bar, the 16x16 thumb, the down arrow,
## top to bottom, positioned as 0x65a390 and 0x659150 place them.
class ChatScroll extends Control:
	signal moved(pos: int)

	var up_texture: Texture2D
	var down_texture: Texture2D
	var bar_texture: Texture2D
	var thumb_texture: Texture2D
	var length := 308.0
	var maximum := 0
	var pos := 0
	var _dragging := false
	var _drag_dy := 0.0

	const B := 16.0

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP

	func set_range(max_pos: int, at: int) -> void:
		maximum = maxi(0, max_pos)
		pos = clampi(at, 0, maximum)
		queue_redraw()

	## The thumb's top, relative to this control (0x659150: the thumb moves
	## (pos - min) * length / (max - min) below the bar's top).
	func thumb_y() -> float:
		var off := 0.0
		if maximum > 0:
			off = floor(float(pos) * length / float(maximum))
		return B + off

	func down_y() -> float:
		return B + length + B

	func _draw() -> void:
		if bar_texture != null:
			draw_texture_rect(bar_texture, Rect2(0, B, B, length + B), false)
		if up_texture != null:
			draw_texture_rect(up_texture, Rect2(0, 0, B, B), false)
		if thumb_texture != null:
			draw_texture_rect(thumb_texture, Rect2(0, thumb_y(), B, B), false)
		if down_texture != null:
			draw_texture_rect(down_texture, Rect2(0, down_y(), B, B), false)

	func _step(delta: int) -> void:
		var np := clampi(pos + delta, 0, maximum)
		if np != pos:
			pos = np
			queue_redraw()
		moved.emit(pos)

	func _pos_for_thumb_top(y: float) -> int:
		if maximum <= 0:
			return 0
		return clampi(int(round((y - B) * float(maximum) / length)), 0, maximum)

	## The arrows step one line (0x6592a0's step 1). A click on the bar jumps
	## the thumb there and starts a drag (OURS: the bar's own click was not
	## read).
	func _gui_input(event: InputEvent) -> void:
		var mb := event as InputEventMouseButton
		if mb != null and mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				var y := mb.position.y
				if y < B:
					_step(-1)
				elif y >= down_y():
					_step(1)
				else:
					var ty := thumb_y()
					_drag_dy = y - ty if (y >= ty and y < ty + B) else B / 2.0
					_dragging = true
					var np := _pos_for_thumb_top(y - _drag_dy)
					if np != pos:
						pos = np
						queue_redraw()
						moved.emit(pos)
			else:
				_dragging = false
			accept_event()
			return
		var mm := event as InputEventMouseMotion
		if mm != null and _dragging:
			var np := _pos_for_thumb_top(mm.position.y - _drag_dy)
			if np != pos:
				pos = np
				queue_redraw()
				moved.emit(pos)
			accept_event()
			return
		if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_step(-1)
			accept_event()
		elif mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_step(1)
			accept_event()
