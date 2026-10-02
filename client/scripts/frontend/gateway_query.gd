extends Node
class_name GatewayQuery

## One question asked of a server before login, on a short-lived TCP
## connection of its own (OURS; round 678's ThemeQuery, made general in round
## 679 for the server list's status): connect -- a host name resolved without
## blocking (IP.resolve_hostname_queue_item; connect_to_host would resolve it
## synchronously) -- send one request frame, read the FIRST frame back (at
## most one frame's worth of bytes, MAX_BUFFER), close. Gives up after
## timeout_ms and on any error; never touches NetClient, so Connect is never
## held up or confused by it.
##
## A subclass gives the request (_request) and reads the reply (_read); the
## answer or the reason there is none goes to _answered once.
##
## Round 681: a conversation of several steps (the original gateway
## protocol, ServerStatus's legacy type). _request may be empty (nothing is
## sent first); _read may answer {"send": bytes} to write more,
## {"consumed": n} to drop n bytes it has used from the front of the buffer,
## and {"retry": why} to hang up and connect again (up to max_attempts, all
## inside the one timeout_ms). max_frame_buffer bounds what is held unread
## and max_total_bytes what one attempt may read.

## One frame's worth (header + the largest payload): the answer is one frame,
## and nothing past it is read (round 678's review).
const MAX_BUFFER := 6 + 0x7FFF

var host := ""
var port := 0
var timeout_ms := 1500
## Round 681 (OURS): connections per query, and the read limits.
var max_attempts := 1
var max_frame_buffer := MAX_BUFFER
var max_total_bytes := MAX_BUFFER
var attempts := 0
var _ip := ""
var _total := 0

var _peer: StreamPeerTCP = null
var _started_ms := 0
var _sent := false
var _buffer := PackedByteArray()
var _done := false
## A host name being resolved, or -1.
var _resolve_id := -1
## Whether the TCP connection was ever made (an answer that never came from a
## server that accepted the connection is not the same as no server).
var connected := false

## The request frame to send once connected (empty: send nothing first).
func _request() -> PackedByteArray:
	return PackedByteArray()

## Called before each new connection after the first (a retry).
func _on_reconnect() -> void:
	pass

## Reads what has arrived: {"value": answer} when the reply is complete,
## {"error": why} when it is not the reply, {} to keep waiting.
func _read(_buf: PackedByteArray) -> Dictionary:
	return {}

## Called once with the answer (null when none) and why.
func _answered(_value, _why: String) -> void:
	pass

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
	_ip = ip
	attempts += 1
	_sent = false
	_buffer = PackedByteArray()
	_total = 0
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
	if Time.get_ticks_msec() - _started_ms > timeout_ms:
		_finish(null, "no answer within %d ms" % timeout_ms)
		return
	if _resolve_id >= 0:
		match IP.get_resolve_item_status(_resolve_id):
			IP.RESOLVER_STATUS_WAITING:
				return
			IP.RESOLVER_STATUS_DONE:
				var ip := pick_address(IP.get_resolve_item_addresses(_resolve_id))
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
			_finish(null, "connection failed" if not connected else "the connection closed without an answer")
			return
	connected = true
	if not _sent:
		var first := _request()
		if not first.is_empty():
			_peer.put_data(first)
		_sent = true
	var available := mini(_peer.get_available_bytes(), max_frame_buffer - _buffer.size())
	if available > 0:
		var got := _peer.get_partial_data(available)
		if got[0] == OK:
			_buffer.append_array(got[1])
			_total += (got[1] as PackedByteArray).size()
	var result := _read(_buffer)
	if result.has("consumed"):
		_buffer = _buffer.slice(int(result["consumed"]))
	if result.has("send") and not (result["send"] as PackedByteArray).is_empty():
		_peer.put_data(result["send"])
	if result.has("retry"):
		if attempts < max_attempts:
			_peer.disconnect_from_host()
			_peer = null
			_on_reconnect()
			_connect(_ip)
		else:
			_finish(null, "%s (%d attempts)" % [result["retry"], attempts])
		return
	if result.has("value"):
		_finish(result["value"], "answered in %d ms" % (Time.get_ticks_msec() - _started_ms) if result["value"] != null else str(result.get("why", "unreadable answer")))
	elif result.has("error"):
		_finish(null, result["error"])
	elif _buffer.size() >= max_frame_buffer:
		_finish(null, "more than %d bytes without an answer" % max_frame_buffer)
	elif _total > max_total_bytes:
		_finish(null, "more than %d bytes without an answer" % max_total_bytes)

## The address to connect to among a name's: the first IPv4 one, else the
## first. OURS (round 679): "localhost" resolved to ::1 first on the render
## box, where the server listened on 127.0.0.1 only, and the server list
## showed it unreachable (MEASURED); a server that listens on IPv6 alone
## still works through the fallback.
static func pick_address(addresses: Array) -> String:
	for a in addresses:
		if str(a).is_valid_ip_address() and not str(a).contains(":"):
			return str(a)
	for a in addresses:
		if str(a).is_valid_ip_address():
			return str(a)
	return ""

## The first frame in `buf` if it has arrived whole: {"opcode", "payload"};
## {} to keep waiting.
static func first_frame(buf: PackedByteArray) -> Dictionary:
	if buf.size() < Packet.HEADER_SIZE:
		return {}
	var size := buf.decode_u16(0) & Packet.MAX_PAYLOAD
	var opcode := buf.decode_u16(2)
	if buf.size() - Packet.HEADER_SIZE < size:
		return {"opcode": opcode}
	return {"opcode": opcode, "payload": buf.slice(Packet.HEADER_SIZE, Packet.HEADER_SIZE + size)}

## Stops waiting: finishes with no answer.
func abandon(why: String) -> void:
	_finish(null, why)

func _finish(value, why: String) -> void:
	if _done:
		return
	_done = true
	set_process(false)
	if _resolve_id >= 0:
		IP.erase_resolve_item(_resolve_id)
		_resolve_id = -1
	if _peer != null:
		_peer.disconnect_from_host()
		_peer = null
	_answered(value, why)
