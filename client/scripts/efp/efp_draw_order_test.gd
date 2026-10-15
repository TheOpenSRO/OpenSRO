extends SceneTree

## Round 786: where an effect draws in the frame.
##
## - READ (EfpEffect.RENDER_PRIORITY's comment, sro_client.exe): every effect
##   draws right after its owner's meshes -- a waterfall's sheet, a
##   fountain's streams, blended in place -- and after the map water, depth-
##   tested with no depth write. Here: every effect material (plate, mesh,
##   Link, and the twins made from them) at a render priority above the object
##   surfaces (0), the water and the fog pass, so Godot's transparent sort by
##   distance can no longer put a sheet or a pool over the particles.
##
## Synthetic trees only -- never game data. Run headless:
## `godot4 --headless --path client --script res://scripts/efp/efp_draw_order_test.gd`

var _failures := 0

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

func _state(src: int, dest: int) -> EfpReader.EfpRenderState:
	var s := EfpReader.EfpRenderState.new()
	s.cull = 1
	s.src_blend = src
	s.dest_blend = dest
	s.color_arg1 = 2
	s.color_arg2 = 0
	s.color_op = 4
	s.alpha_arg1 = 2
	s.alpha_arg2 = 0
	s.alpha_op = 4
	return s

## A plate node living `frames`, emitting one particle a frame up to
## `max_live`, blended src/dest.
func _plate(frames: int, max_live: int, src: int = 5, dest: int = 2) -> EfpReader.EfpNode:
	var n := EfpReader.EfpNode.new()
	n.name = "n"
	n.frames = frames
	n.extinct = _cmd("NormalTimeExtinct")
	n.emit.append(_cmd("StaticEmit", {"type": "SEFStaticEmit", "delay": 0, "duration": 400,
		"interval": 1, "max_live": max_live, "per_trigger": 1.0}))
	n.view = _cmd("ViewBillboard")
	n.render = _cmd("RenderPlate")
	n.state = _state(src, dest)
	var ref := EfpReader.EfpMeshRef.new()
	ref.mesh = ""
	ref.textures = PackedStringArray(["t.ddj"])
	n.meshes.append(ref)
	n.flags = {"u6": 1, "b1": 1}
	return n

## A holder (drawn nothing) with `kids` under it.
func _tree(kids: Array) -> EfpReader.EfpNode:
	var root := EfpReader.EfpNode.new()
	root.name = "root"
	root.frames = 60
	root.extinct = _cmd("NormalTimeExtinct")
	root.emit.append(_cmd("StaticEmit", {"type": "SEFStaticEmit", "delay": 0, "duration": 1,
		"interval": 1, "max_live": 1, "per_trigger": 1.0}))
	root.view = _cmd("ViewNone")
	root.render = _cmd("RenderNone")
	root.state = _state(5, 6)
	root.flags = {"u6": 1, "b1": 1}
	for k in kids:
		root.children.append(k)
	return root

func _build(tree: EfpReader.EfpNode) -> Array:
	var host := Node3D.new()
	host.add_child(Skeleton3D.new())
	get_root().add_child(host)
	var fx := EfpEffect.from_template(EfpSim.compile(tree), func(_p): return PlaceholderTexture2D.new(),
		func(_p): return null, 7)
	fx.loop = true
	fx.sim.keep = true
	host.add_child(fx)
	fx.follow_host(host, "", Vector3.ZERO)
	return [host, fx]

func _stack_of(fx: EfpEffect) -> float:
	var m := (fx._draws[0][1] as GeometryInstance3D).material_override as ShaderMaterial
	return float(m.get_shader_parameter("srr_stack"))

func _initialize() -> void:
	EfpEffect.tick_gate = false
	_test_priorities()
	await process_frame
	_test_effect_materials()
	_test_twins()
	_test_pass()
	_test_mtrl_display_blend()
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)

func _test_priorities() -> void:
	var p := EfpEffect.RENDER_PRIORITY
	_check(EfpEffect.render_priority == p, "the priority in use is RENDER_PRIORITY (%d) without the QA override" % p)
	_check(p > 0, "above every object surface, which draws at priority 0 (an MTRL-blended sheet or stream)")
	_check(p > WorldFog.UNDER_PASS_PRIORITY, "above the map water (%d)" % WorldFog.UNDER_PASS_PRIORITY)
	_check(p > WorldFog.PASS_PRIORITY and p > ShadowCatcher.PRIORITY, "above the fog pass and the shadow catcher")
	var plate := EfpEffect.material_for(PlaceholderTexture2D.new(), _state(5, 2), true)
	var mixm := EfpEffect.material_for(PlaceholderTexture2D.new(), _state(5, 6))
	var link := EfpEffect.link_material_for(PlaceholderTexture2D.new(), _state(5, 2))
	_check(plate.render_priority == p and mixm.render_priority == p and link.render_priority == p,
		"plate, mixing and Link materials all draw at it (%d, %d, %d)" % [plate.render_priority, mixm.render_priority, link.render_priority])

