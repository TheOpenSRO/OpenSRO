extends SceneTree

## ShaderColour (round 693): the client's own shaders sample raw and decode
## their output only where it is linear (Forward+), and the StandardMaterial3Ds
## that multiply by a vertex colour mark it sRGB -- so the colour arithmetic
## Compatibility was measured with is the arithmetic under both renderers.
## Headless: the shader CODE and material flags are checked here; the
## rendered result is round 693's A/B on the box (docs/WORLD_ISSUES.md).
##
## `godot4 --headless --path client --script res://scripts/assets/shader_colour_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	_decode_curve()
	_gl_semantics_shaders()
	_vertex_colour_materials()
	_sky()
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES %d" % _failures)
	quit(1 if _failures > 0 else 0)

## The decode in DECODE_FN is Godot's own sRGB curve (Color.srgb_to_linear).
func _decode_curve() -> void:
	_check(ShaderColour.DECODE_FN.contains("vec3 srr_srgb_to_linear(vec3 srr_v)"), "DECODE_FN defines srr_srgb_to_linear")
	var worst := 0.0
	for i in 256:
		var v := i / 255.0
		var ours := v / 12.92 if v < 0.04045 else pow((v + 0.055) / 1.055, 2.4)
		worst = maxf(worst, absf(ours - Color(v, v, v).srgb_to_linear().r))
	_check(worst < 1e-5, "its curve is Godot's srgb_to_linear over every byte (worst %.2e)" % worst)
	_check(ShaderColour.DECODE_FN.contains("vec4 srr_color(vec4 srr_v, bool srr_output_is_srgb)") and not ShaderColour.DECODE_FN.contains("OUTPUT_IS_SRGB"), "srr_color takes OUTPUT_IS_SRGB from its caller (a user function cannot read it)")
	for line in [ShaderColour.DECODE_ALBEDO, ShaderColour.DECODE_EMISSION, ShaderColour.DECODE_COLOR]:
		_check(line.begins_with("if (!OUTPUT_IS_SRGB)"), "'%s' decodes only where the output is linear" % line)

## A shader written for the GL rule: no source_color, the decode at the end.
func _gl_rule(name: String, code: String, decodes: Array) -> void:
	_check(code != "", "%s: has code" % name)
	# It parses: Godot's shader language lists a shader's uniforms only when
	# the code compiles (a built-in read where it is not allowed lists none --
	# OUTPUT_IS_SRGB inside a user function did exactly that, round 693).
	var sh := Shader.new()
	sh.code = code
	_check(sh.get_shader_uniform_list().size() > 0, "%s: parses (%d uniforms)" % [name, sh.get_shader_uniform_list().size()])
	_check(not _uniform_hinted(code), "%s: samples raw (no source_color uniform)" % name)
	for d in decodes:
		_check(code.contains(d), "%s: carries %s" % [name, d])

