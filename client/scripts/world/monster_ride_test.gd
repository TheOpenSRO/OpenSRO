extends SceneTree

## Round 809: a monster's ride and its death (MonsterRide): the characterInfo
## row's columns, the ride hung under the body by its Ride Type, the rider
## seated on the saddle, the monster's clips mirrored onto the ride, the die
## model swapped in at the death, and everything gone with the body. On a
## quiet World3D subclass with SYNTHETIC models (monster_draw_test.gd's
## pattern, the `_monster_assemble` and `_char_records_override` seams); no
## game data. Run headless on the render box: `client/tools/remote_godot.sh tests`.
##
## NEGATIVE (by construction): against v0.1.569 MonsterRide does not exist and
## the suite stops at its first check; with _ride_mirror emptied the mirror
## checks fail; without the _play_once hook the ride stays on its stand.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	var watchdog := create_timer(60.0)
	watchdog.timeout.connect(func() -> void:
		print("FAIL the suite never reported (a script error stopped it)")
		quit(1))
	if not ClassDB.class_exists("Node") or load("res://scripts/world/monster_ride.gd") == null:
		_check(false, "MonsterRide exists")
		quit(1)
		return
	_test_rows()
	_test_rules()
	var world := _make_world()
	if world != null:
		await process_frame
		_test_seated(world)
		_test_fixed(world)
		_test_dummy(world)
		_test_mirror(world)
		_test_death(world)
		_test_free(world)
		root.remove_child(world)
		world.free()
	print("monster_ride_test: %s (%d failure(s))" % ["PASS" if _failures == 0 else "FAIL", _failures])
	quit(0 if _failures == 0 else 1)

func _test_rows() -> void:
	var text := "#section\tcharacterInfo\n//ResourceFileID\tResourceTypeName\tSize\tRide Type\tride\tDie Bsr\tDie Effect\tDamageBone\tDamagePos\tBloodType\tDead Effect\n" \
		+ "CHAR_FIRST\tPCM_X\t2\tnone\tnone\tnone\tnone\tnone\t0,13,-2\thit_2_redblood\tnone\t0\t0\n" \
		+ "MOB_A\tMOB_A\t3.5\tRT_FIXED\tres\\mob\\a_ice.bsr\tnone\tnone\tnone\t0,14,-3.6\thit_2_ice\tnone\t0\t0\n" \
		+ "MOB_B\tMOB_B\t2.8\tnone\tres\\mob\\tiger.bsr\tnone\tnone\tnone\t0,15,-30\thit_2_redblood\tnone\t0\t0\n" \
		+ "MOB_C\tMOB_C\t7\tRT_DUMMY\tres\\mob\\devil.bsr\tnone\tnone\tnone\t0,20,-3.6\thit_2_redblood\tnone\t0\t0\n" \
		+ "MOB_D\tMOB_D\t1.5\tnone\tnone\tres\\mob\\d_die.bsr\tEVENT_D_DEAD\tnone\t0,10,-6\thit_2_redblood\tDEFFECT_FLASH\t0\t0\n" \
		+ "NPC_SHORT\t\tPLAYER\t1.9\tnone\tnone\tnone\tnone\t0,13,-2\tnone\tnone\t0\n"
	var sizes := {}
	var recs := {}
	SoundTable.parse_character_info(text.to_utf8_buffer(), sizes, recs)
	var a: SoundTable.CharacterInfo = recs.get("MOB_A")
	_check(a != null and a.ride_type == SoundTable.RIDE_FIXED and a.ride == "res\\mob\\a_ice.bsr" and a.die_bsr == "",
		"RT_FIXED and its ride path are read; 'none' is no path")
	var b: SoundTable.CharacterInfo = recs.get("MOB_B")
	_check(b != null and b.ride_type == SoundTable.RIDE_NONE and b.ride == "res\\mob\\tiger.bsr", "a ride of type none")
	var c: SoundTable.CharacterInfo = recs.get("MOB_C")
	_check(c != null and c.ride_type == SoundTable.RIDE_DUMMY, "RT_DUMMY")
	var d: SoundTable.CharacterInfo = recs.get("MOB_D")
	_check(d != null and d.die_bsr == "res\\mob\\d_die.bsr" and d.die_effect == "EVENT_D_DEAD"
		and d.dead_effect == SoundTable.DEAD_EFFECT_FLASH and is_equal_approx(d.size, 1.5), "the die model, Die Effect and DEFFECT_FLASH")
	var n: SoundTable.CharacterInfo = recs.get("NPC_SHORT")
	_check(n != null and n.ride_type == SoundTable.RIDE_UNKNOWN, "a row one cell short reads its Size cell as the Ride Type (-1), as the client's tokenizer does")
	_check(String(recs.get("", "")) == "CHAR_FIRST" and is_equal_approx(float(sizes.get("MOB_A", 0.0)), 3.5),
		"the first row is the fallback, and the sizes are read as before")

