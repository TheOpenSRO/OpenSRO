extends SceneTree

## Round 734: the weapon and shield glow -- the three tables' readers and
## lookups, the pulse and scroll arithmetic, the glow material and its plain
## fallback, the particles' selection and scale, the QA kits.
##   godot4 --headless --path client --script res://scripts/items/item_glow_tables_test.gd
## The table lines are made up in the files' format (no game data): CRLF, `//`
## comments, tab columns, the type column's trailing space.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _near(a: float, b: float, eps: float = 1e-4) -> bool:
	return absf(a - b) <= eps

func _bytes(lines: Array) -> PackedByteArray:
	return "\r\n".join(PackedStringArray(lines)).to_ascii_buffer()

const THRESHOLDS := [3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14]

func _tables() -> ItemGlowTables:
	var t := ItemGlowTables.new()
	t.load_options(_bytes(["// a comment", "ITEM_TEST_SWORD\t3", "ITEM_TEST_SHIELD\t1", "", "BROKEN_LINE"]))
	var rows: Array = ["// comment line"]
	for ty in [1, 3]:
		for p in THRESHOLDS:
			rows.append("%d \t%d\t0.005000,-0.005000\tprim\\mtrl\\itemoption\\test%d.ddj\t%d\t%d\t0.1,0.2,0.3\t0.900,0.800,0.700\t%d\t%d" % [
				ty, p, p, 4 if p == 3 else 5, 9 if p == 13 else 7, 700 if p == 14 else 1000, 1 if ty == 3 else 0])
	t.load_types(_bytes(rows))
	t.load_particles(_bytes(["//code\tefp\tscale\tbone",
		"ITEM_TEST_SWORD\tsystem\\test_a.efp\t175\tai_end\tnone\t8\t100\t130",
		"ITEM_TEST_SHIELD\tsystem\\test_b.efp\t143\tBone01",
		"ITEM_TEST_SPEAR\tsystem\\test_c.efp\t40\tai_start\t1.0,2.0,3.0\t20\t30"]))
	return t

func _initialize() -> void:
	# The effect test places nodes in the tree, which is live from the first frame.
	await process_frame
	_test_tables()
	_test_pulse()
	_test_material()
	_test_fade_fallback()
	_test_particles()
	_test_appearance()
	_test_loadout()
	_test_view_glow()
	_test_reglow_mid_fade()
	await _test_clock()
	print("FAILURES: %d" % _failures if _failures > 0 else "all passed")
	quit(1 if _failures > 0 else 0)

func _test_tables() -> void:
	var t := _tables()
	_check(t.item_count() == 2 and t.skipped["option"] == 1, "itemoption: 2 items, the broken line skipped (%d, %s)" % [t.item_count(), str(t.skipped)])
	_check(t.row_count() == 22 and t.type_of("item_test_sword") == 3, "itemtypenumber: 22 rows; code names compare in upper case")
	_check(t.glow_row("ITEM_TEST_SWORD", 0) == null, "+0: no glow (READ, FUN_00a5f3e0 asks only for plus != 0)")
	_check(t.glow_row("ITEM_TEST_SWORD", 1) == null and t.glow_row("ITEM_TEST_SWORD", 2) == null, "+1, +2: below the lowest threshold, none")
	for pair in [[3, 3], [4, 3], [5, 5], [7, 7], [9, 9], [13, 13], [14, 14], [15, 14], [99, 14], [255, 14]]:
		var r := t.glow_row("ITEM_TEST_SWORD", pair[0])
		_check(r != null and r.plus == pair[1], "+%d -> the +%d row (the highest threshold <= plus)" % pair)
	_check(t.glow_row("ITEM_TEST_SWORD", 256 + 5).plus == 5, "the plus is a u8")
	_check(t.glow_row("ITEM_NOT_LISTED", 9) == null, "an item with no type number has no glow")
	var r13 := t.glow_row("ITEM_TEST_SWORD", 13)
	_check(r13.type_number == 3 and r13.op0 == ItemGlowTables.OP_MODULATE2X and r13.op1 == ItemGlowTables.OP_ADDSIGNED2X,
		"+13: MODULATE2X then ADDSIGNED2X")
	_check(r13.alpha_test and not t.glow_row("ITEM_TEST_SHIELD", 13).alpha_test, "the alpha-test flag per type")
	_check(r13.texture == "prim\\mtrl\\itemoption\\test13.ddj" and r13.color1.is_equal_approx(Vector3(0.1, 0.2, 0.3))
		and r13.color2.is_equal_approx(Vector3(0.9, 0.8, 0.7)), "texture and the two colours")
	_check(t.glow_row("ITEM_TEST_SWORD", 3).op0 == ItemGlowTables.OP_MODULATE and t.glow_row("ITEM_TEST_SWORD", 14).period_ms == 700, "op0 and period per row")
	var uv := t.glow_row("ITEM_TEST_SWORD", 3).uv
	_check(uv.is_equal_approx(Vector2(0.005, -0.005)), "the UV pair")
	_check(t.glow_row("ITEM_TEST_SWORD", 3).uv_per_second().is_equal_approx(Vector2(0.25, -0.25)),
		"the scroll speed is uv x 50 a second (ms x uv / 20.0, READ)")
	# A UTF-16 file (a BOM) reads the same.
	var u := ItemGlowTables.new()
	var b16 := PackedByteArray([0xFF, 0xFE])
	b16.append_array("ITEM_X\t2\r\n".to_utf16_buffer())
	u.load_options(b16)
	_check(u.type_of("ITEM_X") == 2, "a UTF-16LE table reads too")

