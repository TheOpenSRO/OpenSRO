extends SceneTree

## Round 649: a click walk at a raised /speed lands on its point instead of
## ping-ponging across it (ClickWalk.step, World3D._step_click_walk). Run
## headless on the render box: `client/tools/remote_godot.sh tests`.
##
## The fault, reproduced synthetically: 60 ticks a second, the run speed 500
## (50 x /speed 10) -- a step of 8.33 -- and a destination 4 units ahead. The
## pre-649 rule (full speed until within MOVE_TARGET_STOP_DISTANCE, 2.39) steps
## to 4.33 past the point, then 4 short of it, for ever. `_old_rule` replays
## that rule so the scenario is shown to BE the fault; the checks then hold
## the new rule and World3D's own walk to landing on the point.
##
## READ: retail's mover tick FUN_009e0e60 cuts the step to the distance left
## when the step would reach the destination (ClickWalk's doc). The speeds and
## distances here are synthetic.
##
## NEGATIVE: against dev e5bf2ba ClickWalk and World3D._step_click_walk do not
## exist; every new name is looked up before it is called, so the base reports
## FAIL lines rather than a script error. Those two lines only say the names
## are missing; the behavioural evidence is `_old_rule`'s replay (it passes on
## both) and the live base trace (docs/WORLD_ISSUES.md, round 649).
##
## Round 649's follow-up: a click walk into a synthetic blocking edge ends
## there, as retail's mover ends a refused step (ClickWalk.blocked_ends). This
## part drives World3D._move_on_nav_graph itself, which the base has, with the
## base's own full-speed velocity, so the base fails it by BEHAVIOUR: its walk
## holds its order against the edge.

const TICK := 1.0 / 60.0
const STOP := 0.3 * (14.34 / 1.8) # World3D.MOVE_TARGET_STOP_DISTANCE

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## The pre-649 walk (World3D._physics_step before round 649), for one axis:
## returns the positions of `ticks` ticks from `pos` toward `dest`.
func _old_rule(pos: float, dest: float, speed: float, ticks: int) -> Array:
	var out := []
	var ordered := true
	for i in range(ticks):
		if ordered:
			var left := dest - pos
			if absf(left) <= STOP:
				ordered = false
			else:
				pos += signf(left) * speed * TICK
		out.append(pos)
	return out

## How many times consecutive steps reverse direction.
func _reversals(track: Array) -> int:
	var n := 0
	for i in range(2, track.size()):
		var a: float = track[i - 1] - track[i - 2]
		var b: float = track[i] - track[i - 1]
		if a * b < 0.0:
			n += 1
	return n

func _initialize() -> void:
	# The scenario is the fault: the old rule ping-pongs for all 120 ticks.
	var old := _old_rule(0.0, 4.0, 500.0, 120)
	_check(_reversals(old) >= 100, "the old rule ping-pongs at /speed 10 against a point 4 ahead (%d reversals, ends at %.2f)" % [_reversals(old), old[old.size() - 1]])
	var old4 := _old_rule(0.0, 2.5, 306.0, 120)
	_check(_reversals(old4) >= 100, "and at /speed 4 under Grass Walk's x1.53 (306 u/s) against a point 2.5 ahead (%d reversals)" % _reversals(old4))
	# And not at /speed 4 alone (200 u/s, a step of 3.33): no point it can
	# jump over, which is why a plain /speed 2-4 did not show it.
	var worst := 0
	for d10 in range(0, 400):
		worst = maxi(worst, _reversals(_old_rule(0.0, 0.1 * d10 + 0.05, 200.0, 120)))
	_check(worst == 0, "the old rule at 200 u/s never reverses (worst %d): the fault needs a step over %.2f" % [worst, 2.0 * STOP])

	var cw := load("res://scripts/world/click_walk.gd") as GDScript
	_check(cw != null, "ClickWalk exists")
	if cw != null:
		_test_rule(cw)
	var world_script := load("res://scripts/World3D.gd") as GDScript
	var world_ok := world_script != null and world_script.can_instantiate()
	_check(world_ok, "World3D compiles")
	if world_ok:
		_test_world(world_script)
		await _test_blocked_edge(world_script)
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)

