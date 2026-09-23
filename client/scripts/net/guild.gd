extends RefCounted
class_name GuildNet

## Opcodes and payload encoding for the guild system, mirroring
## server/internal/session (guild.go). All require a prior login. Unlike
## PartyNet, there are no broadcast opcodes: guild membership is persistent
## and the server has no live-online tracking for guilds, so a client
## learns about roster changes from its own join/leave responses.

const OP_CREATE := 0x0090          # client -> server
const OP_CREATE_RESULT := 0x0091   # server -> client
const OP_JOIN := 0x0092            # client -> server
const OP_JOIN_RESULT := 0x0093     # server -> client
const OP_LEAVE := 0x0094           # client -> server
const OP_LEAVE_RESULT := 0x0095    # server -> client
const OP_INFO := 0x0096            # client -> server
const OP_INFO_RESULT := 0x0097     # server -> client
## The guild's points (round 525): GatheredSP and each member's GP_Donation,
## the two totals CGuild::AddPoints (0x5c4110) raises from members' skill
## points. srrevamp placeholder opcodes, mirroring session.OpGuildPoints /
## OpGuildPointsResult.
const OP_POINTS := 0x0098          # client -> server
const OP_POINTS_RESULT := 0x0099   # server -> client
## The guild's level (round 528): a report of the level and the next level's
## cost, or, with the level-up byte set, the master's level-up
## (CGuild::HandleLevelUp, 0x5c63d0). srrevamp placeholder opcodes, mirroring
## session.OpGuildLevel / OpGuildLevelResult.
const OP_LEVEL := 0x009A           # client -> server
const OP_LEVEL_RESULT := 0x009B    # server -> client

const ROLE_MEMBER := 0
const ROLE_LEADER := 1

## One guild member.
class Member:
	var character_id: int
	var member_name: String
	var role: int

## Result of decode_result(): shared by OP_CREATE_RESULT and
## OP_JOIN_RESULT. On failure only error is meaningful.
class Result:
	var error: String
	var guild_id: int
	var guild_name: String
	var leader_id: int
	var members: Array[Member] = []

## One member's share of the guild's points: _GUILDMEMBER.GP_Donation.
class PointsMember:
	var member_name: String
	var gp_donation: int

## Result of decode_points_result(). On failure only error is meaningful;
## gathered_sp is the guild's _GUILD.GatheredSP.
class PointsResult:
	var error: String
	var guild_id: int
	var gathered_sp: int
	var members: Array[PointsMember] = []

## Result of decode_level_result(). On failure (error != "") only error and
## code are meaningful: code is the engine's refusal code for a level-up the
## engine refuses (0x4c07, 0x4c0d, 0x4c1e, 0x4c21, 0x4c31, 0x4c32; ErrorText
## gives most of them the game's own words) and 0 for the server's own
## failures. next_gold / next_gp are what the next level costs, both 0 at
## the top level.
class LevelResult:
	var error: String
	var code: int
	var guild_id: int
	var level: int
	var levelled_up: bool
	var max_members: int
	var next_gold: int
	var next_gp: int

## Result of decode_leave_result().
class LeaveResult:
	var ok: bool
	var reason: String
	var error: String

## Encodes an OpGuildCreate request: a character name and the guild name
## to found.
static func encode_create(character_name: String, guild_name: String) -> PackedByteArray:
	var out := _encode_name(character_name)
	out.append_array(_encode_name(guild_name))
	return out

## Encodes an OpGuildLeave request: just a character name.
static func encode_name_request(character_name: String) -> PackedByteArray:
	return _encode_name(character_name)

## Encodes an OpGuildPoints request: just a character name.
static func encode_points(character_name: String) -> PackedByteArray:
	return _encode_name(character_name)

## Encodes an OpGuildLevel request: a character name, then one byte -- 1 to
## level the guild up, 0 only to report its level.
static func encode_level(character_name: String, level_up: bool) -> PackedByteArray:
	var out := _encode_name(character_name)
	out.append(1 if level_up else 0)
	return out

## Encodes an OpGuildJoin request.
static func encode_join(character_name: String, guild_id: int) -> PackedByteArray:
	var out := _encode_name(character_name)
	var id_buf := PackedByteArray()
	id_buf.resize(8)
	id_buf.encode_s64(0, guild_id)
	out.append_array(id_buf)
	return out

static func _encode_name(name: String) -> PackedByteArray:
	var name_bytes := name.to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, name_bytes.size())
	out.append_array(name_bytes)
	return out

static func _decode_member(data: PackedByteArray, offset: int) -> Array:
	if offset + 8 > data.size():
		return [null, -1]
	var m := Member.new()
	m.character_id = data.decode_s64(offset)
	offset += 8

	if offset + 2 > data.size():
		return [null, -1]
	var name_len := data.decode_u16(offset)
	offset += 2
	if offset + name_len > data.size():
		return [null, -1]
	m.member_name = data.slice(offset, offset + name_len).get_string_from_utf8()
	offset += name_len

	if offset + 4 > data.size():
		return [null, -1]
	m.role = data.decode_u32(offset)
	offset += 4

	return [m, offset]

