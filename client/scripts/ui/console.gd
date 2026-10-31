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
## This is OpenSRO's own tooling. Everything here is disclosed, not read
## from the original client, which had no slash console.

## Client-side commands the console runs itself.
const CLIENT_COMMANDS := ["help", "where", "log", "copy", "fps", "entities", "wire", "cam", "errors", "w", "whisper", "unstuck", "stuck", "groundprobe", "layer", "grantname", "friend", "invite", "duel", "uiscale", "names"]

## GM commands the console forwards to the server, which gates and runs them.
## Listed so a typo gets the help line while a real GM word reaches the
## server (which refuses a non-GM). Mirrors server/internal/gm's dispatcher.
## server/internal/gm's TestConsoleListsEveryCommand keeps the two in step
## (round 837: /silk and eight older commands were missing here).
const GM_COMMANDS := ["tp", "goto", "give", "item", "avatar", "gold", "level", "heal", "spawn", "spawnunique", "kill", "damage", "durability", "sp", "hwan", "notice", "invsize", "speed", "hurt", "afflict", "hour", "ban", "block", "unblock", "blockinfo", "chatban", "unchatban", "tradeban", "untradeban", "questblock", "jobexp", "jobweek", "guildlevel", "guildperm", "guildabsent", "guildgp", "union", "guildwar", "silk", "lottery"]

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
		"layer":
			# Round 789 (OURS): which layer of the archive set serves a path --
			# custom/, a pack, or a base archive (AssetArchives.which).
			if args.is_empty():
				_log("Usage: /layer <archive path> (which pack or archive serves it)")
			else:
				_log(AssetArchives.describe_which(AssetArchives.current().which(" ".join(args))))
		"grantname":
			# Round 814: the own grant name -- the guild line's "[guild * name]"
			# (GuildPlateNet; a member names only themselves, OURS). Nothing
			# after it clears the name. At most 12 bytes (READ, the server's
			# `< 0xd`); the server also runs the name filter.
			var nick := " ".join(args)
			if nick.to_utf8_buffer().size() > GuildPlateNet.MAX_NICKNAME_BYTES:
				_log("Usage: /grantname <name> (at most %d letters; nothing clears it)" % GuildPlateNet.MAX_NICKNAME_BYTES)
			else:
				_call("grant_name", [nick])
		"duel":
			# Round 848 (OURS): the prototype duel (DuelNet), whose only way in
			# was the native Duel tab. /duel <name> challenges; accept,
			# decline and hit answer and strike.
			var verb := String(args[0]).to_lower() if args.size() == 1 else ""
			if args.is_empty():
				_log("Usage: /duel <name> | /duel accept | /duel decline | /duel hit")
			elif args.size() == 1 and verb in ["accept", "decline", "hit"]:
				_call("duel", [verb, ""])
			else:
				_call("duel", ["challenge", " ".join(args)])
		"uiscale":
			# Round 848 (OURS): the debug panel's UI scale, for everyone.
			if args.size() != 1 or not String(args[0]).is_valid_float():
				_log("Usage: /uiscale <0.5 to 3> (the interface's scale; 1 is the original's size)")
			else:
				var applied := float(_call("set_ui_scale", [float(args[0])], -1.0))
				if applied > 0.0:
					_log("UI scale %.2f." % applied)
		"names":
			# Round 848 (OURS): the debug panel's name range, for everyone.
			if args.size() != 1 or not String(args[0]).is_valid_float():
				_log("Usage: /names <0 to 400> (how near a name plate shows)")
			else:
				var range_set := float(_call("set_name_range", [float(args[0])], -1.0))
				if range_set >= 0.0:
					_log("Names shown within %d." % int(range_set))
		"friend", "invite":
			# Round 834: retail's own chat commands (UIIT_STT_CHAT_COMMAND_
			# FRIEND_INVITE1 / 2, c:0x7af513): ask the named player to be
			# friends (0x7302).
			var who := " ".join(args).strip_edges()
			if who == "":
				_log("Usage: /friend <name> (asks that player to be your friend)")
			else:
				_call("friend_ask", [who])
		_:
			if GM_COMMANDS.has(cmd):
				_call("forward_gm", [body])
			else:
				_log("Unknown command /%s. %s" % [cmd, help_line()])
	return true

## The one-line help. The client commands always; the GM line only for a GM.
func help_line() -> String:
	var base := "Commands: /help /where /log /copy /fps /entities /wire on|off /cam free|orbit /errors /unstuck /groundprobe /layer <path> /w <name> <msg> /grantname <name> /uiscale <n> /names <n> /duel <name>"
	if is_gm:
		return base + "\n" + gm_help_line()
	return base

## The GM one-liner, shown to a GM in chat on enter-world and in the tooltip.
func gm_help_line() -> String:
	return "GM tools: /tp /give /item /avatar /level /spawn /spawnunique /heal /gold /silk /durability /sp /kill /damage /goto /hwan /notice /invsize /speed /hurt /afflict /hour /ban /block /unblock /blockinfo /chatban /tradeban /jobexp /jobweek /guildlevel -- type /help"

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
