extends SceneTree

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _test_encode_create() -> void:
	var encoded := GuildNet.encode_create("Aria", "Silk Legion")
	_check(encoded.decode_u16(0) == 4, "character name length prefix is 4")
	var guild_name_len_offset := 2 + 4
	_check(encoded.decode_u16(guild_name_len_offset) == 11, "guild name length prefix is 11")

func _test_encode_join() -> void:
	var encoded := GuildNet.encode_join("Bram", 1)
	_check(encoded.decode_u16(0) == 4, "name length prefix is 4")
	_check(encoded.decode_s64(6) == 1, "guild id round-trips")

func _build_result(error: String, guild_id: int, guild_name: String, leader_id: int, members: Array) -> PackedByteArray:
	var out := PackedByteArray()
	var error_bytes := error.to_utf8_buffer()
	var len_buf := PackedByteArray()
	len_buf.resize(2)
	len_buf.encode_u16(0, error_bytes.size())
	out.append_array(len_buf)
	out.append_array(error_bytes)
	if error != "":
		return out

	var id_buf := PackedByteArray()
	id_buf.resize(8)
	id_buf.encode_s64(0, guild_id)
	out.append_array(id_buf)

	var name_bytes := guild_name.to_utf8_buffer()
	len_buf.encode_u16(0, name_bytes.size())
	out.append_array(len_buf)
	out.append_array(name_bytes)

	var leader_buf := PackedByteArray()
	leader_buf.resize(8)
	leader_buf.encode_s64(0, leader_id)
	out.append_array(leader_buf)

	var count_buf := PackedByteArray()
	count_buf.resize(2)
	count_buf.encode_u16(0, members.size())
	out.append_array(count_buf)

	for m in members:
		var mid_buf := PackedByteArray()
		mid_buf.resize(8)
		mid_buf.encode_s64(0, m["id"])
		out.append_array(mid_buf)
		var mname_bytes: PackedByteArray = m["name"].to_utf8_buffer()
		len_buf.encode_u16(0, mname_bytes.size())
		out.append_array(len_buf)
		out.append_array(mname_bytes)
		var role_buf := PackedByteArray()
		role_buf.resize(4)
		role_buf.encode_u32(0, m["role"])
		out.append_array(role_buf)

	return out

func _test_decode_result() -> void:
	var payload := _build_result("", 1, "Silk Legion", 100,
		[{"id": 100, "name": "Aria", "role": GuildNet.ROLE_LEADER}, {"id": 200, "name": "Bram", "role": GuildNet.ROLE_MEMBER}])
	var result := GuildNet.decode_result(payload)
	_check(result.error == "", "no decode error")
	_check(result.guild_id == 1, "guild id round-trips")
	_check(result.guild_name == "Silk Legion", "guild name round-trips")
	_check(result.leader_id == 100, "leader id round-trips")
	_check(result.members.size() == 2, "two members decoded")
	if result.members.size() == 2:
		_check(result.members[0].character_id == 100, "first member id round-trips")
		_check(result.members[0].member_name == "Aria", "first member name round-trips")
		_check(result.members[0].role == GuildNet.ROLE_LEADER, "first member role round-trips")
		_check(result.members[1].role == GuildNet.ROLE_MEMBER, "second member role round-trips")

func _test_decode_result_error() -> void:
	var payload := _build_result("guild name already taken", 0, "", 0, [])
	var result := GuildNet.decode_result(payload)
	_check(result.error == "guild name already taken", "error round-trips")
	_check(result.members.size() == 0, "no members alongside an error")

func _test_decode_leave_result() -> void:
	var payload := PackedByteArray([1, 0, 0])
	var result := GuildNet.decode_leave_result(payload)
	_check(result.error == "", "no decode error")
	_check(result.ok, "ok is true")

## An OpGuildPointsResult payload built by hand, byte for byte as
## session.GuildPointsResult.Encode writes it (round 525): the error string,
## then guild id (s64), GatheredSP (s64), a u16 count and per member a
## u16-prefixed name and GP_Donation (s64).
func _build_points_result(error: String, guild_id: int, gathered_sp: int, members: Array) -> PackedByteArray:
	var out := PackedByteArray()
	var len_buf := PackedByteArray()
	len_buf.resize(2)
	var error_bytes := error.to_utf8_buffer()
	len_buf.encode_u16(0, error_bytes.size())
	out.append_array(len_buf)
	out.append_array(error_bytes)
	if error != "":
		return out
	var s64 := PackedByteArray()
	s64.resize(8)
	s64.encode_s64(0, guild_id)
	out.append_array(s64)
	s64.encode_s64(0, gathered_sp)
	out.append_array(s64)
	len_buf.encode_u16(0, members.size())
	out.append_array(len_buf)
	for m in members:
		var name_bytes: PackedByteArray = String(m["name"]).to_utf8_buffer()
		len_buf.encode_u16(0, name_bytes.size())
		out.append_array(len_buf)
		out.append_array(name_bytes)
		s64.encode_s64(0, int(m["gp"]))
		out.append_array(s64)
	return out

func _test_encode_points() -> void:
	var encoded := GuildNet.encode_points("Aria")
	_check(encoded.size() == 6, "points request is a name only (6 bytes)")
	_check(encoded.decode_u16(0) == 4, "points request name length prefix is 4")
	_check(GuildNet.OP_POINTS == 0x0098 and GuildNet.OP_POINTS_RESULT == 0x0099,
		"points opcodes are 0x0098 / 0x0099, as session.OpGuildPoints")

func _test_decode_points_result() -> void:
	var payload := _build_points_result("", 7, 5412,
		[{"name": "Aria", "gp": 5400}, {"name": "Bram", "gp": 12}])
	var result := GuildNet.decode_points_result(payload)
	_check(result.error == "", "points: no decode error")
	_check(result.guild_id == 7, "points: guild id round-trips")
	_check(result.gathered_sp == 5412, "points: GatheredSP round-trips")
	_check(result.members.size() == 2, "points: two members decoded")
	if result.members.size() == 2:
		_check(result.members[0].member_name == "Aria", "points: first name round-trips")
		_check(result.members[0].gp_donation == 5400, "points: first GP_Donation round-trips")
		_check(result.members[1].member_name == "Bram", "points: second name round-trips")
		_check(result.members[1].gp_donation == 12, "points: second GP_Donation round-trips")

	var refused := GuildNet.decode_points_result(_build_points_result("not in a guild", 0, 0, []))
	_check(refused.error == "not in a guild", "points: the refusal round-trips")
	_check(refused.members.size() == 0 and refused.gathered_sp == 0, "points: nothing alongside a refusal")

	# A body cut short is an error, not a zero donation.
	var cut := payload.slice(0, payload.size() - 1)
	_check(GuildNet.decode_points_result(cut).error != "", "points: a truncated reply is an error")

func _init() -> void:
	_test_encode_create()
	_test_encode_join()
	_test_decode_result()
	_test_decode_result_error()
	_test_decode_leave_result()
	_test_encode_points()
	_test_decode_points_result()

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
