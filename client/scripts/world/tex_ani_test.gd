extends SceneTree

## Round 722: the TEXANI reader, its two steps (the matrix rates and the
## frame grid, as READ from CRTModTexAni's asm), the per-material dispatch,
## the shaders' coordinate line and the material binding. Synthetic bytes
## only -- no game data. Run headless:
## `godot4 --headless --path client --script res://scripts/world/tex_ani_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _near(a: float, b: float, eps: float = 1e-5) -> bool:
	return absf(a - b) <= eps

func _u32(b: PackedByteArray, v: int) -> void:
	var at := b.size()
	b.resize(at + 4)
	b.encode_u32(at, v)

func _f32(b: PackedByteArray, v: float) -> void:
	var at := b.size()
	b.resize(at + 4)
	b.encode_float(at, v)

## A TEXANI body as ModDataTexAni::vslot_004 reads it: the IModData header
## (six words, four bytes), five words, 64 bytes.
func _texani_body(w1: int, material: int, start: int, last: int, flags: int, words: Array, rates: Array) -> PackedByteArray:
	var b := PackedByteArray()
	_u32(b, 0x3f000000)
	_u32(b, w1)
	_u32(b, 784)
	_u32(b, material)
	_u32(b, 0)
	_u32(b, 0)
	b.append(start)
	b.append(last)
	b.append(flags)
	b.append(0)
	for w in words:
		_u32(b, w)
	for i in range(16):
		_f32(b, float(rates[i]) if i < rates.size() else 0.0)
	return b

func _init() -> void:
	_test_reader()
	_test_dispatch()
	_test_rates()
	_test_grid()
	_test_shaders()
	_test_bind()
	print("tex_ani_test: %d failure(s)" % _failures)
	quit(1 if _failures > 0 else 0)

func _test_reader() -> void:
	var rates := []
	rates.resize(16)
	rates.fill(0.0)
	rates[9] = 0.48
	var body := _texani_body(2, 3, 1, 6, 1, [0, 1, 10, 2, 4], rates)
	var cursor := [0]
	_check(BsrReader._skip_mod_body(body, cursor, BsrReader.MOD_TEXANI) and cursor[0] == body.size(),
		"the TEXANI skip ends where the body does (%d of %d)" % [cursor[0], body.size()])
	var t := BsrReader._read_texani(body, 0, 2)
	_check(t["w1"] == 2 and t["material"] == 3 and t["start"] == 1 and t["end"] == 6 and t["flags"] == 1,
		"header: dispatch, material, first and last frame, flags")
	_check(t["mode"] == 0 and t["method"] == 1 and t["fps"] == 10 and t["rows"] == 2 and t["cols"] == 4,
		"the five words: mode, method, fps, rows, columns")
	_check(_near((t["rates"] as PackedFloat32Array)[9], 0.48), "the rates: data +0x5c (index 9) 0.48")

func _test_dispatch() -> void:
	var obj := BsrReader.ParsedObject.new()
	obj.texani_mods = [
		{"set_kind": 2, "w1": 2, "material": 3, "method": 1},
		{"set_kind": 0, "w1": 2, "material": 4, "method": 1},
		{"set_kind": 2, "w1": 1, "material": 0xFFFFFFFF, "method": 0},
	]
	_check(obj.texani_for(3)["method"] == 0, "material 3: the per-object mod listed after it wins (last one)")
	_check(obj.texani_for(4)["method"] == 0, "material 4: a set that plays with a clip is not taken; the per-object one is")
	var only := BsrReader.ParsedObject.new()
	only.texani_mods = [{"set_kind": 2, "w1": 2, "material": 3, "method": 1}]
	_check(only.texani_for(3).size() > 0 and only.texani_for(2).is_empty(), "word 1 of 2 names one material")

func _test_rates() -> void:
	# Hotan's portal (the census): v grows by 0.48 a second, nothing else.
	var r := PackedFloat32Array()
	r.resize(16)
	r[9] = 0.48
	var t := TexAni.create({"method": TexAni.METHOD_RATES, "rates": r})
	t.step(1000.0)
	var rows := t.rows()
	_check(_near(rows[0].x, 1.0) and _near(rows[0].y, 0.0) and _near(rows[0].z, 0.0), "u row unchanged (1, 0, 0)")
	_check(_near(rows[1].x, 0.0) and _near(rows[1].y, 1.0) and _near(rows[1].z, 0.48), "v row: m21 0.48 after one second")
	t.step(500.0)
	_check(_near(t.rows()[1].z, 0.72), "and 0.72 after another half second (nothing wraps)")
	# Constantinople's fountain: the 2x2 part grows too.
	var f := PackedFloat32Array()
	f.resize(16)
	f[0] = 0.02
	f[1] = 0.03
	f[4] = -0.02
	f[5] = 0.03
	var g := TexAni.create({"method": TexAni.METHOD_RATES, "rates": f})
	g.step(10000.0)
	var gr := g.rows()
	_check(_near(gr[0].x, 1.2) and _near(gr[0].y, -0.2) and _near(gr[1].x, 0.3) and _near(gr[1].y, 1.3),
		"m00 += 0.02 t, m10 += -0.02 t (u row), m01 += 0.03 t, m11 += 0.03 t (v row) after 10 s")

