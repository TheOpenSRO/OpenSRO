extends Node

## Thin client-side wrapper around a TCP connection to the Go server,
## dispatching decoded packets (via Packet/Auth/CharacterNet/WorldNet) as
## signals for UI scenes to react to. Meant to be used as an autoload
## singleton (see project.godot) so any scene can reach it.
##
## Frame reads go through a PacketReader (see packet_reader.gd), which
## tracks partial-frame state across _process() calls instead of blocking
## the frame loop while a payload is still arriving over the wire.

signal connected
signal connection_failed
signal disconnected

## Where the last connect_to_server call went, for the login screen to
## remember and the debug panel to show. Empty until the first attempt.
var server_host := ""
var server_port := 0

signal login_result(ok: bool, reason: String)
signal register_result(ok: bool, reason: String)
signal character_list_result(characters: Array, error: String)
signal character_create_result(ok: bool, reason: String)
signal character_delete_result(ok: bool, reason: String)
signal enter_world_result(result: WorldNet.EnterWorldResult)
signal entity_entered(snapshot: WorldNet.EntitySnapshot)
signal entity_moved(moved: WorldNet.EntityMoved)
signal entity_left(character_id: int)
signal change_zone_result(result: WorldNet.ChangeZoneResult)

signal inventory_list_result(slots: Array, error: String)
## The character's own gold, vitals and equipment-derived combat numbers.
signal character_stats_result(stats: StatsNet.Stats)
## Fires for OpEquipmentList AND for equip/unequip acks -- the server uses
## one opcode/shape for all three (a successful equip/unequip ack just has
## an empty items array). Callers that need to react to "my equip request
## succeeded" specifically should track that they're awaiting one.
signal equipment_result(items: Array, error: String)
signal shop_buy_result(ok: bool, reason: String)
signal shop_list_result(entries: Array, error: String)
signal attack_result(result: CombatNet.AttackResult)
signal monster_damaged(damaged: CombatNet.MonsterDamaged)
signal monster_died(monster_id: int)
signal loot_dropped(dropped: CombatNet.LootDropped)
signal monster_list_result(monsters: Array, error: String)
## The player's character just advanced a level: its new level and its total
## unspent stat points. Sent only to the character that levelled.
signal level_up(new_level: int, stat_points: int)
signal learn_skill_result(ok: bool, reason: String)
signal skill_list_result(skills: Array, error: String)

signal party_create_result(result: PartyNet.Result)
signal party_join_result(result: PartyNet.Result)
signal party_leave_result(ok: bool, reason: String)
signal party_member_joined(member: PartyNet.MemberJoined)
signal party_member_left(character_id: int)
signal party_info_result(result: PartyNet.Result)

signal guild_create_result(result: GuildNet.Result)
signal guild_join_result(result: GuildNet.Result)
signal guild_leave_result(ok: bool, reason: String)
signal guild_info_result(result: GuildNet.Result)

signal chat_message(message: ChatNet.Message)
signal chat_whisper_result(ok: bool, reason: String)
signal chat_whisper_message(message: ChatNet.Message)

signal quest_list_result(entries: Array, error: String)
signal quest_accept_result(ok: bool, reason: String)
signal quest_completed(completed: QuestNet.Completed)

signal duel_challenge_result(ok: bool, reason: String)
signal duel_invite(invite: DuelNet.Invite)
signal duel_respond_result(ok: bool, reason: String)
signal duel_started(started: DuelNet.Started)
signal duel_declined(declined: DuelNet.Declined)
signal duel_attack_result(result: DuelNet.AttackResult)
signal duel_opponent_damaged(damaged: DuelNet.OpponentDamaged)
signal duel_ended(ended: DuelNet.Ended)

signal trade_request_result(ok: bool, reason: String)
signal trade_invite(invite: TradeNet.Invite)
signal trade_respond_result(ok: bool, reason: String)
signal trade_started(started: TradeNet.Started)
signal trade_declined(declined: TradeNet.Declined)
signal trade_offer_result(ok: bool, reason: String)
signal trade_offer_updated(updated: TradeNet.OfferUpdated)
signal trade_confirm_result(ok: bool, reason: String)
signal trade_completed(completed: TradeNet.Completed)
signal trade_cancelled(cancelled: TradeNet.Cancelled)

