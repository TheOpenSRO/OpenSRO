extends SceneTree

## Firework (round 860): CIParticleObj's rules (c:0x9c5340 / 0x9c5460) --
## the burst count from the first ACT_S row's CreateCnt, a burst every 2000 ms
## from 8 above the model, the rows' delayed sounds (FUN_00a4fe70's queue),
## the end once everything is over -- against synthetic rows and effects built
## here, never game data. Run headless:
## `godot4 --headless --path client --script res://scripts/effects/firework860_test.gd`

var _failures := 0
var _tex: Texture2D = ImageTexture.create_from_image(Image.create(2, 2, false, Image.FORMAT_RGBA8))

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

## A skilleffectset-shaped row in the file's own column order.
func _row(id: String, cnt: String, mov: String, dir: String, obj: String, snd: String) -> String:
	var cols: Array = ["label", id, "ACT_S", "0", "FALSE", "none", "none", "0", "0", "0", "0", cnt,
		"0,0", "AT_STOP", mov, "0,0,0", "false,0,0,0,0,false", dir, obj, "none", "0,0,0",
		"none", "0,0,0", "none", "0", "none", snd, "none"]
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
	var fx := EfpEffect.from_template(EfpSim.compile(n), func(p): return _tex if p == "t.ddj" else null, func(_p): return null, 5)
	fx.path = _path
	return fx

func _initialize() -> void:
	process_frame.connect(_run, CONNECT_ONE_SHOT)

func _run() -> void:
	var header := "//SkillName11\tSkillEffectID\tAniType\tStartEvent\tDMG Event\tDamageType\tScale\tID\tAttach\tTrade\tKill\tCreateCnt\tFade\tActType\tMovTypeSpeed\tParam\tAct Option\tObj Path\tObjName\tStartBone\tStartOffset\tTargetBone\tTargetOffset\tObjName2\tRotate\tScript\tSndBegin\tSndEnd\r\n"
	var text := "#section\tskilleffectset\r\n" + header
	# The archive's shapes (MEASURED): a one-burst bomb, an eight-burst chain.
	text += _row("ITEM_TEST_FIREWORK_BOMB", "1", "MOV_NONE,0,0,0", "system\\", "item_firework_bomb_r.efp", "firework\\firework_shot_01.wav")
	text += _row("ITEM_TEST_FIREWORK_BOMB", "1", "MOV_NONE,1300,0,0", "none", "none", "firework\\firework_explosion_01.wav")
	text += _row("ITEM_TEST_FIREWORK_CHAIN", "8", "MOV_NONE,0,0,0", "system\\", "firework_chainbomb.efp", "firework\\FireWork_Shot_03.wav")
	text += _row("ITEM_TEST_FIREWORK_CHAIN", "1", "MOV_NONE,600,0,0", "none", "none", "firework\\FireWork_Explosion_02.wav")
	SkillEffects.set_rows(SkillEffects.parse_rows(_utf16(text)))
	SkillAudio.set_tables({}, SkillAudio.parse_effect_sounds(_utf16(text)))

	# --- the rules -----------------------------------------------------------
	_check(Firework.burst_count(Firework.rows_of("ITEM_TEST_FIREWORK_BOMB")) == 1, "a bomb: one burst (CreateCnt 1)")
	_check(Firework.burst_count(Firework.rows_of("ITEM_TEST_FIREWORK_CHAIN")) == 8, "the chain bomb: eight (its first ACT_S row's CreateCnt)")
	_check(Firework.burst_count(Firework.rows_of("ITEM_ETC_FIREWORK_SPIN")) == 0, "no rows: no firework (the original's null record)")
	_check(Firework.burst_due(0, 1, 0.0) and not Firework.burst_due(1, 1, 99999.0), "the first burst on the first frame; no more than the count")
	_check(not Firework.burst_due(1, 8, 1999.0) and Firework.burst_due(1, 8, 2000.0), "the next at fired x 2000 ms")
	_check(Firework.INTERVAL_MS == 2000 and Firework.LIFT == 8.0, "2000 ms, 8 up (c:0x9c5444, .rdata 0xd89240)")

	var rows := ItemUseEffect.sound_rows("ITEM_TEST_FIREWORK_BOMB")
	_check(rows.size() == 2 and int(rows[0]["delay_ms"]) == 0 and int(rows[1]["delay_ms"]) == 1300
		and String(rows[1]["path"]) == "prim\\snd\\firework\\firework_explosion_01.wav",
		"the shot at once, the explosion 1300 ms later (MovTypeSpeed's first number, got %s)" % str(rows))
	_check(ItemUseEffect.sounds_of("ITEM_TEST_FIREWORK_BOMB").size() == 2, "sounds_of still lists both")
	_check(Firework.make("ITEM_ETC_FIREWORK_SPIN", null, Vector3.ZERO, 0.0) == null, "make: nothing for a code with no rows")

	# --- a chain bomb's life, stepped by hand -----------------------------------
	SkillEffects.effect_factory = Callable(self, "_effect")
	var model := Node3D.new()
	var fw := Firework.make("ITEM_TEST_FIREWORK_CHAIN", model, Vector3(10, 2, 30), 0.5)
	var sounds: Array = []
	fw.play_sounds_with = func(r: Array, at: Vector3, _label: String, _alive: Callable) -> void:
		sounds.append({"rows": r.size(), "at": at})
	get_root().add_child(fw)
	fw.set_process(false)
	_check(fw.get_node_or_null("Model") == model and fw.position == Vector3(10, 2, 30), "the model stands where the user stood")
	var bursts: Array = []
	fw.burst.connect(func(i: int, n: int) -> void: bursts.append([i, n, fw.age_ms]))
	for _i in 600: # 600 frames of 33 ms: 19.8 s
		fw.step(33.0)
	_check(bursts.size() == 8, "eight bursts (%d)" % bursts.size())
	var spaced := true
	for i in bursts.size():
		var want := float(i * 2000)
		var at: float = bursts[i][2]
		spaced = spaced and at >= want and at < want + 33.0
	_check(spaced, "one every 2000 ms from the first frame (%s)" % str(bursts.map(func(b): return int(b[2]))))
	_check(int(bursts[0][1]) == 1, "each burst starts the row's effect")
	_check(sounds.size() == 8 and (sounds[0]["at"] as Vector3).is_equal_approx(Vector3(10, 10, 30)),
		"each burst's sounds from 8 above the foot (%s)" % str(sounds[0]["at"] if not sounds.is_empty() else null))
	var lift := fw.get_node_or_null("Lift") as Node3D
	var on_lift := 0
	for c in lift.get_children():
		if c is EfpEffect:
			on_lift += 1
	_check(lift != null and lift.position == Vector3(0, 8, 0), "the effects start on the lift point")
	await create_timer(1.0).timeout
	fw.step(33.0)
	fw.step(33.0)
	_check(not is_instance_valid(fw) or fw.is_queued_for_deletion(), "all bursts gone and every effect ended: the firework is deleted")

	# --- the delayed sound waits for its decoration ---------------------------
	var host := Node3D.new()
	get_root().add_child(host)
	var played := ItemUseEffect.play_sounds([{"path": "prim\\snd\\x.wav", "delay_ms": 50}], Vector3.ZERO, self, "t", func() -> bool: return false)
	_check(played.size() == 1, "play_sounds lists a delayed sound")
	await create_timer(0.2).timeout
	SkillEffects.effect_factory = Callable()
	host.queue_free()
	_finish()

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)
