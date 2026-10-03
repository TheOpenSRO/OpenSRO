extends SceneTree

## The GDScript half of the cross-reader check: decodes every .efp in the
## player's Particles.pk2 with EfpReader.decode and prints
## "<md5 of the canonical dump> <path>", the same line Go's
## `efpcensus -dump` prints. The canonical text is written field for field
## as server/internal/efp/dump.go writes it; keep the two identical.
## client/tools/efp_dump_diff.sh runs both and diffs them.
##
##   godot4 --headless --path client --script res://tools/efp_dump.gd -- --pk2=<Particles.pk2> [--one=<path>]
##
## --one prints the full dump of one file instead, to find where two dumps part
## (write the path with / so no shell eats the backslashes).

var _one := ""
var _out := PackedStringArray()

func _init() -> void:
	var path := OS.get_environment("OPENSRO_PARTICLES_PK2")
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--pk2="):
			path = a.substr(6)
		elif a.begins_with("--one="):
			_one = a.substr(6)
	var pk2 := Pk2Reader.open(path)
	if pk2 == null:
		print("cannot open %s" % path)
		quit(2)
		return
	_walk(pk2, pk2.read_dir(), "")
	pk2.close()
	quit(0)

func _walk(pk2: Pk2Reader, entries: Array, prefix: String) -> void:
	for e in entries:
		if e.name == "." or e.name == "..":
			continue
		var p: String = e.name if prefix == "" else prefix + "\\" + e.name
		if e.is_dir:
			_walk(pk2, pk2.read_dir_at(e), p)
			continue
		if not p.to_lower().ends_with(".efp"):
			continue
		if _one != "" and p.to_lower().replace("\\", "/") != _one.to_lower().replace("\\", "/"):
			continue
		var f := EfpReader.decode(pk2.read_file(e))
		if f == null:
			continue
		var text := dump(f)
		if _one != "":
			printraw(text)
		else:
			print("%s %s" % [text.md5_text(), p])

# ------------------------------------------------------------ canonical text

var _b := PackedStringArray()

static func _bits(x: float) -> int:
	return PackedFloat32Array([x]).to_byte_array().decode_u32(0)

func _w(s: String) -> void:
	_b.append(s)

func _f(x: float) -> void:
	if is_nan(x):
		_b.append(" nan") # as dump.go: widening to a double quiets signalling NaNs
		return
	_b.append(" %08x" % _bits(x))

func _i(x: int) -> void:
	_b.append(" %d" % x)

func _s(x: String) -> void:
	_b.append(" %d:%s" % [x.length(), x])

func _nl() -> void:
	_b.append("\n")

func _v3(v: Vector3) -> void:
	_f(v.x); _f(v.y); _f(v.z)

func _m4(m: PackedFloat32Array) -> void:
	for x in m:
		_f(x)

func _value(v) -> void:
	if v == null:
		_w(" -")
		return
	var t: String = v["type"]
	_w(" " + t)
	match t:
		"float":
			_f(v["value"])
		"Vector":
			_v3(v["value"])
		"Matrix":
			_m4(v["matrix"])
		"AxisVector4":
			var ax: Vector4 = v["axis"]
			_f(ax.x); _f(ax.y); _f(ax.z); _f(ax.w)
			_m4(v["matrix"])
		"RotVector":
			_v3(v["rot"]); _m4(v["matrix"])
		"AngleVector1":
			_v3(v["a"]); _v3(v["b"])
		"SEFStaticEmit":
			_i(v["delay"]); _i(v["duration"]); _i(v["interval"]); _i(v["max_live"]); _f(v["per_trigger"])
		"FrameScale":
			_i(v["frames"].size())
			for s in v["frames"]:
				_v3(s)
		"FrameDiffuse":
			_i(v["colors"].size())
			for c in v["colors"]:
				_i(c)
		"FrameBANRotation":
			_f(v["head"]); _i(v["matrices"].size())
			for m in v["matrices"]:
				_m4(m)
		"FrameBANPosition":
			_f(v["head"]); _i(v["positions"].size())
			for p in v["positions"]:
				_v3(p)
		"BSAnimation":
			_i(v["names"].size())
			for s in v["names"]:
				_s(s)
		"FrameTextureSlide":
			_v3(v["head"]); _i(v["keys"].size())
			for k in v["keys"]:
				_f(k.x); _f(k.y); _f(k.z); _f(k.w)
		"BlendScaleGraph":
			_f(v["a"]); _f(v["b"]); _i(v["times"].size())
			for i in range(v["times"].size()):
				_f(v["times"][i]); _v3(v["scales"][i])
		"BlendScaleGraphPointer":
			_i(v["value"])
		"BlendDiffuseGraph":
			_diffuse(v)

