extends SceneTree

## Round 748: CharacterAppearance's templates made off the main thread
## (prepare / poll_prepared / wait_prepared), on synthetic templates (never
## real game data): the task's two assemblies are stand-ins
## (body_assembler, item_assembler) that build what the archive would, on the
## worker. Run headless on the render box: `client/tools/remote_godot.sh tests`.
##
## What it holds the path to:
## - a build of a new kind is not ready until its task is adopted; asking
##   starts one task per body, never a second while it runs;
## - after adoption build() assembles nothing on the main thread and dresses
##   the body as the synchronous path does;
## - a `_r` model that does not assemble brings its plain fallback (READ
##   0xa5f4f0's rule, as _item_instance has it), and one that does never
##   asks for it (round 758);
## - a second body of the same skeleton layout ends on the layout's one shared
##   skin, its items too (round 738's A2: one skin a body);
## - at most PREP_MAX_RUNNING tasks run; the rest wait their turn;
## - a teardown (wait_prepared(false)) adopts nothing.
##
## - (the review's F1) the readers a task and the main thread share --
##   _fallback_of, the scale tables -- give every thread the right answer
##   while two pool tasks and the main thread call them together.
##
## NEGATIVES: _fallback_of over a `const` Array (as before the review) is
## the heap race the review's stress crashed 18 of 19 times; this case is
## its cheap guard, const_array_lint_test.gd the static one;
## a task given Node.duplicate()'s copy (mesh nodes sharing the
## template's meshes) fails "bones only";
## _finish_prep without _reskin fails "one skin"; _prepare without
## its in-flight test fails "no second task"; _start_queued without the cap
## fails "at most 2 run"; dropping the fallback fails "the plain model";
## template_paths listing every `_r`'s fallback again (as before round 758)
## fails "asks for nothing else".

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
	_test_prepare_adopt_build()
	_test_fallback_only_on_failure()
	_test_shared_skin()
	_test_cap_and_teardown()
	_test_bare_skeleton()
	_test_shared_reads_concurrent()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

## The stand-ins, in a class of their own: the lambdas that call them run on
## worker threads, where a call through the test script's own `self` fails.
class Stand:
	## A body skeleton as an assembled template has it: three bones, one skinned
	## body mesh on the canonical skin.
	static func template(skel_path: String) -> SkinnedBsrAssembler.AssembledCharacter:
		var s := Skeleton3D.new()
		s.add_bone("Bip01")
		s.set_bone_rest(0, Transform3D.IDENTITY)
		s.add_bone("Bip01 Spine")
		s.set_bone_parent(1, 0)
		s.set_bone_rest(1, Transform3D(Basis.IDENTITY, Vector3(0, 10, 0)))
		s.add_bone("Bip01 R Hand")
		s.set_bone_parent(2, 1)
		s.set_bone_rest(2, Transform3D(Basis.IDENTITY, Vector3(3, 0, 0)))
		for i in range(s.get_bone_count()):
			s.reset_bone_pose(i)
		var t := SkinnedBsrAssembler.AssembledCharacter.new()
		t.skeleton = s
		t.canonical_skin = Skeleton3DBuilder.canonical_skin(s)
		t.parsed = BsrReader.ParsedObject.new()
		t.parsed.skeleton_path = skel_path
		var mi := MeshInstance3D.new()
		mi.name = "body_piece"
		# No mesh (round 748's review, F9): this runs on a pool thread, and the
		# headless runner's dummy mesh storage is not thread-safe.
		s.add_child(mi)
		mi.skin = t.canonical_skin
		mi.skeleton = mi.get_path_to(s)
		return t

	## An item as _item_template_on makes one: a holder lifted off a scratch copy
	## of `source`, its mesh on `skin`; null for a path in `fails`.
	static func item(source: Skeleton3D, skin: Skin, path: String, fails: Array, calls: Array, lock: Mutex) -> Array:
		lock.lock()
		calls.append(path.to_lower())
		lock.unlock()
		if fails.has(path.to_lower()):
			return [null, null]
		# In place, as the task's _item_template_on: no Node.duplicate() on a
		# worker thread (its Node3D getters refuse there).
		var scratch := source
		var holder := Node3D.new()
		holder.name = path.get_file().get_basename()
		scratch.add_child(holder)
		var mi := MeshInstance3D.new()
		mi.name = holder.name + "_mesh"
		# No mesh (round 748's review, F9): this runs on a pool thread, and the
		# headless runner's dummy mesh storage is not thread-safe.
		holder.add_child(mi)
		mi.skin = skin
		mi.skeleton = NodePath("../..")
		scratch.remove_child(holder)
		holder.set_meta("bone_count", scratch.get_bone_count())
		return [holder, null]

