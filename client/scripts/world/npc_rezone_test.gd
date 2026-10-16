extends SceneTree

## Round 789 lane E: an NPC holder queued for deletion does not stand (the
## zone rebuilt by a teleport within the zone frees the old terrain node and
## its NPC holders with queue_free() and builds the new cell in the same
## frame; World3D.npc_holder_standing was is_instance_valid alone, so every
## NPC of the region was skipped as already placed -- MEASURED live, "0/3
## NPC(s) placed in 97/168" after a GM /tp, docs/rounds/r789e.md). Synthetic
## nodes, never game data. Run headless on the render box:
## `client/tools/remote_godot.sh tests`.
##
## NEGATIVE: with the old test (is_instance_valid alone) the queued holder
## case reports FAIL.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	var W = load("res://scripts/World3D.gd")
	var region := Node3D.new()
	root.add_child(region)
	var holder := Node3D.new()
	region.add_child(holder)
	_check(W.npc_holder_standing(holder), "a placed holder stands: no second placement")
	_check(not W.npc_holder_standing(null), "no holder: placed")
	region.queue_free()
	_check(is_instance_valid(holder) and not W.npc_holder_standing(holder),
		"a holder under a terrain node queued for deletion (same frame) does not stand: placed again")
	var lone := Node3D.new()
	lone.free()
	_check(not W.npc_holder_standing(lone), "a freed holder does not stand")
	await process_frame
	print("npc_rezone_test: %s (%d failure(s))" % ["PASS" if _failures == 0 else "FAIL", _failures])
	quit(0 if _failures == 0 else 1)
