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

## Real channel names (2026-08-31), from public documentation
## (github.com/DummkopfOfHachtenduden/SilkroadDoc/wiki/JMXVENVI -- fair game
## per docs/LEGAL.md point 3, not decompiled from a binary in this repo's own
## history) whose channel order/size-per-channel independently matches this
## project's own decompiled CHANNEL_GROUP_FLOATS sequence exactly -- strong
## corroborating evidence the names are right for these real files too, not
## just plausible. Channels 4/10/11/12/15 are unnamed in that public source
## ("Graph4" etc.) and aren't given names here either, to avoid inventing
## ones. See docs/protocol/ENVIRONMENT_FORMAT.md for the full derivation.
const CHANNEL_SUN_COLOR := 0
const CHANNEL_SKY_TOP_COLOR := 1
const CHANNEL_DIFFUSE_COLOR := 2
const CHANNEL_OBJECT_AMBIENT_COLOR := 3
const CHANNEL_TERRAIN_AMBIENT_COLOR := 5
const CHANNEL_TERRAIN_SHADOW_COLOR := 6
## The fog PLANES are channels 10 and 11, not 7 and 8 -- READ from the client
## (round 229): the environment update Map::FUN_00a1baf0 evaluates the six
## FloatGraphs in file order (record +0x25c, +0x288, +0x2e8, +0x314, +0x340,
## +0x36c = channels 7, 8, 10, 11, 12, 15) and multiplies the third and fourth
## -- channels 10 and 11 -- by the view-distance global at 0xec54b0 (2500.0 in
## the image; its no-record fallback is -0.2 and 1.0 times the same global),
## storing them as the fog near and far planes (world +0x68af/+0x68b3). The
## real files agree: channel 10 ranges over [-0.147, 0.813] and 11 over
## [0.467, 1.0] across all 74 records (tools/dump_environment_floats.gd) --
## fractions of the view distance, a near plane that may sit just behind the
## camera, a far plane at or inside it. Channels 7 and 8 hold [-1, 1] values
## the client maps through (v + 1) / 2 and 1 - v; their roles are not named
## here. The public source's "FogNearPlane/FogFarPlane" at 7/8 is wrong for
## this client.
const CHANNEL_FOG_NEAR_PLANE := 10
const CHANNEL_FOG_FAR_PLANE := 11
const CHANNEL_FOG_COLOR := 9
## The client's view distance the fog fractions scale by: the initial value of
## the global at 0xec54b0 (`.data`, so a setting may change it at runtime).
const VIEW_DISTANCE_DEFAULT := 2500.0
const CHANNEL_SKY_BOTTOM_COLOR := 13
const CHANNEL_WATER_COLOR := 14

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

## Samples a real 4-float (RGB + time) color channel at normalized
## time-of-day t (0..1, wrapping), linearly interpolating between the two
## real keyframe groups on either side of t -- each group's 4th float is
## its real time value (see CHANNEL_GROUP_FLOATS' doc comment). Returns
## Color(1,1,1) if the channel has fewer than 2 groups (nothing real to
## interpolate) or channel_idx is out of range -- an honest neutral
## fallback, not a guessed color.
## Samples a 2-float (value, time) FloatGraph channel at t, interpolating
## between the two keyframes around t exactly as sample_color_channel does
## for colours (the client's FUN_004e5770 walks 8-byte keys the same way).
static func sample_float_channel(record: Record, channel_idx: int, t: float) -> float:
	var groups: Array = record.channels[channel_idx]
	if groups.is_empty():
		return 0.0
	var prev: PackedFloat32Array = groups[0]
	for g in groups:
		var group: PackedFloat32Array = g
		if group[1] >= t:
			var span := group[1] - prev[1]
			if span <= 0.0:
				return group[0]
			var f := clampf((t - prev[1]) / span, 0.0, 1.0)
			return lerpf(prev[0], group[0], f)
		prev = group
	return prev[0]

static func sample_color_channel(record: Record, channel_idx: int, t: float) -> Color:
	if channel_idx < 0 or channel_idx >= record.channels.size():
		return Color(1, 1, 1)
	var groups: Array = record.channels[channel_idx]
	if groups.size() < 2:
		return Color(1, 1, 1)
	var wrapped_t := fposmod(t, 1.0)
	for i in range(groups.size() - 1):
		var g0: PackedFloat32Array = groups[i]
		var g1: PackedFloat32Array = groups[i + 1]
		var t0: float = g0[3]
		var t1: float = g1[3]
		if wrapped_t >= t0 and wrapped_t <= t1:
			var span := t1 - t0
			var f := (wrapped_t - t0) / span if span > 0.0001 else 0.0
			return Color(g0[0], g0[1], g0[2]).lerp(Color(g1[0], g1[1], g1[2]), f)
	# Past the last real keyframe's time value -- hold the last group's color
	# rather than guessing an extrapolation.
	var last: PackedFloat32Array = groups[groups.size() - 1]
	return Color(last[0], last[1], last[2])

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
