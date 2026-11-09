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
## Round 863 (OURS): the chosen server's name as the login shows it (the
## shard's row, else the server list entry's name), for the starting message.
## Empty until the login screen has a server.
var server_name := ""

signal login_result(ok: bool, reason: String)
## Round 788: retail's 0xA102, the answer to gateway_login.
signal gateway_login_result(ack: LoginAckNet.Ack)
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
## The account PIN, "Character Lock" (round 788, OURS; CharacterLockNet):
## every 0x0121 reply, to a status request or a create / verify / remove.
signal character_lock_reply(reply: CharacterLockNet.Reply)
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
## Round 808: 0xB024, a body's new heading (uid, the u16 wire angle).
signal entity_turned(uid: int, angle: int)
signal entity_left(character_id: int)
signal change_zone_result(result: WorldNet.ChangeZoneResult)
## A character's state changed (WorldNet.OP_STATE_CHANGE, round 607): kind 1 is
## the motion state -- someone sat down or stood up, this player included.
signal state_changed(change: WorldNet.StateChange)
## An emote someone played (WorldNet.OP_EMOTE, round 781), this player's own
## included: the client plays its own emote on this answer, not on the press.
signal emote_received(object_id: int, emote: int)
## Round 832: 0xB074, the character action's answer (ActionNet.decode_result).
signal action_result(result: int, depth: int, code: int)
## Round 832 (OURS): the Extra tab's ping came back.
signal ping_echo(token: int)

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
## Round 789: the avatar inventory (AvatarNet), beside the bag, the worn list
## and the warehouse: storage slot 0..4 -> ItemInstance, from the avatar list
## (0x0045, 0x3013's avatar section) and every avatar move's reply applied to
## it as the client applies 0xB034 (c:0x87ba20). Empty until the list comes.
var last_avatar_instances: Dictionary = {}
var avatar_list_received := false
## The avatar list arrived (a whole new avatar inventory).
signal avatar_list_result(items: Dictionary)
## An avatar move's reply (AvatarNet.decode_move_ack), after it was applied
## to last_avatar_instances and last_inventory_instances.
signal avatar_move_result(result: Dictionary)
## An avatar grant's reply (AvatarNet.decode_grant_ack), after a granted item
## replaced its bag instance.
signal avatar_grant_result(result: Dictionary)
## 0x3078 {3, slot}: the worn devil's spirit in avatar storage `slot` expired
## (READ s:0x4bbd60); its instance's period word is set to "activated, 0 s
## left" before this fires, so the skill strip and the tooltip read it.
signal avatar_spirit_expired(slot: int)
## What each 0x7034 sent is, oldest first ("avatar" or "item"): a refusal
## (u8 2, u16 code) names no type, so it is routed to whoever sent first.
## OURS bookkeeping; the client keeps one request pending (c:0x7999c0).
var _item_op_kinds: Array = []
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
## Round 838: 0x3201, the worn ammunition's count after a cast spent some
## (READ c:0x882280: a u16, slot 7 implied).
signal ammo_count(count: int)
## A repair's outcome: 0 = repaired, otherwise a refusal code; the gold spent
## and the worn slots' durability afterwards (EquipmentNet.RepairResult).
signal repair_result(code: int, gold_spent: int, durabilities: Array)
## Round 829: 0x3052, one item's durability changed (a wear step): `slot` the
## worn slot, or the bag slot + 13; `was` the value held before (-1 unknown).
## The stored durability lists are updated before it fires.
signal durability_changed(slot: int, durability: int, was: int)
## Round 735 (lane A's hook for the glow): another player's worn item changed
## -- retail 0x3038 (put on, or its plus changed: `ref_id` and `plus` >= 0) or
## 0x3039 (taken off from `slot`, the message's own slot byte as retail's
## FUN_008a9560 uses it: `plus` -1). The server sends them to the mover too, as
## retail does; World3D skips its own uid (its equipment result redrew it). `uid` is retail's u32 unique id, the low 32
## bits of the character id (WorldNet.EntitySnapshot.character_id & 0xffffffff);
## `slot` the equip slot (EquipmentNet.SLOT_*); `plus` the effective plus
## (OptLevel + advanced elixir). World3D redresses the body from it
## (_on_other_equipment_changed) and keeps the plus in its look (_other_looks).
## `own_ref` (round 843, OURS): the item's own RefItemID when `ref_id` is the
## row a model switcher has it drawn as, else 0 (Broadcast.own_ref).
signal other_player_equipment_changed(uid: int, slot: int, ref_id: int, plus: int, own_ref: int)
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
## Retail 0x3036 (round 785): a character in the zone -- this player too --
## just picked something up; play its pick-up clip, facing the item.
signal pick_up_motion(motion: GroundItemsNet.PickUpMotion)
## The player's character just advanced a level: its new level and its total
## unspent stat points. Sent only to the character that levelled.
signal level_up(new_level: int, stat_points: int)
## Round 716: retail 0x3056, what a kill (or any award) gained this character.
signal exp_gained(gain: RewardNoticeNet.ExpGain)
## Round 716: retail 0x304E kind 1, the character's new gold total.
signal gold_total(total: int, show: bool)
## Round 860: 0x304E kind 4, the berserk count and the source it rose from.
signal hwan_count(count: int, source: int)
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

## Round 869: the game worlds' runtime structures (the Dimension hole's gate,
## the trigger doors; StructureSpawnNet) in view, by uid, and their messages
## (GameWorldNet): 0x351E, the 0x300C words 0x0C1A / 0x0C1C, 0x320C, 0xB05A.
var structure_roster := StructureSpawnNet.Roster.new()
signal structure_spawned(rec: StructureSpawnNet.Record)
signal structure_despawned(uid: int)
signal event_zone_state(uid: int, state: int)
signal world_notice(n: Dictionary)
signal timed_job(d: Dictionary)
signal teleport_use_ack(d: Dictionary)
## RefObjID -> StructureSpawnNet kind, handed over with the item table.
var _structure_kinds: Dictionary = {}

## Round 795: the COS in view (CICCos records: rides, transports, pets) by
## uid, as last spawned, and this character's own COS data (0x30C8) by uid --
## kept so a World3D that comes up after them adopts them (cos_spawned /
## cos_data have no listener before it). docs/protocol/pets.md.
var cos_roster := {}
var cos_own := {}
signal cos_spawned(rec: CosSpawnNet.Record)
signal cos_despawned(uid: int)
## The owner's 0x30C8, 0x30C9 and the replies to its COS requests.
signal cos_data(d: CosNet.Data)
signal cos_update(u: CosNet.Update)
signal cos_owner_state(d: Dictionary)
signal cos_level_up(uid: int)
signal cos_hp(uid: int, hp: int)
## 0x3040: a bag item's COS state / rent changed ({slot, mask, state, rent_secs}).
signal item_state_changed(d: Dictionary)
## 0xB0CB {ok, code, rider, mounted, cos}; 0x30D0 {uid, walk, run}.
signal ride_changed(d: Dictionary)
signal speed_changed(d: Dictionary)
## 0xB0C5, 0xB420, and the two-field replies (0xB0C6, 0xB116, 0xB117: op, d).
signal cos_command_result(d: Dictionary)
signal cos_setting_result(d: Dictionary)
signal cos_reply(op: int, d: Dictionary)
## 0xB034's pet-bag forms (CosNet.decode_bag_op).
signal cos_bag_op(d: Dictionary)

## Round 799: this character's job (JobNet; docs/protocol/jobs.md) -- the
## player object's +0x7be kind, +0x7bf level, +0x20b4 exp, +0x20b8
## contribution, +0x20bc reward and +0x2098 alias, as the client keeps them.
## Set by OP_JOB_INFO (OURS: retail's 0x3013 section), 0xB0E1, 0xB0E2, 0xB0E3
## and 0x30E6.
var job_kind := 0
## Round 801: the quotations last told (ref item -> unit price; 0x30E0) and
## the owner's trade scale (0x30E8).
var trade_prices_now := {}
var trade_scale := 0
var job_level := 0
var job_exp := 0
var job_contribution := 0
var job_reward := 0
var job_alias := ""
## Round 800: each player in view's job from its spawn record, by uid:
## {state, kind, level, trade_rank}. Retail updates it only from the spawn:
## a suit put on or taken off in view changes no observer's state.
var user_jobs := {}
## Round 814: each player in view's guild line by uid -- {guild_id,
## guild_name, nickname} -- from its spawn record, 0x30FF and 0x3256
## (GuildPlateNet); and this player's own (the server's 0x30FF about it).
var user_guilds := {}
var own_guild_line := {}
## A character's guild line changed (uid; World3D re-draws its line).
signal guild_line_changed(uid: int)
## Round 860: the client's "at war" guild set (0xeedc04, READ: c:0x9dd8a0
## tests it), guild id -> true -- the guild war mark's (GuildWarMark).
var war_guilds := {}
signal war_guilds_changed
## 0x30EF {u8 op, u32 guild}: op 0 adds the guild to the set, 1 takes it out
## (READ c:0x88a770; the server sends it to a guild's own members on its
## first war's start and its last war's end, s:0x5c8800 / s:0x5c88d0).
const OP_GUILD_WAR_STATE := 0x30EF

## Round 860: a war flag as the spawn's guild block and 0x30FF carry it
## (0 at war -> in the set, 1 -> out; READ c:0x9de046).
func note_war_flag(guild_id: int, flag: int) -> void:
	if guild_id == 0 or flag < 0:
		return
	var had := war_guilds.has(guild_id)
	if flag == 0:
		war_guilds[guild_id] = true
	else:
		war_guilds.erase(guild_id)
	if had != war_guilds.has(guild_id):
		print("NetClient: guild %d %s the at-war set (flag %d)" % [guild_id, "joins" if flag == 0 else "leaves", flag])
		war_guilds_changed.emit()
## 0xB256: {ok, code, guild_id, target, nickname} (GuildPlateNet).
signal guild_grant_result(d: Dictionary)
## Round 800: 0x3041 type 2 sub 2 / 0x3042 -- a job suit's 10 seconds starting
## and cancelled (uid, seconds; uid, the cancel byte).
signal strip_started(uid: int, seconds: int)
signal strip_cancelled(uid: int, kind: int)
## Any of the fields above changed.
signal job_changed()
## A job reply (0xB0E1..0xB0E6, JobNet's decoders): op, its dictionary.
signal job_reply(op: int, d: Dictionary)
## 0x30E6: the job exp notice ({kind, level, exp}) and the level and exp it
## replaced (FUN_00884dd0 compares them for the GET / LOST / level-up lines).
signal job_exp_changed(d: Dictionary, old_level: int, old_exp: int)
## Round 801: the specialty trade (TradeNet). trade_prices: an NPC's
## quotation list or one changed entry (0x30E0, merged into trade_prices_now);
## trade_scale: the owner's trade scale (0x30E8); trade_leash: 0x30E7;
## trade_info: the trade-info window's rows (0xB4D4); trade_result: a
## transport buy's or sale's 0xB034 (types 0x13 / 0x14) or a refusal while
## one is the oldest move out.
signal trade_prices(prices: Dictionary)
signal trade_scale_changed(scale: int)
signal trade_leash(kind: int)
signal trade_info(rows: Array)
signal trade_result(d: Dictionary)
## A 0x300C word other than the unique notices' (round 801).
signal notice_word(word: int)
## Round 802 (JobPvpNet): a blow on a player or a COS in the zone
## (OpPlayerStruck, JobPvpNet.decode_struck), and the trader's safe trade
## (0x34D5, JobPvpNet.decode_safe_trade; the last one kept for a world
## scene that loads after the login's report).
signal player_struck(d: Dictionary)
signal safe_trade(d: Dictionary)
var safe_trade_last := {}
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
## OPENSRO_QA_BAG_LIST_DELAY_MS holds each bag list back that long (round
## 830): the order a real network gives an equip's two replies.
var _qa_bag_list_delay_ms := int(OS.get_environment("OPENSRO_QA_BAG_LIST_DELAY_MS"))
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
## least); the rest stays in the socket for the next frame. A share is at most
## what the frame's crowd budget leaves it (OtherCrowd.FrameBudget).
const GROUP_STEP_USEC := 4000
const NET_FRAME_BUDGET_USEC := 8000
## The group being read: {r: the reader, count, i: records read, op}, or null.
var _group_job = null
## Round 762's review, F6: bumped at every group's 0x3018, so World3D tells a
## new group's first share from the next share of the one being read (each
## share is its own user_group_begin / _end bracket).
var group_serial := 0
## Round 764 (OURS): when the group whose 0x3018 bumped group_serial came off
## the socket (msec, Packet.rx_msec) -- not when it is read, which is a
## frame's share at a time and seconds later for a crowd. World3D joins the
## groups that ARRIVED together (one window of the server's, sent in one
## batch) into one page (r764.md).
var group_rx_msec := 0
## The receive time of the packet being dispatched (or of the spawn message
## being replayed): Packet.rx_msec, or now when it has none.
var _rx_msec := 0
## Whether spawn messages are being replayed (set_spawn_item_rows): a group
## then is read whole, in order with what follows it.
var _replaying := false
## QA (round 762): the longest single dispatch since the frame log last read
## it, and its opcode (0x3018: a group's share, its bracket's pump included).
static var qa_max_op_usec := 0
static var qa_max_opcode := 0
static var qa_rx_bytes := 0
static var qa_rx_packets := 0
static var qa_group_players := 0
static var qa_groups := 0
var _spawn_frame := Vector2i(-1, -1)
## The dungeon the last result's FrameRegion names ("dungeon/<rid>", round
## 773; DungeonWorld.rid_of_zone), or -1: positions are then dungeon space and
## a click goes out in 0x7021's dungeon form.
var _spawn_dungeon := -1
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
## Round 786: this player's own body mode as the server last said (0x30BF
## kind 4 with its own id), 0 again at every arrival; 2 is the protection
## after one (ArrivalGuard), in which the client refuses its own skills and
## its attacks on players (READ, 0x81ba58 / 0x791fda).
var own_body_mode := 0
## A skill or an attack this client refused itself for the protection
## (ArrivalGuard.refuses_skill): nothing went out.
signal untouchable_refused(what: String)
signal buff_ended(ended: SkillNet.BuffEnd)
signal skill_moved(moved: SkillNet.SkillMove)
## OpSkillCast 0x00FA (round 622): another player (or a monster) in the zone
## cast a skill -- its start, then its act.
signal skill_cast(cast: SkillNet.SkillCast)

## The party (round 711): the client's party manager, fed by the retail party
## messages (PartyNet, PartyState). Windows read it and listen to its signals;
## it lives here so a message that arrives before World3D listens is kept.
var party := PartyState.new()
## The quest log and its messages (round 785, QuestState; the opcodes are
## routed through register_handler at _init).
var quest := QuestState.new()
## Round 821: the player's guild as the original keeps it (the guild block,
## GuildData), which the guild window draws.
var guild_data := GuildData.new()
## Round 822: the membership replies and the invitation (GuildOpsState).
var guild_ops := GuildOpsState.new()
## Round 844 lane G part 2: the vote, the GP history, the recall.
var guild_part2 := GuildPart2Net.new()
## Round 844: the guild storage's messages and its kept list (GuildStorageState).
var guild_storage := GuildStorageState.new()
## Round 844: the union requests, their replies and the request box
## (UnionOps; the union record itself is guild_data.union).
var union_ops := UnionOps.new()
## Round 865: the academy (training camp) store and its messages
## (AcademyState; AcademyNet has the layouts).
var academy := AcademyState.new()
## Round 865 (QA): every academy request sent, [opcode, payload], newest
## last, so a run without a server can still show what a click sent.
var academy_sent: Array = []
## Round 824: the guilds' crests (CrestCache; World3D gives it silk.dat).
var crest_cache := CrestCache.new()
## Round 838 (OURS): the service scrolls' messages -- the service lines, the
## plate colours, the rename at character select (ServiceNet).
var service := ServiceNet.new()
## Round 838: the characters' titles -- retail's hwan level (0x30DF and the
## spawn record) and the OURS custom title's text (TitleNet).
var titles := TitleNet.new()
## The game clock (round 786, GameClock): kept here so it outlives a scene
## change, as retail keeps it in its CGame config object.
var game_clock := GameClock.new()
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
## Round 844 (lane G): a reply to the notice, level-up, hand-over,
## permission or donation request (GuildManageNet).
signal guild_manage_result(result: GuildManageNet.Result)

## A chat line arrived (round 634): any type -- ordinary, whisper, party,
## guild, global, notice.
signal chat_update(update: ChatNet.Update)
## A unique monster appeared or was killed somewhere in the world (round 657,
## retail 0x300C's 0x0C05 / 0x0C06).
signal unique_notice(notice: UniqueNoticeNet.Notice)
## The server's answer to a line this client sent (0xB025's fields).
signal chat_result(result: ChatNet.Result)


