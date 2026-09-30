extends RefCounted
class_name Console

## The chat-input slash-command console. A tester types a command in the
## same chat line they already use; the console runs the client-side ones
## (reporting into chat and the log), forwards the GM ones to the server,
## and answers an unknown command with the help line -- never silence.
##
## It talks to the world through a `host` dictionary of Callables rather than
## reaching into World3D, so it is exercised headless (console_test.gd) with
## recording stubs. A missing host entry is a no-op, so a partial host (a
## test, or the world before everything is wired) never crashes.
##
## This is srrevamp's own tooling. Everything here is disclosed, not read
## from the original client, which had no slash console.

## Client-side commands the console runs itself.
const CLIENT_COMMANDS := ["help", "where", "log", "copy", "fps", "entities", "wire", "cam", "errors", "w", "whisper", "unstuck", "stuck", "groundprobe"]

## GM commands the console forwards to the server, which gates and runs them.
## Listed so a typo gets the help line while a real GM word reaches the
## server (which refuses a non-GM). Mirrors server/internal/gm's dispatcher.
const GM_COMMANDS := ["tp", "goto", "give", "gold", "level", "heal", "spawn", "spawnunique", "kill", "damage", "durability", "sp", "hwan", "notice", "invsize", "speed"]

## Set from the server's GM probe reply; decides whether help shows the GM
## line and its window shows the GM section.
var is_gm := false

var _host: Dictionary

func _init(host: Dictionary = {}) -> void:
	_host = host

## Handles one chat line that begins with "/". Returns true if it was a
## slash command (always, for such a line) -- the caller sends everything
## else as ordinary chat.
func submit(line: String) -> bool:
	var trimmed := line.strip_edges()
	if not trimmed.begins_with("/"):
		return false
	var body := trimmed.substr(1)
	var parts := body.split(" ", false)
	if parts.is_empty():
		_log(help_line())
		return true
	var cmd := String(parts[0]).to_lower()
	var args: PackedStringArray = parts.slice(1)

	match cmd:
		"help":
			_log(help_line())
			if args.is_empty():
				_call("open_help")
		"where":
			for l in _call("where", [], PackedStringArray()):
				_log(l)
		"log":
			var path := String(_call("log_path", [], ""))
			_log("Log file: %s" % path if path != "" else "Log path unknown.")
			if bool(_call("open_log_dir", [], false)):
				_log("Opened the log folder.")
		"copy":
			var payload := String(_call("copy_payload", [], ""))
			if payload == "":
				_log("Nothing to copy yet.")
			else:
				_call("set_clipboard", [payload])
				_log("Copied the debug report (%d chars) to the clipboard." % payload.length())
		"fps":
			_log("FPS: %.1f" % float(_call("fps", [], 0.0)))
		"entities":
			_log(String(_call("entities", [], "no entity counts available")))
		"wire":
			if args.size() != 1 or (String(args[0]) != "on" and String(args[0]) != "off"):
				_log("Usage: /wire on|off (logs every packet's opcode and size)")
			else:
				var on := String(args[0]) == "on"
				_call("set_wire", [on])
				_log("Packet wire logging %s." % ("on" if on else "off"))
		"cam":
			if args.size() != 1:
				_log("Usage: /cam free|orbit")
			elif bool(_call("set_camera_mode", [String(args[0]).to_lower()], false)):
				_log("Camera: %s." % String(args[0]).to_lower())
			else:
				_log("Usage: /cam free|orbit")
		"errors":
			var errs: PackedStringArray = _call("recent_errors", [20], PackedStringArray())
			if errs.is_empty():
				_log("No script errors logged this session.")
			else:
				_log("Last %d script error(s):" % errs.size())
				for e in errs:
					_log(e)
		"w", "whisper":
			_whisper(args)
		"unstuck", "stuck":
			_call("unstuck")
		"groundprobe":
			# Round 579: records the ground's rendering state for a report of
			# white ground (GroundProbe); "quick" skips its A/B checks.
			var mode := String(args[0]).to_lower() if args.size() == 1 else "full"
			if args.size() > 1 or (mode != "full" and mode != "quick"):
				_log("Usage: /groundprobe [quick] (records the ground's rendering state to a file to send us)")
			else:
				for l in _call("ground_probe", [mode], PackedStringArray(["Ground probe unavailable here."])):
					_log(l)
		_:
			if GM_COMMANDS.has(cmd):
				_call("forward_gm", [body])
			else:
				_log("Unknown command /%s. %s" % [cmd, help_line()])
	return true

## The one-line help. The client commands always; the GM line only for a GM.
func help_line() -> String:
	var base := "Commands: /help /where /log /copy /fps /entities /wire on|off /cam free|orbit /errors /unstuck /groundprobe /w <name> <msg>"
	if is_gm:
		return base + "\n" + gm_help_line()
	return base

## The GM one-liner, shown to a GM in chat on enter-world and in the tooltip.
func gm_help_line() -> String:
	return "GM tools: /tp /give /level /spawn /spawnunique /heal /gold /durability /sp /kill /damage /goto /hwan /notice /invsize /speed -- type /help"

func _whisper(args: PackedStringArray) -> void:
	if args.size() < 2:
		_log("Usage: /w <name> <message>")
		return
	var name := String(args[0])
	var message := " ".join(args.slice(1))
	_call("whisper", [name, message])

func _log(text: String) -> void:
	if text == "":
		return
	# A multi-line help string prints as separate system lines.
	for l in text.split("\n"):
		if _host.has("log"):
			(_host["log"] as Callable).call(String(l))

## Calls a host callable if present, returning its result or `default`.
func _call(name: String, args: Array = [], default: Variant = null) -> Variant:
	if not _host.has(name):
		return default
	return (_host[name] as Callable).callv(args)
