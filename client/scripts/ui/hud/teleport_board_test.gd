extends SceneTree

## Exercises a gate's destination list (round 603; round 578 built a board
## window instead): TeleportBoard's line and price helpers, the list HudPanels
## writes into the talk box, and World3D's talk line -> list -> click ->
## receipt wiring over synthetic teleport tables. The retail client lists the
## destinations in the talk box itself (UI_TELEPORT::FUN_006fd3e0, called from
## CIF_NPCTalk::FUN_007020c0 at 0x702973) and has no teleport window. Every
## text here is a fixture string, never the archive's; no game data.
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

## Six destinations, the shape World3D._open_teleport_list builds.
func _entries() -> Array:
	return [
		{"dest_id": 2, "place": "Fixture Donwhang", "fee": 1111, "waived": false},
		{"dest_id": 175, "place": "Fixture West", "fee": 2222, "waived": false},
		{"dest_id": 176, "place": "Fixture East", "fee": 3333, "waived": false},
		{"dest_id": 5, "place": "Fixture Hotan", "fee": 4444, "waived": true},
		{"dest_id": 20, "place": "Fixture City", "fee": 0, "waived": false},
		{"dest_id": 25, "place": "Fixture Last", "fee": 5555, "waived": false},
	]

## The fixture formats and end line, in the shape of the archive's rows.
const FEE_FMT := "Fixture to [%s] for [%d] coins."
const FREE_FMT := "Fixture to [%s] free."
const END_TEXT := "Fixture end."

## The six entries' lines as the talk box must draw them, numbered from 1,
## then the end line numbered 7.
const DRAWN := [
	"1. Fixture to [Fixture Donwhang] for [1111] coins.",
	"2. Fixture to [Fixture West] for [2222] coins.",
	"3. Fixture to [Fixture East] for [3333] coins.",
	"4. Fixture to [Fixture Hotan] free.",
	"5. Fixture to [Fixture City] free.",
	"6. Fixture to [Fixture Last] for [5555] coins.",
	"7. Fixture end.",
]

func _board() -> Object:
	if not ResourceLoader.exists(BOARD_PATH):
		return null
	var script := load(BOARD_PATH) as GDScript
	if script == null or not script.can_instantiate():
		return null
	return script.new()

func _resolve(token: String, fallback: String) -> String:
	match token:
		"UIIT_CTL_TELEPORT_RESULT":
			return FEE_FMT
		"UIIT_CTL_TELEPORT_FREE_RESULT":
			return FREE_FMT
		"UIIT_STT_NPC_CHATTING_WND_TALKEND":
			return END_TEXT
	return fallback

