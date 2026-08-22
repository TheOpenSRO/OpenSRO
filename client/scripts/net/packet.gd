extends RefCounted
class_name Packet

## Wire framing for this project's own client<->server protocol. Mirrors
## server/internal/proto's Packet type -- same header shape, but this is OUR
## protocol, not a clone of the original game's wire format. See
## docs/protocol/PROTOCOL_DECISION.md.
##
## **Corrected (2026-08-22)**: server/internal/proto moved from a 5-byte
## Size+Opcode+Flags header to the real confirmed 6-byte
## Size+Opcode+RollingByte+ChecksumByte layout (see PACKET_FORMAT.md), with
## the last two bytes read/written as optional per-session security state --
## nil server-side until a real session handshake populates it via
## gateway.Session.SetSecurity, which nothing calls yet. This client mirrors
## that: it sends zero for both bytes and ignores them on read, matching
## exactly what the server does with a nil roll/sum today. Whoever wires up
## real session security server-side needs to update this client to match
## at the same time, or every connection breaks again the way this one did.

const HEADER_SIZE := 6 # Size(2) + Opcode(2) + RollingByte(1) + ChecksumByte(1)
const MAX_PAYLOAD := 0x7FFF # top bit of Size is a real reserved flag -- see PACKET_FORMAT.md

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
	out[4] = 0 # RollingByte: no session security state on either side yet
	out[5] = 0 # ChecksumByte: ditto
	out.append_array(data)
	return out

## Reading a frame off the wire is stateful (a payload can straddle
## multiple polls) and needs to never block a caller's frame loop -- see
## PacketReader in packet_reader.gd, which replaced an earlier
## Packet.read_from() that blocked with a busy-wait loop while a payload
## was still arriving.
