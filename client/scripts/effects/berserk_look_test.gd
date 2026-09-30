extends SceneTree

## BerserkLook (round 651): the SYSTEM_CH_HWANMODE rows and their scripts, the
## body colour's pulse, the size, the burst, the kept effects, the sounds, the
## own flash, the end -- on this player's body and on another player's -- and
## the body-mode book NetClient keeps for bodies drawn later. Synthetic tables
## and synthetic bodies built here, never game data. Run headless:
## `godot4 --headless --path client --script res://scripts/effects/berserk_look_test.gd`
##
## Loaded by path, so a checkout without the script prints FAIL lines.

var _failures := 0
var bl: GDScript
var made: Array = []
var heard: Array = []

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

## A skilleffectset row in the file's own column order (28 columns).
func _row(id: String, ani: String, act: String, dir: String, obj: String, bone: String,
		script: String, snd_begin: String) -> String:
	var cols: Array = ["label", id, ani, "0", "FALSE", "none", "CHAR_BASE", "0", "0", "0", "0", "1",
		"0,0", act, "MOV_NONE,0,0,0", "0,0,0", "false,0,0,0,0,false", dir, obj, bone, "0,0,0",
		"none", "0,0,0", "none", "0", script, snd_begin, "none"]
	return "\t".join(PackedStringArray(cols)) + "\r\n"

func _table() -> PackedByteArray:
	var t := "#section\tskilleffectset\r\n"
	t += "//SkillName11\tSkillEffectID\tAniType\tStartEvent\tDMG Event\tDamageType\tScale\tID\tAttach\tTrade\tKill\tCreateCnt\tFade\tActType\tMovTypeSpeed\tParam\tAct Option\tObj Path\tObjName\tStartBone\tStartOffset\tTargetBone\tTargetOffset\tObjName2\tRotate\tScript\tSndBegin\tSndEnd\r\n"
	t += _row("SYSTEM_CH_HWANMODE", "ACT_S", "AT_ONE_FOLLOW", "fx\\", "burst.efp", "Bip01", "none", "p\\on.wav")
	t += _row("SYSTEM_CH_HWANMODE", "ACT_L", "AT_LOOP", "fx\\", "keep.efp", "Bip01 Spine", "SCT_MAT,10,20,30,110,120,130,1000", "none")
	t += _row("SYSTEM_CH_HWANMODE", "ACT_L", "AT_LOOP", "fx\\", "keep_s.efp", "Bip01 L UpperArm", "SCT_CHAR_SCALE,1.1,1000", "none")
	t += _row("SYSTEM_CH_HWANMODE", "DEACT", "AT_ONE_FOLLOW", "fx\\", "gone.efp", "none", "none", "p\\off.wav")
	t += _row("SYSTEM_CH_HWAN2MODE", "ACT_L", "AT_LOOP", "fx\\", "other.efp", "Bip01", "SCT_MAT,1,2,3,4,5,6,700", "none")
	t += "#section\tskillaniset2\r\n"
	t += _row("SYSTEM_CH_HWANMODE", "ACT_L", "AT_LOOP", "fx\\", "wrong_section.efp", "Bip01", "none", "none")
	return _utf16(t)

## A body: a Node3D holding a Skeleton3D holding two meshes -- one plain
## (StandardMaterial3D), one with a ShaderMaterial carrying an `albedo`.
func _body(name: String) -> Node3D:
	var body := Node3D.new()
	body.name = name
	var skel := Skeleton3D.new()
	skel.scale = Vector3(2, 2, 2)
	body.add_child(skel)
	var mi := MeshInstance3D.new()
	mi.name = "suit"
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.59, 0.59, 0.59, 1.0)
	mi.material_override = m
	skel.add_child(mi)
	var mi2 := MeshInstance3D.new()
	mi2.name = "hair"
	var sm := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = "shader_type spatial;\nuniform vec4 albedo : source_color = vec4(1.0);\nvoid fragment() { ALBEDO = albedo.rgb; }\n"
	sm.shader = sh
	sm.set_shader_parameter("albedo", Color(0.59, 0.59, 0.59, 0.5))
	mi2.material_override = sm
	skel.add_child(mi2)
	root.add_child(body)
	return body

func _mesh(body: Node3D, name: String) -> MeshInstance3D:
	return body.find_child(name, true, false) as MeshInstance3D

func _albedo(mi: MeshInstance3D) -> Color:
	var m := mi.material_override
	if m is StandardMaterial3D:
		return (m as StandardMaterial3D).albedo_color
	return (m as ShaderMaterial).get_shader_parameter("albedo")

func _near(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) < 0.002 and absf(a.g - b.g) < 0.002 and absf(a.b - b.b) < 0.002

