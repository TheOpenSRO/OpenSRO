extends SceneTree

## Exercises EfpReader.decode (the v2 typed tree, round 619) against synthetic
## buffers only -- never real game data. Mirrors server/internal/efp's
## tree_test.go. Run headless:
## `godot4 --headless --path client --script res://scripts/efp/efp_tree_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

# ---------------------------------------------------------------- encoder

var b := PackedByteArray()

func u8(v: int) -> void:
	b.append(v & 0xFF)

func u32(v: int) -> void:
	var t := PackedByteArray()
	t.resize(4)
	t.encode_u32(0, v)
	b.append_array(t)

func f32(v: float) -> void:
	var t := PackedByteArray()
	t.resize(4)
	t.encode_float(0, v)
	b.append_array(t)

func text(s: String) -> void:
	var sb := s.to_ascii_buffer()
	u32(sb.size())
	b.append_array(sb)

func vec3(v: Vector3) -> void:
	f32(v.x)
	f32(v.y)
	f32(v.z)

func mat4(base: float) -> void:
	for i in range(16):
		f32(base + i)

func state(cull: int, src: int, dest: int) -> void:
	for v in [cull, src, dest, 2, 0, 4, 2, 0, 4]:
		u32(v)

func command(cmd_name: String, space: int, flags: int, start: float, step: float, end: float) -> void:
	u8(1)
	text(cmd_name)
	u8(space)
	u8(flags)
	f32(start)
	f32(step)
	f32(end)

func meshes() -> void:
	u32(1)
	text("")
	u32(1)
	text("textures\\glow.ddj")

## Writes one of each typed command (13 parameter types); the other three
## (BlendScaleGraph, BlendDiffuseGraph, BSAnimation) are node variables.
func typed_commands() -> void:
	u32(13)
	command("SetPosition", 7, 0, 0, 1, 0); vec3(Vector3(0, 1, 0))
	command("SetRotationMat", 0, 0, 0, 1, 0); mat4(0)
	command("SetShapeRot", 0, 0, 0, 1, 0); f32(0); f32(1); f32(0); f32(1); mat4(5)
	command("SetRotation", 2, 0, 0, 1, 0); vec3(Vector3(1, 2, 3)); mat4(6)
	command("SetConeVel", 2, 0, 0, 1, 0); vec3(Vector3(0, 1, 0)); vec3(Vector3(10, 20, 0))
	command("Attraction", 0, 0, 0, 1, 0); f32(3)
	command("SetGraphScale", 0, 5, 0, 1, 100); u32(2); vec3(Vector3.ONE); vec3(Vector3(2, 2, 2))
	command("SetGraphRandomScale", 0, 9, 0, 1, 1); u32(2)
	command("SetGraphDiffuse", 0, 4, 0, 1, 100); u32(2); u32(0xff102030); u32(0x80ffffff)
	command("SetBANRot", 2, 5, 0, 1, 100); u32(0); u32(1); mat4(2)
	command("SetBANPos", 7, 5, 0, 1, 100); u32(0); u32(1); vec3(Vector3(0, 2, 0))
	command("TextureSlide", 0, 8, 0, 1, 4); vec3(Vector3(1, 4, 0.25)); u32(1); f32(0); f32(0); f32(1); f32(0.25)
	command("Force", 2, 0, 0, 1, 0); vec3(Vector3(0, -9.5, 0))

