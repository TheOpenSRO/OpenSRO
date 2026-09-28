extends SceneTree

## Round 618: the buff bar (HudBuffBoard, retail's CIFMagicStateBoard) and the
## skill rows it reads (SkillBuffCatalog). Everything is synthetic -- no
## archive, no game data; each rule's address is in hud_buff_board.gd.
##
##   (a) layout: 8 a row on a 23 x 27 pitch, the bbuf list 2 px below the
##       main list's rows, the board 184 wide (0x7ffc10)
##   (b) the expiry gauge: (total - elapsed) / total per frame, untimed full
##       and hidden (0x8056a0, asm 0x7ffd35)
##   (c) right-click routing: plain -> cancel, nbuf without lnks -> nothing,
##       nbuf with lnks -> cancel, cbuf -> confirm box, the second list and an
##       ending icon -> nothing (0x800820) -- and a real button-up through the
##       live viewport reaches it
##   (d) the end: 9 frames of 100 ms, alpha -0x55 a tick after tick 3, the
##       sound once, removal at 900 ms; a second-list end removes at once
##       (0x804b30, 0x806790)
##   (e) the tooltip's remaining-time line in its three shapes (0x800a10)
##   (f) the Param walk the flags come from, and the shard a row is in
##   godot4 --headless --path client --script res://scripts/ui/hud/hud_buff_board_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## A code word as skilldata stores it: the letters big-endian.
static func _word(code: String) -> int:
	var w := 0
	for ch in code.to_ascii_buffer():
		w = (w << 8) | ch
	return w

## A board with a catalog of synthetic rows, a recording sender and sound.
func _board(rows: Array) -> Array:
	var cat := SkillBuffCatalog.new(null)
	for r in rows:
		cat.set_row(r)
	var board := HudBuffBoard.new(null, cat)
	var sent: Array = []
	var sounds: Array = []
	board.cancel_sender = func(skill_id: int, token: int) -> void: sent.append([skill_id, token])
	board.sound_player = func(path: String) -> void: sounds.append(path)
	board.ui_text = func(token: String) -> String:
		return {"UIIT_STT_LEVEL_LV": "Lv", "UIIT_STT_REMAIN_TIME": "Remaining time", "PARAM_DAY": "Day",
			"PARAM_HOUR": "Hour", "PARAM_MINUTE": "Minute", "PARAM_SECOND": "Second",
			"UIIT_STT_CONFIRM_BOX": "Confirmation window"}.get(token, token)
	board.setup()
	return [board, sent, sounds]

func _row(id: int, tags: Array = [], level: int = 1) -> Dictionary:
	var r := {"id": id, "level": level, "icon": "skill\\china\\x.ddj", "name_code": "SN_X_%d" % id,
		"desc_code": "", "walk_complete": true}
	for t in SkillBuffCatalog.BUFF_TAGS:
		r[t] = t in tags
	return r

func _test_layout() -> void:
	var rows: Array = []
	for i in 12:
		rows.append(_row(100 + i, ["bbuf"] if i >= 10 else []))
	var made := _board(rows)
	var board: HudBuffBoard = made[0]
	_check(board.position == Vector2(220, 10), "no registry: placed at GDR_MAGICSTATEBOARD's own 220,10")
	_check(board.size == Vector2(184, 54), "empty: 184 wide, one row per list (2 x 27)")
	for i in 12:
		board.add_buff(-1, 100 + i, 1000 + i, 60000, 60000)
	_check(board.buff_count(true) == 10 and board.buff_count(false) == 2, "10 main, 2 bbuf in the second list")
	var ok := true
	for i in 10:
		var want := Vector2((i % 8) * 23, (i / 8) * 27)
		if board.buff(1000 + i).slot.position != want:
			ok = false
			print("  main %d at %s, want %s" % [i, board.buff(1000 + i).slot.position, want])
	_check(ok, "main list: icon i at ((i%8)*23, (i/8)*27) -- 8 on row 0, 2 on row 1")
	_check(board.buff(1008).slot.position == Vector2(0, 27) and board.buff(1009).slot.position == Vector2(23, 27),
		"icons 9 and 10 wrap to row 1 at x 0 and 23")
	_check(board.buff(1010).slot.position == Vector2(0, 2 * 27 + 2) and board.buff(1011).slot.position == Vector2(23, 56),
		"second list starts below the main list's 2 rows plus 2 px (y 56)")
	_check(board.size == Vector2(184, 3 * 27), "board 184 x (2 + 1) * 27")
	var slot := board.buff(1000).slot
	_check(slot.size == Vector2(20, 20) and slot.icon.size == Vector2(20, 20), "icon 20 x 20")
	_check(slot.gauge.position == Vector2(0, 20) and slot.gauge.size == Vector2(20, 4), "gauge 20 x 4 at (0, 20)")
	_check(board.add_buff(-1, 100, 2000, 0, 0) == null and board.buff_count(true) == 10,
		"a zero duration adds no icon (0x7fda20)")
	board.free()