func _test_rules() -> void:
	_check(MonsterRide.die_swaps(true, true) and MonsterRide.die_swaps(false, false) and MonsterRide.die_swaps(true, false)
		and not MonsterRide.die_swaps(false, true), "the die model: unless the option is off AND the body has its own 36")
	var e := BsrReader.AnimationEntry.new()
	e.events = [PackedInt32Array([900, 2, 0, 1]), PackedInt32Array([640, 1, 0, 0]), PackedInt32Array([300, 1, 0, 0])]
	_check(MonsterRide.first_hit_key(e) == 300 and MonsterRide.first_hit_key(null) == -1, "the death effects' key: the first type-1 event")
	var seat := MonsterRide.seat(Transform3D(Basis(Vector3.UP, 0.5), Vector3(10, 0, 0)), Transform3D(Basis(), Vector3(0, 5, 0)), Vector3(1.5, 1.5, 1.5))
	_check(seat.origin.is_equal_approx(Vector3(10, 5, 0)) and is_equal_approx(seat.basis.get_scale().x, 1.5),
		"the seat: the saddle's pose times the ride's world, at the rider's scale")

# --- the world -----------------------------------------------------------------

const MODELS := {
	"MOB_RIDER": "syn\\rider.bsr", "MOB_FIXED": "syn\\stand.bsr", "MOB_DUMMY": "syn\\stand.bsr",
	"MOB_DIES": "syn\\body.bsr", "MOB_KEEPS": "syn\\body.bsr",
}
## Each model's action types, and whether it has a saddle bone.
const TYPES := {
	"syn\\rider.bsr": [0, 2, 5, 7], "res\\syn\\tiger.bsr": [0, 2, 4, 7], "syn\\stand.bsr": [0, 2],
	"res\\syn\\crystal.bsr": [0, 4], "res\\syn\\devil.bsr": [0, 2], "syn\\body.bsr": [0, 2, 4, 36],
	"res\\syn\\body_die.bsr": [4, 36],
}

func _rec(ride: String, ride_type: int, die := "") -> SoundTable.CharacterInfo:
	var r := SoundTable.CharacterInfo.new()
	r.ride = ride
	r.ride_type = ride_type
	r.die_bsr = die
	return r

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
	_check(sub.reload() == OK and sub.can_instantiate(), "a quiet subclass of World3D.gd compiles")
	var scene := load("res://scenes/World3D.tscn") as PackedScene
	if not sub.can_instantiate() or scene == null:
		return null
	var world: Node = scene.instantiate()
	world.set_script(sub)
	world.set("_monster_models_loaded", true)
	world.set("_monster_models_by_code", MODELS.duplicate())
	world.set("_monster_org_by_code", {})
	world.set("_monster_assemble", _model)
	world.set("_monster_async_templates", false)
	world.set("_char_records_override", {
		"MOB_RIDER": _rec("res\\syn\\tiger.bsr", SoundTable.RIDE_NONE),
		"MOB_FIXED": _rec("res\\syn\\crystal.bsr", SoundTable.RIDE_FIXED),
		"MOB_DUMMY": _rec("res\\syn\\devil.bsr", SoundTable.RIDE_DUMMY),
		"MOB_DIES": _rec("", SoundTable.RIDE_NONE, "res\\syn\\body_die.bsr"),
		"MOB_KEEPS": _rec("", SoundTable.RIDE_NONE, "res\\syn\\body_die.bsr"),
	})
	root.add_child(world)
	return world

