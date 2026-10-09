extends SceneTree

## Round 756: an arriving crowd drawn at once (docs/rounds/r756.md). On
## synthetic templates (never game data); headless on the render box:
## `client/tools/remote_godot.sh tests`.
##
## What it holds:
## - CharacterAppearance.far_recipe names what build() draws: the far parts
##   CrowdGpu reads off the recipe (the template meshes, the hidden body piece
##   left out, the Volume variant, a hung rigid item) are the parts it reads
##   off the built body -- the same meshes, twins, Volume rows, centres; the
##   recipe's Height and layout are the built skeleton's;
## - SkinnedBsrAssembler.hidden_body_nodes hides what apply_body_hides hides;
## - in a quiet World3D: an arrival is a ghost the frame it comes (instances,
##   its name plate and click body), fading in on the GPU from alpha 0 (the
##   start in its instances' custom data) and moving to the shared groups when
##   the fade ends;
## - dressing a ghost hands its clip entry (clip, phase) to the built
##   skeleton in the same call, without a second plate or click body; far at
##   once when it is past the near set, near and posed when within it;
## - a ghost's gait swaps its loop on the GPU when baked, and dresses it
##   first when not; a hit dresses it; a departure fades it out on the GPU;
##   its light takes the level's material; an equipment change draws it in
##   its new kind;
## - OtherCrowd.BuildQueue dresses a body nobody sees before a ghost.
## - round 762's review: a ghost's weapon particles from its recipe, placed
##   from its GPU clip frame (the dressed far body's frame), within 720 only
##   (F1); a body that arrived with buffs, or got one held, is dressed first
##   once its page shows (F2); a zone change resets the held pages, and a
##   deadline reveal drops a waiting arrival whose body is gone (F3); a group
##   a few seconds after the page opened opens its own (F6).
##
## NEGATIVES (by hand): far_recipe without the hides fails "the chest hides
## Body1"; _ghost_handover appending a fresh entry fails "the same phase";
## add_ghost with fade=false everywhere fails "fades in from 0".

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	# Round 762: the crowd's frame budget left whole for every call here.
	OtherCrowd.FrameBudget.unlimited = true
	var watchdog := create_timer(120.0)
	watchdog.timeout.connect(func() -> void:
		print("FAIL the suite never reported (a script error stopped it)")
		quit(1))
	await process_frame
	_test_queue_later()
	_test_hides()
	var app := _app()
	_test_recipe_parity(app)
	var world := _make_world()
	if world != null:
		await process_frame
		await _test_world(world, app)
		root.remove_child(world)
		world.free()
	app.free_templates()
	CrowdGpu.enabled = true
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

# --- fixtures -----------------------------------------------------------------------

const BODY := "char\\test\\man.bsr"
const CHEST := "item\\test_chest.bsr"
const SWORD := "item\\test_sword.bsr"

var _mat: ShaderMaterial = null

func _body_skeleton() -> Skeleton3D:
	var s := Skeleton3D.new()
	s.add_bone("Bip01")
	s.set_bone_rest(0, Transform3D(Basis(Vector3.UP, 0.3), Vector3(0, 1, 0)))
	s.add_bone("Bip01 Spine")
	s.set_bone_parent(1, 0)
	s.set_bone_rest(1, Transform3D(Basis(Vector3(0, 0, 1), PI / 2.0), Vector3(0, 10, 0)))
	s.add_bone("Bip01 L Thigh")
	s.set_bone_parent(2, 0)
	s.set_bone_rest(2, Transform3D(Basis(Vector3(1, 0, 0), PI), Vector3(2, 8, 0)))
	s.add_bone("Bip01 L Calf")
	s.set_bone_parent(3, 2)
	s.set_bone_rest(3, Transform3D(Basis(Vector3(0, 0, 1), 0.2), Vector3(0, 6, 0)))
	for i in range(s.get_bone_count()):
		s.reset_bone_pose(i)
	Skeleton3DBuilder._object_space_bone(s)
	s.force_update_all_bone_transforms()
	return s

func _parsed_mesh(bones: PackedStringArray, lift: float) -> BmsReader.ParsedMesh:
	var m := BmsReader.ParsedMesh.new()
	m.bone_names = bones
	var verts: Array[BmsReader.Vertex] = []
	for p in [Vector3(2, 3 + lift, 0), Vector3(0, 12 + lift, 1), Vector3(1, 9 + lift, 0.5)]:
		var v := BmsReader.Vertex.new()
		v.position = p
		v.normal = Vector3.UP
		v.bone0 = 0
		v.bone1 = -1
		v.weight0 = 1.0
		verts.append(v)
	m.vertices = verts
	m.indices = PackedInt32Array([0, 1, 2])
	return m

## A piece skinned to `skel` on its shared skin, as the assembler leaves one.
func _skinned_piece(skel: Skeleton3D, shared: Skin, name: String, bone: String, lift: float, parent: Node) -> MeshInstance3D:
	var m := _parsed_mesh(PackedStringArray([bone]), lift)
	var palette := Skeleton3DBuilder.build_skin(skel, m.bone_names, false)
	var mi := MeshInstance3D.new()
	mi.name = name
	mi.mesh = Skeleton3DBuilder.canonical_mesh(m, palette)
	mi.material_override = _mat
	parent.add_child(mi)
	mi.skin = shared
	return mi

func _clip(name: String, duration: int) -> BanReader.ParsedAnimation:
	var clip := BanReader.ParsedAnimation.new()
	clip.animation_name = name
	clip.duration_ms = duration
	clip.cyclic = true
	clip.key_times = PackedInt32Array([0, duration / 2])
	for b in ["Bip01", "Bip01 Spine"]:
		var track := BanReader.Bone.new()
		track.bone_name = b
		for k in range(2):
			var kf := BanReader.Keyframe.new()
			kf.rotation = Quaternion(Vector3.UP, 0.2 * float(k))
			kf.position = Vector3(0, 1 if b == "Bip01" else 10, 0)
			track.keyframes.append(kf)
		clip.bones.append(track)
	return clip

## A synthetic appearance with the body's template and two item templates
## installed as prepare() would leave them: a chest skinned to the body that
## hides its Body1 piece, a sword hung from the spine on its own skeleton.
func _app() -> CharacterAppearance:
	_mat = ShaderMaterial.new()
	_mat.shader = ObjectLoader.OBJECT_SHADER
	var app := CharacterAppearance.new()
	app.canonical = true
	app.add_body(1907, BODY)
	var t := SkinnedBsrAssembler.AssembledCharacter.new()
	var s := _body_skeleton()
	t.skeleton = s
	t.canonical_skin = Skeleton3DBuilder.canonical_skin(s)
	CharacterAppearance._mark_canonical(t.canonical_skin)
	t.parsed = BsrReader.ParsedObject.new()
	t.parsed.skeleton_path = "res\\test.bsk"
	t.parsed.is_character = true
	t.parsed.animation_paths = ["t\\man_standcity.ban", "t\\man_runforward.ban", "t\\man_a_benormalhit.ban"]
	var body_block := BsrReader.Attachable.new()
	body_block.entries = [[7, 1]]
	t.parsed.attachable = body_block
	t.animation_cache["t\\man_standcity.ban"] = _clip("stand", 1000)
	t.animation_cache["t\\man_runforward.ban"] = _clip("run", 700)
	var hit := _clip("hit", 400)
	hit.cyclic = false
	t.animation_cache["t\\man_a_benormalhit.ban"] = hit
	for k in range(2):
		var mi := _skinned_piece(s, t.canonical_skin, "Body%d" % k, "Bip01 Spine", float(k), s)
		mi.skeleton = mi.get_path_to(s)
		mi.set_meta(SkinnedBsrAssembler.BODY_MESH_META, k)
	app._body_templates[BODY] = t
	# The chest: a holder with a piece on the body's shared skin.
	var holder := Node3D.new()
	holder.name = "test_chest"
	s.add_child(holder)
	var cm := _skinned_piece(s, t.canonical_skin, "chest_mesh", "Bip01 Spine", 3.0, holder)
	cm.skeleton = cm.get_path_to(s)
	s.remove_child(holder)
	holder.set_meta("bone_count", s.get_bone_count())
	var chest_block := BsrReader.Attachable.new()
	chest_block.flag = BsrReader.HIDE_FLAG
	chest_block.entries = [[7, 0]]
	app._item_templates[CharacterAppearance._item_key(t, BODY, CHEST)] = holder
	app._item_attachables[CHEST.to_lower()] = chest_block
	# The sword: a BoneAttachment3D on the spine, its own skeleton, a rigid mesh.
	var att := BoneAttachment3D.new()
	att.name = "test_sword@Bip01 Spine"
	att.bone_name = "Bip01 Spine"
	var isk := Skeleton3D.new()
	isk.name = "test_sword"
	isk.add_bone("Bone01")
	isk.transform = Transform3D(Basis(Vector3.UP, 0.4), Vector3(0.3, 0.2, 0.1))
	att.add_child(isk)
	var blade := MeshInstance3D.new()
	blade.name = "blade"
	blade.mesh = BoxMesh.new()
	blade.position = Vector3(0.0, 1.5, 0.5)
	blade.material_override = _mat
	isk.add_child(blade)
	att.set_meta("bone_count", s.get_bone_count())
	app._item_templates[CharacterAppearance._item_key(t, BODY, SWORD)] = att
	app._items[5001] = {"models": PackedStringArray([CHEST]), "type_ids": PackedInt32Array([3, 1, 1, 3]), "code": "ITEM_TEST_CHEST"}
	app._items[5004] = {"models": PackedStringArray([SWORD]), "type_ids": PackedInt32Array([3, 1, 6, 2]), "code": "ITEM_TEST_SWORD"}
	app._full_items_loaded = true
	return app

