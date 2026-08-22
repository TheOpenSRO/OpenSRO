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
@onready var view3d_button: Button = $View3DButton

@onready var monster_list: ItemList = $ActionTabs/Monsters/MonsterList
@onready var monster_refresh_button: Button = $ActionTabs/Monsters/MonsterButtonRow/RefreshButton
@onready var attack_button: Button = $ActionTabs/Monsters/MonsterButtonRow/AttackButton
@onready var monster_status_label: Label = $ActionTabs/Monsters/MonsterStatusLabel

@onready var inventory_list: ItemList = $ActionTabs/Inventory/InventoryList
@onready var inventory_refresh_button: Button = $ActionTabs/Inventory/InventoryButtonRow/RefreshButton
@onready var equip_weapon_button: Button = $ActionTabs/Inventory/InventoryButtonRow/EquipWeaponButton
@onready var equip_armor_slot_option: OptionButton = $ActionTabs/Inventory/InventoryButtonRow/EquipArmorSlotOption
@onready var equip_armor_button: Button = $ActionTabs/Inventory/InventoryButtonRow/EquipArmorButton
@onready var inventory_status_label: Label = $ActionTabs/Inventory/InventoryStatusLabel

@onready var equipment_list: ItemList = $ActionTabs/Equipment/EquipmentList
@onready var equipment_refresh_button: Button = $ActionTabs/Equipment/EquipmentButtonRow/RefreshButton
@onready var unequip_weapon_button: Button = $ActionTabs/Equipment/EquipmentButtonRow/UnequipWeaponButton
@onready var unequip_armor_slot_option: OptionButton = $ActionTabs/Equipment/EquipmentButtonRow/UnequipArmorSlotOption
@onready var unequip_armor_button: Button = $ActionTabs/Equipment/EquipmentButtonRow/UnequipArmorButton
@onready var equipment_status_label: Label = $ActionTabs/Equipment/EquipmentStatusLabel

## Real, decompiler-confirmed armor slot names (see
## docs/protocol/EQUIP_SLOTS.md), shown in that same real order in both
## armor-slot pickers.
const ARMOR_SLOT_LABELS := {
	EquipmentNet.SLOT_HELM: "Helm",
	EquipmentNet.SLOT_MAIL: "Mail",
	EquipmentNet.SLOT_SHOULDER_GUARD: "Shoulder Guard",
	EquipmentNet.SLOT_PANTS: "Pants",
	EquipmentNet.SLOT_BOOTS: "Boots",
}

@onready var quest_list: ItemList = $ActionTabs/Quests/QuestList
@onready var quest_refresh_button: Button = $ActionTabs/Quests/QuestButtonRow/RefreshButton
@onready var quest_accept_button: Button = $ActionTabs/Quests/QuestButtonRow/AcceptButton
@onready var quest_status_label: Label = $ActionTabs/Quests/QuestStatusLabel

@onready var shop_list: ItemList = $ActionTabs/Shop/ShopList
@onready var shop_refresh_button: Button = $ActionTabs/Shop/ShopButtonRow/RefreshButton
@onready var shop_buy_button: Button = $ActionTabs/Shop/ShopButtonRow/BuyButton
@onready var shop_status_label: Label = $ActionTabs/Shop/ShopStatusLabel

@onready var party_list: ItemList = $ActionTabs/Party/PartyList
@onready var party_create_button: Button = $ActionTabs/Party/PartyButtonRow/CreateButton
@onready var party_leave_button: Button = $ActionTabs/Party/PartyButtonRow/LeaveButton
@onready var party_join_id_input: LineEdit = $ActionTabs/Party/PartyJoinRow/JoinIdInput
@onready var party_join_button: Button = $ActionTabs/Party/PartyJoinRow/JoinButton
@onready var party_status_label: Label = $ActionTabs/Party/PartyStatusLabel

@onready var guild_list: ItemList = $ActionTabs/Guild/GuildList
@onready var guild_name_input: LineEdit = $ActionTabs/Guild/GuildCreateRow/GuildNameInput
@onready var guild_create_button: Button = $ActionTabs/Guild/GuildCreateRow/CreateButton
@onready var guild_join_id_input: LineEdit = $ActionTabs/Guild/GuildJoinRow/JoinIdInput
@onready var guild_join_button: Button = $ActionTabs/Guild/GuildJoinRow/JoinButton
@onready var guild_leave_button: Button = $ActionTabs/Guild/GuildJoinRow/LeaveButton
@onready var guild_status_label: Label = $ActionTabs/Guild/GuildStatusLabel

