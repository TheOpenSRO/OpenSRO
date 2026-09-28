extends RefCounted
class_name EfpSim

## The particle simulation of one playing .efp effect (round 620): the
## client's own per-frame rules, run over the typed tree EfpReader.decode
## returns. Pure data -- no nodes, no textures -- so the headless tests drive
## it on synthetic trees. EfpEffect draws what it holds.
##
## Every rule below is labelled. READ = read from sro_client.exe at the
## address given (docs/protocol/EFP_FORMAT.md, "Playback"); INFERRED = drawn
## from something READ or MEASURED with the reasoning given; OURS = a choice
## of this client where the binary was not read.
##
## == Time ==
## A frame is 50 ms (READ): the effect clock UI_ALCHEMYBOX::FUN_00bc1490
## adds the game's millisecond delta to an accumulator and, once it reaches
## 50, hands floor(acc / 50.0) frames (the double 50.0 at 0x00d8f0b0) to every
## effect's update (CRTModParticle::FUN_00c80ff0 -> CEFEffect::vslot_000 ->
## +0x28c). The delta is milliseconds: the game loop (funcs_017, FUN near
## 0x00ba4106) caps it at 3000 beside a float twin capped at 3.0 (INFERRED
## seconds). At >= 20 fps retail steps one frame per update; this client
## steps one frame per 50 ms of scene time.
##
## == Structure (READ, FUN_00c86cd0) ==
## A node is a particle system. Its StaticEmit spawns particles; spawning a
## particle also creates one emitter for each child node, owned by that
## particle, so a child node emits relative to each of its parent's particles.
## The root node's emitter is owned by the effect itself, whose age counts
## frames since the effect started.
##
## == Emission (READ, FUN_00c84e70 / FUN_00c87a20; EfpReader.emit_tick) ==
## The emitter frame is EfpReader.emit_tick, the reader's one copy of it: with
## t = owner age - delay, t >= duration stops the emitter; every `interval`
## frames a trigger adds `per_trigger` to a live-particle accumulator clamped
## to `max_live`, and int(new) - int(old) particles spawn; a particle of the
## emitter that dies takes 1.0 back off it. So (0,1,1,1,0.0) emits nothing and
## (0,20,1,20,1.0) adds one a frame up to 20 alive. The two quality globals
## (DAT_01114d54 interval multiplier, DAT_01114d58 threshold) are
## `interval_mul` / `threshold` below, 0 / 0 = full quality, their .bss start
## value (which option sets them in retail, and its default, is OPEN).
##
## == A particle's life (READ, the extinct executors) ==
## Its age counts frames from 0. NormalTimeExtinct (FUN_00c84e20): after the
## age passes N-1 the particle dies. NormalTimeLoop (FUN_00c84dd0): the age
## wraps modulo N. NeverExtinct (FUN_00c84d80): the age advances until it is
## 1 and then stays (`if age != 1: age += frames`), and a node whose N is 0
## kills the particle (the executor's `[def+0x7c] == 0` branch).
##
## == The per-particle program (READ, EFEffect::FUN_00c893f0) ==
## Scheduling (READ, the loop at 0x00ca9276-0x00ca9354): a command's key i
## runs at frame ftol(f_i), where f_0 = start and f_{i+1} = f32(f_i + step),
## while f_i <= end -- a single-precision running sum, truncated by the fldcw
## at 0x00ca92b0. Value i of a Frame* parameter is key i.
## The command's `space` byte is added to its opcode by its factory (READ:
## FUN_00ca8140 registrations, e.g. SetConeVel = 0x3e + space), and the
## interpreter's switch gives each opcode its meaning:
##   position commands (SetPosition, SetConePos, SetBANPos): space = r*3 + o;
##     o: 0 add to the current position, 1 start from the parent particle's
##     position, 2 from the "link" object's; r: the value is rotated by 0 no
##     matrix, 1 the particle's own rotation, 2 the parent's, 3 the link's.
##   SetSpherePos: a point in the unit ball by rejection sampling of
##     (r - 0.5) * 2 from the 5000-entry random table. Space 1 / 2: the point
##     times the value, added to the parent's / link's position. Space 0
##     (0x00c8a4c5-0x00c8a5d4): the point is written straight INTO the
##     position, and then position += value * a stack vector the case never
##     sets. That vector is whatever an earlier command of the same frame's
##     run left there -- the cone cases, ConeForce, Attraction and SetSpherePos
##     itself write it -- and uninitialised when none did. This client keeps
##     that vector per particle run (`_scratch`) and starts it at zero (OURS
##     for the uninitialised case: 66 retail commands use space 0).
##   SetVelocity / SetConeVel: velocity = the value rotated by space 0 none,
##     1 own, 2 parent, 3 link. Force / ConeForce add the same to the velocity
##     (READ, the add at 0x00c8aae8). ConeForce space 0 (case 0x46) falls
##     through into case 0x47 (READ, 0x00c8ac1d -> 0x00c8ac23), so it adds a
##     second cone rotated by the particle's own rotation.
##   Attraction: velocity += normalize(pos - parent pos) * value (space 0),
##     the link's (space 1).
##   Cone (AngleVector1 {a, b}): the vector (0, lerp(b.x, b.y, r1), 0) turned
##     r2 * b.z about Z (IDecoSkill::FUN_00a4d820: FUN_00b44b40 fsin,
##     FUN_00b44a10 fcos) then r3 * 2*pi about Y (FUN_0043cda0). b.z is a.z in
##     radians in every retail value (MEASURED); that the trig takes b is
##     INFERRED.
##   SetRotation* / SetBANRot: rotation = M (space 0), M then own (1), M then
##     the parent's (2), then the link's (3). SetRVelocity*: the per-frame
##     rotation. SetShapeRot / SetShapeRotVel: the shape's rotation and its
##     per-frame step.
##   SetGraphScale: scale = the key's Vector3. SetGraphDiffuse: colour = the
##     key's D3DCOLOR. TextureSlide: the UV rectangle (u0, v0, du, dv) at
##     particle +0x22c = the key (READ, 0x00c8af77). Its head is unused here
##     (OPEN). SetGraphRandomScale: scale = the node's BlendScaleGraph at a
##     random time (FUN_00c89140: first key before a, last after b, linear
##     between; which var the pointer names is INFERRED to be the node's first
##     BlendScaleGraph).
##   The link (+0x34) is the particle the same emitter spawned before this
##     one that is still alive (READ, round 621: the emitter's particle list
##     at emitter+0x30 has prev offset 0x34 and next offset 0x38,
##     FUN_00c88320; the particle init FUN_00c88490 appends at the tail;
##     a death unlinks). Every variant that names the link does nothing
##     when the particle has none -- the oldest live one of its emitter
##     (READ: the interpreter tests +0x34 first in every such case; the
##     full list is names_link below and EFP_FORMAT.md "The link"). See
##     EfpLinks for the chain's drawing.
##
## == Motion per frame (READ, CEFUpdater::vslot_002) ==
## A particle follows its parent's movement (OURS: translation only; retail
## also applies the parent's rotation change), then position += velocity,
## rotation = rotation * rotation velocity, shape = shape * shape velocity.
## A new particle starts at its parent's position with its parent's velocity
## and rotation, scale 1, colour 0xFFFFFFFF, UV rectangle (0, 0, 1, 1) (READ,
## the particle init in EFEffect, funcs_020 near 0x00c87360's callers).
##
## == Order within a frame (OURS where retail's order was not read) ==
## 1 motion, 2 each particle's commands for its age, 3 emission (new
## particles run their frame-0 commands at once, so none is drawn at its
## parent's origin first), 4 ages advance.
##
## == Caps (OURS) ==
## MAX_PARTICLES per effect. Across all live effects, MAX_TOTAL - RESERVE
## for everyone else's effects and the full MAX_TOTAL for `reserved` ones
## (the local player's casts, hits and level-up), so a crowd's auras cannot
## starve the player's own effects. A refused spawn is counted in `dropped`
## and gives its 1.0 back to the emitter.

