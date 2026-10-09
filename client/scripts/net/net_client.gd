extends Node

## Thin client-side wrapper around a TCP connection to the Go server,
## dispatching decoded packets (via Packet/Auth/CharacterNet/WorldNet) as
## signals for UI scenes to react to. Meant to be used as an autoload
## singleton (see project.godot) so any scene can reach it.
##
## Frame reads go through a PacketReader (see packet_reader.gd), which
## buffers what has arrived across _process() calls instead of blocking
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
## The lobby (round 682, LobbyNet): characters are LobbyNet.Character. A
## refusal's reason is LobbyNet.code_text of its code, in lobby_text's words
## when a screen has loaded the archive's table.
signal character_list_result(characters: Array, error: String)
signal character_create_result(ok: bool, reason: String)
signal character_delete_result(ok: bool, reason: String)
signal character_restore_result(ok: bool, reason: String)
signal name_check_result(ok: bool, reason: String)
## Every 0xB007, whole, for screens that want the code rather than words.
signal lobby_result(result: LobbyNet.Result)
## 0xB001: ok, or the refusal's code and words. An OK is followed by the
## enter-world result.
signal start_result(ok: bool, code: int, reason: String)
signal enter_world_result(result: WorldNet.EnterWorldResult)
signal entity_entered(snapshot: WorldNet.EntitySnapshot)
## Round 739's review (F5): around a group spawn's players, so World3D queues
## the page whole before it dresses any (its arrival build pump, nearest first).
signal user_group_begin
signal user_group_end
signal entity_moved(moved: WorldNet.EntityMoved)
## Round 749 (DestMoveNet): retail's 0xB021, an accepted move -- to the 3 x 3
## blocks, this player's own included -- with its world points resolved
## (echo.dest_world, echo.source_world); and 0xB023, a stop or placement the
## server tells the window (stop.world), this player's own when the server
## did not take a stop or placement it was told.
signal entity_move_echo(echo: DestMoveNet.Echo)
signal entity_move_stop(stop: DestMoveNet.Stop)
signal entity_left(character_id: int)
signal change_zone_result(result: WorldNet.ChangeZoneResult)
## A character's state changed (WorldNet.OP_STATE_CHANGE, round 607): kind 1 is
## the motion state -- someone sat down or stood up, this player included.
signal state_changed(change: WorldNet.StateChange)

signal inventory_list_result(slots: Array, error: String)
## The most recent inventory/equipment list's per-slot durability
## (InventoryNet.Durability), stashed rather than threaded through every
## signal. Empty against a server too old to send the trailing block.
var last_inventory_durabilities: Array = []
var last_equipment_durabilities: Array = []
## The bag's size in slots from the most recent bag list or move reply (their
## trailing capacity, round 633); 0 until a server that sends it answers.
var last_inventory_capacity: int = 0
## Each equipment item's own data -- plus, variance, blue options, advanced
## elixir -- from the most recent bag, equipment and warehouse lists (round
## 732): slot -> ItemInstance, for the item tooltip. Empty against an older
## server.
var last_inventory_instances: Dictionary = {}
var last_equipment_instances: Dictionary = {}
var last_storage_instances: Dictionary = {}
var _logged_instances: Dictionary = {}
## The bag after a move_item (the server's own list, not an assumption), or
## why the move was refused.
signal inventory_move_result(slots: Array, error: String)
## The character's own gold, vitals and equipment-derived combat numbers.
signal character_stats_result(stats: StatsNet.Stats)
## Fires for OpEquipmentList AND for equip/unequip replies -- the server uses
## one opcode/shape for all three. A successful equip/unequip is answered
## with the worn list itself (the server's sendWornList), so an empty list
## means nothing is worn; only a refusal carries an error and no list.
## Callers that need to react to "my equip request succeeded" specifically
## should track that they're awaiting one.
signal equipment_result(items: Array, error: String)
## A repair's outcome: 0 = repaired, otherwise a refusal code; the gold spent
## and the worn slots' durability afterwards (EquipmentNet.RepairResult).
signal repair_result(code: int, gold_spent: int, durabilities: Array)
## Round 735 (lane A's hook for the glow): another player's worn item changed
## -- retail 0x3038 (put on, or its plus changed: `ref_id` and `plus` >= 0) or
## 0x3039 (taken off from `slot`, the message's own slot byte as retail's
## FUN_008a9560 uses it: `plus` -1). The server sends them to the mover too, as
## retail does; World3D skips its own uid (its equipment result redrew it). `uid` is retail's u32 unique id, the low 32
## bits of the character id (WorldNet.EntitySnapshot.character_id & 0xffffffff);
## `slot` the equip slot (EquipmentNet.SLOT_*); `plus` the effective plus
## (OptLevel + advanced elixir). World3D redresses the body from it
## (_on_other_equipment_changed) and keeps the plus in _other_pluses.
signal other_player_equipment_changed(uid: int, slot: int, ref_id: int, plus: int)
signal shop_buy_result(ok: bool, reason: String)
signal shop_list_result(entries: Array, error: String)
signal shop_sell_result(ok: bool, reason: String, gold_received: int)
## Round 728: the retail item operation's result (0xB034), ItemOpNet.decode_result.
signal item_op_result(result: Dictionary)
## Round 728: a buy back's failure (0xB168), the code.
signal buyback_failed(code: int)
## capacity is the warehouse's slot count (0 from a server that did not send it).
signal storage_list_result(slots: Array, error: String, capacity: int)
signal storage_deposit_result(ok: bool, reason: String)
signal storage_withdraw_result(ok: bool, reason: String)
signal storage_gold_result(ok: bool, reason: String, carried: int, stored: int)
signal attack_result(result: CombatNet.AttackResult)
signal berserk_result(activated: bool, gauge: int, active: bool)
signal monster_damaged(damaged: CombatNet.MonsterDamaged)
signal monster_died(monster_id: int)
## An object's abnormal-state mask (round 659, StatusNet: retail's 0x3057).
signal object_status(status: StatusNet.ObjectStatus)
signal loot_dropped(dropped: CombatNet.LootDropped)
signal monster_list_result(monsters: Array, error: String)
## Round 656: monsters that left the player's area of interest, to be dropped
## without a death.
signal monster_left(ids: Array)
## The pages of a monster list gathered so far (round 656): a list too big for
## one frame arrives as several, and monster_list_result fires once, on the
## last, with all of them.
var _monster_list_pages: Array = []
## OpenSRO's own monster movement (CombatNet.OP_MONSTER_MOVED /
## OP_MONSTER_MOTION_LIST): one monster's new leg, and the legs of the listed
## monsters sent right after a monster list. The server sends both only with
## its -monster-ai flag on (off by default).
signal monster_moved(moved: CombatNet.MonsterMoved)
signal monster_motion_list(entries: Array)
## OpenSRO's own monster pushes (CombatNet.OP_MONSTER_ATTACKED /
## OP_MONSTER_SPAWNED): one monster's blow on a player, sent to the whole zone
## with the attacker included, and a monster that has just appeared. No server
## sends either yet (round 540 built this half first).
signal monster_attacked(attacked: CombatNet.MonsterAttacked)
signal monster_spawned(spawned: CombatNet.MonsterSpawned)
## The player's own revive (WorldNet.OP_REVIVE_RESULT, round 548): the HP and
## MP the character came back with, or the server's refusal. Only a server
## with its -player-dead-state flag on sends it (the dead state's server
## half; off by default), and only after an OpRevive from this client: since
## round 665 nothing revives a dead player unasked.
signal revive_result(result: WorldNet.ReviveResult)
## Items on the ground (GroundItemsNet): the zone's list, one appearing, one
## leaving (picked or expired), one whose owner window passed, and the
## outcome of our own pick-up.
signal ground_item_list_result(items: Array, error: String)
signal ground_item_spawned(item: GroundItemsNet.Snapshot)
signal ground_item_removed(removed: GroundItemsNet.Removed)
signal ground_item_owner_released(ground_id: int)
signal pick_up_result(result: GroundItemsNet.PickUpResult)
## The player's character just advanced a level: its new level and its total
## unspent stat points. Sent only to the character that levelled.
signal level_up(new_level: int, stat_points: int)
## Round 716: retail 0x3056, what a kill (or any award) gained this character.
signal exp_gained(gain: RewardNoticeNet.ExpGain)
## Round 716: retail 0x304E kind 1, the character's new gold total.
signal gold_total(total: int, show: bool)
signal learn_skill_result(ok: bool, reason: String)
## The same answer with the skill it was for (round 639): the result names no
## skill, so the ids are queued as the requests go out and matched in order
## (the server answers each request in turn). The quick-slot bar's rebind
## (HotbarStore.rebind_for_skill) needs the id.
signal learn_skill_done(skill_id: int, ok: bool)
var _pending_learns: Array[int] = []
signal skill_list_result(skills: Array, error: String)
signal skill_state_result(state: SkillNet.SkillState)
signal raise_mastery_result(result: SkillNet.RaiseMasteryResult)
## Buffs and skill moves (round 617; the skills epic's shared contract,
## SkillNet has the byte layouts). Round 618's buff bar and round 619's auras
## consume these -- the names are part of that contract, keep them:
##   buff_started(start: SkillNet.BuffStart)  OpBuffStart 0x00F5: a buff began
##     on an owner (character or monster), keyed (owner_id, token), with its
##     duration, the time left, and the owner's new run speed (0 = unchanged).
##   buff_ended(ended: SkillNet.BuffEnd)      OpBuffEnd 0x00F6: tokens ended on
##     an owner, and its new run speed (0 = unchanged).
##   skill_moved(moved: SkillNet.SkillMove)   OpSkillMove 0x00F8: a skill (Ghost
##     Walk) put a character at a point, in OpMove's coordinates.
## A payload too short for its layout is dropped with a warning, not emitted.
## The one sender that goes with them is send_buff_cancel(skill_id, token)
## (OpBuffCancel 0x00F7, the buff icon's right-click).
##   self_id_received(character_id: int)      OpSelfId 0x00F9, on world entry:
##     this client's own character id (also kept in own_character_id).
## OpBuffStart / OpBuffEnd carry a trailing ownerKind (SkillNet.OWNER_*).
signal buff_started(start: SkillNet.BuffStart)
## Every owner's active buffs as this connection was last told (round 646,
## BuffRoster): kept here, beside the connection, so a scene built after the
## server's in-view buffs arrived (World3D, swapped in by CharacterSelect on
## OpEnterWorldResult) can replay them, and a body rebuilt later can take its
## auras back. Updated before buff_started / buff_ended / entity_left /
## change_zone_result are emitted.
var buff_roster := BuffRoster.new()
## Round 708: every NPC the server has spawned for this connection (the retail
## spawn messages, NpcSpawnNet). Kept here for the same reason as buff_roster;
## World3D builds its NPCs from it and from npc_spawned / npc_despawned.
var npc_roster := NpcSpawnNet.Roster.new()
signal npc_spawned(rec: NpcSpawnNet.Record)
signal npc_despawned(uid: int)
## Round 737 (crowd_scale.md C1): the other players in view arrive as the
## same retail spawn messages, with a CICUser record (UserSpawnNet), and leave
## by 0x3016 / a type-2 group. user_roster is the uids spawned and not
## despawned (a despawn's uid is a player's when it is here, else an NPC's).
## A player record is read with World3D's item table (_spawn_types, handed
## over by set_spawn_item_rows); the spawns that come before it wait in
## _pending_spawns, in order. _spawn_frame is the frame the records' region
## coordinates are turned into world ones in: the last result's FrameRegion.
var user_roster := {}
## Round 737's review: the uids an OpPlayerZoneNotice named as arriving in the
## zone (the next spawn of each is a real arrival) and as leaving it (World3D
## reads and erases the entry when the despawn comes).
var _zone_arrivals := {}
var zone_departures := {}
const OP_PLAYER_ZONE_NOTICE := 0x00b7
## Round 749's verification (FP6; OURS, retail has no such command): /unstuck
## is the server's -- the client asks (empty), the server puts the character
## at its zone's landing spot with its own 0xB023 and answers u8 ok, u16 the
## seconds until it may be asked again (server/internal/session/unstuck.go).
const OP_UNSTUCK := 0x00b8
const OP_UNSTUCK_RESULT := 0x00b9
signal unstuck_result(ok: bool, wait_seconds: int)
## Every other character's abnormal states as last told (0x3057 for a
## character; uid -> StatusNet.ObjectStatus), so a scene that was not
## listening -- World3D at the world entry, or during a zone change's load,
## which clears its own -- can take them back (round 737's review: a spawn's
## states follow it).
var character_states := {}
## OPENSRO_QA_SPAWN_LOG=1 prints one line per player spawned or despawned
## (live checks); off, only one line per group.
var _spawn_log := OS.get_environment("OPENSRO_QA_SPAWN_LOG") != ""
var _spawn_types: UserSpawnNet.Types = null
var _pending_spawns: Array = []
## Round 762 (QA, counted only while FrameSplit is on): every packet's bytes
## (its 6-byte header and data) and count since the boot, and each player
## group spawn's records, bytes and the clock when its 0x3018 was read
## (`QA NET group` lines), for QaCrowdProbe's arrival timeline.
## Round 762 (OURS): a player group spawn is read and handed to World3D a
## frame's GROUP_STEP_USEC at a time (one record at least), and nothing
## after it is dispatched until it is all read -- the order stays the
## server's. Retail reads a group's every record in its one 0x3018 call
## (READ, FUN_008a6d20); here a record is about 20 us of GDScript to read
## (MEASURED, tools/group_decode_bench.gd: 4,000 in 84 ms) and its arrival
## more, so a crowd's window in one frame was a frame of hundreds of ms.
## And a frame's dispatch stops after NET_FRAME_BUDGET_USEC (one packet at
## least); the rest stays in the socket for the next frame.
const GROUP_STEP_USEC := 4000
const NET_FRAME_BUDGET_USEC := 8000
## The group being read: {r: the reader, count, i: records read, op}, or null.
var _group_job = null
## Whether spawn messages are being replayed (set_spawn_item_rows): a group
## then is read whole, in order with what follows it.
var _replaying := false
static var qa_rx_bytes := 0
static var qa_rx_packets := 0
static var qa_group_players := 0
static var qa_groups := 0
var _spawn_frame := Vector2i(-1, -1)
## Every character's berserk body mode (0x30BF kind 4) as this connection was
## last told (round 651): character id -> 1 while berserk. Kept, cleared and
## dropped with buff_roster, and for the same reason -- the server's in-view
## replay can arrive before World3D listens, and a body built later takes it
## (World3D._berserk_resync). Updated before state_changed is emitted.
var body_modes := {}
signal self_id_received(character_id: int)
## This client's own character id from OpSelfId; -1 until one arrives on this
## connection (and from a server that does not send it).
var own_character_id := -1
signal buff_ended(ended: SkillNet.BuffEnd)
signal skill_moved(moved: SkillNet.SkillMove)
## OpSkillCast 0x00FA (round 622): another player (or a monster) in the zone
## cast a skill -- its start, then its act.
signal skill_cast(cast: SkillNet.SkillCast)

