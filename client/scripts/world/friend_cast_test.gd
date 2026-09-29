extends SceneTree

## Friendly-target casts and other players' casts (round 622). Run headless on
## the render box: `client/tools/remote_godot.sh tests`.
##
## The world is World3D.tscn with a subclass (self_cast_fx_test.gd's pattern)
## whose _ready and frame hooks do nothing and whose body clip is stubbed.
## HudPanels is a real one with its skill catalog set by hand to the rows'
## real columns (MEASURED on the retail skilldata): Heal 149 (Target_Required
## 1, Land 0, Animal 1, Building 0, Self/Ally/Party 1, Range 150) and Smash 3
## (Target_Required 1, Animal 1, hostile groups only). NetClient is the real
## autoload with a StreamPeerBuffer standing in for the socket, and the
## server's messages are dispatched as the bytes the server encodes. The
## skill and effect tables are synthetic, and every effect is a tiny
## synthetic EfpEffect -- never game data.
##
## Checked:
## - SelfCast.plan: a friendly row with nothing selected is refused with the
##   retail client's own 0x3011 text (FUN_0081ba10), at a monster it is sent
##   for the server's target test, at a player it is cast there; a hostile row
##   at a player is refused; the retail 0x3011 test applies to Smash too;
## - the OpSkillCast and targetType 3 layouts;
## - in the world: Heal with nothing selected sends nothing; at a selected
##   player it sends targetType 3 naming them; its ACT_S plays on that
##   player's body when the server accepts; at a monster it goes out as a
##   plain entity request with no cast drawn;
## - another player's OpSkillCast plays the cast's READY on their body, and
##   its act plays ACT_S on the body it names -- this player's, for a heal on
##   this player -- and an act whose buff already started plays no ACT_L.
##
## NEGATIVE: against int/skills 6339b5b (round 620's integration) the plan
## checks for the friendly rows FAIL (Heal with nothing selected was
## "need_target" with the old wording, at a player there was no selection at
## all), and the OpSkillCast checks FAIL (no such message).

var _failures := 0
var _net: Node
var _S: GDScript
var _made: Array = [] ## [path, EfpEffect] in the order made
var _tex: Texture2D = ImageTexture.create_from_image(Image.create(2, 2, false, Image.FORMAT_RGBA8))

const OWN := 4242
const BRAM := 5151
const MONSTER := 777
const HEAL := 149
const SMASH := 3
const BUFF := 8102

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
	_test_plan()
	_test_codec()
	_net = root.get_node_or_null("NetClient")
	_check(_net != null, "the NetClient autoload is there")
	if _net != null:
		_tables()
		var world := _make_world()
		if world != null:
			var handlers := {"buff_started": "_on_buff_started", "buff_ended": "_on_buff_ended",
				"attack_result": "_on_attack_result", "skill_cast": "_on_skill_cast"}
			var connected: Array = []
			for sig in handlers:
				if _net.has_signal(sig) and world.has_method(handlers[sig]):
					_net.connect(sig, Callable(world, handlers[sig]))
					connected.append(sig)
			_check(connected.size() == handlers.size(), "NetClient has skill_cast and World3D _on_skill_cast (got %s)" % str(connected))
			_net.set("own_character_id", OWN)
			_test_nothing_selected(world)
			await _test_heal_on_player(world)
			_test_heal_at_monster(world)
			_test_others_cast(world)
			_test_review(world)
			for sig in connected:
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

# --- SelfCast.plan (pure) -------------------------------------------------------

const ANIMAL := 1
const BUILDING := 2
const SELF := 4
const ALLY := 8
const PARTY := 16

func _heal_reach() -> Dictionary:
	return {"range": 150, "approach": true, "target_required": 1, "target_land": 0,
		"target_groups": ANIMAL | SELF | ALLY | PARTY}

func _smash_reach() -> Dictionary:
	return {"range": 6, "approach": true, "target_required": 1, "target_land": 0, "target_groups": ANIMAL}

