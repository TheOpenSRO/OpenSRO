extends RefCounted
class_name BanReader

## Read-only parser for the .ban (JMXVBAN) bone-animation format.
## See docs/protocol/BAN_FORMAT.md for the on-disk layout. Mirrors
## server/internal/ban's Go implementation; keep the two in sync if the
## format understanding changes.

const MAGIC := "JMXVBAN 0102"
const MAGIC_LEN := 12
const KEYFRAME_SIZE := 28
const MAX_TABLE_COUNT := 100000
const MAX_NAME_LEN := 4096

class Keyframe:
	## Unit quaternion (x, y, z, w) -- confirmed via real files: every
	## keyframe's 4 floats have magnitude ~1.0.
	var rotation: Quaternion
	var position: Vector3

class Bone:
	var bone_name: String
	var keyframes: Array[Keyframe] = []

class ParsedAnimation:
	var animation_name: String
	## How long the clip runs, in milliseconds: the last key time in every
	## real file checked (`chinaman_fighter_standcity` 2333, a run 666).
	var duration_ms: int
	## 30 in every real file checked -- the grid the key times were authored
	## on (every time is a multiple of 33.3 ms). Not a playback rate: a
	## 2333 ms idle has 14 keys, a 2000 ms battle stance 5.
	var authored_fps: int
	## 1 for stands, walks and runs; 0 for skills, sitting down, dying.
	var cyclic: bool
	## When each keyframe falls, in milliseconds from the start -- one entry
	## per keyframe of every bone, ascending, starting at 0. Playing keyframes
	## at a fixed rate instead of these ran a 2333 ms idle in 466 ms.
	var key_times: PackedInt32Array = PackedInt32Array()
	var bones: Array[Bone] = []

	func duration_seconds() -> float:
		return float(duration_ms) / 1000.0

	## The keyframe in force at `seconds` into the clip: the last whose time
	## is not past it. A looping clip wraps at its duration; a one-shot holds
	## its last keyframe.
	func key_index_at(seconds: float, loop: bool) -> int:
		var count := key_times.size()
		if count == 0:
			return 0
		var ms := seconds * 1000.0
		if loop and duration_ms > 0:
			ms = fposmod(ms, float(duration_ms))
		var index := 0
		for i in range(count):
			if float(key_times[i]) <= ms:
				index = i
			else:
				break
		return index

## Parses a .ban file's raw bytes. Returns null (and pushes an error) on
## failure.
static func parse(data: PackedByteArray) -> ParsedAnimation:
	if data.size() < MAGIC_LEN + 4:
		push_error("ban: file too small to contain a header")
		return null
	var magic := data.slice(0, MAGIC_LEN).get_string_from_ascii()
	if magic != MAGIC:
		push_error("ban: bad magic %s, want %s" % [magic, MAGIC])
		return null

	# Two unconfirmed u32 fields (observed 0 in every real file checked)
	# sit between the magic and the animation-name length.
	var off := MAGIC_LEN + 8

	var name_result = _read_len_prefixed_string(data, off)
	if name_result == null:
		push_error("ban: reading name")
		return null
	var a := ParsedAnimation.new()
	a.animation_name = name_result[0]
	off = name_result[1]

	if off + 12 > data.size():
		push_error("ban: truncated before header fields")
		return null
	a.duration_ms = _le_u32(data, off)
	a.authored_fps = _le_u32(data, off + 4)
	a.cyclic = _le_u32(data, off + 8) != 0
	off += 12

	if off + 4 > data.size():
		push_error("ban: truncated before the key time table")
		return null
	var table_count := _le_u32(data, off)
	off += 4
	if table_count > MAX_TABLE_COUNT:
		push_error("ban: implausible key time count %d" % table_count)
		return null
	if off + table_count * 4 > data.size():
		push_error("ban: key time table runs past end of file")
		return null
	a.key_times.resize(table_count)
	for i in range(table_count):
		a.key_times[i] = _le_u32(data, off + i * 4)
	off += table_count * 4

	if off + 4 > data.size():
		push_error("ban: truncated before bone count")
		return null
	var bone_count := _le_u32(data, off)
	off += 4

	for i in range(bone_count):
		var result = _parse_bone(data, off)
		if result == null:
			push_error("ban: reading bone %d/%d" % [i + 1, bone_count])
			return null
		a.bones.append(result[0])
		off = result[1]

	return a

static func _parse_bone(data: PackedByteArray, off: int):
	var name_result = _read_len_prefixed_string(data, off)
	if name_result == null:
		return null
	var b := Bone.new()
	b.bone_name = name_result[0]
	off = name_result[1]

	if off + 4 > data.size():
		return null
	var kf_count := _le_u32(data, off)
	off += 4

	var end := off + kf_count * KEYFRAME_SIZE
	if end > data.size():
		return null

	for i in range(kf_count):
		var rec_off := off + i * KEYFRAME_SIZE
		var kf := Keyframe.new()
		kf.rotation = Quaternion(_le_f32(data, rec_off), _le_f32(data, rec_off + 4), _le_f32(data, rec_off + 8), _le_f32(data, rec_off + 12))
		kf.position = Vector3(_le_f32(data, rec_off + 16), _le_f32(data, rec_off + 20), _le_f32(data, rec_off + 24))
		b.keyframes.append(kf)

	return [b, end]

static func _read_len_prefixed_string(data: PackedByteArray, off: int):
	if off + 4 > data.size():
		return null
	var n := _le_u32(data, off)
	off += 4
	if n < 0 or n > MAX_NAME_LEN or off + n > data.size():
		return null
	return [data.slice(off, off + n).get_string_from_ascii(), off + n]

static func _le_u32(b: PackedByteArray, off: int) -> int:
	return b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24)

static func _le_f32(b: PackedByteArray, off: int) -> float:
	return b.slice(off, off + 4).decode_float(0)
