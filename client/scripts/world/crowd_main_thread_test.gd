extends SceneTree

## Round 757: the main thread's per-frame work in a big crowd made event-driven.
## Run headless on the render box: `client/tools/remote_godot.sh tests`.
## No game data.
##
## Holds:
##   - the eased walk looks only at awake bodies: a move wakes its body, a
##     settled body sleeps, and a target written behind its back is found by
##     the spread re-check within OTHER_WAKE_SCAN_FRAMES frames;
##   - the minimap's other-player signs are written from the moves reported
##     (_other_moved), re-read in a spread, and dropped on a departure;
##   - other players' plates go to NamePlateBatch (their Label3D kept as the
##     record, not drawn), leave it when the body goes, and take the range;
##   - NamePlateBatch shapes a plate as Label3D's glyph quads (an outline pass
##     and a text pass, two triangles a glyph), writes its point, hides a
##     plate whose owner is hidden, reuses a slot, and its shader code carries
##     the 300 rule and the moved billboard origin;
##   - the far bodies' sounds come due from the timing wheel, each at its key,
##     without a pass over every heard body;
##   - EquipFx's candidate pruning keeps every host the cycle's choice can show.
##
## NEGATIVE, on the base (155822c1): _other_awake, _minimap_others_sync,
## NamePlateBatch, _sound_schedule and _prune_candidates do not exist -- the
## suite does not compile.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	await process_frame
	_test_plate_batch_unit()
	_test_prune()
	var world := _make_world()
	if world != null:
		await process_frame
		await _test_awake(world)
		await _test_minimap(world)
		await _test_plates(world)
		_test_sound_wheel(world)
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
		"var advanced: Array = []",
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
		"func _build_assembled_character(_equipped: Dictionary = {}, _body: String = \"\", _scale: int = 0x22, _pluses: Dictionary = {}) -> Skeleton3D:",
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
		"var repeat := false",
		"func _crowd_sound_advance(b: CrowdGpu.Body, t: float) -> void:",
		"\tadvanced.append([b, t])",
		"\tb.sound_due = t + 0.25 if repeat else INF",
		"\tif repeat:",
		"\t\t_sound_schedule(b)",
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

func _spawn(world: Node, ids: Array) -> void:
	var queue = world.get("_other_builds")
	queue.budget_usec = 1 << 30
	var here := _here(world)
	var snaps: Array = []
	for id in ids:
		snaps.append(_snap(int(id), "P%d" % int(id), here + Vector3(float(id) * 3.0, 0, 10)))
	world.call("_spawn_result_others", snaps, [])
	world.call("_pump_other_builds")

func _test_awake(world: Node) -> void:
	_spawn(world, [301, 302, 303])
	var bodies: Dictionary = world.get("_other_bodies")
	var awake: Dictionary = world.get("_other_awake")
	# Settle everyone first.
	for i in range(3):
		world.call("_step_other_bodies", 1.0 / 60.0, 1)
	_check(awake.is_empty(), "a standing crowd is asleep (%d awake)" % awake.size())
	var b1: Node3D = bodies[301]
	var from := b1.position
	world.call("_on_entity_moved", _moved(301, from + Vector3(30, 0, 0)))
	_check(awake.has(301) and awake.size() == 1, "a move wakes its body, and only it")
	world.call("_step_other_bodies", 1.0 / 60.0, 1)
	_check(b1.position.x > from.x, "the woken body walks")
	for i in range(240):
		world.call("_step_other_bodies", 1.0 / 60.0, 1)
	_check(b1.position.is_equal_approx(from + Vector3(30, 0, 0)) and not awake.has(301), "on its target and standing, it sleeps again")
	# A target written by a path that does not wake (behind the set's back).
	var b2: Node3D = bodies[302]
	var t2 := b2.position + Vector3(0, 0, 20)
	(world.get("_other_body_targets") as Dictionary)[302] = t2
	var settled: Dictionary = world.get("_other_settled")
	settled.erase(302)
	var frames := 0
	while not awake.has(302) and frames < 60:
		world.call("_step_other_bodies", 1.0 / 60.0, 1)
		frames += 1
	_check(awake.has(302) and frames <= int(world.get("OTHER_WAKE_SCAN_FRAMES")), "a silent target is found by the spread re-check within %d frames (%d)" % [int(world.get("OTHER_WAKE_SCAN_FRAMES")), frames])