signal duel_challenge_result(ok: bool, reason: String)
signal duel_invite(invite: DuelNet.Invite)
signal duel_respond_result(ok: bool, reason: String)
signal duel_started(started: DuelNet.Started)
signal duel_declined(declined: DuelNet.Declined)
signal duel_attack_result(result: DuelNet.AttackResult)
signal duel_opponent_damaged(damaged: DuelNet.OpponentDamaged)
signal duel_ended(ended: DuelNet.Ended)

## Round 834: the exchange on the retail wire (ExchangeNet). The request
## box (0x3080 kind 1) with the asker's id.
signal exchange_requested(asker_id: int)
## Round 844 (lane V): 0x3080 kind 10, a guild's proclamation of war
## (GuildWarNet.decode_proclamation), and the war requests' replies.
signal guild_war_proclaimed(info: Dictionary)
signal guild_war_result(op: int, result: Dictionary)
## 0xB081: ok with the partner's id, or the refusal's code.
signal exchange_request_result(ok: bool, value: int)
## 0x3085: the target's side of the start, with the asker's id.
signal exchange_started(asker_id: int)
## 0x308C: ExchangeNet.decode_offer's dictionary.
signal exchange_offer(offer: Dictionary)
## 0x3089 kind 2: the partner's gold at their confirm.
signal exchange_partner_gold(gold: int)
## 0x3086: the partner confirmed.
signal exchange_partner_confirmed
## 0xB082 / 0xB083 / 0xB084: the request's opcode and 1 or the code.
signal exchange_result(op: int, code: int)
## 0xB034 for an exchange move: decode_move_result's dictionary, or
## {"code"} for a refusal.
signal exchange_moved(result: Dictionary)
## 0x3087 / 0x3088 (1 for done, else the code).
signal exchange_closed(code: int)
## Round 839: the players' stalls (StallNet). The answers to this client's
## requests -- 0xB0B1 / 0xB0B2 / 0xB0B5 as a code (1 or the refusal), 0xB0B3,
## 0xB0B4 and 0xB0BA as StallNet's dictionaries -- and the stall messages
## about anyone: 0x30B7 (to a stall's participants), 0x30B8 / 0x30B9 /
## 0x30BB (to the owner's view).
signal stall_open_result(code: int)
signal stall_close_result(code: int)
signal stall_leave_result(code: int)
signal stall_entered(d: Dictionary)
signal stall_buy_result(d: Dictionary)
signal stall_updated(d: Dictionary)
signal stall_event(d: Dictionary)
signal stall_appeared(d: Dictionary)
signal stall_gone(d: Dictionary)
signal stall_renamed(d: Dictionary)
## Round 840: the stall network (StallNetworkNet): 0xB461's dictionary,
## 0xB462's and 0xB463's codes.
signal stall_net_searched(d: Dictionary)
signal stall_net_left(code: int)
signal stall_net_bought(code: int)
## Round 840: 0x3405, a GM's chat or trade ban refused a request
## (PunishNet.decode's dictionary).
signal restriction_notice(d: Dictionary)
## Round 837: the item mall (MallNet). 0xB121's result; a mall buy's 0xB034
## (MallNet.decode_buy_result's dictionary, or {"ok": false, "code"}); the
## silk balances (0x3153) and an outside change (0x3154); the silk history
## (0xB11A).
signal mall_open_result(ok: bool)
signal mall_buy_result(result: Dictionary)
signal mall_silk(silk: int, gift: int, point: int)
signal mall_silk_changed(change: Dictionary)
signal mall_history(result: Dictionary)
## OURS, the item chest: its list, a take's result, the take log and an
## item that went into it.
signal chest_list(entries: Array)
signal chest_take_result(result: Dictionary)
signal chest_log(entries: Array)
signal chest_received(entry: Dictionary)
## Round 838: Magic POP (GachaNet). The draw's 0xB118 (decode_play_result's
## dictionary), Gori's refusal 0xB119 (the code) and a Visible prize's
## notice 0x3120.
signal gacha_play_result(result: Dictionary)
signal gacha_exchange_failed(code: int)
signal gacha_announce(ref: int, count: int)
## Round 837 (OURS): the server's big notice (0x00D8 {u16 len, text}).
signal big_notice(text: String)
const OP_BIG_NOTICE := 0x00D8
## Round 838: retail's 0x3201, the worn ammunition's count (ammo_count).
const OP_AMMO_COUNT := 0x3201
## A big notice that arrived before anything listened (it comes with the
## world entry, during the loading screen): the HUD shows it when built.
var pending_big_notice := ""
## The last 0x3153: [silk, gift silk, point] (CGInterface +0x4ac/+0x4b0/+0x4b4).
var silk_balances: Array = [0, 0, 0]
var has_silk := false

## Round 834: friends on the retail wire (FriendNet). The list (0x3305 and
## every 0x3B07 applied to it), kept in last_friend_list.
signal friend_list_changed(friends: Array)
## A 0x3B07 push, after the list took it (the log on/off line, the
## accepted box).
signal friend_pushed(push: FriendNet.Push)
## Someone asks to be our friend (0x7302 from the server).
signal friend_requested(request: FriendNet.Request)
## 0xB302 {2, code}.
signal friend_failed(failure: FriendNet.Failure)
## 0xB304: ok with the id, or the code.
signal friend_delete_result(ok: bool, value: int)
## Using a consumable: what it restored, and how many are left.
signal use_item_result(result: UseItemNet.Result)
## Round 859: retail's 0x305C -- the player of `uid` (the low 32 bits of
## its character id) used item `ref_id`, accepted; sent to the user too.
signal item_use_effect(uid: int, ref_id: int)
## Round 838: the special reverse return scroll's saved locations
## (UseItemNet.decode_reverse_saved).
signal reverse_saved_result(result: Dictionary)
## The Auto potion window's saved settings (round 786, AutoPotionNet): the
## seven bytes retail's character data carries.
signal auto_potion_config(settings: PackedByteArray)
## The Energy of life scroll's grants (round 632 review, CompositeNet).
signal composite_state(state: CompositeNet.State)
signal composite_use_result(result: CompositeNet.UseResult)
## A grant ended (expired or consumed): drop its icon (retail 0x315B).
signal composite_ended(item_id: int, scroll_id: int)
## Round 838: the premium Gold Time's state or refusal (CompositeNet.GoldTime),
## and a BFI1 grant (CompositeNet.decode_buff_item's Dictionary).
signal gold_time(state: CompositeNet.GoldTime)
signal buff_item(info: Dictionary)
## The BFI1 grants held, by decoration id (CIFMagicStateBoard +0x394's map:
## recorded only, no icon; the stall's "Establish as an avatar stall?" reads
## it).
var buff_items := {}
## Round 839: the stalls this client was told of (0x30B8 / 0x30BB, removed
## by 0x30B9), by owner uid: StallNet.decode_appear's dictionary. A stall
## that arrived in a spawn record is the world's (World3D).
var stalls := {}

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
## The alchemy window's reply (AlchemyNet.Result, round 768): a refusal, a
## cancel, or the attempt with the target's new record. result.reinforce says
## which reply (an elixir's 0xB150 shape, or a stone's 0xB151).
signal alchemy_result(result: AlchemyNet.Result)

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

## Round 786 (MEASURED; the choice is OURS): Nagle's algorithm off on the
## game connection (TCP_NODELAY), so a request is written when it is sent.
## With it on -- StreamPeerTCP's default, and this client's until round 786 --
## a small packet written while an earlier one is still unacknowledged waits
## for that acknowledgement, and a server that has nothing to answer the
## earlier one with acknowledges it late (the delayed ACK: 40 ms on Linux,
## up to 200 ms on Windows; macOS's timer is 100 ms, INFERRED from XNU). The
## walk into reach ends with exactly that pair: the stop report (OpMove with
## the stop flag, which the server relays to the watchers, not the mover) and
## then the attack or the cast (World3D._release_pending_attack). MEASURED on
## the render box against the full-map server: an attack's request->result
## 49-52 ms for 97 of 120 clicks with Nagle on (round 786's table);
## tools/nagle_probe.gd measures the bare socket: 40.9 ms against 0.3 ms.
## Retail sets no TCP_NODELAY (READ: sro_client.exe's six setsockopt calls,
## 0x4b0586, 0x4b2640, 0x4c0731, 0x4c077e, 0x4c0801, 0x4c352d, are all
## SOL_SOCKET 0xffff), but retail sends one request for the whole action --
## 0x7074, the server walks the player into reach -- so nothing waits behind
## an unanswered packet there. OPENSRO_NAGLE=1 turns it back on (an A/B aid).
static func no_delay_wanted() -> bool:
	return OS.get_environment("OPENSRO_NAGLE") != "1"

func _process(_delta: float) -> void:
	_process_net()
	# Round 788: the list's timeout is judged after this frame's reads. Before,
	# it came first, so a frame that started more than LIST_TIMEOUT_MS after
	# the request -- the select screen's harbour build blocks that long in a
	# live run -- could report "no answer" with the answer waiting in the
	# socket (round 788's live run timed out on a server that answers the
	# same request in under 10 ms, MEASURED).
	_check_list_timeout(Time.get_ticks_msec())

func _process_net() -> void:
	if _retail != null:
		_poll_retail()
		return
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
			# Round 786: every request goes out at once (no_delay_wanted).
			_tcp_peer.set_no_delay(no_delay_wanted())
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
	_net_frame(_poll_peer)

func _poll_peer() -> Packet:
	return _reader.poll(_peer)

## What is not dispatched this frame waits in the reader's buffer, the socket
## emptied (PacketReader.drain).
func _drain() -> void:
	if _reader != null and _peer != null:
		_reader.drain(_peer)

## One frame's packets (round 762's review, F5: split out of _process so a
## test can feed them). `poll` answers the next Packet, or null.
## Round 759 (QA, FrameSplit only): the read and the dispatch timed apart,
## and each opcode's count and dispatch time (FrameSplit.op).
## Round 762: a group being read goes on first. Round 762's review, F5: while
## it is read, what follows it is read too, and every packet that cannot
## concern a body of the group (_passes_group) is dispatched at once -- the
## player's own HP, combat results, chat, the monsters; the rest waits, in
## order, and goes first once the group is done. Before, nothing after a
## group was dispatched until all of it was read (1-3 s for a crowd).
func _net_frame(poll: Callable) -> void:
	var fs := FrameSplit.on
	var frame_t0 := Time.get_ticks_usec()
	_sync_credit_usec = 0
	if _group_job != null:
		var tg := Time.get_ticks_usec()
		var done := _group_step()
		if fs:
			FrameSplit.add("net_dispatch", Time.get_ticks_usec() - tg)
			if Time.get_ticks_usec() - tg > qa_max_op_usec:
				qa_max_op_usec = Time.get_ticks_usec() - tg
				qa_max_opcode = 0x3018
		if not done:
			_read_during_group(poll, frame_t0)
			return
	var dispatched := 0
	# What waited behind the group, in its order, first.
	while _held_at < _held_packets.size():
		if _group_job != null:
			_read_during_group(poll, frame_t0)
			return
		if dispatched > 0 and _spent(frame_t0) >= NET_FRAME_BUDGET_USEC:
			_drain()
			return
		dispatched += 1
		var hp: Packet = _held_packets[_held_at]
		_held_at += 1
		if hp.opcode == NpcSpawnNet.OP_GROUP_END:
			_held_groups = maxi(_held_groups - 1, 0)
		_dispatch_timed(hp, fs)
	if not _held_packets.is_empty():
		_held_packets.clear()
		_held_groups = 0
		_held_at = 0
		_held_uids.clear()
		_held_barrier = false
	while true:
		if _group_job != null:
			_read_during_group(poll, frame_t0)
			break
		if dispatched > 0 and _spent(frame_t0) >= NET_FRAME_BUDGET_USEC:
			_drain()
			break
		dispatched += 1
		var t0 := Time.get_ticks_usec() if fs else 0
		var p: Packet = poll.call()
		if fs:
			FrameSplit.add("net_read", Time.get_ticks_usec() - t0)
		if p == null:
			break
		_dispatch_timed(p, fs)

## Round 786 (RenderSync): the frame's wait for the render thread, made by a
## body build inside a dispatch, is not the dispatch's own work: it is taken
## off the budget, so a burst of monsters entering the view is read in one
## frame, not one a frame.
var _sync_credit_usec := 0

func credit_render_sync(usec: int) -> void:
	_sync_credit_usec += usec

## What this frame's reading has spent of NET_FRAME_BUDGET_USEC.
func _spent(frame_t0: int) -> int:
	return Time.get_ticks_usec() - frame_t0 - _sync_credit_usec

func _dispatch_timed(p: Packet, fs: bool) -> void:
	if not fs:
		_dispatch(p)
		return
	var t1 := Time.get_ticks_usec()
	qa_rx_bytes += p.data.size() + 6
	qa_rx_packets += 1
	_dispatch(p)
	var t2 := Time.get_ticks_usec()
	FrameSplit.add("net_dispatch", t2 - t1)
	FrameSplit.add("net_packets_calls", 1)
	FrameSplit.op(p.opcode, t2 - t1)
	if t2 - t1 > qa_max_op_usec:
		qa_max_op_usec = t2 - t1
		qa_max_opcode = p.opcode

## Round 762's review, F5 (OURS): the packets behind a group being read --
## held in order, and the uids they name (a movement's: one naming a uid
## held is held too, so a body's moves keep their order) -- and whether a
## barrier (a world entry, a zone change, a teleport, a revive) was held:
## everything after it waits too.
var _held_packets: Array = []
var _held_at := 0
var _held_uids := {}
var _held_barrier := false
## Round 764: the group ends (0x3018) among the held packets -- groups of the
## same window still to be read, so the page they join is not revealed in a
## frame that falls between two of them (group_reading).
var _held_groups := 0

## Reads on while a group is being read, until NET_FRAME_BUDGET_USEC from
## `frame_t0`: each packet is dispatched now when it passes (_passes_group),
## or held.
func _read_during_group(poll: Callable, frame_t0: int) -> void:
	var fs := FrameSplit.on
	while _spent(frame_t0) < NET_FRAME_BUDGET_USEC:
		var p: Packet = poll.call()
		if p == null:
			break
		if _held_barrier or not _passes_group(p):
			if _is_barrier(p.opcode):
				_held_barrier = true
			var u := _move_uid(p)
			if u >= 0:
				_held_uids[u] = true
			if p.opcode == NpcSpawnNet.OP_GROUP_END:
				_held_groups += 1
			_held_packets.append(p)
			continue
		_dispatch_timed(p, fs)
	_drain()

## Tests and QA: how many packets wait behind a group.
func held_count() -> int:
	return _held_packets.size() - _held_at

## The opcodes after which nothing is dispatched ahead of what was held: the
## world itself changes (the views start over).
static func _is_barrier(op: int) -> bool:
	return op == WorldNet.OP_ENTER_WORLD_RESULT or op == WorldNet.OP_CHANGE_ZONE_RESULT or op == TeleportNet.OP_RESULT \
		or op == WorldNet.OP_REVIVE_RESULT

## A movement's uid (0xB021 / 0xB023: u32 at 0), or -1.
static func _move_uid(p: Packet) -> int:
	if (p.opcode == DestMoveNet.OP_MOVEMENT_ECHO or p.opcode == DestMoveNet.OP_MOVEMENT_STOP \
			or p.opcode == DestMoveNet.OP_MOVEMENT_TURN) and p.data.size() >= 4:
		return p.data.decode_u32(0)
	return -1

