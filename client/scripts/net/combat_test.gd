extends SceneTree

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _test_encode_attack() -> void:
	var encoded := CombatNet.encode_attack("Aria", 7)
	_check(encoded.decode_u16(0) == 4, "name length prefix is 4")
	_check(encoded.decode_s64(6) == 7, "target monster id round-trips")

func _build_attack_result(error: String, monster_damage: int, monster_hp: int, monster_died: bool,
		player_damage: int, player_hp: int, player_died: bool) -> PackedByteArray:
	var out := PackedByteArray()
	var error_bytes := error.to_utf8_buffer()
	var len_buf := PackedByteArray()
	len_buf.resize(2)
	len_buf.encode_u16(0, error_bytes.size())
	out.append_array(len_buf)
	out.append_array(error_bytes)

	var buf := PackedByteArray()
	buf.resize(18)
	buf.encode_u32(0, monster_damage)
	buf.encode_u32(4, monster_hp)
	buf[8] = 1 if monster_died else 0
	buf.encode_u32(9, player_damage)
	buf.encode_u32(13, player_hp)
	buf[17] = 1 if player_died else 0
	out.append_array(buf)
	return out

func _test_decode_attack_result() -> void:
	var payload := _build_attack_result("", 20, 20, false, 15, 85, false)
	var result := CombatNet.decode_attack_result(payload)
	_check(result.error == "", "no decode error")
	_check(result.monster_damage == 20, "monster_damage round-trips")
	_check(result.monster_remaining_hp == 20, "monster_remaining_hp round-trips")
	_check(not result.monster_died, "monster_died is false")
	_check(result.player_damage_taken == 15, "player_damage_taken round-trips")
	_check(result.player_hp == 85, "player_hp round-trips")
	_check(not result.player_died, "player_died is false")

## The four fields appended after the berserk tail: the death penalty's exp
## loss and the three combat outcomes. Each was added in its own release, so
## every intermediate width has to decode -- an 18-byte result, a 23-byte one
## with berserk, and every step up to 34.
func _test_decode_attack_result_appended_tail() -> void:
	var base := _build_attack_result("", 20, 20, false, 15, 85, false)
	var tail := PackedByteArray()
	tail.resize(16)
	tail.encode_u32(0, 64)        # berserk gauge
	tail[4] = 1                   # berserk active
	tail.encode_s64(5, 25900)     # death exp lost
	tail[13] = 1                  # monster critical
	tail[14] = 1                  # player critical
	tail[15] = 1                  # player blocked
	var full := base.duplicate()
	full.append_array(tail)

	var r := CombatNet.decode_attack_result(full)
	_check(r.berserk_gauge == 64, "berserk_gauge round-trips")
	_check(r.berserk_active, "berserk_active round-trips")
	_check(r.death_exp_lost == 25900, "death_exp_lost round-trips")
	_check(r.monster_critical, "monster_critical round-trips")
	_check(r.player_critical, "player_critical round-trips")
	_check(r.player_blocked, "player_blocked round-trips")

	# Every shorter width still decodes, reporting only what it carries --
	# an older server must never make the client report a truncated field as
	# a real value.
	for width in [0, 5, 13, 14, 15]:
		var short := base.duplicate()
		short.append_array(tail.slice(0, width))
		var s2 := CombatNet.decode_attack_result(short)
		_check(s2.error == "", "a %d-byte tail still decodes" % width)
		_check(s2.monster_damage == 20, "a %d-byte tail keeps the base fields" % width)
		if width < 13:
			_check(s2.death_exp_lost == 0, "a %d-byte tail reports no exp loss" % width)
		if width < 14:
			_check(not s2.monster_critical, "a %d-byte tail reports no monster crit" % width)
		if width < 15:
			_check(not s2.player_critical, "a %d-byte tail reports no player crit" % width)
		if width < 16:
			_check(not s2.player_blocked, "a %d-byte tail reports no block" % width)

