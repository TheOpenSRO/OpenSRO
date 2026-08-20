extends RefCounted
class_name PacketReader

## Incremental, non-blocking frame reader for Packet's wire format. Tracks
## partial state (have we buffered a header yet? how much payload are we
## still waiting on?) across multiple poll() calls, so a caller in a game
## loop (NetClient._process) never stalls a frame waiting on the network --
## poll() returns null immediately if there isn't a complete frame yet, and
## the caller just tries again next frame. One PacketReader belongs to one
## connection; NetClient creates a fresh one per connect_to_server() call.

var _have_header := false
var _pending_opcode := 0
var _pending_size := 0

## Attempts to read one complete frame from peer without blocking. Returns
## the Packet once one is fully buffered, or null if there isn't enough
## data yet (the caller should try again on a later frame) or on a hard
## read error. peer can be a plain StreamPeerTCP or a StreamPeerTLS wrapping
## one -- both implement the same get_available_bytes/get_data/poll
## contract via the shared StreamPeer base.
func poll(peer: StreamPeer) -> Packet:
	peer.poll()

	if not _have_header:
		if peer.get_available_bytes() < Packet.HEADER_SIZE:
			return null
		var header_result := peer.get_data(Packet.HEADER_SIZE)
		if header_result[0] != OK:
			push_error("PacketReader: reading header: %s" % header_result[0])
			return null
		var header: PackedByteArray = header_result[1]
		_pending_size = header.decode_u16(0)
		_pending_opcode = header.decode_u16(2)
		# header[4] (flags) intentionally ignored for now -- see
		# Packet.encode()'s note.
		_have_header = true

	if peer.get_available_bytes() < _pending_size:
		return null

	var payload := PackedByteArray()
	if _pending_size > 0:
		var payload_result := peer.get_data(_pending_size)
		if payload_result[0] != OK:
			push_error("PacketReader: reading %d-byte payload for opcode 0x%04x: %s" % [_pending_size, _pending_opcode, payload_result[0]])
			# Reset so a subsequent call doesn't keep retrying a read that
			# already failed against a (likely dead) connection.
			_have_header = false
			return null
		payload = payload_result[1]

	var p := Packet.new(_pending_opcode, payload)
	_have_header = false
	return p
