extends SceneTree

## Exercises the teleport board (round 578): TeleportBoard's paging and price
## helpers, the board HudPanels builds from a synthetic layout shaped like
## resinfo\ifteleportboard.txt and ifteleportareaslot.txt (the authored rects
## recorded in teleport_board.gd; never real game data), and World3D's talk
## line -> board -> Move -> receipt wiring over synthetic teleport tables:
##   godot4 --headless --path client --script res://scripts/ui/hud/teleport_board_test.gd
##
## Every new script and method is reached by path and through has_method /
## call, so a tree without them FAILS here rather than failing to parse.

const BOARD_PATH := "res://scripts/ui/hud/teleport_board.gd"
const PANELS_PATH := "res://scripts/ui/hud/hud_panels.gd"

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## Six destinations, the shape World3D._open_teleport_board builds -- one more
## than a page holds.
func _entries() -> Array:
	return [
		{"dest_id": 2, "place": "Fixture Donwhang", "fee": 5000, "waived": false},
		{"dest_id": 175, "place": "Fixture West", "fee": 40000, "waived": false},
		{"dest_id": 176, "place": "Fixture East", "fee": 40000, "waived": false},
		{"dest_id": 5, "place": "Fixture Hotan", "fee": 5000, "waived": true},
		{"dest_id": 20, "place": "Fixture City", "fee": 0, "waived": false},
		{"dest_id": 25, "place": "Fixture Last", "fee": 5000, "waived": false},
	]

func _board() -> Object:
	if not ResourceLoader.exists(BOARD_PATH):
		return null
	var script := load(BOARD_PATH) as GDScript
	if script == null or not script.can_instantiate():
		return null
	return script.new()

func _init() -> void:
	var board := _board()
	_check(board != null, "TeleportBoard loads and instantiates")
	var ok := board != null and board.has_method("page_rows") and board.has_method("page_count") and board.has_method("price_text")
	_check(ok, "TeleportBoard has page_rows, page_count and price_text")
	if not ok:
		return  # _initialize still runs, and reports

	# Paging: five a page -- the layout's five CIFTeleportAreaSlot controls.
	# NEGATIVE: an off-by-one returning six on page 0, or a second full page,
	# fails the exact counts and ids here.
	var entries := _entries()
	var p0: Array = board.call("page_rows", entries, 0)
	var p1: Array = board.call("page_rows", entries, 1)
	var p2: Array = board.call("page_rows", entries, 2)
	_check(p0.size() == 5 and p0.map(func(e): return e.dest_id) == [2, 175, 176, 5, 20],
		"page 0 holds the first five, in order (got %s)" % [p0.map(func(e): return e.dest_id)])
	_check(p1.size() == 1 and p1[0].dest_id == 25, "page 1 holds the sixth alone (got %s)" % [p1.map(func(e): return e.dest_id)])
	_check(p2.is_empty(), "page 2 is empty (got %d)" % p2.size())
	_check((board.call("page_rows", entries, -1) as Array).is_empty(), "a negative page is empty")
	_check(board.call("page_count", 6) == 2, "page_count(6) == 2 (got %s)" % board.call("page_count", 6))
	_check(board.call("page_count", 5) == 1 and board.call("page_count", 10) == 2 and board.call("page_count", 0) == 0,
		"page_count(5) == 1, page_count(10) == 2, page_count(0) == 0")

	# The price line in the archive's own formats: the fee format with the
	# numbers substituted, the free format for a 0 fee or the level waiver.
	var fee_fmt := "Teleport to [%s] for [%d] Gold."
	var free_fmt := "Teleport to [%s] (no cost)."
	var paid: String = board.call("price_text", "Donwhang", 5000, false, fee_fmt, free_fmt)
	_check(paid == "Teleport to [Donwhang] for [5000] Gold.", "a 5000 fee fills the fee format (got %s)" % paid)
	var free: String = board.call("price_text", "Donwhang", 0, false, fee_fmt, free_fmt)
	_check(free == "Teleport to [Donwhang] (no cost).", "a 0 fee takes the free format (got %s)" % free)
	var waived: String = board.call("price_text", "Donwhang", 5000, true, fee_fmt, free_fmt)
	_check(waived == "Teleport to [Donwhang] (no cost).", "the level waiver takes the free format (got %s)" % waived)
	# A format that is not the expected placeholders (or no archive at all)
	# falls back to our own wording rather than erroring in `%`.
	var bad: String = board.call("price_text", "Donwhang", 5000, false, "Teleport %s", "")
	_check(bad == "5000 gold", "a malformed format falls back to our own wording (got %s)" % bad)

