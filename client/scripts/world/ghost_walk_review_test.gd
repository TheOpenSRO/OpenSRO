extends SceneTree

## The 616-618 integration review's follow-up, headless on the render box
## (`client/tools/remote_godot.sh tests`); synthetic data only.
##
## - the terrain-wall stop: the crossing moved toward the mover's cell centre
##   by at most 0.2, and put back to the walk's source point when that move
##   meets one of the cell's objects (FUN_009c1050 / FUN_009a05a0);
## - one NavGraph step per region: a time bound, a region crossing, and a
##   deck object straddling the border;
## - the landing truncated as retail's move record keeps it, and kept in
##   reach in 3-D (y included) so the server's clamp leaves it;
## - a cast refused while the reach is not known;
## - the matched-landing branch of the OpSkillMove settle;
## - the aniset: col 0 = 0 skipped, a repeated SkillID appended, the AniGroup
##   miss falling back to the body's default group, one shared parse.
##
## Reached by name where the base (ff459f0) lacks it, so the suite runs and
## FAILs there check by check (the negative, in docs/WORLD_ISSUES.md).

var _failures := 0
var _net: Node

const TERRAIN_Y := 10.5
const SPAN := 1920.0

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
	_test_terrain_stop()
	_test_cell_object_cancel()
	_test_timing()
	_test_region_crossing()
	_test_truncation_over_an_edge()
	_test_straddling_deck()
	_test_aniset_rules()
	_test_group_fallback()
	_net = root.get_node_or_null("NetClient")
	_check(_net != null, "the NetClient autoload is there")
	if _net != null:
		var world := _make_world()
		if world != null:
			_test_truncation(world)
			_test_reach_with_height(world)
			_test_matched_settle(world)
			_test_refused(world)
			_test_shared_table(world)
			root.remove_child(world)
			world.free()
		_net.set("_connected", false)
		_net.set("_peer", null)
	if _failures == 0:
		print("ALL PASS")
	else:
		print("%d FAILED" % _failures)
	quit(0 if _failures == 0 else 1)

# --- fixtures ----------------------------------------------------------------

## Flat terrain at TERRAIN_Y. With `wall`, two cells split at x = 100 and a
## blocking edge (flag 2) on that boundary, z 0..400.
func _region(wall: bool) -> NvmReader.ParsedRegion:
	var r := NvmReader.ParsedRegion.new()
	r.heights.resize(NvmReader.HEIGHT_COUNT)
	r.heights.fill(TERRAIN_Y)
	var rects: Array = [[Vector2.ZERO, Vector2(SPAN, SPAN)]]
	if wall:
		rects = [[Vector2.ZERO, Vector2(100, SPAN)], [Vector2(100, 0), Vector2(SPAN, SPAN)]]
	for rect in rects:
		var cell := NvmReader.Cell.new()
		cell.rect_min = rect[0]
		cell.rect_max = rect[1]
		r.cells.append(cell)
	for i in range(NvmReader.TILE_COUNT):
		var t := NvmReader.Tile.new()
		t.cell_index = 1 if wall and (i % NvmReader.TILE_MAP_SIDE) * NavGraph.TILE_SIZE >= 100.0 else 0
		r.tiles.append(t)
	if wall:
		var e := NvmReader.Edge.new()
		e.flags = 2
		e.line_min = Vector2(100, 0)
		e.line_max = Vector2(100, 400)
		r.internal_edges = [e]
	return r

func _cedge(v0: int, v1: int, cell_from: int, flags: int) -> BmsReader.CollisionEdge:
	var e := BmsReader.CollisionEdge.new()
	e.v0 = v0
	e.v1 = v1
	e.cell_from = cell_from
	e.cell_to = BmsReader.NO_CELL
	e.flags = flags
	return e