func _test_decode_attack_result_deaths() -> void:
	var payload := _build_attack_result("", 20, 0, true, 0, 100, false)
	var result := CombatNet.decode_attack_result(payload)
	_check(result.monster_died, "monster_died is true")
	_check(result.player_damage_taken == 0, "no counterattack when monster died")

func _test_decode_monster_damaged() -> void:
	var buf := PackedByteArray()
	buf.resize(16)
	buf.encode_s64(0, 1)
	buf.encode_u32(8, 20)
	buf.encode_u32(12, 80)
	var m := CombatNet.decode_monster_damaged(buf)
	_check(m != null, "decodes successfully")
	if m != null:
		_check(m.monster_id == 1, "monster_id round-trips")
		_check(m.damage == 20, "damage round-trips")
		_check(m.remaining_hp == 80, "remaining_hp round-trips")

func _test_decode_monster_died() -> void:
	var buf := PackedByteArray()
	buf.resize(8)
	buf.encode_s64(0, 42)
	_check(CombatNet.decode_monster_died(buf) == 42, "monster id round-trips")

func _build_loot_dropped(monster_id: int, drops: Array) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(8)
	out.encode_s64(0, monster_id)
	var count_buf := PackedByteArray()
	count_buf.resize(2)
	count_buf.encode_u16(0, drops.size())
	out.append_array(count_buf)
	for d in drops:
		var buf := PackedByteArray()
		buf.resize(12)
		buf.encode_s64(0, d["item_id"])
		buf.encode_u32(8, d["quantity"])
		out.append_array(buf)
	return out

func _test_decode_loot_dropped() -> void:
	var payload := _build_loot_dropped(1, [{"item_id": 500, "quantity": 1}, {"item_id": 600, "quantity": 3}])
	var result := CombatNet.decode_loot_dropped(payload)
	_check(result != null, "decodes successfully")
	if result != null:
		_check(result.monster_id == 1, "monster id round-trips")
		_check(result.drops.size() == 2, "two drops decoded")
		if result.drops.size() == 2:
			_check(result.drops[0].item_id == 500, "first drop item id round-trips")
			_check(result.drops[0].quantity == 1, "first drop quantity round-trips")
			_check(result.drops[1].item_id == 600, "second drop item id round-trips")
			_check(result.drops[1].quantity == 3, "second drop quantity round-trips")

func _test_decode_loot_dropped_empty() -> void:
	var payload := _build_loot_dropped(1, [])
	var result := CombatNet.decode_loot_dropped(payload)
	_check(result != null, "decodes successfully with no drops")
	if result != null:
		_check(result.drops.size() == 0, "no drops")

func _build_monster_snapshot(id: int, name: String, x: float, y: float, z: float, max_hp: int, hp: int, code: String = "", level: int = 0, rarity: int = 0) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(8)
	out.encode_s64(0, id)
	for text in [name, code]:
		var text_bytes: PackedByteArray = text.to_utf8_buffer()
		var len_buf := PackedByteArray()
		len_buf.resize(2)
		len_buf.encode_u16(0, text_bytes.size())
		out.append_array(len_buf)
		out.append_array(text_bytes)
	var pos_buf := PackedByteArray()
	pos_buf.resize(12)
	pos_buf.encode_float(0, x)
	pos_buf.encode_float(4, y)
	pos_buf.encode_float(8, z)
	out.append_array(pos_buf)
	var hp_buf := PackedByteArray()
	hp_buf.resize(16)
	hp_buf.encode_u32(0, max_hp)
	hp_buf.encode_u32(4, hp)
	hp_buf.encode_u32(8, level)
	hp_buf.encode_u32(12, rarity)
	out.append_array(hp_buf)
	return out

