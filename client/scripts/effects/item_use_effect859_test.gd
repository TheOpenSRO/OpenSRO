extends SceneTree

## ItemUseEffect (round 859): which effect 0x305C's handler (c:0x8735d0)
## starts for each kind of item, the itemeffect.txt use rows, the 0x305C
## payload, and how the effect plays (its ACT_S and ACT_L rows let go at once,
## the rows' sounds), against synthetic tables and effects built here -- never
## game data. Run headless:
## `godot4 --headless --path client --script res://scripts/effects/item_use_effect859_test.gd`

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
func _row(id: String, ani: String, act: String, dir: String, obj: String, bone: String, snd: String = "none") -> String:
	var cols: Array = ["label", id, ani, "0", "FALSE", "none", "none", "0", "0", "0", "0", "1",
		"0,0", act, "MOV_NONE,0,0,0", "0,0,0", "false,0,0,0,0,false", dir, obj, bone, "0,0,0",
		"none", "0,0,0", "none", "0", "none", snd, "none"]
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
	ref.textures = PackedStringArray(["t.ddj"])
	n.meshes.append(ref)
	var fx := EfpEffect.from_template(EfpSim.compile(n), func(p): return _tex if p == "t.ddj" else null, func(_p): return null, 5)
	fx.path = _path
	return fx

func _initialize() -> void:
	process_frame.connect(_run, CONNECT_ONE_SHOT)

func _t(a: int, b: int, c: int, d: int) -> PackedInt32Array:
	return PackedInt32Array([a, b, c, d])

