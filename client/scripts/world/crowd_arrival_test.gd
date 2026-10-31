extends SceneTree

## Round 739 (crowd_scale.md lane B) in the world itself: arrivals dressed over
## frames nearest first (B4), with what changed while they waited; the others'
## walk once a rendered frame (B1); the uid map (B7); others' clip sounds cut
## at 600 (B3). Run headless on the render box: `client/tools/remote_godot.sh
## tests`.
##
## The world is World3D.tscn with a subclass (seated_spawn_test.gd's pattern)
## whose _ready does nothing and whose asset hooks hand out a bare Skeleton3D
## per body -- recording what each was dressed with -- and a synthetic
## two-keyframe clip per action type, so the real _spawn_or_update_other,
## _pump_other_builds and _dress_other run.
##
## NEGATIVES: _dress_other reading the spawn's own equipped (not the queued
## args _redress_other keeps current) fails "dressed with the item a 0x3038
## put on while it waited"; the pump in arrival order fails "the nearest is
## dressed first"; _on_entity_left without the queue drop fails "a body that
## left before its turn is never dressed".
## Round 748: the pump without its readiness test fails "a body whose
## templates are being made waits"; the readiness kept for ever fails "once
## adopted it is dressed".

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
	await process_frame
	var world := _make_world()
	if world != null:
		await _test_arrival(world)
		_test_walk(world)
		_test_hearing(world)
		await _test_review(world)
		await _test_async_templates(world)
		root.remove_child(world)
		world.free()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

func _make_world() -> Node:
	var sub := GDScript.new()
	sub.source_code = "\n".join(PackedStringArray([
		"extends \"res://scripts/World3D.gd\"",
		"var clips: Dictionary = {}",
		"var dressed: Array = []",
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
		"func _build_assembled_character(look: CharacterLook, _body: String = \"\") -> Skeleton3D:",
		"\tdressed.append([look.worn.duplicate(), look.pluses.duplicate()])",
		"\treturn Skeleton3D.new()",
		"func _body_animation_for(_gender: String, action_type: int, _group: String = \"default\") -> BanReader.ParsedAnimation:",
		"\tif not clips.has(action_type):",
		"\t\tvar a := BanReader.ParsedAnimation.new()",
		"\t\ta.animation_name = \"type%d\" % action_type",
		"\t\ta.duration_ms = 1000",
		"\t\tvar b := BanReader.Bone.new()",
		"\t\tb.keyframes.append(BanReader.Keyframe.new())",
		"\t\tb.keyframes.append(BanReader.Keyframe.new())",
		"\t\ta.bones.append(b)",
		"\t\tclips[action_type] = a",
		"\treturn clips[action_type]",
		"func _body_animation_path(_gender: String, action_type: int, _group: String) -> String:",
		"\treturn \"type%d\" % action_type",
		""]))
	_check(sub.reload() == OK and sub.can_instantiate(), "a subclass of World3D.gd compiles")
	var scene := load("res://scenes/World3D.tscn") as PackedScene
	if not sub.can_instantiate() or scene == null:
		return null
	var world: Node = scene.instantiate()
	world.set_script(sub)
	root.add_child(world)
	return world

func _snap(id: int, name: String, at: Vector3) -> WorldNet.EntitySnapshot:
	var s := WorldNet.EntitySnapshot.new()
	s.character_id = id
	s.char_name = name
	s.gender = CharacterNet.GENDER_CHINA_MAN
	s.x = at.x
	s.y = at.y
	s.z = at.z
	return s

func _moved(id: int, at: Vector3) -> WorldNet.EntityMoved:
	var m := WorldNet.EntityMoved.new()
	m.character_id = id
	m.x = at.x
	m.y = at.y
	m.z = at.z
	return m

func _here(world: Node) -> Vector3:
	var p: Node3D = world.get("player")
	var others: Node3D = world.get("other_entities")
	return others.to_local(p.global_position)

