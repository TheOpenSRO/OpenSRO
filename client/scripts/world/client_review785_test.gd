extends SceneTree

## Round 785's client review: the merged client's defects, each driven
## through World3D's own handlers on a World3D.tscn whose frame hooks do
## nothing (self_cast_fx_test.gd's pattern), with synthetic tables, bodies,
## clips and effects -- never game data. Run headless on the render box:
## `client/tools/remote_godot.sh tests`. Every check here FAILs on d8b43cf7.
##
## 1. another player's Ghost Walk slide arrives (the eased walk no longer
##    pulls it back), leaves an afterimage per 20 units covered, and a slide
##    held back ends at its time limit;
## 2. no script calls a NetClient method that is not there (list_quests);
## 4. a one-shot started during a cast's WAIT hold plays once; a held die
##    clip survives the cast's end; death and a walk order end the cast;
## 5. a zone change undoes this player's abnormal-state look;
## 6. a monster's death and its forgetting drop its state look and clip
##    speed; a gone skeleton's speed is pruned;
## 7. an OpAttackResult naming a plain swing leaves a pending cast pending;
##    one naming the skill answers it; one naming nothing keeps the old rule;
## 10. a self cast's act shoots only its own decoration;
## 11. a swing's turn yields to a walked leg, a slide and a pick-up;
## 12. a blow drawn after a newer HP report does not write its older HP;
## 14. the dungeon minimap clears the field's quest signs.

var _failures := 0
var _net: Node
var _made: Array = []
var _tex: Texture2D = ImageTexture.create_from_image(Image.create(2, 2, false, Image.FORMAT_RGBA8))

const OWN := 4242
const T := BsrReader.AnimationEntry

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	var watchdog := create_timer(90.0)
	watchdog.timeout.connect(func() -> void:
		print("FAIL the suite never reported (a script error stopped it)")
		quit(1))
	await process_frame
	_test_net_calls()
	_net = root.get_node_or_null("NetClient")
	_check(_net != null, "the NetClient autoload is there")
	if _net != null:
		_tables()
		var world := _make_world()
		if world != null:
			_net.set("own_character_id", OWN)
			_net.set("current_character_name", "Aria")
			world.call("_sync_own_id")
			_setup_player(world)
			_test_other_slide(world)
			_test_slide_limit(world)
			_test_one_shots(world)
			_test_zone_change_states(world)
			_test_monster_states(world)
			_test_result_routing(world)
			_test_act_shoots_own(world)
			_test_faces(world)
			await _test_late_strike(world)
			_test_dungeon_signs(world)
			SkillEffects.reset()
			StateLook.clear()
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

# --- 2: every NetClient call names something NetClient has --------------------

func _scripts(dir: String, out: Array) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	for f in d.get_files():
		if f.ends_with(".gd"):
			out.append(dir.path_join(f))
	for sub in d.get_directories():
		_scripts(dir.path_join(sub), out)

func _test_net_calls() -> void:
	var net := root.get_node_or_null("NetClient")
	if net == null:
		_check(false, "the NetClient autoload is there")
		return
	var consts: Dictionary = (net.get_script() as Script).get_script_constant_map()
	var re := RegEx.new()
	re.compile("(?<![\\w.])NetClient\\.(\\w+)")
	var files: Array = []
	_scripts("res://scripts", files)
	var missing := PackedStringArray()
	for path in files:
		var text := FileAccess.get_file_as_string(path)
		var n := 0
		for line in text.split("\n"):
			n += 1
			var code := line
			var hash := code.find("#")
			if hash >= 0:
				code = code.substr(0, hash)
			for m in re.search_all(code):
				var name := m.get_string(1)
				if net.has_method(name) or net.has_signal(name) or name in net or consts.has(name):
					continue
				if name in ["connect", "disconnect", "is_connected", "call", "get", "set", "has_method", "set_meta",
						"get_meta", "has_meta", "emit_signal", "call_deferred", "get_node_or_null"]:
					continue
				missing.append("%s:%d NetClient.%s" % [path.get_file(), n, name])
	_check(files.size() > 100 and missing.is_empty(),
		"every NetClient.<name> in %d scripts is a method, signal, property or constant of it (finding 2; missing: %s)" % [
			files.size(), ", ".join(missing)])

