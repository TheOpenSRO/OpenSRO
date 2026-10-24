extends SceneTree

## Round 821: the guild block (CharacterDependentData::FUN_009965e0's order,
## READ) parsed into GuildData, as the server's guild.EncodeBlock writes it
## (server/internal/guild/wire_test.go has the same bytes). No game data.
## `godot4 --headless --path client --script res://scripts/net/guild_data_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

var _b := PackedByteArray()

func _u8(v: int) -> void:
	_b.append(v)

func _u32(v: int) -> void:
	var x := PackedByteArray()
	x.resize(4)
	x.encode_u32(0, v)
	_b.append_array(x)

func _s(t: String) -> void:
	var raw := t.to_utf8_buffer()
	var x := PackedByteArray()
	x.resize(2)
	x.encode_u16(0, raw.size())
	_b.append_array(x)
	_b.append_array(raw)

func _member(id: int, name: String, cls: int, lv: int, gp: int, perm: int, nick: String, ref: int, offline: int) -> void:
	_u32(id)
	_s(name)
	_u8(cls)
	_u8(lv)
	_u32(gp)
	_u32(perm)
	_u32(0)
	_u32(0)
	_u32(0)
	_s(nick)
	_u32(ref)
	_u8(0)
	_u8(offline)

func _u16(v: int) -> void:
	var x := PackedByteArray()
	x.resize(2)
	x.encode_u16(0, v)
	_b.append_array(x)

## Round 822: 0x38F5 (FUN_00887330), as the server's guild.Encode* writes it.
func _updates(d: GuildData) -> void:
	var lines: Array = []
	var banners: Array = []
	d.line.connect(func(k: String, a: Array) -> void: lines.append([k, a]))
	d.banner.connect(func(w: String, k: String, a: Array) -> void: banners.append([w, k, a]))
	d.own_name = "Tess"
	# Nothing applies before a block.
	d.apply_update(PackedByteArray([GuildOpsNet.UPDATE_DISBANDED]))
	_check(lines.is_empty() and not d.in_guild, "no guild: a disband says nothing")
	_b = PackedByteArray()
	_u32(7)
	_s("Verizon")
	_u8(2)
	_u32(1234)
	_s("Hi")
	_s("Body")
	_u32(3)
	_u8(1)
	_u8(1)
	_member(10, "Tess", 0, 110, 50, 0xffffffff, "Boss", 1907, 0)
	_u8(0)
	_check(d.parse(_b), "a one-member block parses")
	# Type 2: Rook joins (offline flag 0 on the record, the siege byte ignored).
	_b = PackedByteArray()
	_u8(GuildOpsNet.UPDATE_MEMBER_ADD)
	_member(11, "Rook", 10, 30, 0, 0, "", 14875, 0)
	_b[_b.size() - 2] = 4
	d.apply_update(_b)
	var rook := d.member(11)
	_check(rook != null and rook.siege_authority == 0 and rook.online and lines.is_empty(), "type 2 adds Rook, siege 0, no line yet")
	# Type 6 bit 0x02 = 0: "joined", not "logged on".
	_b = PackedByteArray()
	_u8(GuildOpsNet.UPDATE_MEMBER)
	_u32(11)
	_u8(GuildOpsNet.MEMBER_FIELD_OFFLINE)
	_u8(0)
	d.apply_update(_b)
	_check(lines.size() == 1 and lines[0][0] == "UIIT_MSG_GUILD_JOIN_RESULT" and lines[0][1] == ["Rook"], "the first online update says joined (got %s)" % [lines])
	# Offline, then online again: logged off, logged on.
	_b = PackedByteArray()
	_u8(GuildOpsNet.UPDATE_MEMBER)
	_u32(11)
	_u8(GuildOpsNet.MEMBER_FIELD_LEVEL | GuildOpsNet.MEMBER_FIELD_OFFLINE)
	_u8(31)
	_u8(1)
	d.apply_update(_b)
	_check(not rook.online and rook.level == 31 and lines[-1][0] == "UIIT_MSG_GUILD_DISCONNECT", "level then offline, in bit order")
	_b[_b.size() - 1] = 0
	d.apply_update(_b)
	_check(rook.online and lines[-1][0] == "UIIT_MSG_GUILD_CONNECT" and lines[-1][1] == ["Rook"], "back online: logged on")
	# The player's own online line: the notice title follows; no "logged off" for oneself.
	var n0 := lines.size()
	_b = PackedByteArray()
	_u8(GuildOpsNet.UPDATE_MEMBER)
	_u32(10)
	_u8(GuildOpsNet.MEMBER_FIELD_OFFLINE)
	_u8(1)
	d.apply_update(_b)
	_check(lines.size() == n0, "the player's own offline update says nothing")
	_b[_b.size() - 1] = 0
	d.apply_update(_b)
	_check(lines[-1][0] == "UIIT_MSG_GUILD_CONNECT_NOTICE" and lines[-1][1] == ["Hi"], "own online: the guild post's title")
	# Type 6 permission and name.
	_b = PackedByteArray()
	_u8(GuildOpsNet.UPDATE_MEMBER)
	_u32(11)
	_u8(GuildOpsNet.MEMBER_FIELD_PERMISSION | GuildOpsNet.MEMBER_FIELD_NAME)
	_u32(3)
	_s("Rooky")
	d.apply_update(_b)
	_check(rook.permission == 3 and rook.member_name == "Rooky", "permission and name by mask")
	# Type 5: the wide name, level, GP, notice.
	_b = PackedByteArray()
	_u8(GuildOpsNet.UPDATE_GUILD)
	_u8(GuildOpsNet.GUILD_FIELD_NAME | GuildOpsNet.GUILD_FIELD_LEVEL | GuildOpsNet.GUILD_FIELD_GP | GuildOpsNet.GUILD_FIELD_NOTICE)
	var wide := "Verix".to_utf16_buffer()
	_u16(5)
	_b.append_array(wide)
	_u8(3)
	_u32(99)
	_s("T2")
	_s("B2")
	d.apply_update(_b)
	_check(d.guild_name == "Verix" and d.level == 3 and d.gp == 99 and d.notice_title == "T2", "type 5 fields in bit order")
	_check(lines[-1][0] == "UIIT_MSG_GUILD_LEVEL_UP_RESULT" and lines[-1][1] == [3], "level up line")
	_check(banners.size() == 1 and banners[0][0] == "warning" and banners[0][1] == "UIIT_MSG_GUILD_COMMON_KNOW_REMIND_UPDATE", "notice refreshed banner")
	# Type 3 reason 2 for someone else: the line, the record gone.
	_b = PackedByteArray()
	_u8(GuildOpsNet.UPDATE_MEMBER_OUT)
	_u32(11)
	_u8(GuildOpsNet.REMOVED_EXPELLED)
	d.apply_update(_b)
	_check(d.member(11) == null and d.in_guild and lines[-1][0] == "UIIT_MSG_GUILD_EXPULSION_RESULT" and lines[-1][1] == ["Rooky"], "expelled: the member's name")
	# Type 3 reason 1 for someone else says nothing.
	_b = PackedByteArray()
	_u8(GuildOpsNet.UPDATE_MEMBER_ADD)
	_member(12, "Pip", 10, 1, 0, 0, "", 1907, 0)
	d.apply_update(_b)
	var n1 := lines.size()
	_b = PackedByteArray()
	_u8(GuildOpsNet.UPDATE_MEMBER_OUT)
	_u32(12)
	_u8(GuildOpsNet.REMOVED_LEFT)
	d.apply_update(_b)
	_check(lines.size() == n1 and d.member(12) == null, "someone else's leave: removed silently")
	# Type 1: the break line, the banner, the record cleared.
	d.apply_update(PackedByteArray([GuildOpsNet.UPDATE_DISBANDED]))
	_check(not d.in_guild and lines[-1][0] == "UIIT_MSG_GUILD_BREAK_RESULT" and lines[-1][1] == ["Verix"]
		and banners[-1][0] == "notice", "disbanded: line, notice banner, cleared")
	# The player's own leave (reason 1): EXIT_RESULT with the guild's name.
	_b = PackedByteArray()
	_u32(7)
	_s("Again")
	_u8(1)
	_u32(0)
	_s("")
	_s("")
	_u32(0)
	_u8(0)
	_u8(1)
	_member(10, "Tess", 10, 110, 0, 0, "", 1907, 0)
	_u8(0)
	d.parse(_b)
	_b = PackedByteArray()
	_u8(GuildOpsNet.UPDATE_MEMBER_OUT)
	_u32(10)
	_u8(GuildOpsNet.REMOVED_LEFT)
	d.apply_update(_b)
	_check(not d.in_guild and lines[-1][0] == "UIIT_MSG_GUILD_EXIT_RESULT" and lines[-1][1] == ["Again"], "own leave: have left [guild]")

