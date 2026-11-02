extends SceneTree

## ObjectLight (round 706): objects and characters lit by the original's own
## object vertex shader -- oD0 = saturate(object x La + max(0, N.L) x
## material x Ld), pixel = saturate(2 x texture x oD0), in display values --
## with the READ light (channel 3 clamped; channel 2 clamped x 0.8 / 0.6 by
## the Bloom row; to-light (0.707, 0.707, 0)), the layer's SECOND colour as
## the material, 0.6 as a placed object's colour and the shadow tile / 384 as
## a character's. Headless: the arithmetic, the shader code and the
## materials; the rendered result is the round's measurement on the box.
##
## `godot4 --headless --path client --script res://scripts/assets/object_light_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	_constants()
	_light()
	_shade()
	_character()
	_tonemap_undo()
	_shader_text()
	_materials()
	_mod_shader()
	_portrait()
	_character_light()
	_night_lit()
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES %d" % _failures)
	quit(1 if _failures > 0 else 0)

func _near(a: float, b: float, eps: float = 1e-4) -> bool:
	return absf(a - b) <= eps

func _constants() -> void:
	_check(_near(ObjectLight.OBJECT_COLOR, 0.6), "a placed object's colour is CCompoundObj's 0.6 (0xd86fc0)")
	_check(_near(ObjectLight.DIFFUSE_SCALE, 0.6) and _near(ObjectLight.DIFFUSE_SCALE_BLOOM, 0.8), "diffuse x 0.6, x 0.8 with the bloom target (0xde4c64)")
	_check(_near(ObjectLight.SHADOW_DIVISOR, 384.0), "the shadow byte / 384 (0xde4c48)")
	_check(ObjectLight.TO_LIGHT_FILE.is_equal_approx(-Vector3(-1, -1, 0).normalized()), "to-light = -normalize(-1, -1, 0) (DAT_01109510 x -1)")
	_check(ObjectLight.to_light_godot().is_equal_approx(Vector3(0.70710678, 0.70710678, 0.0)), "the mirror leaves it as is (no z)")
	_check(_near(ObjectLight.MODULATE_SCALE, 2.0), "stage 0 MODULATE2X")

func _light() -> void:
	var c := ObjectLight.light_colors(Color(0.7255, 0.7214, 0.7165), Color(0.6784, 0.6745, 0.6627), true)
	_check((c["ambient"] as Vector3).is_equal_approx(Vector3(0.6784, 0.6745, 0.6627)), "ambient = channel 3")
	_check((c["diffuse"] as Vector3).is_equal_approx(Vector3(0.7255, 0.7214, 0.7165) * 0.8), "diffuse = channel 2 x 0.8 with bloom")
	var off := ObjectLight.light_colors(Color(1.5, -0.2, 0.5), Color(2, 0.5, -1), false)
	_check((off["diffuse"] as Vector3).is_equal_approx(Vector3(0.6, 0.0, 0.3)), "channel 2 clamped to [0, 1], x 0.6 without bloom")
	_check((off["ambient"] as Vector3).is_equal_approx(Vector3(1.0, 0.5, 0.0)), "channel 3 clamped to [0, 1]")

func _shade() -> void:
	# A wall facing away from the light: the ambient term alone.
	_check(_near(ObjectLight.shade(0.4, 0.59, 0.6, 0.678, 0.58, -0.3), 2.0 * 0.4 * 0.6 * 0.678), "N.L <= 0: 2 x tex x 0.6 x La")
	# The dragon's layer: second colour 0.59 (red), lit at N.L 0.7.
	var od0 := clampf(0.6 * 0.678 + 0.7 * 0.59 * 0.58, 0.0, 1.0)
	_check(_near(ObjectLight.shade(0.47, 0.59, 0.6, 0.678, 0.58, 0.7), clampf(2.0 * 0.47 * od0, 0.0, 1.0)), "lit: 2 x tex x (0.6 La + N.L x material x Ld)")
	_check(_near(ObjectLight.shade(0.9, 1.0, 1.0, 1.0, 1.0, 1.0), 1.0), "the vertex colour and the stage both saturate")