## A layout in the real ifteleportboard.txt shape (no frame at the origin).
func _board_layout() -> String:
	var slots := ""
	for i in range(5, 0, -1):
		slots += _control("GDR_TB_TASLOT%d" % i, "CIFTeleportAreaSlot", "47,%d,357,76" % (105 + 80 * (i - 1)), "")
	return "Interface Text\n\nSection = Create,\"0,0,0,0\",\"0\"\n{\n" + slots \
		+ _control("GDR_TB_SPIN_PAGE", "CIFSpinButtonCtrl", "181,520,80,24", "") \
		+ _control("GDR_TB_STATIC_NAME", "CIFStatic", "8,65,432,21", "UIIT_CTL_TELEPORT_TARGET") \
		+ _control("GDR_TB_BTN_CLOSE", "CIFCloseButton", "406,15,16,16", "") \
		+ _control("GDR_TB_STATIC_TITLE", "CIFStatic", "13,17,393,21", "UIIT_PAG_TELEPORT") + "}\n"

## A layout in the real ifteleportareaslot.txt shape.
func _slot_layout() -> String:
	return "Interface Text\n\nSection = Create,\"0,0,0,0\",\"0\"\n{\n" \
		+ _control("GDR_TAS_BTN_MOVE", "CIFButton", "252,20,92,36", "UIIT_CTL_MOVE") \
		+ _control("GDR_TAS_STATIC_PRICE", "CIFStatic", "70,44,182,21", "") \
		+ _control("GDR_TAS_STATIC_PLACE", "CIFStatic", "70,14,182,21", "") \
		+ _control("GDR_TAS_STATIC_ICON", "CIFStatic", "6,6,64,64", "") + "}\n"

func _control(control_name: String, type: String, rect: String, text: String) -> String:
	return "\t%s:%s\n\t{\n\t\tClientRect=RECT,\"0,0,0,0\"\n\t\tDDJ=STRING,\"\"\n\t\tFontColor=COLOR,\"255,255,255,255\"\n\t\tFontIndex=INTEGER,\"2\"\n\t\tRect=RECT,\"%s\"\n\t\tText=STRING,\"%s\"\n\t}\n" % [control_name, type, rect, text]

func _text_row(token: String, english: String) -> String:
	return "1\t%s\t0\t0\t0\t0\t0\t0\t%s\t0" % [token, english]

func _text_table(rows: Array) -> UiTextTable:
	return UiTextTable.parse(("\n".join(PackedStringArray(rows))).to_utf16_buffer())

## A builder with no archive whose layout cache holds the three synthetic
## layouts, so HudPanels.open("teleport") builds the board the way it would
## from Media.pk2.
func _builder() -> UiBuilder:
	var builder := UiBuilder.new(null, _text_table([
		_text_row("UIIT_PAG_TELEPORT", "Fixture Teleporter"),
		_text_row("UIIT_CTL_TELEPORT_TARGET", "Fixture select"),
		_text_row("UIIT_CTL_MOVE", "Fixture Move"),
		_text_row("UIIT_CTL_TELEPORT_RESULT", "Fixture to [%s] for [%d] coins."),
		_text_row("UIIT_CTL_TELEPORT_FREE_RESULT", "Fixture to [%s] free."),
	]))
	var cache: Dictionary = builder.get("_layout_cache")
	cache["resinfo\\ifteleportboard.txt"] = UiLayoutParser.parse(_board_layout())
	cache["resinfo\\ifteleportareaslot.txt"] = UiLayoutParser.parse(_slot_layout())
	# A one-static talk box, so open_npc_talk builds one (the zone-change
	# case); a fixture rect, not the authored if_npctalk.txt.
	cache["resinfo\\if_npctalk.txt"] = UiLayoutParser.parse("Interface Text\n\nSection = Create,\"0,0,0,0\",\"0\"\n{\n" \
		+ _control("GDR_NPCTALK_BGTILE", "CIFStatic", "0,0,300,200", "") + "}\n")
	return builder

