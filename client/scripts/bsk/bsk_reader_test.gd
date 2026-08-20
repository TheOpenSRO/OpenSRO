extends SceneTree

## Exercises BskReader against a synthetic skeleton (never real game data),
## run headless:
## `godot4 --headless --path client --script res://scripts/bsk/bsk_reader_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _append_u32(buf: PackedByteArray, v: int) -> PackedByteArray:
	var lp := PackedByteArray()
	lp.resize(4)
	lp[0] = v & 0xFF
	lp[1] = (v >> 8) & 0xFF
	lp[2] = (v >> 16) & 0xFF
	lp[3] = (v >> 24) & 0xFF
	var out := buf.duplicate()
	out.append_array(lp)
	return out

func _append_len_prefixed(buf: PackedByteArray, s: String) -> PackedByteArray:
	var sb := s.to_ascii_buffer()
	buf = _append_u32(buf, sb.size())
	var out := buf.duplicate()
	out.append_array(sb)
	return out

func _append_zeros(buf: PackedByteArray, n: int) -> PackedByteArray:
	var pad := PackedByteArray()
	pad.resize(n)
	var out := buf.duplicate()
	out.append_array(pad)
	return out

func _build_skeleton() -> PackedByteArray:
	var buf := PackedByteArray()
	var magic := BskReader.MAGIC.to_ascii_buffer()
	buf.append_array(magic)
	buf = _append_u32(buf, 0)     # unconfirmed u32 at 0x0c
	buf.append_array(PackedByteArray([0])) # the extra byte before the root name
	buf = _append_len_prefixed(buf, "[root]")
	buf = _append_zeros(buf, BskReader.ROOT_TRANSFORM_LEN)

	# BoneA: announced early (like a real file's opening run of
	# announcements) but not resolved until much later, using the
	# parent-less "Type A" shape (92-byte transform, no parent name).
	buf = _append_len_prefixed(buf, "BoneA")

	# BoneB: resolves immediately (name repeated right away) -- the
	# ordinary "Type B" shape (parent name + 88-byte transform). Parented
	# to BoneA, even though BoneA isn't resolved yet -- the parent field is
	# just a name string, independent of resolution order.
	buf = _append_len_prefixed(buf, "BoneB")
	buf = _append_len_prefixed(buf, "BoneB")
	buf = _append_len_prefixed(buf, "BoneA")
	buf = _append_zeros(buf, BskReader.BONE_TRANSFORM_LEN)

	# BoneC: announced, then its own announcement is what resolves BoneA
	# (BoneA reappears here, resolved via Type A) before BoneC itself
	# resolves later still -- exercises interleaved announce/resolve
	# pairs, confirmed on real Biped-style files.
	buf = _append_len_prefixed(buf, "BoneC")
	buf = _append_len_prefixed(buf, "BoneA")
	buf = _append_zeros(buf, BskReader.ROOT_TRANSFORM_LEN) # resolves BoneA (Type A)

	# BoneC finally resolves (Type B, parented to BoneB).
	buf = _append_len_prefixed(buf, "BoneC")
	buf = _append_len_prefixed(buf, "BoneB")
	buf = _append_zeros(buf, BskReader.BONE_TRANSFORM_LEN)

	buf = _append_zeros(buf, 8) # trailer, observed constant zero
	return buf

func _init() -> void:
	var data := _build_skeleton()

	var s := BskReader.parse(data)
	_check(s != null, "parses synthetic skeleton")
	if s != null:
		_check(s.root_name == "[root]", "root name matches (got %s)" % s.root_name)
		_check(s.bones.size() == 3, "3 bones (got %d)" % s.bones.size())

		var by_name := {}
		for b in s.bones:
			by_name[b.bone_name] = b

		var bone_b: BskReader.Bone = by_name.get("BoneB")
		_check(bone_b != null and bone_b.parent_name == "BoneA", "BoneB's parent is BoneA")
		if bone_b != null:
			_check(bone_b.transform.size() == BskReader.BONE_TRANSFORM_LEN, "BoneB transform length matches")

		var bone_a: BskReader.Bone = by_name.get("BoneA")
		_check(bone_a != null and bone_a.parent_name == "", "BoneA has no parent")
		if bone_a != null:
			_check(bone_a.transform.size() == BskReader.ROOT_TRANSFORM_LEN, "BoneA transform length matches")

		var bone_c: BskReader.Bone = by_name.get("BoneC")
		_check(bone_c != null and bone_c.parent_name == "BoneB", "BoneC's parent is BoneB")
		if bone_c != null:
			_check(bone_c.transform.size() == BskReader.BONE_TRANSFORM_LEN, "BoneC transform length matches")

	var bad_magic := PackedByteArray()
	bad_magic.resize(BskReader.MAGIC_LEN + 10)
	_check(BskReader.parse(bad_magic) == null, "rejects bad magic")

	var truncated := data.slice(0, BskReader.MAGIC_LEN + 10)
	_check(BskReader.parse(truncated) == null, "rejects truncated buffer")

	var orphan := PackedByteArray()
	orphan.append_array(BskReader.MAGIC.to_ascii_buffer())
	orphan = _append_u32(orphan, 0)
	orphan.append_array(PackedByteArray([0]))
	orphan = _append_len_prefixed(orphan, "[root]")
	orphan = _append_zeros(orphan, BskReader.ROOT_TRANSFORM_LEN)
	orphan = _append_len_prefixed(orphan, "Orphan") # announced, never resolved
	orphan = _append_zeros(orphan, 8) # trailer
	_check(BskReader.parse(orphan) == null, "rejects an announcement with no matching resolution")

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
