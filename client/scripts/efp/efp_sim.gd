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
## 1 and then stays (READ literally: `if age != 1: age += frames`).
##
## == The per-particle program (READ, EFEffect::FUN_00c893f0) ==
## Each command runs at the frames of its range (FUN_00ca0f40; value i of a
## Frame* parameter at frame start + i*step, INFERRED from the MEASURED key
## counts). The command's `space` byte is added to its opcode by its factory
## (READ: FUN_00ca8140 registrations, e.g. SetConeVel = 0x3e + space), and the
## interpreter's switch gives each opcode its meaning:
##   position commands (SetPosition, SetConePos, SetBANPos): space = r*3 + o;
##     o: 0 add to the current position, 1 start from the parent particle's
##     position, 2 from the "link" object's; r: the value is rotated by 0 no
##     matrix, 1 the particle's own rotation, 2 the parent's, 3 the link's.
##   SetSpherePos: a uniform point in the unit ball (rejection sampling of
##     (r - 0.5) * 2 from the 5000-entry random table) times the value,
##     added to 0 the position, 1 the parent's position, 2 the link's.
##   SetVelocity / SetConeVel: velocity = the value rotated by space 0 none,
##     1 own, 2 parent, 3 link. Force / ConeForce: the same, added
##     (INFERRED: the add's target is implied in the decompile).
##   Attraction: velocity += normalize(pos - parent pos) * value (space 0),
##     the link's (space 1).
##   Cone (AngleVector1 {a, b}): the vector (0, lerp(b.x, b.y, r1), 0) turned
##     r2 * b.z about Z (IDecoSkill::FUN_00a4d820 builds a Z rotation) then
##     r3 * 2*pi about Y (FUN_0043cda0). b.z is a.z in radians in every
##     retail value (MEASURED); that the trig takes b is INFERRED.
##   SetRotation* / SetBANRot: rotation = M (space 0), M then own (1), M then
##     the parent's (2), then the link's (3). SetRVelocity*: the per-frame
##     rotation. SetShapeRot / SetShapeRotVel: the shape's rotation and its
##     per-frame step.
##   SetGraphScale: scale = the key's Vector3. SetGraphDiffuse: colour = the
##     key's D3DCOLOR. TextureSlide: the UV rectangle (u, v, du, dv) = the key
##     (INFERRED: the decompile loses the store; MEASURED head (3,2,..) with
##     key (0,0,1/3,1/2) is a 3x2 atlas cell). SetGraphRandomScale: scale =
##     the node's BlendScaleGraph at a random time (FUN_00c89140: first key
##     before a, last after b, linear between; which var the pointer names is
##     INFERRED to be the node's first BlendScaleGraph).
##   The link (+0x34) is the particle the same emitter spawned before this
##     one that is still alive (READ, round 621: the emitter's particle list
##     at emitter+0x30 has prev offset 0x34 and next offset 0x38,
##     FUN_00c88320; the particle init FUN_00c88490 appends at the tail;
##     a death unlinks). Every variant that names the link does nothing
##     when the particle has none -- the oldest live one of its emitter
##     (READ: cases 0x03, 0x15, 0x18, 0x1b-0x1e, 0x39, 0x3d, 0x41, 0x45,
##     0x49, 0x4b test +0x34 first). See EfpLinks for the chain's drawing.
##   ConeForce's case 0x46 falls through into 0x47 in the decompile; this
##   client does not reproduce that (OPEN whether it is real).
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
## MAX_PARTICLES per effect and MAX_TOTAL across all live effects; a spawn
## past either is dropped and counted in `dropped`.

const FRAME_SEC := 0.05 ## READ: 50 ms, see the header
const MAX_STEPS_PER_ADVANCE := 10 ## OURS: a long hitch catches up at most 0.5 s
const MAX_PARTICLES := 300 ## OURS
const MAX_TOTAL := 3000 ## OURS

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

## One node, compiled once per file and shared by every playing copy.
class Tpl:
	var node: EfpReader.EfpNode
	var index: int
	var parent: int = -1 ## -1 for the root (owned by the effect)
	var children: Array[int] = []
	var frames: int
	var life: int
	var emit = null ## {delay, duration, interval, max_live, per_trigger} or null
	var schedule: Array = [] ## frame -> Array of [EfpCommand, key]
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
var _root := Particle.new() ## the effect's origin: owner of the root emitter
var _acc := 0.0
var _rng := RandomNumberGenerator.new()

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
		if not OP_BASE.has(c.name):
			if not tp.unsupported.has(c.name):
				tp.unsupported.append(c.name)
			if not t.unsupported.has(c.name):
				t.unsupported.append(c.name)
			continue
		var fr := c.frame_range(tp.frames)
		if not bool(fr["ok"]):
			continue
		var st: float = fr["step"]
		for i in range(int(fr["keys"])):
			var f: int = int(fr["start"]) + int(float(i) * st)
			if f > int(fr["end"]) or f >= tp.frames:
				break
			(tp.schedule[f] as Array).append([c, i])
	t.tpls.append(tp)
	if parent >= 0:
		t.tpls[parent].children.append(tp.index)
	for k in n.children:
		_compile_node(t, k, tp.index)

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

