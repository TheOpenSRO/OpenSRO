extends SceneTree

## GuildWarMark (round 860): FUN_009ddb00's rule, `*`'s height, the war flag
## in 0x30FF and the "at war" set NetClient keeps -- pure, no game data.
## `godot4 --headless --path client --script res://scripts/effects/guild_war_mark860_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	process_frame.connect(_run, CONNECT_ONE_SHOT)

func _str(s: String) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(2)
	b.encode_u16(0, s.length())
	b.append_array(s.to_utf8_buffer())
	return b

func _run() -> void:
	var war := {77: true}
	_check(GuildWarMark.decide(77, war, 4) == GuildWarMark.ON, "a member of a guild at war, no suit: on")
	_check(GuildWarMark.decide(78, war, 4) == GuildWarMark.OFF, "a guild not at war: off")
	_check(GuildWarMark.decide(0, war, 4) == GuildWarMark.OFF, "no guild: off")
	_check(GuildWarMark.decide(77, war, 1) == GuildWarMark.KEEP, "a job suit: as it was (the original's quirk)")
	_check(GuildWarMark.decide(77, war, 4, true) == GuildWarMark.KEEP, "the fortress test: as it was")
	_check(is_equal_approx(GuildWarMark.star_height(2.0) + 16.0, 36.0), "a player (Size 2) wears it 36 above the feet")

	# 0x30FF with the fortress role, then the war flag.
	var d := PackedByteArray()
	d.resize(8)
	d.encode_u32(0, 0x11)
	d.encode_u32(4, 77)
	d.append_array(_str("Wolves"))
	d.append_array(_str("Grunt"))
	var tail := PackedByteArray()
	tail.resize(12)
	d.append_array(tail)
	d.append_array(PackedByteArray([0, 0]))
	var e := GuildPlateNet.decode_entity(d)
	_check(int(e.get("war_flag", -9)) == 0 and int(e["guild_id"]) == 77, "0x30FF: the second byte is the war flag (0: at war)")
	d[d.size() - 1] = 1
	_check(int(GuildPlateNet.decode_entity(d).get("war_flag", -9)) == 1, "... 1: not at war")
	_check(int(GuildPlateNet.decode_entity(d.slice(0, d.size() - 2)).get("war_flag", -9)) == -1, "an old server's short line: no flag")
	_finish()

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)
