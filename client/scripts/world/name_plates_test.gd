extends SceneTree

## When a name plate shows (round 673, NamePlates). Run headless on the render
## box: `client/tools/remote_godot.sh tests`. No game data: plain nodes.
##
## Holds the rule to retail's (READ: FUN_009d0a80 returns at 0x9d0ac3 when
## `300.0 <= object+0x24c`, the object's distance from the local PLAYER,
## written at 0x9d6f7e): shown strictly within 300 of the player, in 3D, and
## the camera has no part in it. Holds the sweep to its schedule (OURS): a new
## plate is hidden until measured and measured on the next step, every plate
## is re-tested within SWEEP_FRAMES steps however many there are, a freed
## plate is dropped, and a range change re-tests them all at once.
##
## NEGATIVE, on the base (4104a11): NamePlates does not exist -- the suite does
## not compile, and the plates hid by their distance from the camera (80).

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	# The root is in the tree from the first frame on; an owner added before
	# it is not, and the sweep measures only owners in the tree.
	await process_frame
	_test_rule()
	await _test_sweep()
	await _test_many()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

func _test_rule() -> void:
	_check(NamePlates.RANGE == 300.0, "the range is retail's 300 (0xd85224)")
	var p := Vector3(100.0, 5.0, -40.0)
	_check(NamePlates.shown(p, p), "the player's own plate (distance 0) shows")
	_check(NamePlates.shown(p + Vector3(299.9, 0.0, 0.0), p), "299.9 away shows")
	_check(not NamePlates.shown(p + Vector3(300.0, 0.0, 0.0), p), "300 away does not (0x9d0ac3 returns at 300)")
	_check(not NamePlates.shown(p + Vector3(0.0, 0.0, 300.1), p), "300.1 away does not")
	# 3D: +0x24c sums the squared x, y and z differences.
	_check(not NamePlates.shown(p + Vector3(200.0, 230.0, 0.0), p), "a height difference counts (200 across, 230 up: 304.8)")
	_check(NamePlates.shown(p + Vector3(200.0, 220.0, 0.0), p), "and 200 across, 220 up (297.3) shows")
	_check(NamePlates.shown(p + Vector3(50.0, 0.0, 0.0), p, 80.0) and not NamePlates.shown(p + Vector3(90.0, 0.0, 0.0), p, 80.0),
		"a narrower range from the debug slider applies")

## An owner with a plate on it, at `at`.
func _owner_with_plate(parent: Node, at: Vector3) -> Array:
	var owner := Node3D.new()
	owner.position = at
	parent.add_child(owner)
	var label := Label3D.new()
	label.position = Vector3(0.0, 18.0, 0.0)
	owner.add_child(label)
	return [owner, label]

func _test_sweep() -> void:
	var holder := Node3D.new()
	root.add_child(holder)
	var sweep := NamePlates.Sweep.new()
	var player := Vector3(0.0, 0.0, 0.0)
	var near: Array = _owner_with_plate(holder, Vector3(120.0, 0.0, 120.0))
	var far: Array = _owner_with_plate(holder, Vector3(250.0, 0.0, 250.0))
	sweep.add(near[1])
	sweep.add(far[1])
	_check(not (near[1] as Node3D).visible and not (far[1] as Node3D).visible, "a new plate is hidden until it is measured")
	var tested := sweep.step(player)
	_check(tested == 2, "the next step measures both new plates (%d)" % tested)
	_check((near[1] as Node3D).visible, "a plate 170 from the player shows")
	_check(not (far[1] as Node3D).visible, "a plate 354 from the player does not")
	# The camera does not enter into it: nothing here has one, and the rule
	# reads only the owner and the player. The player walks up to the far one.
	player = Vector3(200.0, 0.0, 200.0)
	sweep.step(player)
	_check((far[1] as Node3D).visible, "the far plate shows once the player is within 300 (71 away)")
	_check((near[1] as Node3D).visible, "and the near one still shows (113 away)")
	# A plate made before its owner exists waits, then is measured.
	var loose := Label3D.new()
	sweep.add(loose)
	sweep.step(player)
	_check(not loose.visible and sweep.size() == 3, "a plate with no owner yet waits, hidden")
	var late := Node3D.new()
	late.position = Vector3(210.0, 0.0, 200.0)
	holder.add_child(late)
	late.add_child(loose)
	sweep.step(player)
	_check(loose.visible, "and shows once hung on an owner within range")
	# A freed plate is dropped.
	(near[0] as Node).free()
	for i in range(NamePlates.SWEEP_FRAMES + 1):
		sweep.step(player)
	_check(sweep.size() == 2, "a freed plate is dropped (%d left)" % sweep.size())
	# A range change re-tests every plate on the next step.
	sweep.reach = 5.0
	sweep.retest_all()
	sweep.step(player)
	_check(not (far[1] as Node3D).visible and not loose.visible, "a range change applies to every plate on the next step")
	holder.free()
	await process_frame

## A crowd: every plate re-tested within SWEEP_FRAMES steps.
func _test_many() -> void:
	var holder := Node3D.new()
	root.add_child(holder)
	var sweep := NamePlates.Sweep.new()
	var labels: Array = []
	for i in range(1200):
		var pair: Array = _owner_with_plate(holder, Vector3(float(i % 40) * 5.0, 0.0, float(i / 40) * 5.0))
		labels.append(pair[1])
		sweep.add(pair[1])
	sweep.step(Vector3.ZERO)
	var shown_before := 0
	for label in labels:
		if (label as Node3D).visible:
			shown_before += 1
	# Everything within 300 of (0,0,0) shows; the player moves far off.
	var far_player := Vector3(5000.0, 0.0, 5000.0)
	var per := 0
	for i in range(NamePlates.SWEEP_FRAMES):
		per = maxi(per, sweep.step(far_player))
	var still := 0
	for label in labels:
		if (label as Node3D).visible:
			still += 1
	_check(shown_before > 0 and still == 0,
		"every one of 1,200 plates is re-tested within %d steps (%d shown, %d left after)" % [NamePlates.SWEEP_FRAMES, shown_before, still])
	_check(per <= int(ceil(1200.0 / NamePlates.SWEEP_FRAMES)) + 1, "a step tests about a sixth of them (%d)" % per)
	holder.free()
	await process_frame
