extends SceneTree

## SkillEffects (round 620): the skilleffectset effect rows, phase lookup,
## hosts, bone attachment and the buff-token auras, against synthetic tables
## and synthetic effects built here -- never game data. Run headless:
## `godot4 --headless --path client --script res://scripts/effects/skill_effects_test.gd`
##
## Loaded by path, so a checkout without the script prints FAIL lines.

var _failures := 0
var _drawable := true
var _made: Array = []
var _tex: Texture2D = ImageTexture.create_from_image(Image.create(2, 2, false, Image.FORMAT_RGBA8))
var se: GDScript
var skills: Dictionary
var rows: Dictionary

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

func _skill_row(id: int, code: String, group: String, original: int) -> String:
	return "1\t%d\t%d\t%s\tname\t%s\t%d\t1\t0\t0\t0\r\n" % [id, id, code, group, original]

## A skilleffectset-shaped row in the file's own column order.
func _row(id: String, ani: String, ev: int, act: String, dir: String, obj: String, bone: String,
		offset: String, dmg: bool = false, mov: String = "MOV_NONE,0,0,0") -> String:
	var cols: Array = ["label", id, ani, str(ev), "TRUE" if dmg else "FALSE", "none", "none", "0", "0", "0", "0", "1",
		"0,0", act, mov, "0,0,0", "false,0,0,0,0,false", dir, obj, bone, offset,
		"none", "0,0,0", "none", "0", "none", "none", "none"]
	return "\t".join(PackedStringArray(cols)) + "\r\n"

## A tiny synthetic effect: one 3-frame plate particle.
func _effect(_path: String) -> EfpEffect:
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
	ref.textures = PackedStringArray(["t.ddj"] if _drawable else ["missing.ddj"])
	n.meshes.append(ref)
	var S: GDScript = load("res://scripts/efp/efp_sim.gd")
	var E: GDScript = load("res://scripts/efp/efp_effect.gd")
	var fx = E.from_template(S.compile(n), func(p): return _tex if p == "t.ddj" else null, func(_p): return null, 5)
	_made.append(fx)
	return fx

func _initialize() -> void:
	# The attachment checks need the tree running: they start on the first frame.
	process_frame.connect(_run, CONNECT_ONE_SHOT)