## Whether `p` may be dispatched while a group is read, ahead of what is held
## (OURS): it cannot concern a body of the group -- this player's own state
## and results, chat, the social windows, the monsters (never in a player
## group spawn) and the ground items -- or it names only bodies already in
## view (a movement of a known player none of whose moves is held; an object
## status or a monster's blow on this player). Everything else waits.
func _passes_group(p: Packet) -> bool:
	match p.opcode:
		InventoryNet.OP_LIST_RESULT, InventoryNet.OP_MOVE_RESULT, StatsNet.OP_STATS_RESULT, EquipmentNet.OP_RESULT, OP_AMMO_COUNT, \
				EquipmentNet.OP_REPAIR_RESULT, ShopNet.OP_BUY_RESULT, ShopNet.OP_LIST_RESULT, ShopNet.OP_SELL_RESULT, \
				ItemOpNet.OP_MOVE_RESULT, ItemOpNet.OP_BUYBACK_FAIL, UseItemNet.OP_RESULT, UseItemNet.OP_REVERSE_SAVED_RESULT, CompositeNet.OP_STATE, \
				CompositeNet.OP_USE_RESULT, CompositeNet.OP_END, CompositeNet.OP_GOLD_TIME, CompositeNet.OP_BUFF_ITEM_START, \
				CompositeNet.OP_BUFF_ITEM_REFRESH, CompositeNet.OP_BUFF_ITEM_END, StorageNet.OP_LIST_RESULT, StorageNet.OP_DEPOSIT_RESULT, \
				StorageNet.OP_WITHDRAW_RESULT, StorageNet.OP_GOLD_RESULT, CombatNet.OP_ATTACK_RESULT, CombatNet.OP_BERSERK_RESULT, \
				CombatNet.OP_MONSTER_DAMAGED, CombatNet.OP_MONSTER_DIED, CombatNet.OP_LOOT_DROPPED, CombatNet.OP_MONSTER_LEFT, \
				CombatNet.OP_MONSTER_MOVED, CombatNet.OP_MONSTER_MOTION_LIST, CombatNet.OP_MONSTER_SPAWNED, \
				CombatNet.OP_MONSTER_LIST_RESULT, CombatNet.OP_LEVEL_UP, GroundItemsNet.OP_LIST_RESULT, GroundItemsNet.OP_SPAWNED, \
				GroundItemsNet.OP_REMOVED, GroundItemsNet.OP_OWNER_RELEASED, GroundItemsNet.OP_PICK_UP_RESULT, \
				SkillNet.OP_LEARN_RESULT, SkillNet.OP_LIST_RESULT, SkillNet.OP_STATE_RESULT, SkillNet.OP_RAISE_RESULT, \
				RewardNoticeNet.OP_EXP_GAIN, RewardNoticeNet.OP_CHAR_INFO, GuildNet.OP_CREATE_RESULT, GuildNet.OP_JOIN_RESULT, \
				GuildNet.OP_LEAVE_RESULT, GuildNet.OP_INFO_RESULT, GuildNet.OP_POINTS_RESULT, GuildNet.OP_LEVEL_RESULT, \
				UniqueNoticeNet.OP_UNIQUE_NOTICE, ChatNet.OP_UPDATE, ChatNet.OP_RESULT, QuestNet.OP_UPDATE, QuestNet.OP_LOG, \
				QuestNet.OP_TALK_PAGE, QuestNet.OP_REWARD_WINDOW, QuestNet.OP_TAKE_REWARD_RESULT, QuestNet.OP_ABANDON_RESULT, \
				QuestNet.OP_CLAIM_RESULT, QuestNet.OP_UNMARK, FriendNet.OP_ASK, FriendNet.OP_ASK_FAILED, ExchangeNet.OP_REQUEST_RESULT, \
				ExchangeNet.OP_STARTED, ExchangeNet.OP_OFFER, ExchangeNet.OP_UPDATE, ExchangeNet.OP_CONFIRMED, \
				ExchangeNet.OP_CONFIRM_RESULT, ExchangeNet.OP_APPROVE_RESULT, ExchangeNet.OP_CANCEL_RESULT, \
				ExchangeNet.OP_DONE, ExchangeNet.OP_CLOSED, StallNet.OP_OPEN_RESULT, StallNet.OP_CLOSE_RESULT, \
				StallNet.OP_ENTER_RESULT, StallNet.OP_BUY_RESULT, StallNet.OP_LEAVE_RESULT, StallNet.OP_UPDATE_RESULT, \
				StallNet.OP_EVENT, StallNetworkNet.OP_SEARCH_RESULT, StallNetworkNet.OP_LEAVE_RESULT, \
				StallNetworkNet.OP_BUY_RESULT, PunishNet.OP_RESTRICTION, \
				FriendNet.OP_DELETE_RESULT, FriendNet.OP_LIST, FriendNet.OP_PUSH, GmNet.OP_COMMAND_RESULT, OP_UNSTUCK_RESULT, \
				AlchemyNet.OP_REINFORCE_RESULT, AlchemyNet.OP_STONE_RESULT, AutoPotionNet.OP_CONFIG, \
				GameClock.OP_POSITION, GameClock.OP_UPDATE, AvatarNet.OP_LIST, AvatarNet.OP_GRANT_ACK, AvatarNet.OP_ITEM_STATE, \
				CosNet.OP_DATA, CosNet.OP_UPDATE, CosNet.OP_ITEM_STATE, CosNet.OP_COMMAND_ACK, CosNet.OP_SETTING_ACK, \
				CosNet.OP_TERMINATE_ACK, CosNet.OP_UNSUMMON_ACK, CosNet.OP_NAME_ACK, JobNet.OP_JOB_INFO, JobNet.OP_JOB_EXP, \
				JobNet.OP_JOIN_RESULT, JobNet.OP_WITHDRAW_RESULT, JobNet.OP_ALIAS_RESULT, JobNet.OP_RANKING_RESULT, \
				JobNet.OP_REWARD_RESULT, JobNet.OP_PREV_JOB_RESULT, SpecialtyNet.OP_PRICES, SpecialtyNet.OP_SCALE, \
				SpecialtyNet.OP_LEASH, SpecialtyNet.OP_INFO_RESULT, JobPvpNet.OP_SAFE_TRADE:
			return true
		CombatNet.OP_MONSTER_ATTACKED:
			# A monster's blow on this player (the target at 8, s64).
			return own_character_id >= 0 and p.data.size() >= 16 and p.data.decode_s64(8) == own_character_id
		StatusNet.OP_OBJECT_STATUS:
			var st := StatusNet.decode_object_status(p.data)
			return st.error == "" and st.owner_kind == SkillNet.OWNER_CHARACTER and own_character_id >= 0 \
				and (st.owner_id == own_character_id or st.owner_id == (own_character_id & 0xffffffff))
		DestMoveNet.OP_MOVEMENT_ECHO, DestMoveNet.OP_MOVEMENT_STOP, DestMoveNet.OP_MOVEMENT_TURN:
			var u := _move_uid(p)
			return u >= 0 and user_roster.has(u) and not _held_uids.has(u) and _pending_spawns.is_empty()
	return false

## Connects to host:port. If use_tls is true, wraps the connection in TLS
## once the underlying TCP handshake completes (see gateway.Server.TLSConfig
## server-side for the matching -tls-cert/-tls-key flags) -- otherwise
## plain TCP, same as before TLS support existed.
func connect_to_server(host: String, port: int, use_tls: bool = false) -> void:
	if _retail != null: # round 788: a legacy agent is let go quietly
		_retail.close()
		_retail = null
	_tcp_peer = StreamPeerTCP.new()
	_peer = null
	_reader = PacketReader.new()
	_attack_targets_in_flight.clear()
	_attack_types_in_flight.clear()
	own_character_id = -1
	own_guild_line = {}
	guild_data.clear()
	guild_ops.reset_connection()
	guild_storage.reset()
	union_ops.reset_connection()
	academy.reset_connection()
	crest_cache.clear()
	buff_roster.clear()
	npc_roster.clear()
	structure_roster.clear()
	user_roster.clear()
	user_guilds.clear()
	war_guilds.clear()
	character_states.clear()
	_zone_arrivals.clear()
	zone_departures.clear()
	_pending_spawns.clear()
	_group_job = null
	_held_packets.clear()
	_held_groups = 0
	_held_at = 0
	_held_uids.clear()
	_held_barrier = false
	body_modes.clear()
	party.reset_connection()
	# A new connection waits for its own 0x3020 (round 786).
	game_clock.reset()
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
	if _retail != null:
		_retail.close()
		_retail = null
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
	own_guild_line = {}
	cos_own = {}
	safe_trade_last = {}
	buff_roster.clear()
	npc_roster.clear()
	structure_roster.clear()
	user_roster.clear()
	user_guilds.clear()
	war_guilds.clear()
	character_states.clear()
	_zone_arrivals.clear()
	zone_departures.clear()
	_pending_spawns.clear()
	_group_job = null
	_held_packets.clear()
	_held_groups = 0
	_held_at = 0
	_held_uids.clear()
	_held_barrier = false
	body_modes.clear()
	party.reset_connection()
	_forget_session_lists()
	_list_watch.answered()
	disconnected.emit()

func is_connected_to_server() -> bool:
	return _connected or _retail != null

func _send(opcode: int, data: PackedByteArray = PackedByteArray()) -> void:
	if _retail != null:
		_send_retail(opcode, data)
		return
	if not is_connected_to_server():
		push_error("NetClient: _send called while not connected")
		return
	_peer.put_data(Packet.new(opcode, data).encode())

# --- A legacy server's agent (round 788) -------------------------------------

## The agent connection of a `type: legacy` server once RetailLogin has logged
## in on it (OURS, the smallest adapter): the select screen's lobby requests
## go out on it in the original framing, and what it sends back is dispatched
## as if it had come on this project's own connection -- LobbyNet's payloads
## are the original's (round 682). Only the lobby is carried: the world
## protocol is not the original one yet, so anything else is dropped with a
## log line, and Start is refused on the select screen itself.
var _retail: RetailLink = null
const RETAIL_OPS := [LobbyNet.OP_LOBBY]

func attach_retail(link: RetailLink) -> void:
	if _connected or _tcp_peer != null:
		disconnect_from_server()
	_retail = link
	server_host = link.host
	server_port = link.port
	print("NetClient: on a legacy server's agent %s:%d" % [link.host, link.port])

## Whether the session is a legacy server's (the select screen's Start).
func is_retail() -> bool:
	return _retail != null

func _send_retail(opcode: int, data: PackedByteArray) -> void:
	if not opcode in RETAIL_OPS:
		print("NetClient: 0x%04x not sent -- a legacy server's agent carries only the lobby (round 788)" % opcode)
		return
	_retail.send(_retail.conv.send_lobby(opcode, data))

func _poll_retail() -> void:
	for ev in _retail.poll():
		match str(ev["kind"]):
			"frame":
				_dispatch(Packet.new(int(ev["opcode"]), ev["data"]))
			"closed":
				print("NetClient: the legacy agent closed: %s" % ev.get("why", ""))
				disconnect_from_server()
				return

func login(username: String, password: String) -> void:
	_send(Auth.OP_LOGIN, Auth.encode_credentials(username, password))

## Round 788: retail's 0x6102 on this project's own connection (LoginAckNet),
## answered by 0xA102 (gateway_login_result). The content id is the
## archive's own (RetailClientInfo) when it can be read, else 0, and the
## shard id 0: this server is one process with one shard and checks neither
## (OURS, docs/protocol/opcodes/login.md).
func gateway_login(content_id: int, username: String, password: String, shard_id: int = 0) -> void:
	_send(LoginAckNet.OP_GATEWAY_LOGIN, LoginAckNet.encode_login(content_id, username, password, shard_id))

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

## The account PIN (round 788, CharacterLockNet; OURS). Nothing here is
## logged: the PIN and the device token never reach a print.
func char_lock_status(device_token: String) -> void:
	_send(CharacterLockNet.OP_STATUS, CharacterLockNet.encode_status(device_token))

func char_lock_create(pin: String) -> void:
	_send(CharacterLockNet.OP_CREATE, CharacterLockNet.encode_pin(pin))

func char_lock_verify(pin: String, remember: bool, device_token: String) -> void:
	_send(CharacterLockNet.OP_VERIFY, CharacterLockNet.encode_verify(pin, remember, device_token))

func char_lock_remove(pin: String) -> void:
	_send(CharacterLockNet.OP_REMOVE, CharacterLockNet.encode_pin(pin))

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

func _forget_session_lists() -> void:
	last_avatar_instances = {}
	avatar_list_received = false
	_item_op_kinds = []
	last_guild_result = null
	last_friend_list = []
	has_friend_list = false
	silk_balances = [0, 0, 0]
	has_silk = false
	quest.reset()
	# A new entry starts with no COS (round 803 fix): the server tells this
	# entry's own with 0x30C8 after it. Kept, the COS of the last session --
	# a disconnect or a server restart sends no 0x30C9 removal -- came back
	# as status slots with nothing behind them.
	cos_own = {}
	# Round 802: the safe trade is the entry's own (a trader's login sends
	# it; any other character none).
	safe_trade_last = {}

## The current zone label, updated from last_enter_world_result.zone on
## entering the world and again from a successful change_zone_result --
## scenes that need to know "which real region's assets to load" (see
## World3D.gd) read this rather than tracking it themselves.
var current_zone := ""

func enter_world(char_name: String) -> void:
	current_character_name = char_name
	guild_data.own_name = char_name
	_forget_session_lists()
	# The OpSelfId that answers this entry names the character entering now.
	own_character_id = -1
	own_guild_line = {}
	# Round 838: every title comes again -- the own one after the entry, the
	# others' with their spawns.
	titles.clear()
	# Start (round 682): 0x7001, answered by 0xB001 and, when it is OK, the
	# enter-world result.
	_send(LobbyNet.OP_START, LobbyNet.encode_start(char_name))

## `heading_wire` (round 653) is a heading run's u16 wire angle
## (SkyRun.wire_angle), or -1 for a position with no run in effect.
func move_to(x: float, y: float, z: float, relocated: bool = false, heading_wire: int = -1) -> void:
	_send(WorldNet.OP_MOVE, WorldNet.encode_move(x, wire_y(y), z, relocated, heading_wire))

## Round 870: the heights on the movement wire are region-local, as the
## original's are (its 0x7021 destination names the region and the point in
## it, FUN_009ec080), and as the server's own are (its navigation mesh, the
## nests, the instance starts). This client draws a field frame at
## -wire_height_anchor (World3D._group_position: every region group stands at
## minus the frame's anchor height, round 570 -- OURS calibration the
## original does not have), so its scene heights are the wire's less the
## anchor. Until round 870 they went out as scene heights: MEASURED the
## anchor is -2.5 in Jangan's frame but 244 in Hotan's, 834 in the Forgotten
## World's Togui and -1800 in the Wrecked Ship's, and the server -- which
## takes a destination's height for the leg's end -- then held a player 834
## below the NPC nests' heights in Togui, beyond the 300 of the NPC reach
## (0x7045 refused 4 at 167 units after one click-walk). World3D sets the
## anchor for each field frame; in a dungeon it is not applied.
var wire_height_anchor := 0.0

## The wire's height for this client's scene height `y` (a field frame).
func wire_y(y: float) -> float:
	return y + wire_height_anchor if _spawn_dungeon < 0 else y

## This client's scene height for the wire's height `y` (a field frame).
func scene_y(y: float) -> float:
	return y - wire_height_anchor if _spawn_dungeon < 0 else y

## Round 749: where the player's walk stopped short of the destination its
## 0x7021 named (WorldNet.MOVE_FLAG_STOPPED, OURS) -- the server takes it on
## its own leg and tells the window with retail's 0xB023.
## Round 749's verification (FP6): asks the server to put the character at its
## zone's landing spot (OP_UNSTUCK; answered by unstuck_result).
func request_unstuck() -> void:
	_send(OP_UNSTUCK)

func report_stop(x: float, y: float, z: float) -> void:
	_send(WorldNet.OP_MOVE, WorldNet.encode_move(x, wire_y(y), z, false, -1, true))

## Round 749: retail's click move, 0x7021's destination form, for the world
## point `at` in the frame the server named (the last result's FrameRegion):
## the region and the local coordinates truncated (FUN_009ec080). Returns the
## world point the server will walk to -- the truncated one -- or
## Vector3.INF when no frame is known (nothing is sent).
func move_order_destination(at: Vector3) -> Vector3:
	if _spawn_dungeon >= 0:
		var d := DungeonWorld.to_dungeon(at)
		_send_move(DestMoveNet.encode_dungeon_destination(_spawn_dungeon, d.x, d.y, d.z))
		return quantize_destination(at)
	if _spawn_frame.x < 0:
		return Vector3.INF
	var l := DestMoveNet.local_of_world(at.x, at.z, _spawn_frame)
	_send_move(DestMoveNet.encode_destination(int(l["region"]), float(l["lx"]), wire_y(at.y), float(l["lz"])))
	return quantize_destination(at)

## Round 795: the COS this player rides (its uid), 0 on foot. While it is
## set the client steers the COS: a move goes out as 0x70C5 {uid, 1, the
## 0x7021 body} (READ c:FUN_009ebd10: the controlled object is the mount).
var riding_mount := 0

func _send_move(body: PackedByteArray) -> void:
	if riding_mount != 0:
		_send(CosNet.OP_COMMAND, CosNet.encode_command_move(riding_mount, body))
	else:
		_send(DestMoveNet.OP_MOVEMENT_REQUEST, body)

## Round 795: a record's region-local point in world coordinates (the frame
## of the last result), as the players' snapshots are made.
func spawn_world(region: int, local: Vector3) -> Vector3:
	var at := UserSpawnNet.world_xz(region, local.x, local.z, _spawn_frame)
	return Vector3(at.x, local.y, at.y)

