extends SceneTree

## Round 860, lane H: the horse is drawn from its own model, not a capsule.
##
## The summoned horse drew as a white capsule round its rider: its .bsr
## (cos\c_horse1.bsr, MEASURED: a .bsk, two .bms, six clips) writes object
## type 6, and SkinnedBsrAssembler took only types 0 and 1 for a body
## ("is not a character .bsr (type 6)"), so _cos_build_body fell back to its
## untextured CapsuleMesh. The original builds one resource class for types
## 1, 2, 3, 4, 6 and 7 (READ, ResourceMgr::FUN_00be9250 -> FUN_00be8dc0), whose
## loader reads the sound section for every type (ResObject::FUN_00be41d0 ->
## FUN_00c0b740), and animates any resource with a skeleton and clips
## (CCompChar::FUN_00c2b930). So: a characterdata body (a monster, a COS, a
## mall model) is assembled from any skeletal .bsr, and keeps its sound sets.
##
## SYNTHETIC data only (map_animation_fixture.gd's bones, mesh and clip, and
## a .bsr written here), never game data. Run headless on the render box:
## `client/tools/remote_godot.sh tests`.
##
## NEGATIVES: dropping the `true` (skinned_object) from
## World3D._assemble_monster_model fails "the type-6 horse is assembled" and
## "its body is the model, not a capsule"; restoring BsrReader's
## `if built.is_character:` gate on _attach_sound_sets fails "a type-6 body
## keeps its sound sets".

const Fixture = preload("res://scripts/world/map_animation_fixture.gd")

const HORSE := "res\\cos\\synth_horse.bsr"
const HEART := "res\\mob\\synth_heart.bsr"
const MOB := "res\\mob\\synth_mob.bsr"
const ITEM := "res\\item\\synth_blade.bsr"
const STILL6 := "res\\etc\\synth_pillar.bsr"

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## A skinned body .bsr through the section table, of object type `type`:
## one material, the fixture's mesh, a skeleton when `skel` is set, one clip
## in the `default` group as its stand (type 0), and a sound section with
## one by-type set (action 0, `default`) holding one track.
static func _body_bsr(type: int, skel: String) -> PackedByteArray:
	var buf := PackedByteArray()
	buf.resize(BsrReader.PREAMBLE_END)
	var magic := BsrReader.MAGIC.to_ascii_buffer()
	for i in range(magic.size()):
		buf[i] = magic[i]
	buf.encode_u32(BsrReader.OFF_TYPE, (2 << 16) | type)
	Fixture.lp(buf, "synth_body")
	var pad := PackedByteArray()
	pad.resize(112)
	buf.append_array(pad)
	buf.encode_u32(BsrReader.OFF_PTR_MATERIAL, buf.size())
	Fixture.u32(buf, 1)
	Fixture.u32(buf, 0)
	Fixture.lp(buf, "prim\\synth_body.bmt")
	buf.encode_u32(BsrReader.OFF_PTR_MESH, buf.size())
	Fixture.u32(buf, 1)
	Fixture.lp(buf, "prim\\leaf.bms")
	buf.encode_u32(BsrReader.OFF_PTR_ANIMATION, buf.size())
	Fixture.u32(buf, 4096)
	Fixture.u32(buf, 0)
	Fixture.u32(buf, 1)
	Fixture.lp(buf, "prim\\sway.ban")
	buf.encode_u32(BsrReader.OFF_PTR_SKELETON, buf.size())
	Fixture.u32(buf, 1 if skel != "" else 0)
	if skel != "":
		Fixture.lp(buf, skel)
		Fixture.lp(buf, "")
	buf.encode_u32(BsrReader.OFF_PTR_MESH_GROUP, buf.size())
	Fixture.u32(buf, 1)
	Fixture.lp(buf, "default")
	Fixture.u32(buf, 1)
	Fixture.u32(buf, 0)
	buf.encode_u32(BsrReader.OFF_PTR_ANIMATION_GROUP, buf.size())
	Fixture.u32(buf, 1)
	Fixture.lp(buf, "default")
	Fixture.u32(buf, 1)
	Fixture.u32(buf, BsrReader.AnimationEntry.TYPE_STAND)
	Fixture.u32(buf, 0)
	Fixture.u32(buf, 0) # no events
	Fixture.u32(buf, 2) # two walk points, as every real entry
	for v in [0.0, 0.0, 0.0, 1.0]:
		Fixture.f32(buf, v)
	Fixture.f32(buf, 1.0)
	# The sound section (anim_sounds_test.gd's shape): no set by clip, one by
	# type -- kind 1, action 0, `default`, one sound mod with one track.
	buf.encode_u32(BsrReader.OFF_PTR_SOUND, buf.size())
	Fixture.u32(buf, 0)
	Fixture.u32(buf, 1)
	Fixture.u32(buf, 1)
	Fixture.u32(buf, BsrReader.AnimationEntry.TYPE_STAND)
	Fixture.lp(buf, "default")
	Fixture.u32(buf, 1)
	Fixture.u32(buf, 0x50000)
	buf.append_array(_zeros(28))
	Fixture.u32(buf, 1)
	buf.append_array(_zeros(44))
	Fixture.lp(buf, "default")
	Fixture.u32(buf, 1)
	Fixture.u32(buf, 1)
	Fixture.lp(buf, "prim\\snd\\x.wav")
	Fixture.u32(buf, 250)
	Fixture.lp(buf, "snd_hoof")
	return buf