## A flat quad x0..x1, z0..z1 at height h, as two cells, every outline edge
## carrying `flags`.
func _deck(x0: float, x1: float, z0: float, z1: float, h: float, flags: int) -> BmsReader.CollisionMesh:
	var cm := BmsReader.CollisionMesh.new()
	for p in [Vector3(x0, h, z0), Vector3(x1, h, z0), Vector3(x1, h, z1), Vector3(x0, h, z1)]:
		var v := BmsReader.CollisionVertex.new()
		v.position = p
		cm.vertices.append(v)
	for tri in [[0, 1, 2], [0, 2, 3]]:
		var c := BmsReader.CollisionCell.new()
		c.a = tri[0]
		c.b = tri[1]
		c.c = tri[2]
		cm.cells.append(c)
	cm.outline_edges.append(_cedge(0, 1, 0, flags))
	cm.outline_edges.append(_cedge(1, 2, 0, flags))
	cm.outline_edges.append(_cedge(2, 3, 1, flags))
	cm.outline_edges.append(_cedge(3, 0, 1, flags))
	var d := BmsReader.CollisionEdge.new()
	d.v0 = 0
	d.v1 = 2
	d.cell_from = 0
	d.cell_to = 1
	d.flags = 4
	cm.internal_edges.append(d)
	return cm

## A graph over `region` with these decks (index = position in the list),
## each listed by every terrain cell.
func _graph(region: NvmReader.ParsedRegion, decks: Array) -> NavGraph:
	var placed: Array[NavGraph.PlacedObject] = []
	for i in decks.size():
		placed.append(NavGraph.place(decks[i], i, Vector3.ZERO, 0.0))
		for cell in region.cells:
			(cell as NvmReader.Cell).object_indices.append(i)
	return NavGraph.build(region, placed)

func _ghost() -> GDScript:
	return load("res://scripts/world/ghost_walk.gd") as GDScript

## A lookup over [graph, group] pairs by the group's local bounds, as
## World3D._nav_graph_for.
func _lookup(pairs: Array) -> Callable:
	return func(w: Vector3) -> Array:
		for pair in pairs:
			var l: Vector3 = (pair[1] as Node3D).to_local(w)
			if l.x >= 0.0 and l.z >= 0.0 and l.x <= SPAN and l.z <= SPAN:
				return pair
		return []

func _group(at: Vector3) -> Node3D:
	var g := Node3D.new()
	root.add_child(g)
	g.position = at
	return g

# --- NavGraph: the terrain-wall stop ---------------------------------------------

func _test_terrain_stop() -> void:
	var g := _graph(_region(true), [])
	var r = g.callv("step_tracked", [Vector3(50, TERRAIN_Y, 200), Vector2(100, 0), NavGraph.ON_TERRAIN, false])
	# The crossing (100, 200), 0.2 toward cell 0's centre (50, 960).
	var want := Vector2(100, 200) + (Vector2(50, 960) - Vector2(100, 200)).normalized() * 0.2
	_check(r != null and Vector2(r.position.x, r.position.z).distance_to(want) < 0.0005,
		"a terrain wall stops the no-slide walk at the crossing moved 0.2 toward the cell centre, %s (got %s)" % [
			str(want), str(r.position) if r != null else "-"])
	_check(r != null and "cancelled" in r and not bool(r.get("cancelled")), "and nothing sends it back")

func _test_cell_object_cancel() -> void:
	# A sliver object in cell 0 whose left edge lies across the 0.2 move
	# toward the centre but not across the walk's own line (y = x + 150): the
	# cell check (FUN_009a05a0) puts the walk back to its source.
	var region := _region(true)
	var g := _graph(region, [_deck(99.9, 99.95, 250.1, 251.0, TERRAIN_Y, 3)])
	var r = g.callv("step_tracked", [Vector3(50, TERRAIN_Y, 200), Vector2(100, 100), NavGraph.ON_TERRAIN, false])
	_check(r != null and "cancelled" in r and bool(r.get("cancelled")),
		"a stop whose move toward the centre meets one of the cell's objects is cancelled")
	_check(r != null and Vector2(r.position.x, r.position.z).distance_to(Vector2(50, 200)) < 0.001,
		"and the walker is put back at its source point (50, 200) (got %s)" % (str(r.position) if r != null else "-"))

# --- GhostWalk: one step a region ------------------------------------------------

func _test_timing() -> void:
	var gw := _ghost()
	var region := _region(false)
	var decks: Array = []
	for i in 20:
		decks.append(_deck(300 + i * 30, 320 + i * 30, 900, 1100, 30, 3))
	var g := _graph(region, decks)
	var group := _group(Vector3.ZERO)
	var lookup := _lookup([[g, group]])
	var t0 := Time.get_ticks_usec()
	var landing = gw.call("resolve", Vector3(290, TERRAIN_Y, 700), Vector3(290, TERRAIN_Y, 914), 215.0, -2, null, lookup)
	var us := Time.get_ticks_usec() - t0
	# 214 across, so the truncated y (10 against the caster's 10.5) keeps it
	# inside 215 in 3-D and no bisection runs: one walk.
	_check(us < 10000, "a 214-unit landing (reach 215) resolves in under 10 ms (took %d us)" % us)
	_check(landing != null and landing.sent.distance_to(Vector3(290, 10, 914)) < 0.001,
		"and lands at (290, 10, 914) (got %s)" % (str(landing.sent) if landing != null else "-"))
	group.free()