## Round 749's review, F5: the world point the server will take for a
## destination `at` -- the region-local coordinates truncated as the wire
## carries them, turned back into world ones -- without sending anything, so
## the client's 5.0 rule compares what the server compares. Vector3.INF when
## no frame is known.
func quantize_destination(at: Vector3) -> Vector3:
	if _spawn_dungeon >= 0:
		var d := DungeonWorld.to_dungeon(at)
		return DungeonWorld.to_world(Vector3(float(int(d.x)), float(int(d.y)), float(int(d.z))))
	if _spawn_frame.x < 0:
		return Vector3.INF
	var l := DestMoveNet.local_of_world(at.x, at.z, _spawn_frame)
	var lx := float(int(float(l["lx"])))
	var lz := float(int(float(l["lz"])))
	var w := DestMoveNet.world_of_local(int(l["region"]), lx, lz, _spawn_frame)
	return Vector3(w.x, float(int(at.y)), w.y)

## Round 808: the arrow keys' turn, 0x7024 {u16 angle} (FUN_009eb470), or
## 0x70C5 {uid, 4, angle} riding.
func move_turn(angle: int) -> void:
	if riding_mount != 0:
		_send(CosNet.OP_COMMAND, DestMoveNet.encode_cos_angle(riding_mount, DestMoveNet.COS_COMMAND_TURN, angle))
	else:
		_send(DestMoveNet.OP_MOVEMENT_TURN_REQUEST, DestMoveNet.encode_angle(angle))

## Round 808: Up's release, 0x7023 {u16 angle} (FUN_009eb6e0), or 0x70C5
## {uid, 3, angle} riding.
func move_stop_request(angle: int) -> void:
	if riding_mount != 0:
		_send(CosNet.OP_COMMAND, DestMoveNet.encode_cos_angle(riding_mount, DestMoveNet.COS_COMMAND_STOP, angle))
	else:
		_send(DestMoveNet.OP_MOVEMENT_STOP_REQUEST, DestMoveNet.encode_angle(angle))

## Round 749: 0x7021's heading form (the sky click, FUN_009ebec0): kind 0,
## the command (SkyRun.COMMAND_FORWARD) and the u16 wire angle.
func move_order_heading(command: int, angle: int) -> void:
	_send_move(DestMoveNet.encode_heading(command, angle))

## Asks to sit down or stand up (WorldNet.OP_MOTION_REQUEST [4], the N key),
## or to walk or run ([2] / [3], the action window's Walk/Run, round 781).
func request_motion(value: int) -> void:
	_send(WorldNet.OP_MOTION_REQUEST, WorldNet.encode_motion_request(value))

## Round 832: trace the object `target` (0x7074 [01 03 01 <u32>], READ
## 0x793b00 case 1003); 0 for a selection that is no player (ActionNet).
func action_trace(target: int) -> void:
	_send(ActionNet.OP_ACTION_REQUEST, ActionNet.encode_trace(target))

## Round 832: 0x7074 [02], the running action's cancel (READ 0x78f8d0).
func action_cancel() -> void:
	_send(ActionNet.OP_ACTION_REQUEST, ActionNet.encode_cancel())

## Round 832 (OURS): the Extra tab's ping.
func send_ping(token: int) -> void:
	# Not to a legacy agent (round 788): it carries the lobby only.
	if _retail == null and is_connected_to_server():
		_send(ActionNet.OP_PING, ActionNet.encode_ping(token))

## Plays an emote (WorldNet.OP_EMOTE [byte], the action window, round 781).
func request_emote(emote: int) -> void:
	_send(WorldNet.OP_EMOTE, WorldNet.encode_emote(emote))

func change_zone(zone: String, spot: Variant = null) -> void:
	_zone_spot_retry = zone if spot is Vector2 else ""
	_send(WorldNet.OP_CHANGE_ZONE, WorldNet.encode_change_zone(zone, spot))

## Round 764: the zone of the last OpChangeZone sent with a spot, until its
## result: a server older than round 764 refuses the trailing spot as a
## "malformed request", and the request is then sent again without it (the
## refusal not passed on), landing where that server lands it, as before.
var _zone_spot_retry := ""

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
	# Round 789 (OURS, AvatarNet): the avatar inventory is asked for with the
	# worn list, as retail's 0x3013 carries it after the inventory.
	list_avatars(char_name)

## Round 789: the avatar inventory (AvatarNet.OP_LIST_REQUEST, answered by
## AvatarNet.OP_LIST -> avatar_list_result).
func list_avatars(char_name: String) -> void:
	_send(AvatarNet.OP_LIST_REQUEST, AvatarNet.encode_list_request(char_name))

## Round 789: bag index -> avatar storage slot (0x7034 type 0x24).
func avatar_equip(bag_slot: int, avatar_slot: int) -> void:
	_item_op_kinds.append("avatar")
	_send(AvatarNet.OP_ITEM_MOVE, AvatarNet.encode_equip(bag_slot, avatar_slot))

## Round 789: avatar storage slot -> the bag index clicked (0x7034 type 0x23).
func avatar_unequip(avatar_slot: int, bag_slot: int) -> void:
	_item_op_kinds.append("avatar")
	_send(AvatarNet.OP_ITEM_MOVE, AvatarNet.encode_unequip(avatar_slot, bag_slot))

## Round 789: grant `code` (a MATTR_ name) to the avatar in bag index
## `bag_slot` (0x34A9 -> 0x34AA, avatar_grant_result).
func avatar_grant(bag_slot: int, code: String) -> void:
	_send(AvatarNet.OP_GRANT, AvatarNet.encode_grant(bag_slot, code))

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
	_item_op_kinds.append("item")
	_send(ItemOpNet.OP_MOVE, ItemOpNet.encode_split(src, dst, count))

## Sells count of bag slot src to NPC npc (0x7034 type 9).
func sell_item_retail(src: int, count: int, npc: int) -> void:
	_item_op_kinds.append("item")
	_send(ItemOpNet.OP_MOVE, ItemOpNet.encode_sell(src, count, npc))

## Deposits bag slot src's whole stack into warehouse slot dst (0x7034 type 2).
func deposit_retail(src: int, dst: int, npc: int) -> void:
	_item_op_kinds.append("item")
	_send(ItemOpNet.OP_MOVE, ItemOpNet.encode_deposit(src, dst, npc))

## Buys entry index (0 = the oldest) of the buy-back list back (0x7168).
func buyback_retail(npc: int, index: int) -> void:
	_send(ItemOpNet.OP_BUYBACK, ItemOpNet.encode_buyback(npc, index))

## Round 826: the bag slot of the last use asked for (-1 none) -- the reply
## names no item, so its re-use timers are armed for what is there.
var last_use_slot := -1

## Uses one item from a bag slot (a potion). The reply carries the new HP/MP.
func use_item(char_name: String, inventory_slot: int) -> void:
	last_use_slot = inventory_slot
	_send(UseItemNet.OP_USE_ITEM, UseItemNet.encode_use(char_name, inventory_slot))

## A reverse return scroll's use (round 778): the option the box or the map
## chose, and the map option's refoptionalteleport id.
## Round 824: a crest register's use with the crest's 256 bytes.
func use_item_crest(char_name: String, inventory_slot: int, pixels: PackedByteArray) -> void:
	last_use_slot = inventory_slot
	_send(UseItemNet.OP_USE_ITEM, UseItemNet.encode_use_crest(char_name, inventory_slot, pixels))

## Round 838: the skin change scroll's use with the chosen body and scale.
func use_item_skin(char_name: String, inventory_slot: int, ref_obj_id: int, scale: int) -> void:
	last_use_slot = inventory_slot
	_send(UseItemNet.OP_USE_ITEM, UseItemNet.encode_use_skin(char_name, inventory_slot, ref_obj_id, scale))

## Round 838 (OURS): the Custom Title Scroll's use with the typed title.
func use_item_custom_title(char_name: String, inventory_slot: int, text: String) -> void:
	last_use_slot = inventory_slot
	_send(UseItemNet.OP_USE_ITEM, UseItemNet.encode_use_custom_title(char_name, inventory_slot, text))

func use_item_option(char_name: String, inventory_slot: int, option: int, target: int = 0) -> void:
	last_use_slot = inventory_slot
	_send(UseItemNet.OP_USE_ITEM, UseItemNet.encode_use(char_name, inventory_slot, option, target))

## The Auto potion window's settings (round 786): retail's 0x7158 type 2.
func save_auto_potion(settings: PackedByteArray) -> void:
	_send(AutoPotionNet.OP_SAVE, AutoPotionNet.encode_save(settings))

## Asks for the saved Auto potion settings (answered by auto_potion_config).
func load_auto_potion() -> void:
	_send(AutoPotionNet.OP_LOAD, PackedByteArray())

## The casting bar's cancel (round 779): retail's 0x705B, no body.
func scroll_cancel() -> void:
	_send(UseItemNet.OP_SCROLL_CANCEL, PackedByteArray())

## Round 838: list the special scroll's saved locations, or register where
## the player stands into `saved_slot` (UseItemNet.SAVED_*), the scroll in
## `bag_slot`.
func reverse_saved(action: int, saved_slot: int, bag_slot: int) -> void:
	_send(UseItemNet.OP_REVERSE_SAVED, UseItemNet.encode_reverse_saved(action, saved_slot, bag_slot))

## Spends one use of a granted item (the fill an Energy of life scroll grants).
func composite_use(char_name: String, item_id: int, option: int = 0, target: int = 0) -> void:
	_send(CompositeNet.OP_USE, CompositeNet.encode_use(char_name, item_id, option, target))

## Round 838: the premium Gold Time's pause (true) or resume (false), 0x34BF.
func gold_time_pause(pause: bool) -> void:
	_send(CompositeNet.OP_GOLD_TIME_PAUSE, CompositeNet.encode_gold_time_pause(pause))

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

## Round 795: an attack or skill refused because the player rides (READ
## c:0x81ba10: 0x3021 UIIT_MSG_SKILL_USE_FAIL_CANT_USESKILL_IN_RIDESTATE,
## nothing sent), and the owner's own offensive action on a monster (a
## growth pet in attack mode takes the target, c:0x8a6311).
signal ride_refused_action()
signal own_offensive(monster_id: int)

func attack(char_name: String, target_monster_id: int) -> void:
	if not is_connected_to_server():
		return
	if riding_mount != 0:
		ride_refused_action.emit()
		return
	_send(CombatNet.OP_ATTACK, CombatNet.encode_attack(char_name, target_monster_id))
	if target_monster_id > 0:
		own_offensive.emit(target_monster_id)
	if LatencyProbe.on:
		LatencyProbe.attack_send(target_monster_id, Time.get_ticks_msec())
	_attack_targets_in_flight.append(target_monster_id)
	_attack_types_in_flight.append(SkillNet.TARGET_ENTITY)

## Round 802: a plain swing at another player (JobPvpNet.TARGET_CHARACTER,
## his character id) or at a COS (TARGET_COS, its uid). No pet joins it: a
## growth pet's own_offensive is for a monster.
func attack_player(char_name: String, target: int, kind: int) -> void:
	if not is_connected_to_server():
		return
	if riding_mount != 0:
		ride_refused_action.emit()
		return
	_send(CombatNet.OP_ATTACK, JobPvpNet.encode_attack(char_name, target, kind))
	_attack_targets_in_flight.append(target)
	_attack_types_in_flight.append(kind)

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
	# Round 786: no skill in the protection after an arrival (READ,
	# FUN_0081ba10 at 0x81ba58): refused here, nothing sent.
	if ArrivalGuard.refuses_skill(own_body_mode):
		print("CAST refused locally: untouchable (body mode 2), skill %d" % skill_id)
		untouchable_refused.emit("skill")
		return
	if not is_connected_to_server():
		print("CAST send skipped (not connected): skill %d targetType %d" % [skill_id, target_type])
		return
	if riding_mount != 0:
		ride_refused_action.emit()
		return
	# Round 873: a ground point goes out at the wire's height (round 870's
	# wire_y), as a walk's destination does; the server clamps the move in 3-D
	# from the region-local height it holds.
	var wire_point := Vector3(point.x, wire_y(point.y), point.z) if target_type == SkillNet.TARGET_GROUND else point
	_send(SkillNet.OP_USE, SkillNet.encode_use(char_name, skill_id, target_monster_id, target_type, wire_point))
	if target_type == SkillNet.TARGET_ENTITY and target_monster_id > 0 and not JobPvpNet.is_cos_uid(target_monster_id):
		own_offensive.emit(target_monster_id)
	if LatencyProbe.on and target_type == SkillNet.TARGET_ENTITY:
		LatencyProbe.attack_send(target_monster_id, Time.get_ticks_msec())
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
## Round 795, the COS requests (CosNet; docs/protocol/pets.md).
## The COS requests' log lines (QA only: OPENSRO_QA_COS_LOG=1).
var _cos_trace: bool = OS.get_environment("OPENSRO_QA_COS_LOG") != ""

func send_cos_command_move(uid: int, movement: PackedByteArray) -> void:
	_send(CosNet.OP_COMMAND, CosNet.encode_command_move(uid, movement))

func send_cos_attack(uid: int, target: int) -> void:
	if _cos_trace:
		print("COS send: 0x70C5 attack %d -> monster %d" % [uid, target])
	_send(CosNet.OP_COMMAND, CosNet.encode_command_target(uid, CosNet.COMMAND_ATTACK, target))

func send_cos_pick(uid: int, item: int) -> void:
	if _cos_trace:
		print("COS send: 0x70C5 pick %d -> ground item %d" % [uid, item])
	_send(CosNet.OP_COMMAND, CosNet.encode_command_target(uid, CosNet.COMMAND_PICK, item))

func send_cos_follow(uid: int) -> void:
	_send(CosNet.OP_COMMAND, CosNet.encode_command_follow(uid))

func send_cos_ride(mount: bool, uid: int) -> void:
	_send(CosNet.OP_RIDE, CosNet.encode_ride(mount, uid))

func send_cos_terminate(uid: int) -> void:
	_send(CosNet.OP_TERMINATE, CosNet.encode_uid(uid))

func send_cos_unsummon(uid: int) -> void:
	_send(CosNet.OP_UNSUMMON, CosNet.encode_uid(uid))

func send_cos_name(uid: int, name: String) -> void:
	_send(CosNet.OP_NAME, CosNet.encode_name(uid, name))

func send_cos_setting(uid: int, kind: int, value: int) -> void:
	_send(CosNet.OP_SETTING, CosNet.encode_setting(uid, kind, value))

## Round 799, the job guild's requests (JobNet), each naming the NPC.
func send_job_join(npc: int, kind: int) -> void:
	_send(JobNet.OP_JOIN, JobNet.encode_join(npc, kind))

func send_job_withdraw(npc: int) -> void:
	_send(JobNet.OP_WITHDRAW, JobNet.encode_npc(npc))

func send_job_alias(npc: int, op: int, alias: String) -> void:
	_send(JobNet.OP_ALIAS, JobNet.encode_alias(npc, op, alias))

func send_job_ranking(npc: int, kind: int, type: int) -> void:
	_send(JobNet.OP_RANKING, JobNet.encode_ranking(npc, kind, type))

func send_job_reward(npc: int, op: int) -> void:
	_send(JobNet.OP_REWARD, JobNet.encode_reward(npc, op))

func send_job_prev(npc: int) -> void:
	_send(JobNet.OP_PREV_JOB, JobNet.encode_npc(npc))

## The job replies into this character's job fields, as the original's
## handlers set the player object.
func _on_job_packet(op: int, data: PackedByteArray) -> void:
	match op:
		JobNet.OP_JOB_INFO:
			var d := JobNet.decode_job_info(data)
			job_alias = String(d["alias"])
			job_kind = int(d["kind"])
			job_level = int(d["level"])
			job_exp = int(d["exp"])
			job_contribution = int(d["contribution"])
			job_reward = int(d["reward"])
			job_changed.emit()
		JobNet.OP_JOB_EXP:
			var d := JobNet.decode_job_exp(data)
			var old_level := job_level
			var old_exp := job_exp
			job_level = int(d["level"])
			job_exp = int(d["exp"])
			job_exp_changed.emit(d, old_level, old_exp)
			job_changed.emit()
		JobNet.OP_JOIN_RESULT:
			var d := JobNet.decode_join(data)
			if d["ok"]:
				# JobGuild_OnJoinResult: kind (0x9db0b0), level and exp (0x9d4cd0).
				job_kind = int(d["kind"])
				job_level = int(d["level"])
				job_exp = int(d["exp"])
				job_changed.emit()
			job_reply.emit(op, d)
		JobNet.OP_WITHDRAW_RESULT:
			var d := JobNet.decode_plain(data)
			if d["ok"]:
				# JobGuild_OnWithdrawResult: kind 0, level and exp 0, the alias "".
				job_kind = 0
				job_level = 0
				job_exp = 0
				job_alias = ""
				job_changed.emit()
			job_reply.emit(op, d)
		JobNet.OP_ALIAS_RESULT:
			var d := JobNet.decode_alias(data)
			# Op 1's success sets the alias (UI_ALIAS::FUN_00889370); the
			# reply's "was it empty" decides create or modify, so it is kept.
			d["was_empty"] = job_alias == ""
			if d["ok"] and int(d["op"]) == 1:
				job_alias = String(d["alias"])
				job_changed.emit()
			job_reply.emit(op, d)
		JobNet.OP_RANKING_RESULT:
			job_reply.emit(op, JobNet.decode_ranking(data))
		JobNet.OP_REWARD_RESULT:
			var d := JobNet.decode_reward(data)
			if d["ok"] and int(d["op"]) == 1:
				job_reward = int(d["gold"]) # +0x20bc takes the amount paid (READ c:0x8831a6)
				job_changed.emit()
			job_reply.emit(op, d)
		JobNet.OP_PREV_JOB_RESULT:
			job_reply.emit(op, JobNet.decode_prev_job(data))

