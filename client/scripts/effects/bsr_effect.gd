extends Node3D
class_name BsrEffect

## A skill effect row whose object is a `.bsr` (round 809): an animated model
## the cast puts in the world -- Hashade's ice pillar
## (`res\mob\karakoram\ishade_ice_ground.bsr`), a bone hunter's arrow, a
## Roc stone. 406 of the table's 6,340 rows name one (MEASURED, 223 skills,
## 79 files); before this round SkillEffects dropped them all.
##
## READ (sro_client.exe; docs/protocol/combat_presentation.md, "Round 809"):
## - The row's object kind is its ObjName's extension through the name map at
##   0xec7180..0xec7400: none 0, bsr 1, efp 2, wav 3, ddj 4
##   (GlobalEffectManager::FUN_00a9d0f0, record +0x37).
## - The object is loaded as a world object (FUN_009ef2f0(path, 0, 1)) and
##   played through CCObjAnimation::vslot_003 -> FUN_00a5b550("default",
##   type, ...): the `default` group, the clip's own IsCyclic deciding loop or
##   one-shot, fades 0, speed 1, weight 1.
## - AT_TARGET with MovTypeSpeed b == 0 (IDecoSkill::FUN_00a51bc0 case 3):
##   CreateCnt objects (CIDecoStopObj) at the target's TargetBone +
##   TargetOffset (FUN_00a4a140, the offset scaled by the target's scale),
##   facing the caster's heading (+0x8c, FUN_009c4260), NOT scaled (no owner:
##   FUN_00a557f0(row, 0)); each plays type 0, then FUN_00a55ac0 plays type 2;
##   it neither shows nor ticks for MovTypeSpeed a ms (obj+0xe0,
##   GlobalDataManager::FUN_00a55c10).
## - On the caster (ActType 0/1/2, FUN_00a51bc0 cases 0-2 / FUN_00a513a0):
##   scaled by the caster's +0xc4, plays type 0, placed at StartBone +
##   StartOffset like an .efp (AT_STOP once, FUN_00a4ddc0).
## - A mover carrying one (FUN_00a4cc70): it plays type 0, is turned along its
##   travel each frame (FUN_00a4c380) and removed on arrival.
## - It goes when its clip leaves the AniMixer: the mixer's callback gets
##   event 100 (`push 0x64` at 0xc53d87, 0xc53f01, 0xc5400c) and
##   FUN_00a55bd0 removes the object. INFERRED from that wiring: a one-shot
##   (fade-out 0) ends the object at its clip's end -- ishade_ice_ground's
##   type 2, 600 ms (MEASURED), so the pillar lives 600 ms.
##
## OURS: material 0 (FUN_009ef2f0's second argument, 0, is OPEN -- possibly
## the material variant); a model whose clips only loop lives LOOP_MAX_S
## unless its owner ends it; the model is assembled once per path on a worker
## (MonsterDraw.Templates) and a spawn waits for it up to QUEUE_MAX_MS; no
## object colour or appear fade.

## The action types played (READ, above).
const TYPE_FIRST := 0
const TYPE_TARGET := 2
## OURS: how long a model with only looping clips lives unattended.
const LOOP_MAX_S := 4.0
## OURS: a spawn whose model is still being assembled after this is dropped.
const QUEUE_MAX_MS := 1500

## Data.pk2, set on the main thread before the first spawn (World3D's deco
## start); the templates assemble from it on a worker.
static var archive: Pk2Reader = null
## Test seam: Callable(path) -> SkinnedBsrAssembler.AssembledCharacter.
static var assembler: Callable = Callable()
static var _templates: MonsterDraw.Templates = null
static var _live: Array = []
static var _queued: Array = [] # of [path, spec, born ms]
static var _clock_ms := 0.0

var path := ""
var assembled: SkinnedBsrAssembler.AssembledCharacter = null
var skel: Skeleton3D = null
## [[ParsedAnimation, loop], ...] in play order; a later one-shot covers the
## loops while it plays (animation_mixer.md: a one-shot at weight 1 hides
## every loop).
var clips: Array = []
var _t := 0.0
var _delay_s := 0.0
var _end_s := -1.0
## The host it follows (caster rows): placed at bone + offset each frame.
var host: Node3D = null
var bone := ""
var offset := Vector3.ZERO
var follow := false
var done := false