# --- units --------------------------------------------------------------------------

func _test_queue_later() -> void:
	var q := OtherCrowd.BuildQueue.new()
	var bodies := {}
	for k in range(3):
		var n := Node3D.new()
		n.position = Vector3(0, 0, 10.0 * float(k + 1))
		bodies[k] = n
		q.queue(k)
	var order: Array = []
	q.pump(1, Vector3.ZERO, bodies, func(id: int) -> void: order.append(id), Callable(), {0: true, 1: true})
	_check(order == [2, 0, 1], "a body nobody sees is dressed before the ghosts, then the ghosts nearest first (%s)" % str(order))
	for k in bodies:
		(bodies[k] as Node).free()

func _test_hides() -> void:
	var s := _body_skeleton()
	for k in range(3):
		var mi := MeshInstance3D.new()
		mi.set_meta(SkinnedBsrAssembler.BODY_MESH_META, k)
		s.add_child(mi)
	var twin := MeshInstance3D.new()
	twin.set_meta(SkinnedBsrAssembler.BODY_MESH_META, 2)
	s.add_child(twin)
	var body := BsrReader.ParsedObject.new()
	body.attachable = BsrReader.Attachable.new()
	body.attachable.entries = [[7, 2], [8, 0], [9, 2]]
	var item := BsrReader.Attachable.new()
	item.flag = BsrReader.HIDE_FLAG
	item.entries = [[7, 0], [9, 0]]
	var got := SkinnedBsrAssembler.hidden_body_nodes(s, body, [item])
	var n := SkinnedBsrAssembler.apply_body_hides(s, body, [item])
	var same := true
	for c in s.get_children():
		same = same and ((c as Node3D).visible != (got[0] as Dictionary).has(c))
	_check(same and n == int(got[1]) and n == 1, "hidden_body_nodes hides what apply_body_hides hides, one mesh and its twin counted once (%d)" % n)
	s.free()

## The far parts of the recipe against those of the built body.
func _test_recipe_parity(app: CharacterAppearance) -> void:
	var holder := Node3D.new()
	root.add_child(holder)
	var crowd := CrowdGpu.new(root.find_world_3d().scenario)
	var kit := [{"id": 5001, "plus": 0}, {"id": 5004, "plus": 0}]
	for scale in [0x22, 0x44]:
		var r := app.far_recipe(1907, scale, kit)
		_check(r != null, "a recipe for the kind at scale 0x%02x" % scale)
		if r == null:
			continue
		_check(r.hidden_body_meshes == 1, "the chest hides Body1 in the recipe too")
		var b := app.build(1907, scale, kit)
		var skel := b.skeleton
		b.remove_child(skel)
		skel.scale = b.scale
		var height := b.height_factor
		b.free()
		skel.rotation.y = PI
		holder.add_child(skel)
		_check(is_equal_approx(r.height, height) and r.layout_key == String(skel.get_meta(MonsterCrowd.META_LAYOUT)),
			"the recipe's Height (%.2f) and layout (%s) are the built body's" % [r.height, r.layout_key])
		var l := crowd._layout_for(skel)
		var built = crowd._parts_of(skel, l)
		var geo = crowd._recipe_geometry(r)
		_check(built != null and geo != null, "both are drawable far")
		if built == null or geo == null:
			continue
		var a := PackedStringArray()
		for p in built:
			a.append(_part_sig(p))
		var c := PackedStringArray()
		for g in crowd._lit_parts(r, (geo as Array)[0], -1.0):
			var q: Dictionary = (g as Dictionary).duplicate()
			q["material"] = crowd._twin(g["lit"], (geo as Array)[0])
			c.append(_part_sig(q))
		a.sort()
		c.sort()
		_check(a.size() == 3 and a == c, "scale 0x%02x: the recipe's parts are the built body's (%s | %s)" % [scale, ", ".join(a), ", ".join(c)])
		if scale == 0x44:
			var vol := false
			for g in (geo as Array)[1]:
				vol = vol or int(g[0]["vol"]) >= 0
			_check(vol, "a Volume variant draws through its row")
		skel.free()
	_check(app.far_recipe(1907, 0x22, kit) == app.far_recipe(1907, 0x22, kit) and int(app.far_stats["hits"]) >= 1, "the recipe is made once per kind")
	_check(app.far_recipe(1907, 0x22, [{"id": 5009, "plus": 0}]) != null, "an item no table holds is skipped, as build() skips it")
	crowd.release_all()
	holder.free()

static func _part_sig(p: Dictionary) -> String:
	return "%d/%d/%d/%.4f/%d/%.3f" % [(p["mesh"] as Mesh).get_instance_id(), (p["material"] as Material).get_instance_id(), int(p["vol"]),
		float(p["centre"]), int(p["layers"]), float(p["sort"])]

# --- the world ----------------------------------------------------------------------

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
	root.add_child(world)
	return world

## The clip clock on by `secs` and CrowdGpu's frame (its fades end there).
func _advance(world: Node, crowd: CrowdGpu, secs: float) -> void:
	var t: float = float(world.get("_idle_anim_time")) + secs
	world.set("_idle_anim_time", t)
	crowd.flush(t)

static func _count(n: Node, type: String) -> int:
	var k := 0
	for c in n.get_children():
		if c.is_class(type):
			k += 1
	return k

func _ghost(world: Node, id: int, at: Vector3, equipped: Dictionary) -> Node3D:
	world.set("_other_build_defer", 1)
	world.call("_spawn_or_update_other", id, "Ghost%d" % id, at, equipped, "CHAR_TEST_MAN")
	world.set("_other_build_defer", 0)
	world.call("_ghost_other", id)
	return (world.get("_other_bodies") as Dictionary).get(id)

