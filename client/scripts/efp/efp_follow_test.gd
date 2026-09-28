extends SceneTree

## The follow levels (round 621): the node's 20-byte block (u2 orbit, u3
## rotation, u4 velocity, u6 translation, with b0/b1 keeping the old
## rotation/position), the ancestor walk up to the effect, the "changed"
## gate, and the effect placed by its host (EfpSim.set_origin; EfpEffect
## anchoring itself). Synthetic trees only -- never game data. Run headless:
## `godot4 --headless --path client --script res://scripts/efp/efp_follow_test.gd`

var _failures := 0
var S: GDScript
var E: GDScript

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

## A node emitting one particle a frame, living `frames`, with its flags.
func _node(frames: int, flags: Dictionary, render: String = "RenderNone", cmds: Array = []) -> EfpReader.EfpNode:
	var n := EfpReader.EfpNode.new()
	n.name = "n"
	n.frames = frames
	n.extinct = _cmd("NormalTimeExtinct")
	n.emit.append(_cmd("StaticEmit", {"type": "SEFStaticEmit", "delay": 0, "duration": 40,
		"interval": 1, "max_live": 20, "per_trigger": 1.0}))
	n.view = _cmd("ViewNone")
	n.render = _cmd(render)
	n.state = _state()
	var ref := EfpReader.EfpMeshRef.new()
	ref.mesh = ""
	ref.textures = PackedStringArray(["t.ddj"])
	n.meshes.append(ref)
	n.flags = flags
	for c in cmds:
		n.commands.append(c)
	return n

func _initialize() -> void:
	S = load("res://scripts/efp/efp_sim.gd")
	E = load("res://scripts/efp/efp_effect.gd")
	var ok: bool = S != null and S.new().has_method("set_origin")
	_check(ok, "EfpSim.set_origin exists (the effect placed by its host)")
	if not ok:
		_finish()
		return
	_translation()
	_rotation()
	_levels()
	_trail()
	await process_frame # the root is in the tree from the first frame on
	_host()
	_finish()

## The host moves +2 in x a frame. A root node following the effect (u6 = 1)
## keeps its particles on the effect; one following nothing (u6 = 0) leaves
## them where they were born.
func _translation() -> void:
	for u6 in [1, 0]:
		var sim = S.new(S.compile(_node(30, {"u6": u6})), 3)
		for f in range(6):
			sim.set_origin(Vector3(2.0 * f, 0, 0))
			sim.step()
		var xs := []
		for q in sim.particles:
			xs.append(q.pos.x)
		var at: float = sim.origin().x
		if u6 == 1:
			var all_on := true
			for x in xs:
				if absf(x - at) > 1e-4:
					all_on = false
			_check(xs.size() == 6 and all_on, "u6 = 1: the particles travel with the moving effect (%s at %.1f)" % [str(xs), at])
		else:
			_check(xs.size() == 6 and is_equal_approx(xs.min(), 0.0) and is_equal_approx(xs.max(), 10.0),
				"u6 = 0: each particle stays where it was born while the effect moves (%s)" % str(xs))
		sim.clear()

## The effect turns 90 degrees about Y once. u3 = 1 turns the particles'
## rotation with it; u2 = 1 carries their positions round the effect's old
## position; without either they keep both.
func _rotation() -> void:
	var turn := Basis(Vector3.UP, PI / 2)
	for flags in [{"u3": 1}, {"u2": 1}, {}]:
		var n := _node(30, flags, "RenderNone", [_cmd("SetPosition", {"value": Vector3(1, 0, 0)})])
		var fl: Dictionary = (flags as Dictionary).duplicate()
		fl["u6"] = 0
		n.flags = fl
		n.emit.clear()
		n.emit.append(_cmd("StaticEmit", {"type": "SEFStaticEmit", "delay": 0, "duration": 1,
			"interval": 1, "max_live": 1, "per_trigger": 1.0}))
		var sim = S.new(S.compile(n), 3)
		sim.step() # born at (1, 0, 0), rotation identity
		sim.set_origin(Vector3.ZERO, turn)
		sim.step()
		var q = sim.particles[0]
		if flags.has("u3"):
			_check(q.rot.is_equal_approx(turn) and q.pos.is_equal_approx(Vector3(1, 0, 0)),
				"u3 = 1: the rotation turns with the effect, the position does not")
		elif flags.has("u2"):
			_check(q.pos.is_equal_approx(turn * Vector3(1, 0, 0)) and q.rot.is_equal_approx(Basis.IDENTITY),
				"u2 = 1: the position swings round the effect with its turn (%s)" % str(q.pos))
		else:
			_check(q.pos.is_equal_approx(Vector3(1, 0, 0)) and q.rot.is_equal_approx(Basis.IDENTITY),
				"no level: neither turns")
		sim.clear()
	# The gate: a follow applies only on a frame the ancestor changed.
	var sim2 = S.new(S.compile(_node(30, {"u3": 1, "u6": 0})), 3)
	sim2.step()
	sim2.set_origin(Vector3.ZERO, turn)
	sim2.step()
	sim2.step()
	sim2.step()
	_check(sim2.particles[0].rot.is_equal_approx(turn), "a turn is applied once, on the frame it happened, not every frame")
	sim2.clear()