## The party (round 711): the client's party manager, fed by the retail party
## messages (PartyNet, PartyState). Windows read it and listen to its signals;
## it lives here so a message that arrives before World3D listens is kept.
var party := PartyState.new()
## Opcodes another module answers (round 711's hook for the party-match
## lane): opcode -> Callable(data: PackedByteArray). Checked before the
## "unhandled" warning, after every opcode this file routes itself.
var _extra_handlers := {}

signal guild_create_result(result: GuildNet.Result)
signal guild_join_result(result: GuildNet.Result)
signal guild_leave_result(ok: bool, reason: String)
signal guild_info_result(result: GuildNet.Result)
## The guild's points (round 525): GatheredSP and each member's GP_Donation.
signal guild_points_result(result: GuildNet.PointsResult)
## The guild's level and the next level's cost, or a level-up's outcome
## (round 528).
signal guild_level_result(result: GuildNet.LevelResult)

## A chat line arrived (round 634): any type -- ordinary, whisper, party,
## guild, global, notice.
signal chat_update(update: ChatNet.Update)
## A unique monster appeared or was killed somewhere in the world (round 657,
## retail 0x300C's 0x0C05 / 0x0C06).
signal unique_notice(notice: UniqueNoticeNet.Notice)
## The server's answer to a line this client sent (0xB025's fields).
signal chat_result(result: ChatNet.Result)

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
## Using a consumable: what it restored, and how many are left.
signal use_item_result(result: UseItemNet.Result)
## The Energy of life scroll's grants (round 632 review, CompositeNet).
signal composite_state(state: CompositeNet.State)
signal composite_use_result(result: CompositeNet.UseResult)
## A grant ended (expired or consumed): drop its icon (retail 0x315B).
signal composite_ended(item_id: int, scroll_id: int)

## The GM console's reply (GmNet.Result): whether this account is a GM, the
## text to print, and any place to move to / views to refresh.
signal gm_command_result(result: GmNet.Result)
## A gate teleport's receipt (TeleportNet.Result, round 576): the fee charged
## and the destination, or the refusal. On success the server's
## OpChangeZoneResult follows it (change_zone_result).
signal teleport_result(result: TeleportNet.Result)
## A town gate's "Designate as return/recall point" answered (RecallNet.Result,
## round 686): ok, or the refusal's code.
signal recall_designate_result(result: RecallNet.Result)

var _tcp_peer: StreamPeerTCP  # the real socket, always present once connecting starts
var _peer: StreamPeer         # what packets are actually read/written through -- _tcp_peer directly, or a StreamPeerTLS wrapping it once connected with use_tls
var _connecting := false
var _tls_handshaking := false
var _connected := false
var _reader: PacketReader

var _use_tls := false
var _tls_host := ""
## A host name being resolved before the TCP connect (round 679's review),
## or -1; the port it is for.
var _resolve_id := -1
var _resolve_port := 0

func _process(_delta: float) -> void:
	_check_list_timeout(Time.get_ticks_msec())
	if _tcp_peer == null:
		return

	if _resolve_id >= 0:
		_poll_resolve()
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
	# Each poll takes whatever the peer holds into the reader's own buffer
	# (round 663), so a frame larger than what the socket -- or one TLS
	# record -- holds at once still comes through.
	# Round 759 (QA, FrameSplit only): the read and the dispatch timed apart,
	# and each opcode's count and dispatch time (FrameSplit.op).
	var fs := FrameSplit.on
	# Round 762: a group being read goes on first; nothing after it is
	# dispatched until it is done.
	var frame_t0 := Time.get_ticks_usec()
	if _group_job != null:
		var tg := Time.get_ticks_usec()
		var done := _group_step()
		if fs:
			FrameSplit.add("net_dispatch", Time.get_ticks_usec() - tg)
		if not done:
			# The socket emptied all the same (PacketReader.drain).
			_reader.drain(_peer)
			return
	var dispatched := 0
	while true:
		if _group_job != null or (dispatched > 0 and Time.get_ticks_usec() - frame_t0 >= NET_FRAME_BUDGET_USEC):
			# What is not dispatched this frame waits in the reader's buffer,
			# the socket emptied (PacketReader.drain).
			_reader.drain(_peer)
			break
		dispatched += 1
		var t0 := Time.get_ticks_usec() if fs else 0
		var p := _reader.poll(_peer)
		if p == null:
			if fs:
				FrameSplit.add("net_read", Time.get_ticks_usec() - t0)
			break
		if not fs:
			_dispatch(p)
			continue
		var t1 := Time.get_ticks_usec()
		qa_rx_bytes += p.data.size() + 6
		qa_rx_packets += 1
		_dispatch(p)
		var t2 := Time.get_ticks_usec()
		FrameSplit.add("net_read", t1 - t0)
		FrameSplit.add("net_dispatch", t2 - t1)
		FrameSplit.add("net_packets_calls", 1)
		FrameSplit.op(p.opcode, t2 - t1)

## Connects to host:port. If use_tls is true, wraps the connection in TLS
## once the underlying TCP handshake completes (see gateway.Server.TLSConfig
## server-side for the matching -tls-cert/-tls-key flags) -- otherwise
## plain TCP, same as before TLS support existed.
func connect_to_server(host: String, port: int, use_tls: bool = false) -> void:
	_tcp_peer = StreamPeerTCP.new()
	_peer = null
	_reader = PacketReader.new()
	_attack_targets_in_flight.clear()
	_attack_types_in_flight.clear()
	own_character_id = -1
	buff_roster.clear()
	npc_roster.clear()
	user_roster.clear()
	character_states.clear()
	_zone_arrivals.clear()
	zone_departures.clear()
	_pending_spawns.clear()
	_group_job = null
	body_modes.clear()
	party.reset_connection()
	_unhandled_warned.clear()
	_use_tls = use_tls
	_tls_host = host
	server_host = host
	server_port = port
	_tls_handshaking = false
	_connected = false
	_cancel_resolve()
	if host.is_valid_ip_address():
		_connect_ip(host, port)
		return
	# A host name is resolved first, without blocking, and its IPv4 address
	# preferred -- the same path the server list's status takes
	# (GatewayQuery.pick_address), so the server a row says answers is the
	# one Connect reaches (round 679's review: "localhost" showed Check, then
	# Connect went to ::1 and failed). connect_to_host would resolve it
	# synchronously and take the first address of any family. The TLS name
	# stays the host name.
	_resolve_id = IP.resolve_hostname_queue_item(host)
	_resolve_port = port
	_connecting = true

