extends RefCounted
class_name PacketReader

## Incremental, non-blocking frame reader for Packet's wire format. Tracks
## partial state across multiple poll() calls, so a caller in a game loop
## (NetClient._process) never stalls a frame waiting on the network --
## poll() returns null immediately if there isn't a complete frame yet, and
## the caller just tries again next frame. One PacketReader belongs to one
## connection; NetClient creates a fresh one per connect_to_server() call.
##
## Round 663: it reads whatever the peer has into its OWN buffer on every
## poll and cuts frames out of that. Until then it read a frame's payload only
## once get_available_bytes() covered all of it, which wedged for good in two
## ways:
##   - over TCP (MEASURED, round 662 §4): the kernel charges a segment's whole
##     memory until it is read to its end, so a receive buffer full of
##     part-read segments held 31,250 bytes (skmem r137152 of rb138172) while
##     the reader waited for a 32,735-byte list page, the window shut, and
##     neither side moved again;
##   - over TLS (READ, Godot 4.2.2 modules/mbedtls/stream_peer_mbedtls.cpp):
##     StreamPeerTLS.get_available_bytes() is mbedtls_ssl_get_bytes_avail, the
##     bytes left in the current decrypted record -- at most 16,384 -- so a
##     payload larger than one record was never "available" at all.
## Reading into its own buffer, the reader always takes what the kernel (or
## the TLS record) holds, so neither can fill up behind it.
##
## The frames themselves are decoded exactly as before: the Size field's low
## 15 bits, the opcode, and header bytes 4 and 5 (RollingByte/ChecksumByte)
## ignored -- see Packet.encode()'s note -- in arrival order.

## The most one read takes (OURS). The reader reads only while its buffer
## does not yet hold a whole frame, and drops the consumed bytes before each
## read, so its buffer is at most one unfinished frame (under HEADER_SIZE +
## MAX_PAYLOAD = 32,773 bytes) plus one read: under 98,309 bytes (MAX_BUFFER).
const READ_CHUNK := 65536
const MAX_BUFFER := Packet.HEADER_SIZE + Packet.MAX_PAYLOAD + READ_CHUNK

var _buf := PackedByteArray()
## Where the next frame starts in _buf; the bytes before it are consumed.
var _pos := 0
## Round 764 (OURS): when each read's bytes came off the socket. _base is the
## stream offset of _buf[0]; _mark_end[i] is the stream offset just past read
## i and _mark_ms[i] the msec it was made (Time.get_ticks_msec), from
## _mark_at on. A frame's rx_msec is the time of the read that completed it,
## so a frame left in the buffer while NetClient holds its dispatch back (a
## group read a frame's share at a time) still carries when it ARRIVED.
var _base := 0
var _mark_end := PackedInt64Array()
var _mark_ms := PackedInt64Array()
var _mark_at := 0

## Attempts to read one complete frame from peer without blocking. Returns
## the Packet once one is fully buffered, or null if there isn't enough
## data yet (the caller should try again on a later frame) or on a hard
## read error. peer can be a plain StreamPeerTCP or a StreamPeerTLS wrapping
## one -- both implement the same poll/get_available_bytes/get_partial_data
## contract via the shared StreamPeer base.
func poll(peer: StreamPeer) -> Packet:
	peer.poll()
	while _frame_size() < 0:
		if not _read_some(peer):
			return null
	return _take_frame()

## Round 762: reads everything the peer holds onto the buffer without cutting
## a frame: while NetClient holds its dispatch back (a group read a frame's
## share at a time, a frame's dispatch budget spent) the socket is still
## emptied every frame, so the server's writer never blocks on it -- a session
## whose writer blocks long enough is closed (gateway.SendBlockBudget, 10 s a
## minute; MEASURED: the live crowd's arrival closed one before this). The
## buffer then holds what waits to be dispatched, past MAX_BUFFER. Returns the
## reads made.
func drain(peer: StreamPeer) -> int:
	peer.poll()
	var n := 0
	while _read_some(peer):
		n += 1
	return n

## The size of the whole frame at _pos (header + payload), or -1 while the
## buffer does not hold it all yet.
func _frame_size() -> int:
	var have := _buf.size() - _pos
	if have < Packet.HEADER_SIZE:
		return -1
	var size := Packet.HEADER_SIZE + (_buf.decode_u16(_pos) & 0x7FFF)
	return size if have >= size else -1

## Reads what peer has, up to READ_CHUNK, onto the buffer. False when nothing
## came: nothing waiting, the peer closed (a clean end, not reported: NetClient
## sees the status next frame), or a read error, which is reported.
func _read_some(peer: StreamPeer) -> bool:
	if not _is_open(peer):
		return false
	var available := peer.get_available_bytes()
	if available <= 0 and peer is StreamPeerTLS:
		# A TLS peer counts only the current decrypted record (see the top);
		# once that is read, poll() decrypts the next one, if it has come --
		# or finds the peer's close_notify and closes.
		peer.poll()
		if not _is_open(peer):
			return false
		available = peer.get_available_bytes()
	if available <= 0:
		return false
	var result := peer.get_partial_data(mini(available, READ_CHUNK))
	if result[0] == ERR_FILE_EOF:
		return false
	if result[0] != OK:
		push_error("PacketReader: reading: %s" % result[0])
		return false
	var got: PackedByteArray = result[1]
	if got.is_empty():
		return false
	if _pos > 0:
		# Only an unfinished frame is left before a read: dropping what was
		# consumed keeps the buffer within MAX_BUFFER.
		_buf = _buf.slice(_pos)
		_base += _pos
		_pos = 0
	_buf.append_array(got)
	_mark_end.append(_base + _buf.size())
	_mark_ms.append(Time.get_ticks_msec())
	return true

## Whether peer is still connected: a closed TCP or TLS peer reports an
## engine error for every count or read asked of it, so it is not asked.
func _is_open(peer: StreamPeer) -> bool:
	if peer is StreamPeerTLS:
		return (peer as StreamPeerTLS).get_status() == StreamPeerTLS.STATUS_CONNECTED
	if peer is StreamPeerTCP:
		return (peer as StreamPeerTCP).get_status() == StreamPeerTCP.STATUS_CONNECTED
	return true

## Cuts the whole frame at _pos out of the buffer.
func _take_frame() -> Packet:
	var size := _buf.decode_u16(_pos) & 0x7FFF
	var opcode := _buf.decode_u16(_pos + 2)
	# header[4]/[5] (RollingByte/ChecksumByte) intentionally ignored for
	# now -- see Packet.encode()'s note.
	var start := _pos + Packet.HEADER_SIZE
	var payload := PackedByteArray()
	if size > 0:
		payload = _buf.slice(start, start + size)
	_pos = start + size
	var end := _base + _pos
	var rx := 0
	while _mark_at < _mark_end.size():
		if _mark_end[_mark_at] >= end:
			rx = _mark_ms[_mark_at]
			break
		_mark_at += 1
	if _mark_at >= _mark_end.size() or _mark_at > 256:
		# Keep the marks short: those before this frame's end are done with.
		_mark_end = _mark_end.slice(_mark_at)
		_mark_ms = _mark_ms.slice(_mark_at)
		_mark_at = 0
	if _pos >= _buf.size():
		_buf = PackedByteArray()
		_base += _pos
		_pos = 0
	var pk := Packet.new(opcode, payload)
	pk.rx_msec = rx
	return pk
