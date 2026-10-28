extends Node3D
class_name AuraModel

## A buff aura's `.bsr` row (round 838): a model kept on its owner's bone for
## as long as the buff runs -- the archive's mall visuals (horns, crowns,
## wings and capes: `res\item\electus\electus_m_visual_NN.bsr` on `Bip01
## Head` / `Bip01 Spine1`, ACT_L AT_LOOP, MEASURED skilleffect.txt) and
## retail's mall balloons (65 AT_LOOP rows). Before this round SkillEffects
## drew none of them (round 809, OPEN).
##
## READ (sro_client.exe; BsrEffect's header has the object path):
## - A row's object of kind bsr is loaded as a world object and kept by the
##   decoration like an .efp (FUN_00a51bc0 cases 0-2 / FUN_00a513a0); an
##   AT_LOOP row's is placed every frame (its entry's follow flag 1,
##   CIDecoSkill::vslot_014 -> FUN_00a4ddc0) and goes when the decoration
##   ends (the buff's end, FUN_00a53120).
## - The placement (IDecoSkill::FUN_00a4a680, a plain bone: flags 2): the
##   body's matrix times the bone's, the model scale taken out of the bone's
##   (the 1/scale step at 0xa4a8a0), the bone's rotation kept; the row's
##   StartOffset turned by the body and added to the bone's position. With no
##   bone, the body's own matrix. So the model is drawn in the bone's frame
##   at the body's scale.
## - MEASURED (the .bms vertex extents, Data.pk2): the visuals' meshes are
##   authored in their bone's frame -- the horns at x 1.1..4.6, y +-2.3
##   (Bip01 Head: x up the bone, y across the head), the wings 09 at
##   x -0.6..11.3, y +-17.7, z -3.7..-1.0 (behind Bip01 Spine1) -- so the
##   bone's frame is where they belong; the models have no skeleton (the
##   .bsr names no .bsk), which is why BsrEffect, built for cast objects with
##   their own clips, does not take them.
##
## OURS: the model is built by ObjectLoader (prepared on a worker, committed
## on the main thread, one template per path, shared meshes and textures) and
## drawn with the object shader; its collision is dropped; it vanishes at the
## buff's end (no fade, INFERRED from the removal path); a cloth piece runs in
## ClothDriver as a placed object's does.

## Data.pk2 (World3D sets BsrEffect.archive; this class reads it).
static func _archive() -> Pk2Reader:
	return BsrEffect.archive

## path -> Node3D template (not in the tree), or null for a path that failed.
static var _templates: Dictionary = {}
## path -> WorkerThreadPool task id preparing it.
static var _tasks: Dictionary = {}
## path -> the prepared object (written by the task, under _lock).
static var _done: Dictionary = {}
static var _lock := Mutex.new()
## The textures every model shares (ObjectLoader's cache shape).
static var _textures: Dictionary = {}
## Test seam: Callable(path) -> Node3D (a template), instead of the archive.
static var builder: Callable = Callable()

var path := ""
var host: Node3D = null
var bone := ""
var offset := Vector3.ZERO
var model: Node3D = null
var _skel: Skeleton3D = null
var _bone := -1

## A model for `p` on `host` at `bone` + `offset`, kept until released. Its
## model appears when its template is ready (a worker prepares it).
static func spawn(p: String, on: Node3D, at_bone: String, at_offset: Vector3) -> AuraModel:
	if p == "" or on == null or not is_instance_valid(on):
		return null
	if _archive() == null and not builder.is_valid():
		print("EFFECTS aura model %s: no archive to load it from" % p)
		return null
	var a := AuraModel.new()
	a.name = "AuraModel"
	a.path = p
	a.host = on
	a.bone = at_bone.strip_edges()
	a.offset = at_offset
	a.top_level = true
	on.add_child(a)
	request(p)
	a._build()
	a._place()
	return a

