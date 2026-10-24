extends RefCounted
class_name GuildOpsNet

## Round 822: the original's guild membership requests and their replies, as
## sro_client.exe sends and reads them (the server's side is
## server/internal/guild/wire.go and session/guildops.go; docs/protocol/
## guild.md "Membership (round 822)"). READ unless a line says otherwise.
##
## Requests:
## - 0x70F0 create (SendGuildManagerMsg_0f0 c:0x81f5a0): u32 NPC, str name.
## - 0x70F1 disband (c:0x81f710), 0x70F2 leave (c:0x81f7d0): u32 NPC.
## - 0x70F3 invite (c:0x81fb70): u32 the selected player's unique id.
## - 0x70F4 expel (c:0x824190): str the member's name.
## - 0x3080 the invitation's answer (box 0x0F, c:0x797d90 case 0x79819c):
##   {1, 1} yes, {2, u16 0x4c16} no.
## Replies: u8 1 on success, else u8 2 + u16 code (s:0x4e7250 always writes
## the 2). B0F0's code 0x4c3c carries a u32 of seconds left (c:0x8852c0).

const OP_CREATE := 0x70F0
const OP_DISBAND := 0x70F1
const OP_LEAVE := 0x70F2
const OP_INVITE := 0x70F3
const OP_EXPEL := 0x70F4
const OP_REQUEST := 0x3080

const OP_CREATE_RESULT := 0xB0F0
const OP_DISBAND_RESULT := 0xB0F1
const OP_LEAVE_RESULT := 0xB0F2
const OP_INVITE_RESULT := 0xB0F3
const OP_EXPEL_RESULT := 0xB0F4
const OP_JOIN_RESULT := 0xB0F8
const OP_UPDATE := 0x38F5
const RESULT_OPCODES := [OP_CREATE_RESULT, OP_DISBAND_RESULT, OP_LEAVE_RESULT,
	OP_INVITE_RESULT, OP_EXPEL_RESULT, OP_JOIN_RESULT]

## 0x3080's kind for a guild invitation (c:0x88aeb7).
const REQUEST_GUILD_INVITE := 5

const CODE_INVITE_TIMEOUT := 0x4c10
const CODE_JOIN_REFUSED := 0x4c16
const CODE_EXPEL_NOT_ALLOWED := 0x4c1f
const CODE_CREATE_PENALTY := 0x4c3c
const CODE_NOT_ALLOWED_NAME := 0x4c19

## 0x38F5's types (NetProcessInInterface::FUN_00887330).
const UPDATE_REFRESH := 0
const UPDATE_DISBANDED := 1
const UPDATE_MEMBER_ADD := 2
const UPDATE_MEMBER_OUT := 3
const UPDATE_GUILD := 5
const UPDATE_MEMBER := 6
## Type 3's reason byte.
const REMOVED_LEFT := 1
const REMOVED_EXPELLED := 2
## Type 5's mask (guildWnd FUN_005b7b80): bits 0x01, 0x20 and 0x80 are not
## read, so they never carry data.
const GUILD_FIELD_NAME := 0x02
const GUILD_FIELD_LEVEL := 0x04
const GUILD_FIELD_GP := 0x08
const GUILD_FIELD_NOTICE := 0x10
const GUILD_FIELD_SOLDIER := 0x40
## Type 6's mask (guildWnd FUN_005bb1b0). 0x20 is the character's name.
const MEMBER_FIELD_LEVEL := 0x01
const MEMBER_FIELD_OFFLINE := 0x02
const MEMBER_FIELD_CLASS := 0x04
const MEMBER_FIELD_GP := 0x08
const MEMBER_FIELD_PERMISSION := 0x10
const MEMBER_FIELD_NAME := 0x20
const MEMBER_FIELD_SIEGE := 0x40

