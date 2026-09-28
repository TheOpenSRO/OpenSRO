extends SceneTree

## EfpSim (the particle rules) and EfpEffect (the drawing), round 620, on
## synthetic decoded trees built here -- never game data. Run headless:
## `godot4 --headless --path client --script res://scripts/efp/efp_sim_test.gd`
##
## The scripts are loaded by path, so a checkout without them prints FAIL.

var _failures := 0
var S: GDScript
var E: GDScript

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _cmd(name: String, value = null, space: int = 0, flags: int = 0, start: float = 0.0,
		step: float = 1.0, end: float = 0.0) -> EfpReader.EfpCommand:
	var c := EfpReader.EfpCommand.new()
	c.name = name
	c.value = value
	c.space = space
	c.time_flags = flags
	c.start = start
	c.step = step
	c.end = end
	return c

func _emit(delay: int, duration: int, interval: int, count: int, quality: float) -> EfpReader.EfpCommand:
	return _cmd("StaticEmit", {"type": "SEFStaticEmit", "delay": delay, "duration": duration,
		"interval": interval, "max_live": count, "per_trigger": quality})

func _state(src: int, dest: int, cull: int = 1) -> EfpReader.EfpRenderState:
	var s := EfpReader.EfpRenderState.new()
	s.cull = cull
	s.src_blend = src
	s.dest_blend = dest
	s.color_arg1 = 2
	s.color_arg2 = 0
	s.color_op = 4
	s.alpha_arg1 = 2
	s.alpha_arg2 = 0
	s.alpha_op = 4
	return s

## A node: N frames, a lifetime, an emitter, a render mode and commands.
func _node(frames: int, life: String, emit: EfpReader.EfpCommand, render: String = "RenderNone",
		cmds: Array = [], tex: String = "t.ddj", mesh: String = "") -> EfpReader.EfpNode:
	var n := EfpReader.EfpNode.new()
	n.name = "n"
	n.frames = frames
	n.extinct = _cmd(life)
	if emit != null:
		n.emit.append(emit)
	n.view = _cmd("ViewNone")
	n.render = _cmd(render)
	n.state = _state(5, 2)
	var ref := EfpReader.EfpMeshRef.new()
	ref.mesh = mesh
	ref.textures = PackedStringArray([tex]) if tex != "" else PackedStringArray()
	n.meshes.append(ref)
	for c in cmds:
		n.commands.append(c)
	return n

func _sim(root: EfpReader.EfpNode, seed_value: int = 7):
	return S.new(S.compile(root), seed_value)

func _initialize() -> void:
	S = load("res://scripts/efp/efp_sim.gd")
	E = load("res://scripts/efp/efp_effect.gd")
	_check(S != null, "scripts/efp/efp_sim.gd exists (EfpSim, the particle rules)")
	_check(E != null, "scripts/efp/efp_effect.gd exists (EfpEffect, the renderer)")
	if S == null or E == null:
		_finish()
		return
	_timing()
	_emission()
	_lifetimes()
	_children()
	_commands()
	_caps()
	_review_rules()
	_blend()
	_effect_nodes()
	_finish()

func _timing() -> void:
	_check(is_equal_approx(S.FRAME_SEC, 0.05), "a frame is 50 ms (READ, the 50.0 at 0x00d8f0b0)")
	var sim = _sim(_node(10, "NormalTimeExtinct", _emit(0, 1, 1, 1, 1.0)))
	_check(sim.advance(0.049) == 0, "49 ms steps no frame")
	_check(sim.advance(0.002) == 1, "the 51st ms steps one frame (the accumulator carries)")
	_check(sim.advance(1.0) == 10, "a long hitch is capped at MAX_STEPS_PER_ADVANCE (10)")
	_check(sim.advance(0.5) == 10, "... and 0.5 s later the clock is 20 frames a second again")