## Starts preparing `p` off the main thread, unless it is ready or under way.
static func request(p: String) -> void:
	if _templates.has(p) or _tasks.has(p) or builder.is_valid():
		return
	var arc := _archive()
	if arc == null:
		return
	_tasks[p] = WorkerThreadPool.add_task(func() -> void:
		var prepared := ObjectLoader.prepare_object(arc, p)
		AuraModel._lock.lock()
		AuraModel._done[p] = prepared
		AuraModel._lock.unlock(), true, "aura model %s" % p)

## Adopts finished preparations as templates (main thread).
static func poll() -> void:
	for p in _tasks.keys():
		if not WorkerThreadPool.is_task_completed(_tasks[p]):
			continue
		PoolWait.task(_tasks[p])
		_tasks.erase(p)
		_lock.lock()
		var prepared = _done.get(p)
		_done.erase(p)
		_lock.unlock()
		var t: Node3D = null
		if prepared != null:
			t = ObjectLoader.commit_object(prepared, _textures)
		_adopt(p, t)

static func _adopt(p: String, t: Node3D) -> void:
	if t != null:
		# An attachment is not something to stand on or be blocked by.
		for body in t.find_children("*", "StaticBody3D", true, false):
			(body as Node).get_parent().remove_child(body)
			(body as Node).free()
	_templates[p] = t
	print("EFFECTS aura model %s: %s" % [p, "ready" if t != null else "did not load"])

## Builds this object's model from its template once there is one.
func _build() -> void:
	if model != null:
		return
	if builder.is_valid() and not _templates.has(path):
		_adopt(path, builder.call(path))
	poll()
	if not _templates.has(path):
		return
	var t: Node3D = _templates[path]
	if t == null:
		set_process(false)
		return
	model = t.duplicate() as Node3D
	add_child(model)
	ClothDriver.enlist(model)

func _process(_delta: float) -> void:
	if host == null or not is_instance_valid(host):
		queue_free()
		return
	if model == null:
		_build()
	_place()

## The bone's skeleton, re-found when the body's is rebuilt.
func _skeleton() -> Skeleton3D:
	if _skel != null and is_instance_valid(_skel) and not _skel.is_queued_for_deletion() and _skel.is_inside_tree():
		return _skel
	_skel = SkillEffects.skeleton_of(host)
	_bone = -1
	var b := bone.trim_prefix("@").trim_prefix("#")
	if _skel != null and b != "" and b.to_lower() != "none" and b != "*":
		_bone = _skel.find_bone(b)
	return _skel

## Places the model (see the header's READ): the bone's frame at the body's
## scale, the offset in the body's frame; the body's own frame without a bone.
func _place() -> void:
	if host == null or not is_instance_valid(host) or not is_inside_tree():
		return
	var skel := _skeleton()
	if skel != null and skel.is_inside_tree():
		var g := skel.global_transform
		if _bone >= 0:
			var pose := skel.get_bone_global_pose(_bone)
			global_transform = Transform3D(g.basis * pose.basis.orthonormalized(), g * (pose.origin + offset))
		else:
			global_transform = g * Transform3D(Basis.IDENTITY, offset)
	elif host.is_inside_tree():
		global_transform = host.global_transform * Transform3D(Basis.IDENTITY, offset)

## The buff ended: the model goes.
func release() -> void:
	queue_free()

## Every model's templates and tasks go (a world teardown). Waits for a
## preparation still out (ShutdownRelease.wait_tasks has why).
static func reset() -> void:
	wait_pending()
	for p in _templates:
		var t = _templates[p]
		if t != null and is_instance_valid(t):
			(t as Node).free()
	_templates.clear()
	_textures.clear()
	builder = Callable()

## Waits for every preparation still running and drops what it made.
static func wait_pending() -> void:
	for p in _tasks.keys():
		PoolWait.task(_tasks[p])
	_tasks.clear()
	_lock.lock()
	_done.clear()
	_lock.unlock()
