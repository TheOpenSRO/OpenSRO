extends SceneTree

## Tests for the chat-input slash console. Headless: the console talks to the
## world only through a host dictionary of Callables, so recording stubs stand
## in for World3D and every branch is checked without a window.

var _failures := 0
var _logged: PackedStringArray = []
var _calls: Dictionary = {}

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _joined() -> String:
	return "\n".join(_logged)

func _reset() -> void:
	_logged = []
	_calls = {}

## A host whose callables record what the console asked of them.
func _host() -> Dictionary:
	return {
		"log": func(t: String) -> void: _logged.append(t),
		"open_help": func() -> void: _calls["open_help"] = true,
		"where": func() -> PackedStringArray: return PackedStringArray(["zone: jangan", "region 97/168"]),
		"log_path": func() -> String: return "/home/x/.local/share/srrevamp/logs/srrevamp.log",
		"open_log_dir": func() -> bool: return false,
		"copy_payload": func() -> String: return "== build\nx",
		"set_clipboard": func(s: String) -> void: _calls["clipboard"] = s,
		"fps": func() -> float: return 59.5,
		"entities": func() -> String: return "monsters 3, npcs 2, players 1, ground items 0",
		"set_wire": func(on: bool) -> void: _calls["wire"] = on,
		"set_camera_mode": func(m: String) -> bool: _calls["cam"] = m; return m == "free" or m == "orbit",
		"recent_errors": func(_n: int) -> PackedStringArray: return PackedStringArray(["SCRIPT ERROR: boom"]),
		"whisper": func(n: String, m: String) -> void: _calls["whisper"] = [n, m],
		"unstuck": func() -> void: _calls["unstuck"] = true,
		"forward_gm": func(line: String) -> void: _calls["gm"] = line,
	}

func _test_non_slash_is_not_handled() -> void:
	_reset()
	var c := Console.new(_host())
	_check(c.submit("hello world") == false, "a non-slash line is not a command")
	_check(_logged.is_empty(), "a non-slash line logs nothing")

func _test_help_opens_window_and_prints() -> void:
	_reset()
	var c := Console.new(_host())
	c.submit("/help")
	_check(_calls.get("open_help", false) == true, "/help opens the help window")
	_check(_joined().contains("/where"), "/help prints the one-line help")
	_check(not _joined().contains("GM tools"), "no GM line for a non-GM")
	# With an argument the window does not open, but help still prints.
	_reset()
	c.submit("/help playing")
	_check(_calls.get("open_help", false) == false, "/help <topic> does not open the window")
	_check(_joined().contains("/where"), "/help <topic> still prints help")

func _test_gm_help_line_when_gm() -> void:
	_reset()
	var c := Console.new(_host())
	c.is_gm = true
	c.submit("/help playing")
	_check(_joined().contains("GM tools: /tp"), "a GM sees the GM line in help")

func _test_client_commands() -> void:
	_reset()
	var c := Console.new(_host())
	c.submit("/where")
	_check(_joined().contains("region 97/168"), "/where prints the report")

	_reset()
	c.submit("/fps")
	_check(_joined().contains("59.5"), "/fps prints the frame rate")

	_reset()
	c.submit("/entities")
	_check(_joined().contains("monsters 3"), "/entities prints counts")

	_reset()
	c.submit("/log")
	_check(_joined().contains("srrevamp.log"), "/log prints the log path")

	_reset()
	c.submit("/copy")
	_check(_calls.has("clipboard") and String(_calls["clipboard"]).contains("== build"), "/copy sets the clipboard")
	_check(_joined().contains("Copied"), "/copy confirms")

	_reset()
	c.submit("/errors")
	_check(_joined().contains("SCRIPT ERROR: boom"), "/errors prints recent errors")

func _test_wire_and_cam_validate() -> void:
	var c := Console.new(_host())
	_reset()
	c.submit("/wire on")
	_check(_calls.get("wire") == true, "/wire on turns wire logging on")
	_reset()
	c.submit("/wire")
	_check(_joined().contains("Usage: /wire"), "/wire with no argument prints usage")
	_check(not _calls.has("wire"), "/wire with no argument does nothing")
	_reset()
	c.submit("/cam free")
	_check(_calls.get("cam") == "free", "/cam free sets the camera")
	_reset()
	c.submit("/cam sideways")
	_check(_joined().contains("Usage: /cam"), "an invalid camera mode prints usage")

func _test_whisper_and_unstuck() -> void:
	var c := Console.new(_host())
	_reset()
	c.submit("/w Aria hello there")
	_check(_calls.get("whisper") == ["Aria", "hello there"], "/w forwards name and message")
	_reset()
	c.submit("/w Aria")
	_check(_joined().contains("Usage: /w"), "/w with no message prints usage")
	_reset()
	c.submit("/unstuck")
	_check(_calls.get("unstuck", false) == true, "/unstuck calls the host")

func _test_gm_forwarding_and_unknown() -> void:
	var c := Console.new(_host())
	_reset()
	c.submit("/tp -300 -880")
	_check(_calls.get("gm") == "tp -300 -880", "a GM command is forwarded to the server verbatim (no slash)")
	_check(_logged.is_empty(), "forwarding a GM command prints nothing locally (the server replies)")
	_reset()
	c.submit("/frobnicate 1 2")
	_check(_joined().contains("Unknown command /frobnicate"), "an unknown command gets the help line")
	_check(_joined().contains("/where"), "the unknown-command reply carries the help")

func _test_partial_host_is_safe() -> void:
	# A host missing most callables must not crash: a missing entry is a no-op.
	var c := Console.new({"log": func(t: String) -> void: _logged.append(t)})
	_reset()
	c.submit("/where")   # no "where" callable
	c.submit("/copy")    # no "copy_payload"/"set_clipboard"
	c.submit("/fps")
	_check(true, "a partial host does not crash the console")

func _init() -> void:
	_test_non_slash_is_not_handled()
	_test_help_opens_window_and_prints()
	_test_gm_help_line_when_gm()
	_test_client_commands()
	_test_wire_and_cam_validate()
	_test_whisper_and_unstuck()
	_test_gm_forwarding_and_unknown()
	_test_partial_host_is_safe()

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
