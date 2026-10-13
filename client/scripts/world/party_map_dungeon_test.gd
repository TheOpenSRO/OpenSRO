extends SceneTree

## Round 786: party members on the minimap in a dungeon, World3D's side. Run
## headless on the render box: `client/tools/remote_godot.sh tests`.
##
## READ (CIFMinimap::vslot_013's party loop, 0x6643a0..0x664ad1, one loop for
## the field and a dungeon): a member is marked when its record's world id is
## the player's and UI_SILKMALL::FUN_009d5520(record region, record x/y/z)
## says the player can see it -- in a dungeon, the player's own dungeon on
## the player's floor (the floor index of the block under the record against
## the player's block's). The offset is (dx, -dz) / 1920 x the zoom, from the
## player's +0x80 position, which in a dungeon is the dungeon's own space, as
## the record's is (server party.partyPosition; round 780).
##
## Holds here: World3D's dungeon minimap step places the party's marks (a
## member on the player's floor at its dungeon-space offset, the one far off
## on the rim; a member on another floor, in the field or in another dungeon
## not at all), the field frame's last marks do not stay frozen on it, and the
## world map is handed every member's region word and position (y the
## record's height) for HudWorldmap.party_pixel.
##
## Everything is SYNTHETIC (a two-block .dof with no meshes, made-up
## positions); no game data.
##
## NEGATIVE, on the base (dev 2f0f01c8): _refresh_dungeon_minimap never
## called HudMinimap.update_party, so the minimap kept the field's last marks
## (this suite's "frozen" check) and showed no member of the dungeon; the
## suite prints its FAIL lines.

const HudMinimap = preload("res://scripts/ui/hud/hud_minimap.gd")
const UiBuilder = preload("res://scripts/ui/ui_builder.gd")

const CAVE := 0x8001
const TOMB := 0x8007

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	var watchdog := create_timer(120.0)
	watchdog.timeout.connect(func() -> void:
		print("FAIL the suite never reported (a script error stopped it)")
		quit(1))
	await process_frame
	var world := _make_world()
	if world != null:
		await process_frame
		_test_dungeon(world)
		_test_field(world)
		root.remove_child(world)
		world.free()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

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
		"func _input(_event: InputEvent) -> void:",
		"\tpass",
		"func _unhandled_input(_event: InputEvent) -> void:",
		"\tpass",
		"func _exit_tree() -> void:",
		"\tpass",
		""]))
	_check(sub.reload() == OK and sub.can_instantiate(), "a quiet subclass of World3D.gd compiles")
	var scene := load("res://scenes/World3D.tscn") as PackedScene
	if not sub.can_instantiate() or scene == null:
		return null
	var world: Node = scene.instantiate()
	world.set_script(sub)
	# No archive: the zone-name table is not looked for.
	world.set("_text_zone_names_load_attempted", true)
	root.add_child(world)
	return world

func _minimap() -> HudMinimap:
	var minimap := HudMinimap.new(UiBuilder.new(null, null), null, null)
	minimap.setup(null)
	minimap._party_dot_tex = ImageTexture.create_from_image(Image.create(8, 8, false, Image.FORMAT_RGBA8))
	minimap._party_arrow_tex = ImageTexture.create_from_image(Image.create(16, 16, false, Image.FORMAT_RGBA8))
	return minimap

func _block(floor_index: int, y_lo: float) -> DofReader.Block:
	var b := DofReader.Block.new()
	b.floor_index = floor_index
	b.aabb = AABB(Vector3(-5000, y_lo, -5000), Vector3(10000, 100, 10000))
	return b

## A cave of two stacked blocks: block 0, floor 0, around height 0; block 1,
## floor 1, around height 200. No room meshes, so the block under a point is
## the one whose bounds hold it (DofReader.Dof.block_at).
func _dungeon(world: Node) -> DungeonWorld.Built:
	var built := DungeonWorld.Built.new()
	built.rid = CAVE
	built.dof = DofReader.Dof.new()
	built.dof.blocks = [_block(0, -50.0), _block(1, 150.0)]
	built.dof.floor_names = PackedStringArray(["TEST_FLOOR01", "TEST_FLOOR02"])
	built.group = Node3D.new()
	built.group.name = "Dungeon_test"
	built.group.scale.z = -1.0
	world.add_child(built.group)
	var placed: Array[NavGraph.PlacedObject] = []
	built.graph = NavGraph.build_dungeon(placed, {})
	return built

func _member(jid: int, region: int, x: int, y: int, z: int, member_name: String) -> PartyNet.Member:
	var m := PartyNet.Member.new()
	m.jid = jid
	m.member_name = member_name
	m.world_id = 1
	m.region = region
	m.x = x
	m.y = y
	m.z = z
	m.mask = PartyNet.MASK_FULL
	return m

func _party(player_region: int, px: int, pz: int) -> PartyState:
	var party := PartyState.new()
	party.in_party = true
	party.own_jid = 1
	party.members.append(_member(1, player_region, px, 0, pz, "Aria"))
	return party