func _test_plan() -> void:
	var sc: GDScript = load("res://scripts/world/self_cast.gd")
	_check(sc != null, "self_cast.gd loads")
	if sc == null:
		return
	var heal := _heal_reach()
	var smash := _smash_reach()
	var party_only := {"range": 0, "approach": true, "target_required": 1, "target_land": 0, "target_groups": ANIMAL | PARTY}
	var grass := {"range": 0, "approach": false, "target_required": 0, "target_land": 0, "target_groups": 0}
	var plan := func(r: Dictionary, monster: bool, character: bool) -> String:
		return String(sc.callv("plan", [r, monster, character])) if sc.get_script_method_list().any(
			func(m): return m["name"] == "plan" and (m["args"] as Array).size() >= 3) else "(no 3-argument plan)"
	_check(plan.call(heal, false, false) == "no_target",
		"Heal with nothing selected: refused as the retail client refuses it (0x3011), not cast on the player (got %s)" % plan.call(heal, false, false))
	_check(plan.call(heal, true, false) == "friend_at_monster", "Heal at a monster: sent for the server's target test")
	_check(plan.call(heal, false, true) == "friend", "Heal at a selected player: cast at that player")
	_check(plan.call(party_only, false, true) == "friend", "a Party-only buff at a player: cast (the server checks the party)")
	_check(plan.call(smash, false, true) == "hostile_at_character", "Smash at a player: refused (player-versus-player is not modelled)")
	_check(plan.call(smash, true, false) == "target", "Smash at a monster: as before")
	_check(plan.call(smash, false, false) == "no_target", "Smash with nothing selected: the retail 0x3011 test applies to it too")
	_check(plan.call(grass, false, true) == "self", "Grass Walk with a player selected is still a self cast")
	_check(plan.call({}, false, false) == "need_target", "an unknown skill: refused with nothing selected, as before")
	var consts: Dictionary = sc.get_script_constant_map()
	_check(String(consts.get("NO_TARGET_TEXT", "")) == "The target is not selected.", "the 0x3011 text is the retail English one")
	_check(String(consts.get("INVALID_TARGET_TEXT", "")) == "Invalid target", "the 0x3006 text is the retail English one")
	_check(String(consts.get("SILENT_END_TEXT", "")) == "the skill action ended", "the silent-end marker matches the server's (session.silentRefusal)")

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

func _f32(v: float) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_float(0, v)
	return b

## OpSkillCast as the server encodes it (session/friendlycast.go SkillCast).
func _cast_bytes(caster: int, kind: int, skill: int, cast_id: int, phase: int, type: int, target: int) -> PackedByteArray:
	var out := _u64(caster)
	out.append(kind)
	out.append_array(_u64(skill))
	out.append_array(_u32(cast_id))
	out.append(phase)
	out.append(type)
	out.append_array(_u64(target))
	out.append_array(_f32(0.0))
	out.append_array(_f32(0.0))
	out.append_array(_f32(0.0))
	return out

func _use_bytes(name: String, skill: int, target: int, type: int) -> PackedByteArray:
	var n := name.to_utf8_buffer()
	var out := PackedByteArray([n.size() & 0xff, n.size() >> 8])
	out.append_array(n)
	out.append_array(_u64(skill))
	out.append_array(_u64(target))
	out.append(type)
	return out

func _test_codec() -> void:
	var consts: Dictionary = _S.get_script_constant_map() if _S != null else {}
	_check(int(consts.get("OP_SKILL_CAST", -1)) == 0x00FA, "OP_SKILL_CAST is 0x00FA")
	_check(int(consts.get("TARGET_CHARACTER", -1)) == 3, "TARGET_CHARACTER is 3")
	if _S == null or not _S.get_script_method_list().any(func(m): return m["name"] == "decode_skill_cast"):
		_check(false, "SkillNet.decode_skill_cast exists")
		return
	var c = _S.call("decode_skill_cast", _cast_bytes(BRAM, 0, HEAL, 9, 1, 3, OWN))
	_check(c != null and c.caster_id == BRAM and c.caster_kind == 0 and c.skill_id == HEAL and c.cast_id == 9
		and c.phase == 1 and c.target_type == 3 and c.target_id == OWN, "an OpSkillCast decodes field by field")
	_check(_S.call("decode_skill_cast", _cast_bytes(BRAM, 0, HEAL, 9, 1, 3, OWN).slice(0, 42)) == null, "a short one is dropped")
	_check(_S.call("encode_use", "Aria", HEAL, BRAM, 3) == _use_bytes("Aria", HEAL, BRAM, 3),
		"a targetType 3 request is {name, skill, the character's id, 3} with no point")

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
	var sd := _skill_row(HEAL, "TEST_HEAL_A_01", "TEST_HEAL_A")
	sd += _skill_row(BUFF, "TEST_ALLYBUFF_A_01", "TEST_ALLYBUFF_A")
	SkillAudio.set_tables(SkillAudio.parse_skills(_utf16(sd)), {})
	var text := "#section skilleffectset\r\n"
	text += _row("TEST_HEAL_A", "READY", 0, "AT_LOOP", "heal_ready.efp")
	text += _row("TEST_HEAL_A", "ACT_S", 0, "AT_ONE_FOLLOW", "heal_burst.efp")
	text += _row("TEST_ALLYBUFF_A", "ACT_S", 0, "AT_ONE_FOLLOW", "buff_motion.efp")
	text += _row("TEST_ALLYBUFF_A", "ACT_L", 0, "AT_LOOP", "buff_keep.efp")
	SkillEffects.reset()
	SkillEffects.set_rows(SkillEffects.parse_rows(_utf16(text)), {HEAL: [0, 0], BUFF: [0, 0]})
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

