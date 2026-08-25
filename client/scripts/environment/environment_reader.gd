extends RefCounted
class_name EnvironmentReader

## Read-only parser for the real environment.ifo (JMXVENVI) format -- see
## docs/protocol/ENVIRONMENT_FORMAT.md for the full derivation. `.m`'s
## per-block `EnvironmentID` field (see MAPM_FORMAT.md) indexes this real
## table's records by their real `Key` byte.
##
## Real, confirmed location: `Map.pk2` root (alongside `object.ifo`/
## `tile2d.ifo`/etc), NOT `Data.pk2` -- an earlier pass wrongly declared this
## file "entirely absent" after only checking `Data.pk2`; see
## docs/protocol/TILE2D_FORMAT.md's 2026-08-23 correction for the same
## wrong-archive mistake found (and fixed) for real ground textures.
##
## Verified byte-for-byte against a real 76,000-byte sample: all 74 real
## records parse with the real per-record structure below, landing exactly
## on a real trailing "Root(Environment)" section (a separate, real,
## Korean-language editor organizational tree -- not parsed here, see the
## doc's "Unparsed trailer" section).

const MAGIC := "JMXVENVI1003"
const MAGIC_LEN := 12

## Real per-record channel layout, in real file order -- confirmed via
## decompiling the real client's own record reader (FUN_00a1b650) and
## cross-checking its two vector-append helpers' element-size math (a
## 4-float push vs. a 2-float push) against the real byte sample until a
## byte-exact, zero-leftover parse of the real record data was reached.
## Each entry is the real float count per group for that channel index
## (4 or 2); the channel itself is a real, count-prefixed array of that
## many-float groups (0 or more).
const CHANNEL_GROUP_FLOATS: Array[int] = [4, 4, 4, 4, 4, 4, 4, 2, 2, 4, 2, 2, 2, 4, 4, 2]

class Record:
	## Real single-byte ID `.m`'s per-block `EnvironmentID` field references.
	var key: int
	## Real primary preset name (e.g. "Env7", "Env8") -- reused across many
	## records, not unique per record.
	var name1: String
	## Real secondary name field -- empty in every record of the one real
	## sample checked; real purpose beyond "a second optional label" isn't
	## confirmed.
	var name2: String
	## Real 16 channels, in real file order (see CHANNEL_GROUP_FLOATS).
	## Each channel is an Array of PackedFloat32Array groups (each group's
	## length is that channel's CHANNEL_GROUP_FLOATS entry). Real values in
	## the one sample checked are mostly 0.0/1.0 (consistent with, but not
	## confirmed to be, real RGB/weight lighting-blend keyframes across
	## something like time-of-day) -- no per-channel semantic meaning
	## (e.g. "channel 0 is ambient color") is confirmed, so this project
	## does not yet assign one.
	var channels: Array = []

class ParsedFile:
	## Real record count from the header.
	var record_count: int
	## Real records, in real file order.
	var records: Array[Record] = []
	## Byte offset where record data ends and the real, unparsed
	## "Root(Environment)" trailer begins -- see this file's top comment.
	var trailer_offset: int

## Parses environment.ifo's real record data. Returns null (and pushes an
## error) on a structural failure. Does not parse the real trailing
## "Root(Environment)" organizational tree (ParsedFile.trailer_offset marks
## where it starts, for a caller that wants the raw bytes).
static func parse(data: PackedByteArray) -> ParsedFile:
	if data.size() < MAGIC_LEN + 4 + 2:
		push_error("environment: file too small to contain a header")
		return null
	var magic := data.slice(0, MAGIC_LEN).get_string_from_ascii()
	if magic != MAGIC:
		push_error("environment: bad magic %s, want %s" % [magic, MAGIC])
		return null

	var off := MAGIC_LEN
	var record_count := data.decode_u32(off)
	off += 4
	off += 2 # real fixed field, always 0 in the one real sample checked; purpose unconfirmed

	var f := ParsedFile.new()
	f.record_count = record_count

	for i in range(record_count):
		if off + 2 > data.size():
			push_error("environment: truncated before record %d's key" % i)
			return null
		var key: int = data[off]
		var pad: int = data[off + 1]
		off += 2
		if pad != 0:
			push_error("environment: record %d has a non-zero pad byte (%d) -- this project's real structural assumption may not hold for this file" % [i, pad])
			return null

		var name1_result := _read_str(data, off)
		if name1_result.is_empty():
			return null
		off = name1_result[1]

		var name2_result := _read_str(data, off)
		if name2_result.is_empty():
			return null
		off = name2_result[1]

		if off + 4 > data.size():
			push_error("environment: truncated before record %d's reserved field" % i)
			return null
		off += 4 # real fixed field, always 0 in the one real sample checked; purpose unconfirmed

		var rec := Record.new()
		rec.key = key
		rec.name1 = name1_result[0]
		rec.name2 = name2_result[0]

		for group_floats in CHANNEL_GROUP_FLOATS:
			if off + 4 > data.size():
				push_error("environment: truncated before record %d's channel count" % i)
				return null
			var count := data.decode_u32(off)
			off += 4
			var group_len := group_floats * 4
			var groups: Array = []
			for _g in range(count):
				if off + group_len > data.size():
					push_error("environment: truncated inside record %d's channel data" % i)
					return null
				var group := PackedFloat32Array()
				group.resize(group_floats)
				for k in range(group_floats):
					group[k] = data.decode_float(off + k * 4)
				off += group_len
				groups.append(group)
			rec.channels.append(groups)

		f.records.append(rec)

	f.trailer_offset = off
	return f

## Reads a real length-prefixed string (u32 length + that many raw bytes)
## at off. Returns [] on failure (truncated/out of range), or [string,
## next_offset] on success.
static func _read_str(data: PackedByteArray, off: int) -> Array:
	if off + 4 > data.size():
		push_error("environment: truncated before a string length")
		return []
	var n := data.decode_u32(off)
	off += 4
	if off + n > data.size():
		push_error("environment: string length %d exceeds remaining data" % n)
		return []
	var s := data.slice(off, off + n).get_string_from_ascii()
	return [s, off + n]
