extends RefCounted
class_name NpcSpawnNet

## The retail spawn messages for NPCs (round 708), read the way sro_client.exe
## reads them -- docs/protocol/npc_spawn.md has the addresses and the byte
## table. An NPC exists on this client only because the server spawned it:
##
## - 0x3015 single spawn: FUN_008a6ca0 -> FUN_008a6bd0(stream, 1): u32
##   RefObjID, the class's body reader (CICNPC::vslot_025 0x9d46c0), then one
##   byte (FUN_009c2180, to +0xf4).
## - 0x3016 single despawn: FUN_008a6cc0, u32 unique id.
## - 0x3017 group begin (FUN_008ac0e0): u8 type, u16 count, kept in a buffer
##   the begin resets; 0x3019 group data (FUN_008ac170 -> FUN_00833380): the
##   rest of the message appended; 0x3018 group end (FUN_008ac3d0): the buffer
##   read by FUN_008a6d20 -- type 1: count records (FUN_008a6bd0(stream, 0),
##   no trailing byte), type 2: count u32 ids, each despawned.
## - OpNpcFacingUnknown 0x00B6 (OURS): the uids about to be spawned whose angle
##   is not their nest's; World3D faces those by NpcFacing.
##
## This reader takes the CICNPC record. Since round 737 the server sends the
## other players the same way, with a CICUser record (UserSpawnNet, whose
## read_group takes both by RefObjID); a record of another class would read
## wrong, so a decode error drops the group and says so.

const OP_SINGLE_SPAWN := 0x3015
const OP_SINGLE_DESPAWN := 0x3016
const OP_GROUP_BEGIN := 0x3017
const OP_GROUP_END := 0x3018
const OP_GROUP_DATA := 0x3019
const OP_FACING_UNKNOWN := 0x00b6

const GROUP_SPAWN := 1
const GROUP_DESPAWN := 2

const FLAG_NAME := 1
const FLAG_INTERACTIONS := 2
const FLAG_EXTRA := 4

class Record:
	var ref_id: int
	var uid: int
	var region: int
	var region_x: int # the region id's high byte, as NpcTableReader keys it
	var region_y: int
	var local_position: Vector3
	var angle: int
	var flags: int
	var name: String = ""
	var interactions: PackedByteArray = PackedByteArray()
	## The spawn type byte of a 0x3015 (-1 in a group).
	var spawn_type := -1
	## Whether the angle is the server's (its nest's). False for the uids an
	## OpNpcFacingUnknown named and for QA-local records.
	var has_angle := true

	## Whether `other` places the same NPC the same way (uid, RefObjID,
	## region, position, angle and its source) -- the server sends a window
	## twice around a world entry, and World3D leaves such a spawn alone.
	func same_placement(other: Record) -> bool:
		return other != null and uid == other.uid and ref_id == other.ref_id and region == other.region \
			and local_position == other.local_position and angle == other.angle and has_angle == other.has_angle

class Reader:
	var data: PackedByteArray
	var pos := 0
	var error := ""
	func _init(d: PackedByteArray, p: int = 0) -> void:
		data = d
		pos = p
	func _need(n: int) -> bool:
		if error != "":
			return false
		if pos + n > data.size():
			error = "cut short at byte %d (%d wanted, %d left)" % [pos, n, data.size() - pos]
			return false
		return true
	func u8() -> int:
		if not _need(1):
			return 0
		pos += 1
		return data[pos - 1]
	func u16() -> int:
		if not _need(2):
			return 0
		pos += 2
		return data.decode_u16(pos - 2)
	func u32() -> int:
		if not _need(4):
			return 0
		pos += 4
		return data.decode_u32(pos - 4)
	func f32() -> float:
		if not _need(4):
			return 0.0
		pos += 4
		return data.decode_float(pos - 4)
	func bytes(n: int) -> PackedByteArray:
		if not _need(n):
			return PackedByteArray()
		pos += n
		return data.slice(pos - n, pos)

## One record from r (FUN_008a6bd0's ref id, then CICNPC::vslot_025's
## readers: FUN_009c3a70 unique id, region, x/y/z, angle; FUN_008a5640(.., 1)
## the mover; FUN_009d1300's four stance bytes, three speeds and buffs;
## ICharactor::FUN_009d15a0's flags). null with r.error set on a bad record.
static func read_record(r: Reader) -> Record:
	var rec := Record.new()
	rec.ref_id = r.u32()
	if rec.ref_id == 0xffffffff or rec.ref_id == 0xfffffffe:
		# FUN_008a6bd0's -1 / -2 forms (a structure word / an extra u32): not
		# an NPC record.
		r.error = "ref id %#x is not an object id" % rec.ref_id
		return null
	rec.uid = r.u32()
	rec.region = r.u16()
	rec.region_x = (rec.region >> 8) & 0xff
	rec.region_y = rec.region & 0xff
	var x := r.f32()
	var y := r.f32()
	var z := r.f32()
	rec.local_position = Vector3(x, y, z)
	rec.angle = r.u16()
	var has_dest := r.u8()
	r.u8() # the movement type (+1)
	if has_dest != 0:
		# The destination form (u16 region, then i16 or i32 coordinates).
		var dest_region := r.u16()
		if dest_region & 0x8000:
			r.bytes(12)
		else:
			r.bytes(6)
	else:
		r.u8() # +0x14
		r.u16() # the mover's angle
	r.bytes(4) # life state, +0x273, motion state, body mode
	r.bytes(12) # walk, run, param 140
	var buffs := r.u8()
	if buffs != 0 and r.error == "":
		# A buff entry's width depends on the skill's row (FUN_009d1300); an
		# NPC never carries one.
		r.error = "a record with %d buff(s) is not an NPC's" % buffs
		return null
	rec.flags = r.u8()
	if rec.flags & FLAG_NAME:
		var n := r.u16()
		rec.name = r.bytes(n).get_string_from_ascii()
	if rec.flags & FLAG_INTERACTIONS:
		var count := r.u8()
		rec.interactions = r.bytes(count)
	if rec.flags & FLAG_EXTRA:
		r.bytes(5)
	if r.error != "":
		return null
	return rec

