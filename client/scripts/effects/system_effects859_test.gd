extends SceneTree

## Round 859 (lane B): the system decorations (SystemEffects), the hit's
## blood columns (SkillEffectReader, SoundTable), the exp unit column
## (LevelDataReader), SkillEffects.play_system's one-shot end, and the kill
## orbs (ExpOrbs: the count rule, the mover, the live orbs). Synthetic rows and
## synthetic effects only, never game data. Run headless:
## `godot4 --headless --path client --script res://scripts/effects/system_effects859_test.gd`

var _failures := 0
var _tex: Texture2D = ImageTexture.create_from_image(Image.create(2, 2, false, Image.FORMAT_RGBA8))
var _made: Array = []

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _utf16(text: String) -> PackedByteArray:
	var out := PackedByteArray([0xFF, 0xFE])
	out.append_array(text.to_utf16_buffer())
	return out

## A tiny synthetic effect: one 3-frame plate particle (skill_effects_test's).
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
	fx.path = path
	_made.append(fx)
	return fx

func _initialize() -> void:
	process_frame.connect(_run, CONNECT_ONE_SHOT)

func _run() -> void:
	_rules()
	_columns()
	_counts()
	_mover()
	_play_system()
	_orbs()
	print("ALL PASS" if _failures == 0 else "%d FAILED" % _failures)
	quit(0 if _failures == 0 else 1)

func _rules() -> void:
	_check(SystemEffects.level_up_effect(false) == "SYSTEM_LEVELUP" and SystemEffects.level_up_effect(true) == "SYSTEM_PET_LEVEL_UP",
		"0x3054: a COS plays SYSTEM_PET_LEVEL_UP, anything else SYSTEM_LEVELUP")
	_check(SystemEffects.level_up_sounds(false, true, false) and not SystemEffects.level_up_sounds(false, false, false),
		"snd_levup for this player's own level-up only")
	_check(SystemEffects.level_up_sounds(true, false, true) and not SystemEffects.level_up_sounds(true, true, false),
		"a COS's snd_levup only for this player's own COS")
	_check(SystemEffects.own_level_up_is_new(-1, 5000) and not SystemEffects.own_level_up_is_new(4000, 5000)
		and SystemEffects.own_level_up_is_new(1000, 5000), "one level-up told twice within 2 s plays once (OURS)")
	_check(SystemEffects.pet_summon_plays(3, 1) and SystemEffects.pet_summon_plays(4, 1),
		"a growth or ability pet called out (type 1) plays the summon")
	_check(not SystemEffects.pet_summon_plays(3, 4) and not SystemEffects.pet_summon_plays(1, 1)
		and not SystemEffects.pet_summon_plays(2, 1) and not SystemEffects.pet_summon_plays(5, 1),
		"a pet met on the way, a ride, a transport and a soldier play none")
	_check(SystemEffects.blood_path_of("hit_2_stone") == "hiteffect\\hit_2_stone.efp" and SystemEffects.blood_path_of("none") == ""
		and SystemEffects.blood_path_of("") == "", "BloodType -> hiteffect\\<name>.efp, none -> nothing")
	_check(SystemEffects.blood_for("hiteffect\\hit_2_wood.efp", true) == "hiteffect\\hit_2_wood.efp"
		and SystemEffects.blood_for("hiteffect\\hit_2_wood.efp", false) == SystemEffects.GREEN_BLOOD
		and SystemEffects.blood_for("", false) == "", "+0x1c with the option byte set, +0x20 (green) without; none stays none")
	_check(SystemEffects.blood_plays(2, true, true, false) and SystemEffects.blood_plays(1, true, true, false),
		"blood plays with effects on, a DamageEfp and the row's blood flag")
	_check(not SystemEffects.blood_plays(0, true, true, false) and not SystemEffects.blood_plays(2, false, true, false)
		and not SystemEffects.blood_plays(2, true, false, false) and not SystemEffects.blood_plays(2, true, true, true),
		"... and not with effects off, no DamageEfp, the row's 0, or a wall entry")

