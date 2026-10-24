extends SceneTree

## Round 814: the guild line over a character and the own grant name
## (GuildPlateNet, NetClient's guild lines, World3D's _apply_guild_line, the
## console's /grantname). Synthetic data only. Run headless on the render box:
## `client/tools/remote_godot.sh script res://scripts/world/guild_plate_test.gd`
##
## NEGATIVE (by construction): against v0.1.575 GuildPlateNet does not exist
## and the suite stops at its first check; with GUILD_LINE_RAISE_PX at 0 the
## raise check fails; without the job-state test the suited check fails.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	var watchdog := create_timer(60.0)
	watchdog.timeout.connect(func() -> void:
		print("FAIL the suite never reported (a script error stopped it)")
		quit(1))
	if load("res://scripts/net/guild_plate_net.gd") == null:
		_check(false, "GuildPlateNet exists")
		quit(1)
		return
	_test_wire()
	_test_net_client()
	_test_console()
	var world := _make_world()
	if world != null:
		await process_frame
		await physics_frame
		_test_line(world)
		world.queue_free()
		await process_frame
	print("guild_plate_test: %s (%d failure(s))" % ["PASS" if _failures == 0 else "FAIL", _failures])
	quit(0 if _failures == 0 else 1)

## The layouts the server writes (server/internal/session
## TestGuildPlateMessagesBytes pins the same bytes).
func _test_wire() -> void:
	_check(GuildPlateNet.plate_text("Verizon", "Roaster") == "[Verizon * Roaster]", "with a grant name: [guild * grant]")
	_check(GuildPlateNet.plate_text("Verizon", "") == "[Verizon]", "without one: [guild]")
	_check(GuildPlateNet.plate_text("", "Roaster") == "", "no guild, no line")
	var req := GuildPlateNet.encode_grant(0x01020304, "Roaster")
	_check(req == PackedByteArray([4, 3, 2, 1, 7, 0]) + "Roaster".to_utf8_buffer(), "0x7256: u32 target, the name")
	var eg := PackedByteArray([5, 0, 0, 0, 9, 0, 0, 0, 2, 0]) + "Vz".to_utf8_buffer() + PackedByteArray([2, 0]) + "Ro".to_utf8_buffer()
	eg.resize(eg.size() + 14)
	var d := GuildPlateNet.decode_entity(eg)
	_check(d.get("uid") == 5 and d.get("guild_id") == 9 and d.get("guild_name") == "Vz" and d.get("nickname") == "Ro", "0x30FF with a guild (%s)" % [d])
	var none := GuildPlateNet.decode_entity(PackedByteArray([5, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
	_check(none.get("guild_name") == "" and none.get("nickname") == "", "0x30FF without one")
	_check(GuildPlateNet.decode_entity(eg.slice(0, 12)).is_empty(), "a cut 0x30FF is refused")
	var nu := PackedByteArray([9, 0, 0, 0, 4, 0]) + "Bram".to_utf8_buffer() + PackedByteArray([2, 0]) + "Ro".to_utf8_buffer()
	var n := GuildPlateNet.decode_nickname(nu)
	_check(n.get("name") == "Bram" and n.get("nickname") == "Ro" and n.get("guild_id") == 9, "0x3256 (%s)" % [n])
	var ok := GuildPlateNet.decode_grant_result(PackedByteArray([1, 9, 0, 0, 0, 5, 0, 0, 0, 2, 0]) + "Ro".to_utf8_buffer())
	_check(ok.get("ok") == true and ok.get("target") == 5 and ok.get("nickname") == "Ro", "0xB256 success")
	var no := GuildPlateNet.decode_grant_result(PackedByteArray([2, 0x4d, 0x4c]))
	_check(no.get("ok") == false and no.get("code") == GuildPlateNet.ERR_NAME, "0xB256 refusal 0x4c4d")

func _packet(op: int, data: PackedByteArray) -> Packet:
	var p := Packet.new()
	p.opcode = op
	p.data = data
	return p

## NetClient keeps each player's line from its spawn, takes 0x30FF and 0x3256,
## and the own line apart.
func _test_net_client() -> void:
	var nc = load("res://scripts/net/net_client.gd").new()
	var res := WorldNet.EnterWorldResult.new()
	res.ok = true
	res.frame = "97/168"
	nc.last_enter_world_result = res
	nc._start_user_view(res.frame)
	nc.set_spawn_item_rows({})
	var spawn := load("res://scripts/net/user_spawn_test.gd").GUILD_SINGLE.hex_decode() as PackedByteArray
	nc._user_spawn_message(NpcSpawnNet.OP_SINGLE_SPAWN, spawn)
	var g: Dictionary = nc.user_guilds.get(1, {})
	_check(g.get("guild_name") == "Verizon" and g.get("nickname") == "Roaster" and g.get("name") == "Aria", "Aria's line from her spawn (%s)" % [g])
	var changed := []
	nc.guild_line_changed.connect(func(uid: int) -> void: changed.append(uid))
	var nu := PackedByteArray([7, 0, 0, 0, 4, 0]) + "Aria".to_utf8_buffer() + PackedByteArray([3, 0]) + "Ace".to_utf8_buffer()
	nc._dispatch(_packet(GuildPlateNet.OP_NICKNAME_UPDATE, nu))
	_check(String((nc.user_guilds[1] as Dictionary)["nickname"]) == "Ace" and changed == [1], "0x3256 renames her (%s)" % [changed])
	nc._dispatch(_packet(GuildPlateNet.OP_ENTITY_GUILD, PackedByteArray([1, 0, 0, 0, 0, 0, 0, 0, 0, 0])))
	_check(String((nc.user_guilds[1] as Dictionary)["guild_name"]) == "" and String((nc.user_guilds[1] as Dictionary)["name"]) == "Aria", "0x30FF without a guild drops her line, her name kept")
	nc.own_character_id = 42
	nc.current_character_name = "Me"
	var own := PackedByteArray([42, 0, 0, 0, 7, 0, 0, 0, 7, 0]) + "Verizon".to_utf8_buffer() + PackedByteArray([0, 0])
	own.resize(own.size() + 14)
	nc._dispatch(_packet(GuildPlateNet.OP_ENTITY_GUILD, own))
	_check(String(nc.own_guild_line.get("guild_name", "")) == "Verizon" and changed.back() == 42, "the own line from 0x30FF about itself")
	var mine := PackedByteArray([7, 0, 0, 0, 2, 0]) + "Me".to_utf8_buffer() + PackedByteArray([3, 0]) + "Top".to_utf8_buffer()
	nc._dispatch(_packet(GuildPlateNet.OP_NICKNAME_UPDATE, mine))
	_check(String(nc.own_guild_line.get("nickname", "")) == "Top", "0x3256 for its own name sets the own grant name")
	var results := []
	nc.guild_grant_result.connect(func(d: Dictionary) -> void: results.append(d))
	nc._dispatch(_packet(GuildPlateNet.OP_GRANT_NAME_RESULT, PackedByteArray([2, 0x51, 0x4c])))
	_check(results.size() == 1 and int(results[0]["code"]) == GuildPlateNet.ERR_GUILD_LEVEL, "0xB256 reaches the world")
	nc._user_left(1)
	_check(not nc.user_guilds.has(1), "a player's line goes with its despawn")
	nc.free()

## /grantname sends the own grant name; over 12 bytes it does not.
func _test_console() -> void:
	var sent := []
	var logs := []
	var c := Console.new({"grant_name": func(n: String) -> void: sent.append(n), "log": func(l: String) -> void: logs.append(l)})
	c.submit("/grantname Roaster")
	c.submit("/grantname Big Roaster")
	c.submit("/grantname")
	c.submit("/grantname ABCDEFGHIJKLM")
	_check(sent == ["Roaster", "Big Roaster", ""], "/grantname sends the name, spaces kept, nothing clears (%s)" % [sent])
	_check(logs.size() == 1 and String(logs[0]).contains("12"), "13 bytes: the usage, nothing sent")
	_check(c.help_line().contains("/grantname"), "the help line names it")

func _make_world() -> Node:
	var sub := GDScript.new()
	sub.source_code = "\n".join(PackedStringArray([
		"extends \"res://scripts/World3D.gd\"",
		"func _ready() -> void:",
		"\tpass",
		"func _physics_process(_delta: float) -> void:",
		"\tpass",
		"func _process(_delta: float) -> void:",
		"\tpass",
		"func _exit_tree() -> void:",
		"\tpass",
		""]))
	_check(sub.reload() == OK and sub.can_instantiate(), "a subclass of World3D.gd compiles")
	var scene := load("res://scenes/World3D.tscn") as PackedScene
	if not sub.can_instantiate() or scene == null:
		return null
	var world: Node = scene.instantiate()
	world.set_script(sub)
	root.add_child(world)
	return world

## The line: its text, its plate (font 0, the box), GUILD_LINE_RAISE_PX over
## the name centred on the plate's point, the own colour, gone in a job suit,
## raised with the name on a mount.
func _test_line(world: Node) -> void:
	var body := Node3D.new()
	world.add_child(body)
	var plate := Label3D.new()
	plate.name = "Name"
	plate.text = "Pain"
	body.add_child(plate)
	world.call("_retail_plate_look", plate, Color.WHITE)
	world.call("_apply_guild_line", plate, body, {"guild_name": "Verizon", "nickname": "Roaster"}, UserSpawnNet.JOB_STATE_NONE, false, false)
	var g := body.get_node_or_null("GuildLine") as Label3D
	_check(g != null and g.text == "[Verizon * Roaster]", "another's line reads [Verizon * Roaster]")
	if g == null:
		return
	var fk := FontOversampling.factor()
	# Round 823, OURS: no box behind the guild line (the user's reference).
	_check(g.modulate == Color8(102, 185, 255) and g.outline_size == 0 and not bool(g.get_meta(NamePlates.BOX_META, false))
		and g.get_node_or_null("NameBox") == null, "light blue, font 0, with no box")
	_check(is_equal_approx(g.offset.y - plate.offset.y, 20.0 * fk) and is_zero_approx(g.offset.x) and g.pixel_size == plate.pixel_size,
		"20 px over the name, centred on the plate's point (%.2f)" % (g.offset.y - plate.offset.y))
	# Re-laid out with the name (a title, a UI re-scale): it follows.
	plate.offset.y = 3.0
	world.call("_layout_job_decor", plate, body)
	_check(is_equal_approx(g.offset.y, 3.0 + 20.0 * fk), "it follows the name's layout")
	world.call("_set_plate_y", body, plate, 55.0)
	_check(is_equal_approx(g.position.y, 55.0), "raised with the name over a mount")
	world.call("_apply_guild_line", plate, body, {"guild_name": "Verizon", "nickname": ""}, 2, false, false)
	_check(body.get_node_or_null("GuildLine") == null, "in a job suit there is no line")
	world.call("_apply_guild_line", plate, body, {"guild_name": "Verizon", "nickname": ""}, UserSpawnNet.JOB_STATE_NONE, true, false)
	var own := body.get_node_or_null("GuildLine") as Label3D
	_check(own != null and own.text == "[Verizon]" and own.modulate == Color8(254, 173, 46), "the own line, [Verizon], orange")
	world.call("_apply_guild_line", plate, body, {}, UserSpawnNet.JOB_STATE_NONE, true, false)
	_check(body.get_node_or_null("GuildLine") == null, "no guild, no line")
	body.queue_free()
