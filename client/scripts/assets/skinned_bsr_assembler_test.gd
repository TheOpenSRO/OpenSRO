extends SceneTree

## Round 626: how a worn item's layers are drawn -- by the one material rule,
## ObjectLoader.layer_draw_rule, with the item's own ENVMAP mod as the
## object input -- checked on the flag words MEASURED on real items (never
## real game data; the numbers are the words, not the files):
## `godot4 --headless --path client --script res://scripts/assets/skinned_bsr_assembler_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _init() -> void:
	var OL = load("res://scripts/assets/object_loader.gd")
	var names := {}
	for m in (OL as GDScript).get_script_method_list():
		names[m["name"]] = true
	_check(names.has("layer_draw_rule"), "ObjectLoader.layer_draw_rule is the one material rule")
	if not names.has("layer_draw_rule"):
		_finish()
		return
	# [what, layer flag word, the .bsr's ENVMAP flag word (-1 none), alpha ref, two-sided]
	# READ: the ENVMAP mod overrides the layer's 0x200 test for every material
	# (CRTModEnvMap::vslot_004): no test, or its own at ALPHAREF 1 when the
	# mod's word has bit 1. MEASURED words: sword_01 0x0340 + env 1,
	# spear_11 0x0141 + env 1, heavy_11_la 0x0341 + env 3, heavy_01_ha
	# 0x0341 + env 3, clothes_04_ha's two-sided hat card 0x0341 with no mod.
	var cases := [
		["the starting sword", 0x0340, 0x1, 0, false],
		["spear_11 (the report's see-through spear)", 0x0141, 0x1, 0, true],
		["the Degree-11 legs", 0x0341, 0x3, 1, true],
		["a helmet with a plume", 0x0341, 0x3, 1, true],
		["a DXT1 cloth hat card", 0x0341, -1, 128, true],
		["a solid one-sided piece", 0x0140, -1, 0, false],
	]
	for c in cases:
		# No MTRL mod and one pass: items carry neither (census, round 626).
		var rule: Dictionary = OL.layer_draw_rule(c[1], c[2], {}, false)
		_check(int(rule["alpha_ref"]) == c[3] and bool(rule["two_sided"]) == c[4] and String(rule["blend"]) == "",
			"%s: flags 0x%04x env %d -> ALPHAREF %d, two-sided %s, no blend (got ref %s two-sided %s blend '%s')" % [
				c[0], c[1], c[2], c[3], c[4], rule["alpha_ref"], rule["two_sided"], rule["blend"]])
	# A two-sided layer with no test is the foliage shader at scissor 0 --
	# authored normals on both faces -- not a cull-disabled standard material.
	var layer := BmtReader.Layer.new()
	layer.layer_name = "synthetic"
	layer.ambient = Color.WHITE
	var tex := ImageTexture.create_from_image(Image.create(2, 2, false, Image.FORMAT_RGBA8))
	var two: ShaderMaterial = ObjectLoader._build_foliage_material(layer, tex, 0, true)
	_check(two != null and two.shader == ObjectLoader.FOLIAGE_SHADER
			and is_equal_approx(float(two.get_shader_parameter("alpha_scissor")), 0.0),
		"spear_11's layer is the two-sided foliage shader with no cut")
	var one: ShaderMaterial = ObjectLoader._build_foliage_material(layer, tex, 1, true)
	_check(one != null and is_equal_approx(float(one.get_shader_parameter("alpha_scissor")), 1.0 / 255.0),
		"the Degree-11 legs cut only alpha-0 texels (scissor 1/255)")
	_finish()

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
