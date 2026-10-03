extends RefCounted
class_name MonsterDraw

## Drawing many monsters (round 655): the server will send hundreds per view
## (10,195 field placements over the map; the densest 5 x 5-region window
## holds about 500), and each body used to be a fresh assembly of its
## species' `.bsr`, `.bsk`, `.bms` and textures, built the frame its list
## arrived, posed in GDScript every frame wherever it stood. The rules here,
## kept apart from World3D so a headless test can hold them to account:
##
## - **One template per species model** (Templates): the `.bsr` is assembled
##   once, kept detached, and every body is a duplicate() of its skeleton --
##   the meshes, skins, materials and textures shared, only the skeleton and
##   its mesh nodes per body -- the way the NPC path has kept
##   `_npc_model_cache` since round 157. The parsed `.bsr`, its idle clip and
##   the per-model animation cache are shared too, so a clip is parsed once
##   per species, not once per body.
## - **Bodies over several frames** (World3D._pump_monster_builds): a list
##   queues the bodies it names and each frame builds them until
##   BUILD_BUDGET_USEC is spent (at least one). OURS: a budget, not a retail
##   value.
## - **Posing only what is seen** (pose_wanted): an idle or one-shot clip is
##   posed only while the body is in POSE_RANGE of the camera and its sphere
##   touches the view frustum. Out of range its clip also stops sounding, and
##   a monster's model is hidden (META_HIDE).
## - **No body outside the loaded regions** (World3D._monster_region_loaded):
##   a monster whose region is not loaded keeps its snapshot but gets no body
##   until its region loads, and loses its body when its region unloads.

## The main-thread time a frame may spend building queued bodies, in
## microseconds. OURS (a budget, not a retail value): a cached body costs
## tens of microseconds (the round's probe measures it), so a frame builds
## dozens; a species seen for the first time is one assembly, which may
## alone exceed it -- the at-least-one rule lets it through and the rest of
## the queue waits for the next frame.
const BUILD_BUDGET_USEC := 3000
## Bodies built in a frame whatever the budget says, so a queue always drains.
const MIN_BUILDS_PER_FRAME := 1

## How far from the camera a body's clip is still posed. The map objects'
## update range (MapAnimation.OBJECT_RANGE, READ: 2500 - 480 = 2020 from the
## camera, asm 0xa2d961/0xa2d967) applied to characters. For characters it
## is OURS: see docs/WORLD_ISSUES.md round 655 for what was searched.
const POSE_RANGE := MapAnimation.OBJECT_RANGE

## Meta on a skeleton whose clip is culled (monsters and NPCs; never the
## player, other players or the character window's doll), and the radius of
## its bounding sphere in world units.
const META_CULL := "opensro_pose_cull"
const META_RADIUS := "opensro_pose_radius"
## Meta on a monster's skeleton: hidden while out of POSE_RANGE (round 655's
## review; OURS, as MapAnimation hides a map object out of its range). An NPC
## is only left unposed.
const META_HIDE := "opensro_hide_out_of_range"

## The model scale a monster's class gives it (round 660), READ from the
## retail spawn parser CICMonster::vslot_025 (0x9d3850): the scale starts at
## 1.0 (`fld1` 0x9d38c9) and a switch on class - 1 (0x9d3995..0x9d39cb, table
## 0x9d3c70) multiplies it -- champion (1) by 1.5 (float 0xd819ec =
## 0x3fc00000), giant (4) by 3.0 (0xd8adc4 = 0x40400000), elite (6) by 1.7
## (0xde2818 = 0x3fd9999a); every other class, the party flag and the uniques
## keep 1.0. Not modelled: the species' own percent (ref+0x110, whose
## characterdata column is unread) that multiplies it, and the TypeID4 2/3
## monsters that skip the class scale (none of them is a field monster).
static func class_scale(rarity: int) -> float:
	match rarity:
		1:
			return 1.5
		4:
			return 3.0
		6:
			return 1.7
	return 1.0

