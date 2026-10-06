extends SceneTree

## UserSpawnNet (round 737): the other players' retail spawn records, read
## from the bytes server/internal/pcspawn TestClientFixture pins (a group of
## Aria -- sitting, berserk, two items --, an NPC and Bram -- a job suit, so no
## guild block --, a 0x3015 of Aria, a group despawn of both), and NetClient's
## handling of them: a group that comes before World3D's item table waits for
## it, then joins the entry's list; a despawn of a player leaves by
## entity_left, of an NPC by npc_despawned.
## `godot4 --headless --path client --script res://scripts/net/user_spawn_test.gd`

const GROUP := "01030073070000220000006d023b0e000000300e00000705000001000000a86100807a440000604000007f44004000010000400100040100008041000048420000c8420004004172696100000000000000000000000000000000000000000000000000000000000000ffd00700000100007fa861000061440000000000806d44000000010000000100000000000000000000000000c84200020207091b3a0000440000006d02ea2900000df82a00000005000002000000a961000020410000000000d0ee4400c000010000c00100000000008041000096420000c8420004004272616d0000000000000000000000ff"
const SINGLE := "73070000220000006d023b0e000000300e00000705000001000000a86100807a440000604000007f44004000010000400100040100008041000048420000c8420004004172696100000000000000000000000000000000000000000000000000000000000000ff04"
const DESPAWN := "0202000100000002000000"

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## The item table the fixture's items are read by: a chest piece, two
## swords and a job suit (TypeID 3/1/7/2: job state 2).
func _rows() -> Dictionary:
	var rows := {}
	for e in [[3643, [3, 1, 1, 3]], [3632, [3, 1, 6, 2]], [10730, [3, 1, 6, 2]], [11000, [3, 1, 7, 2]]]:
		var it := ItemTableReader.Item.new()
		it.id = e[0]
		it.type_ids = PackedInt32Array(e[1])
		rows[e[0]] = it
	return rows

## Where World3D.region_local_to_world puts region (rx, ry)'s local (lx, lz)
## in frame (fx, fy), by its own two steps -- World3D._cell_offset's
## Vector3(dy * span, 0, dx * span), then TerrainCollision.place_group -- since
## World3D.gd cannot be loaded under --script (it names the NetClient
## autoload).
func _world3d_xz(rx: int, ry: int, lx: float, lz: float, fx: int, fy: int) -> Vector2:
	var g := Node3D.new()
	TerrainCollision.place_group(g, Vector3((ry - fy) * 1920.0, 0.0, (rx - fx) * 1920.0), 0.0)
	var at := g.transform * Vector3(lx, 0.0, lz)
	g.free()
	return Vector2(at.x, at.z)

func _test_records() -> void:
	var types := UserSpawnNet.Types.new(_rows())
	var g := UserSpawnNet.read_group(GROUP.hex_decode(), types)
	_check(g.error == "" and not g.deferred and g.kind == NpcSpawnNet.GROUP_SPAWN, "the group reads (%s)" % g.error)
	_check(g.users.size() == 2 and g.npcs.size() == 1, "two players and an NPC (%d, %d)" % [g.users.size(), g.npcs.size()])
	if g.users.size() != 2 or g.npcs.size() != 1:
		return
	var aria: UserSpawnNet.Record = g.users[0]
	var bram: UserSpawnNet.Record = g.users[1]
	_check(aria.ref_id == 1907 and aria.scale == 0x22 and aria.uid == 1 and aria.name == "Aria", "Aria's body, uid and name")
	_check(aria.region == 0x61a8 and aria.local_position == Vector3(1002, 3.5, 1020) and aria.angle == 16384, "Aria's place and angle")
	_check(aria.motion == UserSpawnNet.MOTION_SIT and aria.body_mode == UserSpawnNet.BODY_MODE_BERSERK and aria.life == 1, "Aria sits, berserk, alive")
	_check(aria.items.size() == 2 and int(aria.items[0]["id"]) == 3643 and int(aria.items[1]["plus"]) == 7, "Aria's items %s" % [aria.items])
	_check(aria.job_state == UserSpawnNet.JOB_STATE_NONE and is_equal_approx(aria.run, 50.0), "Aria: no job suit, run 50")
	_check(bram.ref_id == 14875 and bram.uid == 2 and bram.job_state == 2 and bram.name == "Bram", "Bram: a job suit, job state 2, no guild block")
	_check(int(bram.items[0]["plus"]) == 13 and is_equal_approx(bram.run, 75.0), "Bram's +13 and run 75")
	var npc: NpcSpawnNet.Record = g.npcs[0]
	_check(npc.uid == 0x7f000001 and npc.ref_id == 2000 and npc.interactions == PackedByteArray([7, 9]), "the NPC between them")

	# The snapshot World3D draws from: world coordinates in frame 97/168 (the
	# server's worldmap.ToWorld, World3D.region_local_to_world), equip slots.
	var frame := Vector2i(97, 168)
	var s := UserSpawnNet.to_snapshot(aria, types, frame)
	_check(s.character_id == 1 and s.char_name == "Aria" and s.has_model and s.ref_obj_id == 1907 and s.scale == 0x22, "Aria's snapshot names her body")
	_check(is_equal_approx(s.x, 42.0) and is_equal_approx(s.z, -60.0) and is_equal_approx(s.y, 3.5), "Aria stands at (42, 3.5, -60) (%f, %f, %f)" % [s.x, s.y, s.z])
	var at := _world3d_xz(97, 168, 1002.0, 1020.0, 97, 168)
	_check(at.distance_to(Vector2(s.x, s.z)) < 1e-3, "World3D's region placement agrees (%s)" % at)
	var b := UserSpawnNet.to_snapshot(bram, types, frame)
	var bat := _world3d_xz(97, 169, 10.0, 1910.5, 97, 168)
	_check(bat.distance_to(Vector2(b.x, b.z)) < 1e-3 and is_equal_approx(b.x, 970.0), "Bram, a region over, at %s" % bat)
	_check(s.equipped.get(CharacterAppearance.SLOT_CHEST) == 3643 and s.equipped.get(CharacterAppearance.SLOT_WEAPON) == 3632, "Aria's items by equip slot %s" % [s.equipped])
	_check(s.pluses.size() == 1 and s.pluses.get(CharacterAppearance.SLOT_WEAPON) == 7, "Aria's pluses %s" % [s.pluses])
	_check(is_equal_approx(s.heading, RemoteFacing.from_wire_angle(16384)), "Aria faces the wire angle's heading")
	_check(b.equipped.get(CharacterAppearance.SLOT_SUIT) == 11000 and b.gender == CharacterNet.GENDER_EUROPE_MAN, "Bram's suit in slot 8, a Europe man")

	# The single spawn and the despawn group.
	var one := UserSpawnNet.decode_single_spawn(SINGLE.hex_decode(), types)
	_check(one != null and one.uid == 1 and one.spawn_type == 4, "the 0x3015 of Aria, spawn type 4")
	var gone := UserSpawnNet.read_group(DESPAWN.hex_decode(), null)
	_check(gone.error == "" and gone.kind == NpcSpawnNet.GROUP_DESPAWN and gone.uids == [1, 2], "the group despawn names both (%s)" % [gone.uids])
	# Without the item table a player record cannot be read: the group waits.
	var early := UserSpawnNet.read_group(GROUP.hex_decode(), null)
	_check(early.deferred and early.users.is_empty(), "before the item table the group is deferred")
	_check(UserSpawnNet.parse_frame("97/168") == frame and UserSpawnNet.parse_frame("") == Vector2i(-1, -1), "frames parse")