func _emission() -> void:
	# (0, 30, 3, 10, 1.0): one particle every third frame, ten while none dies
	# (READ: acc = min(acc + quality, count), spawn int deltas, at t % interval == 0).
	var sim = _sim(_node(100, "NormalTimeExtinct", _emit(0, 30, 3, 10, 1.0)))
	var at: Array = []
	for f in range(40):
		var before: int = sim.spawned
		sim.step()
		if sim.spawned > before:
			at.append(f)
	_check(sim.spawned == 10, "max_live caps the live particles: 10 spawned while none dies (%d)" % sim.spawned)
	_check(at == [0, 3, 6, 9, 12, 15, 18, 21, 24, 27], "one per interval from frame 0: %s" % str(at))
	# Fractional quality accumulates: 0.5 a tick gives one every second tick.
	var half = _sim(_node(100, "NormalTimeExtinct", _emit(0, 10, 1, 4, 0.5)))
	var at2: Array = []
	for f in range(12):
		var b2: int = half.spawned
		half.step()
		if half.spawned > b2:
			at2.append(f)
	_check(at2 == [1, 3, 5, 7], "quality 0.5 spawns on every second tick up to count 4: %s" % str(at2))
	# Quality above 1 spawns several at once.
	var burst = _sim(_node(100, "NormalTimeExtinct", _emit(0, 1, 1, 12, 5.0)))
	burst.step()
	_check(burst.spawned == 5, "quality 5 spawns five in one tick (%d)" % burst.spawned)
	# Delay: nothing before frame 5.
	var late = _sim(_node(100, "NormalTimeExtinct", _emit(5, 1, 1, 1, 1.0)))
	var first := -1
	for f in range(10):
		late.step()
		if late.spawned > 0 and first < 0:
			first = f
	_check(first == 5, "delay 5 spawns at frame 5 (%d)" % first)
	# A dying particle gives 1.0 back: count caps the LIVE particles.
	var cap = _sim(_node(3, "NormalTimeExtinct", _emit(0, 20, 1, 2, 1.0)))
	var most := 0
	for _f in range(20):
		cap.step()
		most = maxi(most, cap.particles.size())
	_check(most == 2 and cap.spawned > 4, "count 2 with 3-frame particles: never more than 2 alive, %d spawned as they die" % cap.spawned)
	var zero = _sim(_node(10, "NormalTimeExtinct", _emit(0, 1, 1, 1, 0.0)))
	for _f in range(5):
		zero.step()
	_check(zero.spawned == 0, "(0,1,1,1,0.0) emits nothing: per_trigger is the per-trigger amount")
	# Interval 0 never emits.
	var none = _sim(_node(10, "NormalTimeExtinct", _emit(0, 10, 0, 5, 1.0)))
	for _f in range(12):
		none.step()
	_check(none.spawned == 0, "interval 0 never emits")

func _lifetimes() -> void:
	var once = _sim(_node(4, "NormalTimeExtinct", _emit(0, 1, 1, 1, 1.0)))
	var alive: Array = []
	for _f in range(6):
		once.step()
		alive.append(once.particles.size())
	# Round 623: the death is queued and flushed at the next frame's start
	# (READ, CEFUpdater::vslot_002), so the particle is drawn at its last
	# frame too -- 4 frames, not 3.
	_check(alive == [1, 1, 1, 1, 0, 0], "NormalTimeExtinct: a 4-frame particle is drawn for frames 0-3 then dies: %s" % str(alive))
	_check(once.finished(), "... and the effect is finished (once)")
	var loop = _sim(_node(4, "NormalTimeLoop", _emit(0, 1, 1, 1, 1.0)))
	var ages: Array = []
	for _f in range(9):
		loop.step()
		ages.append(loop.particles[0].age if not loop.particles.is_empty() else -1)
	_check(ages == [1, 2, 3, 0, 1, 2, 3, 0, 1], "NormalTimeLoop: the age wraps modulo N: %s" % str(ages))
	_check(not loop.finished(), "... and a looping particle keeps the effect alive")
	var never = _sim(_node(4, "NeverExtinct", _emit(0, 1, 1, 1, 1.0)))
	for _f in range(20):
		never.step()
	_check(never.particles.size() == 1 and never.particles[0].age == 1,
		"NeverExtinct: the particle lives on with its age held at 1 (READ, FUN_00c84d80)")
	once.restart()
	_check(once.age == 0 and once.particles.is_empty() and not once.finished(), "restart() starts the effect over")

func _children() -> void:
	var root := _node(20, "NormalTimeExtinct", _emit(0, 3, 1, 3, 1.0))
	var kid := _node(10, "NormalTimeExtinct", _emit(0, 1, 1, 1, 1.0), "RenderPlate")
	root.children.append(kid)
	var sim = _sim(root)
	for _f in range(4):
		sim.step()
	var kids := 0
	for p in sim.particles:
		if p.tpl == 1:
			kids += 1
	_check(kids == 3, "a child node emits once per parent particle: 3 parents, 3 children (%d)" % kids)
	_check(sim.template.tpls[1].parent == 0 and sim.template.tpls[0].children == [1], "the template keeps the tree")