func _build_monster_list_result(error: String, monsters: Array) -> PackedByteArray:
	var out := PackedByteArray()
	var len_buf := PackedByteArray()
	len_buf.resize(2)
	var error_bytes := error.to_utf8_buffer()
	len_buf.encode_u16(0, error_bytes.size())
	out.append_array(len_buf)
	out.append_array(error_bytes)
	if error != "":
		return out
	var count_buf := PackedByteArray()
	count_buf.resize(2)
	count_buf.encode_u16(0, monsters.size())
	out.append_array(count_buf)
	for m in monsters:
		out.append_array(_build_monster_snapshot(m["id"], m["name"], m.get("x", 0.0), m.get("y", 0.0), m.get("z", 0.0), m["max_hp"], m["hp"], m.get("code", ""), m.get("level", 0), m.get("rarity", 0)))
	return out

func _test_decode_monster_list_result() -> void:
	var payload := _build_monster_list_result("", [
		{"id": 1, "name": "Stone Golem", "code": "MOB_TEST_GOLEM", "x": 15.0, "y": 0.0, "z": 10.0, "max_hp": 200, "hp": 150, "level": 12, "rarity": 4},
		{"id": 2, "name": "Weasel", "x": -55.0, "y": 0.0, "z": 58.0, "max_hp": 80, "hp": 80},
	])
	var result := CombatNet.decode_monster_list_result(payload)
	_check(result.error == "", "no decode error")
	_check(result.monsters.size() == 2, "two monsters decoded")
	if result.monsters.size() == 2:
		_check(result.monsters[0].x == 15.0, "x round-trips")
		_check(result.monsters[0].z == 10.0, "z round-trips")
		_check(result.monsters[0].monster_id == 1, "monster id round-trips")
		_check(result.monsters[0].monster_name == "Stone Golem", "monster name round-trips")
		_check(result.monsters[0].code_name == "MOB_TEST_GOLEM", "the species' code name round-trips")
		_check(result.monsters[0].max_hp == 200, "max hp round-trips")
		_check(result.monsters[0].hp == 150, "hp round-trips")
		_check(result.monsters[0].level == 12, "monster level round-trips")
		_check(result.monsters[0].rarity == 4, "monster rarity round-trips")
		_check(result.monsters[1].code_name == "" and result.monsters[1].monster_name == "Weasel",
			"a monster without a code name decodes, and the next one after it is intact")

func _test_decode_monster_list_result_error() -> void:
	var payload := _build_monster_list_result("not in the world", [])
	var result := CombatNet.decode_monster_list_result(payload)
	_check(result.error == "not in the world", "error round-trips")
	_check(result.monsters.size() == 0, "no monsters alongside an error")

## The attack-distance rule, mirrored from server/internal/combat/reach.go
## (Tick_Attack 0x004ad8e0 phase 0, Action_IsTargetWithinReach 0x004ad4a0).
## The expected pairs are reach.go's own band cases: a sword (6) against a
## Mangyang (BCRadius 6), a dagger-like 3, the short-band edge 4, a spear
## (18) against a Gyo (10), a bow (180) against a Yeoha (11), bare hands,
## and the exactly-10 hole round 488 fixed.
func _test_approach_band() -> void:
	var cases := [
		[4, 6, 6.0, Vector2(14.0, 16.0)],
		[4, 6, 3.0, Vector2(13.0, 13.0)],
		[4, 6, 4.0, Vector2(14.0, 14.0)],
		[4, 10, 18.0, Vector2(26.6, 32.0)],
		[4, 11, 180.0, Vector2(141.0, 195.0)],
		[4, 6, 0.0, Vector2(10.0, 10.0)],
		[4, 6, 10.0, Vector2(10.0, 10.0)],
	]
	for c in cases:
		var got := CombatNet.approach_band(int(c[0]), int(c[1]), float(c[2]))
		var want: Vector2 = c[3]
		_check(got.is_equal_approx(want), "approach_band(%d, %d, %s) is %s (got %s)" % [
			int(c[0]), int(c[1]), str(c[2]), str(want), str(got)])
	_check(CombatNet.effective_range(0, 6) == 6.0, "a skill with no Range uses the weapon's")
	_check(CombatNet.effective_range(150, 6) == 150.0, "a skill with its own Range uses that")
	_check(CombatNet.effective_range(0, 0) == 0.0, "no skill range and no weapon: 0")