func _test_gauge() -> void:
	var made := _board([_row(1), _row(2)])
	var board: HudBuffBoard = made[0]
	board.add_buff(-1, 1, 11, 10000, 10000)
	board.add_buff(-1, 2, 12, -1, -1)
	var b := board.buff(11)
	_check(is_equal_approx(b.gauge_value(), 1.0) and b.slot.gauge.visible, "timed: starts full, gauge shown")
	board.advance(7500.0)
	_check(is_equal_approx(b.gauge_value(), 0.25), "total 10 s, elapsed 7.5 s -> 0.25")
	_check(is_equal_approx(b.slot.gauge.value, 0.25), "the drawn gauge reads 0.25 the same frame")
	board.advance(5000.0)
	_check(is_equal_approx(b.gauge_value(), 0.0) and board.buff(11) != null,
		"elapsed clamps at total: empty, and still shown until the server ends it")
	var u := board.buff(12)
	_check(is_equal_approx(u.gauge_value(), 1.0) and is_equal_approx(u.slot.gauge.value, 1.0),
		"untimed: the gauge is written full")
	_check(not u.slot.gauge.visible, "untimed: the gauge is hidden (ShowWindow(total != -1))")
	board.add_buff(-1, 1, 13, 10000, 4000)
	_check(is_equal_approx(board.buff(13).gauge_value(), 0.4), "joined with 4 s of 10 left: 0.4")
	board.free()

func _test_right_click() -> void:
	var made := _board([_row(1), _row(2, ["nbuf"]), _row(3, ["nbuf", "lnks"]), _row(4, ["cbuf"]), _row(5, ["bbuf"])])
	var board: HudBuffBoard = made[0]
	var sent: Array = made[1]
	root.add_child(board)
	for i in range(1, 6):
		board.add_buff(-1, i, 20 + i, 30000, 30000)
	_check(board.right_click_action(21) == HudBuffBoard.ACTION_CANCEL, "plain buff -> cancel")
	_check(board.right_click_action(22) == HudBuffBoard.ACTION_NONE, "nbuf without lnks -> nothing")
	_check(board.right_click_action(23) == HudBuffBoard.ACTION_CANCEL, "nbuf with lnks -> cancel")
	_check(board.right_click_action(24) == HudBuffBoard.ACTION_CONFIRM, "cbuf -> confirm box")
	_check(board.right_click_action(25) == HudBuffBoard.ACTION_NONE, "second (bbuf) list -> nothing")
	board.on_slot_right_click(22)
	board.on_slot_right_click(25)
	_check(sent.is_empty(), "nbuf and second-list clicks send nothing")
	board.on_slot_right_click(21)
	_check(sent == [[1, 21]], "plain click sends cancel(skill 1, token 21)")
	sent.clear()
	board.on_slot_right_click(24)
	var box := root.get_node_or_null(HudBuffBoard.CONFIRM_NAME)
	_check(box != null and sent.is_empty(), "cbuf opens the confirm box and sends nothing yet")
	if box != null:
		_check(box.custom_minimum_size == Vector2(308, 148), "the box is 308 x 148 (0x6ec5d0)")
		var ok := box.find_child("OK", true, false) as Button
		ok.pressed.emit()
		_check(sent == [[4, 24]], "its OK sends cancel(skill 4, token 24)")
		box.free()
	sent.clear()

	# A real button-up through the live viewport, the way the OS delivers it.
	root.size = Vector2i(1152, 648)
	root.notification(Node.NOTIFICATION_VP_MOUSE_ENTER)
	var at := board.buff(21).slot.global_position + Vector2(10, 10)
	for pressed in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_RIGHT
		ev.pressed = pressed
		ev.position = at
		ev.global_position = at
		root.push_input(ev, true)
	_check(sent == [[1, 21]], "a right press and release on the icon, through the viewport, sends one cancel")
	sent.clear()
	var ev2 := InputEventMouseButton.new()
	ev2.button_index = MOUSE_BUTTON_RIGHT
	ev2.pressed = false
	ev2.position = board.buff(22).slot.global_position + Vector2(10, 10)
	ev2.global_position = ev2.position
	root.push_input(ev2, true)
	_check(sent.is_empty(), "the same on the nbuf icon sends nothing")

	board.end_buff(21)
	board.on_slot_right_click(21)
	_check(sent.is_empty() and board.right_click_action(21) == HudBuffBoard.ACTION_NONE,
		"an icon playing its end does nothing")
	root.remove_child(board)
	board.free()

