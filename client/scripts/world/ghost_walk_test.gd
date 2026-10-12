extends SceneTree

## Round 616-618 integration's live leftovers, headless on the render box
## (`client/tools/remote_godot.sh tests`); synthetic data only.
##
## 1. A ground cast's landing (GhostWalk): clamped in 3-D to the row's tele
##    value[1], as the retail server's FUN_005862e0 clamps, then walked on the
##    navmesh and stopped at the first wall (no slide), at the ground's height;
##    the OpSkillMove answering it settles the player's footing at once.
## 2. A self cast's body animation from skilleffect.txt's skillaniset2 row
##    (round 785: its decoration, started when the server answers):
##    nothing when READY, WAIT and SHOT are all "none" (Grass Walk, the
##    imbues), the WAIT action type when there is one (Ghost Walk's
##    ANI_SKILL_7, type 32) -- never the weapon swing stand-in.
##
## Everything new is reached by name (load(), call(), callv()) so that
## against the base, which lacks it, the suite runs and FAILs check by check.
##
## NEGATIVE (int/skills 544a7a7, before this change): see the round 618
## Integration note in docs/WORLD_ISSUES.md for the FAIL lines. The review
## follow-up's own cases are ghost_walk_review_test.gd.

var _failures := 0
var _net: Node

const REACH := 100.0
## The synthetic region: flat terrain at TERRAIN_Y with a blocking terrain
## edge (flag 2, as nav_graph_test.gd's) along local x = WALL_X, z 0..400.
const TERRAIN_Y := 10.0
const WALL_X := 100.0

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
	_test_clamp()
	_test_no_slide()
	_test_catalog_tele()
	_test_aniset_parse()
	_net = root.get_node_or_null("NetClient")
	_check(_net != null, "the NetClient autoload is there")
	if _net != null:
		var world := _make_world()
		if world != null:
			_test_world_landing(world)
			_test_skill_move_footing(world)
			_test_cast_anim(world)
			root.remove_child(world)
			world.free()
		_net.set("_connected", false)
		_net.set("_peer", null)
	if _failures == 0:
		print("ALL PASS")
	else:
		print("%d FAILED" % _failures)
	quit(0 if _failures == 0 else 1)

# --- pure --------------------------------------------------------------------

func _ghost() -> GDScript:
	return load("res://scripts/world/ghost_walk.gd") as GDScript

func _test_clamp() -> void:
	var gw := _ghost()
	_check(gw != null, "GhostWalk (scripts/world/ghost_walk.gd) exists")
	if gw == null:
		return
	var from := Vector3(0, 0, 0)
	_check(gw.call("clamp_to_reach", from, Vector3(150, 0, 0), REACH) == Vector3(100, 0, 0),
		"a point 150 away with reach 100 is clamped to 100 along the line")
	_check(gw.call("clamp_to_reach", from, Vector3(80, 0, 0), REACH) == Vector3(80, 0, 0),
		"a point 80 away is kept")
	# 3-D, as retail's x*x + y*y + z*z: 100 across and 100 up is 141 away, so
	# the clamp lands 70.7 across -- a flat clamp would have kept the point.
	var c: Vector3 = gw.call("clamp_to_reach", from, Vector3(0, 100, 100), REACH)
	_check(absf(c.z - 70.7107) < 0.01 and absf(c.y - 70.7107) < 0.01,
		"the clamp is 3-D: (0, 100, 100) with reach 100 lands at (0, 70.7, 70.7) (got %s)" % str(c))