## The slots of the board that hold a built row, and those shown.
func _rows(window: Node) -> Array:
	var built := 0
	var shown := 0
	for i in range(1, 6):
		var slot := window.call("node", "GDR_TB_TASLOT%d" % i) as Control
		if slot != null and slot.has_node("AreaSlot"):
			built += 1
			if slot.visible:
				shown += 1
	return [built, shown]

func _slot_text(window: Node, slot: int, control_name: String) -> String:
	var s := window.call("node", "GDR_TB_TASLOT%d" % slot) as Control
	var label := s.find_child(control_name, true, false) as Label if s != null else null
	return label.text if label != null else "<none>"

func _press_move(window: Node, slot: int) -> void:
	var s := window.call("node", "GDR_TB_TASLOT%d" % slot) as Control
	var move := s.find_child("GDR_TAS_BTN_MOVE", true, false) as BaseButton if s != null else null
	if move != null:
		move.pressed.emit()

## teleportdata / teleportlink / teleportbuilding rows in the archive's shape
## (TeleportReader's columns): Jangan's gate (point 1, building 2094) with six
## links -- fixture values, not the retail fees.
func _tp_row(width: int, fields: Dictionary) -> String:
	var cols := PackedStringArray()
	cols.resize(width)
	cols.fill("0")
	for k in fields:
		cols[int(k)] = str(fields[k])
	return "\t".join(cols)

func _tp_table(rows: Array) -> PackedByteArray:
	return ("\r\n".join(PackedStringArray(rows)) + "\r\n").to_utf16_buffer()

func _reader() -> TeleportReader:
	var data := [_tp_row(14, {0: 1, 1: 1, 2: "GATE_CH", 3: 2094, 4: "SN_ZONE_22001", 5: 25000, 10: 1})]
	var links := []
	for pair in [[2, 5000], [175, 40000], [176, 40000], [5, 5000], [20, 0], [25, 5000]]:
		data.append(_tp_row(14, {0: 1, 1: pair[0], 2: "GATE_%d" % pair[0], 3: 0, 4: "SN_ZONE_%d" % pair[0], 5: 26265}))
		links.append(_tp_row(23, {0: 1, 1: 1, 2: pair[0], 3: pair[1]}))
	var buildings := [_tp_row(59, {0: 1, 1: 2094, 2: "STORE_CH_GATE", 5: "SN_NPC_CH_GATE", 41: 25000, 43: 1254, 44: -6, 45: 1374})]
	var reader := TeleportReader.new()
	reader.parse(_tp_table(data), _tp_table(links), _tp_table(buildings))
	return reader

## The live half: HudPanels and World3D name the NetClient autoload, which a
## --script suite registers only after _init (hud_window_test.gd's note), and
## a window centres itself on the viewport, which needs the running tree --
## entered only after _initialize returns (npc_service_reader_test.gd's (m)).
## So this waits a frame first, under a watchdog.
func _initialize() -> void:
	var watchdog := create_timer(60.0)
	watchdog.timeout.connect(func() -> void:
		print("FAIL the live checks never reported (a script error stopped them)")
		quit(1))
	await process_frame
	var panels_script := load(PANELS_PATH) as GDScript
	var compiled := panels_script != null and panels_script.can_instantiate()
	_check(compiled, "HudPanels compiles in _initialize")
	if compiled:
		_board_checks(panels_script)
		_world_checks(panels_script)
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

