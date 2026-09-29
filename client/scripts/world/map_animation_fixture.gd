extends RefCounted

## The synthetic animated map object map_animation_test.gd (round 645) and
## map_animation_share_test.gd (round 647) build their trees from: a type-4
## `.bsr`, a two-bone `.bsk`, a `.ban` and a skinned `.bms`, served from
## memory -- never real game data (docs/LEGAL.md). Reached by preload(), not
## by a class_name, so a suite copied onto an older tree still runs.

static func u32(buf: PackedByteArray, v: int) -> void:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_u32(0, v & 0xFFFFFFFF)
	buf.append_array(b)

static func f32(buf: PackedByteArray, v: float) -> void:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_float(0, v)
	buf.append_array(b)

static func lp(buf: PackedByteArray, s: String) -> void:
	var sb := s.to_ascii_buffer()
	u32(buf, sb.size())
	buf.append_array(sb)

## A type-4 nature `.bsr` through the section table, the way a swaying tree
## is written (round 625): the 0x2C flag word with bit 0 and a word after
## each mesh path, a skeleton, animations and the `default` group's
## `entries` ([action type, animation index] pairs).
static func build_bsr(meshes: Array, anims: Array, skel: String, entries: Array) -> PackedByteArray:
	var buf := PackedByteArray()
	buf.resize(BsrReader.PREAMBLE_END)
	var magic := BsrReader.MAGIC.to_ascii_buffer()
	for i in range(magic.size()):
		buf[i] = magic[i]
	buf.encode_u32(BsrReader.OFF_TYPE, (2 << 16) | BsrReader.TYPE_NATURE)
	buf.encode_u32(0x2C, 1)
	lp(buf, "tre_synth")
	var pad := PackedByteArray()
	pad.resize(112)
	buf.append_array(pad)
	# One material, never shipped: the pieces load untextured (a missing
	# .bmt is reported, not fatal), which is all this suite looks at.
	buf.encode_u32(BsrReader.OFF_PTR_MATERIAL, buf.size())
	u32(buf, 1)
	u32(buf, 0)
	lp(buf, "prim\\sway.bmt")
	buf.encode_u32(BsrReader.OFF_PTR_MESH, buf.size())
	u32(buf, meshes.size())
	for m in meshes:
		lp(buf, m)
		u32(buf, 1)
	buf.encode_u32(BsrReader.OFF_PTR_ANIMATION, buf.size())
	u32(buf, 4096)
	u32(buf, 0)
	u32(buf, anims.size())
	for a in anims:
		lp(buf, a)
	buf.encode_u32(BsrReader.OFF_PTR_SKELETON, buf.size())
	u32(buf, 1 if skel != "" else 0)
	if skel != "":
		lp(buf, skel)
		lp(buf, "")
	buf.encode_u32(BsrReader.OFF_PTR_MESH_GROUP, buf.size())
	u32(buf, 1)
	lp(buf, "default")
	u32(buf, meshes.size())
	for i in range(meshes.size()):
		u32(buf, i)
	buf.encode_u32(BsrReader.OFF_PTR_ANIMATION_GROUP, buf.size())
	u32(buf, 1 if not entries.is_empty() else 0)
	if not entries.is_empty():
		lp(buf, "default")
		u32(buf, entries.size())
		for e in entries:
			u32(buf, e[0])
			u32(buf, e[1])
			u32(buf, 0) # no events
			u32(buf, 2) # two walk points, as every real entry
			for v in [0.0, 0.0, 0.0, 1.0]:
				f32(buf, v)
			f32(buf, 1.0)
	buf.encode_u32(BsrReader.OFF_PTR_SOUND, buf.size())
	u32(buf, 0)
	u32(buf, 0)
	return buf

## A `.bsk`: the root, BoneB under it and BoneC one unit up under BoneB,
## all with an identity rotation.
static func build_bsk() -> PackedByteArray:
	var buf := PackedByteArray()
	buf.append_array(BskReader.MAGIC.to_ascii_buffer())
	u32(buf, 0)
	buf.append(0)
	lp(buf, "[root]")
	var root := PackedByteArray()
	root.resize(BskReader.ROOT_TRANSFORM_LEN)
	root.encode_float(0x10, 1.0) # w of the rotation at 0x04
	buf.append_array(root)
	for bone in [["BoneB", "[root]", Vector3.ZERO], ["BoneC", "BoneB", Vector3(0, 1, 0)]]:
		lp(buf, bone[0])
		lp(buf, bone[0])
		lp(buf, bone[1])
		var t := PackedByteArray()
		t.resize(BskReader.BONE_TRANSFORM_LEN)
		t.encode_float(0x0c, 1.0) # w
		t.encode_float(0x10, bone[2].x)
		t.encode_float(0x14, bone[2].y)
		t.encode_float(0x18, bone[2].z)
		buf.append_array(t)
	var trailer := PackedByteArray()
	trailer.resize(8)
	buf.append_array(trailer)
	return buf