func _test_minimap(world: Node) -> void:
	var mm := HudMinimap.new()
	root.add_child(mm)
	var img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	(mm.get_node("MapClip/Signs") as MinimapSigns).set_texture("other", ImageTexture.create_from_image(img))
	world.set("_hud_minimap", mm)
	var bodies: Dictionary = world.get("_other_bodies")
	for i in range(int(world.get("MINIMAP_RESCAN_FRAMES")) + 1):
		world.call("_minimap_others_sync")
	_check(mm.other_ids().size() == bodies.size(), "every body has a sign within MINIMAP_RESCAN_FRAMES refreshes (%d of %d)" % [mm.other_ids().size(), bodies.size()])
	var b: Node3D = bodies[303]
	b.position += Vector3(77, 0, 0)
	world.call("_other_moved", b)
	world.call("_minimap_others_sync")
	var signs := mm.get_node("MapClip/Signs") as MinimapSigns
	var k: MinimapSigns.Kind = signs._kinds["other"]
	var slot: int = k.slot_of[303]
	_check(is_equal_approx(k.buf[slot * MinimapSigns.FLOATS + 8], b.global_position.x), "a reported move is written at the next refresh")
	world.call("_on_entity_left", 303)
	_check(not mm.other_ids().has(303), "a departure drops its sign at once")
	world.set("_hud_minimap", null)
	mm.queue_free()

func _test_plates(world: Node) -> void:
	if not NamePlateBatch.new().ok:
		_check(false, "the batch is available")
		return
	_spawn(world, [311])
	var bodies: Dictionary = world.get("_other_bodies")
	var body: Node3D = bodies[311]
	var label := body.get_node_or_null("Name") as Label3D
	var batch: NamePlateBatch = world.get("_plate_batch")
	_check(label != null and not label.visible, "the plate's Label3D is kept as its record and not drawn")
	_check(batch != null and batch.has(label), "the plate is drawn by the batch")
	var sweep: NamePlates.Sweep = world.get("_plate_sweep")
	_check(sweep._plates.find(label) < 0 and sweep._fresh.find(label) < 0, "and not swept (the shader applies the 300 rule)")
	world.call("set_name_plate_range", 120.0)
	_check(is_equal_approx(batch.range, 120.0), "the debug slider's range reaches the batch")
	world.call("set_name_plate_range", NamePlates.RANGE)
	world.call("_plate_batch_switch", false)
	_check(not batch.has(label) and sweep.size() > 0, "the QA switch hands it back to the sweep")
	world.call("_plate_batch_switch", true)
	_check(batch.has(label), "and to the batch again")
	# The review's F4: V hides other players' plates in the same frame.
	# (Round 762: a new plate is shown once its chunk is rebuilt; flush paces
	# the rebuilds, flush_all does them now.)
	batch.flush_all(Vector3.ZERO)
	world.call("_plate_batch_step")
	var slot: int = (batch._plates[label] as NamePlateBatch.Plate).slot
	_check(batch._anchors[slot * 4 + 3] > -1.0e8, "the plate is shown before V")
	world.call("_show_bodies", world.get("_other_bodies"), false, true)
	world.call("_plate_batch_step")
	_check(batch._anchors[slot * 4 + 3] < -1.0e8, "V hides the batched plate in the same frame")
	world.call("_show_bodies", world.get("_other_bodies"), true, true)
	world.call("_plate_batch_step")
	_check(batch._anchors[slot * 4 + 3] > -1.0e8, "and releasing it shows it again in the same frame")
	var before := batch.size()
	body.queue_free()
	(world.get("_other_bodies") as Dictionary).erase(311)
	await process_frame
	_check(batch.size() == before - 1, "a plate leaves the batch with its body (%d -> %d)" % [before, batch.size()])

