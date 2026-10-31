class_name CifEditStyle
extends RefCounted

## What a Godot LineEdit needs so it behaves and draws as the client's
## CIFEdit (round 848), applied to an edit after it is built (the front
## end's own edits, and the archive edits UiBuilder makes for its windows).
## A new file rather than a change to UiBuilder._build_edit because that file
## is another lane's this round; the rules are the class's, so any edit can
## take them.
##
## READ from sro_client.exe (round 848's research, CIFEdit, vtable 0xd9ae3c):
## - **The caret** (draw, slot 13 0x637b70): a quad 2.0 px wide (the double at
##   0xe1b898) and the font's height + 2.0 tall, in the edit's current text
##   colour (+0xa0, the text object's +0x10 -- the layout's FontColor), its
##   left edge at the end of the last character's advance. It blinks 200 ms
##   on, 200 ms off: OnCreate (0x637a60) sets the CETime at +0x388 to rate 5
##   (FUN_00ba9aa0(5), 1000 / 5 ms), and the per-frame update (slot 12,
##   0x635530) flips the blink byte +0x3ec on each tick. It shows only while
##   the edit has the focus (FUN_00634ea0) and flag 0x20 is clear.
## - **No selection.** A left click (slot 17 0x637290, WM_LBUTTONDOWN at
##   0x6378a5) only focuses the edit: it never places the caret and never
##   starts a selection; mouse moves select nothing; Left / Right move the
##   caret one character with or without Shift. The one "selected" state is
##   the whole text (byte +0x41a, 0x635030), set by a dialog's code to
##   pre-select a value, drawn on 0xff3b457a; no front-end edit sets it.
## - **No clipboard but paste, and paste only where a flag allows it.** The
##   exe imports no SetClipboardData: nothing copies. Ctrl+A / C / X / Z are
##   swallowed (the WndProc's Ctrl table at 0x63723c), Shift+Insert always
##   (0x636f9a), and Ctrl+V pastes only with flag 0x200 (0x636e61) -- set on
##   the console's edit alone (0x541718). The login ID (flags 0x2), password
##   (0xa), chat and every front-end edit refuse paste.
## - **No context menu.** A right click (0x637935) only takes the focus away
##   when it lands outside the box; WM_CONTEXTMENU is not handled.
## - **Up / Down do nothing** (slot 17's key cases).
## - **The length**: +0x400, 0x200 = 512 characters unless code sets another
##   (the constructor's default; CPSTitle sets none on its two edits).
##
## So in Godot: no context menu, no shortcut keys (they are Godot's copy, cut,
## paste, undo, redo and select-all), no middle-click paste, no emoji picker,
## no selecting, a click that only focuses, Up / Down kept in the edit, and
## the caret 2 px wide, in the font's colour, blinking every 0.2 s.
##
## Not reproduced (Godot draws its own caret): its height is Godot's line
## height rather than the font height + 2, and Godot shows the caret again
## when a key is typed where the client keeps the blink's phase.

## READ (0xe1b898): the caret's width.
const CARET_WIDTH := 2
## READ (FUN_00ba9aa0(5)): each half of the blink, in seconds.
const BLINK_S := 0.2
## READ (0x635030): the whole-text "selected" background.
const SELECTED_BG := Color8(0x3b, 0x45, 0x7a, 0xff)
## READ (+0x400's default, the constructor): the character limit.
const DEFAULT_MAX_LENGTH := 0x200
const _APPLIED_META := &"cif_edit_style"

## Applies the rules to `edit`. `font_color` is the layout's FontColor (the
## caret's colour); null takes the edit's own font colour. `max_length` 0
## keeps the edit's own limit (or sets DEFAULT_MAX_LENGTH when it has none).
static func apply(edit: LineEdit, font_color: Variant = null, max_length: int = 0) -> void:
	if edit == null:
		return
	edit.context_menu_enabled = false
	edit.shortcut_keys_enabled = false
	edit.middle_mouse_paste_enabled = false
	edit.selecting_enabled = false
	edit.drag_and_drop_selection_enabled = false
	edit.clear_button_enabled = false
	if "emoji_menu_enabled" in edit:
		edit.set("emoji_menu_enabled", false)
	edit.caret_blink = true
	edit.caret_blink_interval = BLINK_S
	var colour: Color = font_color if font_color is Color else edit.get_theme_color(&"font_color")
	edit.add_theme_color_override(&"caret_color", colour)
	edit.add_theme_constant_override(&"caret_width", CARET_WIDTH)
	edit.add_theme_color_override(&"selection_color", SELECTED_BG)
	edit.add_theme_color_override(&"font_selected_color", colour)
	if max_length > 0:
		edit.max_length = max_length
	elif edit.max_length <= 0:
		edit.max_length = DEFAULT_MAX_LENGTH
	# Up / Down stay in the edit (Godot would move the focus to the nearest
	# control above or below).
	edit.focus_neighbor_top = NodePath(".")
	edit.focus_neighbor_bottom = NodePath(".")
	if not edit.has_meta(_APPLIED_META):
		edit.set_meta(_APPLIED_META, true)
		edit.gui_input.connect(_on_gui_input.bind(edit))

## A click focuses the edit and does nothing else (READ, above).
static func _on_gui_input(event: InputEvent, edit: LineEdit) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN \
			or mb.button_index == MOUSE_BUTTON_WHEEL_LEFT or mb.button_index == MOUSE_BUTTON_WHEEL_RIGHT:
		return
	edit.accept_event()
	if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT and edit.editable \
			and edit.focus_mode != Control.FOCUS_NONE:
		if not edit.has_focus():
			edit.grab_focus()
		# Godot 4.4+: a focused LineEdit types only while it is editing.
		if edit.has_method(&"edit") and edit.has_method(&"is_editing") and not edit.call(&"is_editing"):
			edit.call(&"edit")

## Whether `edit` has had the rules applied (tests).
static func applied(edit: LineEdit) -> bool:
	return edit != null and edit.has_meta(_APPLIED_META)
