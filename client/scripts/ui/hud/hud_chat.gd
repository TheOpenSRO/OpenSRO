extends Control
class_name HudChat

## The in-world chat window, built from `resinfo\ifchatviewer.txt`.
##
## The registry places it bottom-left: `GDR_CHAT_BOARD` is a `CIFChatViewer`
## at `0,546,399,398` in the registry's own 1600x1200 reference screen. The
## width and height are the window's; the corner it sits in is what the
## anchor below reproduces, the same way the underbar's horizontal centring
## is authored and its flush-to-the-bottom is a choice.
##
## The layout gives the whole window:
##
##   GDR_CHAT_BG_UP/_MID/_DOWN   three bands of `chat_window.ddj`, sliced by
##                               UV into thirds and stretched -- a 3-slice
##   GDR_LIST_CHATTING           the message area, 365x343 at 27,28, with
##                               four more text boxes stacked on the same
##                               rect for the party, guild, alliance and
##                               apprentice channels
##   GDR_STATIC_*LAMP            the per-channel tab lamps along the top
##   GDR_CHAT_INPUTBOX           the input line, 360x20 at 38,378
##   GDR_CHAT_MODE_BTN           the channel selector left of it, 20x20 at
##                               18,378
##
## Only the "all" channel is wired to anything: the server has one chat
## stream and one whisper stream, and the other four tabs would be empty
## rather than filtered.
##
## **One list at a time, the "all" one first** (round 585,
## docs/RE_COMPLETION.md). CIFChatViewer::Create (0x7ab920) fetches the five
## lists -- IDs 16 (all), 17 (party), 18 (guild), 19 (alliance) and 30
## (apprentice) -- and its loop at 0x7abe80..0x7abf4b shows the first and
## hides the other four; a tab switch (0x7aa690) hides all five and shows
## the selected one. The tabs are built in code and this client has none, so
## the four are hidden and stay hidden (HIDDEN_LISTS).
##
## **Read with UI_UPDATE_2009_FIRST defined.** The same Create fetches IDs
## 30, 31, 41 and 42, which the layout declares only under
## `#ifdef UI_UPDATE_2009_FIRST`, and calls on each without a null check --
## the child fetch returns 0 for an ID the layout lacks, so a build reading
## the other branch would crash there. That is inferred from the code, not
## read from a define table (the client's own table, at 0xeed4e0, is
## consulted by 0x5004a0 and referenced by nothing else in the file). The
## define's one visible effect here is the input line's rect: the `#else`
## branch puts it at 18,378,381,20, under the mode button.

const UiBuilder = preload("res://scripts/ui/ui_builder.gd")
const UiLayoutParser = preload("res://scripts/ui/ui_layout_parser.gd")

## Emitted when the player presses Enter on a non-empty input line.
signal message_submitted(text: String)

const LAYOUT_PATH := "resinfo\\ifchatviewer.txt"
const REGISTRY_NAME := "GDR_CHAT_BOARD"
const LAYOUT_DEFINES := ["UI_UPDATE_2009_FIRST"]
## The channel lists Create hides; see the header.
const HIDDEN_LISTS := ["GDR_LIST_CHATPARTY", "GDR_LIST_CHATGUILD",
	"GDR_LIST_CHATALLIACNE", "GDR_LIST_APPRENTICE"]

## Fallback size if the registry is unreadable; the registry's own is used
## when it is there.
const SIZE_WIDTH := 399.0
const SIZE_HEIGHT := 398.0

## How many lines the message area keeps. The window shows about twenty at
## the authored 343-pixel height and a 12-pixel line, and holding a few
## screens of history is what makes the scrollback worth having.
const MAX_LINES := 200

var _builder: UiBuilder
var _messages: RichTextLabel
var _input: LineEdit

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
	# so the input line and the buttons still work. STOP, as HudWindow uses
	# (its comment has the reasoning): Godot hit-tests the deepest control
	# first, so the input line and the mode button still get their clicks,
	# and STOP only catches what they did not want. This was PASS, which
	# delivers the click here AND keeps propagating it, so a click on the
	# scrollback or the frame reached World3D._unhandled_input: it walked the
	# character, and since round 522 it also took the chat line's focus away
	# mid-message (take_focus_back; measured by round 522's review).
	mouse_filter = Control.MOUSE_FILTER_STOP

	if _builder == null:
		return
	var layout := _builder.load_layout(LAYOUT_PATH, PackedStringArray(LAYOUT_DEFINES), true)
	if layout == null:
		return
	var root := _builder.build_section(layout, "Create")
	if root == null:
		return
	add_child(root)
	UiBuilder.settle_authored_rects(root)

	# The whisper list is authored *above* the window (y=-152) and is a
	# pop-up, not part of the resting window. Hidden until there is
	# something to put in it.
	var whisper := root.get_node_or_null("GDR_WHISPERLIST")
	if whisper is CanvasItem:
		(whisper as CanvasItem).visible = false
	for list_name in HIDDEN_LISTS:
		var list := root.get_node_or_null(list_name)
		if list is CanvasItem:
			(list as CanvasItem).visible = false

	_install_message_area(root)
	_install_input(root)

