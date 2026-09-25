extends SceneTree

## A restored entry keeps the server's position (round 573). Run headless on
## the render box: `client/tools/remote_godot.sh tests`.
##
## The server's -persist-position reads back where a character last stood and
## answers it on OpEnterWorldResult with a trailing Restored byte
## (server/internal/session/world.go; WorldNet.EnterWorldResult.restored).
## Every other entry into a zone with a landing spot -- Jangan's
## ZONE_SPAWN_LOCAL, local (1002, 1020) of 97/168 -- is moved there by
## World3D._load_initial_region_neighborhood -> _place_at_zone_spawn, which
## would throw a restored Jangan position away. And /unstuck returned to the
## ENTRY point, which for a restored entry is the saved spot itself -- where a
## player may be wedged -- so it now lands at the zone's landing instead.
##
## The world is World3D.tscn with the script swapped for a subclass
## (height_retry_test.gd's pattern): _ready, the physics and input callbacks do
## nothing, so the scene's nodes answer every @onready path and nothing opens
## an archive or the network. Two methods are recorded rather than run:
## _reload_zone_assets (which would build the grid from the archives) and
## _place_at_region_local (which lands on a region's walkable graph); the
## recorder stands the player on the region-local point named in 97/168's
## frame, RegionGridState.frame_world -- the port of
## server/internal/worldmap.ToWorld, region y -> world X, region x -> world Z,
## Z mirrored (AGENTS.md) -- at y 0, so where it went is measurable.
##
## NEGATIVES: before round 573 the restored entry is moved to Jangan's landing
## spot (the recorder sees 97/168 (1002, 1020) and the player stands at its
## frame point, not at the server's), and a restored /unstuck returns to the
## saved spot. The non-restored rows are the probe: they pass before and
## after, so the recorder is reached and the rule is what moves the player.

var _failures := 0
## The NetClient autoload, looked up at run time: a --script suite compiles
## before the autoloads are registered, so the name is not an identifier here.
var _net: Node

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## World3D.gd names the NetClient autoload, which a --script suite registers
## only after _init (height_retry_test.gd's pattern).
func _initialize() -> void:
	var watchdog := create_timer(60.0)
	watchdog.timeout.connect(func() -> void:
		print("FAIL the suite never reported (a script error stopped it)")
		quit(1))
	# The root enters the tree only after _initialize returns.
	await process_frame
	var mapm_path := OS.get_environment("SRREVAMP_MAPM_PATH")
	# The QA path loads a fixed region instead of the server's zone; the rule
	# under test is the logged-in path.
	OS.unset_environment("SRREVAMP_MAPM_PATH")
	_net = root.get_node_or_null("NetClient")
	_check(_net != null, "the NetClient autoload is registered")
	if _net == null:
		print("%d FAILURES" % _failures)
		quit(1)
		return
	var saved_result = _net.get("last_enter_world_result")
	var saved_zone: String = _net.get("current_zone")
	var world := _make_world()
	if world != null:
		_test_entry(world)
		_test_unstuck(world)
		root.remove_child(world)
		world.free()
	_net.set("last_enter_world_result", saved_result)
	_net.set("current_zone", saved_zone)
	if mapm_path != "":
		OS.set_environment("SRREVAMP_MAPM_PATH", mapm_path)
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

func _make_world() -> Node:
	var sub := GDScript.new()
	sub.source_code = "\n".join(PackedStringArray([
		"extends \"res://scripts/World3D.gd\"",
		"var reloads: Array = []",
		"var placed: Array = []",
		"func _ready() -> void:",
		"\tpass",
		"func _physics_process(_delta: float) -> void:",
		"\tpass",
		"func _input(_event: InputEvent) -> void:",
		"\tpass",
		"func _unhandled_input(_event: InputEvent) -> void:",
		"\tpass",
		"func _exit_tree() -> void:",
		"\tpass",
		"func _reload_zone_assets(zone: String, frame: String = \"\") -> void:",
		"\treloads.append([zone, frame])",
		"func _place_at_region_local(region_x: int, region_y: int, local_x: float, local_z: float) -> bool:",
		"\tplaced.append([region_x, region_y, local_x, local_z])",
		"\tvar at: Vector2 = RegionGridState.frame_world(region_x, region_y, local_x, local_z, 97, 168)",
		"\tplayer.position = Vector3(at.x, 0.0, at.y)",
		"\t_last_sent_pos = player.position",
		"\treturn true",
		""]))
	_check(sub.reload() == OK and sub.can_instantiate(), "a recording subclass of World3D.gd compiles")
	var scene := load("res://scenes/World3D.tscn") as PackedScene
	_check(scene != null, "World3D.tscn loads")
	if not sub.can_instantiate() or scene == null:
		return null
	var world: Node = scene.instantiate()
	world.set_script(sub)
	root.add_child(world)
	return world