## A synthetic model: a root, b1, and a saddle 5 up on a ride; a two-key clip
## per action type, each tagged with its entry as animation_for tags it.
func _model(path: String) -> SkinnedBsrAssembler.AssembledCharacter:
	var skel := Skeleton3D.new()
	skel.add_bone("root")
	skel.add_bone("b1")
	skel.set_bone_parent(1, 0)
	if path.begins_with("res\\syn\\tiger"):
		skel.add_bone("saddle")
		skel.set_bone_parent(2, 0)
		skel.set_bone_rest(2, Transform3D(Basis(), Vector3(0, 5, 0)))
		skel.reset_bone_poses()
	var mi := MeshInstance3D.new()
	mi.mesh = BoxMesh.new()
	skel.add_child(mi)
	var a := SkinnedBsrAssembler.AssembledCharacter.new()
	a.skeleton = skel
	var parsed := BsrReader.ParsedObject.new()
	var entries: Array = []
	for t in TYPES.get(path, [0]):
		var e := BsrReader.AnimationEntry.new()
		e.action_type = int(t)
		e.path = "%s#%d" % [path, int(t)]
		if int(t) == 4:
			e.events = [PackedInt32Array([250, 1, 0, 0])]
		entries.append(e)
		var clip := _clip(int(t))
		clip.set_meta(BsrReader.CLIP_META, [int(t), "default"])
		clip.set_meta("test_model", path)
		a.animation_cache[e.path] = clip
		if int(t) == 0:
			a.idle_animation = clip
	parsed.animation_groups = {"default": entries}
	a.parsed = parsed
	return a

func _clip(t: int) -> BanReader.ParsedAnimation:
	var clip := BanReader.ParsedAnimation.new()
	clip.duration_ms = 1000 + t
	clip.cyclic = t == 0
	clip.key_times = PackedInt32Array([0, 500])
	var track := BanReader.Bone.new()
	track.bone_name = "b1"
	for q in [Quaternion.IDENTITY, Quaternion(Vector3.RIGHT, 0.5)]:
		var k := BanReader.Keyframe.new()
		k.rotation = q
		track.keyframes.append(k)
	clip.bones.append(track)
	return clip

func _spawn(world: Node, id: int, code: String) -> Node3D:
	var snap := CombatNet.MonsterSnapshot.new()
	snap.monster_id = id
	snap.code_name = code
	snap.monster_name = code
	snap.hp = 10
	snap.max_hp = 10
	(world.get("_monster_snapshots") as Dictionary)[id] = snap
	world.call("_build_monster_body", snap)
	return (world.get("_monster_bodies") as Dictionary).get(id)

func _ride_of(world: Node, id: int) -> MonsterRide:
	return world.call("_monster_ride_of", id)

func _entry_of(world: Node, skel: Skeleton3D) -> Array:
	for e in world.get("_animated"):
		if (e as Array)[0] == skel:
			return e
	return []

func _test_seated(world: Node) -> void:
	var body := _spawn(world, 1, "MOB_RIDER")
	var r := _ride_of(world, 1)
	_check(body != null and r != null and body.get_node_or_null(MonsterRide.NODE) == r.root and r.assembled.skeleton.get_parent() == r.root,
		"a monster whose row names a ride has it under its body (a node of its own)")
	if r == null:
		return
	_check(_entry_of(world, r.assembled.skeleton).is_empty() and r.clip != null and r.clip_loop,
		"the ride is posed with its monster, not a clip-tick body of its own (round 809's perf gate); on its stand")
	body.global_position = Vector3(100, 0, 50)
	body.rotation.y = 1.2
	world.call("_step_monster_rides", true)
	var saddle := r.assembled.skeleton.global_transform * Vector3(0, 5, 0)
	_check(r.rider.global_position.is_equal_approx(saddle), "type none: the rider sits on the ride's saddle (%s at %s)" % [
		str(r.rider.global_position), str(saddle)])
	_check(is_equal_approx(r.root.global_rotation.y, 1.2), "and the ride turns with the monster")

func _test_fixed(world: Node) -> void:
	var body := _spawn(world, 2, "MOB_FIXED")
	var r := _ride_of(world, 2)
	if r == null:
		_check(false, "an RT_FIXED ride is made")
		return
	var rest := r.rider.transform
	body.rotation.y = 2.0
	world.call("_step_monster_rides", true)
	_check(r.root.global_basis.is_equal_approx(Basis.IDENTITY) and r.root.global_position.is_equal_approx(body.global_position),
		"RT_FIXED: the ride at the monster's place, never turned")
	_check(r.rider.transform.is_equal_approx(rest), "and the monster stays where it stands")

