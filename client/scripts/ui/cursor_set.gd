extends RefCounted
class_name CursorSet

## The game's mouse cursors, read out of the player's own `sro_client.exe`.
##
## **What the client shows (READ, round 697).** The cursor manager at
## `0x00ba6260` takes an id and does `LoadCursorA(hInstance,
## MAKEINTRESOURCE(id))` then `SetCursor` (while its show flag +0x20 is set;
## the constructor 0xba6960 sets it, and WM_SETCURSOR in the main window's
## proc 0xba6f10 re-sets the same handle). So every cursor is a Win32
## *resource* cursor; `Media.pk2`'s lone `cursor\cursor_normal1.tga` (a 32x32
## golden hand with alpha, MEASURED) is named nowhere in the exe (ASCII and
## UTF-16 searched) and no archive text names it (raw grep of Media.pk2 and
## Data.pk2: 0 hits) -- it is never drawn. The default "golden" cursor is
## resource 0x95, set before the login screen (CPSVersionCheck::vslot_011
## 0x86d150 calls the manager with 0x95) and on every screen after it.
##
## Who sets an id -- every direct caller of the three entry points (0xba6260
## x4, SetHoverCursor 0x777ec0 x16, the forced cursor 0x777e70 x20; asm):
##
##   0x95  arrow: default, nothing under the mouse, a window under it,
##         friendly characters; version check, skill-mastery toggle, Escape
##   0x96  hammer: the NPC store's repair mode (CIFStore 0x6cea60, the
##         package store 0x6d28d0), forced
##   0x97  red-edged sword: an attackable CICMonster / CICMonsterNPC; a
##         CICUser, CICCos owner, CICGuard or CICATStruct in an enemy guild in
##         a siege-fortress zone; a CICUser of another team (+0x81d)
##   0x98  speech bubble: a CICNPC (exact class, so a CICGuard is not one)
##   0x99  open glove: a CIItem on the ground; 0x9a closed glove while the
##         left button is held (input manager +0x258, set by WM_LBUTTONDOWN)
##   0xa0  bright red sword: a CICUser or another's CICCos outside the party
##         for whom the target's IsHostile(Alt held) (vslot 0xa8) is true
##   0xa1  blue disc: a CITeleportGate
##   0xa3  pouch: a CICUser whose +0x471 is 4 -- the stall state the 0x30b8
##         broadcast (0x873c10) sets
##   0xa6  bright gold arrow: an inventory item applied to another slot,
##         forced (0x676570)
##   0xae / 0xaf  the socket window's two modes, forced (0x592be0 / 0x592c30)
##
## 0x9d, 0x9e, 0x9f and 0xa2 are in the exe but no call passes them (literal
## pushes and the decompile both searched). Nothing sets a cursor for a
## ground-targeted skill. The hover is re-chosen by CGInterface's timer 1
## every 250 ms (`push 0xfa; push 1; call 0xb93320` at 0x787294), not on
## mouse motion: `CGInterface::vslot_005` is the timer handler and case 1 is
## the hover (`0x00789820`), picking the object under the mouse with
## FUN_0078ee20 (no self) and testing its class by exact runtime class.
##
## The art lives in the exe's `.rsrc` as RT_GROUP_CURSOR (type 12) groups
## over RT_CURSOR (type 1) images: 16 numbered groups, ids 0x95..0xaf, and one named (skipped),
## 8-bit DIBs with an AND mask and a hotspot (the first two WORDs of the
## RT_CURSOR data); 32x32 except 0x96 (34x34) and 0x9a (32x31), and 0x99
## carries a second 36x34 image after its 32x32 one (MEASURED). Nothing here
## is extracted or shipped: the exe the player has is parsed at runtime.

const ID_NORMAL := 0x95
const ID_REPAIR := 0x96
const ID_ATTACK := 0x97
const ID_TALK := 0x98
const ID_PICKUP := 0x99
const ID_PICKUP_HELD := 0x9a
const ID_PLAYER_HOSTILE := 0xa0
const ID_GATE := 0xa1
const ID_STALL := 0xa3
const ID_ITEM_USE := 0xa6

## The client exe's names worth reading (round 697): retail's, and the vSRO
## package's DLL-less copy, whose cursor groups decode to the same 16 images
## (MEASURED on the box). The launcher `silkroad.exe` is NOT one: its 15
## cursor groups are 1-bit system-style images (ids 0x7901..), MEASURED.
const EXE_NAMES := ["sro_client.exe", "sro_client_NODLL.exe"]

## Godot's limit on a custom cursor image (DisplayServerWindows /
## DisplayServerMacOS::cursor_set_custom_image, 4.2.2: width or height over
## 256 fails).
const MAX_CURSOR_SIZE := 256