func _connect_ip(ip: String, port: int) -> void:
	var err := _tcp_peer.connect_to_host(ip, port)
	if err != OK:
		push_error("NetClient: connect_to_host failed: %s" % err)
		_connecting = false
		connection_failed.emit()
		return
	_connecting = true

func _poll_resolve() -> void:
	match IP.get_resolve_item_status(_resolve_id):
		IP.RESOLVER_STATUS_WAITING:
			return
		IP.RESOLVER_STATUS_DONE:
			var ip := GatewayQuery.pick_address(IP.get_resolve_item_addresses(_resolve_id))
			_cancel_resolve()
			if ip == "":
				_connecting = false
				print("NetClient: %s did not resolve" % server_host)
				connection_failed.emit()
				return
			print("NetClient: %s -> %s" % [server_host, ip])
			_connect_ip(ip, _resolve_port)
		_:
			_cancel_resolve()
			_connecting = false
			print("NetClient: %s did not resolve" % server_host)
			connection_failed.emit()

func _cancel_resolve() -> void:
	if _resolve_id >= 0:
		IP.erase_resolve_item(_resolve_id)
		_resolve_id = -1

func _keep_guild(result: GuildNet.Result) -> void:
	if result != null and result.error == "":
		last_guild_result = result

func disconnect_from_server() -> void:
	_cancel_resolve()
	_connecting = false
	if _peer is StreamPeerTLS:
		(_peer as StreamPeerTLS).disconnect_from_stream()
	if _tcp_peer != null:
		_tcp_peer.disconnect_from_host()
	_tcp_peer = null
	_peer = null
	_connected = false
	_tls_handshaking = false
	_stats_requests_pending = 0
	_attack_targets_in_flight.clear()
	_attack_types_in_flight.clear()
	_pending_learns.clear()
	own_character_id = -1
	buff_roster.clear()
	npc_roster.clear()
	user_roster.clear()
	character_states.clear()
	_zone_arrivals.clear()
	zone_departures.clear()
	_pending_spawns.clear()
	_group_job = null
	body_modes.clear()
	party.reset_connection()
	_forget_session_lists()
	_list_watch.answered()
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

## The archive's UI text, when a screen has loaded it, for the lobby's
## refusals (LobbyNet.code_text); null gives our own words.
var lobby_text: UiTextTable = null

## The list request outstanding, if any (round 682's review): unanswered
## after LobbyNet.LIST_TIMEOUT_MS, character_list_result says so.
var _list_watch := LobbyNet.ListWatch.new()

func list_characters() -> void:
	_list_watch.arm(Time.get_ticks_msec())
	_send(LobbyNet.OP_LOBBY, LobbyNet.encode_list())

## Called every frame: a list request left unanswered is reported once, as an
## empty list with LobbyNet.LIST_TIMEOUT_TEXT.
func _check_list_timeout(now_ms: int) -> void:
	if _list_watch.expired(now_ms):
		print("NetClient: no answer to the character list in %d ms" % LobbyNet.LIST_TIMEOUT_MS)
		character_list_result.emit([], LobbyNet.LIST_TIMEOUT_TEXT)

## The retail create (0x7007 action 1): a body, a scale byte, and the chest,
## legs, feet and weapon.
func create_character_full(char_name: String, ref_obj_id: int, scale: int, chest: int, legs: int, feet: int, weapon: int) -> void:
	_send(LobbyNet.OP_LOBBY, LobbyNet.encode_create(char_name, ref_obj_id, scale, chest, legs, feet, weapon))

## Today's create screen, which picks only a sex: CharacterNet.INTERIM_KIT's
## body and items for it at the default scale (OURS, until round 685).
func create_character(char_name: String, gender: String = "") -> void:
	var kit: Dictionary = CharacterNet.INTERIM_KIT.get(gender, CharacterNet.INTERIM_KIT[CharacterNet.GENDER_CHINA_MAN])
	create_character_full(char_name, int(kit["model"]), CharacterNet.DEFAULT_SCALE,
		int(kit["chest"]), int(kit["legs"]), int(kit["feet"]), int(kit["weapon"]))

func delete_character(char_name: String) -> void:
	_send(LobbyNet.OP_LOBBY, LobbyNet.encode_named(LobbyNet.ACTION_DELETE, char_name))

func restore_character(char_name: String) -> void:
	_send(LobbyNet.OP_LOBBY, LobbyNet.encode_named(LobbyNet.ACTION_RESTORE, char_name))

func check_character_name(char_name: String) -> void:
	_send(LobbyNet.OP_LOBBY, LobbyNet.encode_named(LobbyNet.ACTION_NAME_CHECK, char_name))

## The character currently in the world on this connection, if any -- set
## by enter_world(). Scenes that load after CharacterSelect (e.g. World.tscn)
## read this instead of needing the caller to pass it through
## change_scene_to_file, which has no way to carry scene-specific state.
var current_character_name := ""

## The most recent OpEnterWorldResult, cached alongside the
## enter_world_result signal for the same reason as current_character_name
## -- a scene loaded after the signal already fired still needs the data.
var last_enter_world_result: WorldNet.EnterWorldResult

## The player's guild as the last guild reply said -- a guild_info, create
## or join reply without an error, or a guild with id 0 after a successful
## leave -- and the last friend list; null / not had until one arrives. Kept
## for a window built after the reply (World3D asks for both before the
## loading screen and builds HudPanels after it). Cleared on entering the
## world and on disconnecting.
var last_guild_result: GuildNet.Result = null
var last_friend_list: Array = []
var has_friend_list := false
## The last quest list reply without an error, kept for the same reason:
## World3D asks for it before the loading screen, and the quest window is
## built after it. Cleared with the others.
var last_quest_list: Array = []
var has_quest_list := false

func _forget_session_lists() -> void:
	last_guild_result = null
	last_friend_list = []
	has_friend_list = false
	last_quest_list = []
	has_quest_list = false

## The current zone label, updated from last_enter_world_result.zone on
## entering the world and again from a successful change_zone_result --
## scenes that need to know "which real region's assets to load" (see
## World3D.gd) read this rather than tracking it themselves.
var current_zone := ""

func enter_world(char_name: String) -> void:
	current_character_name = char_name
	_forget_session_lists()
	# The OpSelfId that answers this entry names the character entering now.
	own_character_id = -1
	# Start (round 682): 0x7001, answered by 0xB001 and, when it is OK, the
	# enter-world result.
	_send(LobbyNet.OP_START, LobbyNet.encode_start(char_name))

## `heading_wire` (round 653) is a heading run's u16 wire angle
## (SkyRun.wire_angle), or -1 for a position with no run in effect.
func move_to(x: float, y: float, z: float, relocated: bool = false, heading_wire: int = -1) -> void:
	_send(WorldNet.OP_MOVE, WorldNet.encode_move(x, y, z, relocated, heading_wire))

## Round 749: where the player's walk stopped short of the destination its
## 0x7021 named (WorldNet.MOVE_FLAG_STOPPED, OURS) -- the server takes it on
## its own leg and tells the window with retail's 0xB023.
## Round 749's verification (FP6): asks the server to put the character at its
## zone's landing spot (OP_UNSTUCK; answered by unstuck_result).
func request_unstuck() -> void:
	_send(OP_UNSTUCK)

func report_stop(x: float, y: float, z: float) -> void:
	_send(WorldNet.OP_MOVE, WorldNet.encode_move(x, y, z, false, -1, true))

## Round 749: retail's click move, 0x7021's destination form, for the world
## point `at` in the frame the server named (the last result's FrameRegion):
## the region and the local coordinates truncated (FUN_009ec080). Returns the
## world point the server will walk to -- the truncated one -- or
## Vector3.INF when no frame is known (nothing is sent).
func move_order_destination(at: Vector3) -> Vector3:
	if _spawn_frame.x < 0:
		return Vector3.INF
	var l := DestMoveNet.local_of_world(at.x, at.z, _spawn_frame)
	_send(DestMoveNet.OP_MOVEMENT_REQUEST, DestMoveNet.encode_destination(int(l["region"]), float(l["lx"]), at.y, float(l["lz"])))
	return quantize_destination(at)

## Round 749's review, F5: the world point the server will take for a
## destination `at` -- the region-local coordinates truncated as the wire
## carries them, turned back into world ones -- without sending anything, so
## the client's 5.0 rule compares what the server compares. Vector3.INF when
## no frame is known.
func quantize_destination(at: Vector3) -> Vector3:
	if _spawn_frame.x < 0:
		return Vector3.INF
	var l := DestMoveNet.local_of_world(at.x, at.z, _spawn_frame)
	var lx := float(int(float(l["lx"])))
	var lz := float(int(float(l["lz"])))
	var w := DestMoveNet.world_of_local(int(l["region"]), lx, lz, _spawn_frame)
	return Vector3(w.x, float(int(at.y)), w.y)

## Round 749: 0x7021's heading form (the sky click, FUN_009ebec0): kind 0,
## the command (SkyRun.COMMAND_FORWARD) and the u16 wire angle.
func move_order_heading(command: int, angle: int) -> void:
	_send(DestMoveNet.OP_MOVEMENT_REQUEST, DestMoveNet.encode_heading(command, angle))

## Asks to sit down or stand up (WorldNet.OP_MOTION_REQUEST [4], the N key).
func request_motion(value: int) -> void:
	_send(WorldNet.OP_MOTION_REQUEST, WorldNet.encode_motion_request(value))

func change_zone(zone: String) -> void:
	_send(WorldNet.OP_CHANGE_ZONE, WorldNet.encode_change_zone(zone))

## Asks to be revived (WorldNet.OP_REVIVE) with retail's option: 1 at the
## return point, 2 where the character lies (round 665). Sent by the dead
## window's buttons or the OPENSRO_QA_REVIVE_AFTER hook. The reply is
## revive_result -- after the zone change to the return point for option 1.
func revive(option: int) -> void:
	_send(WorldNet.OP_REVIVE, WorldNet.encode_revive(option))