func _test_pulse() -> void:
	var p := 1000
	for pair in [[0.0, 0.0], [500.0, 0.5], [1000.0, 1.0], [1500.0, 0.5], [2000.0, 0.0], [2250.0, 0.25], [3000.0, 1.0]]:
		_check(_near(ItemGlowTables.pulse_t(pair[0], p), pair[1]), "pulse at %d ms of a 1000 ms period: %.2f" % [int(pair[0]), pair[1]])
	_check(_near(ItemGlowTables.pulse_t(700.0, 700), 1.0) and _near(ItemGlowTables.pulse_t(1400.0, 700), 0.0), "+14's 700 ms: a full cycle is 1.4 s")
	_check(_near(ItemGlowTables.pulse_t(123.0, 0), 0.0), "period 0: colour 1 held")
	var c1 := Vector3(0.996, 0.173, 0.510)
	var c2 := Vector3(0.902, 0.122, 0.761)
	_check(ItemGlowTables.tfactor(c1, c2, 0.0) == Vector3i(254, 44, 130), "TFACTOR at t 0: round(c1 x 255) = (254, 44, 130)")
	_check(ItemGlowTables.tfactor(c1, c2, 1.0) == Vector3i(230, 31, 194), "TFACTOR at t 1: round(c2 x 255) = (230, 31, 194)")
	_check(ItemGlowTables.tfactor(c1, c2, 0.5) == Vector3i(242, 38, 162), "TFACTOR at t 0.5: the lerp, rounded")
	# The stage maths: MODULATE2X then ADD, clamped after each stage.
	var tf := Vector3i(255, 128, 0)
	var g := ItemGlowTables.glow_colour(Vector3(0.2, 0.2, 0.2), Vector3(0.6, 0.6, 0.6), tf, ItemGlowTables.OP_MODULATE2X, ItemGlowTables.OP_ADD)
	_check(g.is_equal_approx(Vector3(1.0, 0.2 + 0.6 * 128.0 / 255.0 * 2.0, 0.2)), "MODULATE2X(opt, tf) clamps, then ADD the item: %s" % str(g))
	var m := ItemGlowTables.glow_colour(Vector3(0.2, 0.2, 0.2), Vector3(0.6, 0.6, 0.6), tf, ItemGlowTables.OP_MODULATE, ItemGlowTables.OP_ADD)
	_check(m.is_equal_approx(Vector3(0.8, 0.2 + 0.6 * 128.0 / 255.0, 0.2)), "MODULATE: x1")
	var s := ItemGlowTables.glow_colour(Vector3(0.5, 0.3, 0.1), Vector3(0.2, 0.2, 0.2), Vector3i(255, 255, 255), ItemGlowTables.OP_MODULATE2X, ItemGlowTables.OP_ADDSIGNED2X)
	_check(s.is_equal_approx(Vector3(0.8, 0.4, 0.0)), "ADDSIGNED2X: (a + b - 0.5) x 2, clamped: %s" % str(s))
	# The shader carries the same arithmetic.
	var inc := FileAccess.get_file_as_string("res://scripts/assets/object.gdshaderinc")
	_check(inc.contains("round(mix(glow_c1, glow_c2, srr_t) * 255.0) / 255.0") and inc.contains("srr_ph <= 1.0 ? srr_ph : 2.0 - srr_ph")
		and inc.contains("(srr_item + srr_s0 - vec3(0.5)) * 2.0") and inc.contains("fract(glow_uv_speed * srr_time)"),
		"object.gdshaderinc's EQUIP_GLOW path: the triangle, the rounded TFACTOR, ADDSIGNED2X, the scroll")