## Replaces the authored message box with a scrolling text view at exactly
## its rect.
##
## `GDR_LIST_CHATTING` is a `CIFTextBox`, which UiBuilder builds as a plain
## container -- the control is a scrolling list of styled lines and there is
## no Godot node that is one. A RichTextLabel in its place keeps the
## authored geometry and gains the scrollback.
func _install_message_area(root: Control) -> void:
	var box := root.get_node_or_null("GDR_LIST_CHATTING") as Control
	if box == null:
		return
	_messages = RichTextLabel.new()
	_messages.name = "Messages"
	_messages.bbcode_enabled = true
	_messages.scroll_following = true
	_messages.fit_content = false
	_messages.set_anchors_preset(Control.PRESET_FULL_RECT)
	_messages.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _builder != null:
		var font := _builder.font_at(0)
		if font != null:
			_messages.add_theme_font_override("normal_font", font)
		_messages.add_theme_font_size_override("normal_font_size", UiBuilder.FONT_SIZES[0])
	box.add_child(_messages)

## Puts a real editable line over the authored input box.
##
## `GDR_CHAT_INPUTBOX` is a `CIFEInputChatBox` carrying an atlas slice of
## `window_all.ddj` for its own background, which UiBuilder already draws.
## What it needs is somewhere to type.
func _install_input(root: Control) -> void:
	var box := root.get_node_or_null("GDR_CHAT_INPUTBOX") as Control
	if box == null:
		return
	_input = LineEdit.new()
	_input.name = "Input"
	_input.set_anchors_preset(Control.PRESET_FULL_RECT)
	_input.flat = true
	_input.caret_blink = true
	if _builder != null:
		var font := _builder.font_at(0)
		if font != null:
			_input.add_theme_font_override("font", font)
		_input.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[0])
	_input.text_submitted.connect(_on_submitted)
	box.add_child(_input)

## Enter in the line (round 606). The client's key handler for its input box
## (0x7ad400, CIFChatViewer's; the viewer's own caller at 0x7af463 feeds it
## 0x0d after setting the box's text through vslot 0xb4) reads the box's text
## and, when it is empty (the length test at 0x7ad544, `je 0x7ad598`), ends
## the input: 0x7a9a40 gives the Win32 focus back to the main window
## (SetFocus) and moves the UI focus to the viewer's +0x30 (0xb9d9f0; that
## +0x30 is its parent is **inferred**). The test is on the raw text: vslot
## 0xb8 (0x634da0) returns the box's buffer and 0x46e3d0 copies it by its
## wcslen, with no trim (traced by round 606's review), so a line of spaces is
## not empty -- it takes the send path like any other line, and is sent as
## typed here too. A line with text is sent. In the handler 0x7a9a40 is
## called at only three places (0x7ad4dd, 0x7ad59a, 0x7ad7e4): Escape, the
## empty line, and, from 0x7ad7d3 and 0x7ad82e, a mode-2 line missing one of
## the two parts 0x7ab230 parses out and a line of length 1 in the modes that
## reach 0x7ad826 (what those modes and lines are was not read). So after a
## line is sent the box keeps the focus, as this LineEdit does. Escape in the
## box ends the input too (0x7ad4dd); Godot's LineEdit already releases its
## focus on ui_cancel and consumes the key. The client's flood block (a
## fourth way the input ends, docs/RE_COMPLETION.md round 606) is not built.
func _on_submitted(text: String) -> void:
	_input.clear()
	if text == "":
		_input.release_focus()
		return
	message_submitted.emit(text)

## Adds one line. `speaker` empty makes it a system line.
func add_message(speaker: String, text: String) -> void:
	if _messages == null:
		return
	var line := text
	if speaker != "":
		line = "%s: %s" % [speaker, text]
	_messages.append_text(line + "\n")
	_trim()

## Adds a whisper, which the client shows apart from open chat.
func add_whisper(speaker: String, text: String) -> void:
	add_message("[%s]" % speaker, text)

func _trim() -> void:
	if _messages == null:
		return
	while _messages.get_line_count() > MAX_LINES and _messages.get_paragraph_count() > 0:
		_messages.remove_paragraph(0)

## Whether the player is typing, so the world should not treat their keys as
## movement.
func is_typing() -> bool:
	return _input != null and _input.has_focus()

## Puts the caret in the input line, for the Enter-to-chat convention.
func focus_input() -> void:
	if _input != null:
		_input.grab_focus()

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
	if _input == null or not _input.is_visible_in_tree():
		return
	focus_input()
	get_viewport().set_input_as_handled()
