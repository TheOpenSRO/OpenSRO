extends SceneTree

## Exercises SkinnedBsrAssembler.equipment_material -- an equippable item's
## material by the client's own layer-flag rule (round 626) -- against
## synthetic layers and a synthetic texture (never real game data):
## `godot4 --headless --path client --script res://scripts/assets/skinned_bsr_assembler_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _layer(flags: int) -> BmtReader.Layer:
	var l := BmtReader.Layer.new()
	l.layer_name = "synthetic_%04x" % flags
	l.ambient = Color(0.588, 0.588, 0.588, 1.0)
	l.diffuse = Color(0.588, 0.588, 0.588, 1.0)
	l.unknown = flags
	l.texture_path = "synthetic.ddj"
	return l

## A 2x2 texture whose alpha is graded, the way an item's DXT3 gloss mask is.
func _texture() -> Texture2D:
	var img := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	img.set_pixel(0, 0, Color(1, 0, 0, 0.1))
	img.set_pixel(1, 0, Color(0, 1, 0, 0.4))
	img.set_pixel(0, 1, Color(0, 0, 1, 0.7))
	img.set_pixel(1, 1, Color(1, 1, 1, 1.0))
	return ImageTexture.create_from_image(img)

## What ObjectLoader builds for a bit-0 layer today: its cutout shader
## material, carrying the texture as `albedo_texture`.
func _as_loader_cutout(layer: BmtReader.Layer, tex: Texture2D) -> Material:
	return ObjectLoader._build_foliage_material(layer, tex)

func _as_loader_opaque(layer: BmtReader.Layer, tex: Texture2D) -> Material:
	var m := StandardMaterial3D.new()
	m.albedo_color = layer.ambient
	m.albedo_texture = tex
	return m

func _init() -> void:
	var tex := _texture()

	# spear_11's flags (MEASURED): 0x0141 -- bit 0 without bit 9. The
	# client's setter (CObjRendererVS::FUN_00c42a60) turns alpha test on for
	# bit 9 only, so the spear is drawn solid, not cut at 0.5 into holes.
	var spear := _layer(0x0141)
	var m1 := SkinnedBsrAssembler.equipment_material(spear, _as_loader_cutout(spear, tex))
	_check(m1 is StandardMaterial3D, "a bit-0-only item layer is a standard material, not the foliage cutout (got %s)" % m1.get_class())
	if m1 is StandardMaterial3D:
		var s1 := m1 as StandardMaterial3D
		_check(s1.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED,
			"bit 0 alone does not alpha-test: the layer is opaque (transparency %d)" % s1.transparency)
		_check(s1.cull_mode == BaseMaterial3D.CULL_DISABLED,
			"bit 0 is D3DRS_CULLMODE NONE: two-sided (cull %d)" % s1.cull_mode)
		_check(s1.albedo_texture == tex, "the loader's texture is kept")
		_check(s1.albedo_color == spear.ambient, "the albedo is the layer's ambient, as ObjectLoader sets it")

	# heavy_11_la's flags (MEASURED): 0x0341 -- bits 0 and 9. The setter
	# alpha-tests bit 9 at ALPHAREF 0x80, but 89.1% of this item's surface
	# samples alpha below that (MEASURED): its alpha is a gloss mask the
	# worn-item path cannot be testing. Drawn solid, two-sided.
	var legs := _layer(0x0341)
	var m2 := SkinnedBsrAssembler.equipment_material(legs, _as_loader_cutout(legs, tex)) as StandardMaterial3D
	_check(m2 != null and m2.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED,
		"a bit-9 item layer is drawn solid, its gloss alpha not cut (transparency %d)" % (m2.transparency if m2 != null else -1))
	_check(m2 != null and m2.cull_mode == BaseMaterial3D.CULL_DISABLED, "and bit 0 still makes it two-sided")

	# heavy_11_ba's flags (MEASURED): 0x0140 -- neither bit. Opaque, culled.
	var chest := _layer(0x0140)
	var m3 := SkinnedBsrAssembler.equipment_material(chest, _as_loader_opaque(chest, tex)) as StandardMaterial3D
	_check(m3 != null and m3.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED and m3.cull_mode == BaseMaterial3D.CULL_BACK,
		"a layer with neither bit is opaque and back-face culled")

	# sword_01's flags (MEASURED): 0x0340 -- bit 9 without bit 0: one-sided.
	var m4 := SkinnedBsrAssembler.equipment_material(_layer(0x0340), _as_loader_opaque(_layer(0x0340), tex)) as StandardMaterial3D
	_check(m4 != null and m4.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED and m4.cull_mode == BaseMaterial3D.CULL_BACK,
		"bit 9 without bit 0: solid, back faces culled")

	# The flag bits as the setter reads them.
	_check(SkinnedBsrAssembler.LAYER_FLAG_TWO_SIDED == 0x1 and SkinnedBsrAssembler.LAYER_FLAG_ALPHA_TEST == 0x200
		and SkinnedBsrAssembler.ALPHA_TEST_REF == 0x80,
		"bit 0 is two-sided, bit 9 the alpha test, ALPHAREF 0x80 (CObjRendererVS::FUN_00c42a60)")

	_check(SkinnedBsrAssembler.equipment_material(_layer(0x0141), null) == null,
		"no material in, none out")

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
