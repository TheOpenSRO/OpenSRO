extends SceneTree

## Round 786: fountains, waterfalls and their splashes. Synthetic bytes and
## synthetic effects only -- no game data. Run headless:
## `godot4 --headless --path client --script res://scripts/world/water_fx_test.gd`
##
## - the MULTITEX / MULTITEXREV reader (ModDataMultiTex::vslot_004, READ) and
##   its per-material dispatch, through a whole mod section;
## - the second texture on a material (ObjectLoader: the object shader's
##   MULTITEX variant, the MTRL mod shader's stage 1) and TEXANI's stage 1;
## - the world's ambient effects (WorldAmbientFx): which hosts register, the
##   two ranges (READ: 480 for `.o2` lists[2], the object range for the rest),
##   the 3 x 3 sectors, the view test, and the effects built and stepped.

var _failures := 0
var _tex: Texture2D

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _near(a: float, b: float, eps: float = 1e-4) -> bool:
	return absf(a - b) <= eps

func _u32(b: PackedByteArray, v: int) -> void:
	var at := b.size()
	b.resize(at + 4)
	b.encode_u32(at, v)

func _f32(b: PackedByteArray, v: float) -> void:
	var at := b.size()
	b.resize(at + 4)
	b.encode_float(at, v)

func _lp(b: PackedByteArray, s: String) -> void:
	_u32(b, s.length())
	b.append_array(s.to_ascii_buffer())

## The IModData header (FUN_00c5c2a0): six words, four bytes.
func _header(b: PackedByteArray, w1: int, material: int) -> void:
	_u32(b, 0)
	_u32(b, w1)
	_u32(b, 0)
	_u32(b, material)
	_u32(b, 0)
	_u32(b, 0)
	b.append_array(PackedByteArray([0, 0, 0, 0]))

func _multitex_body(w1: int, material: int, op: int, texture: String, factor: int) -> PackedByteArray:
	var b := PackedByteArray()
	_header(b, w1, material)
	_u32(b, op)
	_lp(b, texture)
	_u32(b, factor)
	return b

func _texani_body(w1: int, material: int, mode: int, v_rate: float) -> PackedByteArray:
	var b := PackedByteArray()
	_header(b, w1, material)
	for w in [mode, 1, 10, 1, 1]:
		_u32(b, w)
	for i in range(16):
		_f32(b, v_rate if i == 9 else 0.0)
	return b

func _particle_body(efps: Array) -> PackedByteArray:
	var b := PackedByteArray()
	_header(b, 1, 0xFFFFFFFF)
	_u32(b, efps.size())
	for e in efps:
		_u32(b, 1)
		_lp(b, String(e))
		_lp(b, "")
		_f32(b, 0.0)
		_f32(b, 24.0)
		_f32(b, -56.0)
		_u32(b, 0)
		b.append_array(PackedByteArray([0, 0, 0, 0]))
	return b

func _init() -> void:
	_tex = PlaceholderTexture2D.new()
	_test_multitex_reader()
	_test_mod_section()
	_test_multitex_material()
	_test_ranges()
	# The camera and host tests need the tree: after the first frame.
	process_frame.connect(_in_tree, CONNECT_ONE_SHOT)

func _in_tree() -> void:
	_test_view_box()
	_test_registration()
	_test_playback()
	print("water_fx_test: %d failure(s)" % _failures)
	quit(1 if _failures > 0 else 0)

