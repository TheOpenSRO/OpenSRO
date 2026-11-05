extends SceneTree

## Round 862: the items on the ground. A ground item's name is drawn in the
## original's plate look, in white with no box (READ c:0x9e1d00; MEASURED
## (255, 255, 255) for plain, sealed, +7, gold and potion drops), and a drop
## model's `ambient` effects are handed to World3D (GroundItems.set_effects_for,
## World3D._attach_drop_effects). Never game data: a bare World3D subclass and
## a synthetic model node.
## Run headless on the render box: `client/tools/remote_godot.sh tests`.

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
	var world := _make_world()
	if world != null:
		await process_frame
		_test_plate(world)
		world.queue_free()
		await process_frame
	_test_effects_hook()
	print("ground_drop862_test: %s (%d failure(s))" % ["PASS" if _failures == 0 else "FAIL", _failures])
	quit(0 if _failures == 0 else 1)

func _make_world() -> Node:
	var sub := GDScript.new()
	sub.source_code = "\n".join(PackedStringArray([
		"extends \"res://scripts/World3D.gd\"",
		"func _ready() -> void:",
		"\tpass",
		"func _physics_process(_delta: float) -> void:",
		"\tpass",
		"func _process(_delta: float) -> void:",
		"\tpass",
		"func _exit_tree() -> void:",
		"\tpass",
		""]))
	_check(sub.reload() == OK and sub.can_instantiate(), "a subclass of World3D.gd compiles")
	var scene := load("res://scenes/World3D.tscn") as PackedScene
	if not sub.can_instantiate() or scene == null:
		return null
	var world: Node = scene.instantiate()
	world.set_script(sub)
	root.add_child(world)
	return world

func _test_plate(world: Node) -> void:
	var label: Label3D = world._ground_item_plate("Copper Sword", 2.0)
	_check(label.modulate == Color(1.0, 1.0, 1.0), "an item's name is white (got %s)" % str(label.modulate))
	_check(label.outline_size == 0, "with no outline (the original's plate look)")
	_check(not label.has_meta(NamePlates.BOX_META) and label.get_node_or_null("NameBox") == null, "and no box behind it")
	_check(label.fixed_size and label.no_depth_test, "drawn at a fixed size over the scene, as every plate")
	label.free()

## The hook: a model whose .bsr carries an `ambient` set reaches it once it
## is in the tree; one with none does not.
func _test_effects_hook() -> void:
	var items := GroundItems.new()
	root.add_child(items)
	var seen: Array = []
	items.set_effects_for(func(model: Node3D) -> int:
		seen.append([model.name, model.is_inside_tree()])
		return 1)
	var with_fx := Node3D.new()
	with_fx.name = "drop_ch_equip_rare"
	with_fx.set_meta(AmbientParticles.META_ENTRIES, [[]])
	var without := Node3D.new()
	without.name = "drop_ch_money_large"
	_check(items._attach_model_effects(with_fx) == true, "a model with an ambient set is handed on")
	_check(items._attach_model_effects(without) == false, "one with none is not")
	_check(seen.size() == 1 and String(seen[0][0]) == "drop_ch_equip_rare", "the hook ran once, for the right model (%s)" % str(seen))
	with_fx.free()
	without.free()
	items.queue_free()