const FRAME_SEC := 0.05 ## READ: 50 ms, see the header
const MAX_STEPS_PER_ADVANCE := 10 ## OURS: a long hitch catches up at most 0.5 s
const MAX_PARTICLES := 300 ## OURS
const MAX_TOTAL := 2000 ## OURS: ~7 us a particle-frame in GDScript (MEASURED), so <= ~14 ms a 50 ms frame
const RESERVE := 600 ## OURS: of MAX_TOTAL, kept for reserved (own) effects
const MAX_KEYS := 100000 ## OURS: bound on one command's scheduling loop

const LIFE_EXTINCT := 0
const LIFE_LOOP := 1
const LIFE_NEVER := 2

## The number of particles alive across every EfpSim (the global cap).
static var live_total := 0
## The emission quality globals handed to EfpReader.emit_tick (see above).
static var interval_mul := 0
static var threshold := 0

## Opcode bases (READ: the FUN_00ca8140 factory registrations add the command's
## space byte to these).
const OP_BASE := {
	"SetRotationMat": 0x00, "SetRVelocityMat": 0x04, "SetRotation": 0x05,
	"SetRVelocity": 0x09, "SetRotationAxis": 0x0a, "SetRVelocityAxis": 0x0e,
	"SetBANRot": 0x0f, "SetPosition": 0x13, "SetConePos": 0x1f,
	"SetBANPos": 0x2b, "SetSpherePos": 0x37, "SetVelocity": 0x3a,
	"SetConeVel": 0x3e, "Force": 0x42, "ConeForce": 0x46, "Attraction": 0x4a,
	"TextureSlide": 0x4c, "SetGraphScale": 0x4d, "SetGraphRandomScale": 0x4e,
	"SetGraphDiffuse": 0x4f, "SetShapeRot": 0x50, "SetShapeRotVel": 0x51,
}