## The opening u32 is patched to the byte length of name + controllers,
## as retail files carry (EfpNode.head_len).
func node(id: int, node_name: String, full: bool, kids: int) -> void:
	var head_at := b.size()
	u32(0)
	text(node_name)
	if full:
		u32(9)
		text("NormalTimeLife")
		text("StaticEmit"); u32(0); u32(1); u32(1); u32(1); f32(1)
		text("LinkMode"); u32(1); u32(1); u32(1); u32(0)
		text("Program"); typed_commands()
		text("BAN"); u32(1); text("ani\\swing.ban")
		text("ViewMode"); text("ViewBillboard")
		text("Shape"); text("RenderPlate"); state(2, 5, 2); meshes()
		text("ScaleGraph")
		for i in range(3):
			f32(0); f32(1); u32(2); f32(0); f32(8); f32(1); f32(16)
		u32(0); f32(60)
		text("DiffuseGraph")
		f32(0); f32(1); u32(1); f32(0.5); u8(0x80)
		f32(0); f32(1); u32(1); f32(0); u32(0xff00ff00)
	else:
		u32(0)
	b.encode_u32(head_at, b.size() - head_at - 4)
	u32(10) # frames
	if full:
		u32(3)
		text("BlendScaleGraph"); f32(0); f32(1); u32(1); f32(0); vec3(Vector3.ONE)
		text("BlendDiffuseGraph"); f32(0); f32(1); u32(0)
		text("BSAnimation"); u32(1); text("ani\\swing.ban")
	else:
		u32(0)
	u32(0) # list 0x90
	u32(1); command("StaticEmit", 0, 2, 2, 0, 0); u32(0); u32(30); u32(3); u32(10); f32(1)
	u32(0) # list 0xd8
	command("NormalTimeLoop", 0, 0, 0, 0, 0)
	u32(1); command("ProgramUpdate", 0, 0, 0, 1, 0)
	for v in [1, 1, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0]:
		u8(v)
	command("ViewBillboard", 0, 0, 0, 0, 0)
	state(1, 5, 2)
	meshes()
	command("RenderPlate", 0, 0, 0, 0, 0)
	u32(0) # list 0x20c
	if full:
		typed_commands()
	else:
		u32(1); command("SetSpherePos", 1, 0, 0, 1, 0); vec3(Vector3(0.5, 0.5, 0.5))
	u32(kids)
	for i in range(kids):
		node(id + 1 + i, "NONAME", false, 0)

func build(version: String) -> PackedByteArray:
	b = PackedByteArray()
	b.append_array((EfpReader.MAGIC + " " + version).to_ascii_buffer())
	if version == "0012":
		f32(0.5)
	elif version == "0013":
		f32(0.5); u32(1); u32(2); u32(3)
	node(101, "root fx", true, 1)
	return b

# ---------------------------------------------------------------- tests

