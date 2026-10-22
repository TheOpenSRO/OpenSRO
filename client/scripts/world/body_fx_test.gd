extends SceneTree

## Round 809: a monster body's material slot and its own particles (READ
## addresses in NpcTableReader.texture_slot, BsrReader.material_words and
## BodyFx's header) -- the TextureType table and the champion step, the
## material list read by its leading word, the template key, the ambient
## set's rows, a clip's keys fired once per pass and stopped by a restart.
## Synthetic data only, never game data. `client/tools/remote_godot.sh tests`.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	_test_slots()
	_test_material_words()
	_test_keys()
	_test_ambient()
	_test_clip_fx()
	print("body_fx_test: %s (%d failure(s))" % ["PASS" if _failures == 0 else "FAIL", _failures])
	quit(0 if _failures == 0 else 1)

func _test_slots() -> void:
	var want := {0: 0, 1: 1, 2: 0, 3: 3, 4: 4, 5: 0, 9: 0}
	var ok := true
	for t in want:
		ok = ok and NpcTableReader.texture_slot(int(t), 0) == int(want[t])
	_check(ok, "TextureType 0/1/2/3/4/above -> slot 0/1/0/3/4/0 (the table at 0x9d3c5c)")
	_check(NpcTableReader.texture_slot(0, 1) == 2 and NpcTableReader.texture_slot(1, 1) == 2
		and NpcTableReader.texture_slot(3, 1) == 3 and NpcTableReader.texture_slot(4, 1) == 4,
		"a champion takes slot 2 for 0 or 1, keeps 3 and 4 (0x9d3c70 case 1)")
	_check(NpcTableReader.texture_slot(1, 4) == 1 and NpcTableReader.texture_slot(0, 6) == 0,
		"a giant or an elite keeps its slot")
	_check(NpcTableReader.texture_slot(4, 0, true) == 0 and NpcTableReader.texture_slot(1, 1, true) == 1,
		"a COS maps without case 4 and without the champion step (0x9c611e)")
	var row := PackedStringArray()
	row.resize(105)
	for i in row.size():
		row[i] = "0"
	row[2] = "MOB_TEST_CLON"
	row[93] = "1"
	var other := row.duplicate()
	other[2] = "MOB_TEST"
	other[93] = "0"
	var text := "\t".join(row) + "\n" + "\t".join(other) + "\n"
	var bytes := PackedByteArray([0xFF, 0xFE])
	bytes.append_array(text.to_utf16_buffer())
	var got := NpcTableReader.parse_texture_types(bytes)
	_check(got.get("MOB_TEST_CLON", -1) == 1 and not got.has("MOB_TEST"), "column 93 read per code, zeros left out")

func _test_material_words() -> void:
	var data := PackedByteArray()
	data.resize(BsrReader.PREAMBLE_END)
	var off := data.size()
	var paths := ["a.bmt", "a_clon.bmt", "a_champ.bmt"]
	var words := [0, 1, 2]
	var buf := StreamPeerBuffer.new()
	buf.put_u32(3)
	for i in 3:
		buf.put_u32(words[i])
		buf.put_u32(paths[i].length())
		buf.put_data(paths[i].to_ascii_buffer())
	data.append_array(buf.data_array)
	var m := BsrReader.material_words(data, off)
	_check(m.get(0) == "a.bmt" and m.get(1) == "a_clon.bmt" and m.get(2) == "a_champ.bmt",
		"the material list by its leading word (ResObject::FUN_00be41d0)")
	var p := BsrReader.ParsedObject.new()
	p.material_path = "a.bmt"
	p.material_by_word = {0: "a.bmt", 1: "a_clon.bmt", 2: "a_champ.bmt"}
	_check(p.material_for_slot(1) == "a_clon.bmt" and p.material_for_slot(2) == "a_champ.bmt",
		"a Hashade (slot 1) draws the clone material, a champion (2) the champion one")
	p.material_by_word = {0: "a.bmt", 2: "a_champ.bmt"}
	_check(p.material_for_slot(1) == "a.bmt" and p.material_for_slot(3) == "a.bmt",
		"an empty slot falls back to slot 0 (CCompChar::FUN_00c32680)")
	p.material_by_word = {}
	_check(p.material_for_slot(1) == "a.bmt", "a file with no word map draws its first material")

func _test_keys() -> void:
	_check(MonsterDraw.template_key("mob\\a.bsr", 0) == "mob\\a.bsr", "slot 0 keeps the plain model key")
	var k := MonsterDraw.template_key("mob\\a.bsr", 1)
	_check(k != "mob\\a.bsr" and MonsterDraw.model_of_key(k) == "mob\\a.bsr" and MonsterDraw.slot_of_key(k) == 1,
		"a slot's key comes apart into model and slot")
	_check(MonsterDraw.slot_of_key("mob\\a.bsr") == 0, "a plain key is slot 0")