func _test_plate_batch_unit() -> void:
	var batch := NamePlateBatch.new()
	_check(batch.ok, "the batch starts")
	var code := NamePlateBatch.shader_code(false, BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS)
	_check(code.contains("render_mode blend_mix,depth_draw_opaque,cull_disabled,diffuse_burley,specular_schlick_ggx,unshaded,depth_test_disabled;"), "the material's render modes are Label3D's (get_material_for_2d's)")
	_check(code.contains("vec4(plate_point, 1.0)") and not code.contains("MODEL_MATRIX[3]);"), "the billboard turns about the plate's point, not the instance's origin")
	_check(code.contains("distance(plate_a.xyz, plate_player) >= plate_range"), "the 300 rule is the shader's: hidden at the range itself")
	_check(code.contains("float sc = -(MODELVIEW_MATRIX)[3].z;"), "fixed size, as BaseMaterial3D writes it")
	var holder := Node3D.new()
	root.add_child(holder)
	var owner := Node3D.new()
	owner.position = Vector3(10, 2, -5)
	holder.add_child(owner)
	var label := Label3D.new()
	label.text = "Abc"
	label.position = Vector3(0, 18, 0)
	label.pixel_size = 0.0004
	label.fixed_size = true
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.outline_size = 8
	label.outline_modulate = Color(0, 0, 0, 0.85)
	owner.add_child(label)
	_check(batch.add(label, owner), "a plate is added")
	var p: NamePlateBatch.Plate = batch._plates[label]
	var outline_verts := 0
	var text_verts := 0
	for key in p.parts:
		var n := (p.parts[key][0] as PackedVector3Array).size()
		if String(key).split("|")[1] == "1":
			outline_verts += n
		else:
			text_verts += n
	_check(int(batch.stats["glyphs"]) == 6, "three glyphs shaped in an outline pass and a text pass (%d)" % int(batch.stats["glyphs"]))
	# Round 762: a new plate's anchor stays hidden until its chunk is rebuilt
	# (its slot may still hold another plate's glyphs).
	_check(batch._anchors[p.slot * 4 + 3] < -1.0e8, "round 762: a new plate is hidden until its chunk's rebuild")
	batch.flush_all(Vector3.ZERO)
	# The headless renderer makes no glyph textures, and a glyph without one
	# draws nothing (as Label3D's _generate_glyph_surfaces skips it); with
	# textures each glyph is two triangles.
	_check((text_verts == 18 and outline_verts == 18) or (text_verts == 0 and outline_verts == 0 and DisplayServer.get_name() == "headless"),
		"each glyph with a texture is two triangles (%d, %d vertices)" % [outline_verts, text_verts])
	var o := p.slot * 4
	_check(Vector3(batch._anchors[o], batch._anchors[o + 1], batch._anchors[o + 2]).is_equal_approx(owner.global_position) and batch._anchors[o + 3] == 18.0,
		"its point is the owner's place and the label's height")
	owner.visible = false
	batch.moved(label)
	_check(batch._anchors[o + 3] < -1.0e8, "a hidden owner's plate is hidden")
	owner.visible = true
	batch.moved(label)
	batch.remove(label)
	_check(batch._anchors[o + 3] < -1.0e8 and not batch.has(label), "a removed plate is hidden")
	var other := Label3D.new()
	other.text = "B"
	owner.add_child(other)
	batch.add(other, owner)
	_check((batch._plates[other] as NamePlateBatch.Plate).slot == p.slot, "and its slot is used again")
	_check(batch._anchors[o + 3] < -1.0e8, "round 762: ... hidden until the rebuild (the old plate's glyphs are still in the mesh)")
	batch.flush(Vector3.ZERO)
	_check(batch._anchors[o + 3] < -1.0e8, "round 762: ... a chunk added to this frame waits (REBUILD_SETTLE)")
	batch.flush_all(Vector3.ZERO)
	_check(batch._anchors[o + 3] == 18.0 or is_equal_approx(batch._anchors[o + 3], other.position.y), "round 762: ... and shown once rebuilt")
	# The glyph quads and the chunk's join keep what is appended (round 757's
	# first build grew copies of its packed arrays and drew nothing).
	var part := [PackedVector3Array(), PackedVector2Array(), PackedColorArray(), PackedVector2Array()]
	var six := PackedVector3Array([Vector3.ZERO, Vector3.ONE, Vector3.UP, Vector3.ZERO, Vector3.UP, Vector3.RIGHT])
	var uv6 := PackedVector2Array([Vector2.ZERO, Vector2.ONE, Vector2.UP, Vector2.ZERO, Vector2.UP, Vector2.RIGHT])
	NamePlateBatch.append_quad(part, six, uv6, Color.RED, 5)
	NamePlateBatch.append_quad(part, six, uv6, Color.RED, 5)
	_check((part[0] as PackedVector3Array).size() == 12 and (part[2] as PackedColorArray).size() == 12 and (part[3] as PackedVector2Array)[11] == Vector2(5, 0),
		"two glyph quads are 12 vertices, colours and slots in the part (%d)" % (part[0] as PackedVector3Array).size())
	var joined := NamePlateBatch.concat([part, part])
	_check((joined[0] as PackedVector3Array).size() == 24 and (joined[1] as PackedVector2Array).size() == 24, "and a chunk joins its plates' parts (%d)" % (joined[0] as PackedVector3Array).size())
	holder.queue_free()

