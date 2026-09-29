extends SceneTree

## Round 640's root (OURS -- the user's choice "Root while walled"; retail's
## binaries let a walled caster move, docs/protocol/skill_buffs.md): while
## this player's own protection wall stands, a ground click, a held-button
## steer and the walk into an attack's reach move nobody; the wall's end frees
## it. On a bare World3D, with the catalog rows set by hand (SYNTHETIC rows in
## the catalog's shape: Fire Wall - Tower lv1 carries 'pw', Grass Walk not).
##   godot4 --headless --path client --script res://scripts/world/wall_root_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	var world_script := load("res://scripts/World3D.gd") as GDScript
	_check(world_script != null and world_script.can_instantiate(), "World3D compiles")
	if world_script == null:
		quit(1)
		return
	var net := root.get_node_or_null("NetClient")
	_check(net != null, "the NetClient autoload is there")
	if net == null:
		quit(1)
		return
	net.set("own_character_id", 7)
	var world: Node = world_script.new()
	var player := CharacterBody3D.new()
	world.set("player", player)
	var board := HudBuffBoard.new()
	board.catalog.set_row({"id": 136, "pw": true, "onff": true, "basic_code": "SKILL_CH_FIRE_HWABYEOK_A_01"})
	board.catalog.set_row({"id": 113, "pw": false, "onff": false, "basic_code": "SKILL_CH_LIGHTNING_GYEONGGONG_A_01"})
	world.set("_hud_buff_board", board)

	_check(int(world.call("_wall_root")) == 0, "no buff: not rooted")
	world.call("_note_owner_buff", "character:7", 1, 113)
	_check(int(world.call("_wall_root")) == 0, "a buff that is no wall (Grass Walk): not rooted")
	world.call("_note_owner_buff", "character:7", 2, 136)
	_check(int(world.call("_wall_root")) == 136, "Fire Wall up: rooted by skill 136")
	world.call("_note_owner_buff", "character:9", 3, 136)

	world.call("_try_set_move_target", Vector2(640, 300))
	_check(not bool(world.get("_has_move_target")), "rooted: a ground click sets no move target (no walk, no walk clip)")
	world.set("_left_steering", true)
	world.call("_try_set_move_target", Vector2(700, 300))
	world.set("_left_steering", false)
	_check(not bool(world.get("_has_move_target")), "rooted: a held-button steer sets none either")

	# The server's answer to a move it dropped (OURS): OpSkillMove naming the
	# wall puts this player where the server holds it.
	player.position = Vector3(30, 0, 30)
	var held := SkillNet.SkillMove.new()
	held.character_id = 7
	held.skill_id = 136
	held.x = 10.0
	held.y = 0.0
	held.z = 10.0
	world.call("_on_skill_moved", held)
	_check(is_equal_approx(player.position.x, 10.0) and is_equal_approx(player.position.z, 10.0),
		"the held position from the server snaps the player back (got %s)" % str(player.position))

	# The toggle-off reply ends a cast this client drew (the server decides).
	world.set("_fx_self_cast", {"skill": 136, "ground": false, "acted": false})
	var reply := CombatNet.AttackResult.new()
	reply.target_type = 0
	reply.target_type_echoed = true
	reply.player_hp = 100
	reply.wall = CombatNet.WallHit.new()
	reply.wall.toggled_off = true
	world.call("_on_attack_result", reply)
	_check((world.get("_fx_self_cast") as Dictionary).is_empty(), "the toggle-off reply ends the drawn cast")

	world.call("_forget_owner_buffs", "character:7", [2])
	_check(int(world.call("_wall_root")) == 0, "the wall's OpBuffEnd frees the player (another player's wall does not root this one)")

	net.set("own_character_id", -1)
	board.free()
	world.free()
	player.free()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