## A `.ban` of `duration` ms keyed at 0, duration/2, duration: BoneB turns
## about Y (0, 90, 0 degrees) and BoneC holds one pose throughout.
static func build_ban(duration: int, cyclic: bool) -> PackedByteArray:
	var buf := PackedByteArray()
	buf.append_array(BanReader.MAGIC.to_ascii_buffer())
	u32(buf, 0)
	u32(buf, 0)
	lp(buf, "synth_sway")
	u32(buf, duration)
	u32(buf, 30)
	u32(buf, 1 if cyclic else 0)
	u32(buf, 3)
	for t in [0, duration / 2, duration]:
		u32(buf, t)
	u32(buf, 2)
	var turn := Quaternion(Vector3.UP, PI / 2.0)
	var held := Quaternion(Vector3.RIGHT, 0.25)
	for bone in [["BoneB", [Quaternion.IDENTITY, turn, Quaternion.IDENTITY], Vector3.ZERO],
			["BoneC", [held, held, held], Vector3(0, 1, 0)]]:
		lp(buf, bone[0])
		u32(buf, 3)
		for q in bone[1]:
			for v in [q.x, q.y, q.z, q.w, bone[2].x, bone[2].y, bone[2].z]:
				f32(buf, v)
	return buf

## A skinned `.bms` triangle weighted to BoneB and BoneC (the skin section
## as bms_reader_test.gd writes it).
static func build_bms() -> PackedByteArray:
	var buf := PackedByteArray()
	buf.resize(BmsReader.PREAMBLE_END)
	var magic := BmsReader.MAGIC.to_ascii_buffer()
	for i in range(magic.size()):
		buf[i] = magic[i]
	lp(buf, "leaf")
	lp(buf, "leaf")
	u32(buf, 1)
	u32(buf, 3)
	for p in [Vector3(0, 0, 0), Vector3(1, 1, 0), Vector3(0, 2, 1)]:
		var rec := PackedByteArray()
		rec.resize(44)
		rec.encode_float(0, p.x)
		rec.encode_float(4, p.y)
		rec.encode_float(8, p.z)
		rec.encode_float(0x10, 1.0)
		rec.encode_u32(0x24, 0xFFFFFFFF)
		buf.append_array(rec)
	buf.encode_u32(BmsReader.HEADER_PTRS_BASE, buf.size())
	u32(buf, 2)
	lp(buf, "BoneB")
	lp(buf, "BoneC")
	buf.append_array(PackedByteArray([0, 0xFF, 0xFF, BmsReader.NO_BONE, 0, 0,
		0, 253, 127, 1, 253, 127,
		1, 0xFF, 0xFF, BmsReader.NO_BONE, 0, 0]))
	buf.encode_u32(BmsReader.HEADER_PTRS_BASE + 4, buf.size())
	u32(buf, 1)
	buf.append_array(PackedByteArray([0, 0, 1, 0, 2, 0]))
	buf.encode_u32(BmsReader.HEADER_PTRS_BASE + 16, buf.size())
	for v in [0.0, 0.0, 0.0, 1.0, 2.0, 1.0]:
		f32(buf, v)
	return buf

## A Data.pk2 stand-in serving the files from memory (hud_buff_icon_test.gd's
## StubMedia shape).
class StubArchive extends Pk2Reader:
	var tree := {}
	var files := {}
	var dirs := {}
	func add(path: String, data: PackedByteArray) -> void:
		var parts := path.split("\\")
		var at := ""
		for i in parts.size():
			if not tree.has(at):
				var none: Array[Pk2Reader.Entry] = []
				tree[at] = none
			var name := parts[i]
			var next := name if at == "" else at + "\\" + name
			var found: Pk2Reader.Entry = null
			for e in tree[at]:
				if e.name == name:
					found = e
			if found == null:
				found = Pk2Reader.Entry.new()
				found.name = name
				found.is_dir = i < parts.size() - 1
				tree[at].append(found)
				if found.is_dir:
					dirs[found] = next
				else:
					files[found] = data
					found.size = data.size()
			at = next
	func read_dir() -> Array[Pk2Reader.Entry]:
		var none: Array[Pk2Reader.Entry] = []
		return tree.get("", none)
	func read_dir_at(dir: Pk2Reader.Entry) -> Array[Pk2Reader.Entry]:
		var none: Array[Pk2Reader.Entry] = []
		return tree.get(dirs.get(dir, "?"), none)
	func read_file(file: Pk2Reader.Entry) -> PackedByteArray:
		return files.get(file, PackedByteArray())

static func archive() -> StubArchive:
	var a := StubArchive.new()
	a.add("res\\sway.bsr", build_bsr(["prim\\leaf.bms"], ["prim\\sway.ban"], "prim\\sway.bsk", [[0, 0]]))
	a.add("res\\sway_once.bsr", build_bsr(["prim\\leaf.bms"], ["prim\\once.ban"], "prim\\sway.bsk", [[0, 0]]))
	# Only a type-60 entry, as rok_key03_01 and euro_esteuro_viking20 carry:
	# the map asks for type 0 and nothing else (READ, AniMixer::FUN_00c551a0).
	a.add("res\\type60.bsr", build_bsr(["prim\\leaf.bms"], ["prim\\sway.ban"], "prim\\sway.bsk", [[60, 0]]))
	# A skeleton-less building: still, as ever.
	a.add("res\\still.bsr", build_bsr(["prim\\leaf.bms"], [], "", []))
	a.add("prim\\leaf.bms", build_bms())
	a.add("prim\\sway.bsk", build_bsk())
	a.add("prim\\sway.ban", build_ban(2000, true))
	a.add("prim\\once.ban", build_ban(2000, false))
	return a