@onready var duel_target_input: LineEdit = $ActionTabs/Duel/ChallengeRow/TargetInput
@onready var duel_challenge_button: Button = $ActionTabs/Duel/ChallengeRow/ChallengeButton
@onready var duel_invite_label: Label = $ActionTabs/Duel/InviteRow/InviteLabel
@onready var duel_accept_button: Button = $ActionTabs/Duel/InviteRow/AcceptButton
@onready var duel_decline_button: Button = $ActionTabs/Duel/InviteRow/DeclineButton
@onready var duel_attack_button: Button = $ActionTabs/Duel/AttackButton
@onready var duel_status_label: Label = $ActionTabs/Duel/DuelStatusLabel

@onready var trade_target_input: LineEdit = $ActionTabs/Trade/RequestRow/TargetInput
@onready var trade_request_button: Button = $ActionTabs/Trade/RequestRow/RequestButton
@onready var trade_invite_label: Label = $ActionTabs/Trade/InviteRow/InviteLabel
@onready var trade_accept_button: Button = $ActionTabs/Trade/InviteRow/AcceptButton
@onready var trade_decline_button: Button = $ActionTabs/Trade/InviteRow/DeclineButton
@onready var trade_gold_input: LineEdit = $ActionTabs/Trade/OfferRow/GoldInput
@onready var trade_item_slot_input: LineEdit = $ActionTabs/Trade/OfferRow/ItemSlotInput
@onready var trade_quantity_input: LineEdit = $ActionTabs/Trade/OfferRow/QuantityInput
@onready var trade_set_offer_button: Button = $ActionTabs/Trade/OfferRow/SetOfferButton
@onready var trade_their_offer_label: Label = $ActionTabs/Trade/TheirOfferLabel
@onready var trade_confirm_button: Button = $ActionTabs/Trade/TradeButtonRow/ConfirmButton
@onready var trade_cancel_button: Button = $ActionTabs/Trade/TradeButtonRow/CancelButton
@onready var trade_status_label: Label = $ActionTabs/Trade/TradeStatusLabel

@onready var friend_list: ItemList = $ActionTabs/Friends/FriendList
@onready var friend_remove_button: Button = $ActionTabs/Friends/RemoveButton
@onready var friend_pending_list: ItemList = $ActionTabs/Friends/PendingList
@onready var friend_accept_button: Button = $ActionTabs/Friends/PendingButtonRow/AcceptButton
@onready var friend_decline_button: Button = $ActionTabs/Friends/PendingButtonRow/DeclineButton
@onready var friend_target_input: LineEdit = $ActionTabs/Friends/RequestRow/TargetInput
@onready var friend_request_button: Button = $ActionTabs/Friends/RequestRow/RequestButton
@onready var friend_refresh_button: Button = $ActionTabs/Friends/RefreshButton
@onready var friend_status_label: Label = $ActionTabs/Friends/FriendStatusLabel

# character_id -> display name, for the nearby-entities list.
var _nearby: Dictionary = {}

# Parallel to monster_list/inventory_list's items -- ItemList doesn't carry
# structured data per row on its own, so track what each row actually is.
var _monsters: Array[CombatNet.MonsterSnapshot] = []
var _inventory_slots: Array[InventoryNet.Slot] = []
var _quests: Array[QuestNet.Entry] = []
var _shop_entries: Array[ShopNet.CatalogEntry] = []

# Name of whoever last challenged/requested-trade-with us, so Accept/
# Decline know who to respond to (the server needs it explicitly).
var _pending_duel_challenger := ""
var _pending_trade_requester := ""

