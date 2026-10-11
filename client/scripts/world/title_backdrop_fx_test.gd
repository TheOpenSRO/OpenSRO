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
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
