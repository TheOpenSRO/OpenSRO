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

## Reading a frame off the wire is stateful (a payload can straddle
## multiple polls) and needs to never block a caller's frame loop -- see
## PacketReader in packet_reader.gd, which replaced an earlier
## Packet.read_from() that blocked with a busy-wait loop while a payload
## was still arriving.