static func templates() -> MonsterDraw.Templates:
	if _templates == null:
		_templates = MonsterDraw.Templates.new()
	return _templates

static func _assembler() -> Callable:
	return func(m: String) -> SkinnedBsrAssembler.AssembledCharacter: return BsrEffect._assemble(m)

static func _assemble(p: String) -> SkinnedBsrAssembler.AssembledCharacter:
	if assembler.is_valid():
		return assembler.call(p)
	if archive == null:
		return null
	var a := SkinnedBsrAssembler.assemble_from_archive(archive, p, true)
	if a != null:
		# Its clips read here, off the main thread, into the shared cache.
		for t in [TYPE_FIRST, TYPE_TARGET]:
			SkinnedBsrAssembler.animation_for(archive, a, t)
	return a

## Starts assembling `p` off the main thread (a skill's preload).
static func preload_path(p: String) -> void:
	if p == "" or (archive == null and not assembler.is_valid()):
		return
	templates().request(p, _assembler())

## Puts `p` in the world as `spec` says, now or when its model is ready:
## {"parent": Node, "at": Vector3, "basis": Basis (the turn, unscaled),
##  "scale": float, "types": Array of action types, "delay_ms": int,
##  "host": Node3D, "bone": String, "offset": Vector3, "follow": bool}.
## Returns the object when made now, else null (queued or failed).
static func spawn(p: String, spec: Dictionary) -> BsrEffect:
	if p == "" or (archive == null and not assembler.is_valid()):
		print("EFFECTS bsr %s: no archive to load it from" % p)
		return null
	var t := templates()
	t.poll()
	if t.has(p):
		return _make(p, spec)
	if not t.pending(p):
		t.request(p, _assembler())
	_queued.append([p, spec, int(_clock_ms)])
	return null

static func _make(p: String, spec: Dictionary) -> BsrEffect:
	var parent = spec.get("parent")
	if parent == null or not is_instance_valid(parent):
		return null
	var a := templates().instance(p, _assembler())
	if a == null or a.skeleton == null:
		print("EFFECTS bsr %s: the model did not assemble" % p)
		return null
	var o := BsrEffect.new()
	o.name = "BsrEffect"
	o.path = p
	o.assembled = a
	o.skel = a.skeleton
	o.add_child(o.skel)
	o._delay_s = maxf(float(spec.get("delay_ms", 0)) / 1000.0, 0.0)
	for typ in spec.get("types", [TYPE_FIRST]):
		var anim := _clip(a, int(typ))
		if anim != null:
			o.clips.append([anim, anim.cyclic])
	var last_shot := -1.0
	for c in o.clips:
		if not bool(c[1]):
			last_shot = maxf(last_shot, (c[0] as BanReader.ParsedAnimation).duration_seconds())
	o._end_s = last_shot if last_shot > 0.0 else LOOP_MAX_S
	# A mover's object lives until its carrier goes (READ: removed on arrival).
	if bool(spec.get("until_freed", false)):
		o._end_s = INF
	o.host = spec.get("host")
	o.bone = String(spec.get("bone", "none"))
	o.offset = spec.get("offset", Vector3.ZERO)
	o.follow = bool(spec.get("follow", false)) and o.host != null
	(parent as Node).add_child(o)
	var s := float(spec.get("scale", 1.0))
	var b: Basis = spec.get("basis", Basis.IDENTITY)
	if bool(spec.get("local", false)):
		# On a carrier: its frame, turned along the travel by the carrier.
		o.transform = Transform3D(Basis.IDENTITY.scaled(Vector3(s, s, s)), Vector3.ZERO)
	else:
		o.global_transform = Transform3D(b.orthonormalized().scaled(Vector3(s, s, s)), spec.get("at", Vector3.ZERO))
	if o.follow or bool(spec.get("place_once", false)):
		o._follow_now()
	o.visible = o._delay_s <= 0.0
	o._pose()
	_live.append(o)
	print("EFFECTS bsr %s: %d clip(s), lives %.2f s%s" % [p, o.clips.size(), o._end_s,
		", after %d ms" % int(spec.get("delay_ms", 0)) if o._delay_s > 0.0 else ""])
	return o