func _init() -> void:
	var board := _board()
	_check(board != null, "TeleportBoard loads and instantiates")
	var ok := board != null and board.has_method("price_text") and board.has_method("list_lines") and board.has_method("dest_from_key")
	_check(ok, "TeleportBoard has price_text, list_lines and dest_from_key")
	if not ok:
		return  # _initialize still runs, and reports

	# The price line in the archive's own formats: the fee format with the
	# numbers substituted, the free format for a 0 fee or the level waiver.
	var paid: String = board.call("price_text", "Fixture Place", 1111, false, FEE_FMT, FREE_FMT)
	_check(paid == "Fixture to [Fixture Place] for [1111] coins.", "a 1111 fee fills the fee format (got %s)" % paid)
	var free: String = board.call("price_text", "Fixture Place", 0, false, FEE_FMT, FREE_FMT)
	_check(free == "Fixture to [Fixture Place] free.", "a 0 fee takes the free format (got %s)" % free)
	var waived: String = board.call("price_text", "Fixture Place", 1111, true, FEE_FMT, FREE_FMT)
	_check(waived == "Fixture to [Fixture Place] free.", "the level waiver takes the free format (got %s)" % waived)
	# A format that is not the expected placeholders (or no archive at all)
	# falls back to our own wording rather than erroring in `%` -- and keeps
	# the place (round 603's review: "1. 1111 gold" said nothing of where).
	var bad: String = board.call("price_text", "Fixture Place", 1111, false, "Fixture %s", "")
	_check(bad == "Fixture Place -- 1111 gold", "a malformed format falls back to our own wording with the place (got %s)" % bad)
	var bad_free: String = board.call("price_text", "Fixture Place", 0, false, "", "")
	_check(bad_free == "Fixture Place -- No cost", "a missing free format falls back with the place (got %s)" % bad_free)
	var no_place: String = board.call("price_text", "", 1111, false, FEE_FMT, FREE_FMT)
	_check(no_place == "1111 gold", "no place gives the bare fee (got %s)" % no_place)

	# The lines: every destination on one list (the client has no pages),
	# numbered from 1 in the order given, each a link keyed by its
	# destination, then the end line with the next number. The text's own
	# brackets are escaped, so they draw rather than parse as tags.
	var lines: PackedStringArray = board.call("list_lines", "Fixture Gate", _entries(), _resolve)
	_check(lines.size() == 7, "six destinations give seven lines, the end line last (got %d)" % lines.size())
	if lines.size() == 7:
		_check(lines[0] == "[url=teleport_dest:2]1. Fixture to [lb]Fixture Donwhang] for [lb]1111] coins.[/url]",
			"line 1 is destination 2's link with its escaped text (got %s)" % lines[0])
		_check(lines[5].begins_with("[url=teleport_dest:25]6. "), "line 6 is the sixth destination, on the same list (got %s)" % lines[5])
		_check(lines[6] == "[url=end]7. Fixture end.[/url]", "line 7 is the talk box's end line (got %s)" % lines[6])
	var bare: PackedStringArray = board.call("list_lines", "Fixture Gate", _entries().slice(0, 1), func(_t: String, f: String) -> String: return f)
	_check(bare.size() == 2 and bare[0] == "[url=teleport_dest:2]1. Fixture Donwhang -- 1111 gold[/url]",
		"with no archive formats a line still names its place (got %s)" % [bare])
	_check(board.call("dest_from_key", "teleport_dest:176") == 176, "dest_from_key reads a destination line's key")
	_check(board.call("dest_from_key", "shop") == -1 and board.call("dest_from_key", "teleport_dest:x") == -1,
		"NEGATIVE: a service key or a malformed key is no destination")

func _control(control_name: String, type: String, rect: String, text: String) -> String:
	return "\t%s:%s\n\t{\n\t\tClientRect=RECT,\"0,0,0,0\"\n\t\tDDJ=STRING,\"\"\n\t\tFontColor=COLOR,\"255,255,255,255\"\n\t\tFontIndex=INTEGER,\"2\"\n\t\tRect=RECT,\"%s\"\n\t\tText=STRING,\"%s\"\n\t}\n" % [control_name, type, rect, text]

func _text_row(token: String, english: String) -> String:
	return "1\t%s\t0\t0\t0\t0\t0\t0\t%s\t0" % [token, english]

func _text_table(rows: Array) -> UiTextTable:
	return UiTextTable.parse(("\n".join(PackedStringArray(rows))).to_utf16_buffer())

## A builder with no archive whose layout cache holds a one-static talk box (a
## fixture rect, not the authored if_npctalk.txt), so open_npc_talk builds one.
func _builder() -> UiBuilder:
	var builder := UiBuilder.new(null, _text_table([
		_text_row("UIIT_CTL_TELEPORT_RESULT", FEE_FMT),
		_text_row("UIIT_CTL_TELEPORT_FREE_RESULT", FREE_FMT),
		_text_row("UIIT_STT_NPC_CHATTING_WND_TALKEND", END_TEXT),
	]))
	var cache: Dictionary = builder.get("_layout_cache")
	cache["resinfo\\if_npctalk.txt"] = UiLayoutParser.parse("Interface Text\n\nSection = Create,\"0,0,0,0\",\"0\"\n{\n" \
		+ _control("GDR_NPCTALK_BGTILE", "CIFStatic", "0,0,300,200", "") + "}\n")
	return builder

func _talk_body(panels: Node) -> RichTextLabel:
	var window: Node = (panels.get("_windows") as Dictionary).get("npctalk")
	return window.get_node_or_null("TalkText") as RichTextLabel if window != null else null

func _talk_lines(panels: Node) -> PackedStringArray:
	var body := _talk_body(panels)
	return body.get_parsed_text().split("\n") if body != null else PackedStringArray()

