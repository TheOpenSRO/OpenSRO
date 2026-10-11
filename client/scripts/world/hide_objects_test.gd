extends SceneTree

## Round 771: V hides every other player, monster and departing body, the
## GPU-drawn crowd and the ghosts' weapon effects too -- not only the near
## holders. The original's rule (READ): while DAT_00eef5f4 is set the
## predicate 0x9d0560 fails other players, monsters, CICMonsterNPC, CICRide
## and every COS but the ridden one, and the character's draw 0x9d20d0 then
## skips its body, its attachments and its name.
##   godot4 --headless --path client --script res://scripts/world/hide_objects_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	_crowd()
	_batch()
	_world_source()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

## CrowdGpu.set_hidden: every group's mask off, back as each group wants.
func _crowd() -> void:
	var cg := CrowdGpu.new()
	var shown := CrowdGpu.Group.new()
	shown.inst = RenderingServer.instance_create()
	shown.layers = 5
	shown.shown_o = true
	var off := CrowdGpu.Group.new()
	off.inst = RenderingServer.instance_create()
	off.layers = 5
	off.shown_o = false
	cg._groups["a"] = shown
	cg._groups["b"] = off
	_check(cg._mask(shown, true) == 5 and cg._mask(off, off.shown_o) == 0, "before V: a shown group has its layers, a hidden one 0")
	cg.set_hidden(true)
	_check(cg.hidden and cg._mask(shown, shown.shown_o) == 0, "V held: a shown group is masked off")
	cg.set_hidden(false)
	_check(not cg.hidden and cg._mask(shown, shown.shown_o) == 5 and cg._mask(off, off.shown_o) == 0,
		"V released: each group as its own state wants")
	RenderingServer.free_rid(shown.inst)
	RenderingServer.free_rid(off.inst)

## EquipFxBatch.set_ghosts_hidden (the fallback, where every draw is a
## ghost's): the draws show no instance, and come back on release.
func _batch() -> void:
	var saved: bool = EquipFxBatch.native_wanted
	EquipFxBatch.native_wanted = false
	var parent := Node3D.new()
	root.add_child(parent)
	var fb := EquipFxBatch.new(parent)
	var b := EquipFxBatch.Batch.new()
	b.shown = 3
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = MultiMesh.new()
	mmi.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	parent.add_child(mmi)
	# A link draw (kind 1): one instance a host.
	b.draws = [[mmi, ShaderMaterial.new(), 1, 0, 0, 1]]
	fb._batches["k"] = b
	fb._apply_counts(b)
	_check(mmi.multimesh.visible_instance_count == 3 and mmi.visible, "before V: three ghosts' effects drawn")
	fb.set_ghosts_hidden(true)
	_check(mmi.multimesh.visible_instance_count == 0 and not mmi.visible, "V held: none drawn")
	fb.set_ghosts_hidden(false)
	_check(mmi.multimesh.visible_instance_count == 3 and mmi.visible, "V released: drawn again")
	parent.queue_free()
	EquipFxBatch.native_wanted = saved

## World3D's hooks, read from its source (it is too big to build here).
func _world_source() -> void:
	var src := FileAccess.get_file_as_string("res://scripts/World3D.gd")
	var at := src.find("func _apply_key_holds() -> void:")
	var end := src.find("\nfunc ", at + 10)
	var body := src.substr(at, end - at)
	_check(at >= 0 and body.contains("_crowd_gpu.set_hidden(players_hidden)"), "V reaches the far crowd")
	_check(body.contains("EquipFx.ghosts_hidden = players_hidden"), "and the ghosts' weapon effects")
	_check(body.contains("_show_departing(hiding)"), "and the departing bodies")
	_check(body.contains("_show_bodies(_other_bodies") and body.contains("_show_bodies(_monster_bodies"), "and the near players and the monsters, as before")
	var fade := src.find("func _fade_out_body(")
	_check(fade >= 0 and src.substr(fade, 1200).contains("_departing_bodies[body.get_instance_id()] = body"),
		"a departing player or monster is tracked")
	_check(src.contains("if _objects_hidden and KeyMap.hides_under_v(\"other_player\"):") \
		and src.contains("if _objects_hidden and KeyMap.hides_under_v(\"monster\"):"),
		"a body made while V is held starts hidden")
