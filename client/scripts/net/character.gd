extends RefCounted
class_name CharacterNet

## Opcodes and payload encoding for character list/create/delete, mirroring
## server/internal/session (character.go). All require a prior successful
## OpLogin on the same connection.

const OP_LIST := 0x0010            # client -> server
const OP_LIST_RESULT := 0x0011     # server -> client
const OP_CREATE := 0x0012          # client -> server
const OP_CREATE_RESULT := 0x0013   # server -> client
const OP_DELETE := 0x0014          # client -> server
const OP_DELETE_RESULT := 0x0015   # server -> client

## Encodes a CharacterCreate/CharacterDelete request: just a name.
static func encode_name(name: String) -> PackedByteArray:
	var name_bytes := name.to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, name_bytes.size())
	out.append_array(name_bytes)
	return out

## Result of decode_list_result(): either an error, or a list of names.
class ListResult:
	var error: String
	var names: Array[String] = []

## Decodes an OpCharacterListResult payload: a length-prefixed Error string,
## then a uint16 name count, then that many length-prefixed names.
static func decode_list_result(data: PackedByteArray) -> ListResult:
	var result := ListResult.new()
	if data.size() < 2:
		result.error = "malformed response (truncated)"
		return result

	var error_len := data.decode_u16(0)
	var offset := 2 + error_len
	if offset + 2 > data.size():
		result.error = "malformed response (truncated error field)"
		return result
	result.error = data.slice(2, offset).get_string_from_utf8()

	var count := data.decode_u16(offset)
	offset += 2
	for i in range(count):
		if offset + 2 > data.size():
			result.error = "malformed response (truncated name count)"
			return result
		var name_len := data.decode_u16(offset)
		offset += 2
		if offset + name_len > data.size():
			result.error = "malformed response (truncated name)"
			return result
		result.names.append(data.slice(offset, offset + name_len).get_string_from_utf8())
		offset += name_len

	return result
