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

## A Buf from [position, colour, width, y axis] rows.
func _buf(rows: Array):
	var b = L.Buf.new()
	for r in rows:
		b.add(r[0], r[1] if r.size() > 1 else 0xFFFFFFFF, r[2] if r.size() > 2 else 1.0, r[3] if r.size() > 3 else Vector3.UP)
	return b

func _c8(c: int) -> Color:
	return Color8((c >> 16) & 0xFF, (c >> 8) & 0xFF, c & 0xFF, (c >> 24) & 0xFF)

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
	_follow()
	_link_commands()
	_effect()
	_finish()

func _basics() -> void:
	var w: PackedFloat64Array = L.bspline(0.0)
	_check(is_equal_approx(w[0], 1.0 / 6.0) and is_equal_approx(w[1], 4.0 / 6.0)
		and is_equal_approx(w[2], 1.0 / 6.0) and is_equal_approx(w[3], 0.0),
		"B-spline weights at t=0 are 1/6, 4/6, 1/6, 0")
	for t in [0.0, 1.0 / 3.0, 2.0 / 3.0]:
		var ws: PackedFloat64Array = L.bspline(t)
		_check(is_equal_approx(ws[0] + ws[1] + ws[2] + ws[3], 1.0), "B-spline weights sum to 1 at t=%.3f" % t)
	_check(L.fround(0.5) == 0 and L.fround(1.5) == 2 and L.fround(2.5) == 2 and L.fround(2.6) == 3,
		"fistp rounding is half to even")
	_check(L.lerp_color(0xFF000000, 0xFF0000FF, 0.5) == 0xFF000080, "colour lerps per byte (0..255 at 0.5 is 128)")
	_check(L.lerp_color(0x80FF0000, 0x00000000, 1.0 / 3.0) == 0x55AA0000, "alpha and red lerp on their own bytes")
	# The dedupe (review follow-up). Pipes DROP a near-duplicate and keep the
	# older point; LinkObj OVERWRITES the last taken pair but keeps comparing
	# against the position it took.
	var rows := [[Vector3.ZERO, 0xFF0000FF], [Vector3(6e-7, 0, 0), 0xFF00FF00], [Vector3(1.2e-6, 0, 0), 0xFFFF0000]]
	var pipe_b = L.Buf.new()
	L.dedupe(_buf(rows), false, pipe_b)
	_check(pipe_b.n == 2 and pipe_b.col[0] == 0xFF0000FF and pipe_b.pos[1] == Vector3(1.2e-6, 0, 0),
		"a pipe drops the near-duplicate and keeps the older point")
	var obj_b = L.Buf.new()
	L.dedupe(_buf(rows), true, obj_b)
	_check(obj_b.n == 2 and obj_b.col[0] == 0xFF00FF00 and obj_b.pos[1] == Vector3(1.2e-6, 0, 0),
		"LinkObj overwrites with the near-duplicate but compares against the position it took")
	var o = L.Out.new()
	o.begin_strip(4)
	o.pair(Vector3(0, 1, 0), Vector3(0, -1, 0), 0xFFFFFFFF, 0.0)
	o.pair(Vector3(1, 1, 0), Vector3(1, -1, 0), 0xFFFFFFFF, 1.0)
	o.end_strip()
	# Strip vertices v0..v3 sit at 1..4 behind one stitching copy of v0. D3D
	# draws (v0, v1, v2) and (v2, v1, v3); each must come out reversed.
	_check(o.expand() == [[2, 1, 3], [2, 3, 4]],
		"a 4-vertex strip is D3D's two triangles, each reversed (%s)" % str(o.expand()))
	var o2 = L.Out.new()
	o2.begin_strip(2)
	o2.pair(Vector3.ZERO, Vector3.UP, 0xFFFFFFFF, 0.0)
	o2.end_strip()
	_check(o2.expand().is_empty(), "a 2-vertex strip draws nothing")

## A line along +X seen head-on (the headless view: identity projection).
func _ribbon(b):
	var o = L.Out.new()
	L.pipe_ribbon(b, Projection.IDENTITY, Vector3.RIGHT, Vector3.UP, o)
	return o