func _columns() -> void:
	# skillaniset2: 27 columns, the blood flag last (col 26).
	var cols := PackedStringArray(["1", "name", "SKILL_TEST_A", "0", "FALSE", "0", "DEFAULT", "ANI_SKILL_1", "none", "none",
		"none", "none", "none", "none", "hiteffect\\hit_1.efp", "160", "0,0,0,0", "ONE", "none", "none", "none", "none",
		"none", "none", "none", "1", "0"])
	var sets := {}
	SkillEffectReader._aniset_row(cols, "skillaniset2", sets)
	_check(sets.has("SKILL_TEST_A") and sets["SKILL_TEST_A"].get("blood") == false,
		"skillaniset2 col 26 '0' -> no blood (%s)" % [sets.get("SKILL_TEST_A", {}).get("blood")])
	cols[26] = "1"
	cols[2] = "SKILL_TEST_B"
	SkillEffectReader._aniset_row(cols, "skillaniset2", sets)
	_check(SkillEffectReader.blood_for(sets, "SKILL_TEST_B_03") and not SkillEffectReader.blood_for(sets, "SKILL_TEST_A"),
		"blood_for by Basic_Code with a level suffix")
	_check(SkillEffectReader.blood_for(sets, "SKILL_NO_ROW"), "a skill with no row draws blood (READ: 1 without a row)")
	var short := cols.slice(0, 20)
	short[2] = "SKILL_TEST_C"
	SkillEffectReader._aniset_row(short, "skillaniset2", sets)
	_check(SkillEffectReader.blood_for(sets, "SKILL_TEST_C"), "a row without the column draws blood (OURS)")
	# characterInfo: col 9 BloodType.
	var row := PackedStringArray(["MOB_TEST", "MOB_TEST", "2", "none", "none", "none", "none", "none", "0,13,-2",
		"hit_2_stone", "none", "0", "0"])
	var rec := SoundTable.character_record(row)
	_check(rec.blood == "hiteffect\\hit_2_stone.efp", "characterInfo col 9 is the blood (%s)" % rec.blood)
	row[9] = "none"
	_check(SoundTable.character_record(row).blood == "", "BloodType none: no blood")
	# leveldata col 5.
	var lv := _utf16("1\t118\t1\t0\t0\t24\t15000000\t15000000\t15000000\r\n80\t147400127\t2494\t0\t0\t5170\t-1\t-1\t-1\r\n// c\r\n")
	var units := LevelDataReader.parse_exp_unit(lv)
	_check(int(units.get(1, 0)) == 24 and int(units.get(80, 0)) == 5170 and units.size() == 2,
		"leveldata col 5 is the exp unit (%s)" % [units])

func _counts() -> void:
	_check(ExpOrbs.count_for(64.0) == 10 and ExpOrbs.count_for(1000.0) == 10, "64 units or more: 10 orbs")
	_check(ExpOrbs.count_for(63.9) == 9 and ExpOrbs.count_for(32.0) == 9, "[32, 64): 9")
	_check(ExpOrbs.count_for(2.0) == 5 and ExpOrbs.count_for(1.99) == 4 and ExpOrbs.count_for(1.0) == 4,
		"[2, 4): 5, [1, 2): 4")
	_check(ExpOrbs.count_for(0.9) == 3 and ExpOrbs.count_for(0.7) == 2 and ExpOrbs.count_for(0.5) == 1
		and ExpOrbs.count_for(0.01) == 1 and ExpOrbs.count_for(0.0) == 1, "below 1: 3 - int((1 - f) * 5), at least 1")
	var c := ExpOrbs.gain_counts(24, 100, 24)
	_check(c[0] == 4 and c[1] == 4, "a same-level kill's 24 EXP at unit 24 and 100 SP: 4 + 4 (%s)" % [c])
	c = ExpOrbs.gain_counts(0, 0, 24)
	_check(c[0] == 0 and c[1] == 0, "no gain, no orbs")
	_check(is_zero_approx(ExpOrbs.exp_fraction(10, 0)) and ExpOrbs.exp_fraction(10, -1) < 1e-8,
		"a unit of 0 counts nothing; -1 reads unsigned (tiny)")

## A rand() that replays a list.
func _seq(values: Array) -> Callable:
	var state := {"i": 0}
	return func() -> int:
		var v := int(values[state["i"] % values.size()])
		state["i"] = int(state["i"]) + 1
		return v

func _mover() -> void:
	var m := ExpOrbs.Mover.new()
	# rand: y 200 -> 0.3, r 10 -> 60, delay 500, k 100 -> 1.0
	m.init(Vector3(100, 0, 0), Vector3(0, 0, 0), 0.0, 1.0, 1.0, _seq([200, 10, 500, 100]))
	_check(m.state == 1 and m.delay == 500 and is_equal_approx(m.k, 1.0), "init: waiting, delay and k from the draws")
	var u := Vector3(1, 0.3, 0).normalized()
	_check(m.v.is_equal_approx(u * 60.0), "init: away from the target, 0.3 up, 60 u/s (%s)" % m.v)
	_check(m.step(400) and m.state == 1 and m.p.is_equal_approx(Vector3(100, 0, 0)), "it holds still for its delay")
	_check(m.step(100) and m.state == 2, "then turns (state 2) at the delay")
	var steps := 0
	while m.step(16) and steps < 1000:
		steps += 1
	_check(m.state == 0 and m.p.is_equal_approx(Vector3.ZERO), "it reaches the target and reports done (%d steps)" % steps)
	_check(m.elapsed <= m.delay + 0xdac + 16, "within the 3.5 s bound (%d ms)" % m.elapsed)
	_check(not m.step(16), "a done mover stays done")
	var a := ExpOrbs.Mover.new()
	a.init(Vector3(10, 5, 0), Vector3(0, 5, 0), 0.0, 1.0, 1.0, _seq([0, 0, 0, 0]))
	a.t = Vector3(1000, 5, 0)
	var n := 0
	while a.step(50) and n < 200:
		n += 1
	_check(a.state == 0 and a.p.is_equal_approx(a.t) and a.elapsed <= 0xdac + 50,
		"a target it cannot catch is reached at the 3.5 s bound (%d ms)" % a.elapsed)
	var b := ExpOrbs.Mover.new()
	b.init(Vector3(0, 0, 0), Vector3(0, 0, 0), 0.0, 1.0, 1.0, _seq([0, 0, 0, 0]))
	_check(not b.step(16), "a mover already at its target is done at once")

