extends RefCounted
class_name DofReader

## A dungeon (round 773): Data.pk2's `.dof` ("JMXVDOF 0101") -- the rooms
## (blocks), each an ordinary `.bsr` placed at a position and yaw in dungeon
## space, with its own objects and lights -- and `Dungeon\dungeoninfo.txt`,
## which names the `.dof` of each dungeon region (id | 0x8000).
##
## READ (sro_client.exe; docs/protocol/dungeon.md): the header check
## DungeonObj::FUN_00c209a0, the body ResourceMgr::FUN_00c24b90, each block
## RTDunBlock::FUN_00c6f1d0 (and the navmesh's side, RTNavMeshDungeon::
## FUN_0043e8c0 / FUN_0043d220 / FUN_0043dc40); dungeoninfo by
## MapLoader::FUN_00426fe0 (enable flag, iRid 0..0x7FFF, the path; the
## region id is iRid | 0x8000). MEASURED: this layout walks 41 of the 42 real
## files with every section ending exactly on the next section's pointer
## (the 42nd, dunhwang_cv1.dof, is referenced by nothing and truncated).
## parse() makes the same check and refuses a file that fails it.

const MAGIC := "JMXVDOF 0101"
## The dungeon region flag (bit 15 of a region id).
const DUNGEON_FLAG := 0x8000

class Obj:
	var name: String
	## The object's `.bsr`.
	var path: String
	## Dungeon space.
	var position := Vector3.ZERO
	## Euler angles, radians (MEASURED: y is 0, pi/2, pi or 3pi/2; x, z 0).
	var rotation := Vector3.ZERO
	var scale := Vector3.ONE
	## Bit 2: an obstacle cylinder of `radius` for the navmesh (READ,
	## CRTNavMeshDungeon::FUN_0043e100); bit 4: an extra u32 follows.
	var flags: int
	var index: int
	var radius: float

class Light:
	var name: String
	## The 15 floats: position (3), then three colours and three
	## attenuation-like values (their meaning INFERRED).
	var values := PackedFloat32Array()

	func position() -> Vector3:
		return Vector3(values[0], values[1], values[2]) if values.size() >= 3 else Vector3.ZERO

class Block:
	## The room's `.bsr` (res\dun\...).
	var path: String
	var name: String
	## Dungeon space.
	var position := Vector3.ZERO
	## Radians.
	var yaw: float
	## Bit 0: an entrance block (READ: CRTNavMeshDungeon::vslot_009 maps it
	## to m_sEnterPos).
	var flags: int
	## Block-local bounds.
	var aabb := AABB()
	## The block's light (ARGB, block +0x6c): the dungeon draw's ambient
	## (READ, Map::FUN_00a255c0 via CRTDunBlock::vslot_006).
	var color_a: int
	## The fog's colour (ARGB) and (start, end, density): the block's +0x70
	## record, set as D3DRS_FOGCOLOR / FOGSTART / FOGEND / FOGDENSITY (READ,
	## CObjRendererVS::FUN_00c31450 via vslot_005).
	var color_b: int
	var fog := Vector3.ZERO
	var room_index := -1
	var floor_index := -1
	## The blocks whose outline edges join this one's (READ, +0x108).
	var neighbours := PackedInt32Array()
	## A superset of the neighbours (INFERRED: the visible set, +0x118).
	var visible := PackedInt32Array()
	var objects: Array = []
	var lights: Array = []

	## Block-local to dungeon space (READ FUN_0043d220: m00 = cos, m02 = sin,
	## m20 = -sin, m22 = cos, translation = position; a row-vector matrix, so
	## local (x, z) -> (x cos - z sin + px, x sin + z cos + pz)).
	func to_dungeon(local: Vector3) -> Vector3:
		var c := cos(yaw)
		var s := sin(yaw)
		return Vector3(local.x * c - local.z * s + position.x, local.y + position.y,
			local.x * s + local.z * c + position.z)

	## The dungeon-space point back to the block's local frame.
	func to_local(p: Vector3) -> Vector3:
		var dx := p.x - position.x
		var dz := p.z - position.z
		var c := cos(yaw)
		var s := sin(yaw)
		return Vector3(dx * c + dz * s, p.y - position.y, -dx * s + dz * c)

	## Whether a dungeon-space point lies in the block's bounds.
	func contains(p: Vector3, margin: float = 0.0) -> bool:
		return aabb.grow(margin).has_point(to_local(p))

class Dof:
	## The dungeon's bounds, dungeon space.
	var aabb := AABB()
	var blocks: Array = []
	## The P1 links, a list per block (READ; they differ from the
	## neighbours, why is OPEN).
	var links: Array = []
	var room_names := PackedStringArray()
	var floor_names := PackedStringArray()

	## The block containing a dungeon-space point (the nearest centre when
	## several do), or -1. OURS: the file's own grid (P2) is not used.
	func block_at(p: Vector3, margin: float = 0.0) -> int:
		var best := -1
		var best_d := INF
		for i in blocks.size():
			var b: Block = blocks[i]
			if not b.contains(p, margin):
				continue
			var d := b.to_dungeon(b.aabb.get_center()).distance_squared_to(p)
			if d < best_d:
				best_d = d
				best = i
		return best

	## The floor's name key of a block (textzonename keys, e.g.
	## DH_A01_FLOOR01), or "".
	func floor_name(block: int) -> String:
		if block < 0 or block >= blocks.size():
			return ""
		var f: int = (blocks[block] as Block).floor_index
		return floor_names[f] if f >= 0 and f < floor_names.size() else ""