func _diffuse(v: Dictionary) -> void:
	_f(v["a"]); _f(v["b"]); _i(v["times"].size())
	for i in range(v["times"].size()):
		_f(v["times"][i]); _i(v["colors"][i])

func _command(tag: String, c: EfpReader.EfpCommand) -> void:
	_w(tag)
	if c == null:
		_w(" -"); _nl()
		return
	_s(c.name); _i(c.space); _i(c.time_flags); _f(c.start); _f(c.step); _f(c.end)
	# the range over the node's frames, as dump.go, so the timing arithmetic
	# is compared too
	var fr := c.frame_range(_frames)
	_w(" r%d..%d" % [fr["start"], fr["end"]]); _f(fr["step"])
	_w(" %s k%d" % ["true" if fr["ok"] else "false", fr["keys"]])
	_value(c.value)
	_nl()

func _list(tag: String, cs: Array) -> void:
	_w("%s %d" % [tag, cs.size()]); _nl()
	for c in cs:
		_command("c", c)

func _state(s: EfpReader.EfpRenderState) -> void:
	_w("R")
	for x in [s.cull, s.src_blend, s.dest_blend, s.color_arg1, s.color_arg2,
			s.color_op, s.alpha_arg1, s.alpha_arg2, s.alpha_op]:
		_i(x)
	_nl()

func _meshes(ms: Array) -> void:
	_w("M %d" % ms.size()); _nl()
	for m in ms:
		_w("m"); _s(m.mesh); _i(m.textures.size())
		for t in m.textures:
			_s(t)
		_nl()

func _key_graph(g: Dictionary, is_byte: bool) -> void:
	_f(g["a"]); _f(g["b"]); _i(g["times"].size())
	for i in range(g["times"].size()):
		_f(g["times"][i])
		if is_byte:
			_i(int(g["values"][i]))
		else:
			_f(g["values"][i])

func _controller(c: EfpReader.EfpController) -> void:
	_w("C"); _s(c.key)
	match c.key:
		"StaticEmit":
			_value(c.data["emit"])
		"LinkMode":
			for x in c.data["link"]:
				_i(x)
		"BAN":
			_i(c.data["names"].size())
			for s in c.data["names"]:
				_s(s)
		"ViewMode":
			_s(c.data["view"])
		"Shape":
			_s(c.data["render"]); _nl()
			_state(c.data["state"])
			_meshes(c.data["meshes"])
			return
		"ScaleGraph":
			for g in c.data["axes"]:
				_key_graph(g, false)
			_i(c.data["tail1"]); _f(c.data["tail2"])
		"DiffuseGraph":
			_key_graph(c.data["alpha"], true)
			_diffuse(c.data["color"])
		"Program":
			_nl()
			_list("P", c.data["commands"])
			return
	_nl()

var _frames := 0

func _node(n: EfpReader.EfpNode) -> void:
	_frames = n.frames
	_w("N %d" % n.head_len); _s(n.name); _w(" %d" % n.controllers.size()); _nl()
	for c in n.controllers:
		_controller(c)
	_w("B %d %d" % [n.frames, n.vars.size()]); _nl()
	for v in n.vars:
		_w("A"); _s(v["type"]); _value(v["value"]); _nl()
	_list("L90", n.list_90)
	_list("Lb4", n.emit)
	_list("Ld8", n.list_d8)
	_command("X", n.extinct)
	_list("L130", n.update)
	var f := n.flags
	_w("F %d %d %d %d %d %d %d %d" % [f["b0"], f["b1"], f["u2"], f["u3"], f["u4"], f["b5"], f["u6"], f["b7"]]); _nl()
	_command("V", n.view)
	_state(n.state)
	_meshes(n.meshes)
	_command("D", n.render)
	_list("L20c", n.list_20c)
	_list("L234", n.commands)
	_w("K %d" % n.children.size()); _nl()
	for k in n.children:
		_node(k)

func dump(f: EfpReader.EfpFile) -> String:
	_b = PackedStringArray()
	_w("V"); _s(f.version); _f(f.header_0012)
	for h in f.header_0013:
		_i(h)
	_i(f.trailing); _nl()
	_node(f.root)
	return "".join(_b)
