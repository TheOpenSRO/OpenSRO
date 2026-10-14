extends SceneTree

## Round 787 (OURS, NightLight): dark nights and shadows that follow the sun.
##   - the night amount by the clock: day at noon and at 19:40, full night at
##     23:00 and 02:00;
##   - the scale: a zone whose night is as bright as its noon (as retail's
##     environment 23 nearly is) comes down to the level; one already darker
##     is never brightened; Original changes nothing;
##   - World3D writes the scaled light into the objects' and characters'
##     globals (ObjectLight), the terrain's (TerrainLight, after the clamp),
##     the directional light and the ambient -- the portrait keeps the zone's;
##   - REGRESSION: a scene's average light at 23:00 must be well below noon's,
##     for the objects and the terrain, on a synthetic bright-night record
##     and (on the render box) on the real Jangan and Bandit records;
##   - the shadow light: its direction as a function of the phase (low at
##     dawn and dusk, overhead at noon, the moon's at night), the elevation
##     clamp, the step threshold, the glide and its settle.
## Headless: `client/tools/remote_godot.sh tests`.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _near(a: float, b: float, eps: float = 1e-4) -> bool:
	return absf(a - b) <= eps

func _g4(c: Color, t: float) -> PackedFloat32Array:
	return PackedFloat32Array([c.r, c.g, c.b, t])

func _g2(v: float, t: float) -> PackedFloat32Array:
	return PackedFloat32Array([v, t])

## A record lit `noon` at 0.5 and `night` at 0.0 / 1.0 on channels 2, 3 and
## 5 (diffuse, object ambient, terrain ambient), with a sky, fog, cloud and
## water channel that do the same.
func _record(noon: Color, night: Color) -> EnvironmentReader.Record:
	var rec := EnvironmentReader.Record.new()
	rec.channels.resize(16)
	for i in range(16):
		rec.channels[i] = []
	for ch in [1, 2, 3, 4, 5, 9, 13, 14]:
		rec.channels[ch] = [_g4(night, 0.0), _g4(noon, 0.5), _g4(night, 1.0)]
	rec.channels[6] = [_g4(Color(0, 0, 0), 0.0), _g4(Color(0, 0, 0), 1.0)]
	rec.channels[10] = [_g2(0.5, 0.0), _g2(0.5, 1.0)]
	rec.channels[11] = [_g2(1.0, 0.0), _g2(1.0, 1.0)]
	rec.channels[12] = [_g2(0.2, 0.0), _g2(0.2, 1.0)]
	return rec

func _phase(h: int, m: int) -> float:
	return GameClock.day_phase(float(h) + float(m) / 60.0)

func _test_amount() -> void:
	_check(_near(NightLight.amount(_phase(12, 0)), 0.0), "noon is day (amount 0)")
	_check(NightLight.amount(_phase(19, 40)) < 0.05, "19:40 (the sky's 17:45, the sun 3.7 degrees up) is still day (%.3f)" % NightLight.amount(_phase(19, 40)))
	_check(_near(NightLight.amount(_phase(23, 0)), 1.0) and _near(NightLight.amount(_phase(2, 0)), 1.0), "23:00 and 02:00 are full night")
	_check(NightLight.amount(_phase(20, 30)) > 0.85, "20:30 (the moon up, the sky's 18:45) is nearly full night (%.3f)" % NightLight.amount(_phase(20, 30)))
	var prev := -1.0
	var mono := true
	for i in range(0, 41):
		var a := NightLight.amount(lerpf(0.70, 0.80, float(i) / 40.0))
		if a < prev - 1e-6:
			mono = false
		prev = a
	_check(mono, "the night falls without going back, from the sky's 16:48 to 19:12")
	_check(_near(NightLight.amount(0.25 + 0.016), NightLight.amount(0.75 - 0.016), 1e-5), "dawn mirrors dusk (the sun's height decides)")