# The command families _run dispatches on (compiled once, not a string match
# per particle per frame).
enum { K_POS, K_CONEPOS, K_BANPOS, K_SPHERE, K_VEL, K_CONEVEL, K_FORCE, K_CONEFORCE,
	K_ATTRACT, K_ROT, K_BANROT, K_RVEL, K_SHAPE, K_SHAPEVEL, K_SCALE, K_DIFFUSE, K_SLIDE,
	K_RANDSCALE }
const KIND := {
	"SetPosition": K_POS, "SetConePos": K_CONEPOS, "SetBANPos": K_BANPOS,
	"SetSpherePos": K_SPHERE, "SetVelocity": K_VEL, "SetConeVel": K_CONEVEL,
	"Force": K_FORCE, "ConeForce": K_CONEFORCE, "Attraction": K_ATTRACT,
	"SetRotationMat": K_ROT, "SetRotation": K_ROT, "SetRotationAxis": K_ROT,
	"SetBANRot": K_BANROT, "SetRVelocityMat": K_RVEL, "SetRVelocity": K_RVEL,
	"SetRVelocityAxis": K_RVEL, "SetShapeRot": K_SHAPE, "SetShapeRotVel": K_SHAPEVEL,
	"SetGraphScale": K_SCALE, "SetGraphDiffuse": K_DIFFUSE, "TextureSlide": K_SLIDE,
	"SetGraphRandomScale": K_RANDSCALE,
}

## One node, compiled once per file and shared by every playing copy.
class Tpl:
	var node: EfpReader.EfpNode
	var index: int
	var parent: int = -1 ## -1 for the root (owned by the effect)
	var children: Array[int] = []
	var frames: int
	var life: int
	var emit = null ## {delay, duration, interval, max_live, per_trigger} or null
	var schedule: Array = [] ## frame -> Array of [kind, space, payload] (see _payload)
	var scale_graph = null ## the node's first BlendScaleGraph var, or null
	var unsupported: PackedStringArray = PackedStringArray()

## A compiled effect: the node templates in preorder (parents first).
class Template:
	var tpls: Array[Tpl] = []
	var unsupported: PackedStringArray = PackedStringArray() ## names no rule covers

class Particle:
	var tpl: int
	var emitter: Emitter ## the emitter that spawned it (its death refunds acc)
	var parent: Particle ## null for the effect's own root holder
	var age: int = 0
	var alive := true
	var pos := Vector3.ZERO
	var prev_pos := Vector3.ZERO
	var vel := Vector3.ZERO
	var rot := Basis.IDENTITY
	var rvel := Basis.IDENTITY
	var shape := Basis.IDENTITY
	var shape_vel := Basis.IDENTITY
	var has_rvel := false
	var has_shape_vel := false
	var scale := Vector3.ONE
	var color := 0xFFFFFFFF
	var uv := Vector4(0, 0, 1, 1)
	## The emitter's previous live particle (+0x34) and next one (+0x38).
	var link: Particle = null
	var next_link: Particle = null

class Emitter:
	var tpl: int
	var owner: Particle
	var acc := 0.0
	var done := false
	## The newest live particle of this emitter (the list's tail).
	var tail: Particle = null

