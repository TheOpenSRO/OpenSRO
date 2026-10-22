extends SceneTree

## Round 809: a skill row's .bsr object (BsrEffect), the radial option mover
## (AT_MOV_OPTION) with its trail, ObjName2 and Fade, and the heading the
## movers take -- against synthetic rows, models and effects built here,
## never game data. Run headless on the render box:
## `client/tools/remote_godot.sh tests` (or this file alone with --script).
##
## NEGATIVE (by construction): against v0.1.569 parse_rows drops the .bsr
## row and has no option, fade or ObjName2 fields, so the first checks fail.

var _failures := 0
var _made: Array = []
var _tex: Texture2D = ImageTexture.create_from_image(Image.create(2, 2, false, Image.FORMAT_RGBA8))
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

func _skill_row(id: int, code: String, group: String) -> String:
	return "1\t%d\t%d\t%s\tname\t%s\t0\t1\t0\t0\t0\r\n" % [id, id, code, group]

## A skilleffectset row in the file's own column order (the header names them).
func _row(id: String, act: String, dir: String, obj: String, mov: String, opt: String, fade: String,
		obj2: String, tbone: String = "none", toffset: String = "0,0,0", cnt: String = "1", scale: String = "none") -> String:
	var cols: Array = ["label", id, "SHOT", "1", "FALSE", "none", scale, "0", "0", "0", "0", cnt,
		fade, act, mov, "0,0,0", opt, dir, obj, "none", "0,0,0",
		tbone, toffset, obj2, "0", "none", "none", "none"]
	return "\t".join(PackedStringArray(cols)) + "\r\n"

## A tiny synthetic effect (one plate particle), counted by path.
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

func _made_named(path: String) -> Array:
	var out: Array = []
	for fx in _made:
		if is_instance_valid(fx) and String((fx as EfpEffect).path) == path:
			out.append(fx)
	return out

## A synthetic .bsr model: one bone, a 600 ms one-shot of type 2.
func _model(_p: String) -> SkinnedBsrAssembler.AssembledCharacter:
	var a := SkinnedBsrAssembler.AssembledCharacter.new()
	var sk := Skeleton3D.new()
	sk.add_bone("Bone01")
	sk.set_bone_rest(0, Transform3D.IDENTITY)
	sk.reset_bone_poses()
	a.skeleton = sk
	var po := BsrReader.ParsedObject.new()
	var e := BsrReader.AnimationEntry.new()
	e.action_type = 2
	e.path = "t\\pillar_up.ban"
	po.animation_groups = {"default": [e]}
	a.parsed = po
	var anim := BanReader.ParsedAnimation.new()
	anim.duration_ms = 600
	anim.cyclic = false
	anim.key_times = PackedInt32Array([0, 600])
	a.animation_cache = {"t\\pillar_up.ban": anim}
	return a

func _initialize() -> void:
	process_frame.connect(_run, CONNECT_ONE_SHOT)