## A 0x3015 payload: the record and its spawn-type byte.
static func decode_single_spawn(data: PackedByteArray) -> Record:
	var r := Reader.new(data)
	var rec := read_record(r)
	if rec == null:
		return null
	rec.spawn_type = r.u8()
	return rec if r.error == "" else null

## A 0x3016 payload: the uid, or -1.
static func decode_single_despawn(data: PackedByteArray) -> int:
	return data.decode_u32(0) if data.size() >= 4 else -1

## OpNpcFacingUnknown: the uids.
static func decode_facing_unknown(data: PackedByteArray) -> Array[int]:
	var out: Array[int] = []
	var r := Reader.new(data)
	var n := r.u16()
	for i in n:
		var u := r.u32()
		if r.error != "":
			break
		out.append(u)
	return out

## The group buffer: 0x3017 starts it, 0x3019 appends, 0x3018 reads it.
class Group:
	var buffer := PackedByteArray()
	var open := false

	func begin(data: PackedByteArray) -> void:
		buffer = data.slice(0, 3) # u8 type, u16 count (FUN_008ac0e0 keeps these)
		open = true

	func append(data: PackedByteArray) -> void:
		if open:
			buffer.append_array(data)

	## Ends the group and returns its buffer (the 0x3017's three bytes, then
	## the 0x3019s), empty for a 0x3018 with no 0x3017 -- for a reader that
	## takes every class of record (round 737, UserSpawnNet.read_group).
	func take() -> PackedByteArray:
		if not open:
			return PackedByteArray()
		open = false
		var out := buffer
		buffer = PackedByteArray()
		return out

	## Ends the group: {"kind": 1|2, "records": Array[Record], "uids":
	## Array[int], "error": String}.
	func finish() -> Dictionary:
		var out := {"kind": 0, "records": [], "uids": [], "error": ""}
		if not open:
			out.error = "0x3018 with no 0x3017"
			return out
		open = false
		var r := Reader.new(buffer)
		var kind := r.u8()
		var count := r.u16()
		out.kind = kind
		if kind == GROUP_SPAWN:
			for i in count:
				var rec := NpcSpawnNet.read_record(r)
				if rec == null:
					out.error = "record %d of %d: %s" % [i, count, r.error]
					return out
				out.records.append(rec)
		elif kind == GROUP_DESPAWN:
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

## The client's heading of a record's angle (RemoteFacing.from_wire_angle,
## FUN_009c3a70 + FUN_009c40b0) -- facing (sin h, 0, -cos h) region-local.
static func heading_of(angle: int) -> float:
	return RemoteFacing.from_wire_angle(angle)

## The holder rotation (Godot rotation.y) for heading h, for an NPC holder
## under its region's terrain group (region-local frame, x east, z north) whose
## body's front is its own -Z (MonsterMotion.MODEL_FRONT; the same assembler):
## Basis(UP, a) sends -Z to (-sin a, 0, -cos a), so the facing (sin h, 0,
## -cos h) needs a = -h.
static func holder_yaw(h: float) -> float:
	return wrapf(-h, -PI, PI)

## Every NPC the server has spawned for this connection and not despawned
## (round 708). NetClient keeps it beside the connection, as it keeps
## BuffRoster: the window's first groups arrive straight after the world
## entry, while CharacterSelect is still swapping in World3D, so World3D reads
## the roster when it is ready and follows npc_spawned / npc_despawned after.
class Roster:
	## uid -> Record.
	var npcs: Dictionary = {}
	## uid -> true: named by OpNpcFacingUnknown, applied when the record comes.
	var _unfaced: Dictionary = {}
	var group := Group.new()

	func clear() -> void:
		npcs.clear()
		_unfaced.clear()
		group = Group.new()

	func facing_unknown(uids: Array[int]) -> void:
		for u in uids:
			_unfaced[u] = true

	## Keeps rec (replacing an earlier record of its uid); returns it.
	func spawn(rec: Record) -> Record:
		if _unfaced.has(rec.uid):
			rec.has_angle = false
			_unfaced.erase(rec.uid)
		npcs[rec.uid] = rec
		return rec

	## Drops uid; true when it was held.
	func despawn(uid: int) -> bool:
		_unfaced.erase(uid)
		return npcs.erase(uid)
