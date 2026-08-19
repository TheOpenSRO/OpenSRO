extends Node

## Thin client-side wrapper around a TCP connection to the Go server,
## dispatching decoded packets (via Packet/Auth/CharacterNet/WorldNet) as
## signals for UI scenes to react to. Meant to be used as an autoload
## singleton (see project.godot) so any scene can reach it.
##
## Known limitation: Packet.read_from busy-waits (in small increments) for a
## payload to fully arrive once its header is seen, which is fine for a
## local dev server but would stall a frame against a slow/adversarial
## connection. Acceptable for now; worth revisiting before this talks to
## anything over a real network.

signal connected
signal connection_failed
signal disconnected

signal login_result(ok: bool, reason: String)
signal register_result(ok: bool, reason: String)
signal character_list_result(names: Array, error: String)
signal character_create_result(ok: bool, reason: String)
signal character_delete_result(ok: bool, reason: String)
signal enter_world_result(result: WorldNet.EnterWorldResult)
signal entity_entered(snapshot: WorldNet.EntitySnapshot)
signal entity_moved(moved: WorldNet.EntityMoved)
signal entity_left(character_id: int)

signal inventory_list_result(slots: Array, error: String)
## Fires for OpEquipmentList AND for equip/unequip acks -- the server uses
## one opcode/shape for all three (a successful equip/unequip ack just has
## an empty items array). Callers that need to react to "my equip request
## succeeded" specifically should track that they're awaiting one.
signal equipment_result(items: Array, error: String)
signal shop_buy_result(ok: bool, reason: String)
signal attack_result(result: CombatNet.AttackResult)
signal monster_damaged(damaged: CombatNet.MonsterDamaged)
signal monster_died(monster_id: int)
signal learn_skill_result(ok: bool, reason: String)

signal party_create_result(result: PartyNet.Result)
signal party_join_result(result: PartyNet.Result)
signal party_leave_result(ok: bool, reason: String)
signal party_member_joined(member: PartyNet.MemberJoined)
signal party_member_left(character_id: int)

signal guild_create_result(result: GuildNet.Result)
signal guild_join_result(result: GuildNet.Result)
signal guild_leave_result(ok: bool, reason: String)

signal chat_message(message: ChatNet.Message)
signal chat_whisper_result(ok: bool, reason: String)
signal chat_whisper_message(message: ChatNet.Message)

signal quest_list_result(entries: Array, error: String)
signal quest_accept_result(ok: bool, reason: String)
signal quest_completed(completed: QuestNet.Completed)

var _peer: StreamPeerTCP
var _connecting := false

func _process(_delta: float) -> void:
	if _peer == null:
		return

	if _connecting:
		_peer.poll()
		var status := _peer.get_status()
		if status == StreamPeerTCP.STATUS_CONNECTED:
			_connecting = false
			connected.emit()
		elif status == StreamPeerTCP.STATUS_ERROR or status == StreamPeerTCP.STATUS_NONE:
			_connecting = false
			connection_failed.emit()
		return

	if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return

	# Drain everything currently available; Packet.read_from returns null
	# once there's not a full header buffered yet.
	while true:
		var p := Packet.read_from(_peer)
		if p == null:
			break
		_dispatch(p)

func connect_to_server(host: String, port: int) -> void:
	_peer = StreamPeerTCP.new()
	var err := _peer.connect_to_host(host, port)
	if err != OK:
		push_error("NetClient: connect_to_host failed: %s" % err)
		connection_failed.emit()
		return
	_connecting = true

func disconnect_from_server() -> void:
	if _peer != null:
		_peer.disconnect_from_host()
		_peer = null
	disconnected.emit()

func is_connected_to_server() -> bool:
	return _peer != null and _peer.get_status() == StreamPeerTCP.STATUS_CONNECTED

func _send(opcode: int, data: PackedByteArray = PackedByteArray()) -> void:
	if not is_connected_to_server():
		push_error("NetClient: _send called while not connected")
		return
	_peer.put_data(Packet.new(opcode, data).encode())

func login(username: String, password: String) -> void:
	_send(Auth.OP_LOGIN, Auth.encode_credentials(username, password))