## Whether a body at `origin` with bounding radius `radius` is posed this
## frame: in POSE_RANGE of the camera `eye` (the map objects' strict
## `dist - radius < range`) and its sphere inside every frustum plane
## (Camera3D.get_frustum(), normals outward). Empty `planes` passes the
## frustum test (no camera).
static func pose_wanted(origin: Vector3, radius: float, eye: Vector3, planes: Array, pose_range: float = POSE_RANGE) -> bool:
	if not in_range(origin, radius, eye, pose_range):
		return false
	for plane in planes:
		if (plane as Plane).distance_to(origin) > radius:
			return false
	return true

## The distance half of pose_wanted: a body out of range neither poses nor
## sounds.
static func in_range(origin: Vector3, radius: float, eye: Vector3, pose_range: float = POSE_RANGE) -> bool:
	return origin.distance_to(eye) - radius < pose_range

## The height a monster's name plate sits at: its skeleton's highest bone in
## the bind pose plus 15 %, as World3D computed it per body before this round.
static func label_height(skeleton: Skeleton3D) -> float:
	var max_y := 0.0
	for i in range(skeleton.get_bone_count()):
		if Skeleton3DBuilder.is_skeleton_bone(skeleton, i):
			max_y = maxf(max_y, skeleton.get_bone_global_pose(i).origin.y)
	return max_y + max_y * 0.15

## The radius of a body's culling sphere about its placement origin (its
## feet): the farthest corner of any of its meshes' bounds in the bind pose,
## and at least `floor_radius` (the name plate's height). OURS: a sphere
## about the feet rather than retail's bounds; a mesh hung rigidly off a bone
## is measured in its own space, so a far-flung rigid piece is under-counted
## by its bone's offset.
static func cull_radius(skeleton: Skeleton3D, floor_radius: float) -> float:
	var r := maxf(floor_radius, 1.0)
	for node in skeleton.find_children("*", "MeshInstance3D", true, false):
		var box := (node as MeshInstance3D).get_aabb()
		for i in range(8):
			r = maxf(r, box.get_endpoint(i).length())
	return r

