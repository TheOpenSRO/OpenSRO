class_name WindowTitle
extends RefCounted

## The game window's title (round 778, the user's request): "[<character>]
## <server>" while in the world -- "[deadass3] OldSRO" -- and the project's
## name everywhere else. The server is the server list entry the player
## picked (ClientSettings.server_name, the setting file's `name`); with none
## (an address typed in by hand) the project's name stands in. OURS.

const DEFAULT := "OpenSRO"

static func in_world(character: String, server: String) -> String:
	var s := server.strip_edges()
	if s == "":
		s = DEFAULT
	if character.strip_edges() == "":
		return s
	return "[%s] %s" % [character.strip_edges(), s]

static func apply_in_world(character: String) -> void:
	DisplayServer.window_set_title(in_world(character, ClientSettings.server_name()))

static func apply_default() -> void:
	DisplayServer.window_set_title(DEFAULT)