signal friend_request_result(ok: bool, reason: String)
signal friend_request_received(received: FriendNet.RequestReceived)
signal friend_accept_result(ok: bool, reason: String)
signal friend_accepted(accepted: FriendNet.Accepted)
signal friend_decline_result(ok: bool, reason: String)
signal friend_list_result(friends: Array, error: String)
signal friend_remove_result(ok: bool, reason: String)
signal friend_pending_list_result(requests: Array, error: String)

var _tcp_peer: StreamPeerTCP  # the real socket, always present once connecting starts
var _peer: StreamPeer         # what packets are actually read/written through -- _tcp_peer directly, or a StreamPeerTLS wrapping it once connected with use_tls
var _connecting := false
var _tls_handshaking := false
var _connected := false
var _reader: PacketReader

var _use_tls := false
var _tls_host := ""

func _process(_delta: float) -> void:
	if _tcp_peer == null:
		return

	if _connecting:
		_tcp_peer.poll()
		var status := _tcp_peer.get_status()
		if status == StreamPeerTCP.STATUS_CONNECTED:
			_connecting = false
			if _use_tls:
				var tls_peer := StreamPeerTLS.new()
				# InsecureSkipVerify-equivalent: this project's dev/local
				# setup uses self-signed certs (see gateway.Server.TLSConfig
				# in server/internal/gateway), so there's no CA chain to
				# validate against. A deployment with a real cert should
				# pass a proper TLSOptions.client() here instead.
				var tls_options := TLSOptions.client_unsafe()
				if tls_peer.connect_to_stream(_tcp_peer, _tls_host, tls_options) != OK:
					push_error("NetClient: starting TLS handshake failed")
					connection_failed.emit()
					return
				_peer = tls_peer
				_tls_handshaking = true
			else:
				_peer = _tcp_peer
				_connected = true
				connected.emit()
		elif status == StreamPeerTCP.STATUS_ERROR or status == StreamPeerTCP.STATUS_NONE:
			_connecting = false
			connection_failed.emit()
		return

	if _tls_handshaking:
		var tls_peer := _peer as StreamPeerTLS
		tls_peer.poll()
		var status := tls_peer.get_status()
		if status == StreamPeerTLS.STATUS_CONNECTED:
			_tls_handshaking = false
			_connected = true
			connected.emit()
		elif status == StreamPeerTLS.STATUS_ERROR or status == StreamPeerTLS.STATUS_ERROR_HOSTNAME_MISMATCH:
			_tls_handshaking = false
			connection_failed.emit()
		return

	if not _connected:
		return

	# Real bug found live (2026-08-26): once _connected is true, nothing
	# ever re-checked whether the underlying peer was still actually open.
	# If the connection dropped (server closed it, or the app itself is
	# mid-shutdown and the OS already tore the socket down), the loop below
	# called peer.get_available_bytes() on a closed peer every single
	# frame, producing a real, repeating engine-level error
	# ("Condition "!is_open()" is true", drivers/unix/net_socket_posix.cpp)
	# instead of a clean one-time disconnect. Checking the peer's own real
	# status before polling isn't a guess -- StreamPeerTCP/StreamPeerTLS
	# both expose get_status() for exactly this, and STATUS_CONNECTED is
	# the one real status polling should ever happen in.
	var still_connected := false
	if _tcp_peer != null:
		if _peer is StreamPeerTLS:
			still_connected = (_peer as StreamPeerTLS).get_status() == StreamPeerTLS.STATUS_CONNECTED
		else:
			still_connected = _tcp_peer.get_status() == StreamPeerTCP.STATUS_CONNECTED
	if not still_connected:
		disconnect_from_server()
		return

	# Drain everything currently available; PacketReader.poll returns null
	# once there's not a full frame buffered yet (never blocks the frame).
	while true:
		var p := _reader.poll(_peer)
		if p == null:
			break
		_dispatch(p)