## Level N is the owner N-1 more times up; the effect sits above the root
## node's particles, and nothing above it.
func _levels() -> void:
	var root := _node(30, {"u6": 1})
	var kid := _node(30, {"u6": 2})
	var kid2 := _node(30, {"u6": 3})
	root.children.append(kid)
	kid.children.append(kid2)
	var sim = S.new(S.compile(root), 3)
	sim.step()
	sim.step()
	sim.step()
	var by := {}
	for q in sim.particles:
		by[q.tpl] = q
	var eff = by[0].parent
	_check(by.has(2) and by[1].f_move == eff and by[2].f_move == eff and by[0].f_move == eff,
		"level depth+1 is the effect: the root's 1, its child's 2, the grandchild's 3")
	_check(S._ancestor(by[2], 1) == by[1] and S._ancestor(by[2], 2) == by[0] and S._ancestor(by[2], 9) == null,
		"level 1 is the owner, 2 its owner, and past the effect there is nothing")
	sim.clear()

## A Link chain on a moving effect: with u6 = 0 its particles trail and the
## strip has triangles; with u6 = 1 they ride the effect and collapse.
func _trail() -> void:
	for u6 in [0, 1]:
		var n := _node(10, {"u6": u6}, "RenderLinkDPipe")
		var fx = E.from_template(S.compile(n), func(_p): return PlaceholderTexture2D.new(), func(_p): return null, 5)
		for f in range(8):
			fx.sim.set_origin(Vector3(3.0 * f, 0, 0))
			fx.sim.step()
		fx.reset_link_budget()
		fx._update_links()
		var tris: int = (fx._links[0][3] as EfpLinks.Out).expand().size()
		if u6 == 0:
			_check(tris > 0, "u6 = 0 on a moving effect: the Link chain trails and draws (%d triangles)" % tris)
		else:
			_check(tris == 0, "u6 = 1: the chain rides the effect and collapses to a point (%d triangles)" % tris)
		fx.sim.clear()
		fx.free()

## EfpEffect on a host: the node pins itself (top_level) at its first
## placement and hands the host's motion to the simulation.
func _host() -> void:
	var host := Node3D.new()
	var skel := Skeleton3D.new()
	host.add_child(skel)
	get_root().add_child(host)
	var fx = E.from_template(S.compile(_node(30, {"u6": 0})), func(_p): return PlaceholderTexture2D.new(),
		func(_p): return null, 5)
	host.add_child(fx)
	fx.follow_host(host, "", Vector3.ZERO)
	var start: Transform3D = fx.global_transform
	host.position = Vector3(5, 0, 0)
	fx._process(0.05)
	_check(fx.top_level and fx.global_transform.is_equal_approx(start), "the effect node stays at its anchor while the host moves")
	_check(fx.sim.origin().is_equal_approx(Vector3(5, 0, 0)), "the host's motion reaches the simulation as the effect's placement (%s)" % str(fx.sim.origin()))
	host.position = Vector3(500, 0, 0)
	fx._process(0.05)
	_check(fx.sim.origin().length() < 1.0 and fx.global_transform.origin.is_equal_approx(Vector3(500, 0, 0)),
		"far from the anchor it re-centres, shifting the simulation with it")
	fx.sim.clear()
	host.free()

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)
