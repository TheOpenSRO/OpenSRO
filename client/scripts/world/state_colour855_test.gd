extends SceneTree

## Round 855: "the status effect color lingers when it shouldn't". Driven
## through World3D's own _on_object_status (state_end847_test's pattern: a
## World3D.tscn whose frame hooks do nothing), on this player (the owner) and
## on another player's body (what an observer draws), each standing on a
## terrain tile -- its meshes on ObjectLight's shared level copy, as
## CharacterLight leaves a body there -- and rescanned by CharacterLight while
## the state runs, as every 8th visit does in the game. What is checked is the
## colour drawn, measured on the meshes (TintProbe), never the books:
## - a poison's end: no mesh of the body, and no shared material, draws a
##   colour (NEGATIVE on 6b1b1223: the poison's last green stayed on the
##   body and on every body at that level -- MEASURED live, round 855);
## - two states, one ends: the colour ends with it (READ, +0x4c whoever set
##   it), the other's aura stays;
## - a death (the look dropped without a walk) and a zone change: no colour.
## Synthetic tables and materials, never game data. Run headless on the
## render box: `client/tools/remote_godot.sh tests`.

var _failures := 0
var _net: Node

const OWN := 4848
const OTHER := 5252
const LEVEL := 153.0 / 384.0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	var watchdog := create_timer(90.0)
	watchdog.timeout.connect(func() -> void:
		print("FAIL the suite never reported (a script error stopped it)")
		quit(1))
	await process_frame
	_net = root.get_node_or_null("NetClient")
	_check(_net != null, "the NetClient autoload is there")
	if _net != null:
		SkillAudio.set_tables({}, {})
		SkillEffects.reset()
		SkillEffects.effect_factory = func(_p: String): return null
		var world := _make_world()
		if world != null:
			_net.set("own_character_id", OWN)
			_net.set("current_character_name", "Aria")
			world.call("_sync_own_id")
			var base := ShaderMaterial.new()
			base.shader = ObjectLoader.object_shader("solid")
			var player: Node3D = world.get("player")
			_give_skeleton(player, base)
			var other := Node3D.new()
			world.add_child(other)
			_give_skeleton(other, base)
			(world.get("_other_bodies") as Dictionary)[OTHER] = other
			var bystander := Node3D.new()
			world.add_child(bystander)
			_give_skeleton(bystander, base)
			for view in [[OWN, player, "the owner"], [OTHER, other, "an observer"]]:
				_test_paths(world, int(view[0]), view[1], bystander, String(view[2]))
			SkillEffects.effect_factory = Callable()
			SkillEffects.reset()
			StateLook.clear()
			root.remove_child(world)
			world.free()
		_net.set("own_character_id", -1)
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

func _status(world: Node, id: int, mask: int) -> void:
	var st := StatusNet.ObjectStatus.new()
	st.owner_kind = 0
	st.owner_id = id
	st.mask = mask
	world.call("_on_object_status", st)

## A frame of the game's: the pulse steps, CharacterLight rescans the body
## (every 8th visit in the game) and the bystander at the same level.
func _frame(body: Node3D, bystander: Node3D) -> void:
	BodyPulse.tick(1.0 / 60.0)
	CharacterLight.set_on(body, LEVEL, true)
	CharacterLight.set_on(bystander, LEVEL, true)
	BodyPulse.tick(1.0 / 60.0)

func _drawn(body: Node3D) -> int:
	return int(TintProbe.measure(body)["tinted"])

func _clean(body: Node3D, bystander: Node3D, what: String) -> void:
	_frame(body, bystander)
	_check(_drawn(body) == 0 and _drawn(bystander) == 0 and TintProbe.shared_tinted() == 0,
		"%s: no colour on the body (%d meshes), on a body beside it at its level (%d), or on a shared material (%d)" % [
			what, _drawn(body), _drawn(bystander), TintProbe.shared_tinted()])

func _test_paths(world: Node, id: int, body: Node3D, bystander: Node3D, who: String) -> void:
	# A poison, left to expire.
	_status(world, id, 0x10)
	for i in 10:
		_frame(body, bystander)
	_check(_drawn(body) >= 1 and _drawn(bystander) == 0, "%s, a poison: the body draws its colour, the body beside it none" % who)
	_status(world, id, 0)
	_clean(body, bystander, "%s, the poison's expiry" % who)

	# A burn and a poison; the poison ends first, the burn stays.
	_status(world, id, 0x8)
	_frame(body, bystander)
	_status(world, id, 0x18)
	for i in 10:
		_frame(body, bystander)
	_status(world, id, 0x8)
	_check(_drawn(body) == 0, "%s, a poison ending beside a burn: the colour ends with it (READ, +0x4c whoever set it)" % who)
	_status(world, id, 0)
	_clean(body, bystander, "%s, the burn cured after" % who)

	# A death: the look dropped at once, without a walk.
	_status(world, id, 0x10)
	for i in 10:
		_frame(body, bystander)
	world.call("_drop_state_look", "character:%d" % id, body)
	(world.get("_abnormal_states") as Dictionary).erase("character:%d" % id)
	_clean(body, bystander, "%s, a death with a poison on" % who)

	# A zone change with a burn on.
	_status(world, id, 0x8)
	for i in 10:
		_frame(body, bystander)
	world.call("_clear_state_looks", "the test's zone change")
	_clean(body, bystander, "%s, a zone change with a burn on" % who)

func _give_skeleton(body: Node3D, base: Material) -> void:
	var skel := Skeleton3D.new()
	skel.add_bone("Bip01")
	body.add_child(skel)
	var mi := MeshInstance3D.new()
	mi.mesh = BoxMesh.new()
	mi.material_override = ObjectLight.with_object_color(base, LEVEL)
	skel.add_child(mi)
	body.set_meta(CharacterLight.META_VALUE, LEVEL)

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
	SkillEffects.own_body = world.get("player")
	return world