## A flat region with one blocking terrain edge between its two cells, as
## real terrain walls lie on cell boundaries: cell 0 is x 0..100, cell 1 the
## rest (the review follow-up; a wall inside one cell has no real analogue).
func _region() -> NvmReader.ParsedRegion:
	var r := NvmReader.ParsedRegion.new()
	r.heights.resize(NvmReader.HEIGHT_COUNT)
	r.heights.fill(TERRAIN_Y)
	for rect in [[Vector2.ZERO, Vector2(WALL_X, 1920.0)], [Vector2(WALL_X, 0.0), Vector2(1920.0, 1920.0)]]:
		var cell := NvmReader.Cell.new()
		cell.rect_min = rect[0]
		cell.rect_max = rect[1]
		r.cells.append(cell)
	for i in range(NvmReader.TILE_COUNT):
		var t := NvmReader.Tile.new()
		t.cell_index = 0 if (i % NvmReader.TILE_MAP_SIDE) * NavGraph.TILE_SIZE < WALL_X else 1
		r.tiles.append(t)
	var e := NvmReader.Edge.new()
	e.flags = 2
	e.line_min = Vector2(WALL_X, 0.0)
	e.line_max = Vector2(WALL_X, 400.0)
	r.internal_edges = [e]
	return r

func _graph() -> NavGraph:
	return NavGraph.build(_region(), [] as Array[NavGraph.PlacedObject])

func _test_no_slide() -> void:
	var g := _graph()
	# A move at 45 degrees into the wall: sliding runs on along it; the skill
	# move stops where the line meets it, moved toward the centre of the
	# mover's cell (50, 960) by 0.2 (FUN_009c1050, the review follow-up).
	var slid = g.callv("step_tracked", [Vector3(50, TERRAIN_Y, 200), Vector2(100, 100), NavGraph.ON_TERRAIN])
	var stopped = g.callv("step_tracked", [Vector3(50, TERRAIN_Y, 200), Vector2(100, 100), NavGraph.ON_TERRAIN, false])
	_check(slid != null and slid.position.z > 290.0, "a walk into the wall slides along it (z %s)" % (str(slid.position.z) if slid != null else "-"))
	var want := Vector2(100, 250) + (Vector2(50, 960) - Vector2(100, 250)).normalized() * 0.2
	_check(stopped != null and stopped.blocked and Vector2(stopped.position.x, stopped.position.z).distance_to(want) < 0.001,
		"step_tracked(..., slide false) stops at the wall's crossing moved 0.2 toward the cell centre, %s (got %s)" % [
			str(want), str(stopped.position) if stopped != null else "no such argument"])

func _test_catalog_tele() -> void:
	var cols := PackedStringArray()
	cols.resize(80)
	cols.fill("0")
	cols[1] = "114"
	cols[7] = "1"
	cols[61] = "icon.ddj"
	cols[62] = "SN_X"
	cols[64] = "SN_X_DESC"
	# 'tele' 500 100 as the Param block's first run ("tele" big-endian).
	cols[69] = str(0x74656c65)
	cols[70] = "500"
	cols[71] = "100"
	var info: Dictionary = SkillBuffCatalog.parse_row(cols)
	_check(info.get("tele", null) == [500, 100], "the catalog keeps 'tele' value[0] and value[1] (got %s)" % str(info.get("tele", null)))
	var cat := SkillBuffCatalog.new(null)
	cat.set_row(info)
	_check(cat.has_method("tele_reach") and is_equal_approx(float(cat.call("tele_reach", 114)), REACH),
		"tele_reach(114) is value[1], 100")
	cols[69] = "0"
	var none: Dictionary = SkillBuffCatalog.parse_row(cols)
	_check(none.get("tele", null) == [], "a row without 'tele' has none")

func _utf16(text: String) -> PackedByteArray:
	var out := PackedByteArray([0xFF, 0xFE])
	out.append_array(text.to_utf16_buffer())
	return out