func _test_arrival(world: Node) -> void:
	var queue = world.get("_other_builds")
	queue.budget_usec = 0  # one body a frame
	var here := _here(world)
	var bodies: Dictionary = world.get("_other_bodies")
	var gaits: Dictionary = world.get("_other_gaits")
	var dressed: Array = world.get("dressed")
	world.call("_spawn_result_others", [_snap(201, "Far", here + Vector3(50, 0, 0)), _snap(202, "Near", here + Vector3(5, 0, 0)),
		_snap(203, "Mid", here + Vector3(20, 0, 0))], [203])
	_check(bodies.has(201) and bodies.has(202) and bodies.has(203), "every arrival has its node at once")
	_check(gaits.has(202) and not gaits.has(201) and not gaits.has(203), "the nearest is dressed first, the others wait (dressed %s)" % str(gaits.keys()))
	_check(int(world.call("_other_by_uid", 203)) == 203, "a waiting body is found by its uid (B7)")
	# While Mid waits: a weapon at +7 (0x3038), and Far walks, then leaves.
	world.call("_on_other_equipment_changed", 203, EquipmentNet.SLOT_WEAPON, 9001, 7)
	var far: Node3D = bodies[201]
	var far_from := far.position
	world.call("_on_entity_moved", _moved(201, here + Vector3(70, 0, 0)))
	world.call("_step_other_bodies", 1.0 / 60.0, 1)
	_check(far.position.distance_to(far_from.lerp(here + Vector3(70, 0, 0), 0.25)) < 1e-3, "a waiting body walks as a dressed one does")
	world.call("_on_entity_left", 201)
	_check(not queue.has(201), "a body that left is taken off the queue")
	await process_frame
	world.call("_pump_other_builds")
	_check(gaits.has(203), "the next frame dresses the next nearest")
	var last: Array = dressed[-1] if not dressed.is_empty() else [{}, {}]
	_check(int((last[0] as Dictionary).get(EquipmentNet.SLOT_WEAPON, 0)) == 9001 and int((last[1] as Dictionary).get(EquipmentNet.SLOT_WEAPON, 0)) == 7,
		"dressed with the item a 0x3038 put on while it waited, at its plus (got %s)" % str(last))
	_check(gaits.has(203) and bool((gaits[203] as Dictionary).get("sitting", false)), "dressed seated, from the result's Seated tail")
	var loop = null
	if gaits.has(203):
		for entry in world.get("_animated"):
			if entry[0] == gaits[203]["skeleton"]:
				loop = entry[1]
	var sitting = world.call("_body_animation_for", "", BsrReader.AnimationEntry.TYPE_SITTING, "default")
	_check(loop == sitting, "and looping the sitting clip")
	await process_frame
	world.call("_pump_other_builds")
	_check(not gaits.has(201) and dressed.size() == 2 and queue.is_empty(), "a body that left before its turn is never dressed (%d dressed)" % dressed.size())
	_check(int(world.call("_other_by_uid", 201)) == -1, "and its uid is gone")
	# With budget to spare an arrival is dressed in its own call, as before.
	queue.budget_usec = 1 << 30
	world.call("_on_entity_entered", _snap(204, "Quick", here + Vector3(0, 0, 30)))
	_check(gaits.has(204), "with budget left a lone arrival is dressed at once")
	var plate := false
	for c in (bodies[204] as Node).get_children():
		if c is Label3D:
			plate = true
	_check(plate, "with its name plate")

## B1: eight physics steps in one rendered frame walk a body as eight passes did.
func _test_walk(world: Node) -> void:
	var bodies: Dictionary = world.get("_other_bodies")
	var gaits: Dictionary = world.get("_other_gaits")
	var body: Node3D = bodies[202]
	var from := body.position
	var to := from + Vector3(40, 0, 0)
	world.call("_on_entity_moved", _moved(202, to))
	world.call("_step_other_bodies", 8.0 / 60.0, 8)
	var p := from
	for i in 8:
		p = p.lerp(to, 0.25)
	_check(body.position.distance_to(p) < 1e-3, "8 folded steps walk the body where 8 per-step passes did (%.4f off)" % body.position.distance_to(p))
	_check(bool((gaits[202] as Dictionary).get("moving", false)), "and it runs while still catching up")

