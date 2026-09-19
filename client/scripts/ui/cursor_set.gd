extends RefCounted
class_name CursorSet

## The game's mouse cursors, read out of the player's own `sro_client.exe`.
##
## The original draws no cursor art from the archives: `Media.pk2` holds a
## single `cursor\cursor_normal1.tga`, and the client hides the system cursor
## (`SetCursor(NULL)`) and sets Win32 *resource* cursors by id --
## `LoadCursorA(hInstance, MAKEINTRESOURCE(id))` in the cursor manager at
## `0x00ba6260`, fed by `SetHoverCursor` (`0x00777ec0`) from the mouse-move
## handler `CGInterface::vslot_005` (`0x00789820`). That handler picks the
## object under the mouse and chooses the id by the object's class:
##
##   default / nothing hostile        0x95   (arrow, hotspot 2,1)
##   CICMonster, hostile CICUser/Guard 0x97  (attack)
##   CICNPC                           0x98   (talk, hotspot 2,26)
##   CIItem on the ground             0x99   (pick up; 0x9a with a modifier)
##   CITeleportGate                   0xa1
##   CICUser / CICCos with Alt held   0xa0
##
## So the art lives in the exe's `.rsrc` section as RT_GROUP_CURSOR (type 12)
## groups over RT_CURSOR (type 1) images: 17 groups, ids 0x95..0xaf, each a
## 32x32 8-bit DIB with an AND mask and a real hotspot (the first two WORDs
## of the RT_CURSOR data). Nothing here is extracted or shipped: the exe sits
## beside the archives the client already opens, and is parsed the same way.

const ID_NORMAL := 0x95
const ID_ATTACK := 0x97
const ID_TALK := 0x98
const ID_PICKUP := 0x99
const ID_GATE := 0xa1

const RT_CURSOR := 1
const RT_GROUP_CURSOR := 12

## One decoded cursor: the RGBA image and the hotspot the file gives it.
class Cursor:
	var id: int
	var image: Image
	var hotspot: Vector2i

## Every cursor group in the exe, keyed by resource id -> Cursor. Empty if
## the file is missing or is not a PE with a resource section; the reason is
## printed once so a plain arrow is a known state, not a mystery.
static func load_from_exe(path: String) -> Dictionary:
	var out := {}
	if not FileAccess.file_exists(path):
		print("CursorSet: no client exe at %s -- system cursor stays" % path)
		return out
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.size() < 0x40:
		print("CursorSet: %s is too small to be an exe" % path)
		return out
	var pe := _parse_pe(bytes)
	if pe.is_empty():
		print("CursorSet: %s has no resource section" % path)
		return out
	var groups: Dictionary = pe["groups"]
	var images: Dictionary = pe["cursors"]
	for gid in groups:
		var cur := _decode_group(bytes, groups[gid], images)
		if cur != null:
			cur.id = gid
			out[gid] = cur
	print("CursorSet: %d cursor group(s) read from %s" % [out.size(), path.get_file()])
	return out

## The exe beside an archive: the folder that holds Data.pk2 holds
## sro_client.exe in every retail install.
static func exe_beside(pk2_path: String) -> String:
	if pk2_path == "":
		return ""
	return pk2_path.get_base_dir().path_join("sro_client.exe")

# --- PE -----------------------------------------------------------------

## Walks DOS -> PE -> sections -> .rsrc, and the resource directory for the
## two cursor types. Returns {"groups": {id: PackedByteArray-slice-info},
## "cursors": {id: ...}} where each value is [offset, size] into `bytes`.
static func _parse_pe(b: PackedByteArray) -> Dictionary:
	if b.decode_u16(0) != 0x5A4D:  # "MZ"
		return {}
	var pe: int = b.decode_u32(0x3c)
	if pe + 24 > b.size() or b.decode_u32(pe) != 0x00004550:  # "PE\0\0"
		return {}
	var nsec: int = b.decode_u16(pe + 6)
	var opt_size: int = b.decode_u16(pe + 20)
	var opt: int = pe + 24
	var magic: int = b.decode_u16(opt)
	# Data directory 2 is the resource table: PE32 at +96, PE32+ at +112.
	var dd: int = opt + (112 if magic == 0x20b else 96) + 8 * 2
	var rsrc_rva: int = b.decode_u32(dd)
	if rsrc_rva == 0:
		return {}
	var sections: Array = []
	var sec: int = opt + opt_size
	for i in range(nsec):
		var o: int = sec + 40 * i
		sections.append({
			"va": b.decode_u32(o + 12), "vsize": b.decode_u32(o + 8),
			"raw": b.decode_u32(o + 20), "rsize": b.decode_u32(o + 16)})
	var rbase: int = _rva_to_offset(sections, rsrc_rva)
	if rbase < 0:
		return {}
	var groups := {}
	var cursors := {}
	for type_entry in _dir_entries(b, rbase):
		var type_id: int = type_entry[0]
		if type_id & 0x80000000 or (type_id != RT_CURSOR and type_id != RT_GROUP_CURSOR):
			continue
		if not (type_entry[1] & 0x80000000):
			continue
		for id_entry in _dir_entries(b, rbase + (type_entry[1] & 0x7fffffff)):
			var res_id: int = id_entry[0]
			if res_id & 0x80000000 or not (id_entry[1] & 0x80000000):
				continue
			var langs := _dir_entries(b, rbase + (id_entry[1] & 0x7fffffff))
			if langs.is_empty():
				continue
			var data_entry: int = rbase + (langs[0][1] & 0x7fffffff)
			var data_rva: int = b.decode_u32(data_entry)
			var data_size: int = b.decode_u32(data_entry + 4)
			var off: int = _rva_to_offset(sections, data_rva)
			if off < 0 or off + data_size > b.size():
				continue
			if type_id == RT_GROUP_CURSOR:
				groups[res_id] = [off, data_size]
			else:
				cursors[res_id] = [off, data_size]
	return {"groups": groups, "cursors": cursors}

