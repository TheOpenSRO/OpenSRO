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

## The fog colour the client renders with, from channel 9's sampled colour
## (READ, rounds 623-628 integration review): `Map::FUN_00a1baf0` clamps
## channel 9 into world+0x68a3..0x68ab (each to [0, 1]), then stores the
## square root of each (`FUN_00a1baf0` 0xa1d164/0xa1d17b/0xa1d192 call
## FUN_00b42de0, the CRT sqrt -- `fsqrt` at 0xb42e1c) into world+0x68b7,
## 0x68bb, 0x68bf; `FUN_00a26f60` packs those x 255 into world+0x67e6 and
## sets it as D3DRS_FOGCOLOR (0x22) before the landscape draws. So a
## channel value of 0.25 fogs to 0.5. Alpha is kept.
static func render_fog_color(channel_9: Color) -> Color:
	return Color(sqrt(clampf(channel_9.r, 0.0, 1.0)), sqrt(clampf(channel_9.g, 0.0, 1.0)),
		sqrt(clampf(channel_9.b, 0.0, 1.0)), channel_9.a)
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

## How the client samples a graph at the day phase t (READ, round 786):
## ColorGraph `FUN_004e55e0` (16-byte keys, the time at +0xc) and FloatGraph
## `FUN_004e5770` (8-byte keys, the time at +4) both find the first key whose
## time is >= t. None: the LAST key's value. The first key: its value. Else,
## with p the key before it, frac = (t - time[p]) / (time[p+1] - time[p]) --
## 0 when that gap is <= 0.0001 (the float at 0xe1b880) -- and the value is
## the graph's interpolator (`FUN_004e4530` / `FUN_004e4770`) through four
## keys: key[p-1] (key[0] when p is 0), key[p], key[p+1], key[p+2] (key[p+1]
## when p+1 is the last). The interpolator is the function pointer at graph
## +0x10, which the record's graph constructors set to `FUN_004e0920` (colour,
## 0xa1ba6c) and `0x4df7d0` (float, 0xa1bacc): both the uniform Catmull-Rom
## spline, 0.5 x (2 P1 + (P2 - P0) f + (2 P0 - 5 P1 + 4 P2 - P3) f^2 +
## (-P0 + 3 P1 - 3 P2 + P3) f^3) (the doubles 2.0, 5.0, 4.0, 3.0, 0.5 at
## 0xe1b898, 0xd81950, 0xe1b860, 0xe1b808, 0xe1b7d0); the pre-step at graph
## +0xc is cleared by the base constructor (0x4e62dc). The spline passes
## through every key and may overshoot between them; the environment step
## clamps the colours it uses (Map::FUN_00a1baf0). Before round 786 this
## reader interpolated linearly, which only the keys agreed with.
##
## Returns the key indices [p0, p1, p2, p3] and frac, or [] when the value is
## a key's own -- then `hold` is that key's index (out[0]).
static func _spline_keys(times: PackedFloat32Array, t: float) -> Array:
	var n := times.size()
	var i := 0
	while i < n and not (t <= times[i]):
		i += 1
	if i >= n:
		return [n - 1]
	if i == 0:
		return [0]
	var p := i - 1
	var gap := times[i] - times[p]
	var frac := 0.0 if gap <= 0.0001 else (t - times[p]) / gap
	var p0 := p - 1 if p > 0 else 0
	var p3 := p + 1 if p == n - 2 else p + 2
	return [p0, p, p + 1, p3, frac]

## The uniform Catmull-Rom spline (READ, FUN_004e0920 / 0x4df7d0).
static func catmull_rom(p0: float, p1: float, p2: float, p3: float, f: float) -> float:
	var f2 := f * f
	var f3 := f2 * f
	return 0.5 * (2.0 * p1 + (p2 - p0) * f + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * f2
		+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * f3)

## Samples a 2-float (value, time) FloatGraph channel at t (READ above). 0.0
## for an empty channel (OURS: the client asserts on one; none of the 74
## records has an empty channel).
static func sample_float_channel(record: Record, channel_idx: int, t: float) -> float:
	if channel_idx < 0 or channel_idx >= record.channels.size():
		return 0.0
	var groups: Array = record.channels[channel_idx]
	if groups.is_empty():
		return 0.0
	var times := PackedFloat32Array()
	for g in groups:
		times.append((g as PackedFloat32Array)[1])
	var k := _spline_keys(times, t)
	if k.size() == 1:
		return (groups[k[0]] as PackedFloat32Array)[0]
	return catmull_rom((groups[k[0]] as PackedFloat32Array)[0], (groups[k[1]] as PackedFloat32Array)[0],
		(groups[k[2]] as PackedFloat32Array)[0], (groups[k[3]] as PackedFloat32Array)[0], k[4])

## Samples a 4-float (RGB, time) ColorGraph channel at the day phase t (READ
## above), unclamped. Color(1,1,1) for an empty channel or an index out of
## range (OURS: a neutral fallback, not a guessed colour).
static func sample_color_channel(record: Record, channel_idx: int, t: float) -> Color:
	if channel_idx < 0 or channel_idx >= record.channels.size():
		return Color(1, 1, 1)
	var groups: Array = record.channels[channel_idx]
	if groups.is_empty():
		return Color(1, 1, 1)
	var times := PackedFloat32Array()
	for g in groups:
		times.append((g as PackedFloat32Array)[3])
	var k := _spline_keys(times, t)
	if k.size() == 1:
		var key: PackedFloat32Array = groups[k[0]]
		return Color(key[0], key[1], key[2])
	var a: PackedFloat32Array = groups[k[0]]
	var b: PackedFloat32Array = groups[k[1]]
	var c: PackedFloat32Array = groups[k[2]]
	var d: PackedFloat32Array = groups[k[3]]
	var f: float = k[4]
	return Color(catmull_rom(a[0], b[0], c[0], d[0], f), catmull_rom(a[1], b[1], c[1], d[1], f),
		catmull_rom(a[2], b[2], c[2], d[2], f))

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