var _friends: Array[FriendNet.FriendEntry] = []
var _pending_friend_requests: Array[FriendNet.PendingRequest] = []

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
	NetClient.quest_list_result.connect(_on_quest_list_result)
	NetClient.quest_accept_result.connect(_on_quest_accept_result)
	NetClient.quest_completed.connect(_on_quest_completed)
	NetClient.shop_list_result.connect(_on_shop_list_result)
	NetClient.shop_buy_result.connect(_on_shop_buy_result)

	NetClient.party_create_result.connect(_on_party_result)
	NetClient.party_join_result.connect(_on_party_result)
	NetClient.party_leave_result.connect(_on_party_leave_result)
	NetClient.party_member_joined.connect(_on_party_member_joined)
	NetClient.party_member_left.connect(_on_party_member_left)
	NetClient.party_info_result.connect(_on_party_result)

	NetClient.guild_create_result.connect(_on_guild_result)
	NetClient.guild_join_result.connect(_on_guild_result)
	NetClient.guild_leave_result.connect(_on_guild_leave_result)
	NetClient.guild_info_result.connect(_on_guild_result)

	NetClient.duel_challenge_result.connect(_on_duel_challenge_result)
	NetClient.duel_invite.connect(_on_duel_invite)
	NetClient.duel_respond_result.connect(_on_duel_respond_result)
	NetClient.duel_started.connect(_on_duel_started)
	NetClient.duel_declined.connect(_on_duel_declined)
	NetClient.duel_attack_result.connect(_on_duel_attack_result)
	NetClient.duel_opponent_damaged.connect(_on_duel_opponent_damaged)
	NetClient.duel_ended.connect(_on_duel_ended)

	NetClient.trade_request_result.connect(_on_trade_request_result)
	NetClient.trade_invite.connect(_on_trade_invite)
	NetClient.trade_respond_result.connect(_on_trade_respond_result)
	NetClient.trade_started.connect(_on_trade_started)
	NetClient.trade_declined.connect(_on_trade_declined)
	NetClient.trade_offer_result.connect(_on_trade_offer_result)
	NetClient.trade_offer_updated.connect(_on_trade_offer_updated)
	NetClient.trade_confirm_result.connect(_on_trade_confirm_result)
	NetClient.trade_completed.connect(_on_trade_completed)
	NetClient.trade_cancelled.connect(_on_trade_cancelled)

	NetClient.friend_request_result.connect(_on_friend_request_result)
	NetClient.friend_request_received.connect(_on_friend_request_received)
	NetClient.friend_accept_result.connect(_on_friend_accept_result)
	NetClient.friend_accepted.connect(_on_friend_accepted)
	NetClient.friend_decline_result.connect(_on_friend_decline_result)
	NetClient.friend_list_result.connect(_on_friend_list_result)
	NetClient.friend_remove_result.connect(_on_friend_remove_result)
	NetClient.friend_pending_list_result.connect(_on_friend_pending_list_result)

	send_button.pressed.connect(_on_send_pressed)
	chat_input.text_submitted.connect(func(_text: String): _on_send_pressed())
	disconnect_button.pressed.connect(_on_disconnect_pressed)
	view3d_button.pressed.connect(_on_view3d_pressed)

	monster_refresh_button.pressed.connect(func(): NetClient.list_monsters())
	attack_button.pressed.connect(_on_attack_pressed)
	inventory_refresh_button.pressed.connect(func(): NetClient.list_inventory(NetClient.current_character_name))
	for slot in EquipmentNet.ARMOR_SLOTS:
		equip_armor_slot_option.add_item(ARMOR_SLOT_LABELS[slot], slot)
		unequip_armor_slot_option.add_item(ARMOR_SLOT_LABELS[slot], slot)

	equip_weapon_button.pressed.connect(func(): _on_equip_pressed(EquipmentNet.SLOT_WEAPON))
	equip_armor_button.pressed.connect(func(): _on_equip_pressed(equip_armor_slot_option.get_selected_id()))
	equipment_refresh_button.pressed.connect(func(): NetClient.list_equipment(NetClient.current_character_name))
	unequip_weapon_button.pressed.connect(func(): _on_unequip_pressed(EquipmentNet.SLOT_WEAPON))
	unequip_armor_button.pressed.connect(func(): _on_unequip_pressed(unequip_armor_slot_option.get_selected_id()))
	quest_refresh_button.pressed.connect(func(): NetClient.list_quests(NetClient.current_character_name))
	quest_accept_button.pressed.connect(_on_quest_accept_pressed)
	shop_refresh_button.pressed.connect(func(): NetClient.list_shop())
	shop_buy_button.pressed.connect(_on_shop_buy_pressed)

	party_create_button.pressed.connect(func(): NetClient.create_party(NetClient.current_character_name))
	party_leave_button.pressed.connect(func(): NetClient.leave_party(NetClient.current_character_name))
	party_join_button.pressed.connect(_on_party_join_pressed)

	guild_create_button.pressed.connect(_on_guild_create_pressed)
	guild_join_button.pressed.connect(_on_guild_join_pressed)
	guild_leave_button.pressed.connect(func(): NetClient.leave_guild(NetClient.current_character_name))

	duel_challenge_button.pressed.connect(_on_duel_challenge_pressed)
	duel_accept_button.pressed.connect(func(): _on_duel_respond_pressed(true))
	duel_decline_button.pressed.connect(func(): _on_duel_respond_pressed(false))
	duel_attack_button.pressed.connect(func(): NetClient.duel_attack(NetClient.current_character_name))

	trade_request_button.pressed.connect(_on_trade_request_pressed)
	trade_accept_button.pressed.connect(func(): _on_trade_respond_pressed(true))
	trade_decline_button.pressed.connect(func(): _on_trade_respond_pressed(false))
	trade_set_offer_button.pressed.connect(_on_trade_set_offer_pressed)
	trade_confirm_button.pressed.connect(func(): NetClient.trade_confirm(NetClient.current_character_name))
	trade_cancel_button.pressed.connect(func(): NetClient.trade_cancel(NetClient.current_character_name))

	friend_request_button.pressed.connect(_on_friend_request_pressed)
	friend_accept_button.pressed.connect(_on_friend_accept_pressed)
	friend_decline_button.pressed.connect(_on_friend_decline_pressed)
	friend_remove_button.pressed.connect(_on_friend_remove_pressed)
	friend_refresh_button.pressed.connect(_refresh_friends)

	NetClient.list_monsters()
	NetClient.list_inventory(NetClient.current_character_name)
	NetClient.list_equipment(NetClient.current_character_name)
	NetClient.list_quests(NetClient.current_character_name)
	NetClient.list_shop()
	NetClient.party_info(NetClient.current_character_name)
	NetClient.guild_info(NetClient.current_character_name)
	_refresh_friends()

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