func _test_world(world: Node, app: CharacterAppearance) -> void:
	CrowdGpu.near_count = 16
	# Round 762: these cases make each ghost by hand; the page hold has its own
	# case (_test_hold).
	world.set("_holds_on", false)
	var cam := Camera3D.new()
	world.add_child(cam)
	cam.global_position = Vector3(0.0, 5.0, 0.0)
	cam.look_at(Vector3(0.0, 5.0, -100.0))
	cam.far = 4000.0
	cam.make_current()
	world.set("_appearance", app)
	(world.get("_body_id_by_code") as Dictionary)["CHAR_TEST_MAN"] = 1907
	(world.get("_item_models") as Dictionary)[5001] = PackedStringArray([CHEST])
	(world.get("_item_models") as Dictionary)[5004] = PackedStringArray([SWORD])
	(world.get("_item_kinds") as Dictionary)[5004] = 2
	var player := world.get("player") as Node3D
	if player != null:
		player.global_position = Vector3.ZERO
	var kit := {EquipmentNet.SLOT_MAIL: 5001, EquipmentNet.SLOT_WEAPON: 5004}
	var crowd: CrowdGpu = world.call("_crowd_gpu_get")
	var gaits: Dictionary = world.get("_other_gaits")
	var t0: float = world.get("_idle_anim_time")
	# The stand loop bakes first (a ghost waits on it, queued again).
	var n601 := _ghost(world, 601, Vector3(0, 0, -80), kit)
	_check(n601 != null and not crowd.is_ghost(n601) and (world.get("_other_ghosts") as OtherCrowd.BuildQueue).has(601),
		"a ghost whose loop is not baked waits, queued again")
	# Round 762: with nobody dressed and no far body yet, the crowd's frame
	# still runs while an arrival waits on its clip (it bakes in the flush);
	# it stopped there and a held page waited for ever.
	var f0: int = crowd._frame
	var gaits0: Dictionary = world.get("_other_gaits")
	world.set("_other_gaits", {})
	world.call("_crowd_gpu_step")
	world.set("_other_gaits", gaits0)
	_check(crowd.body_count() > 0 or crowd._frame == f0 + 1, "round 762: the crowd's flush runs while an arrival waits to be a ghost")
	crowd.bake_all()
	world.call("_ghost_other", 601)
	_check(crowd.is_ghost(n601) and crowd.ghost_count() == 1, "an arrival is a ghost once its loop is baked")
	_check(_count(n601, "Label3D") == 1 and _count(n601, "StaticBody3D") == 1, "... with its name plate and click body")
	crowd.flush(t0)
	var b: CrowdGpu.Body = crowd.body_of(n601)
	_check(b != null and b.parts.size() == 3 and int(crowd.stats["instances"]) == 3, "its three parts are instances (%d)" % int(crowd.stats["instances"]))
	_check(is_zero_approx(crowd.fade_elapsed(n601)) and _fading_rec(crowd, b.parts[0]),
		"it fades in from 0, drawn by its groups' fade instances")
	var w: float = crowd._body_data[b.slot * CrowdGpu.FLOATS_PER_BODY + 17]
	_check(is_equal_approx(w, CrowdGpu.FADE_CODE + (t0 - crowd._epoch) * 1000.0),
		"round 762: its texel carries the fade's start for the shader's alpha (%.1f)" % w)
	var g0: CrowdGpu.Group = (b.parts[0] as Array)[0]
	_check(g0.n_fade == 1 and g0.fade_inst.is_valid() and g0.shown_f and not g0.shown_o,
		"round 762: its group draws it from its fade instance, the opaque one hidden (no other body in it)")
	var phase := float(b.entry[3])
	# The gait with its run not baked (a new run clip): never dressed for it
	# (review F3); it keeps its loop, and runs on the GPU once the clip is up.
	var tmpl: SkinnedBsrAssembler.AssembledCharacter = app._body_templates[BODY]
	tmpl.animation_cache["t\\man_runforward.ban"] = _clip("run", 650)
	var n603 := _ghost(world, 603, Vector3(0, 0, -90), kit)
	var waits_before := (world.get("_ghost_gait_wait") as Dictionary).size()
	world.call("_set_other_gait", 603, true)
	_check(crowd.is_ghost(n603) and not gaits.has(603) and (world.get("_ghost_gait_wait") as Dictionary).has(603)
		and String((crowd.entry_of(n603)[1] as BanReader.ParsedAnimation).animation_name) == "stand",
		"a ghost starting a loop that is not baked stays a ghost on its loop, waiting (%d waiting before)" % waits_before)
	crowd.bake_all()
	world.call("_retry_ghost_gaits")
	_check(crowd.is_ghost(n603) and String((crowd.entry_of(n603)[1] as BanReader.ParsedAnimation).animation_name) == "run"
		and not (world.get("_ghost_gait_wait") as Dictionary).has(603), "... and runs on the GPU once its clip is up")
	# An aura does not dress a ghost (review F1): it goes first in the dressing.
	var owner_body = world.call("_fx_owner_body", 603, SkillNet.OWNER_CHARACTER)
	var builds: OtherCrowd.BuildQueue = world.get("_other_builds")
	_check(owner_body == null and crowd.is_ghost(n603) and builds.urgent.has(603),
		"a buff on a ghost leaves it a ghost, first in the dressing queue")
	var first: Array = []
	builds.budget_usec = 0
	builds.pump(Engine.get_process_frames() + 1000, Vector3.ZERO, world.get("_other_bodies"), func(id: int) -> void: first.append(id), Callable(), world.get("_ghost_ids"))
	builds.budget_usec = OtherCrowd.BUILD_BUDGET_USEC
	_check(first == [603], "... and is the next dressed (%s)" % str(first))
	(world.get("_other_build_args") as Dictionary)[603] = {"equipped": kit, "scale": CharacterAppearance.DEFAULT_SCALE}
	builds.queue(603)
	world.call("_dress_ghost_now", 603)
	var g603: Dictionary = gaits.get(603, {})
	_check(not g603.is_empty() and bool(g603.get("moving", false)), "dressed walking, it runs")
	# Dressed far: the near set's line is nearer than it.
	_advance(world, crowd, 2.1)
	_check(crowd.fade_elapsed(n601) < 0.0 and not _fading_rec(crowd, b.parts[0]),
		"when the fade ends its parts move to the shared groups")
	world.set("_crowd_come", 10.0)
	world.call("_dress_ghost_now", 601)
	var g601: Dictionary = gaits.get(601, {})
	var skel: Skeleton3D = g601.get("skeleton")
	_check(skel != null and crowd.has(skel) and not crowd.is_ghost(n601), "dressed past the near set, it is drawn far from its skeleton at once")
	_check(skel != null and is_equal_approx(float(crowd.entry_of(skel)[3]), phase) and crowd.entry_of(skel)[0] == skel,
		"... with the ghost's clip entry: the same phase")
	_check(_count(n601, "Label3D") == 1 and _count(n601, "StaticBody3D") == 1, "... and no second plate or click body")
	var plate: Label3D = n601.get_node("Name")
	var want_y: float = float(world.call("_skeleton_top", skel)) * (1.0 + world.NAME_PLATE_CLEARANCE_FRACTION) if skel != null else -1.0
	_check(skel != null and is_equal_approx(plate.position.y, want_y), "... its plate re-placed over the built body (%.3f, %.3f)" % [plate.position.y, want_y])
	# Dressed near: within the line, posed on the full path, fading on.
	var n602 := _ghost(world, 602, Vector3(0, 0, -5), kit)
	_advance(world, crowd, 0.5)
	world.call("_dress_ghost_now", 602)
	var s602: Skeleton3D = (gaits.get(602, {}) as Dictionary).get("skeleton")
	var in_tick := false
	for e in world.get("_animated"):
		in_tick = in_tick or e[0] == s602
	var fades: AppearFade.Fades = world.get("_appear_fades")
	_check(s602 != null and not crowd.has(s602) and in_tick and fades.fading(n602),
		"dressed within the near set, it is posed on the full path and fades on from where the ghost was")
	crowd.bake_all()
	var n604 := _ghost(world, 604, Vector3(0, 0, -95), kit)
	world.call("_set_other_gait", 604, true)
	_check(crowd.is_ghost(n604) and String((crowd.entry_of(n604)[1] as BanReader.ParsedAnimation).animation_name) == "run",
		"a ghost starting a baked loop swaps it on the GPU, still a ghost")
	world.call("_play_other_hit", 604)
	_check(gaits.has(604) and not crowd.is_ghost(n604), "a hit dresses it")
	# The light, and an equipment change.
	var n605 := _ghost(world, 605, Vector3(0, 0, -100), kit)
	var b605: CrowdGpu.Body = crowd.body_of(n605)
	var mats_before := b605.mats.duplicate()
	var groups_before: Array = []
	for prec in b605.parts:
		groups_before.append((prec as Array)[0])
	world.call("_crowd_ghost_light", n605, 0.9)
	var groups_after: Array = []
	for prec in b605.parts:
		groups_after.append((prec as Array)[0])
	# Round 759: the level is the body's texel, not a copy of each material.
	var want_objc := float(roundi(0.9 * ObjectLight.VARIANT_STEPS)) / ObjectLight.VARIANT_STEPS
	_check(b605.mats == mats_before and groups_after == groups_before and is_equal_approx(b605.objc, want_objc)
		and is_equal_approx(crowd._body_data[b605.slot * CrowdGpu.FLOATS_PER_BODY + 16], want_objc),
		"its light is its texel (%.4f), its materials and groups unchanged" % b605.objc)
	(world.get("_other_equipped") as Dictionary)[605] = {EquipmentNet.SLOT_WEAPON: 5004}
	world.call("_redress_other", 605)
	world.call("_ghost_other", 605)
	var b605b: CrowdGpu.Body = crowd.body_of(n605)
	_check(crowd.is_ghost(n605) and b605b != b605 and b605b.parts.size() == 3 and b605b.fade == CrowdGpu.FADE_IN and is_equal_approx(b605b.fade_start, b605.fade_start),
		"an equipment change draws the ghost in its new kind (Body1 shown again, no chest), its fade going on")
	# A departure fades out on the GPU.
	world.call("_on_entity_left", 605)
	world.call("_depart_step")
	_check(crowd.is_ghost(n605) and _fading_rec(crowd, b605b.parts[0]), "a departing ghost fades out")
	var wo: float = crowd._body_data[b605b.slot * CrowdGpu.FLOATS_PER_BODY + 17]
	_check(wo < 0.0, "... its texel marked fading out (%.1f)" % wo)
	_advance(world, crowd, 1.6)
	world.call("_depart_step")
	_check(not is_instance_valid(n605) or not crowd.is_ghost(n605), "... and leaves the instances when its fade-out ends")
	_test_merge757(world, crowd, kit)
	_test_hold(world, crowd, kit)
	# Round 764: the holder path (EquipFxBatch off), then the batches.
	EquipFxBatch.enabled = false
	_test_ghost_fx(world, crowd, kit, app)
	EquipFxBatch.enabled = true
	await _test_ghost_fx_batch(world, crowd, kit, app)
	_test_arrival_buffs(world, crowd, kit)
	_test_pages(world, crowd, kit)
	_test_stale_twins(world, crowd, kit)
	_test_lit_bound(crowd, app)
	_test_zone_reset(world, crowd, kit)
	world.set("_appearance", null)

