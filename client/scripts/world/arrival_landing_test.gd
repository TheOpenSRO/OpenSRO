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

	# (b) Where a teleport point is in the world, without its region loaded
	# (region_local_to_world): the server's own numbers for the two gates
	# (MEASURED, msg=teleport in run i4/i5 under -single-frame, frame 97/168).
	var has_conv := world_script.get_script_method_list().any(func(m): return m["name"] == "region_local_to_world")
	_check(has_conv, "World3D.region_local_to_world exists")
	if has_conv:
		var ch: Vector2 = world_script.call("region_local_to_world", 97, 168, 969.0, 1369.0, 97, 168)
		_check(ch.distance_to(Vector2(9.0, -409.0)) < 0.01, "GATE_CH 97/168 (969, 1369) is world (9, -409) in frame 97/168 (got %s)" % str(ch))
		var kt: Vector2 = world_script.call("region_local_to_world", 92, 135, 1138.0, 153.0, 97, 168)
		_check(kt.distance_to(Vector2(-63182.0, 10407.0)) < 0.01, "GATE_KT 92/135 (1138, 153) is world (-63182, 10407) in frame 97/168 (got %s)" % str(kt))

	# (c) A restored entry at a teleport point (_teleport_point_at): the
	# server saved it at height 0 -- a dead logout at the return point, or a
	# logout where a teleport left the player.
	var reader := TeleportReader.new()
	reader.parse(
		_table([
			_row(14, {0: 1, 1: 1, 2: "GATE_CH", 3: 2094, 4: "SN_ZONE_22001", 5: 25000, 6: 969, 7: 0, 8: 1369, 9: 150, 10: 1, 11: 0, 12: 1}),
			_row(14, {0: 1, 1: 5, 2: "GATE_KT", 3: 2096, 4: "SN_ZONE_22003", 5: 23687, 6: 1138, 7: 250, 8: 153, 9: 250, 10: 1, 11: 0, 12: 1}),
			# Not a town gate (no id 7): a logout right after a teleport there
			# re-entered 355.79 under its object before the review.
			_row(14, {0: 1, 1: 164, 2: "GATE_TOMB_GATE_IN", 3: 0, 4: "SN_X", 5: 19019, 6: 500, 7: 398, 8: 500, 9: 50, 10: 0, 11: 0, 12: 1}),
			# A dungeon's point: never matched.
			_row(14, {0: 1, 1: 9, 2: "GATE_DUNGEON", 3: 0, 4: "SN_Y", 5: -32760, 6: 969, 7: 0, 8: 1369, 9: 50, 10: 0, 11: 0, 12: 1}),
		]),
		_table([]), _table([]))
	_check(reader.has_method("world_points"), "TeleportReader.world_points exists")
	var world: Node = world_script.new()
	world.set("_teleport_reader", reader)
	var has_at := world.has_method("_teleport_point_at")
	_check(has_at, "World3D._teleport_point_at exists")
	if has_at and has_conv:
		var frame := {"x": 97, "y": 168}
		var at: Vector2 = world_script.call("region_local_to_world", 97, 168, 969.0, 1369.0, 97, 168)
		var found = world.call("_teleport_point_at", at, frame)
		_check(found != null and found.code == "GATE_CH", "GATE_CH's point is a teleport point (got %s)" % [found.code if found != null else "null"])
		_check(world.call("_teleport_point_at", at + Vector2(0.5, 0.0), frame) != null, "half a unit off still is (the server names it in float32)")
		_check(world.call("_teleport_point_at", at + Vector2(5.0, 0.0), frame) == null, "five units off is not")
		var kt = world.call("_teleport_point_at", Vector2(-63182.0, 10407.0), frame)
		_check(kt != null and kt.code == "GATE_KT", "GATE_KT is matched with its region not loaded (got %s)" % [kt.code if kt != null else "null"])
		var tomb_at: Vector2 = world_script.call("region_local_to_world", 74, 75, 500.0, 500.0, 97, 168)
		var tomb = world.call("_teleport_point_at", tomb_at, frame)
		_check(tomb != null and tomb.code == "GATE_TOMB_GATE_IN",
			"a point that is no town gate is matched too (review item 4; got %s)" % [tomb.code if tomb != null else "null"])
		_check(world.call("_teleport_point_at", at, {}) == null, "no frame, no match")

	# (d) The request bookkeeping (round 690's review).
	var has_match := world.has_method("_match_zone_change_request") and world.has_method("_note_zone_change_request")
	_check(has_match, "World3D._note_zone_change_request / _match_zone_change_request exist")
	if has_match:
		var reqs := func() -> Array: return Array(world.get("_zone_change_requests"))
		world.call("_request_zone_change", "Donwhang")
		_check(reqs.call() == ["donwhang"], "_request_zone_change remembers the zone it asks for (got %s)" % str(reqs.call()))
		_check(bool(world.call("_match_zone_change_request", "", false, false)) and reqs.call().is_empty(),
			"a refused change answers the oldest request (left %s)" % str(reqs.call()))
		_check(not bool(world.call("_match_zone_change_request", "jangan", true, true)), "with nothing asked, a move is the server's own")
		# The interleave: the zone box asked for Jangan; a flag-off kill's
		# return to Jangan's gate arrives first, then the answer.
		world.call("_note_zone_change_request", "jangan")
		_check(not bool(world.call("_match_zone_change_request", "jangan", true, true)),
			"a result for the asked label but at a teleport point is the return, not the answer")
		_check(reqs.call() == ["jangan"], "and leaves the request for its answer (got %s)" % str(reqs.call()))
		_check(bool(world.call("_match_zone_change_request", "jangan", true, false)) and reqs.call().is_empty(),
			"the answer at the landing then takes it")
		# Two requests answered out of label order.
		world.call("_note_zone_change_request", "hotan")
		world.call("_note_zone_change_request", "jangan")
		_check(bool(world.call("_match_zone_change_request", "jangan", true, false)) and reqs.call() == ["hotan"],
			"an answer takes the request for its own label (left %s)" % str(reqs.call()))
		_check(not bool(world.call("_match_zone_change_request", "donwhang", true, false)) and reqs.call() == ["hotan"],
			"a label nobody asked for is the server's own move and takes nothing")
		# A gate teleport's arrival (its receipt marked it) is answered without
		# touching the requests, even at a point in an asked-for zone.
		_check(world.has_method("_zone_result_requested"), "World3D._zone_result_requested exists")
		if world.has_method("_zone_result_requested"):
			_check(bool(world.call("_zone_result_requested", true, "hotan", true, true)) and reqs.call() == ["hotan"],
				"a teleport arrival is this client's and leaves the requests alone (left %s)" % str(reqs.call()))
			_check(bool(world.call("_zone_result_requested", false, "hotan", true, false)) and reqs.call().is_empty(),
				"a plain result goes through the matcher")
	world.free()
	_finish()

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
