extends RefCounted
class_name CharacterLockDevice

## "Remember this PC" (round 788, lane P; OURS): this PC's device token for a
## server, made once and kept. The server stores only its hash and lets a
## status request that carries it past the PIN (docs/protocol/pin.md).
##
## Kept in its own file, user://character_lock.cfg, not ClientSettings'
## settings.cfg: that file is the one a tester reads and passes around, and
## it holds nothing secret (its own header says so); the token is a key to
## the account's PIN. One token per server (host:port), so one server never
## learns another's. Never printed.

const PATH := "user://character_lock.cfg"
const SECTION := "devices"
## 32 random bytes as 64 hex characters (the server takes 16..128 bytes).
const TOKEN_BYTES := 32

## The server's key in the file: host:port, lower case.
static func server_key(host: String, port: int) -> String:
	return "%s:%d" % [host.strip_edges().to_lower(), port]

## This PC's token for the server, made and saved on first use. `path` is a
## test seam.
static func token_for(host: String, port: int, path: String = PATH) -> String:
	var key := server_key(host, port)
	var file := ConfigFile.new()
	file.load(path) # a missing or unreadable file is an empty one
	var token := str(file.get_value(SECTION, key, ""))
	if _valid(token):
		return token
	token = Crypto.new().generate_random_bytes(TOKEN_BYTES).hex_encode()
	file.set_value(SECTION, key, token)
	file.save(path)
	return token

## The token if one was made, "" otherwise (no file is written).
static func existing_token(host: String, port: int, path: String = PATH) -> String:
	var file := ConfigFile.new()
	if file.load(path) != OK:
		return ""
	var token := str(file.get_value(SECTION, server_key(host, port), ""))
	return token if _valid(token) else ""

static func _valid(token: String) -> bool:
	if token.length() != TOKEN_BYTES * 2:
		return false
	for c in token:
		if not c in "0123456789abcdef":
			return false
	return true
