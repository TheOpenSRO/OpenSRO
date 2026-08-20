extends Control

## In-world HUD: the first playable slice past character select. No map/
## asset rendering exists yet (see docs/protocol/PK2_FORMAT.md and the
## client's own scripts/pk2 reader -- that's a separate, unfinished piece),
## so this is a plain 2D overlay showing zone, nearby players, and chat --
## everything the wire protocol actually supports today, honestly
## represented rather than faking a 3D view. Loaded by CharacterSelect.gd
## on a successful OpEnterWorld.
##
## Character HP isn't shown: EnterWorldResult doesn't carry it and there's
## no "get my current HP" query opcode yet (HP only ever appears as a side
## effect of AttackResult/DuelAttackResult), so there's nothing honest to
## display before a fight starts.

@onready var character_label: Label = $HUD/CharacterLabel
@onready var zone_label: Label = $HUD/ZoneLabel
@onready var entity_list: ItemList = $EntityPanel/EntityList
@onready var chat_log: RichTextLabel = $ChatPanel/ChatLog
@onready var chat_input: LineEdit = $ChatPanel/ChatInputRow/ChatInput
@onready var send_button: Button = $ChatPanel/ChatInputRow/SendButton
@onready var disconnect_button: Button = $DisconnectButton

# character_id -> display name, for the nearby-entities list.
var _nearby: Dictionary = {}

func _ready() -> void:
	character_label.text = "Character: %s" % NetClient.current_character_name

	var result := NetClient.last_enter_world_result
	if result != null and result.ok:
		zone_label.text = "Zone: %s" % result.zone
		for other in result.others:
			_nearby[other.character_id] = other.char_name
	_refresh_entity_list()

	NetClient.entity_entered.connect(_on_entity_entered)
	NetClient.entity_moved.connect(_on_entity_moved)
	NetClient.entity_left.connect(_on_entity_left)
	NetClient.chat_message.connect(_on_chat_message)
	NetClient.chat_whisper_message.connect(_on_chat_whisper_message)
	NetClient.disconnected.connect(_on_disconnected)

	send_button.pressed.connect(_on_send_pressed)
	chat_input.text_submitted.connect(func(_text: String): _on_send_pressed())
	disconnect_button.pressed.connect(_on_disconnect_pressed)

func _refresh_entity_list() -> void:
	entity_list.clear()
	for character_id in _nearby.keys():
		entity_list.add_item(_nearby[character_id])

func _on_entity_entered(snapshot: WorldNet.EntitySnapshot) -> void:
	if snapshot == null:
		return
	_nearby[snapshot.character_id] = snapshot.char_name
	_refresh_entity_list()
	_log_system("%s entered the zone." % snapshot.char_name)

func _on_entity_moved(_moved: WorldNet.EntityMoved) -> void:
	# Position isn't rendered anywhere yet (no map view), so there's
	# nothing to update on-screen for a move beyond what entity_entered/
	# entity_left already cover.
	pass

func _on_entity_left(character_id: int) -> void:
	var departing_name: String = _nearby.get(character_id, "someone")
	_nearby.erase(character_id)
	_refresh_entity_list()
	_log_system("%s left the zone." % departing_name)

func _on_chat_message(message: ChatNet.Message) -> void:
	if message == null:
		return
	chat_log.add_text("%s: %s\n" % [message.sender_name, message.message_text])

func _on_chat_whisper_message(message: ChatNet.Message) -> void:
	if message == null:
		return
	chat_log.add_text("[%s whispers]: %s\n" % [message.sender_name, message.message_text])

func _log_system(text: String) -> void:
	chat_log.add_text("* %s\n" % text)

func _on_send_pressed() -> void:
	var text := chat_input.text.strip_edges()
	if text.is_empty():
		return
	chat_input.text = ""

	if text.begins_with("/w "):
		var rest := text.substr(3)
		var space_index := rest.find(" ")
		if space_index == -1:
			_log_system("Usage: /w <name> <message>")
			return
		var target_name := rest.substr(0, space_index)
		var whisper_text := rest.substr(space_index + 1)
		NetClient.whisper(target_name, whisper_text)
		return

	NetClient.say(text)

func _on_disconnect_pressed() -> void:
	NetClient.disconnect_from_server()

func _on_disconnected() -> void:
	get_tree().change_scene_to_file("res://scenes/Login.tscn")