## Round 801: a good bought into the transport (0x7034 type 0x13).
func send_specialty_buy(cos: int, tab: int, slot: int, count: int, npc: int) -> void:
	_item_op_kinds.append("trade")
	_send(ItemOpNet.OP_MOVE, SpecialtyNet.encode_buy(cos, tab, slot, count, npc))

## Round 801: goods sold from the transport (0x7034 type 0x14).
func send_specialty_sell(cos: int, slot: int, count: int, npc: int) -> void:
	_item_op_kinds.append("trade")
	_send(ItemOpNet.OP_MOVE, SpecialtyNet.encode_sell(cos, slot, count, npc))

## Round 801: the trade-info window's Refresh (0x74D4).
func send_trade_info(npc_ref: int) -> void:
	_send(SpecialtyNet.OP_INFO, SpecialtyNet.encode_info(npc_ref))

func send_cos_bag_move(t: int, uid: int, src: int, dst: int, count: int = 1) -> void:
	_item_op_kinds.append("cos")
	_send(ItemOpNet.OP_MOVE, CosNet.encode_bag_move(t, uid, src, dst, count))

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
	# The quest messages (round 785).
	quest.send = func(op: int, payload: PackedByteArray) -> void: _send(op, payload)
	quest.register_with(self)
	guild_data.register_with(self)
	for op in GuildOpsNet.RESULT_OPCODES:
		register_handler(op, func(data: PackedByteArray) -> void: guild_ops.handle(op, data))
	# Round 844: the guild storage (0xB250..0xB252, 0x3253..0x3255).
	guild_storage.send = func(op: int, payload: PackedByteArray) -> void: _send(op, payload)
	guild_storage.register_with(self)
	# Round 844: the notice, level-up, hand-over, permission and donation
	# replies.
	for op in GuildPart2Net.SERVER_OPCODES:
		register_handler(op, func(data: PackedByteArray) -> void: guild_part2.handle(op, data))
	# The block's vote tail follows each parse; a vote ended clears it.
	guild_data.changed.connect(func() -> void: guild_part2.set_from_block(guild_data.votes))
	# Round 860 (READ c:0x99ac71): a hostile list with any war puts this
	# player's own guild in the "at war" set.
	guild_data.hostile.changed.connect(func() -> void:
		if guild_data.in_guild and guild_data.guild_id != 0 and guild_data.hostile.count() > 0:
			note_war_flag(guild_data.guild_id, 0))
	guild_part2.vote_changed.connect(func() -> void:
		if guild_part2.vote_id == 0:
			guild_data.votes = [])
	for op in GuildManageNet.RESULT_OPCODES:
		register_handler(op, func(data: PackedByteArray) -> void:
			var r := GuildManageNet.decode_result(op, data)
			if r != null:
				guild_manage_result.emit(r))
	# Round 844 (lane V): the war requests' replies (c:0x881ec0, 0x881f30,
	# 0x881f80, 0x885ae0).
	for op in GuildWarNet.RESULT_OPCODES:
		register_handler(op, func(data: PackedByteArray) -> void:
			guild_war_result.emit(op, GuildWarNet.decode_result(op, data)))
	# B0F0's success carries the guild block (c:0x8852c0 -> FUN_009965e0).
	guild_ops.created.connect(func(block: PackedByteArray) -> void:
		if guild_data.parse(block):
			guild_data.changed.emit())
	# Round 824: the crests -- 0x3257 (also the own guild's revision, when
	# the name is the own guild's: c:0x895810), and the bytes asked for.
	crest_cache.send = func(op: int, payload: PackedByteArray) -> void: _send(op, payload)
	register_handler(CrestNet.OP_CREST_UPDATE, func(data: PackedByteArray) -> void:
		var u := crest_cache.handle_update(data)
		if u != null and u.kind == CrestNet.KIND_GUILD and guild_data.in_guild and u.guild_names[0] == guild_data.guild_name:
			guild_data.crest_rev = u.rev
			guild_data.changed.emit()
		# Round 844: the own union's (c:0x895a3b, the id against +0x248).
		if u != null and u.kind == CrestNet.KIND_UNION and guild_data.union.union_id == u.id and u.id != 0:
			guild_data.union.crest_rev = u.rev)
	register_handler(CrestNet.OP_CREST_DATA, func(data: PackedByteArray) -> void: crest_cache.handle_data(data))
	# Round 838 (OURS): the service scrolls' lines, plate colours and rename.
	service.send = func(op: int, payload: PackedByteArray) -> void: _send(op, payload)
	service.register_with(self)
	# Round 838: 0x30DF and the custom title's text.
	titles.register_with(self)
	guild_data.changed.connect(func() -> void:
		if guild_data.in_guild:
			crest_cache.note_guild(guild_data.guild_name, guild_data.guild_id, guild_data.crest_rev))
	guild_ops.player_name = func(uid: int) -> String:
		return String((user_guilds.get(uid, {}) as Dictionary).get("name", "")) if user_roster.has(uid) else ""
	guild_ops.player_guild = func(uid: int) -> String:
		return String((user_guilds.get(uid, {}) as Dictionary).get("guild_name", "")) if user_roster.has(uid) else ""
	# Round 844: the union's requests and replies (UnionOps).
	union_ops.send = func(op: int, payload: PackedByteArray) -> void: _send(op, payload)
	union_ops.player_name = guild_ops.player_name
	union_ops.player_guild = guild_ops.player_guild
	union_ops.register_with(self)
	# Round 865: the academy's replies and pushes (AcademyState).
	for op in AcademyNet.SERVER_OPCODES:
		register_handler(op, func(data: PackedByteArray) -> void: academy.handle(op, data))
	academy.own_name = func() -> String: return current_character_name
	# The game clock (round 786, GameClock): 0x3020 at world entry, 0x3027
	# when an operator sets the hour.
	for op in [GameClock.OP_POSITION, GameClock.OP_UPDATE]:
		register_handler(op, func(data: PackedByteArray) -> void: game_clock.handle(op, data, Time.get_ticks_msec()))

## Round 844: a guild storage move (0x7034 types 0x1d..0x21, GuildStorageNet's
## payload); its 0xB034 comes back to guild_storage.
func guild_storage_move(payload: PackedByteArray) -> void:
	_item_op_kinds.append("guild_storage")
	_send(ItemOpNet.OP_MOVE, payload)

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

## Round 822: the original's guild requests (GuildOpsNet; c:0x81f5a0,
## 0x81f710, 0x81f7d0, 0x81fb70, 0x824190).
func guild_found(npc_uid: int, guild_name: String) -> void:
	_send(GuildOpsNet.OP_CREATE, GuildOpsNet.encode_create(npc_uid, guild_name))

func guild_disband(npc_uid: int) -> void:
	_send(GuildOpsNet.OP_DISBAND, GuildOpsNet.encode_npc(npc_uid))

func guild_secede(npc_uid: int) -> void:
	_send(GuildOpsNet.OP_LEAVE, GuildOpsNet.encode_npc(npc_uid))

## The sender sets GInterface+0x509 before it sends (c:0x81fc2c).
func guild_invite(target_uid: int) -> void:
	guild_ops.invite_lock = true
	_send(GuildOpsNet.OP_INVITE, GuildOpsNet.encode_invite(target_uid))

## Round 844: one of GuildManageNet's requests (its encoders build the
## payload).
func guild_manage(op: int, payload: PackedByteArray) -> void:
	_send(op, payload)

func guild_expel(member_name: String) -> void:
	_send(GuildOpsNet.OP_EXPEL, GuildOpsNet.encode_expel(member_name))

## Round 844 (lane V): guild war's requests (GuildWarNet).
func guild_war_declare(target_guild: String, period: int, point_index: int, gold: int) -> void:
	_send(GuildWarNet.OP_DECLARE, GuildWarNet.encode_declare(target_guild, period, point_index, gold))

func guild_war_answer(accept: bool) -> void:
	_send(GuildWarNet.OP_REQUEST, GuildWarNet.encode_answer(accept))

func guild_war_end(war_id: int) -> void:
	_send(GuildWarNet.OP_END, GuildWarNet.encode_u32(war_id))

func guild_war_ask_reward(npc_uid: int) -> void:
	_send(GuildWarNet.OP_ASK_REWARD, GuildWarNet.encode_u32(npc_uid))

func guild_war_claim(npc_uid: int) -> void:
	_send(GuildWarNet.OP_CLAIM, GuildWarNet.encode_u32(npc_uid))

## Round 865: one academy request (AcademyNet's encoders build the payload;
## the senders c:0x821e40..0x825100). Kept in academy_sent and logged, so a
## QA run shows the bytes a click produced.
func academy_send(op: int, payload: PackedByteArray = PackedByteArray()) -> void:
	academy_sent.append([op, payload])
	if academy_sent.size() > 64:
		academy_sent = academy_sent.slice(academy_sent.size() - 64)
	print("ACADEMY SEND 0x%04X %s" % [op, payload.hex_encode()])
	if op == AcademyNet.OP_INVITE:
		# GInterface+0x509 (c:0x777bd0(1) before the send).
		academy.invite_pending = true
	if is_connected_to_server():
		_send(op, payload)

## The academy invitation box's answer; nothing when no box is open.
func academy_answer(accept: bool) -> void:
	var payload := academy.answer(accept)
	if not payload.is_empty():
		academy_send(AcademyNet.OP_REQUEST, payload)

## Round 865 (QA): a message through the real decode path, as if the server
## had sent it (OPENSRO_QA_INPUT `acapkt:`; the suites).
func qa_receive(op: int, data: PackedByteArray) -> void:
	_dispatch(Packet.new(op, data))

## Box 0x0F's answer; nothing when no invitation is open.
func guild_answer(accept: bool) -> void:
	var payload := guild_ops.answer(accept)
	if not payload.is_empty():
		_send(GuildOpsNet.OP_REQUEST, payload)

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

## The alchemy window's start (AlchemyNet, round 768): `op` and the bag
## indices, target first. The reply is alchemy_result, 3-4 s later.
func alchemy_start(op: int, bag_slots: Array) -> void:
	_send(AlchemyNet.OP_REQUEST, AlchemyNet.encode_start(op, bag_slots))

## The alchemy window's cancel, while an attempt waits.
func alchemy_cancel() -> void:
	_send(AlchemyNet.OP_REQUEST, AlchemyNet.encode_cancel())

## Asks to make the gate the player is talking to (a teleportdata id) its
## return point (RecallNet.OP_DESIGNATE, round 686). The reply is
## recall_designate_result.
func recall_designate(gate_id: int) -> void:
	_send(RecallNet.OP_DESIGNATE, RecallNet.encode_designate(gate_id))


func duel_challenge(char_name: String, target_name: String) -> void:
	_send(DuelNet.OP_CHALLENGE, DuelNet.encode_challenge(char_name, target_name))

func duel_respond(char_name: String, challenger_name: String, accept: bool) -> void:
	_send(DuelNet.OP_RESPOND, DuelNet.encode_respond(char_name, challenger_name, accept))

func duel_attack(char_name: String) -> void:
	# Round 786: no attack on a player in the protection (READ, 0x791fda).
	if ArrivalGuard.refuses_attack_on_player(own_body_mode):
		print("DUEL attack refused locally: untouchable (body mode 2)")
		untouchable_refused.emit("duel")
		return
	_send(DuelNet.OP_ATTACK, DuelNet.encode_attack(char_name))

## Round 786: the loading-done report, 0x3012 (ArrivalGuard.ReadyReport).
func report_ready_to_play() -> void:
	if not is_connected_to_server():
		return
	_send(WorldNet.OP_READY_TO_PLAY)
	print("NetClient: ready to play sent (0x3012)")

## Round 839: the stalls' requests (StallNet).
func stall_open(title: String) -> void:
	_send(StallNet.OP_OPEN, StallNet.encode_open(title))

func stall_close() -> void:
	_send(StallNet.OP_CLOSE)

func stall_enter(owner: int) -> void:
	_send(StallNet.OP_ENTER, StallNet.encode_enter(owner))

func stall_buy(slot: int) -> void:
	_send(StallNet.OP_BUY, StallNet.encode_buy(slot))

func stall_leave() -> void:
	_send(StallNet.OP_LEAVE)

## 0x7160: a BFI1 decoration for the stall about to open (the avatar
## stall's Yes).
func stall_avatar(key: int, decoration: int) -> void:
	_send(StallNet.OP_AVATAR_STALL, StallNet.encode_avatar_stall(key, decoration))

## 0x70BA with one of StallNet's encode_* bodies.
func stall_update(body: PackedByteArray) -> void:
	_send(StallNet.OP_UPDATE, body)

## Round 840: the stall network's requests (StallNetworkNet). The page a
## search asked for is kept for its answer's Number column.
var stall_net_page := 0

func stall_net_search(mode: int, page: int, group: int, degree: int) -> void:
	stall_net_page = page
	_send(StallNetworkNet.OP_SEARCH, StallNetworkNet.encode_search(mode, page, group, degree))

func stall_net_leave() -> void:
	_send(StallNetworkNet.OP_LEAVE)

func stall_net_buy(r: StallNetworkNet.Record) -> void:
	_send(StallNetworkNet.OP_BUY, StallNetworkNet.encode_buy(r))

## Round 834: the exchange's requests (ExchangeNet).
func exchange_request(target_id: int) -> void:
	_send(ExchangeNet.OP_REQUEST, ExchangeNet.encode_request(target_id))

func exchange_answer(accept: bool) -> void:
	_send(PartyNet.OP_REQUEST, ExchangeNet.encode_answer(accept))

## The bag index (0-based) offered: 0x7034 type 4.
func exchange_add(bag_index: int) -> void:
	_send(ExchangeNet.OP_ITEM_MOVE, ExchangeNet.encode_add(bag_index))
	_item_op_kinds.append("exchange")

func exchange_remove(index: int) -> void:
	_send(ExchangeNet.OP_ITEM_MOVE, ExchangeNet.encode_remove(index))
	_item_op_kinds.append("exchange")

func exchange_gold(gold: int) -> void:
	_send(ExchangeNet.OP_ITEM_MOVE, ExchangeNet.encode_gold(gold))
	_item_op_kinds.append("exchange")

func exchange_confirm() -> void:
	_send(ExchangeNet.OP_CONFIRM)

func exchange_approve() -> void:
	_send(ExchangeNet.OP_APPROVE)

func exchange_cancel() -> void:
	_send(ExchangeNet.OP_CANCEL)

## Round 837: the item mall's requests (MallNet).
func mall_open(group: int) -> void:
	_send(MallNet.OP_OPEN, MallNet.encode_open(group))

func mall_buy(b: MallNet.Buy) -> void:
	_send(MallNet.OP_ITEM_MOVE, MallNet.encode_buy(b))
	_item_op_kinds.append("mall")

func mall_history_request(kind: int, period: int) -> void:
	_send(MallNet.OP_HISTORY, MallNet.encode_history(kind, period))

func chest_list_request() -> void:
	_send(MallNet.OP_CHEST_LIST)

func chest_take(entry: int) -> void:
	_send(MallNet.OP_CHEST_TAKE, MallNet.encode_chest_take(entry))

func chest_log_request() -> void:
	_send(MallNet.OP_CHEST_LOG)

## Round 838: Magic POP's draw (0x7118) with the card in `bag_slot`, and
## Gori's exchange (0x7119).
func gacha_play(npc_uid: int, gacha_id: int, bag_slot: int) -> void:
	_send(GachaNet.OP_PLAY, GachaNet.encode_play(npc_uid, gacha_id, bag_slot))

func gacha_exchange(npc_uid: int) -> void:
	_send(GachaNet.OP_EXCHANGE, GachaNet.encode_exchange(npc_uid))

## Round 834: ask a player by name (0x7302; the Add box, the target menu,
## /friend and /invite).
func friend_ask(target_name: String) -> void:
	_send(FriendNet.OP_ASK, FriendNet.encode_ask(target_name))

## The request box's answer (0x3303).
func friend_answer(job: int, asker_jid: int, accept: bool) -> void:
	_send(FriendNet.OP_ANSWER, FriendNet.encode_answer(job, asker_jid, accept))