func _appearance(bodies: Dictionary, fails: Array, calls: Array, body_calls: Array) -> CharacterAppearance:
	var app := CharacterAppearance.new()
	for ref in bodies:
		app.add_body(int(ref), String(bodies[ref][0]))
	var layouts := {}
	for ref in bodies:
		layouts[String(bodies[ref][0])] = String(bodies[ref][1])
	# The stand-ins run on worker threads, two at a time: their logs are
	# appended under a lock.
	var lock := Mutex.new()
	app.body_assembler = func(path: String) -> SkinnedBsrAssembler.AssembledCharacter:
		lock.lock()
		body_calls.append(path)
		lock.unlock()
		return Stand.template(String(layouts[path]))
	app.item_assembler = func(source: Skeleton3D, skin: Skin, path: String) -> Array:
		return Stand.item(source, skin, path, fails, calls, lock)
	app._items[5001] = {"models": PackedStringArray(["item\\chest_a.bsr"]), "type_ids": PackedInt32Array([3, 1, 1, 3]), "code": "ITEM_CHEST"}
	app._items[5004] = {"models": PackedStringArray(["item\\dagger_01.bsr"]), "type_ids": PackedInt32Array([3, 1, 6, 13]), "code": "ITEM_DAGGER"}
	app._full_items_loaded = true
	return app

## The skins of every skinned mesh under `n`.
static func _skins(n: Node) -> Dictionary:
	var out := {}
	for mi in n.find_children("*", "MeshInstance3D", true, false):
		if (mi as MeshInstance3D).skin != null:
			out[(mi as MeshInstance3D).skin] = true
	return out

static func _has_mesh(n: Node, name: String) -> bool:
	for mi in n.find_children("*", "MeshInstance3D", true, false):
		if String(mi.name) == name:
			return true
	return false

func _test_prepare_adopt_build() -> void:
	var calls: Array = []
	var body_calls: Array = []
	# The dagger's _r model does not assemble: its plain model is the fallback.
	var app := _appearance({1907: ["char\\test\\man.bsr", "res\\man.bsk"]}, ["item\\dagger_01_r.bsr"], calls, body_calls)
	var kit := [{"id": 5001, "plus": 0}, {"id": 5004, "plus": 0}]
	var paths: Array = app.template_paths(1907, kit)
	_check(Array(paths[0]) == ["item\\chest_a.bsr", "item\\dagger_01_l.bsr", "item\\dagger_01_r.bsr"],
		"the paths a build hangs: the chest, the dagger's _l and _r -- the _r's fallback only once the _r fails (round 758; got %s)" % str(paths[0]))
	_check(String(paths[2]) == "dagger", "and the dagger's animation group (%s)" % String(paths[2]))
	_check(not app.templates_ready(1907, kit), "a new kind is not ready")
	_check(app.prep_stats["tasks"] == 0, "asking whether it is ready starts nothing")
	_check(not app.prepare(1907, kit) and app.preparing(), "prepare starts its task and answers not ready")
	_check(not app.prepare(1907, kit) and app.prep_stats["tasks"] == 1, "no second task for the body while one runs")
	app.wait_prepared()
	_check(not app.preparing() and app.prep_generation > 0, "the task is adopted (generation %d)" % app.prep_generation)
	_check(body_calls == ["char\\test\\man.bsr"], "the body was assembled once, by the task (%s)" % str(body_calls))
	_check(calls.has("item\\dagger_01.bsr") and calls.has("item\\dagger_01_r.bsr"), "the _r model failed and its plain model was made (%s)" % str(calls))
	_check(app.templates_ready(1907, kit), "after adoption the kind is ready")
	_check(app.prepare(1907, kit) and app.prep_stats["tasks"] == 1, "and asking again starts nothing")
	var before := app.stats.duplicate()
	var made := calls.size()
	var b := app.build(1907, 0x22, kit)
	_check(b != null and calls.size() == made and app.stats["body_assemblies"] == before["body_assemblies"]
		and app.stats["item_assemblies"] == before["item_assemblies"], "build assembles nothing on the main thread")
	if b != null:
		_check(_has_mesh(b, "chest_a_mesh") and _has_mesh(b, "dagger_01_l_mesh") and _has_mesh(b, "dagger_01_mesh"),
			"the body wears the chest, the dagger's _l and the _r's fallback")
		_check(b.weapon_group == "dagger", "and holds the dagger's group (%s)" % b.weapon_group)
		b.free()
	app.free_templates()

