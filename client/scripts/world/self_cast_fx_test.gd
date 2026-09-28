extends SceneTree

## The self and ground casts' particle effects (round 616-620 integration):
## World3D's self-cast path wired into SkillEffects' cast sequencer, driven by
## the real NetClient autoload decoding real OpBuffStart / OpBuffEnd /
## OpSkillMove / OpAttackResult bytes into real SkillNet / CombatNet objects.
## Run headless on the render box: `client/tools/remote_godot.sh tests`.
##
## The world is World3D.tscn with a subclass (self_cast_test.gd's pattern)
## whose _ready and frame hooks do nothing, whose body clip is stubbed (it
## returns a fixed length, recorded) and whose skillaniset2 rows are set by
## hand. The skill and effect tables are synthetic, in the files' own column
## order, and every effect is a tiny synthetic EfpEffect -- never game data.
## The sequencer's clock is driven by SkillEffects.process(now_ms) here.
##
## Checked:
## - a self-cast buff runs READY at the send, ACT_S and its ACT_L aura on its
##   own OpBuffStart, nothing more on the accepted reply, and the aura goes on
##   its OpBuffEnd;
## - a non-buff self cast acts on its accepted reply;
## - a Ghost Walk's WAIT loop holds past its skilldata time and stops on
##   OpSkillMove, on a refusal, or (fallback) after the WAIT clip's length;
## - another player's buff aura goes on that player's body, a monster's
##   (ownerKind 1) on the monster even when its id is this player's, and this
##   player is decided by the buff board's own check (the sit answer's id
##   when no OpSelfId came).
##
## NEGATIVE: against the merge of feat/efprender into int/skills without this
## wiring, the ACT-on-OpBuffStart, WAIT-held, stop-on-OpSkillMove and
## refusal checks FAIL (docs/WORLD_ISSUES.md, the 616-620 integration note).

var _failures := 0
var _net: Node
var _S: GDScript
var _made: Array = [] ## [path, EfpEffect] in the order made
var _tex: Texture2D = ImageTexture.create_from_image(Image.create(2, 2, false, Image.FORMAT_RGBA8))

const OWN := 4242
const POINT := Vector3(1234.5, 67.25, -890.75)

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
	_S = load("res://scripts/net/skill.gd")
	_test_timings()
	_net = root.get_node_or_null("NetClient")
	_check(_net != null, "the NetClient autoload is there")
	if _net != null:
		_tables()
		var world := _make_world()
		if world != null:
			var handlers := {"buff_started": "_on_buff_started", "buff_ended": "_on_buff_ended",
				"skill_moved": "_on_skill_moved", "attack_result": "_on_attack_result"}
			for sig in handlers:
				_net.connect(sig, Callable(world, handlers[sig]))
			_net.set("own_character_id", OWN)
			_test_buff(world)
			_test_non_buff(world)
			_test_ghost_walk(world)
			_test_other_owners(world)
			_test_sit_id(world)
			for sig in handlers:
				_net.disconnect(sig, Callable(world, handlers[sig]))
			SkillEffects.reset()
			root.remove_child(world)
			world.free()
		_net.set("own_character_id", -1)
		_net.set("_connected", false)
		_net.set("_peer", null)
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

# --- SelfCast.effect_timings (pure) ---------------------------------------------

func _test_timings() -> void:
	var sc: GDScript = load("res://scripts/world/self_cast.gd")
	var ok: bool = sc != null and sc.has_method("effect_timings")
	_check(ok, "SelfCast.effect_timings exists")
	if not ok:
		return
	var none := {"ready": [], "wait": [], "shot": []}
	var wait := {"ready": [], "wait": [32], "shot": [], "group": "DEFAULT"}
	var ready_only := {"ready": [5], "wait": [], "shot": []}
	_check(sc.call("effect_timings", none, 0.0) == {"prep_ms": 0, "cast_ms": 0},
		"no body clip (Grass Walk, the imbues): the phases advance at once")
	_check(sc.call("effect_timings", wait, 1.5) == {"prep_ms": 0, "cast_ms": 1500},
		"a WAIT clip: WAIT from the send, its fallback end the clip's length")
	_check(sc.call("effect_timings", wait, 0.0) == {"prep_ms": 0, "cast_ms": int(SkillEffects.READY_LOOP_MAX * 1000.0)},
		"a WAIT with no clip in the body: the loop guard")
	_check(sc.call("effect_timings", ready_only, 2.0) == {}, "only a READY (timing unread): skilldata's columns")
	_check(sc.call("effect_timings", {}, 0.0) == {}, "no row: skilldata's columns")