## Truncation moves a point toward the region's origin; walking toward it and
## stopped just past a wall, truncating would carry the landing over the wall
## (Jangan's pit railing, 953.46 -> 953, MEASURED). The walked stop is kept.
func _test_truncation_over_an_edge() -> void:
	var gw := _ghost()
	var r := NvmReader.ParsedRegion.new()
	r.heights.resize(NvmReader.HEIGHT_COUNT)
	r.heights.fill(TERRAIN_Y)
	for rect in [[Vector2.ZERO, Vector2(100.5, SPAN)], [Vector2(100.5, 0), Vector2(SPAN, SPAN)]]:
		var cell := NvmReader.Cell.new()
		cell.rect_min = rect[0]
		cell.rect_max = rect[1]
		r.cells.append(cell)
	for i in range(NvmReader.TILE_COUNT):
		var t := NvmReader.Tile.new()
		t.cell_index = 1 if (i % NvmReader.TILE_MAP_SIDE) * NavGraph.TILE_SIZE >= 100.0 else 0
		r.tiles.append(t)
	var e := NvmReader.Edge.new()
	e.flags = 2
	e.line_min = Vector2(100.5, 0)
	e.line_max = Vector2(100.5, 400)
	r.internal_edges = [e]
	var g := NavGraph.build(r, [] as Array[NavGraph.PlacedObject])
	var group := _group(Vector3.ZERO)
	var landing = gw.call("resolve", Vector3(150, TERRAIN_Y, 200), Vector3(50, TERRAIN_Y, 200), 100.0, -2, null, _lookup([[g, group]]))
	_check(landing != null and "truncated" in landing and not bool(landing.get("truncated")) and landing.sent.x > 100.5,
		"a truncation that would cross the wall it stopped at keeps the walked stop, x past 100.5 (sent %s)" % (str(landing.sent) if landing != null else "-"))
	group.free()

func _test_region_crossing() -> void:
	var gw := _ghost()
	var a := _graph(_region(false), [])
	var b := _graph(_region(false), [])
	var ga := _group(Vector3.ZERO)
	var gb := _group(Vector3(SPAN, 0, 0))
	var landing = gw.call("resolve", Vector3(1900, TERRAIN_Y, 600), Vector3(1960.6, TERRAIN_Y, 600), 100.0, -2, null,
		_lookup([[a, ga], [b, gb]]))
	_check(landing != null and landing.graph == b, "a walk over the region border lands in the next region's graph")
	_check(landing != null and landing.sent.distance_to(Vector3(1960, 10, 600)) < 0.001,
		"at (1960, 10, 600): truncated in THAT region's coordinates, local 40 (got %s)" % (str(landing.sent) if landing != null else "-"))
	ga.free()
	gb.free()

func _test_straddling_deck() -> void:
	# One deck at 30 over x 1850..1990 of region A, i.e. -70..70 of region B:
	# each region's graph places its own copy, as each region's file lists
	# the objects over its cells.
	var gw := _ghost()
	var a := _graph(_region(false), [_deck(1850, 1990, 550, 650, 30, 0)])
	var b := _graph(_region(false), [_deck(-70, 70, 550, 650, 30, 0)])
	var ga := _group(Vector3.ZERO)
	var gb := _group(Vector3(SPAN, 0, 0))
	var landing = gw.call("resolve", Vector3(1880, 30, 600), Vector3(1960, 30, 600), 100.0, -2, null,
		_lookup([[a, ga], [b, gb]]))
	_check(landing != null and landing.graph == b and landing.footing == 0,
		"a walk on a deck over the border stays on the deck in the next region (footing %s)" % (str(landing.footing) if landing != null else "-"))
	_check(landing != null and is_equal_approx(landing.position.y, 30.0), "at the deck's height, 30 (got %s)" % (str(landing.position) if landing != null else "-"))
	ga.free()
	gb.free()