func _initialize() -> void:
	bl = load("res://scripts/effects/berserk_look.gd")
	if bl == null:
		_check(false, "berserk_look.gd loads")
		quit(1)
		return
	_parse_checks()
	_pulse_checks()
	_body_checks()
	_book_checks()
	print("ALL PASS" if _failures == 0 else "%d FAILED" % _failures)
	quit(0 if _failures == 0 else 1)

func _parse_checks() -> void:
	var rows: Array = bl.parse_rows(_table())
	_check(rows.size() == 4, "four SYSTEM_CH_HWANMODE rows, only from skilleffectset (got %d)" % rows.size())
	if rows.size() != 4:
		return
	_check(int(rows[0]["ani"]) == SkillAudio.ACT_S and rows[0]["path"] == "fx\\burst.efp" and rows[0]["bone"] == "Bip01",
		"the ACT_S burst row: %s" % [rows[0]])
	_check(rows[0]["snd_begin"] == "prim\\snd\\p\\on.wav", "its SndBegin is a prim\\snd path (%s)" % rows[0]["snd_begin"])
	var mat: Dictionary = rows[1]["script"]
	_check(int(mat.get("flag", 0)) == bl.SCT_MAT and mat["c1"] == Color8(10, 20, 30) and mat["c2"] == Color8(110, 120, 130)
		and int(mat["ms"]) == 1000, "SCT_MAT: two colours and the ms (%s)" % [mat])
	var grow: Dictionary = rows[2]["script"]
	_check(int(grow.get("flag", 0)) == bl.SCT_CHAR_SCALE and is_equal_approx(float(grow["scale"]), 1.1)
		and is_equal_approx(float(grow["secs"]), 1.0), "SCT_CHAR_SCALE: 1.1 over 1000 ms x 0.001 (%s)" % [grow])
	_check(int(rows[1]["act"]) == SkillEffects.AT_LOOP and int(rows[3]["ani"]) == SkillAudio.DEACT
		and rows[3]["snd_begin"] == "prim\\snd\\p\\off.wav", "the kept rows loop; the DEACT row sounds the end")
	_check((bl.parse_script("none") as Dictionary).is_empty() and int(bl.parse_script("SCT_RUT,45")["flag"]) == 0,
		"'none' is no script; another SCT_ is kept but not drawn")

func _pulse_checks() -> void:
	var c1 := Color8(64, 16, 0)
	var c2 := Color8(140, 32, 0)
	_check(_near(bl.pulse(0.0, c1, c2, 1000.0), c1), "the pulse starts on colour 1")
	_check(_near(bl.pulse(1000.0, c1, c2, 1000.0), c2), "it reaches colour 2 after the ms")
	_check(_near(bl.pulse(2000.0, c1, c2, 1000.0), c1), "and is back on colour 1 after twice the ms")
	_check(_near(bl.pulse(500.0, c1, c2, 1000.0), c1.lerp(c2, 0.5)) and _near(bl.pulse(1500.0, c1, c2, 1000.0), c1.lerp(c2, 0.5)),
		"halfway up and halfway down are the midpoint")
	_check(is_zero_approx(bl.flash_alpha(0.0)) and is_equal_approx(bl.flash_alpha(0.2), 128.0 / 255.0)
		and is_equal_approx(bl.flash_alpha(0.45), 64.0 / 255.0) and is_zero_approx(bl.flash_alpha(0.7))
		and is_zero_approx(bl.flash_alpha(-0.1)), "the flash: up to 128/255 in 0.2 s, down in 0.5 s")