## Connects to host:port. If use_tls is true, wraps the connection in TLS
## once the underlying TCP handshake completes (see gateway.Server.TLSConfig
## server-side for the matching -tls-cert/-tls-key flags) -- otherwise
## plain TCP, same as before TLS support existed.
func connect_to_server(host: String, port: int, use_tls: bool = false) -> void:
	_tcp_peer = StreamPeerTCP.new()
	_peer = null
	_reader = PacketReader.new()
	_use_tls = use_tls
	_tls_host = host
	server_host = host
	server_port = port
	_tls_handshaking = false
	_connected = false
	var err := _tcp_peer.connect_to_host(host, port)
	if err != OK:
		push_error("NetClient: connect_to_host failed: %s" % err)
		connection_failed.emit()
		return
	_connecting = true

func disconnect_from_server() -> void:
	if _peer is StreamPeerTLS:
		(_peer as StreamPeerTLS).disconnect_from_stream()
	if _tcp_peer != null:
		_tcp_peer.disconnect_from_host()
	_tcp_peer = null
	_peer = null
	_connected = false
	_tls_handshaking = false
	disconnected.emit()

func is_connected_to_server() -> bool:
	return _connected

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

func create_character(char_name: String, gender: String = "") -> void:
	_send(CharacterNet.OP_CREATE, CharacterNet.encode_create(char_name, gender))

func delete_character(char_name: String) -> void:
	_send(CharacterNet.OP_DELETE, CharacterNet.encode_name(char_name))

## The character currently in the world on this connection, if any -- set
## by enter_world(). Scenes that load after CharacterSelect (e.g. World.tscn)
## read this instead of needing the caller to pass it through
## change_scene_to_file, which has no way to carry scene-specific state.
var current_character_name := ""

## The most recent OpEnterWorldResult, cached alongside the
## enter_world_result signal for the same reason as current_character_name
## -- a scene loaded after the signal already fired still needs the data.
var last_enter_world_result: WorldNet.EnterWorldResult

## The current zone label, updated from last_enter_world_result.zone on
## entering the world and again from a successful change_zone_result --
## scenes that need to know "which real region's assets to load" (see
## World3D.gd) read this rather than tracking it themselves.
var current_zone := ""

func enter_world(char_name: String) -> void:
	current_character_name = char_name
	_send(WorldNet.OP_ENTER_WORLD, WorldNet.encode_enter_world(char_name))

func move_to(x: float, y: float, z: float) -> void:
	_send(WorldNet.OP_MOVE, WorldNet.encode_move(x, y, z))

func change_zone(zone: String) -> void:
	_send(WorldNet.OP_CHANGE_ZONE, WorldNet.encode_change_zone(zone))

func list_inventory(char_name: String) -> void:
	_send(InventoryNet.OP_LIST, InventoryNet.encode_list_request(char_name))

## Asks for the character's own gold, vitals and combat numbers.
func character_stats(char_name: String) -> void:
	_send(StatsNet.OP_STATS, StatsNet.encode_request(char_name))

func list_equipment(char_name: String) -> void:
	_send(EquipmentNet.OP_LIST, EquipmentNet.encode_list_request(char_name))

func equip(char_name: String, slot: int, inventory_slot: int) -> void:
	_send(EquipmentNet.OP_EQUIP, EquipmentNet.encode_equip(char_name, slot, inventory_slot))

func unequip(char_name: String, slot: int) -> void:
	_send(EquipmentNet.OP_UNEQUIP, EquipmentNet.encode_unequip(char_name, slot))

func shop_buy(char_name: String, item_id: int, quantity: int) -> void:
	_send(ShopNet.OP_BUY, ShopNet.encode_buy(char_name, item_id, quantity))

func list_shop() -> void:
	_send(ShopNet.OP_LIST, ShopNet.encode_list_request())

func attack(char_name: String, target_monster_id: int) -> void:
	_send(CombatNet.OP_ATTACK, CombatNet.encode_attack(char_name, target_monster_id))

func list_monsters() -> void:
	_send(CombatNet.OP_MONSTER_LIST, CombatNet.encode_monster_list())

func learn_skill(char_name: String, skill_id: int) -> void:
	_send(SkillNet.OP_LEARN, SkillNet.encode_learn(char_name, skill_id))