# --- synthetic tables ---------------------------------------------------------

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
	var sd := _skill_row(90, "TEST_IMBUE_A_01", "TEST_IMBUE_A")
	sd += _skill_row(114, "TEST_GHOST_A_01", "TEST_GHOST_A")
	sd += _skill_row(150, "TEST_SELFHEAL_A_01", "TEST_SELFHEAL_A")
	SkillAudio.set_tables(SkillAudio.parse_skills(_utf16(sd)), {})
	var text := "#section skilleffectset\r\n"
	text += _row("TEST_IMBUE_A", "READY", 0, "AT_LOOP", "charge.efp")
	text += _row("TEST_IMBUE_A", "ACT_S", 0, "AT_ONE_FOLLOW", "motion.efp")
	text += _row("TEST_IMBUE_A", "ACT_L", 0, "AT_LOOP", "keep.efp")
	text += _row("TEST_GHOST_A", "WAIT", 0, "AT_LOOP", "move_wait.efp")
	text += _row("TEST_SELFHEAL_A", "ACT_S", 0, "AT_ONE_FOLLOW", "heal_burst.efp")
	SkillEffects.reset()
	# skilldata timings: the Ghost Walk row's prep/cast are 0 (skills_spec
	# §1.5), so without the clip's hold its WAIT would end at once.
	SkillEffects.set_rows(SkillEffects.parse_rows(_utf16(text)), {90: [0, 0], 114: [0, 0], 150: [0, 0]})
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

func _made_named(name: String) -> Array:
	var out: Array = []
	for m in _made:
		if m[0] == name:
			out.append(m[1])
	return out

func _live(fx) -> bool:
	return fx != null and is_instance_valid(fx) and not (fx as Node).is_queued_for_deletion()

# --- the world ------------------------------------------------------------------

func _make_world() -> Node:
	var sub := GDScript.new()
	sub.source_code = "\n".join(PackedStringArray([
		"extends \"res://scripts/World3D.gd\"",
		"var body_clips: Array = []",
		"func _ready() -> void:",
		"\tpass",
		"func _physics_process(_delta: float) -> void:",
		"\tpass",
		"func _process(_delta: float) -> void:",
		"\tpass",
		"func _exit_tree() -> void:",
		"\tpass",
		"func _skill_anisets() -> Dictionary:",
		"\treturn {\"TEST_IMBUE_A\": {\"ready\": [], \"wait\": [], \"shot\": []},",
		"\t\t\"TEST_SELFHEAL_A\": {\"ready\": [], \"wait\": [], \"shot\": []},",
		"\t\t\"TEST_GHOST_A\": {\"ready\": [], \"wait\": [32], \"shot\": [], \"group\": \"DEFAULT\"}}",
		"func _play_self_cast_anim(basic_code: String, _anim_base: String) -> float:",
		"\tbody_clips.append(basic_code)",
		"\treturn 1.5 if basic_code.begins_with(\"TEST_GHOST\") else 0.0",
		""]))
	_check(sub.reload() == OK and sub.can_instantiate(), "a subclass of World3D.gd compiles")
	var scene := load("res://scenes/World3D.tscn") as PackedScene
	if not sub.can_instantiate() or scene == null:
		return null
	var world: Node = scene.instantiate()
	world.set_script(sub)
	root.add_child(world)
	_net.set("current_character_name", "Aria")
	SkillEffects.own_body = world.get("player")
	return world

func _fresh_socket() -> void:
	_net.set("_peer", StreamPeerBuffer.new())
	_net.set("_connected", true)
	_net.set("_attack_targets_in_flight", [] as Array[int])
	if "_attack_types_in_flight" in _net:
		_net.set("_attack_types_in_flight", [] as Array[int])

# --- bytes, as the server encodes them (self_cast_test.gd's layouts) -------------

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

func _f32(v: float) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_float(0, v)
	return b