## Category 0x10 of UI_SILKMALL::FUN_007b8b40 (c:0x7ba32b: code - 0x4c06,
## index bytes 0x7bbc80, targets 0x7bbb78; docs/protocol/error_codes.md).
## A code without a row prints nothing (the default exit 0x7b913a).
const UIIT_BY_CODE := {
	0x4c06: "UIIT_MSG_GUILDERR_TARGET_BUSY",
	0x4c07: "UIIT_MSG_GUILDERR_IM_DEAD",
	0x4c0a: "UIIT_MSG_GUILDERR_TOO_LOW_CREATOR_LEVEL",
	0x4c0c: "UIIT_MSG_GUILDERR_NOT_ENOUGH_GOLD",
	0x4c12: "UIIT_MSG_GUILDERR_EXISTING_MEMBER",
	0x4c13: "UIIT_MSG_GUILDERR_MEMBER_FULL",
	0x4c16: "UIIT_MSG_GUILDERR_JOIN_GUILD_REFUSED",
	0x4c17: "UIIT_MSG_GUILDERR_MEMBER_OF_ANOTHER_GUILD",
	0x4c18: "UIIT_MSG_GUILDERR_INVALID_GUILDNAME_LEN",
	0x4c19: "UIIT_MSG_GUILDERR_NOT_ALLOWED_GUILDNAME",
	0x4c1a: "UIIT_MSG_GUILDERR_SAME_GUILDNAME_EXIST",
	0x4c1b: "UIIT_MSG_GUILDERR_CANT_CREATE_GUILD_IN_DB",
	0x4c1c: "UIIT_MSG_GUILDERR_CANT_ADD_MEMBER_IN_DB",
	0x4c1d: "UIIT_MSG_GUILDERR_CANT_FIND_MEMBER",
	0x4c1e: "UIIT_MSG_GUILDERR_PERMISSION_DENIED",
	0x4c1f: "UIIT_MSG_GUILD_EXPULSION_NOTEXP",
	0x4c21: "UIIT_MSG_ERROR_GUILD_LEVEL_UP_FULL",
	0x4c22: "UIIT_MSG_GUILDERR_INVALID_MASTER_COMMENT_TITLE",
	0x4c23: "UIIT_MSG_GUILDERR_INVALID_MASTER_COMMENT",
	0x4c24: "UIIT_MSG_GUILDERR_TARGET_PERMISSION_DENIED",
	0x4c25: "UIIT_MSG_GUILDERR_CANT_FIND_TARGET_GUILD",
	0x4c26: "UIIT_MSG_GUILDERR_CANT_ALLY_TO_OWN_GUILD",
	0x4c27: "UIIT_MSG_GUILDERR_ALREADY_ALLIED",
	0x4c28: "UIIT_MSG_GUILDERR_TARGET_GUILD_HAS_ALLIANCE_ALREADY",
	0x4c29: "UIIT_MSG_GUILDERR_ALLIANCE_FULL",
	0x4c2a: "UIIT_MSG_GUILDERR_TOO_LOW_CREATOR_ALLIANCE",
	0x4c2b: "UIIT_MSG_GUILDERR_TOO_LOW_JOINER_ALLIANCE",
	0x4c31: "UIIT_MSG_ERROR_GUILD_LEVEL_UP_GOLD_DEFICIT",
	0x4c32: "UIIT_MSG_ERROR_GUILD_LEVEL_UP_GP_DEFICIT",
	0x4c36: "UIIT_MSG_GUILD_EXPULSION_NOTEXP",
	0x4c38: "UIIT_MSG_MRELEASEERR_NOTSECEDE",
	0x4c39: "UIIT_MSG_MRELEASEERR_NOTREMOVE",
	0x4c3a: "UIIT_MSG_GUILDWARERR_ENEMYGUILD",
	0x4c3b: "UIIT_MSG_GUILDERR_TARGET_GUILD_MASTER_IS_NOT_IN_GAME",
	0x4c3c: "UIIT_MSG_GUILDWARERR_GUILD_CREATE_PENALTY",
	0x4c3d: "UIIT_MSG_GUILD_PENALTY",
	0x4c3e: "UIIT_MSG_GUILDWARERR_MAX_HOSTILE_GUILD",
	0x4c3f: "UIIT_MSG_GUILDWARERR_TARGET_MAX_HOSTILE_GUILD",
	0x4c41: "UIIT_MSG_GUILDWARERR_ALLYGUILD",
	0x4c42: "UIIT_MSG_QUESTION_GUILD_RESPECT_ALLY_NOTALLY",
	0x4c43: "UIIT_MSG_GUILDWAR_SUGGESTIONS_02",
	0x4c44: "UIIT_MSG_PARTYERR_UNKNOWN_ERROR",
	0x4c46: "UIIT_MSG_GUILD_ERROR_BREAK_WAR",
	0x4c48: "UIIT_MSG_GUILD_WAREHOUSE_INTERRUPT",
	0x4c4a: "UIIT_MSG_GUILD_WAREHOUSE_LIMIT",
	0x4c4b: "UIIT_MSG_GUILD_UNION_CHAT_FULL",
	0x4c4c: "UIIT_MSG_GUILD_WAREHOUSE_USE_ING",
	0x4c4d: "UIIT_MSG_GUILD_ERROR_NAME_GRANT_SPECIAL_LETTER",
	0x4c52: "UIIT_MSG_GUILDERR_PERMISSION_DENIED",
	0x4c53: "UIIT_MSG_GUILD_SOLDIER_ABILITY_OVER",
	0x4c54: "UIIT_MSG_GUILD_SOLDIER_ABILITY_SELECT_ERROR",
	0x4c55: "UIIT_MSG_GUILD_SOLDIER_LEAVE_MASTER_ERROR",
	0x4c56: "UIIT_CTL_GUILD_JOIN_JOB_ERROR",
	0x4c57: "UIIT_CTL_GUILD_CREATE_JOB_ERROR",
	0x4c60: "UIIT_STT_ERR_COMMON_TOO_FAR",
}