func register_account(username: String, password: String) -> void:
	_send(Auth.OP_REGISTER, Auth.encode_credentials(username, password))

func list_characters() -> void:
	_send(CharacterNet.OP_LIST)

func create_character(char_name: String) -> void:
	_send(CharacterNet.OP_CREATE, CharacterNet.encode_name(char_name))

func delete_character(char_name: String) -> void:
	_send(CharacterNet.OP_DELETE, CharacterNet.encode_name(char_name))

func enter_world(char_name: String) -> void:
	_send(WorldNet.OP_ENTER_WORLD, WorldNet.encode_enter_world(char_name))

func move_to(x: float, y: float, z: float) -> void:
	_send(WorldNet.OP_MOVE, WorldNet.encode_move(x, y, z))

func list_inventory(char_name: String) -> void:
	_send(InventoryNet.OP_LIST, InventoryNet.encode_list_request(char_name))

func list_equipment(char_name: String) -> void:
	_send(EquipmentNet.OP_LIST, EquipmentNet.encode_list_request(char_name))

func equip(char_name: String, slot: int, inventory_slot: int) -> void:
	_send(EquipmentNet.OP_EQUIP, EquipmentNet.encode_equip(char_name, slot, inventory_slot))

func unequip(char_name: String, slot: int) -> void:
	_send(EquipmentNet.OP_UNEQUIP, EquipmentNet.encode_unequip(char_name, slot))

func shop_buy(char_name: String, item_id: int, quantity: int) -> void:
	_send(ShopNet.OP_BUY, ShopNet.encode_buy(char_name, item_id, quantity))

func attack(char_name: String, target_monster_id: int) -> void:
	_send(CombatNet.OP_ATTACK, CombatNet.encode_attack(char_name, target_monster_id))

func learn_skill(char_name: String, skill_id: int) -> void:
	_send(SkillNet.OP_LEARN, SkillNet.encode_learn(char_name, skill_id))

## Response arrives as attack_result (see SkillNet's doc comment: using a
## skill reuses OpAttackResult, since it's just an attack with a bonus).
func use_skill(char_name: String, skill_id: int, target_monster_id: int) -> void:
	_send(SkillNet.OP_USE, SkillNet.encode_use(char_name, skill_id, target_monster_id))

func create_party(char_name: String) -> void:
	_send(PartyNet.OP_CREATE, PartyNet.encode_name_request(char_name))

func join_party(char_name: String, party_id: int) -> void:
	_send(PartyNet.OP_JOIN, PartyNet.encode_join(char_name, party_id))

func leave_party(char_name: String) -> void:
	_send(PartyNet.OP_LEAVE, PartyNet.encode_name_request(char_name))

func create_guild(char_name: String, guild_name: String) -> void:
	_send(GuildNet.OP_CREATE, GuildNet.encode_create(char_name, guild_name))

func join_guild(char_name: String, guild_id: int) -> void:
	_send(GuildNet.OP_JOIN, GuildNet.encode_join(char_name, guild_id))

func leave_guild(char_name: String) -> void:
	_send(GuildNet.OP_LEAVE, GuildNet.encode_name_request(char_name))

func say(message_text: String) -> void:
	_send(ChatNet.OP_SAY, ChatNet.encode_say(message_text))

func whisper(target_name: String, message_text: String) -> void:
	_send(ChatNet.OP_WHISPER, ChatNet.encode_whisper(target_name, message_text))

func list_quests(char_name: String) -> void:
	_send(QuestNet.OP_LIST, QuestNet.encode_list_request(char_name))

func accept_quest(char_name: String, quest_id: int) -> void:
	_send(QuestNet.OP_ACCEPT, QuestNet.encode_accept(char_name, quest_id))

