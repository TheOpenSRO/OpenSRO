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
		offset: String) -> String:
	var cols: Array = ["label", id, ani, str(ev), "FALSE", "none", "none", "0", "0", "0", "0", "1",
		"0,0", act, "MOV_NONE,0,0,0", "0,0,0", "false,0,0,0,0,false", dir, obj, bone, offset,
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
	skills = SkillAudio.parse_skills(_utf16(sd))
	var header := "//SkillName11\tSkillEffectID\tAniType\tStartEvent\tDMG Event\tDamageType\tScale\tID\tAttach\tTrade\tKill\tCreateCnt\tFade\tActType\tMovTypeSpeed\tParam\tAct Option\tObj Path\tObjName\tStartBone\tStartOffset\tTargetBone\tTargetOffset\tObjName2\tRotate\tScript\tSndBegin\tSndEnd\r\n"
	var text := "#section characterInfo\r\n" + _row("TEST_IMBUE_A", "ACT_L", 0, "AT_LOOP", "x\\", "wrong.efp", "none", "0,0,0")
	text += "#section skilleffectset\r\n" + header
	text += _row("TEST_IMBUE_A", "ACT_S", 0, "AT_ONE_FOLLOW", "skill\\china\\", "motion.efp", "Bip01 R Finger2", "0,0,0")
	text += _row("TEST_IMBUE_A", "ACT_L", 0, "AT_LOOP", "skill\\china\\", "keep.efp", "Bip01 R Finger2", "0,0,0")
	text += _row("TEST_IMBUE_A", "READY", 0, "AT_LOOP", "skill\\china\\", "charge.efp", "none", "0,0,4")
	text += _row("TEST_IMBUE_A", "SHOT", 1, "AT_ONE_FOLLOW", "none", "none", "none", "0,0,0")
	text += _row("TEST_SMASH_A", "SHOT", 1, "AT_DMG_POS", "hiteffect\\", "hit.efp", "none", "0,10,-13")
	text += _row("TEST_IMBUE_A", "WAIT", 0, "AT_LOOP", "skill\\china\\", "wait.efp", "none", "0,0,0")
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
	_check(fx.size() == 1 and (fx[0] as Node3D).global_position.is_equal_approx(Vector3(3, 4, 5)),
		"... placed at the StartBone (%s)" % (str((fx[0] as Node3D).global_position) if fx.size() == 1 else "none"))
	_check(fx.size() == 1 and not (fx[0] as EfpEffect).loop, "AT_ONE_FOLLOW plays once")

	# An equipment change frees the skeleton: the aura stays and moves to the new one.
	var aura0: Array = se.attach_aura("character:1", 5, 90, caster)
	skel.free()
	var skel2 := _skeleton(Vector3(7, 1, 2))
	caster.add_child(skel2)
	(aura0[0] as EfpEffect)._process(0.0)
	_check(is_instance_valid(aura0[0]) and (aura0[0] as Node3D).global_position.is_equal_approx(Vector3(7, 1, 2)),
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
	_check((early[0] as Node3D).global_position.is_equal_approx(Vector3(0, 6, 0)), "an aura attached before the skeleton finds its bone later")
	se.detach_aura("character:2", 1)

	# The cast sequencer: READY now, WAIT after prep, SHOT at the server's answer.
	var c0: Array = se.cast(90, caster, target, {"now_ms": 1000})
	_check(c0.size() == 1 and (c0[0] as EfpEffect).loop and se.cast_phase(caster) == SkillAudio.READY,
		"cast: the READY AT_LOOP glow starts at once and loops")
	se.process(1499)
	_check(se.cast_phase(caster) == SkillAudio.READY, "... READY holds for the preparing time (500 ms)")
	se.process(1500)
	_check(se.cast_phase(caster) == SkillAudio.WAIT and is_instance_valid(c0[0]) and not (c0[0] as Node).is_queued_for_deletion(),
		"... WAIT starts at prep; a skill with WAIT rows holds there, READY's loop still up")
	se.shot(caster, 1700)
	_check(se.cast_phase(caster) == -1 and (c0[0] as Node).is_queued_for_deletion(),
		"shot(): SHOT starts at the server's answer and the phase loops end then")
	se.cast(90, caster, target, {"now_ms": 5000})
	se.process(6600)
	_check(se.cast_phase(caster) == -1, "without an answer SHOT starts at prep + cast (OURS fallback)")
	# A skill without WAIT rows goes READY -> SHOT at prep; prep 0 = at once.
	se.cast(3, caster, target, {"now_ms": 100})
	_check(se.cast_phase(caster) == -1, "prep 0 and no WAIT rows: SHOT at the cast's start")
	var hits: Array = se.hit(caster, target, 3)
	_check(hits.size() == 1 and (hits[0] as Node).get_parent() == target, "hit(): SHOT/1 rows on the struck body")
	# cancel_cast: a refused cast ends its loops and fires nothing more.
	var c1: Array = se.cast(90, caster, target, {"now_ms": 9000})
	se.cancel_cast(caster)
	_check(se.cast_phase(caster) == -1 and (c1[0] as Node).is_queued_for_deletion(), "cancel_cast ends the cast and its READY loop")
	se.process(20000)
	_check(se.cast_phase(caster) == -1, "... and nothing fires later")
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
	_check((aura[0] as Node).is_queued_for_deletion() and se.aura_count() == 1, "a second start of the same token replaces the first")
	se.attach_aura("character:7", 42, 90, caster)
	se.attach_aura("monster:9", 41, 90, target)
	_check(se.aura_count() == 3, "tokens and owners are kept apart (3 auras)")
	_check(se.detach_aura("character:7", 41) == 1 and (again[0] as Node).is_queued_for_deletion(),
		"detach_aura ends the token's aura at once")
	_check(se.detach_aura("character:7", 41) == 0, "a token that already ended stops nothing")
	_check(se.detach_owner("character:7") == 1 and se.aura_count() == 1, "detach_owner ends the rest of that owner's auras")
	_check(se.attach_aura("character:8", 1, 3, caster).is_empty(), "a skill with no ACT_L rows makes no aura")
	# The fallback end: remaining time + AURA_GRACE_MS.
	var timed: Array = se.attach_aura("character:3", 1, 90, caster, 1000, 0)
	se.process(1000 + se.AURA_GRACE_MS - 1)
	_check(not (timed[0] as Node).is_queued_for_deletion(), "an aura outlives its time by up to the grace period")
	se.process(1000 + se.AURA_GRACE_MS)
	_check((timed[0] as Node).is_queued_for_deletion(), "... and then ends even if no buff end arrived")
	# Freed bodies are forgotten.
	var gone := Node3D.new()
	get_root().add_child(gone)
	se.attach_aura("monster:5", 3, 90, gone)
	se.cast(90, gone, null, {"now_ms": 0})
	var before: int = se.tracked_count()
	gone.free()
	se.process(1)
	_check(se.tracked_count() == before - 2, "a freed body's cast and auras are pruned (%d -> %d)" % [before, se.tracked_count()])
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