func _test_scale() -> void:
	_check(_near(NightLight.scale(1.4, 1.4, 1.0, 0.3), 0.3), "a night as bright as noon comes down to the level, 0.3")
	_check(_near(NightLight.scale(1.4, 0.7, 1.0, 0.3), 0.6), "a night already at half of noon is scaled by 0.6 to reach 0.3")
	_check(_near(NightLight.scale(1.4, 0.2, 1.0, 0.3), 1.0), "a night darker than the level is never brightened")
	_check(_near(NightLight.scale(1.4, 1.4, 1.0, 0.0), 1.0), "Original (level 0) changes nothing")
	_check(_near(NightLight.scale(1.4, 1.4, 0.0, 0.3), 1.0), "by day nothing changes")
	_check(_near(NightLight.scale(1.4, 1.4, 0.5, 0.3), 0.65), "half way into the night, half way down")
	_check(_near(NightLight.sky_scale(0.25), pow(0.25, 0.75)) and _near(NightLight.sky_scale(1.0), 1.0), "the sky, the fog and the clouds take k^0.75")
	var c := NightLight.scaled(Color(0.5, 0.6, 0.8, 1.0), 0.5)
	_check(_near(c.r, 0.25) and _near(c.b, 0.4) and _near(c.a, 1.0), "a scaled colour keeps its alpha")
	_check(_near(NightLight.level(0), 0.0) and _near(NightLight.level(1), 0.5) and _near(NightLight.level(2), 0.3),
		"the Night Darkness row: Original 0, Dim 0.5, Dark 0.3")

## What a scene's light comes to: an object (ObjectLight.shade on a mid
## texel, N.L 0.7) and the terrain (TerrainLight.lit, N.L 0.7) under `st`
## with the night's k as World3D applies it.
func _scene_light(st: DayCycle.State, k: float) -> Array:
	var amb := NightLight.scaled(st.object_ambient, k)
	var dif := NightLight.scaled(st.diffuse, k)
	var cols := ObjectLight.light_colors(dif, amb, true)
	var a: Vector3 = cols["ambient"]
	var d: Vector3 = cols["diffuse"]
	var obj := 0.0
	for i in range(3):
		obj += ObjectLight.shade(0.4, 0.6, ObjectLight.OBJECT_COLOR, a[i], d[i], 0.7)
	var t := TerrainLight.lit(0.7, Color(1, 1, 1), st.diffuse, st.terrain_ambient, k)
	return [obj / 3.0, (t.r + t.g + t.b) / 3.0]

## The k World3D computes for a record at a phase and a level.
func _k(rec: EnvironmentReader.Record, phase: float, lvl: float) -> float:
	var st := DayCycle.targets(rec, phase)
	return NightLight.scale(NightLight.noon_metric(rec), NightLight.light_metric(DayCycle._clamp01(st.diffuse), DayCycle._clamp01(st.object_ambient)),
		NightLight.amount(phase), lvl)

## REGRESSION: night stays bright -> FAIL.
func _check_dark_night(rec: EnvironmentReader.Record, label: String, retail_bright: bool) -> void:
	var noon := DayCycle.targets(rec, _phase(12, 0))
	for when in [[23, 0], [2, 0]]:
		var ph := _phase(when[0], when[1])
		var st := DayCycle.targets(rec, ph)
		for f in ["diffuse", "object_ambient", "terrain_ambient"]:
			st.set(f, DayCycle._clamp01(st.get(f)))
		var lit_noon := _scene_light(noon, 1.0)
		var lit_dark := _scene_light(st, _k(rec, ph, NightLight.level(2)))
		var lit_orig := _scene_light(st, _k(rec, ph, NightLight.level(0)))
		print("MEASURED %s %02d:00 objects %.3f / noon %.3f (Original %.3f); terrain %.3f / noon %.3f (Original %.3f)" % [
			label, when[0], lit_dark[0], lit_noon[0], lit_orig[0], lit_dark[1], lit_noon[1], lit_orig[1]])
		_check(lit_dark[0] < 0.45 * lit_noon[0], "%s at %02d:00, Dark: the objects' light is well below noon's (%.3f against %.3f)" % [label, when[0], lit_dark[0], lit_noon[0]])
		_check(lit_dark[1] < 0.45 * lit_noon[1], "%s at %02d:00, Dark: the terrain's light is well below noon's (%.3f against %.3f)" % [label, when[0], lit_dark[1], lit_noon[1]])
		if retail_bright:
			_check(lit_orig[1] > 0.8 * lit_noon[1], "%s at %02d:00, Original: retail's own keys leave the terrain near noon's light (%.3f against %.3f) -- why the OURS row exists" % [label, when[0], lit_orig[1], lit_noon[1]])

func _test_regression_synthetic() -> void:
	# A night as bright as noon's (the shape of environment 23's terrain).
	var rec := _record(Color(0.72, 0.72, 0.72), Color(0.70, 0.74, 0.76))
	_check_dark_night(rec, "synthetic bright night", true)