func _grid(start: int, last: int, flags: int, fps: int, rows: int, cols: int) -> TexAni:
	return TexAni.create({"method": TexAni.METHOD_GRID, "start": start, "end": last, "flags": flags,
		"fps": fps, "rows": rows, "cols": cols})

func _test_grid() -> void:
	# fps 10: a 100 ms period; 350 ms is three frames and 50 kept.
	var t := _grid(0, 7, TexAni.FLAG_LOOP, 10, 2, 4)
	t.step_grid(350)
	_check(t.frame == 3 and t.acc_ms == 50, "350 ms at 10 fps: frame 3, 50 ms kept (got %d, %d)" % [t.frame, t.acc_ms])
	var rows := t.rows()
	_check(_near(rows[0].z, 0.75) and _near(rows[1].z, 0.0), "frame 3 of a 2 x 4 grid: offset (3 % 4 / 4, 3 / 4 / 2) = (0.75, 0)")
	t.step_grid(250)
	_check(t.frame == 6 and _near(t.rows()[0].z, 0.5) and _near(t.rows()[1].z, 0.5), "frame 6: (0.5, 0.5)")
	t.step_grid(300)
	# 6 + 3 = 9 is past 7: + (0 - 7 - 1) = 1.
	_check(t.frame == 1 and t.running, "looping: frame 9 wraps to 1 (got %d)" % t.frame)
	var once := _grid(0, 3, 0, 10, 1, 4)
	once.step_grid(500)
	_check(once.frame == 3 and not once.running, "no loop: stops at the last frame (got %d)" % once.frame)
	once.step_grid(500)
	_check(once.frame == 3, "and stays")
	var same := _grid(2, 2, TexAni.FLAG_LOOP, 10, 1, 4)
	same.step_grid(200)
	_check(not same.running and same.frame == 2, "a first frame equal to the last stops at once")
	var pp := _grid(0, 3, TexAni.FLAG_PINGPONG, 10, 1, 4)
	pp.step_grid(500)
	_check(pp.frame == 1 and pp.direction == -1, "ping-pong: 5 frames from 0 reflect at 3 to 1, heading back (got %d, %d)" % [pp.frame, pp.direction])
	pp.step_grid(300)
	_check(pp.frame == 0 and not pp.running, "without the loop bit it stops at the first frame on the way back (got %d)" % pp.frame)
	var ppl := _grid(0, 3, TexAni.FLAG_PINGPONG | TexAni.FLAG_LOOP, 10, 1, 4)
	ppl.step_grid(500)
	ppl.step_grid(300)
	_check(ppl.frame == 2 and ppl.direction == 1 and ppl.running, "with it, it reflects again at 0 (got %d, %d)" % [ppl.frame, ppl.direction])
	var back := _grid(5, 2, TexAni.FLAG_LOOP, 10, 1, 8)
	_check(back.direction == -1 and back.frame == 5, "a first frame after the last runs backwards (vslot_007)")
	var slow := _grid(0, 7, TexAni.FLAG_LOOP, 10, 1, 8)
	slow.step(40.4)
	slow.step(40.4)
	slow.step(40.4)
	_check(slow.frame == 1, "fractional milliseconds gather into whole ones (121 ms: one frame, got %d)" % slow.frame)

func _test_shaders() -> void:
	var inc := FileAccess.get_file_as_string("res://scripts/assets/object.gdshaderinc")
	_check(inc.contains("uniform vec3 texani_u") and inc.contains(TexAni.SHADER_LINE),
		"object.gdshaderinc declares the two rows and applies them")
	var mod := ObjectLoader._mod_shader("back", "mix", false)
	_check(mod.code.contains("uniform vec3 texani_u") and mod.code.contains(TexAni.SHADER_LINE),
		"the MTRL mod shader does too")

func _test_bind() -> void:
	var mat := ShaderMaterial.new()
	mat.shader = ObjectLoader.object_shader("solid")
	var r := PackedFloat32Array()
	r.resize(16)
	r[8] = 0.5
	var before := TexAni.live_count()
	TexAni.bind(mat, {"method": TexAni.METHOD_RATES, "rates": r})
	_check(TexAni.live_count() == before + 1, "bind registers the material")
	TexAni.tick(2000.0)
	var u: Vector3 = mat.get_shader_parameter("texani_u")
	_check(u != null and _near(u.z, 1.0), "tick: m20 grew by 0.5 a second for 2 s (got %s)" % str(u))
	mat = null
	TexAni.tick(16.0)
	_check(TexAni.live_count() == before, "a freed material leaves on the next tick")