## B3: another player's clip sounds are rested past 600 from the listener, in
## round 738's player branch of the tick (round 739's review, F1): the state is
## the player cull entry's info[1], "out of hearing at the last tick".
## NEGATIVE: on the scratch merge of 738 before F1 (B3 in an `elif` the player
## branch never reaches) the 700 case fails.
func _test_hearing(world: Node) -> void:
	var gaits: Dictionary = world.get("_other_gaits")
	var skel: Skeleton3D = gaits[202]["skeleton"]
	var body: Node3D = (world.get("_other_bodies") as Dictionary)[202]
	var here := _here(world)
	body.position = here + Vector3(700, 0, 0)
	world.call("_tick_idle_animations", 1.0 / 60.0)
	var info: Array = world.get("_crowd_cull").info(skel)
	_check(info.size() == CrowdAnim.PLAYER_INFO_SIZE, "another player's skeleton takes the player branch (entry of %d fields)" % info.size())
	_check(info.size() > 1 and float(info[1]) == 1.0, "700 from the listener its sounds are out of hearing")
	body.position = here + Vector3(100, 0, 0)
	world.call("_tick_idle_animations", 1.0 / 60.0)
	_check(info.size() > 1 and float(info[1]) == 0.0, "and back in at 100")

## Round 739's review: F5 (a group page queued whole), F2 (a waiting sitter who
## walks off), F7 (a waiting body is not drawn for its auras), F8 (a re-sent
## spawn's items for a waiting body), F6 (a body an ulp short is put on its
## target and then left alone).
## NEGATIVES: without NetClient's bracket (the begin/end calls dropped) the
## first-listed Far1 is dressed first; without F2's erase Mid1 is dressed on
## the sitting loop.
func _test_review(world: Node) -> void:
	var queue = world.get("_other_builds")
	queue.budget_usec = 0
	var here := _here(world)
	var gaits: Dictionary = world.get("_other_gaits")
	var bodies: Dictionary = world.get("_other_bodies")
	var dressed: Array = world.get("dressed")
	await process_frame
	world.call("_on_user_group_begin")
	for sn in [_snap(301, "Far1", here + Vector3(0, 0, 60)), _snap(302, "Near1", here + Vector3(0, 0, -6)),
			_snap(303, "Mid1", here + Vector3(0, 0, -25))]:
		world.call("_on_entity_entered", sn)
	_check(not gaits.has(301) and not gaits.has(302) and not gaits.has(303), "F5: inside a group page nothing is dressed yet")
	world.call("_on_user_group_end")
	_check(gaits.has(302) and not gaits.has(301) and not gaits.has(303),
		"F5: at the page's end its nearest is dressed first, not the first listed (dressed %s)" % str(gaits.keys()))
	# F2: Mid1 sits while waiting, then walks off.
	world.call("_seat_result_others", [303])
	world.call("_on_entity_moved", _moved(303, here + Vector3(4, 0, -25)))
	_check(not (world.get("_other_seated") as Dictionary).has(303), "F2: a waiting sitter who walks off is not seated any more")
	# F7 and F8 on Far1, still waiting.
	_check(world.call("_fx_owner_body", 301, SkillNet.OWNER_CHARACTER) == null, "F7: a waiting body is not drawn for its auras")
	world.call("_spawn_or_update_other", 301, "Far1", here + Vector3(0, 0, 60), {EquipmentNet.SLOT_WEAPON: 7777})
	await process_frame
	world.call("_pump_other_builds")
	_check(gaits.has(303) and not bool((gaits[303] as Dictionary).get("sitting", false)), "F2: and it is dressed standing")
	var loop = null
	if gaits.has(303):
		for entry in world.get("_animated"):
			if entry[0] == gaits[303]["skeleton"]:
				loop = entry[1]
	_check(loop == world.call("_body_animation_for", "", BsrReader.AnimationEntry.TYPE_STAND, "default"), "F2: on the stand loop")
	await process_frame
	world.call("_pump_other_builds")
	_check(gaits.has(301), "the last of the page is dressed the frame after")
	var last: Array = dressed[-1] if not dressed.is_empty() else [{}, {}]
	_check(int((last[0] as Dictionary).get(EquipmentNet.SLOT_WEAPON, 0)) == 7777, "F8: in the items a re-sent spawn named while it waited (got %s)" % str(last[0]))
	_check(world.call("_fx_owner_body", 301, SkillNet.OWNER_CHARACTER) == bodies.get(301), "F7: dressed, it is the auras' body")
	# F6: an ulp short of its target.
	var near: Node3D = bodies[302]
	var target: Vector3 = (world.get("_other_body_targets") as Dictionary)[302]
	near.position = target + Vector3(0.0001, 0, 0)
	world.call("_step_other_bodies", 1.0 / 60.0, 1)
	_check(near.position == target, "F6: a body within the snap distance is put on its target (%s against %s)" % [str(near.position), str(target)])


