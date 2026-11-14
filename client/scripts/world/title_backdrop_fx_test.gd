extends SceneTree

## Round 767: a title backdrop (World3D with title_mode, under the login,
## select and customize screens) never claims its viewport for EquipFx's
## batches. The select screen draws its characters in that same viewport, and
## the batches step only with a CrowdGpu (EquipFxBatch.step), which a backdrop
## has none of -- so their seal and plus particles were handed to batches that
## never drew (round 764's review F1 made the claim unconditional). Nor does a
## backdrop going away reset what a world in that viewport owns.
##
## `godot4 --headless --path client --script res://scripts/world/title_backdrop_fx_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	var src := FileAccess.get_file_as_string("res://scripts/World3D.gd")
	var ready_at := src.find("func _ready() -> void:")
	var claim_at := src.find("EquipFx.batch_viewport = get_viewport()", ready_at)
	var guard_at := src.rfind("if not title_mode:", claim_at)
	_check(ready_at >= 0 and claim_at > ready_at, "World3D._ready claims the viewport for the batches")
	_check(guard_at > ready_at and src.substr(guard_at, claim_at - guard_at).count("\n") == 1,
		"... only when it is not a title backdrop (the line right under `if not title_mode:`)")
	_check(src.count("EquipFx.batch_viewport = get_viewport()") == 1, "... and nowhere else")
	var exit_at := src.find("func _exit_tree() -> void:")
	var reset_at := src.find(".reset_world()", exit_at)
	var release_at := src.find("EquipFx.batch_viewport = null", exit_at)
	_check(exit_at >= 0 and reset_at > exit_at and release_at > reset_at, "World3D._exit_tree resets the batches and releases the viewport")
	var tail := src.substr(exit_at, release_at - exit_at)
	_check(tail.contains("if not title_mode and fx_vp != null and fx_vp.has_meta(EquipFx.DRIVER_META):")
		and tail.contains("if not title_mode and EquipFx.batch_viewport == fx_vp:"),
		"... neither when it is a title backdrop, which claimed nothing")
	_test_title_effects(src)
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

## Round 884 (the user: the intro "doesn't load any effects, especially around
## the teleporter"): the backdrop runs the scenery's effects as the world does
## -- the placed objects' ambient effects (WorldAmbientFx) every frame, the
## glow pass and the animated textures every tick. NEGATIVE: before round 884
## _title_physics ran only the sky, the map animations and the stream queue,
## and _process returned right after the night flag -- these checks fail there.
func _test_title_effects(src: String) -> void:
	var tp_at := src.find("func _title_physics(")
	var tp_end := src.find("\nfunc ", tp_at + 1)
	var tp := src.substr(tp_at, tp_end - tp_at)
	_check(tp_at >= 0 and tp.contains("_ambient_step(delta)"), "the title's tick runs the glow pass (_ambient_step)")
	_check(tp.contains("TexAni.tick(delta * 1000.0)"), "... and the animated textures (TexAni.tick)")
	var pr_at := src.find("func _process(_delta: float) -> void:")
	var night_at := src.find("_night_tick()", pr_at)
	var ret_at := src.find("return", night_at)
	var head := src.substr(night_at, ret_at - night_at)
	_check(pr_at >= 0 and head.contains("if title_mode:") and head.contains("_tick_world_fx(_delta)"),
		"the title's frame builds and steps the placed objects' effects before it returns (_tick_world_fx)")
	# An S_EffectCreate's host (World3D.title_effect_transform, READ FUN_009c4610):
	# its region's offset from the frame region, lo -> x, hi -> z, then the
	# world's z mirror; the angle in degrees turned as a placed object's yaw.
	var w: GDScript = load("res://scripts/World3D.gd")
	var cmd := IntroScript.Command.new()
	cmd.region_lo = 12
	cmd.region_hi = 34
	cmd.pos = Vector3(100, 5, 200)
	var frame := Vector2i(34, 11)
	var xf: Transform3D = w.call("title_effect_transform", cmd, frame)
	var expect: Vector3 = w.call("title_world_from_local", Vector3(100 + 1920, 5, 200))
	_check(xf.origin.is_equal_approx(expect), "an effect one region east (lo + 1) stands 1920 further along x (got %s, want %s)" % [xf.origin, expect])
	cmd.region_lo = 11
	cmd.region_hi = 33
	xf = w.call("title_effect_transform", cmd, frame)
	expect = w.call("title_world_from_local", Vector3(100, 5, 200 - 1920))
	_check(xf.origin.is_equal_approx(expect), "one region south (hi - 1) stands 1920 back along the region's z (got %s)" % xf.origin)
	_check(xf.basis.determinant() < 0.0, "the host carries the region group's mirror, as a placed object does")
	cmd.angle_deg = 90.0
	var turned: Transform3D = w.call("title_effect_transform", cmd, frame)
	var obj := Basis.from_scale(Vector3(1, 1, -1)) * Basis(Vector3.UP, NavGraph.godot_yaw(PI / 2.0))
	_check(turned.basis.is_equal_approx(obj), "an angle of 90 degrees is a placed object's yaw of pi/2")
