class_name RewardNoticeNet
extends RefCounted

## Round 716: two of the original's reward messages, both READ in the client
## and the GameServer (docs/protocol/party_protocol.md "Rewards").
##
##   0x3056  the EXP/skill-EXP gain (c:Client_ApplyExpAndLevelUp 0x8a97c0;
##           GS GObjPC_GainExpAndLevel 0x4e5250): u32 source object id, u64 EXP
##           (signed: a death's loss is negative), u64 skill EXP, u8 flags,
##           then a u32 when flags & 0x0f == 1 and two u32s when
##           flags & 0xf0 == 0x10 (training-camp states), then a u16 -- the
##           unspent stat points -- only when the gain raised the level.
##   0x304E  the character-info update (c:0x8a70d0; GS FUN_004e3fb0). Only
##           kind 1 is read here: u8 1, u64 the new gold total, u8 show.

const OP_EXP_GAIN := 0x3056
const OP_CHAR_INFO := 0x304E
const CHAR_INFO_GOLD := 1

class ExpGain:
	var source: int = 0
	var exp: int = 0
	var skill_exp: int = 0
	var flags: int = 0
	var level_up: bool = false
	var stat_points: int = 0

## Reads a 0x3056. The client decides whether the stat-point u16 follows by
## running the level arithmetic on its own EXP (0x8a9930..0x8a9960); this
## reader takes it from the bytes left (OURS, equal for every well-formed
## message). Null when the message is short.
static func decode_exp_gain(data: PackedByteArray) -> ExpGain:
	if data.size() < 21:
		return null
	var g := ExpGain.new()
	g.source = data.decode_u32(0)
	g.exp = data.decode_s64(4)
	g.skill_exp = data.decode_s64(12)
	g.flags = data.decode_u8(20)
	var off := 21
	if (g.flags & 0x0f) == 1:
		off += 4
	if (g.flags & 0xf0) == 0x10:
		off += 8
	if data.size() >= off + 2:
		g.level_up = true
		g.stat_points = data.decode_u16(off)
	return g

static func encode_exp_gain(g: ExpGain) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(21)
	out.encode_u32(0, g.source)
	out.encode_s64(4, g.exp)
	out.encode_s64(12, g.skill_exp)
	out.encode_u8(20, g.flags)
	if g.level_up:
		out.resize(23)
		out.encode_u16(21, g.stat_points)
	return out

## Reads 0x304E kind 1 as [total, show]; an empty array for any other kind
## (those are not read by this client yet) or a short message.
static func decode_gold(data: PackedByteArray) -> Array:
	if data.size() < 10 or data.decode_u8(0) != CHAR_INFO_GOLD:
		return []
	return [data.decode_s64(1), data.decode_u8(9) != 0]

## The system lines Client_ApplyExpAndLevelUp writes, all type 1 (GAIN):
## UIIT_MSG_STATE_GAIN_EXP when the EXP is above 0 (0x8a9a45..0x8a9a76),
## UIIT_MSG_STATE_LOSE_EXP with the loss when it is below (0x8a9b76..
## 0x8a9baa), and UIIT_MSG_STATE_GET_SKILL_EXP when the skill EXP is above 0
## (0x8a9cd1..0x8a9cfa). An empty template falls back to the archive's English.
static func exp_lines(g: ExpGain, gain_t: String, lose_t: String, skill_t: String) -> PackedStringArray:
	var out := PackedStringArray()
	if g == null:
		return out
	if g.exp > 0:
		out.append(_fill(gain_t if gain_t != "" else "[%I64d]Experience Points gained.", ["%I64d", "%lld", "%d"], str(g.exp)))
	elif g.exp < 0:
		out.append(_fill(lose_t if lose_t != "" else "[%I64d]Experience Points lost.", ["%I64d", "%lld", "%d"], str(-g.exp)))
	if g.skill_exp > 0:
		out.append(_fill(skill_t if skill_t != "" else "[%u]skill experience point gained.", ["%u", "%d"], str(g.skill_exp)))
	return out

## The gold line c:0x8a70d0 writes for a shown kind 1: UIIT_MSG_STATE_GAIN_GOLD
## with the rise over the client's own total, clamped to 0x7fffffff, and only
## when the total rose. Empty otherwise.
static func gold_line(old_total: int, new_total: int, show: bool, template: String) -> String:
	if not show or new_total <= old_total:
		return ""
	var rise := mini(new_total - old_total, 0x7fffffff)
	return _fill(template if template != "" else "[%d]gold gained.", ["%d"], str(rise))

## The 0x3068 line (c:0x873990): for the player's own JID, the type-1
## UIIT_MSG_STATE_GET_ITEM_EXPENDABLE "item [%s %d pieces]gained."; for
## another member, the type-4 UIIT_MSG_PARTYGET_ITEM_EXPENDABLE "Item [%s %d
## pieces]is distributed to [%s]." with (item, count, member), or for gold
## UIIT_MSG_PARTYGET_GOLD "[%d]gold is distributed to [%s]." Returns
## [text, type]. The GameServer sends 0x3068 to every member except the
## recipient and never for gold (round 712), so the first and last branches
## are read but not reached with this server.
static func item_notice_line(is_self: bool, is_gold: bool, item_name: String, amount: int,
		member_name: String, self_t: String, party_item_t: String, party_gold_t: String) -> Array:
	if is_gold:
		var t := party_gold_t if party_gold_t != "" else "[%d]gold is distributed to [%s]."
		return [_fill(_fill(t, ["%d"], str(amount)), ["%s"], member_name), 4]
	if is_self:
		var t := self_t if self_t != "" else "item [%s %d pieces]gained."
		return [_fill(_fill(t, ["%s"], item_name), ["%d"], str(amount)), 1]
	var t := party_item_t if party_item_t != "" else "Item [%s %d pieces]is distributed to [%s]."
	return [_fill(_fill(_fill(t, ["%s"], item_name), ["%d"], str(amount)), ["%s"], member_name), 4]

## Replaces the first of `specs` the template carries, once.
static func _fill(template: String, specs: Array, value: String) -> String:
	for spec in specs:
		var at := template.find(String(spec))
		if at >= 0:
			return template.substr(0, at) + value + template.substr(at + String(spec).length())
	return template