func _test_multitex_reader() -> void:
	var body := _multitex_body(2, 3, 1, "prim\\mtrl\\etc\\water_offset_01.ddj", 0x66000000)
	var cursor := [0]
	_check(BsrReader._skip_mod_body(body, cursor, BsrReader.MOD_MULTITEX) and cursor[0] == body.size(),
		"the MULTITEX skip ends where the body does (%d of %d)" % [cursor[0], body.size()])
	var m := BsrReader._read_multitex(body, 0, 2, BsrReader.MOD_MULTITEX)
	_check(m["w1"] == 2 and m["material"] == 3 and m["set_kind"] == 2, "header: dispatch 2, material 3, the ambient set")
	_check(m["op"] == 1 and m["texture"] == "prim\\mtrl\\etc\\water_offset_01.ddj" and m["factor"] == 0x66000000 and not m["rev"],
		"body: +0x24 op 1, +0x28 the texture, +0x44 the factor (ModDataMultiTex::vslot_004)")
	var rev := BsrReader._read_multitex(_multitex_body(1, 0xFFFFFFFF, 0, "x.ddj", 0x80000000), 0, 2, BsrReader.MOD_MULTITEXREV)
	_check(rev["rev"] and rev["op"] == 0 and rev["factor"] == 0x80000000, "a MULTITEXREV is marked rev, op 0 keeps its factor")
	var obj := BsrReader.ParsedObject.new()
	obj.multitex_mods = [
		{"set_kind": 2, "w1": 2, "material": 3, "op": 1, "texture": "a.ddj", "factor": 0, "rev": false},
		{"set_kind": 0, "w1": 2, "material": 4, "op": 1, "texture": "clip.ddj", "factor": 0, "rev": false},
		{"set_kind": 2, "w1": 1, "material": 0xFFFFFFFF, "op": 0, "texture": "all.ddj", "factor": 0, "rev": false}]
	_check(obj.multitex_for(3)["texture"] == "all.ddj", "the last live mod wins: an every-material (w1 1) one after material 3's")
	_check(obj.multitex_for(4)["texture"] == "all.ddj", "a clip set's mod is not live (set kind 0)")
	obj.multitex_mods.pop_back()
	_check(obj.multitex_for(3)["texture"] == "a.ddj" and obj.multitex_for(5).is_empty(),
		"w1 2 names one material (CRTModMultiTex::vslot_004 compares +0x14)")

## One `ambient` set carrying a particle, a TEXANI and a MULTITEX mod, parsed
## as ResObject::FUN_00c0b740 reads the section.
func _test_mod_section() -> void:
	var b := PackedByteArray()
	# The section sits past the file's 0x44-byte preamble (parse_sound_section
	# refuses an offset inside it).
	b.resize(BsrReader.PREAMBLE_END + 4)
	var at := b.size()
	_u32(b, 1) # list 1: one set
	_u32(b, 2) # kind 2: `ambient`
	_u32(b, 0xFFFFFFFF) # action -1
	_lp(b, "ambient")
	_u32(b, 3)
	_u32(b, BsrReader.MOD_PARTICLE)
	b.append_array(_particle_body(["map\\alex_library_01.efp", "map\\alex_library_01.efp"]))
	_u32(b, BsrReader.MOD_TEXANI)
	b.append_array(_texani_body(1, 0xFFFFFFFF, 1, -0.88))
	_u32(b, BsrReader.MOD_MULTITEX)
	b.append_array(_multitex_body(1, 0xFFFFFFFF, 1, "prim\\mtrl\\etc\\water_offset_01.ddj", 0x66000000))
	_u32(b, 0) # list 2: none
	var section = BsrReader.parse_sound_section(b, at)
	_check(section != null and section["end"] == b.size(), "the section parses to its end")
	if section == null:
		return
	_check((section["multitex_mods"] as Array).size() == 1 and (section["texani_mods"] as Array).size() == 1
		and (section["particle_mods"] as Array).size() == 1, "one MULTITEX, one TEXANI and one particle mod come back")
	var obj := BsrReader.ParsedObject.new()
	obj.multitex_mods = section["multitex_mods"]
	obj.texani_mods = section["texani_mods"]
	obj.particle_mods = section["particle_mods"]
	var t := obj.texani_for(0)
	_check(int(t.get("mode", -1)) == 1 and TexAni.stage_of(t) == 1 and _near(TexAni.rate_rows(t)[1].z, -0.88),
		"its TEXANI is mode 1: stage 1's coordinates, v -0.88 a second (the fountain spouts')")
	_check(obj.multitex_for(0)["texture"] == "prim\\mtrl\\etc\\water_offset_01.ddj", "and its material has the MULTITEX texture")
	var entries := AmbientParticles.ambient_entries(obj.particle_mods)
	_check(entries.size() == 1 and (entries[0] as Array).size() == 2
		and (entries[0][0] as BsrReader.ParticleEntry).offset == Vector3(0, 24, -56), "the ambient set's two effects, at their offsets")

