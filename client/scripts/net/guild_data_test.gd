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

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