func _test_dummy(world: Node) -> void:
	var body := _spawn(world, 3, "MOB_DUMMY")
	var r := _ride_of(world, 3)
	if r == null:
		_check(false, "an RT_DUMMY ride is made")
		return
	r.rider.scale = BodyMirror.SCALE * 1.5
	r.rider_rest = r.rider.transform
	body.rotation.y = -0.7
	world.call("_step_monster_rides", true)
	# Round 828: both skeletons mirrored (BodyMirror), the root between them less the rider's.
	_check(r.assembled.skeleton.global_transform.is_equal_approx(r.rider.global_transform)
		and r.root.global_transform.basis.determinant() > 0.0, "RT_DUMMY: the ride takes the monster's whole transform")

func _test_mirror(world: Node) -> void:
	var r := _ride_of(world, 1)
	var monster: SkinnedBsrAssembler.AssembledCharacter = (world.get("_monster_assembled") as Dictionary).get(1)
	if r == null or monster == null:
		_check(false, "the rider for the mirror checks")
		return
	var attack: BanReader.ParsedAnimation = monster.animation_cache["syn\\rider.bsr#2"]
	world.call("_pose_ride", monster.skeleton, attack, 0.1, false, false)
	_check(r.clip != null and r.clip.get_meta("test_model", "") == "res\\syn\\tiger.bsr" and r.clip.get_meta(BsrReader.CLIP_META)[0] == 2
		and not r.clip_loop and r.follows, "the monster's one-shot of type 2 poses the ride's own type 2, once")
	var before := r.clip
	var other: BanReader.ParsedAnimation = monster.animation_cache["syn\\rider.bsr#5"]
	world.call("_pose_ride", monster.skeleton, other, 0.1, false, false)
	_check(r.clip == before and not r.follows, "a type the ride lacks (5) leaves its clip playing, on its own clock")
	var run: BanReader.ParsedAnimation = monster.animation_cache["syn\\rider.bsr#7"]
	world.call("_pose_ride", monster.skeleton, run, 2.0, true, false)
	_check(r.clip != null and r.clip.get_meta(BsrReader.CLIP_META)[0] == 7 and r.clip_loop and r.follows,
		"a gait loop (7) is the ride's loop, posed at the monster's time")

func _test_death(world: Node) -> void:
	world.set("_monster_decay_ms_by_code", {"MOB_DIES": 5000, "MOB_KEEPS": 5000})
	var body := _spawn(world, 4, "MOB_DIES")
	var assembled: Dictionary = world.get("_monster_assembled")
	var old: SkinnedBsrAssembler.AssembledCharacter = assembled.get(4)
	world.set("_die_model_option", true)
	world.call("_begin_monster_death", 4)
	var now: SkinnedBsrAssembler.AssembledCharacter = assembled.get(4)
	_check(now != null and now != old and old.skeleton.is_queued_for_deletion() and now.skeleton.get_parent() == body
		and (now.animation_cache.values()[0] as Object).get_meta("test_model", "") == "res\\syn\\body_die.bsr",
		"a dying monster with a die model becomes it, in place")
	_check(now.skeleton.transform.is_equal_approx(old.skeleton.transform), "at the body's own transform (its scale kept)")
	world.set("_die_model_option", false)
	_spawn(world, 5, "MOB_KEEPS")
	var keep: SkinnedBsrAssembler.AssembledCharacter = assembled.get(5)
	world.call("_begin_monster_death", 5)
	_check(assembled.get(5) == keep, "with the option off, a body with its own 36 keeps its body")
	world.set("_die_model_option", true)
	world.call("_dead_flash_start")
	var flash: ColorRect = world.get("_dead_flash")
	_check(flash != null and is_instance_valid(flash), "DEFFECT_FLASH puts a white layer over the screen")

func _test_free(world: Node) -> void:
	var r := _ride_of(world, 1)
	world.call("_free_monster_body", 1)
	_check(_ride_of(world, 1) == null and (r == null or r.root.is_queued_for_deletion() or r.body.is_queued_for_deletion()),
		"a freed body takes its ride with it")