func _on_view3d_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/World3D.tscn")

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
		# A kill may have progressed a quest's kill count even without
		# completing it (OpQuestCompleted only fires on completion), so
		# refresh here rather than only on _on_quest_completed.
		NetClient.list_quests(NetClient.current_character_name)
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
		var slot_name: String = "Weapon" if e.slot == EquipmentNet.SLOT_WEAPON else ARMOR_SLOT_LABELS.get(e.slot, "Slot %d" % e.slot)
		equipment_list.add_item("%s: item #%d" % [slot_name, e.item_id])

func _on_unequip_pressed(slot: int) -> void:
	_awaiting_equip_ack = true
	NetClient.unequip(NetClient.current_character_name, slot)

# --- Quests tab --------------------------------------------------------

func _on_quest_list_result(entries: Array, error: String) -> void:
	if error != "":
		quest_status_label.text = "Error: %s" % error
		return
	_quests.assign(entries)
	quest_list.clear()
	for q in _quests:
		var state := "completed" if q.completed else ("accepted" if q.accepted else "available")
		quest_list.add_item("%s: kill %s (%d/%d) for %dg [%s]" % [
			q.quest_name, q.monster_name, q.kills, q.target_kills, q.gold_reward, state
		])

func _on_quest_accept_pressed() -> void:
	var selected := quest_list.get_selected_items()
	if selected.is_empty():
		quest_status_label.text = "Select a quest first."
		return
	var chosen: QuestNet.Entry = _quests[selected[0]]
	NetClient.accept_quest(NetClient.current_character_name, chosen.quest_id)

func _on_quest_accept_result(ok: bool, reason: String) -> void:
	quest_status_label.text = "Quest accepted." if ok else "Accept failed: %s" % reason
	NetClient.list_quests(NetClient.current_character_name)

func _on_quest_completed(completed: QuestNet.Completed) -> void:
	if completed == null:
		return
	_log_system("Quest complete! +%dg" % completed.gold_reward)
	NetClient.list_quests(NetClient.current_character_name)

# --- Shop tab ------------------------------------------------------------

func _on_shop_list_result(entries: Array, error: String) -> void:
	if error != "":
		shop_status_label.text = "Error: %s" % error
		return
	_shop_entries.assign(entries)
	shop_list.clear()
	for e in _shop_entries:
		shop_list.add_item("Item #%d (class %d, atk %.1f/def %.1f) -- %dg" % [
			e.item_id, e.item_class, e.phys_attack_max, e.phys_defense_max, e.price
		])