static func _zeros(n: int) -> PackedByteArray:
	var z := PackedByteArray()
	z.resize(n)
	return z

func _archive() -> Pk2Reader:
	var a := Fixture.StubArchive.new()
	a.add(HORSE, _body_bsr(6, "prim\\sway.bsk"))
	a.add(HEART, _body_bsr(3, "prim\\sway.bsk"))
	a.add(MOB, _body_bsr(BsrReader.TYPE_CHARACTER, "prim\\sway.bsk"))
	a.add(ITEM, _body_bsr(BsrReader.TYPE_ITEM, "prim\\sway.bsk"))
	a.add(STILL6, _body_bsr(6, ""))
	a.add("prim\\leaf.bms", Fixture.build_bms())
	a.add("prim\\sway.bsk", Fixture.build_bsk())
	a.add("prim\\sway.ban", Fixture.build_ban(2000, true))
	return a

func _initialize() -> void:
	var watchdog := create_timer(60.0)
	watchdog.timeout.connect(func() -> void:
		print("FAIL the suite never reported (a script error stopped it)")
		quit(1))
	await process_frame
	var archive := _archive()
	_test_parse(archive)
	_test_assembler(archive)
	var world := _make_world()
	if world != null:
		_test_world(world, archive)
		root.remove_child(world)
		world.free()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

func _parsed(archive: Pk2Reader, path: String) -> BsrReader.ParsedObject:
	return BsrReader.parse(archive.read_file(ObjectLoader.find_file(archive, path)))

func _test_parse(archive: Pk2Reader) -> void:
	var horse := _parsed(archive, HORSE)
	_check(horse != null and horse.object_type == 6 and horse.skeleton_path == "prim\\sway.bsk",
		"a type-6 body parses with its skeleton")
	_check(horse != null and not horse.is_character, "and is not a type 0/1 character (the type word is kept as written)")
	_check(horse != null and horse.animation_for(BsrReader.AnimationEntry.TYPE_STAND, "default") == "prim\\sway.ban",
		"its stand clip is found in its default group")
	var hoof: BsrReader.SoundSet = horse.sound_set_for(BsrReader.AnimationEntry.TYPE_STAND, "default") if horse != null else null
	_check(hoof != null and hoof.tracks.size() == 1 and hoof.tracks[0].name == "snd_hoof",
		"a type-6 body keeps its sound sets (FUN_00be41d0 reads them for every type)")
	var heart := _parsed(archive, HEART)
	_check(heart != null and heart.sound_set_for(BsrReader.AnimationEntry.TYPE_STAND, "default") != null,
		"so does a type-3 skeletal body")
	var mob := _parsed(archive, MOB)
	_check(mob != null and mob.is_character and mob.sound_set_for(BsrReader.AnimationEntry.TYPE_STAND, "default") != null,
		"a type-1 monster as before: a character, with its sounds")
	var item := _parsed(archive, ITEM)
	_check(item != null and item.sound_sets_by_type.is_empty(), "an item with a skeleton of its own reads none, as before")
	var still := _parsed(archive, STILL6)
	_check(still != null and still.skeleton_path == "" and still.sound_sets_by_type.is_empty(),
		"a type-6 object with no skeleton reads none, as before")