func _run() -> void:
	se = load("res://scripts/effects/skill_effects.gd")
	_check(se != null, "scripts/effects/skill_effects.gd exists (SkillEffects, the skill effect rows)")
	if se == null:
		_finish()
		return
	var sd := _skill_row(90, "TEST_IMBUE_A_01", "TEST_IMBUE_A", 0)
	sd += _skill_row(3, "TEST_SMASH_A_01", "TEST_SMASH_A", 0)
	sd += _skill_row(4, "TEST_BOLT_A_01", "TEST_BOLT_A", 0)
	sd += _skill_row(5, "TEST_STUN_A_01", "TEST_STUN_A", 0)
	skills = SkillAudio.parse_skills(_utf16(sd))
	var header := "//SkillName11\tSkillEffectID\tAniType\tStartEvent\tDMG Event\tDamageType\tScale\tID\tAttach\tTrade\tKill\tCreateCnt\tFade\tActType\tMovTypeSpeed\tParam\tAct Option\tObj Path\tObjName\tStartBone\tStartOffset\tTargetBone\tTargetOffset\tObjName2\tRotate\tScript\tSndBegin\tSndEnd\r\n"
	var text := "#section characterInfo\r\n" + _row("TEST_IMBUE_A", "ACT_L", 0, "AT_LOOP", "x\\", "wrong.efp", "none", "0,0,0")
	text += "#section skilleffectset\r\n" + header
	text += _row("TEST_IMBUE_A", "ACT_S", 0, "AT_ONE_FOLLOW", "skill\\china\\", "motion.efp", "Bip01 R Finger2", "0,0,0")
	text += _row("TEST_IMBUE_A", "ACT_L", 0, "AT_LOOP", "skill\\china\\", "keep.efp", "Bip01 R Finger2", "0,0,0")
	text += _row("TEST_IMBUE_A", "READY", 0, "AT_LOOP", "skill\\china\\", "charge.efp", "none", "0,0,4")
	text += _row("TEST_IMBUE_A", "SHOT", 1, "AT_ONE_FOLLOW", "none", "none", "none", "0,0,0")
	text += _row("TEST_SMASH_A", "SHOT", 1, "AT_DMG_POS", "hiteffect\\", "hit.efp", "none", "0,10,-13", true)
	text += _row("TEST_IMBUE_A", "WAIT", 0, "AT_LOOP", "skill\\china\\", "wait.efp", "none", "0,0,0")
	text += _row("TEST_BOLT_A", "SHOT", 1, "AT_MOV_1TAR", "skill\\china\\", "bolt.efp", "none", "0,9,-14", true, "MOV_STRAIGHT,0,200,200")
	text += _row("PARAM_TEST", "ACT_L", 0, "AT_LOOP", "battle\\", "status.efp", "Bip01", "0,0,0")
	text += _row("TEST_STUN_A", "SHOT", 1, "AT_STOP", "monster\\", "stun.efp", "none", "0,0,0")
	rows = se.parse_rows(_utf16(text))
	_check(rows.has("TEST_IMBUE_A") and (rows["TEST_IMBUE_A"] as Array).size() == 4,
		"only skilleffectset rows that name an .efp are kept (4 for the imbue)")
	var keep: Array = se.rows_in(skills, rows, 90, SkillAudio.ACT_L)
	_check(keep.size() == 1 and keep[0]["path"] == "skill\\china\\keep.efp" and keep[0]["act"] == se.AT_LOOP
		and keep[0]["bone"] == "Bip01 R Finger2", "ACT_L: Obj Path + ObjName, AT_LOOP, at the StartBone")
	var ready: Array = se.rows_in(skills, rows, 90, SkillAudio.READY)
	_check(ready.size() == 1 and (ready[0]["offset"] as Vector3).is_equal_approx(Vector3(0, 0, 4)), "StartOffset parses")
	var hit: Array = se.rows_in(skills, rows, 3, SkillAudio.SHOT, 1)
	_check(hit.size() == 1 and hit[0]["act"] == se.AT_DMG_POS, "the smash's SHOT/1 row plays at the damage position")
	_check(se.rows_in(skills, rows, 3, SkillAudio.SHOT, 0).is_empty(), "StartEvent filters")

	# Hosts.
	var caster := Node3D.new()
	var target := Node3D.new()
	get_root().add_child(caster)
	get_root().add_child(target)
	_check(se.host_for(se.AT_DMG_POS, caster, target) == target, "AT_DMG_POS plays on the target")
	_check(se.host_for(se.AT_ONE_FOLLOW, caster, target) == caster, "AT_ONE_FOLLOW plays on the caster")
	_check(se.host_for(se.AT_TARGET, caster, null) == caster, "a target row with no target falls back to the caster")

	# Bone attachment: a child of the body, placed at the bone of its current skeleton.
	var skel := _skeleton(Vector3(3, 4, 5))
	caster.add_child(skel)
	SkillAudio.set_tables(skills, {})
	se.reset()
	se.set_rows(rows, {90: [500, 1000], 3: [0, 411]})
	se.effect_factory = _effect
	var fx: Array = se.play_phase(90, SkillAudio.ACT_S, -1, caster, caster, "test")
	_check(fx.size() == 1 and (fx[0] as Node).get_parent() == caster, "the effect is a child of the body, not of its skeleton")
	_check(fx.size() == 1 and (fx[0] as EfpEffect).placed_at().is_equal_approx(Vector3(3, 4, 5)),
		"... placed at the StartBone (%s)" % (str((fx[0] as EfpEffect).placed_at()) if fx.size() == 1 else "none"))
	_check(fx.size() == 1 and not (fx[0] as EfpEffect).loop, "AT_ONE_FOLLOW plays once")

	# Round 785: the ActType values are retail's (READ: the name table at
	# 0x00ec7280 the row parser maps the column through), and only AT_LOOP is
	# kept; AT_STOP plays once where it was cast (IDecoSkill::FUN_00a513a0).
	_check(se.ACT_TYPES.find("AT_STOP") == 0 and se.ACT_TYPES.find("AT_ONE_FOLLOW") == 1
		and se.ACT_TYPES.find("AT_LOOP") == 2 and se.ACT_TYPES.find("AT_TARGET") == 3
		and se.ACT_TYPES.find("AT_DMG_POS") == 6 and se.ACT_TYPES.find("AT_MOV_PIERCE") == 11
		and se.AT_STOP == 0 and se.AT_ONE_FOLLOW == 1 and se.AT_LOOP == 2,
		"ActType values: AT_STOP 0, AT_ONE_FOLLOW 1, AT_LOOP 2, AT_TARGET 3 ... AT_MOV_PIERCE 11")
	_check(se.kept_act(se.AT_LOOP) and not se.kept_act(se.AT_STOP) and not se.kept_act(se.AT_ONE_FOLLOW),
		"only AT_LOOP is kept")
	var stop: Array = se.play_phase(5, SkillAudio.SHOT, 1, caster, null, "test")
	_check(stop.size() == 1 and not (stop[0] as EfpEffect).loop and (stop[0] as EfpEffect).static_host,
		"AT_STOP plays once and is placed once")
	if stop.size() == 1:
		var at0: Vector3 = (stop[0] as EfpEffect).placed_at()
		var at_follow: Vector3 = (fx[0] as EfpEffect).placed_at()
		caster.position += Vector3(30, 0, 0)
		(stop[0] as EfpEffect)._process(0.05)
		(fx[0] as EfpEffect)._process(0.05)
		_check((stop[0] as EfpEffect).placed_at().is_equal_approx(at0) and (fx[0] as EfpEffect).placed_at().is_equal_approx(at_follow + Vector3(30, 0, 0)),
			"... the AT_STOP effect stays where it was cast while the AT_ONE_FOLLOW one follows the body")
		caster.position -= Vector3(30, 0, 0)
		(stop[0] as EfpEffect).stop()

	# Round 785 (READ: GlobalEffectManager::FUN_00a9d0f0's placement flags,
	# IDecoSkill::FUN_00a4a680 / FUN_00a4ddc0): a plain StartBone turns the
	# effect with the bone; '@' puts it at the bone along the world's axes;
	# "none" turns it with the body; Rotate turns it in its own frame after.
	_bone_turns()

	# An equipment change frees the skeleton: the aura stays and moves to the new one.
	var aura0: Array = se.attach_aura("character:1", 5, 90, caster)
	skel.free()
	var skel2 := _skeleton(Vector3(7, 1, 2))
	caster.add_child(skel2)
	(aura0[0] as EfpEffect)._process(0.0)
	# Round 621 (follow levels): the effect node stays at its anchor and its
	# placement carries the host, so the placement is what moved.
	_check(is_instance_valid(aura0[0]) and (aura0[0] as EfpEffect).placed_at().is_equal_approx(Vector3(7, 1, 2)),
		"a rebuilt skeleton keeps the aura, now at the new skeleton's bone")
	var dying := _skeleton(Vector3(9, 9, 9))
	skel2.add_sibling(dying)
	skel2.queue_free()
	_check(se.skeleton_of(caster) == dying, "skeleton_of skips a skeleton queued for deletion")
	se.detach_aura("character:1", 5)

	# An aura attached before the body has a skeleton finds it when it comes.
	var bare := Node3D.new()
	get_root().add_child(bare)
	var early: Array = se.attach_aura("character:2", 1, 90, bare)
	bare.add_child(_skeleton(Vector3(0, 6, 0)))
	(early[0] as EfpEffect)._process(0.0)
	_check((early[0] as EfpEffect).placed_at().is_equal_approx(Vector3(0, 6, 0)), "an aura attached before the skeleton finds its bone later")
	se.detach_aura("character:2", 1)

	# Round 785: the DMG groups and the projectile flight.
	_check(se.group_dmg(3, SkillAudio.SHOT, 1) and not se.group_dmg(3, SkillAudio.SHOT, 0),
		"group_dmg: the smash's SHOT/1 carries the DMG event")
	_check(se.group_dmg_flies(4, SkillAudio.SHOT, 1), "group_dmg_flies: the bolt's DMG row is a projectile")
	_check(se.last_event(3, SkillAudio.SHOT) == 1, "last_event: the smash's SHOT groups run to 1")
	var arrived := [false]
	target.position = Vector3(100, 0, 0)
	var shot: Array = se.play_phase(4, SkillAudio.SHOT, 1, caster, target, "test", func() -> void: arrived[0] = true)
	_check(shot.size() == 1 and se.flight_count() == 1 and not arrived[0], "the projectile leaves the caster, its hit in the air")
	se.step_flights(0.1)
	_check(se.flight_count() == 1 and not arrived[0], "... 200 u/s: 20 units after 0.1 s")
	se.step_flights(1.0)
	_check(se.flight_count() == 0 and arrived[0], "... and lands its hit on arrival")
	var gone_target := Node3D.new()
	get_root().add_child(gone_target)
	var landed := [false]
	se.play_phase(4, SkillAudio.SHOT, 1, caster, gone_target, "test", func() -> void: landed[0] = true)
	gone_target.free()
	se.step_flights(0.016)
	_check(se.flight_count() == 0 and landed[0], "a projectile whose target is gone lands where it is")
	target.position = Vector3.ZERO
	var acted: Array = se.act(90, caster, caster)
	_check(acted.size() == 1 and not (acted[0] as EfpEffect).loop, "act(): ACT_S now")
	_check(se.act(90, caster, caster, true).size() == 2, "act(..., true): ACT_S and one ACT_L cycle when no token will come")

	# An effect that draws nothing is not left behind.
	_drawable = false
	_made.clear()
	_check(se.play_phase(90, SkillAudio.ACT_S, -1, caster, caster, "test").is_empty()
		and not is_instance_valid(_made[0]), "an effect drawing nothing is freed, not orphaned")
	_drawable = true

	# Buff auras per (owner, token).
	var aura: Array = se.attach_aura("character:7", 41, 90, caster)
	_check(aura.size() == 1 and (aura[0] as EfpEffect).loop and se.aura_count() == 1,
		"attach_aura keeps the ACT_L AT_LOOP effect for the token")
	var again: Array = se.attach_aura("character:7", 41, 90, caster)
	_check(not (aura[0] as EfpEffect).loop and se.aura_count() == 1 and _let_go(aura[0]), "a second start of the same token replaces the first (the first let go)")
	se.attach_aura("character:7", 42, 90, caster)
	se.attach_aura("monster:9", 41, 90, target)
	_check(se.aura_count() == 3, "tokens and owners are kept apart (3 auras)")
	var detached: int = se.detach_aura("character:7", 41)
	_check(detached == 1 and not (again[0] as Node).is_queued_for_deletion() and not (again[0] as EfpEffect).loop,
		"detach_aura lets the token's aura go: it is no longer kept, and still drawn this frame (round 785, READ)")
	_check(_let_go(again[0]), "... and it ends once its last cycle has played out")
	_check(se.detach_aura("character:7", 41) == 0, "a token that already ended stops nothing")
	_check(se.detach_owner("character:7") == 1 and se.aura_count() == 1, "detach_owner ends the rest of that owner's auras")
	_check(se.attach_aura("character:8", 1, 3, caster).is_empty(), "a skill with no ACT_L rows makes no aura")
	# The fallback end: remaining time + AURA_GRACE_MS.
	var timed: Array = se.attach_aura("character:3", 1, 90, caster, 1000, 0)
	se.process(1000 + se.AURA_GRACE_MS - 1)
	_check(not (timed[0] as Node).is_queued_for_deletion(), "an aura outlives its time by up to the grace period")
	se.process(1000 + se.AURA_GRACE_MS)
	_check(_let_go(timed[0]), "... and then is let go even if no buff end arrived")
	# Freed bodies are forgotten.
	var gone := Node3D.new()
	get_root().add_child(gone)
	se.attach_aura("monster:5", 3, 90, gone)
	var before: int = se.tracked_count()
	gone.free()
	se.process(1)
	_check(se.tracked_count() == before - 1, "a freed body's auras are pruned (%d -> %d)" % [before, se.tracked_count()])
	# Round 785: an effect id's own rows (a PARAM_ state).
	var st: Array = se.play_named("PARAM_TEST", SkillAudio.ACT_L, caster, "character:4", -1003)
	_check(st.size() == 1 and (st[0] as EfpEffect).loop and se.has_aura_on("character:4", -1003, -1, caster),
		"play_named: a state's ACT_L loop kept as the owner's aura")
	_check(se.detach_aura("character:4", -1003) == 1, "... and ended by its token")
	# The effect caches are bounded (LRU, OURS).
	for i in range(300):
		EfpEffect.template_for("nowhere\\f%d.efp" % i, null)
	_check(int(EfpEffect.cache_sizes()["templates"]) <= EfpEffect.CACHE_TEMPLATES,
		"the template cache keeps at most CACHE_TEMPLATES (%d)" % int(EfpEffect.cache_sizes()["templates"]))
	EfpEffect.clear_caches()
	se.reset()
	caster.queue_free()
	target.queue_free()
	bare.queue_free()
	_finish()