func _test_aniset_parse() -> void:
	var ser := load("res://scripts/effects/skill_effect_reader.gd") as GDScript
	var has := false
	for m in ser.get_script_method_list():
		if m["name"] == "parse_aniset":
			has = true
	_check(has, "SkillEffectReader.parse_aniset exists")
	if not has:
		return
	var head := "\t".join(PackedStringArray(["1", "n", "SKILL_TEST_%s", "0", "FALSE", "0", "DEFAULT"]))
	var text := "\n".join(PackedStringArray([
		"#section\tcharacterInfo",
		"CHAR_X\tPCM_X\t2",
		"#section\tskillaniset2",
		" //\tSkillName\tSkillID\tPriority\tAniTRUE\tHide Weapon\tAniGroup\tAniReady\tAniWait\tAniShot",
		head % "NONE" + "\tnone\tnone\tnone\tnone\tnone\tnone",
		head % "WAIT" + "\tnone\tANI_SKILL_7\tnone\tnone\tnone\tnone",
		head % "LIST" + "\tANI_READY04\tANI_WAIT04\tANI_SKILL_1,ANI_SHOT,ANI_SKILL_11\tnone\tnone\tnone",
		"#section\tskilleffectset",
		head % "OTHER" + "\tnone\tANI_SKILL_7\tnone",
	]))
	var sets: Dictionary = ser.call("parse_aniset", _utf16(text))
	# Round 640 adds "priority" (col 3) and, when col 13 names one, "defense"
	# to a row; the lists and the group are what this test is about.
	var lists := func(row: Dictionary) -> Dictionary:
		return {"group": row.get("group"), "ready": row.get("ready"), "wait": row.get("wait"), "shot": row.get("shot")}
	_check(lists.call(sets.get("SKILL_TEST_NONE", {})) == {"group": "default", "ready": [], "wait": [], "shot": []}, "an all-none row has three empty lists and its AniGroup")
	_check(sets.get("SKILL_TEST_WAIT", {}).get("wait", []) == [32], "ANI_SKILL_7 is action type 32 (0x20, FUN_009e5240)")
	_check(lists.call(sets.get("SKILL_TEST_LIST", {})) == {"group": "default", "ready": [43], "wait": [94], "shot": [26, 68]},
		"lists split on commas, ANI_READY04 43, ANI_WAIT04 94, and ANI_SHOT (not in the map) is dropped (got %s)" % str(sets.get("SKILL_TEST_LIST", {})))
	_check(not sets.has("SKILL_TEST_OTHER"), "rows of other sections are not animation rows")
	_check(ser.call("aniset_for", sets, "SKILL_TEST_WAIT_03") == sets.get("SKILL_TEST_WAIT", {}), "a level suffix is tolerated")
	# Round 785: the decoration's plan (SkillDeco.plan, FUN_00a54f00).
	var deco := load("res://scripts/effects/skill_deco.gd") as GDScript
	_check(String(deco.call("plan", sets["SKILL_TEST_NONE"], 0)["kind"]) == "none", "all-none plays nothing")
	var w: Dictionary = deco.call("plan", sets["SKILL_TEST_WAIT"], 0)
	_check(int(w["wait"]) == 32 and String(w["group"]) == "default", "a WAIT plays its type in the row's group")
	_check(String(deco.call("plan", {}, 0)["kind"]) == "none", "no row plays nothing (no stand-in)")

# --- the world ---------------------------------------------------------------

