extends SceneTree

## Round 723: a gate row matched to a model placed in a NEIGHBOUR region, in
## either load order (GateEffectMatch). Synthetic positions only. Run headless:
## `godot4 --headless --path client --script res://scripts/world/gate_effect_match_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## A world where region `row_region` holds the row at `row_local` and region
## `obj_region` holds the model at `obj_local` (each region-local x/z), and
## the commit of `committed` asks for pairs with only `loaded` regions'
## objects present.
func _pairs_on_commit(committed: Vector2i, loaded: Array, row_region: Vector2i, row_local: Vector2,
		obj_region: Vector2i, obj_local: Vector2, done: bool = false) -> Array:
	var rows: Array = []
	for r in GateEffectMatch.around(committed):
		if r == row_region:
			rows.append({"key": "row", "at": GateEffectMatch.row_in_frame(row_local, row_region, committed)})
	var objects: Array = []
	for r in GateEffectMatch.around(committed):
		if r == obj_region and loaded.has(obj_region):
			objects.append({"key": "obj", "at": GateEffectMatch.row_in_frame(obj_local, obj_region, committed), "done": done})
	return GateEffectMatch.pairs(rows, objects, 30.0)

func _init() -> void:
	# Samarkand's shape: the row at 107/107 local x 1917 (the region's x edge),
	# the model 1.0 away but in the region one step along region y (world X),
	# where its local x is 1917 + 1 - 1920 = -2.
	var row_r := Vector2i(107, 107)
	var obj_r := Vector2i(107, 108)
	var row_l := Vector2(1917.0, 108.0)
	var obj_l := Vector2(-2.0, 108.0)
	_check(GateEffectMatch.row_in_frame(obj_l, obj_r, row_r).is_equal_approx(Vector2(1918.0, 108.0)),
		"a region one step along region y is +1920 on local x (region y runs along world X)")
	_check(GateEffectMatch.row_in_frame(Vector2(5.0, 7.0), Vector2i(108, 107), row_r).is_equal_approx(Vector2(5.0, 1927.0)),
		"a region one step along region x is +1920 on local z (region x runs along world Z)")

	# Order 1: the row's region commits first, the model's region later.
	var first := _pairs_on_commit(row_r, [row_r], row_r, row_l, obj_r, obj_l)
	_check(first.is_empty(), "row's region first: nothing yet (the model's region is not loaded)")
	var second := _pairs_on_commit(obj_r, [row_r, obj_r], row_r, row_l, obj_r, obj_l)
	_check(second.size() == 1 and absf(float(second[0]["distance"]) - 1.0) < 1e-4,
		"then the model's region commits: its commit pairs the neighbour's row, 1.0 apart")

	# Order 2: the model's region commits first (the user's teleport into
	# Samarkand), the row's region later.
	var early := _pairs_on_commit(obj_r, [obj_r], row_r, row_l, obj_r, obj_l)
	_check(early.size() == 1, "model's region first: the row of the neighbour is matched at once")
	var late := _pairs_on_commit(row_r, [row_r, obj_r], row_r, row_l, obj_r, obj_l, true)
	_check(late.is_empty(), "and the row's later commit skips the model already done (once per object)")
	var late_fresh := _pairs_on_commit(row_r, [row_r, obj_r], row_r, row_l, obj_r, obj_l)
	_check(late_fresh.size() == 1, "had the model's commit missed it, the row's own commit pairs it from the neighbour container")

	# The radius still holds across the boundary.
	var far := _pairs_on_commit(obj_r, [obj_r], row_r, row_l, obj_r, Vector2(40.0, 108.0))
	_check(far.is_empty(), "a model 43 away across the boundary is not the gate's")

	# Two regions apart is out of reach of the eight neighbours.
	_check(GateEffectMatch.around(Vector2i(10, 10)).size() == 9 and not GateEffectMatch.around(Vector2i(10, 10)).has(Vector2i(12, 10)),
		"around() is the region and its eight neighbours")

	# One object, two rows: it plays once.
	var rows := [{"key": "a", "at": Vector2(0, 0)}, {"key": "b", "at": Vector2(5, 0)}]
	var objs := [{"key": "o", "at": Vector2(2, 0), "done": false}]
	_check(GateEffectMatch.pairs(rows, objs, 30.0).size() == 1, "an object near two rows pairs once")

	print("%d failure(s)" % _failures)
	quit(1 if _failures > 0 else 0)