func _test_effect_materials() -> void:
	var made := _build(_tree([_plate(10, 4), _plate(10, 4, 5, 6)]))
	var host: Node3D = made[0]
	var fx: EfpEffect = made[1]
	var ok := not fx._draws.is_empty()
	for d in fx._draws:
		ok = ok and ((d[1] as GeometryInstance3D).material_override as Material).render_priority == EfpEffect.RENDER_PRIORITY
	_check(ok, "an effect's draws carry the priority (%d draws)" % fx._draws.size())
	EfpEffect.display_twins_headless = true
	fx.use_display_blend()
	EfpEffect.display_twins_headless = false
	ok = fx._display_materials.size() == fx._draws.size()
	for d in fx._draws:
		var m := (d[1] as GeometryInstance3D).material_override as ShaderMaterial
		ok = ok and m.render_priority == EfpEffect.RENDER_PRIORITY and m.shader.code.contains("hint_screen_texture")
	_check(ok, "the display twins keep it")
	fx.make_glow()
	ok = not fx._glow_materials.is_empty()
	for g in fx._glow_materials:
		ok = ok and g.render_priority == EfpEffect.RENDER_PRIORITY
	_check(ok, "the glow twins keep it")
	fx.sim.clear()
	host.free()
	var made2 := _build(_tree([_plate(10, 4)]))
	var fx2: EfpEffect = made2[1]
	fx2.use_shared_turn()
	ok = true
	for d in fx2._draws:
		ok = ok and ((d[1] as GeometryInstance3D).material_override as Material).render_priority == EfpEffect.RENDER_PRIORITY
	_check(ok, "the shared-turn twins keep it")
	fx2.sim.clear()
	(made2[0] as Node3D).free()

func _twins(fx: EfpEffect) -> void:
	EfpEffect.display_twins_headless = true
	fx.use_display_blend()
	EfpEffect.display_twins_headless = false

## The display twins' blend itself is round 722 / 774's, unchanged: the
## priority is the only change to them.
func _test_twins() -> void:
	var made := _build(_tree([_plate(30, 5), _plate(30, 5), _plate(30, 3, 5, 6)]))
	var fx: EfpEffect = made[1]
	_twins(fx)
	var ok := fx._display_materials.size() == 3
	for m in fx._display_materials:
		ok = ok and is_equal_approx(float(m.get_shader_parameter("srr_stack")), 2.0) and m.render_priority == EfpEffect.RENDER_PRIORITY
	_check(ok, "three twins, round 774's stack (two additive nodes: 2), at the effects' priority")
	fx.sim.clear()
	(made[0] as Node3D).free()