## Round 758: the plain fallback is made only when the `_r` fails. A dual axe
## whose _l and _r assemble (as every axe in the archive does, which has no
## plain axe_NN.bsr) never asks for the plain path -- asking logged "item ...
## not found in archive" for every axe and set dagger in the world. A body
## whose template is already cached, then given a dagger whose _r fails, still
## gets the fallback from the task (the second branch of _prepare).
func _test_fallback_only_on_failure() -> void:
	var calls: Array = []
	var body_calls: Array = []
	var app := _appearance({1907: ["char\\test\\man.bsr", "res\\man.bsk"]}, ["item\\dagger_01_r.bsr"], calls, body_calls)
	app._items[5006] = {"models": PackedStringArray(["item\\axe_11.bsr"]), "type_ids": PackedInt32Array([3, 1, 6, 9]), "code": "ITEM_AXE"}
	var axe := [{"id": 5006, "plus": 0}]
	app.prepare(1907, axe)
	app.wait_prepared()
	_check(calls == ["item\\axe_11_l.bsr", "item\\axe_11_r.bsr"], "an axe whose halves assemble asks for nothing else (%s)" % str(calls))
	_check(app.templates_ready(1907, axe), "and is ready")
	var b := app.build(1907, 0x22, axe)
	if b != null:
		_check(Array(b.worn[0]["drawn"]) == ["item\\axe_11_l.bsr", "item\\axe_11_r.bsr"] and b.weapon_group == "dual_axe",
			"the axe draws both halves in the dual-axe group (%s, %s)" % [str(b.worn[0]["drawn"]), b.weapon_group])
		b.free()
	else:
		_check(false, "the axe builds")
	# The body is cached now: a dagger whose _r fails is the second branch.
	calls.clear()
	var dagger := [{"id": 5004, "plus": 0}]
	_check(not app.templates_ready(1907, dagger), "a dagger on the cached body is not ready yet")
	app.prepare(1907, dagger)
	app.wait_prepared()
	_check(calls == ["item\\dagger_01_l.bsr", "item\\dagger_01_r.bsr", "item\\dagger_01.bsr"],
		"its _r failed, so the task made the plain fallback (%s)" % str(calls))
	_check(app.templates_ready(1907, dagger), "and the dagger is ready")
	var d := app.build(1907, 0x22, dagger)
	if d != null:
		_check(Array(d.worn[0]["drawn"]) == ["item\\dagger_01_l.bsr", "item\\dagger_01.bsr"], "the dagger draws _l and the fallback (%s)" % str(d.worn[0]["drawn"]))
		d.free()
	app.free_templates()

func _test_shared_skin() -> void:
	var calls: Array = []
	var body_calls: Array = []
	# Two bodies of one skeleton layout (file and bone count).
	var app := _appearance({1907: ["char\\test\\man_a.bsr", "res\\man.bsk"], 1908: ["char\\test\\man_b.bsr", "res\\man.bsk"]}, [], calls, body_calls)
	var kit := [{"id": 5001, "plus": 0}]
	app.prepare(1907, kit)
	app.wait_prepared()
	app.prepare(1908, kit)
	app.wait_prepared()
	_check(app.templates_ready(1907, kit) and app.templates_ready(1908, kit), "both kinds ready")
	var a := app.build(1907, 0x22, kit)
	var b := app.build(1908, 0x22, kit)
	if a == null or b == null:
		_check(false, "both build")
		return
	var sa := _skins(a)
	var sb := _skins(b)
	_check(sa.size() == 1 and sb.size() == 1 and sa.keys()[0] == sb.keys()[0],
		"one skin a body, the layout's one shared skin on both, items included (%d, %d)" % [sa.size(), sb.size()])
	a.free()
	b.free()
	app.free_templates()