func _buff_start(owner: int, skill: int, token: int, kind: int) -> void:
	var out := _u64(owner)
	out.append_array(_u64(skill))
	out.append_array(_u32(token))
	out.append_array(_u64(15000))
	out.append_array(_u64(15000))
	out.append_array(_u32(0))
	out.append(kind)
	_net.call("_dispatch", Packet.new(0x00F5, out))

func _buff_end(owner: int, tokens: Array, kind: int) -> void:
	var out := _u64(owner)
	out.append(tokens.size())
	for t in tokens:
		out.append_array(_u32(int(t)))
	out.append_array(_u32(0))
	out.append(kind)
	_net.call("_dispatch", Packet.new(0x00F6, out))

func _skill_move(character: int, skill: int, p: Vector3) -> void:
	var out := _u64(character)
	out.append_array(_u64(skill))
	out.append_array(_f32(p.x))
	out.append_array(_f32(p.y))
	out.append_array(_f32(p.z))
	_net.call("_dispatch", Packet.new(0x00F8, out))

func _reply(error: String, echo: int) -> void:
	var e := error.to_utf8_buffer()
	var out := PackedByteArray([e.size() & 0xff, e.size() >> 8])
	out.append_array(e)
	out.append_array(_u32(0))
	out.append_array(_u32(0))
	out.append(0)
	out.append_array(_u32(0))
	out.append_array(_u32(100))
	out.append(0)
	out.append_array(_u32(0))
	out.append(0)
	out.append_array(_u64(0))
	out.append_array(PackedByteArray([0, 0, 0]))
	out.append_array(_u64(0))
	out.append(echo)
	_net.call("_dispatch", Packet.new(CombatNet.OP_ATTACK_RESULT, out))

# --- the checks -------------------------------------------------------------------

func _test_buff(world: Node) -> void:
	var player: Node3D = world.get("player")
	_made.clear()
	_fresh_socket()
	world.call("_send_self_cast", 90, "TEST_IMBUE_A_01", 0, Vector3.ZERO)
	_check(_made_named("charge.efp").size() == 1, "the imbue's READY effect plays at the send")
	_check(_made_named("motion.efp").is_empty() and _made_named("keep.efp").is_empty(),
		"and nothing acts before the server answers")
	_buff_start(OWN, 90, 61, 0)
	var motion := _made_named("motion.efp")
	var keep := _made_named("keep.efp")
	_check(motion.size() == 1 and _live(motion[0]) and motion[0].get_parent() == player,
		"its own OpBuffStart plays ACT_S on the player (got %d)" % motion.size())
	_check(keep.size() == 1 and _live(keep[0]) and keep[0].get_parent() == player and bool(keep[0].loop),
		"and attaches the ACT_L aura, looping, on the player")
	_check(SkillEffects.aura_count() == 1, "one aura is held (got %d)" % SkillEffects.aura_count())
	var order: Array = _made.map(func(m): return m[0])
	_check(order == ["charge.efp", "motion.efp", "keep.efp"], "READY -> ACT_S -> ACT_L, in that order (got %s)" % str(order))
	_reply("", 0)
	_check(_made_named("motion.efp").size() == 1 and _made_named("keep.efp").size() == 1,
		"the accepted reply after the start adds nothing (ACT once per cast)")
	_buff_end(OWN, [61], 0)
	_check(SkillEffects.aura_count() == 0 and keep.size() == 1 and not _live(keep[0]), "its OpBuffEnd ends the aura at once")

func _test_non_buff(world: Node) -> void:
	_made.clear()
	_fresh_socket()
	world.call("_send_self_cast", 150, "TEST_SELFHEAL_A_01", 0, Vector3.ZERO)
	_check(_made_named("heal_burst.efp").is_empty(), "a non-buff self cast does not act at the send")
	_reply("", 0)
	_check(_made_named("heal_burst.efp").size() == 1, "it acts (ACT_S) on its accepted reply")