# --- the tables and the world ---------------------------------------------------

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
	var sd := _skill_row(114, "TEST_GHOST_A_01", "TEST_GHOST_A")
	sd += _skill_row(150, "TEST_SELFHEAL_A_01", "TEST_SELFHEAL_A")
	sd += _skill_row(160, "TEST_BOLT_A_01", "TEST_BOLT_A")
	SkillAudio.set_tables(SkillAudio.parse_skills(_utf16(sd)), {})
	var text := "#section skilleffectset\r\n"
	text += _row("TEST_GHOST_A", "WAIT", 0, "AT_LOOP", "move_wait.efp")
	text += _row("PARAM_BU", "ACT_L", 0, "AT_LOOP", "status_burn.efp")
	text += _row("PARAM_FB", "ACT_L", 0, "AT_LOOP", "status_frostbite.efp")
	text += _row("PARAM_FZ", "ACT_L", 0, "AT_LOOP", "icing_on.efp")
	text += _row("PARAM_SLOW", "ACT_L", 0, "AT_LOOP", "status_slow.efp")
	SkillEffects.reset()
	SkillEffects.set_rows(SkillEffects.parse_rows(_utf16(text)), {114: [0, 0], 150: [0, 0], 160: [0, 0]})
	SkillEffects.effect_factory = _effect

## A tiny synthetic effect: one 3-frame plate particle.
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

func _make_world() -> Node:
	var sub := GDScript.new()
	sub.source_code = "\n".join(PackedStringArray([
		"extends \"res://scripts/World3D.gd\"",
		"var images := {}",
		"var anims := {}",
		"var own_results: Array = []",
		"var strikes: Array = []",
		"func _ready() -> void:",
		"\tpass",
		"func _physics_process(_delta: float) -> void:",
		"\tpass",
		"func _process(_delta: float) -> void:",
		"\tpass",
		"func _exit_tree() -> void:",
		"\tpass",
		"func _skill_anisets() -> Dictionary:",
		"\treturn {\"TEST_GHOST_A\": {\"ready\": [], \"wait\": [32], \"shot\": [], \"group\": \"DEFAULT\"},",
		"\t\t\"TEST_SELFHEAL_A\": {\"ready\": [], \"wait\": [91], \"shot\": [26], \"group\": \"default\"},",
		"\t\t\"TEST_BOLT_A\": {\"ready\": [], \"wait\": [91], \"shot\": [26], \"group\": \"default\"}}",
		"func _skill_afterimage(body: Node3D) -> void:",
		"\timages[body.get_instance_id()] = int(images.get(body.get_instance_id(), 0)) + 1",
		"func _body_animation_for(_body: String, action_type: int, _group: String = \"default\") -> BanReader.ParsedAnimation:",
		"\treturn anims.get(action_type)",
		"func _body_animation_path(_body: String, action_type: int, _group: String) -> String:",
		"\treturn \"t%d.ban\" % action_type",
		"func _deco_clip_info(_body: String, _group: String, _action_type: int) -> Dictionary:",
		"\treturn {\"ms\": 1000, \"events\": []}",
		"func _own_skill_result(_result: CombatNet.AttackResult, skill: int, code: String) -> void:",
		"\town_results.append([skill, code])",
		"func _show_own_strike(attacked: CombatNet.MonsterAttacked, write_hp: bool = true) -> void:",
		"\tstrikes.append([attacked.target_hp, write_hp])",
		"func _play_monster_action(_monster_id: int, _action_type: int, _hold: bool = false) -> float:",
		"\treturn 1.0",
		"func _monster_action_seconds(_monster_id: int, _action_type: int) -> float:",
		"\treturn 1.0",
		"func _monster_strike_seconds(_monster_id: int, _action_type: int = BsrReader.AnimationEntry.TYPE_ATTACK) -> float:",
		"\treturn 0.2",
		"func _refresh_dungeon_minimap() -> void:",
		"\tpass",
		""]))
	_check(sub.reload() == OK and sub.can_instantiate(), "a subclass of World3D.gd compiles (it overrides _show_own_strike(attacked, write_hp))")
	var scene := load("res://scenes/World3D.tscn") as PackedScene
	if not sub.can_instantiate() or scene == null:
		return null
	var world: Node = scene.instantiate()
	world.set_script(sub)
	root.add_child(world)
	SkillEffects.own_body = world.get("player")
	return world