var template: Template
var particles: Array[Particle] = []
var emitters: Array[Emitter] = []
var age := 0 ## the effect's own age, in frames
var dropped := 0 ## spawns refused by a cap
var spawned := 0
## The local player's own effect: may use the RESERVE share of MAX_TOTAL.
var reserved := false
var _root := Particle.new() ## the effect's origin: owner of the root emitter
var _acc := 0.0
var _rng := RandomNumberGenerator.new()
var _scratch := Vector3.ZERO ## the interpreter's stack vector (see SetSpherePos)

## Compiles a decoded file (or its root node) into a template. Unsupported
## command names are listed, not fatal.
static func compile(root: EfpReader.EfpNode) -> Template:
	var t := Template.new()
	if root == null:
		return t
	_compile_node(t, root, -1)
	return t

static func _compile_node(t: Template, n: EfpReader.EfpNode, parent: int) -> void:
	var tp := Tpl.new()
	tp.node = n
	tp.index = t.tpls.size()
	tp.parent = parent
	tp.frames = maxi(n.frames, 0)
	tp.life = LIFE_LOOP if n.loops() else (LIFE_NEVER if n.never_extinct() else LIFE_EXTINCT)
	tp.emit = n.emission()
	for v in n.vars:
		if v is Dictionary and String(v.get("type", "")) == "BlendScaleGraph" and tp.scale_graph == null:
			tp.scale_graph = v.get("value")
	tp.schedule.resize(tp.frames)
	for f in range(tp.frames):
		tp.schedule[f] = []
	for c in n.commands:
		if not KIND.has(c.name):
			if not tp.unsupported.has(c.name):
				tp.unsupported.append(c.name)
			if not t.unsupported.has(c.name):
				t.unsupported.append(c.name)
			continue
		var kind: int = KIND[c.name]
		for pair in key_frames(c, tp.frames):
			var pl = _payload(kind, c, int(pair[1]))
			if pl == null:
				continue
			(tp.schedule[int(pair[0])] as Array).append([kind, int(c.space), pl])
	t.tpls.append(tp)
	if parent >= 0:
		t.tpls[parent].children.append(tp.index)
	for k in n.children:
		_compile_node(t, k, tp.index)

## The value one key of a command runs with, resolved once at compile time
## so the per-particle loop does no dictionary or key lookups: a Vector3, a
## Basis, a colour int, a Vector4, the cone's b Vector3, or true; null when
## the key has no value (the command then does nothing, as before).
static func _payload(kind: int, c: EfpReader.EfpCommand, key: int):
	var val = c.value
	if not (val is Dictionary):
		return true if kind == K_RANDSCALE else null
	match kind:
		K_POS, K_SPHERE, K_VEL, K_FORCE:
			return val.get("value", Vector3.ZERO)
		K_CONEPOS, K_CONEVEL, K_CONEFORCE:
			return val.get("b", Vector3.ZERO)
		K_BANPOS:
			var ps: PackedVector3Array = val.get("positions", PackedVector3Array())
			return ps[key] if key < ps.size() else null
		K_ATTRACT:
			return float(val.get("value", 0.0))
		K_ROT, K_RVEL, K_SHAPE, K_SHAPEVEL:
			return basis_of(val.get("matrix"))
		K_BANROT:
			var ms: Array = val.get("matrices", [])
			return basis_of(ms[key]) if key < ms.size() else null
		K_SCALE:
			var fs: PackedVector3Array = val.get("frames", PackedVector3Array())
			return fs[key] if key < fs.size() else null
		K_DIFFUSE:
			var cs: PackedInt64Array = val.get("colors", PackedInt64Array())
			return cs[key] if key < cs.size() else null
		K_SLIDE:
			var ks: Array = val.get("keys", [])
			return ks[key] if key < ks.size() else null
		K_RANDSCALE:
			return true
	return null

## [frame, key] pairs a command runs at over a program of n frames (READ, the
## scheduling loop: see the header). Frames outside [0, n) are dropped.
static func key_frames(c: EfpReader.EfpCommand, n: int) -> Array:
	var out: Array = []
	var fr := c.frame_range(n)
	if not bool(fr["ok"]):
		return out
	var st := EfpReader.f32(float(fr["step"]))
	var endf := float(int(fr["end"]))
	var f := EfpReader.f32(float(int(fr["start"])))
	var key := 0
	while f <= endf and key < MAX_KEYS:
		var fi := EfpReader.ftol(f)
		if fi >= 0 and fi < n:
			out.append([fi, key])
		key += 1
		var nf := EfpReader.f32(f + st)
		if nf <= f:
			break
		f = nf
	return out