func _character() -> void:
	_check(_near(ObjectLight.character_color(255, true), 255.0 / 384.0), "a lit tile: 255 / 384")
	_check(_near(ObjectLight.character_color(153, true), 153.0 / 384.0), "the darkest tile: 153 / 384")
	_check(_near(ObjectLight.character_color(200, false), 0.6), "on an object's navmesh: 0.6")
	_check(_near(ObjectLight.character_color(-1, true), 1.0), "no region: 1.0")
	_check(_near(ObjectLight.character_color(153, true, true), 1.0), "a dungeon region: 1.0")
	var m := PackedByteArray()
	m.resize(96 * 96)
	m[5 * 96 + 7] = 229
	_check(ObjectLight.shadow_byte_at(m, 7 * 20 + 3, 5 * 20 + 19) == 229, "the byte at column x / 20, row z / 20 (96 wide)")
	_check(ObjectLight.shadow_byte_at(m, -1, 5) == -1 and ObjectLight.shadow_byte_at(m, 1921, 5) == -1, "off the map: -1")
	_check(ObjectLight.shadow_byte_at(PackedByteArray(), 5, 5) == -1, "no map: -1")

## The shaders' filmic inverse is WorldFog's (Godot 4.2's curve): showing
## the written value through the tone map gives the display value back.
func _tonemap_undo() -> void:
	var worst := 0.0
	for i in range(1, 250):
		var v := i / 255.0
		var lin := WorldFog.srgb_to_linear(v)
		var written := WorldFog.filmic_inverse(lin, 1.0)
		var shown := WorldFog.linear_to_srgb(WorldFog.filmic(written, 1.0))
		worst = maxf(worst, absf(shown - v))
	_check(worst < 1e-3, "filmic(filmic_inverse(x)) = x over the display range (worst %.2e)" % worst)
	_check(ObjectLight.SHADER_FN.contains("0.88 * x + 0.1 * 0.6") and ObjectLight.SHADER_FN.contains("0.2 * (0.3 * u - 0.01)"), "the GLSL carries WorldFog's curve constants")
	var env := Environment.new()
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var t := ObjectLight.tonemap_vector(env)
	_check(_near(t.z, 1.0) and _near(t.x, env.tonemap_exposure) and _near(t.y, env.tonemap_white), "Filmic: z 1, exposure and white passed")
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	_check(_near(ObjectLight.tonemap_vector(env).z, 0.0), "Linear: nothing to invert but the exposure")
	ObjectLight.qa_undo = 0
	_check(_near(ObjectLight.tonemap_vector(env).w, 0.0), "objtm=0 turns the undo off")
	ObjectLight.qa_undo = -1

func _shader_text() -> void:
	var inc := FileAccess.get_file_as_string("res://scripts/assets/object.gdshaderinc")
	_check(inc.contains(ObjectLight.SHADER_FN), "the include carries ObjectLight.SHADER_FN verbatim")
	_check(inc.contains(ShaderColour.DECODE_FN), "... and ShaderColour.DECODE_FN")
	_check(inc.contains(ObjectLight.OD0_LINE), "... and computes oD0 per vertex (OD0_LINE)")
	_check(inc.contains("ALBEDO = srr_obj_present(clamp((SRR_NIGHT_LIT ? 1.0 : 2.0) * tex.rgb * srr_od0"),
		"... MODULATE2X of the texture and oD0 (MODULATE for a night-lit layer at night), the tone map undone")
	_check(not inc.contains(": source_color") and not inc.contains(", source_color"), "... raw samples (ShaderColour's rule)")
	for kind in ["solid", "one", "two"]:
		for fade in [false, true]:
			var s := ObjectLoader.object_shader(kind, fade)
			var what := "object shader %s%s" % [kind, " (fade)" if fade else ""]
			_check(s.code.contains("unshaded") and s.code.contains("cull_disabled" if kind == "two" else "cull_back"), "%s: unshaded, its cull" % what)
			_check(s.code.contains("blend_mix") == fade and s.code.contains("APPEAR_FADE") == fade, "%s: blended only as a fade twin" % what)
			var names := []
			for u in s.get_shader_uniform_list():
				names.append(u["name"])
			_check(names.has("albedo") and names.has("albedo_texture") and names.has("object_tint"), "%s parses (uniforms %s)" % [what, str(names)])
			if not fade:
				_check(ObjectLoader.appear_fade_shader(s) == ObjectLoader.object_shader(kind, true), "%s: its fade twin" % what)
	_check(ObjectLoader.OBJECT_SHADER == ObjectLoader.object_shader("solid") and ObjectLoader.FOLIAGE_SHADER == ObjectLoader.object_shader("two"), "one shader per kind")
	# Round 706 review (H1, MEASURED): an instance uniform on every placed
	# mesh overflowed Godot's instance buffer at the Jangan spawn ("Too many
	# instances using shader instance variables", 1,093 times a boot) and
	# drew the losers with no ambient term. No object shader may declare one.
	_check(inc.contains("\nuniform vec3 object_color = vec3(0.6);"), "object_color is a plain material uniform (0.6)")
	var codes := [inc, ObjectLight.SHADER_FN]
	for kind in ["solid", "one", "two"]:
		for fade in [false, true]:
			codes.append(ObjectLoader.object_shader(kind, fade).code)
	for blend in ["opaque", "mix", "add", "mul"]:
		for fade in [false, true]:
			codes.append(ObjectLoader._mod_shader("back", blend, blend != "opaque", fade).code)
	var with_instance := 0
	for c in codes:
		if RegEx.create_from_string("(^|\\n)\\s*instance\\s+uniform").search(c) != null:
			with_instance += 1
	_check(with_instance == 0, "no object or mod shader declares an instance uniform (%d do)" % with_instance)

