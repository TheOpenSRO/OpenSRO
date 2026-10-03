extends SceneTree

## GameCursor (round 697): the hover kind -> resource id table read from
## CGInterface::vslot_005, the class rules for players, monsters and items,
## and the per-scale cache. No game data: a set of plain images stands in
## for the exe's cursors.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _test_ids() -> void:
	var want := {"normal": 0x95, "attack": 0x97, "talk": 0x98, "pickup": 0x99, "pickup_held": 0x9a,
		"gate": 0xa1, "player_hostile": 0xa0, "stall": 0xa3}
	for kind in want:
		_check(GameCursor.id_for(kind) == int(want[kind]), "%s -> 0x%x (got 0x%x)" % [kind, int(want[kind]), GameCursor.id_for(kind)])
	_check(GameCursor.KIND_IDS.size() == want.size(), "no kind beyond the read ones")
	_check(GameCursor.id_for("nonsense") == 0x95, "an unknown kind is the default arrow")

func _test_rules() -> void:
	# CICUser: party / Alt-hostile / stall / team (0x7899a4..0x789a87).
	_check(GameCursor.player_kind(false, false, false) == "normal", "a plain player: arrow")
	_check(GameCursor.player_kind(true, false, false) == "player_hostile", "hostile outside the party: 0xa0")
	_check(GameCursor.player_kind(true, true, false) == "normal", "hostile but in the party: arrow")
	_check(GameCursor.player_kind(false, false, true) == "stall", "a stalling player: the pouch")
	_check(GameCursor.player_kind(true, false, true) == "player_hostile", "hostile wins over the stall")
	_check(GameCursor.player_kind(false, false, false, 1, 2) == "attack", "another team: 0x97")
	_check(GameCursor.player_kind(true, false, false, 1, 1) == "normal", "the same team: arrow, whatever else")
	_check(GameCursor.player_hostile(true) and not GameCursor.player_hostile(false), "here IsHostile is the Alt branch")
	# CICMonster: thief / hunter NPC monsters to a jobless player.
	_check(GameCursor.monster_kind("MOB_CH_MANGNYANG") == "attack", "a monster: the sword")
	_check(GameCursor.monster_kind("") == "attack", "an unknown code: the sword")
	_check(GameCursor.monster_kind("MOB_EU_THIEF_NPC_0001") == "normal", "a thief NPC monster, no job: arrow")
	_check(GameCursor.monster_kind("MOB_HUNTER_NPC_0003") == "normal", "a hunter NPC monster, no job: arrow")
	_check(GameCursor.monster_kind("MOB_HUNTER_NPC_0003", false) == "attack", "with a job: the sword")
	_check(not GameCursor.is_job_monster("NPC_CH_THIEF_NPC"), "only MOB_ rows")
	# CIItem: the left button picks the closed glove.
	_check(GameCursor.item_kind(false) == "pickup" and GameCursor.item_kind(true) == "pickup_held", "item: 0x99, 0x9a held")

func _plain(hot: Vector2i) -> CursorSet.Cursor:
	var c := CursorSet.Cursor.new()
	c.image = Image.create(32, 32, false, Image.FORMAT_RGBA8)
	c.image.fill(Color(1, 1, 0, 1))
	c.hotspot = hot
	return c

func _test_cache_and_show() -> void:
	GameCursor.install_for_test({0x95: _plain(Vector2i(2, 1)), 0x97: _plain(Vector2i(2, 1))})
	var a := GameCursor.scaled_entry(0x95, 2.0)
	var b := GameCursor.scaled_entry(0x95, 2.0)
	_check(a[0] == b[0], "one texture per id and scale, made once")
	_check((a[0] as Texture2D).get_size() == Vector2(64, 64) and a[1] == Vector2i(5, 3), "2.0: 64x64, hotspot (5, 3) (got %s %s)" % [str((a[0] as Texture2D).get_size()), str(a[1])])
	var c := GameCursor.scaled_entry(0x95, 1.0)
	_check(c[1] == Vector2i(2, 1) and (c[0] as Texture2D).get_size() == Vector2(32, 32), "1.0: the file's own")
	_check(GameCursor.scaled_entry(0xa3, 1.0).is_empty(), "an id the set lacks: nothing")
	var w := root
	_check(GameCursor.show(0x97, w), "showing a new id sets it")
	_check(not GameCursor.show(0x97, w), "the same id again is a no-op")
	_check(GameCursor.current_id() == 0x97, "current id follows")
	_check(GameCursor.show(0xa3, w) and GameCursor.current_id() == 0x95, "an id the exe lacks falls back to the arrow")
	GameCursor.suspend()
	_check(not GameCursor.show(0x97, w), "nothing is shown while suspended")
	GameCursor.resume(w)
	_check(not GameCursor.is_suspended() and GameCursor.current_id() == 0x95, "resume puts the arrow back")
	GameCursor.reset_for_test()
	_check(not GameCursor.show(0x95, w), "no exe: nothing to show, no error")

## Round 700: the hover reaches the objects the original client holds --
## the 3 x 3 message blocks of 320 around the player's (READ, server
## CMsgBlock / CRgnTerrain; the client's pick has no per-class range).
func _test_view_window() -> void:
	_check(GameCursor.VIEW_BLOCK_SPAN == 320.0 and GameCursor.VIEW_BLOCK_RADIUS == 1, "blocks of 320, one block each way")
	_check(GameCursor.view_block(0.0) == 3 and GameCursor.view_block(-960.0) == 0 and GameCursor.view_block(959.99) == 5
		and GameCursor.view_block(960.0) == 6 and GameCursor.view_block(-960.01) == -1,
		"blocks line up with the region lines at 960 + 1920k, as the server's CellOf")
	var me := Vector3(0, 0, 0)  # block 3 on both axes: [0, 320)
	_check(GameCursor.in_view_window(me, Vector3(-320.0, 50, 0)) and not GameCursor.in_view_window(me, Vector3(-320.01, 0, 0)),
		"behind: the block before holds to -320, not past it")
	_check(GameCursor.in_view_window(me, Vector3(639.99, 0, 0)) and not GameCursor.in_view_window(me, Vector3(640.0, 0, 0)),
		"ahead: to the end of the next block (640), not into the one after")
	_check(GameCursor.in_view_window(me, Vector3(0, 0, 639.0)) and not GameCursor.in_view_window(me, Vector3(0, 0, 641.0)), "the same on z")
	_check(GameCursor.in_view_window(me, Vector3(639, 0, -320)) and not GameCursor.in_view_window(me, Vector3(641, 0, -320)),
		"a square, not a circle: the corner block holds (723 units away)")
	var edge := Vector3(319.99, 0, 100)  # the far side of block 3
	_check(GameCursor.in_view_window(edge, Vector3(-320, 0, 100)) and not GameCursor.in_view_window(edge, Vector3(640, 0, 100)),
		"320 to 640 units each way, by where the player stands in its block: 639.99 behind, 320.01 ahead is out")
	_check(GameCursor.in_view_window(Vector3(950, 0, 0), Vector3(970, 0, 0)) and GameCursor.in_view_window(Vector3(970, 0, 0), Vector3(1500, 0, 0))
		and not GameCursor.in_view_window(Vector3(950, 0, 0), Vector3(1600, 0, 0)),
		"across a region line like anywhere else (the blocks link across regions)")

func _init() -> void:
	_test_view_window()
	_test_ids()
	_test_rules()
	_test_cache_and_show()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