# --- the aniset ------------------------------------------------------------------

func _utf16(text: String) -> PackedByteArray:
	var out := PackedByteArray([0xFF, 0xFE])
	out.append_array(text.to_utf16_buffer())
	return out

func _test_aniset_rules() -> void:
	var ser := load("res://scripts/effects/skill_effect_reader.gd") as GDScript
	var row := func(service: String, code: String, group: String, ready: String, wait: String) -> String:
		return "\t".join(PackedStringArray([service, "n", code, "0", "FALSE", "0", group, ready, wait, "none", "none", "none", "none", "none", "hiteffect\\x.efp"]))
	var text := "\n".join(PackedStringArray([
		"#section\tskillaniset2",
		row.call("0", "SKILL_OFF", "DEFAULT", "none", "ANI_SKILL_7"),
		row.call("1", "SKILL_TWICE", "DEFAULT", "ANI_READY01", "ANI_SKILL_1"),
		row.call("1", "SKILL_TWICE", "SWORD", "ANI_READY02", "ANI_SKILL_2"),
	]))
	var has_all := false
	for m in ser.get_script_method_list():
		if m["name"] == "parse_all":
			has_all = true
	_check(has_all, "SkillEffectReader.parse_all reads both tables in one pass")
	var sets: Dictionary = ser.call("parse_aniset", _utf16(text))
	_check(not sets.has("SKILL_OFF"), "a skillaniset2 row with col 0 = 0 is skipped, as the loader skips it")
	_check(sets.get("SKILL_TWICE", {}).get("wait", []) == [26, 27] and sets.get("SKILL_TWICE", {}).get("ready", []) == [40, 41],
		"a repeated SkillID appends its lists (got %s)" % str(sets.get("SKILL_TWICE", {})))
	_check(String(sets.get("SKILL_TWICE", {}).get("group", "")) == "sword", "and its AniGroup is the later row's")
	if has_all:
		var both: Dictionary = ser.call("parse_all", _utf16(text))
		_check((both["hit"] as Dictionary).get("SKILL_TWICE", "") == "hiteffect\\x.efp" and both["aniset"] == sets,
			"parse_all gives the hit map and the aniset rows together")

func _test_group_fallback() -> void:
	# The row's AniGroup names a group the body lacks: the lookup takes the
	# body's default group's entry.
	var parsed := BsrReader.ParsedObject.new()
	var e := BsrReader.AnimationEntry.new()
	e.action_type = 32
	e.path = "prim\\ani\\char\\china\\man\\skill_china_lightning_bobeop.ban"
	parsed.animation_groups = {"default": [e]}
	_check(parsed.animation_for(32, "nosuch") == e.path, "a group the body lacks falls back to its default group's entry")

# --- the world ---------------------------------------------------------------------