func _layer(flags: int) -> BmtReader.Layer:
	var l := BmtReader.Layer.new()
	l.layer_name = "test"
	l.ambient = Color(0.34, 0.21, 0.05, 1.0)
	l.diffuse = Color(0.59, 0.37, 0.09, 1.0)
	l.unknown = flags
	return l

func _materials() -> void:
	var solid = ObjectLoader._commit_material({"layer": _layer(0x140), "texture_key": "", "alpha_ref": 0, "two_sided": false, "rule": {}}, {})
	_check(solid is ShaderMaterial and (solid as ShaderMaterial).shader == ObjectLoader.OBJECT_SHADER, "a solid layer draws with object.gdshader")
	if solid is ShaderMaterial:
		_check((solid as ShaderMaterial).get_shader_parameter("albedo") == Color(0.59, 0.37, 0.09, 1.0), "... its material colour is the layer's SECOND colour, not the first")
	var two = ObjectLoader._commit_material({"layer": _layer(0x141), "texture_key": "", "alpha_ref": 0, "two_sided": true, "rule": {}}, {})
	_check(two is ShaderMaterial and (two as ShaderMaterial).shader == ObjectLoader.FOLIAGE_SHADER, "an untextured two-sided layer: the two-sided shader")
	var tex := ImageTexture.create_from_image(Image.create(1, 1, false, Image.FORMAT_RGBA8))
	var cut := ObjectLoader._build_foliage_material(_layer(0x341), tex, 128, false)
	_check(cut.get_shader_parameter("albedo") == Color(0.59, 0.37, 0.09, 1.0), "the foliage material's colour is the second colour too")

func _mod_shader() -> void:
	for blend in ["opaque", "mix", "add", "mul"]:
		var code := ObjectLoader._mod_shader("back", blend, blend != "opaque").code
		_check(code.contains("render_mode unshaded"), "mod shader (%s): unshaded" % blend)
		_check(code.contains(ObjectLight.OD0_LINE) and code.contains("vec3 lit = c.lit * srr_od0;"), "  ... DIFFUSE is the original's vertex colour")
		_check(not code.contains("EMISSION"), "  ... the stage result is drawn whole (no lit/unlit split)")
		_check(code.contains("ALBEDO = srr_obj_present(") == (blend in ["opaque", "mix"]), "  ... the tone map undone only on a drawn-over colour")
		var sh := Shader.new()
		sh.code = code
		_check(sh.get_shader_uniform_list().size() > 0, "  ... parses")