func _test_in_reach() -> void:
	_check(CombatNet.in_reach(16.0, 16.0), "in reach at exactly the reach")
	_check(CombatNet.in_reach(18.9, 16.0), "in reach at 18.9 against 16: int(18.9) = 18 <= 16 + 2")
	_check(CombatNet.in_reach(0.0, 16.0), "in reach standing on the target")
	_check(not CombatNet.in_reach(19.0, 16.0), "out of reach at 19 against 16")
	# A bow at 150 from a Yeoha: reach 195, so the click fires where it stands.
	var bow := CombatNet.approach_band(CombatNet.PLAYER_BC_RADIUS, 11, CombatNet.effective_range(0, 180))
	_check(CombatNet.in_reach(150.0, bow.y), "a bow user 150 away from a Yeoha is in reach (reach %s): no walk" % str(bow.y))

## NEGATIVE -- the decision the client got wrong before it could walk: a sword
## user who clicks a Mangyang 40 units away used to send at once and get "too
## far away". 40 is out of the 16 reach, and the walk ends 14 short of the
## target, on the line from the target back to the player.
func _test_approach_from_forty() -> void:
	var band := CombatNet.approach_band(CombatNet.PLAYER_BC_RADIUS, 6, CombatNet.effective_range(0, 6))
	_check(not CombatNet.in_reach(40.0, band.y), "40 units from a Mangyang with a sword is out of reach %s" % str(band.y))
	var point := CombatNet.approach_point(Vector2(40.0, 0.0), Vector2(0.0, 0.0), band.x)
	_check(point.is_equal_approx(Vector2(14.0, 0.0)), "the walk from (40, 0) stops at (14, 0) (got %s)" % str(point))
	var diagonal := CombatNet.approach_point(Vector2(30.0, 40.0), Vector2(0.0, 0.0), 14.0)
	_check(diagonal.is_equal_approx(Vector2(8.4, 11.2)), "a diagonal walk stops 14 short along the line (got %s)" % str(diagonal))
	_check(CombatNet.approach_point(Vector2(5.0, 0.0), Vector2(0.0, 0.0), 14.0) == Vector2(5.0, 0.0),
		"a walker already inside the stop distance stays put")
	_check(CombatNet.approach_point(Vector2(0.0, 0.0), Vector2(0.0, 0.0), 14.0) == Vector2(0.0, 0.0),
		"a walker on the target stays put (no division by zero)")

## NEGATIVE -- the decision round 519's first cut got wrong: it walked for
## every cast. Tick_UseSkill (0x004ae590) phase 0 casts a Target_Required 0 row
## (0x4ae743) and a land-targeted one (0x4ae753, Target_Required 1 with
## TargetType_Land 1) with no band and no walk; only the other rows walk.
func _test_skill_tick_approaches() -> void:
	_check(not CombatNet.skill_tick_approaches(0, 0),
		"Target_Required 0 (a self heal, a shield): cast where the player stands, no walk")
	_check(not CombatNet.skill_tick_approaches(0, 1),
		"Target_Required 0 with a land byte: still no walk (the 0x4ae743 jump comes first)")
	_check(not CombatNet.skill_tick_approaches(1, 1),
		"Target_Required 1 on a land target: no walk (0x4ae753)")
	_check(CombatNet.skill_tick_approaches(1, 0),
		"Target_Required 1 on a unit (Smash, a heal on another): walks into reach")
	_check(CombatNet.skill_tick_approaches(2, 1),
		"Target_Required other than 0/1 (no China board row has one; the asm's own branch): the land test is skipped (0x4ae74b jne), so it walks")

## The protocol table's fixture (docs/protocol/monster_ai.md, "srrevamp's own
## monster protocol (placeholders)"): monster 7 from (100,-200) to
## (140,-200) at 8 u/s, walking.
const MOVED_FIXTURE := [0x07, 0, 0, 0, 0, 0, 0, 0, 0x00, 0x00, 0xc8, 0x42, 0x00, 0x00, 0x48, 0xc3,
	0x00, 0x00, 0x0c, 0x43, 0x00, 0x00, 0x48, 0xc3, 0x00, 0x00, 0x00, 0x41, 0x00]
