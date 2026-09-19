extends RefCounted
class_name GmNet

## Opcodes and payload encoding for the GM console, mirroring
## server/internal/session/gm.go. ONE additive op pair: the client sends a
## command line, the server answers with a text reply plus the little
## structure a reply needs. This is srrevamp's own tooling, not an
## original-client feature.

const OP_COMMAND := 0x00F1        # client -> server
const OP_COMMAND_RESULT := 0x00F2 # server -> client

## Refresh bits in Result.refresh (gm.go's gmRefresh*).
const REFRESH_STATS := 1 << 0
const REFRESH_MONSTERS := 1 << 1
const REFRESH_INVENTORY := 1 << 2
const REFRESH_EQUIPMENT := 1 << 3

## The server's reply, decoded.
class Result:
	var is_gm: bool = false
	var refused: bool = false
	var text: String = ""
	var has_pos: bool = false
	var zone: String = ""        # a zone to change to first; "" for none
	var x: float = 0.0
	var z: float = 0.0
	var new_level: int = 0       # 0 = no level-up
	var stat_points: int = 0
	var refresh: int = 0

## Encodes an OpGMCommand: the character name, the command line exactly as
## typed, and the monster the client currently has selected (0 if none).
## Two length-prefixed strings then a signed 64-bit id -- the layout
## DecodeGMCommandRequest reads.
static func encode_command(character_name: String, line: String, selected_monster: int) -> PackedByteArray:
	var out := _encode_string(character_name)
	out.append_array(_encode_string(line))
	var tail := PackedByteArray()
	tail.resize(8)
	tail.encode_s64(0, selected_monster)
	out.append_array(tail)
	return out

## Decodes an OpGMCommandResult payload (gm.go's GMCommandResult.Encode):
## two flag bytes, the text, a position flag + two float32, the zone string,
## two int32 (level, stat points) and the refresh byte. Returns null on a
## truncated payload rather than a half-filled result.
static func decode_result(data: PackedByteArray) -> Result:
	var r := Result.new()
	if data.size() < 2:
		return null
	r.is_gm = data.decode_u8(0) != 0
	r.refused = data.decode_u8(1) != 0
	var offset := 2

	var text_res := _decode_string(data, offset)
	if text_res[1] < 0:
		return null
	r.text = text_res[0]
	offset = text_res[1]

	if offset + 1 > data.size():
		return null
	r.has_pos = data.decode_u8(offset) != 0
	offset += 1

	if offset + 8 > data.size():
		return null
	r.x = data.decode_float(offset)
	r.z = data.decode_float(offset + 4)
	offset += 8

	var zone_res := _decode_string(data, offset)
	if zone_res[1] < 0:
		return null
	r.zone = zone_res[0]
	offset = zone_res[1]

	if offset + 9 > data.size():
		return null
	r.new_level = data.decode_s32(offset)
	r.stat_points = data.decode_s32(offset + 4)
	r.refresh = data.decode_u8(offset + 8)
	return r

## A length-prefixed UTF-8 string: u16 length then the bytes.
static func _encode_string(s: String) -> PackedByteArray:
	var bytes := s.to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, bytes.size())
	out.append_array(bytes)
	return out

## Reads one length-prefixed string at offset, returning [text, next_offset]
## (next_offset -1 on truncation).
static func _decode_string(data: PackedByteArray, offset: int) -> Array:
	if offset + 2 > data.size():
		return ["", -1]
	var n := data.decode_u16(offset)
	offset += 2
	if offset + n > data.size():
		return ["", -1]
	var text := data.slice(offset, offset + n).get_string_from_utf8()
	return [text, offset + n]