func _commands() -> void:
	var v := {"type": "Vector", "value": Vector3(1, 0, 0)}
	var moving = _sim(_node(20, "NormalTimeExtinct", _emit(0, 1, 1, 1, 1.0), "RenderNone",
		[_cmd("SetVelocity", v)]))
	for _f in range(4):
		moving.step()
	_check(moving.particles[0].pos.is_equal_approx(Vector3(3, 0, 0)),
		"SetVelocity at frame 0 sets units per frame; three frames of motion later x = 3 (%s)" % str(moving.particles[0].pos))
	# SetPosition space 1 starts from the parent's position.
	var root := _node(20, "NormalTimeExtinct", _emit(0, 1, 1, 1, 1.0), "RenderNone",
		[_cmd("SetPosition", {"type": "Vector", "value": Vector3(0, 5, 0)})])
	var kid := _node(20, "NormalTimeExtinct", _emit(0, 1, 1, 1, 1.0), "RenderNone",
		[_cmd("SetPosition", {"type": "Vector", "value": Vector3(2, 0, 0)}, 1)])
	root.children.append(kid)
	var sim = _sim(root)
	sim.step()
	var kp = null
	for p in sim.particles:
		if p.tpl == 1:
			kp = p
	_check(kp != null and kp.pos.is_equal_approx(Vector3(2, 5, 0)), "SetPosition space 1 = the parent's position + the value")
	# Frame* keys: value i at frame start + i*step.
	var scales := PackedVector3Array([Vector3.ONE, Vector3(2, 2, 2), Vector3(3, 3, 3), Vector3(4, 4, 4)])
	var colours := PackedInt64Array([0xFF000000, 0x80FF0000, 0x4000FF00, 0x100000FF])
	var slides: Array = [Vector4(0, 0, 0.5, 0.5), Vector4(0.5, 0, 0.5, 0.5), Vector4(0, 0.5, 0.5, 0.5), Vector4(0.5, 0.5, 0.5, 0.5)]
	var g = _sim(_node(4, "NormalTimeExtinct", _emit(0, 1, 1, 1, 1.0), "RenderPlate", [
		_cmd("SetGraphScale", {"type": "FrameScale", "frames": scales}, 0, 0, 0, 1, 3),
		_cmd("SetGraphDiffuse", {"type": "FrameDiffuse", "colors": colours}, 0, 0, 0, 1, 3),
		_cmd("TextureSlide", {"type": "FrameTextureSlide", "head": Vector3(2, 2, 1), "keys": slides}, 0, 0, 0, 1, 3)]))
	var seen_s: Array = []
	var seen_c: Array = []
	var seen_u: Array = []
	for _f in range(4):
		g.step()
		if not g.particles.is_empty():
			seen_s.append(g.particles[0].scale.x)
			seen_c.append(g.particles[0].color)
			seen_u.append(g.particles[0].uv)
	# Round 623: a 4-frame particle is drawn at all 4 frames (its death is
	# queued and flushed at the next frame's start), so key 3 is seen too.
	_check(seen_s == [1.0, 2.0, 3.0, 4.0], "SetGraphScale: after frame f the particle holds key f (frame 0 ran at spawn): %s" % str(seen_s))
	_check(seen_c == [0xFF000000, 0x80FF0000, 0x4000FF00, 0x100000FF], "SetGraphDiffuse: the colour key of each frame")
	_check(seen_u == [slides[0], slides[1], slides[2], slides[3]], "TextureSlide: the UV rectangle key of each frame")
	var col: Color = S.color_of(0x80FF0000)
	_check(is_equal_approx(col.r, 1.0) and is_equal_approx(col.a, 128.0 / 255.0), "a colour is D3DCOLOR 0xAARRGGBB")
	# Step 2: keys at frames 0, 2.
	var two = _sim(_node(4, "NormalTimeExtinct", _emit(0, 1, 1, 1, 1.0), "RenderPlate", [
		_cmd("SetGraphScale", {"type": "FrameScale", "frames": PackedVector3Array([Vector3(5, 5, 5), Vector3(6, 6, 6)])}, 0, 0, 0, 2, 3)]))
	var s2: Array = []
	for _f in range(3):
		two.step()
		s2.append(two.particles[0].scale.x)
	_check(s2 == [5.0, 5.0, 6.0], "a step-2 graph sets frames 0 and 2 and holds between: %s" % str(s2))
	# Cone velocity: radius in [min, max]; a zero-angle cone points straight up.
	var cone = _sim(_node(4, "NormalTimeExtinct", _emit(0, 1, 1, 20, 20.0), "RenderNone", [
		_cmd("SetConeVel", {"type": "AngleVector1", "a": Vector3(2, 3, 0), "b": Vector3(2, 3, 0)})]))
	cone.step()
	var up := true
	for p in cone.particles:
		if absf(p.vel.x) > 1e-5 or absf(p.vel.z) > 1e-5 or p.vel.y < 2.0 - 1e-5 or p.vel.y > 3.0 + 1e-5:
			up = false
	_check(up and cone.particles.size() == 20, "SetConeVel with angle 0: all straight up (+Y), speed in [min, max]")
	var wide = _sim(_node(4, "NormalTimeExtinct", _emit(0, 1, 1, 50, 50.0), "RenderNone", [
		_cmd("SetConeVel", {"type": "AngleVector1", "a": Vector3(1, 1, 360), "b": Vector3(1, 1, TAU)})]))
	wide.step()
	var down := 0
	var unit := true
	for p in wide.particles:
		if p.vel.y < 0.0:
			down += 1
		if absf(p.vel.length() - 1.0) > 1e-4:
			unit = false
	_check(unit and down > 5, "a full-circle cone spreads both ways at speed 1 (%d of 50 downward)" % down)
	var sg: Vector3 = S.sample_scale_graph({"a": 0.0, "b": 1.0, "times": PackedFloat32Array([0.0, 1.0]),
		"scales": PackedVector3Array([Vector3.ONE, Vector3(3, 3, 3)])}, 0.5)
	_check(sg.is_equal_approx(Vector3(2, 2, 2)), "a BlendScaleGraph interpolates linearly between keys")