## Bounds on what a file may claim (OURS, round 697 review L1): the PE
## format's own section limit (96, the Windows loader's) and a resource
## directory size far beyond what a client's cursors need.
const MAX_SECTIONS := 96
const MAX_DIR_ENTRIES := 4096

## The scan's bounds (OURS, round 700): files per folder, and how much of
## each file the probe reads.
const MAX_SCAN_PER_DIR := 64
const PROBE_HEADER_BYTES := 4096
const PROBE_RSRC_BYTES := 262144

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

## Where a player's install has the client exe, in the order tried (round
## 697): `override` (SRREVAMP_CLIENT_EXE, OURS, for a dev box; the exe or the
## folder holding it, expand) first; then, for each of EXE_NAMES, the folder
## of Data.pk2 (retail's layout), its parent (a `pk2` folder made inside the
## install, or beside our exe inside the install), and the folder of our own
## executable. Duplicates are dropped, so a pk2 folder that is our exe's
## folder is tried once. A renamed client is found by scan_for_client.
static func exe_candidates(data_pk2: String, own_exe: String, override: String = "") -> PackedStringArray:
	var out := PackedStringArray()
	for p in expand(override):
		if not out.has(p):
			out.append(p)
	var dirs: Array[String] = []
	if data_pk2 != "":
		var d := data_pk2.get_base_dir()
		dirs.append(d)
		var parent := d.get_base_dir()
		if parent != "" and parent != d:
			dirs.append(parent)
	if own_exe != "":
		dirs.append(own_exe.get_base_dir())
	for exe_name in EXE_NAMES:
		for d in dirs:
			var p := String(d).path_join(String(exe_name))
			if not out.has(p):
				out.append(p)
	return out

## A path given by SRREVAMP_CLIENT_EXE, as the files to try (round 700,
## OURS): backslashes become slashes (a Windows path, `C:\Silkroad`; Godot
## takes `/` on every platform), one pair of
## surrounding quotes and a trailing separator are dropped; a path ending in
## `.exe` (any case) is that file, anything else a folder holding one of
## EXE_NAMES. Empty in, empty out.
static func expand(path: String) -> PackedStringArray:
	var out := PackedStringArray()
	var p := path.strip_edges()
	if p.length() >= 2 and ((p.begins_with("\"") and p.ends_with("\"")) or (p.begins_with("'") and p.ends_with("'"))):
		p = p.substr(1, p.length() - 2).strip_edges()
	p = p.replace("\\", "/")
	while p.length() > 1 and p.ends_with("/") and not p.ends_with(":/"):
		p = p.substr(0, p.length() - 1)
	if p == "":
		return out
	if p.to_lower().ends_with(".exe"):
		out.append(p)
		return out
	for exe_name in EXE_NAMES:
		out.append(p.path_join(String(exe_name)))
	return out

## Reads the first candidate that exists and carries the default cursor
## (ID_NORMAL): {"path": the file used or "", "cursors": {id: Cursor},
## "tried": every path looked at, in order}. Never guesses: no file, no set.
static func load_first(candidates: PackedStringArray) -> Dictionary:
	var tried := PackedStringArray()
	for p in candidates:
		tried.append(p)
		if not FileAccess.file_exists(p):
			continue
		var found := load_from_exe(p)
		if found.has(ID_NORMAL):
			return {"path": p, "cursors": found, "tried": tried}
	return {"path": "", "cursors": {}, "tried": tried}

## The folders a scan looks through, in order (round 700): the folder
## `override` names (or its exe's folder), the folder of Data.pk2, its parent,
## and our own executable's folder; no duplicates.
static func scan_dirs(data_pk2: String, own_exe: String, override: String = "") -> PackedStringArray:
	var out := PackedStringArray()
	var ex := expand(override)
	if not ex.is_empty():
		var d0 := ex[0].get_base_dir()
		if d0 != "":
			out.append(d0)
	if data_pk2 != "":
		var d := data_pk2.get_base_dir()
		if not out.has(d):
			out.append(d)
		var parent := d.get_base_dir()
		if parent != "" and parent != d and not out.has(parent):
			out.append(parent)
	if own_exe != "":
		var d := own_exe.get_base_dir()
		if d != "" and not out.has(d):
			out.append(d)
	return out