func _test_rule(cw: GDScript) -> void:
	# A step longer than the distance left is cut to land on the point.
	var r: Dictionary = cw.call("step", Vector2(4.0, 0.0), 500.0, TICK, STOP)
	var v: Vector2 = r["velocity"]
	_check(not bool(r["arrived"]) and absf(v.x * TICK - 4.0) < 1e-4 and absf(v.y) < 1e-6,
		"a step of 8.33 against 4 left is cut to 4: it lands on the point (READ, FUN_009e0e60) (%s)" % str(v * TICK))
	# A step shorter than the distance is the full speed.
	r = cw.call("step", Vector2(0.0, -30.0), 500.0, TICK, STOP)
	v = r["velocity"]
	_check(absf(v.length() - 500.0) < 1e-3 and v.y < 0.0, "30 left: the full speed toward the point (%s)" % str(v))
	# Within the stop: arrived.
	r = cw.call("step", Vector2(1.0, 1.0), 500.0, TICK, STOP)
	_check(bool(r["arrived"]) and (r["velocity"] as Vector2) == Vector2.ZERO, "within the stop distance the walk is over")
	# The whole walk, every speed /speed allows, every distance: no reversal,
	# ends on or within the stop of the point, never past it.
	var worst_rev := 0
	var worst_over := 0.0
	var unfinished := 0
	for f in [1.0, 2.0, 3.06, 4.0, 5.74, 6.0, 8.0, 10.0, 15.3]:
		var speed: float = 50.0 * f
		for d10 in range(0, 400):
			var dest := 0.1 * d10 + 0.05
			var pos := 0.0
			var track := [pos]
			var done := false
			for i in range(600):
				var rr: Dictionary = cw.call("step", Vector2(dest - pos, 0.0), speed, TICK, STOP)
				if bool(rr["arrived"]):
					done = true
					break
				pos += (rr["velocity"] as Vector2).x * TICK
				track.append(pos)
				worst_over = maxf(worst_over, pos - dest)
			if not done:
				unfinished += 1
			worst_rev = maxi(worst_rev, _reversals(track))
	_check(worst_rev == 0, "no walk from 0.05 to 40 units at x1-x15.3 reverses (worst %d)" % worst_rev)
	_check(worst_over < 1e-4, "none passes its point (worst %.5f)" % worst_over)
	_check(unfinished == 0, "every walk ends (%d did not)" % unfinished)

## World3D's own walk: the player at /speed 10, a point 4 ahead. The step is
## applied as _move_on_nav_graph applies it (velocity x delta).
func _test_world(world_script: GDScript) -> void:
	var world: Node = world_script.new()
	var player := CharacterBody3D.new()
	world.set("player", player)
	if not world.has_method("_step_click_walk"):
		_check(false, "World3D._step_click_walk exists (the walk's tick)")
		player.free()
		world.free()
		return
	for case in [[500.0, Vector3(4.0, 0.0, 0.0)], [306.0, Vector3(0.0, 0.0, -3.0)], [400.0, Vector3(2.5, 0.0, 2.5)]]:
		var speed: float = case[0]
		var dest: Vector3 = case[1]
		player.position = Vector3.ZERO
		world.set("_move_speed", speed)
		world.set("_move_target", dest)
		world.set("_has_move_target", true)
		var xs := [0.0]
		var ticks := 0
		for i in range(120):
			if bool(world.call("_step_click_walk", TICK)):
				break
			player.position += Vector3(player.velocity.x, 0.0, player.velocity.z) * TICK
			xs.append(player.position.dot(dest.normalized()))
			ticks += 1
		var left := Vector2(dest.x - player.position.x, dest.z - player.position.z).length()
		_check(not bool(world.get("_has_move_target")) and ticks <= 2 and left < 1e-3 and _reversals(xs) == 0,
			"World3D at %.0f u/s to a point %.2f away: lands on it and stops (%d ticks, %.4f left, %d reversals)" % [
				speed, dest.length(), ticks, left, _reversals(xs)])
	player.free()
	world.free()