# --- the world ----------------------------------------------------------------------

var _bram: Node3D
var _mob: Node3D

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
		"\treturn {}",
		"func _play_self_cast_anim(basic_code: String, _anim_base: String) -> float:",
		"\tbody_clips.append(basic_code)",
		"\treturn 0.0",
		"func _ground_point_at(_screen_pos: Vector2) -> Variant:",
		"\treturn Vector3(1, 0, 1)",
		""]))
	_check(sub.reload() == OK and sub.can_instantiate(), "a subclass of World3D.gd compiles")
	var scene := load("res://scenes/World3D.tscn") as PackedScene
	if not sub.can_instantiate() or scene == null:
		return null
	var world: Node = scene.instantiate()
	world.set_script(sub)
	root.add_child(world)
	var panels: Node = (load("res://scripts/ui/hud/hud_panels.gd") as GDScript).new()
	panels.set("_skill_catalog_loaded", true)
	panels.set("_skill_reach_by_id", {HEAL: _heal_reach(), SMASH: _smash_reach(),
		BUFF: {"range": 0, "approach": true, "target_required": 1, "target_land": 0, "target_groups": ANIMAL | ALLY | PARTY}})
	world.set("_hud_panels", panels)
	_net.set("current_character_name", "Aria")
	SkillEffects.own_body = world.get("player")
	var player: Node3D = world.get("player")
	_bram = Node3D.new()
	world.add_child(_bram)
	_bram.position = player.position + Vector3(3, 0, 0)
	(world.get("_other_bodies") as Dictionary)[BRAM] = _bram
	(world.get("_other_body_targets") as Dictionary)[BRAM] = _bram.position
	_mob = Node3D.new()
	world.add_child(_mob)
	(world.get("_monster_bodies") as Dictionary)[MONSTER] = _mob
	return world

func _fresh_socket() -> StreamPeerBuffer:
	var buf := StreamPeerBuffer.new()
	_net.set("_peer", buf)
	_net.set("_connected", true)
	_net.set("_attack_targets_in_flight", [] as Array[int])
	if "_attack_types_in_flight" in _net:
		_net.set("_attack_types_in_flight", [] as Array[int])
	return buf

func _uses(buf: StreamPeerBuffer) -> Array:
	var out: Array = []
	var bytes := buf.data_array
	var at := 0
	while at + Packet.HEADER_SIZE <= bytes.size():
		var size := bytes.decode_u16(at)
		var op := bytes.decode_u16(at + 2)
		if op == 0x0072:
			out.append(bytes.slice(at + Packet.HEADER_SIZE, at + Packet.HEADER_SIZE + size))
		at += Packet.HEADER_SIZE + size
	return out

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

func _buff_start(owner: int, skill: int, token: int) -> void:
	var out := _u64(owner)
	out.append_array(_u64(skill))
	out.append_array(_u32(token))
	out.append_array(_u64(15000))
	out.append_array(_u64(15000))
	out.append_array(_u32(0))
	out.append(0)
	_net.call("_dispatch", Packet.new(0x00F5, out))

func _skill_cast(caster: int, skill: int, cast_id: int, phase: int, type: int, target: int) -> void:
	_net.call("_dispatch", Packet.new(0x00FA, _cast_bytes(caster, 0, skill, cast_id, phase, type, target)))