func _test_end() -> void:
	var made := _board([_row(1), _row(2, ["bbuf"])])
	var board: HudBuffBoard = made[0]
	var sounds: Array = made[2]
	# A stand-in sheet so the frame regions are live.
	board._textures_loaded = true
	board._burst_tex = ImageTexture.create_from_image(Image.create(512, 64, false, Image.FORMAT_RGBA8))
	board.add_buff(-1, 1, 31, 30000, 30000)
	board.add_buff(-1, 2, 32, 30000, 30000)
	var b := board.buff(31)
	var slot := b.slot
	board.end_buff(31)
	_check(sounds == [HudBuffBoard.DISAPPEAR_SOUND] and sounds[0] == "prim\\snd\\ui\\buf_disappear.wav",
		"the end plays buf_disappear.wav once")
	_check(slot.burst.visible and not slot.gauge.visible, "burst shown, gauge hidden")
	_check(slot.burst.position == Vector2(-15, -16) and slot.burst.size == Vector2(50, 52), "burst 50 x 52 centred on the icon at (-15, -16)")
	var at := slot.burst.texture as AtlasTexture
	_check(at != null and at.region == Rect2(0, 0, 50, 52), "frame 0 at (0, 0, 50, 52)")
	var alphas: Array = []
	var frames: Array = []
	for t in range(1, 9):
		board.advance(100.0)
		alphas.append(int(round(slot.icon.modulate.a * 255.0)))
		frames.append(int(at.region.position.x))
	_check(frames == [50, 100, 150, 200, 250, 300, 350, 400], "a frame per 100 ms tick: x = 50 i")
	_check(alphas == [255, 255, 255, 170, 85, 0, 0, 0], "alpha: full to tick 3, then -0x55 a tick, 0 below 0x56")
	_check(board.buff(31) != null, "still on the board at 800 ms")
	board.advance(99.0)
	_check(board.buff(31) != null, "still on the board at 899 ms")
	board.advance(1.0)
	_check(board.buff(31) == null and board.buff_count(true) == 0, "removed at tick 9, 900 ms")
	_check(board.buff(32).slot.position == Vector2(0, 29), "the grid is laid out again (second list at y 27 + 2)")
	sounds.clear()
	board.end_buff(32)
	_check(board.buff(32) == null and sounds.is_empty(), "a second-list end removes at once, silently")
	# Through the signal handlers, with the owner test.
	board.is_self = func(owner_id: int) -> bool: return owner_id == 7
	board.on_buff_started(8, 1, 41, 5000, 5000, 0)
	_check(board.buff(41) == null, "another owner's buff is not shown")
	board.on_buff_started(7, 1, 42, 5000, 5000, 0)
	_check(board.buff(42) != null, "this player's buff is shown")
	board.on_buff_ended(8, [42], 0)
	_check(board.buff(42) != null and not board.buff(42).ending, "another owner's end does not touch it")
	board.on_buff_ended(7, [42], 0)
	_check(board.buff(42).ending, "this player's end starts the burst")
	board.free()

func _test_tooltip() -> void:
	var t := {"remain": "Remaining time", "day": "Day", "hour": "Hour", "minute": "Minute", "second": "Second"}
	_check(HudBuffBoard.remain_line(45999, t) == "Remaining time 45Second", "under 60 s: '%s %d%s'")
	_check(HudBuffBoard.remain_line(125000, t) == "Remaining time 2Minute 5Second", "under 1 h: '%s %d%s %d%s'")
	_check(HudBuffBoard.remain_line(90061000, t) == "Remaining time: 1Day 1Hour 1Minute", "else: '%s: %d%s %d%s %d%s'")
	_check(HudBuffBoard.remain_line(3600000, t) == "Remaining time: 0Day 1Hour 0Minute", "exactly 1 h takes the day form")
	var made := _board([_row(1, [], 3)])
	var board: HudBuffBoard = made[0]
	board.add_buff(-1, 1, 51, 60000, 60000)
	board.advance(30000.0)
	_check(board.tooltip_for(51) == "SN_X_1 Lv 3\nRemaining time 30Second", "the tooltip: name Lv level, then the time")
	_check(board.buff(51).slot.get_tooltip(Vector2(5, 5)) == board.tooltip_for(51),
		"the slot's own tooltip (Control.get_tooltip -> _get_tooltip) is that text")
	board.add_buff(-1, 1, 52, -1, -1)
	_check(board.tooltip_for(52) == "SN_X_1 Lv 3", "untimed: no time line")
	board.free()