func _test_dungeon(world: Node) -> void:
	if not world.has_method("_refresh_dungeon_minimap") or world.get("player") == null:
		_check(false, "World3D has its dungeon minimap step and a player")
		return
	var minimap := _minimap()
	root.add_child(minimap)
	world.set("_hud_minimap", minimap)
	# The field frame's last marks, before the dungeon: a member 96 east.
	minimap.update_party(Vector2(1000, 1000), PackedVector2Array([Vector2(1096, 1000)]))
	_check(minimap.party_marks_report() == "dot@(8.0,0.0)", "the field's mark is up before the teleport")

	world.set("_dungeon", _dungeon(world))
	world.set("_dungeon_block", 0)
	# The player at the cave's entry, dungeon (1011, 0, -862).
	(world.get("player") as Node3D).global_position = DungeonWorld.to_world(Vector3(1011, 0, -862))
	var party := _party(CAVE, 1011, -862)
	# Cara: on the player's floor, 191 dungeon-z lower (15.9 px south at the
	# boot zoom, 160 px a region). Dex: the same x and z one floor up (height
	# 200). Eve: in the field. Gus: in another dungeon at the player's spot.
	# Hal: on the player's floor 1500 east, past the 47 px rim.
	party.members.append(_member(2, CAVE, 1011, 0, -1053, "Cara"))
	party.members.append(_member(3, CAVE, 1011, 200, -1053, "Dex"))
	party.members.append(_member(4, (97 << 8) | 168, 1002, 0, 1020, "Eve"))
	party.members.append(_member(5, TOMB, 1011, 0, -862, "Gus"))
	party.members.append(_member(6, CAVE, 2511, 0, -862, "Hal"))
	world.set("_party_marks_party", party)
	world.call("_refresh_minimap")
	var report := minimap.party_marks_report()
	_check(report == "dot@(0.0,15.9) arrow@(47.0,0.0)r-180",
		"in the dungeon: Cara's dot 15.9 px south, Hal's arrow on the east rim; Dex (another floor), Eve (the field) and Gus (another dungeon) unmarked (got '%s')" % report)
	_check(not report.contains("dot@(8.0,0.0)"), "the field's last mark does not stay frozen on the dungeon's minimap")
	var mini: PackedVector2Array = world.get("_party_marks_mini")
	_check(mini == PackedVector2Array([Vector2(1011, -1053), Vector2(2511, -862)]),
		"the minimap's positions are the records' dungeon-space x, z (got %s)" % str(mini))

	# The world map is handed every member but the player, in each one's own
	# frame, with the record's height (the cave's floor bands read it).
	var regions: PackedInt32Array = world.get("_party_marks_regions")
	var pos: PackedVector3Array = world.get("_party_marks_pos")
	_check(regions == PackedInt32Array([CAVE, CAVE, (97 << 8) | 168, TOMB, CAVE]),
		"the world map gets every other member's region word (got %s)" % str(regions))
	_check(pos.size() == 5 and pos[0] == Vector3(1011, 0, -1053) and pos[1] == Vector3(1011, 200, -1053)
		and pos[2] == Vector3(1002, 0, 1020) and pos[3] == Vector3(1011, 0, -862),
		"each at its record's position, the field member region-local, the dungeon ones in dungeon space (got %s)" % str(pos))

	# The player climbs to floor 1: now Dex is on it, Cara and Hal are not.
	world.set("_dungeon_block", 1)
	world.call("_refresh_minimap")
	report = minimap.party_marks_report()
	_check(report == "dot@(0.0,15.9)", "on the upper floor only Dex is marked (got '%s')" % report)
	world.set("_dungeon_block", 0)

	# A member who moves: the record's new place is read, not a cached one.
	(party.members[2] as PartyNet.Member).y = 0
	(party.members[2] as PartyNet.Member).z = -862
	world.call("_refresh_minimap")
	report = minimap.party_marks_report()
	_check(report == "dot@(0.0,0.0) dot@(0.0,15.9) arrow@(47.0,0.0)r-180" or report == "dot@(0.0,15.9) dot@(0.0,0.0) arrow@(47.0,0.0)r-180",
		"Dex, come down beside the player, is marked there (got '%s')" % report)

	# Out of the party: no marks.
	world.set("_party_marks_party", PartyState.new())
	world.call("_refresh_minimap")
	_check(minimap.party_marks_report() == "", "no party, no marks (got '%s')" % minimap.party_marks_report())

	var built: DungeonWorld.Built = world.get("_dungeon")
	world.set("_dungeon", null)
	built.group.queue_free()
	world.set("_hud_minimap", null)
	root.remove_child(minimap)
	minimap.free()

## The field: the minimap's frame is the player's region; a member in a
## dungeon is left off the minimap (0x9d5520 answers 0) but handed to the
## world map at its dungeon position (its dungeon's field point there).
func _test_field(world: Node) -> void:
	var group := Node3D.new()
	group.name = "RealTerrain_97_168"
	world.add_child(group)
	world.set("_minimap_group", group)
	world.set("_minimap_group_name", group.name)
	var party := _party((97 << 8) | 168, 1002, 1020)
	party.members.append(_member(2, (97 << 8) | 169, 10, 0, 20, "Cara"))
	party.members.append(_member(3, CAVE, 1011, 0, -862, "Dex"))
	world.set("_party_marks_party", party)
	world.call("_fill_party_marks", Vector2i(97, 168))
	var mini: PackedVector2Array = world.get("_party_marks_mini")
	_check(mini == PackedVector2Array([Vector2(1930, 20)]),
		"in the field the minimap marks the field member one region y over, 1920 further east, and not the one in the cave (got %s)" % str(mini))
	var regions: PackedInt32Array = world.get("_party_marks_regions")
	var pos: PackedVector3Array = world.get("_party_marks_pos")
	_check(regions == PackedInt32Array([(97 << 8) | 168, CAVE]) and pos.size() == 2
		and pos[0] == Vector3(1930, 0, 20) and pos[1] == Vector3(1011, 0, -862),
		"the world map gets the field member in the player's region frame and the cave member in the cave's (got %s %s)" % [str(regions), str(pos)])
	world.set("_party_marks_party", null)
	world.set("_minimap_group", null)
	group.queue_free()