func _init(tmpl: Template = null, seed_value: int = 0) -> void:
	template = tmpl
	if seed_value != 0:
		_rng.seed = seed_value
	else:
		_rng.randomize()
	restart()

## Starts the effect over: no particles, the root emitter fresh.
func restart() -> void:
	clear()
	age = 0
	_acc = 0.0
	if template != null and not template.tpls.is_empty():
		var e := Emitter.new()
		e.tpl = 0
		e.owner = _root
		emitters.append(e)

## Drops every particle (and its share of the global count) and every
## emitter: the effect is finished.
func clear() -> void:
	for p in particles:
		if p.alive:
			live_total -= 1
			p.alive = false
	particles.clear()
	emitters.clear()

## True once nothing is alive and no emitter can spawn again.
func finished() -> bool:
	if not particles.is_empty():
		return false
	for e in emitters:
		if not e.done:
			return false
	return true

## Advances by `delta` seconds of scene time, one frame per 50 ms. Returns
## the frames stepped.
func advance(delta: float) -> int:
	_acc += maxf(delta, 0.0)
	var n := 0
	while _acc >= FRAME_SEC and n < MAX_STEPS_PER_ADVANCE:
		_acc -= FRAME_SEC
		step()
		n += 1
	if n == MAX_STEPS_PER_ADVANCE:
		_acc = minf(_acc, FRAME_SEC)
	return n

## One 50 ms frame.
func step() -> void:
	if template == null:
		return
	var tpls := template.tpls
	# 1 motion
	for p in particles:
		p.prev_pos = p.pos
	for p in particles:
		var par := p.parent
		if par != null and par != _root and par.alive:
			p.pos += par.pos - par.prev_pos
		p.pos += p.vel
		if p.has_rvel:
			p.rot = p.rvel * p.rot
		if p.has_shape_vel:
			p.shape = p.shape_vel * p.shape
	# 2 commands for each particle's age
	for p in particles:
		var sched: Array = tpls[p.tpl].schedule
		if p.age >= 0 and p.age < sched.size():
			var list: Array = sched[p.age]
			if not list.is_empty():
				_run_list(p, tpls[p.tpl], list)
	# 3 emission (the list grows as particles spawn child emitters)
	var i := 0
	while i < emitters.size():
		_emit(emitters[i])
		i += 1
	# 4 ages advance (newborns included: their frame 0 has run)
	var keep: Array[Particle] = []
	for p in particles:
		var tp: Tpl = tpls[p.tpl]
		match tp.life:
			LIFE_EXTINCT:
				p.age += 1
				if p.age >= tp.frames:
					p.alive = false
			LIFE_LOOP:
				p.age += 1
				if tp.frames > 0:
					p.age %= tp.frames
			LIFE_NEVER:
				if p.age != 1:
					p.age += 1
				if tp.frames == 0:
					p.alive = false
		if p.alive:
			keep.append(p)
		else:
			_on_death(p)
	particles = keep
	# emitters whose owner died stop (OURS); finished ones are dropped, so a
	# frame walks only the emitters that can still spawn
	var live_emitters: Array[Emitter] = []
	for e in emitters:
		if not e.done and (e.owner == _root or e.owner.alive):
			live_emitters.append(e)
	emitters = live_emitters
	age += 1
	_root.prev_pos = _root.pos

func _owner_age(e: Emitter) -> int:
	return age if e.owner == _root else e.owner.age

func _emit(e: Emitter) -> void:
	if e.done:
		return
	var tp: Tpl = template.tpls[e.tpl]
	if tp.emit == null:
		e.done = true
		return
	var r := EfpReader.emit_tick(tp.emit, _owner_age(e), e.acc, interval_mul, threshold)
	e.acc = float(r["acc"])
	if bool(r["stopped"]):
		e.done = true
		return
	for _k in range(maxi(int(r["spawn"]), 0)):
		_spawn(e.tpl, e.owner, e)

## A particle dies: the global count drops and its emitter's acc gives back
## 1.0, so `max_live` caps the live particles (READ, FUN_00c87a20).
func _on_death(p: Particle) -> void:
	live_total -= 1
	if p.emitter != null:
		p.emitter.acc = maxf(p.emitter.acc - 1.0, 0.0)
	_unlink(p)