func _make_world() -> Node:
	var sub := GDScript.new()
	sub.source_code = "\n".join(PackedStringArray([
		"extends \"res://scripts/World3D.gd\"",
		"var cast_clips: Array = []",
		"var swings := 0",
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
		"func _body_animation_for(_gender: String, _t: int, _group: String = \"default\") -> BanReader.ParsedAnimation:",
		"\treturn null",
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
	panels.set("_skill_reach_by_id", {114: {"range": 0, "approach": false, "target_required": 1, "target_land": 1}})
	world.set("_hud_panels", panels)
	var cat := SkillBuffCatalog.new(null)
	cat.set_row({"id": 114, "tele": [500, 100]})
	var board: Node = (load("res://scripts/ui/hud/hud_buff_board.gd") as GDScript).new(null, cat)
	world.set("_hud_buff_board", board)
	# A deck at 60 (entered through any edge) at x 120..300, z 550..650, and a
	# roof at 21.5 over x 60..90, z 580..620 that a terrain walker passes
	# beneath (outline 0x10).
	var group := Node3D.new()
	world.add_child(group)
	var g := _graph(_region(false), [_deck(120, 300, 550, 650, 60, 0), _deck(60, 90, 580, 620, 21.5, 0x10)])
	(world.get("_grid") as RegionGridState).add_nav_graph(0, 0, g, group)
	world.set("_skill_anisets_loaded", true)
	world.set("_skill_anisets_cache", {})
	_net.set("current_character_name", "Aria")
	return world

func _fresh_socket() -> StreamPeerBuffer:
	var buf := StreamPeerBuffer.new()
	_net.set("_peer", buf)
	_net.set("_connected", true)
	return buf

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

func _ghost_cast(world: Node, from: Vector3, point: Vector3) -> Array:
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
	return sends

func _test_truncation(world: Node) -> void:
	var sends := _ghost_cast(world, Vector3(50, TERRAIN_Y, 200), Vector3(50.7, TERRAIN_Y, 120.6))
	_check(sends.size() == 1 and sends[0] == Vector3(50, 10, 120),
		"the sent landing is truncated like retail's record: (50.7, 10.5, 120.6) -> (50, 10, 120) (sent %s)" % str(sends))

func _test_reach_with_height(world: Node) -> void:
	# From the ground at 10.5 onto the deck at 60: the landing on the deck is
	# out of reach once its height counts, so it comes back along the line.
	var from := Vector3(50, TERRAIN_Y, 600)
	var sends := _ghost_cast(world, from, Vector3(145, 60, 600))
	var d := from.distance_to(sends[0]) if sends.size() == 1 else INF
	_check(sends.size() == 1 and d <= 100.0, "the sent landing is within reach in 3-D, y included (%.3f from the caster, sent %s)" % [d, str(sends)])
	_check(sends.size() == 1 and sends[0].y == 60.0 and sends[0].x >= 130.0,
		"and still on the deck, as far along as reach allows (sent %s)" % str(sends))

func _test_matched_settle(world: Node) -> void:
	var skill_net := load("res://scripts/net/skill.gd") as GDScript
	var sc = world.get("_self_cast")
	if sc != null:
		sc.call("tell_own_id", 4242)
		sc.call("note_cast", 114, Time.get_ticks_msec())
	# Under the roof (21.5) on the ground (10.5): the landing's own footing is
	# the ground; a settle from the height alone would lift the player onto
	# the roof (within 12 of the sent 10).
	var sends := _ghost_cast(world, Vector3(50, TERRAIN_Y, 600), Vector3(75, TERRAIN_Y, 600))
	_check(sends.size() == 1 and sends[0] == Vector3(75, 10, 600), "the walk passes under the roof to (75, 10, 600) (sent %s)" % str(sends))
	if sends.size() != 1:
		return
	var out := PackedByteArray()
	out.resize(28)
	out.encode_s64(0, 4242)
	out.encode_s64(8, 114)
	out.encode_float(16, sends[0].x)
	out.encode_float(20, sends[0].y)
	out.encode_float(24, sends[0].z)
	world.call("_on_skill_moved", skill_net.call("decode_skill_move", out))
	world.call("_tick_skill_slides", 10.0)
	var player: Node3D = world.get("player")
	_check(is_equal_approx(player.position.y, TERRAIN_Y) and int(world.get("_nav_footing")) == NavGraph.ON_TERRAIN,
		"the echoed landing takes the walk's own footing: the ground at 10.5, not the roof (y %s, footing %s)" % [
			str(player.position.y), str(world.get("_nav_footing"))])

func _test_refused(world: Node) -> void:
	var board: Node = world.get("_hud_buff_board")
	var keep = board.get("catalog")
	board.set("catalog", SkillBuffCatalog.new(null))
	var sends := _ghost_cast(world, Vector3(50, TERRAIN_Y, 200), Vector3(50, TERRAIN_Y, 150))
	_check(sends.is_empty(), "with the reach not known (the index not loaded) the cast is refused, nothing sent (sent %s)" % str(sends))
	board.set("catalog", keep)

func _test_shared_table(world: Node) -> void:
	_check(world.has_method("_preload_skill_effect_table"), "World3D preloads skilleffect.txt at world entry")
	if not world.has_method("_skill_effect_tables"):
		_check(false, "and both readings come from one parse")
		return
	world.set("_skill_hit_efp_loaded", false)
	world.set("_skill_anisets_loaded", false)
	world.set("_skill_table_loaded", true)
	world.set("_skill_table_cache", {"hit": {"SKILL_A": "hiteffect\\a.efp"}, "aniset": {"SKILL_A": {"group": "", "ready": [], "wait": [], "shot": []}}})
	_check((world.call("_skill_effects") as Dictionary).has("SKILL_A") and (world.call("_skill_anisets") as Dictionary).has("SKILL_A"),
		"and both readings come from that one parse")
