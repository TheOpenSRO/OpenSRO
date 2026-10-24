extends RefCounted
class_name GuildPlateNet

## Round 814: the guild line over a character and a member's own grant name
## (docs/protocol/guild_plate.md; the server's twin is
## server/internal/session/guildplate.go). Every layout is READ from
## sro_client.exe unless it says otherwise:
## - 0x7256 (client -> server): u32 target character id, the grant name (the
##   game server's GObjPC_HandleGuildMsg_256 0x517b70). OURS: the target is
##   always the sender -- a member names only themselves (the user's
##   request; the original let only the master name others).
## - 0xB256: u8 1, u32 (INFERRED the guild's id), u32 the target, the name
##   (the client's FUN_0088f9e0); a refusal u8 2, u16 code
##   (Msg_SendTwoFieldReply).
## - 0x3256: u32 (INFERRED the guild's id), the member's name, the grant name
##   (FUN_008905d0: the character found by name gets the nickname).
## - 0x30FF: u32 uid, u32 guild id, the guild's name; with a name, the grant
##   name, three u32 and two bytes (FUN_0088a420). An empty name: OURS, the
##   line goes (the original's client changes nothing then; how it drops a
##   line is OPEN).
## Strings are u16 length + bytes, as every name OpenSRO sends.

const OP_GRANT_NAME := 0x7256
const OP_GRANT_NAME_RESULT := 0xB256
const OP_NICKNAME_UPDATE := 0x3256
const OP_ENTITY_GUILD := 0x30FF
## Round 822: 0x3100 {u32 uid} -- that player's guild record dropped (the
## client's FUN_008819b0 -> FUN_009db110, READ): the line goes.
const OP_GUILD_LEFT := 0x3100

## The longest grant name, in bytes (READ: the server's `< 0xd` test in
## FUN_005c7560; the client's input box takes 12 -- FUN_00641f40 case 3,
## FUN_00634f80(0xc)).
const MAX_NICKNAME_BYTES := 12

## The refusals' codes (docs/protocol/error_codes.md).
const ERR_NOT_IN_GUILD := 0x4c0d
const ERR_GUILD_LEVEL := 0x4c51
const ERR_PERMISSION := 0x4c1e
const ERR_NAME := 0x4c4d

## The line's text (READ, c:0x9dea30 event 4, asm 0x9df0b2..0x9df21f, the
## constants "[" 0xe18b24, " * " 0xde3050, "]" 0xe18b28): "[guild * grant]",
## or "[guild]" with no grant name; "" with no guild. The original's
## "(fortress role)" suffix is not drawn: OpenSRO has no fortress roles.
static func plate_text(guild_name: String, nickname: String) -> String:
	if guild_name == "":
		return ""
	if nickname == "":
		return "[" + guild_name + "]"
	return "[" + guild_name + " * " + nickname + "]"

static func encode_grant(target: int, nickname: String) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(4)
	out.encode_u32(0, target & 0xffffffff)
	_put_string(out, nickname)
	return out

## 0x30FF as {uid, guild_id, guild_name, nickname}; {} when malformed.
static func decode_entity(data: PackedByteArray) -> Dictionary:
	if data.size() < 10:
		return {}
	var at := [8]
	var name = _take_string(data, at)
	if name == null:
		return {}
	var nick := ""
	if name != "":
		var n = _take_string(data, at)
		if n == null:
			return {}
		nick = n
	return {"uid": data.decode_u32(0), "guild_id": data.decode_u32(4), "guild_name": name, "nickname": nick}

## 0x3256 as {guild_id, name, nickname}; {} when malformed.
static func decode_nickname(data: PackedByteArray) -> Dictionary:
	if data.size() < 8:
		return {}
	var at := [4]
	var name = _take_string(data, at)
	var nick = _take_string(data, at) if name != null else null
	if nick == null:
		return {}
	return {"guild_id": data.decode_u32(0), "name": name, "nickname": nick}

## 0xB256 as {ok, code, guild_id, target, nickname}; {} when malformed.
static func decode_grant_result(data: PackedByteArray) -> Dictionary:
	if data.size() >= 3 and data[0] == 2:
		return {"ok": false, "code": data.decode_u16(1)}
	if data.size() < 11 or data[0] != 1:
		return {}
	var at := [9]
	var nick = _take_string(data, at)
	if nick == null:
		return {}
	return {"ok": true, "code": 0, "guild_id": data.decode_u32(1), "target": data.decode_u32(5), "nickname": nick}

static func _put_string(out: PackedByteArray, s: String) -> void:
	var b := s.to_utf8_buffer()
	var at := out.size()
	out.resize(at + 2)
	out.encode_u16(at, b.size())
	out.append_array(b)

## The string at at[0] (u16 length + UTF-8 bytes), advancing at[0]; null when
## it runs past the end.
static func _take_string(data: PackedByteArray, at: Array):
	var i: int = at[0]
	if i + 2 > data.size():
		return null
	var n := data.decode_u16(i)
	if i + 2 + n > data.size():
		return null
	at[0] = i + 2 + n
	return data.slice(i + 2, i + 2 + n).get_string_from_utf8()