func _body_checks() -> void:
	bl.set_rows(bl.parse_rows(_table()))
	bl.effect_factory = func(path: String):
		made.append(path)
		return null
	bl.sound_player = func(path: String, _pos) -> void:
		heard.append(path)
	var own := _body("own")
	var other := _body("other")
	var suit := _mesh(own, "suit")
	var hair := _mesh(own, "hair")
	var plain_suit := suit.material_override
	var skel := own.get_child(0) as Skeleton3D

	# This player's own activation: the burst, the kept rows, the sound.
	bl.start(own, false, true)
	_check(made == ["fx\\burst.efp", "fx\\keep.efp", "fx\\keep_s.efp"], "the burst and both kept effects start (%s)" % [made])
	_check(heard == ["prim\\snd\\p\\on.wav"], "the start sound plays (%s)" % [heard])
	_check(bl.active(own) and not bl.active(other), "only the berserk body wears the look")
	_check(suit.material_override != plain_suit and _near(_albedo(suit), Color8(10, 20, 30))
		and _near(_albedo(hair), Color8(10, 20, 30)), "every piece is drawn in colour 1 at once (suit %s, hair %s)" % [_albedo(suit), _albedo(hair)])
	_check(is_equal_approx(((suit.material_override) as StandardMaterial3D).albedo_color.a, 1.0)
		and is_equal_approx(_albedo(hair).a, 0.5), "the material's own alpha is kept")
	_check(_near(_albedo(_mesh(other, "suit")), Color(0.59, 0.59, 0.59)), "another body keeps its colour")
	bl.tick(0.5)
	_check(_near(_albedo(suit), Color8(10, 20, 30).lerp(Color8(110, 120, 130), 0.5)), "half a period on, the midpoint (%s)" % _albedo(suit))
	_check(skel.scale.is_equal_approx(Vector3(2, 2, 2) * 1.05), "and the body has grown half way to x1.1 (%s)" % skel.scale)
	bl.tick(0.5)
	_check(_near(_albedo(suit), Color8(110, 120, 130)) and skel.scale.is_equal_approx(Vector3(2.2, 2.2, 2.2)),
		"after the ms: colour 2, and the full x1.1 (%s, %s)" % [_albedo(suit), skel.scale])
	bl.tick(1.0)
	_check(_near(_albedo(suit), Color8(10, 20, 30)), "and back to colour 1 after twice the ms")

	# Another player, already berserk when drawn: no burst, no sound.
	made.clear()
	heard.clear()
	bl.start(other, true, false)
	_check(made == ["fx\\keep.efp", "fx\\keep_s.efp"] and heard.is_empty(),
		"a body drawn berserk gets the kept rows only (%s, %s)" % [made, heard])
	_check(_near(_albedo(_mesh(other, "suit")), Color8(10, 20, 30)), "and the colour")
	made.clear()
	bl.start(other, false, false)
	_check(made.is_empty(), "a second 'on' keeps the running look")

	# A piece put on mid-berserk takes the colour too.
	var cape := MeshInstance3D.new()
	var cm := StandardMaterial3D.new()
	cm.albedo_color = Color(0.3, 0.3, 0.3)
	cape.material_override = cm
	skel.add_child(cape)
	bl.tick(0.3)
	_check(cape.material_override != cm, "a piece worn later is found and tinted")

	# The end: the colour goes at once, the size over its second, the burst and sound.
	made.clear()
	heard.clear()
	_check(bl.stop(own), "the end is taken")
	_check(suit.material_override == plain_suit and _near(_albedo(suit), Color(0.59, 0.59, 0.59))
		and not suit.has_meta(bl.ORIGINAL_META) and cape.material_override == cm,
		"every piece has its own material back")
	_check(made == ["fx\\gone.efp"] and heard == ["prim\\snd\\p\\off.wav"], "the end's burst and sound (%s, %s)" % [made, heard])
	_check(not bl.active(own) and bl.active(other), "the other body is still berserk")
	var mid := skel.scale.x
	bl.tick(0.5)
	_check(skel.scale.x < mid and skel.scale.x > 2.0, "the size is on its way back (%s)" % skel.scale)
	bl.tick(0.6)
	_check(skel.scale.is_equal_approx(Vector3(2, 2, 2)) and not skel.has_meta(bl.SCALE_META), "and back to its own after a second")
	_check(bl.count() == 1, "the ended look is forgotten (%d held)" % bl.count())
	_check(not bl.stop(own), "a second end does nothing")

	# The other player's berserk ends too.
	bl.stop(other)
	bl.tick(1.1)
	_check(_near(_albedo(_mesh(other, "suit")), Color(0.59, 0.59, 0.59)) and bl.count() == 0, "the other body is itself again")

	# A body freed while berserk is dropped.
	var gone := _body("gone")
	bl.start(gone, true, false)
	gone.free()
	bl.tick(0.1)
	_check(bl.count() == 0, "a freed body's look is dropped")
	own.free()
	other.free()
	# The static seams hold lambdas bound to this script: let go of them
	# before the engine tears the script down.
	bl.effect_factory = Callable()
	bl.sound_player = Callable()
	bl.clear()

func _book_checks() -> void:
	# By name, so a checkout without the helper prints a FAIL line.
	var wn: GDScript = load("res://scripts/net/world.gd")
	if not wn.has_method("note_body_mode"):
		_check(false, "WorldNet.note_body_mode keeps the body-mode book")
		return
	var modes := {}
	var on := WorldNet.StateChange.new()
	on.object_id = 7
	on.kind = WorldNet.STATE_KIND_BODY_MODE
	on.value = 1
	_check(wn.call("note_body_mode", modes, on) and int(modes.get(7, 0)) == 1, "a kind-4 value 1 marks the character berserk")
	var motion := WorldNet.StateChange.new()
	motion.object_id = 7
	motion.kind = WorldNet.STATE_KIND_MOTION
	motion.value = 0
	_check(not wn.call("note_body_mode", modes, motion) and modes.has(7), "a motion change leaves it")
	var off := WorldNet.StateChange.new()
	off.object_id = 7
	off.kind = WorldNet.STATE_KIND_BODY_MODE
	off.value = 0
	_check(wn.call("note_body_mode", modes, off) and not modes.has(7), "a kind-4 value 0 clears it")