func _dispatch(p: Packet) -> void:
	match p.opcode:
		Auth.OP_LOGIN_RESULT:
			var r := Auth.decode_result(p.data)
			login_result.emit(r.ok, r.reason if r.error == "" else r.error)
		Auth.OP_REGISTER_RESULT:
			var r := Auth.decode_result(p.data)
			register_result.emit(r.ok, r.reason if r.error == "" else r.error)
		CharacterNet.OP_LIST_RESULT:
			var r := CharacterNet.decode_list_result(p.data)
			character_list_result.emit(r.names, r.error)
		CharacterNet.OP_CREATE_RESULT:
			var r := Auth.decode_result(p.data)
			character_create_result.emit(r.ok, r.reason if r.error == "" else r.error)
		CharacterNet.OP_DELETE_RESULT:
			var r := Auth.decode_result(p.data)
			character_delete_result.emit(r.ok, r.reason if r.error == "" else r.error)
		WorldNet.OP_ENTER_WORLD_RESULT:
			enter_world_result.emit(WorldNet.decode_enter_world_result(p.data))
		WorldNet.OP_ENTITY_ENTERED:
			entity_entered.emit(WorldNet.decode_entity_entered(p.data))
		WorldNet.OP_ENTITY_MOVED:
			entity_moved.emit(WorldNet.decode_entity_moved(p.data))
		WorldNet.OP_ENTITY_LEFT:
			entity_left.emit(WorldNet.decode_entity_left(p.data))
		InventoryNet.OP_LIST_RESULT:
			var r := InventoryNet.decode_list_result(p.data)
			inventory_list_result.emit(r.slots, r.error)
		EquipmentNet.OP_RESULT:
			var r := EquipmentNet.decode_result(p.data)
			equipment_result.emit(r.items, r.error)
		ShopNet.OP_BUY_RESULT:
			var r := ShopNet.decode_buy_result(p.data)
			shop_buy_result.emit(r.ok, r.reason if r.error == "" else r.error)
		CombatNet.OP_ATTACK_RESULT:
			attack_result.emit(CombatNet.decode_attack_result(p.data))
		CombatNet.OP_MONSTER_DAMAGED:
			monster_damaged.emit(CombatNet.decode_monster_damaged(p.data))
		CombatNet.OP_MONSTER_DIED:
			monster_died.emit(CombatNet.decode_monster_died(p.data))
		SkillNet.OP_LEARN_RESULT:
			var r := SkillNet.decode_learn_result(p.data)
			learn_skill_result.emit(r.ok, r.reason if r.error == "" else r.error)
		PartyNet.OP_CREATE_RESULT:
			party_create_result.emit(PartyNet.decode_result(p.data))
		PartyNet.OP_JOIN_RESULT:
			party_join_result.emit(PartyNet.decode_result(p.data))
		PartyNet.OP_LEAVE_RESULT:
			var r := PartyNet.decode_leave_result(p.data)
			party_leave_result.emit(r.ok, r.reason if r.error == "" else r.error)
		PartyNet.OP_MEMBER_JOINED:
			party_member_joined.emit(PartyNet.decode_member_joined(p.data))
		PartyNet.OP_MEMBER_LEFT:
			party_member_left.emit(PartyNet.decode_member_left(p.data))
		GuildNet.OP_CREATE_RESULT:
			guild_create_result.emit(GuildNet.decode_result(p.data))
		GuildNet.OP_JOIN_RESULT:
			guild_join_result.emit(GuildNet.decode_result(p.data))
		GuildNet.OP_LEAVE_RESULT:
			var r := GuildNet.decode_leave_result(p.data)
			guild_leave_result.emit(r.ok, r.reason if r.error == "" else r.error)
		ChatNet.OP_MESSAGE:
			chat_message.emit(ChatNet.decode_message(p.data))
		ChatNet.OP_WHISPER_RESULT:
			var r := ChatNet.decode_whisper_result(p.data)
			chat_whisper_result.emit(r.ok, r.reason if r.error == "" else r.error)
		ChatNet.OP_WHISPER_MESSAGE:
			chat_whisper_message.emit(ChatNet.decode_message(p.data))
		QuestNet.OP_LIST_RESULT:
			var r := QuestNet.decode_list_result(p.data)
			quest_list_result.emit(r.entries, r.error)
		QuestNet.OP_ACCEPT_RESULT:
			var r := Auth.decode_result(p.data)
			quest_accept_result.emit(r.ok, r.reason if r.error == "" else r.error)
		QuestNet.OP_COMPLETED:
			quest_completed.emit(QuestNet.decode_completed(p.data))
		_:
			push_warning("NetClient: unhandled opcode 0x%04x" % p.opcode)