func list_inventory(char_name: String) -> void:
	_send(InventoryNet.OP_LIST, InventoryNet.encode_list_request(char_name))

## Moves the stack in one bag slot onto another (a drag in the inventory
## window). The server decides whether that is a move, a merge or a swap and
## answers with the whole bag -- see inventory_move_result.
func move_item(char_name: String, from_slot: int, to_slot: int) -> void:
	_send(InventoryNet.OP_MOVE, InventoryNet.encode_move_request(char_name, from_slot, to_slot))

## Asks for the character's own gold, vitals and combat numbers.
func character_stats(char_name: String) -> void:
	_stats_requests_pending += 1
	_send(StatsNet.OP_STATS, StatsNet.encode_request(char_name))

## Round 716's review: the stats replies this client asked for and has not
## yet seen, so a reply can be told from the server's unprompted pushes (the
## regen and status ticks). The 0x304E gold line's base moves only on gold
## messages and on replies this client asked for, never on a push that may
## carry a total the gold message has not yet announced.
var _stats_requests_pending := 0
## Whether the newest stats reply answered one of this client's requests.
var last_stats_reply_requested := false

## Spends unspent stat points on Strength and/or Intellect. The server
## applies the engine's rule (the sum must fit the pool; plain increments)
## and answers with a character_stats_result carrying the new numbers.
func spend_stat_points(char_name: String, str_points: int, int_points: int) -> void:
	_stats_requests_pending += 1
	_send(StatsNet.OP_SPEND_STAT, StatsNet.encode_spend_request(char_name, str_points, int_points))

func list_equipment(char_name: String) -> void:
	_send(EquipmentNet.OP_LIST, EquipmentNet.encode_list_request(char_name))

func equip(char_name: String, slot: int, inventory_slot: int) -> void:
	_send(EquipmentNet.OP_EQUIP, EquipmentNet.encode_equip(char_name, slot, inventory_slot))

## Takes off what is worn in `slot`; `to_bag_slot` is the bag slot it was
## put down on (-1: the server picks the first free one).
func unequip(char_name: String, slot: int, to_bag_slot: int = -1) -> void:
	_send(EquipmentNet.OP_UNEQUIP, EquipmentNet.encode_unequip(char_name, slot, to_bag_slot))

## Repairs a worn slot, or every worn item (EquipmentNet.REPAIR_ALL), for
## gold. The server answers OP_REPAIR_RESULT -> repair_result.
func repair(char_name: String, slot: int) -> void:
	_send(EquipmentNet.OP_REPAIR, EquipmentNet.encode_repair_request(char_name, slot))

func shop_buy(char_name: String, item_id: int, quantity: int) -> void:
	_send(ShopNet.OP_BUY, ShopNet.encode_buy(char_name, item_id, quantity))

func list_shop(item_ids: Array = []) -> void:
	_send(ShopNet.OP_LIST, ShopNet.encode_list_request(item_ids))

func sell_item(char_name: String, slot: int, quantity: int) -> void:
	_send(ShopNet.OP_SELL, ShopNet.encode_sell(char_name, slot, quantity))

## Round 728, the retail item operation (ItemOpNet): split count of bag slot
## src into empty bag slot dst (0x7034 type 0).
func split_item(src: int, dst: int, count: int) -> void:
	_send(ItemOpNet.OP_MOVE, ItemOpNet.encode_split(src, dst, count))

## Sells count of bag slot src to NPC npc (0x7034 type 9).
func sell_item_retail(src: int, count: int, npc: int) -> void:
	_send(ItemOpNet.OP_MOVE, ItemOpNet.encode_sell(src, count, npc))

## Deposits bag slot src's whole stack into warehouse slot dst (0x7034 type 2).
func deposit_retail(src: int, dst: int, npc: int) -> void:
	_send(ItemOpNet.OP_MOVE, ItemOpNet.encode_deposit(src, dst, npc))

## Buys entry index (0 = the oldest) of the buy-back list back (0x7168).
func buyback_retail(npc: int, index: int) -> void:
	_send(ItemOpNet.OP_BUYBACK, ItemOpNet.encode_buyback(npc, index))

## Uses one item from a bag slot (a potion). The reply carries the new HP/MP.
func use_item(char_name: String, inventory_slot: int) -> void:
	_send(UseItemNet.OP_USE_ITEM, UseItemNet.encode_use(char_name, inventory_slot))

## Spends one use of a granted item (the fill an Energy of life scroll grants).
func composite_use(char_name: String, item_id: int) -> void:
	_send(CompositeNet.OP_USE, CompositeNet.encode_use(char_name, item_id))

## Asks which item grants this character holds (answered by composite_state).
func composite_list(char_name: String) -> void:
	_send(CompositeNet.OP_LIST, CompositeNet.encode_list(char_name))

func list_storage(char_name: String) -> void:
	_send(StorageNet.OP_LIST, StorageNet.encode_list_request(char_name))

func deposit_to_storage(char_name: String, bag_slot: int, quantity: int) -> void:
	_send(StorageNet.OP_DEPOSIT, StorageNet.encode_move(char_name, bag_slot, quantity))

func withdraw_from_storage(char_name: String, warehouse_slot: int, quantity: int) -> void:
	_send(StorageNet.OP_WITHDRAW, StorageNet.encode_move(char_name, warehouse_slot, quantity))

func storage_gold(char_name: String, op: int, amount: int) -> void:
	_send(StorageNet.OP_GOLD, StorageNet.encode_gold(char_name, op, amount))

## Which monster each outstanding attack/skill was sent AT, oldest first. The
## server answers every OpAttack and OpUseSkill with exactly one OpAttackResult
## (refusals included) and now names the monster in it; this queue is the
## fallback for a server that predates that field (monster_id 0), so the
## client still attributes the blow to the monster it swung at rather than to
## whatever it is targeting by the time the result lands. Pushed only when the
## send actually went out, so the queue stays aligned with the replies.
var _attack_targets_in_flight: Array[int] = []
## The targetType of each request in _attack_targets_in_flight, in step with
## it (round 617): a plain swing and an entity cast are SkillNet.TARGET_ENTITY,
## a self-cast TARGET_NONE and a ground cast TARGET_GROUND. The reply is
## tagged with it (CombatNet.AttackResult.target_type), so World3D can tell a
## self-cast's reply from a blow on the monster it is targeting.
var _attack_types_in_flight: Array[int] = []

func attack(char_name: String, target_monster_id: int) -> void:
	if not is_connected_to_server():
		return
	_send(CombatNet.OP_ATTACK, CombatNet.encode_attack(char_name, target_monster_id))
	_attack_targets_in_flight.append(target_monster_id)
	_attack_types_in_flight.append(SkillNet.TARGET_ENTITY)

func berserk(char_name: String) -> void:
	_send(CombatNet.OP_BERSERK, CombatNet.encode_berserk(char_name))

func list_monsters() -> void:
	_send(CombatNet.OP_MONSTER_LIST, CombatNet.encode_monster_list())

func list_ground_items() -> void:
	_send(GroundItemsNet.OP_LIST, GroundItemsNet.encode_list())

## Asks to pick a ground item up; the server decides range and ownership.
func pick_up(char_name: String, ground_id: int) -> void:
	_send(GroundItemsNet.OP_PICK_UP, GroundItemsNet.encode_pick_up(char_name, ground_id))

func learn_skill(char_name: String, skill_id: int) -> void:
	if not is_connected_to_server():
		push_error("NetClient: learn_skill called while not connected")
		return
	_pending_learns.append(skill_id)
	_send(SkillNet.OP_LEARN, SkillNet.encode_learn(char_name, skill_id))

## Response arrives as attack_result (see SkillNet's doc comment: using a
## skill reuses OpAttackResult, since it's just an attack with a bonus).
## target_type is SkillNet.TARGET_ENTITY (the monster), TARGET_NONE (a
## self-cast: Grass Walk, the imbues) or TARGET_GROUND (Ghost Walk, at
## `point`). Every send is logged -- "CAST send ..." -- so a tester's log
## shows what went out.
func use_skill(char_name: String, skill_id: int, target_monster_id: int,
		target_type: int = SkillNet.TARGET_ENTITY, point: Vector3 = Vector3.ZERO) -> void:
	if not is_connected_to_server():
		print("CAST send skipped (not connected): skill %d targetType %d" % [skill_id, target_type])
		return
	_send(SkillNet.OP_USE, SkillNet.encode_use(char_name, skill_id, target_monster_id, target_type, point))
	_attack_targets_in_flight.append(target_monster_id)
	_attack_types_in_flight.append(target_type)
	match target_type:
		SkillNet.TARGET_NONE:
			print("CAST send: skill %d targetType 0 (self; monster field %d)" % [skill_id, target_monster_id])
		SkillNet.TARGET_GROUND:
			print("CAST send: skill %d targetType 2 (ground) at (%.1f, %.1f, %.1f)" % [
				skill_id, point.x, point.y, point.z])
		SkillNet.TARGET_CHARACTER:
			print("CAST send: skill %d targetType 3 (character %d)" % [skill_id, target_monster_id])
		_:
			print("CAST send: skill %d targetType 1 (monster %d)" % [skill_id, target_monster_id])

## Asks the server to end one of this character's buffs: the skill and the
## token OpBuffStart gave it (round 618's buff bar calls this on a right
## click). Uses the logged-in character's name, as the other senders are
## handed it.
func send_buff_cancel(skill_id: int, token: int) -> void:
	if not is_connected_to_server():
		return
	_send(SkillNet.OP_BUFF_CANCEL, SkillNet.encode_buff_cancel(current_character_name, skill_id, token))
	print("BUFF cancel send: skill %d token %d" % [skill_id, token])

func list_skills(char_name: String) -> void:
	_send(SkillNet.OP_LIST, SkillNet.encode_list(char_name))

## Ask for the character's skill economy state (points + per-mastery levels),
## which drives the skill window's totals and lit/greyed skills.
func skill_state(char_name: String) -> void:
	_send(SkillNet.OP_STATE, SkillNet.encode_state_request(char_name))

## Spend skill points to raise a mastery one level.
func raise_mastery(char_name: String, mastery_id: int) -> void:
	_send(SkillNet.OP_RAISE, SkillNet.encode_raise_mastery(char_name, mastery_id))

