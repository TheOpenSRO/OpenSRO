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
		_test_world(world, app)
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
	crowd.bake_all()
	world.call("_ghost_other", 601)
	_check(crowd.is_ghost(n601) and crowd.ghost_count() == 1, "an arrival is a ghost once its loop is baked")
	_check(_count(n601, "Label3D") == 1 and _count(n601, "StaticBody3D") == 1, "... with its name plate and click body")
	crowd.flush(t0)
	var b: CrowdGpu.Body = crowd.body_of(n601)
	_check(b != null and b.parts.size() == 3 and int(crowd.stats["instances"]) == 3, "its three parts are instances (%d)" % int(crowd.stats["instances"]))
	_check(is_zero_approx(crowd.fade_elapsed(n601)) and _fading_rec(b.parts[0]),
		"it fades in from 0 on the fade groups")
	var rec: Array = b.parts[0]
	var w: float = (rec[0] as CrowdGpu.Group).buf[int(rec[1]) * CrowdGpu.INSTANCE_FLOATS + 15]
	_check(w >= 0.0 and is_equal_approx(w, (t0 - crowd._epoch) * 1000.0),
		"its instances carry the fade's start for the shader's per-instance alpha (%.1f)" % w)
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
	_check(crowd.fade_elapsed(n601) < 0.0 and not _fading_rec(b.parts[0]),
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
	world.call("_crowd_ghost_light", n605, 0.9)
	_check(b605.mats.size() == mats_before.size() and b605.mats[0] != mats_before[0] and ObjectLight.base_of(b605.mats[0]) == mats_before[0],
		"its light takes the level's copy of each material")
	(world.get("_other_equipped") as Dictionary)[605] = {EquipmentNet.SLOT_WEAPON: 5004}
	world.call("_redress_other", 605)
	world.call("_ghost_other", 605)
	var b605b: CrowdGpu.Body = crowd.body_of(n605)
	_check(crowd.is_ghost(n605) and b605b != b605 and b605b.parts.size() == 3 and b605b.fade == CrowdGpu.FADE_IN and is_equal_approx(b605b.fade_start, b605.fade_start),
		"an equipment change draws the ghost in its new kind (Body1 shown again, no chest), its fade going on")
	# A departure fades out on the GPU.
	world.call("_on_entity_left", 605)
	_check(crowd.is_ghost(n605) and _fading_rec(b605b.parts[0]), "a departing ghost fades out")
	var wo: float = ((b605b.parts[0] as Array)[0] as CrowdGpu.Group).buf[int((b605b.parts[0] as Array)[1]) * CrowdGpu.INSTANCE_FLOATS + 15]
	_check(wo < 0.0, "... its instances marked fading out (%.1f)" % wo)
	_advance(world, crowd, 1.6)
	_check(not crowd.is_ghost(n605), "... and leaves the instances when its fade-out ends")
	_test_stale_twins(world, crowd, kit)
	_test_lit_bound(crowd, app)
	world.set("_appearance", null)

## Round 756's review, F2 (its probe): a kind's twins are freed by collect()
## after its ghosts left; when the slot texture then grows, a new ghost of the
## kind must draw from live twins, given the current textures.
func _test_stale_twins(world: Node, crowd: CrowdGpu, kit: Dictionary) -> void:
	var n := _ghost(world, 620, Vector3(30, 0, -120), kit)
	_advance(world, crowd, 2.1)
	world.call("_on_entity_left", 620)
	_advance(world, crowd, 1.6)
	_check(not crowd.is_ghost(n), "the probe's ghost faded in, left and faded out")
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

## Whether a part record draws from a fade group (a blended fade twin).
static func _fading_rec(rec: Array) -> bool:
	var g: CrowdGpu.Group = rec[0]
	return g.material.shader.code.contains("APPEAR_FADE") or g.material.shader.code.contains("appear_alpha")