func _gl_semantics_shaders() -> void:
	for blend in ["opaque", "mix", "add"]:
		for fade in [false, true]:
			var code := ObjectLoader._mod_shader("back", blend, blend != "opaque", fade).code
			_gl_rule("the mod shader (%s%s)" % [blend, ", fade" if fade else ""], code,
				[ShaderColour.DECODE_FN, ShaderColour.DECODE_ALBEDO, ShaderColour.DECODE_EMISSION])
			# The decode comes after the stage result is written.
			_check(code.find(ShaderColour.DECODE_ALBEDO) > code.find("EMISSION = unlit;"), "  ... after ALBEDO and EMISSION are written")
			_check(code.contains("srr_color(albedo, OUTPUT_IS_SRGB)") and not code.contains("* albedo.rgb"), "  ... and reads its Color parameter as stored (srr_color)")
			_check(code.find("vec4 srr_color(") >= 0 and code.find("vec4 srr_color(") < code.find("Split carg("), "  ... with the helpers defined before they are used")
	for cls in ["mix", "add", "add_one", "darken"]:
		_gl_rule("the particle shader (%s)" % cls, EfpEffect._shader(cls, false).code, [ShaderColour.DECODE_FN, ShaderColour.DECODE_ALBEDO])
	var portrait := PlayerPortrait.new()
	for blend in [false, true]:
		var code := portrait._shader("cull_back", blend).code
		_gl_rule("the portrait shader (blend %s)" % blend, code, [ShaderColour.DECODE_FN, ShaderColour.DECODE_ALBEDO])
		_check(code.find(ShaderColour.DECODE_ALBEDO) > code.find(CharSelectStage.PORTRAIT_ALBEDO), "  ... after the line the select screen's tone-mapping undo replaces")
		_check(code.contains("srr_color(material_color, OUTPUT_IS_SRGB)") and code.find("vec4 srr_color(") < code.find("void vertex()"), "  ... reads material_color (a Color) as stored, helpers before vertex()")
		# The select screen's rewrite keeps the decode after its undo.
		var mat := ShaderMaterial.new()
		var sh := Shader.new()
		sh.code = code
		mat.shader = sh
		var env := Environment.new()
		env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
		CharSelectStage._undo_tonemap(mat, env)
		var undone := mat.shader.code
		_check(undone.contains("ALBEDO = undo_tonemap(") and undone.find(ShaderColour.DECODE_ALBEDO) > undone.find("ALBEDO = undo_tonemap("),
			"  ... and the select screen's undo is decoded after it, where the output is linear")
	portrait.free()
	for path in ["res://scripts/assets/cloud_dome.gdshader", "res://scripts/mapm/water_reflection.gdshader"]:
		var text := FileAccess.get_file_as_string(path)
		_check(not _uniform_hinted(text), "%s samples raw" % path.get_file())
		_check((load(path) as Shader).get_shader_uniform_list().size() > 0, "%s parses" % path.get_file())
		_check(text.contains("if (!OUTPUT_IS_SRGB) {") and text.find("if (!OUTPUT_IS_SRGB) {") > text.find("ALBEDO = "),
			"%s decodes its ALBEDO where the output is linear" % path.get_file())
	for unshaded in [false, true]:
		for blend in [false, true]:
			var code := WaterReflection.terrain_clip_code(unshaded, blend)
			var csh := Shader.new()
			csh.code = code
			_check(csh.get_shader_uniform_list().size() > 0, "the mirror terrain (unshaded %s, blend %s) parses" % [unshaded, blend])
			_check(code.contains(ShaderColour.DECODE_FN) and code.contains(ShaderColour.DECODE_COLOR),
				"the mirror terrain (unshaded %s, blend %s) decodes its vertex colour as the terrain does" % [unshaded, blend])

## Whether any `uniform` line carries the source_color hint (comments may
## name it).
static func _uniform_hinted(code: String) -> bool:
	for line in code.split("\n"):
		if line.strip_edges().begins_with("uniform") and line.contains("source_color"):
			return true
	return false

## The sky (GammaSkyMaterial): ProceduralSkyMaterial's gradient with its
## colours passed as Vector3 (no renderer converts those) and the decode
## chosen by the renderer running.
func _sky() -> void:
	var m := GammaSkyMaterial.new()
	_check(m.shader != null and m.shader.get_shader_uniform_list().size() >= 9, "the gamma sky parses (%d uniforms)" % (m.shader.get_shader_uniform_list().size() if m.shader != null else -1))
	m.sky_top_color = Color(0.2, 0.4, 0.6)
	var v = m.get_shader_parameter("sky_top_color")
	_check(v is Vector3 and (v as Vector3).is_equal_approx(Vector3(0.2, 0.4, 0.6)), "a sky colour reaches the shader as a Vector3, as stored (%s)" % str(v))
	_check(m.get_shader_parameter("decode_out") == (RendererChoice.running() == RendererChoice.FORWARD_PLUS), "decode_out follows the renderer running")
	var code := m.shader.code
	_check(code.contains("decode_out ? enc(LIGHT0_COLOR)") and code.contains("COLOR = dec(COLOR)"), "the sun's colour is re-encoded and the result decoded under Forward+")
	var w3d := FileAccess.get_file_as_string("res://scripts/World3D.gd")
	_check(w3d.contains("GammaSkyMaterial.new()") and not w3d.contains("ProceduralSkyMaterial.new()"), "World3D draws its sky with GammaSkyMaterial")
	_check(w3d.contains("env.fog_sky_affect = 0.0"), "World3D keeps the fog off the sky, as Compatibility does")

func _vertex_colour_materials() -> void:
	for blend in [false, true]:
		var m := MapmTerrainBuilder._surface_material({"texture_key": -1, "unshaded": true, "blend": blend, "base": not blend}, {}, null)
		_check(m.vertex_color_use_as_albedo and m.vertex_color_is_srgb, "a terrain pass (blend %s) marks its vertex colour sRGB" % blend)
	var w := MapmWater.water_material(null, Color.WHITE)
	_check(w.vertex_color_use_as_albedo and w.vertex_color_is_srgb, "the water marks its vertex colour sRGB")
