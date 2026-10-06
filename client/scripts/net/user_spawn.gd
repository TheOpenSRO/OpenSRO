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
	var uid: int
	var region: int
	var local_position: Vector3
	var angle: int
	var life: int
	var motion: int
	var body_mode: int
	var walk: float
	var run: float
	var name: String
	var job_state: int = JOB_STATE_NONE
	## The 0x3015's spawn-type byte (-1 in a group).
	var spawn_type := -1

## The item table the reader asks (World3D's own: RefItemID ->
## ItemTableReader.Item).
class Types:
	var rows: Dictionary

	func _init(r: Dictionary) -> void:
		rows = r

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
		var s := CharacterAppearance.visual_slot(type_ids(id))
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
## destination, buffs, a ride, a stall: their widths depend on more than
## this reader models).
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
	r.u8() # avatar storage size
	if r.u8() != 0 and r.error == "":
		r.error = "avatar items in a player record"
		return null
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
	if r.u8() != 0 and r.error == "":
		r.error = "a destination in a player record"
		return null
	r.u8() # run flag
	r.u8() # source byte
	r.u16() # the mover's angle
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
	r.u8() # job type
	r.u8() # job level
	r.u8() # PvP state
	var ride := r.u8()
	r.u8() # battle state
	if ride == 1 and r.error == "":
		r.error = "a ride in a player record"
		return null
	r.u8() # teleport state
	var interact := r.u8()
	r.u8() # trade rank
	r.bytes(r.u16()) # guild name
	rec.job_state = types.job_state(rec.items) if types != null else JOB_STATE_NONE
	if rec.job_state == JOB_STATE_NONE:
		r.u32() # guild id
		r.bytes(r.u16()) # member nickname
		r.bytes(12) # three u32
		r.u8() # membership
		r.u8() # fortress role
	if interact == 4 and r.error == "":
		r.error = "a stall in a player record"
		return null
	r.u8() # timer byte
	r.u8() # team byte
	if r.error != "":
		return null
	return rec

## World (x, z) of region-local (lx, lz) in the frame centred on region
## (fx, fy): the server's worldmap.ToWorld, and World3D.region_local_to_world
## (region y drives world X, region x drives world Z, z mirrored).
static func world_xz(region: int, lx: float, lz: float, frame: Vector2i) -> Vector2:
	var rx := (region >> 8) & 0xff
	var ry := region & 0xff
	return Vector2(float(ry - frame.y) * 1920.0 + lx - 960.0, float(frame.x - rx) * 1920.0 + 960.0 - lz)

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
	for it in rec.items:
		var slot := types.equip_slot(int(it["id"])) if types != null else -1
		if slot < 0:
			continue
		s.equipped[slot] = int(it["id"])
		if int(it["plus"]) != 0:
			s.pluses[slot] = int(it["plus"])
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
	var out := {"kind": 0, "npcs": [], "users": [], "uids": [], "error": "", "deferred": false}
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
