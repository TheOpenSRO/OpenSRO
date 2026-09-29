extends RefCounted
class_name StatsNet

## Opcodes and payload encoding for a character's own stats, mirroring
## server/internal/session (stats.go). Requires a prior login.
##
## Only what the server really computes is here. The character pane
## (`resinfo\ifplayerinfo_trijob2.txt`, the layout CIFPlayerInfo loads, in
## the main popup) shows the rows the server can state -- level,
## exp and exp-to-next, Str/Int and the unspent stat points, HP/MP, both
## attack ranges, both defence sums, and the balance percentages the client
## computes from Str/Int and the level (round 629) -- and leaves the rest as
## the layout drew them: hit rate and parry (engine params the server does not carry
## per instance and the engine never reads), the job grades and honour (no
## such systems here). See HudPanels._apply_stats for the row-by-row reasons.

const OP_STATS := 0x00EE        # client -> server
const OP_STATS_RESULT := 0x00EF # server -> client
## Spend unspent stat points on Strength / Intellect; the server answers
## with an OP_STATS_RESULT carrying the new numbers.
const OP_SPEND_STAT := 0x00F0   # client -> server

class Stats:
	var error: String
	var gold: int
	var hp: int
	var max_hp: int
	## The equipped weapon's maximum physical attack, or the unarmed value.
	var phys_attack: int
	## Summed physical defence across the worn armour.
	var phys_defense: int
	## Level and experience progress at that level; exp_to_next is 0 when no
	## level curve is loaded. skill_points is the unspent SP.
	var level: int = 1
	var exp: int = 0
	var exp_to_next: int = 0
	var skill_points: int = 0
	## Mana. max_mp is the game's own base curve (100 * 1.02^(level-1),
	## recovered from the server binary); mp equals it until something
	## spends mana. 0 from a server too old to send the pair.
	var mp: int = 0
	var max_mp: int = 0
	## The character rows (third appended tail; 0 from a server too old to
	## send them): the stored Str/Int and the unspent stat-point pool, the
	## bottom of the physical range (phys_attack is its top), the magical
	## range, and the magical defence sum.
	var str: int = 0
	var intel: int = 0
	var stat_points: int = 0
	var phys_attack_min: int = 0
	var mag_attack_min: int = 0
	var mag_attack_max: int = 0
	var mag_defense: int = 0
	## True when the server sent the character rows at all.
	var has_character_rows: bool = false
	## The berserk orbs held, _CHAR.RemainHwanCount (0..5) -- the fourth tail
	## (round 629), so the player block's orbs are right from the moment the
	## world loads rather than from the first blow. has_hwan_count is false
	## from a server too old to send it.
	var hwan_count: int = 0
	var has_hwan_count: bool = false

	## The EXP gauge fill, 0..100, or 0 when exp-to-next is unknown.
	func exp_percent() -> float:
		return (float(exp) / float(exp_to_next)) * 100.0 if exp_to_next > 0 else 0.0

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
	# The level/exp/SP tail is appended; an older 24-byte result omits it.
	if offset + 48 <= data.size():
		stats.level = data.decode_s32(offset + 24)
		stats.exp = data.decode_s64(offset + 28)
		stats.exp_to_next = data.decode_s64(offset + 36)
		stats.skill_points = data.decode_s32(offset + 44)
	# The mana pair is appended in turn; a 48-byte result omits it.
	if offset + 56 <= data.size():
		stats.mp = data.decode_s32(offset + 48)
		stats.max_mp = data.decode_s32(offset + 52)
	# The character rows are the third tail; a 56-byte result omits them.
	if offset + 84 <= data.size():
		stats.str = data.decode_s32(offset + 56)
		stats.intel = data.decode_s32(offset + 60)
		stats.stat_points = data.decode_s32(offset + 64)
		stats.phys_attack_min = data.decode_s32(offset + 68)
		stats.mag_attack_min = data.decode_s32(offset + 72)
		stats.mag_attack_max = data.decode_s32(offset + 76)
		stats.mag_defense = data.decode_s32(offset + 80)
		stats.has_character_rows = true
	# The orb count is the fourth tail; an 84-byte result omits it.
	if offset + 88 <= data.size():
		stats.hwan_count = data.decode_s32(offset + 84)
		stats.has_hwan_count = true
	return stats

## Encodes an OpSpendStatPoints request: the name, then how many points go
## to Strength and how many to Intellect (one byte each).
static func encode_spend_request(character_name: String, str_points: int, int_points: int) -> PackedByteArray:
	var out := encode_request(character_name)
	out.append(clampi(str_points, 0, 255))
	out.append(clampi(int_points, 0, 255))
	return out