func _test_multitex_material() -> void:
	# The object shader's MULTITEX variant.
	var mat := ShaderMaterial.new()
	mat.shader = ObjectLoader.object_shader("solid")
	var cache := {"k.ddj": {"texture": _tex}}
	ObjectLoader._commit_multitex(mat, {"op": 1, "factor": 0x66000000, "rev": false, "texture_key": "k.ddj"}, cache)
	_check(mat.shader == ObjectLoader.object_shader("solid", false, false, true) and mat.shader.code.contains("#define MULTITEX"),
		"an object-shader material moves to its MULTITEX variant")
	_check(mat.get_shader_parameter("multitex_texture") == _tex and int(mat.get_shader_parameter("multitex_op")) == 1
		and _near(float(mat.get_shader_parameter("multitex_factor")), 0x66 / 255.0),
		"the texture, op 1, and the factor's alpha byte / 255")
	var inc := FileAccess.get_file_as_string("res://scripts/assets/object.gdshaderinc")
	_check(inc.contains("float srr_k = multitex_op == 1 ? srr_t1.a : multitex_factor;") and inc.contains("return mix(srr_current, srr_t1.rgb, srr_k);"),
		"stage 1: BLENDTEXTUREALPHA (op 1) or BLENDFACTORALPHA (op 0) over the stage-0 colour")
	_check(inc.contains("texture(multitex_texture, srr_uv1)"), "stage 1 samples on srr_uv1 (TexAni's stage-1 coordinates)")
	# The MTRL mod shader has the stage built in.
	var mod := ShaderMaterial.new()
	mod.shader = ObjectLoader._mod_shader("back", "add", false)
	ObjectLoader._commit_multitex(mod, {"op": 0, "factor": 0x80000000, "rev": true, "texture_key": "k.ddj"}, cache)
	_check(mod.shader == ObjectLoader._mod_shader("back", "add", false) and int(mod.get_shader_parameter("multitex_op")) == 0
		and bool(mod.get_shader_parameter("multitex_rev")) and _near(float(mod.get_shader_parameter("multitex_factor")), 128.0 / 255.0),
		"an MTRL mod material keeps its shader and takes the uniforms (op 0, REV, factor 128/255)")
	_check(mod.shader.code.contains("if (multitex_op >= 0)") and mod.shader.code.contains("stage = mix(stage, t1.rgb, multitex_op == 1 ? t1.a : multitex_factor);"),
		"the mod shader blends stage 1 over its stage-0 result, before the blend emulation")
	_check(mod.shader.code.contains("multitex_rev ? texture(multitex_texture, UV) : texture(albedo_texture, UV)"),
		"a REV samples the mod's texture on stage 0")
	# Missing texture: nothing changes.
	var bare := ShaderMaterial.new()
	bare.shader = ObjectLoader.object_shader("solid")
	ObjectLoader._commit_multitex(bare, {"op": 1, "factor": 0, "rev": false, "texture_key": "none"}, cache)
	_check(bare.shader == ObjectLoader.object_shader("solid"), "a texture not in the cache leaves the material as it was")
	# The prepare: a known texture is named, not decoded again.
	var plan := {}
	var prepared := {"textures": {}, "missing": []}
	var known := {"prim/mtrl/etc/w.ddj": {"four_cc": "DXT5", "alpha": {}}}
	ObjectLoader._prepare_multitex(null, {"op": 1, "factor": 7, "rev": false, "texture": "prim\\mtrl\\etc\\w.ddj"},
		"prim\\mtrl\\x.bmt", plan, {"prim\\mtrl\\etc\\w.ddj": known["prim/mtrl/etc/w.ddj"]}, prepared)
	_check(plan.has("multitex") and plan["multitex"]["texture_key"] == "prim\\mtrl\\etc\\w.ddj" and plan["multitex"]["factor"] == 7,
		"the prepare names the full path the mod gives (lower-cased key) and keeps op, factor")