## Every *.exe in `dir` (any case), sorted case-insensitively, at most
## MAX_SCAN_PER_DIR, without `skip` (compared case-insensitively: Windows
## names are). Empty for a missing folder.
static func exes_in(dir: String, skip: PackedStringArray = PackedStringArray()) -> PackedStringArray:
	var out := PackedStringArray()
	var da := DirAccess.open(dir)
	if da == null:
		return out
	var lower_skip := PackedStringArray()
	for k in skip:
		lower_skip.append(String(k).to_lower())
	var names: Array = []
	for f in da.get_files():
		if String(f).to_lower().ends_with(".exe"):
			names.append(String(f))
	names.sort_custom(func(a: String, b: String) -> bool: return a.to_lower() < b.to_lower())
	for f in names:
		var p := dir.path_join(f)
		if lower_skip.has(p.to_lower()):
			continue
		out.append(p)
		if out.size() >= MAX_SCAN_PER_DIR:
			break
	return out

## Whether the file at `path` has a cursor group `id` (RT_GROUP_CURSOR),
## reading only the PE headers and the head of its resource section (round
## 700): a scanned folder can hold large executables -- an installer, this
## client's own 70 MB build -- that are never read whole. At most
## PROBE_HEADER_BYTES of headers and PROBE_RSRC_BYTES of the resource section:
## the resource directories come before their data (MEASURED on the box's
## four client exes -- sro_client.exe, sro_client_NODLL.exe, a private
## server's SRO_Client_VTX.exe and the launcher silkroad.exe: the cursor
## group directory ends within the first 0x290 bytes of .rsrc, and the
## headers within 0x300); a directory past the cut counts as absent.
static func probe_has_group(path: String, id: int) -> bool:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var size := f.get_length()
	var head := f.get_buffer(mini(size, PROBE_HEADER_BYTES))
	var info := _pe_layout(head)
	if info.is_empty():
		return false
	var sec: Dictionary = info["rsrc_section"]
	var raw: int = sec["raw"]
	if raw <= 0 or raw >= size:
		return false
	f.seek(raw)
	var rs := f.get_buffer(mini(mini(int(sec["rsize"]), PROBE_RSRC_BYTES), size - raw))
	var rbase: int = int(info["rsrc_rva"]) - int(sec["va"])
	if rbase < 0 or rbase >= rs.size():
		return false
	for type_entry in _dir_entries(rs, rbase):
		if int(type_entry[0]) != RT_GROUP_CURSOR or not (int(type_entry[1]) & 0x80000000):
			continue
		for id_entry in _dir_entries(rs, rbase + (int(type_entry[1]) & 0x7fffffff)):
			if int(id_entry[0]) == id:
				return true
		return false
	return false

## Looks for the client when no candidate name is there (round 700): a
## private server's install often renames sro_client.exe (the box's
## SRO_Client_VTX.exe, a private server's client, carries the same cursor
## groups -- MEASURED). Each folder of `dirs`, each *.exe in it not in
## `skip` (the names already tried, our own executable), probed for the
## default cursor's group, then read whole and kept if it decodes (load_first's
## rule). {"path", "cursors", "tried", "probed": count, "usec"}.
static func scan_for_client(dirs: PackedStringArray, skip: PackedStringArray) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	var tried := PackedStringArray()
	var probed := 0
	for d in dirs:
		for p in exes_in(String(d), skip):
			if tried.has(p):
				continue
			tried.append(p)
			probed += 1
			if not probe_has_group(p, ID_NORMAL):
				continue
			var found := load_from_exe(p)
			if found.has(ID_NORMAL):
				return {"path": p, "cursors": found, "tried": tried, "probed": probed, "usec": Time.get_ticks_usec() - t0}
	return {"path": "", "cursors": {}, "tried": tried, "probed": probed, "usec": Time.get_ticks_usec() - t0}

## A cursor scaled by the UI scale (round 697, the user's decision: "Scale
## the cursor with the dpi scaling, just like the rasterized images" --
## OURS; the 32x32 art and its hotspot are READ). Nearest-neighbour, the size
## rounded and clamped to 1..MAX_CURSOR_SIZE; the hotspot is the scaled
## centre of its own source pixel, floor((h + 0.5) * k), so it lands inside
## the block that pixel became, and stays within the image. Returns
## [Image, Vector2i].
static func scaled(cur: Cursor, factor: float) -> Array:
	var w: int = cur.image.get_width()
	var h: int = cur.image.get_height()
	var k := maxf(factor, 0.01)
	var sw := clampi(roundi(w * k), 1, MAX_CURSOR_SIZE)
	var sh := clampi(roundi(h * k), 1, MAX_CURSOR_SIZE)
	var img: Image = cur.image
	if sw != w or sh != h:
		img = cur.image.duplicate() as Image
		img.resize(sw, sh, Image.INTERPOLATE_NEAREST)
	var kx := float(sw) / float(w)
	var ky := float(sh) / float(h)
	var hot := Vector2i(clampi(floori((cur.hotspot.x + 0.5) * kx), 0, sw - 1),
		clampi(floori((cur.hotspot.y + 0.5) * ky), 0, sh - 1))
	return [img, hot]

