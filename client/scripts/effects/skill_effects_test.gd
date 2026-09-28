extends SceneTree

## SkillEffects (round 620): the skilleffectset effect rows, phase lookup,
## hosts, bone attachment and the buff-token auras, against synthetic tables
## and synthetic effects built here -- never game data. Run headless:
## `godot4 --headless --path client --script res://scripts/effects/skill_effects_test.gd`
##
## Loaded by path, so a checkout without the script prints FAIL lines.

var _failures := 0

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
	var S: GDScript = load("res://scripts/efp/efp_sim.gd")
	var E: GDScript = load("res://scripts/efp/efp_effect.gd")
	return E.from_template(S.compile(n), func(_p): return null, func(_p): return null, 5)

func _initialize() -> void:
	var se: GDScript = load("res://scripts/effects/skill_effects.gd")
	_check(se != null, "scripts/effects/skill_effects.gd exists (SkillEffects, the skill effect rows)")
	if se == null:
		_finish()
		return
	var sd := _skill_row(90, "TEST_IMBUE_A_01", "TEST_IMBUE_A", 0)
	sd += _skill_row(3, "TEST_SMASH_A_01", "TEST_SMASH_A", 0)
	var skills: Dictionary = SkillAudio.parse_skills(_utf16(sd))
	var header := "//SkillName11\tSkillEffectID\tAniType\tStartEvent\tDMG Event\tDamageType\tScale\tID\tAttach\tTrade\tKill\tCreateCnt\tFade\tActType\tMovTypeSpeed\tParam\tAct Option\tObj Path\tObjName\tStartBone\tStartOffset\tTargetBone\tTargetOffset\tObjName2\tRotate\tScript\tSndBegin\tSndEnd\r\n"
	var text := "#section characterInfo\r\n" + _row("TEST_IMBUE_A", "ACT_L", 0, "AT_LOOP", "x\\", "wrong.efp", "none", "0,0,0")
	text += "#section skilleffectset\r\n" + header
	text += _row("TEST_IMBUE_A", "ACT_S", 0, "AT_ONE_FOLLOW", "skill\\china\\", "motion.efp", "Bip01 R Finger2", "0,0,0")
	text += _row("TEST_IMBUE_A", "ACT_L", 0, "AT_LOOP", "skill\\china\\", "keep.efp", "Bip01 R Finger2", "0,0,0")
	text += _row("TEST_IMBUE_A", "READY", 0, "AT_LOOP", "skill\\china\\", "charge.efp", "none", "0,0,4")
	text += _row("TEST_IMBUE_A", "SHOT", 1, "AT_ONE_FOLLOW", "none", "none", "none", "0,0,0")
	text += _row("TEST_SMASH_A", "SHOT", 1, "AT_DMG_POS", "hiteffect\\", "hit.efp", "none", "0,10,-13")
	var rows: Dictionary = se.parse_rows(_utf16(text))
	_check(rows.has("TEST_IMBUE_A") and (rows["TEST_IMBUE_A"] as Array).size() == 3,
		"only skilleffectset rows that name an .efp are kept (3 for the imbue)")
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

	# Bone attachment: under the skeleton, following the named bone.
	var skel := Skeleton3D.new()
	skel.add_bone("Bip01")
	skel.add_bone("Bip01 R Finger2")
	skel.set_bone_parent(1, 0)
	skel.set_bone_rest(1, Transform3D(Basis.IDENTITY, Vector3(3, 4, 5)))
	skel.reset_bone_poses()
	caster.add_child(skel)
	SkillAudio.set_tables(skills, {})
	se.reset()
	se.set_rows(rows)
	se.effect_factory = _effect
	var fx: Array = se.play_phase(90, SkillAudio.ACT_S, -1, caster, caster, "test")
	_check(fx.size() == 1 and (fx[0] as Node).get_parent() == skel, "the effect is placed under the body's skeleton")
	_check(fx.size() == 1 and (fx[0] as Node3D).position.is_equal_approx(Vector3(3, 4, 5)),
		"... at the StartBone's position (%s)" % (str((fx[0] as Node3D).position) if fx.size() == 1 else "none"))
	_check(fx.size() == 1 and not (fx[0] as EfpEffect).loop, "AT_ONE_FOLLOW plays once")

	# READY loops until the caster's next phase.
	var charge: Array = se.play_phase(90, SkillAudio.READY, -1, caster, null, "test")
	_check(charge.size() == 1 and (charge[0] as EfpEffect).loop, "a READY AT_LOOP charge glow loops")
	se.play_phase(90, SkillAudio.SHOT, 1, caster, target, "test")
	_check(not (charge[0] as EfpEffect).loop, "... and stops when the caster's next phase fires")

	# Buff auras per (owner, token).
	var aura: Array = se.attach_aura("character:7", 41, 90, caster)
	_check(aura.size() == 1 and (aura[0] as EfpEffect).loop and se.aura_count() == 1,
		"attach_aura keeps the ACT_L AT_LOOP effect for the token")
	var again: Array = se.attach_aura("character:7", 41, 90, caster)
	_check(not (aura[0] as EfpEffect).loop and se.aura_count() == 1, "a second start of the same token replaces the first")
	se.attach_aura("character:7", 42, 90, caster)
	se.attach_aura("monster:9", 41, 90, target)
	_check(se.aura_count() == 3, "tokens and owners are kept apart (3 auras)")
	_check(se.detach_aura("character:7", 41) == 1 and not (again[0] as EfpEffect).loop,
		"detach_aura stops the token's aura (it finishes its cycle)")
	_check(se.detach_aura("character:7", 41) == 0, "a token that already ended stops nothing")
	_check(se.detach_owner("character:7") == 1 and se.aura_count() == 1, "detach_owner ends the rest of that owner's auras")
	_check(se.attach_aura("character:8", 1, 3, caster).is_empty(), "a skill with no ACT_L rows makes no aura")
	se.reset()
	caster.queue_free()
	target.queue_free()
	_finish()

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)