const MOTION_LIST_FIXTURE := [0x01, 0x00, 0x07, 0, 0, 0, 0, 0, 0, 0, 0x00, 0x00, 0x0c, 0x43,
	0x00, 0x00, 0x48, 0xc3, 0x00, 0x00, 0x00, 0x41, 0x00]

func _test_decode_monster_moved() -> void:
	var data := PackedByteArray(MOVED_FIXTURE)
	_check(data.size() == 29, "the OpMonsterMoved fixture is 29 bytes")
	var m := CombatNet.decode_monster_moved(data)
	_check(m != null and m.monster_id == 7, "OpMonsterMoved: the monster id")
	_check(m != null and m.x == 100.0 and m.z == -200.0, "OpMonsterMoved: the server position (100,-200)")
	_check(m != null and m.dest_x == 140.0 and m.dest_z == -200.0, "OpMonsterMoved: the destination (140,-200)")
	_check(m != null and m.speed == 8.0 and m.mode == 0, "OpMonsterMoved: 8 u/s, mode 0 (walk)")
	_check(CombatNet.decode_monster_moved(data.slice(0, 28)) == null, "28 bytes decode to null")

func _test_decode_monster_motion_list() -> void:
	var data := PackedByteArray(MOTION_LIST_FIXTURE)
	_check(data.size() == 23, "the OpMonsterMotionList fixture is 23 bytes")
	var entries := CombatNet.decode_monster_motion_list(data)
	_check(entries.size() == 1, "one entry")
	if entries.size() == 1:
		var e: CombatNet.MotionEntry = entries[0]
		_check(e.monster_id == 7 and e.dest_x == 140.0 and e.dest_z == -200.0 and e.speed == 8.0 and e.mode == 0,
			"the entry is monster 7 to (140,-200) at 8, mode 0")
	# n = 2, with the second entry cut short: the whole first one is kept.
	var two := data.duplicate()
	two.encode_u16(0, 2)
	two.append_array(data.slice(2, 12))
	_check(CombatNet.decode_monster_motion_list(two).size() == 1, "n=2 with a truncated second entry gives 1 entry")
	_check(CombatNet.decode_monster_motion_list(PackedByteArray([1])).is_empty(), "a payload without its count gives none")

## The protocol table's OpMonsterAttacked fixture (docs/protocol/monster_ai.md,
## "srrevamp's own monster protocol (placeholders)"): monster 7 strikes
## character 42 for 200, critical and killing (flags 0x05), which leaves it on
## 76 HP and costs it 25900 experience. The numbers are a fixture, not any
## species' own.
const STRIKE_FIXTURE := [0x07, 0, 0, 0, 0, 0, 0, 0, 0x2a, 0, 0, 0, 0, 0, 0, 0,
	0xc8, 0x00, 0x00, 0x00, 0x05, 0x4c, 0x00, 0x00, 0x00, 0x2c, 0x65, 0, 0, 0, 0, 0, 0]
## And its OpMonsterSpawned fixture: monster 31, "Mob" / MOB_TEST (a fixture
## species), at (100, 0, -200) with 100/100 HP, level 1, rarity 0, heading
## pi/2 (f32 0x3fc90fdb) -- facing +z.
const SPAWN_FIXTURE := [0x1f, 0, 0, 0, 0, 0, 0, 0, 0x03, 0x00, 0x4d, 0x6f, 0x62,
	0x08, 0x00, 0x4d, 0x4f, 0x42, 0x5f, 0x54, 0x45, 0x53, 0x54,
	0x00, 0x00, 0xc8, 0x42, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x48, 0xc3,
	0x64, 0, 0, 0, 0x64, 0, 0, 0, 0x01, 0, 0, 0, 0x00, 0, 0, 0,
	0xdb, 0x0f, 0xc9, 0x3f]

