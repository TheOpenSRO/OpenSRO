extends Node
class_name CharSelectRename

## The Name Change Scroll's rename at character select (round 838; OURS
## throughout -- a private server's scroll, ITEM_NAME_CHANGE: "A scroll that
## is going to allow you to change your name on your next login"). The
## server refuses Start for a character whose rename waits
## (ServiceNet.START_RENAME_PENDING); this asks for the new name in the
## archive's input box (HudCosBox.build_rename_input, with retail's own
## rename line), checks it by character creation's rules
## (CharCreateModel.name_error, the archive's name filter), asks the server
## (0x0139) and, on its yes, has the screen list the characters again with
## the renamed one selected (`name_changed`). A refusal shows its words and asks
## again.
##
## OPENSRO_QA_RENAME=<name> (QA only, OURS): when the box opens, types the
## name into its edit as key presses and presses Enter, as a player would,
## then starts the renamed character once the list is back.

signal name_changed(new_name: String)

var host: Control = null
var box: HudCosBox = null
var _builder: UiBuilder = null
var _media = null
var _say: Callable
var _char := ""
var _qa_name := OS.get_environment("OPENSRO_QA_RENAME")
var _qa_typed := false

## `say(text)` shows a line on the screen (its message line).
func setup(host_control: Control, builder: UiBuilder, media, say: Callable) -> void:
	name = "CharSelectRename"
	host = host_control
	_builder = builder
	_media = media
	_say = say
	NetClient.start_result.connect(_on_start_result)
	NetClient.service.rename_result.connect(_on_rename_result)

## Whether the box is up.
func is_open() -> bool:
	return box != null and is_instance_valid(box) and box.visible

## Start was answered: a waiting rename opens the box for that character.
func _on_start_result(ok: bool, code: int, _why: String) -> void:
	if ok or code != ServiceNet.START_RENAME_PENDING:
		return
	var who := String(host.call("selected_name")) if host != null and host.has_method("selected_name") else ""
	if who == "":
		return
	open_for(who)

## Opens the box for `char_name`.
func open_for(char_name: String) -> void:
	_char = char_name
	if is_open():
		box.close()
	box = HudCosBox.new()
	if not box.build_rename_input(_builder):
		box = null
		_line("Enter the new name of your character.")
		return
	box.accepted.connect(_on_typed)
	# Round 848: the box's edit is the layout's, so already a CifEdit
	# (UiBuilder._build_edit); a plain one still gets CIFEdit's rules.
	if box.edit != null and not box.edit is CifEdit:
		CifEdit.style(box.edit, box.edit.get_theme_color(&"font_color"))
	host.add_child(box)
	box.centre_on(host.get_viewport().get_visible_rect().size)
	print("SELECT: rename box for %s" % char_name)
	if _qa_name != "" and not _qa_typed:
		_qa_typed = true
		_qa_type.call_deferred(_qa_name)

func _on_typed(new_name: String) -> void:
	new_name = new_name.strip_edges()
	var err := CharCreateModel.name_error(new_name, NameFilter.shared(_media) if _media != null else null)
	if err != "":
		_line(_text(err, "That character name is unavailable."))
		open_for.call_deferred(_char)
		return
	print("SELECT: rename %s -> %s" % [_char, new_name])
	NetClient.service.request_rename(_char, new_name)

func _on_rename_result(ok: bool, code: int, new_name: String) -> void:
	if ok:
		print("SELECT: renamed %s -> %s" % [_char, new_name])
		_line("Your character's name is now %s." % new_name)
		name_changed.emit(new_name)
		return
	var why := LobbyNet.code_text(code, NetClient.lobby_text) if code != ServiceNet.RENAME_NOT_PENDING else ""
	if why == "" or code == 0x410:
		why = _text("UIIT_MSG_ITEM_CHANGE_NAME_CANNOT", "That character name is unavailable.")
	print("SELECT: rename refused (0x%x): %s" % [code, why])
	_line(why)
	if code != ServiceNet.RENAME_NOT_PENDING:
		open_for(_char)

func _line(text: String) -> void:
	if _say.is_valid():
		_say.call(text)

func _text(key: String, fallback: String) -> String:
	var t: UiTextTable = NetClient.lobby_text
	if t != null and t.has(key):
		var v := t.get_text(key, fallback).strip_edges()
		if v != "" and v != key:
			return v
	return fallback

## QA only: the name typed as key presses into the focused edit, then Enter.
func _qa_type(text: String) -> void:
	await host.get_tree().process_frame
	await host.get_tree().process_frame
	if box == null or box.edit == null:
		return
	box.edit.grab_focus()
	for ch in text:
		var ev := InputEventKey.new()
		ev.pressed = true
		ev.unicode = ch.unicode_at(0)
		host.get_viewport().push_input(ev)
		var up := ev.duplicate() as InputEventKey
		up.pressed = false
		host.get_viewport().push_input(up)
		await host.get_tree().process_frame
	print("QA RENAME: typed '%s' -> edit '%s'" % [text, box.edit.text])
	var enter := InputEventKey.new()
	enter.pressed = true
	enter.keycode = KEY_ENTER
	host.get_viewport().push_input(enter)
