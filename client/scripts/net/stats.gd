extends RefCounted
class_name StatsNet

## Opcodes and payload encoding for a character's own stats, mirroring
## server/internal/session (stats.go). Requires a prior login.
##
## Only what the server really computes is here. The character panel
## (`resinfo\ifplayerinfo.txt`) also has rows for strength, intelligence,
## magical attack and defence, balance, hit rate, parry and three job
## grades; nothing on this server produces any of them, so they are not on
## the wire and the panel leaves them as the layout drew them rather than
## filling them with numbers that would look live.

const OP_STATS := 0x00EE        # client -> server
const OP_STATS_RESULT := 0x00EF # server -> client

class Stats:
	var error: String
	var gold: int
	var hp: int
	var max_hp: int
	## The equipped weapon's maximum physical attack, or the unarmed value.
	var phys_attack: int
	## Summed physical defence across the worn armour.
	var phys_defense: int

## Encodes an OpCharacterStats request: one length-prefixed name, and
## nothing after it.
static func encode_request(character_name: String) -> PackedByteArray:
	var name_bytes := character_name.to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, name_bytes.size())
	out.append_array(name_bytes)
	return out

static func decode_result(data: PackedByteArray) -> Stats:
	var stats := Stats.new()
	if data.size() < 2:
		stats.error = "truncated"
		return stats
	var error_len := data.decode_u16(0)
	var offset := 2 + error_len
	if offset > data.size():
		stats.error = "truncated error field"
		return stats
	stats.error = data.slice(2, offset).get_string_from_utf8()
	if offset + 24 > data.size():
		if stats.error == "":
			stats.error = "truncated stats"
		return stats
	stats.gold = data.decode_s64(offset)
	stats.hp = data.decode_s32(offset + 8)
	stats.max_hp = data.decode_s32(offset + 12)
	stats.phys_attack = data.decode_s32(offset + 16)
	stats.phys_defense = data.decode_s32(offset + 20)
	return stats
