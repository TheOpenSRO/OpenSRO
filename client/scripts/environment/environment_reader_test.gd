extends SceneTree

## Exercises EnvironmentReader against a synthetic environment.ifo file
## (never real game data), run headless:
## `godot4 --headless --path client --script res://scripts/environment/environment_reader_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _append_u32(buf: PackedByteArray, v: int) -> void:
	for i in range(4):
		buf.append((v >> (8 * i)) & 0xff)

func _append_u16(buf: PackedByteArray, v: int) -> void:
	for i in range(2):
		buf.append((v >> (8 * i)) & 0xff)

func _append_float(buf: PackedByteArray, v: float) -> void:
	var tmp := PackedFloat32Array([v])
	buf.append_array(tmp.to_byte_array())

func _append_str(buf: PackedByteArray, s: String) -> void:
	var bytes := s.to_ascii_buffer()
	_append_u32(buf, bytes.size())
	buf.append_array(bytes)

## Builds a real-shaped record: key/pad, name1/name2, a reserved u32, then
## one real group per channel (all channels get exactly `groups_per_channel`
## groups, each group's floats set to `fill`) -- real per-channel float
## counts (4 or 2) come from EnvironmentReader.CHANNEL_GROUP_FLOATS itself,
## so this fixture automatically tracks the reader's own real layout.
func _append_record(buf: PackedByteArray, key: int, name1: String, name2: String, groups_per_channel: int, fill: float) -> void:
	buf.append(key)
	buf.append(0) # pad
	_append_str(buf, name1)
	_append_str(buf, name2)
	_append_u32(buf, 0) # reserved
	for group_floats in EnvironmentReader.CHANNEL_GROUP_FLOATS:
		_append_u32(buf, groups_per_channel)
		for _g in range(groups_per_channel):
			for _k in range(group_floats):
				_append_float(buf, fill)

func _build_file(records: Array) -> PackedByteArray:
	var buf := PackedByteArray()
	buf.append_array("JMXVENVI1003".to_ascii_buffer())
	_append_u32(buf, records.size())
	_append_u16(buf, 0) # real fixed field, always 0 in the one real sample checked
	for r in records:
		_append_record(buf, r[0], r[1], r[2], r[3], r[4])
	return buf

