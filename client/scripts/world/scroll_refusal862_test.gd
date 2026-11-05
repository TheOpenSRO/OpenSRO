extends SceneTree

## Round 862: what a return scroll's cast shows for the requests it refuses
## (server/internal/session/scrollhold.go, ScrollHoldGate). READ: a second
## scroll's 0x185d raises the warning banner and the system line (the
## category-1 case jumps to 0x7b8ccc), a reuse delay's 0x185b the system line
## only; the pick-up refused 0x4004 shows nothing. The results go through
## World3D's own handlers on a bare subclass (never game data).
## Run headless on the render box: `client/tools/remote_godot.sh tests`.

const ErrorText = preload("res://scripts/net/error_text.gd")

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	var watchdog := create_timer(60.0)
	watchdog.timeout.connect(func() -> void:
		print("FAIL the suite never reported (a script error stopped it)")
		quit(1))
	_test_rule()
	var world := _make_world()
	if world != null:
		await process_frame
		_test_world(world)
		world.queue_free()
		await process_frame
	print("scroll_refusal862_test: %s (%d failure(s))" % ["PASS" if _failures == 0 else "FAIL", _failures])
	quit(0 if _failures == 0 else 1)

func _test_rule() -> void:
	for code in [0x185d, 0x185f, 0x1875, 0x187a]:
		_check(ErrorText.scroll_banner(code), "0x%x raises the banner (0x7b8ccc)" % code)
	for code in [0x185b, 0x185e, 0x186a, 0x1885, 0x18fd, 0]:
		_check(not ErrorText.scroll_banner(code), "0x%x is the system line only (0x7b966d)" % code)
	_check(GroundItemsNet.ERR_REFUSED == 0x4004, "the held pick-up's code is 0x4004")

func _make_world() -> Node:
	var sub := GDScript.new()
	sub.source_code = "\n".join(PackedStringArray([
		"extends \"res://scripts/World3D.gd\"",
		"var banners: Array = []",
		"func _ready() -> void:",
		"\tpass",
		"func _physics_process(_delta: float) -> void:",
		"\tpass",
		"func _process(_delta: float) -> void:",
		"\tpass",
		"func _exit_tree() -> void:",
		"\tpass",
		"func _show_banner(kind: String, text: String) -> void:",
		"\tbanners.append([kind, text])",
		""]))
	_check(sub.reload() == OK and sub.can_instantiate(), "a subclass of World3D.gd compiles")
	var scene := load("res://scenes/World3D.tscn") as PackedScene
	if not sub.can_instantiate() or scene == null:
		return null
	var world: Node = scene.instantiate()
	world.set_script(sub)
	root.add_child(world)
	return world

func _refusal(code: int, error: String) -> UseItemNet.Result:
	var r := UseItemNet.Result.new()
	r.error = error
	r.code = code
	return r

func _test_world(world: Node) -> void:
	# A second scroll during the cast: the banner and the line, the same text.
	world._on_use_item_result(_refusal(0x185d, "another teleport is already working"))
	var banners: Array = world.banners
	_check(banners.size() == 1 and String(banners[0][0]) == "warning",
		"0x185d raises the warning banner (got %s)" % str(banners))
	var line := String(banners[0][1]) if banners.size() == 1 else ""
	_check(line != "" and world.log_text().contains(line), "and the same text is in the system log")
	# The reuse delay: the line only.
	world._on_use_item_result(_refusal(0x185b, "wait for the reuse delay"))
	_check(banners.size() == 1, "0x185b raises no banner")
	_check(world.log_text().contains("wait for the reuse delay"), "0x185b's line is in the system log")
	# A pick-up held by the cast: nothing shown.
	var before: String = world.log_text()
	var pick := GroundItemsNet.PickUpResult.new()
	pick.code = GroundItemsNet.ERR_REFUSED
	pick.ground_id = 41
	world._pending_pickup_id = 41
	world._pickup_inflight = true
	world._on_pick_up_result(pick)
	_check(world.log_text() == before, "a held pick-up writes no line")
	_check(banners.size() == 1, "and raises no banner")
	_check(not world._pickup_inflight and world._pending_pickup_id == -1, "and ends the pick (nothing in flight)")
	# Any other refusal still says why (the 2026-09-20 playtest rule).
	pick.code = GroundItemsNet.ERR_CANNOT_PICK
	world._on_pick_up_result(pick)
	_check(world.log_text() != before, "another pick-up refusal still writes its line")