func _entry(mode: int, efp: String, bone: String, w4c: int = 0) -> BsrReader.ParticleEntry:
	var e := BsrReader.ParticleEntry.new()
	e.mode = mode
	e.efp = efp
	e.bone = bone
	e.w4c = w4c
	return e

func _skel() -> Skeleton3D:
	var s := Skeleton3D.new()
	s.add_bone("Bip01")
	s.add_bone("Bone03")
	s.set_bone_parent(1, 0)
	s.add_bone("Bone04")
	s.set_bone_parent(2, 0)
	return s

func _test_ambient() -> void:
	var amb := BsrReader.ParticleMod.new()
	amb.set_kind = BsrReader.SET_BY_CLIP
	amb.set_name = "ambient"
	amb.entries.append(_entry(0, "ice.efp", "Bone03"))
	amb.entries.append(_entry(0, "ice.efp", "Bone04"))
	amb.entries.append(_entry(1, "off.efp", ""))
	var p := BsrReader.ParsedObject.new()
	p.particle_mods = [amb]
	var s := _skel()
	var rows := BodyFx.ambient_rows(p, s)
	_check(rows.size() == 2 and (rows[0] as ItemGlowTables.ParticleRow).bone == "Bone03"
		and (rows[1] as ItemGlowTables.ParticleRow).bone == "Bone04",
		"the ambient set's bone entries become rows on the body's skeleton; the offset one is left (OPEN)")
	var broken := BsrReader.ParticleMod.new()
	broken.set_kind = BsrReader.SET_BY_CLIP
	broken.set_name = "ambient"
	broken.entries.append(_entry(0, "a.efp", "NoSuchBone"))
	broken.entries.append(_entry(0, "b.efp", "Bone03"))
	p.particle_mods = [broken]
	_check(BodyFx.ambient_rows(p, s).is_empty(), "a missing bone ends its mod (round 720's rule)")
	s.free()

func _test_clip_fx() -> void:
	var die := BsrReader.ParticleMod.new()
	die.set_kind = BsrReader.SET_BY_TYPE
	die.action_type = 4
	die.set_name = "default"
	die.entries.append(_entry(1, "smog.efp", "", 2379))
	die.entries.append(_entry(0, "spark.efp", "Bone03", 0))
	var p := BsrReader.ParsedObject.new()
	p.particle_mods = [die]
	_check(p.particle_entries_for(4, "sword").size() == 2, "a group without its own set takes default's (AniMixer::FUN_00c551a0)")
	_check(p.particle_entries_for(2, "default").is_empty(), "a type without a set has none")
	_check(BodyFx.clip_paths(p) == PackedStringArray(["smog.efp", "spark.efp"]), "the clip effect files, for the preload")

	var host := Node3D.new()
	root.add_child(host)
	var s := _skel()
	host.add_child(s)
	var fx := BodyFx.new()
	var made: Array = []
	fx.factory = func(path: String) -> EfpEffect:
		var e := EfpEffect.new()
		e.path = path
		made.append(e)
		return e
	var sounds := AnimSounds.new()
	var calls: Array = []
	sounds.clip_fx = func(owner, skel, key: String, entries: Array, restarted: bool) -> void:
		calls.append([key, entries.size(), restarted])
		if restarted:
			fx.restart(skel, key)
		if not entries.is_empty():
			fx.fire(owner.node, skel, key, entries)
	var owner := AnimSounds.Owner.new()
	owner.parsed = p
	owner.node = host
	sounds.register(s, owner)
	var anim := BanReader.ParsedAnimation.new()
	anim.duration_ms = 3000
	anim.set_meta(BsrReader.CLIP_META, [4, "default"])
	sounds.advance(s, anim, 1.0, 16.0, false)
	_check(calls.size() == 1 and int(calls[0][1]) == 1 and bool(calls[0][2]) and made.size() == 1
		and (made[0] as EfpEffect).path == "spark.efp", "the die clip's first frame fires its 0 ms key")
	sounds.advance(s, anim, 1.0, 2000.0, false)
	_check(made.size() == 1, "nothing between the keys")
	sounds.advance(s, anim, 1.0, 2400.0, false)
	_check(made.size() == 2 and (made[1] as EfpEffect).path == "smog.efp", "the 2379 ms key fires when the clip passes it")
	sounds.advance(s, anim, 1.0, 2900.0, false)
	_check(made.size() == 2, "each key fires once a pass")
	sounds.advance(s, anim, 2.0, 10.0, false)
	_check(made.size() == 3 and (made[0] as EfpEffect).is_queued_for_deletion() and (made[1] as EfpEffect).is_queued_for_deletion(),
		"the clip played again stops its last run's effects (CRTAnimation::vslot_001) and fires anew")
	_check(fx.fired == 3, "three effects started in all")
	host.queue_free()
