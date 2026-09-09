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
##   GDR_CHAT_INPUTBOX           the input line, 381x20 at 18,378
##   GDR_CHAT_MODE_BTN           the channel selector beside it
##
## Only the "all" channel is wired to anything: the server has one chat
## stream and one whisper stream, and the other four tabs would be empty
## rather than filtered. They are built and left as the layout draws them.

const UiBuilder = preload("res://scripts/ui/ui_builder.gd")
const UiLayoutParser = preload("res://scripts/ui/ui_layout_parser.gd")

## Emitted when the player presses Enter on a non-empty input line.
signal message_submitted(text: String)

const LAYOUT_PATH := "resinfo\\ifchatviewer.txt"
const REGISTRY_NAME := "GDR_CHAT_BOARD"

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
	# so the input line and the buttons still work. PASS rather than STOP
	# for the same reason a panel window uses it.
	mouse_filter = Control.MOUSE_FILTER_PASS

	if _builder == null:
		return
	var layout := _builder.load_layout(LAYOUT_PATH)
	if layout == null:
		return
	var root := _builder.build_section(layout, "Create")
	if root == null:
		return
	add_child(root)

	# The whisper list is authored *above* the window (y=-152) and is a
	# pop-up, not part of the resting window. Hidden until there is
	# something to put in it.
	var whisper := root.get_node_or_null("GDR_WHISPERLIST")
	if whisper is CanvasItem:
		(whisper as CanvasItem).visible = false

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

func _on_submitted(text: String) -> void:
	var trimmed := text.strip_edges()
	_input.clear()
	if trimmed == "":
		return
	message_submitted.emit(trimmed)

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
