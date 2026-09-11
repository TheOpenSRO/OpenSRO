extends SceneTree

## Exercises LevelUpEffect's data-free logic (never real game data, per the
## project rule -- the real-mesh loading path is verified separately with a
## render-box run against a real Particles.pk2). Run headless:
## `godot4 --headless --path client --script res://scripts/effects/level_up_effect_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _approx(a: float, b: float, eps: float = 0.0001) -> bool:
	return absf(a - b) <= eps

func _init() -> void:
	# No particles archive -> no effect at all, rather than a fabricated one.
	_check(LevelUpEffect.create(null, 16.0) == null,
		"create() with no archive returns null (no fabricated visual)")

	# The easing helpers pin their endpoints and stay inside [0,1] and
	# monotonic across the range -- the scale envelope depends on both.
	_check(_approx(LevelUpEffect._ease_out(0.0), 0.0), "_ease_out(0) == 0")
	_check(_approx(LevelUpEffect._ease_out(1.0), 1.0), "_ease_out(1) == 1")
	_check(_approx(LevelUpEffect._ease_in(0.0), 0.0), "_ease_in(0) == 0")
	_check(_approx(LevelUpEffect._ease_in(1.0), 1.0), "_ease_in(1) == 1")
	_check(LevelUpEffect._ease_out(0.5) > 0.5, "_ease_out eases out (fast start)")
	_check(LevelUpEffect._ease_in(0.5) < 0.5, "_ease_in eases in (slow start)")

	var prev_out := -1.0
	var prev_in := -1.0
	var mono := true
	for i in range(21):
		var x := i / 20.0
		var o := LevelUpEffect._ease_out(x)
		var n := LevelUpEffect._ease_in(x)
		if o < prev_out - 0.0001 or n < prev_in - 0.0001:
			mono = false
		if o < 0.0 or o > 1.0 or n < 0.0 or n > 1.0:
			mono = false
		prev_out = o
		prev_in = n
	_check(mono, "easing helpers are monotonic and stay within [0,1]")

	# Endpoints clamp outside the unit range rather than blowing up.
	_check(_approx(LevelUpEffect._ease_out(2.0), 1.0), "_ease_out clamps above 1")
	_check(_approx(LevelUpEffect._ease_in(-1.0), 0.0), "_ease_in clamps below 0")

	# The real four core meshes are declared, each with a paired texture and a
	# full animation row -- guards against an accidental truncation of LAYERS.
	_check(LevelUpEffect.LAYERS.size() == 4, "four real mesh layers declared")
	var shapes_ok := true
	for row in LevelUpEffect.LAYERS:
		if row.size() != 7:
			shapes_ok = false
		elif not (row[0] as String).ends_with(".bms"):
			shapes_ok = false
		elif not (row[1] as String).ends_with(".ddj"):
			shapes_ok = false
		elif float(row[6]) < 0.0 or float(row[6]) > 1.0:
			shapes_ok = false
	_check(shapes_ok, "every layer is (mesh.bms, texture.ddj, + 5 anim fields, intensity in [0,1])")

	if _failures == 0:
		print("all LevelUpEffect tests passed")
	else:
		print("%d LevelUpEffect test(s) failed" % _failures)
	quit(1 if _failures > 0 else 0)
