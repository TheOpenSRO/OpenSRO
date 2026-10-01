extends RefCounted
class_name AppearFade

## A character fades into existence (round 676). Retail does not pop a
## monster or another player in: it fades the model up from nothing over two
## seconds. Everything below is READ from the client (sro_client.exe) unless
## it says otherwise; docs/protocol/appear_fade.md has the addresses.
##
## - **Who starts it.** A spawn (0x3015, `FUN_008a6ca0`) and a group spawn
##   (`FUN_008a6d20`, type 1) both run the object's body reader (vslot 0x64);
##   a character's reader ends in vslot 0x6c, `FUN_009d17e0`, which -- while
##   the object's byte +0x770 is set -- creates a `CIDecoAppear` (class link
##   0x110a770, name string 0xde5610) on the object's id with the float at
##   0xd86ecc, **2.0 seconds**. The byte is 1 from the CICharactor
##   constructor (asm 0x9d2e50) and cleared only for objects the client makes
##   itself (a game script's actor at 0x518514, an icscriptobj at 0x9e26de,
##   `FUN_0050f1b0`). Monsters, NPCs, guards, pets (CICCos) and other players
##   (CICUser, whose vslot 0x6c `FUN_009dbcc0` calls `FUN_009d17e0`) all
##   take it, at the same 2.0 s. Ground items (CIItem, vslot 0x6c
##   `FUN_009c1890`) do not: they pop in.
## - **The curve.** `CIDecoAppear::FUN_00a48a20` starts the alpha at 0 and
##   its rate at 255.0 (the double at 0xd83108) / 2.0; each frame
##   `CIDecoAppear::vslot_009` (0xa48ae0) adds rate x dt (the float at
##   0x110f7fc, the frame's elapsed time -- in seconds, INFERRED, as for the
##   map objects' fade) and, while the sum is <= 255, sets the model's
##   alpha to round(sum) & 0xff; past 255 it sets 0xff and the deco removes
##   itself. Linear, 0 to 255 in 2.0 s.
## - **What it fades.** The alpha goes to the model's compound,
##   `CCompChar` vslot 5 (0xc25590: +0x4c = alpha << 24). Whether the name
##   plate, the shadow or attached effects read it is not read (OPEN); this
##   client fades the model's own meshes only and leaves the plate, the bar
##   and any effect as they were.
## - **The way out** (READ, not drawn here): a despawn (0x3016,
##   `FUN_008a6cc0`, and a group despawn) calls vslot 0x4c with 0, which
##   makes a `CIDecoDisappear` (0x110a790) of **1.5 s** (float 0xd819ec):
##   255 down to 0, then the object is deleted. OPEN for this client.
##
## How it is drawn (OURS). Godot 4.2's GL Compatibility renderer ignores
## GeometryInstance3D.transparency (MEASURED, round 676: a model at
## transparency 1.0 covered all of its pixels), so a fading model is drawn
## with blended twins of its own materials: a StandardMaterial3D duplicated
## with alpha blending, a ShaderMaterial duplicated onto its shader's fade
## twin (ObjectLoader.appear_fade_shader: the foliage *_fade variants and the
## mod shader's `fade` twin), the alpha set on the twin. The twins are shared
## by every model whose fade started in the same frame (one cohort: they are
## always at the same alpha), so a list of hundreds of one species makes one
## twin per material, not one per body. When the fade ends each mesh gets its
## own material back -- the shared, opaque one -- and the twins are dropped.
## A material with no fade twin (a shader this file does not know) is left
## as it is: that piece pops in, as before (counted in `unfadable`).

## The fade-in's length, seconds. READ: the float at 0xd86ecc (2.0), passed
## by `FUN_009d17e0` (asm 0x9d190b) to `CIDecoAppear::FUN_00a48a20`.
const APPEAR_SECONDS := 2.0
## The fade-out's length on a despawn, seconds. READ: the float at 0xd819ec
## (1.5), passed by `IGIDObject::FUN_009c32f0` / `FUN_009d3c90` to
## `CIDecoDisappear::FUN_00a49970`. Not drawn by this client yet (OPEN).
const DISAPPEAR_SECONDS := 1.5
## Full alpha. READ: the double at 0xd83108 (255.0).
const FULL := 255.0
## Meta on a mesh while it fades: the material it gets back. BerserkLook
## reads it (original_material), so a berserk starting mid-fade keeps the
## real one.
const ORIGINAL_META := "srrevamp_appear_original"