func _init() -> void:
	# The invitation's auto-decline (PartyState._on_request) answers without
	# the player.
	party.send_answer.connect(func(payload: PackedByteArray) -> void: _send(PartyNet.OP_REQUEST, payload))

## Registers `handler` (Callable(data: PackedByteArray)) for `opcode`, for a
## module this file does not route itself (round 711; the party-match lane
## registers its messages through it). A later registration replaces one.
func register_handler(opcode: int, handler: Callable) -> void:
	_extra_handlers[opcode] = handler

## 0x7060: create a party with the selected player, with the settings
## block's type byte (party_gui.md §1, c:0x81c6d0).
func party_create(target_world_id: int) -> void:
	_send(PartyNet.OP_CREATE, PartyNet.encode_create(target_world_id, party.flags_byte()))

## 0x7062: invite the selected player into this party (c:0x81c8f0).
func party_invite(target_world_id: int) -> void:
	_send(PartyNet.OP_INVITE, PartyNet.encode_invite(target_world_id))

## 0x7061: leave the party -- also what the leader's Dismiss sends
## (c:0x6d5a00 -> jmp 0x81cad0).
func party_leave() -> void:
	_send(PartyNet.OP_LEAVE, PartyNet.encode_leave())

## 0x7063: banish a member (the leader's row button, c:0x81cb70).
func party_kick(member_jid: int) -> void:
	_send(PartyNet.OP_KICK, PartyNet.encode_kick(member_jid))

## 0x3080: the invitation box's answer (c:0x81cc30 / 0x81cd20 / 0x81ce00 /
## 0x81cef0). Nothing is sent when no invitation is showing.
func party_answer(accept: bool) -> void:
	var payload := party.answer(accept)
	if not payload.is_empty():
		_send(PartyNet.OP_REQUEST, payload)

func create_guild(char_name: String, guild_name: String) -> void:
	_send(GuildNet.OP_CREATE, GuildNet.encode_create(char_name, guild_name))

func join_guild(char_name: String, guild_id: int) -> void:
	_send(GuildNet.OP_JOIN, GuildNet.encode_join(char_name, guild_id))

func leave_guild(char_name: String) -> void:
	_send(GuildNet.OP_LEAVE, GuildNet.encode_name_request(char_name))

func guild_info(char_name: String) -> void:
	_send(GuildNet.OP_INFO, GuildNet.encode_name_request(char_name))

func guild_points(char_name: String) -> void:
	_send(GuildNet.OP_POINTS, GuildNet.encode_points(char_name))

## Asks for the guild's level (level_up false), or asks to raise it -- the
## master only; the server refuses anyone else (round 528).
func guild_level(char_name: String, level_up: bool = false) -> void:
	_send(GuildNet.OP_LEVEL, GuildNet.encode_level(char_name, level_up))

## Sends one chat line of `type` (HudChat's TYPE_*): the index comes back
## in the result so the sender's own line can be shown (round 634).
func send_chat(type: int, index: int, target_name: String, message_text: String) -> void:
	_send(ChatNet.OP_SEND, ChatNet.encode_send(type, index, target_name, message_text))

## Ordinary chat (type 1) with index 0, for callers that do not track the
## echo (the QA command hook).
func say(message_text: String) -> void:
	send_chat(0x01, 0, "", message_text)

## A whisper (type 2) with index 0 (the console's /w).
func whisper(target_name: String, message_text: String) -> void:
	send_chat(0x02, 0, target_name, message_text)

## A global: the global chatting item in `inventory_slot` carries the text to
## every player (the item use 0x704c, round 634).
func send_global(inventory_slot: int, message_text: String) -> void:
	_send(ChatNet.OP_GLOBAL, ChatNet.encode_global(inventory_slot, message_text))

## Sends a GM console command line (the server gates and runs it). An empty
## line is the enter-world probe that asks whether this account is a GM.
func gm_command(char_name: String, line: String, selected_monster: int) -> void:
	_send(GmNet.OP_COMMAND, GmNet.encode_command(char_name, line, selected_monster))

## Asks to travel from the gate the player is at to one of its destinations,
## both teleportdata ids (TeleportNet.OP_USE). The reply is teleport_result;
## the move itself is change_zone_result.
func teleport_use(gate_id: int, dest_id: int) -> void:
	_send(TeleportNet.OP_USE, TeleportNet.encode_use(gate_id, dest_id))

## Asks to make the gate the player is talking to (a teleportdata id) its
## return point (RecallNet.OP_DESIGNATE, round 686). The reply is
## recall_designate_result.
func recall_designate(gate_id: int) -> void:
	_send(RecallNet.OP_DESIGNATE, RecallNet.encode_designate(gate_id))

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

## When on (the /wire console command), every received packet's opcode and
## size is printed to stdout, which the file logger also captures -- for
## chasing a desync or a crash from the log.
var wire_logging := false

## Opcodes this session has already warned about as unhandled. A client older
## than a server's messages -- 0x007C/0x007F arrive many times a second in a
## zone once the server's monster AI runs -- warned once per PACKET and filled
## the log; now it warns once per opcode per connection (cleared in
## connect_to_server).
var _unhandled_warned := {}

## Whether to warn about an unhandled `opcode`: the first time this session
## sees it, and never again until the next connect.
func _should_warn_unhandled(opcode: int) -> bool:
	if _unhandled_warned.has(opcode):
		return false
	_unhandled_warned[opcode] = true
	return true

## One 0xB007 to the signal its action has.
func _dispatch_lobby(r: LobbyNet.Result) -> void:
	lobby_result.emit(r)
	var why := ""
	if r.error != "":
		why = "malformed response (%s)" % r.error
	elif not r.ok:
		why = LobbyNet.code_text(r.code, lobby_text)
	var ok := r.ok and r.error == ""
	match r.action:
		LobbyNet.ACTION_LIST:
			_list_watch.answered()
			character_list_result.emit(r.characters if ok else [], why)
		LobbyNet.ACTION_CREATE:
			character_create_result.emit(ok, why)
		LobbyNet.ACTION_DELETE:
			character_delete_result.emit(ok, why)
		LobbyNet.ACTION_RESTORE:
			character_restore_result.emit(ok, why)
		LobbyNet.ACTION_NAME_CHECK:
			name_check_result.emit(ok, why)

## World3D's item table (RefItemID -> ItemTableReader.Item), for the
## players' spawn records (round 737, UserSpawnNet): World3D hands it over
## as soon as it has read it. The spawns that waited for it are read now, in
## the order they came.
func set_spawn_item_rows(rows: Dictionary) -> void:
	_spawn_types = UserSpawnNet.Types.new(rows)
	var waiting := _pending_spawns
	_pending_spawns = []
	_replaying = true
	for m in waiting:
		_apply_spawn_message(int(m["op"]), m["data"])
	_replaying = false

## A world entry or zone change: the players in view start over, and their
## records' coordinates are in frame (the result's FrameRegion).
func _start_user_view(frame: String) -> void:
	user_roster.clear()
	_pending_spawns.clear()
	_group_job = null
	_zone_arrivals.clear()
	zone_departures.clear()
	character_states.clear()
	_spawn_frame = UserSpawnNet.parse_frame(frame)

## OpPlayerZoneNotice (round 737's review, OURS): u8 kind (1 entered, 2
## left), u32 uid, u16 + name -- a real arrival in the zone or a leave of
## it, ahead of its spawn or despawn, as opposed to a walk into or out of
## view. Kept for the spawn (snapshot.zone_arrival) and the despawn
## (zone_departures), which World3D logs.
func _on_zone_notice(data: PackedByteArray) -> void:
	if data.size() < 7:
		return
	var uid := data.decode_u32(1)
	if data[0] == 1:
		_zone_arrivals[uid] = true
	elif data[0] == 2:
		zone_departures[uid] = true

## Round 749: an 0xB021's world points in frame.
static func resolve_echo(echo: DestMoveNet.Echo, frame: Vector2i) -> void:
	if echo.kind == DestMoveNet.KIND_DESTINATION:
		var d := DestMoveNet.world_of_local(echo.region, float(echo.local.x), float(echo.local.z), frame)
		echo.dest_world = Vector3(d.x, float(echo.local.y), d.y)
	if echo.has_source:
		var s := DestMoveNet.world_of_local(echo.source_region, echo.source_local.x, echo.source_local.z, frame)
		echo.source_world = Vector3(s.x, echo.source_local.y, s.y)

## A spawn message that may name a player: read now, or queued behind any
## that wait for the item table.
func _user_spawn_message(op: int, data: PackedByteArray) -> void:
	if not _pending_spawns.is_empty():
		_pending_spawns.append({"op": op, "data": data})
		return
	_apply_spawn_message(op, data)

