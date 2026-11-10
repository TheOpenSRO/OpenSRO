extends SceneTree

## Round 879: the Wrecked Ship's monsters drawn on their deck and its doors
## that block. The heights a monster record and a drop carry (NetClient's
## _monster_wire_height / _ground_wire_height), a door's yaw from its wire
## angle, and the walk's stop at a closed door's outline
## (DoorBlock.stop).
## `godot4 --headless --path client --script res://scripts/world/fgw879_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _test_wire_heights() -> void:
	var nc = load("res://scripts/net/net_client.gd").new()
	# The Wrecked Ship's frame is anchored at -1800 (round 870).
	nc.wire_height_anchor = -1800.0
	var deck := CombatNet.MonsterSnapshot.new()
	deck.y = -842.3
	nc._monster_wire_height(deck)
	_check(deck.has_height and is_equal_approx(deck.y, 957.7),
		"a monster on the deck (wire -842.3) has its height, scene 957.7 (%.2f)" % deck.y)
	var field := CombatNet.MonsterSnapshot.new()
	nc._monster_wire_height(field)
	_check(not field.has_height and field.y == 0.0, "an open-world monster's 0 names no height and stays 0")
	var gold := GroundItemsNet.Snapshot.new()
	gold.y = -842.3
	nc._ground_wire_height(gold)
	_check(is_equal_approx(gold.y, 957.7), "a drop on the deck comes into the scene at 957.7 (%.2f)" % gold.y)
	nc._spawn_dungeon = 1
	var cave := CombatNet.MonsterSnapshot.new()
	cave.y = 42.0
	nc._monster_wire_height(cave)
	_check(not cave.has_height and cave.y == 42.0, "a dungeon's heights are left as they are")
	nc.free()

func _test_door() -> void:
	# The server's angleOfYaw(5.0614552) is 36409 (the Wrecked Ship's first
	# door, MEASURED in prod's client log); door_yaw undoes it.
	_check(absf(DoorBlock.door_yaw(36409) - 5.0614552) < 1e-3, "the door's yaw back from its angle (%.4f)" % DoorBlock.door_yaw(36409))
	_check(is_equal_approx(DoorBlock.crossing(Vector2(0, 0), Vector2(10, 0), Vector2(4, -1), Vector2(4, 1)), 0.4),
		"a step crossing an edge at 4 of 10 crosses at 0.4")
	_check(DoorBlock.crossing(Vector2(0, 0), Vector2(3, 0), Vector2(4, -1), Vector2(4, 1)) < 0.0, "a step short of it does not")
	var holders := {}
	var group := Node3D.new()
	root.add_child(group)
	group.position = Vector3(100, 0, 0)
	var holder := Node3D.new()
	group.add_child(holder)
	holder.position = Vector3(0, 50, 0)
	# A slab 150 wide along z and 30 deep along x at the group's origin.
	holder.set_meta(DoorBlock.META_SEGMENTS, PackedVector2Array([
		Vector2(-15, -75), Vector2(-15, 75), Vector2(15, -75), Vector2(15, 75),
		Vector2(-15, -75), Vector2(15, -75), Vector2(-15, 75), Vector2(15, 75)]))
	holders[7] = holder
	var stop := DoorBlock.stop(holders, Vector3(50, 50, 60), Vector3(150, 50, 60))
	_check(not stop.is_empty() and absf((stop["at"] as Vector3).x - 84.8) < 1e-3,
		"a walk across the door 60 off its middle stops 0.2 short of its near side (%s)" % str(stop))
	_check(DoorBlock.stop(holders, Vector3(50, 50, 90), Vector3(150, 50, 90)).is_empty(), "a walk beside it goes on")
	holders.erase(7)
	_check(DoorBlock.stop(holders, Vector3(50, 50, 60), Vector3(150, 50, 60)).is_empty(), "an open (removed) door stops nothing")
	group.free()

## An arrival 3 regions along the ship from its frame region (114/243): the
## zone loads the 3 x 3 cells around the frame region, and the point's cell
## (111/243) is not among them until the grid streams it in.
func _test_far_arrival_cell() -> void:
	var grid := RegionGridState.new()
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			grid.mark_loaded(dx, dy, 114 + dx, 243 + dy)
	# The frame region's corner in its own frame: (-960, 0, 960).
	var corner := Vector3(-960.0, 0.0, 960.0)
	var far := Vector3(-897.0, 0.0, 5140.0) - corner
	_check(RegionGridState.cell_at(far) == Vector2i(-3, 0), "frame point (-897, 5140) lies in cell -3, 0 (%s)" % str(RegionGridState.cell_at(far)))
	_check(not grid.cell_loaded_at(far), "its cell is not loaded with the zone's 3 x 3: the arrival is held")
	_check(grid.cell_loaded_at(Vector3(-273.0, 0.0, 2191.0) - corner), "a point one region along (-273, 2191) has its cell")
	grid.mark_loaded(-3, 0, 111, 243)
	_check(grid.cell_loaded_at(far), "once cell -3, 0 is built the arrival lands")

func _initialize() -> void:
	_test_wire_heights()
	_test_door()
	_test_far_arrival_cell()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
