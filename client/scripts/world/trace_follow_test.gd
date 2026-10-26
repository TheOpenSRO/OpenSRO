extends SceneTree

## Round 832: TraceFollow, the original server's trace walker (0x4ae3d0,
## 0x4b0490, READ). Positions are synthetic; every constant is the binary's.
##   godot4 --headless --path client --script res://scripts/world/trace_follow_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	# Two player bodies of BCRadius 5: stop 60, restart 90.
	var b := TraceFollow.bands(5, 5)
	_check(b == Vector2i(60, 90), "stop = both radii + 50, walk again beyond both radii + 80 (%s)" % str(b))
	var stop := b.x
	var restart := b.y
	var own := Vector3(100, 0, 100)
	# Within the walk-again distance nothing is sent, however far from stop.
	_check(TraceFollow.step(own, own + Vector3(90, 0, 0), Vector3.ZERO, 5, 5, stop, restart)["do"] == "none",
		"at exactly 90 (the restart distance) nothing is sent")
	_check(TraceFollow.step(own, own + Vector3(61, 0, 0), Vector3.ZERO, 5, 5, stop, restart)["do"] == "none",
		"at 61, beyond the stop distance but within restart, nothing")
	# Beyond it: a walk that ends `stop` short of the target, on the line.
	var w := TraceFollow.step(own, own + Vector3(0, 0, 200), Vector3.ZERO, 5, 5, stop, restart)
	_check(w["do"] == "walk" and (w["point"] as Vector3).is_equal_approx(own + Vector3(0, 0, 140)),
		"at 200 a walk to 60 short of it (%s)" % str(w.get("point")))
	# A height difference: the step is the 3-D direction's x/z times (dist - stop), y kept.
	var up := TraceFollow.step(own, own + Vector3(0, 30, 160), Vector3.ZERO, 5, 5, stop, restart)
	var dist := Vector3(0, 30, 160).length()
	_check(up["do"] == "walk" and is_equal_approx((up["point"] as Vector3).z - own.z, 160.0 / dist * (dist - 60.0))
		and is_equal_approx((up["point"] as Vector3).y, own.y), "on a slope the walk keeps its own height and the 3-D direction's x/z")
	# Already walking toward it within 15 degrees: left alone; beyond: re-aimed.
	var ahead := Vector3(0, 0, 1)
	var t14 := own + Vector3(sin(deg_to_rad(14.0)), 0, cos(deg_to_rad(14.0))) * 300.0
	var t16 := own + Vector3(sin(deg_to_rad(16.0)), 0, cos(deg_to_rad(16.0))) * 300.0
	_check(TraceFollow.step(own, t14, ahead, 5, 5, stop, restart)["do"] == "none", "a walk heading 14 degrees off goes on")
	_check(TraceFollow.step(own, t16, ahead, 5, 5, stop, restart)["do"] == "walk", "16 degrees off: a new walk")
	# Too far: the walker lets go.
	_check(TraceFollow.step(own, own + Vector3(1000, 0, 0), Vector3.ZERO, 5, 5, stop, restart)["do"] == "walk",
		"at exactly 1000 it still walks")
	_check(TraceFollow.step(own, own + Vector3(1000.5, 0, 0), Vector3.ZERO, 5, 5, stop, restart)["do"] == "end",
		"beyond 1000 (3-D) it lets go")
	# Inside the other body (closer than 10 - 4): a step back by the radii, no run.
	var back := TraceFollow.step(own, own + Vector3(5, 0, 0), Vector3.ZERO, 5, 5, stop, restart)
	_check(back["do"] == "back" and (back["point"] as Vector3).is_equal_approx(own - Vector3(10, 0, 0)),
		"overlapping: a step straight back by both radii (%s)" % str(back.get("point")))
	_check(TraceFollow.step(own, own + Vector3(6, 0, 0), Vector3.ZERO, 5, 5, stop, restart)["do"] == "none",
		"at exactly radii - 4 it stays")
	# The target test.
	_check(TraceFollow.target_valid(true, 1, 0x6461, 0x6562), "a living player one region over")
	_check(not TraceFollow.target_valid(false, 1, 0x6461, 0x6461), "not a monster or NPC (IsPC)")
	_check(not TraceFollow.target_valid(true, 2, 0x6461, 0x6461) and not TraceFollow.target_valid(true, 3, 0x6461, 0x6461),
		"not a dead one (life state 2), nor state 3")
	_check(not TraceFollow.target_valid(true, 1, 0x6461, 0x6463), "not two regions away")
	_check(not TraceFollow.target_valid(true, 1, 0x6461, 0x8001) and TraceFollow.target_valid(true, 1, 0x8001, 0x8005),
		"not across field and dungeon; any two dungeon words pass")
	print("FAILURES: %d" % _failures if _failures > 0 else "ALL PASS")
	quit(1 if _failures > 0 else 0)