func _test_sound_wheel(world: Node) -> void:
	var crowd := CrowdGpu.new()
	world.set("_crowd_gpu", crowd)
	world.set("_idle_anim_time", 10.0)
	world.set("_sound_wheel_at", -1)
	(world.get("_sound_wheel") as Dictionary).clear()
	var advanced: Array = world.get("advanced")
	advanced.clear()
	var due := [10.05, 10.3, 10.3, 11.0]
	var made: Array = []
	var skels: Array = []
	for d in due:
		var b := CrowdGpu.Body.new()
		b.skel = Skeleton3D.new()
		skels.append(b.skel)
		b.heard = true
		b.sound_due = d
		made.append(b)
		crowd._bodies[b.skel] = b
		world.call("_sound_schedule", b)
	crowd._heard_dirty = true
	# The spread re-check is kept busy on bodies out of hearing, so only the
	# wheel can bring the four in.
	var decoys: Array = []
	for i in range(3000):
		decoys.append(CrowdGpu.Body.new())
	var t := 10.0
	var fired_at := {}
	for f in range(80):
		t += 1.0 / 60.0
		world.set("_idle_anim_time", t)
		world.set("_sound_ring", decoys)
		world.set("_sound_ring_at", 0)
		world.call("_crowd_sound_step")
		for e in advanced:
			if not fired_at.has(e[0]):
				fired_at[e[0]] = e[1]
	var ok := true
	for i in range(made.size()):
		var at = fired_at.get(made[i])
		if at == null or float(at) < due[i] or float(at) > due[i] + 1.0 / 60.0 + 1e-6:
			ok = false
	_check(ok and advanced.size() == 4, "each far body's sound fires in the first frame at or after its key, from the wheel alone (%d advances)" % advanced.size())
	# The review's F1: a far body brought near (CrowdGpu.remove, as _crowd_wake
	# does) never advances from the wheel again, though it was filed and its
	# advances reschedule it; nor does a record a later switch replaced.
	world.set("repeat", true)
	advanced.clear()
	var woken := CrowdGpu.Body.new()
	woken.skel = Skeleton3D.new()
	woken.heard = true
	woken.sound_due = t + 0.05
	crowd._bodies[woken.skel] = woken
	world.call("_sound_schedule", woken)
	var replaced := CrowdGpu.Body.new()
	replaced.skel = Skeleton3D.new()
	replaced.heard = true
	replaced.sound_due = t + 0.05
	crowd._bodies[replaced.skel] = replaced
	world.call("_sound_schedule", replaced)
	var live := CrowdGpu.Body.new()
	live.skel = Skeleton3D.new()
	live.heard = true
	live.sound_due = t + 0.05
	crowd._bodies[live.skel] = live
	world.call("_sound_schedule", live)
	# One frame past the key: each fires once and is filed again.
	for f in range(6):
		t += 1.0 / 60.0
		world.set("_idle_anim_time", t)
		world.set("_sound_ring", decoys)
		world.set("_sound_ring_at", 0)
		world.call("_crowd_sound_step")
	var fired_before := advanced.size()
	crowd.remove(woken.skel)
	var newer := CrowdGpu.Body.new()
	newer.skel = replaced.skel
	crowd._bodies[replaced.skel] = newer
	_check(not woken.heard and woken.sound_due == INF, "CrowdGpu.remove takes the body off the far sounds (heard %s, due %s)" % [woken.heard, woken.sound_due])
	advanced.clear()
	for f in range(120):
		t += 1.0 / 60.0
		world.set("_idle_anim_time", t)
		world.set("_sound_ring", [woken, replaced, live])
		world.set("_sound_ring_at", 0)
		world.call("_crowd_sound_step")
	var by := {}
	for e in advanced:
		by[e[0]] = int(by.get(e[0], 0)) + 1
	_check(fired_before == 3 and not by.has(woken) and not by.has(replaced) and int(by.get(live, 0)) >= 6,
		"a woken body and a replaced record never advance again, the live one goes on (woken %d, replaced %d, live %d)" % [int(by.get(woken, 0)), int(by.get(replaced, 0)), int(by.get(live, 0))])
	world.set("repeat", false)
	for sk in skels + [woken.skel, replaced.skel, live.skel]:
		if is_instance_valid(sk):
			(sk as Node).free()
	world.set("_crowd_gpu", null)