## Delete a friend (0x7304).
func friend_delete(character_id: int) -> void:
	_send(FriendNet.OP_DELETE, FriendNet.encode_delete(character_id))

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
func set_spawn_item_rows(rows: Dictionary, cos_kind: Callable = Callable(), structure_kinds: Dictionary = {}) -> void:
	if not structure_kinds.is_empty():
		_structure_kinds = structure_kinds
	_spawn_types = UserSpawnNet.Types.new(rows, cos_kind, _structure_kinds)
	_cos_kind = cos_kind
	var waiting := _pending_spawns
	_pending_spawns = []
	_replaying = true
	for m in waiting:
		_rx_msec = int(m.get("rx", Time.get_ticks_msec()))
		_apply_spawn_message(int(m["op"]), m["data"])
	_replaying = false

## Round 795: the COS table's TypeID4 by RefObjID (World3D's CosTable).
var _cos_kind: Callable

func cos_kind_of(ref_id: int) -> int:
	return int(_cos_kind.call(ref_id)) if _cos_kind.is_valid() else 0

## A world entry or zone change: the players in view start over, and their
## records' coordinates are in frame (the result's FrameRegion).
func _start_user_view(frame: String) -> void:
	user_roster.clear()
	user_guilds.clear()
	cos_roster.clear()
	_pending_spawns.clear()
	_group_job = null
	_zone_arrivals.clear()
	zone_departures.clear()
	character_states.clear()
	_spawn_frame = UserSpawnNet.parse_frame(frame)
	_spawn_dungeon = DungeonWorld.rid_of_zone(frame)

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
## `anchor` (round 870): the frame's wire_height_anchor, taken off the heights.
static func resolve_echo(echo: DestMoveNet.Echo, frame: Vector2i, anchor: float = 0.0) -> void:
	if echo.kind == DestMoveNet.KIND_DESTINATION:
		var d := DestMoveNet.world_of_local(echo.region, float(echo.local.x), float(echo.local.z), frame)
		echo.dest_world = Vector3(d.x, float(echo.local.y) - anchor, d.y)
	if echo.has_source:
		var s := DestMoveNet.world_of_local(echo.source_region, echo.source_local.x, echo.source_local.z, frame)
		echo.source_world = Vector3(s.x, echo.source_local.y - anchor, s.y)

## A spawn message that may name a player: read now, or queued behind any
## that wait for the item table.
func _user_spawn_message(op: int, data: PackedByteArray) -> void:
	if not _pending_spawns.is_empty():
		_pending_spawns.append({"op": op, "data": data, "rx": _rx_msec})
		return
	_apply_spawn_message(op, data)

func _apply_spawn_message(op: int, data: PackedByteArray) -> void:
	match op:
		DestMoveNet.OP_MOVEMENT_ECHO:
			var echo := DestMoveNet.decode_echo(data)
			if echo.error != "":
				push_warning("NetClient: a 0xB021 that does not read (%s)" % echo.error)
				return
			resolve_echo(echo, _spawn_frame, wire_y(0.0))
			entity_move_echo.emit(echo)
		DestMoveNet.OP_MOVEMENT_STOP:
			var stop := DestMoveNet.decode_stop(data)
			if stop.error != "":
				push_warning("NetClient: a 0xB023 that does not read (%s)" % stop.error)
				return
			var at := DestMoveNet.world_of_local(stop.region, stop.local.x, stop.local.z, _spawn_frame)
			stop.world = Vector3(at.x, scene_y(stop.local.y), at.y)
			entity_move_stop.emit(stop)
		DestMoveNet.OP_MOVEMENT_TURN:
			# Round 808: a body's new heading, in order with its moves.
			var turn := DestMoveNet.decode_turn(data)
			if int(turn["uid"]) >= 0:
				entity_turned.emit(int(turn["uid"]), int(turn["angle"]))
		NpcSpawnNet.OP_SINGLE_SPAWN:
			if _spawn_types == null:
				_pending_spawns.append({"op": op, "data": data, "rx": _rx_msec})
				return
			if data.size() >= 4 and not UserSpawnNet.is_player_ref(data.decode_u32(0)):
				# Round 869: a structure (StructureSpawnNet).
				var sk := _spawn_types.structure_kind_of(data.decode_u32(0))
				if sk != StructureSpawnNet.KIND_NONE:
					var st := StructureSpawnNet.decode_single_spawn(data, sk)
					if st == null:
						push_warning("NetClient: a 0x3015 that does not read as a structure record (%d bytes)" % data.size())
					else:
						structure_spawned.emit(structure_roster.spawn(st))
					return
				var k := _spawn_types.cos_kind_of(data.decode_u32(0))
				if k != 0:
					var c := CosSpawnNet.decode_single_spawn(data, k)
					if c == null:
						push_warning("NetClient: a 0x3015 that does not read as a COS record (%d bytes)" % data.size())
					else:
						_cos_spawned(c)
				else:
					var single := NpcSpawnNet.decode_single_spawn(data)
					if single != null:
						npc_spawned.emit(npc_roster.spawn(single))
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
			if structure_roster.despawn(gone):
				structure_despawned.emit(gone)
			elif cos_roster.has(gone):
				_cos_despawned(gone)
			elif user_roster.has(gone):
				if _spawn_log:
					print("NetClient: 0x3016 player %d went out of view" % gone)
				_user_left(gone)
			elif gone >= 0 and npc_roster.despawn(gone):
				npc_despawned.emit(gone)
		NpcSpawnNet.OP_GROUP_END:
			group_serial += 1
			group_rx_msec = _rx_msec if _rx_msec > 0 else Time.get_ticks_msec()
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
				_pending_spawns.append({"op": op, "data": data, "rx": _rx_msec})
				return
			if g.error != "":
				push_warning("NetClient: a group spawn that does not read (%s) -- dropped" % g.error)
			elif g.kind == NpcSpawnNet.GROUP_SPAWN:
				if not g.users.is_empty():
					print("NetClient: group spawn of %d player(s)%s" % [g.users.size(),
						(" and %d NPC(s)" % g.npcs.size()) if not g.npcs.is_empty() else ""])
				for rec in g.npcs:
					npc_spawned.emit(npc_roster.spawn(rec))
				for c in g.cos:
					_cos_spawned(c)
				for st in g.structures:
					structure_spawned.emit(structure_roster.spawn(st))
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
					if structure_roster.despawn(u):
						structure_despawned.emit(u)
					elif cos_roster.has(u):
						_cos_despawned(u)
					elif user_roster.has(u):
						_user_left(u)
					elif npc_roster.despawn(u):
						npc_despawned.emit(u)

## Round 762: whether a group spawn or despawn is still being read.
func group_reading() -> bool:
	return _group_job != null or _held_groups > 0

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
	# Round 762: the share the frame's crowd budget leaves (OtherCrowd.FrameBudget),
	# GROUP_STEP_USEC at most.
	var step := mini(GROUP_STEP_USEC, OtherCrowd.FrameBudget.group_step_usec())
	while int(job["i"]) < count:
		if int(job["i"]) > first and Time.get_ticks_usec() - t0 >= step:
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
		elif _spawn_types != null and _spawn_types.structure_kind_of(UserSpawnNet.peek_ref(r)) != 0:
			# Round 869: a structure (StructureSpawnNet).
			var st := StructureSpawnNet.read_record(r, _spawn_types.structure_kind_of(UserSpawnNet.peek_ref(r)))
			if st == null:
				push_warning("NetClient: a group spawn that does not read (record %d of %d: %s) -- the rest dropped" % [int(job["i"]), count, r.error])
				job["i"] = count
				break
			structure_spawned.emit(structure_roster.spawn(st))
		elif _spawn_types != null and _spawn_types.cos_kind_of(UserSpawnNet.peek_ref(r)) != 0:
			# Round 795: a COS (CICCos, cos_spawn.gd).
			var c := CosSpawnNet.read_record(r, _spawn_types.cos_kind_of(UserSpawnNet.peek_ref(r)))
			if c == null:
				push_warning("NetClient: a group spawn that does not read (record %d of %d: %s) -- the rest dropped" % [int(job["i"]), count, r.error])
				job["i"] = count
				break
			_cos_spawned(c)
		else:
			var npc := NpcSpawnNet.read_record(r)
			if npc == null:
				push_warning("NetClient: a group spawn that does not read (record %d of %d: %s) -- the rest dropped" % [int(job["i"]), count, r.error])
				job["i"] = count
				break
			npc_spawned.emit(npc_roster.spawn(npc))
			job["npcs"] = int(job["npcs"]) + 1
		job["i"] = int(job["i"]) + 1
	OtherCrowd.FrameBudget.spend(Time.get_ticks_usec() - t0)
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
	var step := mini(GROUP_STEP_USEC, OtherCrowd.FrameBudget.group_step_usec())
	while int(job["i"]) < uids.size():
		if int(job["i"]) > first and Time.get_ticks_usec() - t0 >= step:
			break
		var u: int = uids[int(job["i"])]
		job["i"] = int(job["i"]) + 1
		if structure_roster.despawn(u):
			structure_despawned.emit(u)
		elif cos_roster.has(u):
			_cos_despawned(u)
		elif user_roster.has(u):
			job["users"] = int(job["users"]) + 1
			_user_left(u)
		elif npc_roster.despawn(u):
			npc_despawned.emit(u)
	OtherCrowd.FrameBudget.spend(Time.get_ticks_usec() - t0)
	if int(job["i"]) < uids.size():
		return false
	_group_job = null
	if int(job["users"]) > 0:
		print("NetClient: group despawn of %d player(s)%s" % [int(job["users"]),
			(" at %d ms, over %d frame(s)" % [Time.get_ticks_msec(), int(job["frames"])]) if FrameSplit.on else ""])
	return true

## Round 795: a COS came into view (or was spawned again: a summon, a level
## row's change, a death).
func _cos_spawned(rec: CosSpawnNet.Record) -> void:
	cos_roster[rec.uid] = rec
	cos_spawned.emit(rec)

func _cos_despawned(uid: int) -> void:
	cos_roster.erase(uid)
	cos_despawned.emit(uid)

## A player came into view: World3D's snapshot of it, its body mode kept for
## its body (_berserk_resync), and its sitting.
func _user_spawned(rec: UserSpawnNet.Record) -> void:
	var snap := UserSpawnNet.to_snapshot(rec, _spawn_types, _spawn_frame)
	# Round 870: the record's heights are the wire's (region-local).
	snap.y = scene_y(snap.y)
	if snap.has_dest:
		snap.dest.y = scene_y(snap.dest.y)
	user_roster[rec.uid] = true
	# Round 800: its job as the record carries it (the client's +0x50d job
	# state, +0x7be / +0x7bf, +0x50e): the plate, the target window.
	user_jobs[rec.uid] = {"state": rec.job_state, "kind": rec.job_kind, "level": rec.job_level,
		"trade_rank": rec.trade_rank}
	# Round 814: its guild line as the record carries it.
	user_guilds[rec.uid] = {"guild_id": rec.guild_id, "guild_name": rec.guild_name, "nickname": rec.nickname, "name": rec.name,
		"crest_rev": rec.crest_rev, "union_id": rec.union_id}
	note_war_flag(rec.guild_id, rec.guild_war_flag)
	# Round 838: its title as the record carries it (slot 27 -> FUN_009ca930).
	titles.note_level(rec.uid, rec.hwan_level, false)
	crest_cache.note_guild(rec.guild_name, rec.guild_id, rec.crest_rev)
	crest_cache.note_union(rec.guild_name, rec.union_id, rec.union_crest_rev)
	# Round 839: a stalling owner (+0x471 == 4): its stall as 0x30B8 would
	# have told it (c:0x9ca3d9 spawns it at its booth).
	if rec.interact == 4:
		stalls[rec.uid] = {"owner": rec.uid, "name": rec.stall_name, "decoration": rec.stall_decoration}
	else:
		stalls.erase(rec.uid)
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
## Round 814: 0x30FF -- one character's guild line, this player's own or a
## player's in view.
func _guild_line_update(d: Dictionary) -> void:
	if d.is_empty():
		return
	var uid := int(d["uid"])
	var line := {"guild_id": int(d["guild_id"]), "guild_name": String(d["guild_name"]), "nickname": String(d["nickname"]),
		"crest_rev": int(d.get("crest_rev", 0)), "union_id": int(d.get("union_id", 0))}
	crest_cache.note_guild(String(d["guild_name"]), int(d["guild_id"]), int(d.get("crest_rev", 0)))
	crest_cache.note_union(String(d["guild_name"]), int(d.get("union_id", 0)), int(d.get("union_crest_rev", 0)))
	note_war_flag(int(d["guild_id"]), int(d.get("war_flag", -1)))
	if own_character_id >= 0 and uid == (own_character_id & 0xffffffff):
		own_guild_line = line
	elif user_roster.has(uid):
		line["name"] = String((user_guilds.get(uid, {}) as Dictionary).get("name", ""))
		user_guilds[uid] = line
	else:
		return
	guild_line_changed.emit(uid)

## Round 814: 0x3256 -- a guild member's grant name, by the member's name
## (READ FUN_008905d0: the character found by name gets the nickname).
func _guild_nickname_update(d: Dictionary) -> void:
	if d.is_empty():
		return
	var who := String(d["name"])
	if who == current_character_name and not own_guild_line.is_empty():
		own_guild_line["nickname"] = String(d["nickname"])
		if own_character_id >= 0:
			guild_line_changed.emit(own_character_id & 0xffffffff)
		return
	for uid in user_guilds:
		var g: Dictionary = user_guilds[uid]
		if String(g.get("name", "")) == who:
			g["nickname"] = String(d["nickname"])
			guild_line_changed.emit(int(uid))

## Round 814: the own grant name (0x7256, the target this player's own id --
## OURS: a member names only themselves).
func send_guild_grant_name(nickname: String) -> void:
	if own_character_id < 0:
		return
	_send(GuildPlateNet.OP_GRANT_NAME, GuildPlateNet.encode_grant(own_character_id, nickname))