## On the box's Map.pk2: Jangan (environment 15) and the Bandit's Mountain
## Stronghold area (environment 23, `Env21`, regions 91/160 and around).
func _test_regression_real() -> void:
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
	var bytes := AssetSource.read_bytes("environment.ifo", archive)
	var table := EnvironmentReader.parse(bytes) if not bytes.is_empty() else null
	_check(table != null, "Map.pk2's environment.ifo parses")
	if table == null:
		return
	var by_key := {}
	for r in table.records:
		by_key[r.key] = r
	_check(by_key.has(15) and by_key.has(23), "environments 15 and 23 are there")
	if by_key.has(15):
		_check_dark_night(by_key[15], "Jangan (env 15)", false)
	if by_key.has(23):
		var rec: EnvironmentReader.Record = by_key[23]
		_check_dark_night(rec, "Bandit (env 23 %s)" % rec.name1, true)
		var mid := DayCycle.targets(rec, 0.0)
		print("MEASURED env 23 at 00:00 of the sky: diffuse %s object ambient %s terrain ambient %s sky top %s sky bottom %s fog %s" % [
			mid.diffuse, mid.object_ambient, mid.terrain_ambient, mid.sky_top, mid.sky_bottom, mid.fog])

## World3D's push on a bare World3D: the scaled light reaches the objects'
## and the terrain's globals, the light and the ambient; the portrait's
## channels stay the zone's own.
func _test_world_push() -> void:
	var world_script := load("res://scripts/World3D.gd") as GDScript
	_check(world_script != null and world_script.can_instantiate(), "World3D compiles")
	if world_script == null:
		return
	var world: Node = world_script.new()
	var light := DirectionalLight3D.new()
	var we := WorldEnvironment.new()
	we.environment = Environment.new()
	world.set("directional_light", light)
	world.set("world_environment", we)
	var o := VideoOptions.new()
	VideoOptions.set_row(o.current(), VideoOptions.SHADOW, 2)
	world.set("_video", o)
	var rec := _record(Color(0.72, 0.72, 0.72), Color(0.70, 0.74, 0.76))
	world.set("_env_record", rec)
	var cyc := DayCycle.new()
	cyc.set_record(rec)
	for when in [[12, 0], [23, 0]]:
		var ph := _phase(when[0], when[1])
		world.set("_env_time", ph)
		cyc.snap()
		var st := cyc.step(ph, 0.0)
		world.call("_day_push", st, false)
		var k: float = world.get("_night_k")
		print("World push %02d:00: k %.3f obj ambient %s terrain night %.3f light %s ambient %s" % [
			when[0], k, ObjectLight.current_ambient, TerrainLight.current_night, light.light_color, we.environment.ambient_light_color])
		if when[0] == 12:
			_check(_near(k, 1.0) and _near(TerrainLight.current_night, 1.0), "noon: no night scale")
			_check(_near(ObjectLight.current_ambient.x, 0.72, 1e-3), "noon: the objects' ambient is channel 3 (%.3f)" % ObjectLight.current_ambient.x)
		else:
			_check(k < 0.5, "23:00: the night's k is applied (%.3f)" % k)
			_check(_near(ObjectLight.current_ambient.x, st.object_ambient.r * k, 1e-3) and _near(ObjectLight.current_diffuse.x, st.diffuse.r * k * ObjectLight.diffuse_scale(true), 1e-3),
				"23:00: the objects' and characters' globals carry k (ambient %.3f, diffuse %.3f)" % [ObjectLight.current_ambient.x, ObjectLight.current_diffuse.x])
			_check(_near(TerrainLight.current_night, k, 1e-4), "23:00: the terrain's srr_terrain_night is k")
			_check(_near(light.light_color.r, st.diffuse.r * k, 1e-3) and _near(we.environment.ambient_light_color.r, st.object_ambient.r * k, 1e-3),
				"23:00: the directional light and the ambient carry k")
			var chans: Array = world.get("_object_light_channels")
			_check(_near((chans[1] as Color).r, st.object_ambient.r, 1e-4), "the portrait's channels stay the zone's own")
	# Original: nothing scaled.
	VideoOptions.set_row(o.current(), VideoOptions.NIGHT, 0)
	world.call("_day_push", cyc.state, false)
	_check(_near(float(world.get("_night_k")), 1.0) and _near(TerrainLight.current_night, 1.0), "Night Darkness Original: k 1 at 23:00")
	# The front end's fixed hour keeps retail's values.
	VideoOptions.set_row(o.current(), VideoOptions.NIGHT, 2)
	world.set("_env_fixed_phase", _phase(23, 0))
	world.call("_day_push", cyc.state, false)
	_check(_near(float(world.get("_night_k")), 1.0), "the front end's fixed hour is not darkened")
	world.set("_env_fixed_phase", -1.0)
	TerrainLight.set_light(Color(1, 1, 1), Color(0, 0, 0), Color(0, 0, 0), 1.0)
	light.free()
	we.free()
	world.free()

