extends RefCounted
class_name Packet

## Wire framing for this project's own client<->server protocol. Mirrors
## server/internal/proto's Packet type — same header shape (size, opcode,
## one reserved/flags byte), but this is OUR protocol, not a clone of the
## original game's wire format. See docs/protocol/PROTOCOL_DECISION.md.

const HEADER_SIZE := 5 # Size(2) + Opcode(2) + Flags(1)
const MAX_PAYLOAD := 0xFFFF

var opcode: int
var data: PackedByteArray

func _init(p_opcode: int = 0, p_data: PackedByteArray = PackedByteArray()) -> void:
	opcode = p_opcode
	data = p_data

## Encodes this packet as wire bytes (header + payload).
func encode() -> PackedByteArray:
	assert(data.size() <= MAX_PAYLOAD, "Packet payload too large for a single frame")
	var out := PackedByteArray()
	out.resize(HEADER_SIZE)
	out.encode_u16(0, data.size())
	out.encode_u16(2, opcode)
	out[4] = 0 # flags: reserved for future use, unlike the original protocol's
	           # encrypted/trailer/massive bits — see PROTOCOL_DECISION.md
	out.append_array(data)
	return out

## Reads exactly one frame's worth of header fields from a connected
## StreamPeerTCP. Returns null if the connection doesn't have a full header
## available yet (caller should retry once more data has arrived) or on a
## hard read error.
static func read_from(peer: StreamPeerTCP) -> Packet:
	peer.poll()
	if peer.get_available_bytes() < HEADER_SIZE:
		return null

	var header_result := peer.get_data(HEADER_SIZE)
	if header_result[0] != OK:
		push_error("Packet: reading header: %s" % header_result[0])
		return null
	var header: PackedByteArray = header_result[1]

	var size := header.decode_u16(0)
	var opcode := header.decode_u16(2)
	# header[4] (flags) intentionally ignored for now -- see encode()'s note.

	# Wait for the full payload to be buffered before consuming it, so a
	# short read doesn't desync framing for the next packet.
	while peer.get_available_bytes() < size:
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			push_error("Packet: connection closed while waiting for %d-byte payload" % size)
			return null
		OS.delay_msec(1)

	var payload := PackedByteArray()
	if size > 0:
		var payload_result := peer.get_data(size)
		if payload_result[0] != OK:
			push_error("Packet: reading %d-byte payload for opcode 0x%04x: %s" % [size, opcode, payload_result[0]])
			return null
		payload = payload_result[1]

	return Packet.new(opcode, payload)
