extends Control

## Character select screen: lists the logged-in account's characters via
## NetClient, and lets the player create, delete, or enter the world with
## one.

@onready var char_list: ItemList = $VBoxContainer/CharList
@onready var new_name_edit: LineEdit = $VBoxContainer/CreateRow/NewNameEdit
@onready var create_button: Button = $VBoxContainer/CreateRow/CreateButton
@onready var delete_button: Button = $VBoxContainer/ActionRow/DeleteButton
@onready var enter_button: Button = $VBoxContainer/ActionRow/EnterButton
@onready var status_label: Label = $VBoxContainer/StatusLabel

func _ready() -> void:
	create_button.pressed.connect(_on_create_pressed)
	delete_button.pressed.connect(_on_delete_pressed)
	enter_button.pressed.connect(_on_enter_pressed)
	NetClient.character_list_result.connect(_on_list_result)
	NetClient.character_create_result.connect(_on_create_result)
	NetClient.character_delete_result.connect(_on_delete_result)
	NetClient.enter_world_result.connect(_on_enter_world_result)
	NetClient.list_characters()

func _on_list_result(names: Array, error: String) -> void:
	char_list.clear()
	if error != "":
		status_label.text = "Error: %s" % error
		return
	for n in names:
		char_list.add_item(n)

func _on_create_pressed() -> void:
	var char_name := new_name_edit.text
	if char_name.is_empty():
		status_label.text = "Enter a name first."
		return
	NetClient.create_character(char_name)

func _on_create_result(ok: bool, reason: String) -> void:
	if ok:
		status_label.text = "Character created."
		new_name_edit.text = ""
		NetClient.list_characters()
	else:
		status_label.text = "Create failed: %s" % reason

func _selected_name() -> String:
	var selected := char_list.get_selected_items()
	if selected.is_empty():
		return ""
	return char_list.get_item_text(selected[0])

func _on_delete_pressed() -> void:
	var char_name := _selected_name()
	if char_name.is_empty():
		status_label.text = "Select a character first."
		return
	NetClient.delete_character(char_name)

func _on_delete_result(ok: bool, reason: String) -> void:
	if ok:
		status_label.text = "Character deleted."
		NetClient.list_characters()
	else:
		status_label.text = "Delete failed: %s" % reason

func _on_enter_pressed() -> void:
	var char_name := _selected_name()
	if char_name.is_empty():
		status_label.text = "Select a character first."
		return
	NetClient.enter_world(char_name)

func _on_enter_world_result(result: WorldNet.EnterWorldResult) -> void:
	if result.error != "":
		status_label.text = "Malformed response: %s" % result.error
		return
	if not result.ok:
		status_label.text = "Enter world failed: %s" % result.reason
		return
	# No in-world scene exists yet (needs real map/asset rendering) --
	# confirm success here as the current end of this vertical slice.
	status_label.text = "Entered zone '%s' at (%.1f, %.1f, %.1f). %d other player(s) present." % [
		result.zone, result.x, result.y, result.z, result.others.size()
	]
