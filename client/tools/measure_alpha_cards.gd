extends SceneTree

## Measurement (round 695): does a real DXT1 card keep its cut-out under this
## renderer?
##
## For each .ddj named, builds the texture through DdjReader exactly as the
## game does, draws it 1:1 on a quad with the client's alpha test (discard
## below ObjectLoader.ALPHA_TEST_REF / 255, nearest, mip 0) over a magenta
## background, reads the frame back and counts the magenta pixels: the
## RENDERED cut fraction. Beside it, the EXPECTED one: the same payload decoded
## on the CPU by the engine (squish, alpha kept), counted the same way. Each
## texture is drawn twice: `dxt1` forces DXT1 as every build before round 695
## did (DdjReader.dxt1_alpha_override = 0), `game` is what the reader does now.
##
##   tools/xwl_run.sh godot --rendering-method forward_plus --rendering-driver vulkan \
##     --path client --script res://tools/measure_alpha_cards.gd -- --pk2=/path/Data.pk2 \
##     --files='prim\mtrl\...\a.ddj;prim\mtrl\...\b.ddj'
## or under xvfb-run + vglrun with --rendering-driver opengl3 (Compatibility).

const SHADER := """shader_type spatial;
render_mode unshaded, cull_disabled;
uniform sampler2D tex : filter_nearest;
uniform float ref = 0.5;
void fragment() {
	vec4 t = textureLod(tex, UV, 0.0);
	if (t.a < ref) {
		discard;
	}
	ALBEDO = t.rgb;
}
"""

var _jobs: Array = []
var _job := -1
var _wait := 0
var _vp: SubViewport
var _quad: MeshInstance3D
var _cam: Camera3D
var _mat: ShaderMaterial
var _failures := 0

func _arg(flag: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return ""

func _initialize() -> void:
	var archive := Pk2Reader.open(_arg("--pk2"))
	if archive == null:
		printerr("ALPHA could not open --pk2")
		quit(2)
		return
	var ref := float(ObjectLoader.ALPHA_TEST_REF) / 255.0
	for f in _arg("--files").split(";", false):
		var bytes := AssetSource.read_bytes(f, archive)
		var parsed := DdjReader.parse(bytes) if not bytes.is_empty() else null
		if parsed == null:
			print("ALPHA %s: not found or not a .ddj" % f)
			_failures += 1
			continue
		var px := parsed.dds.slice(4 + DdjReader.DDS_HEADER_SIZE)
		var cpu := Image.create_from_data(parsed.width, parsed.height, parsed.mip_map_count > 1, Image.FORMAT_DXT1, px) \
			if parsed.four_cc == "DXT1" else DdjReader.to_image(parsed)
		cpu.clear_mipmaps()
		cpu.decompress()
		cpu.convert(Image.FORMAT_RGBA8)
		var cut := 0
		var d := cpu.get_data()
		for i in range(3, d.size(), 4):
			if d[i] < ref * 255.0:
				cut += 1
		var expected := float(cut) / float(cpu.get_width() * cpu.get_height())
		for mode in [["dxt1", 0], ["game", -1]]:
			DdjReader.dxt1_alpha_override = mode[1]
			var img := DdjReader.to_image(parsed)
			_jobs.append({"file": f, "mode": mode[0], "format": img.get_format(), "four_cc": parsed.four_cc,
				"tex": ImageTexture.create_from_image(img), "w": parsed.width, "h": parsed.height, "expected": expected})
	DdjReader.dxt1_alpha_override = -1
	print("ALPHA renderer: %s, adapter %s, msaa %s" % [RendererChoice.running(), RenderingServer.get_video_adapter_name(), _arg("--msaa")])
	_vp = SubViewport.new()
	_vp.own_world_3d = true
	_vp.transparent_bg = false
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	# --msaa=2: draw with 2x MSAA, as the Video tab's Texture Filtering On does
	# under Forward+ (round 694), to see whether it changes the cut.
	if _arg("--msaa") == "2":
		_vp.msaa_3d = Viewport.MSAA_2X
	root.add_child(_vp)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(1, 0, 1)
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var we := WorldEnvironment.new()
	we.environment = env
	_vp.add_child(we)
	_cam = Camera3D.new()
	_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	_cam.keep_aspect = Camera3D.KEEP_HEIGHT
	_cam.position = Vector3(0, 0, 10)
	_cam.current = true
	_vp.add_child(_cam)
	_quad = MeshInstance3D.new()
	_quad.mesh = QuadMesh.new()
	var sh := Shader.new()
	sh.code = SHADER
	_mat = ShaderMaterial.new()
	_mat.shader = sh
	_mat.set_shader_parameter("ref", ref)
	_quad.material_override = _mat
	_vp.add_child(_quad)
	RenderingServer.frame_post_draw.connect(_drawn)
	_next()

func _next() -> void:
	_job += 1
	if _job >= _jobs.size():
		print("ALPHA done, %d failure(s)" % _failures)
		quit(1 if _failures > 0 else 0)
		return
	var j: Dictionary = _jobs[_job]
	_vp.size = Vector2i(j["w"], j["h"])
	(_quad.mesh as QuadMesh).size = Vector2(j["w"], j["h"])
	_cam.size = float(j["h"])
	_mat.set_shader_parameter("tex", j["tex"])
	_wait = 3

func _drawn() -> void:
	if _job >= _jobs.size():
		return
	_wait -= 1
	if _wait > 0:
		return
	var j: Dictionary = _jobs[_job]
	var img := _vp.get_texture().get_image()
	img.convert(Image.FORMAT_RGBA8)
	var d := img.get_data()
	var magenta := 0
	for i in range(0, d.size(), 4):
		if d[i] > 240 and d[i + 1] < 16 and d[i + 2] > 240:
			magenta += 1
	var rendered := float(magenta) / float(img.get_width() * img.get_height())
	var ok := absf(rendered - float(j["expected"])) <= 0.01
	print("ALPHA %-60s %-4s %s format %2d  expected cut %.4f  rendered cut %.4f  %s" % [
		j["file"], j["mode"], j["four_cc"], j["format"], j["expected"], rendered, "MATCH" if ok else "DIFFERS"])
	_next()
