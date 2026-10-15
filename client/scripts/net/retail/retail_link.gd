extends RefCounted
class_name RetailLink

## One connection in the ORIGINAL protocol's framing (round 788): a TCP socket
## driven through a RetailGatewayClient, polled once a frame. poll() returns
## the conversation's events and the link's own -- {"kind": "connected"},
## {"kind": "connect_failed", "why"}, {"kind": "closed", "why"} (the server
## hung up, or the conversation hit an error). RetailLogin holds the gateway's
## and the agent's; once logged in, NetClient holds the agent's
## (NetClient.attach_retail) and the select screen's lobby requests go
## through it.

## OURS: how long a connect may take before it is a failed connect.
const CONNECT_TIMEOUT_MS := 10000
## OURS: what may be held unread (a frame is at most 4 KiB, RetailSecurity).
const MAX_BUFFER := 0x10000
## OURS: connections per link when the session's checksum table cannot be
## built (handshake.md; the server list's ServerStatus does the same).
const MAX_ATTEMPTS := 3

var host := ""
var port := 0
var conv: RetailGatewayClient = null
## Builds a fresh conversation for each connection (a retry starts over).
var _make: Callable
## The keep-alive (READ, CClientProcess::vslot_025 0x4cf990): an empty plain
## 0x2002 when nothing has been sent for KEEP_ALIVE_IDLE_MS, looked at every
## KEEP_ALIVE_CHECK_MS (vslot_002's timeSetEvent period), on the gateway and
## the agent alike, once the server's 0x2001 is in. Off for the transcript
## tests (time would change their bytes).
const KEEP_ALIVE_IDLE_MS := 5000
const KEEP_ALIVE_CHECK_MS := 1666
var keep_alive := true
var _last_check_ms := 0

var _peer: StreamPeerTCP = null
var _resolve_id := -1
var _started_ms := 0
var _connected := false
var _closed := false
var _buf := PackedByteArray()
var _last_send_ms := 0
var _attempts := 0

func _init(p_host: String, p_port: int, make_conv: Callable) -> void:
	host = p_host
	port = p_port
	_make = make_conv

func is_open() -> bool:
	return not _closed and _peer != null

func is_connected_now() -> bool:
	return _connected and not _closed

func start() -> void:
	_attempts += 1
	conv = _make.call()
	_buf = PackedByteArray()
	_connected = false
	_closed = false
	_started_ms = Time.get_ticks_msec()
	_peer = StreamPeerTCP.new()
	if host.is_valid_ip_address():
		_connect_ip(host)
	else:
		_resolve_id = IP.resolve_hostname_queue_item(host)

func _connect_ip(ip: String) -> void:
	if _peer.connect_to_host(ip, port) != OK:
		_peer = null

## Writes bytes the conversation built (nothing when the link is down).
func send(b: PackedByteArray) -> void:
	if b.is_empty() or not is_connected_now():
		return
	_peer.put_data(b)
	_last_send_ms = Time.get_ticks_msec()

func close() -> void:
	_closed = true
	_cancel_resolve()
	if _peer != null:
		_peer.disconnect_from_host()
	_peer = null

func _cancel_resolve() -> void:
	if _resolve_id >= 0:
		IP.erase_resolve_item(_resolve_id)
		_resolve_id = -1

func poll() -> Array:
	var out: Array = []
	if _closed:
		return out
	var now := Time.get_ticks_msec()
	if _resolve_id >= 0:
		match IP.get_resolve_item_status(_resolve_id):
			IP.RESOLVER_STATUS_WAITING:
				return out
			IP.RESOLVER_STATUS_DONE:
				var ip := GatewayQuery.pick_address(IP.get_resolve_item_addresses(_resolve_id))
				_cancel_resolve()
				if ip == "":
					return _fail_connect(out, "%s did not resolve" % host)
				_connect_ip(ip)
			_:
				_cancel_resolve()
				return _fail_connect(out, "%s did not resolve" % host)
	if _peer == null:
		return _fail_connect(out, "the connect to %s:%d could not start" % [host, port])
	_peer.poll()
	var st := _peer.get_status()
	if not _connected:
		if st == StreamPeerTCP.STATUS_CONNECTED:
			_connected = true
			_peer.set_no_delay(true)
			_last_send_ms = now
			out.append({"kind": "connected"})
		elif st == StreamPeerTCP.STATUS_ERROR or st == StreamPeerTCP.STATUS_NONE:
			return _fail_connect(out, "%s:%d refused or unreachable" % [host, port])
		elif now - _started_ms > CONNECT_TIMEOUT_MS:
			return _fail_connect(out, "no connection to %s:%d within %d ms" % [host, port, CONNECT_TIMEOUT_MS])
		else:
			return out
	if st != StreamPeerTCP.STATUS_CONNECTED:
		# StreamPeerTCP reports the hang-up only once nothing is left to
		# read, so the server's last frames were taken on earlier polls.
		close()
		out.append({"kind": "closed", "why": "the server closed the connection"})
		return out
	var n := _peer.get_available_bytes()
	if n > 0:
		var r := _peer.get_partial_data(n)
		if r[0] == OK:
			_buf.append_array(r[1])
	if _buf.size() > MAX_BUFFER:
		close()
		out.append({"kind": "closed", "why": "more than %d bytes unread" % MAX_BUFFER})
		return out
	if not _buf.is_empty():
		var f := conv.feed(_buf)
		_buf = _buf.slice(int(f["consumed"]))
		send(f["send"])
		out.append_array(f["events"])
		if f["error"] != "":
			if f["retry"] and _attempts < MAX_ATTEMPTS:
				print("RETAIL: %s:%d: %s" % [host, port, f["error"]])
				_peer.disconnect_from_host()
				start()
				return out
			close()
			out.append({"kind": "closed", "why": str(f["error"])})
			return out
	if keep_alive and now - _last_check_ms >= KEEP_ALIVE_CHECK_MS:
		_last_check_ms = now
		if now - _last_send_ms >= KEEP_ALIVE_IDLE_MS:
			send(conv.keep_alive())
	return out

func _fail_connect(out: Array, why: String) -> Array:
	close()
	out.append({"kind": "connect_failed", "why": why})
	return out
