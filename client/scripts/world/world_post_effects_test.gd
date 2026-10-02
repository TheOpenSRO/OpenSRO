extends SceneTree

## WorldPostEffects (round 693): the world's SSAO and glow are off unless
## asked for, and on when the Options window asks.
##
## `godot4 --headless --path client --script res://scripts/world/world_post_effects_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	_check(not WorldPostEffects.SSAO_DEFAULT and not WorldPostEffects.GLOW_DEFAULT, "both default off")
	var env := Environment.new()
	env.ssao_enabled = true
	env.glow_enabled = true
	WorldPostEffects.apply(env)
	_check(not env.ssao_enabled and not env.glow_enabled, "apply() with the defaults turns both off")
	WorldPostEffects.apply(env, true, false)
	_check(env.ssao_enabled and not env.glow_enabled, "SSAO on alone")
	WorldPostEffects.apply(env, false, true)
	_check(not env.ssao_enabled and env.glow_enabled, "glow on alone")
	WorldPostEffects.apply(null)
	_check(true, "a null environment is ignored")

	# The world scene's own environment, as the engine loads it (the title's
	# backdrop and every world entry): both off before any script runs.
	var scene := load("res://scenes/World3D.tscn") as PackedScene
	var we_env: Environment = null
	var state := scene.get_state()
	for i in state.get_node_count():
		if state.get_node_type(i) == &"WorldEnvironment":
			for p in state.get_node_property_count(i):
				if state.get_node_property_name(i, p) == &"environment":
					we_env = state.get_node_property_value(i, p) as Environment
	_check(we_env != null, "World3D.tscn has a WorldEnvironment with an environment")
	if we_env != null:
		_check(not we_env.ssao_enabled, "World3D.tscn's environment has SSAO off")
		_check(not we_env.glow_enabled, "World3D.tscn's environment has glow off")
	# And World3D applies the choice before its title branch.
	var src := FileAccess.get_file_as_string("res://scripts/World3D.gd")
	var ready_at := src.find("func _ready() -> void:")
	var apply_at := src.find("WorldPostEffects.apply(world_environment.environment", ready_at)
	var title_at := src.find("if title_mode:", ready_at)
	_check(ready_at >= 0 and apply_at > ready_at and apply_at < title_at,
		"World3D._ready applies WorldPostEffects before the title branch")

	# The sun under Forward+ (the user's "Raise it to match"): scaled only
	# where Forward+ runs; this headless run is neither, so the factor is 1 --
	# Compatibility's look is never touched.
	_check(WorldPostEffects.FORWARD_PLUS_SUN_SCALE > 1.0, "Forward+ raises the sun (x%.2f)" % WorldPostEffects.FORWARD_PLUS_SUN_SCALE)
	_check(is_equal_approx(WorldPostEffects.sun_scale(), 1.0), "the factor is 1 where Forward+ is not running (got %.2f)" % WorldPostEffects.sun_scale())
	var sun_at := src.find("directional_light.light_energy *= WorldPostEffects.sun_scale()", ready_at)
	_check(sun_at > ready_at and sun_at < title_at, "World3D._ready scales the sun before the title branch (the title and select backdrops too)")

	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES %d" % _failures)
	quit(1 if _failures > 0 else 0)