static func error_key(code: int) -> String:
	return UIIT_BY_CODE.get(code, "")

static func _str(s: String) -> PackedByteArray:
	var raw := s.to_utf8_buffer()
	var b := PackedByteArray()
	b.resize(2)
	b.encode_u16(0, raw.size())
	b.append_array(raw)
	return b

static func _u32(v: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_u32(0, v)
	return b

static func encode_create(npc_uid: int, guild_name: String) -> PackedByteArray:
	var b := _u32(npc_uid)
	b.append_array(_str(guild_name))
	return b

## Disband and leave carry only the talk's NPC.
static func encode_npc(npc_uid: int) -> PackedByteArray:
	return _u32(npc_uid)

static func encode_invite(target_uid: int) -> PackedByteArray:
	return _u32(target_uid)

static func encode_expel(member_name: String) -> PackedByteArray:
	return _str(member_name)

static func encode_answer(accept: bool) -> PackedByteArray:
	if accept:
		return PackedByteArray([1, 1])
	var b := PackedByteArray([2, 0, 0])
	b.encode_u16(1, CODE_JOIN_REFUSED)
	return b

class Result:
	var ok := false
	var code := 0
	## B0F0's u32 after 0x4c3c: the penalty's seconds left.
	var seconds := 0
	## B0F0's success: the guild block that follows the 1 (FUN_009965e0).
	var block := PackedByteArray()

## Reads a result. Null for an empty one, and for a first byte other than 1
## or 2 (the handlers test == 2 and drop anything else).
static func decode_result(op: int, data: PackedByteArray) -> Result:
	if data.is_empty():
		return null
	var r := Result.new()
	if data[0] == 1:
		r.ok = true
		r.block = data.slice(1)
		return r
	if data[0] != 2 or data.size() < 3:
		return null
	r.code = data.decode_u16(1)
	if op == OP_CREATE_RESULT and r.code == CODE_CREATE_PENALTY and data.size() >= 7:
		r.seconds = data.decode_u32(3)
	return r

## 0x3080 kind 5's inviter, or -1 when the message is not a guild
## invitation (c:0x88aeb7: u8 5, u32 the inviter's unique id, nothing else).
static func invitation_inviter(data: PackedByteArray) -> int:
	if data.size() < 5 or data[0] != REQUEST_GUILD_INVITE:
		return -1
	return data.decode_u32(1)

## UIIT_MSG_GUILD_SECESSION_PENALTY's three numbers (c:0x8852c0: days =
## s / 86400, then the hours and minutes left over).
static func penalty_parts(seconds: int) -> Array:
	return [seconds / 86400, (seconds % 86400) / 3600, (seconds % 3600) / 60]