func _apply_spawn_message(op: int, data: PackedByteArray) -> void:
	match op:
		DestMoveNet.OP_MOVEMENT_ECHO:
			var echo := DestMoveNet.decode_echo(data)
			if echo.error != "":
				push_warning("NetClient: a 0xB021 that does not read (%s)" % echo.error)
				return
			resolve_echo(echo, _spawn_frame)
			entity_move_echo.emit(echo)
		DestMoveNet.OP_MOVEMENT_STOP:
			var stop := DestMoveNet.decode_stop(data)
			if stop.error != "":
				push_warning("NetClient: a 0xB023 that does not read (%s)" % stop.error)
				return
			var at := DestMoveNet.world_of_local(stop.region, stop.local.x, stop.local.z, _spawn_frame)
			stop.world = Vector3(at.x, stop.local.y, at.y)
			entity_move_stop.emit(stop)
		NpcSpawnNet.OP_SINGLE_SPAWN:
			if _spawn_types == null:
				_pending_spawns.append({"op": op, "data": data})
				return
			var rec := UserSpawnNet.decode_single_spawn(data, _spawn_types)
			if rec == null:
				push_warning("NetClient: a 0x3015 that does not read as a player record (%d bytes)" % data.size())
			else:
				if _spawn_log:
					print("NetClient: 0x3015 player %d %s came into view" % [rec.uid, rec.name])
				_user_spawned(rec)
		NpcSpawnNet.OP_SINGLE_DESPAWN:
			var gone := NpcSpawnNet.decode_single_despawn(data)
			if user_roster.has(gone):
				if _spawn_log:
					print("NetClient: 0x3016 player %d went out of view" % gone)
				_user_left(gone)
			elif gone >= 0 and npc_roster.despawn(gone):
				npc_despawned.emit(gone)
		NpcSpawnNet.OP_GROUP_END:
			# Round 762: a spawn group is read a frame's share at a time.
			if not _replaying and _spawn_types != null and data.size() >= 3 and data[0] == NpcSpawnNet.GROUP_SPAWN:
				var jr := NpcSpawnNet.Reader.new(data)
				jr.u8()
				_group_job = {"r": jr, "count": jr.u16(), "i": 0, "users": 0, "npcs": 0, "bytes": data.size(),
					"t0": Time.get_ticks_usec(), "frames": 0}
				_group_step()
				return
			# And a despawn group, its ids a frame's share at a time.
			if not _replaying and data.size() >= 3 and data[0] == NpcSpawnNet.GROUP_DESPAWN:
				var dg := UserSpawnNet.read_group(data, _spawn_types)
				if dg.error == "":
					_group_job = {"uids": dg.uids, "count": (dg.uids as Array).size(), "i": 0, "users": 0, "npcs": 0,
						"bytes": data.size(), "t0": Time.get_ticks_usec(), "frames": 0}
					_group_step()
					return
			var qd := Time.get_ticks_usec()
			var g := UserSpawnNet.read_group(data, _spawn_types)
			qd = Time.get_ticks_usec() - qd
			if g.deferred:
				_pending_spawns.append({"op": op, "data": data})
				return
			if g.error != "":
				push_warning("NetClient: a group spawn that does not read (%s) -- dropped" % g.error)
			elif g.kind == NpcSpawnNet.GROUP_SPAWN:
				if not g.users.is_empty():
					print("NetClient: group spawn of %d player(s)%s" % [g.users.size(),
						(" and %d NPC(s)" % g.npcs.size()) if not g.npcs.is_empty() else ""])
				for rec in g.npcs:
					npc_spawned.emit(npc_roster.spawn(rec))
				if not g.users.is_empty():
					var qt := Time.get_ticks_usec()
					user_group_begin.emit()
					for rec in g.users:
						_user_spawned(rec)
					user_group_end.emit()
					if FrameSplit.on:
						qa_groups += 1
						qa_group_players += g.users.size()
						print("QA NET group %d: %d player(s), %d bytes, at %d ms, decoded in %.1f ms, handled in %.1f ms (rx %d bytes, %d packets)" % [qa_groups,
							g.users.size(), data.size(), Time.get_ticks_msec(), qd / 1000.0, (Time.get_ticks_usec() - qt) / 1000.0, qa_rx_bytes, qa_rx_packets])
			else:
				var players := 0
				for u in g.uids:
					if user_roster.has(u):
						players += 1
				if players > 0:
					print("NetClient: group despawn of %d player(s)%s" % [players,
						(" at %d ms" % Time.get_ticks_msec()) if FrameSplit.on else ""])
				for u in g.uids:
					if user_roster.has(u):
						_user_left(u)
					elif npc_roster.despawn(u):
						npc_despawned.emit(u)

## Round 762: reads the group being read for GROUP_STEP_USEC (one record at
## least), each player handed over as it is read inside a group bracket
## (World3D queues them whole, as before); true when the group is done.
func _group_step() -> bool:
	if _group_job == null:
		return true
	var job: Dictionary = _group_job
	if job.has("uids"):
		return _despawn_step(job)
	var r: NpcSpawnNet.Reader = job["r"]
	var count: int = job["count"]
	var t0 := Time.get_ticks_usec()
	var first := int(job["i"])
	job["frames"] = int(job["frames"]) + 1
	var bracket := false
	while int(job["i"]) < count:
		if int(job["i"]) > first and Time.get_ticks_usec() - t0 >= GROUP_STEP_USEC:
			break
		if UserSpawnNet.is_player_ref(UserSpawnNet.peek_ref(r)):
			var rec := UserSpawnNet.read_record(r, _spawn_types)
			if rec == null:
				push_warning("NetClient: a group spawn that does not read (record %d of %d: %s) -- the rest dropped" % [int(job["i"]), count, r.error])
				job["i"] = count
				break
			if not bracket:
				bracket = true
				user_group_begin.emit()
			_user_spawned(rec)
			job["users"] = int(job["users"]) + 1
		else:
			var npc := NpcSpawnNet.read_record(r)
			if npc == null:
				push_warning("NetClient: a group spawn that does not read (record %d of %d: %s) -- the rest dropped" % [int(job["i"]), count, r.error])
				job["i"] = count
				break
			npc_spawned.emit(npc_roster.spawn(npc))
			job["npcs"] = int(job["npcs"]) + 1
		job["i"] = int(job["i"]) + 1
	if bracket:
		user_group_end.emit()
	if int(job["i"]) < count:
		return false
	_group_job = null
	if r.error == "" and r.pos != r.data.size():
		push_warning("NetClient: %d byte(s) left after a group spawn" % (r.data.size() - r.pos))
	if int(job["users"]) > 0:
		print("NetClient: group spawn of %d player(s)%s" % [int(job["users"]),
			(" and %d NPC(s)" % int(job["npcs"])) if int(job["npcs"]) > 0 else ""])
		if FrameSplit.on:
			qa_groups += 1
			qa_group_players += int(job["users"])
			print("QA NET group %d: %d player(s), %d bytes, at %d ms, read over %d frame(s) in %.1f ms (rx %d bytes, %d packets)" % [qa_groups,
				int(job["users"]), int(job["bytes"]), Time.get_ticks_msec(), int(job["frames"]), (Time.get_ticks_usec() - int(job["t0"])) / 1000.0,
				qa_rx_bytes, qa_rx_packets])
	return true

## Round 762: a despawn group's ids, GROUP_STEP_USEC a frame (one at least).
func _despawn_step(job: Dictionary) -> bool:
	var uids: Array = job["uids"]
	var t0 := Time.get_ticks_usec()
	var first := int(job["i"])
	job["frames"] = int(job["frames"]) + 1
	while int(job["i"]) < uids.size():
		if int(job["i"]) > first and Time.get_ticks_usec() - t0 >= GROUP_STEP_USEC:
			break
		var u: int = uids[int(job["i"])]
		job["i"] = int(job["i"]) + 1
		if user_roster.has(u):
			job["users"] = int(job["users"]) + 1
			_user_left(u)
		elif npc_roster.despawn(u):
			npc_despawned.emit(u)
	if int(job["i"]) < uids.size():
		return false
	_group_job = null
	if int(job["users"]) > 0:
		print("NetClient: group despawn of %d player(s)%s" % [int(job["users"]),
			(" at %d ms, over %d frame(s)" % [Time.get_ticks_msec(), int(job["frames"])]) if FrameSplit.on else ""])
	return true

## A player came into view: World3D's snapshot of it, its body mode kept for
## its body (_berserk_resync), and its sitting.
func _user_spawned(rec: UserSpawnNet.Record) -> void:
	var snap := UserSpawnNet.to_snapshot(rec, _spawn_types, _spawn_frame)
	user_roster[rec.uid] = true
	var mode := WorldNet.StateChange.new()
	mode.object_id = rec.uid
	mode.kind = WorldNet.STATE_KIND_BODY_MODE
	mode.value = 1 if rec.body_mode == UserSpawnNet.BODY_MODE_BERSERK else 0
	WorldNet.note_body_mode(body_modes, mode)
	var sitting := rec.motion == UserSpawnNet.MOTION_SIT
	# Round 737's review: World3D draws a sitter seated from the snapshot --
	# at once, or when a zone change's load lays its arrivals out -- rather
	# than from a SIT state change, which a body still being loaded drops and
	# a drawn one answers with the sit-down clip.
	snap.seated = sitting
	# A real arrival in the zone (OpPlayerZoneNotice came first), not a walk
	# into view: World3D says so in the chat, as it did before round 737.
	snap.zone_arrival = _zone_arrivals.has(rec.uid)
	_zone_arrivals.erase(rec.uid)
	var res := last_enter_world_result
	if entity_entered.get_connections().is_empty() and res != null and res.ok:
		# World3D is not up yet -- the entry's spawns come while
		# CharacterSelect swaps it in -- and lays out the result's list when
		# it is: the spawn joins that list.
		for i in res.others.size():
			if res.others[i].character_id == snap.character_id:
				res.others.remove_at(i)
				break
		res.others.append(snap)
		res.seated.erase(snap.character_id)
		if sitting:
			res.seated.append(snap.character_id)
		return
	entity_entered.emit(snap)

## A player went out of view (0x3016, or a type-2 group): as OpEntityLeft.
func _user_left(uid: int) -> void:
	user_roster.erase(uid)
	buff_roster.drop(BuffRoster.key_of(uid, SkillNet.OWNER_CHARACTER))
	body_modes.erase(uid)
	character_states.erase(uid)
	var res := last_enter_world_result
	if entity_left.get_connections().is_empty() and res != null and res.ok:
		for i in res.others.size():
			if res.others[i].character_id == uid:
				res.others.remove_at(i)
				break
		res.seated.erase(uid)
		return
	entity_left.emit(uid)

