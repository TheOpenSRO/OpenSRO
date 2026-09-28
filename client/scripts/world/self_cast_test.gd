extends SceneTree

## Casting with no monster target, and the buff / skill-move messages (round
## 617). Run headless on the render box: `client/tools/remote_godot.sh tests`.
##
## The world is World3D.tscn with a subclass (seated_spawn_test.gd's pattern)
## whose _ready and frame hooks do nothing, whose cast clip and sounds are
## stubbed, and whose ground ray returns a fixed point -- the ray is the walk's
## own, and what is checked is what the click does with the point it finds.
## HudPanels is a real one with its skill catalog set by hand to the three
## rows' real columns (skills_spec §1.5, MEASURED): Grass Walk 113 (TR 0,
## Land 0), Ghost Walk 114 (TR 1, Land 1) and Smash 3 (TR 1, Land 0).
## NetClient is the real autoload with a StreamPeerBuffer standing in for the
## socket, so the bytes checked are the bytes the client would send.
##
## Review follow-up: the attack result's targetType echo and the reply queue
## out of step (_test_interleaved_replies), OpSelfId and ownerKind
## (_test_own_id), and the pick's cursor leaving with the world
## (_test_leave_world).
##
## NEGATIVE (round 617): against dev b50a7b9 the Grass Walk key with nothing
## selected sends nothing ("Select a target first"), and the Ghost Walk key
## does the same, so the ground click walks instead of casting -- the
## OpUseSkill checks below FAIL there.

var _failures := 0
var _net: Node
## SkillNet, called by name rather than bound at compile time, so that against
## a SkillNet without round 617's functions this suite still runs and FAILs
## check by check (the negative) instead of failing to parse.
var _S: GDScript

const GROUND_POINT := Vector3(1234.5, 67.25, -890.75)

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
	await process_frame
	_S = load("res://scripts/net/skill.gd")
	_test_plan()
	_test_codec()
	_net = root.get_node_or_null("NetClient")
	_check(_net != null, "the NetClient autoload is there")
	if _net != null:
		_test_dispatch()
		var world := _make_world()
		if world != null:
			_test_self_cast(world)
			_test_ground_pick(world)
			_test_cancel(world)
			_test_buffs_and_move(world)
			_test_self_reply(world)
			_test_interleaved_replies(world)
			_test_own_id(world)
			_test_leave_world(world)
			root.remove_child(world)
			world.free()
		_net.set("_connected", false)
		_net.set("_peer", null)
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

# --- SelfCast.plan -------------------------------------------------------------

func _test_plan() -> void:
	var sc: GDScript = load("res://scripts/world/self_cast.gd")
	_check(sc != null, "self_cast.gd loads")
	if sc == null:
		return
	var grass := {"range": 0, "approach": false, "target_required": 0, "target_land": 0}
	var ghost := {"range": 0, "approach": false, "target_required": 1, "target_land": 1}
	var smash := {"range": 6, "approach": true, "target_required": 1, "target_land": 0}
	_check(sc.call("plan", grass, false) == "self", "TR 0 with nothing selected casts on the player")
	_check(sc.call("plan", grass, true) == "self", "TR 0 with a monster selected still casts on the player")
	_check(sc.call("plan", ghost, false) == "ground", "TR 1 + Land 1 picks a ground point")
	_check(sc.call("plan", ghost, true) == "ground", "even with a monster selected")
	_check(sc.call("plan", smash, true) == "target", "TR 1 casts at the selection")
	_check(sc.call("plan", smash, false) == "need_target", "and is refused with none")
	_check(sc.call("plan", {}, false) == "need_target", "a skill the catalog does not know is refused with nothing selected")
	_check(sc.call("plan", {}, true) == "target", "and cast at a selection, as before")
	# is_self_reply(target_type, echoed, monster_damage, monster_died, player_died, error)
	_check(sc.call("is_self_reply", 0, true, 0, false, false, ""), "an echoed type-0 reply with no damage is the self cast's")
	_check(sc.call("is_self_reply", 0, true, 0, false, false, "skill on cooldown"), "and so is its echoed refusal")
	_check(sc.call("is_self_reply", 2, true, 0, false, false, ""), "an echoed type-2 reply is the ground cast's")
	_check(not sc.call("is_self_reply", 0, true, 12, false, false, ""), "one that reports damage is a blow")
	_check(not sc.call("is_self_reply", 1, true, 0, false, false, ""), "an entity cast's reply is never a self reply")
	_check(sc.call("is_self_reply", 0, false, 0, false, false, ""), "unechoed, a clean type-0 reply is the cast's")
	_check(not sc.call("is_self_reply", 0, false, 0, false, true, ""), "unechoed, one carrying the player's death is never swallowed")
	_check(not sc.call("is_self_reply", 0, false, 0, false, false, "too far away"), "unechoed, one carrying an error is never swallowed")
	_check(not sc.call("is_self_reply", 0, false, 30, false, false, ""), "unechoed, one carrying damage is never swallowed")
	_check(not sc.call("is_self_reply", 0, true, 0, false, true, ""), "even echoed, the player's death is drawn")