## The model's alpha byte `elapsed` seconds into a fade of `duration`, as
## `CIDecoAppear::vslot_009` sets it: round(255 / duration x elapsed) while
## that is <= 255, else 255. (Retail rounds with the FPU's
## round-half-to-even; round() here goes half away from zero -- one step of
## 255 at an exact half, OURS.)
static func alpha_at(elapsed: float, duration: float = APPEAR_SECONDS) -> int:
	if duration <= 0.0:
		return 255
	var a := FULL / duration * maxf(elapsed, 0.0)
	if a > FULL:
		return 255
	return int(round(a)) & 0xff

## Whether a fade of `duration` is over `elapsed` seconds in: the deco's sum
## has passed 255 (it set 0xff and removed itself).
static func done_at(elapsed: float, duration: float = APPEAR_SECONDS) -> bool:
	return duration <= 0.0 or FULL / duration * elapsed > FULL

## The meshes a model is drawn with: every MeshInstance3D at or under
## `model`, not counting an effect's (under an EfpEffect). A name plate
## (Label3D), a bar or mark (Sprite3D) and a collider are not meshes.
static func instances_of(model: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if model == null:
		return out
	var stack: Array[Node] = [model]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is EfpEffect:
			continue
		if n is MeshInstance3D:
			out.append(n)
		for c in n.get_children():
			stack.append(c)
	return out

## The material `mi` really draws with: the one it gets back after a fade
## when it is fading, else its material_override.
static func original_material(mi: MeshInstance3D) -> Material:
	if mi.has_meta(ORIGINAL_META):
		return mi.get_meta(ORIGINAL_META)
	return mi.material_override

## A blended twin of `src` at alpha 0, or null when `src` has none. OURS:
## depth is written (depth_draw_always) so the model's near faces stay in
## front of its far ones while it is translucent.
static func fade_twin(src: Material) -> Material:
	if src is BaseMaterial3D:
		var std := (src as BaseMaterial3D).duplicate() as BaseMaterial3D
		std.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		std.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS
		std.set_meta("srrevamp_appear_base_alpha", (src as BaseMaterial3D).albedo_color.a)
		set_twin_alpha(std, 0.0)
		return std
	if src is ShaderMaterial:
		var shader := ObjectLoader.appear_fade_shader((src as ShaderMaterial).shader)
		if shader == null:
			return null
		var sm := (src as ShaderMaterial).duplicate() as ShaderMaterial
		sm.shader = shader
		set_twin_alpha(sm, 0.0)
		return sm
	return null

## Sets a twin's alpha, 0..1.
static func set_twin_alpha(twin: Material, a: float) -> void:
	if twin is BaseMaterial3D:
		var std := twin as BaseMaterial3D
		var c := std.albedo_color
		c.a = float(std.get_meta("srrevamp_appear_base_alpha", 1.0)) * a
		std.albedo_color = c
	elif twin is ShaderMaterial:
		(twin as ShaderMaterial).set_shader_parameter("appear_alpha", a)

## Models fading in together: started in the same frame, so always at the
## same alpha, and sharing their materials' twins.
class Cohort:
	var elapsed := 0.0
	var duration := APPEAR_SECONDS
	## source material instance id -> its twin (null: none)
	var twins := {}
	## [MeshInstance3D, surface (-1: material_override), original, twin]
	var meshes: Array = []
	var models: Array = []

## The fades running, stepped once a physics step by World3D.
class Fades:
	var _cohorts: Array[Cohort] = []
	## The cohort started since the last step, which new models join.
	var _open: Cohort = null
	var _started := 0
	var _finished := 0
	var _unfadable := 0

	## Starts `model` fading in from nothing: from now every mesh under it
	## (instances_of) draws with its material's twin at alpha 0, the deco's
	## start value, until step() raises it.
	func start(model: Node, duration: float = APPEAR_SECONDS) -> void:
		if model == null or not is_instance_valid(model) or fading(model):
			return
		if _open == null or _open.duration != duration:
			_open = Cohort.new()
			_open.duration = duration
			_cohorts.append(_open)
		var co := _open
		var took := false
		for mi in AppearFade.instances_of(model):
			if mi.has_meta(AppearFade.ORIGINAL_META):
				continue
			if mi.material_override != null:
				took = _take(co, mi, -1, mi.material_override) or took
			elif mi.mesh != null:
				for s in range(mi.mesh.get_surface_count()):
					var src := mi.get_active_material(s)
					if src != null:
						took = _take(co, mi, s, src) or took
		if took:
			co.models.append(model)
			_started += 1

	func _take(co: Cohort, mi: MeshInstance3D, surface: int, src: Material) -> bool:
		var id := src.get_instance_id()
		if not co.twins.has(id):
			co.twins[id] = AppearFade.fade_twin(src)
		var twin: Material = co.twins[id]
		if twin == null:
			_unfadable += 1
			return false
		var original: Material = src if surface < 0 else mi.get_surface_override_material(surface)
		if surface < 0:
			mi.set_meta(AppearFade.ORIGINAL_META, original)
			mi.material_override = twin
		else:
			mi.set_surface_override_material(surface, twin)
		co.meshes.append([mi, surface, original, twin])
		return true

	## Advances every fade by `delta` seconds: the twins take the cohort's
	## alpha; a finished cohort gives each mesh its own material back and is
	## dropped.
	func step(delta: float) -> void:
		_open = null
		if _cohorts.is_empty():
			return
		var keep: Array[Cohort] = []
		for co in _cohorts:
			co.elapsed += delta
			if AppearFade.done_at(co.elapsed, co.duration):
				_restore(co)
				_finished += co.models.size()
				continue
			var a := float(AppearFade.alpha_at(co.elapsed, co.duration)) / AppearFade.FULL
			for twin in co.twins.values():
				if twin != null:
					AppearFade.set_twin_alpha(twin, a)
			keep.append(co)
		_cohorts = keep

	## Gives each still-fading mesh its own material back. A mesh whose
	## material something else has replaced since (BerserkLook) is left with
	## what it has now.
	func _restore(co: Cohort) -> void:
		for m in co.meshes:
			var mi = m[0]
			if mi == null or not is_instance_valid(mi):
				continue
			var surface: int = m[1]
			if surface < 0:
				if (mi as MeshInstance3D).material_override == m[3]:
					(mi as MeshInstance3D).material_override = m[2]
				(mi as Node).remove_meta(AppearFade.ORIGINAL_META)
			elif (mi as MeshInstance3D).get_surface_override_material(surface) == m[3]:
				(mi as MeshInstance3D).set_surface_override_material(surface, m[2])
		co.meshes.clear()
		co.twins.clear()

	## Ends every fade at once, opaque (the world leaving).
	func finish_all() -> void:
		for co in _cohorts:
			_restore(co)
			_finished += co.models.size()
		_cohorts.clear()
		_open = null

	func running() -> int:
		var n := 0
		for co in _cohorts:
			for m in co.models:
				if is_instance_valid(m):
					n += 1
		return n

	func fading(model: Node) -> bool:
		for co in _cohorts:
			if co.models.has(model):
				return true
		return false

	## The alpha (0..255) `model` is drawn at, or 255 when it is not fading.
	func alpha_of(model: Node) -> int:
		for co in _cohorts:
			if co.models.has(model):
				return AppearFade.alpha_at(co.elapsed, co.duration)
		return 255

	## How many twins are alive (shared materials made for the fades running).
	func twin_count() -> int:
		var n := 0
		for co in _cohorts:
			for t in co.twins.values():
				if t != null:
					n += 1
		return n

	func started() -> int:
		return _started

	func finished() -> int:
		return _finished

	func unfadable() -> int:
		return _unfadable