func _test_catalog() -> void:
	_check(SkillBuffCatalog.code_of(0x00617474) == "att", "code_of(0x00617474) = att")
	_check(SkillBuffCatalog.code_of(_word("cbuf")) == "cbuf", "code_of round-trips cbuf")
	var words := PackedInt64Array([_word("att"), 1, 2, 3, 4, 5, 0, _word("dura"), 12000, _word("cbuf"),
		_word("lnks"), 1, 2, 3, 4, _word("ssou"), _word("nbuf")])
	var w := SkillBuffCatalog.walk(words)
	_check(w["complete"] and Array(w["codes"]) == ["att", "dura", "cbuf", "lnks", "ssou"],
		"walk: runs, padding, markers, stop at ssou (nbuf past it is not read)")
	var bad := SkillBuffCatalog.walk(PackedInt64Array([_word("dura"), 5, 12345]))
	_check(not bad["complete"], "a word that is no code ends the walk incomplete")
	# A synthetic row: 69 leading columns, then the block.
	var cols := PackedStringArray()
	cols.resize(69)
	for i in 69:
		cols[i] = "0"
	cols[1] = "7001"
	cols[7] = "4"
	cols[61] = "skill\\china\\y.ddj"
	cols[62] = "SN_Y"
	cols[64] = "SN_Y_TT_DESC"
	for v in [_word("dura"), 30000, _word("bbuf"), _word("nbuf"), 0, 0]:
		cols.append(str(v))
	var row := SkillBuffCatalog.parse_row(cols)
	_check(row["id"] == 7001 and row["level"] == 4 and row["icon"] == "skill\\china\\y.ddj", "row: id, level, icon")
	_check(row["bbuf"] and row["nbuf"] and not row["cbuf"] and not row["lnks"], "row: bbuf and nbuf set, cbuf and lnks not")
	_check(SkillBuffCatalog.shard_path(999).ends_with("skilldata_1000.txt"), "id 999 -> skilldata_1000")
	_check(SkillBuffCatalog.shard_path(1000).ends_with("skilldata_2000.txt"), "id 1000 -> skilldata_2000")
	_check(SkillBuffCatalog.shard_path(30897).ends_with("skilldata_31000.txt"), "id 30897 -> skilldata_31000")
	# The run table is the server's (169 codes; the Go test compares them all).
	_check(SkillBuffCatalog.RUN.size() == 169 and SkillBuffCatalog.RUN["lnks"] == 5 and SkillBuffCatalog.RUN["cbuf"] == 1,
		"the run table: 169 codes, lnks 5, cbuf 1")

func _test_qa_and_net() -> void:
	var made := _board([_row(1), _row(2)])
	var board: HudBuffBoard = made[0]
	board.qa_inject("1:20000:15000,2:-1", "0@500")
	_check(board.buff(HudBuffBoard.QA_FIRST_TOKEN) != null and board.buff(HudBuffBoard.QA_FIRST_TOKEN + 1) != null,
		"SRREVAMP_QA_BUFFS injects two icons")
	_check(is_equal_approx(board.buff(HudBuffBoard.QA_FIRST_TOKEN).gauge_value(), 0.75), "15 s of 20 left: 0.75")
	board.advance(500.0)
	_check(board.buff(HudBuffBoard.QA_FIRST_TOKEN).ending, "SRREVAMP_QA_BUFFS_END ends the first at 500 ms")
	var fake := GDScript.new()
	fake.source_code = "extends Node\nsignal buff_started(owner_id, skill_id, token, duration_ms, remaining_ms, run_speed)\nsignal buff_ended(owner_id, tokens, run_speed)\n"
	fake.reload()
	var net := Node.new()
	net.set_script(fake)
	_check(board.connect_net(net), "connects when the node has buff_started")
	net.emit_signal("buff_started", 5, 2, 77, 9000, 9000, 0)
	_check(board.buff(77) != null, "a buff_started signal adds the icon")
	_check(not board.connect_net(Node.new()), "a node without the signals: not connected (the base's NetClient)")
	net.free()
	board.free()

func _initialize() -> void:
	var watchdog := create_timer(60.0)
	watchdog.timeout.connect(func() -> void:
		print("FAIL the suite never reported (a script error stopped it)")
		quit(1))
	await process_frame
	_test_layout()
	_test_gauge()
	_test_right_click()
	_test_end()
	_test_tooltip()
	_test_catalog()
	_test_qa_and_net()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