func _dpipe() -> void:
	var b = _buf([[Vector3(0, 0, 0), 0xFFFF0000, 2.0], [Vector3(1, 0, 0), 0xFF00FF00, 3.0],
		[Vector3(2, 0, 0), 0xFF0000FF, 4.0]])
	var s = _ribbon(b)
	_check(s.nv == 7 and s.expand().size() == 4, "a 3-point pipe is a 6-vertex strip, 4 triangles")
	var k := 1 # the strip starts behind one stitching vertex
	# d = C(i-1) - C(i+1) = (-2, 0), so the side is up * 2, normalised.
	_check(_near(s.verts[k + 2], Vector3(1, 3, 0)) and _near(s.verts[k + 3], Vector3(1, -3, 0)),
		"the ribbon's half-width is the point's width, across the screen line")
	_check(_near(s.verts[k], Vector3(0, 2, 0)) and _near(s.verts[k + 5], Vector3(2, -4, 0)),
		"the end points use their one neighbour")
	_check(s.uvs[k] == Vector2(0, 0) and s.uvs[k + 1] == Vector2(0, 1) and s.uvs[k + 2] == Vector2(0.5, 0)
		and s.uvs[k + 5] == Vector2(1, 1), "u runs 0..1 along the chain, v is 0 on the + side and 1 on the -")
	_check(s.colors[k] == _c8(0xFFFF0000) and s.colors[k + 3] == _c8(0xFF00FF00), "each pair takes its point's colour")
	_check(_ribbon(_buf([[Vector3.ZERO]])).nv == 0, "one point draws no pipe")
	# Two strips into one Out stay separate (no triangle joins them).
	var o = L.Out.new()
	L.pipe_ribbon(b, Projection.IDENTITY, Vector3.RIGHT, Vector3.UP, o)
	L.pipe_ribbon(b, Projection.IDENTITY, Vector3.RIGHT, Vector3.UP, o)
	# Stitched into one strip: the triangles between the two are degenerate.
	var tris: Array = o.expand()
	var joins := false
	for t in tris:
		var lo: int = mini(t[0], mini(t[1], t[2]))
		var hi: int = maxi(t[0], maxi(t[1], t[2]))
		if lo <= 6 and hi > 7:
			joins = true
	_check(tris.size() == 8 and not joins, "two chains are two strips, never joined by a drawn triangle")
	# Every drawn triangle of both keeps the reversed orientation: in this
	# head-on view (x right, y up) D3D's are counter-clockwise, so ours are
	# clockwise (negative signed area).
	var all_cw := true
	for t in tris:
		var a: Vector3 = o.verts[t[0]]
		var bb: Vector3 = o.verts[t[1]]
		var c: Vector3 = o.verts[t[2]]
		if (bb.x - a.x) * (c.y - a.y) - (bb.y - a.y) * (c.x - a.x) >= 0.0:
			all_cw = false
	_check(all_cw, "the second strip keeps the first's orientation (stitching parity)")

func _pipe() -> void:
	var two = L.Buf.new()
	L.spline(_buf([[Vector3(0, 0, 0), 0xFF000000, 1.0], [Vector3(6, 0, 0), 0xFF0000FF, 4.0]]), two)
	_check(two.n == 4, "LinkPipe: 2 points give 3*(2-1)+1 = 4")
	# P0 = P1 = 0, P2 = P3 = 6: at t=0 the sample is (0 + 4*0 + 6)/6 = 1.
	_check(_near(two.pos[0], Vector3(1, 0, 0)), "the first sample is the B-spline at t=0, not the first point")
	_check(_near(two.pos[3], Vector3(6, 0, 0)), "the last point is appended as it is")
	_check(is_equal_approx(two.w[1], 2.0) and is_equal_approx(two.w[2], 3.0),
		"the width steps by a third of the difference")
	_check(two.col[1] == 0xFF000055, "the colour lerps by t (255/3 = 85 at t=1/3)")
	var four = L.Buf.new()
	L.spline(_buf([[Vector3(0, 0, 0)], [Vector3(1, 0, 0)], [Vector3(2, 0, 0)], [Vector3(3, 0, 0)]]), four)
	_check(four.n == 10, "LinkPipe: 4 points give 10")
	var on_line := true
	for q in range(four.n):
		if absf(four.pos[q].y) > 1e-6 or absf(four.pos[q].z) > 1e-6:
			on_line = false
	_check(on_line, "a straight chain stays straight")
	_check(_near(four.pos[4], Vector3(4.0 / 3.0, 0, 0), 1e-5), "evenly spaced points are sampled evenly inside")
	var one = L.Buf.new()
	L.spline(_buf([[Vector3.ZERO]]), one)
	_check(one.n == 0, "one point draws no LinkPipe")