## Round 762: an arriving page is held -- its ghosts at alpha 0, no plate, click
## body or circle, not in the dressing queue -- until every arrived body is a
## ghost, then revealed in one call: every body's fade-in starts at the same
## clock (one hold slot's reveal), and the plates and the rest follow. A held
## ghost that leaves is gone at once.
func _test_hold(world: Node, crowd: CrowdGpu, kit: Dictionary) -> void:
	world.set("_holds_on", true)
	crowd.bake_all()
	var bodies: Dictionary = world.get("_other_bodies")
	var ghosts: OtherCrowd.BuildQueue = world.get("_other_ghosts")
	var builds: OtherCrowd.BuildQueue = world.get("_other_builds")
	# Bodies earlier cases left queued would keep the page held.
	ghosts.clear()
	world.set("_other_build_defer", 1)
	for i in range(4):
		world.call("_spawn_or_update_other", 630 + i, "Held%d" % i, Vector3(3.0 * i, 0, -60), kit, "CHAR_TEST_MAN")
	world.set("_other_build_defer", 0)
	for i in range(3):
		world.call("_ghost_other", 630 + i)
		ghosts.drop(630 + i)
	var n630: Node3D = bodies.get(630)
	var n631: Node3D = bodies.get(631)
	var slot := crowd.hold_of(n630)
	_check(slot >= 0 and crowd.is_held(n630) and crowd.is_held(n631) and crowd.hold_pending(slot),
		"round 762: an arriving page's ghosts are held in one slot (%d)" % slot)
	var b630: CrowdGpu.Body = crowd.body_by_node(n630)
	_check(is_equal_approx(crowd._body_data[b630.slot * CrowdGpu.FLOATS_PER_BODY + 17], CrowdGpu.HOLD_CODE + slot)
		and _held_extras(world, n630, true) and not (world.get("_other_gaits") as Dictionary).has(630),
		"... marked held in their texel, their plate held (not drawn) and their click body on no layer, not dressed")
	# A held ghost that leaves is gone at once (alpha 0).
	world.call("_on_entity_left", 632)
	world.call("_depart_step")
	_check(crowd.fade_elapsed(bodies.get(630)) == 0.0 and crowd._body_data[crowd.body_by_node(n630).slot * CrowdGpu.FLOATS_PER_BODY + 17] > 0.0,
		"... (one leaving does not reveal the others)")
	world.call("_hold_step")
	_check(crowd.is_held(n630), "while an arrived body is still to be a ghost the page stays held")
	world.call("_ghost_other", 633)
	ghosts.drop(633)
	var t: float = world.get("_idle_anim_time")
	world.call("_hold_step")
	_check(not crowd.is_held(n630) and not crowd.is_held(n631) and crowd.fade_elapsed(n630) == 0.0
		and is_equal_approx(crowd.fade_start_of(n630), t) and is_equal_approx(crowd.fade_start_of(n631), t),
		"once every arrived body is a ghost the page is revealed: every fade starts at the same clock")
	_check(is_equal_approx(crowd._reveal[slot], (t - crowd._epoch) * 1000.0) and _held_extras(world, n630, false)
		and _held_extras(world, n631, false) and builds.has(630) and builds.has(631),
		"... the slot's reveal clock set; plates drawn and click bodies on their layer; dressed from now")
	_advance(world, crowd, 2.1)
	_check(crowd._body_data[crowd.body_by_node(n630).slot * CrowdGpu.FLOATS_PER_BODY + 17] == 0.0 and crowd._slot_cohort[slot] == null,
		"when the page's fade ends its bodies are opaque again and the slot is free")
	for id in [630, 631, 633]:
		builds.drop(id)
		world.call("_on_entity_left", id)
	world.call("_depart_step")
	_advance(world, crowd, 1.6)
	world.call("_depart_step")
	world.set("_holds_on", false)

## Round 762: whether `node`'s plate and click body are there and held (the
## plate not drawn, the click body on no layer) -- or, `held` false, drawn
## and on the other players' layer.
static func _held_extras(world: Node, node: Node, held: bool) -> bool:
	var label: Label3D = null
	var click: StaticBody3D = null
	for c in node.get_children():
		if c is Label3D:
			label = c
		elif c is StaticBody3D:
			click = c
	if label == null or click == null:
		return false
	var batch = world.get("_plate_batch")
	var plate_held: bool = batch != null and (batch as NamePlateBatch)._held.has(label)
	return plate_held == held and (click.collision_layer == 0) == held

## Round 757's merge with round 756 (r756_review.md, "The merge with round
## 757"): S1 a ghost's sounds go through the sound wheel keyed by its holder;
## S2 its plate is batched; S3 it is inside the far bounds the cycle resets
## the groups' AABB to.
func _test_merge757(world: Node, crowd: CrowdGpu, kit: Dictionary) -> void:
	crowd.bake_all()
	var n := _ghost(world, 606, Vector3(0, 0, -40), kit)
	var b: CrowdGpu.Body = crowd.body_of(n)
	_check(crowd.is_ghost(n) and b != null and b.heard, "S1: a ghost within hearing is heard")
	var on_wheel := false
	for k in (world.get("_sound_wheel") as Dictionary):
		on_wheel = on_wheel or ((world.get("_sound_wheel") as Dictionary)[k] as Array).has(b)
	_check(on_wheel and bool(world.call("_sound_live", b)), "S1: ... filed on the sound wheel, live by its holder")
	var adv0 := int(crowd.stats.get("sound_advances", 0))
	world.set("_idle_anim_time", float(world.get("_idle_anim_time")) + 0.25)
	world.call("_crowd_sound_step")
	_check(int(crowd.stats.get("sound_advances", 0)) > adv0, "S1: ... and advanced from it, not dropped for want of a skeleton (%d)" % (int(crowd.stats.get("sound_advances", 0)) - adv0))
	var batch: NamePlateBatch = world.get("_plate_batch")
	var label := n.get_node_or_null("Name") as Label3D
	_check(label != null and batch != null and batch.has(label) and not label.visible, "S2: a ghost's plate is batched, its Label3D not drawn")
	var far := _ghost(world, 607, Vector3(900, 0, -900), kit)
	_check(crowd.is_ghost(far), "S3: a ghost far off")
	for f in range(CrowdGpu.RESELECT_FRAMES * 6):
		world.call("_crowd_gpu_step")
	_check(crowd._aabb.has_point(far.global_position + Vector3(0, 5, 0)) and crowd._aabb.has_point(n.global_position + Vector3(0, 5, 0)),
		"S3: the far bounds the cycle reset to hold the ghosts (%s)" % str(crowd._aabb))

