extends SceneTree

## Other players' buffs stay visible through world entry, zone changes and
## body rebuilds (round 646). Run headless on the render box:
## `client/tools/remote_godot.sh tests`.
##
## The user's report: "If someone has a skill and teleports to where a player
## is, the player won't see the skill until they recast." MEASURED live in
## round 646 (docs/WORLD_ISSUES.md): a client entering the world where a
## buffed player stands logs `BUFF start: owner 1 ... skill 113` from
## NetClient and then no handler line and no aura -- the server's in-view
## replay arrives while CharacterSelect is swapping World3D in, and nothing is
## connected to buff_started yet. The same loss was open to a zone change:
## the replay can arrive during the loading screen's await, land on the old
## zone's bodies, and then the old bodies and the target book were cleared.
##
## The world is World3D.tscn with a subclass (friend_cast_test.gd's pattern)
## whose _ready and frame hooks do nothing. NetClient is the real autoload;
## the server's messages are dispatched as the bytes the server encodes. The
## skill and effect tables are synthetic, and every effect is a tiny
## synthetic EfpEffect -- never game data.
##
## Checked:
## - BuffRoster: start / end / drop / clear, the countdown of the time left,
##   and that a run-out timed buff is not replayed;
## - NetClient keeps it: OpBuffStart and OpBuffEnd update it, an owner's
##   OpEntityLeft drops it, a successful OpEnterWorldResult and
##   OpChangeZoneResult start it over;
## - the world entry: buffs dispatched before World3D listened reach the
##   bodies, the target window's book and the buff bar once it is ready;
## - a body built after its owner's buffs arrived (an arrival list, an
##   OpEntityEntered) takes their auras at once;
## - a zone change whose replay came during the loading screen: the new
##   bodies have the auras and the book has the buffs;
## - a re-sent start for a buff whose aura already draws on the body keeps
##   it (no second effect), as the retail client's spawned buff skips its
##   start effect (FUN_00a53850 arg4 1, READ).
##
## NEGATIVE: against dev 8658370 the roster and replay checks FAIL (no
## NetClient.buff_roster, no replay, the zone change's book cleared after the
## replay), quoted in the round's WORLD_ISSUES entry.

var _failures := 0
var _net: Node
var _made: Array = [] ## [path, EfpEffect] in the order made
var _tex: Texture2D = ImageTexture.create_from_image(Image.create(2, 2, false, Image.FORMAT_RGBA8))

const OWN := 4242
const BRAM := 5151
const CARL := 6161
const GRASS := 113
const WALL := 136

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
	await process_frame
	_test_roster()
	_net = root.get_node_or_null("NetClient")
	_check(_net != null, "the NetClient autoload is there")
	if _net != null:
		_tables()
		_test_net_keeps_the_roster()
		await _test_world()
		_net.set("own_character_id", -1)
		_net.set("_connected", false)
		_net.set("_peer", null)
		var roster = _net.get("buff_roster")
		if roster != null:
			roster.clear()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

# --- bytes ----------------------------------------------------------------------