func _test_ranges() -> void:
	var far := MapAnimation.OBJECT_RANGE
	var eye := Vector3.ZERO
	var c := Vector3.ZERO
	_check(WorldAmbientFx.in_range(Vector3(0, 0, 2000), 30.0, false, Vector3(0, 0, 2080), eye, far),
		"a lists[1] host 2000 away with radius 30: 1970 < 2020, in range")
	_check(not WorldAmbientFx.in_range(Vector3(0, 0, 2100), 30.0, false, Vector3(0, 0, 2080), eye, far),
		"2100 away: 2070 >= 2020, out (SWorld::FUN_00a38a50, strictly below)")
	_check(WorldAmbientFx.in_range(Vector3(0, 0, 450), 0.0, true, c, eye, far), "a lists[2] host 450 away: within 480")
	_check(not WorldAmbientFx.in_range(Vector3(0, 0, 600), 0.0, true, Vector3(0, 0, 320), eye, far),
		"600 away: out (480, the float at 0xde4f64)")
	_check(not WorldAmbientFx.in_range(Vector3(470, 0, 0), 0.0, true, Vector3(480, 0, 0), eye, far),
		"470 away but its sector two over: not one of the 9 nearest (INFERRED 3 x 3)")
	_check(WorldAmbientFx.in_range(Vector3(470, 0, 0), 0.0, true, Vector3(400, 0, 0), eye, far),
		"the same distance in the neighbouring sector: in range")
	MapAnimation.set_view_distance(1200.0)
	_check(not WorldAmbientFx.in_range(Vector3(0, 0, 1000), 0.0, false, c, eye, MapAnimation.object_range),
		"the view distance option shrinks the far range (1200 - 480 = 720)")
	MapAnimation.set_view_distance(MapAnimation.OBJECT_RANGE_SETTING)

func _test_view_box() -> void:
	var cam := Camera3D.new()
	get_root().add_child(cam)
	cam.global_transform = Transform3D(Basis.IDENTITY, Vector3.ZERO)
	var planes := cam.get_frustum()
	_check(WorldAmbientFx.box_in_view(AABB(Vector3(-5, -5, -100), Vector3(10, 10, 10)), planes), "a box in front is in view")
	_check(not WorldAmbientFx.box_in_view(AABB(Vector3(-5, -5, 100), Vector3(10, 10, 10)), planes), "a box behind is not")
	_check(WorldAmbientFx.box_in_view(AABB(Vector3(-500, -5, -10), Vector3(1000, 10, 20)), planes),
		"a box straddling the view is")
	_check(WorldAmbientFx.box_in_view(AABB(Vector3(0, 0, 999), Vector3.ONE), []), "no planes: everything is")
	cam.free()

## A placed object as ObjectLoader commits one: a root carrying `ambient`
## entries and a mesh, or a compound whose child carries them.
func _host(entries: Array, compound: bool) -> Node3D:
	var root := Node3D.new()
	var carrier := root
	if compound:
		carrier = Node3D.new()
		root.add_child(carrier)
	carrier.set_meta(AmbientParticles.META_ENTRIES, entries)
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(60, 10, 80)
	mi.mesh = box
	carrier.add_child(mi)
	return root

func _entry(efp: String, offset: Vector3) -> BsrReader.ParticleEntry:
	var e := BsrReader.ParticleEntry.new()
	e.mode = 1
	e.efp = efp
	e.offset = offset
	return e

func _test_registration() -> void:
	var container := Node3D.new()
	get_root().add_child(container)
	var wf := WorldAmbientFx.new()
	var a := _host([[_entry("map\\a.efp", Vector3.ZERO), _entry("map\\a.efp", Vector3(0, 10, 0))]], false)
	a.position = Vector3(100, 0, 100)
	container.add_child(a)
	_check(wf.add(a, false) == 1 and wf.size() == 1, "a placed object with an ambient set is one host")
	var h: WorldAmbientFx.Host = wf.hosts()[0]
	_check(h.paths == PackedStringArray(["map\\a.efp"]) and not h.near, "its effect files, once each; lists[1]")
	_check(_near(h.radius, Vector2(30, 40).length()), "its radius: half its mesh bounds' X-Z diagonal (got %f)" % h.radius)
	var cpd := _host([[_entry("map\\b.efp", Vector3.ZERO)]], true)
	container.add_child(cpd)
	_check(wf.add(cpd, true) == 1 and (wf.hosts()[1] as WorldAmbientFx.Host).near, "a compound's child carrying entries is a host; lists[2]")
	var night := _entry("map\\n.efp", Vector3.ZERO)
	night.b51 = 1
	var dark := _host([[night]], false)
	container.add_child(dark)
	_check(wf.add(dark, false) == 0, "a host whose only entry is night-only is not registered (AmbientParticles.shows)")
	var plain := Node3D.new()
	container.add_child(plain)
	_check(wf.add(plain, false) == 0, "an object without ambient entries is not")
	a.free()
	wf.tick(0.016, Vector3.ZERO, [], 0)
	_check(wf.size() == 1, "a freed host leaves at the next decision")
	wf.reset()
	_check(wf.size() == 0 and wf.hosts().is_empty(), "reset drops everything (a zone change)")
	container.free()