func _test_ghost_walk(world: Node) -> void:
	var player: Node3D = world.get("player")
	# 1. Held, then stopped by OpSkillMove.
	_made.clear()
	_fresh_socket()
	world.call("_send_self_cast", 114, "TEST_GHOST_A_01", 2, POINT)
	var waits := _made_named("move_wait.efp")
	_check(waits.size() == 1 and _live(waits[0]) and waits[0].get_parent() == player and bool(waits[0].loop),
		"Ghost Walk's WAIT loop plays on the player at the send")
	_check(SkillEffects.cast_phase(player) == SkillAudio.WAIT, "the cast is in WAIT (got %d)" % SkillEffects.cast_phase(player))
	SkillEffects.process(SkillEffects._now() + 1000)
	_check(SkillEffects.cast_phase(player) == SkillAudio.WAIT and waits.size() == 1 and _live(waits[0]),
		"1 s on (skilldata's prep + cast is 0) it still holds")
	_skill_move(OWN, 114, POINT)
	_check(SkillEffects.cast_phase(player) == -1, "OpSkillMove ends the cast (SHOT)")
	_check(waits.size() == 1 and not _live(waits[0]), "and stops the WAIT loop")
	_reply("", 2)
	# 2. Refused.
	_made.clear()
	_fresh_socket()
	world.call("_send_self_cast", 114, "TEST_GHOST_A_01", 2, POINT)
	waits = _made_named("move_wait.efp")
	_reply("not enough mana", 2)
	_check(SkillEffects.cast_phase(player) == -1 and waits.size() == 1 and not _live(waits[0]),
		"a refusal stops the WAIT loop")
	# 3. No answer: the WAIT clip's length (1.5 s) ends it.
	_made.clear()
	_fresh_socket()
	world.call("_send_self_cast", 114, "TEST_GHOST_A_01", 2, POINT)
	waits = _made_named("move_wait.efp")
	SkillEffects.process(SkillEffects._now() + 1400)
	_check(SkillEffects.cast_phase(player) == SkillAudio.WAIT, "with no answer it holds through the WAIT clip")
	SkillEffects.process(SkillEffects._now() + 1600)
	_check(SkillEffects.cast_phase(player) == -1 and waits.size() == 1 and not _live(waits[0]),
		"and ends after the clip's length (the fallback)")
	_check((world.get("body_clips") as Array).count("TEST_GHOST_A_01") == 3, "each cast played the body clip")
	_reply("", 2)

func _test_other_owners(world: Node) -> void:
	var player: Node3D = world.get("player")
	_made.clear()
	var other := Node3D.new()
	world.add_child(other)
	(world.get("_other_bodies") as Dictionary)[5151] = other
	_buff_start(5151, 90, 71, 0)
	var keep := _made_named("keep.efp")
	_check(keep.size() == 1 and _live(keep[0]) and keep[0].get_parent() == other,
		"another player's buff aura goes on that player's body")
	_check(_made_named("motion.efp").is_empty(), "with no ACT_S (no cast of ours answered)")
	_buff_end(5151, [71], 0)
	_check(keep.size() == 1 and not _live(keep[0]), "and its OpBuffEnd ends it")
	# A monster whose id is this player's: ownerKind 1 is the monster.
	var mob := Node3D.new()
	world.add_child(mob)
	(world.get("_monster_bodies") as Dictionary)[OWN] = mob
	_made.clear()
	_buff_start(OWN, 90, 72, 1)
	keep = _made_named("keep.efp")
	_check(keep.size() == 1 and keep[0].get_parent() == mob,
		"a monster's buff (ownerKind 1) goes on the monster even when its id is this player's")
	_check(not keep.is_empty() and keep[0].get_parent() != player, "not on the player")
	_buff_end(OWN, [72], 1)
	_check(keep.size() == 1 and not _live(keep[0]), "and the monster's end ends it")
	(world.get("_other_bodies") as Dictionary).erase(5151)
	(world.get("_monster_bodies") as Dictionary).erase(OWN)
	other.free()
	mob.free()

## This player by the buff board's check: with no OpSelfId, the sit answer's id.
func _test_sit_id(world: Node) -> void:
	var player: Node3D = world.get("player")
	_net.set("own_character_id", -1)
	var sit = world.get("_sit")
	sit.own_id = 3131
	_made.clear()
	_buff_start(3131, 90, 81, 0)
	var keep := _made_named("keep.efp")
	_check(keep.size() == 1 and keep[0].get_parent() == player,
		"with only the sit answer's id, this player's buff aura is on the player (the board's check)")
	_buff_end(3131, [81], 0)
	_net.set("own_character_id", OWN)