func _init() -> void:
	_u32(7)
	_s("Verizon")
	_u8(2)
	_u32(1234)
	_s("Hi")
	_s("Body")
	_u32(3)
	_u8(1)
	_u8(2)
	_member(10, "Tess", 0, 110, 50, 0xffffffff, "Boss", 1907, 0)
	_member(11, "Rook", 10, 30, 5, 0, "", 14875, 1)
	_u8(0)

	var d := GuildData.new()
	var changes := [0]
	d.changed.connect(func() -> void: changes[0] += 1)
	# Split over two chunks, as 0x3101 may carry it.
	d.handle(PackedByteArray(), GuildData.OP_BEGIN)
	d.handle(_b.slice(0, 20), GuildData.OP_CHUNK)
	d.handle(_b.slice(20), GuildData.OP_CHUNK)
	d.handle(PackedByteArray(), GuildData.OP_END)
	_check(changes[0] == 1 and d.in_guild, "the block parsed once, in a guild")
	_check(d.guild_id == 7 and d.guild_name == "Verizon" and d.level == 2 and d.gp == 1234, "id, name, level, GP")
	_check(d.notice_title == "Hi" and d.notice_body == "Body" and d.crest_rev == 3 and d.soldier_flags == 1, "notice, crest, soldier flags")
	_check(d.members.size() == 2, "two members")
	var m := d.master()
	_check(m != null and m.member_name == "Tess" and m.level == 110 and m.permission == 0xffffffff and m.nickname == "Boss"
		and m.ref_obj_id == 1907 and m.online, "the master, online")
	var r := d.member(11)
	_check(r != null and r.member_class == GuildData.CLASS_MEMBER and r.gp_donation == 5 and not r.online, "a member, offline")
	_check(d.max_members() == 20 and d.level_up_gp() == 50400, "level 2: cap 20, next level 50400 GP")

	# A short block leaves the record as it was.
	d.handle(PackedByteArray(), GuildData.OP_BEGIN)
	d.handle(_b.slice(0, 30), GuildData.OP_CHUNK)
	d.handle(PackedByteArray(), GuildData.OP_END)
	_check(changes[0] == 1 and d.guild_name == "Verizon", "a short block changes nothing")

	d.clear()
	_check(not d.in_guild and d.members.is_empty() and changes[0] == 2, "clear forgets the guild")

	_updates(GuildData.new())

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
