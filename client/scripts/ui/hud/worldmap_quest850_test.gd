extends SceneTree

## Round 850 lane Q: when a quest's marks leave the world map, and what a
## normal open shows after a quest's map (HudWorldmap's quest marks section
## has the reading). READ, sro_client.exe:
## - 0x61a620 (the clear) is called only by 0x6256e0 (the next quest's map),
##   0x622dd0(1) (the teleport selection), 0x624f40(m, 0, ..) (a guide
##   monster, 0x628d30), 0x6255c0 (box 31) and the destructor 0x621ed0 --
##   never by ShowWindow (vslot_023 0x624550), so closing and M keep them;
## - 0x61e700 / 0x61e890 draw them in mode 0 (world) and 2 (floor) only;
## - the ground click 0x793570 (0x793a84..0x793ad8) turns auto-move back on
##   when the stale flag is set, outside the teleport selection, and the
##   map then follows the player to its own map.
## The rule checks run everywhere; the map's checks SKIP without the box's
## Media.pk2 (no game data in the repo, docs/LEGAL.md).
##
##   client/tools/remote_godot.sh script res://scripts/ui/hud/worldmap_quest850_test.gd

const MEDIA := "/opt/sro-files/client/Media.pk2"
## Jangan, the game's spawn (AGENTS.md): region x 97, y 168, local (1002, 1020).
const JANGAN_X := 97
const JANGAN_Y := 168
const JANGAN_AT := Vector3(1002, 0, 1020)

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	await _run()
	print("FAILURES: %d" % _failures if _failures > 0 else "ALL PASS")
	quit(1 if _failures > 0 else 0)

func _run() -> void:
	_rule()
	if not FileAccess.file_exists(MEDIA):
		print("SKIP (no %s)" % MEDIA)
		return
	var pk2 := Pk2Reader.open(MEDIA)
	_check(pk2 != null, "Media.pk2 opens")
	if pk2 == null:
		return
	var entry := ObjectLoader.find_file(pk2, "server_dep\\silkroad\\textdata\\textuisystem.txt")
	var table := UiTextTable.parse(pk2.read_file(entry)) if entry != null else null
	root.size = Vector2i(1280, 720)
	await process_frame
	await _paths(UiBuilder.new(pk2, table), pk2)

# --- The ground click's rule (0x793a84..0x793ad8), no archive -------------------

func _rule() -> void:
	var wm := HudWorldmap.new()
	# A quest's map (or a press on the map) left auto-move off and the flag set.
	wm._auto = false
	wm._auto_art_stale = true
	wm._teleport_select = true
	wm.ground_clicked()
	_check(not wm.is_auto_move() and wm._auto_art_stale, "in the teleport selection (+0x9990) the click changes nothing")
	wm._teleport_select = false
	wm.ground_clicked()
	_check(wm.is_auto_move() and not wm._auto_art_stale, "outside it: the flag cleared, auto-move back on (0x60fc30(0), 0x60fc10(1))")
	wm.ground_clicked()
	_check(wm.is_auto_move() and not wm._auto_art_stale, "a second click leaves it on")
	# Button 20 turned it off: no flag, so a click does not undo the choice.
	wm._auto = false
	wm._auto_art_stale = false
	wm.ground_clicked()
	_check(not wm.is_auto_move(), "auto-move turned off by button 20 (no stale flag) stays off")
	wm.free()

# --- Every path, on the real map -------------------------------------------------

func _counts(wm: HudWorldmap) -> String:
	var c := wm.quest_layer_counts()
	return "%d/%d signs, %d/%d areas" % [c["signs_shown"], c["signs"], c["areas_shown"], c["areas"]]

func _map_id(wm: HudWorldmap) -> int:
	var rep := wm.qa_report()
	var at := rep.find(" map=")
	return int(rep.substr(at + 5).split(" ")[0]) if at >= 0 else -99