static func _clip(a: SkinnedBsrAssembler.AssembledCharacter, typ: int) -> BanReader.ParsedAnimation:
	if a.parsed == null or a.parsed.animation_for(typ, "default") == "":
		return null
	if archive == null:
		# A test's model: its clips are in the cache by path.
		var p := a.parsed.animation_for(typ, "default")
		return a.animation_cache.get(p)
	return SkinnedBsrAssembler.animation_for(archive, a, typ)

## Placed at the host's bone + offset (the body's turn and scale kept).
func _follow_now() -> void:
	if host == null or not is_instance_valid(host):
		return
	var s := absf(global_transform.basis.get_scale().x)
	global_transform = Transform3D(host_turn(host).scaled(Vector3(s, s, s)), SkillEffects.bone_point(host, bone, offset))

## The turn of a body's drawn model (its skeleton's, scale taken out).
static func host_turn(n: Node3D) -> Basis:
	var sk := SkillEffects.skeleton_of(n)
	var b := (sk as Node3D).global_transform.basis if sk != null and sk.is_inside_tree() else n.global_transform.basis
	return b.orthonormalized()

func _pose() -> void:
	if clips.is_empty() or skel == null:
		return
	# The one-shot playing covers the loops (the later one over the earlier);
	# with none playing, the first loop; with no loop, the last held.
	var show = null
	for c in clips:
		if not bool(c[1]) and _t < (c[0] as BanReader.ParsedAnimation).duration_seconds():
			show = c
	if show == null:
		for c in clips:
			if bool(c[1]):
				show = c
				break
	if show == null:
		show = clips[clips.size() - 1]
	Skeleton3DBuilder.apply_ban_pose_at(skel, show[0], _t, bool(show[1]))

## One frame; false when the object is over.
func step(delta: float) -> bool:
	if done or not is_instance_valid(self) or is_queued_for_deletion():
		return false
	var dt := delta
	if _delay_s > 0.0:
		_delay_s -= delta
		if _delay_s > 0.0:
			return true
		# The clip starts when the delay ends, the frame's rest played.
		dt = -_delay_s
		_delay_s = 0.0
		visible = true
	_t += dt
	if follow:
		if host == null or not is_instance_valid(host):
			end()
			return false
		_follow_now()
	if _t >= _end_s:
		end()
		return false
	_pose()
	return true

## Gone now (its clip ended, its mover arrived, its owner ended it).
func end() -> void:
	if done:
		return
	done = true
	if is_instance_valid(self) and not is_queued_for_deletion():
		queue_free()

## Every frame (SkillEffects.tick): the queued spawns whose model is ready are
## made, the rest wait up to QUEUE_MAX_MS; every live object steps.
static func tick(delta: float) -> void:
	_clock_ms += maxf(delta, 0.0) * 1000.0
	if not _queued.is_empty():
		templates().poll()
		var keep: Array = []
		for q in _queued:
			var p := String(q[0])
			if templates().has(p):
				_make(p, q[1])
			elif int(_clock_ms) - int(q[2]) < QUEUE_MAX_MS:
				keep.append(q)
			else:
				print("EFFECTS bsr %s: its model was not ready in %d ms -- not drawn" % [p, QUEUE_MAX_MS])
		_queued = keep
	if _live.is_empty():
		return
	var alive: Array = []
	for o in _live:
		if is_instance_valid(o) and (o as BsrEffect).step(delta):
			alive.append(o)
	_live = alive

static func live_count() -> int:
	return _live.size()

static func queued_count() -> int:
	return _queued.size()

## Every object gone (a world teardown).
static func clear() -> void:
	for o in _live:
		if is_instance_valid(o):
			(o as BsrEffect).end()
	_live.clear()
	_queued.clear()

## The templates freed too (the world leaving).
static func reset() -> void:
	clear()
	if _templates != null:
		_templates.free_all()
	_templates = null