## Round 785: ended the way retail's decoration ends an effect (READ,
## IDecoSkill::FUN_00a4db00: slot 4 with 0) -- let go, no longer kept, and
## gone once its last cycle has played out (EfpEffect.release).
func _let_go(fx) -> bool:
	if fx == null or not is_instance_valid(fx) or (fx as Node).is_queued_for_deletion():
		return true
	var e := fx as EfpEffect
	if e.loop:
		return false
	for i in 400:
		e._process(0.05)
		if not is_instance_valid(e) or e.is_queued_for_deletion():
			return true
	return false

func _bone_turns() -> void:
	var body := Node3D.new()
	body.rotation.y = 0.5 # the body faces somewhere else than the bone
	get_root().add_child(body)
	var sk := Skeleton3D.new()
	sk.add_bone("Bip01")
	sk.add_bone("Bip01 R Finger2")
	sk.set_bone_parent(1, 0)
	var bone_turn := Basis(Vector3(0, 0, 1), PI / 2)
	sk.set_bone_rest(1, Transform3D(bone_turn, Vector3(1, 2, 3)))
	sk.reset_bone_poses()
	body.add_child(sk)
	var body_turn := body.global_transform.basis
	var cases := [["Bip01 R Finger2", 0, body_turn * bone_turn, "a plain StartBone: the bone's turn"],
		["@Bip01 R Finger2", 0, Basis.IDENTITY, "'@': the world's axes at the bone"],
		["none", 0, body_turn, "\"none\": the body's turn"],
		["Bip01 R Finger2", 450, body_turn * bone_turn * Basis(Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(0, -1, 0)),
			"Rotate 450: the bone's turn, then 90 degrees about X in the effect's frame"]]
	for c in cases:
		var fx := _effect("x.efp")
		se.attach(fx, body, String(c[0]), Vector3(0, 0, 1), int(c[1]))
		fx._process(0.0)
		var want: Basis = c[2]
		var at_ok := true
		if String(c[0]) != "none":
			# the bone's position plus the offset turned by the body, not the bone
			at_ok = fx.placed_at().is_equal_approx(body.global_transform * (Vector3(1, 2, 3) + Vector3(0, 0, 1)))
		_check(fx.sim._root.rot.is_equal_approx(want) and at_ok,
			"%s (%s, at %s)" % [String(c[3]), str(fx.sim._root.rot), str(fx.placed_at())])
		fx.stop()
	_check(se.rotate_basis(990).is_equal_approx(Basis(Vector3(0, -1, 0), Vector3(1, 0, 0), Vector3(0, 0, 1)))
		and se.rotate_basis(180).is_equal_approx(Basis(Vector3(-1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, -1)))
		and se.rotate_basis(0) == Basis.IDENTITY,
		"Rotate 990 is 270 degrees about Z, 180 is 180 about Y, 0 none")
	body.free()

func _skeleton(at: Vector3) -> Skeleton3D:
	var sk := Skeleton3D.new()
	sk.add_bone("Bip01")
	sk.add_bone("Bip01 R Finger2")
	sk.set_bone_parent(1, 0)
	sk.set_bone_rest(1, Transform3D(Basis.IDENTITY, at))
	sk.reset_bone_poses()
	return sk

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)