## The windows HudPanels has on screen, by key.
func _shown(panels: Node) -> Array:
	var out: Array = []
	var windows: Dictionary = panels.get("_windows")
	for key in windows:
		var w: Control = windows[key]
		if w != null and w.visible:
			out.append(key)
	return out

## teleportdata / teleportlink / teleportbuilding rows in the archive's shape
## (TeleportReader's columns): a gate at point 1 (building 2094, the shape of
## Jangan's) with six links whose fees are synthetic (1111 ... 5555, one 0),
## not the retail ones.
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
	for pair in [[2, 1111], [175, 2222], [176, 3333], [5, 4444], [20, 0], [25, 5555]]:
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
		_list_checks(panels_script)
		_world_checks(panels_script)
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

func _list_checks(panels_script: GDScript) -> void:
	# NEGATIVE: round 578 registered a "teleport" window built from
	# ifteleportboard.txt, a layout the exe never names.
	var spec_map: Dictionary = panels_script.get_script_constant_map().get("PANELS", {})
	_check(not spec_map.has("teleport"), "PANELS has no teleport window (got %s)" % [spec_map.get("teleport", [])])
	var panels: Node = panels_script.new(_builder())
	root.add_child(panels)
	var has_list := panels.has_method("open_teleport_list") and panels.has_method("teleport_list_shown") \
		and panels.has_method("qa_press_teleport_line") and panels.has_signal("teleport_requested")
	_check(has_list, "HudPanels has open_teleport_list, teleport_list_shown, qa_press_teleport_line and teleport_requested")
	if not has_list:
		panels.queue_free()
		return
	var requested: Array = []
	panels.connect("teleport_requested", func(id: int) -> void: requested.append(id))
	_check(panels.call("open_teleport_list", "Fixture Gate", _entries()) == false,
		"NEGATIVE: with no talk box up, the list draws nowhere")
	panels.call("open_npc_talk", "Fixture Gate", "Fixture greeting", NpcServiceReader.gate_services(true, true, false))
	_check(panels.call("teleport_list_shown") == false, "the gate's menu is not a destination list")
	_check(panels.call("open_teleport_list", "Fixture Gate", _entries()) == true, "the list opens in the talk box")
	var drawn := _talk_lines(panels)
	var want := PackedStringArray(["Fixture greeting", ""])
	want.append_array(PackedStringArray(DRAWN))
	_check(drawn == want, "the talk box keeps its text on top, then all six destinations and the end line, as drawn (got %s)" % [drawn])
	_check(_shown(panels) == ["npctalk"], "no window but the talk box is up (got %s)" % [_shown(panels)])

	# A click on a line is the request; the talk box stays up.
	var body := _talk_body(panels)
	body.meta_clicked.emit("teleport_dest:176")
	_check(requested == [176], "clicking line 3 requests destination 176 (got %s)" % [requested])
	_check(panels.call("is_open", "npctalk") and panels.call("teleport_list_shown"), "the talk box and its list stay up after the click")
	requested.clear()
	_check(panels.call("qa_press_teleport_line", 25) == true and requested == [25],
		"qa_press_teleport_line(25) clicks the sixth line (got %s)" % [requested])
	requested.clear()
	_check(panels.call("qa_press_teleport_line", 999) == false and requested.is_empty(),
		"NEGATIVE: a destination the list does not hold clicks nothing")

	# A guild reply's refresh does not turn the list back into the menu.
	panels.call("refresh_npc_talk", "Fixture Gate", "Fixture greeting", NpcServiceReader.gate_services(true, true, false))
	_check(_talk_lines(panels) == want, "a refresh leaves the destination list")
	# A new conversation is the menu again.
	panels.call("open_npc_talk", "Fixture Gate", "Fixture greeting", NpcServiceReader.gate_services(true, true, false))
	_check(panels.call("teleport_list_shown") == false, "a new conversation drops the list")
	# The end line closes the talk box, as the menu's does.
	panels.call("open_teleport_list", "Fixture Gate", _entries().slice(0, 2))
	_check(_talk_lines(panels).size() == 5 and _talk_lines(panels)[4] == "3. Fixture end.",
		"two destinations number the end line 3 (got %s)" % [_talk_lines(panels)])
	body.meta_clicked.emit("end")
	_check(not panels.call("is_open", "npctalk") and requested.is_empty(), "the end line closes the talk box and requests nothing")
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
	# World3D._ready makes this connection; the suite does not run _ready.
	panels.connect("teleport_requested", Callable(world, "_on_teleport_requested"))
	var names_row := PackedStringArray()
	names_row.resize(10)
	names_row.fill("0")
	names_row[0] = "1"
	names_row[1] = "SN_ZONE_2"
	names_row[8] = "Fixture Donwhang"
	world.set("_object_name_table", UiTextTable.parse(("\t".join(names_row) + "\n").to_utf16_buffer()))
	panels.call("open_npc_talk", "Fixture Gate", "", [])

	# The gate's talk line lists the point's six links in the talk box, in the
	# link table's file order. NEGATIVE: round 578 opened a board window.
	world.call("_on_npc_service_selected", "teleport")
	_check(chat.get_parsed_text().find("not available yet") < 0, "the teleport line no longer answers 'not available yet' (chat: %s)" % chat.get_parsed_text().strip_edges())
	var shown: bool = panels.call("teleport_list_shown") if panels.has_method("teleport_list_shown") else false
	_check(shown, "the teleport line lists the destinations in the talk box")
	_check(_shown(panels) == ["npctalk"], "and opens no other window (got %s)" % [_shown(panels)])
	var drawn := _talk_lines(panels)
	_check(drawn.size() == 9, "the talk text, a blank line, six destinations and the end line (got %d: %s)" % [drawn.size(), drawn])
	if drawn.size() == 9:
		_check(drawn[2] == "1. Fixture to [Fixture Donwhang] for [1111] coins.", "a named destination shows its textdata_object name (got %s)" % drawn[2])
		_check(drawn[3] == "2. Fixture to [GATE_175] for [2222] coins.", "an unnamed one shows its teleportdata codename, never the SN_ token (got %s)" % drawn[3])
		_check(drawn[8] == "7. Fixture end.", "the end line is numbered after the destinations (got %s)" % drawn[8])
	_check(world.get("_teleport_gate_point_id") == 1, "the list remembers Jangan's point, 1, as the click's source")
	# Offline, a click on a line says so rather than sending.
	chat.clear()
	var body := _talk_body(panels)
	if body != null:
		body.meta_clicked.emit("teleport_dest:2")
	_check(chat.get_parsed_text().find("needs the server") >= 0, "a line clicked offline says it needs the server (chat: %s)" % chat.get_parsed_text().strip_edges())

	# One request at a time (round 578's review): with a request out, a second
	# click is ignored before anything else -- here it does not even reach the
	# offline line. NEGATIVE: without the guard it says "needs the server".
	var has_pending := "_teleport_request_pending" in world
	_check(has_pending, "World3D has _teleport_request_pending")
	if has_pending:
		world.set("_teleport_request_pending", true)
		chat.clear()
		if body != null:
			body.meta_clicked.emit("teleport_dest:2")
		_check(chat.get_parsed_text().find("needs the server") < 0, "a click while a request is pending is ignored (chat: %s)" % chat.get_parsed_text().strip_edges())
		# Round 582: listing the destinations again keeps the request pending,
		# so a second click before the reply is still ignored.
		world.call("_on_npc_service_selected", "teleport")
		_check(world.get("_teleport_request_pending") == true, "listing the destinations again keeps the pending request")
		chat.clear()
		world.call("_on_teleport_requested", 2)
		_check(chat.get_parsed_text().find("needs the server") < 0, "a click after listing them again, before the reply, is still ignored (chat: %s)" % chat.get_parsed_text().strip_edges())

	# The server's refusal leaves the list up to choose again; its yes marks
	# the arrival, and the zone change after it closes the talk box.
	var refused := TeleportNet.Result.new()
	refused.ok = false
	refused.code = 0x1c07
	refused.reason = "not enough gold"
	world.call("_on_teleport_result", refused)
	_check(shown and panels.call("teleport_list_shown"), "a refusal leaves the list up")
	_check(has_pending and world.get("_teleport_request_pending") == false, "the reply clears the pending request, so a click works again")
	var accepted := TeleportNet.Result.new()
	accepted.ok = true
	accepted.fee = 1111
	accepted.destination = "SN_ZONE_2"
	# The request this reply answers is out (offline, the send path stops at
	# "needs the server", so the flag is set here as a sent click sets it).
	world.set("_teleport_request_pending", true)
	world.call("_on_teleport_result", accepted)
	_check(world.get("_teleport_arrival_pending") == true, "an accepted teleport marks the arrival")
	# Round 603's review: between the server's yes and its zone change the
	# talk box still lists the destinations, and the two can land in
	# different frames. A click there must not send a second OpTeleportUse
	# (the server would charge again). NEGATIVE: dae2dc9 cleared the request
	# on the yes, so the click reached the send path ("needs the server").
	_check(world.get("_teleport_request_pending") == true, "an accepted reply leaves the request pending until the zone change")
	chat.clear()
	if body != null:
		body.meta_clicked.emit("teleport_dest:175")
	_check(chat.get_parsed_text().find("needs the server") < 0, "a click after the yes and before the zone change is ignored (chat: %s)" % chat.get_parsed_text().strip_edges())
	# The move then fails (warpTo's "not in the world"; the server refunds):
	# the refused zone change ends the request, so a line works again.
	var failed := WorldNet.ChangeZoneResult.new()
	failed.ok = false
	failed.reason = "fixture refusal"
	world.call("_on_change_zone_result", failed)
	_check(world.get("_teleport_request_pending") == false, "a refused zone change after the yes clears the request")
	chat.clear()
	if body != null:
		body.meta_clicked.emit("teleport_dest:175")
	_check(chat.get_parsed_text().find("needs the server") >= 0, "and a click works again (chat: %s)" % chat.get_parsed_text().strip_edges())
	# A refused zone change that is no teleport's arrival leaves a request
	# that is still out alone.
	world.set("_teleport_request_pending", true)
	world.call("_on_change_zone_result", failed)
	_check(world.get("_teleport_request_pending") == true, "NEGATIVE: an unrelated refused zone change keeps a pending request")
	world.set("_teleport_request_pending", false)

	_zone_change_checks(world, panels, chat)
	world.free()
	chat.free()
	panels.queue_free()

