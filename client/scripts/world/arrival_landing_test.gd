extends SceneTree

## Round 690: where a move the server makes lands on this client.
##   godot4 --headless --path client --script res://scripts/world/arrival_landing_test.gd
##
## The user (2026-10-02): "when I set Hotan as my default spawn and die I get
## resurrected back in hotan but im clipped half way through the ground."
## MEASURED on the render box (lane tele690, run i2, srrevamp-01's flags): the
## revive's zone change put the feet at 234.59 on Hotan's gate point, the
## terrain there at 234.25 and the walkable graph's landing (the castle plaza)
## at 246.78 -- 12.19 under the floor -- because a zone change the client did
## not ask for took the plain zone change's branch: no landing on the graph,
## only the terrain-only lift. In Jangan the same branch moved the return to
## the square, 350 units from where the server had put the character.
##
## World3D is reached through has_method/call, so a World3D without the round's
## functions FAILS here rather than failing to parse. Synthetic rows only.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _row(width: int, fields: Dictionary) -> String:
	var cols := PackedStringArray()
	cols.resize(width)
	cols.fill("0")
	for k in fields:
		cols[int(k)] = str(fields[k])
	return "\t".join(cols)

func _table(rows: Array) -> PackedByteArray:
	return PackedByteArray([0xFF, 0xFE]) + ("\r\n".join(PackedStringArray(rows)) + "\r\n").to_utf16_buffer()

func _initialize() -> void:
	var world_script := load("res://scripts/World3D.gd") as GDScript
	_check(world_script != null and world_script.can_instantiate(), "World3D compiles")
	if world_script == null:
		_finish()
		return

	# (a) Which arrivals keep the server's point and stand it on the walkable
	# graph: arrival_keeps_server_point(teleport, requested, dead).
	var has_rule := world_script.get_script_method_list().any(func(m): return m["name"] == "arrival_keeps_server_point")
	_check(has_rule, "World3D.arrival_keeps_server_point exists")
	if has_rule:
		_check(not bool(world_script.call("arrival_keeps_server_point", false, true, false)),
			"a zone change this client asked for, alive: the zone's own landing spot, as before")
		_check(bool(world_script.call("arrival_keeps_server_point", true, false, false)),
			"a gate teleport (its receipt came first): the server's point, as since round 576")
		_check(bool(world_script.call("arrival_keeps_server_point", false, false, true)),
			"a move that finds the player dead -- option 1's return point: the server's point")
		_check(bool(world_script.call("arrival_keeps_server_point", false, true, true)),
			"dead even with a request outstanding: still the return point (the server refuses a dead zone change)")
		_check(bool(world_script.call("arrival_keeps_server_point", false, false, false)),
			"a move this client never asked for, alive -- the flag-off respawn: the server's point")

	# (b) A restored entry at a town gate's point is a return point
	# (_return_point_at): the server saved a character that left dead at
	# its return point, at height 0.
	var reader := TeleportReader.new()
	reader.parse(
		_table([
			_row(14, {0: 1, 1: 1, 2: "GATE_CH", 3: 2094, 4: "SN_ZONE_22001", 5: 25000, 6: 969, 7: 0, 8: 1369, 9: 150, 10: 1, 11: 0, 12: 1}),
			_row(14, {0: 1, 1: 5, 2: "GATE_KT", 3: 2096, 4: "SN_ZONE_22003", 5: 23687, 6: 1138, 7: 250, 8: 153, 9: 250, 10: 1, 11: 0, 12: 1}),
			# A ferry's point: no id 7, so never a return point.
			_row(14, {0: 1, 1: 3, 2: "GATE_NPC_CH_FERRY", 3: 2011, 4: "SN_ZONE_21002", 5: 25000, 6: 500, 7: 0, 8: 500, 9: 200, 10: 0, 11: 0, 12: 1}),
		]),
		_table([]), _table([]))
	_check(reader.has_method("return_points"), "TeleportReader.return_points exists")
	var world: Node = world_script.new()
	world.set("_teleport_reader", reader)
	var group := Node3D.new()
	group.name = "RealTerrain_97_168"
	TerrainCollision.place_group(group, world_script.call("_cell_offset", 0, 0), 0.0)
	world.add_child(group)
	var has_at := world.has_method("_return_point_at")
	_check(has_at, "World3D._return_point_at exists")
	if has_at:
		var xf: Transform3D = world_script.call("_chain_transform", group)
		var at := xf * Vector3(969.0, 0.0, 1369.0)
		var found = world.call("_return_point_at", Vector2(at.x, at.z))
		_check(found != null and found.code == "GATE_CH",
			"GATE_CH's point named in its region's frame is a return point (got %s)" % [found.code if found != null else "null"])
		var near = world.call("_return_point_at", Vector2(at.x + 0.5, at.z))
		_check(near != null, "half a unit off still is (the server names it in float32)")
		# NEGATIVE: a restored point that is no gate's keeps the old rule.
		_check(world.call("_return_point_at", Vector2(at.x + 5.0, at.z)) == null, "five units off is not")
		var ferry := xf * Vector3(500.0, 0.0, 500.0)
		_check(world.call("_return_point_at", Vector2(ferry.x, ferry.z)) == null, "a ferry's point (no id 7) is not")
		# Hotan's region is not loaded: its point cannot be matched there.
		_check(world.call("_return_point_at", Vector2(-63182.0, 10407.0)) == null, "a gate whose region is not loaded is not matched")
	world.free()
	_finish()

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