## A tiny synthetic effect: one looping plate particle (as
## client_review785_test's).
func _effect(path: String) -> EfpEffect:
	var n := EfpReader.EfpNode.new()
	n.frames = 3
	var ex := EfpReader.EfpCommand.new()
	ex.name = "NormalTimeExtinct"
	n.extinct = ex
	var em := EfpReader.EfpCommand.new()
	em.name = "StaticEmit"
	em.value = {"type": "SEFStaticEmit", "delay": 0, "duration": 1, "interval": 1, "max_live": 1, "per_trigger": 1.0}
	n.emit.append(em)
	var rd := EfpReader.EfpCommand.new()
	rd.name = "RenderPlate"
	n.render = rd
	var vw := EfpReader.EfpCommand.new()
	vw.name = "ViewNone"
	n.view = vw
	n.state = EfpReader.EfpRenderState.new()
	n.state.src_blend = 5
	n.state.dest_blend = 2
	var ref := EfpReader.EfpMeshRef.new()
	ref.textures = PackedStringArray(["t.ddj"])
	n.meshes.append(ref)
	var fx := EfpEffect.from_template(EfpSim.compile(n), func(p): return _tex if p == "t.ddj" else null, func(_p): return null, 5)
	fx.path = path
	return fx

func _test_playback() -> void:
	AmbientParticles.effect_factory = _effect
	# The files count as decoded (WorldAmbientFx waits for the preload).
	for p in ["map\\near.efp", "map\\far.efp", "map\\out.efp"]:
		EfpEffect._templates[p.to_lower()] = EfpSim.Template.new()
	var container := Node3D.new()
	get_root().add_child(container)
	var cam := Camera3D.new()
	get_root().add_child(cam)
	cam.global_transform = Transform3D(Basis.IDENTITY, Vector3(0, 10, 0))
	var wf := WorldAmbientFx.new()
	wf.ambient = AmbientParticles.new()
	var spout := _host([[_entry("map\\near.efp", Vector3(0, 24, 0)), _entry("map\\near.efp", Vector3(56, 24, 0))]], false)
	spout.position = Vector3(0, 0, -300)
	container.add_child(spout)
	var falls := _host([[_entry("map\\far.efp", Vector3.ZERO)]], false)
	falls.position = Vector3(0, 0, -1800)
	container.add_child(falls)
	var lamp := _host([[_entry("map\\out.efp", Vector3.ZERO)]], false)
	lamp.position = Vector3(0, 0, -900)
	container.add_child(lamp)
	wf.add(spout, true)
	wf.add(falls, false)
	wf.add(lamp, true)
	var planes := cam.get_frustum()
	wf.tick(0.016, cam.global_position, planes, 0)
	wf.tick(0.016, cam.global_position, planes, 16)
	var by_path := {}
	for h_v in wf.hosts():
		var h := h_v as WorldAmbientFx.Host
		by_path[h.paths[0]] = h
	var sh: WorldAmbientFx.Host = by_path["map\\near.efp"]
	var fh: WorldAmbientFx.Host = by_path["map\\far.efp"]
	var lh: WorldAmbientFx.Host = by_path["map\\out.efp"]
	_check(sh.on and sh.built and sh.effects.size() == 2, "the lists[2] spout 300 away: in range, its two effects built")
	_check(fh.on and fh.built and fh.effects.size() == 1, "the lists[1] waterfall 1,800 away: in range (2020), built")
	_check(not lh.on and not lh.built, "the lists[2] lamp 900 away: out of range (480), not built")
	var fx := sh.effects[0] as EfpEffect
	_check(fx.loop and fx.process_mode == Node.PROCESS_MODE_DISABLED and fx.get_parent() == spout,
		"an effect loops, follows its object (its child) and is stepped by the manager, not its own _process")
	_check(fx.static_host, "a still object's effects are placed once (static_host)")
	_check(wf.stepping().size() == 3, "the three effects in view step (got %d)" % wf.stepping().size())
	var age0 := fx.sim.age
	for i in range(30):
		wf.tick(0.05, cam.global_position, planes, 32 + 50 * i)
	_check(fx.sim.age > age0, "and they play: the simulation advanced (%d -> %d frames)" % [age0, fx.sim.age])
	# Out of range: hidden and paused. (The far plane past the hosts: a sector
	# the view does not reach keeps its objects' state, READ.)
	cam.far = 20000.0
	var away := Vector3(0, 10, 5000)
	cam.global_position = away
	wf.tick(0.05, away, cam.get_frustum(), 5000)
	_check(not sh.on and not fx.visible and fx.culled and wf.stepping().is_empty(),
		"the camera 5,000 away: every host out of range, hidden, culled and paused")
	var age1 := fx.sim.age
	wf.tick(0.05, away, cam.get_frustum(), 5200)
	_check(fx.sim.age == age1, "a paused effect does not advance")
	# Back in range, but looking away: an object the view does not reach is
	# not visited, so it keeps its state (READ) -- here, off.
	cam.global_transform = Transform3D(Basis(Vector3.UP, PI), Vector3(0, 10, 0))
	wf.tick(0.05, cam.global_position, cam.get_frustum(), 5400)
	_check(not sh.on and wf.stepping().is_empty(),
		"back in range looking away: not visited, so still off; nothing steps")
	# Facing it again: visited, in range, shown and stepping.
	cam.global_transform = Transform3D(Basis.IDENTITY, Vector3(0, 10, 0))
	wf.tick(0.05, cam.global_position, cam.get_frustum(), 5600)
	wf.tick(0.05, cam.global_position, cam.get_frustum(), 5616)
	_check(sh.on and fx.visible and not fx.culled and wf.stepping().has(fx), "facing it again: shown and stepping")
	# Past its warm-up, an effect whose particles are out of the view does
	# not step; during it, it does (WARM_MS).
	var lone := WorldAmbientFx.Host.new()
	var behind := _effect("map\\behind.efp")
	container.add_child(behind)
	behind.global_position = Vector3(0, 10, 300)
	lone.effects = [behind]
	lone.fx_box = WorldAmbientFx.particles_box_of(lone.effects)
	_check(lone.fx_box.has_point(Vector3(0, 10, 300)) or lone.fx_box.position.is_equal_approx(Vector3(0, 10, 300)),
		"an effect with no particle yet: its box is the point it stands at")
	var wf2 := WorldAmbientFx.new()
	wf2._seen = [lone]
	wf2._now_ms = 10000
	lone.warm_until_ms = 9000
	wf2._choose_stepping(cam.get_frustum())
	_check(wf2.stepping().is_empty(), "particles behind the eye, warm-up over: it does not step")
	lone.warm_until_ms = 11000
	wf2._choose_stepping(cam.get_frustum())
	_check(wf2.stepping() == [behind], "within its warm-up it steps whatever the view")
	behind.free()
	# A big object is visited while its own box is in view, wherever its
	# origin stands (the `.o2` lists it in every sector it reaches).
	var big := WorldAmbientFx.Host.new()
	big.box = AABB(Vector3(-2000, 0, -900), Vector3(4000, 50, 800))
	big.view_box = big.box
	_check(WorldAmbientFx.box_in_view(big.view_box, cam.get_frustum()) and not cam.is_position_in_frustum(Vector3(1800, 0, -100)),
		"a 4,000-unit object whose origin is off to the side is still in view by its box")
	AmbientParticles.effect_factory = Callable()
	for p in ["map\\near.efp", "map\\far.efp", "map\\out.efp"]:
		EfpEffect._templates.erase(p.to_lower())
	container.free()
	cam.free()