func _test_decode_monster_attacked() -> void:
	var data := PackedByteArray(STRIKE_FIXTURE)
	_check(data.size() == CombatNet.MONSTER_ATTACKED_SIZE, "the OpMonsterAttacked fixture is 33 bytes")
	var m := CombatNet.decode_monster_attacked(data)
	_check(m != null and m.monster_id == 7 and m.target_character_id == 42, "OpMonsterAttacked: monster 7 on character 42")
	_check(m != null and m.damage == 200 and m.target_hp == 76, "OpMonsterAttacked: 200 damage, 76 HP after it")
	_check(m != null and m.critical and not m.blocked and m.target_died, "OpMonsterAttacked: flags 0x05 are critical and died, not blocked")
	_check(m != null and m.death_exp_lost == 25900, "OpMonsterAttacked: 25900 experience lost")
	# A blocked blow: bit 1 alone, 0 damage.
	var blocked := data.duplicate()
	blocked.encode_s32(16, 0)
	blocked[20] = CombatNet.STRIKE_BLOCKED
	var b := CombatNet.decode_monster_attacked(blocked)
	_check(b != null and b.blocked and not b.critical and not b.target_died and b.damage == 0,
		"flags 0x02 alone is a block that dealt nothing")
	_check(CombatNet.decode_monster_attacked(data.slice(0, 32)) == null, "32 bytes decode to null")
	var longer := data.duplicate()
	longer.append(0xff)
	_check(CombatNet.decode_monster_attacked(longer) != null, "a byte past the 33rd is ignored")

## Round 640: the wall suffix on OpMonsterAttacked (after 33 bytes) and on
## OpAttackResult (after the echoed targetType), and its absence.
func _test_decode_wall_suffix() -> void:
	var data := PackedByteArray(STRIKE_FIXTURE)
	var m := CombatNet.decode_monster_attacked(data)
	_check(m != null and m.wall == null, "a 33-byte OpMonsterAttacked has no wall")
	var walled := data.duplicate()
	var suffix := PackedByteArray()
	suffix.resize(13)
	suffix[0] = CombatNet.WALL_ABSORBED | CombatNet.WALL_BROKE
	suffix.encode_s32(1, 321)
	suffix.encode_s32(5, 0)
	suffix.encode_s32(9, 1159)
	walled.append_array(suffix)
	m = CombatNet.decode_monster_attacked(walled)
	_check(m != null and m.wall != null and m.wall.absorbed and m.wall.broke and not m.wall.critical,
		"the wall suffix's flags: absorbed and broke")
	_check(m != null and m.wall != null and m.wall.damage == 321 and m.wall.hp == 0 and m.wall.max_hp == 1159,
		"the wall suffix's numbers: 321 on a 1159-HP wall, 0 left")
	var ar := _build_attack_result("", 0, 0, false, 0, 150, false)
	var tail := PackedByteArray()
	tail.resize(25) # berserk 5, exp 8, three flags, monster id 8, target type 1
	tail[24] = 0
	ar.append_array(tail)
	_check(CombatNet.decode_attack_result(ar).wall == null, "an OpAttackResult ending at its targetType has no wall")
	var toggled := suffix.duplicate()
	toggled[0] = CombatNet.WALL_TOGGLED_OFF
	ar.append_array(toggled)
	var r := CombatNet.decode_attack_result(ar)
	_check(r.wall != null and r.wall.toggled_off and not r.wall.absorbed and r.player_hp == 150,
		"an OpAttackResult with the toggle-off marker")

