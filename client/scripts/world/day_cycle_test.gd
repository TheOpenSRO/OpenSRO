extends SceneTree

## DayCycle, TerrainLight and LensFlare (round 786): the time of day's
## arithmetic as READ from sro_client.exe (DayCycle's header), on synthetic
## records -- and, where the box's Map.pk2 is there, on the real data:
## Jangan's SunColor at noon and at dawn, and the sun textures' own colours,
## which is where the red sun came from (SkyBox\glow.ddj). Headless:
## `godot4 --headless --path client --script res://scripts/world/day_cycle_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _near(a: float, b: float, eps: float = 1e-4) -> bool:
	return absf(a - b) <= eps

func _cnear(a: Color, b: Color, eps: float = 1e-4) -> bool:
	return _near(a.r, b.r, eps) and _near(a.g, b.g, eps) and _near(a.b, b.b, eps)

## A record with every channel empty but the ones given: channel -> groups.
func _record(channels: Dictionary) -> EnvironmentReader.Record:
	var rec := EnvironmentReader.Record.new()
	rec.channels.resize(16)
	for i in range(16):
		rec.channels[i] = channels.get(i, [])
	return rec

func _g4(r: float, g: float, b: float, t: float) -> PackedFloat32Array:
	return PackedFloat32Array([r, g, b, t])

func _g2(v: float, t: float) -> PackedFloat32Array:
	return PackedFloat32Array([v, t])

func _test_cycle() -> void:
	# Channel 0 (SunColor): dark at midnight, white at noon -- four keys so the
	# spline has neighbours.
	var rec := _record({
		0: [_g4(0.1, 0.1, 0.2, 0.0), _g4(1.0, 0.8, 0.4, 0.25), _g4(1.0, 1.0, 1.0, 0.5), _g4(1.0, 0.7, 0.3, 0.75), _g4(0.1, 0.1, 0.2, 1.0)],
		2: [_g4(0.4, 0.5, 0.6, 0.0), _g4(0.8, 0.8, 0.8, 0.5), _g4(0.4, 0.5, 0.6, 1.0)],
		9: [_g4(1.2, -0.3, 0.5, 0.0), _g4(1.2, -0.3, 0.5, 1.0)],
		10: [_g2(0.2, 0.0), _g2(0.6, 0.5), _g2(0.2, 1.0)],
		12: [_g2(0.5, 0.0), _g2(0.5, 1.0)],
	})
	var cyc := DayCycle.new()
	cyc.set_record(rec)
	var st := cyc.step(0.5, 0.016)
	_check(_cnear(st.sun, Color(1, 1, 1)), "the first step snaps to the record at its phase: the noon key (got %s)" % st.sun)
	_check(_cnear(st.fog, Color(1, 0, 0.5)), "colours are clamped to [0, 1] as retail clamps its fields (got %s)" % st.fog)
	_check(_near(st.cloud_alpha, 0.75), "the cloud alpha is (channel 12 + 1) / 2 (got %.3f)" % st.cloud_alpha)
	_check(_near(st.fog_near, 0.6), "the fog's near fraction is channel 10 (got %.3f)" % st.fog_near)
	# Easing: the next frame moves a quarter of the way at dt 0.5 (f = dt x 0.5).
	var target := DayCycle.targets(rec, 0.25)
	var before: Color = st.diffuse
	st = cyc.step(0.25, 0.5)
	var want := before + (target.diffuse - before) * 0.25
	_check(_cnear(st.diffuse, want), "a frame of 0.5 s eases a quarter of the way (READ: dt x 0.5) (got %s want %s)" % [st.diffuse, want])
	st = cyc.step(0.25, 10.0)
	_check(_cnear(st.diffuse, target.diffuse), "f is capped at 1: a long frame arrives (got %s)" % st.diffuse)
	cyc.snap()
	st = cyc.step(0.0, 0.016)
	_check(_cnear(st.sun, Color(0.1, 0.1, 0.2)), "snap() takes the next values at once (got %s)" % st.sun)
	# Resampling off: the cached targets.
	st = cyc.step(0.5, 10.0, false)
	_check(_cnear(st.sun, Color(0.1, 0.1, 0.2)), "without a resample the step eases toward the last targets")
	_check(cyc.settled, "a step that arrives settles: the next frames without a sample do nothing (OURS)")
	st = cyc.step(0.25, 0.016)
	_check(not cyc.settled, "a new sample that moved unsettles it")
	for i in range(2000):
		st = cyc.step(0.25, 0.016, false)
		if cyc.settled:
			break
	_check(cyc.settled and _cnear(st.sun, DayCycle._clamp01(DayCycle.targets(rec, 0.25).sun), 1e-6),
		"easing frame by frame settles on the targets exactly")
	# The keyframes through the day (spline, READ): between the dawn and noon
	# keys the spline, not the line.
	var mid := DayCycle.targets(rec, 0.375).sun
	var lin := Color(1.0, 0.9, 0.7)
	_check(_cnear(DayCycle.targets(rec, 0.25).sun, Color(1.0, 0.8, 0.4)) and _cnear(DayCycle.targets(rec, 0.75).sun, Color(1.0, 0.7, 0.3)),
		"at a key's time the sun colour is the key (dawn and dusk)")
	_check(not _cnear(mid, lin, 1e-3), "(negative) between keys it is not the linear midpoint (got %s)" % mid)
	var cr := Color(EnvironmentReader.catmull_rom(0.1, 1.0, 1.0, 1.0, 0.5), EnvironmentReader.catmull_rom(0.1, 0.8, 1.0, 0.7, 0.5),
		EnvironmentReader.catmull_rom(0.2, 0.4, 1.0, 0.3, 0.5))
	_check(_cnear(mid, cr), "it is the Catmull-Rom spline through the four keys around it (got %s want %s)" % [mid, cr])