## Round 786: the display pass (EfpDisplayPass): its blend factors are the
## node's own Direct3D pair, and an effect hands it its draws.
func _test_pass() -> void:
	var F := RenderingDevice
	_check(EfpDisplayPass.d3d_pair(5, 2) == Vector2i(F.BLEND_FACTOR_SRC_ALPHA, F.BLEND_FACTOR_ONE)
		and EfpDisplayPass.d3d_pair(5, 6) == Vector2i(F.BLEND_FACTOR_SRC_ALPHA, F.BLEND_FACTOR_ONE_MINUS_SRC_ALPHA)
		and EfpDisplayPass.d3d_pair(2, 2) == Vector2i(F.BLEND_FACTOR_ONE, F.BLEND_FACTOR_ONE)
		and EfpDisplayPass.d3d_pair(1, 6) == Vector2i(F.BLEND_FACTOR_ZERO, F.BLEND_FACTOR_ONE_MINUS_SRC_ALPHA),
		"SRCALPHA/ONE, SRCALPHA/INVSRCALPHA, ONE/ONE and ZERO/INVSRCALPHA map to the same factors")
	_check(EfpDisplayPass.d3d_pair(12, 2) == Vector2i(F.BLEND_FACTOR_SRC_ALPHA, F.BLEND_FACTOR_ONE_MINUS_SRC_ALPHA)
		and EfpDisplayPass.d3d_pair(13, 1) == Vector2i(F.BLEND_FACTOR_ONE_MINUS_SRC_ALPHA, F.BLEND_FACTOR_SRC_ALPHA)
		and EfpDisplayPass.d3d_pair(9, 1) == Vector2i(F.BLEND_FACTOR_DST_COLOR, F.BLEND_FACTOR_ZERO),
		"BOTHSRCALPHA and BOTHINVSRCALPHA set the destination too; DESTCOLOR/ZERO multiplies")
	var xf := Transform3D(Basis(Vector3(1, 0, 0), Vector3(0, 2, 0), Vector3(0, 0, -1)), Vector3(10, 20, 30))
	var pc := EfpDisplayPass.push_constants(xf, PackedInt32Array([4, 2, 0, 5, 2, 0]), 200, 5)
	var f := pc.slice(0, 48).to_float32_array()
	var i := pc.slice(48).to_int32_array()
	_check(pc.size() == 80 and f[3] == 10.0 and f[5] == 2.0 and f[10] == -1.0 and f[11] == 30.0
		and i == PackedInt32Array([4, 2, 0, 5, 2, 0, 200, 5]),
		"the push constants: three rows of the node's transform, the stage ops, the glow alpha and the stride (80 bytes)")
	var dp := EfpDisplayPass.new()
	var q := QuadMesh.new()
	q.size = Vector2(1, 1)
	var md := dp.mesh_data(q)
	_check(md.size() == 6 * 8 and dp.mesh_data(q) == md, "a plate is two triangles, eight floats a vertex, kept per mesh")
	EfpDisplayPass.pass_headless_active(dp)
	EfpEffect.pass_headless = true
	EfpEffect.display_twins_headless = true
	var made := _build(_tree([_plate(30, 4), _plate(30, 4, 5, 6)]))
	var fx: EfpEffect = made[1]
	fx.use_display_blend()
	EfpEffect.pass_headless = false
	EfpEffect.display_twins_headless = false
	var hidden := true
	for d in fx._draws:
		hidden = hidden and (d[1] as GeometryInstance3D).layers == 0
	_check(fx._pass_draws and hidden and dp.count() == 1, "use_display_blend hands the plates to the pass and Godot draws them no more")
	for k in 6:
		fx._process(0.05)
	var items: Array = []
	fx.pass_items(items, [], Vector3(0, 0, 100), dp)
	var ok := items.size() == 2
	if ok:
		var a: Dictionary = items[0]
		var b: Dictionary = items[1]
		ok = a["src"] == 5 and a["dest"] == 2 and b["dest"] == 6 and int(a["count"]) > 0 and a["cull"] == false \
			and a["depth_test"] == true and (a["pc"] as PackedByteArray).size() == 80 and a["mm"] is MultiMesh and a["tex"] is Texture2D
	_check(ok, "each drawn node becomes an item: its blend pair, particle count, culling (a billboard: none), depth test and push constants (%d items)" % items.size())
	EfpDisplayPass.pass_headless_active(null)
	fx.sim.clear()
	(made[0] as Node3D).free()

## Round 786: an MTRL pass blends in display values where it writes no depth.
func _test_mtrl_display_blend() -> void:
	_check(ObjectLoader.wants_display_blend("mix", false, false, true) and ObjectLoader.wants_display_blend("add", false, false, true),
		"a mixing or adding MTRL pass with no depth write gets the display tail under Forward+")
	_check(not ObjectLoader.wants_display_blend("mix", true, false, true) and not ObjectLoader.wants_display_blend("mul", false, false, true)
		and not ObjectLoader.wants_display_blend("mix", false, true, true) and not ObjectLoader.wants_display_blend("mix", false, false, false),
		"not with its depth write on (leaves), a multiplying pair, a fading pass or under Compatibility")
	_check(ObjectLoader.DISPLAY_BLEND_MIX.contains("mix(srr_mb_shown(srr_bg), srr_mb_shown(srr_src), srr_a)")
		and ObjectLoader.DISPLAY_BLEND_MIX.contains("FOG = vec4(0.0);")
		and ObjectLoader.DISPLAY_BLEND_ADD.contains("srr_mb_shown(srr_bg) + srr_mb_shown(srr_src) * srr_a")
		and ObjectLoader.DISPLAY_BLEND_ADD.contains("ALPHA = 1.0;"),
		"the mix and the sum are taken on display values, the fog folded into the source first")
