extends RefCounted
class_name UserSpawnNet

## Retail's spawn record for another player (round 737, docs/protocol/
## pc_spawn.md, crowd_scale.md C1): the server sends the players in view as
## the same messages it sends NPCs -- the group spawn 0x3017 / 0x3019 /
## 0x3018 when they come into view (one group per message block), the single
## spawn 0x3015 when one arrives in a block already in view, and the despawns
## 0x3016 / the group of type 2 when they go -- with a CICUser's record:
## FUN_008a6bd0's RefObjID, then CICUser slot 25 (GlobalDataManager::
## FUN_009de2f0) and its readers (slot 22 0x9dbc30, slot 23 0x9ddc40 ->
## 0x9d1300). Every width and condition below is READ from both binaries
## (server CGObjPC::vslot_294 0x4e5a10 mode 2 -> vslot_293 0x4e5b00); the
## server's twin is server/internal/pcspawn.
##
## Two of the reader's choices depend on the item table, as the client's
## own do: whether a plus byte follows an equipment-list item (its type word
## is TypeID 3/1), and the job state (the visual-slot-8 suit's TypeID4 when
## it is 3/1/7/1..3, else 4; the client's 0x9db8b0), which decides whether
## the guild block is there. So a record is read only once World3D has
## handed NetClient its item table (Types); a group that holds one before
## then waits (NetClient._pending_spawns).
##
## Which class a record is: FUN_008a6bd0 asks the RefObjID's TypeID. This
## reader has no characterdata, so it takes the 52 creatable Figures' ids --
## 1907-1932 and 14875-14900 (MEASURED, CharacterNet.gender_of_model) -- as
## the players (OURS); anything else is read as an NPC (NpcSpawnNet).

const JOB_STATE_NONE := 4
const MOTION_SIT := 4
## The body mode a berserk character's record carries (round 651's 0x30BF
## kind 4 value 1).
const BODY_MODE_BERSERK := 1
const TEAM_NONE := 0xff

class Record:
	var ref_id: int
	var scale: int
	var hwan_level: int
	## [{"id": RefItemID, "plus": int}] in wire order: equip slots 0..8,
	## ascending.
	var items: Array = []
	## Round 789: the avatar block's [{"id", "plus"}] in storage order
	## (AvatarNet.read_spawn_block; the record carries no slot byte).
	var avatars: Array = []
	var uid: int
	var region: int
	var local_position: Vector3
	var angle: int
	var life: int
	var motion: int
	var body_mode: int
	var walk: float
	var run: float
	## The mover's run flag (+0x155; round 781): 0 while the character walks.
	var run_flag := 1
	var name: String
	var job_state: int = JOB_STATE_NONE
	## Round 800: row 22's job kind (0 none, 1 trader, 2 thief, 3 hunter) and
	## job level (player +0x7be / +0x7bf), row 28's trade scale (+0x50e).
	var job_kind: int = 0
	var job_level: int = 0
	var trade_rank: int = 0
	## The 0x3015's spawn-type byte (-1 in a group).
	var spawn_type := -1
	## The mover (round 749): walking to dest_local of dest_region, or the
	## heading form's command (bit 0 runs) and angle.
	var has_dest := false
	var dest_region: int
	var dest_local := Vector3i.ZERO
	var move_command: int
	var move_angle: int
	## Round 795: the ridden COS's uid (ride state 1), 0 when it walks.
	var mount_uid := 0
	## Round 814: its guild line (GuildPlateNet.plate_text): the guild's name
	## (READ: the string after the trade rank, which the client keeps at
	## CICUser+0x7e4, c:0x9ddf4b), and in the guild block -- only without a
	## job suit -- the guild's id and the member's grant name (+0x7c8,
	## FUN_009dc520 at c:0x9de08c). "" / 0 for none.
	var guild_name := ""
	var guild_id := 0
	var nickname := ""
	## Round 824: the guild's crest revision (the guild block's first u32
	## after the grant name; GlobalDataManager::FUN_009ddc40 0x9de0fe).
	var crest_rev := 0
	## Round 842: the union's id and crest revision (the block's next two
	## u32, handed to the crest cache 0x9a4780 with the guild's); 0 none.
	var union_id := 0
	var union_crest_rev := 0
	## Round 839: the interaction byte (+0x471, c:0x9ddee9) and, when it is 4,
	## the stall block after the guild block (c:0x9de103..0x9de1bd): the
	## stall's name (kept as "[name]" at +0x798) and its booth (+0x790).
	var interact := 0
	var stall_name := ""
	var stall_decoration := 0