func _run() -> void:
	var sd := _skill_row(268, "MSKILL_T_PILLAR", "MSKILL_T_PILLAR")
	sd += _skill_row(269, "MSKILL_T_STAR", "MSKILL_T_STAR")
	sd += _skill_row(270, "MSKILL_T_BOLT", "MSKILL_T_BOLT")
	skills = SkillAudio.parse_skills(_utf16(sd))
	var header := "//SkillName11\tSkillEffectID\tAniType\tStartEvent\tDMG Event\tDamageType\tScale\tID\tAttach\tTrade\tKill\tCreateCnt\tFade\tActType\tMovTypeSpeed\tParam\tAct Option\tObj Path\tObjName\tStartBone\tStartOffset\tTargetBone\tTargetOffset\tObjName2\tRotate\tScript\tSndBegin\tSndEnd\r\n"
	var text := "#section skilleffectset\r\n" + header
	text += _row("MSKILL_T_PILLAR", "AT_TARGET", "res\\mob\\t\\", "pillar.bsr", "MOV_NONE,250,0,0", "false,0,0,0,0,false", "0,0", "none", "none", "0,0,0", "2")
	text += _row("MSKILL_T_STAR", "AT_MOV_OPTION", "skill\\china\\", "shard.efp", "MOV_STRAIGHT,0,100,100",
		"true,90,50,10,3000,true", "3000,3000", "monster\\star_end.efp", "none", "0,0,0", "1", "MOB_BASE")
	text += _row("MSKILL_T_BOLT", "AT_MOV_1TAR", "skill\\china\\", "bolt.efp", "MOV_STRAIGHT,0,200,200",
		"false,0,0,0,0,false", "0,0", "monster\\bolt_hit.efp")
	text += _row("MSKILL_T_BOLT", "AT_ONE_FOLLOW", "none", "swing.wav", "MOV_NONE,0,0,0", "false,0,0,0,0,false", "0,0", "none")
	rows = SkillEffects.parse_rows(_utf16(text))

	# The parse.
	var pillar: Array = rows.get("MSKILL_T_PILLAR", [])
	_check(pillar.size() == 1 and int(pillar[0]["kind"]) == SkillEffects.KIND_BSR
		and String(pillar[0]["path"]) == "res\\mob\\t\\pillar.bsr",
		"a .bsr row is kept, its kind 1 (the name map's bsr)")
	_check(pillar.size() == 1 and int(pillar[0]["cnt"]) == 2 and int(pillar[0]["mov_a"]) == 250,
		"CreateCnt and MovTypeSpeed's delay (a) read, MOV_NONE too")
	var star: Array = rows.get("MSKILL_T_STAR", [])
	var opt: Dictionary = star[0]["opt"] if star.size() == 1 else {}
	_check(star.size() == 1 and is_equal_approx(float(opt.get("angle", -1.0)), PI / 2.0)
		and float(opt.get("dist", 0.0)) == 50.0 and float(opt.get("spacing", 0.0)) == 10.0,
		"Act Option: the angle in radians (90 deg), the distance, the spacing")
	_check(star.size() == 1 and star[0]["fade"] == [3000, 3000] and String(star[0]["obj2"]) == "monster\\star_end.efp"
		and int(star[0]["scale"]) == 2, "Fade, ObjName2 and the Scale kind (MOB_BASE 2)")
	_check((rows.get("MSKILL_T_BOLT", []) as Array).size() == 1, "a .wav row is still not an effect row")
	_check(SkillEffects.parse_option("false,0,0,0,0,false").is_empty() and SkillEffects.parse_option("junk").is_empty(),
		"an option whose flag is false is no option")
	_check(SkillEffects.is_option_mover(star[0]) and not SkillEffects.is_option_mover(rows["MSKILL_T_BOLT"][0]),
		"AT_MOV_OPTION with its flag is an option mover; a plain AT_MOV_1TAR is not")

	_headings()

	SkillAudio.set_tables(skills, {})
	SkillEffects.reset()
	SkillEffects.set_rows(rows, {})
	SkillEffects.effect_factory = _effect
	BsrEffect.reset()
	BsrEffect.assembler = _model

	# The radial mover: from the caster's StartBone, 50 along heading + 90 deg,
	# a copy every 10 units, ObjName2 at its end, then held for the fade.
	var caster := _body(0.0)
	get_root().add_child(caster)
	var target := _body(0.0)
	target.position = Vector3(0, 0, 300)
	get_root().add_child(target)
	SkillEffects.play_phase(269, SkillAudio.SHOT, 1, caster, target, "test")
	_check(SkillEffects.flight_count() == 1, "the option row moves, though no target is needed")
	var want := SkillEffects.option_goal(Vector3.ZERO, SkillEffects.heading_of(caster), opt)
	_check(absf(want.length() - 50.0) < 1e-3, "its goal is 50 away (%s)" % str(want))
	# 60 frames a second: 1.67 units a frame, a copy each time past 10.
	for i in 40:
		SkillEffects.tick(1.0 / 60.0)
	_check(SkillEffects.flight_count() == 0, "it arrives (50 units at 100 u/s)")
	var copies := _made_named("skill\\china\\shard.efp")
	# (the sixth when float rounding puts the sixth step just past 10)
	_check(copies.size() == 5 or copies.size() == 6,
		"a copy every 10 units: %d effects of the row (the head and 4-5 left on the way)" % copies.size())
	_check(_made_named("monster\\star_end.efp").size() == 1, "ObjName2 is made where it arrived")
	_check(SkillEffects.linger_count() == 1 and _all_kept(copies), "Fade 3000,3000: head and trail held after the arrival")
	for i in 70:
		SkillEffects.tick(0.05)
	_check(not _all_kept(copies), "... and let go when the fade's 3000 ms are over")
	# the direction: 90 degrees round from the caster's front (its model's -Z)
	var sideways := want.normalized()
	var front := -(caster.get_child(0) as Node3D).global_transform.basis.z
	_check(absf(sideways.dot(front)) < 1e-3, "the 90 degree spoke runs square to the caster's front")

	# ObjName2 on a projectile's arrival, Fade 0,0: the head is let go.
	_made.clear()
	SkillEffects.play_phase(270, SkillAudio.SHOT, 1, caster, target, "test")
	for i in 40:
		SkillEffects.tick(0.05)
	_check(SkillEffects.flight_count() == 0 and _made_named("monster\\bolt_hit.efp").size() == 1,
		"a projectile's ObjName2 is made at the target")

	# The .bsr object: at the target's TargetBone, CreateCnt of them, after
	# MovTypeSpeed a, gone when its one-shot type 2 ends (600 ms).
	BsrEffect.preload_path("res\\mob\\t\\pillar.bsr")
	SkillEffects.play_phase(268, SkillAudio.SHOT, 1, caster, target, "test")
	for i in 3:
		SkillEffects.tick(0.0)
		await process_frame
	_check(BsrEffect.live_count() == 2, "CreateCnt 2: two objects (%d live, %d queued)" % [BsrEffect.live_count(), BsrEffect.queued_count()])
	var objs: Array = []
	for n in get_root().find_children("*", "Node3D", true, false):
		if n is BsrEffect:
			objs.append(n)
	_check(objs.size() == 2 and not (objs[0] as Node3D).visible, "hidden while MovTypeSpeed a (250 ms) runs")
	_check(objs.size() == 2 and (objs[0] as Node3D).global_position.distance_to(target.global_position) < 1e-3,
		"at the target's TargetBone point")
	SkillEffects.tick(0.3)
	_check(objs.size() == 2 and (objs[0] as Node3D).visible, "shown once the delay is over")
	SkillEffects.tick(0.4)
	_check(BsrEffect.live_count() == 2, "still playing its 600 ms clip")
	SkillEffects.tick(0.25)
	_check(BsrEffect.live_count() == 0, "gone when its one-shot ends")

	SkillEffects.reset()
	BsrEffect.reset()
	BsrEffect.assembler = Callable()
	caster.queue_free()
	target.queue_free()
	await process_frame
	print("bsr_effect_test: %s (%d failure(s))" % ["PASS" if _failures == 0 else "FAIL", _failures])
	quit(0 if _failures == 0 else 1)