func _run() -> void:
	# --- the itemeffect.txt use rows ------------------------------------------
	var ie := "//comment\r\n#section\titemcodename\t\t\r\n//SkillEffect Codename\tSkillEffect Codename\tstate\t\r\n"
	ie += "ITEM_TEST_AVATAR\tITEMSKILL_TEST_AWAKE\t2\t\r\n"
	ie += "ITEM_TEST_AVATAR\tITEMSKILL_TEST_EQUIP\t0\t\r\n"
	ie += "ITEM_TEST_AVATAR\tITEMSKILL_TEST_TIMEOUT\t3\t\r\n"
	ie += "ITEM_TEST_EXTENSION\tITEMSKILL_TEST_EXT_USE\t2\t\r\n"
	ie += "#section\titemtypeid\t\t\t\t\t\r\n//  TID 1\tTID 2\tTID 3\tTID 4\tSkillEffect Codename\tstate\r\n"
	ie += "ITEM_WRONG_SECTION\tITEMSKILL_X\t2\t\r\n"
	var use := ItemUseEffect.parse_use_rows(_utf16(ie))
	_check(use.size() == 2 and use.get("ITEM_TEST_AVATAR") == "ITEMSKILL_TEST_AWAKE"
		and use.get("ITEM_TEST_EXTENSION") == "ITEMSKILL_TEST_EXT_USE",
		"itemeffect.txt: the itemcodename rows of state 2 only (got %s)" % str(use))
	_check(ItemUseEffect.parse_use_rows(_utf16(ie), 0).get("ITEM_TEST_AVATAR") == "ITEMSKILL_TEST_EQUIP",
		"... and another state on request")

	# --- which effect (c:0x8735d0's steps) ------------------------------------
	var known := {"SYSTEM_HPPOTION": true, "SYSTEM_MPPOTION": true, "SYSTEM_LIFE": true,
		"SYSTEM_RETURNSCROLL": true, "SYSTEM_COS_HPPOTION": true, "SYSTEM_COS_HGPPOTION": true,
		"PARAM_CURE_ALL": true, "STATUS_CURE_COS": true, "ITEMSKILL_TEST_AWAKE": true,
		"ITEM_TEST_HWAN_POTION": true, "ITEM_TEST_SCROLL_CODE": true}
	var knows := func(id: String) -> bool: return known.has(id)
	var cases := [
		[_t(3, 3, 1, 1), "ITEM_ETC_HP_POTION_01", "SYSTEM_HPPOTION", "an HP potion"],
		[_t(3, 3, 1, 2), "ITEM_ETC_MP_POTION_01", "SYSTEM_MPPOTION", "an MP potion"],
		[_t(3, 3, 1, 3), "ITEM_ETC_ALL_POTION_01", "SYSTEM_LIFE", "a vigor potion"],
		[_t(3, 3, 1, 4), "ITEM_ETC_COS_HP_POTION_01", "SYSTEM_COS_HPPOTION", "a pet HP potion"],
		[_t(3, 3, 1, 5), "ITEM_TEST_COS_MP", "", "a COS MP potion: SYSTEM_COS_MPPOTION has no rows, nor its code"],
		[_t(3, 3, 1, 9), "ITEM_COS_P_HGP_POTION_01", "SYSTEM_COS_HGPPOTION", "the HGP potion"],
		[_t(3, 3, 2, 1), "ITEM_ETC_CURE_RANDOM_01", "PARAM_CURE_ALL", "a purification pill"],
		[_t(3, 3, 2, 6), "ITEM_ETC_CURE_ALL_01", "PARAM_CURE_ALL", "a universal pill"],
		[_t(3, 3, 2, 7), "ITEM_COS_P_CURE_ALL_01", "STATUS_CURE_COS", "the pet's pill"],
		[_t(3, 3, 2, 8), "ITEM_MALL_CURE_SUPERSET_1_BAG", "", "a pill bag: no type row, no code row"],
		[_t(3, 3, 3, 1), "ITEM_ETC_SCROLL_RETURN_01", "SYSTEM_RETURNSCROLL", "a return scroll"],
		[_t(3, 3, 3, 2), "ITEM_COS_C_HORSE1", "SYSTEM_RETURNSCROLL", "any 3/3/3, a horse's scroll too"],
		[_t(3, 3, 3, 1), "ITEM_TEST_SCROLL_CODE", "SYSTEM_RETURNSCROLL", "a scroll's type row first, never its code row"],
		[_t(3, 3, 1, 8), "ITEM_TEST_HWAN_POTION", "ITEM_TEST_HWAN_POTION", "a berserk potion by its own code name"],
		[_t(3, 3, 1, 8), "ITEM_EVENT_HWAN_POTION", "", "a berserk potion with no row of its code"],
		[_t(3, 3, 13, 1), "ITEM_ETC_SPEED_UP_BASIC", "", "a speed scroll (its buff draws its aura)"],
		[_t(3, 3, 6, 1), "ITEM_ETC_FIREWORK_STAR_SHOWER", ItemUseEffect.FIREWORK, "a firework: the firework object"],
		[_t(3, 1, 14, 1), "ITEM_TEST_AVATAR", "ITEMSKILL_TEST_AWAKE", "a devil's spirit by its itemeffect use row"],
		[_t(3, 3, 1, 1), "ITEM_TEST_EXTENSION", "", "an itemeffect row wins even when its effect has no rows"],
	]
	for c in cases:
		var got := ItemUseEffect.effect_id(c[0], c[1], 100, 3664, use, knows)
		_check(got == c[2], "%s -> %s (got %s)" % [c[3], c[2] if c[2] != "" else "none", got if got != "" else "none"])
	_check(ItemUseEffect.effect_id(_t(3, 3, 3, 1), "ITEM_ETC_AUTOMOB", 3664, 3664, use, knows) == "",
		"ITEM_ETC_AUTOMOB's ref starts nothing (DAT_00eeeb7c)")
	_check(ItemUseEffect.effect_id(_t(3, 3, 1, 1), "ITEM_ETC_HP_POTION_01", 3664, -1, use, knows) == "SYSTEM_HPPOTION",
		"an unknown automob ref skips nothing")

	# --- the 0x305C payload ------------------------------------------------
	var payload := PackedByteArray([0x04, 0x03, 0x02, 0x81, 55, 0, 0, 0])
	var ue := UseItemNet.decode_use_effect(payload)
	_check(int(ue.get("uid", -1)) == 0x81020304 and int(ue.get("ref", -1)) == 55, "0x305C: u32 uid, u32 RefItemID (got %s)" % str(ue))
	_check(UseItemNet.decode_use_effect(payload.slice(0, 7)).is_empty(), "a short 0x305C decodes to nothing")
	_check(UseItemNet.OP_USE_EFFECT == 0x305C, "the opcode is retail's 0x305C")

	# --- how it plays ------------------------------------------------------
	var header := "//SkillName11\tSkillEffectID\tAniType\tStartEvent\tDMG Event\tDamageType\tScale\tID\tAttach\tTrade\tKill\tCreateCnt\tFade\tActType\tMovTypeSpeed\tParam\tAct Option\tObj Path\tObjName\tStartBone\tStartOffset\tTargetBone\tTargetOffset\tObjName2\tRotate\tScript\tSndBegin\tSndEnd\r\n"
	var text := "#section\tskilleffectset\r\n" + header
	text += _row("SYSTEM_HPPOTION", "ACT_S", "AT_ONE_FOLLOW", "system\\", "item_hpotion.efp", "none")
	text += _row("SYSTEM_RETURNSCROLL", "ACT_S", "AT_LOOP", "system\\", "item_returnscroll.efp", "none")
	text += _row("PARAM_CURE_ALL", "ACT_S", "AT_ONE_FOLLOW", "skill\\china\\", "water_cure_effect_a.efp", "Bip01")
	text += _row("ITEM_TEST_HWAN_POTION", "ACT_S", "AT_ONE_FOLLOW", "system\\", "item_qt_hwan.efp", "none", "UI\\HyanGet.wav")
	SkillEffects.set_rows(SkillEffects.parse_rows(_utf16(text)))
	SkillAudio.set_tables({}, SkillAudio.parse_effect_sounds(_utf16(text)))
	SkillEffects.effect_factory = Callable(self, "_effect")
	_check(ItemUseEffect.knows("SYSTEM_HPPOTION") and ItemUseEffect.knows("ITEM_TEST_HWAN_POTION")
		and not ItemUseEffect.knows("SYSTEM_COS_MPPOTION"), "knows: an id with rows, not one without")
	var body := Node3D.new()
	get_root().add_child(body)
	var hp := ItemUseEffect.play("SYSTEM_HPPOTION", body)
	var fx: Array = hp["fx"]
	_check(fx.size() == 1 and (fx[0] as EfpEffect).path == "system\\item_hpotion.efp" and (fx[0] as Node).get_parent() == body,
		"an HP potion: item_hpotion.efp on the user's body")
	_check((hp["sounds"] as PackedStringArray).is_empty(), "... with no sound of its row (snd_potion is the reply's)")
	var sc := ItemUseEffect.play("SYSTEM_RETURNSCROLL", body)
	var scroll: EfpEffect = (sc["fx"] as Array)[0]
	_check(not scroll.loop, "a return scroll's AT_LOOP effect is let go at once (the decoration ends, FUN_00a53120)")
	var cure := ItemUseEffect.play("PARAM_CURE_ALL", body)
	_check((cure["fx"] as Array).size() == 1 and ((cure["fx"] as Array)[0] as EfpEffect)._follow_bone_name == "Bip01",
		"a pill: water_cure_effect_a.efp at Bip01")
	var hw := ItemUseEffect.play("ITEM_TEST_HWAN_POTION", body)
	_check(hw["sounds"] == PackedStringArray(["prim\\snd\\ui\\hyanget.wav"]), "a hwan potion's row sound plays (got %s)" % str(hw["sounds"]))
	_check((ItemUseEffect.play("", body)["fx"] as Array).is_empty()
		and (ItemUseEffect.play(ItemUseEffect.FIREWORK, body)["fx"] as Array).is_empty()
		and (ItemUseEffect.play("SYSTEM_HPPOTION", null)["fx"] as Array).is_empty(), "nothing for no effect, a firework or no body")
	# The released effects end by themselves (a 3-frame particle, 50 ms frames).
	await create_timer(1.0).timeout
	_check(not is_instance_valid(scroll) or scroll.is_queued_for_deletion(), "the let-go scroll effect ends by itself")
	SkillEffects.effect_factory = Callable()
	body.queue_free()
	_finish()

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)