## Response arrives as attack_result (see SkillNet's doc comment: using a
## skill reuses OpAttackResult, since it's just an attack with a bonus).
func use_skill(char_name: String, skill_id: int, target_monster_id: int) -> void:
	_send(SkillNet.OP_USE, SkillNet.encode_use(char_name, skill_id, target_monster_id))

func list_skills(char_name: String) -> void:
	_send(SkillNet.OP_LIST, SkillNet.encode_list(char_name))

func create_party(char_name: String) -> void:
	_send(PartyNet.OP_CREATE, PartyNet.encode_name_request(char_name))

func join_party(char_name: String, party_id: int) -> void:
	_send(PartyNet.OP_JOIN, PartyNet.encode_join(char_name, party_id))

func leave_party(char_name: String) -> void:
	_send(PartyNet.OP_LEAVE, PartyNet.encode_name_request(char_name))

func party_info(char_name: String) -> void:
	_send(PartyNet.OP_INFO, PartyNet.encode_name_request(char_name))

func create_guild(char_name: String, guild_name: String) -> void:
	_send(GuildNet.OP_CREATE, GuildNet.encode_create(char_name, guild_name))

func join_guild(char_name: String, guild_id: int) -> void:
	_send(GuildNet.OP_JOIN, GuildNet.encode_join(char_name, guild_id))

func leave_guild(char_name: String) -> void:
	_send(GuildNet.OP_LEAVE, GuildNet.encode_name_request(char_name))

func guild_info(char_name: String) -> void:
	_send(GuildNet.OP_INFO, GuildNet.encode_name_request(char_name))

func say(message_text: String) -> void:
	_send(ChatNet.OP_SAY, ChatNet.encode_say(message_text))

func whisper(target_name: String, message_text: String) -> void:
	_send(ChatNet.OP_WHISPER, ChatNet.encode_whisper(target_name, message_text))

func list_quests(char_name: String) -> void:
	_send(QuestNet.OP_LIST, QuestNet.encode_list_request(char_name))

func accept_quest(char_name: String, quest_id: int) -> void:
	_send(QuestNet.OP_ACCEPT, QuestNet.encode_accept(char_name, quest_id))

func duel_challenge(char_name: String, target_name: String) -> void:
	_send(DuelNet.OP_CHALLENGE, DuelNet.encode_challenge(char_name, target_name))

func duel_respond(char_name: String, challenger_name: String, accept: bool) -> void:
	_send(DuelNet.OP_RESPOND, DuelNet.encode_respond(char_name, challenger_name, accept))

func duel_attack(char_name: String) -> void:
	_send(DuelNet.OP_ATTACK, DuelNet.encode_attack(char_name))

func trade_request(char_name: String, target_name: String) -> void:
	_send(TradeNet.OP_REQUEST, TradeNet.encode_request(char_name, target_name))

func trade_respond(char_name: String, requester_name: String, accept: bool) -> void:
	_send(TradeNet.OP_RESPOND, TradeNet.encode_respond(char_name, requester_name, accept))

func trade_set_offer(char_name: String, gold: int, item_slot: int, quantity: int) -> void:
	_send(TradeNet.OP_SET_OFFER, TradeNet.encode_set_offer(char_name, gold, item_slot, quantity))

func trade_confirm(char_name: String) -> void:
	_send(TradeNet.OP_CONFIRM, TradeNet.encode_confirm(char_name))

func trade_cancel(char_name: String) -> void:
	_send(TradeNet.OP_CANCEL, TradeNet.encode_cancel(char_name))

func friend_request(char_name: String, target_name: String) -> void:
	_send(FriendNet.OP_REQUEST, FriendNet.encode_request(char_name, target_name))

func friend_accept(char_name: String, requester_id: int) -> void:
	_send(FriendNet.OP_ACCEPT, FriendNet.encode_accept(char_name, requester_id))

func friend_decline(char_name: String, requester_id: int) -> void:
	_send(FriendNet.OP_DECLINE, FriendNet.encode_decline(char_name, requester_id))

func friend_list(char_name: String) -> void:
	_send(FriendNet.OP_LIST, FriendNet.encode_name_request(char_name))