func _init() -> void:
	_check(EnvironmentReader.CHANNEL_GROUP_FLOATS.size() == 16, "16 real channels defined (got %d)" % EnvironmentReader.CHANNEL_GROUP_FLOATS.size())
	_check(EnvironmentReader.CHANNEL_GROUP_FLOATS.count(4) == 10, "10 real 4-float channels (got %d)" % EnvironmentReader.CHANNEL_GROUP_FLOATS.count(4))
	_check(EnvironmentReader.CHANNEL_GROUP_FLOATS.count(2) == 6, "6 real 2-float channels (got %d)" % EnvironmentReader.CHANNEL_GROUP_FLOATS.count(2))

	var data := _build_file([
		[7, "Env7", "", 2, 1.0],
		[39, "Env8", "Second", 3, 0.5],
	])
	var parsed := EnvironmentReader.parse(data)
	_check(parsed != null, "parses a synthetic environment.ifo")
	if parsed != null:
		_check(parsed.record_count == 2, "record_count matches (got %d)" % parsed.record_count)
		_check(parsed.records.size() == 2, "2 real records parsed (got %d)" % parsed.records.size())
		_check(parsed.trailer_offset == data.size(), "trailer_offset lands exactly at EOF for a file with no trailer (got %d, want %d)" % [parsed.trailer_offset, data.size()])

		var r0: EnvironmentReader.Record = parsed.records[0]
		_check(r0.key == 7, "record 0 key matches (got %d)" % r0.key)
		_check(r0.name1 == "Env7", "record 0 name1 matches (got %s)" % r0.name1)
		_check(r0.name2 == "", "record 0 name2 is empty (got %s)" % r0.name2)
		_check(r0.channels.size() == 16, "record 0 has 16 real channels (got %d)" % r0.channels.size())
		_check(r0.channels[0].size() == 2, "record 0 channel 0 has 2 real groups (got %d)" % r0.channels[0].size())
		var g: PackedFloat32Array = r0.channels[0][0]
		_check(g.size() == 4, "record 0 channel 0's group has 4 real floats (got %d)" % g.size())
		_check(is_equal_approx(g[0], 1.0), "record 0 channel 0's group holds the real fill value (got %s)" % g[0])
		var d_chan: PackedFloat32Array = r0.channels[7][0] # channel 7 is a real 2-float channel
		_check(d_chan.size() == 2, "record 0 channel 7 (2-float type) has 2 real floats (got %d)" % d_chan.size())

		var r1: EnvironmentReader.Record = parsed.records[1]
		_check(r1.key == 39, "record 1 key matches (got %d)" % r1.key)
		_check(r1.name2 == "Second", "record 1 name2 matches (got %s)" % r1.name2)
		_check(r1.channels[0].size() == 3, "record 1 channel 0 has 3 real groups (got %d)" % r1.channels[0].size())

	# sample_color_channel: a real-shaped record where channel 0 (SunColor)
	# has 3 real keyframes at t=0 (red), t=0.5 (green), t=1 (blue) -- every
	# other channel gets 1 dummy group so parse() has something to read.
	var sample_buf := PackedByteArray()
	sample_buf.append_array("JMXVENVI1003".to_ascii_buffer())
	_append_u32(sample_buf, 1)
	_append_u16(sample_buf, 0)
	sample_buf.append(1) # key
	sample_buf.append(0) # pad
	_append_str(sample_buf, "TestEnv")
	_append_str(sample_buf, "")
	_append_u32(sample_buf, 0) # reserved
	for ch_idx in range(EnvironmentReader.CHANNEL_GROUP_FLOATS.size()):
		var group_floats: int = EnvironmentReader.CHANNEL_GROUP_FLOATS[ch_idx]
		if ch_idx == EnvironmentReader.CHANNEL_SUN_COLOR:
			_append_u32(sample_buf, 3)
			for group in [[1.0, 0.0, 0.0, 0.0], [0.0, 1.0, 0.0, 0.5], [0.0, 0.0, 1.0, 1.0]]:
				for v in group:
					_append_float(sample_buf, v)
		else:
			_append_u32(sample_buf, 1)
			for _k in range(group_floats):
				_append_float(sample_buf, 0.0)
	var sample_parsed := EnvironmentReader.parse(sample_buf)
	_check(sample_parsed != null, "parses the sample_color_channel test file")
	if sample_parsed != null:
		var rec: EnvironmentReader.Record = sample_parsed.records[0]
		var c_start := EnvironmentReader.sample_color_channel(rec, EnvironmentReader.CHANNEL_SUN_COLOR, 0.0)
		_check(c_start.is_equal_approx(Color(1, 0, 0)), "t=0 samples the first real keyframe exactly (got %s)" % c_start)
		var c_mid := EnvironmentReader.sample_color_channel(rec, EnvironmentReader.CHANNEL_SUN_COLOR, 0.25)
		_check(c_mid.is_equal_approx(Color(0.5, 0.5, 0, 1)), "t=0.25 lerps halfway between the t=0/t=0.5 keyframes (got %s)" % c_mid)
		# t=1.0 wraps to t=0.0 via fposmod (correct: a real day cycle loops,
		# and real data confirms the t=0/t=1 keyframes are identical) --
		# sample just under 1.0 instead to check the last real segment.
		var c_near_end := EnvironmentReader.sample_color_channel(rec, EnvironmentReader.CHANNEL_SUN_COLOR, 0.75)
		_check(c_near_end.is_equal_approx(Color(0, 0.5, 0.5, 1)), "t=0.75 lerps halfway between the t=0.5/t=1 keyframes (got %s)" % c_near_end)
		var c_wrap := EnvironmentReader.sample_color_channel(rec, EnvironmentReader.CHANNEL_SUN_COLOR, 1.25)
		_check(c_wrap.is_equal_approx(Color(0.5, 0.5, 0, 1)), "t=1.25 wraps to the same result as t=0.25 (got %s)" % c_wrap)
		var c_empty := EnvironmentReader.sample_color_channel(rec, EnvironmentReader.CHANNEL_SKY_TOP_COLOR, 0.5)
		_check(c_empty.is_equal_approx(Color(1, 1, 1)), "a channel with only 1 group falls back to a neutral color, not a guess (got %s)" % c_empty)

	_check(EnvironmentReader.parse(PackedByteArray([1, 2, 3])) == null, "rejects a buffer too small for a header")

	var bad_magic := data.duplicate()
	bad_magic[0] = 0x58
	_check(EnvironmentReader.parse(bad_magic) == null, "rejects bad magic")

	var bad_pad := data.duplicate()
	bad_pad[EnvironmentReader.MAGIC_LEN + 4 + 2 + 1] = 5 # the first record's pad byte
	_check(EnvironmentReader.parse(bad_pad) == null, "rejects a non-zero pad byte")

	var truncated := data.slice(0, data.size() - 4)
	_check(EnvironmentReader.parse(truncated) == null, "rejects a file truncated mid-record")

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