func _all_kept(fxs: Array) -> bool:
	for fx in fxs:
		if not is_instance_valid(fx) or (fx as Node).is_queued_for_deletion() or not (fx as EfpEffect).loop:
			return false
	return not fxs.is_empty()

## A monster-like body: a node turned to heading `h` (rotation.y = h - PI,
## RemoteFacing.yaw_of with the -Z front), its skeleton unturned under it.
func _body(h: float) -> Node3D:
	var n := Node3D.new()
	n.rotation.y = RemoteFacing.yaw_of(h, PI)
	var sk := Skeleton3D.new()
	sk.add_bone("Bip01")
	sk.set_bone_rest(0, Transform3D.IDENTITY)
	sk.reset_bone_poses()
	n.add_child(sk)
	return n

## The heading convention the movers use: a monster's (front -Z, its node
## turned) and a player's (its skeleton turned PI under the root) give the
## client's heading, and heading h faces RemoteFacing.facing_of(h).
func _headings() -> void:
	for h in [0.3, 2.0, 4.5]:
		var mob := _body(h)
		get_root().add_child(mob)
		var pc := Node3D.new()
		pc.rotation.y = h
		var psk := Skeleton3D.new()
		psk.rotation.y = PI
		pc.add_child(psk)
		get_root().add_child(pc)
		var front := -(mob.get_child(0) as Node3D).global_transform.basis.z
		var f := RemoteFacing.facing_of(SkillEffects.heading_of(mob))
		_check(is_equal_approx(SkillEffects.heading_of(mob), h) and absf(SkillEffects.heading_of(pc) - h) < 1e-4
			and Vector2(front.x, front.z).distance_to(f) < 1e-4,
			"heading %.1f: a monster's and a player's body read it back, facing their model's front" % h)
		var g := SkillEffects.option_goal(Vector3.ZERO, h, {"angle": 0.0, "dist": 10.0})
		_check(g.distance_to(front * 10.0) < 1e-3, "... an option at angle 0 goes straight ahead")
		mob.free()
		pc.free()
