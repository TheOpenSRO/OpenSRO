extends SceneTree

## Round 719: the select screen's translucent pairs (CharSelectStage.fade_code)
## on the body shaders the screen really draws -- PlayerPortrait's opaque and
## blended layers -- run headless:
## `godot4 --headless --path client --script res://scripts/frontend/charselect_fade_test.gd`
##
## What the frames show (the effective alpha of the pending character) is
## measured on the render box with OPENSRO_QA_PENDING_PROBE (party719.md).

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _modes(code: String) -> PackedStringArray:
	var m := RegEx.create_from_string("render_mode([^;]*);").search(code)
	var out := PackedStringArray()
	if m != null:
		for p in m.get_string(1).split(","):
			out.append(p.strip_edges())
	return out

func _fragment_tail(code: String) -> String:
	var frag := code.find("void fragment()")
	return code.substr(frag)

func _init() -> void:
	var portrait := PlayerPortrait.new()
	var opaque: String = (portrait.call("_shader", "cull_back", false) as Shader).code
	var blended: String = (portrait.call("_shader", "cull_disabled", true) as Shader).code

	# The opaque layer: a depth pass and a colour pass.
	var depth := CharSelectStage.fade_code(opaque, true)
	var colour := CharSelectStage.fade_code(opaque, false)
	_check(depth != "" and colour != "", "an opaque portrait layer has both passes")
	var dm := _modes(depth)
	_check(dm.has("unshaded") and dm.has("cull_back"), "the depth pass keeps the layer's own modes")
	_check(dm.has("blend_mix") and dm.has("depth_draw_always") and not dm.has("depth_draw_opaque"),
		"the depth pass writes depth always, blended (got %s)" % ", ".join(dm))
	_check(_fragment_tail(depth).contains("ALPHA = 0.0;"), "the depth pass draws no colour (ALPHA 0)")
	_check(_fragment_tail(depth).contains("discard"), "the depth pass keeps the alpha test's discard")
	var cm := _modes(colour)
	_check(cm.has("blend_mix") and cm.has("depth_draw_never") and not cm.has("depth_draw_opaque"),
		"the colour pass blends and writes no depth (got %s)" % ", ".join(cm))
	_check(colour.contains("uniform float select_fade = 1.0;"), "the colour pass has the fade uniform")
	_check(colour.contains("uniform float select_use_tex = 1.0;"), "the colour pass has the texture-alpha switch")
	_check(_fragment_tail(colour).contains("ALPHA = mix(1.0, t.a, select_use_tex) * select_fade;"),
		"the colour alpha is the texture's alpha x the fade (MODULATE), or the fade alone (SELECTARG2) when switched off")
	_check(not opaque.contains("ALPHA"), "the opaque source writes no ALPHA (its alpha only enters under the fade)")

	# The blended layer: no depth pass; under the fade its own blend gives way
	# to blend_mix (FUN_00bf0e20 sets the mods' states before the fade's).
	_check(CharSelectStage.fade_code(blended, true) == "", "a blended layer that writes no depth has no depth pass")
	var bc := CharSelectStage.fade_code(blended, false)
	var bm := _modes(bc)
	_check(bm.has("blend_mix") and bm.count("blend_mix") == 1 and bm.has("depth_draw_never"),
		"a blended layer's colour pass blends once, as a mix, and writes no depth (got %s)" % ", ".join(bm))
	_check(_fragment_tail(bc).contains("ALPHA = mix(1.0, t.a, select_use_tex) * select_fade;"),
		"a blended layer's alpha under the fade is the original's stage-0 rule too")
	var add_mod := "shader_type spatial;\nrender_mode unshaded, blend_add, depth_draw_always;\nvoid fragment() {\n\tALBEDO = vec3(1.0);\n\tALPHA = 0.5;\n}\n"
	var am := _modes(CharSelectStage.fade_code(add_mod, false))
	_check(am.has("blend_mix") and not am.has("blend_add"), "an additive mod is mixed under the fade (got %s)" % ", ".join(am))
	_check(CharSelectStage.fade_code(add_mod, true) != "", "a blending mod that writes depth keeps a depth pass")

	# Shaders the pairs cannot rewrite.
	_check(CharSelectStage.fade_code("shader_type canvas_item;\nvoid fragment() { COLOR = vec4(1.0); }", false) == "",
		"a canvas shader is not rewritten")
	_check(CharSelectStage.fade_code("shader_type spatial;\nvoid fragment() { ALBEDO = vec3(1.0); }", false) == "",
		"a spatial shader with no render_mode is not rewritten")

	# The tail goes inside fragment(), not into a later function.
	var two := "shader_type spatial;\nrender_mode unshaded;\nvoid fragment() {\n\tif (true) { ALBEDO = vec3(1.0); }\n}\nvoid light() {\n\tDIFFUSE_LIGHT = vec3(0.0);\n}\n"
	var t := CharSelectStage.fade_code(two, false)
	var at := t.find("ALPHA = select_fade;")
	_check(at > t.find("void fragment()") and at < t.find("void light()"), "the fade line lands at the end of fragment()")

	# Round 734's review, F8 (OURS): a glowing weapon's particle holders fade
	# with the body; other effects are not this screen's to touch.
	var stage := CharSelectStage.new()
	var d := CharSelectStage.Drawn.new()
	d.body = CharacterAppearance.Body.new()
	var holder := EfpEffect.new()
	holder.set_meta(EquipGlow.FX_META, true)
	var part := MeshInstance3D.new()
	holder.add_child(part)
	d.body.add_child(holder)
	var other := EfpEffect.new()
	var other_part := MeshInstance3D.new()
	other.add_child(other_part)
	d.body.add_child(other)
	d.alpha = 102.0
	stage.call("_apply_alpha", d)
	_check(absf(part.transparency - 0.6) < 1e-4 and other_part.transparency == 0.0,
		"alpha 102: the glow's particle holder drawn at 0.4 (transparency %.3f), another effect untouched" % part.transparency)
	d.alpha = 255.0
	stage.call("_apply_alpha", d)
	_check(part.transparency == 0.0, "full alpha: the holder opaque again")
	d.body.free()
	stage.free()

	portrait.free()
	print("charselect_fade_test: %d failure(s)" % _failures)
	quit(1 if _failures > 0 else 0)