func _plain() -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = ObjectLoader.OBJECT_SHADER
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.5, 0.25, 0.125, 1.0))
	m.set_shader_parameter("albedo_texture", ImageTexture.create_from_image(img))
	m.set_shader_parameter("albedo", Color.WHITE)
	return m

func _test_material() -> void:
	var t := _tables()
	var row := t.glow_row("ITEM_TEST_SWORD", 13)
	var p := EquipGlow.row_params(row)
	_check(_near(float(p["glow_period"]), 1.0) and _near(float(p["glow_mul0"]), 2.0) and _near(float(p["glow_signed2x"]), 1.0)
		and (p["glow_uv_speed"] as Vector2).is_equal_approx(Vector2(0.25, -0.25)) and _near(float(p["alpha_scissor"]), 1.0 / 255.0),
		"row_params: period s, MODULATE2X x2, ADDSIGNED2X, speed, alpha test at 1/255")
	_check(_near(float(EquipGlow.row_params(t.glow_row("ITEM_TEST_SHIELD", 3))["alpha_scissor"]), 0.0)
		and _near(float(EquipGlow.row_params(t.glow_row("ITEM_TEST_SHIELD", 3))["glow_mul0"]), 1.0), "flag 0: no alpha test; MODULATE x1")
	for cull in ["back", "disabled"]:
		for at in [false, true]:
			var sh := EquipGlow.glow_shader(cull, at)
			var names := []
			for u in sh.get_shader_uniform_list():
				names.append(u["name"])
			_check(names.has("glow_texture") and names.has("glow_c1") and names.has("glow_uv_speed") and names.has("albedo_texture")
				and sh.code.contains("unshaded") and sh.code.contains("cull_" + cull) and sh.code.contains("OBJECT_SOLID") != at,
				"glow shader %s/%s parses, unshaded (uniforms %d)" % [cull, at, names.size()])
	_check(EquipGlow.glow_shader("back", true) == EquipGlow.glow_shader("back", true), "one shader per (cull, test)")
	var plain := _plain()
	var g := EquipGlow.material_for(plain, row, null)
	_check(EquipGlow.is_glow(g) and EquipGlow.plain_of(g) == plain and EquipGlow.plain_of(plain) == plain, "the glow keeps its plain material")
	_check(g.get_shader_parameter("albedo_texture") == plain.get_shader_parameter("albedo_texture"), "the item's own texture on stage 1 (READ, OPEN 9 closed: 0x80000000 -> SetTexture(1) at 0xbf10ce)")
	_check(EquipGlow.material_for(plain, row, null) == g, "a glow material is shared per (row, plain material)")
	_check(not ObjectLight.is_object_material(g), "CharacterLight leaves a glow material alone (it is unlit)")
	_check(EquipGlow.cull_of(_foliage_two()) == "disabled" and EquipGlow.cull_of(plain) == "back", "the cull follows the plain material")
	# Applied to an item node and taken off again.
	var node := Node3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = BoxMesh.new()
	mi.material_override = plain
	node.add_child(mi)
	var done := EquipGlow.apply([node], row, [], null, null, "test")
	_check(int(done["meshes"]) == 1 and EquipGlow.is_glow(mi.material_override), "apply: the item's mesh glows")
	EquipGlow.apply([node], t.glow_row("ITEM_TEST_SWORD", 5), [], null, null, "test")
	_check(EquipGlow.plain_of(mi.material_override) == plain and (mi.material_override as ShaderMaterial).get_shader_parameter("glow_signed2x") == 0.0,
		"re-applied: built on the plain material, never on a glow")
	_check(EquipGlow.clear(node) == 1 and mi.material_override == plain, "clear: back on the plain material")
	node.free()

func _foliage_two() -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = ObjectLoader.FOLIAGE_SHADER
	return m

