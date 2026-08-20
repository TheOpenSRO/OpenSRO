extends SceneTree

## Exercises BanReader against a synthetic animation (never real game
## data), run headless:
## `godot4 --headless --path client --script res://scripts/ban/ban_reader_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _put_u32(b: PackedByteArray, off: int, v: int) -> void:
	b[off] = v & 0xFF
	b[off + 1] = (v >> 8) & 0xFF
	b[off + 2] = (v >> 16) & 0xFF
	b[off + 3] = (v >> 24) & 0xFF

func _append_u32(buf: PackedByteArray, v: int) -> PackedByteArray:
	var lp := PackedByteArray()
	lp.resize(4)
	_put_u32(lp, 0, v)
	var out := buf.duplicate()
	out.append_array(lp)
	return out

func _append_f32(buf: PackedByteArray, v: float) -> PackedByteArray:
	var lp := PackedByteArray()
	lp.resize(4)
	lp.encode_float(0, v)
	var out := buf.duplicate()
	out.append_array(lp)
	return out

func _append_len_prefixed(buf: PackedByteArray, s: String) -> PackedByteArray:
	var sb := s.to_ascii_buffer()
	buf = _append_u32(buf, sb.size())
	var out := buf.duplicate()
	out.append_array(sb)
	return out

func _append_keyframe(buf: PackedByteArray, rot: Quaternion, pos: Vector3) -> PackedByteArray:
	buf = _append_f32(buf, rot.x)
	buf = _append_f32(buf, rot.y)
	buf = _append_f32(buf, rot.z)
	buf = _append_f32(buf, rot.w)
	buf = _append_f32(buf, pos.x)
	buf = _append_f32(buf, pos.y)
	buf = _append_f32(buf, pos.z)
	return buf

func _build_animation(name: String, bones: Array) -> PackedByteArray:
	var buf := PackedByteArray()
	var magic := BanReader.MAGIC.to_ascii_buffer()
	buf.append_array(magic)
	buf = _append_u32(buf, 0)
	buf = _append_u32(buf, 0)
	buf = _append_len_prefixed(buf, name)
	buf = _append_u32(buf, 666)
	buf = _append_u32(buf, 30)
	buf = _append_u32(buf, 1)

	# Offset table: 2 entries of unconfirmed content.
	buf = _append_u32(buf, 2)
	buf = _append_u32(buf, 0)
	buf = _append_u32(buf, 0)

	buf = _append_u32(buf, bones.size())
	for bone in bones:
		var bone_name: String = bone[0]
		var keyframes: Array = bone[1]
		buf = _append_len_prefixed(buf, bone_name)
		buf = _append_u32(buf, keyframes.size())
		for kf in keyframes:
			buf = _append_keyframe(buf, kf[0], kf[1])
	return buf

func _init() -> void:
	var data := _build_animation("test_spin", [
		["Bone01", [
			[Quaternion(0, 0, 0, 1), Vector3.ZERO],
			[Quaternion(0.7071068, 0, 0, 0.7071068), Vector3(1, 2, 3)],
		]],
	])

	var a := BanReader.parse(data)
	_check(a != null, "parses synthetic animation")
	if a != null:
		_check(a.animation_name == "test_spin", "name matches (got %s)" % a.animation_name)
		_check(a.unknown1 == 666 and a.unknown2 == 30 and a.unknown3 == 1, "header fields match")
		_check(a.bones.size() == 1, "1 bone (got %d)" % a.bones.size())
		if a.bones.size() == 1:
			var b := a.bones[0]
			_check(b.bone_name == "Bone01", "bone name matches (got %s)" % b.bone_name)
			_check(b.keyframes.size() == 2, "2 keyframes (got %d)" % b.keyframes.size())
			if b.keyframes.size() == 2:
				_check(b.keyframes[1].position == Vector3(1, 2, 3), "keyframe 1 position matches (got %s)" % b.keyframes[1].position)
				_check(b.keyframes[1].rotation.is_equal_approx(Quaternion(0.7071068, 0, 0, 0.7071068)), "keyframe 1 rotation matches (got %s)" % b.keyframes[1].rotation)

	var multi := _build_animation("test_walk", [
		["Root", [[Quaternion(0, 0, 0, 1), Vector3.ZERO]]],
		["Spine", [[Quaternion(0, 0, 0, 1), Vector3.ZERO], [Quaternion(0, 0, 0, 1), Vector3.ZERO]]],
	])
	var multi_a := BanReader.parse(multi)
	_check(multi_a != null and multi_a.bones.size() == 2, "multi-bone animation parses (got %d bones)" % (multi_a.bones.size() if multi_a else -1))
	if multi_a != null and multi_a.bones.size() == 2:
		_check(multi_a.bones[1].bone_name == "Spine" and multi_a.bones[1].keyframes.size() == 2, "second bone matches")

	var bad_magic := PackedByteArray()
	bad_magic.resize(BanReader.MAGIC_LEN + 4)
	_check(BanReader.parse(bad_magic) == null, "rejects bad magic")

	var truncated := data.slice(0, data.size() - 10)
	_check(BanReader.parse(truncated) == null, "rejects truncated buffer")

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
