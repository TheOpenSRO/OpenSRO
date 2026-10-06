extends RefCounted
class_name DestMoveNet

## Moving by destination, as retail does (round 749; docs/protocol/opcodes/
## movement.md, "0xB021 in full"; docs/rounds/r749.md). The server's half is
## server/internal/session/destmove.go.
##
## READ, both binaries (round 737, re-read in round 749):
##   - The click sends one 0x7021 per accepted click (FUN_009ec570 ->
##     0x9ec240 -> 0x9ec080): `01 | region u16 | x i16 | y i16 | z i16`, the
##     raw region-local coordinates TRUNCATED (ftol; nothing scales them by
##     10). A sky click sends the heading form `00 | command u8 | angle u16`
##     (FUN_009ebec0, command 1).
##   - The server answers an accepted move with 0xB021 to the 3 x 3 blocks, the
##     mover included: `u32 uid | the movement | u8 flag | (flag 1) source
##     region u16, x * 10 u16, y f32, z * 10 u16` (NetProcessInNavAndSkill::
##     FUN_008a5750 reads it; the x/z width is 4 when the LOCAL player's region
##     has bit 15, a dungeon, which OpenSRO serves none of).
##   - A stop the server sends is 0xB023: `u32 uid, u16 region, f32 x, f32 y,
##     f32 z, u16 angle` (FUN_008a4f80 reads 4, 2 and 0xe bytes and snaps the
##     object there, FUN_009e00f0 / FUN_009e11e0).
## Both are in the client's dispatch table (0xb021 -> FUN_008a5750, 0xb023
## -> FUN_008a4f80).

const OP_MOVEMENT_REQUEST := 0x7021  # client -> server
const OP_MOVEMENT_ECHO := 0xB021     # server -> the 3 x 3, the mover included
const OP_MOVEMENT_STOP := 0xB023     # server -> the 3 x 3

const KIND_HEADING := 0
const KIND_DESTINATION := 1
const REGION_DUNGEON_BIT := 0x8000
## The region span: local coordinates run [0, 1920).
const REGION_SPAN := 1920.0

## One 0xB021, decoded. Coordinates are region-local; `World` adds the world
## ones (NetClient.resolve_echo).
class Echo:
	var uid: int
	var kind: int
	## The destination form: its region and the three i16 (sign-extended,
	## 0x8a5640).
	var region: int
	var local := Vector3i.ZERO
	## The heading form: the command byte and the u16 wire angle.
	var command: int
	var angle: int
	var has_source: bool
	var source_region: int
	## The source's local x and z (the wire's tenths divided by 10.0, 0xe1b840)
	## and its y.
	var source_local := Vector3.ZERO
	var error := ""
	## Filled by NetClient from its frame: the world points.
	var dest_world := Vector3.ZERO
	var source_world := Vector3.ZERO

## One 0xB023, decoded.
class Stop:
	var uid: int
	var region: int
	var local := Vector3.ZERO
	var angle: int
	var error := ""
	var world := Vector3.ZERO

## The destination form of 0x7021 for region-local (lx, ly, lz), truncated
## as the client's ftol does (int() truncates toward zero).
static func encode_destination(region: int, lx: float, ly: float, lz: float) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(9)
	out[0] = KIND_DESTINATION
	out.encode_u16(1, region & 0xffff)
	out.encode_s16(3, clampi(int(lx), -32768, 32767))
	out.encode_s16(5, clampi(int(ly), -32768, 32767))
	out.encode_s16(7, clampi(int(lz), -32768, 32767))
	return out

## The heading form of 0x7021 (FUN_009ebec0): kind 0, the command byte, the
## u16 wire angle (SkyRun.wire_angle).
static func encode_heading(command: int, angle: int) -> PackedByteArray:
	var out := PackedByteArray([KIND_HEADING, command & 0xff, 0, 0])
	out.encode_u16(2, angle & 0xffff)
	return out

## Reads a 0xB021 payload.
static func decode_echo(data: PackedByteArray) -> Echo:
	var e := Echo.new()
	if data.size() < 5:
		e.error = "0xB021 of %d bytes" % data.size()
		return e
	e.uid = data.decode_u32(0)
	e.kind = data[4]
	var at := 5
	if e.kind == KIND_HEADING:
		if data.size() < at + 3:
			e.error = "short heading form"
			return e
		e.command = data[at]
		e.angle = data.decode_u16(at + 1)
		at += 3
	else:
		if data.size() < at + 2:
			e.error = "short destination"
			return e
		e.region = data.decode_u16(at)
		at += 2
		if e.region & REGION_DUNGEON_BIT:
			if data.size() < at + 12:
				e.error = "short dungeon destination"
				return e
			e.local = Vector3i(data.decode_s32(at), data.decode_s32(at + 4), data.decode_s32(at + 8))
			at += 12
		else:
			if data.size() < at + 6:
				e.error = "short destination"
				return e
			e.local = Vector3i(data.decode_s16(at), data.decode_s16(at + 2), data.decode_s16(at + 4))
			at += 6
	if data.size() < at + 1:
		e.error = "no flag"
		return e
	e.has_source = data[at] == 1
	at += 1
	if e.has_source:
		if data.size() < at + 10:
			e.error = "short source"
			return e
		e.source_region = data.decode_u16(at)
		e.source_local = Vector3(float(data.decode_u16(at + 2)) / 10.0, data.decode_float(at + 4), float(data.decode_u16(at + 8)) / 10.0)
	return e

## Reads a 0xB023 payload.
static func decode_stop(data: PackedByteArray) -> Stop:
	var s := Stop.new()
	if data.size() < 20:
		s.error = "0xB023 of %d bytes" % data.size()
		return s
	s.uid = data.decode_u32(0)
	s.region = data.decode_u16(4)
	s.local = Vector3(data.decode_float(6), data.decode_float(10), data.decode_float(14))
	s.angle = data.decode_u16(18)
	return s

## The region and the local x, z of world (x, z) in the frame centred on
## region (fx, fy): the server's worldmap.FromWorld (region y drives world X,
## region x drives world Z, z mirrored), the inverse of UserSpawnNet.world_xz.
## {"region": int, "lx": float, "lz": float}.
static func local_of_world(x: float, z: float, frame: Vector2i) -> Dictionary:
	var half := REGION_SPAN / 2.0
	var ky := int(floor((x + half) / REGION_SPAN))
	var ry := frame.y + ky
	var lx := x + half - float(ky) * REGION_SPAN
	var kx := int(ceil((z - half) / REGION_SPAN))
	var rx := frame.x - kx
	var lz := float(kx) * REGION_SPAN + half - z
	return {"region": ((rx & 0xff) << 8) | (ry & 0xff), "lx": lx, "lz": lz}

## World (x, z) of region-local (lx, lz) in frame: UserSpawnNet.world_xz.
static func world_of_local(region: int, lx: float, lz: float, frame: Vector2i) -> Vector2:
	return UserSpawnNet.world_xz(region, lx, lz, frame)