# --- PE -----------------------------------------------------------------

## Walks DOS -> PE -> sections -> .rsrc, and the resource directory for the
## two cursor types. Returns {"groups": {id: PackedByteArray-slice-info},
## "cursors": {id: ...}} where each value is [offset, size] into `bytes`.
static func _parse_pe(b: PackedByteArray) -> Dictionary:
	var info := _pe_layout(b)
	if info.is_empty():
		return {}
	var sections: Array = info["sections"]
	var rbase: int = _rva_to_offset(sections, int(info["rsrc_rva"]))
	if rbase < 0 or rbase >= b.size():
		return {}
	var groups := {}
	var cursors := {}
	var seen_types := {}
	for type_entry in _dir_entries(b, rbase):
		var type_id: int = type_entry[0]
		if type_id & 0x80000000 or (type_id != RT_CURSOR and type_id != RT_GROUP_CURSOR):
			continue
		if not (type_entry[1] & 0x80000000) or seen_types.has(type_id):
			continue
		seen_types[type_id] = true
		for id_entry in _dir_entries(b, rbase + (type_entry[1] & 0x7fffffff)):
			var res_id: int = id_entry[0]
			if res_id & 0x80000000 or not (id_entry[1] & 0x80000000):
				continue
			var langs := _dir_entries(b, rbase + (id_entry[1] & 0x7fffffff))
			if langs.is_empty():
				continue
			var data_entry: int = rbase + (langs[0][1] & 0x7fffffff)
			if data_entry + 8 > b.size():
				continue
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

## The PE's sections and resource table from its headers (the first bytes
## of the file are enough): {"sections": [{va, vsize, raw, rsize}],
## "rsrc_rva", "rsrc_section": the section holding it}, or {} when `b` is not
## a PE with a resource table.
static func _pe_layout(b: PackedByteArray) -> Dictionary:
	if b.size() < 0x40 or b.decode_u16(0) != 0x5A4D:  # "MZ"
		return {}
	var pe: int = b.decode_u32(0x3c)
	if pe + 24 > b.size() or b.decode_u32(pe) != 0x00004550:  # "PE\0\0"
		return {}
	# Every count and offset is checked against the file before it is used
	# (round 697's review, L1: a PE-signed garbage file was trusted for its
	# section count and directory counts -- 1.1 s and 240k error lines).
	var nsec: int = b.decode_u16(pe + 6)
	var opt_size: int = b.decode_u16(pe + 20)
	var opt: int = pe + 24
	if nsec < 1 or nsec > MAX_SECTIONS or opt + 2 > b.size():
		return {}
	var magic: int = b.decode_u16(opt)
	# Data directory 2 is the resource table: PE32 at +96, PE32+ at +112.
	var dd: int = opt + (112 if magic == 0x20b else 96) + 8 * 2
	if dd + 4 > b.size():
		return {}
	var rsrc_rva: int = b.decode_u32(dd)
	if rsrc_rva == 0:
		return {}
	var sections: Array = []
	var sec: int = opt + opt_size
	if sec + 40 * nsec > b.size():
		return {}
	var holder := {}
	for i in range(nsec):
		var o: int = sec + 40 * i
		var s := {"va": b.decode_u32(o + 12), "vsize": b.decode_u32(o + 8),
			"raw": b.decode_u32(o + 20), "rsize": b.decode_u32(o + 16)}
		sections.append(s)
		var span: int = maxi(int(s["vsize"]), int(s["rsize"]))
		if holder.is_empty() and rsrc_rva >= int(s["va"]) and rsrc_rva < int(s["va"]) + span:
			holder = s
	if holder.is_empty():
		return {}
	return {"sections": sections, "rsrc_rva": rsrc_rva, "rsrc_section": holder}

static func _rva_to_offset(sections: Array, rva: int) -> int:
	for s in sections:
		var va: int = s["va"]
		var span: int = maxi(int(s["vsize"]), int(s["rsize"]))
		if rva >= va and rva < va + span:
			return int(s["raw"]) + (rva - va)
	return -1

## The entries of one IMAGE_RESOURCE_DIRECTORY: [[name_or_id, offset], ..].
static func _dir_entries(b: PackedByteArray, o: int) -> Array:
	if o < 0 or o + 16 > b.size():
		return []
	var n: int = b.decode_u16(o + 12) + b.decode_u16(o + 14)
	if n > MAX_DIR_ENTRIES or o + 16 + 8 * n > b.size():
		return []
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
	if int(where[1]) < 6 + 14 or o + 20 > b.size() or b.decode_u16(o + 4) < 1:
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