func _portrait() -> void:
	var p := PlayerPortrait.new()
	var mat := ShaderMaterial.new()
	mat.shader = ObjectLoader._mod_shader("back", "mix", false)
	mat.set_shader_parameter("albedo", Color(0.59, 0.59, 0.59, 1.0))
	var m := p._mod_material(mat)
	_check(m != null, "the portrait maps a mod pass")
	if m != null:
		_check(m.shader.code.contains(PlayerPortrait.MOD_OD0) and not m.shader.code.contains(ObjectLight.OD0_LINE), "  ... lit by the portrait's light")
		_check(not m.shader.code.contains("ALBEDO = srr_obj_present("), "  ... with no tone map to undo (its environment is Linear)")
		var sh := Shader.new()
		sh.code = m.shader.code
		_check(sh.get_shader_uniform_list().size() > 0, "  ... and parses")
	var solid := ObjectLoader._build_object_material(_layer(0x140), null)
	var pm := p._portrait_material(solid)
	_check(pm != null and pm.get_shader_parameter("material_color") == Color(0.59, 0.37, 0.09, 1.0), "the portrait reads a solid layer's second colour as c11's material")
	_check(_near((PlayerPortrait.zone_light_colors(Color(1, 1, 1), Color(1, 1, 1))["diffuse"] as Vector3).x, ObjectLight.diffuse_scale(ObjectLight.current_bloom)), "the portrait's diffuse scale follows the Bloom row")
	p.free()

func _character_light() -> void:
	var group := Node3D.new()
	var m := PackedByteArray()
	m.resize(96 * 96)
	m.fill(255)
	m[10 * 96 + 20] = 153
	group.set_meta(CharacterLight.SHADOW_META, m)
	var cl := CharacterLight.new(func(_p: Vector3) -> Array: return [null, group])
	_check(_near(cl.color_at(Vector3(20 * 20 + 5, 0, 10 * 20 + 5)), 153.0 / 384.0), "a body on the darkest tile: 153 / 384")
	_check(_near(cl.color_at(Vector3(5, 0, 5)), 255.0 / 384.0), "on a lit tile: 255 / 384")
	var none := CharacterLight.new(func(_p: Vector3) -> Array: return [])
	_check(_near(none.color_at(Vector3.ZERO), 1.0), "off every region: 1.0")
	# Per-level copies (round 706 review): the material itself at 0.6, one
	# shared copy per material and level otherwise, which remembers its base.
	var base := ObjectLoader._build_object_material(_layer(0x140), null)
	_check(ObjectLight.is_object_material(base), "an object material can take a colour")
	_check(ObjectLight.with_object_color(base, 0.6) == base, "0.6: the material itself")
	var c1 := ObjectLight.with_object_color(base, 153.0 / 384.0)
	var c2 := ObjectLight.with_object_color(base, 153.0 / 384.0)
	_check(c1 != base and c1 == c2, "one shared copy per material and level")
	_check(c1 is ShaderMaterial and absf(((c1 as ShaderMaterial).get_shader_parameter("object_color") as Vector3).x - 153.0 / 384.0) < 1e-3, "  ... with object_color set")
	_check(ObjectLight.base_of(c1) == base and ObjectLight.with_object_color(c1, 0.6) == base, "  ... which goes back to its base")
	# Built by parameter, not Resource.duplicate() (round 706 review,
	# MEASURED on the box: a duplicate drew its diffuse term brighter).
	var tex_m := ObjectLoader._build_object_material(_layer(0x140), ImageTexture.create_from_image(Image.create(1, 1, false, Image.FORMAT_RGBA8)))
	var cp := ObjectLight.copy_material(tex_m)
	_check(cp != tex_m and cp.shader == tex_m.shader and typeof(cp.get_shader_parameter("albedo")) == TYPE_COLOR
		and cp.get_shader_parameter("albedo") == tex_m.get_shader_parameter("albedo")
		and cp.get_shader_parameter("albedo_texture") == tex_m.get_shader_parameter("albedo_texture"), "copy_material: same shader, every parameter by name, the colour still a Color")
	var fade := ShaderMaterial.new()
	fade.shader = ObjectLoader.object_shader("solid", true)
	_check(not ObjectLight.is_object_material(fade), "a fade twin is AppearFade's, not touched")
	var mod_mat := ShaderMaterial.new()
	mod_mat.shader = ObjectLoader._mod_shader("back", "mix", false)
	_check(ObjectLight.is_object_material(mod_mat), "an MTRL mod's material takes one too")
	var body := Node3D.new()
	var mi := MeshInstance3D.new()
	mi.material_override = base
	body.add_child(mi)
	var mb := MeshInstance3D.new()
	mb.material_override = base
	mb.set_meta(CharacterLight.PULSE_META, base)
	body.add_child(mb)
	CharacterLight.set_on(body, 0.5)
	_check(mi.material_override != base and ObjectLight.base_of(mi.material_override) == base
		and absf(((mi.material_override as ShaderMaterial).get_shader_parameter("object_color") as Vector3).x - 0.5) < 1e-3, "set_on draws a mesh with its copy at the level")
	_check(mb.material_override == base, "a mesh a pulse holds (a state's or berserk's colour) is left alone")
	CharacterLight.set_on(body, 0.6)
	_check(mi.material_override == base, "back to 0.6: the material itself")
	_check(BodyPulse.ORIGINAL_META == CharacterLight.PULSE_META, "CharacterLight.PULSE_META is BodyPulse.ORIGINAL_META")
	body.free()
	group.free()

