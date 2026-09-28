extends SceneTree

## The Link render modes (round 621): EfpLinks' geometry for RenderLinkDPipe,
## RenderLinkPipe and RenderLinkObj, the emitter's particle chain (the "link",
## +0x34) in EfpSim, and EfpEffect drawing Link nodes. Synthetic data only --
## never game data. Run headless:
## `godot4 --headless --path client --script res://scripts/efp/efp_links_test.gd`
##
## The scripts are loaded by path, so a checkout without them prints FAIL.

var _failures := 0
var L: GDScript
var S: GDScript
var E: GDScript

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _near(a: Vector3, b: Vector3, eps: float = 1e-4) -> bool:
	return a.distance_to(b) <= eps

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

## A root node emitting one particle a frame (up to 20 alive), each living
## `frames` frames, with the given render mode and frame-0 commands.
func _node(frames: int, render: String, cmds: Array = []) -> EfpReader.EfpNode:
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
	for c in cmds:
		n.commands.append(c)
	return n

func _pt(p: Vector3, c: int = 0xFFFFFFFF, w: float = 1.0):
	return L.Pt.new(p, c, w)

func _initialize() -> void:
	L = load("res://scripts/efp/efp_links.gd")
	S = load("res://scripts/efp/efp_sim.gd")
	E = load("res://scripts/efp/efp_effect.gd")
	_check(L != null, "scripts/efp/efp_links.gd exists (EfpLinks, the Link geometry)")
	if S == null or E == null:
		_finish()
		return
	if L != null:
		_basics()
		_dpipe()
		_pipe()
		_obj()
	_chain()
	_link_commands()
	_effect()
	_finish()

func _basics() -> void:
	var w: Array = L.bspline(0.0)
	_check(is_equal_approx(w[0], 1.0 / 6.0) and is_equal_approx(w[1], 4.0 / 6.0)
		and is_equal_approx(w[2], 1.0 / 6.0) and is_equal_approx(w[3], 0.0),
		"B-spline weights at t=0 are 1/6, 4/6, 1/6, 0")
	for t in [0.0, 1.0 / 3.0, 2.0 / 3.0]:
		var ws: Array = L.bspline(t)
		_check(is_equal_approx(ws[0] + ws[1] + ws[2] + ws[3], 1.0), "B-spline weights sum to 1 at t=%.3f" % t)
	_check(L.fround(0.5) == 0 and L.fround(1.5) == 2 and L.fround(2.5) == 2 and L.fround(2.6) == 3,
		"fistp rounding is half to even")
	_check(L.lerp_color(0xFF000000, 0xFF0000FF, 0.5) == 0xFF000080, "colour lerps per byte (0..255 at 0.5 is 128)")
	_check(L.lerp_color(0x80FF0000, 0x00000000, 1.0 / 3.0) == 0x55AA0000, "alpha and red lerp on their own bytes")
	var tk: Array = L.take([_pt(Vector3.ZERO), _pt(Vector3(5e-7, 0, 0), 0xFF00FF00), _pt(Vector3(1, 0, 0))])
	_check(tk.size() == 2 and tk[0].color == 0xFF00FF00,
		"a point within 1e-6 of the last taken one replaces it")
	var tri: PackedInt32Array = L.strip_triangles(4)
	_check(tri == PackedInt32Array([0, 1, 2, 2, 1, 3]), "a 4-vertex strip is two triangles, winding alternated")
	_check(L.strip_triangles(2).is_empty(), "a 2-vertex strip draws nothing")

