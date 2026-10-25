extends SceneTree

## Round 826: the camera shake (CameraShake) and where skills start it
## (SkillEffects' Script column, the shake hook, the AT_TARGET movers),
## against synthetic tables and effects -- never game data.
## `godot4 --headless --path client --script res://scripts/effects/camera_shake826_test.gd`

var _failures := 0
var _tex: Texture2D = ImageTexture.create_from_image(Image.create(2, 2, false, Image.FORMAT_RGBA8))

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	process_frame.connect(_run, CONNECT_ONE_SHOT)

func _utf16(text: String) -> PackedByteArray:
	var out := PackedByteArray([0xFF, 0xFE])
	out.append_array(text.to_utf16_buffer())
	return out

func _skill_row(id: int, code: String, group: String) -> String:
	return "1\t%d\t%d\t%s\tname\t%s\t0\t1\t0\t0\t0\r\n" % [id, id, code, group]

func _row(id: String, ani: String, ev: int, act: String, obj: String, offset: String, script: String,
		dmg: bool = false, mov: String = "MOV_NONE,0,0,0", toffset: String = "0,0,0") -> String:
	var cols: Array = ["label", id, ani, str(ev), "TRUE" if dmg else "FALSE", "none", "none", "0", "0", "0", "0", "1",
		"0,0", act, mov, "0,0,0", "false,0,0,0,0,false", "skill\\" if obj != "none" else "none", obj, "none", offset,
		"none", toffset, "none", "0", script, "none", "none"]
	return "\t".join(PackedStringArray(cols)) + "\r\n"

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
	ref.textures = PackedStringArray(["t.ddj"])
	n.meshes.append(ref)
	return EfpEffect.from_template(EfpSim.compile(n), func(p): return _tex if p == "t.ddj" else null, func(_p): return null, 5)

func _run() -> void:
	_engine()
	_rows()
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)

func _engine() -> void:
	# The flags' shakes, in the order the client tests them.
	var both := CameraShake.shakes_of(CameraShake.SCT_SHAKECAM0 | CameraShake.SCT_SHAKECAM3, CameraShake.START_FLAGS)
	_check(both == [[50, 20], [400, 25]], "SHAKECAM0 then SHAKECAM3: 50 / 20 ms, 400 / 25 ms")
	_check(CameraShake.shakes_of(CameraShake.SCT_SHAKECAM_MOV1, CameraShake.START_FLAGS).is_empty()
		and CameraShake.shakes_of(CameraShake.SCT_SHAKECAM_MOV1, CameraShake.MOV_FLAGS) == [[200, 25]],
		"a MOV flag shakes at the arrival, not at the play")
	# The own blow's.
	_check(CameraShake.hit_shake(false, false).is_empty() and CameraShake.hit_shake(true, false) == [50, 20]
		and CameraShake.hit_shake(false, true) == [50, 20] and CameraShake.hit_shake(true, true) == [200, 25],
		"own blows: a critical 50, berserk 50, a critical in berserk 200, else none")
	# The x87's round to nearest-even.
	_check(CameraShake._round_even(2.5) == 2 and CameraShake._round_even(3.5) == 4 and CameraShake._round_even(2.6) == 3
		and CameraShake._round_even(2.4) == 2, "round half to even")

	# The run: strength 50, 500 ms, a tick of 20 ms, frames 20 ms apart.
	var c := CameraShake.new()
	var draws: Array = [0, 99, 50, 25]
	var k := [0]
	c.rand = func() -> int:
		var v: int = draws[k[0] % draws.size()]
		k[0] += 1
		return v
	c.start(CameraShake.MODE_BOTH, 50, 500, 20, 1000)
	_check(c.active and c.offset() == Vector3.ZERO, "started: running, no offset before the first tick")
	c.step(1010)
	_check(c.offset() == Vector3.ZERO, "10 ms in: the tick is not due")
	c.step(1020)
	# The strength 50 - round(50 x 20 / 500) = 48; draws 0 and 99 -> (0 - 48) / 100, (99 % 96 - 48) / 100.
	_check(c.strength == 48 and is_equal_approx(c.side, -0.48) and is_equal_approx(c.height, -0.45),
		"the first tick: strength 48, side -0.48, height -0.45 (got %d, %.2f, %.2f)" % [c.strength, c.side, c.height])
	_check(c.offset().is_equal_approx(Vector3(-0.48, -0.45, 0.0)), "the offset: the side on x, the height on y")
	# A late frame: the fall is by the time since the tick last fired (70 ms -> 7).
	c.step(1090)
	_check(c.strength == 41, "a 70 ms gap takes round(50 x 70 / 500) = 7 (got %d)" % c.strength)
	c.step(1499)
	_check(c.active, "still running at 499 ms")
	c.step(1500)
	_check(not c.active and c.offset() == Vector3.ZERO, "500 ms: over, the offsets back to zero")
	# A strength that reaches 0 becomes 1.
	var z := CameraShake.new()
	z.rand = func() -> int: return 0
	z.start(CameraShake.MODE_BOTH, 50, 500, 20, 0)
	z.step(499)
	_check(z.strength == 1, "a fall to 0 leaves 1 (got %d)" % z.strength)
	# Modes 1 and 2 draw one offset each.
	var h := CameraShake.new()
	h.rand = func() -> int: return 0
	h.start(CameraShake.MODE_HEIGHT, 50, 500, 20, 0)
	h.step(20)
	_check(h.side == 0.0 and h.height < 0.0, "mode 1 moves the height only")
	# A new shake replaces the running one.
	c.start(CameraShake.MODE_BOTH, 200, 500, 25, 2000)
	c.start(CameraShake.MODE_BOTH, 50, 500, 20, 2010)
	_check(c.strength0 == 50 and c.tick_ms == 20, "a second start replaces the first")