func _board_checks(panels_script: GDScript) -> void:
	var panels: Node = panels_script.new(_builder())
	root.add_child(panels)
	var has_open := panels.has_method("open_teleport_board") and panels.has_signal("teleport_requested")
	_check(has_open, "HudPanels has open_teleport_board and teleport_requested")
	var spec: Array = (panels_script.get_script_constant_map().get("PANELS", {}) as Dictionary).get("teleport", [])
	_check(spec.size() == 3 and spec[0] == "resinfo\\ifteleportboard.txt" and spec[1] == "",
		"PANELS[\"teleport\"] is ifteleportboard.txt with no caller title (got %s)" % [spec])
	if not has_open:
		panels.free()
		return
	var requested: Array = []
	panels.connect("teleport_requested", func(id: int) -> void: requested.append(id))
	var window: Node = panels.call("open_teleport_board", "Fixture Gate", _entries())
	_check(window != null and window.visible, "the board opens")
	if window == null:
		panels.free()
		return
	# The authored title static carries the caption; HudWindow's own bar is
	# left empty (no second caption over it).
	var title := window.call("node", "GDR_TB_STATIC_TITLE") as Label
	_check(title != null and title.text == "Fixture Teleporter", "the authored title static reads UIIT_PAG_TELEPORT (got %s)" % (title.text if title != null else "<none>"))
	var bar := window.get_node_or_null("TitleBar") as Label
	_check(bar == null or bar.text == "", "the window's own title bar is empty")

	var counts := _rows(window)
	_check(counts == [5, 5], "exactly five slot rows built, five shown on page 0 (got built %d, shown %d)" % counts)
	_check(_slot_text(window, 1, "GDR_TAS_STATIC_PLACE") == "Fixture Donwhang", "slot 1's place is the first destination (got %s)" % _slot_text(window, 1, "GDR_TAS_STATIC_PLACE"))
	_check(_slot_text(window, 1, "GDR_TAS_STATIC_PRICE") == "Fixture to [Fixture Donwhang] for [5000] coins.",
		"slot 1's price is the archive's fee format (got %s)" % _slot_text(window, 1, "GDR_TAS_STATIC_PRICE"))
	_check(_slot_text(window, 4, "GDR_TAS_STATIC_PRICE") == "Fixture to [Fixture Hotan] free." and _slot_text(window, 5, "GDR_TAS_STATIC_PRICE") == "Fixture to [Fixture City] free.",
		"a waived row and a 0-fee row take the free format")
	var move_label := _slot_text(window, 1, "ButtonLabel")
	_check(move_label == "Fixture Move", "Move is labelled UIIT_CTL_MOVE (got %s)" % move_label)
	_press_move(window, 1)
	_press_move(window, 3)
	_check(requested == [2, 176], "Move emits teleport_requested with its row's dest_id (got %s)" % [requested])

	# The spinner turns to page 1: one row shown, carrying the sixth.
	var spin := window.call("node", "GDR_TB_SPIN_PAGE") as Control
	_check(spin != null and int(spin.get_meta("max", -1)) == 1, "the spinner ranges over two pages (max %s)" % (spin.get_meta("max", -1) if spin != null else "<none>"))
	if spin != null:
		UiBuilder._spin_step(spin, 1)
	_check(_rows(window) == [5, 1], "page 1 shows one row (got built %d, shown %d)" % _rows(window))
	requested.clear()
	_press_move(window, 1)
	_check(requested == [25], "page 1's Move sends the sixth destination (got %s)" % [requested])

	# The QA path presses the real button: back to page 0 for 175.
	requested.clear()
	var pressed: bool = panels.call("qa_press_teleport_move", 175) if panels.has_method("qa_press_teleport_move") else false
	_check(pressed and requested == [175] and _rows(window) == [5, 5], "qa_press_teleport_move(175) turns back to page 0 and presses its Move (got %s)" % [requested])
	_check(panels.call("qa_press_teleport_move", 999) == false if panels.has_method("qa_press_teleport_move") else false,
		"NEGATIVE: a destination the board does not list presses nothing")

	# Reopening at another gate with fewer destinations resets the page and
	# hides the empty slots.
	panels.call("open_teleport_board", "Fixture Gate 2", _entries().slice(0, 2))
	_check(_rows(window) == [5, 2] and spin != null and int(spin.get_meta("max", -1)) == 0 and int(spin.get_meta("value", -1)) == 0,
		"a two-destination gate shows two rows on one page (got %s)" % [_rows(window)])
	panels.queue_free()