func _test_terrain_shader() -> void:
	var code := TerrainLight.shader_code(false, false)
	var clamp_at := code.find("clamp(COLOR.r * srr_terrain_diffuse.rgb")
	var night_at := code.find("lit *= srr_terrain_night.rgb")
	_check(clamp_at >= 0 and night_at > clamp_at, "the terrain shader scales the lit colour by srr_terrain_night after retail's clamp")
	var lit := TerrainLight.lit(0.7, Color(1, 1, 1), Color(0.6, 0.6, 0.6), Color(0.8, 0.8, 0.8), 0.3)
	_check(_near(lit.r, 0.3), "a saturated night (0.7 x 0.6 + 0.8 > 1) still darkens: 1 x 0.3 (got %.3f)" % lit.r)
	_check(ObjectLight.SHADER_FN.contains("global uniform vec4 srr_obj_ambient") and ObjectLight.SHADER_FN.contains("srr_obj_diffuse.rgb"),
		"every object and character shader reads the two scaled globals")
	var catcher := ShadowCatcher.material()
	ShadowCatcher.set_strength(0.0)
	_check(_near(float(catcher.get_shader_parameter("k")), 1.0), "shadow strength 0: the catcher darkens nothing")
	ShadowCatcher.set_strength(1.0)
	_check(_near(float(catcher.get_shader_parameter("k")), ShadowCatcher.K_LINEAR), "strength 1: the fitted K_LINEAR")

func _test_shadow_light() -> void:
	var noon: Array = NightLight.shadow_light(_phase(12, 0), 0)
	var n_dir: Vector3 = noon[0]
	_check(n_dir.y > 0.999 and _near(float(noon[1]), 1.0), "noon: the shadow light stands overhead (short shadows), full strength")
	var morning: Array = NightLight.shadow_light(_phase(8, 0), 0)
	var evening: Array = NightLight.shadow_light(_phase(17, 0), 0)
	var m_dir: Vector3 = morning[0]
	var e_dir: Vector3 = evening[0]
	_check(m_dir.x > 0.5 and e_dir.x < -0.5, "08:00 the light is in the east (+x), 17:00 in the west (-x)")
	var m_len := 1.0 / tan(asin(m_dir.y))
	var e_len := 1.0 / tan(asin(e_dir.y))
	print("shadow length per unit of height: 08:00 %.2f, 12:00 %.2f, 17:00 %.2f" % [m_len, 1.0 / tan(asin(n_dir.y)), e_len])
	_check(m_len > 0.95 and e_len > 1.4 and 1.0 / tan(asin(n_dir.y)) < 0.05,
		"long shadows morning and evening (08:00 is the sky's 09:00, the sun 45 degrees up: as long as the body is tall; 17:00 the sky's 15:45, 34 degrees: 1.5x), none at noon")
	var dawn: Array = NightLight.shadow_light(0.251, 0)
	_check(_near(asin((dawn[0] as Vector3).y), NightLight.SHADOW_MIN_ELEVATION, 1e-4), "at sunrise the light is held at 15 degrees (shadows 3.7 heights long, not endless)")
	_check(float(dawn[1]) < 0.5, "and the sun's shadows are fading in")
	var night: Array = NightLight.shadow_light(_phase(0, 0), 0)
	var night_dir: Vector3 = night[0]
	_check(night_dir.is_equal_approx(NightLight.clamp_elevation(DayCycle.moon_direction(_phase(0, 0)))) and _near(float(night[1]), NightLight.MOON_SHADOW_STRENGTH),
		"midnight: the moon casts, at MOON_SHADOW_STRENGTH")
	var no_moon: Array = NightLight.shadow_light(_phase(0, 0), 29)
	_check(_near(float(no_moon[1]), 0.0), "no moon (day 29 on): no night shadows")
	var dusk_gap: Array = NightLight.shadow_light(0.77, 0)
	_check(_near(float(dusk_gap[1]), 0.0), "between sunset and moonrise both are faded out (the source changes unseen)")
	# The step threshold.
	var a := NightLight.shadow_light(0.5, 0)[0] as Vector3
	var b := NightLight.shadow_light(0.5 + 0.2 / 360.0, 0)[0] as Vector3
	var c := NightLight.shadow_light(0.5 + 0.6 / 360.0, 0)[0] as Vector3
	_check(not NightLight.should_retarget(a, b) and NightLight.should_retarget(a, c), "the target moves only in steps of 0.5 degrees")
	# The glide: eases, then settles exactly.
	var cur := Vector3(1, 1, 0).normalized()
	var tgt := Vector3(0, 1, 0)
	var g: Array = NightLight.glide(cur, tgt, 0.1, 1.0)
	var moved := rad_to_deg(cur.angle_to(g[0]))
	_check(not bool(g[1]) and moved > 7.0 and moved < 11.0, "one 0.1 s frame glides a fifth of 45 degrees (%.2f)" % moved)
	var steps := 0
	while not bool(g[1]) and steps < 1000:
		g = NightLight.glide(g[0], tgt, 1.0 / 60.0, 1.0)
		steps += 1
	_check(bool(g[1]) and (g[0] as Vector3).is_equal_approx(tgt), "it settles on the target (%d frames)" % steps)
	var jump: Array = NightLight.glide(cur, tgt, 0.016, 0.0)
	_check(bool(jump[1]) and (jump[0] as Vector3).is_equal_approx(tgt), "a light at strength 0 takes the target at once")
	var basis := NightLight.light_basis(Vector3(0.6, 0.8, 0.0))
	_check(basis.z.is_equal_approx(Vector3(0.6, 0.8, 0.0)), "the light's basis z is the direction to the light (it shines along -z)")
	_check(NightLight.light_basis(Vector3.UP).z.is_equal_approx(Vector3.UP), "overhead is a valid basis (up is +z)")