func _make_world() -> Node:
	var sub := GDScript.new()
	sub.source_code = "\n".join(PackedStringArray([
		"extends \"res://scripts/World3D.gd\"",
		"var cast_clips: Array = []",
		"var swings := 0",
		"var body_types: Array = []",
		"var body_groups: Array = []",
		"var ground_point := Vector3.ZERO",
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
		"func _play_weapon_swing_anim() -> float:",
		"\tswings += 1",
		"\treturn 1.0",
		"func _body_animation_for(_gender: String, action_type: int, _group: String = \"default\") -> BanReader.ParsedAnimation:",
		"\treturn null",
		"func _deco_play_clip(e: Dictionary, _phase: int, action_type: int, _loop: bool) -> void:",
		"\tbody_types.append(action_type)",
		"\tbody_groups.append(String(e[\"group\"]))",
		"func _audio_cast_start(_skill_id: int, _monster_id: int = -1, _fx_timings: Dictionary = {}) -> void:",
		"\tpass",
		"func _ground_point_at(_screen_pos: Vector2, _length: float = 2000.0) -> Variant:",
		"\treturn ground_point",
		""]))
	_check(sub.reload() == OK and sub.can_instantiate(), "a subclass of World3D.gd compiles")
	var scene := load("res://scenes/World3D.tscn") as PackedScene
	if not sub.can_instantiate() or scene == null:
		return null
	var world: Node = scene.instantiate()
	world.set_script(sub)
	root.add_child(world)
	var panels: Node = (load("res://scripts/ui/hud/hud_panels.gd") as GDScript).new()
	panels.set("_skill_catalog_loaded", true)
	panels.set("_skill_reach_by_id", {
		113: {"range": 0, "approach": false, "target_required": 0, "target_land": 0},
		114: {"range": 0, "approach": false, "target_required": 1, "target_land": 1},
	})
	world.set("_hud_panels", panels)
	var cat := SkillBuffCatalog.new(null)
	cat.set_row({"id": 114, "tele": [500, 100]})
	var board: Node = (load("res://scripts/ui/hud/hud_buff_board.gd") as GDScript).new(null, cat)
	world.set("_hud_buff_board", board)
	# The synthetic region at the world origin, identity transform.
	var group := Node3D.new()
	world.add_child(group)
	(world.get("_grid") as RegionGridState).add_nav_graph(0, 0, _graph(), group)
	world.set("_skill_anisets_loaded", true)
	world.set("_skill_anisets_cache", {
		"SKILL_CH_LIGHTNING_GYEONGGONG_A": {"group": "default", "ready": [], "wait": [], "shot": []},
		"SKILL_CH_LIGHTNING_GYEONGGONG_B": {"group": "default", "ready": [], "wait": [32], "shot": []},
	})
	_net.set("current_character_name", "Aria")
	return world

func _fresh_socket() -> StreamPeerBuffer:
	var buf := StreamPeerBuffer.new()
	_net.set("_peer", buf)
	_net.set("_connected", true)
	return buf

## The ground point of each OpUseSkill targetType 2 on the fake socket.
func _ground_sends(buf: StreamPeerBuffer) -> Array:
	var out: Array = []
	var bytes := buf.data_array
	var at := 0
	while at + Packet.HEADER_SIZE <= bytes.size():
		var size := bytes.decode_u16(at)
		var op := bytes.decode_u16(at + 2)
		var p := bytes.slice(at + Packet.HEADER_SIZE, at + Packet.HEADER_SIZE + size)
		at += Packet.HEADER_SIZE + size
		if op != 0x0072:
			continue
		var n := p.decode_u16(0)
		var i := 2 + n + 16
		if i < p.size() and p[i] == 2 and i + 13 <= p.size():
			out.append(Vector3(p.decode_float(i + 1), p.decode_float(i + 5), p.decode_float(i + 9)))
	return out

func _clear_in_flight() -> void:
	_net.set("_attack_targets_in_flight", [] as Array[int])
	if "_attack_types_in_flight" in _net:
		_net.set("_attack_types_in_flight", [] as Array[int])

## Picks `point` with Ghost Walk from `from`; returns the point sent, or null.
func _ghost_cast(world: Node, from: Vector3, point: Vector3) -> Variant:
	var player: Node3D = world.get("player")
	player.global_position = from
	world.set("_nav_footing_pos", Vector3.INF)
	world.set("_last_attack_target", -1)
	world.set("ground_point", point)
	var buf := _fresh_socket()
	# Round 785: the key casts at once at the cursor's point (no pick mode).
	world.call("_cast_skill", 114, "SKILL_CH_LIGHTNING_GYEONGGONG_B_01")
	var sends := _ground_sends(buf)
	_clear_in_flight()
	return sends[0] if sends.size() == 1 else null