func _caps() -> void:
	S.live_total = 0
	var big = _sim(_node(100, "NormalTimeLoop", _emit(0, 10, 1, 100000, 1000.0)))
	big.step()
	_check(big.particles.size() == S.MAX_PARTICLES and big.dropped > 0,
		"one effect holds at most MAX_PARTICLES (%d, dropped %d)" % [big.particles.size(), big.dropped])
	var others: Array = []
	for _i in range(int(S.MAX_TOTAL / S.MAX_PARTICLES) + 2):
		var o = _sim(_node(100, "NormalTimeLoop", _emit(0, 10, 1, 100000, 1000.0)))
		o.step()
		others.append(o)
	_check(S.live_total == S.MAX_TOTAL - S.RESERVE, "other effects together hold at most MAX_TOTAL - RESERVE (%d)" % S.live_total)
	for o in others:
		o.clear()
	big.clear()
	_check(S.live_total == 0, "clearing the effects returns their share of the total")

func _review_rules() -> void:
	# NeverExtinct with N == 0 kills the particle (FUN_00c84d80).
	var n0 = _sim(_node(0, "NeverExtinct", _emit(0, 1, 1, 1, 1.0)))
	n0.step()
	var drawn_once: bool = n0.particles.size() == 1
	n0.step()
	_check(drawn_once and n0.particles.is_empty() and n0.spawned == 1,
		"NeverExtinct with N == 0 kills the particle: queued at its first frame, drawn once, gone at the next (round 623)")
	# Scheduling is a float32 running sum of the step, truncated.
	var c := _cmd("SetGraphScale", {"type": "FrameScale", "frames": PackedVector3Array()}, 0, 0, 0.0, 0.3, 2.0)
	var fr: Array = S.key_frames(c, 10)
	var frames: Array = []
	for pair in fr:
		frames.append(pair[0])
	_check(frames == [0, 0, 0, 0, 1, 1, 1], "step 0.3 from 0 to 2: keys at ftol of the float32 sum: %s" % str(frames))
	# SetSpherePos space 0: position = the ball point, + value * the stack vector.
	var sp = _sim(_node(10, "NormalTimeExtinct", _emit(0, 1, 1, 20, 20.0), "RenderNone", [
		_cmd("SetPosition", {"type": "Vector", "value": Vector3(100, 0, 0)}),
		_cmd("SetSpherePos", {"type": "Vector", "value": Vector3(50, 50, 50)})]))
	sp.step()
	var inside := true
	for q in sp.particles:
		if q.pos.length() > 1.0001:
			inside = false
	_check(inside and sp.particles.size() == 20,
		"SetSpherePos space 0 overwrites the position with a unit-ball point; with no stack vector the value adds nothing")
	var sp2 = _sim(_node(10, "NormalTimeExtinct", _emit(0, 1, 1, 20, 20.0), "RenderNone", [
		_cmd("SetConePos", {"type": "AngleVector1", "a": Vector3(3, 3, 0), "b": Vector3(3, 3, 0)}),
		_cmd("SetSpherePos", {"type": "Vector", "value": Vector3(2, 2, 2)})]))
	sp2.step()
	var shifted := true
	for q in sp2.particles:
		if absf(q.pos.y - 6.0) > 1.0001 or Vector2(q.pos.x, q.pos.z).length() > 1.0001:
			shifted = false
	_check(shifted, "... after a cone position the stack vector is that cone: pos = ball + value * (0, 3, 0)")
	# ConeForce space 0 falls through into 0x47: two cones.
	var cf = _sim(_node(10, "NormalTimeExtinct", _emit(0, 1, 1, 1, 1.0), "RenderNone", [
		_cmd("ConeForce", {"type": "AngleVector1", "a": Vector3(1, 1, 0), "b": Vector3(1, 1, 0)})]))
	cf.step()
	_check(cf.particles[0].vel.is_equal_approx(Vector3(0, 2, 0)), "ConeForce space 0 adds its cone twice (0x46 falls into 0x47): %s" % str(cf.particles[0].vel))
	var cf1 = _sim(_node(10, "NormalTimeExtinct", _emit(0, 1, 1, 1, 1.0), "RenderNone", [
		_cmd("ConeForce", {"type": "AngleVector1", "a": Vector3(1, 1, 0), "b": Vector3(1, 1, 0)}, 1)]))
	cf1.step()
	_check(cf1.particles[0].vel.is_equal_approx(Vector3(0, 1, 0)), "ConeForce space 1 adds one")
	# The reserved share: others stop at MAX_TOTAL - RESERVE, own effects may go on.
	S.live_total = 0
	var crowd: Array = []
	for _i in range(20):
		var o = _sim(_node(100, "NormalTimeLoop", _emit(0, 10, 1, 100000, 1000.0)))
		o.step()
		crowd.append(o)
	_check(S.live_total == S.MAX_TOTAL - S.RESERVE, "everyone else's effects stop at MAX_TOTAL - RESERVE (%d)" % S.live_total)
	var mine = _sim(_node(100, "NormalTimeLoop", _emit(0, 10, 1, 100000, 1000.0)))
	mine.reserved = true
	mine.step()
	_check(mine.particles.size() == S.MAX_PARTICLES, "the player's own effect still gets its particles (%d)" % mine.particles.size())
	mine.clear()
	for o in crowd:
		o.clear()
	_check(S.live_total == 0, "... and the count returns to 0")