func _world_checks(panels_script: GDScript) -> void:
	var world_script := load("res://scripts/World3D.gd") as GDScript
	var world_ok := world_script != null and world_script.can_instantiate()
	_check(world_ok, "World3D compiles in _initialize")
	if not world_ok:
		return
	var world: Node = world_script.new()
	var chat := RichTextLabel.new()
	world.set("chat_log", chat)
	var panels: Node = panels_script.new(_builder())
	root.add_child(panels)
	world.set("_hud_panels", panels)
	world.set("_teleport_reader", _reader())
	world.set("_talk_npc_code", "STORE_CH_GATE")
	world.set("_talk_npc_name", "Fixture Gate")
	var names_row := PackedStringArray()
	names_row.resize(10)
	names_row.fill("0")
	names_row[0] = "1"
	names_row[1] = "SN_ZONE_2"
	names_row[8] = "Fixture Donwhang"
	world.set("_object_name_table", UiTextTable.parse(("\t".join(names_row) + "\n").to_utf16_buffer()))

	# The gate's talk line opens the board with the point's six links, in the
	# link table's file order. NEGATIVE: before round 578 the line fell to the
	# default, "Teleport is not available yet.", and no board opened.
	world.call("_on_npc_service_selected", "teleport")
	_check(chat.get_parsed_text().find("not available yet") < 0, "the teleport line no longer answers 'not available yet' (chat: %s)" % chat.get_parsed_text().strip_edges())
	_check(panels.call("is_open", "teleport"), "the teleport line opens the board")
	var window: Node = (panels.get("_windows") as Dictionary).get("teleport")
	if window != null:
		_check(_rows(window) == [5, 5], "Jangan's six links fill page 0's five slots (got %s)" % [_rows(window)])
		_check(_slot_text(window, 1, "GDR_TAS_STATIC_PLACE") == "Fixture Donwhang", "a named destination shows its textdata_object name (got %s)" % _slot_text(window, 1, "GDR_TAS_STATIC_PLACE"))
		_check(_slot_text(window, 2, "GDR_TAS_STATIC_PLACE") == "GATE_175", "an unnamed one shows its teleportdata codename, never the SN_ token (got %s)" % _slot_text(window, 2, "GDR_TAS_STATIC_PLACE"))
	_check(world.get("_teleport_gate_point_id") == 1, "the board remembers Jangan's point, 1, as Move's source")
	# Offline, Move says so rather than sending.
	chat.clear()
	world.call("_on_teleport_requested", 2)
	_check(chat.get_parsed_text().find("needs the server") >= 0, "Move offline says it needs the server (chat: %s)" % chat.get_parsed_text().strip_edges())

	# One request at a time (round 578's review): with a request out, a second
	# Move is ignored before anything else -- here it does not even reach the
	# offline line. NEGATIVE: without the guard it says "needs the server".
	var has_pending := "_teleport_request_pending" in world
	_check(has_pending, "World3D has _teleport_request_pending")
	if has_pending:
		world.set("_teleport_request_pending", true)
		chat.clear()
		world.call("_on_teleport_requested", 2)
		_check(chat.get_parsed_text().find("needs the server") < 0, "a Move while a request is pending is ignored (chat: %s)" % chat.get_parsed_text().strip_edges())
		# Round 582: reopening the board -- its talk box's teleport line is
		# still up behind it -- keeps the request pending, so a second Move
		# before the reply is still ignored. NEGATIVE: round 578's
		# _open_teleport_board cleared the flag, the second Move got through
		# (offline: "needs the server"; online: a second OpTeleportUse, charged
		# again), and both checks below fail.
		panels.call("close", "teleport")
		world.call("_on_npc_service_selected", "teleport")
		_check(panels.call("is_open", "teleport"), "the talk box's teleport line reopens the board")
		_check(world.get("_teleport_request_pending") == true, "reopening the board keeps the pending request")
		chat.clear()
		world.call("_on_teleport_requested", 2)
		_check(chat.get_parsed_text().find("needs the server") < 0, "a Move after reopening the board, before the reply, is still ignored (chat: %s)" % chat.get_parsed_text().strip_edges())

	# The server's refusal leaves the board up; its yes closes it.
	var refused := TeleportNet.Result.new()
	refused.ok = false
	refused.code = 0x1c07
	refused.reason = "not enough gold"
	world.call("_on_teleport_result", refused)
	_check(panels.call("is_open", "teleport"), "a refusal leaves the board open")
	_check(has_pending and world.get("_teleport_request_pending") == false, "the reply clears the pending request, so Move works again")
	var accepted := TeleportNet.Result.new()
	accepted.ok = true
	accepted.fee = 5000
	accepted.destination = "SN_ZONE_2"
	world.call("_on_teleport_result", accepted)
	_check(not panels.call("is_open", "teleport"), "an accepted teleport closes the board")
	_check(world.get("_teleport_arrival_pending") == true, "and marks the arrival")

	_zone_change_checks(world, panels, chat)
	world.free()
	chat.free()
	panels.queue_free()