func _test_bodies() -> void:
	var noon := DayCycle.sun_direction(0.5)
	_check(noon.distance_to(Vector3(0, 1, 0)) < 1e-6, "the sun stands overhead at noon (got %s)" % noon)
	_check(DayCycle.sun_direction(0.25).distance_to(Vector3(1, 0, 0)) < 1e-6, "it rises at +x at 06:00")
	_check(DayCycle.sun_direction(0.75).distance_to(Vector3(-1, 0, 0)) < 1e-6, "it sets at -x at 18:00")
	_check(DayCycle.sun_disc_drawn(0.25) and DayCycle.sun_disc_drawn(0.875) and not DayCycle.sun_disc_drawn(0.2) and not DayCycle.sun_disc_drawn(0.9),
		"the disc is drawn for 0.25 <= phase <= 0.875 (READ 0xd9a2b8, 0xde4d90)")
	var axis := DayCycle.body_axis(DayCycle.sun_direction(0.4))
	_check(_near(axis.dot(DayCycle.sun_direction(0.4)), 0.0, 1e-6), "the quad's axis is perpendicular to the direction: it faces the eye")
	_check(_near(DayCycle.moon_angle(0.0), 0.25 * TAU), "the moon stands overhead at midnight (angle pi/2)")
	_check(DayCycle.moon_direction(0.0).y > 0.99 and DayCycle.moon_direction(0.5).y < 0.0, "up at midnight, down at noon")
	_check(DayCycle.moon_drawn(0.1, 0) and DayCycle.moon_drawn(0.8, 28) and not DayCycle.moon_drawn(0.6, 0) and not DayCycle.moon_drawn(0.1, 29),
		"the moon is drawn while the day < 29 and phase < 0.5 or > 0.75 (READ)")
	_check(DayCycle.moon_texture(0) == "Sun\\moon01.ddj" and DayCycle.moon_texture(14) == "Sun\\moon15.ddj", "the moon's picture is moon%02d of day + 1")
	_check(DayCycle.is_night(0.0) and DayCycle.is_night(0.8) and not DayCycle.is_night(0.5) and not DayCycle.is_night(0.25),
		"night is 18:00 to 06:00 of the sky")
	_check(_near(DayCycle.SUN_HALF_SIZE, 666.6666870117188) and _near(DayCycle.BODY_DISTANCE, 20000.0) and _near(DayCycle.MOON_HALF_SIZE, 1000.0),
		"the disc's half-size 666.67 and the moon's 1000 at 20000 (READ)")

func _test_terrain_light() -> void:
	# The dynamic terrain's shader term equals the bake it replaced, for any
	# N.L, tint and channels (the CPU twins).
	var n := Vector3(0.2, 0.9, 0.1).normalized()
	var l := Vector3(0.6, 0.8, 0.0).normalized()
	var diffuse := Color(0.72, 0.70, 0.60)
	var ambient := Color(0.69, 0.75, 0.64)
	var tint := Color(0.5, 0.6, 0.7)
	var baked := MapmTerrainBuilder._lit_vertex_color(n, l, diffuse, ambient)
	var ndotl := MapmTerrainBuilder._lit_vertex_color(n, l, Color.WHITE, Color.BLACK).r
	var now := TerrainLight.lit(ndotl, tint, diffuse, ambient)
	_check(_cnear(now, Color(tint.r * baked.r, tint.g * baked.g, tint.b * baked.b)),
		"TerrainLight's term from the stored N.L equals the bake (tint x clamp(N.L x diffuse + ambient)) (got %s)" % now)
	_check(_near(ndotl, maxf(n.dot(l), 0.0)), "the dynamic build's vertex colour is N.L itself")
	var code := TerrainLight.shader_code(true, true)
	_check(code.contains("srr_terrain_diffuse") and code.contains("srr_terrain_shadow") and code.contains("water_clip_plane") and code.contains("ALPHA = c.a"),
		"the overlay mirror variant reads the three globals, the clip plane and writes alpha")
	_check(not TerrainLight.shader_code(false, false).contains("ALPHA"), "the opaque variant writes no alpha")
	var mat := TerrainLight.material(null, null, tint, false, -1, -1)
	_check(TerrainLight.is_terrain(mat) and mat.render_priority == -1 and int(mat.get_meta("terrain_texture_key")) == -1,
		"a dynamic material carries its priority and its texture key")