## World3D's shadow light on a bare World3D: the row on turns the light and
## the terrain's N.L keeps the scene light; the row off restores it.
func _test_world_shadow() -> void:
	var world_script := load("res://scripts/World3D.gd") as GDScript
	var world: Node = world_script.new()
	var light := DirectionalLight3D.new()
	var scene_basis := Basis.from_euler(Vector3(-0.8, 0.6, 0.0))
	light.basis = scene_basis
	world.add_child(light)
	world.set("directional_light", light)
	var o := VideoOptions.new()
	VideoOptions.set_row(o.current(), VideoOptions.SHADOW, 2)
	world.set("_video", o)
	world.call("_sun_shadow_target", _phase(8, 0))
	var to_light := light.basis.z
	var want: Vector3 = NightLight.shadow_light(_phase(8, 0), 0)[0]
	_check(to_light.is_equal_approx(want), "the row on: the light turns to the 08:00 sun (%s)" % str(to_light))
	var fixed: Vector3 = world.call("_fixed_to_light")
	_check(fixed.is_equal_approx(scene_basis.z), "the terrain's N.L keeps the scene's own light")
	world.call("_sun_shadow_target", _phase(8, 0) + 0.1 / 360.0)
	_check(bool(world.get("_sun_shadow_settled")), "a 0.1 degree move sets no new target")
	world.call("_sun_shadow_target", _phase(9, 0))
	_check(not bool(world.get("_sun_shadow_settled")), "an hour later a new target")
	for i in range(240):
		world.call("_sun_shadow_glide", 1.0 / 60.0)
	_check(bool(world.get("_sun_shadow_settled")) and light.basis.z.is_equal_approx(NightLight.shadow_light(_phase(9, 0), 0)[0]),
		"the light glides there and stops")
	VideoOptions.set_row(o.current(), VideoOptions.SUN_SHADOWS, 0)
	world.call("_sun_shadow_target", _phase(9, 0))
	_check(light.basis.z.is_equal_approx(scene_basis.z) and _near(ShadowCatcher.strength, 1.0), "the row off: the scene's fixed light at full strength")
	world.free()

func _initialize() -> void:
	_test_amount()
	_test_scale()
	_test_terrain_shader()
	_test_regression_synthetic()
	_test_regression_real()
	_test_shadow_light()
	_test_world_push()
	_test_world_shadow()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
