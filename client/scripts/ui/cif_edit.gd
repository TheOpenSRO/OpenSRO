extends LineEdit
class_name CifEdit

## The client's text edit, `CIFEdit` (and `CIFEInputChatBox`, which shares its
## draw and message handlers), as a LineEdit with Godot's own behaviour taken
## away where the original has none (round 848, lane H). Every address is
## sro_client.exe's. Labels: READ (from the binary), INFERRED, OURS, OPEN.
##
## **How the original edits (READ).** CIFEdit keeps its own text buffer
## (`+0x5474`, at most 0x1000 characters: 0x6354e0 / 0x63748c) and caret
## (`+0x444`). Its Create (vslot_010, 0x637a60) makes a hidden Win32 EDIT at
## (-100, -100) only to own the keyboard focus and the IME, and subclasses it
## (0x637a30 -> 0x636cd0). The keys it acts on (0x637290, WM_KEYDOWN):
## End, Home, Left, Right (one character each, 0x635460) and Delete; and on
## WM_CHAR: Backspace, Enter, Tab / Escape (handed to the parent with style
## bit 2) and every character from 0x20 up. There is **no selection** of a
## range, **no word move or word delete**, and no mouse placement of the
## caret: a left press inside the edit only gives it the focus (0x637290
## case 0x201 -> 0xb9d9f0), outside it ends the input.
##
## **Ctrl (READ, 0x636cd0).** With Ctrl down, A, C, X and Z are swallowed (the
## proc returns 0). V pastes the clipboard at the caret only for an edit with
## style bit 0x200, and the one edit in the client that sets it is the
## developer console's (CIFConsole::vslot_023, `push 0x1302` at 0x54170b);
## every other edit swallows Ctrl+V too. Shift+Insert is swallowed.
##
## **The whole-text mark (READ).** Shift+Home or Shift+End sets the edit's
## mark (`+0x41a`, 0x635030(1)), which gives the text board the background
## colour 0xff3b457a (0x635044); Home, End, Left and Right clear it
## (0x635030(0)); Delete with the mark empties the edit (0x6354e0); a
## character or Backspace with the mark first empties it (0x635720). This is
## the LineEdit's select_all with that selection colour, the text keeping its
## own colour.
##
## **The caret (READ, the draw 0x637b70).** A quad from the caret's x to x +
## 2.0 (`0xe1b898`), in the edit's own FontColor (`+0xa0`), drawn while the
## blink flag `+0x3ec` is set, the edit has the focus (0x634ea0) and style
## bit 0x20 is clear. The flag starts clear (0x637b50) and flips each time
## the edit's CETime (`+0x388`, set to 5 per second by 0x637b3c ->
## 0xba9aa0(5): 1000 / 5 = 200 ms) ticks (0x635530). So the caret is 2 pixels
## wide, the text's colour, and blinks 200 ms on, 200 ms off. Its height is
## the font's tmHeight + 2.0 from the text's top; Godot draws its caret the
## line's height (ascent + descent) -- OPEN, measured in the round's frames.
##
## **Not built (OPEN):** the IME composition underline the draw adds
## (0x637b70, `0x468` / DAT_0110f9c8: dotted 0xff969696 or solid white); Godot
## draws its own IME underline.

## The caret's width (READ, the double at 0xe1b898).
const CARET_WIDTH := 2
## The caret's blink: the CETime at 5 Hz, a flip per tick (READ).
const CARET_BLINK_SEC := 0.2
## The whole-text mark's background (READ, 0x635044: 0xff3b457a).
const MARK_COLOUR := Color8(0x3b, 0x45, 0x7a)

var _colour := Color.WHITE

func _init() -> void:
	KeyInput.line_edit_as_42(self)  # round 754: Godot 4.4+ editing state
	context_menu_enabled = false
	shortcut_keys_enabled = false
	middle_mouse_paste_enabled = false
	drag_and_drop_selection_enabled = false
	if "emoji_menu_enabled" in self:
		set("emoji_menu_enabled", false)
	caret_blink = true
	caret_blink_interval = CARET_BLINK_SEC
	add_theme_constant_override("caret_width", CARET_WIDTH)
	add_theme_color_override("selection_color", MARK_COLOUR)
	set_colour(_colour)

## The edit's FontColor: its text, its caret and its marked text. Also the
## colour of an edit that does not take input (INFERRED: CIFEdit's draw has
## one text colour; Godot greys a read-only line) and of a layout's own text
## shown before anything is typed (OURS: Godot's placeholder is a faded grey;
## how CIFEdit shows a layout's Text was not read).
func set_colour(colour: Color) -> void:
	_colour = colour
	add_theme_color_override("font_color", colour)
	add_theme_color_override("caret_color", colour)
	add_theme_color_override("font_selected_color", colour)
	add_theme_color_override("font_uneditable_color", colour)
	add_theme_color_override("font_placeholder_color", colour)

func colour() -> Color:
	return _colour