func _test_fade_fallback() -> void:
	var t := _tables()
	var plain := _plain()
	var g := EquipGlow.material_for(plain, t.glow_row("ITEM_TEST_SWORD", 9), null)
	var twin := AppearFade.fade_twin(g) as ShaderMaterial
	_check(twin != null and twin.shader == ObjectLoader.appear_fade_shader(ObjectLoader.OBJECT_SHADER) and not twin.shader.code.contains("EQUIP_GLOW"),
		"a fading glowing item fades on its plain material (the full-alpha gate)")

func _test_particles() -> void:
	var t := _tables()
	_check(t.particle_rows("ITEM_TEST_SWORD", 7).is_empty(), "+7: no particles (min 8)")
	_check(t.particle_rows("ITEM_TEST_SWORD", 8).size() == 1 and t.particle_rows("ITEM_TEST_SWORD", 100).size() == 1, "+8 and +100: the row")
	_check(t.particle_rows("ITEM_TEST_SWORD", 101).is_empty(), "+101: past max, none")
	var r: ItemGlowTables.ParticleRow = t.particle_rows("ITEM_TEST_SWORD", 9)[0]
	_check(r.efp == "system\\test_a.efp" and r.bone == "ai_end" and _near(r.scale, 1.75) and r.offset == Vector3.ZERO,
		"efp, bone in file order; scale col3/100; `none` offset zero")
	var sh: ItemGlowTables.ParticleRow = t.particle_rows("ITEM_TEST_SHIELD", 0)[0]
	_check(sh.min_plus == 0 and sh.max_plus == 255, "missing min/max columns: 0 and 0xFF (READ)")
	var sp: ItemGlowTables.ParticleRow = t.particle_rows("ITEM_TEST_SPEAR", 25)[0]
	_check(sp.offset.is_equal_approx(Vector3(1, 2, 3)) and t.particle_rows("ITEM_TEST_SPEAR", 31).is_empty(), "an offset and a min/max read")
	# The effect's scale on its anchor (CRTModParticle +0xc0 -> CEFEffect::vslot_010).
	var host := Node3D.new()
	get_root().add_child(host)
	var fx := EfpEffect.new()
	fx.effect_scale = 1.75
	SkillEffects.attach(fx, host, "none", Vector3.ZERO)
	_check(_near(fx.global_transform.basis.get_scale().x, 1.75), "effect_scale scales the effect's anchor (%s)" % str(fx.global_transform.basis.get_scale()))
	host.free()
	# No bone, no effect (READ: FUN_00c816c0 returns 0); no archive, none built.
	var node := Node3D.new()
	var skel := Skeleton3D.new()
	skel.add_bone("ai_end")
	node.add_child(skel)
	var before := int(EquipGlow.stats["no_bone"])
	var made := EquipGlow.apply([node], null, t.particle_rows("ITEM_TEST_SHIELD", 9), null, null, "test")
	_check(int(made["particles"]) == 0 and int(EquipGlow.stats["no_bone"]) == before + 1, "a row naming a bone the item lacks attaches nothing")
	var failed := int(EquipGlow.stats["particles_failed"])
	made = EquipGlow.apply([node], null, t.particle_rows("ITEM_TEST_SWORD", 9), null, null, "test")
	_check(int(made["particles"]) == 0 and int(EquipGlow.stats["particles_failed"]) == failed + 1, "the bone found, no Particles.pk2: counted, not drawn")
	node.free()
	# The portrait's copy: effects made here are stripped.
	var root := Node3D.new()
	var mark := EfpEffect.new()
	mark.set_meta(EquipGlow.FX_META, true)
	var other := EfpEffect.new()
	root.add_child(mark)
	root.add_child(other)
	_check(EquipGlow.strip_particles(root) == 1 and root.get_child_count() == 1, "strip_particles frees only the glow's effects")
	root.free()

