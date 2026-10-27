extends SceneTree

## Round 832: the trace's wire (ActionNet), the selection a trace names, the
## Ping / FPS box's arithmetic, and -- against the real Media.pk2 when the
## box has it -- the Option window's Extra tab and the target menu built from
## their .2dt files.
##   godot4 --headless --path client --script res://scripts/world/trace832_test.gd

const MEDIA := "/opt/sro-files/client/Media.pk2"

var _failures := 0

class FakeNet extends Node:
	signal ping_echo(token: int)
	var sent: Array[int] = []
	func is_connected_to_server() -> bool:
		return true
	func send_ping(token: int) -> void:
		sent.append(token)

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	_wire()
	_targets()
	_counter()
	await _ping()
	await _archive()
	print("FAILURES: %d" % _failures if _failures > 0 else "ALL PASS")
	quit(1 if _failures > 0 else 0)

func _wire() -> void:
	_check(ActionNet.encode_trace(0x01020304) == PackedByteArray([1, 3, 1, 4, 3, 2, 1]),
		"the trace is 0x7074 [01 03 01 <u32>] (0x793b00 case 1003)")
	_check(ActionNet.encode_cancel() == PackedByteArray([2]), "the cancel is [02] (0x78f8d0)")
	var started := ActionNet.decode_result(PackedByteArray([1, 1]))
	var err := ActionNet.decode_result(PackedByteArray([3, 0, 0x04, 0x40]))
	_check(started == {"result": 1, "depth": 1, "code": 0} and err == {"result": 3, "depth": 0, "code": 0x4004},
		"0xB074 is {result, depth} and a u16 code after a 3 (0x880b60)")
	_check(ActionNet.decode_result(PackedByteArray([3, 0])).is_empty() and ActionNet.decode_result(PackedByteArray([1])).is_empty(),
		"a short answer decodes to nothing")
	_check(not ActionNet.ERROR_LINES.has(0x4004) and not ActionNet.ERROR_LINES.has(0x4003)
		and ActionNet.ERROR_LINES[0x4005] == "UIIT_MSG_COS_BAN_FOLLOW_COS", "0x4003 / 0x4004 show nothing (0x7baf0d)")
	_check(ActionNet.decode_ping_echo(ActionNet.encode_ping(77)) == 77 and ActionNet.decode_ping_echo(PackedByteArray([1])) == -1,
		"the ping's token comes back as it went")

func _targets() -> void:
	var W = load("res://scripts/World3D.gd")
	_check(W.trace_target_of(42, 7, true) == 42, "another player selected: their id")
	_check(W.trace_target_of(7, 7, false) == 7, "this player selected: its own id, as retail sends whatever is selected")
	_check(W.trace_target_of(42, 7, false) == 0 and W.trace_target_of(-1, 7, false) == 0,
		"a monster or nothing: 0, which names no one (OpenSRO's ids overlap)")

func _counter() -> void:
	_check(PingFpsCounter.fps_of(30, 0.5) == 60 and PingFpsCounter.fps_of(0, 0.0) == 0, "frames over the half second")
	_check(PingFpsCounter.clamp_into(Vector2(-5, 900), Vector2(800, 600)) == Vector2(0, 600 - PingFpsCounter.BOX_SIZE.y)
		and PingFpsCounter.clamp_into(Vector2(790, 10), Vector2(800, 600)) == Vector2(800 - PingFpsCounter.BOX_SIZE.x, 10),
		"the box stays inside the view")
	_check(PingFpsCounter.BOX_SIZE == Vector2(87, 54) and PingFpsCounter.BORDER_LIGHT == Color8(185, 168, 115),
		"the reference's 87 x 54 box and its beige line (MEASURED, 2x video)")

## A ping goes out every PING_PERIOD_S; its echo sets the shown time; an
## echo of a token never sent is ignored.
func _ping() -> void:
	var net := FakeNet.new()
	root.add_child(net)
	var box := PingFpsCounter.new()
	box.net = net
	root.add_child(box)
	await process_frame
	await process_frame
	_check(net.sent.size() == 1, "the first ping goes out at once (got %d)" % net.sent.size())
	_check(box.ping_ms() == -1, "no time before the echo")
	net.ping_echo.emit(999)
	_check(box.ping_ms() == -1, "a stray echo is ignored")
	if not net.sent.is_empty():
		net.ping_echo.emit(net.sent[0])
	_check(box.ping_ms() >= 0, "the echo sets the time (%d ms)" % box.ping_ms())
	box.queue_free()
	net.queue_free()