func _on_shop_buy_pressed() -> void:
	var selected := shop_list.get_selected_items()
	if selected.is_empty():
		shop_status_label.text = "Select an item first."
		return
	var chosen: ShopNet.CatalogEntry = _shop_entries[selected[0]]
	NetClient.shop_buy(NetClient.current_character_name, chosen.item_id, 1)

func _on_shop_buy_result(ok: bool, reason: String) -> void:
	shop_status_label.text = "Purchased." if ok else "Purchase failed: %s" % reason
	if ok:
		NetClient.list_inventory(NetClient.current_character_name)

# --- Party tab -------------------------------------------------------------

func _refresh_party_list(result: PartyNet.Result) -> void:
	party_list.clear()
	for m in result.members:
		party_list.add_item(m.member_name)

func _on_party_result(result: PartyNet.Result) -> void:
	if result == null:
		return
	if result.error != "":
		party_status_label.text = "Error: %s" % result.error
		return
	if result.party_id == 0:
		party_status_label.text = "Not in a party."
		party_list.clear()
		return
	party_status_label.text = "Party #%d (%d member(s))." % [result.party_id, result.members.size()]
	_refresh_party_list(result)

func _on_party_join_pressed() -> void:
	var id_text := party_join_id_input.text.strip_edges()
	if not id_text.is_valid_int():
		party_status_label.text = "Enter a numeric party ID."
		return
	NetClient.join_party(NetClient.current_character_name, id_text.to_int())

func _on_party_leave_result(ok: bool, reason: String) -> void:
	if ok:
		party_status_label.text = "Left the party."
		party_list.clear()
	else:
		party_status_label.text = "Leave failed: %s" % reason

func _on_party_member_joined(member: PartyNet.MemberJoined) -> void:
	if member == null:
		return
	_log_system("%s joined your party." % member.member_name)
	NetClient.party_info(NetClient.current_character_name)

func _on_party_member_left(character_id: int) -> void:
	_log_system("A party member left (character #%d)." % character_id)
	NetClient.party_info(NetClient.current_character_name)

# --- Guild tab -------------------------------------------------------------

func _refresh_guild_list(result: GuildNet.Result) -> void:
	guild_list.clear()
	for m in result.members:
		var role_name := "Leader" if m.role == GuildNet.ROLE_LEADER else "Member"
		guild_list.add_item("%s [%s]" % [m.member_name, role_name])

func _on_guild_result(result: GuildNet.Result) -> void:
	if result == null:
		return
	if result.error != "":
		guild_status_label.text = "Error: %s" % result.error
		return
	if result.guild_id == 0:
		guild_status_label.text = "Not in a guild."
		guild_list.clear()
		return
	guild_status_label.text = "%s (#%d, %d member(s))." % [result.guild_name, result.guild_id, result.members.size()]
	_refresh_guild_list(result)

func _on_guild_create_pressed() -> void:
	var guild_name := guild_name_input.text.strip_edges()
	if guild_name.is_empty():
		guild_status_label.text = "Enter a guild name first."
		return
	NetClient.create_guild(NetClient.current_character_name, guild_name)

func _on_guild_join_pressed() -> void:
	var id_text := guild_join_id_input.text.strip_edges()
	if not id_text.is_valid_int():
		guild_status_label.text = "Enter a numeric guild ID."
		return
	NetClient.join_guild(NetClient.current_character_name, id_text.to_int())

func _on_guild_leave_result(ok: bool, reason: String) -> void:
	if ok:
		guild_status_label.text = "Left the guild."
		guild_list.clear()
	else:
		guild_status_label.text = "Leave failed: %s" % reason

# --- Duel tab --------------------------------------------------------------

func _on_duel_challenge_pressed() -> void:
	var target := duel_target_input.text.strip_edges()
	if target.is_empty():
		duel_status_label.text = "Enter a target name first."
		return
	NetClient.duel_challenge(NetClient.current_character_name, target)

func _on_duel_challenge_result(ok: bool, reason: String) -> void:
	duel_status_label.text = "Challenge sent." if ok else "Challenge failed: %s" % reason