## An entry result as the server sends it: Jangan in its own frame, at the
## point the character left, (100, 5, -200). `restored` is set through set(),
## so a WorldNet without the field leaves it unset rather than failing to
## parse.
func _entry(restored: bool) -> WorldNet.EnterWorldResult:
	var result := WorldNet.EnterWorldResult.new()
	result.ok = true
	result.zone = "jangan"
	result.frame = "97/168"
	result.x = 100.0
	result.y = 5.0
	result.z = -200.0
	result.set("restored", restored)
	return result

## The recorder's stand-in landing: the region-local point named in 97/168's
## frame, at y 0.
static func _frame_point(region_x: int, region_y: int, local: Vector2) -> Vector3:
	var at: Vector2 = RegionGridState.frame_world(region_x, region_y, local.x, local.y, 97, 168)
	return Vector3(at.x, 0.0, at.y)

## _ready puts the player at the result's position; _load_initial_region_
## neighborhood then builds the zone and -- unless the entry was restored --
## moves it to the zone's landing spot.
func _enter(world: Node, result: WorldNet.EnterWorldResult) -> void:
	_net.set("last_enter_world_result", result)
	_net.set("current_zone", result.zone)
	world.set("reloads", [])
	world.set("placed", [])
	var player: Node3D = world.get("player")
	player.position = Vector3(result.x, result.y, result.z)
	world.call("_load_initial_region_neighborhood")

func _test_entry(world: Node) -> void:
	var consts: Dictionary = (world.get_script() as GDScript).get_base_script().get_script_constant_map()
	var spot: Vector2 = consts["ZONE_SPAWN_LOCAL"]["97/168"]
	var landing := _frame_point(97, 168, spot)
	var player: Node3D = world.get("player")

	# The probe: an entry that restored nothing is moved to Jangan's landing
	# spot, before and after round 573.
	_enter(world, _entry(false))
	_check(world.get("reloads") == [["jangan", "97/168"]], "the entry builds jangan in the server's frame 97/168 (got %s)" % str(world.get("reloads")))
	_check(world.get("placed") == [[97, 168, spot.x, spot.y]],
		"an entry that restored nothing is placed at 97/168's landing spot (%s) (got %s)" % [spot, str(world.get("placed"))])
	_check(player.position.is_equal_approx(landing), "and stands there, %s (got %s)" % [landing, player.position])

	# A restored entry keeps the server's position.
	_enter(world, _entry(true))
	_check(world.get("reloads") == [["jangan", "97/168"]], "a restored entry builds the same grid (got %s)" % str(world.get("reloads")))
	_check(world.get("placed") == [], "a restored entry is NOT moved to the landing spot (got %s)" % str(world.get("placed")))
	_check(player.position.is_equal_approx(Vector3(100.0, 5.0, -200.0)),
		"and stands where the server restored it, (100, 5, -200) (got %s)" % player.position)

## /unstuck: an entry that restored nothing returns to the entry point, as it
## always has; a restored one goes to the current zone's landing -- Jangan's
## landing spot, or the middle of the zone's centre region where the zone has
## none (server/internal/worldmap.Landing, local (960, 960)) -- and leaves the
## move sync to report it.
func _test_unstuck(world: Node) -> void:
	var consts: Dictionary = (world.get_script() as GDScript).get_base_script().get_script_constant_map()
	var spot: Vector2 = consts["ZONE_SPAWN_LOCAL"]["97/168"]
	var half: float = float(consts["REGION_SPAN"]) / 2.0
	var player: Node3D = world.get("player")
	var wedged := Vector3(333.0, 44.0, 555.0)

	_net.set("last_enter_world_result", _entry(false))
	_net.set("current_zone", "jangan")
	world.set("placed", [])
	player.position = wedged
	world.call("_unstuck_player")
	_check(player.position.is_equal_approx(Vector3(100.0, 5.0, -200.0)) and world.get("placed") == [],
		"/unstuck after an entry that restored nothing returns to the entry point (got %s, placed %s)" % [player.position, str(world.get("placed"))])

	_net.set("last_enter_world_result", _entry(true))
	world.set("placed", [])
	player.position = wedged
	world.set("_last_sent_pos", wedged)
	world.call("_unstuck_player")
	_check(world.get("placed") == [[97, 168, spot.x, spot.y]],
		"/unstuck after a restored entry lands at 97/168's landing spot, not the saved point (placed %s)" % str(world.get("placed")))
	_check(player.position.is_equal_approx(_frame_point(97, 168, spot)), "and the player stands there (got %s)" % player.position)
	_check(world.get("_last_sent_pos") == wedged, "and the landing is left for the move sync to report (last sent %s)" % str(world.get("_last_sent_pos")))

	# After a zone change to a town with no landing spot: its centre's middle.
	_net.set("current_zone", "donwhang")
	world.set("placed", [])
	player.position = wedged
	world.call("_unstuck_player")
	_check(world.get("placed") == [[102, 153, half, half]],
		"/unstuck in donwhang after a restored entry lands at 102/153's middle, local (%s, %s) (placed %s)" % [half, half, str(world.get("placed"))])