## No gate UI survives a zone change (round 578's review): the talk box stays
## up behind the board (HudPanels._on_npc_talk_choice), so a talk box left up
## after the Jangan -> Donwhang arrival reopened Jangan's board in Donwhang,
## and Move sent Jangan's links from there. NEGATIVE: with only the board
## closed on a zone change, the talk box, the talk code and a reopened board
## all fail below.
func _zone_change_checks(world: Node, panels: Node, chat: RichTextLabel) -> void:
	panels.call("open_npc_talk", "Fixture Gate", "", [])
	world.call("_on_npc_service_selected", "teleport")
	_check(panels.call("is_open", "npctalk") and panels.call("is_open", "teleport"),
		"the gate's talk box and board are up before the zone change")
	# A placeholder loading screen: _show_loading_screen then returns without
	# awaiting a frame, and the handler stops at its not-in-tree guard -- the
	# gate UI is closed before either.
	var screen := LoadingScreen.new()
	world.set("_loading_screen", screen)

	# A refused zone change moves nobody: the gate UI stays.
	var refused := WorldNet.ChangeZoneResult.new()
	refused.ok = false
	refused.reason = "fixture refusal"
	world.call("_on_change_zone_result", refused)
	_check(panels.call("is_open", "npctalk") and panels.call("is_open", "teleport") and world.get("_talk_npc_code") == "STORE_CH_GATE",
		"a refused zone change leaves the talk box, the board and the talk code")

	var arrived := WorldNet.ChangeZoneResult.new()
	arrived.ok = true
	arrived.zone = "102/153"
	# A request still out when the zone changes is forgotten with the gate
	# (round 582 keeps it across a reopen, so this is where it must go).
	world.set("_teleport_request_pending", true)
	world.call("_on_change_zone_result", arrived)
	_check(world.get("_teleport_request_pending") == false, "a zone change clears a pending teleport request")
	_check(not panels.call("is_open", "teleport"), "a zone change closes the board")
	_check(not panels.call("is_open", "npctalk"), "a zone change closes the gate's talk box")
	_check(world.get("_talk_npc_code") == "" and world.get("_teleport_gate_point_id") == 0,
		"a zone change forgets the gate being talked to (code '%s', point %s)" % [world.get("_talk_npc_code"), world.get("_teleport_gate_point_id")])
	# The teleport line chosen afterwards (a stale click) opens nothing and
	# says nothing.
	chat.clear()
	world.call("_on_npc_service_selected", "teleport")
	_check(not panels.call("is_open", "teleport"), "the teleport line after a zone change opens no board")
	_check(chat.get_parsed_text().strip_edges() == "", "and logs nothing (chat: %s)" % chat.get_parsed_text().strip_edges())
	world.set("_loading_screen", null)
	screen.free()