func _on_duel_invite(invite: DuelNet.Invite) -> void:
	if invite == null:
		return
	_pending_duel_challenger = invite.challenger_name
	duel_invite_label.text = "%s challenges you to a duel!" % invite.challenger_name

func _on_duel_respond_pressed(accept: bool) -> void:
	if _pending_duel_challenger.is_empty():
		duel_status_label.text = "No pending challenge to respond to."
		return
	NetClient.duel_respond(NetClient.current_character_name, _pending_duel_challenger, accept)
	_pending_duel_challenger = ""
	duel_invite_label.text = "(no pending challenge)"

func _on_duel_respond_result(ok: bool, reason: String) -> void:
	if not ok:
		duel_status_label.text = "Respond failed: %s" % reason

func _on_duel_started(started: DuelNet.Started) -> void:
	if started == null:
		return
	duel_status_label.text = "Dueling %s! Attack away." % started.opponent_name

func _on_duel_declined(declined: DuelNet.Declined) -> void:
	if declined == null:
		return
	duel_status_label.text = "%s declined your challenge." % declined.target_name

func _on_duel_attack_result(result: DuelNet.AttackResult) -> void:
	if result == null:
		return
	if result.error != "":
		duel_status_label.text = "Attack failed: %s" % result.error
		return
	if result.opponent_died:
		duel_status_label.text = "Hit for %d -- you won!" % result.damage
	else:
		duel_status_label.text = "Hit for %d (opponent HP %d)." % [result.damage, result.opponent_hp]

func _on_duel_opponent_damaged(damaged: DuelNet.OpponentDamaged) -> void:
	if damaged == null:
		return
	duel_status_label.text = "Took %d damage (HP %d)." % [damaged.damage, damaged.remaining_hp]

func _on_duel_ended(ended: DuelNet.Ended) -> void:
	if ended == null:
		return
	duel_status_label.text = "Duel over -- %s won." % ended.winner_name

# --- Trade tab ---------------------------------------------------------

func _on_trade_request_pressed() -> void:
	var target := trade_target_input.text.strip_edges()
	if target.is_empty():
		trade_status_label.text = "Enter a target name first."
		return
	NetClient.trade_request(NetClient.current_character_name, target)

func _on_trade_request_result(ok: bool, reason: String) -> void:
	trade_status_label.text = "Trade request sent." if ok else "Request failed: %s" % reason

func _on_trade_invite(invite: TradeNet.Invite) -> void:
	if invite == null:
		return
	_pending_trade_requester = invite.requester_name
	trade_invite_label.text = "%s wants to trade with you!" % invite.requester_name

func _on_trade_respond_pressed(accept: bool) -> void:
	if _pending_trade_requester.is_empty():
		trade_status_label.text = "No pending request to respond to."
		return
	NetClient.trade_respond(NetClient.current_character_name, _pending_trade_requester, accept)
	_pending_trade_requester = ""
	trade_invite_label.text = "(no pending request)"

func _on_trade_respond_result(ok: bool, reason: String) -> void:
	if not ok:
		trade_status_label.text = "Respond failed: %s" % reason

func _on_trade_started(started: TradeNet.Started) -> void:
	if started == null:
		return
	trade_status_label.text = "Trading with %s. Set your offer below." % started.partner_name
	trade_their_offer_label.text = "Their offer: (none yet)"

func _on_trade_declined(declined: TradeNet.Declined) -> void:
	if declined == null:
		return
	trade_status_label.text = "%s declined your trade request." % declined.target_name

func _on_trade_set_offer_pressed() -> void:
	var gold_text := trade_gold_input.text.strip_edges()
	var slot_text := trade_item_slot_input.text.strip_edges()
	var qty_text := trade_quantity_input.text.strip_edges()
	var gold := int(gold_text) if gold_text.is_valid_int() else 0
	var item_slot := int(slot_text) if slot_text.is_valid_int() else TradeNet.ITEM_SLOT_NONE
	var quantity := int(qty_text) if qty_text.is_valid_int() else 0
	NetClient.trade_set_offer(NetClient.current_character_name, gold, item_slot, quantity)

func _on_trade_offer_result(ok: bool, reason: String) -> void:
	if not ok:
		trade_status_label.text = "Offer failed: %s" % reason

func _on_trade_confirm_result(ok: bool, reason: String) -> void:
	trade_status_label.text = "Confirmed. Waiting on the other side." if ok else "Confirm failed: %s" % reason