func _test_cap_and_teardown() -> void:
	var calls: Array = []
	var body_calls: Array = []
	var bodies := {}
	for i in 5:
		bodies[2000 + i] = ["char\\test\\b%d.bsr" % i, "res\\b%d.bsk" % i]
	var app := _appearance(bodies, [], calls, body_calls)
	for ref in bodies:
		app.prepare(int(ref), [])
	_check(app._prep_running <= CharacterAppearance.PREP_MAX_RUNNING and app._prep_queue.size() == 5 - app._prep_running,
		"at most %d run; the rest wait their turn (%d running, %d queued)" % [CharacterAppearance.PREP_MAX_RUNNING, app._prep_running, app._prep_queue.size()])
	app.wait_prepared()
	var all := true
	for ref in bodies:
		if not app.templates_ready(int(ref), []):
			all = false
	_check(all and app.prep_stats["tasks"] == 5, "every queued request ran in turn (%d tasks)" % app.prep_stats["tasks"])
	app.free_templates()
	# A teardown: started and queued requests are dropped, nothing adopted.
	var app2 := _appearance(bodies, [], calls, body_calls)
	for ref in bodies:
		app2.prepare(int(ref), [])
	app2.wait_prepared(false)
	_check(not app2.preparing() and app2._body_templates.is_empty() and app2._prep_queue.is_empty(),
		"wait_prepared(false) adopts nothing and leaves no request")

## The task's copy of an existing template's skeleton: its bones only, so
## nothing the task frees shares a mesh (and its signal) with the main thread.
func _test_bare_skeleton() -> void:
	var t := Stand.template("res\\x.bsk")
	var b := CharacterAppearance._bare_skeleton(t.skeleton)
	var same := b.get_bone_count() == t.skeleton.get_bone_count()
	for i in range(mini(b.get_bone_count(), t.skeleton.get_bone_count())):
		if b.get_bone_name(i) != t.skeleton.get_bone_name(i) or b.get_bone_parent(i) != t.skeleton.get_bone_parent(i) \
				or not b.get_bone_rest(i).is_equal_approx(t.skeleton.get_bone_rest(i)):
			same = false
	_check(same and b.get_child_count() == 0, "the task's skeleton copy: the same bones, rests and parents, bones only (%d children)" % b.get_child_count())
	b.free()
	t.skeleton.free()

## The review's F1: the same readers on two pool threads and the main thread
## for a second and a half; every answer checked (a race through a read-only
## Array's shared slot returns the other thread's element, or worse).
func _test_shared_reads_concurrent() -> void:
	var stop := [false]
	var bad := [0, 0]
	var calls := [0, 0]
	var lock := Mutex.new()
	var job := func(slot: int) -> void:
		var n := 0
		var wrong := 0
		while not stop[0]:
			if CharacterAppearance._fallback_of("item\\a_r.bsr") != "item\\a.bsr":
				wrong += 1
			if CharacterAppearance._fallback_of("item\\b_f.BSR") != "item\\b.bsr" or CharacterAppearance._fallback_of("item\\c.bsr") != "":
				wrong += 1
			if not is_equal_approx(CharacterAppearance.height_factor(0x04), 1.06):
				wrong += 1
			if CharacterAppearance.volume_bone_scales(0x42, true).size() != 8:
				wrong += 1
			n += 1
		lock.lock()
		bad[slot] = wrong
		calls[slot] = n
		lock.unlock()
	var t1 := WorkerThreadPool.add_task(job.bind(0))
	var t2 := WorkerThreadPool.add_task(job.bind(1))
	var main_wrong := 0
	var main_calls := 0
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 1500:
		if CharacterAppearance._fallback_of("item\\a_r.bsr") != "item\\a.bsr" or not is_equal_approx(CharacterAppearance.height_factor(0x00), 0.94) \
				or CharacterAppearance.volume_bone_scales(0x02, false).size() != 7:
			main_wrong += 1
		main_calls += 1
	stop[0] = true
	WorkerThreadPool.wait_for_task_completion(t1)
	WorkerThreadPool.wait_for_task_completion(t2)
	_check(bad[0] == 0 and bad[1] == 0 and main_wrong == 0 and calls[0] > 0 and calls[1] > 0,
		"two pool tasks and the main thread read the shared tables together: every answer right (%d + %d + %d calls)" % [calls[0], calls[1], main_calls])