## A clip of `ms` with two keyframes (a one-shot _play_player_once takes).
func _anim(ms: int) -> BanReader.ParsedAnimation:
	var a := BanReader.ParsedAnimation.new()
	a.duration_ms = ms
	var b := BanReader.Bone.new()
	b.keyframes.append(BanReader.Keyframe.new())
	b.keyframes.append(BanReader.Keyframe.new())
	a.bones.append(b)
	return a

var _wait_clip: BanReader.ParsedAnimation
var _shot_clip: BanReader.ParsedAnimation
var _hit_clip: BanReader.ParsedAnimation
var _die_clip: BanReader.ParsedAnimation
var _pick_clip: BanReader.ParsedAnimation

func _setup_player(world: Node) -> void:
	var player: Node3D = world.get("player")
	var skel := Skeleton3D.new()
	skel.add_bone("Bip01")
	player.add_child(skel)
	world.set("_player_skeleton", skel)
	world.set("_player_body", "TESTBODY")
	_wait_clip = _anim(1000)
	_shot_clip = _anim(800)
	_hit_clip = _anim(500)
	_die_clip = _anim(1500)
	_pick_clip = _anim(700)
	world.set("anims", {91: _wait_clip, 26: _shot_clip, T.TYPE_HIT: _hit_clip, T.TYPE_DIE: _die_clip,
		T.TYPE_PICKUP: _pick_clip, 32: _wait_clip})

func _deco_phase(world: Node, body: Node3D) -> int:
	var e: Dictionary = world.call("_deco_on", body)
	return (e["deco"] as SkillDeco).phase if not e.is_empty() else -1

# --- 1: another player's slide --------------------------------------------------

func _test_other_slide(world: Node) -> void:
	var other := Node3D.new()
	other.set_meta("character_id", 5151)
	world.add_child(other)
	(world.get("_other_bodies") as Dictionary)[5151] = other
	(world.get("_other_body_targets") as Dictionary)[5151] = Vector3.ZERO
	_made.clear()
	var mv := SkillNet.SkillMove.new()
	mv.character_id = 5151
	mv.skill_id = 114
	mv.x = 100.0
	mv.y = 0.0
	mv.z = 0.0
	world.call("_on_skill_moved", mv)
	var waits := _made_named("move_wait.efp")
	_check(waits.size() == 1 and _deco_phase(world, other) == SkillDeco.WAIT, "the slide's cast holds WAIT with its loop effect")
	var frames := 0
	var arrived_at := -1
	for f in 120:
		world.call("_tick_skill_slides", 1.0 / 60.0)
		world.call("_step_other_bodies", 1.0 / 60.0, 1)
		frames += 1
		if not (world.get("_skill_slides") as Dictionary).has(other.get_instance_id()) and arrived_at < 0:
			arrived_at = f
	var at := other.position
	_check(arrived_at >= 0 and arrived_at <= 13 and at.distance_to(Vector3(100, 0, 0)) < 0.01,
		"another player's 100-unit slide arrives in 0.2 s at 500 u/s and stays there (frame %d, at %s; finding 1)" % [arrived_at, str(at)])
	_check(_deco_phase(world, other) == -1, "its arrival ends the cast (no WAIT left holding)")
	var n := int((world.get("images") as Dictionary).get(other.get_instance_id(), 0))
	_check(n >= 4 and n <= 5, "an afterimage every 20 units covered: %d for 100 units (READ, FUN_00a50f70)" % n)
	_check(Vector3((world.get("_other_body_targets") as Dictionary)[5151]).distance_to(Vector3(100, 0, 0)) < 0.01,
		"the walk's target is the slide's end")
	(world.get("_other_bodies") as Dictionary).erase(5151)
	(world.get("_other_body_targets") as Dictionary).erase(5151)
	other.free()

## A slide something holds back ends at its time limit, and leaves no
## afterimage for distance it never covered.
func _test_slide_limit(world: Node) -> void:
	var pinned := Node3D.new()
	world.add_child(pinned)
	var done := [0]
	world.call("_start_skill_slide", pinned, Vector3(100, 0, 0), 500.0, 20.0, "pinned", func() -> void: done[0] += 1)
	var t := 0.0
	while t < 3.0 and done[0] == 0:
		pinned.position = Vector3.ZERO
		world.call("_tick_skill_slides", 1.0 / 60.0)
		t += 1.0 / 60.0
	_check(done[0] == 1 and t <= 1.3, "a slide held back ends at its limit (%.2f s for a 0.2 s slide; finding 1)" % t)
	var n := int((world.get("images") as Dictionary).get(pinned.get_instance_id(), 0))
	_check(n == 0, "and leaves no afterimage for ground it never covered (got %d)" % n)
	pinned.free()