func _obj() -> void:
	var o2 = L.Out.new()
	L.obj_ribbon(_buf([[Vector3(0, 0, 0)], [Vector3(1, 0, 0)]]), o2)
	_check(o2.expand().is_empty(), "LinkObj: 2 particles make no triangle (the last pair is only a control point)")
	var s = L.Out.new()
	L.obj_ribbon(_buf([[Vector3(0, 0, 0), 0xFFFFFFFF, 2.0], [Vector3(3, 0, 0), 0xFFFFFFFF, 2.0],
		[Vector3(6, 0, 0), 0xFFFFFFFF, 2.0]]), s)
	_check(s.nv == 9 and s.expand().size() == 6, "LinkObj: 3 particles give 3 samples and the closing pair, 8 vertices")
	var k := 1
	_check(_near(s.verts[k], Vector3(0.5, 2, 0)) and _near(s.verts[k + 1], Vector3(0.5, -2, 0)),
		"the edges are pos +- rotation Y * scale.x, splined (first sample (0*1+0*4+3)/6)")
	_check(_near(s.verts[k + 6], Vector3(3, 2, 0)) and _near(s.verts[k + 7], Vector3(3, -2, 0)),
		"the strip closes at the second-newest particle")
	_check(is_equal_approx(s.uvs[k].x, 1.0) and is_equal_approx(s.uvs[k + 6].x, 0.0) and is_equal_approx(s.uvs[k + 2].x, 2.0 / 3.0)
		and s.uvs[k + 1].y == 1.0 and s.uvs[k].y == 0.0, "u runs 1 -> 0 by 2/sample vertices; v is 0 on + and 1 on -")
	var tilted = L.Out.new()
	L.obj_ribbon(_buf([[Vector3(0, 0, 0), 0xFFFFFFFF, 1.0, Vector3.RIGHT], [Vector3(0, 0, 3), 0xFFFFFFFF, 1.0, Vector3.RIGHT],
		[Vector3(0, 0, 6), 0xFFFFFFFF, 1.0, Vector3.RIGHT]]), tilted)
	_check(_near(tilted.verts[7], Vector3(1, 0, 3)), "the width follows the particle's own Y axis, not the camera")

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
	var after: Dictionary = E.link_chains(sim)
	_check(after.has(0) and (after[0][0] as Array).size() == 4, "a dead head does not blank the strip: the rest still chain")
	# A spawn the cap refuses is never linked (review follow-up).
	var saved: int = S.live_total
	S.live_total = 1000000
	var tail = sim.particles[sim.particles.size() - 1]
	sim.step()
	S.live_total = saved + (S.live_total - 1000000)
	var consistent: bool = tail.next_link == null or sim.particles.has(tail.next_link)
	for q in sim.particles:
		if q.link != null and not sim.particles.has(q.link):
			consistent = false
	_check(consistent and sim.dropped > 0, "a refused spawn leaves the chain consistent (dropped %d)" % sim.dropped)
	var kept: Array = sim.particles.duplicate()
	sim.clear()
	var cleared := true
	for q in kept:
		if q.link != null or q.next_link != null:
			cleared = false
	_check(cleared, "clear() breaks every link pair (no RefCounted cycle is left)")