## Round 806 (READ, docs/protocol/night_lights.md): a layer with flag word
## bit 0x8 draws, at night, with oD0 = 1 and stage 0 MODULATE.
func _night_lit() -> void:
	_check(ObjectLoader.layer_draw_rule(0x348)["night_lit"] and ObjectLoader.layer_draw_rule(0x148)["night_lit"],
		"flag word 0x8 (0x348 / 0x148, the census's lamp words) is night-lit")
	_check(not ObjectLoader.layer_draw_rule(0x340)["night_lit"] and not ObjectLoader.layer_draw_rule(0x141)["night_lit"],
		"a word without 0x8 is not")
	_check(ObjectLoader.layer_draw_rule(0x348, -1, {"alpha_test": false, "blend": false})["night_lit"],
		"an MTRL mod does not clear it (it only ORs 0x10000000 in)")
	var inc := FileAccess.get_file_as_string("res://scripts/assets/object.gdshaderinc")
	_check(inc.contains("uniform bool night_lit = false;\nglobal uniform float srr_night;\n#define SRR_NIGHT_LIT (night_lit && srr_night > 0.5)"),
		"a material's night_lit and the world's srr_night make SRR_NIGHT_LIT")
	_check(inc.contains("\tif (SRR_NIGHT_LIT) {\n\t\tsrr_od0 = vec3(1.0);"), "at night a night-lit layer's oD0 is NOLIGHT's 1.0")
	for kind in ["solid", "one", "two"]:
		var names := []
		for u in ObjectLoader.object_shader(kind).get_shader_uniform_list():
			names.append(u["name"])
		_check(names.has("night_lit"), "the %s object shader has night_lit" % kind)
	var solid = ObjectLoader._commit_material({"layer": _layer(0x148), "texture_key": "", "alpha_ref": 0, "two_sided": false,
		"rule": ObjectLoader.layer_draw_rule(0x148)}, {})
	_check(solid is ShaderMaterial and (solid as ShaderMaterial).shader == ObjectLoader.OBJECT_SHADER
		and (solid as ShaderMaterial).get_shader_parameter("night_lit") == true, "a 0x148 layer: the object shader, night_lit on")
	var two = ObjectLoader._commit_material({"layer": _layer(0x349), "texture_key": "", "alpha_ref": 0, "two_sided": true,
		"rule": ObjectLoader.layer_draw_rule(0x349)}, {})
	_check(two is ShaderMaterial and (two as ShaderMaterial).shader == ObjectLoader.FOLIAGE_SHADER
		and (two as ShaderMaterial).get_shader_parameter("night_lit") == true, "a two-sided 0x349 layer: the two-sided shader, night_lit on")
	var day = ObjectLoader._commit_material({"layer": _layer(0x140), "texture_key": "", "alpha_ref": 0, "two_sided": false,
		"rule": ObjectLoader.layer_draw_rule(0x140)}, {})
	_check(day is ShaderMaterial and (day as ShaderMaterial).get_shader_parameter("night_lit") != true, "a 0x140 layer: night_lit off")
	_check(ProjectSettings.has_setting("shader_globals/srr_night"), "srr_night is a project shader global")
	# The pixel, on the CPU: MODULATE2X of the lit colour by day, the texture itself at night.
	var t := Vector3(0.6, 0.4, 0.2)
	var od0 := Vector3(0.35, 0.35, 0.4)
	_check(ObjectLight.night_lit_pixel(t, od0, false).is_equal_approx(Vector3(0.42, 0.28, 0.16)), "by day: 2 x texture x oD0")
	_check(ObjectLight.night_lit_pixel(t, od0, true).is_equal_approx(t), "at night: the texture itself")