## The emitter's particle list (READ, see the header): append at the tail.
static func _link_in(p: Particle, e: Emitter) -> void:
	if e == null:
		return
	p.link = e.tail
	if e.tail != null:
		e.tail.next_link = p
	e.tail = p

## ... and unlink on death (CEFElement::FUN_00c873a0).
static func _unlink(p: Particle) -> void:
	if p.next_link != null:
		p.next_link.link = p.link
	if p.link != null:
		p.link.next_link = p.next_link
	if p.emitter != null and p.emitter.tail == p:
		p.emitter.tail = p.link
	p.link = null
	p.next_link = null

## Whether one more particle fits the caps (see the header).
func can_spawn() -> bool:
	if particles.size() >= MAX_PARTICLES:
		return false
	var limit := MAX_TOTAL if reserved else MAX_TOTAL - RESERVE
	return live_total < limit

func _spawn(tpl_index: int, owner: Particle, from: Emitter = null) -> void:
	if not can_spawn():
		dropped += 1
		if from != null:
			from.acc = maxf(from.acc - 1.0, 0.0) # OURS: a refused spawn is not live
		return
	var tp: Tpl = template.tpls[tpl_index]
	var p := Particle.new()
	p.tpl = tpl_index
	p.emitter = from
	p.parent = owner
	p.pos = owner.pos
	p.prev_pos = owner.pos
	p.vel = owner.vel
	p.rot = owner.rot
	_link_in(p, from)
	particles.append(p)
	live_total += 1
	spawned += 1
	if tp.schedule.size() > 0 and not (tp.schedule[0] as Array).is_empty():
		_run_list(p, tp, tp.schedule[0])
	for k in tp.children:
		var e := Emitter.new()
		e.tpl = k
		e.owner = p
		emitters.append(e)

# ---------------------------------------------------------------- commands

## A D3D row-major 4x4 (16 floats) as a Basis acting like `v * M`.
static func basis_of(m) -> Basis:
	if not (m is PackedFloat32Array) or (m as PackedFloat32Array).size() < 11:
		return Basis.IDENTITY
	var a: PackedFloat32Array = m
	return Basis(Vector3(a[0], a[1], a[2]), Vector3(a[4], a[5], a[6]), Vector3(a[8], a[9], a[10]))

func _parent_of(p: Particle) -> Particle:
	return p.parent if p.parent != null else _root

## The rotation a space selector names: 0 none, 1 own, 2 parent, 3 link
## (READ; a link variant is skipped before this when there is no link).
func _frame(p: Particle, sel: int) -> Basis:
	match sel:
		1:
			return p.rot
		2:
			return _parent_of(p).rot
		3:
			return p.link.rot if p.link != null else Basis.IDENTITY
	return Basis.IDENTITY

## True when command `name` with this space byte names the link (+0x34):
## the variants the interpreter runs only when the particle has one (READ,
## see the header).
static func names_link(name: String, space: int) -> bool:
	return KIND.has(name) and kind_names_link(int(KIND[name]), space)

## The same by command family (what _run dispatches on).
static func kind_names_link(kind: int, space: int) -> bool:
	match kind:
		K_POS, K_CONEPOS, K_BANPOS:
			return space % 3 == 2 or space / 3 == 3
		K_SPHERE:
			return space == 2
		K_VEL, K_CONEVEL, K_FORCE, K_CONEFORCE, K_ROT, K_BANROT:
			return space == 3
		K_ATTRACT:
			return space == 1
	return false

func _rand() -> float:
	return _rng.randf()

## A cone vector from AngleVector1's b = (min, max, angle in radians).
func _cone(b: Vector3) -> Vector3:
	var r := lerpf(b.x, b.y, _rand())
	var tilt := _rand() * b.z
	var spin := _rand() * TAU
	# (0, r, 0) * Rz(tilt) * Ry(spin), row vectors (READ order).
	var x := -r * sin(tilt)
	var y := r * cos(tilt)
	return Vector3(x * cos(spin), y, x * sin(spin))

func _ball() -> Vector3:
	for _i in range(64):
		var q := Vector3((_rand() - 0.5) * 2.0, (_rand() - 0.5) * 2.0, (_rand() - 0.5) * 2.0)
		if q.length_squared() <= 1.0:
			return q
	return Vector3.ZERO

