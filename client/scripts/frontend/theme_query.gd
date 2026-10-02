extends GatewayQuery
class_name ThemeQuery

## Asks the configured server for its front-end theme at boot (round 678,
## OURS): one short-lived TCP connection of its own (GatewayQuery) -- not
## NetClient's, so Connect is never held up or confused by it -- sends
## OpFrontEndThemeRequest (0x0005, no payload) and reads one OpFrontEndTheme
## (0x0006: a uint16 LE byte length, then that many bytes of UTF-8 JSON,
## FrontEndTheme's structure), then closes. Gives up after TIMEOUT_MS, and on
## any error.
##
## Why a query of its own: retail picks its intro from option.txt before any
## connection (READ, CGame at 0x8475d3), and this client connects only when
## Connect is pressed, so no reply it already gets comes in time. The server
## answers the request without a login (server/internal/session
## frontendtheme.go).

signal finished(theme: FrontEndTheme, why: String)

const OP_REQUEST := 0x0005
const OP_THEME := 0x0006
## OURS: long enough for a LAN or a nearby server, short enough that a dead
## address does not hold the title up noticeably (the title waits for this
## at most once per launch; the last answer is cached for the next).
const TIMEOUT_MS := 1500

## What finished() carried, for a caller that connects late.
var result_theme: FrontEndTheme = null
var result_why := ""

func _init() -> void:
	timeout_ms = TIMEOUT_MS

func _request() -> PackedByteArray:
	return Packet.new(OP_REQUEST).encode()

func _read(buf: PackedByteArray) -> Dictionary:
	var result := parse_frames(buf)
	if result.has("theme_json"):
		var warnings := PackedStringArray()
		var theme := FrontEndTheme.from_json(result["theme_json"], warnings)
		for w in warnings:
			print("FrontEnd: server theme: %s" % w)
		return {"value": theme, "why": "unreadable answer"}
	return result

## Reads the FIRST frame that has arrived: {"theme_json": text} when it is a
## complete OpFrontEndTheme, {"error": why} when it is anything else (the
## server answers this request with that frame and nothing before it), or {}
## to keep waiting.
static func parse_frames(buf: PackedByteArray) -> Dictionary:
	var frame := first_frame(buf)
	if frame.is_empty():
		return {}
	if int(frame["opcode"]) != OP_THEME:
		return {"error": "the first frame is opcode 0x%04x, not a theme" % int(frame["opcode"])}
	if not frame.has("payload"):
		return {}
	var payload: PackedByteArray = frame["payload"]
	if payload.size() < 2:
		return {"error": "theme frame too short"}
	var n := payload.decode_u16(0)
	if payload.size() < 2 + n:
		return {"error": "theme frame's text is cut short"}
	return {"theme_json": payload.slice(2, 2 + n).get_string_from_utf8()}

func _answered(value, why: String) -> void:
	result_theme = value as FrontEndTheme
	result_why = why
	finished.emit(result_theme, why)