## Decodes an OpGuildCreateResult/OpGuildJoinResult payload.
static func decode_result(data: PackedByteArray) -> Result:
	var result := Result.new()
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

	if offset + 8 > data.size():
		result.error = "truncated guild id"
		return result
	result.guild_id = data.decode_s64(offset)
	offset += 8

	if offset + 2 > data.size():
		result.error = "truncated guild name length"
		return result
	var name_len := data.decode_u16(offset)
	offset += 2
	if offset + name_len > data.size():
		result.error = "truncated guild name"
		return result
	result.guild_name = data.slice(offset, offset + name_len).get_string_from_utf8()
	offset += name_len

	if offset + 8 > data.size():
		result.error = "truncated leader id"
		return result
	result.leader_id = data.decode_s64(offset)
	offset += 8

	if offset + 2 > data.size():
		result.error = "truncated member count"
		return result
	var count := data.decode_u16(offset)
	offset += 2

	for i in range(count):
		var decoded := _decode_member(data, offset)
		if decoded[0] == null:
			result.error = "truncated member %d" % i
			return result
		result.members.append(decoded[0])
		offset = decoded[1]

	return result

## Decodes an OpGuildLeaveResult payload (same OK/Reason shape as
## Auth.decode_result).
static func decode_leave_result(data: PackedByteArray) -> LeaveResult:
	var result := LeaveResult.new()
	if data.size() < 1:
		result.error = "empty payload"
		return result

	var ok := data[0] != 0
	if data.size() < 3:
		result.error = "truncated reason length prefix"
		return result

	var reason_len := data.decode_u16(1)
	if 3 + reason_len > data.size():
		result.error = "declared reason length %d exceeds remaining bytes" % reason_len
		return result

	result.ok = ok
	result.reason = data.slice(3, 3 + reason_len).get_string_from_utf8()
	return result

## Decodes an OpGuildPointsResult payload: an error string, then (on success)
## the guild id (s64), GatheredSP (s64), a u16 member count and, per member,
## a u16-prefixed UTF-8 name and its GP_Donation (s64).
static func decode_points_result(data: PackedByteArray) -> PointsResult:
	var result := PointsResult.new()
	if data.size() < 2:
		result.error = "truncated"
		return result

	var error_len: int = data.decode_u16(0)
	var offset: int = 2 + error_len
	if offset > data.size():
		result.error = "truncated error field"
		return result
	result.error = data.slice(2, offset).get_string_from_utf8()
	if result.error != "":
		return result

	if offset + 16 > data.size():
		result.error = "truncated guild points"
		return result
	result.guild_id = data.decode_s64(offset)
	offset += 8
	result.gathered_sp = data.decode_s64(offset)
	offset += 8

	if offset + 2 > data.size():
		result.error = "truncated member count"
		return result
	var count: int = data.decode_u16(offset)
	offset += 2

	for i in range(count):
		if offset + 2 > data.size():
			result.error = "truncated member %d" % i
			return result
		var name_len: int = data.decode_u16(offset)
		offset += 2
		if offset + name_len + 8 > data.size():
			result.error = "truncated member %d" % i
			return result
		var m := PointsMember.new()
		m.member_name = data.slice(offset, offset + name_len).get_string_from_utf8()
		offset += name_len
		m.gp_donation = data.decode_s64(offset)
		offset += 8
		result.members.append(m)

	return result

## Decodes an OpGuildLevelResult payload (session.GuildLevelResult): an error
## string and a u16 code, then (on success) the guild id (s64), level (u8),
## whether this reply raised it (u8), the member cap (u16) and the next
## level's gold and guild points (s64 each).
static func decode_level_result(data: PackedByteArray) -> LevelResult:
	var result := LevelResult.new()
	if data.size() < 2:
		result.error = "truncated"
		return result

	var error_len: int = data.decode_u16(0)
	var offset: int = 2 + error_len
	if offset + 2 > data.size():
		result.error = "truncated error field"
		return result
	result.error = data.slice(2, offset).get_string_from_utf8()
	result.code = data.decode_u16(offset)
	offset += 2
	if result.error != "":
		return result

	if offset + 8 + 4 + 16 > data.size():
		result.error = "truncated guild level"
		return result
	result.guild_id = data.decode_s64(offset)
	offset += 8
	result.level = data[offset]
	result.levelled_up = data[offset + 1] != 0
	result.max_members = data.decode_u16(offset + 2)
	offset += 4
	result.next_gold = data.decode_s64(offset)
	offset += 8
	result.next_gp = data.decode_s64(offset)
	return result