func _test_decode_monster_spawned() -> void:
	var data := PackedByteArray(SPAWN_FIXTURE)
	_check(data.size() == 55, "the OpMonsterSpawned fixture is 55 bytes")
	# The record is OpMonsterListResult's own: the list's record builder,
	# then the f32 heading, gives the fixture byte for byte.
	var built := _build_monster_snapshot(31, "Mob", 100.0, 0.0, -200.0, 100, 100, "MOB_TEST", 1, 0)
	var heading := PackedByteArray()
	heading.resize(4)
	heading.encode_float(0, PI / 2.0)
	built.append_array(heading)
	_check(built == data, "the list's record plus the heading is the fixture")
	var s := CombatNet.decode_monster_spawned(data)
	_check(s != null and s.monster != null and s.monster.monster_id == 31, "OpMonsterSpawned: monster 31")
	if s != null and s.monster != null:
		_check(s.monster.monster_name == "Mob" and s.monster.code_name == "MOB_TEST", "OpMonsterSpawned: the list record's name and code")
		_check(s.monster.x == 100.0 and s.monster.y == 0.0 and s.monster.z == -200.0, "OpMonsterSpawned: at (100, 0, -200)")
		_check(s.monster.max_hp == 100 and s.monster.hp == 100 and s.monster.level == 1 and s.monster.rarity == 0,
			"OpMonsterSpawned: 100/100 HP, level 1, rarity 0")
		_check(is_equal_approx(s.heading, PI / 2.0), "OpMonsterSpawned: heading pi/2 (got %s)" % str(s.heading))
	_check(CombatNet.decode_monster_spawned(data.slice(0, 54)) == null, "a heading cut short decodes to null")
	_check(CombatNet.decode_monster_spawned(data.slice(0, 20)) == null, "a record cut short decodes to null")

## NEGATIVE (fails before round 540, where 0x007D and 0x007E fell to the
## unhandled-opcode branch and no signal carried them): NetClient routes both
## pushes to their signals, drops a short one rather than emitting null, and no
## longer warns about either as unhandled.
func _test_net_client_dispatch_strike_spawn() -> void:
	var nc: Node = (load("res://scripts/net/net_client.gd") as GDScript).new()
	_check(nc.has_signal("monster_attacked") and nc.has_signal("monster_spawned"),
		"NetClient has the monster_attacked and monster_spawned signals")
	if not (nc.has_signal("monster_attacked") and nc.has_signal("monster_spawned")):
		nc.free()
		return
	var strikes: Array = []
	var spawns: Array = []
	nc.connect("monster_attacked", func(m): strikes.append(m))
	nc.connect("monster_spawned", func(m): spawns.append(m))
	nc.call("_dispatch", Packet.new(CombatNet.OP_MONSTER_ATTACKED, PackedByteArray(STRIKE_FIXTURE)))
	_check(strikes.size() == 1 and strikes[0].damage == 200, "0x007D reaches monster_attacked")
	nc.call("_dispatch", Packet.new(CombatNet.OP_MONSTER_ATTACKED, PackedByteArray(STRIKE_FIXTURE).slice(0, 20)))
	_check(strikes.size() == 1, "a short 0x007D is dropped, not emitted as null")
	nc.call("_dispatch", Packet.new(CombatNet.OP_MONSTER_SPAWNED, PackedByteArray(SPAWN_FIXTURE)))
	_check(spawns.size() == 1 and spawns[0].monster.monster_id == 31, "0x007E reaches monster_spawned")
	nc.call("_dispatch", Packet.new(CombatNet.OP_MONSTER_SPAWNED, PackedByteArray(SPAWN_FIXTURE).slice(0, 30)))
	_check(spawns.size() == 1, "a short 0x007E is dropped, not emitted as null")
	var warned: Dictionary = nc.get("_unhandled_warned")
	_check(not warned.has(0x007d) and not warned.has(0x007e), "neither is warned about as unhandled")
	nc.free()