func _test_appearance() -> void:
	var t := _tables()
	var a := CharacterAppearance.new()
	a.glow_tables = t
	var node := Node3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = BoxMesh.new()
	var plain := _plain()
	mi.material_override = plain
	node.add_child(mi)
	var wear := {"slot": CharacterAppearance.SLOT_WEAPON, "code": "ITEM_TEST_SWORD", "plus": 7, "nodes": [node]}
	a._apply_glow(wear)
	_check(int(wear["glow"]) == 7 and EquipGlow.is_glow(mi.material_override), "a +7 weapon wears the +7 row")
	var chest := {"slot": CharacterAppearance.SLOT_CHEST, "code": "ITEM_TEST_SWORD", "plus": 7, "nodes": [node]}
	a._apply_glow(chest)
	_check(int(chest["glow"]) == 0, "only the weapon and shield slots glow (FUN_00a60a90's kind-1 attachments)")
	var skel := Skeleton3D.new()
	skel.add_child(node)
	skel.set_meta(CharacterAppearance.GLOW_WEARS_META, [{"slot": CharacterAppearance.SLOT_WEAPON, "code": "ITEM_TEST_SWORD", "plus": 7, "nodes": [node]}])
	_check(a.reglow(skel, {CharacterAppearance.SLOT_WEAPON: 11}) == 1 and EquipGlow.plain_of(mi.material_override) == plain
		and _near(float((mi.material_override as ShaderMaterial).get_shader_parameter("glow_period")), 1.0), "reglow: +11 drawn on the built body")
	a.reglow(skel, {})
	_check(mi.material_override == plain, "reglow at +0: the glow comes off")
	a.glow_enabled = false
	var off := {"slot": CharacterAppearance.SLOT_WEAPON, "code": "ITEM_TEST_SWORD", "plus": 9, "nodes": [node]}
	a._apply_glow(off)
	_check(int(off["glow"]) == 0 and mi.material_override == plain, "glow_enabled false draws none")
	skel.free()

func _test_loadout() -> void:
	var bad: Array = []
	var k := EquipGlow.parse_loadout("6=3632+13,7=0,1=3637,bad,4=x,5=3+y", bad)
	_check((k[0] as Dictionary) == {6: 3632, 7: 0, 1: 3637} and (k[1] as Dictionary) == {6: 13}, "QA loadout: slot=id[+plus] (%s)" % str(k))
	_check(bad.size() == 3, "QA loadout: the malformed pairs named (%s)" % str(bad))

## Round 734's review, F1 (its probe A as a test): the select screen, the
## equipment window and the portrait put their own materials on a dressed body
## (PlayerPortrait._apply_materials). A glowing item keeps its glow there, and
## the plain layer behind it keeps its alpha reference. NEGATIVE on cf11fefa:
## after _apply_materials, is_glow false and alpha_ref 0 (the flag-0 row's
## alpha_scissor taken for the plain layer's 0.502).
func _test_view_glow() -> void:
	var t := _tables()
	for case in [["ITEM_TEST_SHIELD", 3, false], ["ITEM_TEST_SWORD", 13, true]]:
		var row := t.glow_row(String(case[0]), int(case[1]))
		var plain := _plain()
		plain.set_shader_parameter("alpha_scissor", 0.502)
		var opt := ImageTexture.create_from_image(Image.create(2, 2, false, Image.FORMAT_RGBA8))
		var glow := EquipGlow.material_for(plain, row, opt)
		for world in [false, true]:
			var node := Node3D.new()
			var mi := MeshInstance3D.new()
			mi.mesh = BoxMesh.new()
			mi.material_override = glow
			node.add_child(mi)
			var view := PlayerPortrait.new()
			view.glow_world_present = world
			view.call("_apply_materials", node)
			var m := mi.material_override as ShaderMaterial
			var back := EquipGlow.plain_of(m) as ShaderMaterial
			var key: Array = m.shader.get_meta(EquipGlow.GLOW_SHADER_META, []) if m != null and m.shader != null else []
			var label := "%s +%d, %s" % [case[0], case[1], "select screen" if world else "portrait / equipment window"]
			_check(m != null and m != glow and EquipGlow.is_glow(m) and key.size() == 3 and bool(key[1]) == bool(case[2]) and bool(key[2]) == world,
				"%s: the glow is kept, on the %s glow shader, alpha test %s (%s)" % [label, "world's" if world else "Linear view's", case[2], str(key)])
			_check(m != null and m.get_shader_parameter("glow_texture") == opt and _near(float(m.get_shader_parameter("glow_period")), float(row.period_ms) / 1000.0)
				and m.get_shader_parameter("albedo_texture") == plain.get_shader_parameter("albedo_texture")
				and _near(float(m.get_shader_parameter("alpha_scissor")), float(EquipGlow.row_params(row)["alpha_scissor"])),
				"%s: the row's uniforms copied (option texture, period, the item's texture, the row's alpha test)" % label)
			_check(back != null and back != plain and _near(float(back.get_shader_parameter("alpha_ref")), 0.502),
				"%s: behind it, the view's own plain material with the item's alpha_ref 0.502 (%s)" % [label, str(back.get_shader_parameter("alpha_ref")) if back != null else "none"])
			var mats: Array = view.get("_materials")
			_check(mats.has(back) and not mats.has(m), "%s: the plain material takes the view's light, the unlit glow is not in its list" % label)
			_check(EquipGlow.is_glow(glow) and EquipGlow.plain_of(glow) == plain, "%s: the world's shared glow material is untouched" % label)
			node.free()
			view.free()
	var lin := EquipGlow.glow_shader("back", true, false)
	_check(lin.code.contains("#define OBJECT_NO_PRESENT") and not EquipGlow.glow_shader("back", true).code.contains("OBJECT_NO_PRESENT")
		and lin != EquipGlow.glow_shader("back", true), "the Linear view's glow shader skips srr_obj_present; the world's keeps it")
	var inc := FileAccess.get_file_as_string("res://scripts/assets/object.gdshaderinc")
	_check(inc.contains("#ifdef OBJECT_NO_PRESENT\n\t// A Linear view (the portrait, the equipment window): written as is.\n\tALBEDO = srr_glow("),
		"object.gdshaderinc: OBJECT_NO_PRESENT writes the glow without srr_obj_present")