func _test_prune() -> void:
	var fx := EquipFx.new()
	# 400 hosts on 200 weapons (two each), the weapons 1..200 units away.
	var hosts: Array = []
	var dists := PackedFloat32Array()
	for w in range(200):
		var skel := Skeleton3D.new()
		for k in range(2):
			var h := EquipFx.Host.new()
			h.skel = skel
			hosts.append(h)
			dists.append(float(200 - w))
	fx._cand = hosts
	fx._cand_d = dists
	fx._prune_candidates()
	var kept := {}
	var whole := true
	for i in fx._cand.size():
		kept[(fx._cand[i] as EquipFx.Host).skel] = int(kept.get((fx._cand[i] as EquipFx.Host).skel, 0)) + 1
	for s in kept:
		if int(kept[s]) != 2:
			whole = false
	var far := 0.0
	for d in fx._cand_d:
		far = maxf(far, d)
	_check(fx._cand.size() >= EquipFx.VISIBLE_BUDGET and whole, "pruning keeps at least the %d nearest hosts and never half a weapon (%d kept)" % [EquipFx.VISIBLE_BUDGET, fx._cand.size()])
	_check(far <= 32.0, "and drops every host past the %d-th nearest (farthest kept %.0f)" % [EquipFx.VISIBLE_BUDGET, far])
	for h in hosts:
		if is_instance_valid((h as EquipFx.Host).skel):
			(h as EquipFx.Host).skel.free()
	fx.free()