## Round 756's review, F2 (its probe): a kind's twins are freed by collect()
## after its ghosts left; when the slot texture then grows, a new ghost of the
## kind must draw from live twins, given the current textures.
func _test_stale_twins(world: Node, crowd: CrowdGpu, kit: Dictionary) -> void:
	var n := _ghost(world, 620, Vector3(30, 0, -120), kit)
	_advance(world, crowd, 2.1)
	world.call("_on_entity_left", 620)
	world.call("_depart_step")
	_advance(world, crowd, 1.6)
	world.call("_depart_step")
	_check(not is_instance_valid(n) or not crowd.is_ghost(n), "the probe's ghost faded in, left and faded out")
	# Every body of that kind gone: the other test bodies' kinds are the
	# same, so take them off the instances too.
	for g in crowd.ghosts():
		crowd.remove(g)
	for sk in crowd.skeletons():
		crowd.remove(sk)
	for i in range(CrowdGpu.GROUP_EMPTY_CYCLES + 1):
		crowd.collect()
	var cap0: int = crowd._slot_cap
	for i in range(cap0 + 1):
		crowd._take_slot()
	crowd._body_dirty = true
	crowd.flush(float(world.get("_idle_anim_time")))
	_check(crowd._slot_cap > cap0, "the slot texture grew (%d -> %d)" % [cap0, crowd._slot_cap])
	var n2 := _ghost(world, 621, Vector3(34, 0, -120), kit)
	crowd.flush(float(world.get("_idle_anim_time")))
	var b: CrowdGpu.Body = crowd.body_of(n2)
	var live := 0
	var current := 0
	for rec in b.parts if b != null else []:
		var g: CrowdGpu.Group = rec[0]
		if crowd._twins.values().has(g.material):
			live += 1
		if g.material.get_shader_parameter("crowd_bodies") == crowd._body_tex:
			current += 1
	_check(b != null and b.parts.size() > 0 and live == b.parts.size() and current == b.parts.size(),
		"a new ghost of a collected kind draws from live twins with the current body texture (%d, %d of %d)" % [live, current, b.parts.size() if b != null else 0])

## Review F5: a recipe keeps a few light levels, not every one it was drawn at.
func _test_lit_bound(crowd: CrowdGpu, app: CharacterAppearance) -> void:
	var r := app.far_recipe(1907, 0x22, [{"id": 5001, "plus": 0}, {"id": 5004, "plus": 0}])
	var geo = crowd._recipe_geometry(r)
	for k in range(10):
		crowd._lit_parts(r, (geo as Array)[0], 0.4 + 0.03 * float(k))
	var held := 0
	for key in crowd._recipe_lit:
		if String(key).begins_with(r.key + "|"):
			held += 1
	_check(held <= CrowdGpu.LIT_LEVELS_PER_RECIPE, "a recipe keeps at most %d light levels (%d after 10)" % [CrowdGpu.LIT_LEVELS_PER_RECIPE, held])

## Whether a part record's body fades (round 762: its texel, drawn by its
## group's fade instance).
static func _fading_rec(crowd: CrowdGpu, rec: Array) -> bool:
	var b: CrowdGpu.Body = rec[2]
	return b.fade != 0 and crowd._body_data[b.slot * CrowdGpu.FLOATS_PER_BODY + 17] != 0.0

# --- round 762's review ------------------------------------------------------------

const FX_EFP := "system\\test_fx.efp"
## A page this old (ms) is past PAGE_JOIN_MSEC (3,000).
const OLD_PAGE_MS := 4000

## Bodies `ids` leave and their fade-outs run out.
func _leave_all(world: Node, crowd: CrowdGpu, ids: Array) -> void:
	var builds: OtherCrowd.BuildQueue = world.get("_other_builds")
	for id in ids:
		builds.drop(id)
		world.call("_on_entity_left", id)
	world.call("_depart_step")
	_advance(world, crowd, 1.6)
	world.call("_depart_step")

static func _fx_holder(n: Node) -> EfpEffect:
	for c in n.get_children():
		if c is EfpEffect and String(c.name).contains("EquipFxHolder"):
			return c
	return null

## F1: a ghost carries its weapon's particles without being dressed -- its
## recipe's particle rows as EquipFx hosts on its holder, placed from its GPU
## clip frame (the same frame a far dressed body's weapon is placed at), within
## 720 units only, none while its page is held; dressed, the built items' own
## hosts take over.
func _test_ghost_fx(world: Node, crowd: CrowdGpu, kit: Dictionary, app: CharacterAppearance) -> void:
	world.set("_holds_on", false)
	crowd.bake_all()
	var d := EquipFx.driver_for(world.get_viewport())
	d.set_process(false)
	var key := EquipFx.kind_key(FX_EFP, 1.0)
	if not d._kinds.has(key):
		var m := EfpEffect.new()
		var mm := MultiMeshInstance3D.new()
		mm.multimesh = MultiMesh.new()
		m.add_child(mm)
		d.add_child(m)
		var k := EquipFx.Kind.new()
		k.key = key
		k.master = m
		d._kinds[key] = k
	# What World3D._ready hands EquipFx (the quiet subclass skips it).
	EquipFx.ghost_frame = Callable(world, "_crowd_ghost_item_frame")
	EquipFx.ghost_origin = Callable(world, "_crowd_ghost_origin")
	EquipFx.far_frame = Callable(world, "_crowd_item_frame")
	EquipFx.far_origin = Callable(world, "_crowd_item_origin")
	var n := _ghost(world, 650, Vector3(4, 0, -70), kit)
	var b: CrowdGpu.Body = crowd.body_of(n)
	_check(n != null and crowd.is_ghost(n) and b != null and b.recipe != null, "F1: a ghost to carry its weapon's particles")
	if b == null:
		return
	var r: CharacterAppearance.FarRecipe = b.recipe
	var tmpl: SkinnedBsrAssembler.AssembledCharacter = app._body_templates[BODY]
	var att: BoneAttachment3D = app._item_templates[CharacterAppearance._item_key(tmpl, BODY, SWORD)]
	var isk := att.get_child(0) as Skeleton3D
	isk.force_update_all_bone_transforms()
	var row := {"efp": FX_EFP, "scale": 1.0, "skel": isk, "bone": 0, "pose": isk.get_bone_global_pose(0),
		"att_bone": r.skeleton.find_bone("Bip01 Spine"), "chain": isk.transform, "wear": EquipmentNet.SLOT_WEAPON}
	r.fx = [row]
	world.call("_ghost_fx", n, r)
	_check(d.has_node_hosts(n) and d._ghost_hosts == 1, "F1: its recipe's particle row is a host on its holder (%d)" % d._ghost_hosts)
	d._hurry = true
	d._process(1.0 / 60.0)
	var h := _fx_holder(n)
	var g = crowd.ghost_item_frame(n, int(row["att_bone"]), row["chain"])
	var want: Transform3D = EquipFx.place(g, row["pose"], 1.0) if g != null else Transform3D()
	_check(h != null and h.visible and g != null and h.global_transform.is_equal_approx(want),
		"F1: shown, placed from the ghost's GPU clip frame (%s)" % (str(h.global_transform.origin) if h != null else "none"))
	# Two more of the kind (their hosts come with _ghost_other): 700 units off
	# shows, 750 does not (retail's LOD 0.9: 720).
	var n700 := _ghost(world, 651, Vector3(0, 0, -700), kit)
	var n750 := _ghost(world, 652, Vector3(0, 0, -750), kit)
	d._hurry = true
	d._process(1.0 / 60.0)
	var h700 := _fx_holder(n700)
	var h750 := _fx_holder(n750)
	_check(d._ghost_hosts == 3 and h700 != null and h700.visible and (h750 == null or not h750.visible) and int(d.stats.get("ghost_shown", 0)) == 2,
		"F1: within 720 units a ghost's particles show, past it not (shown %d, far %.0f)" % [int(d.stats.get("ghost_shown", 0)), float(d.stats.get("ghost_shown_far", 0.0))])
	# Dressed far: the same frame as the ghost's, from the built weapon's
	# item skeleton (CrowdGpu.item_frame); the ghost's hosts gone.
	world.set("_crowd_come", 10.0)
	world.call("_dress_ghost_now", 650)
	var skel: Skeleton3D = ((world.get("_other_gaits") as Dictionary).get(650, {}) as Dictionary).get("skeleton")
	var built_isk: Skeleton3D = null
	if skel != null:
		for c in skel.get_children():
			if c is BoneAttachment3D and (c as Node).get_child_count() > 0 and (c as Node).get_child(0) is Skeleton3D:
				built_isk = (c as Node).get_child(0)
	var f = crowd.item_frame(built_isk) if built_isk != null else null
	_check(f != null and g != null and (f as Transform3D).is_equal_approx(g),
		"F1: the ghost's weapon frame is the dressed far body's (item_frame: %s, ghost %s, far %s)" % [str(f), str(g), str(skel != null and crowd.has(skel))])
	_check(not d.has_node_hosts(n) and d._ghost_hosts == 2, "F1: dressed, the ghost's hosts are gone (%d left)" % d._ghost_hosts)
	r.fx = []
	_leave_all(world, crowd, [650, 651, 652])
	_check(d._ghost_hosts == 0, "F1: a departing ghost's hosts go with it (%d)" % d._ghost_hosts)
	_advance(world, crowd, 2.1)
	EquipFx.ghost_frame = Callable()
	EquipFx.ghost_origin = Callable()
	EquipFx.far_frame = Callable()
	EquipFx.far_origin = Callable()