## A child node that follows its parent's translation (u6 = 1) moves with
## it; one that follows nothing (u6 = 0) stays where it was born (READ,
## CEFGroup::vslot_004 / CEFUpdater::vslot_002; efp_follow_test.gd has the
## rest).
func _follow() -> void:
	for u6 in [1, 0]:
		var root := _node(40, "RenderNone", [_cmd("SetVelocity", {"value": Vector3(1, 0, 0)})])
		root.emit.clear()
		root.emit.append(_cmd("StaticEmit", {"type": "SEFStaticEmit", "delay": 0, "duration": 1,
			"interval": 1, "max_live": 1, "per_trigger": 1.0}))
		root.flags = {"u6": 1, "b1": 1}
		# The children stand still on their own (a new particle inherits its
		# parent's velocity minus the followed one's), so only a follow moves them.
		var kid := _node(10, "RenderLinkDPipe", [_cmd("SetVelocity", {"value": Vector3.ZERO})])
		kid.flags = {"u6": u6}
		root.children.append(kid)
		var sim = S.new(S.compile(root), 4)
		for _i in range(6):
			sim.step()
		var xs := []
		for q in sim.particles:
			if q.tpl == 1:
				xs.append(snappedf(q.pos.x, 0.001))
		var spread: float = (xs.max() - xs.min()) if not xs.is_empty() else 0.0
		if u6 == 1:
			_check(xs.size() >= 3 and spread == 0.0, "u6 = 1: the children move with their parent (spread %.2f)" % spread)
		else:
			_check(xs.size() >= 3 and spread >= 2.0, "u6 = 0: the children stay where they were born, so the chain trails (spread %.2f)" % spread)
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
		var ok := mi != null and mi.mesh != null and mi.mesh.get_surface_count() == 1
		_check(ok, "%s builds one surface for its chain" % mode)
		if ok:
			var arr: Array = mi.mesh.surface_get_arrays(0)
			var nv: int = (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
			_check(nv >= 3 and mi.mesh.surface_get_primitive_type(0) == Mesh.PRIMITIVE_TRIANGLE_STRIP,
				"%s's surface is one triangle strip (%d vertices)" % [mode, nv])
			var code: String = (mi.material_override as ShaderMaterial).shader.code
			_check(code.find("INSTANCE_CUSTOM") < 0, "%s's shader does not apply the instance UV rectangle" % mode)
		fx.sim.clear()
		fx.free()
	# The plate shader still maps the instance UV rectangle.
	var plate_m: ShaderMaterial = E.material_for(PlaceholderTexture2D.new(), _state())
	_check(plate_m.shader.code.find("INSTANCE_CUSTOM") >= 0, "the plate shader keeps the instance UV rectangle")
	# The node's cull applies to its strips (review follow-up): 1 none, 3 ccw.
	var st1 := _state()
	var st3 := _state()
	st3.cull = 3
	var m1: ShaderMaterial = E.link_material_for(PlaceholderTexture2D.new(), st1)
	var m3: ShaderMaterial = E.link_material_for(PlaceholderTexture2D.new(), st3)
	_check(m1.shader.code.find("cull_disabled") >= 0 and m3.shader.code.find("cull_back") >= 0,
		"a Link strip honours its node's cull (1 both faces, 3 back faces culled)")
	# Rebuilt only after a step (no camera headless), and within the budget.
	var host := Node3D.new()
	get_root().add_child(host)
	var fx3 = E.from_template(S.compile(_node(10, "RenderLinkPipe", [_cmd("SetVelocity", {"value": Vector3(1, 0, 0)})])),
		func(_p): return PlaceholderTexture2D.new(), func(_p): return null, 9)
	host.add_child(fx3)
	fx3._process(0.05)
	fx3._process(0.05)
	var u0: int = fx3.link_updates
	fx3._process(0.01)
	_check(fx3.link_updates == u0, "no step and no camera move: the strips are not rebuilt")
	fx3._process(0.05)
	_check(fx3.link_updates == u0 + 1, "a step rebuilds them")
	var before: int = fx3.get_node("link_0").mesh.get_surface_count()
	E._link_budget_frame = Engine.get_process_frames()
	E._link_budget_left = 0
	fx3.sim.step()
	fx3._update_links()
	_check(fx3.get_node("link_0").mesh.get_surface_count() == before, "past the Link budget a node keeps last frame's strips")
	E._link_budget_frame = -1
	fx3.sim.clear()
	host.free()
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