# --- 4: one-shots under a cast's WAIT hold ----------------------------------------

func _test_one_shots(world: Node) -> void:
	var player: Node3D = world.get("player")
	# (a) a hit reaction during the hold plays once.
	world.call("_start_deco", player, 160, null, "test bolt", {"due_ms": -1, "code": "TEST_BOLT_A_01"})
	_check(world.get("_player_one_shot") == _wait_clip and bool(world.get("_player_one_shot_loop")),
		"the cast's WAIT clip repeats while it holds")
	world.call("_play_player_once", _hit_clip)
	_check(world.get("_player_one_shot") == _hit_clip and not bool(world.get("_player_one_shot_loop")),
		"a hit reaction during the hold plays once (finding 4)")
	world.call("_end_deco", player, "test", false)
	# (b) the die clip during the hold: once, and held through the cast's end.
	world.call("_start_deco", player, 160, null, "test bolt", {"due_ms": -1, "code": "TEST_BOLT_A_01"})
	world.call("_hold_player_one_shot", _die_clip)
	_check(world.get("_player_one_shot") == _die_clip and not bool(world.get("_player_one_shot_loop")),
		"the die clip during the hold does not loop (the body falls once)")
	world.call("_end_deco", player, "test", true)
	_check(world.get("_player_one_shot") == _die_clip and bool(world.get("_player_one_shot_hold")),
		"the cast's end leaves the held die clip (a dead player does not stand)")
	world.set("_player_one_shot_hold", false)
	world.set("_player_one_shot", null)
	# (c) death ends the cast.
	world.call("_start_deco", player, 160, null, "test bolt", {"due_ms": -1, "code": "TEST_BOLT_A_01"})
	world.call("_enter_dead_state", 0)
	_check(_deco_phase(world, player) == -1, "death ends this player's cast")
	world.set("_player_dead", false)
	world.set("_player_one_shot_hold", false)
	world.set("_player_one_shot", null)
	# (d) a walk order ends the cast and its WAIT clip.
	world.call("_start_deco", player, 160, null, "test bolt", {"due_ms": -1, "code": "TEST_BOLT_A_01"})
	var r := String(world.call("_issue_walk", player.position + Vector3(200, 0, 0)))
	_check(r == "walk" and _deco_phase(world, player) == -1 and world.get("_player_one_shot") == null,
		"a click-walk during the hold ends the cast and its WAIT clip (%s; no glide in the WAIT pose)" % r)
	world.set("_has_move_target", false)
	world.set("_player_move_order", false)
	player.velocity = Vector3.ZERO

# --- 5: the zone change undoes this player's state look ---------------------------

func _test_zone_change_states(world: Node) -> void:
	var player: Node3D = world.get("player")
	_made.clear()
	var st := StatusNet.ObjectStatus.new()
	st.owner_kind = 0
	st.owner_id = OWN
	st.mask = 0x8 | 0x2
	world.call("_on_object_status", st)
	var burn := _made_named("status_burn.efp")
	_check(is_equal_approx(float(world.get("_player_clip_speed")), 0.5) and StateLook.tinted(player) and burn.size() == 1,
		"burn and frostbite on this player: its pulse, its clip speed 0.5, the burn's loop")
	world.call("_replace_others_for_arrival", [], [])
	_check(is_equal_approx(float(world.get("_player_clip_speed")), 1.0), "after the zone change the clips run at 1 (finding 5; got %s)" % world.get("_player_clip_speed"))
	_check(not StateLook.tinted(player), "and the pulse is gone")
	_check((world.get("_state_looks") as Dictionary).is_empty() and (world.get("_abnormal_states") as Dictionary).is_empty(),
		"and the books are empty")
	_check(burn.size() == 1 and (not is_instance_valid(burn[0]) or not bool((burn[0] as EfpEffect).loop)),
		"and the PARAM_ aura is let go")

# --- 6: a monster's death and its forgetting --------------------------------------

