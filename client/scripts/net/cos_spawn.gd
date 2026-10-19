extends RefCounted
class_name CosSpawnNet

## Round 795: the spawn record of a COS -- a ride horse, a transport, a
## growth, fellow or ability pet, a guild soldier -- as sro_client.exe reads
## it (docs/protocol/pets.md, "The COS spawn record"). Every 1/2/3/x object
## is one class, CICCos (class link 0xeef6f0, vtable 0xde211c; READ
## IGIDObject::FUN_009c1fa0 -> FUN_00504f20); its slot 25 (0x9c60b0) reads,
## after FUN_008a6bd0's RefObjID:
##
## - the common body, the NPC's (FUN_009c3a70: unique id, region, x/y/z,
##   angle; FUN_008a5640(.., 1): the mover; 0x9d1300: four stance bytes,
##   three speeds, the buffs);
## - CICCos::vslot_034 (0x9c6a40): u8 flags (bit 0 a name, bit 1 the
##   interaction ids; no bit-2 block);
## - by the RefObj's TypeID4 (READ 0x9c6c4b..0x9c63e5):
##     3, 4 (pets)             u16 + bytes, the pet's name
##     2, 3, 4, 5, 6           u16 + bytes, the owner's name
##     2, 3, 4, 5              u8, the owner's job state
##     2, 3, 5                 u8, the owner's PvP state
##     5 (guild soldier)       u32, a guild id
##     anything but 1          u32, the owner's unique id
##   so a ride horse (TypeID4 1) ends at the flags byte; its rider names it
##   from its own record (PC field 24 and its u32).
## - 0x3015 only: the spawn-type byte (slot 26; 1 on a pet plays the summon
##   effect and snd_cos_summon).
##
## Which records are a COS's: FUN_008a6bd0 asks the RefObjID's TypeID. This
## reader asks World3D's COS table (CosTable: RefObjID -> TypeID4), handed
## over with the item table.

const KIND_RIDE := 1
const KIND_TRANSPORT := 2
const KIND_GROWTH := 3
const KIND_ABILITY := 4
const KIND_SOLDIER := 5

class Record:
	var ref_id: int
	## The RefObj's TypeID4 (KIND_*).
	var kind: int
	var uid: int
	var region: int
	var local_position: Vector3
	var angle: int
	var has_dest := false
	var run_flag := 1
	var dest_region: int
	var dest_local := Vector3i.ZERO
	var move_command := 0
	var move_angle := 0
	var life: int
	var motion: int
	var walk: float
	var run: float
	var flags: int
	var name := ""
	var owner_name := ""
	var owner_job := 4
	var owner_pvp := 0
	var guild_id := 0
	## The owner's unique id; 0 for a ride horse (its rider's record names it).
	var owner_uid := 0
	var spawn_type := -1

	func is_pet() -> bool:
		return kind == KIND_GROWTH or kind == KIND_ABILITY

## One record from r, the RefObjID's TypeID4 given (kind). null with r.error
## set on a bad record.
static func read_record(r: NpcSpawnNet.Reader, kind: int) -> Record:
	var rec := Record.new()
	rec.ref_id = r.u32()
	rec.kind = kind
	rec.uid = r.u32()
	rec.region = r.u16()
	var x := r.f32()
	var y := r.f32()
	var z := r.f32()
	rec.local_position = Vector3(x, y, z)
	rec.angle = r.u16()
	var has_dest := r.u8()
	rec.run_flag = r.u8()
	if has_dest != 0:
		rec.has_dest = true
		rec.dest_region = r.u16()
		if rec.dest_region & 0x8000:
			rec.dest_local = Vector3i(UserSpawnNet._s32(r.u32()), UserSpawnNet._s32(r.u32()), UserSpawnNet._s32(r.u32()))
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
	r.u8() # body mode
	rec.walk = r.f32()
	rec.run = r.f32()
	r.f32() # param 140
	if r.u8() != 0 and r.error == "":
		# A buff entry's width hangs on the skill's row (0x9d1300); OpenSRO's
		# server sends a COS's buffs as their own messages.
		r.error = "buffs in a COS record"
		return null
	rec.flags = r.u8()
	if rec.flags & NpcSpawnNet.FLAG_NAME:
		rec.name = r.bytes(r.u16()).get_string_from_utf8()
	if rec.flags & NpcSpawnNet.FLAG_INTERACTIONS:
		r.bytes(r.u8())
	if kind == KIND_GROWTH or kind == KIND_ABILITY:
		rec.name = r.bytes(r.u16()).get_string_from_utf8()
	if kind >= KIND_TRANSPORT and kind <= 6:
		rec.owner_name = r.bytes(r.u16()).get_string_from_utf8()
	if kind >= KIND_TRANSPORT and kind <= KIND_SOLDIER:
		rec.owner_job = r.u8()
	if kind == KIND_TRANSPORT or kind == KIND_GROWTH or kind == KIND_SOLDIER:
		rec.owner_pvp = r.u8()
	if kind == KIND_SOLDIER:
		rec.guild_id = r.u32()
	if kind != KIND_RIDE:
		rec.owner_uid = r.u32()
	if r.error != "":
		return null
	return rec

## A 0x3015 payload read as a COS's.
static func decode_single_spawn(data: PackedByteArray, kind: int) -> Record:
	var r := NpcSpawnNet.Reader.new(data)
	var rec := read_record(r, kind)
	if rec == null:
		return null
	rec.spawn_type = r.u8()
	return rec if r.error == "" else null