func _dispatch(p: Packet) -> void:
	if wire_logging:
		print("WIRE recv opcode=0x%04x size=%d" % [p.opcode, p.data.size()])
	match p.opcode:
		Auth.OP_LOGIN_RESULT:
			var r := Auth.decode_result(p.data)
			login_result.emit(r.ok, r.reason if r.error == "" else r.error)
		Auth.OP_REGISTER_RESULT:
			var r := Auth.decode_result(p.data)
			register_result.emit(r.ok, r.reason if r.error == "" else r.error)
		LobbyNet.OP_LOBBY_RESULT:
			_dispatch_lobby(LobbyNet.decode_result(p.data))
		LobbyNet.OP_START_RESULT:
			var r := LobbyNet.decode_start_result(p.data)
			var why := ""
			if r.error != "":
				why = "malformed response (%s)" % r.error
			elif not r.ok:
				why = LobbyNet.code_text(r.code, lobby_text)
			start_result.emit(r.ok and r.error == "", r.code, why)
			if why != "":
				# The screens wait on the enter-world result; a refused Start
				# is one, with the refusal's words.
				var refused := WorldNet.EnterWorldResult.new()
				refused.ok = false
				refused.reason = why
				enter_world_result.emit(refused)
		WorldNet.OP_ENTER_WORLD_RESULT:
			var result := WorldNet.decode_enter_world_result(p.data)
			last_enter_world_result = result
			if result.ok:
				current_zone = result.zone
				# The zone's buffs follow this result (round 646): the roster
				# starts over from them.
				buff_roster.clear()
				body_modes.clear()
				# So does the NPC window: the server forgets what it sent this
				# session at the entry (session.forgetNPCWindow) and spawns
				# the whole window again.
				npc_roster.clear()
				# And the players in view (round 737): they follow as spawns.
				_start_user_view(result.frame)
			enter_world_result.emit(result)
		WorldNet.OP_ENTITY_ENTERED:
			entity_entered.emit(WorldNet.decode_entity_entered(p.data))
		WorldNet.OP_ENTITY_MOVED:
			entity_moved.emit(WorldNet.decode_entity_moved(p.data))
		WorldNet.OP_ENTITY_LEFT:
			var left_id := WorldNet.decode_entity_left(p.data)
			# Its buffs went with its body (round 646, BuffRoster.drop), and
			# its body mode (round 651).
			buff_roster.drop(BuffRoster.key_of(left_id, SkillNet.OWNER_CHARACTER))
			body_modes.erase(left_id)
			entity_left.emit(left_id)
		WorldNet.OP_CHANGE_ZONE_RESULT:
			var zone_result := WorldNet.decode_change_zone_result(p.data)
			if zone_result.ok:
				current_zone = zone_result.zone
				# The new zone's buffs, this player's own included, follow
				# this result (round 646; sendBuffsInView).
				buff_roster.clear()
				body_modes.clear()
				# And its players, as spawns (round 737).
				_start_user_view(zone_result.frame)
			change_zone_result.emit(zone_result)
		WorldNet.OP_REVIVE_RESULT:
			revive_result.emit(WorldNet.decode_revive_result(p.data))
		WorldNet.OP_STATE_CHANGE:
			var change := WorldNet.decode_state_change(p.data)
			if change != null:
				WorldNet.note_body_mode(body_modes, change)
				state_changed.emit(change)
		InventoryNet.OP_LIST_RESULT:
			var r := InventoryNet.decode_list_result(p.data)
			last_inventory_durabilities = r.durabilities
			last_inventory_instances = _note_instances("bag", r.instances)
			if r.capacity > 0:
				last_inventory_capacity = r.capacity
			inventory_list_result.emit(r.slots, r.error)
		InventoryNet.OP_MOVE_RESULT:
			var r := InventoryNet.decode_list_result(p.data)
			last_inventory_durabilities = r.durabilities
			last_inventory_instances = _note_instances("bag", r.instances)
			if r.capacity > 0:
				last_inventory_capacity = r.capacity
			inventory_move_result.emit(r.slots, r.error)
		StatsNet.OP_STATS_RESULT:
			last_stats_reply_requested = _stats_requests_pending > 0
			if _stats_requests_pending > 0:
				_stats_requests_pending -= 1
			character_stats_result.emit(StatsNet.decode_result(p.data))
		EquipmentNet.OP_RESULT:
			var r := EquipmentNet.decode_result(p.data)
			last_equipment_durabilities = r.durabilities
			last_equipment_instances = _note_instances("worn", r.instances)
			equipment_result.emit(r.items, r.error)
		EquipmentNet.OP_REPAIR_RESULT:
			var rr := EquipmentNet.decode_repair_result(p.data)
			repair_result.emit(rr.code, rr.gold_spent, rr.durabilities)
		EquipmentNet.OP_EQUIP_BROADCAST, EquipmentNet.OP_UNEQUIP_BROADCAST:
			var eb := EquipmentNet.decode_broadcast(p.data)
			if eb != null:
				var on := p.opcode == EquipmentNet.OP_EQUIP_BROADCAST
				print("NetClient: %s uid %d slot %d item %d plus %d" % ["0x3038" if on else "0x3039", eb.uid, eb.slot, eb.ref_item_id, eb.plus])
				# A 0x3038 with no plus byte (a non-equipment item, which retail's
				# layout allows) is a +0 put on, never a removal (round 735's
				# review, finding 7): only a 0x3039 is -1.
				other_player_equipment_changed.emit(eb.uid, eb.slot, eb.ref_item_id, maxi(eb.plus, 0) if on else -1)
		ShopNet.OP_BUY_RESULT:
			var r := ShopNet.decode_buy_result(p.data)
			shop_buy_result.emit(r.ok, r.reason if r.error == "" else r.error)
		ShopNet.OP_LIST_RESULT:
			var r := ShopNet.decode_list_result(p.data)
			shop_list_result.emit(r.entries, r.error)
		ShopNet.OP_SELL_RESULT:
			var r := ShopNet.decode_sell_result(p.data)
			shop_sell_result.emit(r.ok, r.reason if r.error == "" else r.error, r.gold_received)
		ItemOpNet.OP_MOVE_RESULT:
			item_op_result.emit(ItemOpNet.decode_result(p.data))
		ItemOpNet.OP_BUYBACK_FAIL:
			var f := ItemOpNet.decode_result(p.data)
			buyback_failed.emit(int(f.get("code", 0)))
		UseItemNet.OP_RESULT:
			use_item_result.emit(UseItemNet.decode_result(p.data))
		CompositeNet.OP_STATE:
			composite_state.emit(CompositeNet.decode_state(p.data))
		CompositeNet.OP_USE_RESULT:
			composite_use_result.emit(CompositeNet.decode_use_result(p.data))
		CompositeNet.OP_END:
			var ended := CompositeNet.decode_end(p.data)
			if ended.size() == 2:
				composite_ended.emit(int(ended[0]), int(ended[1]))
		StorageNet.OP_LIST_RESULT:
			var r := StorageNet.decode_list_result(p.data)
			last_storage_instances = _note_instances("warehouse", r.instances)
			storage_list_result.emit(r.slots, r.error, r.capacity)
		StorageNet.OP_DEPOSIT_RESULT:
			var r := StorageNet.decode_move_result(p.data)
			storage_deposit_result.emit(r.ok, r.reason if r.error == "" else r.error)
		StorageNet.OP_WITHDRAW_RESULT:
			var r := StorageNet.decode_move_result(p.data)
			storage_withdraw_result.emit(r.ok, r.reason if r.error == "" else r.error)
		StorageNet.OP_GOLD_RESULT:
			var r := StorageNet.decode_gold_result(p.data)
			storage_gold_result.emit(r.ok, r.reason if r.error == "" else r.error, r.carried, r.stored)
		CombatNet.OP_ATTACK_RESULT:
			var ar := CombatNet.decode_attack_result(p.data)
			# One reply per swing: consume the oldest sent target. The server's
			# own id wins when it gave one; the queue only fills a 0.
			var sent_at := -1
			if not _attack_targets_in_flight.is_empty():
				sent_at = _attack_targets_in_flight.pop_front()
			# The server's own echo wins; the queue only fills a reply that
			# carries none (an older server).
			if not _attack_types_in_flight.is_empty():
				var queued: int = _attack_types_in_flight.pop_front()
				if not ar.target_type_echoed:
					ar.target_type = queued
			if ar.monster_id == 0 and sent_at != -1:
				ar.monster_id = sent_at
			attack_result.emit(ar)
		CombatNet.OP_BERSERK_RESULT:
			var br := CombatNet.decode_berserk_result(p.data)
			berserk_result.emit(br.activated, br.gauge, br.active)
		CombatNet.OP_MONSTER_DAMAGED:
			monster_damaged.emit(CombatNet.decode_monster_damaged(p.data))
		CombatNet.OP_MONSTER_DIED:
			var died := CombatNet.decode_monster_died(p.data)
			if died >= 0:
				buff_roster.drop(BuffRoster.key_of(died, SkillNet.OWNER_MONSTER))
			monster_died.emit(died)
		StatusNet.OP_OBJECT_STATUS:
			var st := StatusNet.decode_object_status(p.data)
			if st.error == "":
				if st.owner_kind == SkillNet.OWNER_CHARACTER:
					if st.mask == 0:
						character_states.erase(st.owner_id)
					else:
						character_states[st.owner_id] = st
				object_status.emit(st)
		OP_PLAYER_ZONE_NOTICE:
			_on_zone_notice(p.data)
		OP_UNSTUCK_RESULT:
			if p.data.size() >= 3:
				unstuck_result.emit(p.data[0] == 1, p.data.decode_u16(1))
		CombatNet.OP_LOOT_DROPPED:
			loot_dropped.emit(CombatNet.decode_loot_dropped(p.data))
		CombatNet.OP_MONSTER_LIST_RESULT:
			var r := CombatNet.decode_monster_list_result(p.data)
			if r.error != "" or r.pages <= 1:
				_monster_list_pages.clear()
				monster_list_result.emit(r.monsters, r.error)
			else:
				if r.page == 0:
					_monster_list_pages.clear()
				_monster_list_pages.append_array(r.monsters)
				if r.page + 1 >= r.pages:
					var whole := _monster_list_pages.duplicate()
					_monster_list_pages.clear()
					monster_list_result.emit(whole, "")
		NpcSpawnNet.OP_FACING_UNKNOWN:
			npc_roster.facing_unknown(NpcSpawnNet.decode_facing_unknown(p.data))
		DestMoveNet.OP_MOVEMENT_ECHO, DestMoveNet.OP_MOVEMENT_STOP:
			# Round 749: in order behind any player spawn still waiting for the
			# item table, so a body is never told to walk before it exists.
			_user_spawn_message(p.opcode, p.data)
		NpcSpawnNet.OP_SINGLE_SPAWN:
			# A player's record (round 737) or an NPC's, by its RefObjID.
			if p.data.size() >= 4 and UserSpawnNet.is_player_ref(p.data.decode_u32(0)):
				_user_spawn_message(NpcSpawnNet.OP_SINGLE_SPAWN, p.data)
			else:
				var single := NpcSpawnNet.decode_single_spawn(p.data)
				if single == null:
					push_warning("NetClient: a 0x3015 that does not read as an NPC record (%d bytes)" % p.data.size())
				else:
					npc_spawned.emit(npc_roster.spawn(single))
		NpcSpawnNet.OP_SINGLE_DESPAWN:
			var gone := NpcSpawnNet.decode_single_despawn(p.data)
			if gone >= 0 and (user_roster.has(gone) or not _pending_spawns.is_empty()):
				# A player's (round 737): in order behind any spawn still
				# waiting for the item table.
				_user_spawn_message(NpcSpawnNet.OP_SINGLE_DESPAWN, p.data)
			elif gone >= 0 and npc_roster.despawn(gone):
				npc_despawned.emit(gone)
		NpcSpawnNet.OP_GROUP_BEGIN:
			npc_roster.group.begin(p.data)
		NpcSpawnNet.OP_GROUP_DATA:
			npc_roster.group.append(p.data)
		NpcSpawnNet.OP_GROUP_END:
			# Every record by its class (round 737: players' too).
			var buffer: PackedByteArray = npc_roster.group.take()
			if buffer.is_empty():
				push_warning("NetClient: a group spawn that does not read (0x3018 with no 0x3017) -- dropped")
			else:
				_user_spawn_message(NpcSpawnNet.OP_GROUP_END, buffer)
		CombatNet.OP_MONSTER_LEFT:
			monster_left.emit(CombatNet.decode_monster_left(p.data))
		CombatNet.OP_MONSTER_MOVED:
			var moved := CombatNet.decode_monster_moved(p.data)
			if moved != null:
				monster_moved.emit(moved)
		CombatNet.OP_MONSTER_MOTION_LIST:
			monster_motion_list.emit(CombatNet.decode_monster_motion_list(p.data))
		CombatNet.OP_MONSTER_ATTACKED:
			var attacked := CombatNet.decode_monster_attacked(p.data)
			if attacked != null:
				monster_attacked.emit(attacked)
		CombatNet.OP_MONSTER_SPAWNED:
			var mob_spawned := CombatNet.decode_monster_spawned(p.data)
			if mob_spawned != null:
				monster_spawned.emit(mob_spawned)
		GroundItemsNet.OP_LIST_RESULT:
			var gl := GroundItemsNet.decode_list_result(p.data)
			ground_item_list_result.emit(gl.items, gl.error)
		GroundItemsNet.OP_SPAWNED:
			var spawned := GroundItemsNet.decode_snapshot(p.data)
			if spawned != null:
				ground_item_spawned.emit(spawned)
		GroundItemsNet.OP_REMOVED:
			var removed := GroundItemsNet.decode_removed(p.data)
			if removed != null:
				ground_item_removed.emit(removed)
		GroundItemsNet.OP_OWNER_RELEASED:
			var released := GroundItemsNet.decode_owner_released(p.data)
			if released != -1:
				ground_item_owner_released.emit(released)
		GroundItemsNet.OP_PICK_UP_RESULT:
			var pr := GroundItemsNet.decode_pick_up_result(p.data)
			if pr != null:
				pick_up_result.emit(pr)
		CombatNet.OP_LEVEL_UP:
			var lu := CombatNet.decode_level_up(p.data)
			level_up.emit(lu.new_level, lu.stat_points)
		SkillNet.OP_LEARN_RESULT:
			var r := SkillNet.decode_learn_result(p.data)
			learn_skill_result.emit(r.ok, r.reason if r.error == "" else r.error)
			if not _pending_learns.is_empty():
				learn_skill_done.emit(_pending_learns.pop_front(), r.ok)
		SkillNet.OP_LIST_RESULT:
			var r := SkillNet.decode_list_result(p.data)
			skill_list_result.emit(r.skills, r.error)
		SkillNet.OP_STATE_RESULT:
			skill_state_result.emit(SkillNet.decode_state_result(p.data))
		SkillNet.OP_RAISE_RESULT:
			raise_mastery_result.emit(SkillNet.decode_raise_mastery_result(p.data))
		SkillNet.OP_BUFF_START:
			var bs := SkillNet.decode_buff_start(p.data)
			if bs == null:
				push_warning("NetClient: short OpBuffStart (%d bytes) dropped" % p.data.size())
			else:
				print("BUFF start: owner %d (kind %s) skill %d token %d duration %d ms remaining %d ms runSpeed %d" % [
					bs.owner_id, str(bs.owner_kind) if bs.owner_kind_sent else "unsent", bs.skill_id, bs.token,
					bs.duration_ms, bs.remaining_ms, bs.run_speed])
				buff_roster.start(bs, Time.get_ticks_msec())
				buff_started.emit(bs)
		SkillNet.OP_BUFF_END:
			var be := SkillNet.decode_buff_end(p.data)
			if be == null:
				push_warning("NetClient: short OpBuffEnd (%d bytes) dropped" % p.data.size())
			else:
				print("BUFF end: owner %d (kind %s) tokens %s runSpeed %d" % [be.owner_id,
					str(be.owner_kind) if be.owner_kind_sent else "unsent", str(be.tokens), be.run_speed])
				buff_roster.end(be)
				buff_ended.emit(be)
		SkillNet.OP_SELF_ID:
			var sid := SkillNet.decode_self_id(p.data)
			if sid < 0:
				push_warning("NetClient: short OpSelfId (%d bytes) dropped" % p.data.size())
			else:
				own_character_id = sid
				print("SELF id: this character is %d" % sid)
				self_id_received.emit(sid)
		SkillNet.OP_SKILL_CAST:
			var sc := SkillNet.decode_skill_cast(p.data)
			if sc == null:
				push_warning("NetClient: short OpSkillCast (%d bytes) dropped" % p.data.size())
			else:
				print("SKILL cast: %s %d skill %d cast %d %s, target type %d id %d" % [
					"monster" if sc.caster_kind == SkillNet.OWNER_MONSTER else "character", sc.caster_id,
					sc.skill_id, sc.cast_id, "start" if sc.phase == SkillNet.CAST_START else "act",
					sc.target_type, sc.target_id])
				skill_cast.emit(sc)
		SkillNet.OP_SKILL_MOVE:
			var sm := SkillNet.decode_skill_move(p.data)
			if sm == null:
				push_warning("NetClient: short OpSkillMove (%d bytes) dropped" % p.data.size())
			else:
				print("SKILL move: character %d skill %d to (%.1f, %.1f, %.1f)" % [
					sm.character_id, sm.skill_id, sm.x, sm.y, sm.z])
				skill_moved.emit(sm)
		PartyNet.OP_CREATE_ACK, PartyNet.OP_INVITE_ACK, PartyNet.OP_JOIN_ACK, \
				PartyNet.OP_PARTY_INFO, PartyNet.OP_REQUEST, PartyNet.OP_EVENT, \
				PartyNet.OP_ITEM_NOTICE:
			party.handle(p.opcode, p.data)
		RewardNoticeNet.OP_EXP_GAIN:
			var g := RewardNoticeNet.decode_exp_gain(p.data)
			if g == null:
				push_warning("NetClient: short 0x3056 (%d bytes) dropped" % p.data.size())
			else:
				exp_gained.emit(g)
		RewardNoticeNet.OP_CHAR_INFO:
			var gold := RewardNoticeNet.decode_gold(p.data)
			if not gold.is_empty():
				gold_total.emit(gold[0], gold[1])
		GuildNet.OP_CREATE_RESULT:
			var r := GuildNet.decode_result(p.data)
			_keep_guild(r)
			guild_create_result.emit(r)
		GuildNet.OP_JOIN_RESULT:
			var r := GuildNet.decode_result(p.data)
			_keep_guild(r)
			guild_join_result.emit(r)
		GuildNet.OP_LEAVE_RESULT:
			var r := GuildNet.decode_leave_result(p.data)
			if r.error == "" and r.ok:
				_keep_guild(GuildNet.Result.new())
			guild_leave_result.emit(r.ok, r.reason if r.error == "" else r.error)
		GuildNet.OP_INFO_RESULT:
			var r := GuildNet.decode_result(p.data)
			_keep_guild(r)
			guild_info_result.emit(r)
		GuildNet.OP_POINTS_RESULT:
			guild_points_result.emit(GuildNet.decode_points_result(p.data))
		GuildNet.OP_LEVEL_RESULT:
			guild_level_result.emit(GuildNet.decode_level_result(p.data))
		UniqueNoticeNet.OP_UNIQUE_NOTICE:
			var un := UniqueNoticeNet.decode(p.data)
			if un != null:
				unique_notice.emit(un)
			else:
				print("NetClient: malformed unique notice (%d bytes)" % p.data.size())
		ChatNet.OP_UPDATE:
			var u := ChatNet.decode_update(p.data)
			if u != null:
				chat_update.emit(u)
		ChatNet.OP_RESULT:
			var r := ChatNet.decode_result(p.data)
			if r != null:
				chat_result.emit(r)
		QuestNet.OP_LIST_RESULT:
			var r := QuestNet.decode_list_result(p.data)
			if r.error == "":
				last_quest_list = r.entries.duplicate()
				has_quest_list = true
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
			if r.error == "":
				last_friend_list = r.friends.duplicate()
				has_friend_list = true
			friend_list_result.emit(r.friends, r.error)
		FriendNet.OP_REMOVE_RESULT:
			var r := Auth.decode_result(p.data)
			friend_remove_result.emit(r.ok, r.reason if r.error == "" else r.error)
		FriendNet.OP_PENDING_LIST_RESULT:
			var r := FriendNet.decode_pending_list_result(p.data)
			friend_pending_list_result.emit(r.requests, r.error)
		GmNet.OP_COMMAND_RESULT:
			var r := GmNet.decode_result(p.data)
			if r != null:
				gm_command_result.emit(r)
		TeleportNet.OP_RESULT:
			var r := TeleportNet.decode_result(p.data)
			if r != null:
				teleport_result.emit(r)
		RecallNet.OP_DESIGNATE_RESULT:
			var r := RecallNet.decode_result(p.data)
			if r != null:
				recall_designate_result.emit(r)
		ItemInstance.OP_MORE:
			# The rest of a list's item instances (round 732 review F8).
			if p.data.size() >= 1:
				var more := ItemInstance.decode_block(p.data, 1)
				match int(p.data[0]):
					ItemInstance.CONTAINER_BAG:
						last_inventory_instances.merge(_note_instances("bag", more), true)
					ItemInstance.CONTAINER_WORN:
						last_equipment_instances.merge(_note_instances("worn", more), true)
					ItemInstance.CONTAINER_WAREHOUSE:
						last_storage_instances.merge(_note_instances("warehouse", more), true)
		_:
			if _extra_handlers.has(p.opcode):
				(_extra_handlers[p.opcode] as Callable).call(p.data)
			elif _should_warn_unhandled(p.opcode):
				push_warning("NetClient: unhandled opcode 0x%04x (warned once per connection)" % p.opcode)

## Keeps a list's item instances and logs each one whose data changed since
## it was last logged (round 732): the record, the variance groups and the
## percentages, so a tester's log carries what the tooltip will show.
func _note_instances(container: String, instances: Dictionary) -> Dictionary:
	for at in instances:
		var it: ItemInstance = instances[at]
		var line := it.log_line(container)
		var key := "%s/%d" % [container, at]
		if _logged_instances.get(key, "") != line:
			_logged_instances[key] = line
			print(line)
	return instances
