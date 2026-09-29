extends HudWindow
class_name HudWholeChat

## CIFWholeChat, the "Chat to all" window a global chatting item opens (round
## 634; docs/protocol/chat.md).
##
## READ:
##   - opening: the inventory slot's use handler (IFSlotWithHelp 0x676570)
##     sends an item of TypeID 3/3/3/5 -- the type word's case 5 -- to
##     GInterfaceWndRelation 0x79b8a0, which builds "WholeChat" (interface
##     child 0x38, ginterface.txt's GDR_WHOLE_CHAT: `msgbox2_window_`,
##     433x239), keeps the slot (0x7ef3e0 -> +0x7b0) and reads the stack's
##     count into "Remaining turns" (0x7ef400 -> +0x7b4);
##   - layout: resinfo\ifwholechat.txt; title UIIT_STT_WHOLECHAT ("Chat to
##     all", CIFWholeChat::Create 0x7ef6f0 sets it on its caption);
##   - Use (GDR_WHOLE_CHAT_BTN_OK, 0x7ef550): nothing with no turns left; an
##     empty line shows UIIT_STT_WHOLECHAT_INPUTMSG; a line the filter
##     (0x8c4020) rejects shows UIIT_MSG_WHOLECHATERR_NOTINUSEMSG (the filter
##     is not built here -- OPEN); anything else goes out as 0x704c with the
##     slot and the text (0x7901c0). The edit box is emptied on every path.
##
## The message lines 0x7ef550 raises go through 0x7781b0 (the system message
## window, not built); here they reach the caller's `refused` signal, which
## World3D writes to the chat (OURS).

signal send_requested(inventory_slot: int, text: String)
signal refused(text: String)

const LAYOUT := "resinfo\\ifwholechat.txt"
const REGISTRY := {"name": "GDR_WHOLE_CHAT"}

var slot := -1
var count := 0
var _edit: LineEdit

func setup(builder: UiBuilder) -> bool:
	var title := builder.resolve_text("UIIT_STT_WHOLECHAT") if builder != null else "Chat to all"
	if not build(builder, LAYOUT, title, PackedStringArray(), PackedStringArray(), false, REGISTRY):
		return false
	_edit = node("GDR_WHOLE_CHAT_EDITBOX_INPUT") as LineEdit
	if _edit != null:
		_edit.text_submitted.connect(func(_t: String) -> void: use())
	var ok := node("GDR_WHOLE_CHAT_BTN_OK") as BaseButton
	if ok != null:
		ok.pressed.connect(use)
		# The client has no keyboard focus on buttons (round 606's note in
		# HudChat): a clicked Use must not keep Enter and Escape (measured on
		# the live run: Escape then left the focus on it and the window open).
		ok.focus_mode = Control.FOCUS_NONE
	var cancel := node("GDR_WHOLE_CHAT_BTN_CANCEL") as BaseButton
	if cancel != null:
		cancel.pressed.connect(close)
		cancel.focus_mode = Control.FOCUS_NONE
	visible = false
	return true

func close() -> void:
	if _edit != null:
		_edit.release_focus()
	visible = false

## Escape closes the window (OURS: the window-close order for Escape,
## HudPanels._escape_close, does not know this window).
func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if visible and key != null and key.pressed and not key.echo and key.keycode == KEY_ESCAPE:
		close()
		get_viewport().set_input_as_handled()

## Opens the window for the global chatting item in bag slot `at`, holding
## `turns` of them.
func open_for(at: int, turns: int) -> void:
	slot = at
	set_count(turns)
	centre()
	visible = true
	if _edit != null:
		_edit.grab_focus()

func set_count(turns: int) -> void:
	count = turns
	var label := node("GDR_WHOLE_CHAT_ODDITEM") as Control
	if label != null and _builder != null:
		_builder.set_static_text(label, str(turns))

func edit_text() -> String:
	return _edit.text if _edit != null else ""

func set_edit_text(t: String) -> void:
	if _edit != null:
		_edit.text = t

## The Use button (0x7ef550).
func use() -> void:
	var t := edit_text()
	if count >= 1:
		if t == "":
			refused.emit(_builder.resolve_text("UIIT_STT_WHOLECHAT_INPUTMSG") if _builder != null
				else "Send your message to all players")
		else:
			send_requested.emit(slot, t)
	set_edit_text("")