func _play_system() -> void:
	SkillEffects.reset()
	var header := "//SkillName11\tSkillEffectID\tAniType\tStartEvent\tDMG Event\tDamageType\tScale\tID\tAttach\tTrade\tKill\tCreateCnt\tFade\tActType\tMovTypeSpeed\tParam\tAct Option\tObj Path\tObjName\tStartBone\tStartOffset\tTargetBone\tTargetOffset\tObjName2\tRotate\tScript\tSndBegin\tSndEnd\r\n"
	var rowf := func(id: String, act: String, obj: String) -> String:
		var cols := ["label", id, "ACT_S", "0", "FALSE", "none", "none", "0", "0", "0", "0", "1", "0,0", act,
			"MOV_NONE,0,0,0", "0,0,0", "false,0,0,0,0,false", "system\\", obj, "none", "0,0,0", "none", "0,0,0", "none", "0",
			"none", "none", "none"]
		return "\t".join(PackedStringArray(cols)) + "\r\n"
	var text := "#section skilleffectset\r\n" + header
	text += rowf.call("SYSTEM_LEVELUP", "AT_ONE_FOLLOW", "system_levelup.efp")
	text += rowf.call("SYSTEM_PET_APPEAR", "AT_LOOP", "item_returnscroll.efp")
	SkillEffects.set_rows(SkillEffects.parse_rows(_utf16(text)))
	SkillEffects.effect_factory = _effect
	var body := Node3D.new()
	get_root().add_child(body)
	var up := SkillEffects.play_system("SYSTEM_LEVELUP", body)
	_check(up.size() == 1 and (up[0] as EfpEffect).path.ends_with("system_levelup.efp") and not (up[0] as EfpEffect).loop
		and (up[0] as Node).get_parent() == body, "SYSTEM_LEVELUP: its ACT_S row on the body, once")
	var pet := SkillEffects.play_system("SYSTEM_PET_APPEAR", body)
	_check(pet.size() == 1 and not (pet[0] as EfpEffect).loop and is_instance_valid(pet[0]),
		"SYSTEM_PET_APPEAR's AT_LOOP row is let go at once (the decoration ends): it plays one cycle")
	_check(SkillEffects.aura_count() == 0, "a system one-shot holds no aura")
	SkillEffects.effect_factory = Callable()
	SkillEffects.reset()
	body.queue_free()

func _orbs() -> void:
	var holder := Node3D.new()
	get_root().add_child(holder)
	var player := Node3D.new()
	holder.add_child(player)
	player.global_position = Vector3(0, 0, 0)
	var heard: Array = []
	var orbs := ExpOrbs.new()
	orbs.parent = holder
	orbs.factory = _effect
	orbs.sound = func(path: String, at: Vector3) -> void: heard.append([path, at])
	orbs.rand = _seq([5, 100, 3, 50, 7])
	_made.clear()
	var n := orbs.launch(Vector3(60, 0, 40), [4, 2, 0, 1], player)
	_check(n == 6 and orbs.live() == 6, "4 EXP + 2 SP orbs fly; a COS orb with no COS body does not (%d)" % n)
	var fly := _made.map(func(f): return (f as EfpEffect).path)
	_check(fly.count("battle\\hwan_g.efp") == 4 and fly.count("battle\\hwan_y.efp") == 2,
		"EXP orbs are hwan_g, SP orbs hwan_y (%s)" % [fly])
	_check((_made[0] as EfpEffect).loop, "a flying orb is kept (slot 4 with 1)")
	_check(ExpOrbs.target_point(player).is_equal_approx(Vector3(0, ExpOrbs.NO_BONE_RISE, 0)),
		"a body with no Bip01 Spine1 is aimed at 10 above its feet")
	_made.clear()
	var guard := 0
	while orbs.live() > 0 and guard < 400:
		orbs.tick(1.0 / 60.0)
		guard += 1
	_check(orbs.live() == 0 and orbs.absorbed == 6, "every orb is absorbed (%d frames)" % guard)
	var ab := _made.map(func(f): return (f as EfpEffect).path)
	_check(ab.count("battle\\hwn_blue_indraft.efp") == 4 and ab.count("battle\\hwn_red_indraft.efp") == 2,
		"each lands as its indraft: blue for EXP, red for SP (%s)" % [ab])
	_check(heard.size() == 6 and String(heard[0][0]) == "prim\\snd\\ui\\hyanget.wav"
		and (heard[0][1] as Vector3).distance_to(Vector3(0, 10, 0)) < 0.01,
		"hyanget.wav at the player's chest for each (%d)" % heard.size())
	orbs.launch(Vector3(60, 0, 40), [1, 0, 0, 0], player)
	orbs.clear()
	_check(orbs.live() == 0, "clear drops the orbs in flight")
	holder.queue_free()