## The item table the reader asks (World3D's own: RefItemID ->
## ItemTableReader.Item).
class Types:
	var rows: Dictionary
	## Round 795: the COS table's TypeID4 by RefObjID (CosTable.kind_of): a
	## record whose ref it names is a CICCos's (CosSpawnNet). Unbound, none is.
	var cos_kind: Callable

	func _init(r: Dictionary, cos: Callable = Callable()) -> void:
		rows = r
		cos_kind = cos

	## A RefObjID's COS TypeID4, 0 for none.
	func cos_kind_of(ref_id: int) -> int:
		return int(cos_kind.call(ref_id)) if cos_kind.is_valid() else 0

	func type_ids(id: int) -> PackedInt32Array:
		var it = rows.get(id)
		if it == null:
			return PackedInt32Array()
		return it.type_ids

	## The reader's plus test (0x9de350): an item of TypeID 3/1. An item the
	## table does not know is taken as equipment, as the server takes it.
	func has_plus(id: int) -> bool:
		var t := type_ids(id)
		if t.size() < 2:
			return true
		return t[0] == 3 and t[1] == 1

	## Whether the spawn's avatar block carries a plus byte after this id
	## (READ c:0x9de3e2..0x9de4a1: only a 3/1/13 or 3/1/14). OURS: an id the
	## table does not know is read with one -- the server puts only avatars
	## in the block, and the client's own reading of an unknown ref is not
	## READ.
	func avatar_has_plus(id: int) -> bool:
		var t := type_ids(id)
		if t.size() < 3:
			return true
		return t[0] == 3 and t[1] == 1 and (t[2] == 13 or t[2] == 14)

	## The job state the worn items give (0x9db8b0).
	func job_state(items: Array) -> int:
		for it in items:
			var t := type_ids(int(it["id"]))
			if t.size() >= 4 and t[0] == 3 and t[1] == 1 and t[2] == 7 and t[3] >= 1 and t[3] <= 3:
				return t[3]
		return JOB_STATE_NONE

	## The equip slot an item is worn in: its visual slot 0..8
	## (CharacterAppearance.visual_slot, ResolveVisualSlotForItem), which is
	## the equip slot for every item the list can hold; -1 when unknown.
	func equip_slot(id: int) -> int:
		var t := type_ids(id)
		# Ammunition (TypeID 3/3/4) is worn in equip slot 7, the shield's
		# (server equipment.SlotFor, READ from the engine's resolver).
		if t.size() >= 3 and t[0] == 3 and t[1] == 3 and t[2] == 4:
			return CharacterAppearance.SLOT_SHIELD
		var s := CharacterAppearance.visual_slot(t)
		return s if s >= 0 and s <= CharacterAppearance.SLOT_SUIT else -1

## Whether a RefObjID is a player body (the 52 creatable Figures, OURS: see
## the header).
static func is_player_ref(ref_id: int) -> bool:
	return (ref_id >= 1907 and ref_id <= 1932) or (ref_id >= 14875 and ref_id <= 14900)

## The RefObjID at r's position, without moving it; -1 when cut short.
static func peek_ref(r: NpcSpawnNet.Reader) -> int:
	if r.pos + 4 > r.data.size():
		return -1
	return r.data.decode_u32(r.pos)

