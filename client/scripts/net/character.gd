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

## Real, RE-confirmed body/skeleton/armor asset options -- see
## server/internal/character's GenderChinaMan/GenderChinaWoman doc comment
## for why only these two (not a larger invented roster).
const GENDER_CHINA_MAN := "china_man"
const GENDER_CHINA_WOMAN := "china_woman"

## Encodes a CharacterDelete request: just a name.
static func encode_name(name: String) -> PackedByteArray:
	var name_bytes := name.to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, name_bytes.size())
	out.append_array(name_bytes)
	return out

## Encodes a CharacterCreate request: a name plus a real Gender choice (one
## of GENDER_CHINA_MAN/GENDER_CHINA_WOMAN, or "" to take the server's
## default). Mirrors server/internal/session's CharacterCreateRequest.
static func encode_create(name: String, gender: String = "") -> PackedByteArray:
	var out := encode_name(name)
	var gender_bytes := gender.to_utf8_buffer()
	var len_buf := PackedByteArray()
	len_buf.resize(2)
	len_buf.encode_u16(0, gender_bytes.size())
	out.append_array(len_buf)
	out.append_array(gender_bytes)
	return out

## One character as the select screen needs it. Only the fields the server
## actually tracks -- there is no experience/MP/stat-point system yet, so
## those are honestly absent rather than invented (see the server's
## CharacterSummary).
class Summary:
	var char_name: String
	var gender: String
	var level: int
	var hp: int
	var max_hp: int

## Result of decode_list_result(): either an error, or a list of Summary.
class ListResult:
	var error: String
	var characters: Array = [] # of Summary

## Decodes an OpCharacterListResult payload: a length-prefixed Error string,
## a uint16 count, then per character a name and gender (both length-prefixed)
## and three uint16s -- level, hp, max hp.
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
		var name_res := _read_string(data, offset)
		if name_res.is_empty():
			result.error = "malformed response (truncated name)"
			return result
		offset = name_res["offset"]
		var gender_res := _read_string(data, offset)
		if gender_res.is_empty():
			result.error = "malformed response (truncated gender)"
			return result
		offset = gender_res["offset"]
		if offset + 6 > data.size():
			result.error = "malformed response (truncated stats)"
			return result
		var s := Summary.new()
		s.char_name = name_res["value"]
		s.gender = gender_res["value"]
		s.level = data.decode_u16(offset)
		s.hp = data.decode_u16(offset + 2)
		s.max_hp = data.decode_u16(offset + 4)
		offset += 6
		result.characters.append(s)

	return result

## Reads a uint16-length-prefixed string at `offset`. Returns
## {"value": String, "offset": int past it}, or {} if truncated.
static func _read_string(data: PackedByteArray, offset: int) -> Dictionary:
	if offset + 2 > data.size():
		return {}
	var length := data.decode_u16(offset)
	offset += 2
	if offset + length > data.size():
		return {}
	return {"value": data.slice(offset, offset + length).get_string_from_utf8(), "offset": offset + length}