## Round 748: an arrival whose templates are not made yet waits in the queue
## while they are made off the main thread, and a farther body of a ready
## kind is not held up by a nearer one still waiting. The appearance is a synthetic one whose task assemblies are stand-ins
## (CharacterAppearance.body_assembler / item_assembler); the subclass's own
## _build_assembled_character still dresses the body.
func _test_async_templates(world: Node) -> void:
	var queue = world.get("_other_builds")
	queue.budget_usec = 1 << 30
	var here := _here(world)
	var gaits: Dictionary = world.get("_other_gaits")
	var app := CharacterAppearance.new()
	app.add_body(1907, "char\\test\\man.bsr")
	app.add_body(1908, "char\\test\\woman.bsr")
	app._items[5001] = {"models": PackedStringArray(["item\\chest_a.bsr"]), "type_ids": PackedInt32Array([3, 1, 1, 3]), "code": "ITEM_CHEST"}
	app._full_items_loaded = true
	app.body_assembler = func(path: String) -> SkinnedBsrAssembler.AssembledCharacter:
		# A new kind's task takes a while (round 756: the stand-in finished
		# between two spawns on a loaded box, and the "waits" case raced it).
		if path.contains("woman"):
			OS.delay_msec(500)
		var s3 := Skeleton3D.new()
		s3.add_bone("Bip01")
		var t := SkinnedBsrAssembler.AssembledCharacter.new()
		t.skeleton = s3
		t.canonical_skin = Skeleton3DBuilder.canonical_skin(s3)
		return t
	app.item_assembler = func(source: Skeleton3D, _skin: Skin, item_path: String) -> Array:
		var holder := Node3D.new()
		holder.name = item_path.get_file().get_basename()
		holder.set_meta("bone_count", source.get_bone_count())
		return [holder, null]
	world.set("_appearance", app)
	(world.get("_body_id_by_code") as Dictionary)["CHAR_TEST_MAN"] = 1907
	(world.get("_body_id_by_code") as Dictionary)["CHAR_TEST_WOMAN"] = 1908
	(world.get("_item_models") as Dictionary)[5001] = PackedStringArray(["item\\chest_a.bsr"])
	# The man's kind made first (the queue waits for it), then a woman near
	# and a man far: the far man (ready) is dressed, the near woman waits.
	world.call("_spawn_or_update_other", 401, "Man1", here + Vector3(0, 0, -10), {1: 5001}, "CHAR_TEST_MAN")
	_check(not gaits.has(401) and app.preparing(), "a body whose templates are being made waits; its task runs")
	app.wait_prepared()
	world.call("_pump_other_builds")
	_check(gaits.has(401), "once adopted it is dressed")
	world.call("_spawn_or_update_other", 402, "Woman1", here + Vector3(0, 0, -5), {1: 5001}, "CHAR_TEST_WOMAN")
	world.call("_spawn_or_update_other", 403, "Man2", here + Vector3(0, 0, -50), {1: 5001}, "CHAR_TEST_MAN")
	_check(gaits.has(403) and not gaits.has(402), "a farther body of a ready kind is dressed; the nearer one of a new kind waits")
	app.wait_prepared()
	world.call("_pump_other_builds")
	_check(gaits.has(402) and (queue as OtherCrowd.BuildQueue).is_empty(), "and the waiting one once its kind is made")
	world.set("_appearance", null)
	app.free_templates()