func _user_left(uid: int) -> void:
	user_roster.erase(uid)
	stalls.erase(uid)
	user_jobs.erase(uid)
	user_guilds.erase(uid)
	titles.forget(uid)
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
	_rx_msec = p.rx_msec if p.rx_msec > 0 else Time.get_ticks_msec()
	if wire_logging:
		print("WIRE recv opcode=0x%04x size=%d" % [p.opcode, p.data.size()])
	match p.opcode:
		Auth.OP_LOGIN_RESULT:
			var r := Auth.decode_result(p.data)
			login_result.emit(r.ok, r.reason if r.error == "" else r.error)
		Auth.OP_REGISTER_RESULT:
			var r := Auth.decode_result(p.data)
			register_result.emit(r.ok, r.reason if r.error == "" else r.error)
		LoginAckNet.OP_GATEWAY_LOGIN_ACK:
			gateway_login_result.emit(LoginAckNet.decode_ack(p.data))
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
			# Round 801: a new entry starts with no scale and no prices told.
			trade_scale = 0
			trade_prices_now.clear()
			if result.ok:
				current_zone = result.zone
				# The zone's buffs follow this result (round 646): the roster
				# starts over from them.
				buff_roster.clear()
				body_modes.clear()
				own_body_mode = 0
				# So does the NPC window: the server forgets what it sent this
				# session at the entry (session.forgetNPCWindow) and spawns
				# the whole window again.
				npc_roster.clear()
				structure_roster.clear()
				# And the players in view (round 737): they follow as spawns.
				_start_user_view(result.frame)
			enter_world_result.emit(result)
		WorldNet.OP_ENTITY_ENTERED:
			var entered = WorldNet.decode_entity_entered(p.data)
			# Round 870: its height is the wire's (region-local).
			if entered != null:
				entered.y = scene_y(entered.y)
			entity_entered.emit(entered)
		WorldNet.OP_ENTITY_MOVED:
			var moved = WorldNet.decode_entity_moved(p.data)
			if moved != null:
				moved.y = scene_y(moved.y)
			entity_moved.emit(moved)
		WorldNet.OP_ENTITY_LEFT:
			var left_id := WorldNet.decode_entity_left(p.data)
			# Its buffs went with its body (round 646, BuffRoster.drop), and
			# its body mode (round 651).
			buff_roster.drop(BuffRoster.key_of(left_id, SkillNet.OWNER_CHARACTER))
			body_modes.erase(left_id)
			entity_left.emit(left_id)
		WorldNet.OP_CHANGE_ZONE_RESULT:
			var zone_result := WorldNet.decode_change_zone_result(p.data)
			var retry := _zone_spot_retry
			_zone_spot_retry = ""
			if retry != "" and not zone_result.ok and zone_result.reason == "malformed request":
				_send(WorldNet.OP_CHANGE_ZONE, WorldNet.encode_change_zone(retry))
				return
			if zone_result.ok:
				current_zone = zone_result.zone
				# The new zone's buffs, this player's own included, follow
				# this result (round 646; sendBuffsInView).
				buff_roster.clear()
				body_modes.clear()
				own_body_mode = 0
				# And its players, as spawns (round 737).
				_start_user_view(zone_result.frame)
			change_zone_result.emit(zone_result)
		WorldNet.OP_REVIVE_RESULT:
			revive_result.emit(WorldNet.decode_revive_result(p.data))
		WorldNet.OP_STATE_CHANGE:
			var change := WorldNet.decode_state_change(p.data)
			if change != null:
				WorldNet.note_body_mode(body_modes, change)
				if change.kind == WorldNet.STATE_KIND_BODY_MODE and own_character_id >= 0 \
						and change.object_id == own_character_id:
					own_body_mode = change.value
				state_changed.emit(change)
		WorldNet.OP_EMOTE:
			var em := WorldNet.decode_emote(p.data)
			if not em.is_empty():
				emote_received.emit(int(em[0]), int(em[1]))
		ActionNet.OP_ACTION_RESULT:
			var ar := ActionNet.decode_result(p.data)
			if not ar.is_empty():
				action_result.emit(int(ar["result"]), int(ar["depth"]), int(ar["code"]))
		ActionNet.OP_PING_ECHO:
			var token := ActionNet.decode_ping_echo(p.data)
			if token >= 0:
				ping_echo.emit(token)
		UseItemNet.OP_REVERSE_SAVED_RESULT:
			var rs := UseItemNet.decode_reverse_saved(p.data)
			if not rs.is_empty():
				reverse_saved_result.emit(rs)
		UseItemNet.OP_SCROLL_CANCEL_RESULT:
			# READ: FUN_008727a0 shows nothing for a refusal (round 779).
			print("NetClient: scroll cancel refused (code %d)" % UseItemNet.decode_cancel_result(p.data))
		InventoryNet.OP_LIST_RESULT:
			var r := InventoryNet.decode_list_result(p.data)
			last_inventory_durabilities = r.durabilities
			last_inventory_instances = _note_instances("bag", r.instances)
			if r.capacity > 0:
				last_inventory_capacity = r.capacity
			if _qa_bag_list_delay_ms > 0 and Engine.get_main_loop() is SceneTree:
				# QA only (round 830): the bag list a moment after the worn
				# list, as over a real network.
				var slots := r.slots
				var err := r.error
				(Engine.get_main_loop() as SceneTree).create_timer(_qa_bag_list_delay_ms / 1000.0).timeout.connect(
					func() -> void: inventory_list_result.emit(slots, err))
			else:
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
		OP_AMMO_COUNT:
			# Round 838: the slot-7 stack's new count (c:0x6ab830 sets the
			# worn item's count, READ).
			if p.data.size() >= 2:
				var n := p.data.decode_u16(0)
				print("AMMO: slot 7 count %d" % n)
				var worn = last_equipment_instances.get(7)
				if worn != null:
					worn.count = n
					if n == 0:
						last_equipment_instances.erase(7)
				ammo_count.emit(n)
		EquipmentNet.OP_RESULT:
			var r := EquipmentNet.decode_result(p.data)
			last_equipment_durabilities = r.durabilities
			last_equipment_instances = _note_instances("worn", r.instances)
			equipment_result.emit(r.items, r.error)
		EquipmentNet.OP_REPAIR_RESULT:
			var rr := EquipmentNet.decode_repair_result(p.data)
			repair_result.emit(rr.code, rr.gold_spent, rr.durabilities)
		EquipmentNet.OP_DURABILITY_CHANGED:
			# Round 829: {u8 slot, u32 durability} (0x3052, READ 0x8adf50).
			if p.data.size() >= 5:
				var dslot := p.data.decode_u8(0)
				var dval := p.data.decode_s32(1)
				var list: Array = last_equipment_durabilities if dslot < EquipmentNet.BAG_SLOT_BASE else last_inventory_durabilities
				var key := dslot if dslot < EquipmentNet.BAG_SLOT_BASE else dslot - EquipmentNet.BAG_SLOT_BASE
				var was := -1
				for d in list:
					if d != null and int(d.slot) == key:
						was = int(d.current)
						d.current = dval
				durability_changed.emit(dslot, dval, was)
		EquipmentNet.OP_EQUIP_BROADCAST, EquipmentNet.OP_UNEQUIP_BROADCAST:
			var eb := EquipmentNet.decode_broadcast(p.data)
			if eb != null:
				var on := p.opcode == EquipmentNet.OP_EQUIP_BROADCAST
				print("NetClient: %s uid %d slot %d item %d plus %d%s" % ["0x3038" if on else "0x3039", eb.uid, eb.slot, eb.ref_item_id, eb.plus,
					(" own %d" % eb.own_ref) if eb.own_ref != 0 else ""])
				# A 0x3038 with no plus byte (a non-equipment item, which retail's
				# layout allows) is a +0 put on, never a removal (round 735's
				# review, finding 7): only a 0x3039 is -1.
				other_player_equipment_changed.emit(eb.uid, eb.slot, eb.ref_item_id, maxi(eb.plus, 0) if on else -1, eb.own_ref if on else 0)
		ShopNet.OP_BUY_RESULT:
			var r := ShopNet.decode_buy_result(p.data)
			shop_buy_result.emit(r.ok, r.reason if r.error == "" else r.error)
		ShopNet.OP_LIST_RESULT:
			var r := ShopNet.decode_list_result(p.data)
			shop_list_result.emit(r.entries, r.error)
		ShopNet.OP_SELL_RESULT:
			var r := ShopNet.decode_sell_result(p.data)
			shop_sell_result.emit(r.ok, r.reason if r.error == "" else r.error, r.gold_received)
		SpecialtyNet.OP_PRICES:
			var pr := SpecialtyNet.decode_prices(p.data)
			trade_prices_now.merge(pr["prices"], true)
			trade_prices.emit(pr["prices"])
		SpecialtyNet.OP_SCALE:
			if p.data.size() >= 1:
				trade_scale = p.data[0]
				trade_scale_changed.emit(trade_scale)
		SpecialtyNet.OP_LEASH:
			if p.data.size() >= 1:
				trade_leash.emit(p.data[0])
		SpecialtyNet.OP_INFO_RESULT:
			trade_info.emit(SpecialtyNet.decode_info(p.data))
		JobPvpNet.OP_PLAYER_STRUCK:
			var st := JobPvpNet.decode_struck(p.data)
			if not st.is_empty():
				player_struck.emit(st)
		JobPvpNet.OP_SAFE_TRADE:
			var sf := JobPvpNet.decode_safe_trade(p.data)
			if not sf.is_empty():
				safe_trade_last = sf
				safe_trade.emit(sf)
		JobNet.OP_JOB_INFO, JobNet.OP_JOB_EXP, JobNet.OP_JOIN_RESULT, JobNet.OP_WITHDRAW_RESULT, JobNet.OP_ALIAS_RESULT, \
				JobNet.OP_RANKING_RESULT, JobNet.OP_REWARD_RESULT, JobNet.OP_PREV_JOB_RESULT:
			_on_job_packet(p.opcode, p.data)
		JobNet.OP_STRIP_START:
			var st := JobNet.decode_strip_start(p.data)
			if int(st.get("kind", 0)) == 2 and int(st.get("sub", 0)) == 2:
				strip_started.emit(int(st["uid"]), int(st["seconds"]))
		JobNet.OP_STRIP_CANCEL:
			if p.data.size() >= 5:
				strip_cancelled.emit(p.data.decode_u32(0), p.data[4])
		CosNet.OP_DATA:
			var cd := CosNet.decode_data(p.data, Callable(self, "cos_kind_of"))
			if cd.error != "":
				push_warning("NetClient: a 0x30C8 that does not read (%s)" % cd.error)
			else:
				cos_own[cd.uid] = cd
				cos_data.emit(cd)
		CosNet.OP_UPDATE:
			var cu := CosNet.decode_update(p.data)
			if cu.type == CosNet.UPDATE_REMOVED:
				cos_own.erase(cu.uid)
			cos_update.emit(cu)
		CosNet.OP_OWNER_STATE:
			cos_owner_state.emit(CosNet.decode_owner_state(p.data))
		CosNet.OP_LEVEL_UP:
			if p.data.size() >= 4:
				cos_level_up.emit(p.data.decode_u32(0))
		CosNet.OP_ITEM_STATE:
			item_state_changed.emit(CosNet.decode_item_state(p.data))
		CosNet.OP_RIDE_ACK:
			ride_changed.emit(CosNet.decode_ride_ack(p.data))
		CosNet.OP_SPEED:
			speed_changed.emit(CosNet.decode_speed(p.data))
		CosNet.OP_COMMAND_ACK:
			cos_command_result.emit(CosNet.decode_command_ack(p.data))
		CosNet.OP_SETTING_ACK:
			var sa := CosNet.decode_setting_ack(p.data)
			if bool(sa.get("ok", false)) and cos_own.has(int(sa["uid"])):
				(cos_own[int(sa["uid"])] as CosNet.Data).pet_option = int(sa["value"])
			cos_setting_result.emit(sa)
		CosNet.OP_TERMINATE_ACK, CosNet.OP_UNSUMMON_ACK, CosNet.OP_NAME_ACK:
			cos_reply.emit(p.opcode, CosNet.decode_reply(p.data))
		ItemOpNet.OP_MOVE_RESULT:
			# Round 837: a mall buy (type 0x18), and a refusal while one is
			# the oldest move out.
			var mb := MallNet.decode_buy_result(p.data)
			if not mb.is_empty() or (p.data.size() >= 3 and p.data[0] == 2 and not _item_op_kinds.is_empty()
					and _item_op_kinds[0] == "mall"):
				if not _item_op_kinds.is_empty() and _item_op_kinds[0] == "mall":
					_item_op_kinds.pop_front()
				mall_buy_result.emit(mb if not mb.is_empty() else {"ok": false, "code": MallNet.decode_failure(p.data)})
				return
			# Round 844: the guild storage's moves (types 0x1d..0x21), and a
			# refusal while one is the oldest move out.
			if GuildStorageNet.is_move_ack(p.data) or (p.data.size() >= 3 and p.data[0] == 2 and not _item_op_kinds.is_empty()
					and _item_op_kinds[0] == "guild_storage"):
				if not _item_op_kinds.is_empty() and _item_op_kinds[0] == "guild_storage":
					_item_op_kinds.pop_front()
				guild_storage.on_move(GuildStorageNet.decode_move(p.data))
				return
			# Round 834: the exchange's moves (types 4, 5, 0xd), and a refusal
			# while one is the oldest move out.
			var em := ExchangeNet.decode_move_result(p.data)
			if not em.is_empty() or (p.data.size() >= 3 and p.data[0] == 2 and not _item_op_kinds.is_empty()
					and _item_op_kinds[0] == "exchange"):
				if not _item_op_kinds.is_empty() and _item_op_kinds[0] == "exchange":
					_item_op_kinds.pop_front()
				exchange_moved.emit(em if not em.is_empty() else {"code": ExchangeNet.decode_result(p.data)})
				return
			# Round 801: the transport's buy and sale, and a refusal while one
			# is the oldest move out.
			if p.data.size() >= 2 and p.data[0] == 1 and p.data[1] in [SpecialtyNet.TYPE_BUY, SpecialtyNet.TYPE_SELL]:
				if not _item_op_kinds.is_empty():
					_item_op_kinds.pop_front()
				trade_result.emit(SpecialtyNet.decode_result(p.data))
				return
			if p.data.size() >= 1 and p.data[0] == 2 and not _item_op_kinds.is_empty() and _item_op_kinds[0] == "trade":
				_item_op_kinds.pop_front()
				trade_result.emit(SpecialtyNet.decode_result(p.data))
				return
			# Round 795: the pet bag's forms (a pet's own pick comes unasked).
			if p.data.size() >= 2 and p.data[0] == 1 and p.data[1] in [CosNet.BAG_COS_TO_COS, CosNet.BAG_PICK,
					CosNet.BAG_COS_TO_BAG, CosNet.BAG_BAG_TO_COS]:
				if p.data[1] != CosNet.BAG_PICK and not _item_op_kinds.is_empty():
					_item_op_kinds.pop_front()
				cos_bag_op.emit(CosNet.decode_bag_op(p.data))
				return
			if p.data.size() >= 1 and p.data[0] == 2 and not _item_op_kinds.is_empty() and _item_op_kinds[0] == "cos":
				_item_op_kinds.pop_front()
				cos_bag_op.emit(CosNet.decode_bag_op(p.data))
				return
			# Round 789: an avatar move's reply (its type byte, or a refusal
			# while an avatar move is the oldest one out) is AvatarNet's.
			# A buy back's success comes here too (type 0x22) but was sent as
			# 0x7168: it takes no entry.
			# Round 869: 0x0F (an item the server took, the hole's use) answers
			# no request either.
			var buyback := p.data.size() >= 2 and p.data[0] == 1 and p.data[1] in [ItemOpNet.TYPE_BUYBACK, ItemOpNet.TYPE_ITEM_TAKEN]
			var kind: String = _item_op_kinds.pop_front() if not buyback and not _item_op_kinds.is_empty() else ""
			if AvatarNet.is_move_ack(p.data) or (kind == "avatar" and p.data.size() >= 1 and p.data[0] == 2):
				_on_avatar_move_ack(p.data)
			else:
				item_op_result.emit(ItemOpNet.decode_result(p.data))
		ItemOpNet.OP_BUYBACK_FAIL:
			var f := ItemOpNet.decode_result(p.data)
			buyback_failed.emit(int(f.get("code", 0)))
		UseItemNet.OP_RESULT:
			use_item_result.emit(UseItemNet.decode_result(p.data))
		UseItemNet.OP_USE_EFFECT:
			var ue := UseItemNet.decode_use_effect(p.data)
			if not ue.is_empty():
				item_use_effect.emit(int(ue["uid"]), int(ue["ref"]))
		MallNet.OP_OPEN_RESULT:
			mall_open_result.emit(MallNet.decode_open_result(p.data))
		MallNet.OP_SILK:
			var sb := MallNet.decode_silk(p.data)
			if sb.size() == 3:
				silk_balances = sb
				has_silk = true
				mall_silk.emit(int(sb[0]), int(sb[1]), int(sb[2]))
		MallNet.OP_SILK_CHANGED:
			mall_silk_changed.emit(MallNet.decode_silk_changed(p.data))
		MallNet.OP_HISTORY_RESULT:
			mall_history.emit(MallNet.decode_history(p.data))
		MallNet.OP_CHEST_LIST_RESULT:
			chest_list.emit(MallNet.decode_chest_list(p.data))
		MallNet.OP_CHEST_TAKE_RESULT:
			chest_take_result.emit(MallNet.decode_chest_take(p.data))
		MallNet.OP_CHEST_LOG_RESULT:
			chest_log.emit(MallNet.decode_chest_log(p.data))
		MallNet.OP_CHEST_RECEIVED:
			chest_received.emit(MallNet.decode_chest_received(p.data))
		GachaNet.OP_PLAY_RESULT:
			gacha_play_result.emit(GachaNet.decode_play_result(p.data))
		GachaNet.OP_EXCHANGE_RESULT:
			gacha_exchange_failed.emit(GachaNet.decode_failure(p.data))
		GachaNet.OP_ANNOUNCE:
			var ga := GachaNet.decode_announce(p.data)
			if not ga.is_empty():
				gacha_announce.emit(int(ga["ref"]), int(ga["count"]))
		OP_BIG_NOTICE:
			if p.data.size() >= 2:
				var bn := p.data.decode_u16(0)
				var bt := p.data.slice(2, 2 + bn).get_string_from_utf8()
				if big_notice.get_connections().is_empty():
					pending_big_notice = bt
				else:
					big_notice.emit(bt)
		AutoPotionNet.OP_CONFIG:
			auto_potion_config.emit(p.data)
		CharacterLockNet.OP_REPLY:
			character_lock_reply.emit(CharacterLockNet.decode_reply(p.data))
		CompositeNet.OP_STATE:
			composite_state.emit(CompositeNet.decode_state(p.data))
		CompositeNet.OP_USE_RESULT:
			composite_use_result.emit(CompositeNet.decode_use_result(p.data))
		CompositeNet.OP_END:
			var ended := CompositeNet.decode_end(p.data)
			if ended.size() == 2:
				composite_ended.emit(int(ended[0]), int(ended[1]))
		CompositeNet.OP_GOLD_TIME:
			var gt := CompositeNet.decode_gold_time(p.data)
			if gt != null:
				gold_time.emit(gt)
		CompositeNet.OP_BUFF_ITEM_START, CompositeNet.OP_BUFF_ITEM_REFRESH, CompositeNet.OP_BUFF_ITEM_END:
			var bi := CompositeNet.decode_buff_item(p.opcode, p.data)
			if not bi.is_empty():
				if bool(bi["ended"]):
					buff_items.erase(int(bi["decoration"]))
				else:
					buff_items[int(bi["decoration"])] = bi
				print("NetClient: BFI1 grant %s" % str(bi))
				buff_item.emit(bi)
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
			# Round 795: a COS's HP (OwnerCOS 2, flag 1: u32 HP; OURS head,
			# retail's flag-1 field, c:0x8a9e30).
			if p.data.size() >= 16 and p.data[0] == 2 and p.data[11] & 1:
				cos_hp.emit(p.data.decode_u32(1), p.data.decode_u32(12))
				return
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
		DestMoveNet.OP_MOVEMENT_ECHO, DestMoveNet.OP_MOVEMENT_STOP, DestMoveNet.OP_MOVEMENT_TURN:
			# Round 749: in order behind any player spawn still waiting for the
			# item table, so a body is never told to walk before it exists.
			_user_spawn_message(p.opcode, p.data)
		NpcSpawnNet.OP_SINGLE_SPAWN:
			# A player's record (round 737) or an NPC's, by its RefObjID; a
			# COS's (round 795) by the COS table, which comes with the item
			# table: before both, the record waits with the players'.
			if p.data.size() >= 4 and (UserSpawnNet.is_player_ref(p.data.decode_u32(0)) \
					or _spawn_types == null or cos_kind_of(p.data.decode_u32(0)) != 0 \
					or _structure_kinds.has(p.data.decode_u32(0))):
				_user_spawn_message(NpcSpawnNet.OP_SINGLE_SPAWN, p.data)
			else:
				var single := NpcSpawnNet.decode_single_spawn(p.data)
				if single == null:
					push_warning("NetClient: a 0x3015 that does not read as an NPC record (%d bytes)" % p.data.size())
				else:
					npc_spawned.emit(npc_roster.spawn(single))
		NpcSpawnNet.OP_SINGLE_DESPAWN:
			var gone := NpcSpawnNet.decode_single_despawn(p.data)
			if gone >= 0 and (user_roster.has(gone) or cos_roster.has(gone) or structure_roster.has(gone) or not _pending_spawns.is_empty()):
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
		GroundItemsNet.OP_PICK_UP_MOTION:
			var pm := GroundItemsNet.decode_pick_up_motion(p.data)
			if pm != null:
				pick_up_motion.emit(pm)
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
				# Round 873: its height is the wire's (region-local), as every
				# position since round 870. Taken raw, a sprint on the Wrecked
				# Ship (anchor -1800) slid the player 1,560 units down off the
				# deck to the sea floor (prod, v0.1.643).
				var wire_height := sm.y
				sm.y = scene_y(sm.y)
				print("SKILL move: character %d skill %d to (%.1f, %.1f, %.1f) (wire height %.1f)" % [
					sm.character_id, sm.skill_id, sm.x, sm.y, sm.z, wire_height])
				skill_moved.emit(sm)
		PartyNet.OP_CREATE_ACK, PartyNet.OP_INVITE_ACK, PartyNet.OP_JOIN_ACK, \
				PartyNet.OP_PARTY_INFO, PartyNet.OP_REQUEST, PartyNet.OP_EVENT, \
				PartyNet.OP_ITEM_NOTICE:
			# Round 834: 0x3080 kind 1 is the exchange's (c:0x88aa60 case 1).
			if p.opcode == PartyNet.OP_REQUEST and p.data.size() >= 5 and p.data[0] == ExchangeNet.REQUEST_KIND:
				exchange_requested.emit(p.data.decode_u32(1))
				return
			# Round 844 (lane V): kind 10 is a proclamation of war (0x88aea8).
			if p.opcode == PartyNet.OP_REQUEST and p.data.size() >= 1 and p.data[0] == GuildWarNet.REQUEST_WAR:
				var info := GuildWarNet.decode_proclamation(p.data)
				if not info.is_empty():
					guild_war_proclaimed.emit(info)
				return
			# Round 865: kind 9 is the academy's invitation (c:0x88aba8).
			if p.opcode == PartyNet.OP_REQUEST and academy.handle(p.opcode, p.data):
				return
			# Round 844: 0x3080 kind 6 is the union's (c:0x88afb4).
			if p.opcode == PartyNet.OP_REQUEST and union_ops.handle(p.opcode, p.data):
				return
			# Round 822: 0x3080 kind 5 is the guild's (c:0x88aeb7).
			if p.opcode != PartyNet.OP_REQUEST or not guild_ops.handle(p.opcode, p.data):
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
			var hwan := RewardNoticeNet.decode_hwan(p.data)
			if not hwan.is_empty():
				hwan_count.emit(hwan[0], hwan[1])
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
		GuildPlateNet.OP_ENTITY_GUILD:
			_guild_line_update(GuildPlateNet.decode_entity(p.data))
		OP_GUILD_WAR_STATE:
			if p.data.size() >= 5:
				note_war_flag(p.data.decode_u32(1), 0 if p.data.decode_u8(0) == 0 else 1)
		GuildPlateNet.OP_GUILD_LEFT:
			if p.data.size() >= 4:
				_guild_line_update({"uid": p.data.decode_u32(0), "guild_id": 0, "guild_name": "", "nickname": ""})
		GuildPlateNet.OP_NICKNAME_UPDATE:
			_guild_nickname_update(GuildPlateNet.decode_nickname(p.data))
		GuildPlateNet.OP_GRANT_NAME_RESULT:
			var gr := GuildPlateNet.decode_grant_result(p.data)
			if not gr.is_empty():
				guild_grant_result.emit(gr)
		UniqueNoticeNet.OP_UNIQUE_NOTICE:
			# Round 801: a word the unique notices do not carry (0x0c01, the
			# thief's town veto) goes to its own signal.
			if p.data.size() >= 2 and p.data.decode_u16(0) not in [UniqueNoticeNet.KIND_SPAWN, UniqueNoticeNet.KIND_KILL]:
				# Round 869: the game worlds' two words (GameWorldNet).
				if GameWorldNet.is_world_notice(p.data):
					_world_notice(p.data)
					return
				notice_word.emit(p.data.decode_u16(0))
				return
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
		ExchangeNet.OP_REQUEST_RESULT:
			var er := ExchangeNet.decode_request_result(p.data)
			if not er.is_empty():
				exchange_request_result.emit(bool(er[0]), int(er[1]))
		ExchangeNet.OP_STARTED:
			if p.data.size() >= 4:
				exchange_started.emit(p.data.decode_u32(0))
		ExchangeNet.OP_OFFER:
			var eo := ExchangeNet.decode_offer(p.data, own_character_id)
			if eo.is_empty():
				push_warning("NetClient: 0x308C did not parse (%d bytes)" % p.data.size())
			else:
				exchange_offer.emit(eo)
		ExchangeNet.OP_UPDATE:
			var eg := ExchangeNet.decode_gold_update(p.data)
			if eg >= 0:
				exchange_partner_gold.emit(eg)
		ExchangeNet.OP_CONFIRMED:
			exchange_partner_confirmed.emit()
		ExchangeNet.OP_CONFIRM_RESULT, ExchangeNet.OP_APPROVE_RESULT, ExchangeNet.OP_CANCEL_RESULT:
			exchange_result.emit(p.opcode - 0x8000, ExchangeNet.decode_result(p.data))
		ExchangeNet.OP_DONE:
			exchange_closed.emit(1)
		ExchangeNet.OP_CLOSED:
			if p.data.size() >= 2:
				exchange_closed.emit(p.data.decode_u16(0))
		StallNet.OP_OPEN_RESULT:
			stall_open_result.emit(StallNet.decode_result(p.data))
		StallNet.OP_CLOSE_RESULT:
			stall_close_result.emit(StallNet.decode_result(p.data))
		StallNet.OP_LEAVE_RESULT:
			stall_leave_result.emit(StallNet.decode_result(p.data))
		StallNet.OP_ENTER_RESULT:
			var se := StallNet.decode_enter(p.data)
			if se.is_empty():
				push_warning("NetClient: 0xB0B3 did not parse (%d bytes)" % p.data.size())
			else:
				stall_entered.emit(se)
		StallNet.OP_BUY_RESULT:
			var sb := StallNet.decode_buy(p.data)
			if not sb.is_empty():
				stall_buy_result.emit(sb)
		StallNet.OP_UPDATE_RESULT:
			var su := StallNet.decode_update(p.data)
			if su.is_empty():
				push_warning("NetClient: 0xB0BA did not parse (%d bytes)" % p.data.size())
			else:
				stall_updated.emit(su)
		StallNet.OP_EVENT:
			var sv := StallNet.decode_event(p.data)
			if sv.is_empty():
				push_warning("NetClient: 0x30B7 did not parse (%d bytes)" % p.data.size())
			else:
				stall_event.emit(sv)
		StallNet.OP_APPEAR:
			var sa := StallNet.decode_appear(p.data)
			if not sa.is_empty():
				stalls[int(sa["owner"])] = sa
				stall_appeared.emit(sa)
		StallNet.OP_GONE:
			var sg := StallNet.decode_gone(p.data)
			if not sg.is_empty():
				stalls.erase(int(sg["owner"]))
				stall_gone.emit(sg)
		StallNetworkNet.OP_SEARCH_RESULT:
			var nsr := StallNetworkNet.decode_search(p.data, stall_net_page)
			if nsr.is_empty():
				push_warning("NetClient: 0xB461 did not parse (%d bytes)" % p.data.size())
			else:
				stall_net_searched.emit(nsr)
		StallNetworkNet.OP_LEAVE_RESULT:
			stall_net_left.emit(int(p.data[0]) if p.data.size() >= 1 else -1)
		StallNetworkNet.OP_BUY_RESULT:
			stall_net_bought.emit(StallNetworkNet.decode_result(p.data))
		PunishNet.OP_RESTRICTION:
			var rn := PunishNet.decode(p.data)
			if not rn.is_empty():
				restriction_notice.emit(rn)
		StallNet.OP_RENAMED:
			var sr := StallNet.decode_renamed(p.data)
			if not sr.is_empty():
				if stalls.has(int(sr["owner"])):
					(stalls[int(sr["owner"])] as Dictionary)["name"] = sr["name"]
				stall_renamed.emit(sr)
		FriendNet.OP_LIST:
			last_friend_list = FriendNet.decode_list(p.data)
			has_friend_list = true
			friend_list_changed.emit(last_friend_list)
		FriendNet.OP_PUSH:
			var fp := FriendNet.decode_push(p.data)
			if fp == null:
				push_warning("NetClient: 0x3B07 kind %d not handled (%d bytes)" % [p.data[0] if p.data.size() > 0 else -1, p.data.size()])
			else:
				FriendNet.apply_push(last_friend_list, fp)
				friend_list_changed.emit(last_friend_list)
				friend_pushed.emit(fp)
		FriendNet.OP_ASK:
			var fr := FriendNet.decode_request(p.data)
			if fr != null:
				friend_requested.emit(fr)
		FriendNet.OP_ASK_FAILED:
			var ff := FriendNet.decode_failure(p.data)
			if ff != null:
				friend_failed.emit(ff)
		FriendNet.OP_DELETE_RESULT:
			var fd := FriendNet.decode_delete_result(p.data)
			if not fd.is_empty():
				friend_delete_result.emit(bool(fd[0]), int(fd[1]))
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
		AlchemyNet.OP_REINFORCE_RESULT, AlchemyNet.OP_STONE_RESULT:
			var r := AlchemyNet.decode_result(p.data, p.opcode == AlchemyNet.OP_REINFORCE_RESULT)
			if r != null:
				alchemy_result.emit(r)
		AvatarNet.OP_LIST:
			var al := AvatarNet.decode_list(p.data)
			if al.has("error"):
				push_warning("NetClient: avatar list: %s" % al["error"])
			else:
				last_avatar_instances = _note_instances("avatar", al["items"])
				avatar_list_received = true
				avatar_list_result.emit(last_avatar_instances)
		AvatarNet.OP_ITEM_STATE:
			var st := AvatarNet.decode_item_state(p.data)
			if not st.is_empty() and int(st["kind"]) == AvatarNet.ITEM_STATE_SPIRIT_EXPIRED:
				var spirit = last_avatar_instances.get(int(st["slot"]))
				if spirit != null:
					(spirit as ItemInstance).durability = 1 << 31
				print("NetClient: 0x3078 the devil's spirit in avatar slot %d expired" % int(st["slot"]))
				avatar_spirit_expired.emit(int(st["slot"]))
			else:
				print("NetClient: 0x3078 %s (kind not read)" % p.data.hex_encode())
		AvatarNet.OP_GRANT_ACK:
			var ga := AvatarNet.decode_grant_ack(p.data)
			if ga.has("error"):
				push_warning("NetClient: avatar grant reply: %s" % ga["error"])
			else:
				if bool(ga["ok"]) and ga["item"] != null:
					# READ c:0x899f40: the new item is put at bag index slot - 13.
					var it: ItemInstance = ga["item"]
					last_inventory_instances[it.slot] = it
					_note_instances("bag", {it.slot: it})
				avatar_grant_result.emit(ga)
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
		GameWorldNet.OP_NOTICE:
			# Round 869: retail's own 0x300C (the server may send the game
			# worlds' words on it rather than on OpUniqueNotice).
			if GameWorldNet.is_world_notice(p.data):
				_world_notice(p.data)
			elif p.data.size() >= 2:
				notice_word.emit(p.data.decode_u16(0))
		StructureSpawnNet.OP_EVENT_ZONE_STATE:
			# Round 869 (READ c:0x89a7b0): only field 0x10 is acted on.
			var ez := StructureSpawnNet.decode_event_zone_state(p.data)
			if not ez.is_empty() and int(ez["field"]) == StructureSpawnNet.EVENT_FIELD_TRIGGER:
				var known: StructureSpawnNet.Record = structure_roster.structures.get(int(ez["uid"]))
				if known != null:
					known.state = int(ez["state"])
				event_zone_state.emit(int(ez["uid"]), int(ez["state"]))
		GameWorldNet.OP_TIMED_JOB:
			var tj := GameWorldNet.decode_timed_job(p.data)
			if not tj.is_empty():
				timed_job.emit(tj)
		GameWorldNet.OP_TELEPORT_USE_ACK:
			var ta := GameWorldNet.decode_teleport_ack(p.data)
			if not ta.is_empty():
				teleport_use_ack.emit(ta)
		_:
			if _extra_handlers.has(p.opcode):
				(_extra_handlers[p.opcode] as Callable).call(p.data)
			elif _should_warn_unhandled(p.opcode):
				push_warning("NetClient: unhandled opcode 0x%04x (warned once per connection)" % p.opcode)