# --- the checks ---------------------------------------------------------------------

func _test_nothing_selected(world: Node) -> void:
	world.set("_last_attack_target", -1)
	world.set("_selected_character", -1)
	var buf := _fresh_socket()
	_made.clear()
	world.call("_cast_skill", HEAL, "TEST_HEAL_A_01")
	_check(_uses(buf).is_empty(), "Heal with nothing selected sends nothing (the retail client refuses it, 0x3011)")
	_check(_made_named("heal_ready.efp").is_empty(), "and draws no cast")

func _test_heal_on_player(world: Node) -> void:
	var buf := _fresh_socket()
	_made.clear()
	if not world.has_method("_select_character"):
		_check(false, "World3D can select a player (_select_character)")
		return
	world.call("_select_character", BRAM, "Bram")
	_check(int(world.get("_last_attack_target")) == -1, "selecting a player ends the monster selection")
	world.call("_cast_skill", HEAL, "TEST_HEAL_A_01")
	var uses := _uses(buf)
	_check(uses.size() == 1 and uses[0] == _use_bytes("Aria", HEAL, BRAM, 3),
		"Heal at the selected player sends targetType 3 naming them (got %s)" % str(uses))
	_check(_made_named("heal_ready.efp").size() == 1, "its READY plays on the caster at the send")
	_check(_made_named("heal_burst.efp").is_empty(), "nothing acts before the server answers")
	_reply("", 3)
	var burst := _made_named("heal_burst.efp")
	_check(burst.size() == 1 and burst[0].get_parent() == _bram,
		"accepted, its ACT_S plays on the healed player's body (got %d, parent %s)" % [burst.size(),
			str(burst[0].get_parent()) if not burst.is_empty() else "-"])
	# With a prep + cast, the act waits for them from the send.
	SkillEffects.set_rows(SkillEffects._rows, {HEAL: [300, 0], BUFF: [0, 0]})
	_fresh_socket()
	_made.clear()
	world.call("_cast_skill", HEAL, "TEST_HEAL_A_01")
	_reply("", 3)
	_check(_made_named("heal_burst.efp").is_empty(), "a Heal with 300 ms of prep does not act on the reply at once")
	await create_timer(0.5).timeout
	_check(_made_named("heal_burst.efp").size() == 1, "and acts once its prep + cast from the send has passed")
	SkillEffects.set_rows(SkillEffects._rows, {HEAL: [0, 0], BUFF: [0, 0]})
	# A refusal (too far away, a stranger for a Party-only row) ends the cast.
	_fresh_socket()
	_made.clear()
	world.call("_cast_skill", HEAL, "TEST_HEAL_A_01")
	_reply("too far away", 3)
	_check(_made_named("heal_burst.efp").is_empty() and SkillEffects.cast_phase(world.get("player")) == -1,
		"a refused Heal at a player acts nowhere and its cast ends")
	# A hostile row at the player: nothing sent, and nothing said (retail
	# drops it silently when the player is not attackable).
	var b2 := _fresh_socket()
	var said := _chat_count(world)
	_check(said >= 0, "the world's chat log is there to read")
	world.call("_cast_skill", SMASH, "TEST_SMASH_A_01")
	_check(_uses(b2).is_empty(), "Smash at a selected player sends nothing")
	_check(_chat_count(world) == said, "and says nothing (0x81bc93..0x81bcaf: a non-attackable player is a silent no-op)")

func _test_heal_at_monster(world: Node) -> void:
	world.call("_show_target", MONSTER)
	_check(int(world.get("_selected_character")) == -1, "a monster selection ends the player selection")
	world.set("_last_attack_target", MONSTER)
	var buf := _fresh_socket()
	_made.clear()
	world.call("_cast_skill", HEAL, "TEST_HEAL_A_01")
	var uses := _uses(buf)
	_check(uses.size() == 1 and uses[0] == _use_bytes("Aria", HEAL, MONSTER, 1),
		"Heal at a monster goes out at once as an entity request for the server's target test (got %s)" % str(uses))
	_check(_made_named("heal_ready.efp").is_empty(), "with no cast drawn (retail draws the cast from the server's 0xB070)")
	world.set("_last_attack_target", -1)