## Drops every particle (and its share of the global count).
func clear() -> void:
	for p in particles:
		if p.alive:
			live_total -= 1
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
		if p.parent != null and p.parent != _root and p.parent.alive:
			p.pos += p.parent.pos - p.parent.prev_pos
		p.pos += p.vel
		p.rot = p.rvel * p.rot
		p.shape = p.shape_vel * p.shape
	# 2 commands for each particle's age
	for p in particles:
		var tp: Tpl = tpls[p.tpl]
		if p.age >= 0 and p.age < tp.schedule.size():
			for entry in tp.schedule[p.age]:
				_run(p, tp, entry[0], int(entry[1]))
	# 3 emission (the list grows as particles spawn child emitters)
	var born := particles.size()
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
		if p.alive:
			keep.append(p)
		else:
			_on_death(p)
	particles = keep
	# emitters whose owner died stop (OURS)
	var live_emitters: Array[Emitter] = []
	for e in emitters:
		if e.owner == _root or e.owner.alive:
			live_emitters.append(e)
	emitters = live_emitters
	age += 1
	_root.prev_pos = _root.pos
	var _unused := born

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
## 1.0, so `count` caps the live particles (READ, FUN_00c87a20).
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

func _spawn(tpl_index: int, owner: Particle, from: Emitter = null) -> void:
	if particles.size() >= MAX_PARTICLES or live_total >= MAX_TOTAL:
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
	if tp.schedule.size() > 0:
		for entry in tp.schedule[0]:
			_run(p, tp, entry[0], int(entry[1]))
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
	match name:
		"SetPosition", "SetConePos", "SetBANPos":
			return space % 3 == 2 or space / 3 == 3
		"SetSpherePos":
			return space == 2
		"SetVelocity", "SetConeVel", "Force", "ConeForce", \
				"SetRotationMat", "SetRotation", "SetRotationAxis", "SetBANRot":
			return space == 3
		"Attraction":
			return space == 1
	return false

func _rand() -> float:
	return _rng.randf()

func _cone(v: Dictionary) -> Vector3:
	var b: Vector3 = v.get("b", Vector3.ZERO)
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

func _set_pos(p: Particle, space: int, v: Vector3) -> void:
	var o := space % 3
	var r := space / 3
	if o == 1:
		p.pos = _parent_of(p).pos
	elif o == 2:
		p.pos = p.link.pos
	p.pos += _frame(p, r) * v

func _run(p: Particle, tp: Tpl, c: EfpReader.EfpCommand, key: int) -> void:
	var val = c.value
	var s: int = c.space
	if p.link == null and names_link(c.name, s):
		return
	match c.name:
		"SetPosition":
			if val is Dictionary:
				_set_pos(p, s, val.get("value", Vector3.ZERO))
		"SetConePos":
			if val is Dictionary:
				_set_pos(p, s, _cone(val))
		"SetBANPos":
			if val is Dictionary:
				var ps: PackedVector3Array = val.get("positions", PackedVector3Array())
				if key < ps.size():
					_set_pos(p, s, ps[key])
		"SetSpherePos":
			if val is Dictionary:
				var off := _ball() * (val.get("value", Vector3.ZERO) as Vector3)
				if s == 1:
					p.pos = _parent_of(p).pos
				elif s == 2:
					p.pos = p.link.pos
				p.pos += off
		"SetVelocity":
			if val is Dictionary:
				p.vel = _frame(p, s) * (val.get("value", Vector3.ZERO) as Vector3)
		"SetConeVel":
			if val is Dictionary:
				p.vel = _frame(p, s) * _cone(val)
		"Force":
			if val is Dictionary:
				p.vel += _frame(p, s) * (val.get("value", Vector3.ZERO) as Vector3)
		"ConeForce":
			if val is Dictionary:
				p.vel += _frame(p, s) * _cone(val)
		"Attraction":
			if val is Dictionary:
				var d := p.pos - (p.link.pos if s == 1 else _parent_of(p).pos)
				if d.length_squared() > 0.0:
					p.vel += d.normalized() * float(val.get("value", 0.0))
		"SetRotationMat", "SetRotation", "SetRotationAxis":
			if val is Dictionary:
				_set_rot(p, s, basis_of(val.get("matrix")))
		"SetBANRot":
			if val is Dictionary:
				var ms: Array = val.get("matrices", [])
				if key < ms.size():
					_set_rot(p, s, basis_of(ms[key]))
		"SetRVelocityMat", "SetRVelocity", "SetRVelocityAxis":
			if val is Dictionary:
				p.rvel = basis_of(val.get("matrix"))
		"SetShapeRot":
			if val is Dictionary:
				p.shape = basis_of(val.get("matrix"))
		"SetShapeRotVel":
			if val is Dictionary:
				p.shape_vel = basis_of(val.get("matrix"))
		"SetGraphScale":
			if val is Dictionary:
				var fs: PackedVector3Array = val.get("frames", PackedVector3Array())
				if key < fs.size():
					p.scale = fs[key]
		"SetGraphDiffuse":
			if val is Dictionary:
				var cs: PackedInt64Array = val.get("colors", PackedInt64Array())
				if key < cs.size():
					p.color = cs[key]
		"TextureSlide":
			if val is Dictionary:
				var ks: Array = val.get("keys", [])
				if key < ks.size():
					p.uv = ks[key]
		"SetGraphRandomScale":
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