## Round 869: a 0x300C word of the game worlds, decoded (GameWorldNet).
func _world_notice(data: PackedByteArray) -> void:
	var n := GameWorldNet.decode_notice(data)
	if n.is_empty():
		push_warning("NetClient: a game-world notice that does not read (%d bytes)" % data.size())
		return
	world_notice.emit(n)

## Round 789: an avatar move's 0xB034 applied as the client applies it (READ
## c:0x87ba20): 0x24 moves bag src-13 into avatar storage dst, 0x23 avatar
## src into bag dst-13, then each sub-op the same way; then avatar_move_result.
func _on_avatar_move_ack(data: PackedByteArray) -> void:
	var r := AvatarNet.decode_move_ack(data)
	if r.has("error"):
		push_warning("NetClient: avatar move reply: %s" % r["error"])
		return
	if bool(r["ok"]):
		var moves: Array = [r]
		moves.append_array(r["subs"])
		for m in moves:
			_apply_avatar_move(int(m["type"]), int(m["src"]), int(m["dst"]))
		print("NetClient: avatar move 0x%02x %d -> %d (%d sub-op(s)); avatars %s" % [int(r["type"]), int(r["src"]), int(r["dst"]),
			(r["subs"] as Array).size(), str(last_avatar_instances.keys())])
	else:
		print("NetClient: avatar move refused (code 0x%x)" % int(r["code"]))
	avatar_move_result.emit(r)

func _apply_avatar_move(type: int, src: int, dst: int) -> void:
	if type == AvatarNet.TYPE_BAG_TO_AVATAR:
		var it = last_inventory_instances.get(src - AvatarNet.BAG_OFFSET)
		last_inventory_instances.erase(src - AvatarNet.BAG_OFFSET)
		if it != null:
			(it as ItemInstance).slot = dst
			last_avatar_instances[dst] = it
	elif type == AvatarNet.TYPE_AVATAR_TO_BAG:
		var it = last_avatar_instances.get(src)
		last_avatar_instances.erase(src)
		if it != null:
			(it as ItemInstance).slot = dst - AvatarNet.BAG_OFFSET
			last_inventory_instances[dst - AvatarNet.BAG_OFFSET] = it

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