func _test_others_cast(world: Node) -> void:
	var player: Node3D = world.get("player")
	# Bram heals this player.
	_made.clear()
	_skill_cast(BRAM, HEAL, 41, 0, 3, OWN)
	var ready := _made_named("heal_ready.efp")
	_check(ready.size() == 1 and ready[0].get_parent() == _bram, "another player's cast start plays its READY on their body")
	_check(_made_named("heal_burst.efp").is_empty(), "and nothing acts at the start")
	_skill_cast(BRAM, HEAL, 41, 1, 3, OWN)
	var burst := _made_named("heal_burst.efp")
	_check(burst.size() == 1 and burst[0].get_parent() == player,
		"its act plays ACT_S on this player, the one healed (got %d)" % burst.size())
	# Bram buffs this player: the buff's own OpBuffStart holds the aura, so the
	# act plays ACT_S and no ACT_L cycle.
	_made.clear()
	_skill_cast(BRAM, BUFF, 42, 0, 3, OWN)
	_buff_start(OWN, BUFF, 91)
	var keeps_before := _made_named("buff_keep.efp").size()
	_skill_cast(BRAM, BUFF, 42, 1, 3, OWN)
	_check(_made_named("buff_keep.efp").size() == keeps_before, "an act whose buff already started adds no ACT_L cycle")
	_check(not _made_named("buff_motion.efp").is_empty(), "and plays its ACT_S")
	# A cast by nobody drawn here is ignored.
	_made.clear()
	_skill_cast(999, HEAL, 43, 0, 0, 0)
	_check(_made.is_empty(), "a caster not in view draws nothing")

## How much the world's chat log holds (World3D._log_system writes every
## system line there), to tell whether a step said anything.
func _chat_count(world: Node) -> int:
	var cl = world.get("chat_log")
	if cl != null and cl is RichTextLabel:
		return (cl as RichTextLabel).get_parsed_text().length()
	return -1

# --- round 622's review ------------------------------------------------------------

func _test_review(world: Node) -> void:
	var player: Node3D = world.get("player")
	# Selecting oneself: the portrait block's left press, and the cast at oneself.
	_check(world.has_method("_select_self"), "World3D can select this player (_select_self)")
	if world.has_method("_select_self"):
		_test_self_select(world, player)
	# A walk supersedes a friendly cast walking to its player.
	world.set("_pending_friend_cast", {"character": BRAM, "skill": HEAL, "code": "TEST_HEAL_A_01", "stop": 1.0, "reach": 2.0})
	world.call("_try_set_move_target", Vector2.ZERO)
	_check((world.get("_pending_friend_cast") as Dictionary).is_empty(), "a click-to-walk drops a pending friendly cast")
	# A heal on this player from a caster not in view still plays its act here.
	_made.clear()
	_skill_cast(999, HEAL, 60, 1, 3, OWN)
	var seen := _made_named("heal_burst.efp")
	_check(seen.size() == 1 and seen[0].get_parent() == player,
		"a heal on this player from a caster out of view plays ACT_S on this player (got %d)" % seen.size())
	_check(not ("_other_casts" in world), "the unused cast map is gone")

func _test_self_select(world: Node, player: Node3D) -> void:
	var info_script: GDScript = load("res://scripts/ui/hud/hud_player_info.gd")
	var info: Control = info_script.new(null)
	_check(info.has_signal("self_pressed"), "the player block has self_pressed (CIFPlayerMiniInfo::vslot_030)")
	if info.has_signal("self_pressed"):
		info.connect("self_pressed", Callable(world, "_select_self"))
		world.set("_selected_character", -1)
		var press := InputEventMouseButton.new()
		press.button_index = MOUSE_BUTTON_LEFT
		press.pressed = true
		info.call("_gui_input", press)
		_check(int(world.get("_selected_character")) == OWN, "a left press on the player block selects this player (got %d)" % int(world.get("_selected_character")))
	info.free()
	var buf := _fresh_socket()
	_made.clear()
	world.call("_cast_skill", HEAL, "TEST_HEAL_A_01")
	var uses := _uses(buf)
	_check(uses.size() == 1 and uses[0] == _use_bytes("Aria", HEAL, OWN, 3),
		"Heal with oneself selected sends targetType 3 naming this player (got %s)" % str(uses))
	_reply("", 3)
	var burst := _made_named("heal_burst.efp")
	_check(burst.size() == 1 and burst[0].get_parent() == player, "and its ACT_S plays on this player")
