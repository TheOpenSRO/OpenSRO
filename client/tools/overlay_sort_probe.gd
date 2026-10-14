extends SceneTree

## Round 786 (the ground flicker): does the terrain overlays' draw order hold
## still while the rest of the transparent list changes? Measured in the real
## renderer, on the real builder's surfaces and materials, with synthetic
## data only (no game files).
##
## The scene: REGIONS synthetic regions built by MapmTerrainBuilder (dynamic
## light, TerrainLight's materials) whose vertices cycle through four flat-
## coloured tiles, so nearly every quad is covered by two or three overlays;
## a still camera over them; and CHURN invisible transparent quads (ALPHA 0)
## created BEFORE the regions -- as a session's bodies and effects sit among
## the regions in the scenario's instance array -- of which a few are hidden
## or shown every frame (a monster leaving the view, an effect ending).
## Nothing visible moves, so a pixel that changes between two frames is the
## overlays' order changing.
##
## ```
## tools/xwl_run.sh -s 640x360 godot --rendering-method forward_plus \
##   --rendering-driver vulkan --path client --script res://tools/overlay_sort_probe.gd
## OPENSRO_QA_OVERLAY_ORDER=tie ...   # the overlays at one priority, as before round 786
## ```
##
## Lines:
##   PROBE frame <n> changed <px>          a frame that differs from the last
##   PROBE RESULT mode <tie|ranked> frames <n> frames_changed <n> changed_px_total <n>
##        changed_px_max <n> distinct_pictures <n>

const REGIONS := 6
const CHURN := 300
const FRAMES := 240
const WARMUP := 30
const TILE_COLOURS := [Color(0.85, 0.2, 0.2), Color(0.2, 0.75, 0.25), Color(0.2, 0.3, 0.9), Color(0.9, 0.85, 0.2)]

var _churn: Array[MeshInstance3D] = []
var _rng := RandomNumberGenerator.new()
var _frame := 0
var _prev: PackedByteArray = PackedByteArray()
var _changed_frames := 0
var _changed_total := 0
var _changed_max := 0
var _pictures := {}

func _make_region(offset: int) -> MapmReader.ParsedRegion:
	var region := MapmReader.ParsedRegion.new()
	region.version = "1000"
	for band_row in MapmReader.BLOCKS_PER_SIDE:
		for band_col in MapmReader.BLOCKS_PER_SIDE:
			var block := MapmReader.Block.new()
			block.vertices.resize(17 * 17)
			for r in 17:
				for c in 17:
					var v := MapmReader.Vertex.new()
					v.height = 0.0
					var gr := band_row * 16 + r
					var gc := band_col * 16 + c
					var extra := PackedByteArray()
					extra.resize(3)
					extra.encode_u16(0, 1 + ((gr * 3 + gc * 2 + offset) % 4))
					v.extra = extra
					block.vertices[r * 17 + c] = v
			region.blocks.append(block)
	return region

func _initialize() -> void:
	_rng.seed = 786
	var root3d := Node3D.new()
	root.add_child(root3d)
	# The churn first, so it holds the instance array's early places.
	var sh := Shader.new()
	sh.code = "shader_type spatial;\nrender_mode unshaded, blend_mix, depth_draw_never, cull_disabled;\nvoid fragment() { ALBEDO = vec3(0.0); ALPHA = 0.0; }\n"
	var cmat := ShaderMaterial.new()
	cmat.shader = sh
	var quad := QuadMesh.new()
	quad.size = Vector2(40.0, 40.0)
	quad.material = cmat
	for i in CHURN:
		var q := MeshInstance3D.new()
		q.mesh = quad
		q.position = Vector3(_rng.randf_range(0.0, 1920.0 * 3), 30.0, _rng.randf_range(0.0, 1920.0 * 2))
		q.rotation_degrees = Vector3(-90, 0, 0)
		root3d.add_child(q)
		_churn.append(q)
	var lookup := {}
	for i in TILE_COLOURS.size():
		var img := Image.create(8, 8, true, Image.FORMAT_RGBA8)
		img.fill(TILE_COLOURS[i])
		img.generate_mipmaps()
		lookup[i + 1] = ImageTexture.create_from_image(img)
	TerrainLight.set_light(Color.WHITE, Color(0.0, 0.0, 0.0), Color(1, 1, 1), 1.0)
	for k in REGIONS:
		var region := _make_region(k)
		var surfaces := MapmTerrainBuilder.build_full_region_surfaces_textured(region, lookup,
			Vector3.UP, Color.WHITE, Color.BLACK, PackedByteArray(), true)
		var mi := MeshInstance3D.new()
		mi.mesh = MapmTerrainBuilder.surfaces_to_mesh(surfaces, lookup, null)
		mi.position = Vector3(1920.0 * (k % 3), 0.0, 1920.0 * (k / 3))
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root3d.add_child(mi)
	var cam := Camera3D.new()
	cam.position = Vector3(1920.0 * 1.5, 1500.0, 1920.0 * 2.4)
	cam.far = 20000.0
	root3d.add_child(cam)
	cam.look_at(Vector3(1920.0 * 1.5, 0.0, 1920.0), Vector3.UP)
	cam.current = true
	print("PROBE mode %s regions %d churn %d" % [_mode(), REGIONS, CHURN])
	RenderingServer.frame_post_draw.connect(_after_draw)

func _mode() -> String:
	return "tie" if OS.get_environment("OPENSRO_QA_OVERLAY_ORDER") == "tie" else "ranked"

func _process(_delta: float) -> bool:
	# A few of the churn leave the view or come back each frame.
	for i in 6:
		var q := _churn[_rng.randi() % _churn.size()]
		q.visible = not q.visible
	return false

func _after_draw() -> void:
	_frame += 1
	if _frame <= WARMUP:
		return
	var img := root.get_texture().get_image()
	var data := img.get_data()
	if not _prev.is_empty() and _prev.size() == data.size():
		var changed := 0
		var ch := img.get_format() == Image.FORMAT_RGBA8
		var stride := 4 if ch else 3
		var i := 0
		while i < data.size():
			if absi(data[i] - _prev[i]) > 8 or absi(data[i + 1] - _prev[i + 1]) > 8 or absi(data[i + 2] - _prev[i + 2]) > 8:
				changed += 1
			i += stride
		if changed > 0:
			_changed_frames += 1
			_changed_total += changed
			_changed_max = maxi(_changed_max, changed)
			print("PROBE frame %d changed %d" % [_frame, changed])
	_prev = data
	_pictures[hash(data)] = true
	if _frame >= WARMUP + FRAMES:
		print("PROBE RESULT mode %s frames %d frames_changed %d changed_px_total %d changed_px_max %d distinct_pictures %d" % [
			_mode(), FRAMES, _changed_frames, _changed_total, _changed_max, _pictures.size()])
		quit(0)
