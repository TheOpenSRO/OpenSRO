extends SceneTree

## Round 842 (lane P): a guild line's colour by its guild's relation to the
## player's (GuildLineColour, READ FUN_009a4f40 / FUN_009dc460 /
## FUN_009a4450), the union record it reads (UnionData: 0x3102, 0x38F5 types
## 0x0d and 0x12, as the server's guild.EncodeUnion* writes them --
## server/internal/guild/round842_test.go pins the same bytes), the lines
## recoloured live, and a stall title's box staying with the title instead
## of behind the name. Synthetic data only.
##   client/tools/remote_godot.sh script res://scripts/world/guild_colour842_test.gd
##
## NEGATIVE (by construction): with round 841's colour (orange only for the
## own line) a fellow member's line is light blue and the "same guild" check
## fails; with the title's box fitted only when it is made, its box sits on
## the name's line and the box checks fail.

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
	_test_colours()
	_test_union()
	var world := _make_world()
	if world != null:
		await process_frame
		await physics_frame
		_test_live(world)
		_test_stall_box(world)
		world.queue_free()
		await process_frame
	print("guild_colour842_test: %s (%d failure(s))" % ["PASS" if _failures == 0 else "FAIL", _failures])
	quit(0 if _failures == 0 else 1)

func _test_colours() -> void:
	_check(GuildLineColour.OWN == Color8(0xfe, 0xad, 0x2e) and GuildLineColour.ALLY == Color8(0xa0, 0xfe, 0x68)
		and GuildLineColour.HOSTILE == Color8(0xff, 0, 0) and GuildLineColour.OTHER == Color8(0x66, 0xb9, 0xff),
		"the READ ARGB: own 0xfffead2e, union 0xffa0fe68, hostile 0xffff0000, others 0xff66b9ff")
	var allied := func(n: String) -> bool: return n == "Beta"
	var hostile := func(n: String) -> bool: return n == "Gamma" or n == "Beta"
	_check(GuildLineColour.colour_for("OFWS", "OFWS", allied, hostile) == GuildLineColour.OWN, "a fellow member of the own guild: orange")
	_check(GuildLineColour.colour_for("Beta", "OFWS", allied, hostile) == GuildLineColour.ALLY, "a union guild: green, before the hostile test")
	_check(GuildLineColour.colour_for("Gamma", "OFWS", allied, hostile) == GuildLineColour.HOSTILE, "a hostile guild: red")
	_check(GuildLineColour.colour_for("Delta", "OFWS", allied, hostile) == GuildLineColour.OTHER, "any other guild: light blue")
	_check(GuildLineColour.colour_for("OFWS", "", allied) == GuildLineColour.OTHER, "with no own guild, nobody is orange")
	_check(GuildLineColour.colour_for("ofws", "OFWS") == GuildLineColour.OTHER, "the name is compared exactly (wcsncmp)")