func _mob(world: Node, id: int) -> Array:
	var mob := Node3D.new()
	world.add_child(mob)
	var skel := Skeleton3D.new()
	skel.add_bone("Bip01")
	mob.add_child(skel)
	(world.get("_monster_bodies") as Dictionary)[id] = mob
	return [mob, skel]

func _status(world: Node, id: int, mask: int) -> void:
	var st := StatusNet.ObjectStatus.new()
	st.owner_kind = 1
	st.owner_id = id
	st.mask = mask
	world.call("_on_object_status", st)

func _test_monster_states(world: Node) -> void:
	var speeds: Dictionary = world.get("_clip_speeds")
	# Frozen, then killed.
	var a := _mob(world, 777)
	_status(world, 777, 0x1)
	_check(speeds.has((a[1] as Skeleton3D).get_instance_id()) and is_zero_approx(float(speeds[(a[1] as Skeleton3D).get_instance_id()])),
		"a frozen monster's clips hold")
	world.call("_begin_monster_death", 777)
	_check(not speeds.has((a[1] as Skeleton3D).get_instance_id()), "its death lets its die clip run at full speed (finding 6)")
	_check(not (world.get("_state_looks") as Dictionary).has("monster:777"), "and its look is forgotten")
	# Frostbitten (a pulse and half speed), then killed.
	var b := _mob(world, 778)
	_status(world, 778, 0x2)
	_check(StateLook.tinted(b[0]) and is_equal_approx(float(speeds.get((b[1] as Skeleton3D).get_instance_id(), 1.0)), 0.5),
		"a frostbitten monster pulses at half speed")
	world.call("_begin_monster_death", 778)
	_check(not StateLook.tinted(b[0]) and not speeds.has((b[1] as Skeleton3D).get_instance_id()),
		"its death ends the pulse and the half speed: it falls all the way")
	# Slowed, then forgotten.
	var c := _mob(world, 779)
	_status(world, 779, 0x100)
	var c_skel := (c[1] as Skeleton3D).get_instance_id()
	_check(speeds.has(c_skel), "a slowed monster's clips run at 0.75")
	world.call("_forget_monster", 779)
	_check(not speeds.has(c_skel) and not (world.get("_state_looks") as Dictionary).has("monster:779"),
		"forgetting it drops its clip speed and its look")
	# A skeleton freed without either: pruned.
	var gone := Skeleton3D.new()
	var gone_id := gone.get_instance_id()
	speeds[gone_id] = 0.5
	gone.free()
	world.call("_step_clip_speeds", 1.0 / 60.0)
	_check(not speeds.has(gone_id), "a gone skeleton's clip speed is pruned")
	for id in [777, 778, 779]:
		(world.get("_monster_bodies") as Dictionary).erase(id)
	for m in [a[0], b[0], c[0]]:
		if is_instance_valid(m):
			(m as Node).free()

# --- 7: the attack result names what it answers ----------------------------------