## Round 764 (EquipFxBatch): every ghost's weapon particles drawn by its
## kind's batch, whichever way the camera looks -- the user's "the seal
## effects appear and disappear and it seems like it's based off camera
## angle" was EquipFx drawing only the 64 nearest hosts in the view, chosen
## again as the camera turned. Ghosts on every side of the camera, eight
## yaws: at each, every host is in its batch's table, switched on, and the
## draw's instances are every host's particles; and each host's frame as the
## batch's shader composes it (EquipFxBatch.cpu_hold, the same arithmetic
## from the table's floats) is the holder's (EquipFx.place of the ghost's
## GPU clip frame). NEGATIVE (by hand): EquipFxBatch.enabled false fails
## "in its batch" at every yaw; dropping the chain from the table's rest
## rows fails the frame check.
func _test_ghost_fx_batch(world: Node, crowd: CrowdGpu, kit: Dictionary, app: CharacterAppearance) -> void:
	world.set("_holds_on", false)
	crowd.bake_all()
	var vp := world.get_viewport()
	if vp.has_meta(EquipFx.DRIVER_META):
		var old = vp.get_meta(EquipFx.DRIVER_META)
		vp.remove_meta(EquipFx.DRIVER_META)
		if is_instance_valid(old):
			(old as Node).free()
	var d := EquipFx.driver_for(vp)
	d.set_process(false)
	var key := EquipFx.kind_key(FX_EFP, 1.0)
	# A master with three particles in one plate node, its buffer as a
	# simulation leaves it (EfpEffect.draw_buffer).
	var m := EfpEffect.new()
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = MultiMesh.new()
	mmi.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	mmi.multimesh.use_colors = true
	mmi.multimesh.use_custom_data = true
	mmi.multimesh.mesh = QuadMesh.new()
	mmi.material_override = EfpEffect.material_for(ImageTexture.create_from_image(Image.create(2, 2, false, Image.FORMAT_RGBA8)), null)
	m.add_child(mmi)
	m._draws.append([0, mmi, "ViewNone"])
	m.keep_draw_buffers = true
	var buf := PackedFloat32Array()
	buf.resize(3 * 20)
	for i in 3:
		EfpEffect._put_instance(buf, i * 20, Transform3D(Basis.IDENTITY, Vector3(0, 0.5 * i, 0)), Color(1, 1, 1, 1), Color(0, 0, 1, 1))
	m._draw_bufs = [buf]
	m.draw_updates = 1
	d.add_child(m)
	var k := EquipFx.Kind.new()
	k.key = key
	k.master = m
	d._kinds[key] = k
	EquipFx.ghost_frame = Callable(world, "_crowd_ghost_item_frame")
	EquipFx.ghost_origin = Callable(world, "_crowd_ghost_origin")
	EquipFx.ghost_gpu = Callable(world, "_crowd_gpu_now")
	var tmpl: SkinnedBsrAssembler.AssembledCharacter = app._body_templates[BODY]
	var att: BoneAttachment3D = app._item_templates[CharacterAppearance._item_key(tmpl, BODY, SWORD)]
	var isk := att.get_child(0) as Skeleton3D
	isk.force_update_all_bone_transforms()
	# Ghosts all round the camera: ahead, behind, either side, and one past
	# 720 units.
	var spots := [Vector3(0, 0, -50), Vector3(0, 0, 65), Vector3(80, 0, 0), Vector3(-95, 0, 0), Vector3(40, 0, -40), Vector3(0, 0, -750)]
	var ids: Array = []
	for i in spots.size():
		var id := 760 + i
		var n := _ghost(world, id, spots[i], kit)
		var b: CrowdGpu.Body = crowd.body_of(n)
		if b == null:
			continue
		var r: CharacterAppearance.FarRecipe = b.recipe
		var row := {"efp": FX_EFP, "scale": 1.0, "skel": isk, "bone": 0, "pose": isk.get_bone_global_pose(0),
			"att_bone": r.skeleton.find_bone("Bip01 Spine"), "chain": isk.transform, "wear": EquipmentNet.SLOT_WEAPON}
		r.fx = [row]
		world.call("_ghost_fx", n, r)
		ids.append(id)
	_check(ids.size() == spots.size() and d._ghost_hosts == spots.size(), "r764: six ghosts carry a host each (%d)" % d._ghost_hosts)
	# A camera of the test's own, at the middle of the ring.
	var cam := Camera3D.new()
	cam.name = "R764Cam"
	world.add_child(cam)
	cam.global_position = Vector3(0, 10, 0)
	cam.current = true
	_check(vp.get_camera_3d() == cam, "r764: the test's camera draws the viewport")
	var bodies: Dictionary = world.get("_other_bodies")
	var bt: EquipFxBatch = d._batch
	var native := bt != null and bt.native
	print("r764: EquipFxBatch %s" % ("native (SrEfpHosts)" if native else "the GDScript fallback"))
	var host_of := func(id: int):
		var n: Node3D = bodies.get(id)
		return d._hosts.get(d._by_skel.get(n.get_instance_id(), [""])[0]) if n != null else null
	for yaw in range(0, 360, 45):
		cam.global_transform = Transform3D(Basis(Vector3.UP, deg_to_rad(float(yaw))), cam.global_position)
		for rep in EquipFxBatch.REBUILD_EVERY + 2:
			d._hurry = true
			d._process(1.0 / 60.0)
		var all_in := true
		var batch: EquipFxBatch.Batch = null
		for id in ids:
			var h = host_of.call(id)
			if h == null or h.batch == null:
				all_in = false
				continue
			batch = h.batch
		if native:
			# Chosen in every direction (5: the 750-unit one is past reach),
			# drawn whatever is within the view, its instances the drawn hosts
			# x the node's stride, its master stepped.
			var in_view := 0
			for id in ids.slice(0, ids.size() - 1):
				if cam.is_position_in_frustum((bodies.get(id) as Node3D).global_position):
					in_view += 1
			# (The headless renderer keeps no instance counts: the counts the
			# batch gave the library, its drawn hosts x each draw's stride.)
			var vis := int(bt.stats["instances"])
			var drawn := int(bt.stats["drawn"])
			_check(all_in and int(bt.stats["in_reach"]) == 5 and bt.selected_count() == 5 and drawn >= in_view and drawn >= 1
				and vis == drawn * 4 and bt.live_kinds.has(key),
				"review F1: yaw %d: 5 hosts chosen in every direction, %d drawn (%d in the frustum), %d instances (drawn x 4), the master stepped" % [yaw, drawn, in_view, vis])
		else:
			var on := true
			for id in ids:
				var h = host_of.call(id)
				if h == null or h.batch == null:
					continue
				if id == ids[ids.size() - 1]:
					if h.sel:
						on = false
					continue
				var at: int = (h.batch as EquipFxBatch.Batch).drawn.find(h)
				if at < 0 or at >= h.batch.shown or h.batch.host_data[at * EquipFxBatch.HOST_FLOATS + 3] < 1.0:
					on = false
			var inst := 0
			if batch != null:
				for dr in batch.draws:
					inst += int(dr[4])
			_check(all_in and on and batch != null and batch.shown == ids.size() - 1 and inst == (ids.size() - 1) * 4,
				"r764: yaw %d: every ghost's host within 720 in its batch's table and on, %d instances (%d hosts x 4)" % [yaw, inst, batch.shown if batch != null else -1])
	# The budget (OURS): two hosts drawn -- the two nearest, whatever the yaw.
	EquipFxBatch.host_budget = 2
	for yaw in [0, 180]:
		cam.global_transform = Transform3D(Basis(Vector3.UP, deg_to_rad(float(yaw))), cam.global_position)
		for rep in EquipFxBatch.REBUILD_EVERY + 2:
			d._hurry = true
			d._process(1.0 / 60.0)
		_check(bt.selected_count() == 2, "r764: a budget of 2 chooses 2 hosts at yaw %d (%d)" % [yaw, bt.selected_count()])
	EquipFxBatch.host_budget = 0
	for rep in EquipFxBatch.REBUILD_EVERY + 2:
		d._hurry = true
		d._process(1.0 / 60.0)
	_check(bt.selected_count() == 5, "review F1: no budget (retail's rule): every host within 720 chosen (%d)" % bt.selected_count())
	EquipFxBatch.host_budget = EquipFxBatch.HOST_BUDGET
	for rep in EquipFxBatch.REBUILD_EVERY + 2:
		d._hurry = true
		d._process(1.0 / 60.0)
	# The frame the batch draws each host at, against the holder's.
	_advance(world, crowd, 0.0)
	var worst := 0.0
	var checked := 0
	var b0: EquipFxBatch.Batch = null
	for id in ids:
		var n: Node3D = bodies.get(id)
		var h = host_of.call(id)
		if h == null or h.batch == null:
			continue
		b0 = h.batch
		var got = null
		if native:
			if id == ids[ids.size() - 1]:
				continue
			got = bt.native_frame(crowd, h)
		else:
			var at: int = (h.batch as EquipFxBatch.Batch).drawn.find(h)
			if at < 0:
				continue
			got = EquipFxBatch.cpu_hold(crowd, h.batch, at)
		checked += 1
		var g = crowd.ghost_item_frame(n, h.att_bone, h.chain)
		if got == null or g == null:
			worst = INF
			continue
		var want := EquipFx.place(g, h.pose, h.scale)
		var t: Transform3D = got
		worst = maxf(worst, (t.origin - want.origin).length())
		for c in 3:
			worst = maxf(worst, (t.basis[c] - want.basis[c]).length())
	_check(checked == 5 and worst < 1e-4, "r764: each drawn host's frame as the batch places it is the holder's (%d hosts, worst %.7f)" % [checked, worst])
	var holders := 0
	for id in ids:
		if _fx_holder(bodies.get(id)) != null:
			holders += 1
	_check(holders == 0 and d.steps_master(k), "r764: no holder for a batched ghost (%d), its kind stepped" % holders)
	# The review's F6: the world leaves and is entered again -- nothing grows.
	var before := [bt._batches.size(), bt._layouts.size(), _count_batch_nodes(d)]
	for cycle in 2:
		d.reset_world()
		_check(d._ghost_hosts == 0 and bt._batches.is_empty() and bt._layouts.is_empty(), "review F6: the world left, no ghost host, batch or layout kept")
		for id in ids:
			var n: Node3D = bodies.get(id)
			var rb = crowd.body_of(n)
			world.call("_ghost_fx", n, rb.recipe)
		for rep in EquipFxBatch.REBUILD_EVERY + 2:
			d._process(1.0 / 60.0)
		await process_frame
		var after := [bt._batches.size(), bt._layouts.size(), _count_batch_nodes(d)]
		_check(after == before, "review F6: entered again (%d), the batches, layouts and draw nodes are as many as before (%s against %s)" % [cycle + 1, str(after), str(before)])
	for id in ids:
		var rr = crowd.body_of(bodies.get(id))
		if rr != null and rr.recipe != null:
			rr.recipe.fx = []
	_leave_all(world, crowd, ids)
	for rep in EquipFxBatch.REBUILD_EVERY + 1:
		d._process(1.0 / 60.0)
	_check(d._ghost_hosts == 0 and (b0 == null or b0.hosts.is_empty()) and bt.selected_count() == 0,
		"r764: the ghosts gone, their hosts leave the batch and none is chosen (%d)" % bt.selected_count())
	_advance(world, crowd, 2.1)
	await _test_reveal_budget(world, crowd, kit, d, isk, cam)
	_test_native_panic(world, d, cam)
	EquipFx.ghost_frame = Callable()
	EquipFx.ghost_origin = Callable()
	EquipFx.ghost_gpu = Callable()
	cam.queue_free()

