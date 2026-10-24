extends RefCounted
class_name CrestNet

## Round 824: guild and union crests (emblems) on the wire and in pixels.
## READ from sro_client.exe unless a line says otherwise; docs/protocol/
## guild.md "Crests (round 824)".
##
## - 0x3257 (FUN_00895810): u8 type; type 1 {u32 guild id, str guild name,
##   u32 rev}; type 2 {u32 union id, u8 n, n x str guild name, u32 rev}. Rev
##   0 clears the crest (0x9a48f0).
## - A crest is 256 palette indices into Media.pk2's silk.dat (768 bytes of
##   R, G, B; loaded by Client_LoadAllRefData 0x845fa1), 16 x 16, the BMP's
##   bottom row first (no flip anywhere: c:0x4f9d70 writes them so and the
##   .rd cache's BMP is bottom-up, 0x4fb2a0).
## - OURS: the bytes come from the game server (0x0130 / 0x0131), not from
##   the original's FTP host (type.txt's MarkFTPAddr).

const OP_CREST_UPDATE := 0x3257
const OP_CREST_GET := 0x0130
const OP_CREST_DATA := 0x0131
const KIND_GUILD := 1
const KIND_UNION := 2
const SIZE := 16
const BYTES := 256
const PALETTE_PATH := "silk.dat"
const GUILD_MARK_FILE := "guildmark.bmp"
const UNION_MARK_FILE := "unionmark.bmp"

## c:0x4f9d70's answers: the pixels, no file, or not the format.
const BMP_OK := 0
const BMP_MISSING := 1
const BMP_FORMAT := 2

class Update:
	var kind := 0
	var id := 0
	var rev := 0
	## The guild's name (type 1), or the union's guilds (type 2).
	var guild_names: PackedStringArray = []

static func _str(d: PackedByteArray, at: int) -> Array:
	if at + 2 > d.size():
		return ["", -1]
	var n := d.decode_u16(at)
	if at + 2 + n > d.size():
		return ["", -1]
	return [d.slice(at + 2, at + 2 + n).get_string_from_utf8(), at + 2 + n]

## 0x3257 read, or null when short or of another type.
static func decode_update(d: PackedByteArray) -> Update:
	if d.size() < 5:
		return null
	var u := Update.new()
	u.kind = d[0]
	u.id = d.decode_u32(1)
	var at := 5
	if u.kind == KIND_GUILD:
		var s := _str(d, at)
		if int(s[1]) < 0:
			return null
		u.guild_names.append(String(s[0]))
		at = int(s[1])
	elif u.kind == KIND_UNION:
		if at >= d.size():
			return null
		var n := d[at]
		at += 1
		for i in n:
			var s := _str(d, at)
			if int(s[1]) < 0:
				return null
			u.guild_names.append(String(s[0]))
			at = int(s[1])
	else:
		return null
	if at + 4 > d.size():
		return null
	u.rev = d.decode_u32(at)
	return u

static func encode_get(kind: int, id: int, rev: int) -> PackedByteArray:
	var b := PackedByteArray([kind, 0, 0, 0, 0, 0, 0, 0, 0])
	b.encode_u32(1, id)
	b.encode_u32(5, rev)
	return b

class Data:
	var kind := 0
	var id := 0
	var rev := 0
	var ok := false
	var pixels := PackedByteArray()

static func decode_data(d: PackedByteArray) -> Data:
	if d.size() < 10:
		return null
	var r := Data.new()
	r.kind = d[0]
	r.id = d.decode_u32(1)
	r.rev = d.decode_u32(5)
	r.ok = d[9] == 1 and d.size() >= 10 + BYTES
	if r.ok:
		r.pixels = d.slice(10, 10 + BYTES)
	return r

## c:0x4f9d70: a 16 x 16, 24-bit BMP (a BITMAPFILEHEADER 'BM', its info
## header, then 0x300 bytes of B, G, R), each pixel the palette entry
## nearest by |R-r| + |G-g| + |B-b|, ties to the higher index (`<=`); the
## pixels in the file's order. Returns [code, pixels].
static func bmp_to_indices(bmp: PackedByteArray, palette: PackedByteArray) -> Array:
	if bmp.is_empty():
		return [BMP_MISSING, PackedByteArray()]
	if bmp.size() < 54 or bmp[0] != 0x42 or bmp[1] != 0x4d:
		return [BMP_FORMAT, PackedByteArray()]
	var off := bmp.decode_u32(10)
	var width := bmp.decode_s32(18)
	var height := bmp.decode_s32(22)
	var bits := bmp.decode_u16(28)
	if bits != 24 or width != SIZE or height != SIZE or off + SIZE * SIZE * 3 > bmp.size() or palette.size() < 768:
		return [BMP_FORMAT, PackedByteArray()]
	var out := PackedByteArray()
	out.resize(BYTES)
	for i in BYTES:
		var b := bmp[off + i * 3]
		var g := bmp[off + i * 3 + 1]
		var r := bmp[off + i * 3 + 2]
		var best := 0
		var best_d := 0x7fffffff
		for p in 256:
			var dd: int = absi(r - palette[p * 3]) + absi(g - palette[p * 3 + 1]) + absi(b - palette[p * 3 + 2])
			if dd <= best_d:
				best_d = dd
				best = p
		out[i] = best
	return [BMP_OK, out]

## The crest as an image: row 0 of the bytes is the picture's bottom row.
static func image_of(pixels: PackedByteArray, palette: PackedByteArray) -> Image:
	if pixels.size() < BYTES or palette.size() < 768:
		return null
	var img := Image.create(SIZE, SIZE, false, Image.FORMAT_RGB8)
	for i in BYTES:
		var p := pixels[i]
		img.set_pixel(i % SIZE, SIZE - 1 - i / SIZE,
			Color8(palette[p * 3], palette[p * 3 + 1], palette[p * 3 + 2]))
	return img
