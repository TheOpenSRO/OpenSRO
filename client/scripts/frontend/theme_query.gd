extends Node
class_name ThemeQuery

## Asks the configured server for its front-end theme at boot (round 678,
## OURS): one short-lived TCP connection of its own -- not NetClient's, so
## Connect is never held up or confused by it -- sends OpFrontEndThemeRequest
## (0x0005, no payload) and reads one OpFrontEndTheme (0x0006: a uint16 LE
## byte length, then that many bytes of UTF-8 JSON, FrontEndTheme's
## structure), then closes. Gives up after TIMEOUT_MS, and on any error.
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
## One frame's worth (header + the largest payload): the answer is one frame,
## and nothing past it is read (round 678's review).
const MAX_BUFFER := 6 + 0x7FFF

var _peer: StreamPeerTCP = null
var _started_ms := 0
var _sent := false
var _buffer := PackedByteArray()
var _done := false
var host := ""
var port := 0
## What finished() carried, for a caller that connects late.
var result_theme: FrontEndTheme = null
var result_why := ""
## A host name being resolved without blocking (IP.resolve_hostname_queue_item,
## round 678's review: connect_to_host resolves a name synchronously), or -1.
var _resolve_id := -1

## Starts the query, or finishes at once (deferred) when there is nothing to
## ask.
func start(p_host: String, p_port: int) -> void:
	host = p_host
	port = p_port
	_started_ms = Time.get_ticks_msec()
	if host == "" or port <= 0:
		_finish.call_deferred(null, "no server address")
		return
	if host.is_valid_ip_address():
		_connect(host)
	else:
		_resolve_id = IP.resolve_hostname_queue_item(host)
	set_process(true)

func _connect(ip: String) -> void:
	_peer = StreamPeerTCP.new()
	var err := _peer.connect_to_host(ip, port)
	if err != OK:
		_peer = null
		_finish.call_deferred(null, "connect_to_host failed (%d)" % err)

func is_done() -> bool:
	return _done

func _ready() -> void:
	set_process(not _done)

func _process(_delta: float) -> void:
	if _done:
		return
	if Time.get_ticks_msec() - _started_ms > TIMEOUT_MS:
		_finish(null, "no answer within %d ms" % TIMEOUT_MS)
		return
	if _resolve_id >= 0:
		match IP.get_resolve_item_status(_resolve_id):
			IP.RESOLVER_STATUS_WAITING:
				return
			IP.RESOLVER_STATUS_DONE:
				var ip := IP.get_resolve_item_address(_resolve_id)
				IP.erase_resolve_item(_resolve_id)
				_resolve_id = -1
				if ip == "":
					_finish(null, "%s did not resolve" % host)
					return
				_connect(ip)
			_:
				IP.erase_resolve_item(_resolve_id)
				_resolve_id = -1
				_finish(null, "%s did not resolve" % host)
				return
	if _peer == null:
		return
	_peer.poll()
	match _peer.get_status():
		StreamPeerTCP.STATUS_CONNECTING:
			return
		StreamPeerTCP.STATUS_ERROR, StreamPeerTCP.STATUS_NONE:
			_finish(null, "connection failed")
			return
	if not _sent:
		_peer.put_data(Packet.new(OP_REQUEST).encode())
		_sent = true
	var available := mini(_peer.get_available_bytes(), MAX_BUFFER - _buffer.size())
	if available > 0:
		var got := _peer.get_partial_data(available)
		if got[0] == OK:
			_buffer.append_array(got[1])
	var result := parse_frames(_buffer)
	if result.has("theme_json"):
		var warnings := PackedStringArray()
		var theme := FrontEndTheme.from_json(result["theme_json"], warnings)
		for w in warnings:
			print("FrontEnd: server theme: %s" % w)
		_finish(theme, "answered in %d ms" % (Time.get_ticks_msec() - _started_ms) if theme != null else "unreadable answer")
	elif result.has("error"):
		_finish(null, result["error"])
	elif _buffer.size() >= MAX_BUFFER:
		_finish(null, "more than %d bytes without a theme frame" % MAX_BUFFER)

## Reads the FIRST frame that has arrived: {"theme_json": text} when it is a
## complete OpFrontEndTheme, {"error": why} when it is anything else (the
## server answers this request with that frame and nothing before it), or {}
## to keep waiting.
static func parse_frames(buf: PackedByteArray) -> Dictionary:
	if buf.size() < Packet.HEADER_SIZE:
		return {}
	var size := buf.decode_u16(0) & Packet.MAX_PAYLOAD
	var opcode := buf.decode_u16(2)
	if opcode != OP_THEME:
		return {"error": "the first frame is opcode 0x%04x, not a theme" % opcode}
	if buf.size() - Packet.HEADER_SIZE < size:
		return {}
	var payload := buf.slice(Packet.HEADER_SIZE, Packet.HEADER_SIZE + size)
	if payload.size() < 2:
		return {"error": "theme frame too short"}
	var n := payload.decode_u16(0)
	if payload.size() < 2 + n:
		return {"error": "theme frame's text is cut short"}
	return {"theme_json": payload.slice(2, 2 + n).get_string_from_utf8()}

## Stops waiting (the player clicked through): finishes with no answer.
func abandon(why: String) -> void:
	_finish(null, why)

func _finish(theme: FrontEndTheme, why: String) -> void:
	if _done:
		return
	_done = true
	result_theme = theme
	result_why = why
	set_process(false)
	if _resolve_id >= 0:
		IP.erase_resolve_item(_resolve_id)
		_resolve_id = -1
	if _peer != null:
		_peer.disconnect_from_host()
		_peer = null
	finished.emit(theme, why)