func _test_world_landing(world: Node) -> void:
	var from := Vector3(50, TERRAIN_Y, 200)
	# Through the wall: 130 across and 30 up (133.4 away) is clamped to 100
	# along the line, then walked -- the wall at x 100 stops it, on the ground.
	var sent = _ghost_cast(world, from, Vector3(180, 40, 200))
	_check(sent != null and sent.x == WALL_X - 1.0 and sent.z == 200.0,
		"a pick behind a wall lands at the wall, truncated to (99, 200) (sent %s)" % str(sent))
	_check(sent != null and is_equal_approx(sent.y, TERRAIN_Y), "at the ground's height, 10 (sent y %s)" % (str(sent.y) if sent != null else "-"))
	# Open ground, within reach: the point itself, on the ground (not the 40
	# the pick came back with).
	sent = _ghost_cast(world, from, Vector3(50, 40, 120))
	_check(sent != null and sent.distance_to(Vector3(50, TERRAIN_Y, 120)) < 0.01,
		"an open pick in reach lands at the point, on the ground (sent %s)" % str(sent))
	# Out of reach in 3-D but not flat: the clamp is retail's 3-D one.
	sent = _ghost_cast(world, from, Vector3(50, 110, 300))
	_check(sent != null and sent.z == 270.0 and is_equal_approx(sent.y, TERRAIN_Y),
		"(0, 100, 100) away is clamped in 3-D to 70.7 across, truncated to 270, on the ground (sent %s)" % str(sent))

func _move_bytes(character: int, skill: int, p: Vector3) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(28)
	out.encode_s64(0, character)
	out.encode_s64(8, skill)
	out.encode_float(16, p.x)
	out.encode_float(20, p.y)
	out.encode_float(24, p.z)
	return out

func _test_skill_move_footing(world: Node) -> void:
	var skill_net := load("res://scripts/net/skill.gd") as GDScript
	var player: Node3D = world.get("player")
	var sc = world.get("_self_cast")
	if sc != null:
		sc.call("tell_own_id", 4242)
		sc.call("note_cast", 114, Time.get_ticks_msec())
	# The server moved the player to a point off the ground (its own 3-D
	# clamp): the footing is settled at once and the player stands on it.
	world.set("_ground_landing", null)
	world.call("_on_skill_moved", skill_net.call("decode_skill_move", _move_bytes(4242, 114, Vector3(60, 25, 200))))
	# Round 785: the move slides at 500 u/s; it is settled on arrival.
	world.call("_tick_skill_slides", 10.0)
	_check(player.position.distance_to(Vector3(60, TERRAIN_Y, 200)) < 0.01,
		"an OpSkillMove off the ground puts the player on it when it arrives (got %s)" % str(player.position))
	var graph = world.get("_nav_footing_graph")
	_check(graph != null and int(world.get("_nav_footing")) == NavGraph.ON_TERRAIN,
		"and the walk's footing is settled there (graph %s, footing %s)" % [str(graph), str(world.get("_nav_footing"))])
	_check((world.get("_nav_footing_pos") as Vector3).distance_to(player.global_position) < 0.01,
		"so the next step does not re-settle it")

func _test_cast_anim(world: Node) -> void:
	world.set("cast_clips", [])
	world.set("swings", 0)
	world.set("body_types", [])
	world.set("body_groups", [])
	world.set("_last_attack_target", -1)
	_fresh_socket()
	world.call("_cast_skill", 113, "SKILL_CH_LIGHTNING_GYEONGGONG_A_01")
	_clear_in_flight()
	_check((world.get("cast_clips") as Array).is_empty() and int(world.get("swings")) == 0 and (world.get("body_types") as Array).is_empty(),
		"Grass Walk (all none) plays no body animation and no swing (clips %s, swings %d)" % [str(world.get("cast_clips")), int(world.get("swings"))])
	world.set("cast_clips", [])
	world.set("_player_weapon_group", "sword")
	_ghost_cast(world, Vector3(50, TERRAIN_Y, 200), Vector3(50, TERRAIN_Y, 150))
	_check((world.get("body_types") as Array).is_empty(), "nothing plays at the send (round 785)")
	world.call("_fx_self_cast_accepted")
	_check((world.get("body_types") as Array) == [32] and (world.get("cast_clips") as Array).is_empty(),
		"Ghost Walk plays its WAIT, action type 32 (types %s, clips %s)" % [str(world.get("body_types")), str(world.get("cast_clips"))])
	_check((world.get("body_groups") as Array) == ["default"],
		"in the row's AniGroup, default, not the held sword's group (groups %s)" % str(world.get("body_groups")))