## One record from r, read as the client reads it. null with r.error set on a
## bad record, or on a form OpenSRO's server never sends (a mask, a
## destination, buffs, a ride: their widths depend on more than this reader
## models).
static func read_record(r: NpcSpawnNet.Reader, types: Types) -> Record:
	var rec := Record.new()
	rec.ref_id = r.u32()
	rec.scale = r.u8()
	rec.hwan_level = r.u8()
	r.u8() # PVP cape
	r.u8() # AutoInvestExp
	r.u8() # inventory size
	var n := r.u8()
	for i in n:
		var id := r.u32()
		var plus := 0
		if types == null or types.has_plus(id):
			plus = r.u8()
		rec.items.append({"id": id, "plus": plus})
	# Round 789: the avatar block (READ c:0x9de3e2..0x9de4a1, s:0x4ba720
	# mode 2): u8 size (5), u8 count, per item u32 RefItemID and a plus only
	# for a 3/1/13 or 3/1/14. Until now any avatar failed the record.
	rec.avatars = AvatarNet.read_spawn_block(r, types.avatar_has_plus if types != null else Callable())
	if r.u8() != 0 and r.error == "":
		r.error = "a mask in a player record"
		return null
	rec.uid = r.u32()
	rec.region = r.u16()
	var x := r.f32()
	var y := r.f32()
	var z := r.f32()
	rec.local_position = Vector3(x, y, z)
	rec.angle = r.u16()
	# The mover (0x48be00; round 749): a destination -- its region and three
	# i16, or a dungeon's three i32 -- or the command byte and the mover's
	# angle (+0x168, +0x164: a heading run while the command's bit 0 is set).
	var has_dest := r.u8()
	rec.run_flag = r.u8()
	if has_dest != 0:
		rec.has_dest = true
		rec.dest_region = r.u16()
		if rec.dest_region & 0x8000:
			# A dungeon's three i32, dungeon space (round 773).
			var ddx := r.u32()
			var ddy := r.u32()
			var ddz := r.u32()
			rec.dest_local = Vector3i(_s32(ddx), _s32(ddy), _s32(ddz))
		else:
			var dx := r.u16()
			var dy := r.u16()
			var dz := r.u16()
			rec.dest_local = Vector3i(dx - 0x10000 if dx >= 0x8000 else dx, dy - 0x10000 if dy >= 0x8000 else dy,
				dz - 0x10000 if dz >= 0x8000 else dz)
	else:
		rec.move_command = r.u8()
		rec.move_angle = r.u16()
	rec.life = r.u8()
	r.u8()
	rec.motion = r.u8()
	rec.body_mode = r.u8()
	rec.walk = r.f32()
	rec.run = r.f32()
	r.f32() # param 140
	if r.u8() != 0 and r.error == "":
		r.error = "buffs in a player record"
		return null
	rec.name = r.bytes(r.u16()).get_string_from_utf8()
	rec.job_kind = r.u8()
	rec.job_level = r.u8()
	r.u8() # PvP state
	var ride := r.u8()
	r.u8() # battle state
	# Round 795: a rider's COS uid follows the battle byte (READ
	# s:0x4e5c04..0x4e5c86, c:0x9dde69..0x9ddeba).
	if ride == 1:
		rec.mount_uid = r.u32()
	r.u8() # teleport state
	var interact := r.u8()
	rec.trade_rank = r.u8()
	rec.guild_name = r.bytes(r.u16()).get_string_from_utf8()
	rec.job_state = types.job_state(rec.items) if types != null else JOB_STATE_NONE
	if rec.job_state == JOB_STATE_NONE:
		rec.guild_id = r.u32()
		rec.nickname = r.bytes(r.u16()).get_string_from_utf8()
		rec.crest_rev = r.u32()
		# Round 842: the union's id and crest revision.
		rec.union_id = r.u32()
		rec.union_crest_rev = r.u32()
		r.u8() # membership
		r.u8() # fortress role
	rec.interact = interact
	if interact == 4:
		rec.stall_name = r.bytes(r.u16()).get_string_from_utf8()
		rec.stall_decoration = r.u32()
	r.u8() # timer byte
	r.u8() # team byte
	if r.error != "":
		return null
	return rec

## World (x, z) of region-local (lx, lz) in the frame centred on region
## (fx, fy): the server's worldmap.ToWorld, and World3D.region_local_to_world
## (region y drives world X, region x drives world Z, z mirrored).
##
## A dungeon region (bit 15, round 773) carries dungeon-space coordinates,
## whatever the frame: the world point is (x, -z), the one mirror
## (DungeonWorld).
static func world_xz(region: int, lx: float, lz: float, frame: Vector2i) -> Vector2:
	if region & 0x8000:
		return Vector2(lx, -lz)
	var rx := (region >> 8) & 0xff
	var ry := region & 0xff
	return Vector2(float(ry - frame.y) * 1920.0 + lx - 960.0, float(frame.x - rx) * 1920.0 + 960.0 - lz)

static func _s32(v: int) -> int:
	return v - 0x100000000 if v >= 0x80000000 else v