func _ortho(pts: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in pts:
		out.append(Vector2(p.pos.x, p.pos.y))
	return out

func _dpipe() -> void:
	var pts: Array = [_pt(Vector3(0, 0, 0), 0xFFFF0000, 2.0), _pt(Vector3(1, 0, 0), 0xFF00FF00, 3.0),
		_pt(Vector3(2, 0, 0), 0xFF0000FF, 4.0)]
	var line: Array = L.dpipe_points(pts)
	_check(line.size() == 3, "LinkDPipe keeps its points as they are")
	var s = L.pipe_ribbon(line, _ortho(line), Vector3.RIGHT, Vector3.UP)
	_check(s.size() == 6, "a 3-point pipe is a 6-vertex strip")
	# A line along +X seen head-on: d = C(i-1) - C(i+1) = (-2, 0), so the side
	# is up * 2, normalised: the + vertex is P + up*w, the - vertex P - up*w.
	_check(_near(s.verts[2], Vector3(1, 3, 0)) and _near(s.verts[3], Vector3(1, -3, 0)),
		"the ribbon's half-width is the point's width, across the screen line")
	_check(_near(s.verts[0], Vector3(0, 2, 0)) and _near(s.verts[5], Vector3(2, -4, 0)),
		"the end points use their one neighbour")
	_check(s.uvs[0] == Vector2(0, 0) and s.uvs[1] == Vector2(0, 1) and s.uvs[2] == Vector2(0.5, 0)
		and s.uvs[5] == Vector2(1, 1), "u runs 0..1 along the chain, v is 0 on the + side and 1 on the -")
	_check(s.colors[0] == 0xFFFF0000 and s.colors[3] == 0xFF00FF00, "each pair takes its point's colour")
	_check(L.pipe_ribbon([_pt(Vector3.ZERO)], PackedVector2Array([Vector2.ZERO]), Vector3.RIGHT, Vector3.UP).size() == 0,
		"one point draws no pipe")

func _pipe() -> void:
	var two: Array = L.pipe_points([_pt(Vector3(0, 0, 0), 0xFF000000, 1.0), _pt(Vector3(6, 0, 0), 0xFF0000FF, 4.0)])
	_check(two.size() == 4, "LinkPipe: 2 points give 3*(2-1)+1 = 4")
	# P0 = P1 = 0, P2 = P3 = 6: at t=0 the sample is (0 + 4*0 + 6)/6 = 1.
	_check(_near(two[0].pos, Vector3(1, 0, 0)), "the first sample is the B-spline at t=0, not the first point")
	_check(_near(two[3].pos, Vector3(6, 0, 0)), "the last point is appended as it is")
	_check(is_equal_approx(two[1].width, 2.0) and is_equal_approx(two[2].width, 3.0),
		"the width steps by a third of the difference")
	_check(two[1].color == 0xFF000055, "the colour lerps by t (255/3 = 85 at t=1/3)")
	var four: Array = L.pipe_points([_pt(Vector3(0, 0, 0)), _pt(Vector3(1, 0, 0)), _pt(Vector3(2, 0, 0)), _pt(Vector3(3, 0, 0))])
	_check(four.size() == 10, "LinkPipe: 4 points give 10")
	var on_line := true
	for q in four:
		if absf(q.pos.y) > 1e-6 or absf(q.pos.z) > 1e-6:
			on_line = false
	_check(on_line, "a straight chain stays straight")
	_check(_near(four[4].pos, Vector3(4.0 / 3.0, 0, 0), 1e-5), "evenly spaced points are sampled evenly inside")
	_check(L.pipe_points([_pt(Vector3.ZERO)]).is_empty(), "one point draws no LinkPipe")

func _obj() -> void:
	var ys := [Vector3.UP, Vector3.UP, Vector3.UP]
	var two = L.obj_ribbon([_pt(Vector3(0, 0, 0)), _pt(Vector3(1, 0, 0))], [Vector3.UP, Vector3.UP])
	_check(L.strip_triangles(two.size()).is_empty(), "LinkObj: 2 particles make no triangle (the last pair is only a control point)")
	var s = L.obj_ribbon([_pt(Vector3(0, 0, 0), 0xFFFFFFFF, 2.0), _pt(Vector3(3, 0, 0), 0xFFFFFFFF, 2.0),
		_pt(Vector3(6, 0, 0), 0xFFFFFFFF, 2.0)], ys)
	_check(s.size() == 8, "LinkObj: 3 particles give 3 samples and the closing pair, 8 vertices")
	_check(_near(s.verts[0], Vector3(0.5, 2, 0)) and _near(s.verts[1], Vector3(0.5, -2, 0)),
		"the edges are pos +- rotation Y * scale.x, splined (first sample (0*1+0*4+3)/6)")
	_check(_near(s.verts[6], Vector3(3, 2, 0)) and _near(s.verts[7], Vector3(3, -2, 0)),
		"the strip closes at the second-newest particle")
	_check(is_equal_approx(s.uvs[0].x, 1.0) and is_equal_approx(s.uvs[6].x, 0.0) and is_equal_approx(s.uvs[2].x, 2.0 / 3.0)
		and s.uvs[1].y == 1.0 and s.uvs[0].y == 0.0, "u runs 1 -> 0 by 2/sample vertices; v is 0 on + and 1 on -")
	var tilted = L.obj_ribbon([_pt(Vector3(0, 0, 0), 0xFFFFFFFF, 1.0), _pt(Vector3(0, 0, 3), 0xFFFFFFFF, 1.0),
		_pt(Vector3(0, 0, 6), 0xFFFFFFFF, 1.0)], [Vector3.RIGHT, Vector3.RIGHT, Vector3.RIGHT])
	_check(_near(tilted.verts[6], Vector3(1, 0, 3)), "the width follows the particle's own Y axis, not the camera")

func _chain() -> void:
	var sim = S.new(S.compile(_node(5, "RenderNone", [_cmd("SetVelocity", {"value": Vector3(1, 0, 0)})])), 3)
	for _i in range(3):
		sim.step()
	_check(sim.particles.size() == 3, "one particle a frame: 3 alive after 3 frames")
	var a = sim.particles[0]
	var b = sim.particles[1]
	var c = sim.particles[2]
	_check("link" in a, "a particle carries its link (+0x34)")
	if not ("link" in a):
		sim.clear()
		return
	_check(a.link == null and b.link == a and c.link == b, "the link is the emitter's previous live particle")
	_check(a.next_link == b and b.next_link == c and c.next_link == null, "and next_link the one after")
	var chains: Dictionary = E.link_chains(sim)
	_check(chains.has(0) and (chains[0] as Array).size() == 1 and (chains[0][0] as Array) == [a, b, c],
		"one chain per emitter, oldest first")
	for _i in range(3):
		sim.step()
	_check(sim.particles.size() == 4 and sim.particles[0].link == null and sim.particles[1].link == sim.particles[0],
		"a death unlinks: the oldest live particle heads the chain")
	sim.clear()

func _link_commands() -> void:
	if not S.has_method("names_link"):
		_check(false, "EfpSim.names_link exists")
		return
	# SetPosition space 2: start from the link's position and add the value.
	var sim = S.new(S.compile(_node(10, "RenderNone", [_cmd("SetPosition", {"value": Vector3(0, 1, 0)}, 2)])), 5)
	sim.step()
	sim.step()
	var first = sim.particles[0]
	var second = sim.particles[1]
	_check(_near(first.pos, Vector3.ZERO), "a link variant does nothing without a link (the oldest particle)")
	_check(_near(second.pos, Vector3(0, 1, 0)), "SetPosition space 2 starts from the link's position")
	_check(S.names_link("SetPosition", 2) and S.names_link("SetPosition", 9) and not S.names_link("SetPosition", 7)
		and S.names_link("Force", 3) and S.names_link("Attraction", 1) and S.names_link("SetSpherePos", 2)
		and not S.names_link("SetSpherePos", 1), "which variants name the link")
	sim.clear()

func _effect() -> void:
	for mode in ["RenderLinkDPipe", "RenderLinkPipe", "RenderLinkObj"]:
		var n := _node(10, mode, [_cmd("SetVelocity", {"value": Vector3(1, 0.2, 0)})])
		var tmpl = S.compile(n)
		var fx = E.from_template(tmpl, func(_p): return PlaceholderTexture2D.new(), func(_p): return null, 9)
		var skipped_mode := false
		for r in fx.skipped:
			if String(r).begins_with(mode):
				skipped_mode = true
		_check(not skipped_mode and fx.draw_count() == 1, "%s is drawn, not skipped" % mode)
		if not fx.has_method("_update_links"):
			fx.sim.clear()
			fx.free()
			continue
		for _i in range(6):
			fx.sim.step()
		fx._update_links()
		var mi: MeshInstance3D = fx.get_node_or_null("link_0")
		var ok := mi != null and mi.mesh is ImmediateMesh and (mi.mesh as ImmediateMesh).get_surface_count() == 1
		_check(ok, "%s builds one surface for its chain" % mode)
		if ok:
			var arr: Array = (mi.mesh as ImmediateMesh).surface_get_arrays(0)
			var nv: int = (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
			_check(nv > 0 and nv % 3 == 0, "%s's surface is whole triangles (%d vertices)" % [mode, nv])
		fx.sim.clear()
		fx.free()
	var none := _node(10, "RenderLinkPipe")
	none.meshes.clear()
	var fx2 = E.from_template(S.compile(none), func(_p): return PlaceholderTexture2D.new(), func(_p): return null, 9)
	_check(fx2.draw_count() == 0 and "texture (none)" in fx2.skipped, "a Link node without a texture entry is reported, not drawn")
	fx2.sim.clear()
	fx2.free()

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)