func _u64(v: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(8)
	b.encode_s64(0, v)
	return b

func _u32(v: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_u32(0, v)
	return b

## OpBuffStart as session.BuffStart encodes it (41 bytes, ownerKind 0).
func _start_bytes(owner: int, skill: int, token: int, dura: int, left: int) -> PackedByteArray:
	var out := _u64(owner)
	out.append_array(_u64(skill))
	out.append_array(_u32(token))
	out.append_array(_u64(dura))
	out.append_array(_u64(left))
	out.append_array(_u32(0))
	out.append(0)
	return out

func _buff_start(owner: int, skill: int, token: int, dura: int = 355462, left: int = 300000) -> void:
	_net.call("_dispatch", Packet.new(0x00F5, _start_bytes(owner, skill, token, dura, left)))

func _buff_end(owner: int, tokens: Array, speed: int = 0) -> void:
	var out := _u64(owner)
	out.append(tokens.size())
	for t in tokens:
		out.append_array(_u32(int(t)))
	out.append_array(_u32(speed))
	out.append(0)
	_net.call("_dispatch", Packet.new(0x00F6, out))

func _entity_left(id: int) -> void:
	_net.call("_dispatch", Packet.new(WorldNet.OP_ENTITY_LEFT, _u64(id)))

func _decode(bs: PackedByteArray) -> SkillNet.BuffStart:
	return SkillNet.decode_buff_start(bs)

# --- BuffRoster (pure) ----------------------------------------------------------

func _test_roster() -> void:
	var script := load("res://scripts/net/buff_roster.gd") as GDScript
	_check(script != null, "BuffRoster exists (client/scripts/net/buff_roster.gd)")
	if script == null:
		return
	var r = script.new()
	r.start(_decode(_start_bytes(BRAM, GRASS, 7, 355462, 300000)), 1000)
	r.start(_decode(_start_bytes(BRAM, WALL, 8, -1, -1)), 1000)
	r.start(_decode(_start_bytes(OWN, GRASS, 9, 355462, 100)), 1000)
	_check(r.count() == 3 and r.owners().size() == 2, "three starts for two owners are held")
	var b: Array = r.starts_of("character:%d" % BRAM, 6000)
	_check(b.size() == 2 and b[0].token == 7 and b[0].remaining_ms == 295000 and b[1].token == 8 and b[1].remaining_ms == -1,
		"an owner's starts come back in order, the timed one counted down by the 5 s since it arrived, the wall untimed")
	_check(r.starts_of("character:%d" % OWN, 6000).is_empty(), "a timed buff whose time has run out is not replayed")
	r.start(_decode(_start_bytes(BRAM, GRASS, 7, 355462, 200000)), 9000)
	_check(r.starts_of("character:%d" % BRAM, 9000).size() == 2 and r.starts_of("character:%d" % BRAM, 9000)[0].remaining_ms == 200000,
		"a re-sent token replaces the held one")
	var be := SkillNet.BuffEnd.new()
	be.owner_id = BRAM
	be.tokens = [7] as Array[int]
	r.end(be)
	_check(r.starts_of("character:%d" % BRAM, 9000).size() == 1, "an end removes its token")
	r.drop("character:%d" % BRAM)
	_check(r.starts_of("character:%d" % BRAM, 9000).is_empty(), "an owner that left is dropped")
	r.clear()
	_check(r.count() == 0, "clear empties it")
	# Round 646's review: the owner's latest run speed is kept.
	if not r.has_method("run_speed_of"):
		_check(false, "BuffRoster keeps the owner's run speed (run_speed_of)")
		return
	var fast := _decode(_start_bytes(OWN, GRASS, 51, 355462, 300000))
	fast.run_speed = 60
	r.start(fast, 0)
	var be2 := SkillNet.BuffEnd.new()
	be2.owner_id = OWN
	be2.run_speed = 0
	r.end(be2)
	_check(r.run_speed_of("character:%d" % OWN) == 60, "a start's run speed is kept, and a 0 (unchanged) leaves it")
	be2.run_speed = 90
	r.end(be2)
	_check(r.run_speed_of("character:%d" % OWN) == 90, "a /speed-only end (no tokens) sets it")
	r.clear()
	_check(r.run_speed_of("character:%d" % OWN) == 0, "clear forgets it")

# --- NetClient keeps it -------------------------------------------------------------

func _roster():
	return _net.get("buff_roster") if _net != null else null

func _held(owner: int) -> Array:
	var r = _roster()
	if r == null:
		return []
	var out: Array = []
	for bs in r.starts_of("character:%d" % owner, Time.get_ticks_msec()):
		out.append(bs.token)
	return out

func _test_net_keeps_the_roster() -> void:
	_check(_roster() != null, "NetClient keeps a buff_roster")
	if _roster() == null:
		return
	_roster().clear()
	_buff_start(BRAM, GRASS, 11)
	_buff_start(BRAM, WALL, 12, -1, -1)
	_check(_held(BRAM) == [11, 12], "OpBuffStart is held (got %s)" % str(_held(BRAM)))
	_buff_end(BRAM, [11])
	_check(_held(BRAM) == [12], "OpBuffEnd removes its token (got %s)" % str(_held(BRAM)))
	_entity_left(BRAM)
	_check(_held(BRAM).is_empty(), "OpEntityLeft drops the owner")
	_buff_start(BRAM, GRASS, 13)
	# A successful zone change starts it over (the server re-sends the zone's).
	_net.call("_dispatch", Packet.new(WorldNet.OP_CHANGE_ZONE_RESULT, _change_zone_ok()))
	_check(_held(BRAM).is_empty(), "a successful OpChangeZoneResult starts the roster over")
	_roster().clear()

## A successful OpChangeZoneResult as the server encodes it: decoded here to
## make sure the bytes say ok.
func _change_zone_ok() -> PackedByteArray:
	var z := "donwhang".to_utf8_buffer()
	# ok, an empty reason, the zone, then x, y, z (the rest left off).
	var out := PackedByteArray([1, 0, 0])
	out.append_array(PackedByteArray([z.size() & 0xff, z.size() >> 8]))
	out.append_array(z)
	for _i in 3:
		var f := PackedByteArray()
		f.resize(4)
		f.encode_float(0, 0.0)
		out.append_array(f)
	var r = WorldNet.decode_change_zone_result(out)
	if r == null or not r.ok:
		print("note: the synthetic OpChangeZoneResult does not decode as ok (%s)" % str(r))
	return out

# --- synthetic tables -------------------------------------------------------------

func _utf16(text: String) -> PackedByteArray:
	var out := PackedByteArray([0xFF, 0xFE])
	out.append_array(text.to_utf16_buffer())
	return out

func _skill_row(id: int, code: String, group: String) -> String:
	return "1\t%d\t%d\t%s\tname\t%s\t0\t1\t0\t0\t0\r\n" % [id, id, code, group]

func _row(id: String, ani: String, ev: int, act: String, obj: String) -> String:
	var cols: Array = ["label", id, ani, str(ev), "FALSE", "none", "none", "0", "0", "0", "0", "1",
		"0,0", act, "MOV_NONE,0,0,0", "0,0,0", "false,0,0,0,0,false", "test\\", obj, "none", "0,0,0",
		"none", "0,0,0", "none", "0", "none", "none", "none"]
	return "\t".join(PackedStringArray(cols)) + "\r\n"

func _tables() -> void:
	var sd := _skill_row(GRASS, "TEST_GRASS_A_01", "TEST_GRASS_A")
	sd += _skill_row(WALL, "TEST_WALL_A_01", "TEST_WALL_A")
	SkillAudio.set_tables(SkillAudio.parse_skills(_utf16(sd)), {})
	var text := "#section skilleffectset\r\n"
	text += _row("TEST_GRASS_A", "ACT_S", 0, "AT_ONE_FOLLOW", "grass_burst.efp")
	text += _row("TEST_GRASS_A", "ACT_L", 0, "AT_LOOP", "grass_keep.efp")
	text += _row("TEST_WALL_A", "ACT_L", 0, "AT_LOOP", "wall_keep.efp")
	SkillEffects.reset()
	SkillEffects.set_rows(SkillEffects.parse_rows(_utf16(text)), {GRASS: [0, 0], WALL: [0, 0]})
	SkillEffects.effect_factory = _effect

## A tiny synthetic effect: one 3-frame plate particle; recorded by path.
func _effect(path: String) -> EfpEffect:
	var n := EfpReader.EfpNode.new()
	n.frames = 3
	var ex := EfpReader.EfpCommand.new()
	ex.name = "NormalTimeExtinct"
	n.extinct = ex
	var em := EfpReader.EfpCommand.new()
	em.name = "StaticEmit"
	em.value = {"type": "SEFStaticEmit", "delay": 0, "duration": 1, "interval": 1, "max_live": 1, "per_trigger": 1.0}
	n.emit.append(em)
	var rd := EfpReader.EfpCommand.new()
	rd.name = "RenderPlate"
	n.render = rd
	var vw := EfpReader.EfpCommand.new()
	vw.name = "ViewNone"
	n.view = vw
	n.state = EfpReader.EfpRenderState.new()
	n.state.src_blend = 5
	n.state.dest_blend = 2
	var ref := EfpReader.EfpMeshRef.new()
	ref.textures = PackedStringArray(["t.ddj"])
	n.meshes.append(ref)
	var fx := EfpEffect.from_template(EfpSim.compile(n), func(p): return _tex if p == "t.ddj" else null, func(_p): return null, 5)
	_made.append([path.get_file(), fx])
	return fx

## The live effects of `name` drawing under `body`.
func _live_on(name: String, body: Node) -> int:
	var n := 0
	for m in _made:
		var fx = m[1]
		if m[0] == name and is_instance_valid(fx) and not (fx as Node).is_queued_for_deletion() \
				and body != null and is_instance_valid(body) and body.is_ancestor_of(fx):
			n += 1
	return n

# --- the world ----------------------------------------------------------------------

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
		"func _skill_anisets() -> Dictionary:",
		"\treturn {}",
		"func _build_assembled_character(_equipped: Dictionary = {}, _gender: String = \"\") -> Skeleton3D:",
		"\treturn null",
		""]))
	_check(sub.reload() == OK and sub.can_instantiate(), "a subclass of World3D.gd compiles")
	var scene := load("res://scenes/World3D.tscn") as PackedScene
	if not sub.can_instantiate() or scene == null:
		return null
	var world: Node = scene.instantiate()
	world.set_script(sub)
	root.add_child(world)
	_net.set("current_character_name", "Aria")
	_net.set("own_character_id", OWN)
	SkillEffects.own_body = world.get("player")
	return world