func _test_flare() -> void:
	_check(LensFlare.element_texture(2) == "Sun\\lens3.ddj", "the sun's flare element is lens3 (READ: index byte 2 + 1)")
	_check(LensFlare.element_alpha(0) == 10 and LensFlare.element_alpha(2) == 255 and LensFlare.element_alpha(5) == 20 and LensFlare.element_alpha(11) == 19,
		"the elements' alpha bytes (READ)")
	var mesh := LensFlare.quads(PackedInt32Array([2, 6]))
	_check(mesh.get_surface_count() == 1 and (mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() == 8,
		"one quad per element")

## A minimal A8R8G8B8 DDJ (DDS_PIXELFORMAT masks R 0xff0000 G 0xff00 B 0xff
## A 0xff000000) of one texel whose bytes in the file are b, g, r, a.
func _argb_ddj(b: int, g: int, r: int, a: int) -> PackedByteArray:
	var dds := PackedByteArray()
	dds.resize(4 + DdjReader.DDS_HEADER_SIZE + 4)
	var magic := "DDS ".to_ascii_buffer()
	for i in range(4):
		dds[i] = magic[i]
	dds.encode_u32(4, DdjReader.DDS_HEADER_SIZE)
	dds.encode_u32(4 + 8, 1)
	dds.encode_u32(4 + 12, 1)
	dds.encode_u32(4 + 24, 1)
	var pf := 4 + 72
	dds.encode_u32(pf, 32)
	dds.encode_u32(pf + 4, DdjReader.DDPF_RGB | DdjReader.DDPF_ALPHAPIXELS)
	dds.encode_u32(pf + 12, 32)
	dds.encode_u32(pf + 16, 0x00FF0000)
	dds.encode_u32(pf + 20, 0x0000FF00)
	dds.encode_u32(pf + 24, 0x000000FF)
	dds.encode_u32(pf + 28, 0xFF000000)
	var o := 4 + DdjReader.DDS_HEADER_SIZE
	dds[o] = b
	dds[o + 1] = g
	dds[o + 2] = r
	dds[o + 3] = a
	var buf := PackedByteArray()
	buf.resize(DdjReader.WRAPPER_SIZE + dds.size())
	var m := DdjReader.MAGIC.to_ascii_buffer()
	for i in range(m.size()):
		buf[i] = m[i]
	buf.encode_u32(0x0c, buf.size() - DdjReader.MAGIC_LEN)
	buf.encode_u32(0x10, 3)
	for i in range(dds.size()):
		buf[DdjReader.WRAPPER_SIZE + i] = dds[i]
	return buf

## The channel order: the file stores B, G, R, A; SkyBox\glow.ddj's texel
## is bytes 04 3a fc ff (MEASURED on the box) -- (252, 58, 4), red-orange.
## A decoder that took the bytes as R, G, B would read (4, 58, 252), blue,
## and this fails.
func _test_channel_order() -> void:
	var parsed := DdjReader.parse(_argb_ddj(0x04, 0x3a, 0xfc, 0xff))
	var img := DdjReader.to_image(parsed) if parsed != null else null
	_check(img != null, "a one-texel A8R8G8B8 DDJ decodes")
	if img != null:
		var px := img.get_pixel(0, 0)
		_check(px.r8 == 252 and px.g8 == 58 and px.b8 == 4 and px.a8 == 255,
			"bytes 04 3a fc ff are (R 252, G 58, B 4): the file's B, G, R, A order, by its masks (got %d %d %d %d)" % [px.r8, px.g8, px.b8, px.a8])
		_check(not (px.r8 == 4 and px.b8 == 252), "(negative) not read as R, G, B -- a swapped decoder turns the red glow blue")

## The real data, where the box has it (MEASURED; skipped elsewhere).
func _test_real_data() -> void:
	var path := Pk2Config.map_path()
	if path == "" or not FileAccess.file_exists(path):
		if FileAccess.file_exists("/opt/sro-files/client/Map.pk2"):
			path = "/opt/sro-files/client/Map.pk2"
		else:
			print("skip: no Map.pk2 -- the real-data checks run on the render box")
			return
	var archive := Pk2Reader.open(path)
	if archive == null:
		print("skip: %s does not open" % path)
		return
	var env_bytes := AssetSource.read_bytes("environment.ifo", archive)
	var table := EnvironmentReader.parse(env_bytes) if not env_bytes.is_empty() else null
	_check(table != null, "Map.pk2's environment.ifo parses")
	if table != null:
		var jangan: EnvironmentReader.Record = null
		for rec in table.records:
			if rec.key == 15:
				jangan = rec
		_check(jangan != null and jangan.name1 == "Env7", "environment 15 is Jangan's Env7")
		if jangan != null:
			var noon := DayCycle.targets(jangan, 0.5).sun
			var dawn := DayCycle.targets(jangan, 0.2487864).sun
			print("MEASURED Jangan SunColor: noon %s, dawn key %s, 0.88 %s" % [noon, dawn, DayCycle.targets(jangan, 0.881068).sun])
			_check(_cnear(noon, Color(1, 1, 1), 0.01), "Jangan's sun disc at noon is white (channel 0 = 1, 1, 1)")
			_check(dawn.r > dawn.g and dawn.g > dawn.b and dawn.b < 0.8, "at dawn it is yellow: R > G > B, B 0.757 (got %s)" % dawn)
			for phase in [0.25, 0.3, 0.5, 0.7, 0.85]:
				var c := DayCycle.targets(jangan, phase).sun
				_check(not (c.r > 0.8 and c.g < 0.5), "at phase %.2f the sun colour is not red (got %s)" % [phase, c])
	var tex_rgb := func(p: String, x: int, y: int) -> Color:
		var b := AssetSource.read_bytes(p, archive)
		var pt := DdjReader.parse(b) if not b.is_empty() else null
		var im := DdjReader.to_image(pt) if pt != null else null
		return im.get_pixel(x, y) if im != null else Color(-1, -1, -1, -1)
	var glow: Color = tex_rgb.call("SkyBox\\glow.ddj", 64, 64)
	print("MEASURED SkyBox\\glow.ddj centre texel %d %d %d %d" % [glow.r8, glow.g8, glow.b8, glow.a8])
	_check(glow.r8 == 252 and glow.g8 == 58 and glow.b8 == 4, "SkyBox\\glow.ddj is (252, 58, 4): the red the old sun sprite drew")
	var lens2: Color = tex_rgb.call("Sun\\lens2.ddj", 64, 64)
	_check(lens2.r8 == 255 and lens2.g8 == 255 and lens2.b8 == 255 and lens2.a8 == 255, "Sun\\lens2.ddj (the disc's alpha) is white and opaque at its centre")
	var halo: Color = tex_rgb.call("Sun\\lens3.ddj", 128 + 64, 128)
	print("MEASURED Sun\\lens3.ddj texel at r = 64: %d %d %d %d" % [halo.r8, halo.g8, halo.b8, halo.a8])
	_check(halo.r8 >= halo.g8 and halo.g8 > halo.b8 and halo.b8 > 150, "Sun\\lens3.ddj's halo (the flare's sun glow) is pale yellow: R >= G > B")

## Every shader round 786 adds parses (the dummy renderer compiles them and
## prints a SHADER ERROR otherwise).
func _test_shaders_parse() -> void:
	var body := load("res://scripts/world/sky_body.gdshader") as Shader
	_check(body != null and body.get_shader_uniform_list().size() >= 7, "sky_body.gdshader parses")
	for blend in ["blend_mix", "blend_add"]:
		var sh := Shader.new()
		sh.code = LensFlare.SHADER % blend
		_check(sh.get_shader_uniform_list().size() >= 8, "the flare's shader (%s) parses" % blend)
	for blend in [false, true]:
		for clip in [false, true]:
			var sh := TerrainLight.shader(blend, clip)
			_check(sh.get_shader_uniform_list().size() >= 5, "TerrainLight's shader (blend %s, clip %s) parses" % [blend, clip])
	var cloud := load("res://scripts/assets/cloud_dome.gdshader") as Shader
	var names := []
	for u in cloud.get_shader_uniform_list():
		names.append(u["name"])
	_check(names.has("body_sun_on") and names.has("body_moon_tex"), "the cloud layer takes the sun and the moon for its Forward+ blend")

func _init() -> void:
	_test_shaders_parse()
	_test_cycle()
	_test_bodies()
	_test_terrain_light()
	_test_flare()
	_test_channel_order()
	_test_real_data()
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)