class _R:
	var b: PackedByteArray
	var o := 0
	var bad := false

	func _init(data: PackedByteArray, at: int = 0) -> void:
		b = data
		o = at

	func _need(n: int) -> bool:
		if bad or o + n > b.size():
			bad = true
			return false
		return true

	func u8() -> int:
		if not _need(1):
			return 0
		o += 1
		return b[o - 1]

	func u32() -> int:
		if not _need(4):
			return 0
		o += 4
		return b.decode_u32(o - 4)

	func f() -> float:
		if not _need(4):
			return 0.0
		o += 4
		return b.decode_float(o - 4)

	func v3() -> Vector3:
		return Vector3(f(), f(), f())

	## A u32-counted byte string (paths ASCII; some names CP949, kept as
	## Latin-1 code points so they stay unique keys).
	func s() -> String:
		var n := u32()
		if n > 4096 or not _need(n):
			bad = true
			return ""
		var raw := b.slice(o, o + n)
		o += n
		var out := ""
		for c in raw:
			out += char(c)
		return out

	func ints() -> PackedInt32Array:
		var n := u32()
		var out := PackedInt32Array()
		if n > 100000:
			bad = true
			return out
		for i in n:
			out.append(u32())
		return out

## Parses a `.dof`; null when it is not one or a section does not end where
## the next begins.
static func parse(data: PackedByteArray) -> Dof:
	if data.size() < 0x5c or data.slice(0, 12).get_string_from_ascii() != MAGIC:
		return null
	var p := PackedInt32Array()
	for i in 8:
		p.append(data.decode_u32(12 + 4 * i))
	var d := Dof.new()
	var r := _R.new(data, p[7])
	var lo := r.v3()
	var hi := r.v3()
	d.aabb = AABB(lo, hi - lo)
	r.o = p[0]
	var n := r.u32()
	if n > 10000:
		return null
	for i in n:
		var k := Block.new()
		k.path = r.s()
		k.name = r.s()
		r.u32()
		k.position = r.v3()
		k.yaw = r.f()
		k.flags = r.u32()
		var blo := r.v3()
		var bhi := r.v3()
		k.aabb = AABB(blo, bhi - blo)
		k.color_a = r.u32()
		k.color_b = r.u32()
		k.fog = r.v3()
		if r.u8() != 0:
			for j in 4:
				r.f()
		if r.u8() != 0:
			for j in 7:
				r.f()
		r.s() # the label, empty in every file measured
		k.room_index = _signed(r.u32())
		k.floor_index = _signed(r.u32())
		k.neighbours = r.ints()
		k.visible = r.ints()
		var no := r.u32()
		r.u32() # the obstacle count (READ: asserted equal to the flag-2 objects)
		if no > 100000:
			return null
		for j in no:
			var ob := Obj.new()
			ob.name = r.s()
			ob.path = r.s()
			ob.position = r.v3()
			ob.rotation = r.v3()
			ob.scale = r.v3()
			ob.flags = r.u32()
			ob.index = r.u32()
			ob.radius = r.f()
			if ob.flags & 4:
				r.u32()
			k.objects.append(ob)
		var nl := r.u32()
		if nl > 100000:
			return null
		for j in nl:
			var li := Light.new()
			li.name = r.s()
			for m in 15:
				li.values.append(r.f())
			k.lights.append(li)
		if r.bad:
			return null
		d.blocks.append(k)
	# Each section must end where the next begins (the reader's own check).
	if not _ends_at(r.o, p, 0, data.size()):
		return null
	if p[1] != 0:
		r.o = p[1]
		var nb := r.u32()
		for i in nb:
			d.links.append(r.ints())
		if r.bad or not _ends_at(r.o, p, 1, data.size()):
			return null
	if p[4] != 0:
		r.o = p[4]
		for t in 2:
			var cnt := r.u32()
			var names := PackedStringArray()
			for i in cnt:
				names.append(r.s())
			if t == 0:
				d.room_names = names
			else:
				d.floor_names = names
		if r.bad:
			return null
	return d

static func _signed(v: int) -> int:
	return v - 0x100000000 if v >= 0x80000000 else v

## Whether offset `at` is where the section after section `i` begins (the
## next non-zero pointer above it, or EOF).
static func _ends_at(at: int, p: PackedInt32Array, i: int, size: int) -> bool:
	var next := size
	for k in [0, 1, 2, 3, 4]:
		if p[k] > p[i] and p[k] < next:
			next = p[k]
	return at == next

## dungeoninfo.txt: {region id (iRid | 0x8000): `.dof` path} for the enabled
## rows (READ, MapLoader::FUN_00426fe0: enable, iRid, the quoted path).
static func parse_info(data: PackedByteArray) -> Dictionary:
	var text := ""
	if data.size() >= 2 and data[0] == 0xFF and data[1] == 0xFE:
		text = TextDecode.utf16(data.slice(2))
	else:
		text = data.get_string_from_ascii()
	var out := {}
	for line in text.replace("\r", "").split("\n"):
		var cols := line.split("\t")
		if cols.size() < 3 or not cols[0].strip_edges().is_valid_int() or not cols[1].strip_edges().is_valid_int():
			continue
		if int(cols[0]) == 0:
			continue
		var rid := int(cols[1])
		if rid < 0 or rid > 0x7FFF:
			continue
		out[rid | DUNGEON_FLAG] = cols[2].strip_edges().trim_prefix("\"").trim_suffix("\"")
	return out

## Whether a region id is a dungeon's (bit 15; a signed short below zero).
static func is_dungeon_region(region: int) -> bool:
	return region < 0 or (region & DUNGEON_FLAG) != 0