func _body(world: Node, id: int) -> Node3D:
	var b = (world.get("_other_bodies") as Dictionary).get(id)
	return b if b != null and is_instance_valid(b) else null

func _book_tokens(world: Node, id: int) -> Array:
	var out: Array = []
	var book = world.get("_target_buff_book")
	if book == null:
		return out
	for e in book.list_of("character:%d" % id):
		out.append(int(e["token"]))
	return out

func _connect(world: Node) -> Array:
	var handlers := {"buff_started": "_on_buff_started", "buff_ended": "_on_buff_ended", "entity_left": "_on_entity_left"}
	var done: Array = []
	for sig in handlers:
		_net.connect(sig, Callable(world, handlers[sig]))
		done.append([sig, Callable(world, handlers[sig])])
	return done

func _disconnect(done: Array) -> void:
	for d in done:
		if _net.is_connected(d[0], d[1]):
			_net.disconnect(d[0], d[1])

func _test_world() -> void:
	if _roster() != null:
		_roster().clear()
	_made.clear()
	# --- 1. The world entry: the replay comes before World3D listens. ---------
	# Bram stands in the zone with Grass Walk and a wall; the server's in-view
	# replay follows OpEnterWorldResult and is dispatched while no scene has
	# connected to buff_started (CharacterSelect is swapping World3D in).
	_buff_start(BRAM, GRASS, 21)
	_buff_start(BRAM, WALL, 22, -1, -1)
	_buff_start(OWN, GRASS, 23)
	# A GM's /speed at entry: an OpBuffEnd with no token (round 636).
	_buff_end(OWN, [], 90)
	var world := _make_world()
	if world == null:
		return
	# World3D._ready, in order: the arrival list's bodies, then the handlers,
	# then (round 646) the replay of what arrived before.
	world.call("_spawn_or_update_other", BRAM, "Bram", Vector3(3, 0, 0))
	var bram := _body(world, BRAM)
	var done := _connect(world)
	if world.has_method("_replay_held_buffs"):
		world.call("_replay_held_buffs", "the test's world entry")
	_check(_live_on("grass_keep.efp", bram) == 1 and _live_on("wall_keep.efp", bram) == 1,
		"world entry: Bram's Grass Walk and wall, sent before this scene listened, draw on his body (got %d, %d)" % [
			_live_on("grass_keep.efp", bram), _live_on("wall_keep.efp", bram)])
	_check(_book_tokens(world, BRAM) == [21, 22], "world entry: the target window's book has Bram's two buffs (got %s)" % str(_book_tokens(world, BRAM)))
	_check(_live_on("grass_keep.efp", world.get("player")) == 1, "world entry: this player's own Grass Walk draws on this player")
	_check(_live_on("grass_burst.efp", bram) == 0, "a replayed buff plays no act on the body (retail's spawned buff skips its start effect)")

	_check(is_equal_approx(float(world.get("_move_speed")), 90.0),
		"world entry: the /speed sent before this scene listened is this player's run speed (got %s)" % str(world.get("_move_speed")))

	# --- 2. A re-sent start keeps the running aura. ----------------------------
	var before := _made.size()
	_buff_start(BRAM, GRASS, 21, 355462, 290000)
	_check(_made.size() == before and _live_on("grass_keep.efp", bram) == 1,
		"a re-sent start for a buff whose aura draws on the body starts no second effect (made %d)" % (_made.size() - before))

	# --- 3. A body built after the buffs arrived takes them. -------------------
	# Carl's buff arrives while no body of his is drawn (his OpBuffStart before
	# his body, as a zone's replay can land during a load).
	_buff_start(CARL, GRASS, 31)
	_check(_body(world, CARL) == null, "Carl has no body yet")
	world.call("_spawn_or_update_other", CARL, "Carl", Vector3(-3, 0, 0))
	var carl := _body(world, CARL)
	_check(_live_on("grass_keep.efp", carl) == 1, "a body built after its owner's buff arrived takes the aura at once (got %d)" % _live_on("grass_keep.efp", carl))
	_check(_book_tokens(world, CARL) == [31], "and the book has it (got %s)" % str(_book_tokens(world, CARL)))

	# --- 4. OpEntityLeft then a new body with the re-sent starts (a warp in the
	# one bucket): the aura goes with the old body and comes back on the new.
	_entity_left(BRAM)
	await process_frame
	world.call("_spawn_or_update_other", BRAM, "Bram", Vector3(30, 0, 0))
	_buff_start(BRAM, GRASS, 21, 355462, 280000)
	var bram2 := _body(world, BRAM)
	_check(bram2 != null and bram2 != bram and _live_on("grass_keep.efp", bram2) == 1,
		"after a leave and a re-entry, the re-sent start draws on the new body")

	# --- 5. A zone change whose replay came during the loading screen. -------
	# The result starts the roster over; the new zone's starts arrive (here,
	# during the loading screen's await: the old bodies are still drawn and
	# take them); then the arrival list replaces every body.
	if _roster() != null:
		_roster().clear()
	_buff_start(BRAM, GRASS, 41)
	_buff_start(OWN, GRASS, 23)
	var old_bram := _body(world, BRAM)
	var snap := WorldNet.EntitySnapshot.new()
	snap.character_id = BRAM
	snap.char_name = "Bram"
	snap.x = 50.0
	if world.has_method("_replace_others_for_arrival"):
		world.call("_replace_others_for_arrival", [snap], [])
	else:
		# dev 8658370's _on_change_zone_result, after its await, did exactly
		# this: free the bodies, clear the book, spawn the arrival list.
		for id in (world.get("_other_bodies") as Dictionary).keys():
			(world.get("_other_bodies") as Dictionary)[id].queue_free()
		(world.get("_other_bodies") as Dictionary).clear()
		world.get("_target_buff_book").clear()
		world.call("_spawn_result_others", [snap], [])
	await process_frame
	var new_bram := _body(world, BRAM)
	_check(new_bram != null and new_bram != old_bram, "the arrival list replaced Bram's old body")
	_check(_live_on("grass_keep.efp", new_bram) == 1,
		"zone change: Bram's buff, re-sent during the load, draws on his new body (got %d)" % _live_on("grass_keep.efp", new_bram))
	_check(_book_tokens(world, BRAM) == [41], "zone change: the target window's book has it (got %s)" % str(_book_tokens(world, BRAM)))
	_check(_live_on("grass_keep.efp", world.get("player")) == 1, "zone change: this player's own aura is still one")

	# --- 6. Who enters or leaves during a zone change's load (round 646's
	# review): Dave enters after the result, Bram (on the result's list)
	# leaves; the arrival lays out Dave and not Bram.
	world.set("_arrival_pending", true)
	var dave := WorldNet.EntitySnapshot.new()
	dave.character_id = 7171
	dave.char_name = "Dave"
	dave.x = 70.0
	world.call("_on_entity_entered", dave)
	world.call("_on_entity_left", BRAM)
	var moved := WorldNet.EntityMoved.new()
	moved.character_id = 7171
	moved.x = 75.0
	world.call("_on_entity_moved", moved)
	var snap2 := WorldNet.EntitySnapshot.new()
	snap2.character_id = BRAM
	snap2.char_name = "Bram"
	if world.has_method("_replace_others_for_arrival"):
		world.call("_replace_others_for_arrival", [snap2], [])
	await process_frame
	var dave_body := _body(world, 7171)
	_check(dave_body != null, "a player who entered during the load is drawn after the arrival")
	_check(dave_body != null and is_equal_approx(dave_body.position.x, 75.0), "where their last move during the load put them")
	_check(_body(world, BRAM) == null, "a player on the result's list who left during the load is not drawn")

	_disconnect(done)
	SkillEffects.reset()
	root.remove_child(world)
	world.free()
