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

## An OpGuildLevelResult payload built by hand, byte for byte as
## session.GuildLevelResult.Encode writes it (round 528): the error string and
## a u16 code, then on success the guild id (s64), level (u8), levelled-up
## (u8), member cap (u16) and the next level's gold and guild points (s64).
func _build_level_result(error: String, code: int, guild_id: int, level: int, levelled_up: bool,
		max_members: int, next_gold: int, next_gp: int) -> PackedByteArray:
	var out := PackedByteArray()
	var u16 := PackedByteArray()
	u16.resize(2)
	var error_bytes := error.to_utf8_buffer()
	u16.encode_u16(0, error_bytes.size())
	out.append_array(u16)
	out.append_array(error_bytes)
	u16.encode_u16(0, code)
	out.append_array(u16)
	if error != "":
		return out
	var s64 := PackedByteArray()
	s64.resize(8)
	s64.encode_s64(0, guild_id)
	out.append_array(s64)
	out.append(level)
	out.append(1 if levelled_up else 0)
	u16.encode_u16(0, max_members)
	out.append_array(u16)
	s64.encode_s64(0, next_gold)
	out.append_array(s64)
	s64.encode_s64(0, next_gp)
	out.append_array(s64)
	return out

func _test_encode_level() -> void:
	var up := GuildNet.encode_level("Aria", true)
	_check(up.size() == 7 and up.decode_u16(0) == 4 and up[6] == 1,
		"level-up request is the name, then byte 1 (7 bytes)")
	var report := GuildNet.encode_level("Aria", false)
	_check(report.size() == 7 and report[6] == 0, "level report request ends in byte 0")
	_check(GuildNet.OP_LEVEL == 0x009A and GuildNet.OP_LEVEL_RESULT == 0x009B,
		"level opcodes are 0x009A / 0x009B, as session.OpGuildLevel")

func _test_decode_level_result() -> void:
	var payload := _build_level_result("", 0, 7, 2, true, 20, 9000000, 50400)
	var r := GuildNet.decode_level_result(payload)
	_check(r.error == "" and r.code == 0, "level: no decode error")
	_check(r.guild_id == 7, "level: guild id round-trips")
	_check(r.level == 2 and r.levelled_up, "level: level 2, levelled up")
	_check(r.max_members == 20, "level: the member cap round-trips")
	_check(r.next_gold == 9000000 and r.next_gp == 50400, "level: the next level's cost round-trips")

	var refused := GuildNet.decode_level_result(
		_build_level_result("not enough guild points to level up the guild", 0x4c32, 0, 0, false, 0, 0, 0))
	_check(refused.error == "not enough guild points to level up the guild", "level: the refusal's words round-trip")
	_check(refused.code == 0x4c32, "level: the refusal's engine code round-trips")
	_check(refused.level == 0 and not refused.levelled_up, "level: nothing alongside a refusal")

	# NEGATIVE: a body cut short is an error, not a zero cost.
	var cut := payload.slice(0, payload.size() - 1)
	_check(GuildNet.decode_level_result(cut).error != "", "level: a truncated reply is an error")
	var no_code := _build_level_result("x", 0, 0, 0, false, 0, 0, 0).slice(0, 3)
	_check(GuildNet.decode_level_result(no_code).error == "truncated error field",
		"level: a refusal without its code is an error")

func _init() -> void:
	_test_encode_create()
	_test_encode_join()
	_test_decode_result()
	_test_decode_result_error()
	_test_decode_leave_result()
	_test_encode_points()
	_test_decode_points_result()
	_test_encode_level()
	_test_decode_level_result()

## World3D's Guild tab after a level reply (round 528), on a bare World3D (no
## scene; the tab's nodes are set by hand). This runs in _initialize, not
## _init: World3D names the NetClient autoload, which a --script suite
## registers only after _init (error_text_test.gd does the same).
func _test_world_guild_level() -> void:
	var world_script := load("res://scripts/World3D.gd") as GDScript
	var world_ok := world_script != null and world_script.can_instantiate()
	_check(world_ok, "World3D compiles in _initialize")
	if not world_ok:
		return
	var world: Node = world_script.new()
	var status := Label.new()
	var button := Button.new()
	var chat := RichTextLabel.new()
	button.visible = false
	world.set("guild_status_label", status)
	world.set("guild_level_up_button", button)
	world.set("chat_log", chat)
	var roster := GuildNet.Result.new()
	roster.guild_id = 7
	roster.guild_name = "Silk Legion"
	var lead := GuildNet.Member.new()
	lead.member_name = "Aria"
	lead.role = GuildNet.ROLE_LEADER
	roster.members.append(lead)
	world.set("_guild_roster", roster)
	world.set("_guild_id", 7)
	world.set("_guild_master", true)

	world.call("_on_guild_level_result", GuildNet.decode_level_result(
		_build_level_result("", 0, 7, 2, false, 20, 9000000, 50400)))
	_check(status.text == "Silk Legion (#7, level 2, 1/20 members).",
		"the Guild tab shows the level and the cap (got '%s')" % status.text)
	_check(button.visible and not button.disabled and button.text == "Level Up Guild (9000000 gold, 50400 GP)",
		"the master's button quotes the next level's cost (got '%s')" % button.text)

	world.call("_on_guild_level_result", GuildNet.decode_level_result(
		_build_level_result("", 0, 7, 5, false, 50, 0, 0)))
	_check(button.visible and button.disabled, "at level 5 the button is shown but disabled")

	# NEGATIVE: a reply for another guild changes nothing.
	world.call("_on_guild_level_result", GuildNet.decode_level_result(
		_build_level_result("", 0, 8, 3, false, 25, 15000000, 135000)))
	_check(status.text == "Silk Legion (#7, level 5, 1/50 members).",
		"a level reply for another guild is ignored (got '%s')" % status.text)

	# NEGATIVE: a member who is not the master gets no button.
	world.set("_guild_master", false)
	world.call("_refresh_guild_level_button")
	_check(not button.visible, "a member who is not the master sees no level-up button")

	world.free()
	status.free()
	button.free()
	chat.free()

func _initialize() -> void:
	_test_world_guild_level()

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