## A flat synthetic region, every tile on cell 0, with one blocking edge at
## local x = 100 from z 0 to 200 (the fixture of nav_graph_test.gd).
func _walled_graph() -> NavGraph:
	var r := NvmReader.ParsedRegion.new()
	r.heights.resize(NvmReader.HEIGHT_COUNT)
	r.heights.fill(0.0)
	var cell := NvmReader.Cell.new()
	cell.rect_min = Vector2.ZERO
	cell.rect_max = Vector2(1920.0, 1920.0)
	r.cells.append(cell)
	for _i in range(NvmReader.TILE_COUNT):
		var t := NvmReader.Tile.new()
		t.cell_index = 0
		r.tiles.append(t)
	var e := NvmReader.Edge.new()
	e.flags = 2
	e.line_min = Vector2(100.0, 0.0)
	e.line_max = Vector2(100.0, 200.0)
	r.internal_edges = [e]
	return NavGraph.build(r, [] as Array[NavGraph.PlacedObject])

## Walks the player from `from` toward `dest` for up to `ticks` ticks through
## World3D._move_on_nav_graph, with the velocity the base's walk sets (full
## speed toward the point while the order is in effect). Returns
## [ticks walked with the order in effect, final position].
func _walk_into(world: Node, player: CharacterBody3D, from: Vector3, dest: Vector3, speed: float, ticks: int) -> Array:
	player.global_position = from
	world.set("_nav_footing_pos", Vector3.INF)
	world.set("_move_target", dest)
	world.set("_has_move_target", true)
	var held := 0
	for i in range(ticks):
		if not bool(world.get("_has_move_target")):
			break
		var d := Vector3(dest.x - player.global_position.x, 0.0, dest.z - player.global_position.z)
		if d.length() <= STOP:
			world.set("_has_move_target", false)
			break
		var v := d.normalized() * speed
		player.velocity = Vector3(v.x, 0.0, v.z)
		world.call("_move_on_nav_graph", TICK)
		held += 1
	return [held, player.global_position]

func _test_blocked_edge(world_script: GDScript) -> void:
	var world: Node = world_script.new()
	var player := CharacterBody3D.new()
	var group := Node3D.new()
	get_root().add_child(player)
	get_root().add_child(group)
	# The nodes are in the tree (global transforms) from the next frame.
	await process_frame
	world.set("player", player)
	var grid = world.get("_grid")
	grid.call("add_nav_graph", 0, 0, _walled_graph(), group)
	for speed in [50.0, 200.0, 500.0]:
		# Straight at the edge, the point 10 beyond it: the walk must end at
		# the edge, not hold its order there.
		var r := _walk_into(world, player, Vector3(90.0, 0.0, 100.0), Vector3(110.0, 0.0, 100.0), speed, 240)
		var pos: Vector3 = r[1]
		_check(not bool(world.get("_has_move_target")) and pos.x < 100.0 and int(r[0]) < 240,
			"a walk at %.0f u/s straight into a blocking edge ends there (%d ticks, x %.3f, order %s)" % [
				speed, int(r[0]), pos.x, str(world.get("_has_move_target"))])
	# Oblique: the walk slides along the edge while that gets it anywhere,
	# and ends only where it stops dead, level with its point.
	var s := _walk_into(world, player, Vector3(90.0, 0.0, 100.0), Vector3(110.0, 0.0, 150.0), 50.0, 600)
	var sp: Vector3 = s[1]
	_check(not bool(world.get("_has_move_target")) and sp.x < 100.0 and sp.z > 145.0,
		"an oblique walk slides along the edge and ends level with its point, not at first contact (x %.3f, z %.3f, %d ticks)" % [sp.x, sp.z, int(s[0])])
	# An attack walking into reach is not ended here: retail's attack tick
	# re-issues its approach while out of reach (auto_command.md, phase 1).
	world.set("_pending_attack", {"monster": 1})
	var a := _walk_into(world, player, Vector3(90.0, 0.0, 100.0), Vector3(110.0, 0.0, 100.0), 200.0, 60)
	_check(bool(world.get("_has_move_target")) and int(a[0]) == 60,
		"an attack's approach walk is left to the attack tick (%d ticks, order %s)" % [int(a[0]), str(world.get("_has_move_target"))])
	world.set("_pending_attack", {})
	world.set("_has_move_target", false)
	player.queue_free()
	group.queue_free()
	world.free()
