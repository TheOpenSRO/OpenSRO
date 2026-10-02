extends RefCounted
class_name RetailClientInfo

## What a retail client tells a gateway about itself in 0x6100 (round 681),
## read at run time from the player's own Media.pk2 -- never a built-in
## guess (a gateway refuses an unknown content id or a wrong version).
##
## - The content id (READ): the first byte of DIVISIONINFO.TXT. The launcher
##   reads it (silkroad.exe 0x436faf opens DIVISIONINFO.TXT, 0x4370a7 reads
##   one byte into 0x4b8f64) and passes it as the first number of
##   "/%d %d %d" (0x4331dd, format 0x492fd8); sro_client sscanf's it into
##   CGame+0x810 (0x846b40) and hands that byte to the net layer (0x844b7e),
##   which sends it in 0x6100. (sro_client's own DIVISIONINFO reader skips the
##   byte: docs/protocol/server_list.md.)
## - The version (READ, CGame 0x846b4e..0x846c52): Media.pk2's sv.t is a u32
##   length then Blowfish data; the client keys Blowfish with the first 8
##   bytes of "SILKROADVERSION" (0xdd3f00, strcpy'd into 16 then keyed with
##   8: 0x846ba7..0x846c19), decrypts ceil(length / 8) blocks from offset 4
##   (0x4aaa20, halves little-endian) and atoi's the text into CGame+0x7e8.

const DIVISIONINFO := "divisioninfo.txt"
const SV_T := "sv.t"
## READ: the key is these 8 bytes ("SILKROADVERSION" cut to 8).
const SV_KEY := "SILKROAD"
## READ: the client reads at most 0x400 bytes of sv.t (0x846b87).
const SV_MAX := 0x400

## {"content_id", "version"} or {"error"}.
static func from_media(media: Pk2Reader) -> Dictionary:
	if media == null:
		return {"error": "no Media.pk2 (the content id and version are the archive's own)"}
	var div := _read(media, DIVISIONINFO)
	if div.is_empty():
		return {"error": "Media.pk2 has no %s" % DIVISIONINFO}
	var sv := _read(media, SV_T)
	if sv.is_empty():
		return {"error": "Media.pk2 has no %s" % SV_T}
	var v := parse_sv_t(sv)
	if v.has("error"):
		return v
	return {"content_id": div[0], "version": v["version"], "sv_text": v["text"]}

static func _read(media: Pk2Reader, path: String) -> PackedByteArray:
	var e := ObjectLoader.find_file(media, path)
	if e == null or e.is_dir:
		return PackedByteArray()
	return media.read_file(e)

## sv.t's bytes -> {"version"} or {"error"}.
static func parse_sv_t(b: PackedByteArray) -> Dictionary:
	if b.size() < 4:
		return {"error": "sv.t is %d bytes" % b.size()}
	b = b.slice(0, mini(b.size(), SV_MAX))
	var n := b.decode_u32(0)
	var blocks := RetailSecurity.padded_len(n)
	if n == 0 or 4 + blocks > b.size():
		return {"error": "sv.t says %d bytes of version but holds %d" % [n, b.size() - 4]}
	var bf := Blowfish.new(SV_KEY.to_ascii_buffer())
	var text := bf.decrypt_le(b.slice(4, 4 + blocks))
	var v := atoi(text)
	if v < 0:
		return {"error": "sv.t's text is not a version number"}
	return {"version": v, "text": text.slice(0, n).hex_encode()}

## The C library's atoi on the decrypted bytes: leading spaces, an optional
## sign, then digits until anything else. -1 when there are no digits or the
## number is not a u32 (OURS).
static func atoi(b: PackedByteArray) -> int:
	var i := 0
	while i < b.size() and b[i] in [0x20, 0x09, 0x0a, 0x0b, 0x0c, 0x0d]:
		i += 1
	if i < b.size() and b[i] == 0x2b:
		i += 1
	var v := 0
	var digits := 0
	while i < b.size() and b[i] >= 0x30 and b[i] <= 0x39:
		v = v * 10 + (b[i] - 0x30)
		digits += 1
		if v > RetailSecurity.MASK32:
			return -1
		i += 1
	return v if digits > 0 else -1