func _paths(builder: UiBuilder, pk2: Pk2Reader) -> void:
	var guide := QuestMapGuide.shared(pk2)
	var running := QuestNet.View.new()
	running.status = 1
	var wm := HudWorldmap.new(builder)
	root.add_child(wm)
	_check(wm.build_worldmap(), "the world map builds")
	await process_frame
	wm.update_player(JANGAN_X, JANGAN_Y, JANGAN_AT)
	wm.open()
	var town := _map_id(wm)
	_check(town > 0 and town < 1000 and wm._mode == HudWorldmap.MODE_LOCAL,
		"opened at Jangan: the town's local map (got map %d mode %d)" % [town, wm._mode])
	var home := wm._canvas.position

	# The quest list's map button (0x6e51e0 -> 0x6256e0).
	wm.quest_guide = guide
	wm.show_quest(running, "QNO_CH_POTION_1")
	_check(_map_id(wm) == 0 and _counts(wm) == "1/1 signs, 3/3 areas" and not wm.is_auto_move() and wm._auto_art_stale,
		"POTION_1: the world map, the water ghost's icon and three areas shown, auto-move off with the flag (got map %d, %s)" % [_map_id(wm), _counts(wm)])
	var quest_scroll := wm._canvas.position

	# The close button (vslot_043 0x46d7c0 -> ShowWindow(0)): kept.
	wm.hide()
	_check(wm.quest_marks_on and _counts(wm) == "1/1 signs, 3/3 areas",
		"closed: the marks are kept (ShowWindow(0) never reaches 0x61a620; got %s)" % _counts(wm))

	# M at once (0x79abe0 -> 0x46d740 -> ShowWindow(1)), no click between:
	# auto-move is still off, so 0x623060 keeps the map and the scroll.
	wm.toggle()
	_check(wm.visible and _map_id(wm) == 0 and wm._canvas.position == quest_scroll and _counts(wm) == "1/1 signs, 3/3 areas",
		"M straight after: the quest's map, scroll and marks, as the original (got map %d, %s, canvas %s)" % [_map_id(wm), _counts(wm), wm._canvas.position])
	wm.toggle()
	_check(not wm.visible and _counts(wm) == "1/1 signs, 3/3 areas", "M again closes it, the marks kept")

	# The player walks by mouse (0x793570's ground branch): auto-move back on;
	# the next position update follows the player to the town's map.
	wm.ground_clicked()
	_check(wm.is_auto_move() and not wm._auto_art_stale, "the ground click turns auto-move back on")
	wm.update_player(JANGAN_X, JANGAN_Y, JANGAN_AT)
	wm.toggle()
	_check(wm.visible and _map_id(wm) == town and wm._mode == HudWorldmap.MODE_LOCAL,
		"M after a walk: the town's own map (got map %d)" % _map_id(wm))
	_check(_counts(wm) == "0/1 signs, 0/3 areas" and wm._canvas.position == home,
		"no quest mark shown, the map centred on the player as before the quest (got %s, canvas %s against %s)" % [_counts(wm), wm._canvas.position, home])

	# A local map never draws them (0x61e700 / 0x61e890: modes 0 and 2 only),
	# even one whose id a mark carries.
	var fake := TextureRect.new()
	fake.set_meta(HudWorldmap.QUEST_MAP_META, town)
	wm._quest_sign_layer.add_child(fake)
	wm._refresh_quest_marks()
	_check(not fake.visible, "a mark on the local map's own id stays hidden in mode 1")
	wm._quest_sign_layer.remove_child(fake)
	fake.free()

	# The world button (0x6231e0): the field's marks are still there (READ:
	# nothing on these paths cleared them).
	wm.show_world()
	_check(_map_id(wm) == 0 and _counts(wm) == "1/1 signs, 3/3 areas",
		"the world button: the world map with the quest's marks, which the original keeps (got %s)" % _counts(wm))

	# The next quest's button clears the last (0x6256e0 -> 0x61a620).
	wm.show_quest(running, "QNO_CH_HWAN_1_3_1")
	_check(_counts(wm) == "1/1 signs, 0/0 areas", "the next quest: only its own marks (got %s)" % _counts(wm))
	# The teleport selection clears them (0x622dd0(1) -> 0x61a620).
	wm.enter_select_mode()
	_check(not wm.quest_marks_on and _counts(wm) == "0/0 signs, 0/0 areas", "the teleport selection clears them (got %s)" % _counts(wm))
	wm.leave_select_mode()
	wm.queue_free()
	await process_frame
