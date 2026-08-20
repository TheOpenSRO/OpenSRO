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

@onready var monster_list: ItemList = $ActionTabs/Monsters/MonsterList
@onready var monster_refresh_button: Button = $ActionTabs/Monsters/MonsterButtonRow/RefreshButton
@onready var attack_button: Button = $ActionTabs/Monsters/MonsterButtonRow/AttackButton
@onready var monster_status_label: Label = $ActionTabs/Monsters/MonsterStatusLabel

@onready var inventory_list: ItemList = $ActionTabs/Inventory/InventoryList
@onready var inventory_refresh_button: Button = $ActionTabs/Inventory/InventoryButtonRow/RefreshButton
@onready var equip_weapon_button: Button = $ActionTabs/Inventory/InventoryButtonRow/EquipWeaponButton
@onready var equip_armor_button: Button = $ActionTabs/Inventory/InventoryButtonRow/EquipArmorButton
@onready var inventory_status_label: Label = $ActionTabs/Inventory/InventoryStatusLabel

@onready var equipment_list: ItemList = $ActionTabs/Equipment/EquipmentList
@onready var equipment_refresh_button: Button = $ActionTabs/Equipment/EquipmentButtonRow/RefreshButton
@onready var unequip_weapon_button: Button = $ActionTabs/Equipment/EquipmentButtonRow/UnequipWeaponButton
@onready var unequip_armor_button: Button = $ActionTabs/Equipment/EquipmentButtonRow/UnequipArmorButton
@onready var equipment_status_label: Label = $ActionTabs/Equipment/EquipmentStatusLabel

# character_id -> display name, for the nearby-entities list.
var _nearby: Dictionary = {}

# Parallel to monster_list/inventory_list's items -- ItemList doesn't carry
# structured data per row on its own, so track what each row actually is.
var _monsters: Array[CombatNet.MonsterSnapshot] = []
var _inventory_slots: Array[InventoryNet.Slot] = []

# equipment_result fires for OpEquipmentList *and* equip/unequip acks (see
# NetClient.equipment_result's doc comment: a successful equip/unequip ack
# just has an empty items array, same shape as "nothing equipped"). Track
# whether we're expecting an ack so an empty response isn't misread as
# "you have nothing equipped" right after a successful equip.
var _awaiting_equip_ack := false

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

	NetClient.monster_list_result.connect(_on_monster_list_result)
	NetClient.attack_result.connect(_on_attack_result)
	NetClient.monster_damaged.connect(_on_monster_damaged)
	NetClient.monster_died.connect(_on_monster_died)
	NetClient.loot_dropped.connect(_on_loot_dropped)
	NetClient.inventory_list_result.connect(_on_inventory_list_result)
	NetClient.equipment_result.connect(_on_equipment_result)

	send_button.pressed.connect(_on_send_pressed)
	chat_input.text_submitted.connect(func(_text: String): _on_send_pressed())
	disconnect_button.pressed.connect(_on_disconnect_pressed)

	monster_refresh_button.pressed.connect(func(): NetClient.list_monsters())
	attack_button.pressed.connect(_on_attack_pressed)
	inventory_refresh_button.pressed.connect(func(): NetClient.list_inventory(NetClient.current_character_name))
	equip_weapon_button.pressed.connect(func(): _on_equip_pressed(EquipmentNet.SLOT_WEAPON))
	equip_armor_button.pressed.connect(func(): _on_equip_pressed(EquipmentNet.SLOT_ARMOR))
	equipment_refresh_button.pressed.connect(func(): NetClient.list_equipment(NetClient.current_character_name))
	unequip_weapon_button.pressed.connect(func(): _on_unequip_pressed(EquipmentNet.SLOT_WEAPON))
	unequip_armor_button.pressed.connect(func(): _on_unequip_pressed(EquipmentNet.SLOT_ARMOR))

	NetClient.list_monsters()
	NetClient.list_inventory(NetClient.current_character_name)
	NetClient.list_equipment(NetClient.current_character_name)

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

# --- Monsters tab ---------------------------------------------------------

func _on_monster_list_result(monsters: Array, error: String) -> void:
	if error != "":
		monster_status_label.text = "Error: %s" % error
		return
	_monsters.assign(monsters)
	monster_list.clear()
	for m in _monsters:
		monster_list.add_item("%s (HP %d/%d)" % [m.monster_name, m.hp, m.max_hp])

func _on_attack_pressed() -> void:
	var selected := monster_list.get_selected_items()
	if selected.is_empty():
		monster_status_label.text = "Select a monster first."
		return
	var target: CombatNet.MonsterSnapshot = _monsters[selected[0]]
	NetClient.attack(NetClient.current_character_name, target.monster_id)

func _on_attack_result(result: CombatNet.AttackResult) -> void:
	if result == null:
		return
	if result.error != "":
		monster_status_label.text = "Attack failed: %s" % result.error
		return
	if result.monster_died:
		monster_status_label.text = "Hit for %d -- it died!" % result.monster_damage
	else:
		monster_status_label.text = "Hit for %d (%d HP left). Took %d damage (HP %d)." % [
			result.monster_damage, result.monster_remaining_hp, result.player_damage_taken, result.player_hp
		]
	NetClient.list_monsters()

func _on_monster_damaged(_damaged: CombatNet.MonsterDamaged) -> void:
	NetClient.list_monsters()

func _on_monster_died(_monster_id: int) -> void:
	NetClient.list_monsters()

func _on_loot_dropped(dropped: CombatNet.LootDropped) -> void:
	if dropped == null:
		return
	for d in dropped.drops:
		_log_system("Looted %dx item #%d." % [d.quantity, d.item_id])
	NetClient.list_inventory(NetClient.current_character_name)

# --- Inventory tab ---------------------------------------------------------

func _on_inventory_list_result(slots: Array, error: String) -> void:
	if error != "":
		inventory_status_label.text = "Error: %s" % error
		return
	_inventory_slots.assign(slots)
	inventory_list.clear()
	for s in _inventory_slots:
		inventory_list.add_item("Slot %d: item #%d x%d" % [s.slot_index, s.item_id, s.quantity])

func _on_equip_pressed(slot: int) -> void:
	var selected := inventory_list.get_selected_items()
	if selected.is_empty():
		inventory_status_label.text = "Select an item first."
		return
	var chosen: InventoryNet.Slot = _inventory_slots[selected[0]]
	_awaiting_equip_ack = true
	NetClient.equip(NetClient.current_character_name, slot, chosen.slot_index)

# --- Equipment tab ---------------------------------------------------------

func _on_equipment_result(items: Array, error: String) -> void:
	if error != "":
		equipment_status_label.text = "Error: %s" % error
		_awaiting_equip_ack = false
		return

	if _awaiting_equip_ack:
		# This empty-items response is the equip/unequip ack, not a real
		# "nothing equipped" list -- re-request the real list, and refresh
		# inventory since equip/unequip moves an item between the two.
		_awaiting_equip_ack = false
		equipment_status_label.text = "Equipment updated."
		NetClient.list_equipment(NetClient.current_character_name)
		NetClient.list_inventory(NetClient.current_character_name)
		return

	equipment_list.clear()
	for e in items:
		var slot_name := "Weapon" if e.slot == EquipmentNet.SLOT_WEAPON else "Armor"
		equipment_list.add_item("%s: item #%d" % [slot_name, e.item_id])

func _on_unequip_pressed(slot: int) -> void:
	_awaiting_equip_ack = true
	NetClient.unequip(NetClient.current_character_name, slot)