func _u32(v: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_u32(0, v)
	return b

func _u64(v: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(8)
	b.encode_s64(0, v)
	return b

func _attack_reply(monster: int, damage: int, tail: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray([0, 0])
	out.append_array(_u32(damage))
	out.append_array(_u32(500))
	out.append(0)
	out.append_array(_u32(0))
	out.append_array(_u32(100))
	out.append(0)
	out.append_array(_u32(0))
	out.append(0)
	out.append_array(_u64(0))
	out.append_array(PackedByteArray([0, 0, 0]))
	out.append_array(_u64(monster))
	out.append(1)
	out.append_array(_u64(0))
	out.append_array(_u64(0))
	if not tail.is_empty():
		var wall := PackedByteArray()
		wall.resize(13)
		out.append_array(wall)
		out.append_array(tail)
	return out

func _tail(target: int, damage: int, skill_id: int) -> PackedByteArray:
	var h := SkillHits.new()
	h.target_id = target
	h.flags = SkillHits.FLAG_DAMAGE
	h.hit_count = 1
	var t := SkillHits.Target.new()
	t.id = target
	t.id_kind = 1
	var hit := SkillHits.Hit.new()
	hit.kind = SkillHits.KIND_HIT
	hit.flags = 1
	hit.damage = damage
	t.hits.append(hit)
	h.targets.append(t)
	h.target_kind = 1
	h.skill_id = skill_id
	return SkillHits.encode(h)

func _test_result_routing(world: Node) -> void:
	# The bytes: the section's trailing u32 is read, and its absence is -1.
	var with_id := SkillHits.decode(_tail(555, 100, 160), 0)
	var without := _tail(555, 100, -1)
	_check(with_id != null and with_id.skill_id == 160 and with_id.size == _tail(555, 100, 160).size(),
		"the 0xAB section's trailing u32 is the answered skill (finding 7)")
	var old := SkillHits.decode(without, 0)
	_check(old != null and old.skill_id == -1 and not old.has_skill_id(), "a section without it (an older server) says nothing (-1)")
	var cut := _tail(555, 100, 160)
	cut.resize(cut.size() - 2)
	var c := SkillHits.decode(cut, 0)
	_check(c != null and c.skill_id == -1, "a cut u32 is not read")
	var results: Array = world.get("own_results")
	results.clear()
	var handler := Callable(world, "_on_attack_result")
	_net.connect("attack_result", handler)
	_net.set("_peer", StreamPeerBuffer.new())
	_net.set("_connected", true)
	_net.set("_attack_targets_in_flight", [] as Array[int])
	if "_attack_types_in_flight" in _net:
		_net.set("_attack_types_in_flight", [] as Array[int])
	world.set("_pending_skill_id", 160)
	world.set("_pending_skill_hit_code", "TEST_BOLT_A_01")
	world.set("_last_attack_target", 555)
	# A keep-up's plain swing, named 0, in flight while the cast was sent.
	_net.call("_dispatch", Packet.new(CombatNet.OP_ATTACK_RESULT, _attack_reply(555, 90, _tail(555, 90, 0))))
	_check(results.is_empty() and int(world.get("_pending_skill_id")) == 160 and String(world.get("_pending_skill_hit_code")) == "TEST_BOLT_A_01",
		"a result naming a plain swing is drawn as a swing; the cast stays pending (got %s)" % str(results))
	_net.call("_dispatch", Packet.new(CombatNet.OP_ATTACK_RESULT, _attack_reply(555, 300, _tail(555, 300, 160))))
	_check(results.size() == 1 and results[0] == [160, "TEST_BOLT_A_01"] and int(world.get("_pending_skill_id")) == 0,
		"the result naming the skill is the cast's answer (got %s)" % str(results))
	# An older server's result while a cast is pending: the old rule.
	results.clear()
	world.set("_pending_skill_id", 160)
	world.set("_pending_skill_hit_code", "TEST_BOLT_A_01")
	_net.call("_dispatch", Packet.new(CombatNet.OP_ATTACK_RESULT, _attack_reply(555, 300, _tail(555, 300, -1))))
	_check(results.size() == 1 and results[0][0] == 160, "a result naming nothing answers the pending cast, as before")
	_net.disconnect("attack_result", handler)
	world.set("_pending_skill_id", 0)
	world.set("_pending_skill_hit_code", "")
	world.set("_last_attack_target", -1)
	world.set("_player_one_shot", null)

# --- 10: a self cast's act shoots its own decoration only -------------------------

func _test_act_shoots_own(world: Node) -> void:
	var player: Node3D = world.get("player")
	world.call("_start_deco", player, 160, null, "a cast at a monster", {"due_ms": -1, "code": "TEST_BOLT_A_01"})
	world.set("_fx_self_cast", {"skill": 150, "code": "TEST_SELFHEAL_A_01", "ground": false, "acted": false, "begun": true})
	world.call("_fx_self_cast_acts", 150, "test", false)
	_check(_deco_phase(world, player) == SkillDeco.WAIT and int((world.call("_deco_on", player) as Dictionary)["skill"]) == 160,
		"another cast's act leaves the running cast in WAIT (finding 10; phase %d)" % _deco_phase(world, player))
	world.call("_end_deco", player, "test", false)
	world.call("_start_deco", player, 150, null, "the self cast", {"due_ms": -1, "code": "TEST_SELFHEAL_A_01"})
	world.set("_fx_self_cast", {"skill": 150, "code": "TEST_SELFHEAL_A_01", "ground": false, "acted": false, "begun": true})
	world.call("_fx_self_cast_acts", 150, "test", false)
	_check(_deco_phase(world, player) == SkillDeco.SHOT, "its own cast's act forces its SHOT (phase %d)" % _deco_phase(world, player))
	world.call("_end_deco", player, "test", false)
	world.set("_fx_self_cast", {})
	world.set("_player_one_shot", null)

# --- 11: the swing's turn yields -------------------------------------------------

func _test_faces(world: Node) -> void:
	var faces: Dictionary = world.get("_combat_faces")
	var other := Node3D.new()
	other.set_meta("character_id", 6161)
	world.add_child(other)
	(world.get("_other_bodies") as Dictionary)[6161] = other
	other.rotation.y = PI / 2.0
	world.call("_face_while_striking", other, 0.0, func() -> Variant: return Vector3(0, 0, 100), 2.0)
	(world.get("_other_legs") as Dictionary)[6161] = {}
	world.call("_step_combat_faces", 1.0 / 60.0)
	_check(not faces.has(other.get_instance_id()) and is_equal_approx(other.rotation.y, PI / 2.0),
		"a player walking a leg is not turned by its swing (finding 11; yaw %.3f)" % other.rotation.y)
	(world.get("_other_legs") as Dictionary).erase(6161)
	world.call("_face_while_striking", other, 0.0, func() -> Variant: return Vector3(0, 0, 100), 2.0)
	world.call("_start_skill_slide", other, Vector3(50, 0, 0), 500.0, 0.0, "test slide")
	_check(not faces.has(other.get_instance_id()), "a slide's start ends the swing's turn")
	world.call("_tick_skill_slides", 1.0)
	var player: Node3D = world.get("player")
	world.call("_face_while_striking", player, 0.0, func() -> Variant: return Vector3(0, 0, 100), 2.0)
	var motion := GroundItemsNet.PickUpMotion.new()
	motion.object_id = OWN
	motion.angle = 64
	world.call("_on_pick_up_motion", motion)
	_check(not faces.has(player.get_instance_id()), "a pick-up's heading ends this player's swing turn")
	world.set("_player_one_shot", null)
	world.set("_player_pickup_clip", null)
	(world.get("_other_bodies") as Dictionary).erase(6161)
	other.free()

# --- 12: a late blow's HP --------------------------------------------------------

func _test_late_strike(world: Node) -> void:
	var strikes: Array = world.get("strikes")
	strikes.clear()
	var mob := Node3D.new()
	world.add_child(mob)
	(world.get("_monster_bodies") as Dictionary)[600] = mob
	var a := CombatNet.MonsterAttacked.new()
	a.monster_id = 600
	a.target_character_id = OWN
	a.target_hp = 100
	a.damage = 0
	world.call("_draw_monster_strike", a, true, true)
	_check(strikes.is_empty(), "the blow's HP waits for the swing's hit event")
	# A potion (any newer HP report) comes before the blow lands.
	_check(world.has_method("_own_hp_told"), "a newer HP report is counted (finding 12)")
	if world.has_method("_own_hp_told"):
		world.call("_own_hp_told")
	await create_timer(0.4).timeout
	_check(strikes.size() == 1 and strikes[0] == [100, false],
		"the late blow does not write its older HP over the newer one (got %s)" % str(strikes))
	strikes.clear()
	world.call("_draw_monster_strike", a, true, true)
	await create_timer(0.4).timeout
	_check(strikes.size() == 1 and strikes[0] == [100, true], "with nothing newer, the blow's HP is shown as it lands")
	(world.get("_monster_bodies") as Dictionary).erase(600)
	mob.free()

# --- 14: the dungeon minimap -----------------------------------------------------

func _test_dungeon_signs(world: Node) -> void:
	var mm_script := GDScript.new()
	mm_script.source_code = "\n".join(PackedStringArray([
		"extends \"res://scripts/ui/hud/hud_minimap.gd\"",
		"var quest_calls: Array = []",
		"func update_quest(player_local: Vector2, targets_local: PackedVector2Array) -> void:",
		"\tquest_calls.append(targets_local.size())",
		""]))
	_check(mm_script.reload() == OK, "a minimap double compiles")
	var mm = mm_script.new()
	world.set("_hud_minimap", mm)
	world.set("_dungeon", DungeonWorld.Built.new())
	world.call("_refresh_minimap")
	_check((mm.get("quest_calls") as Array) == [0], "in a dungeon the field's quest signs are cleared (finding 14; got %s)" % str(mm.get("quest_calls")))
	world.set("_dungeon", null)
	world.set("_hud_minimap", null)
	mm.free()