func _init() -> void:
	for version in ["0010", "0011", "0012", "0013"]:
		var data := build(version)
		var f := EfpReader.decode(data)
		_check(f != null, "%s decodes (%s)" % [version, EfpReader.last_error])
		if f == null:
			continue
		_check(f.trailing == 0, "%s consumes every byte (left %d)" % [version, f.trailing])
		if version == "0013":
			_check(f.header_0012 == 0.5 and f.header_0013[2] == 3, "0013 header fields")
		var n := f.root
		_check(n.head_len_matches() and n.name == "root fx" and n.frames == 10, "%s root head_len/name/frames" % version)
		_check(n.children.size() == 1 and n.children[0].head_len_matches(), "%s child head_len" % version)
		_check(n.controllers.size() == 9, "%s 9 controllers" % version)
		var shape: EfpReader.EfpController = null
		for c in n.controllers:
			if c.key == "Shape":
				shape = c
		_check(shape != null and shape.data["render"] == "RenderPlate" and shape.data["state"].cull == 3,
			"%s Shape controller (cull 2 reads as 3)" % version)
		_check(n.commands.size() == 13, "%s 13 typed commands" % version)
		var types := {}
		for c in n.commands:
			types[c.value["type"]] = true
		for v in n.vars:
			types[v["type"]] = true
		for c in n.emit:
			types[c.value["type"]] = true
		var missing := []
		for t in EfpReader.VALUE_TYPES:
			if not types.has(t):
				missing.append(t)
		_check(missing.is_empty(), "%s all 16 value types decoded (missing %s)" % [version, missing])
		var sp := n.command("SetPosition")
		_check(sp != null and sp.space == 7 and sp.value["value"] == Vector3(0, 1, 0), "%s SetPosition Vector" % version)
		var sr := n.command("SetShapeRot")
		_check(sr != null and sr.value["axis"] == Vector4(0, 1, 0, 1) and sr.value["matrix"].size() == 16
			and sr.value["matrix"][15] == 20.0, "%s AxisVector4 axis + matrix" % version)
		var gd := n.command("SetGraphDiffuse")
		_check(gd != null and gd.value["colors"].size() == 2 and gd.value["colors"][0] == 0xff102030,
			"%s FrameDiffuse colours" % version)
		var gs := n.command("SetGraphScale")
		_check(gs != null and gs.value["frames"][1] == Vector3(2, 2, 2), "%s FrameScale" % version)
		var ts := n.command("TextureSlide")
		_check(ts != null and ts.value["head"] == Vector3(1, 4, 0.25) and ts.value["keys"][0] == Vector4(0, 0, 1, 0.25),
			"%s FrameTextureSlide" % version)
		var em = n.emission()
		_check(em != null and em["max_live"] == 10 and em["interval"] == 3 and em["duration"] == 30, "%s emission" % version)
		_check(n.loops() and not n.never_extinct(), "%s NormalTimeLoop" % version)
		_check(n.view_mode() == "ViewBillboard" and n.render_mode() == "RenderPlate", "%s view/render" % version)
		_check(n.state.src_blend == 5 and n.state.is_additive(), "%s additive blend state" % version)
		_check(n.meshes.size() == 1 and n.meshes[0].textures[0] == "textures\\glow.ddj", "%s meshes" % version)
		_check(n.vars.size() == 3 and n.vars[2]["value"]["names"][0] == "ani\\swing.ban", "%s program vars" % version)
		_check(n.children.size() == 1 and n.children[0].name == "NONAME" and n.children[0].commands.size() == 1,
			"%s child node" % version)
		var seen := [0]
		n.walk(func(_x): seen[0] += 1)
		_check(seen[0] == 2, "%s walk visits 2 nodes" % version)

	# Every proper prefix fails; trailing bytes are counted, not swallowed.
	var full := build("0011")
	var prefix_ok := true
	for cut in range(full.size()):
		if EfpReader.decode(full.slice(0, cut)) != null:
			prefix_ok = false
			print("  prefix of %d bytes decoded" % cut)
			break
	_check(prefix_ok, "every truncation is an error (%d prefixes)" % full.size())
	var padded := full.duplicate()
	padded.append_array(PackedByteArray([0, 0, 0]))
	var fp := EfpReader.decode(padded)
	_check(fp != null and fp.trailing == 3, "trailing bytes reported")

	var v0000 := full.duplicate()
	v0000[8] = 0x30; v0000[9] = 0x30; v0000[10] = 0x30; v0000[11] = 0x30
	_check(EfpReader.decode(v0000) == null, "rejects version 0000")
	_check(EfpReader.decode(PackedByteArray()) == null, "rejects empty")

	# An unknown command would desynchronise the rest; it fails.
	b = PackedByteArray()
	b.append_array((EfpReader.MAGIC + " 0011").to_ascii_buffer())
	u32(1); text("x"); u32(0); u32(10); u32(0)
	u32(1); command("SetWobble", 0, 0, 0, 1, 0)
	_check(EfpReader.decode(b) == null and EfpReader.last_error.contains("unknown command"),
		"unknown command fails (%s)" % EfpReader.last_error)

	# frame_range follows FUN_00ca0f40 (same cases as the Go test).
	var cases := [
		[4, 0.0, 1.0, 100.0, 30, 0, 29, 1.0, true],
		[5, 0.0, 1.0, 100.0, 30, 0, 29, 1.0, true],
		[0, 5.0, 1.0, 24.0, 30, 5, 24, 1.0, true],
		[8, 2.0, 1.0, 4.0, 30, 2, 6, 1.0, true],
		[6, 0.0, 10.0, 100.0, 30, 0, 29, 3.0, true],
		[16, 0.0, 2.0, 3.0, 30, 0, 6, 2.0, true],
		[16, 0.0, 2.0, 0.5, 30, 0, 0, 0.0, false],
		[0, 10.0, 1.0, 5.0, 30, 10, 5, 1.0, false],
	]
	for cs in cases:
		var c := EfpReader.EfpCommand.new()
		c.time_flags = cs[0]; c.start = cs[1]; c.step = cs[2]; c.end = cs[3]
		var fr := c.frame_range(cs[4])
		_check(fr["start"] == cs[5] and fr["end"] == cs[6] and is_equal_approx(fr["step"], cs[7]) and fr["ok"] == cs[8],
			"frame_range flags %d start %s end %s -> %s" % [cs[0], cs[1], cs[3], fr])

	# keys: the number of values a Frame* parameter holds over the range.
	var key_cases := [[5, 0.0, 1.0, 100.0, 30], [8, 2.0, 1.0, 4.0, 5], [6, 0.0, 10.0, 100.0, 10],
		[16, 0.0, 2.0, 3.0, 4], [16, 0.0, 2.0, 0.5, 0]]
	for kc in key_cases:
		var c := EfpReader.EfpCommand.new()
		c.time_flags = kc[0]; c.start = kc[1]; c.step = kc[2]; c.end = kc[3]
		_check(c.frame_range(30)["keys"] == kc[4], "keys flags %d end %s -> %d" % [kc[0], kc[3], kc[4]])

	# End mode 3: the divisor is -100.0 (0x00db9a38): start + int(End/100)*N.
	var m3 := EfpReader.EfpCommand.new()
	m3.time_flags = 12; m3.start = 2.0; m3.step = 1.0; m3.end = 100.0
	var fr3 := m3.frame_range(30)
	_check(fr3["start"] == 2 and fr3["end"] == 29 and fr3["ok"], "end mode 3 End 100 -> 2..29 (%s)" % fr3)
	m3.end = 50.0
	fr3 = m3.frame_range(30)
	_check(fr3["end"] == 2 and fr3["ok"], "end mode 3 End 50 -> 2..2")
	# The client's _ftol: 0x80000000 outside int32; garbage never gives huge counts.
	_check(EfpReader.ftol(3e9) == -2147483648 and EfpReader.ftol(NAN) == -2147483648
		and EfpReader.ftol(-2.9) == -2, "ftol truncates, overflow gives 0x80000000")
	var g := EfpReader.EfpCommand.new()
	g.time_flags = 0; g.start = 0.0; g.step = 1.0; g.end = 1e20
	_check(g.frame_range(30)["keys"] == 0, "garbage End gives 0 keys")
	_check(EfpReader.f32(0.1) != 0.1 and EfpReader.f32(0.5) == 0.5, "f32 rounds to single precision")

	# emit_tick follows FUN_00c84e70 (same trace as Go's TestStaticEmitTick).
	var em2 := {"delay": 2, "duration": 10, "interval": 2, "max_live": 3, "per_trigger": 1.5}
	var acc := 0.0
	var spawns := []
	for age in range(14):
		var tk := EfpReader.emit_tick(em2, age, acc)
		acc = tk["acc"]
		spawns.append(tk["spawn"])
	_check(spawns == [0, 0, 1, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0], "emit_tick spawns %s" % [spawns])
	var tk2 := EfpReader.emit_tick(em2, 6, acc - 1.0)
	_check(tk2["spawn"] == 1 and tk2["acc"] == 3.0, "a death frees one slot under max_live")
	_check(EfpReader.emit_tick(em2, 4, 0.0, 2, 10)["spawn"] == 0, "interval_mul 2 skips age 4")
	var big := {"delay": 0, "duration": 10, "interval": 1, "max_live": 9, "per_trigger": 20.0}
	_check(EfpReader.emit_tick(big, 0, 0.0, 2, 10)["spawn"] == 4, "threshold halves max_live")
	_check(EfpReader.emit_tick(big, 0, 0.0)["spawn"] == 9, "full quality keeps max_live")

	# Graph keys are a map by time: sorted, last write wins.
	b = PackedByteArray()
	f32(0); f32(1); u32(4)
	f32(1.0); u32(0x10); f32(0.0); u32(0x20); f32(0.5); u32(0x30); f32(0.0); u32(0x40)
	var cur := EfpReader._Cur.new(b, 0)
	var dg := EfpReader._diffuse_graph(cur)
	_check(dg["times"] == PackedFloat32Array([0.0, 0.5, 1.0]) and dg["colors"] == PackedInt64Array([0x40, 0x30, 0x10]),
		"diffuse graph keys sorted, duplicate time keeps the last (%s)" % dg)

	# Strings: cut at NUL, high bytes kept as their code points.
	_check(EfpReader.latin1(PackedByteArray([0x61, 0x62, 0, 0x63])) == "ab", "string cut at NUL")
	_check(EfpReader.latin1(PackedByteArray([0xb7, 0xb9])) == String.chr(0xb7) + String.chr(0xb9), "high bytes as Latin-1")

	# The full 8-byte magic, space included.
	var nomagic := build("0011")
	nomagic[7] = 0x5f
	_check(EfpReader.decode(nomagic) == null, "rejects a magic without its space")

	_check(EfpReader.COMMAND_TYPES.size() == 37 and EfpReader.VALUE_TYPES.size() == 16
		and EfpReader.CONTROLLERS.size() == 10, "registry sizes 37 / 16 / 10")
	_check(EfpReader.d3dcolor(0x80ff0000) == Color8(255, 0, 0, 128), "d3dcolor reads 0xAARRGGBB")

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