## One template per species model. `assemble` is called once per model path
## (a Callable taking the path and returning an AssembledCharacter or null);
## a model that failed is remembered as failed and not tried again.
class Templates:
	var _by_model := {} # model path -> AssembledCharacter, or null for a model that failed
	var _label_heights := {} # model path -> label_height of its template
	var _radii := {} # model path -> cull_radius of its template
	## Assemblies run and bodies instanced, for the log and the test.
	var assembles := 0
	var instances := 0
	var assemble_usec := 0
	var instance_usec := 0

	## Round 661: assemblies off the main thread. request() starts one
	## WorkerThreadPool task per model; poll() adopts the finished ones and
	## answers their models. A species' first body used to assemble its model
	## on the main thread inside the frame that drew it -- Tiger Girl's 844 ms,
	## a rotation's respawn in view froze the game for 862 ms (round 661's
	## live check). instance() still assembles on the spot a model nobody
	## requested (the synchronous path, OPENSRO_SYNC_LOAD=1, the tests).
	var _tasks := {} # model -> WorkerThreadPool task id
	var _done := {} # model -> [AssembledCharacter or null, usec], written by the task
	var _lock := Mutex.new()

	func has(model: String) -> bool:
		return _by_model.has(model)

	## Whether model is being assembled off the main thread.
	func pending(model: String) -> bool:
		return _tasks.has(model)

	## Starts model's assembly on a WorkerThreadPool task, unless it is
	## assembled or under way.
	func request(model: String, assemble: Callable) -> void:
		if _by_model.has(model) or _tasks.has(model):
			return
		_tasks[model] = WorkerThreadPool.add_task(_assemble_task.bind(model, assemble), true, "monster template %s" % model)

	func _assemble_task(model: String, assemble: Callable) -> void:
		var sw := Time.get_ticks_usec()
		var built = assemble.call(model)
		var usec := Time.get_ticks_usec() - sw
		_lock.lock()
		_done[model] = [built, usec]
		_lock.unlock()

	## Adopts every finished assembly as its model's template; answers the
	## models that became ready (a failed one too: it is then a capsule).
	func poll() -> Array[String]:
		var ready: Array[String] = []
		if _tasks.is_empty():
			return ready
		for model in _tasks.keys():
			if not WorkerThreadPool.is_task_completed(_tasks[model]):
				continue
			_finish(model)
			ready.append(model)
		return ready

	## Waits for model's task and adopts what it built (round 661's review:
	## also what a synchronous instance() of a pending model does, so it never
	## assembles a second copy for the task to overwrite).
	func _finish(model: String) -> void:
		WorkerThreadPool.wait_for_task_completion(_tasks[model])
		_tasks.erase(model)
		_lock.lock()
		var r = _done.get(model)
		_done.erase(model)
		_lock.unlock()
		_adopt(model, r[0] if r != null else null, int(r[1]) if r != null else 0)

	func _adopt(model: String, built, usec: int) -> void:
		assemble_usec += usec
		assembles += 1
		if _by_model.has(model):
			# Already a template: the new copy is freed, never leaked.
			var extra := built as SkinnedBsrAssembler.AssembledCharacter
			if extra != null and is_instance_valid(extra.skeleton):
				extra.skeleton.free()
			return
		var made := built as SkinnedBsrAssembler.AssembledCharacter
		if made != null and made.skeleton == null:
			made = null
		_by_model[model] = made
		if made != null:
			_label_heights[model] = MonsterDraw.label_height(made.skeleton)
			_radii[model] = MonsterDraw.cull_radius(made.skeleton, float(_label_heights[model]))

	func size() -> int:
		return _by_model.size()

	## A body for `model`: a new AssembledCharacter whose skeleton is a
	## duplicate of the template's, sharing everything else. Null when the
	## model does not assemble.
	func instance(model: String, assemble: Callable) -> SkinnedBsrAssembler.AssembledCharacter:
		if not _by_model.has(model) and _tasks.has(model):
			_finish(model) # round 661's review: the pending assembly, not a second one
		if not _by_model.has(model):
			var sw := Time.get_ticks_usec()
			var built = assemble.call(model)
			_adopt(model, built, Time.get_ticks_usec() - sw)
		var template: SkinnedBsrAssembler.AssembledCharacter = _by_model[model]
		if template == null:
			return null
		var sw2 := Time.get_ticks_usec()
		var body := MonsterDraw.instance_of(template)
		instance_usec += Time.get_ticks_usec() - sw2
		if body != null:
			instances += 1
		return body

	func label_height_of(model: String) -> float:
		return float(_label_heights.get(model, 0.0))

	func radius_of(model: String) -> float:
		return float(_radii.get(model, 1.0))

	## Frees every template's detached skeleton (they are never parented, so
	## nothing else would); returns how many.
	func free_all() -> int:
		# An assembly still under way is waited for, then freed with the rest.
		for model in _tasks.keys():
			WorkerThreadPool.wait_for_task_completion(_tasks[model])
		_tasks.clear()
		for r in _done.values():
			var orphan := (r as Array)[0] as SkinnedBsrAssembler.AssembledCharacter
			if orphan != null and is_instance_valid(orphan.skeleton):
				orphan.skeleton.free()
		_done.clear()
		var freed := 0
		for t in _by_model.values():
			var template := t as SkinnedBsrAssembler.AssembledCharacter
			if template != null and is_instance_valid(template.skeleton):
				template.skeleton.free()
				freed += 1
		_by_model.clear()
		_label_heights.clear()
		_radii.clear()
		return freed

## A body from a template: its skeleton duplicated (the mesh, skin and
## material resources shared), the parsed `.bsr`, the clips and the
## per-model animation cache shared by reference.
static func instance_of(template: SkinnedBsrAssembler.AssembledCharacter) -> SkinnedBsrAssembler.AssembledCharacter:
	if template == null or template.skeleton == null:
		return null
	var skeleton := template.skeleton.duplicate() as Skeleton3D
	if skeleton == null:
		return null
	var body := SkinnedBsrAssembler.AssembledCharacter.new()
	body.skeleton = skeleton
	body.animation_paths = template.animation_paths
	body.parsed = template.parsed
	body.animation_cache = template.animation_cache
	body.idle_animation = template.idle_animation
	body.piece_bones = template.piece_bones
	body.piece_distances = template.piece_distances
	body.skinned_pieces = template.skinned_pieces
	return body
