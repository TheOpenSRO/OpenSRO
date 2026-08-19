extends RefCounted
class_name QuestNet

## Opcodes and payload encoding for the quest system, mirroring
## server/internal/session (quest.go). All require a prior login.

const OP_LIST := 0x00B0             # client -> server
const OP_LIST_RESULT := 0x00B1      # server -> client
const OP_ACCEPT := 0x00B2           # client -> server
const OP_ACCEPT_RESULT := 0x00B3    # server -> client
const OP_COMPLETED := 0x00B4        # server -> client, direct to the character who just completed one

## One catalog entry, with this character's progress folded in.
class Entry:
	var quest_id: int
	var quest_name: String
	var monster_name: String
	var target_kills: int
	var gold_reward: int
	var kills: int
	var accepted: bool
	var completed: bool

## Result of decode_list_result().
class ListResult:
	var error: String
	var entries: Array[Entry] = []

## Result of decode_completed().
class Completed:
	var quest_id: int
	var gold_reward: int

## Encodes an OpQuestList request: just a character name.
static func encode_list_request(character_name: String) -> PackedByteArray:
	return _encode_string(character_name)

## Encodes an OpQuestAccept request.
static func encode_accept(character_name: String, quest_id: int) -> PackedByteArray:
	var out := _encode_string(character_name)
	var id_buf := PackedByteArray()
	id_buf.resize(8)
	id_buf.encode_s64(0, quest_id)
	out.append_array(id_buf)
	return out

static func _encode_string(s: String) -> PackedByteArray:
	var bytes := s.to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, bytes.size())
	out.append_array(bytes)
	return out

static func _decode_entry(data: PackedByteArray, offset: int) -> Array:
	if offset + 8 > data.size():
		return [null, -1]
	var e := Entry.new()
	e.quest_id = data.decode_s64(offset)
	offset += 8

	if offset + 2 > data.size():
		return [null, -1]
	var name_len := data.decode_u16(offset)
	offset += 2
	if offset + name_len > data.size():
		return [null, -1]
	e.quest_name = data.slice(offset, offset + name_len).get_string_from_utf8()
	offset += name_len

	if offset + 2 > data.size():
		return [null, -1]
	var monster_len := data.decode_u16(offset)
	offset += 2
	if offset + monster_len > data.size():
		return [null, -1]
	e.monster_name = data.slice(offset, offset + monster_len).get_string_from_utf8()
	offset += monster_len

	if offset + 4 > data.size():
		return [null, -1]
	e.target_kills = data.decode_u32(offset)
	offset += 4

	if offset + 8 > data.size():
		return [null, -1]
	e.gold_reward = data.decode_s64(offset)
	offset += 8

	if offset + 4 > data.size():
		return [null, -1]
	e.kills = data.decode_u32(offset)
	offset += 4

	if offset + 1 > data.size():
		return [null, -1]
	var flags := data[offset]
	e.accepted = (flags & 1) != 0
	e.completed = (flags & 2) != 0
	offset += 1

	return [e, offset]

## Decodes an OpQuestListResult payload.
static func decode_list_result(data: PackedByteArray) -> ListResult:
	var result := ListResult.new()
	if data.size() < 2:
		result.error = "truncated"
		return result

	var error_len := data.decode_u16(0)
	var offset := 2 + error_len
	if offset > data.size():
		result.error = "truncated error field"
		return result
	result.error = data.slice(2, offset).get_string_from_utf8()
	if result.error != "":
		return result

	if offset + 2 > data.size():
		result.error = "truncated entry count"
		return result
	var count := data.decode_u16(offset)
	offset += 2

	for i in range(count):
		var decoded := _decode_entry(data, offset)
		if decoded[0] == null:
			result.error = "truncated entry %d" % i
			return result
		result.entries.append(decoded[0])
		offset = decoded[1]

	return result

## Decodes an OpQuestCompleted payload.
static func decode_completed(data: PackedByteArray) -> Completed:
	if data.size() < 16:
		return null
	var c := Completed.new()
	c.quest_id = data.decode_s64(0)
	c.gold_reward = data.decode_s64(8)
	return c