func _on_trade_offer_updated(updated: TradeNet.OfferUpdated) -> void:
	if updated == null:
		return
	var item_desc := "no item" if updated.offer.item_slot < 0 else "slot %d x%d" % [updated.offer.item_slot, updated.offer.quantity]
	trade_their_offer_label.text = "Their offer: %dg, %s" % [updated.offer.gold, item_desc]

func _on_trade_completed(completed: TradeNet.Completed) -> void:
	if completed == null:
		return
	_log_system("Trade complete! Received %dg%s" % [
		completed.received_gold,
		(" and %dx item #%d" % [completed.received_quantity, completed.received_item_id]) if completed.received_item_id != 0 else ""
	])
	NetClient.list_inventory(NetClient.current_character_name)

func _on_trade_cancelled(cancelled: TradeNet.Cancelled) -> void:
	if cancelled == null:
		return
	var by_whom := cancelled.cancelled_by_name if cancelled.cancelled_by_name != "" else "the system"
	trade_status_label.text = "Trade cancelled by %s." % by_whom
	trade_their_offer_label.text = "Their offer: (none yet)"

# --- Friends tab -----------------------------------------------------------

func _refresh_friends() -> void:
	NetClient.friend_list(NetClient.current_character_name)
	NetClient.friend_pending_list(NetClient.current_character_name)

func _on_friend_request_pressed() -> void:
	var target := friend_target_input.text.strip_edges()
	if target.is_empty():
		friend_status_label.text = "Enter a target name first."
		return
	NetClient.friend_request(NetClient.current_character_name, target)

func _on_friend_request_result(ok: bool, reason: String) -> void:
	friend_status_label.text = "Request sent." if ok else "Request failed: %s" % reason

func _on_friend_request_received(received: FriendNet.RequestReceived) -> void:
	if received == null:
		return
	_log_system("%s sent you a friend request." % received.requester_name)
	_refresh_friends()

func _on_friend_accept_pressed() -> void:
	var selected := friend_pending_list.get_selected_items()
	if selected.is_empty():
		friend_status_label.text = "Select a pending request first."
		return
	var chosen: FriendNet.PendingRequest = _pending_friend_requests[selected[0]]
	NetClient.friend_accept(NetClient.current_character_name, chosen.requester_id)

func _on_friend_accept_result(ok: bool, reason: String) -> void:
	friend_status_label.text = "Friend added." if ok else "Accept failed: %s" % reason
	if ok:
		_refresh_friends()

func _on_friend_accepted(accepted: FriendNet.Accepted) -> void:
	if accepted == null:
		return
	_log_system("%s accepted your friend request." % accepted.accepter_name)
	_refresh_friends()

func _on_friend_decline_pressed() -> void:
	var selected := friend_pending_list.get_selected_items()
	if selected.is_empty():
		friend_status_label.text = "Select a pending request first."
		return
	var chosen: FriendNet.PendingRequest = _pending_friend_requests[selected[0]]
	NetClient.friend_decline(NetClient.current_character_name, chosen.requester_id)

func _on_friend_decline_result(ok: bool, reason: String) -> void:
	friend_status_label.text = "Declined." if ok else "Decline failed: %s" % reason
	if ok:
		_refresh_friends()

func _on_friend_list_result(friends: Array, error: String) -> void:
	if error != "":
		friend_status_label.text = "Error: %s" % error
		return
	_friends.assign(friends)
	friend_list.clear()
	for f in _friends:
		friend_list.add_item("%s [%s]" % [f.friend_name, "online" if f.online else "offline"])

func _on_friend_remove_pressed() -> void:
	var selected := friend_list.get_selected_items()
	if selected.is_empty():
		friend_status_label.text = "Select a friend first."
		return
	var chosen: FriendNet.FriendEntry = _friends[selected[0]]
	NetClient.friend_remove(NetClient.current_character_name, chosen.character_id)

func _on_friend_remove_result(ok: bool, reason: String) -> void:
	friend_status_label.text = "Removed." if ok else "Remove failed: %s" % reason
	if ok:
		_refresh_friends()

func _on_friend_pending_list_result(requests: Array, error: String) -> void:
	if error != "":
		return
	_pending_friend_requests.assign(requests)
	friend_pending_list.clear()
	for r in _pending_friend_requests:
		friend_pending_list.add_item(r.requester_name)