## A position command: origin o, rotation frame r (space = r*3 + o).
## SetConePos's o=0 cases (0x1f/0x22/0x25/0x28) build the vector in the
## interpreter's stack vector (0x00c899a1), so `stack` records it there.
func _set_pos(p: Particle, space: int, v: Vector3, stack: bool = false) -> void:
	var o := space % 3
	var r := space / 3
	var d := _frame(p, r) * v
	if o == 1:
		p.pos = _parent_of(p).pos
	elif o == 2:
		p.pos = p.link.pos
	elif stack:
		_scratch = d
	p.pos += d

func _run_list(p: Particle, tp: Tpl, list: Array) -> void:
	_scratch = Vector3.ZERO # OURS: the stack vector's uninitialised start
	for entry in list:
		_run(p, tp, entry[0], entry[1], entry[2])

func _run(p: Particle, tp: Tpl, kind: int, s: int, v) -> void:
	if p.link == null and kind_names_link(kind, s):
		return # READ: every link variant tests +0x34 first (round 621)
	match kind:
		K_POS, K_BANPOS:
			_set_pos(p, s, v)
		K_CONEPOS:
			_set_pos(p, s, _cone(v), true)
		K_SPHERE:
			if s == 0:
				# READ, 0x00c8a4c5: position = the ball point, then
				# position += value * the stack vector (see the header).
				p.pos = _ball()
				_scratch = (v as Vector3) * _scratch
				p.pos += _scratch
			else:
				var o: Vector3 = p.link.pos if s == 2 else _parent_of(p).pos
				p.pos = o + _ball() * (v as Vector3)
		K_VEL:
			p.vel = _frame(p, s) * (v as Vector3)
		K_CONEVEL:
			p.vel = _frame(p, s) * _cone(v)
		K_FORCE:
			p.vel += _frame(p, s) * (v as Vector3)
		K_CONEFORCE:
			var c1 := _cone(v)
			_scratch = c1
			p.vel += _frame(p, s) * c1
			if s == 0:
				# READ: case 0x46 falls through into 0x47 (own rotation).
				var c2 := p.rot * _cone(v)
				_scratch = c2
				p.vel += c2
		K_ATTRACT:
			var d := p.pos - (p.link.pos if s == 1 else _parent_of(p).pos)
			if d.length_squared() > 0.0:
				_scratch = d.normalized() * float(v)
				p.vel += _scratch
		K_ROT, K_BANROT:
			_set_rot(p, s, v)
		K_RVEL:
			p.rvel = v
			p.has_rvel = p.rvel != Basis.IDENTITY
		K_SHAPE:
			p.shape = v
		K_SHAPEVEL:
			p.shape_vel = v
			p.has_shape_vel = p.shape_vel != Basis.IDENTITY
		K_SCALE:
			p.scale = v
		K_DIFFUSE:
			p.color = v
		K_SLIDE:
			p.uv = v
		K_RANDSCALE:
			if tp.scale_graph is Dictionary:
				p.scale = sample_scale_graph(tp.scale_graph, _rand())

## M, then the frame's rotation (row vectors: M * F) as Godot bases: F * M.
func _set_rot(p: Particle, s: int, m: Basis) -> void:
	match s:
		0:
			p.rot = m
		_:
			p.rot = _frame(p, s) * m

## A BlendScaleGraph {a, b, times, scales} at time t (READ shape, FUN_00c89140).
static func sample_scale_graph(g: Dictionary, t: float) -> Vector3:
	var times: PackedFloat32Array = g.get("times", PackedFloat32Array())
	var scales: PackedVector3Array = g.get("scales", PackedVector3Array())
	var n := mini(times.size(), scales.size())
	if n == 0:
		return Vector3.ONE
	if t < float(g.get("a", 0.0)) or t <= times[0]:
		return scales[0]
	if t > float(g.get("b", 1.0)) or t >= times[n - 1]:
		return scales[n - 1]
	for i in range(1, n):
		if t <= times[i]:
			var span := times[i] - times[i - 1]
			var w := (t - times[i - 1]) / span if span > 0.0 else 1.0
			return scales[i - 1].lerp(scales[i], w)
	return scales[n - 1]

## A raw D3DCOLOR as a Godot colour (INFERRED 0xAARRGGBB).
static func color_of(c: int) -> Color:
	return EfpReader.d3dcolor(c)
