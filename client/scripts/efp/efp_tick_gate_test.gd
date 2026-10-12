extends SceneTree

## Round 786 (the second report): an effect on a host is placed once per
## physics tick, the frame its body moves on (EfpEffect.tick_gate; READ in
## its _process comment: one placement and one follow pass a frame,
## 0x00a503f0 / 0x00c85f20 / 0x00c863a0, and a follower of a dead ancestor
## adds the ancestor's last per-pass move on every pass). Placed every
## rendered frame at 144 a second over a body moved on 60 Hz ticks, that
## last move was 0 or a whole tick's, so the follower stopped or ran 2.4
## times too fast. Synthetic trees only -- never game data. Run headless:
## `godot4 --headless --path client --script res://scripts/efp/efp_tick_gate_test.gd`

var _failures := 0
var S: GDScript
var E: GDScript
var _tick := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _cmd(name: String, value = null, space: int = 0) -> EfpReader.EfpCommand:
	var c := EfpReader.EfpCommand.new()
	c.name = name
	c.value = value
	c.space = space
	c.time_flags = 0
	c.start = 0.0
	c.step = 1.0
	c.end = 0.0
	return c

func _state() -> EfpReader.EfpRenderState:
	var s := EfpReader.EfpRenderState.new()
	s.cull = 1
	s.src_blend = 5
	s.dest_blend = 2
	s.color_arg1 = 2
	s.color_arg2 = 0
	s.color_op = 4
	s.alpha_arg1 = 2
	s.alpha_arg2 = 0
	s.alpha_op = 4
	return s

func _node(frames: int, flags: Dictionary, emit_dur: int, emit_max: int) -> EfpReader.EfpNode:
	var n := EfpReader.EfpNode.new()
	n.name = "n"
	n.frames = frames
	n.extinct = _cmd("NormalTimeExtinct")
	n.emit.append(_cmd("StaticEmit", {"type": "SEFStaticEmit", "delay": 0, "duration": emit_dur,
		"interval": 1, "max_live": emit_max, "per_trigger": 1.0}))
	n.view = _cmd("ViewNone")
	n.render = _cmd("RenderPlate")
	n.state = _state()
	var ref := EfpReader.EfpMeshRef.new()
	ref.mesh = ""
	ref.textures = PackedStringArray(["t.ddj"])
	n.meshes.append(ref)
	n.flags = flags
	return n

## A holder living 4 frames (u6 = 1) whose children live 200 and follow it
## (u6 = 1): the children outlive it and follow its frozen move.
func _orphans_tree() -> EfpReader.EfpNode:
	var holder := _node(4, {"u6": 1, "b1": 1}, 1, 1)
	holder.children.append(_node(200, {"u6": 1, "b1": 1}, 4, 4))
	return holder

## A straight run at `speed`, rendered at `fps`, the body moved on 60 Hz
## ticks: the farthest orphan from the body.
func _run(gate: bool, fps: float, speed: float) -> float:
	EfpEffect.tick_gate = gate
	_tick = 0
	EfpEffect.tick_of = func(): return _tick
	var host := Node3D.new()
	host.add_child(Skeleton3D.new())
	get_root().add_child(host)
	var fx = E.from_template(S.compile(_orphans_tree()), func(_p): return PlaceholderTexture2D.new(),
		func(_p): return null, 5)
	host.add_child(fx)
	fx.follow_host(host, "", Vector3.ZERO)
	var dt := 1.0 / fps
	var acc := 0.0
	var worst := 0.0
	for f in range(int(fps * 3.0)):
		acc += dt
		while acc >= 1.0 / 60.0:
			acc -= 1.0 / 60.0
			_tick += 1
			host.position.x += speed / 60.0
		fx._process(dt)
		for p in fx.sim.particles:
			if p.tpl == 1:
				worst = maxf(worst, ((fx.global_transform * p.pos) - host.global_position).length())
	fx.sim.clear()
	host.free()
	return worst

func _initialize() -> void:
	S = load("res://scripts/efp/efp_sim.gd")
	E = load("res://scripts/efp/efp_effect.gd")
	var probe = E.new() if E != null else null
	var ok: bool = probe != null and probe.has_method("gate_ticks") and probe.has_method("_tick_now")
	if probe != null:
		probe.free()
	_check(ok, "EfpEffect.tick_gate / tick_of / gate_ticks exist")
	if not ok:
		_finish()
		return
	await process_frame
	var smooth := _run(false, 60.0, 50.0)
	_check(smooth < 1.0, "a body moved every frame (60 fps, 60 Hz): the orphans keep pace (%.2f)" % smooth)
	var off := _run(false, 144.0, 50.0)
	_check(off > 20.0, "placed every frame at 144 fps over 60 Hz ticks: the orphans leave the body (%.1f)" % off)
	var on := _run(true, 144.0, 50.0)
	_check(on < 1.0, "placed once a tick: they keep pace again (%.2f)" % on)
	var on2 := _run(true, 240.0, 300.0)
	_check(on2 < 1.0, "... at 240 fps and 300 a second too (%.2f)" % on2)
	# A frame with no tick neither places nor steps.
	EfpEffect.tick_gate = true
	_tick = 0
	var host := Node3D.new()
	host.add_child(Skeleton3D.new())
	get_root().add_child(host)
	var fx = E.from_template(S.compile(_node(30, {"u6": 1}, 400, 20)), func(_p): return PlaceholderTexture2D.new(),
		func(_p): return null, 5)
	host.add_child(fx)
	fx.follow_host(host, "", Vector3.ZERO)
	fx._process(0.05)
	var age: int = fx.sim.age
	host.position.x += 10.0
	for f in range(5):
		fx._process(0.05)
	_check(fx.sim.age == age and fx.sim.origin().is_zero_approx(), "no tick: no placement and no step (age %d)" % fx.sim.age)
	_tick += 1
	fx._process(0.05)
	_check(fx.sim.age == age + MAX_STEPS and fx.sim.origin().is_equal_approx(Vector3(10, 0, 0)),
		"the tick: one placement, and the frames' time stepped (age %d, origin %s)" % [fx.sim.age, str(fx.sim.origin())])
	fx.sim.clear()
	host.free()
	# World3D holds the gate while it exists.
	var src := FileAccess.get_file_as_string("res://scripts/World3D.gd")
	var ready_at := src.find("func _ready() -> void:")
	var exit_at := src.find("func _exit_tree() -> void:")
	_check(ready_at >= 0 and src.find("EfpEffect.gate_ticks(true)", ready_at) - ready_at < 400,
		"World3D takes the gate as it starts")
	_check(exit_at >= 0 and src.find("EfpEffect.gate_ticks(false)", exit_at) > exit_at,
		"... and gives it up when it goes")
	EfpEffect.tick_gate = false
	EfpEffect.tick_of = Callable()
	_finish()

## The five 50 ms frames of time the untaken frames held, plus the tick's.
const MAX_STEPS := 6

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)