# --- The §4.0 byte layouts -----------------------------------------------------

func _u64(v: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(8)
	b.encode_s64(0, v)
	return b

func _u32(v: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_u32(0, v)
	return b

func _f32(v: float) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_float(0, v)
	return b

## {name, i64 skillId, i64 targetMonsterId, u8 targetType, [f32 x, y, z]},
## built byte by byte from the contract.
func _use_bytes(name: String, skill: int, monster: int, type: int, point: Vector3 = Vector3.ZERO) -> PackedByteArray:
	var n := name.to_utf8_buffer()
	var out := PackedByteArray([n.size() & 0xff, n.size() >> 8])
	out.append_array(n)
	out.append_array(_u64(skill))
	out.append_array(_u64(monster))
	out.append(type)
	if type == 2:
		out.append_array(_f32(point.x))
		out.append_array(_f32(point.y))
		out.append_array(_f32(point.z))
	return out

func _buff_start_bytes(owner: int, skill: int, token: int, dura: int, remaining: int, speed: int) -> PackedByteArray:
	var out := _u64(owner)
	out.append_array(_u64(skill))
	out.append_array(_u32(token))
	out.append_array(_u64(dura))
	out.append_array(_u64(remaining))
	out.append_array(_u32(speed))
	return out

## The same with the trailing u8 ownerKind.
func _with_kind(bytes: PackedByteArray, kind: int) -> PackedByteArray:
	var out := bytes.duplicate()
	out.append(kind)
	return out

## An OpAttackResult as the server encodes it (session/combat.go
## AttackResult.Encode): {str error, u32 dmg, u32 remaining, u8 died,
## u32 taken, u32 hp, u8 player_died, u32 gauge, u8 berserk, i64 exp lost,
## u8 mcrit, u8 pcrit, u8 blocked, i64 monsterId}, then round 617's u8
## targetType echo when `echo` >= 0.
func _attack_result_bytes(error: String, dmg: int, player_died: bool, hp: int, monster: int, echo: int) -> PackedByteArray:
	var e := error.to_utf8_buffer()
	var out := PackedByteArray([e.size() & 0xff, e.size() >> 8])
	out.append_array(e)
	out.append_array(_u32(dmg))
	out.append_array(_u32(0))
	out.append(0)
	out.append_array(_u32(0))
	out.append_array(_u32(hp))
	out.append(1 if player_died else 0)
	out.append_array(_u32(0))
	out.append(0)
	out.append_array(_u64(0))
	out.append_array(PackedByteArray([0, 0, 0]))
	out.append_array(_u64(monster))
	if echo >= 0:
		out.append(echo)
	return out

func _buff_end_bytes(owner: int, tokens: Array, speed: int) -> PackedByteArray:
	var out := _u64(owner)
	out.append(tokens.size())
	for t in tokens:
		out.append_array(_u32(int(t)))
	out.append_array(_u32(speed))
	return out

func _skill_move_bytes(character: int, skill: int, p: Vector3) -> PackedByteArray:
	var out := _u64(character)
	out.append_array(_u64(skill))
	out.append_array(_f32(p.x))
	out.append_array(_f32(p.y))
	out.append_array(_f32(p.z))
	return out

func _test_codec() -> void:
	_check(_S.call("encode_use", "Aria", 113, 0, 0) == _use_bytes("Aria", 113, 0, 0),
		"OpUseSkill targetType 0 is the contract's bytes")
	_check(_S.call("encode_use", "Aria", 3, 55) == _use_bytes("Aria", 3, 55, 1),
		"an entity cast carries targetType 1 as its suffix")
	_check(_S.call("encode_use", "Aria", 114, 0, 2, GROUND_POINT) == _use_bytes("Aria", 114, 0, 2, GROUND_POINT),
		"OpUseSkill targetType 2 carries the point as three f32")
	var cancel := PackedByteArray([4, 0])
	cancel.append_array("Aria".to_utf8_buffer())
	cancel.append_array(_u64(113))
	cancel.append_array(_u32(0xDEADBEEF))
	_check(_S.call("encode_buff_cancel", "Aria", 113, 0xDEADBEEF) == cancel, "OpBuffCancel is {name, i64 skillId, u32 token}")

	var bs = _S.call("decode_buff_start", _buff_start_bytes(77, 113, 0xFFFFFFF0, -1, 355462, 60))
	_check(bs != null and bs.owner_id == 77 and bs.skill_id == 113 and bs.token == 0xFFFFFFF0
		and bs.duration_ms == -1 and bs.remaining_ms == 355462 and bs.run_speed == 60,
		"OpBuffStart decodes every field (u32 token above 2^31, durationMs -1)")
	_check(_S.call("decode_buff_start", _buff_start_bytes(77, 113, 1, 1, 1, 0).slice(0, 39)) == null,
		"a short OpBuffStart is refused")
	var be = _S.call("decode_buff_end", _buff_end_bytes(77, [5, 9, 0x80000001], 50))
	_check(be != null and be.owner_id == 77 and be.tokens == [5, 9, 0x80000001] and be.run_speed == 50,
		"OpBuffEnd decodes the count, the tokens and the speed")
	var be0 = _S.call("decode_buff_end", _buff_end_bytes(78, [], 0))
	_check(be0 != null and be0.tokens.is_empty() and be0.run_speed == 0, "an OpBuffEnd with no tokens decodes")
	_check(_S.call("decode_buff_end", _buff_end_bytes(77, [5, 9], 50).slice(0, 20)) == null,
		"a short OpBuffEnd is refused")
	var bsk = _S.call("decode_buff_start", _with_kind(_buff_start_bytes(77, 113, 5, 1, 1, 0), 1))
	_check(bsk != null and bsk.owner_kind == 1 and bsk.owner_kind_sent, "OpBuffStart's trailing ownerKind 1 (monster) is read")
	_check(bs != null and bs.owner_kind == 0 and not bs.owner_kind_sent, "without it the owner reads as a character, marked unsent")
	var bek = _S.call("decode_buff_end", _with_kind(_buff_end_bytes(77, [5, 9], 50), 1))
	_check(bek != null and bek.owner_kind == 1 and bek.owner_kind_sent and bek.run_speed == 50 and bek.tokens == [5, 9],
		"OpBuffEnd's trailing ownerKind is read after runSpeed")
	_check(_S.call("decode_self_id", _u64(4242)) == 4242, "OpSelfId decodes {i64 characterId}")
	_check(_S.call("decode_self_id", _u64(4242).slice(0, 7)) == -1, "a short OpSelfId is refused")
	var ar_echo := CombatNet.decode_attack_result(_attack_result_bytes("", 0, false, 100, 555, 0))
	_check(ar_echo.monster_id == 555 and ar_echo.target_type == 0 and ar_echo.target_type_echoed,
		"OpAttackResult's trailing targetType echo is read after monsterId")
	var ar_old := CombatNet.decode_attack_result(_attack_result_bytes("", 7, false, 100, 555, -1))
	_check(ar_old.monster_damage == 7 and not ar_old.target_type_echoed and ar_old.target_type == 1,
		"a result without the echo reads type 1, marked unechoed")
	var sm = _S.call("decode_skill_move", _skill_move_bytes(77, 114, GROUND_POINT))
	_check(sm != null and sm.character_id == 77 and sm.skill_id == 114
		and Vector3(sm.x, sm.y, sm.z) == GROUND_POINT, "OpSkillMove decodes the character, skill and point")
	_check(_S.call("decode_skill_move", _skill_move_bytes(77, 114, GROUND_POINT).slice(0, 27)) == null,
		"a short OpSkillMove is refused")

## NetClient turns the three packets into the three signals round 618 uses.
func _test_dispatch() -> void:
	var got := {}
	var on_start := func(s) -> void: got["start"] = s
	var on_end := func(e) -> void: got["end"] = e
	var on_move := func(m) -> void: got["move"] = m
	var has := _net.has_signal("buff_started") and _net.has_signal("buff_ended") and _net.has_signal("skill_moved")
	_check(has, "NetClient has buff_started, buff_ended and skill_moved")
	if not has:
		return
	_net.connect("buff_started", on_start)
	_net.connect("buff_ended", on_end)
	_net.connect("skill_moved", on_move)
	_net.call("_dispatch", Packet.new(0x00F5, _buff_start_bytes(91, 113, 7, 355462, 1000, 60)))
	_net.call("_dispatch", Packet.new(0x00F6, _buff_end_bytes(91, [7], 50)))
	_net.call("_dispatch", Packet.new(0x00F8, _skill_move_bytes(91, 114, GROUND_POINT)))
	var ids: Array = []
	var on_id := func(i) -> void: ids.append(i)
	_check(_net.has_signal("self_id_received"), "NetClient has self_id_received")
	if _net.has_signal("self_id_received"):
		_net.connect("self_id_received", on_id)
		_net.call("_dispatch", Packet.new(0x00F9, _u64(9191)))
		_net.disconnect("self_id_received", on_id)
	_check(ids == [9191] and int(_net.get("own_character_id")) == 9191,
		"0x00F9 emits self_id_received and keeps own_character_id (got %s)" % str(ids))
	_net.set("own_character_id", -1)
	_check(got.has("start") and got["start"].token == 7 and got["start"].run_speed == 60, "0x00F5 emits buff_started")
	_check(got.has("end") and got["end"].tokens == [7], "0x00F6 emits buff_ended")
	_check(got.has("move") and got["move"].skill_id == 114, "0x00F8 emits skill_moved")
	_net.disconnect("buff_started", on_start)
	_net.disconnect("buff_ended", on_end)
	_net.disconnect("skill_moved", on_move)
	_check(_net.has_method("send_buff_cancel"), "NetClient has send_buff_cancel(skill_id, token)")

# --- The world ---------------------------------------------------------------

func _make_world() -> Node:
	var sub := GDScript.new()
	sub.source_code = "\n".join(PackedStringArray([
		"extends \"res://scripts/World3D.gd\"",
		"var cast_clips: Array = []",
		"var ground_point = Vector3(%s, %s, %s)" % [GROUND_POINT.x, GROUND_POINT.y, GROUND_POINT.z],
		"func _ready() -> void:",
		"\tpass",
		"func _physics_process(_delta: float) -> void:",
		"\tpass",
		"func _process(_delta: float) -> void:",
		"\tpass",
		"func _exit_tree() -> void:",
		"\tpass",
		"func _play_skill_cast_anim(anim_base: String) -> float:",
		"\tcast_clips.append(anim_base)",
		"\treturn 1.0",
		"func _audio_cast_start(_skill_id: int) -> void:",
		"\tpass",
		"func _ground_point_at(_screen_pos: Vector2) -> Variant:",
		"\treturn ground_point",
		""]))
	_check(sub.reload() == OK and sub.can_instantiate(), "a subclass of World3D.gd compiles")
	var scene := load("res://scenes/World3D.tscn") as PackedScene
	if not sub.can_instantiate() or scene == null:
		return null
	var world: Node = scene.instantiate()
	world.set_script(sub)
	root.add_child(world)
	# Loaded, not named: HudPanels names the NetClient autoload, which a
	# --script run registers only after this suite has compiled.
	var panels: Node = (load("res://scripts/ui/hud/hud_panels.gd") as GDScript).new()
	panels.set("_skill_catalog_loaded", true)
	panels.set("_skill_reach_by_id", {
		113: {"range": 0, "approach": false, "target_required": 0, "target_land": 0},
		114: {"range": 0, "approach": false, "target_required": 1, "target_land": 1},
		3: {"range": 6, "approach": true, "target_required": 1, "target_land": 0},
	})
	world.set("_hud_panels", panels)
	_net.set("current_character_name", "Aria")
	return world

## A fresh fake socket; returns it.
func _fresh_socket() -> StreamPeerBuffer:
	var buf := StreamPeerBuffer.new()
	_net.set("_peer", buf)
	_net.set("_connected", true)
	return buf

## Every frame written to the fake socket, as [opcode, payload].
func _frames(buf: StreamPeerBuffer) -> Array:
	var out: Array = []
	var bytes := buf.data_array
	var at := 0
	while at + Packet.HEADER_SIZE <= bytes.size():
		var size := bytes.decode_u16(at)
		var op := bytes.decode_u16(at + 2)
		out.append([op, bytes.slice(at + Packet.HEADER_SIZE, at + Packet.HEADER_SIZE + size)])
		at += Packet.HEADER_SIZE + size
	return out

func _uses(buf: StreamPeerBuffer) -> Array:
	return _frames(buf).filter(func(f) -> bool: return int(f[0]) == 0x0072)

func _test_self_cast(world: Node) -> void:
	world.set("_last_attack_target", -1)
	var buf := _fresh_socket()
	world.call("_cast_skill", 113, "SKILL_CH_LIGHTNING_GYEONGGONG_A_01")
	var uses := _uses(buf)
	_check(uses.size() == 1, "Grass Walk with nothing selected sends one OpUseSkill (got %d)" % uses.size())
	if uses.size() == 1:
		_check(uses[0][1] == _use_bytes("Aria", 113, 0, 0),
			"and it is targetType 0 with no monster (got %s)" % str(uses[0][1]))
	_check((world.get("cast_clips") as Array).has("skill_ch_lightning_gyeonggong_a"),
		"the cast clip plays on the player (got %s)" % str(world.get("cast_clips")))
	var types: Array = _net.get("_attack_types_in_flight") if "_attack_types_in_flight" in _net else []
	_check(types == [0], "the reply is expected as a self cast's (got %s)" % str(types))
	_net.set("_attack_targets_in_flight", [] as Array[int])
	if "_attack_types_in_flight" in _net:
		_net.set("_attack_types_in_flight", [] as Array[int])

	# With a monster selected, the selection stays and is not re-shown as the
	# cast's target; the monster field carries it for an older server.
	world.set("_last_attack_target", 555)
	buf = _fresh_socket()
	world.call("_cast_skill", 113, "SKILL_CH_LIGHTNING_GYEONGGONG_A_01")
	uses = _uses(buf)
	_check(uses.size() == 1 and uses[0][1] == _use_bytes("Aria", 113, 555, 0),
		"with monster 555 selected it is still targetType 0 (got %s)" % (str(uses[0][1]) if uses.size() == 1 else "%d sends" % uses.size()))
	_check(int(world.get("_last_attack_target")) == 555, "and the selection is kept")
	_check(world.get("_pending_skill_hit_code") == "", "no hit effect is armed for the target")
	_net.set("_attack_targets_in_flight", [] as Array[int])
	if "_attack_types_in_flight" in _net:
		_net.set("_attack_types_in_flight", [] as Array[int])

	# A skill that needs a target is still refused with none (the old rule).
	world.set("_last_attack_target", -1)
	buf = _fresh_socket()
	world.call("_cast_skill", 3, "SKILL_CH_SWORD_SMASH_A_01")
	_check(_uses(buf).is_empty(), "Smash with nothing selected sends nothing")

func _test_ground_pick(world: Node) -> void:
	world.set("_last_attack_target", -1)
	var buf := _fresh_socket()
	world.call("_cast_skill", 114, "SKILL_CH_LIGHTNING_GYEONGGONG_B_01")
	_check(_uses(buf).is_empty(), "Ghost Walk's key sends nothing yet")
	var sc = world.get("_self_cast")
	_check(sc != null and sc.picking(), "it enters ground-pick mode")
	var what: String = world.call("_dispatch_left_click", Vector2(300, 200))
	var uses := _uses(buf)
	_check(what == "ground_pick", "the left click is the ground pick, not a walk (got %s)" % what)
	_check(uses.size() == 1, "the click sends one OpUseSkill (got %d)" % uses.size())
	if uses.size() == 1:
		_check(uses[0][1] == _use_bytes("Aria", 114, 0, 2, GROUND_POINT),
			"targetType 2 with the clicked point (got %s)" % str(uses[0][1]))
	_check(sc == null or not sc.picking(), "and the mode ends")
	_check(not bool(world.get("_has_move_target")), "and the player does not walk there")
	_net.set("_attack_targets_in_flight", [] as Array[int])
	if "_attack_types_in_flight" in _net:
		_net.set("_attack_types_in_flight", [] as Array[int])

func _test_cancel(world: Node) -> void:
	var sc = world.get("_self_cast")
	if sc == null:
		_check(false, "World3D has _self_cast")
		return
	var buf := _fresh_socket()
	world.call("_cast_skill", 114, "SKILL_CH_LIGHTNING_GYEONGGONG_B_01")
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.pressed = true
	world.call("_input", esc)
	_check(not sc.picking(), "Escape cancels the pick")
	world.call("_cast_skill", 114, "SKILL_CH_LIGHTNING_GYEONGGONG_B_01")
	var right := InputEventMouseButton.new()
	right.button_index = MOUSE_BUTTON_RIGHT
	right.pressed = true
	world.call("_unhandled_input", right)
	_check(not sc.picking(), "a right click cancels the pick")
	right.pressed = false
	world.call("_unhandled_input", right)
	# A cancelled pick's click walks.
	var what: String = world.call("_dispatch_left_click", Vector2(300, 200))
	_check(what == "walk" and _uses(buf).is_empty(), "after a cancel the click walks and casts nothing (got %s)" % what)
	world.set("_has_move_target", false)

func _test_buffs_and_move(world: Node) -> void:
	var now := Time.get_ticks_msec()
	var sc = world.get("_self_cast")
	if sc == null:
		return
	# Grass Walk was cast in _test_self_cast; its start names this player.
	sc.note_cast(113, now)
	world.set("_move_speed", 50.0)
	world.call("_on_buff_started", _S.call("decode_buff_start", _buff_start_bytes(4242, 113, 31, 355462, 355462, 60)))
	_check(is_equal_approx(float(world.get("_move_speed")), 60.0), "Grass Walk's start sets the run speed to 60 (got %s)" % str(world.get("_move_speed")))
	_check(sc.own_id == 4242, "and teaches the client its own id")
	# Another player's buff moves nothing.
	world.call("_on_buff_started", _S.call("decode_buff_start", _buff_start_bytes(5151, 113, 32, 355462, 355462, 99)))
	_check(is_equal_approx(float(world.get("_move_speed")), 60.0), "someone else's buff leaves the speed")
	# runSpeed 0 is unchanged.
	world.call("_on_buff_started", _S.call("decode_buff_start", _buff_start_bytes(4242, 90, 33, 15000, 15000, 0)))
	_check(is_equal_approx(float(world.get("_move_speed")), 60.0), "a start with runSpeed 0 leaves the speed")
	world.call("_on_buff_ended", _S.call("decode_buff_end", _buff_end_bytes(4242, [31], 50)))
	_check(is_equal_approx(float(world.get("_move_speed")), 50.0), "the end puts it back to 50 (got %s)" % str(world.get("_move_speed")))

	# Ghost Walk's landing moves this player to the point, at once.
	var player: Node3D = world.get("player")
	player.position = Vector3(1200, 67, -880)
	world.call("_on_skill_moved", _S.call("decode_skill_move", _skill_move_bytes(4242, 114, GROUND_POINT)))
	_check(player.position == GROUND_POINT, "OpSkillMove snaps this player to the point (got %s)" % str(player.position))
	_check(world.get("_last_sent_pos") == GROUND_POINT, "and does not send the move back")
	# Another player's body moves, and this player does not.
	var other := Node3D.new()
	world.add_child(other)
	(world.get("_other_bodies") as Dictionary)[5151] = other
	world.call("_on_skill_moved", _S.call("decode_skill_move", _skill_move_bytes(5151, 114, Vector3(1, 2, 3))))
	_check(other.position == Vector3(1, 2, 3), "another player's body is put at its point")
	_check(player.position == GROUND_POINT, "and this player stays")
	(world.get("_other_bodies") as Dictionary).erase(5151)
	other.free()

## A self cast's reply is not a blow on the selected monster: no swing.
func _test_self_reply(world: Node) -> void:
	world.set("_last_attack_target", 555)
	world.set("_pending_skill_hit_code", "SKILL_CH_SWORD_SMASH_A_01")
	var step := int(world.get("_attack_step"))
	var r := CombatNet.AttackResult.new()
	r.set("target_type", 0)
	r.set("player_hp", 100)
	_fresh_socket()
	world.call("_on_attack_result", r)
	_check(int(world.get("_attack_step")) == step, "a self cast's reply plays no swing (step %d -> %d)" % [step, int(world.get("_attack_step"))])
	_check(world.get("_pending_skill_hit_code") == "SKILL_CH_SWORD_SMASH_A_01", "and leaves the monster cast's hit effect armed")
	_check(int(world.get("_last_attack_target")) == 555, "and the selection")

## Round 617's review: the reply queue out of step. A keep-up repeat the client
## never asked for lands between a self cast and its reply.
func _test_interleaved_replies(world: Node) -> void:
	var got: Array = []
	var on_result := func(r) -> void: got.append(r)
	_net.connect("attack_result", on_result)
	world.set("_last_attack_target", 555)
	# 1. A server that echoes: the repeat says type 1 though the queue's head
	# is the self cast's 0, and is drawn as a blow; the cast's reply says 0.
	var buf := _fresh_socket()
	_net.set("_attack_targets_in_flight", [] as Array[int])
	_net.set("_attack_types_in_flight", [] as Array[int])
	world.call("_cast_skill", 113, "SKILL_CH_LIGHTNING_GYEONGGONG_A_01")
	_net.call("_dispatch", Packet.new(CombatNet.OP_ATTACK_RESULT, _attack_result_bytes("", 30, false, 90, 555, 1)))
	_net.call("_dispatch", Packet.new(CombatNet.OP_ATTACK_RESULT, _attack_result_bytes("", 0, false, 90, 0, 0)))
	_check(got.size() == 2, "two replies dispatched (got %d)" % got.size())
	if got.size() == 2:
		_check(got[0].target_type == 1, "the unsolicited keep-up repeat keeps its echoed type 1 (got %d)" % got[0].target_type)
		_check(got[1].target_type == 0, "the self cast's reply keeps its echoed 0 (got %d)" % got[1].target_type)
		var step := int(world.get("_attack_step"))
		world.call("_on_attack_result", got[0])
		_check(int(world.get("_attack_step")) == step + 1, "the repeat is drawn as a blow")
		world.call("_on_attack_result", got[1])
		_check(int(world.get("_attack_step")) == step + 1, "the self cast's echoed reply is not")
	# 2. A server that does not echo: the queue hands the repeat the self
	# cast's 0. A repeat on which the monster killed the player carries no
	# damage -- it must still be drawn, not swallowed as the cast's reply.
	got.clear()
	_net.set("_attack_targets_in_flight", [] as Array[int])
	_net.set("_attack_types_in_flight", [] as Array[int])
	world.call("_cast_skill", 113, "SKILL_CH_LIGHTNING_GYEONGGONG_A_01")
	_net.call("_dispatch", Packet.new(CombatNet.OP_ATTACK_RESULT, _attack_result_bytes("", 0, true, 100, 555, -1)))
	if got.size() == 1:
		_check(got[0].target_type == 0 and not got[0].target_type_echoed, "unechoed, the repeat is handed the queue's 0")
		var step2 := int(world.get("_attack_step"))
		world.call("_on_attack_result", got[0])
		_check(int(world.get("_attack_step")) == step2 + 1, "but carrying player_died it is drawn, not swallowed")
	else:
		_check(false, "one reply dispatched (got %d)" % got.size())
	# 3. Review item 5: a server that applies a type-0 cast to the caster
	# echoes 0 with no damage even when a monster was selected -- a quiet
	# accept, no swing, nothing refused.
	got.clear()
	_net.set("_attack_targets_in_flight", [] as Array[int])
	_net.set("_attack_types_in_flight", [] as Array[int])
	world.call("_cast_skill", 113, "SKILL_CH_LIGHTNING_GYEONGGONG_A_01")
	_net.call("_dispatch", Packet.new(CombatNet.OP_ATTACK_RESULT, _attack_result_bytes("", 0, false, 100, 555, 0)))
	if got.size() == 1:
		var step3 := int(world.get("_attack_step"))
		world.call("_on_attack_result", got[0])
		_check(int(world.get("_attack_step")) == step3, "an echoed type-0, no-damage reply naming the selection plays no swing")
		_check(int(world.get("_last_attack_target")) == 555, "and keeps the selection")
	else:
		_check(false, "one reply dispatched (got %d)" % got.size())
	_net.disconnect("attack_result", on_result)
	_net.set("_attack_targets_in_flight", [] as Array[int])
	_net.set("_attack_types_in_flight", [] as Array[int])

## Round 617's review: the own id from OpSelfId, and a monster's buff never
## moves this player's speed.
func _test_own_id(world: Node) -> void:
	var sc = world.get("_self_cast")
	if sc == null or not ("own_character_id" in _net):
		_check(false, "World3D has _self_cast and NetClient own_character_id")
		return
	var now := Time.get_ticks_msec()
	world.set("_move_speed", 50.0)
	# The fallback learned 4242 in _test_buffs_and_move; OpSelfId says 7777.
	(world.get("_sit") as RefCounted).set("own_id", 4242)
	_net.call("_dispatch", Packet.new(0x00F9, _u64(7777)))
	world.call("_on_self_id_received", 7777)
	_check(sc.own_id == 7777 and sc.own_id_told, "OpSelfId replaces the learned id (got %d)" % sc.own_id)
	_check(int((world.get("_sit") as RefCounted).get("own_id")) == 7777, "and the sit state's")
	sc.note_cast(113, now)
	world.call("_on_buff_started", _S.call("decode_buff_start", _with_kind(_buff_start_bytes(4242, 113, 41, 1000, 1000, 70), 0)))
	_check(is_equal_approx(float(world.get("_move_speed")), 50.0), "a buff on 4242 is not this player's any more, recent cast or not")
	world.call("_on_buff_started", _S.call("decode_buff_start", _with_kind(_buff_start_bytes(7777, 113, 42, 1000, 1000, 99), 1)))
	_check(is_equal_approx(float(world.get("_move_speed")), 50.0), "a MONSTER 7777's buff moves nothing, though the id matches")
	world.call("_on_buff_ended", _S.call("decode_buff_end", _with_kind(_buff_end_bytes(7777, [42], 99), 1)))
	_check(is_equal_approx(float(world.get("_move_speed")), 50.0), "nor does a monster's buff end")
	world.call("_on_buff_started", _S.call("decode_buff_start", _with_kind(_buff_start_bytes(7777, 113, 43, 1000, 1000, 60), 0)))
	_check(is_equal_approx(float(world.get("_move_speed")), 60.0), "character 7777's buff is this player's (got %s)" % str(world.get("_move_speed")))
	# Before any OpSelfId, a monster-kind owner is never learned as this player.
	sc.forget_owner()
	_net.set("own_character_id", -1)
	(world.get("_sit") as RefCounted).set("own_id", -1)
	sc.note_cast(113, now)
	world.set("_move_speed", 50.0)
	world.call("_on_buff_started", _S.call("decode_buff_start", _with_kind(_buff_start_bytes(8888, 113, 44, 1000, 1000, 99), 1)))
	_check(is_equal_approx(float(world.get("_move_speed")), 50.0) and sc.own_id == -1,
		"with no OpSelfId, a monster's buff after our cast is neither applied nor learned")
	world.set("_move_speed", 50.0)

## Round 617's review: a pick left on leaves with the world, cursor and all.
func _test_leave_world(world: Node) -> void:
	var sc = world.get("_self_cast")
	if sc == null or not world.has_method("_leave_ground_pick"):
		_check(false, "World3D has _leave_ground_pick")
		return
	world.call("_cast_skill", 114, "SKILL_CH_LIGHTNING_GYEONGGONG_B_01")
	_check(sc.picking() and int(world.get("_default_cursor_shape")) == Input.CURSOR_CROSS,
		"a pick shows the cross (got shape %d)" % int(world.get("_default_cursor_shape")))
	world.call("_leave_ground_pick", "test")
	_check(not sc.picking() and int(world.get("_default_cursor_shape")) == Input.CURSOR_ARROW,
		"leaving ends the pick and puts the arrow back (got shape %d)" % int(world.get("_default_cursor_shape")))
	var src := (load("res://scripts/World3D.gd") as GDScript).source_code
	var exit_at := src.find("func _exit_tree() -> void:")
	var disc_at := src.find("func _on_disconnected() -> void:")
	_check(exit_at >= 0 and src.find("_leave_ground_pick(", exit_at) - exit_at < 400,
		"_exit_tree ends the pick first thing")
	_check(disc_at >= 0 and src.find("_leave_ground_pick(", disc_at) - disc_at < 400,
		"_on_disconnected (Restart, Exit, a dropped peer) ends it too")