func _test_net_client() -> void:
	var nc = load("res://scripts/net/net_client.gd").new()
	var res := WorldNet.EnterWorldResult.new()
	res.ok = true
	res.frame = "97/168"
	nc.last_enter_world_result = res
	nc._start_user_view(res.frame)
	# The entry's group comes before World3D: it waits for the item table.
	nc._user_spawn_message(NpcSpawnNet.OP_GROUP_END, GROUP.hex_decode())
	_check(nc._pending_spawns.size() == 1 and res.others.is_empty(), "the group waits for the item table")
	var npcs := []
	nc.npc_spawned.connect(func(rec): npcs.append(rec.uid))
	nc.set_spawn_item_rows(_rows())
	_check(nc._pending_spawns.is_empty(), "the item table reads it")
	_check(res.others.size() == 2 and res.others[0].char_name == "Aria" and res.others[1].char_name == "Bram", "nobody listens yet: both join the entry's list")
	_check(res.seated.size() == 1 and res.seated[0] == 1, "Aria joins its seated list (%s)" % [res.seated])
	_check(nc.body_modes.get(1) == 1 and not nc.body_modes.has(2), "Aria's berserk is kept for her body")
	_check(npcs == [0x7f000001] and nc.npc_roster.npcs.has(0x7f000001), "the NPC is spawned as before")
	# World3D listens now: a 0x3016 of a player leaves by entity_left; of the
	# NPC, by npc_despawned.
	var left := []
	var despawned := []
	nc.entity_left.connect(func(id): left.append(id))
	nc.npc_despawned.connect(func(uid): despawned.append(uid))
	var u2 := PackedByteArray([2, 0, 0, 0])
	nc._user_spawn_message(NpcSpawnNet.OP_SINGLE_DESPAWN, u2)
	var npc_uid := PackedByteArray()
	npc_uid.resize(4)
	npc_uid.encode_u32(0, 0x7f000001)
	nc._apply_spawn_message(NpcSpawnNet.OP_SINGLE_DESPAWN, npc_uid)
	_check(left == [2] and despawned == [0x7f000001], "Bram left, the NPC despawned (%s, %s)" % [left, despawned])
	# A single spawn while listening: entity_entered, then her sitting.
	var entered := []
	var states := []
	nc.entity_entered.connect(func(snap): entered.append(snap.character_id))
	nc.state_changed.connect(func(c): states.append([c.object_id, c.kind, c.value]))
	nc._user_spawn_message(NpcSpawnNet.OP_SINGLE_SPAWN, SINGLE.hex_decode())
	_check(entered == [1] and states == [[1, WorldNet.STATE_KIND_MOTION, WorldNet.MOTION_SIT]], "Aria enters, then sits (%s, %s)" % [entered, states])
	nc.free()

func _init() -> void:
	_test_records()
	_test_net_client()
	if _failures > 0:
		print("%d failure(s)" % _failures)
		quit(1)
	else:
		print("all user spawn checks passed")
		quit(0)