## The entry the server writes: u32 id, str name, u8 level, str master, u32,
## u8.
func _entry(id: int, name: String, level: int, master: String, model: int, members: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_u32(0, id)
	b.append_array(_str(name))
	b.append(level)
	b.append_array(_str(master))
	var m := PackedByteArray()
	m.resize(4)
	m.encode_u32(0, model)
	b.append_array(m)
	b.append(members)
	return b

func _str(t: String) -> PackedByteArray:
	var raw := t.to_utf8_buffer()
	var b := PackedByteArray([raw.size() & 0xff, raw.size() >> 8])
	b.append_array(raw)
	return b

func _info(uid: int, crest: int, leader: int, entries: Array) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(12)
	b.encode_u32(0, uid)
	b.encode_u32(4, crest)
	b.encode_u32(8, leader)
	b.append(entries.size())
	for e in entries:
		b.append_array(e)
	return b

func _test_union() -> void:
	# The server test's bytes (guild.TestRound842UnionBytes).
	var want := PackedByteArray([
		7, 0, 0, 0, 3, 0, 0, 0, 11, 0, 0, 0, 2,
		11, 0, 0, 0, 2, 0, 0x41, 0x62, 2, 1, 0, 0x4d, 7, 7, 0, 0, 5,
		12, 0, 0, 0, 1, 0, 0x43, 4, 2, 0, 0x4e, 0x6e, 8, 7, 0, 0, 1])
	_check(_info(7, 3, 11, [_entry(11, "Ab", 2, "M", 0x0707, 5), _entry(12, "C", 4, "Nn", 0x0708, 1)]) == want,
		"the test's 0x3102 bytes are the server's")
	var d := GuildData.new()
	d.in_guild = true
	d.guild_id = 11
	d.guild_name = "Ab"
	var lines: Array = []
	d.line.connect(func(key: String, args: Array) -> void: lines.append([key, args]))
	var changes := [0]
	d.union.changed.connect(func() -> void: changes[0] += 1)
	d.handle(want, GuildData.OP_UNION_INFO)
	var u := d.union
	_check(u.union_id == 7 and u.crest_rev == 3 and u.leader_guild_id == 11 and u.guilds.size() == 2 and changes[0] == 1,
		"0x3102: the union's id, crest, first guild and two entries")
	var e: UnionData.Entry = u.guilds.get(12)
	_check(e != null and e.guild_name == "C" and e.level == 4 and e.master == "Nn" and e.master_model == 0x0708 and e.members == 1, "an entry's fields")
	_check(u.is_allied("Ab") and u.is_allied("C") and not u.is_allied("Other") and not u.is_allied(""), "is_allied by name")
	_check(not u.parse_info(want.slice(0, want.size() - 1)) and u.guilds.size() == 2, "a cut record changes nothing")
	# Type 0x0d: a third guild.
	var j := PackedByteArray([UnionData.UPDATE_JOINED])
	j.append_array(_entry(13, "Dee", 3, "Q", 0, 2))
	d.apply_update(j)
	_check(u.is_allied("Dee") and u.guilds.size() == 3 and lines.back() == ["UIIT_MSG_GUILD_ALLY_JOIN_RESULT", ["Dee"]],
		"0x38F5 0x0d adds it, with ALLY_JOIN_RESULT [Dee]")
	# Type 0x12 kind 1 about another: that guild alone goes (3 before).
	d.apply_update(PackedByteArray([UnionData.UPDATE_OUT, 1, 13, 0, 0, 0]))
	_check(not u.is_allied("Dee") and u.guilds.size() == 2 and lines.back() == ["UIIT_MSG_GUILD_ALLY_EXIT_RESULT", ["Dee"]],
		"0x12 kind 1: Dee leaves, ALLY_EXIT_RESULT")
	# Kind 2 about another with two before: only it goes (the map's size
	# before the removal is tested, 0x988a60 < 2).
	d.apply_update(PackedByteArray([UnionData.UPDATE_OUT, 2, 12, 0, 0, 0]))
	_check(u.guilds.size() == 1 and u.is_allied("Ab") and lines.back() == ["UIIT_MSG_GUILD_RESPECT_ALLY_EXPEL_RESULT", ["C"]],
		"0x12 kind 2 with two guilds: C alone is taken out, EXPEL_RESULT")
	d.handle(want, GuildData.OP_UNION_INFO)
	# Kind 1 about the own guild: the whole union goes.
	d.apply_update(PackedByteArray([UnionData.UPDATE_OUT, 1, 11, 0, 0, 0]))
	_check(not u.in_union() and u.union_id == 0, "0x12 about the own guild clears the union")
	d.handle(want, GuildData.OP_UNION_INFO)
	d.apply_update(PackedByteArray([UnionData.UPDATE_OUT, 3]))
	_check(not u.in_union() and lines.back() == ["UIIT_MSG_QUESTION_GUILD_RESPECT_ALLY_BREAKUP", []], "0x12 kind 3: broken, cleared")
	d.handle(want, GuildData.OP_UNION_INFO)
	d.handle(_info(0, 0, 0, []), GuildData.OP_UNION_INFO)
	_check(not u.in_union() and u.union_id == 0, "an empty record (the server's no union) clears it")
	d.handle(want, GuildData.OP_UNION_INFO)
	d.clear()
	_check(not u.in_union(), "out of the guild, out of the union")
	_check(GuildData.SERVER_OPCODES.has(0x3102), "GuildData takes 0x3102")

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

## Another player's body with a name plate, its guild line drawn.
func _other(world: Node, uid: int, char_name: String, guild_name: String) -> Node3D:
	var nc = root.get_node("NetClient")
	var body := Node3D.new()
	body.set_meta("character_id", uid)
	world.add_child(body)
	var plate := Label3D.new()
	plate.name = "Name"
	plate.text = char_name
	body.add_child(plate)
	world.call("_retail_plate_look", plate, Color.WHITE)
	(world.get("_other_bodies") as Dictionary)[uid] = body
	nc.user_roster[uid] = true
	nc.user_guilds[uid] = {"guild_id": 1, "guild_name": guild_name, "nickname": "", "name": char_name}
	world.call("_apply_guild_line", plate, body, nc.user_guilds[uid], UserSpawnNet.JOB_STATE_NONE, false, false)
	return body

func _line_colour(body: Node3D) -> Color:
	var g := body.get_node_or_null("GuildLine") as Label3D
	return g.modulate if g != null else Color(0, 0, 0, 0)

## The user's case: Pain in OFWS, Tobi in OFWS too, a union guild, another.
func _test_live(world: Node) -> void:
	var nc = root.get_node("NetClient")
	# World3D._ready's two connections (the test's subclass skips _ready).
	nc.guild_data.union.changed.connect(Callable(world, "_recolour_guild_lines"))
	nc.guild_line_changed.connect(Callable(world, "_on_guild_line_changed"))
	nc.own_guild_line = {"guild_id": 1, "guild_name": "OFWS", "nickname": "RatSlayer"}
	nc.guild_data.in_guild = true
	nc.guild_data.guild_id = 1
	nc.guild_data.guild_name = "OFWS"
	var tobi := _other(world, 501, "Tobi", "OFWS")
	var ally := _other(world, 502, "Ally", "Beta")
	var other := _other(world, 503, "Other", "Gamma")
	_check(_line_colour(tobi) == GuildLineColour.OWN, "Tobi, in the player's guild: orange like the own line (%s)" % _line_colour(tobi))
	_check(_line_colour(ally) == GuildLineColour.OTHER and _line_colour(other) == GuildLineColour.OTHER,
		"Beta and Gamma, no union yet: light blue")
	# Beta allies with OFWS: 0x3102 -> every line recoloured.
	nc.guild_data.handle(_info(4, 0, 1, [_entry(1, "OFWS", 5, "Pain", 0, 2), _entry(2, "Beta", 2, "Ally", 0, 1)]), GuildData.OP_UNION_INFO)
	_check(_line_colour(ally) == GuildLineColour.ALLY and _line_colour(tobi) == GuildLineColour.OWN and _line_colour(other) == GuildLineColour.OTHER,
		"after 0x3102: Beta green, Tobi still orange (the own entry wins), Gamma blue (%s %s %s; union %s)"
		% [_line_colour(ally), _line_colour(tobi), _line_colour(other), nc.guild_data.union.guilds.keys()])
	# A player spawning into view afterwards takes the colour at once.
	var late := _other(world, 504, "Late", "Beta")
	_check(_line_colour(late) == GuildLineColour.ALLY, "a union member spawning later: green")
	# Beta leaves the union (0x38F5 0x12, two guilds before: Beta alone out).
	nc.guild_data.apply_update(PackedByteArray([UnionData.UPDATE_OUT, 1, 2, 0, 0, 0]))
	_check(_line_colour(ally) == GuildLineColour.OTHER and _line_colour(late) == GuildLineColour.OTHER, "Beta left: blue again, live")
	# The player leaves OFWS: the own line goes, Tobi is light blue.
	# (Beta's leave left OFWS alone in the union, as the original's client
	# does with two guilds before; the own leave's 0x38F5 type 3 clears the
	# guild and so the union.)
	_check(nc.guild_data.union.is_allied("OFWS") and nc.guild_data.union.guilds.size() == 1, "OFWS alone stays in the union record")
	nc.guild_data.clear()
	nc.own_character_id = 77
	nc._guild_line_update({"uid": 77, "guild_id": 0, "guild_name": "", "nickname": ""})
	_check(_line_colour(tobi) == GuildLineColour.OTHER, "the player out of OFWS: Tobi light blue, live (%s, own %s, id %s)"
		% [_line_colour(tobi), nc.own_guild_line, nc.own_character_id])
	# And joins Gamma: Gamma's lines turn orange.
	var own := PackedByteArray([77, 0, 0, 0, 3, 0, 0, 0]) + _str("Gamma") + _str("")
	own.resize(own.size() + 14)
	nc._guild_line_update(GuildPlateNet.decode_entity(own))
	_check(_line_colour(other) == GuildLineColour.OWN and _line_colour(tobi) == GuildLineColour.OTHER, "the player into Gamma: Gamma's line orange")
	# Tobi's own line changes (0x30FF): re-made in its new colour.
	nc._guild_line_update({"uid": 501, "guild_id": 3, "guild_name": "Gamma", "nickname": ""})
	_check(_line_colour(tobi) == GuildLineColour.OWN, "Tobi joining Gamma too: orange")
	for b in [tobi, ally, other, late]:
		var id := int(b.get_meta("character_id"))
		(world.get("_other_bodies") as Dictionary).erase(id)
		nc.user_roster.erase(id)
		nc.user_guilds.erase(id)
		b.queue_free()
	nc.own_guild_line = {}
	nc.own_character_id = -1
	nc.guild_data.clear()

## The stall title's box hangs at the title, not behind the name: the name's
## box keeps the name's width with the stall open, the title has its own.
func _test_stall_box(world: Node) -> void:
	var nc = root.get_node("NetClient")
	var body := _other(world, 601, "Tobi", "OFWS")
	var plate := body.get_node("Name") as Label3D
	var name_box := plate.get_node_or_null("NameBox") as Sprite3D
	var before := name_box.texture.get_size() if name_box != null and name_box.texture != null else Vector2.ZERO
	nc.stalls[601] = {"owner": 601, "name": "[Tobi]'s stall.", "decoration": 0}
	var sw := StallWorld.new(world)
	sw.apply(601, body, 0, 10.0)
	var title := body.get_node_or_null(StallWorld.TITLE_NODE) as Label3D
	_check(title != null and title.text == "[[Tobi]'s stall.]", "the title reads \"[\" + the stall's name + \"]\" (c:0x9dc3a0): %s" % (title.text if title != null else "none"))
	if title == null:
		return
	var tbox := title.get_node_or_null("NameBox") as Sprite3D
	_check(tbox != null and tbox.texture != null, "the title has its own box (c:0x9c89ca, the 0x40000000 box)")
	if tbox == null or tbox.texture == null:
		return
	var r := NamePlates.box_rect(title)
	_check(is_equal_approx(tbox.offset.y, r.position.y) and r.position.y > plate.offset.y + 30.0 * FontOversampling.factor(),
		"the title's box is at the title, 37 px up, not on the name's line (box y %.1f, name y %.1f)" % [tbox.offset.y, plate.offset.y])
	var nb := NamePlates.box_rect(plate)
	var tb := NamePlates.box_rect(title)
	var after := name_box.texture.get_size() if name_box != null and name_box.texture != null else Vector2.ZERO
	_check(after == before and tb.size.x > nb.size.x and absf((tbox.offset.y) - (name_box.offset.y if name_box != null else 0.0)) > 20.0,
		"the name's box keeps its width (%s -> %s) with a wider title box well above it" % [before, after])
	# A rename (0x30BB) refits it.
	nc.stalls[601] = {"owner": 601, "name": "Short", "decoration": 0}
	sw.apply(601, body, 0, 10.0)
	var rb := NamePlates.box_rect(title)
	_check(tbox.texture.get_size().x == rb.size.x and rb.size.x < tb.size.x, "a renamed title's box takes the new width")
	nc.stalls.erase(601)
	sw.apply(601, body, 0, 10.0)
	_check(body.get_node_or_null(StallWorld.TITLE_NODE) == null, "closed: the title goes")
	(world.get("_other_bodies") as Dictionary).erase(601)
	body.queue_free()