static func _rva_to_offset(sections: Array, rva: int) -> int:
	for s in sections:
		var va: int = s["va"]
		var span: int = maxi(int(s["vsize"]), int(s["rsize"]))
		if rva >= va and rva < va + span:
			return int(s["raw"]) + (rva - va)
	return -1

## The entries of one IMAGE_RESOURCE_DIRECTORY: [[name_or_id, offset], ..].
static func _dir_entries(b: PackedByteArray, o: int) -> Array:
	if o + 16 > b.size():
		return []
	var n: int = b.decode_u16(o + 12) + b.decode_u16(o + 14)
	var out: Array = []
	for i in range(n):
		var e: int = o + 16 + 8 * i
		if e + 8 > b.size():
			break
		out.append([b.decode_u32(e), b.decode_u32(e + 4)])
	return out

# --- cursor group + DIB -------------------------------------------------

## A GRPCURSORDIR: WORD reserved, WORD type, WORD count, then 14-byte
## entries whose last WORD names the RT_CURSOR image. The first entry is
## taken (every group in this exe is one 32x32 image, two have a second).
static func _decode_group(b: PackedByteArray, where: Array, images: Dictionary) -> Cursor:
	var o: int = where[0]
	if int(where[1]) < 6 + 14 or b.decode_u16(o + 4) < 1:
		return null
	var image_id: int = b.decode_u16(o + 6 + 12)
	if not images.has(image_id):
		return null
	var img_where: Array = images[image_id]
	return decode_cursor_image(b.slice(int(img_where[0]), int(img_where[0]) + int(img_where[1])))

## An RT_CURSOR image: WORD xHot, WORD yHot, then a BITMAPINFOHEADER whose
## height is doubled -- the colour (XOR) bitmap over the 1-bit AND mask, both
## bottom-up and 4-byte padded. Indexed (1/4/8-bit) and 32-bit are handled;
## an AND bit of 1 makes the pixel transparent.
static func decode_cursor_image(d: PackedByteArray) -> Cursor:
	if d.size() < 4 + 40:
		return null
	var cur := Cursor.new()
	cur.hotspot = Vector2i(d.decode_u16(0), d.decode_u16(2))
	var h0 := 4
	var width: int = d.decode_s32(h0 + 4)
	var height2: int = d.decode_s32(h0 + 8)
	var bpp: int = d.decode_u16(h0 + 14)
	var header_size: int = d.decode_u32(h0)
	var height: int = abs(height2) / 2
	if width <= 0 or height <= 0 or width > 256 or height > 256:
		return null
	var palette_count := 0
	if bpp <= 8:
		var declared: int = d.decode_u32(h0 + 32)
		palette_count = declared if declared > 0 else (1 << bpp)
	var pal: int = h0 + header_size
	var xor_off: int = pal + palette_count * 4
	var xor_stride: int = ((width * bpp + 31) / 32) * 4
	var and_off: int = xor_off + xor_stride * height
	var and_stride: int = ((width + 31) / 32) * 4
	if and_off + and_stride * height > d.size():
		return null
	var rgba := PackedByteArray()
	rgba.resize(width * height * 4)
	for y in range(height):
		var src_row: int = height - 1 - y  # bottom-up
		for x in range(width):
			var r := 0
			var g := 0
			var bl := 0
			if bpp == 32:
				var p: int = xor_off + src_row * xor_stride + x * 4
				bl = d[p]
				g = d[p + 1]
				r = d[p + 2]
			else:
				var index := _indexed_pixel(d, xor_off + src_row * xor_stride, x, bpp)
				var pe: int = pal + index * 4
				if pe + 2 < d.size():
					bl = d[pe]
					g = d[pe + 1]
					r = d[pe + 2]
			var and_byte: int = d[and_off + src_row * and_stride + (x >> 3)]
			var masked: bool = (and_byte >> (7 - (x & 7))) & 1 == 1
			var o: int = (y * width + x) * 4
			rgba[o] = r
			rgba[o + 1] = g
			rgba[o + 2] = bl
			rgba[o + 3] = 0 if masked else 255
	cur.image = Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, rgba)
	return cur

static func _indexed_pixel(d: PackedByteArray, row: int, x: int, bpp: int) -> int:
	match bpp:
		8:
			return d[row + x]
		4:
			var v: int = d[row + (x >> 1)]
			return (v >> 4) if (x & 1) == 0 else (v & 0xf)
		1:
			return (d[row + (x >> 3)] >> (7 - (x & 7))) & 1
	return 0