func _test_assembler(archive: Pk2Reader) -> void:
	_check(SkinnedBsrAssembler.assemble_from_archive(archive, HORSE, true) == null,
		"the character-only gate still refuses a type-6 file (the switch is the caller's)")
	var a := SkinnedBsrAssembler.assemble_from_archive(archive, HORSE, true, false, 0, true)
	_check(a != null and a.skeleton != null and a.skeleton.get_bone_count() > 0 and a.skinned_pieces == 1,
		"taken as a skinned object it is a skeleton with its skinned piece")
	_check(a != null and a.idle_animation != null, "and its idle clip")
	_check(SkinnedBsrAssembler.assemble_from_archive(archive, STILL6, true, false, 0, true) == null,
		"a skeleton-less type 6 is still refused (nothing to skin)")
	if a != null and a.skeleton != null:
		a.skeleton.free()

func _make_world() -> Node:
	var sub := GDScript.new()
	sub.source_code = "\n".join(PackedStringArray([
		"extends \"res://scripts/World3D.gd\"",
		"func _ready() -> void:",
		"\tpass",
		"func _physics_process(_delta: float) -> void:",
		"\tpass",
		"func _process(_delta: float) -> void:",
		"\tpass",
		"func _input(_event: InputEvent) -> void:",
		"\tpass",
		"func _unhandled_input(_event: InputEvent) -> void:",
		"\tpass",
		"func _exit_tree() -> void:",
		"\tpass",
		""]))
	_check(sub.reload() == OK and sub.can_instantiate(), "a subclass of World3D.gd compiles")
	var scene := load("res://scenes/World3D.tscn") as PackedScene
	if not sub.can_instantiate() or scene == null:
		return null
	var world: Node = scene.instantiate()
	world.set_script(sub)
	root.add_child(world)
	return world

func _test_world(world: Node, archive: Pk2Reader) -> void:
	# The archive's own assembler (no test hook), synchronously.
	world.set("_data_pk2", archive)
	world.set("_monster_async_templates", false)
	world.set("_monster_models_loaded", true)
	var assembled = world.call("_assemble_monster_model", "cos\\synth_horse.bsr")
	_check(assembled != null and (assembled as SkinnedBsrAssembler.AssembledCharacter).skeleton != null,
		"the type-6 horse is assembled by the world's monster/COS assembler")
	if assembled != null and (assembled as SkinnedBsrAssembler.AssembledCharacter).skeleton != null:
		(assembled as SkinnedBsrAssembler.AssembledCharacter).skeleton.free()
	# The COS body itself, through _cos_build_body.
	var table := CosTable.new()
	var row := CosTable.Row.new()
	row.id = 2191
	row.code = "COS_C_SYNTH_HORSE"
	row.type4 = 1
	row.model = "cos\\synth_horse.bsr"
	row.bc = 20
	table.by_id[row.id] = row
	table.by_code[row.code] = row
	world.set("_cos_table", table)
	var rec := CosSpawnNet.Record.new()
	rec.uid = 0x7e000001
	rec.ref_id = row.id
	rec.kind = 0
	rec.life = 1
	(world.get("_cos_recs") as Dictionary)[rec.uid] = rec
	world.call("_cos_build_body", rec, Vector3(10, 0, 10))
	var body: Node3D = (world.get("_cos_bodies") as Dictionary).get(rec.uid)
	_check(body != null, "the COS body is built")
	if body == null:
		return
	var skel: Skeleton3D = null
	var capsules := 0
	var pieces := 0
	for n in body.find_children("*", "", true, false):
		if n is Skeleton3D and skel == null:
			skel = n
		if n is MeshInstance3D and (n as MeshInstance3D).mesh is CapsuleMesh:
			capsules += 1
		if n is MeshInstance3D and (n as MeshInstance3D).skin != null:
			pieces += 1
	_check(skel != null and capsules == 0 and pieces >= 1,
		"its body is the model, not a capsule (skeleton %s, %d skinned piece(s), %d capsule(s))" % [skel != null, pieces, capsules])
	_check(skel != null and skel.get_parent() == body, "the skeleton hangs under the COS body, where the rider's saddle is read from")
	world.call("_cos_free_body", rec.uid)