func friend_remove(char_name: String, friend_id: int) -> void:
	_send(FriendNet.OP_REMOVE, FriendNet.encode_remove(char_name, friend_id))

func friend_pending_list(char_name: String) -> void:
	_send(FriendNet.OP_PENDING_LIST, FriendNet.encode_name_request(char_name))

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
			character_list_result.emit(r.characters, r.error)
		CharacterNet.OP_CREATE_RESULT:
			var r := Auth.decode_result(p.data)
			character_create_result.emit(r.ok, r.reason if r.error == "" else r.error)
		CharacterNet.OP_DELETE_RESULT:
			var r := Auth.decode_result(p.data)
			character_delete_result.emit(r.ok, r.reason if r.error == "" else r.error)
		WorldNet.OP_ENTER_WORLD_RESULT:
			var result := WorldNet.decode_enter_world_result(p.data)
			last_enter_world_result = result
			if result.ok:
				current_zone = result.zone
			enter_world_result.emit(result)
		WorldNet.OP_ENTITY_ENTERED:
			entity_entered.emit(WorldNet.decode_entity_entered(p.data))
		WorldNet.OP_ENTITY_MOVED:
			entity_moved.emit(WorldNet.decode_entity_moved(p.data))
		WorldNet.OP_ENTITY_LEFT:
			entity_left.emit(WorldNet.decode_entity_left(p.data))
		WorldNet.OP_CHANGE_ZONE_RESULT:
			var zone_result := WorldNet.decode_change_zone_result(p.data)
			if zone_result.ok:
				current_zone = zone_result.zone
			change_zone_result.emit(zone_result)
		InventoryNet.OP_LIST_RESULT:
			var r := InventoryNet.decode_list_result(p.data)
			inventory_list_result.emit(r.slots, r.error)
		StatsNet.OP_STATS_RESULT:
			character_stats_result.emit(StatsNet.decode_result(p.data))
		EquipmentNet.OP_RESULT:
			var r := EquipmentNet.decode_result(p.data)
			equipment_result.emit(r.items, r.error)
		ShopNet.OP_BUY_RESULT:
			var r := ShopNet.decode_buy_result(p.data)
			shop_buy_result.emit(r.ok, r.reason if r.error == "" else r.error)
		ShopNet.OP_LIST_RESULT:
			var r := ShopNet.decode_list_result(p.data)
			shop_list_result.emit(r.entries, r.error)
		CombatNet.OP_ATTACK_RESULT:
			attack_result.emit(CombatNet.decode_attack_result(p.data))
		CombatNet.OP_MONSTER_DAMAGED:
			monster_damaged.emit(CombatNet.decode_monster_damaged(p.data))
		CombatNet.OP_MONSTER_DIED:
			monster_died.emit(CombatNet.decode_monster_died(p.data))
		CombatNet.OP_LOOT_DROPPED:
			loot_dropped.emit(CombatNet.decode_loot_dropped(p.data))
		CombatNet.OP_MONSTER_LIST_RESULT:
			var r := CombatNet.decode_monster_list_result(p.data)
			monster_list_result.emit(r.monsters, r.error)
		CombatNet.OP_LEVEL_UP:
			var lu := CombatNet.decode_level_up(p.data)
			level_up.emit(lu.new_level, lu.stat_points)
		SkillNet.OP_LEARN_RESULT:
			var r := SkillNet.decode_learn_result(p.data)
			learn_skill_result.emit(r.ok, r.reason if r.error == "" else r.error)
		SkillNet.OP_LIST_RESULT:
			var r := SkillNet.decode_list_result(p.data)
			skill_list_result.emit(r.skills, r.error)
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
		PartyNet.OP_INFO_RESULT:
			party_info_result.emit(PartyNet.decode_result(p.data))
		GuildNet.OP_CREATE_RESULT:
			guild_create_result.emit(GuildNet.decode_result(p.data))
		GuildNet.OP_JOIN_RESULT:
			guild_join_result.emit(GuildNet.decode_result(p.data))
		GuildNet.OP_LEAVE_RESULT:
			var r := GuildNet.decode_leave_result(p.data)
			guild_leave_result.emit(r.ok, r.reason if r.error == "" else r.error)
		GuildNet.OP_INFO_RESULT:
			guild_info_result.emit(GuildNet.decode_result(p.data))
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
		DuelNet.OP_CHALLENGE_RESULT:
			var r := Auth.decode_result(p.data)
			duel_challenge_result.emit(r.ok, r.reason if r.error == "" else r.error)
		DuelNet.OP_INVITE:
			duel_invite.emit(DuelNet.decode_invite(p.data))
		DuelNet.OP_RESPOND_RESULT:
			var r := Auth.decode_result(p.data)
			duel_respond_result.emit(r.ok, r.reason if r.error == "" else r.error)
		DuelNet.OP_STARTED:
			duel_started.emit(DuelNet.decode_started(p.data))
		DuelNet.OP_DECLINED:
			duel_declined.emit(DuelNet.decode_declined(p.data))
		DuelNet.OP_ATTACK_RESULT:
			duel_attack_result.emit(DuelNet.decode_attack_result(p.data))
		DuelNet.OP_OPPONENT_DAMAGED:
			duel_opponent_damaged.emit(DuelNet.decode_opponent_damaged(p.data))
		DuelNet.OP_ENDED:
			duel_ended.emit(DuelNet.decode_ended(p.data))
		TradeNet.OP_REQUEST_RESULT:
			var r := Auth.decode_result(p.data)
			trade_request_result.emit(r.ok, r.reason if r.error == "" else r.error)
		TradeNet.OP_INVITE:
			trade_invite.emit(TradeNet.decode_invite(p.data))
		TradeNet.OP_RESPOND_RESULT:
			var r := Auth.decode_result(p.data)
			trade_respond_result.emit(r.ok, r.reason if r.error == "" else r.error)
		TradeNet.OP_STARTED:
			trade_started.emit(TradeNet.decode_started(p.data))
		TradeNet.OP_DECLINED:
			trade_declined.emit(TradeNet.decode_declined(p.data))
		TradeNet.OP_OFFER_RESULT:
			var r := Auth.decode_result(p.data)
			trade_offer_result.emit(r.ok, r.reason if r.error == "" else r.error)
		TradeNet.OP_OFFER_UPDATED:
			trade_offer_updated.emit(TradeNet.decode_offer_updated(p.data))
		TradeNet.OP_CONFIRM_RESULT:
			var r := Auth.decode_result(p.data)
			trade_confirm_result.emit(r.ok, r.reason if r.error == "" else r.error)
		TradeNet.OP_COMPLETED:
			trade_completed.emit(TradeNet.decode_completed(p.data))
		TradeNet.OP_CANCELLED:
			trade_cancelled.emit(TradeNet.decode_cancelled(p.data))
		FriendNet.OP_REQUEST_RESULT:
			var r := Auth.decode_result(p.data)
			friend_request_result.emit(r.ok, r.reason if r.error == "" else r.error)
		FriendNet.OP_REQUEST_RECEIVED:
			friend_request_received.emit(FriendNet.decode_request_received(p.data))
		FriendNet.OP_ACCEPT_RESULT:
			var r := Auth.decode_result(p.data)
			friend_accept_result.emit(r.ok, r.reason if r.error == "" else r.error)
		FriendNet.OP_ACCEPTED:
			friend_accepted.emit(FriendNet.decode_accepted(p.data))
		FriendNet.OP_DECLINE_RESULT:
			var r := Auth.decode_result(p.data)
			friend_decline_result.emit(r.ok, r.reason if r.error == "" else r.error)
		FriendNet.OP_LIST_RESULT:
			var r := FriendNet.decode_list_result(p.data)
			friend_list_result.emit(r.friends, r.error)
		FriendNet.OP_REMOVE_RESULT:
			var r := Auth.decode_result(p.data)
			friend_remove_result.emit(r.ok, r.reason if r.error == "" else r.error)
		FriendNet.OP_PENDING_LIST_RESULT:
			var r := FriendNet.decode_pending_list_result(p.data)
			friend_pending_list_result.emit(r.requests, r.error)
		_:
			push_warning("NetClient: unhandled opcode 0x%04x" % p.opcode)