## The EquipFxBatch draw nodes under the driver (live ones).
static func _count_batch_nodes(d: Node) -> int:
	var n := 0
	for c in d.get_children():
		if c is MultiMeshInstance3D and c.has_meta(EquipFxBatch.DRAW_META) and not c.is_queued_for_deletion():
			n += 1
	return n

## The re-review's R1: a dressed body's host drawn by the native batch; the
## library's step panics (SrEfpHosts.qa_panic_next_step) -- the batch goes to
## the GDScript fallback and the dressed host back to EquipFx's holders, shown
## again within a cycle. Natively only (the fallback has no dressed hosts).
## NEGATIVE (by hand): dropping `h.direct = false` from the broken branch
## leaves the host with no batch and no holder ("drawn again by a holder").
func _test_native_panic(world: Node, d: EquipFx, cam: Camera3D) -> void:
	var bt: EquipFxBatch = d._batch
	if bt == null or not bt.native:
		print("r764 R1: the native batch is not here (no library): skipped")
		return
	var vp := world.get_viewport()
	EquipFx.batch_viewport = vp
	cam.global_transform = Transform3D(Basis.IDENTITY, Vector3(0, 10, 0))
	var holder := Node3D.new()
	world.add_child(holder)
	holder.global_position = Vector3(0, 0, -40)
	var sk := Skeleton3D.new()
	sk.add_bone("ai_end")
	holder.add_child(sk)
	d.add_host(sk, "ai_end", FX_EFP, 1.0, null)
	var hid = d._by_skel.get(sk.get_instance_id(), [""])[0]
	var h = d._hosts.get(hid)
	for rep in 3:
		d._process(1.0 / 60.0)
	_check(h != null and h.direct and h.batch != null and int(bt.stats["direct"]) == 1 and int(bt.stats["drawn"]) >= 1,
		"r764 R1: a dressed body's host is drawn by the native batch (direct %d)" % (int(bt.stats["direct"]) if h != null else -1))
	bt._hn.call("qa_panic_next_step")
	d._process(1.0 / 60.0)
	_check(not bt.native and h != null and not h.direct and h.batch == null,
		"r764 R1: the library's step panicked -- the batch is the fallback and the dressed host is EquipFx's again")
	for rep in 3:
		d._hurry = true
		d._process(1.0 / 60.0)
	var hf := _fx_holder(sk)
	_check(hf != null and hf.visible, "r764 R1: ... drawn again by a holder")
	d.remove_skel(sk)
	holder.queue_free()
	EquipFx.batch_viewport = null

## The review's F2: a page of six ghosts held, then revealed, with a budget of
## two hosts -- no frame from the reveal on chooses more than two.
func _test_reveal_budget(world: Node, crowd: CrowdGpu, kit: Dictionary, d: EquipFx, isk: Skeleton3D, cam: Camera3D) -> void:
	world.set("_holds_on", true)
	EquipFxBatch.host_budget = 2
	var ghosts: OtherCrowd.BuildQueue = world.get("_other_ghosts")
	var bodies: Dictionary = world.get("_other_bodies")
	ghosts.clear()
	world.set("_page_pick", true)
	world.set("_other_build_defer", 1)
	var ids: Array = []
	for i in 6:
		world.call("_spawn_or_update_other", 790 + i, "Rev%d" % i, Vector3(-30 + 12 * i, 0, -60), kit, "CHAR_TEST_MAN")
		ids.append(790 + i)
	world.set("_other_build_defer", 0)
	for id in ids:
		world.call("_ghost_other", id)
		ghosts.drop(id)
		var b = crowd.body_of(bodies.get(id))
		if b != null and b.recipe != null:
			b.recipe.fx = [{"efp": FX_EFP, "scale": 1.0, "skel": isk, "bone": 0, "pose": isk.get_bone_global_pose(0),
				"att_bone": b.recipe.skeleton.find_bone("Bip01 Spine"), "chain": isk.transform, "wear": EquipmentNet.SLOT_WEAPON}]
	var held_ok := crowd.is_held(bodies.get(ids[0])) and d._ghost_hosts == 0
	_check(held_ok, "review F9: a held page's ghosts register no host until their activation (%d hosts)" % d._ghost_hosts)
	var worst := 0
	for f in 40:
		world.call("_hold_step")
		_advance(world, crowd, 1.0 / 60.0)
		d._hurry = true
		d._process(1.0 / 60.0)
		worst = maxi(worst, d._batch.selected_count())
	_check(d._ghost_hosts == 6 and worst <= 2 and d._batch.selected_count() == 2,
		"review F2: after the reveal 6 hosts are registered and no frame chose more than the budget of 2 (most %d, now %d)" % [worst, d._batch.selected_count()])
	for id in ids:
		var rb = crowd.body_of(bodies.get(id))
		if rb != null and rb.recipe != null:
			rb.recipe.fx = []
	_leave_all(world, crowd, ids)
	_advance(world, crowd, 2.1)
	EquipFxBatch.host_budget = EquipFxBatch.HOST_BUDGET
	world.set("_holds_on", false)

