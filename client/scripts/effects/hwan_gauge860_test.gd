extends SceneTree

## HwanGauge (round 860): the hwan count while violet orbs fly -- 0x304E kind
## 4's two paths (c:0x8a70d0) and FUN_009d4ad0's arrival step -- the kind-4
## payload, and ExpOrbs' per-kind arrival and drop. Pure; synthetic effects.
## `godot4 --headless --path client --script res://scripts/effects/hwan_gauge860_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	process_frame.connect(_run, CONNECT_ONE_SHOT)

func _run() -> void:
	# --- the payload ---------------------------------------------------------
	var p := PackedByteArray([4, 3, 0x04, 0x03, 0x02, 0x01])
	var h := RewardNoticeNet.decode_hwan(p)
	_check(h.size() == 2 and int(h[0]) == 3 and int(h[1]) == 0x01020304, "0x304E kind 4: u8 count, u32 source (%s)" % str(h))
	_check(RewardNoticeNet.decode_hwan(p.slice(0, 5)).is_empty(), "a short kind 4 decodes to nothing")
	_check(RewardNoticeNet.decode_gold(p).is_empty() and RewardNoticeNet.decode_hwan(PackedByteArray([1, 0, 0, 0, 0, 0, 0, 0, 0, 0])).is_empty(),
		"kind 1 and kind 4 do not read each other")

	# --- a kill's rise: the orbs light the gauge one by one --------------------
	var g := HwanGauge.new()
	g.told(1)
	var r := g.on_count(3, true)
	_check(int(r["fly"]) == 2 and not bool(r["show"]) and g.display == 1 and g.pending == 2,
		"a rise of 2 from a body in view: 2 violet orbs, the display held at 1")
	_check(not g.told(3) and g.display == 1, "an attack result's count does not light them early")
	_check(g.arrive() == 2 and g.pending == 1, "the first arrival: 2")
	_check(g.arrive() == 3 and g.pending == 0, "the last: the real count, 3")
	_check(g.arrive() == 3, "an arrival with nothing pending: the real count")

	# --- no source / a fall: shown at once, the flight dropped ----------------
	r = g.on_count(5, false)
	_check(bool(r["reset"]) and bool(r["show"]) and g.display == 5 and g.pending == 0, "no body in view: shown at once (a potion)")
	g.on_count(5, true)
	r = g.on_count(0, false)
	_check(not bool(r["reset"]) and g.display == 0, "the activation's 5 -> 0 with 5 shown: only FUN_00778ae0(0, 0)")
	g.told(2)
	g.on_count(4, true)
	r = g.on_count(1, false)
	_check(bool(r["reset"]) and g.pending == 0 and g.display == 1, "a fall while orbs fly: they are dropped, 1 shown")
	g.on_count(3, true)
	_check(g.arrive(5) == 3 and g.pending == 0, "FUN_009d4ad0 with n above pending: the real count")

	# --- ExpOrbs: the arrival per kind, the violet drop ------------------------
	var orbs := ExpOrbs.new()
	var root := Node3D.new()
	get_root().add_child(root)
	var player := Node3D.new()
	root.add_child(player)
	player.global_position = Vector3(0, 0, 0)
	orbs.parent = root
	var kinds: Array = []
	orbs.arrived = func(k: int) -> void: kinds.append(k)
	var seq := [0]
	orbs.rand = func() -> int:
		seq[0] += 1
		return 0
	var n := orbs.launch(Vector3(3, 0, 0), [1, 0, 2, 0], player)
	_check(n == 3 and orbs.live_of(ExpOrbs.KIND_HWAN) == 2, "launch: 1 EXP and 2 violet orbs")
	_check(orbs.drop_kind(ExpOrbs.KIND_HWAN) == 2 and orbs.live() == 1, "drop_kind deletes the violet ones only")
	for _i in 400:
		orbs.tick(0.016)
	_check(orbs.live() == 0 and kinds == [ExpOrbs.KIND_EXP], "the EXP orb arrives and is handed over (%s)" % str(kinds))
	var cos := Node3D.new()
	root.add_child(cos)
	cos.global_position = Vector3(-5, 0, 2)
	_check(orbs.launch(Vector3(3, 0, 0), [0, 0, 0, 2], player, cos) == 2, "kind 3 flies to the COS")
	_check(orbs.launch(Vector3(3, 0, 0), [0, 0, 0, 2], player, null) == 0, "kind 3 with no COS body: none")
	for _i in 400:
		orbs.tick(0.016)
	_check(kinds.count(ExpOrbs.KIND_COS) == 2, "both COS orbs arrive")
	root.queue_free()
	_finish()

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)
