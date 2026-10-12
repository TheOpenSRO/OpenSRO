class_name GameIcon
extends RefCounted

## The game's own icon on the window and the taskbar (round 780, the user's
## request), read at boot from the player's sro_client.exe -- the same file
## GameCursor found -- and never shipped: the image lives only in memory and
## goes to DisplayServer.set_icon.
##
## MEASURED (the box's sro_client.exe): one RT_GROUP_ICON (id 132) with one
## entry, a 32x32 8-bit RT_ICON (id 1, 2,216 bytes) -- the only icon in the
## file, so the window's. An RT_ICON is a cursor image without the hotspot
## words: a BITMAPINFOHEADER with the height doubled, the colour bitmap over
## the 1-bit AND mask (CursorSet.decode_cursor_image reads that shape); a PNG
## entry (Vista-style icons) is read as PNG. A 32-bit entry's own alpha is
## kept. Several entries: the largest, then the deepest.

const RT_ICON := 3
const RT_GROUP_ICON := 14

static var _applied := false

## Sets the window's icon once from GameCursor's exe; a no-op without one.
static func apply_once() -> void:
	if _applied:
		return
	_applied = true
	var path := GameCursor.source_path()
	if path == "":
		print("GameIcon: no client exe -- the window keeps its own icon")
		return
	var img := load_from_exe(path)
	if img == null:
		print("GameIcon: no icon in %s" % path.get_file())
		return
	DisplayServer.set_icon(img)
	print("GameIcon: %dx%d icon from %s" % [img.get_width(), img.get_height(), path.get_file()])

## The exe's first icon group's best image, or null.
static func load_from_exe(path: String) -> Image:
	if not FileAccess.file_exists(path):
		return null
	return from_pe_bytes(FileAccess.get_file_as_bytes(path))

static func from_pe_bytes(b: PackedByteArray) -> Image:
	var info := CursorSet._pe_layout(b)
	if info.is_empty():
		return null
	var sections: Array = info["sections"]
	var rbase: int = CursorSet._rva_to_offset(sections, int(info["rsrc_rva"]))
	if rbase < 0 or rbase >= b.size():
		return null
	var groups := _resources(b, sections, rbase, RT_GROUP_ICON)
	var icons := _resources(b, sections, rbase, RT_ICON)
	var ids := groups.keys()
	ids.sort()
	for gid in ids:
		var g: PackedByteArray = groups[gid]
		if g.size() < 6:
			continue
		var count: int = g.decode_u16(4)
		var best_id := -1
		var best_key := -1
		for i in range(count):
			var e := 6 + 14 * i
			if e + 14 > g.size():
				break
			var w: int = g[e] if g[e] != 0 else 256
			var bpp: int = g.decode_u16(e + 6)
			var key := w * 64 + bpp
			if key > best_key and icons.has(g.decode_u16(e + 12)):
				best_key = key
				best_id = g.decode_u16(e + 12)
		if best_id >= 0:
			var img := decode_icon_image(icons[best_id])
			if img != null:
				return img
	return null

## One RT_ICON entry as an RGBA image, or null.
static func decode_icon_image(d: PackedByteArray) -> Image:
	if d.size() >= 8 and d[0] == 0x89 and d[1] == 0x50 and d[2] == 0x4E and d[3] == 0x47:
		var png := Image.new()
		return png if png.load_png_from_buffer(d) == OK else null
	var prefixed := PackedByteArray([0, 0, 0, 0])
	prefixed.append_array(d)
	var cur := CursorSet.decode_cursor_image(prefixed)
	if cur == null:
		return null
	if d.size() >= 40 and d.decode_u16(14) == 32:
		# A 32-bit icon carries its own alpha in the colour bitmap.
		var w: int = d.decode_s32(4)
		var h: int = absi(d.decode_s32(8)) / 2
		var off: int = d.decode_u32(0)
		var stride := w * 4
		if off + stride * h <= d.size():
			for y in range(h):
				for x in range(w):
					var a: int = d[off + (h - 1 - y) * stride + x * 4 + 3]
					var c := cur.image.get_pixel(x, y)
					c.a = a / 255.0
					cur.image.set_pixel(x, y, c)
	return cur.image

## {resource id: bytes} of one resource type (the first language of each).
static func _resources(b: PackedByteArray, sections: Array, rbase: int, type_id: int) -> Dictionary:
	var out := {}
	for type_entry in CursorSet._dir_entries(b, rbase):
		if int(type_entry[0]) != type_id or not (int(type_entry[1]) & 0x80000000):
			continue
		for id_entry in CursorSet._dir_entries(b, rbase + (int(type_entry[1]) & 0x7fffffff)):
			var res_id: int = id_entry[0]
			if res_id & 0x80000000 or not (int(id_entry[1]) & 0x80000000):
				continue
			var langs := CursorSet._dir_entries(b, rbase + (int(id_entry[1]) & 0x7fffffff))
			if langs.is_empty():
				continue
			var de: int = rbase + (int(langs[0][1]) & 0x7fffffff)
			if de + 8 > b.size():
				continue
			var off: int = CursorSet._rva_to_offset(sections, b.decode_u32(de))
			var size: int = b.decode_u32(de + 4)
			if off < 0 or off + size > b.size():
				continue
			out[res_id] = b.slice(off, off + size)
		break
	return out