func _rows() -> void:
	var skills := SkillAudio.parse_skills(_utf16(_skill_row(7, "TEST_BASH_A_01", "TEST_BASH_A")
		+ _skill_row(8, "TEST_ICE_A_01", "TEST_ICE_A") + _skill_row(9, "TEST_SPIN_A_01", "TEST_SPIN_A")))
	var header := "//SkillName11\tSkillEffectID\tAniType\tStartEvent\tDMG Event\tDamageType\tScale\tID\tAttach\tTrade\tKill\tCreateCnt\tFade\tActType\tMovTypeSpeed\tParam\tAct Option\tObj Path\tObjName\tStartBone\tStartOffset\tTargetBone\tTargetOffset\tObjName2\tRotate\tScript\tSndBegin\tSndEnd\r\n"
	var text := "#section skilleffectset\r\n" + header
	text += _row("TEST_BASH_A", "SHOT", 1, "AT_ONE_FOLLOW", "bash.efp", "0,0,0", "SCT_SHAKECAM1")
	text += _row("TEST_BASH_A", "SHOT", 2, "AT_ONE_FOLLOW", "none", "0,0,0", "SCT_SHAKECAM3")
	text += _row("TEST_BASH_A", "SHOT", 3, "AT_ONE_FOLLOW", "none", "0,0,0", "none")
	text += _row("TEST_ICE_A", "SHOT", 1, "AT_TARGET", "ice.efp", "26,100,-14", "SCT_SHAKECAM_MOV0", true,
		"MOV_STRAIGHT,0,200,200", "26,0,-14")
	text += _row("TEST_SPIN_A", "SHOT", 1, "AT_LOOP", "spin.efp", "0,0,0", "SCT_SHAKECAM0")
	text += _row("TEST_SPIN_A", "SHOT", 1, "AT_TARGET", "spark.efp", "0,0,0", "SCT_SHAKECAM2")
	var rows := SkillEffects.parse_rows(_utf16(text))
	_check(SkillEffects.script_flag("SCT_SHAKECAM_MOV2") == 0x200 and SkillEffects.script_flag("SCT_MAT,1,2,3,4,5,6,7") == 0x800
		and SkillEffects.script_flag("none") == 0, "the Script cell's SCT_ name to its flag (0x00ec7378's table)")
	_check((rows["TEST_BASH_A"] as Array).size() == 2, "a row of no effect is kept only for its shake (2 of 3)")
	_check(SkillEffects.rows_in(skills, rows, 7, SkillAudio.SHOT, 2).is_empty()
		and SkillEffects.rows_in(skills, rows, 7, SkillAudio.SHOT, 2, true).size() == 1,
		"rows_in leaves the shake-only row out unless asked")
	var ice: Dictionary = (rows["TEST_ICE_A"] as Array)[0]
	_check(int(ice["mov_b"]) == 200 and SkillEffects.is_target_mover(ice), "an AT_TARGET row with a speed is a mover")
	_check(SkillEffects.world_offset(Vector3(26, 100, -14)) == Vector3(26, 100, 14), "a row offset on the world's axes: z mirrored")

	SkillAudio.set_tables(skills, {})
	SkillEffects.reset()
	SkillEffects.set_rows(rows, {})
	SkillEffects.effect_factory = _effect
	var shakes: Array = []
	SkillEffects.shake_hook = func(flags: int, who: Node3D, arrival: bool) -> void: shakes.append([flags, who, arrival])
	var caster := Node3D.new()
	var target := Node3D.new()
	get_root().add_child(caster)
	get_root().add_child(target)
	target.position = Vector3(10, 0, 20)
	SkillEffects.play_phase(7, SkillAudio.SHOT, 1, caster, target, "test")
	_check(shakes.size() == 1 and shakes[0][0] == 0x10 and shakes[0][1] == caster and not shakes[0][2],
		"the row plays: its SHAKECAM1, with the caster")
	SkillEffects.play_phase(7, SkillAudio.SHOT, 2, caster, target, "test")
	_check(shakes.size() == 2 and shakes[1][0] == 0x100, "a row of no effect shakes too")
	SkillEffects.play_phase(7, SkillAudio.SHOT, 1, null, target, "test")
	_check(shakes.size() == 2, "no caster in view: no shake")

	# The Effect Quality refusal: AT_LOOP skips the test, AT_TARGET does not.
	shakes.clear()
	SkillEffects.quality = SkillEffects.EFFECTS_NONE
	SkillEffects.play_phase(9, SkillAudio.SHOT, 1, caster, target, "test")
	_check(shakes.size() == 1 and shakes[0][0] == 0x80, "effects off: the AT_TARGET row still shakes, the AT_LOOP one does not")
	SkillEffects.quality = SkillEffects.EFFECTS_ALL

	# The falling mover: from the target + StartOffset to the target + TargetOffset, the hit and
	# the MOV shake at its arrival.
	shakes.clear()
	var landed := [0]
	SkillEffects.play_phase(8, SkillAudio.SHOT, 1, caster, target, "test", func() -> void: landed[0] += 1)
	_check(SkillEffects.flight_count() == 1 and shakes.is_empty() and landed[0] == 0, "the ice falls: one flight, no shake yet")
	SkillEffects.step_flights(0.0)
	var carrier: Node3D = null
	for n in caster.get_parent().get_children():
		if n.name.begins_with("SkillFlight"):
			carrier = n
	_check(carrier != null and carrier.global_position.is_equal_approx(Vector3(36, 100, 34)),
		"it starts at the target + StartOffset (%s)" % (str(carrier.global_position) if carrier != null else "none"))
	_check(SkillEffects.group_dmg_flies(8, SkillAudio.SHOT, 1), "its group's hit lands on arrival")
	SkillEffects.step_flights(0.3)
	_check(landed[0] == 0 and SkillEffects.flight_count() == 1, "100 units at 200 a second: still falling at 0.3 s")
	SkillEffects.step_flights(0.3)
	_check(landed[0] == 1 and SkillEffects.flight_count() == 0, "landed by 0.6 s, the hit with it")
	_check(shakes.size() == 1 and shakes[0][0] == 0x20 and shakes[0][2] and shakes[0][1] == caster,
		"the arrival shakes SHAKECAM_MOV0")
	SkillEffects.shake_hook = Callable()
	SkillEffects.reset()
	caster.free()
	target.free()