## The record as the snapshot World3D draws other players from: world
## coordinates in frame, the worn items by equip slot, the heading the wire
## angle gives.
static func to_snapshot(rec: Record, types: Types, frame: Vector2i) -> WorldNet.EntitySnapshot:
	var s := WorldNet.EntitySnapshot.new()
	s.character_id = rec.uid
	s.char_name = rec.name
	var at := world_xz(rec.region, rec.local_position.x, rec.local_position.z, frame)
	s.x = at.x
	s.y = rec.local_position.y
	s.z = at.y
	s.gender = CharacterNet.gender_of_model(rec.ref_id)
	s.heading = RemoteFacing.from_wire_angle(rec.angle)
	s.ref_obj_id = rec.ref_id
	s.scale = rec.scale
	s.has_model = true
	s.mount_uid = rec.mount_uid
	s.run_speed = rec.run
	# A walker (round 781): its walk speed, else 0 (it runs).
	s.walk_speed = rec.walk if rec.run_flag == 0 and rec.walk > 0.0 else 0.0
	if rec.has_dest:
		var d := world_xz(rec.dest_region, float(rec.dest_local.x), float(rec.dest_local.z), frame)
		s.has_dest = true
		s.dest = Vector3(d.x, float(rec.dest_local.y), d.y)
	elif rec.move_command & SkyRun.COMMAND_FORWARD:
		s.run_wire = rec.move_angle
	for it in rec.items:
		var slot := types.equip_slot(int(it["id"])) if types != null else -1
		if slot < 0:
			continue
		s.equipped[slot] = int(it["id"])
		if int(it["plus"]) != 0:
			s.pluses[slot] = int(it["plus"])
	# Round 789: the avatars, under the keys World3D keeps them by
	# (CharacterAppearance.AVATAR_KEY_BASE + their order in the block, OURS:
	# the record names no slot, and the client attaches them by RefItemID).
	for i in rec.avatars.size():
		var key := CharacterAppearance.AVATAR_KEY_BASE + i
		s.equipped[key] = int(rec.avatars[i]["id"])
		if int(rec.avatars[i]["plus"]) != 0:
			s.pluses[key] = int(rec.avatars[i]["plus"])
	return s

## A 0x3015 payload read as a player's: the record and its spawn-type byte.
static func decode_single_spawn(data: PackedByteArray, types: Types) -> Record:
	var r := NpcSpawnNet.Reader.new(data)
	var rec := read_record(r, types)
	if rec == null:
		return null
	rec.spawn_type = r.u8()
	return rec if r.error == "" else null

## A group's buffer (0x3017's three bytes, then the 0x3019s), read as the
## client's FUN_008a6d20 reads it, each spawn record by its class:
## {"kind": 1|2, "npcs": Array[NpcSpawnNet.Record], "users": Array[Record],
## "uids": Array[int], "error": String, "deferred": bool}. deferred is set,
## and nothing else read, when a player record comes before types.
static func read_group(buffer: PackedByteArray, types: Types) -> Dictionary:
	var out := {"kind": 0, "npcs": [], "users": [], "cos": [], "uids": [], "error": "", "deferred": false}
	var r := NpcSpawnNet.Reader.new(buffer)
	var kind := r.u8()
	var count := r.u16()
	out.kind = kind
	if kind == NpcSpawnNet.GROUP_SPAWN:
		for i in count:
			if is_player_ref(peek_ref(r)):
				if types == null:
					out.deferred = true
					return out
				var rec := read_record(r, types)
				if rec == null:
					out.error = "record %d of %d: %s" % [i, count, r.error]
					return out
				out.users.append(rec)
			elif types != null and types.cos_kind_of(peek_ref(r)) != 0:
				# Round 795: a COS (CICCos, cos_spawn.gd).
				var c := CosSpawnNet.read_record(r, types.cos_kind_of(peek_ref(r)))
				if c == null:
					out.error = "record %d of %d: %s" % [i, count, r.error]
					return out
				out.cos.append(c)
			else:
				var npc := NpcSpawnNet.read_record(r)
				if npc == null:
					out.error = "record %d of %d: %s" % [i, count, r.error]
					return out
				out.npcs.append(npc)
	elif kind == NpcSpawnNet.GROUP_DESPAWN:
		for i in count:
			var u := r.u32()
			if r.error != "":
				out.error = r.error
				return out
			out.uids.append(u)
	else:
		out.error = "group type %d" % kind
		return out
	if r.error != "":
		out.error = r.error
	elif r.pos != buffer.size():
		out.error = "%d byte(s) left after the group" % (buffer.size() - r.pos)
	return out

## The frame "rx/ry" a result names (EnterWorldResult.frame), or (-1, -1).
static func parse_frame(frame: String) -> Vector2i:
	var parts := frame.split("/")
	if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return Vector2i(-1, -1)
	return Vector2i(int(parts[0]), int(parts[1]))