## Round 734's review, F6: a reglow while the body fades in (AppearFade) keeps
## the fade's twin on the mesh, builds the new glow on the plain material (not
## on the twin), and the fade's end gives the new glow back -- or, at +0, the
## plain material. NEGATIVE on cf11fefa: the twin became the glow's plain
## material, and a clear left the old glow to come back at the fade's end.
func _test_reglow_mid_fade() -> void:
	var t := _tables()
	var plain := _plain()
	var node := Node3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = BoxMesh.new()
	mi.material_override = plain
	node.add_child(mi)
	EquipGlow.apply([node], t.glow_row("ITEM_TEST_SWORD", 7), [], null, null, "test")
	var g7 := mi.material_override
	var fades := AppearFade.Fades.new()
	fades.start(node)
	fades.step(0.5)
	var twin := mi.material_override
	_check(twin != g7 and twin.has_meta(AppearFade.TWIN_META), "fading: the mesh draws on the fade's twin")
	EquipGlow.clear(node)
	EquipGlow.apply([node], t.glow_row("ITEM_TEST_SWORD", 9), [], null, null, "test")
	var given: Material = mi.get_meta(AppearFade.ORIGINAL_META, null)
	_check(mi.material_override == twin and EquipGlow.is_glow(given) and EquipGlow.plain_of(given) == plain,
		"reglow +7 -> +9 mid-fade: the twin stays, the +9 glow is built on the plain material and waits for the fade's end")
	fades.step(2.0)
	_check(mi.material_override == given and not mi.has_meta(AppearFade.ORIGINAL_META), "the fade's end gives back the +9 glow")
	fades.start(node)
	fades.step(0.5)
	EquipGlow.clear(node)
	_check(mi.get_meta(AppearFade.ORIGINAL_META, null) == plain and mi.material_override.has_meta(AppearFade.TWIN_META), "reglow to +0 mid-fade: the plain material waits")
	fades.step(2.0)
	_check(mi.material_override == plain, "and the fade's end gives back the plain material, not the old glow")
	node.free()

## Round 734's review, F8: the glow's clock is a script accumulator wrapped at
## a whole number of every pulse cycle, not TIME (whose 3600 s rollover cut
## +14's 1.4 s cycle).
func _test_clock() -> void:
	var inc := FileAccess.get_file_as_string("res://scripts/assets/object.gdshaderinc")
	_check(inc.contains("global uniform float srr_glow_clock;") and inc.contains("srr_glow(tex.rgb, UV, srr_glow_clock)")
		and not inc.contains("srr_glow(tex.rgb, UV, TIME)"), "the glow runs on srr_glow_clock, not TIME")
	for cycle in [2.0, 1.4]:
		var n: float = EquipGlow.CLOCK_WRAP / float(cycle)
		_check(absf(n - roundf(n)) < 1e-6, "the wrap holds a whole number of %.1f s pulse cycles (%.1f)" % [cycle, n])
	_check(absf(fmod(EquipGlow.CLOCK_WRAP, 3600.0)) < 1e-6, "the wrap is a multiple of 3600 s, so every scroll cycle that fit TIME's rollover fits it")
	var before := EquipGlow.clock
	await process_frame
	await process_frame
	_check(EquipGlow.clock != before, "the clock advances with the frames (%.4f -> %.4f)" % [before, EquipGlow.clock])