## F2: a body that arrives with buffs (the book holds them) is dressed first
## once its page shows, and so is one whose buff came while it was held or not
## a ghost yet; none is dressed before its page shows.
func _test_arrival_buffs(world: Node, crowd: CrowdGpu, kit: Dictionary) -> void:
	world.set("_holds_on", true)
	crowd.bake_all()
	var ghosts: OtherCrowd.BuildQueue = world.get("_other_ghosts")
	var builds: OtherCrowd.BuildQueue = world.get("_other_builds")
	var bodies: Dictionary = world.get("_other_bodies")
	var book: HudTargetBuffs.Book = world.get("_target_buff_book")
	ghosts.clear()
	world.set("_page_pick", true)
	world.set("_other_build_defer", 1)
	for i in range(4):
		world.call("_spawn_or_update_other", 660 + i, "Buffed%d" % i, Vector3(3.0 * i, 0, -50), kit, "CHAR_TEST_MAN")
	world.set("_other_build_defer", 0)
	book.start("character:660", 7601, 1001)
	world.call("_fx_owner_body", 661, SkillNet.OWNER_CHARACTER)
	_check(not builds.urgent.has(661), "F2: a buff on a body not a ghost yet does not dress it during its page")
	for i in range(4):
		world.call("_ghost_other", 660 + i)
		ghosts.drop(660 + i)
	var n660: Node3D = bodies.get(660)
	_check(crowd.is_held(n660) and not builds.has(660), "F2: the page is held, its ghosts out of the dressing queue")
	world.call("_fx_owner_body", 662, SkillNet.OWNER_CHARACTER)
	_check(not builds.urgent.has(662), "F2: a buff on a held ghost does not dress it before its page shows")
	world.call("_hold_step")
	_check(not crowd.is_held(n660) and builds.urgent.has(660) and builds.urgent.has(661) and builds.urgent.has(662) and builds.has(663) and not builds.urgent.has(663),
		"F2: at the reveal the ones that arrived with buffs, or got one meanwhile, are first in the dressing; the others queued")
	book.drop("character:660")
	_leave_all(world, crowd, [660, 661, 662, 663])
	_advance(world, crowd, 2.1)
	world.set("_holds_on", false)

## F6: a group whose first share comes more than PAGE_JOIN_MSEC after the
## current page opened opens a page of its own, and the first page is revealed
## when its own arrivals are ghosts. F3: a page revealed by its deadline drops
## an arrival whose body is gone.
func _test_pages(world: Node, crowd: CrowdGpu, kit: Dictionary) -> void:
	world.set("_holds_on", true)
	crowd.bake_all()
	var ghosts: OtherCrowd.BuildQueue = world.get("_other_ghosts")
	var bodies: Dictionary = world.get("_other_bodies")
	ghosts.clear()
	world.set("_page_pick", true)
	world.set("_other_build_defer", 1)
	world.call("_spawn_or_update_other", 680, "PageA", Vector3(0, 0, -40), kit, "CHAR_TEST_MAN")
	world.set("_other_build_defer", 0)
	var pa = world.get("_page_cur")
	# Round 764: a page is joined by the groups that ARRIVED (rx) within
	# PAGE_JOIN_MSEC of its first, however long ago it opened on the clock.
	pa.opened_ms -= OLD_PAGE_MS
	world.set("_page_pick", true)
	world.set("_page_pick_rx", pa.rx_ms + 100)
	world.set("_other_build_defer", 1)
	world.call("_spawn_or_update_other", 679, "PageA2", Vector3(-3, 0, -40), kit, "CHAR_TEST_MAN")
	world.set("_other_build_defer", 0)
	_check((world.get("_page_wait") as Dictionary).get(679) == pa and (world.get("_pages") as Array).size() == 1,
		"r764: a group read %d ms after the page opened, but received with its first group, joins it" % OLD_PAGE_MS)
	world.call("_ghost_other", 679)
	ghosts.drop(679)
	# The review's F8: a group 2,900 ms after the one before it -- 3,000 after
	# the page's first -- still joins (a window spread over a slow link).
	var first_rx: int = pa.rx_ms - 100
	world.set("_page_pick", true)
	world.set("_page_pick_rx", first_rx + 3000)
	world.set("_other_build_defer", 1)
	world.call("_spawn_or_update_other", 678, "PageA3", Vector3(-6, 0, -40), kit, "CHAR_TEST_MAN")
	world.set("_other_build_defer", 0)
	_check((world.get("_page_wait") as Dictionary).get(678) == pa and (world.get("_pages") as Array).size() == 1,
		"review F8: a group 2,900 ms after the one before it (3,000 after the first) joins the page")
	world.call("_ghost_other", 678)
	ghosts.drop(678)
	pa.rx_ms -= OLD_PAGE_MS + 3000
	world.set("_page_pick", true)
	world.set("_other_build_defer", 1)
	world.call("_spawn_or_update_other", 681, "PageB", Vector3(3, 0, -40), kit, "CHAR_TEST_MAN")
	world.set("_other_build_defer", 0)
	var pb = (world.get("_page_wait") as Dictionary).get(681)
	_check(pb != null and pb != pa and (world.get("_pages") as Array).size() == 2, "F6: a group received %d ms after the page's first opens its own" % OLD_PAGE_MS)
	world.set("_page_pick", true)
	world.set("_other_build_defer", 1)
	world.call("_spawn_or_update_other", 682, "PageB2", Vector3(6, 0, -40), kit, "CHAR_TEST_MAN")
	world.set("_other_build_defer", 0)
	_check((world.get("_page_wait") as Dictionary).get(682) == pb, "F6: a group within a few seconds of it joins it")
	world.call("_ghost_other", 680)
	ghosts.drop(680)
	world.call("_hold_step")
	var n680: Node3D = bodies.get(680)
	_check(not crowd.is_held(n680) and not crowd.is_held(bodies.get(679)) and not crowd.is_held(bodies.get(678)) and (world.get("_pages") as Array).size() == 1, "F6: the first page shows once its own arrivals are ghosts, the second still waiting")
	world.call("_ghost_other", 681)
	ghosts.drop(681)
	var n681: Node3D = bodies.get(681)
	_check(crowd.is_held(n681), "F6: the second page holds its ghosts")
	# 682's body goes without a departure (freed under it): the deadline
	# reveal drops it.
	var n682: Node3D = bodies.get(682)
	bodies.erase(682)
	ghosts.drop(682)
	if n682 != null:
		n682.free()
	pb.opened_ms -= world.HOLD_MAX_MSEC
	world.call("_hold_step")
	_check(not crowd.is_held(n681) and (world.get("_page_wait") as Dictionary).is_empty() and (world.get("_pages") as Array).is_empty(),
		"F3: a page revealed by its deadline drops a waiting arrival whose body is gone")
	(world.get("_other_build_args") as Dictionary).erase(682)
	_leave_all(world, crowd, [678, 679, 680, 681])
	_advance(world, crowd, 2.1)
	world.set("_holds_on", false)

## F3: a zone change while a page is held resets the hold state (its slot
## revealed, nothing left waiting), so a later group is shown when its own
## arrivals are ghosts, not 20 s on.
func _test_zone_reset(world: Node, crowd: CrowdGpu, kit: Dictionary) -> void:
	world.set("_holds_on", true)
	crowd.bake_all()
	var ghosts: OtherCrowd.BuildQueue = world.get("_other_ghosts")
	var bodies: Dictionary = world.get("_other_bodies")
	ghosts.clear()
	world.set("_page_pick", true)
	world.set("_other_build_defer", 1)
	for i in range(2):
		world.call("_spawn_or_update_other", 670 + i, "Zone%d" % i, Vector3(3.0 * i, 0, -45), kit, "CHAR_TEST_MAN")
	world.set("_other_build_defer", 0)
	world.call("_ghost_other", 670)
	ghosts.drop(670)
	var slot := crowd.hold_of(bodies.get(670))
	_check(slot >= 0 and crowd.hold_pending(slot) and not (world.get("_page_wait") as Dictionary).is_empty(), "F3: a page held, an arrival still waiting")
	world.call("_replace_others_for_arrival", [], [])
	_check((world.get("_pages") as Array).is_empty() and (world.get("_page_wait") as Dictionary).is_empty() and not crowd.hold_pending(slot)
		and (world.get("_activate_ids") as Array).is_empty() and world.get("_page_cur") == null,
		"F3: a zone change resets every page's hold state and reveals the held slot")
	_advance(world, crowd, 2.1)
	ghosts.clear()
	world.set("_page_pick", true)
	world.set("_other_build_defer", 1)
	for i in range(2):
		world.call("_spawn_or_update_other", 672 + i, "After%d" % i, Vector3(3.0 * i, 0, -45), kit, "CHAR_TEST_MAN")
	world.set("_other_build_defer", 0)
	for i in range(2):
		world.call("_ghost_other", 672 + i)
		ghosts.drop(672 + i)
	var n672: Node3D = (world.get("_other_bodies") as Dictionary).get(672)
	world.call("_hold_step")
	_check(n672 != null and not crowd.is_held(n672) and crowd.fade_elapsed(n672) == 0.0, "F3: ... and the next group is revealed once its arrivals are ghosts")
	world.set("_holds_on", false)