## An existing LineEdit given the same look (a line this file did not make).
## Its behaviour stays Godot's.
static func style(edit: LineEdit, colour: Color) -> void:
	if edit == null:
		return
	if edit is CifEdit:
		(edit as CifEdit).set_colour(colour)
		return
	edit.context_menu_enabled = false
	edit.shortcut_keys_enabled = false
	edit.middle_mouse_paste_enabled = false
	edit.caret_blink = true
	edit.caret_blink_interval = CARET_BLINK_SEC
	edit.add_theme_constant_override("caret_width", CARET_WIDTH)
	edit.add_theme_color_override("selection_color", MARK_COLOUR)
	for c in ["font_color", "caret_color", "font_selected_color", "font_uneditable_color"]:
		edit.add_theme_color_override(c, colour)

## A multi-line CIFEdit (style bit 0x40: the draw's line offset 0x637d6a and
## the scroll 0x635070 makes) shown as a TextEdit, given the same rules as far
## as a TextEdit takes them: the caret, no selection, menu, shortcuts or
## middle-button paste, and a left press that only gives it the keyboard
## (accepted in the gui_input signal, which runs before TextEdit's own
## handling). Its scroll bar is not the original's (OPEN).
static func style_text_edit(edit: TextEdit, colour: Color) -> void:
	if edit == null:
		return
	edit.context_menu_enabled = false
	edit.shortcut_keys_enabled = false
	edit.selecting_enabled = false
	edit.middle_mouse_paste_enabled = false
	edit.drag_and_drop_selection_enabled = false
	if "emoji_menu_enabled" in edit:
		edit.set("emoji_menu_enabled", false)
	edit.caret_blink = true
	edit.caret_blink_interval = CARET_BLINK_SEC
	edit.highlight_current_line = false
	edit.highlight_all_occurrences = false
	edit.add_theme_constant_override("caret_width", CARET_WIDTH)
	for c in ["font_color", "caret_color", "font_readonly_color", "font_selected_color"]:
		edit.add_theme_color_override(c, colour)
	edit.add_theme_color_override("background_color", Color(0, 0, 0, 0))
	edit.gui_input.connect(func(event: InputEvent) -> void:
		var mb := event as InputEventMouseButton
		if mb != null and mb.button_index != MOUSE_BUTTON_WHEEL_UP and mb.button_index != MOUSE_BUTTON_WHEEL_DOWN:
			if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT and edit.editable and not edit.has_focus():
				edit.grab_focus()
			edit.accept_event()
		elif event is InputEventMouseMotion and (event as InputEventMouseMotion).button_mask != 0:
			edit.accept_event())

## The original's input rules, ahead of LineEdit's own (a handled event never
## reaches LineEdit: Control._call_gui_input).
func _gui_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb != null:
		# Every button: no caret placed, no range selected, no menu, no
		# middle-button paste. A left press gives the edit the keyboard.
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT and editable:
			take_keyboard()
		if mb.button_index != MOUSE_BUTTON_WHEEL_UP and mb.button_index != MOUSE_BUTTON_WHEEL_DOWN:
			accept_event()
		return
	if event is InputEventMouseMotion and (event as InputEventMouseMotion).button_mask != 0:
		accept_event()
		return
	var k := event as InputEventKey
	if k == null or not k.pressed:
		return
	if _key(k):
		accept_event()

## The keyboard to this edit, editing (a left press inside it).
func take_keyboard() -> void:
	if not has_focus():
		grab_focus()
	if has_method("edit") and has_method("is_editing") and not bool(call("is_editing")):
		call("edit")

## One key press: true when it is handled here (and so not by LineEdit).
func _key(k: InputEventKey) -> bool:
	var code := k.keycode
	var ctrl := k.ctrl_pressed or k.meta_pressed
	if ctrl and code in [KEY_A, KEY_C, KEY_X, KEY_Z, KEY_V, KEY_Y]:
		return true
	if k.shift_pressed and code == KEY_INSERT:
		return true
	if k.shift_pressed and (code == KEY_HOME or code == KEY_END):
		if text != "":
			select_all()
		return true
	match code:
		KEY_LEFT, KEY_RIGHT:
			# One character, with Shift or Ctrl too; the mark goes.
			var at := caret_column
			deselect()
			caret_column = clampi(at + (1 if code == KEY_RIGHT else -1), 0, text.length())
			return true
		KEY_HOME, KEY_END:
			deselect()
			caret_column = 0 if code == KEY_HOME else text.length()
			return true
		KEY_BACKSPACE, KEY_DELETE:
			if not editable:
				return true
			if has_selection():
				# The mark empties the edit (0x6354e0 / 0x635720).
				_replace_all("")
				return true
			if ctrl:
				# One character, not a word.
				var at := caret_column
				if code == KEY_BACKSPACE and at > 0:
					_replace_all(text.substr(0, at - 1) + text.substr(at), at - 1)
				elif code == KEY_DELETE and at < text.length():
					_replace_all(text.substr(0, at) + text.substr(at + 1), at)
				return true
	return false

func _replace_all(value: String, caret := 0) -> void:
	text = value
	caret_column = caret
	text_changed.emit(text)