## The approach walk's release, aim and refusal rules (round 533).
func _test_approach_release_rules() -> void:
	# Mangyang, unarmed: stop = reach = 10 (approach_band(4, 6, 0)).
	_check(CombatNet.approach_releases(12.9, 10.0, 10.0, false), "a standing target releases at the slack edge (int 12 <= 10 + 2)")
	_check(not CombatNet.approach_releases(12.9, 10.0, 10.0, true), "a moving target does not release at the slack edge")
	_check(CombatNet.approach_releases(10.0, 10.0, 10.0, true) and not CombatNet.approach_releases(10.1, 10.0, 10.0, true),
		"a moving target releases at the stop distance")
	_check(is_equal_approx(CombatNet.approach_aim(10.0, true, 2.39), 7.61) and CombatNet.approach_aim(10.0, false, 2.39) == 10.0,
		"a tight walk aims its arrival tolerance short of the stop")
	_check(CombatNet.approach_aim(1.0, true, 2.39) == 0.0, "never past the target")
	_check(CombatNet.should_rewalk("too far away", true, 0, 0), "a too-far refusal of a swing on a live target walks again")
	_check(CombatNet.should_rewalk("too far away", true, CombatNet.APPROACH_RETRY_CAP - 1, 0), "up to the cap")
	_check(not CombatNet.should_rewalk("too far away", true, CombatNet.APPROACH_RETRY_CAP, 0), "not past it")
	_check(not CombatNet.should_rewalk("too far away", false, 0, 0), "not on a dead or dying target")
	_check(not CombatNet.should_rewalk("skill on cooldown", true, 0, 0), "not on another refusal")
	# NEGATIVE (round 534; before it a refused skill walked and was sent again,
	# playing a second cast): a skill release is never re-walked.
	_check(not CombatNet.should_rewalk("too far away", true, 0, 50), "a too-far refusal of a SKILL does not walk again")

## NetClient routes the two new opcodes to their signals, and warns about an
## unhandled opcode once per connection rather than once per packet (an older
## client in a zone whose server runs the monster AI gets 0x007C many times a
## second).
func _test_net_client_dispatch() -> void:
	var nc: Node = (load("res://scripts/net/net_client.gd") as GDScript).new()
	var moved: Array = []
	var lists: Array = []
	nc.connect("monster_moved", func(m): moved.append(m))
	nc.connect("monster_motion_list", func(e): lists.append(e))
	nc.call("_dispatch", Packet.new(CombatNet.OP_MONSTER_MOVED, PackedByteArray(MOVED_FIXTURE)))
	_check(moved.size() == 1 and moved[0].dest_x == 140.0, "0x007C reaches monster_moved")
	nc.call("_dispatch", Packet.new(CombatNet.OP_MONSTER_MOVED, PackedByteArray(MOVED_FIXTURE).slice(0, 20)))
	_check(moved.size() == 1, "a short 0x007C is dropped, not emitted as null")
	nc.call("_dispatch", Packet.new(CombatNet.OP_MONSTER_MOTION_LIST, PackedByteArray(MOTION_LIST_FIXTURE)))
	_check(lists.size() == 1 and (lists[0] as Array).size() == 1, "0x007F reaches monster_motion_list")
	_check(bool(nc.call("_should_warn_unhandled", 0x7ffd)), "the first unhandled 0x7ffd warns")
	_check(not bool(nc.call("_should_warn_unhandled", 0x7ffd)), "the second does not")
	_check(bool(nc.call("_should_warn_unhandled", 0x7ffc)), "another opcode still warns once")
	nc.call("_dispatch", Packet.new(0x7ffe, PackedByteArray()))
	_check((nc.get("_unhandled_warned") as Dictionary).has(0x7ffe), "_dispatch records an unhandled opcode it warned about")
	nc.free()

func _init() -> void:
	_test_decode_monster_moved()
	_test_decode_monster_motion_list()
	_test_approach_release_rules()
	_test_net_client_dispatch()
	_test_decode_monster_attacked()
	_test_decode_wall_suffix()
	_test_decode_monster_spawned()
	_test_net_client_dispatch_strike_spawn()
	_test_encode_attack()
	_test_decode_attack_result()
	_test_decode_attack_result_appended_tail()
	_test_decode_attack_result_deaths()
	_test_decode_monster_damaged()
	_test_decode_monster_died()
	_test_decode_loot_dropped()
	_test_decode_loot_dropped_empty()
	_test_decode_monster_list_result()
	_test_decode_monster_list_result_error()
	_test_approach_band()
	_test_in_reach()
	_test_skill_tick_approaches()
	_test_approach_from_forty()

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