func _archive() -> void:
	if not FileAccess.file_exists(MEDIA):
		print("SKIP the archive checks (no %s)" % MEDIA)
		return
	var pk2 := Pk2Reader.open(MEDIA)
	_check(pk2 != null, "Media.pk2 opens")
	if pk2 == null:
		return
	root.size = Vector2i(1280, 720)
	var builder := UiBuilder.new(pk2, null)
	# The Extra tab.
	var saved_ping = ClientSettings.get_value(ClientSettings.SECTION_EXTRA, ClientSettings.KEY_PING_FPS, null)
	var saved_short = ClientSettings.get_value(ClientSettings.SECTION_GAME, ClientSettings.KEY_ACTION_SHORTCUT, null)
	var win := OptionWindow.new(builder)
	root.add_child(win)
	_check(win.build_option(), "the Option window builds from optionwnd.2dt")
	await process_frame
	await process_frame
	var game := win.control([OptionWindow.ID_TAB_GAME])
	var extra := win.control([OptionWindow.ID_TAB_EXTRA])
	_check(extra != null and game != null and is_equal_approx(extra.position.x - game.position.x, 125.0)
		and extra.position.y == game.position.y and extra.size == game.size,
		"the Extra tab: the Game tab's button one step (125) to the right")
	var label := extra.get_node_or_null(TwoDtBuilder.TEXT_NODE) as Label if extra != null else null
	_check(label != null and label.text == "Extra Settings", "labelled Extra Settings (the user's reference)")
	var pane := win.control([OptionWindow.ID_PANE_EXTRA])
	_check(pane != null and not pane.visible, "its pane starts hidden")
	if extra != null and pane != null:
		(extra as BaseButton).pressed.emit()
		_check(pane.visible and win.current_tab() == OptionWindow.ID_TAB_EXTRA
			and not win.control([OptionWindow.ID_PANE_GAME]).visible, "a click shows it and hides the others")
		(game as BaseButton).pressed.emit()
		_check(not pane.visible, "another tab hides it again")
	var box := win.extra_box("ping_fps")
	_check(box != null and win.extra_box("action_short_cut") != null, "two check-box rows")
	if box != null:
		box.button_pressed = true
		_check(win.extra_value("ping_fps"), "ticking the box edits the value")
		var got := {}
		win.extra_applied.connect(func(v: Dictionary) -> void: got.merge(v))
		win.press_apply()
		_check(bool(got.get("ping_fps", false)) and ClientSettings.ping_fps_shown(), "Apply stores it and hands it on")
		(extra as BaseButton).pressed.emit()
		win.press_default()
		_check(not win.extra_value("ping_fps") and not box.button_pressed and not win.extra_value("action_short_cut"),
			"Default on the Extra tab clears every row")
	win.queue_free()
	ClientSettings.set_value(ClientSettings.SECTION_EXTRA, ClientSettings.KEY_PING_FPS, saved_ping if saved_ping != null else false)
	ClientSettings.set_value(ClientSettings.SECTION_GAME, ClientSettings.KEY_ACTION_SHORTCUT, saved_short if saved_short != null else false)
	# The target menu.
	var menu := TargetMenu.new()
	root.add_child(menu)
	_check(menu.build(builder), "the target menu builds from targetmenu.2dt")
	_check(menu.size == Vector2(102, 142), "102 x 142 (got %s)" % str(menu.size))
	var all := true
	for id in TargetMenu.BUTTONS:
		all = all and menu.button(id) != null
	_check(all, "its five buttons")
	menu.open_at(Vector2(300, 200), "Bram")
	_check(menu.visible and menu.position == Vector2(300, 200), "opened with its top-left at the cursor")
	var chosen: Array[int] = []
	menu.chosen.connect(func(id: int) -> void: chosen.append(id))
	menu.button(TargetMenu.ID_TRACE).pressed.emit()
	_check(chosen == [TargetMenu.ID_TRACE] and not menu.visible, "a button hides it and reports itself")
	menu.queue_free()