func _blend() -> void:
	_check(E.blend_class(5, 2) == "add" and E.godot_blend("add") == BaseMaterial3D.BLEND_MODE_ADD,
		"SRCALPHA/ONE -> BLEND_MODE_ADD")
	_check(E.blend_class(5, 6) == "mix" and E.godot_blend("mix") == BaseMaterial3D.BLEND_MODE_MIX,
		"SRCALPHA/INVSRCALPHA -> BLEND_MODE_MIX")
	_check(E.blend_class(12, 2) == "mix", "BOTHSRCALPHA is the alpha pair whatever the dest says")
	_check(E.blend_class(2, 2) == "add_one", "ONE/ONE is additive with alpha 1")
	_check(E.blend_class(1, 6) == "darken", "ZERO/INVSRCALPHA darkens")
	_check(E.blend_class(4, 3) == "other" and E.godot_blend("other") == BaseMaterial3D.BLEND_MODE_MIX,
		"an unmapped pair is labelled other and drawn MIX")
	_check(E.cull_disabled(1) and not E.cull_disabled(3), "D3DCULL NONE draws both faces, CCW culls back faces")

func _effect_nodes() -> void:
	var img := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	var tex := ImageTexture.create_from_image(img)
	var load_tex := func(p: String): return tex if p == "t.ddj" else null
	var load_mesh := func(p: String): return BoxMesh.new() if p == "m.bms" else null
	var root := _node(4, "NormalTimeExtinct", _emit(0, 1, 1, 1, 1.0))
	root.children.append(_node(4, "NormalTimeExtinct", _emit(0, 1, 1, 1, 1.0), "RenderPlate"))
	root.children.append(_node(4, "NormalTimeExtinct", _emit(0, 1, 1, 1, 1.0), "RenderMesh", [], "t.ddj", "m.bms"))
	root.children.append(_node(4, "NormalTimeExtinct", _emit(0, 1, 1, 1, 1.0), "RenderLinkPipe"))
	root.children.append(_node(4, "NormalTimeExtinct", _emit(0, 1, 1, 1, 1.0), "RenderPlate", [], "missing.ddj"))
	var fx = E.from_template(S.compile(root), load_tex, load_mesh, 3)
	# Round 621: the Link modes draw (efp_links_test.gd covers them).
	_check(fx.draw_count() == 3, "a plate, a mesh and a link pipe draw (%d)" % fx.draw_count())
	_check(fx.skipped.size() == 1, "the missing texture is skipped and listed: %s" % str(fx.skipped))
	var host := Node3D.new()
	get_root().add_child(host)
	host.add_child(fx)
	for _i in range(3):
		fx._process(0.05)
	var mmi: MultiMeshInstance3D = fx.get_child(0)
	_check(mmi.multimesh.visible_instance_count == 1, "the plate node's particle is in its MultiMesh")
	var once_done := false
	for _i in range(20):
		fx._process(0.05)
		if fx.is_queued_for_deletion():
			once_done = true
			break
	_check(once_done, "a once effect frees itself when its particles are gone")
	var looping = E.from_template(S.compile(_node(3, "NormalTimeExtinct", _emit(0, 1, 1, 1, 1.0), "RenderPlate")), load_tex, load_mesh, 3)
	looping.loop = true
	host.add_child(looping)
	var first_root = null
	var same_root := true
	for _i in range(20):
		looping._process(0.05)
		if looping.sim.particles.size() != 1:
			same_root = false
		elif first_root == null:
			first_root = looping.sim.particles[0]
		elif looping.sim.particles[0] != first_root:
			same_root = false
	_check(not looping.is_queued_for_deletion(), "a kept (AT_LOOP) effect does not end")
	_check(same_root and looping.sim.spawned == 1,
		"... its root particle is revived, never replaced: one spawn, always drawn (round 623, READ CEFEffect::vslot_000)")
	var live_before: int = S.live_total
	var held: int = looping.sim.particles.size()
	looping.stop()
	_check(looping.is_queued_for_deletion() and looping.sim.particles.is_empty() and S.live_total == live_before - held,
		"stop() ends a looping effect at once: every particle goes, the node frees (READ: the interface's release)")
	var never = E.from_template(S.compile(_node(5, "NeverExtinct", _emit(0, 1, 1, 1, 1.0), "RenderPlate")), load_tex, load_mesh, 3)
	host.add_child(never)
	for _i in range(30):
		never._process(0.05)
	_check(not never.is_queued_for_deletion() and never.sim.particles.size() == 1, "a never-extinct effect lives on by itself")
	never.stop()
	_check(never.is_queued_for_deletion(), "... and stop() ends it too (the review's 18 never-ending files)")
	# Draws are rewritten only after a simulation frame.
	var lazy = E.from_template(S.compile(_node(40, "NormalTimeExtinct", _emit(0, 1, 1, 1, 1.0), "RenderPlate")), load_tex, load_mesh, 3)
	host.add_child(lazy)
	lazy._process(0.01)
	lazy._process(0.01)
	var d0: int = lazy.draw_updates
	lazy._process(0.04)
	_check(d0 == 0 and lazy.draw_updates == 1, "the MultiMeshes are rewritten only on a frame that stepped (%d, %d)" % [d0, lazy.draw_updates])
	lazy.stop()
	# The view modes.
	var p = S.Particle.new()
	p.vel = Vector3(1, 0, 0)
	var vb: Basis = E.view_basis(p, "ViewVBillboard", Basis.IDENTITY)
	_check(vb.y.is_equal_approx(Vector3(1, 0, 0)), "ViewVBillboard turns the shape's Y along the velocity")
	var cam := Basis(Vector3(1, 0, 0), -0.4) * Basis(Vector3(0, 1, 0), 0.7)
	var bb: Basis = E.view_basis(p, "ViewBillboard", cam)
	_check(bb.x.is_equal_approx(cam.x) and bb.y.is_equal_approx(cam.y) and bb.z.is_equal_approx(-cam.z),
		"ViewBillboard is the inverse view's rows: camera right, up and look (= -back)")
	var yb: Basis = E.view_basis(p, "ViewYBillboard", cam)
	_check(yb.y.is_equal_approx(Vector3.UP) and yb.x.is_equal_approx(cam.x) and yb.z.is_equal_approx(-cam.z),
		"ViewYBillboard forces only row 1 to (0,1,0), rows 0 and 2 unchanged (READ, FUN_00cb0ee0)")
	host.queue_free()

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)