## No gate UI survives a zone change (round 578's review): a talk box left up
## after the Jangan -> Donwhang arrival would list Jangan's destinations in
## Donwhang, and a click would send Jangan's links from there.
func _zone_change_checks(world: Node, panels: Node, chat: RichTextLabel) -> void:
	panels.call("open_npc_talk", "Fixture Gate", "", [])
	world.call("_on_npc_service_selected", "teleport")
	var shown: bool = panels.call("teleport_list_shown") if panels.has_method("teleport_list_shown") else false
	_check(shown, "the gate's talk box lists the destinations before the zone change")
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
	_check(shown and panels.call("teleport_list_shown") and world.get("_talk_npc_code") == "STORE_CH_GATE",
		"a refused zone change leaves the talk box, its list and the talk code")

	var arrived := WorldNet.ChangeZoneResult.new()
	arrived.ok = true
	arrived.zone = "102/153"
	# A request still out when the zone changes is forgotten with the gate
	# (round 582 keeps it across a relisting, so this is where it must go).
	world.set("_teleport_request_pending", true)
	world.call("_on_change_zone_result", arrived)
	_check(world.get("_teleport_request_pending") == false, "a zone change clears a pending teleport request")
	_check(not panels.call("is_open", "npctalk"), "a zone change closes the gate's talk box")
	_check(world.get("_talk_npc_code") == "" and world.get("_teleport_gate_point_id") == 0,
		"a zone change forgets the gate being talked to (code '%s', point %s)" % [world.get("_talk_npc_code"), world.get("_teleport_gate_point_id")])
	# The teleport line chosen afterwards (a stale click) lists nothing and
	# says nothing.
	chat.clear()
	world.call("_on_npc_service_selected", "teleport")
	_check(_shown(panels).is_empty(), "the teleport line after a zone change opens nothing (got %s)" % [_shown(panels)])
	_check(chat.get_parsed_text().strip_edges() == "", "and logs nothing (chat: %s)" % chat.get_parsed_text().strip_edges())
	world.set("_loading_screen", null)
	screen.free()
