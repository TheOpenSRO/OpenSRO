extends RefCounted
class_name GuildManageNet

## Round 844 (lane G): the guild window's and the guild manager's own
## requests -- the notice, the members' permission bits, the master's
## hand-over, the SP -> GP donation and the level-up -- and their replies, as
## sro_client.exe sends and reads them (the server's side is
## server/internal/session/guildmanage.go; docs/protocol/guild_census.md).
## READ unless a line says otherwise. Strings are OpenSRO's u16 length +
## UTF-8, as every guild message here (GuildOpsNet._str; the original's are
## ANSI bytes).

## 0x70F9 {str title, str body} (SendGuild_HandleNoticeUpdate c:0x824360,
## from the write window's Completed c:0x70b7b0). B0F9 {1}:
## UIIT_MSG_GUILD_COMMON_KNOW_REMIND_UPDATE in the warning banner (c:0x881a70).
const OP_NOTICE := 0x70F9
const OP_NOTICE_RESULT := 0xB0F9
## 0x70FA {u32 NPC} (CIFGuildLevelUp::SendGuild_HandleLevelUpRequest
## c:0x81fdc0). B0FA {1} | {2, code} (Guild_OnLevelUpResult c:0x881bd0).
const OP_LEVEL_UP := 0x70FA
const OP_LEVEL_UP_RESULT := 0xB0FA
## 0x7103 {u32 NPC, u32 the new master's id} (c:0x81fe80, from
## CIFGuildMasterLeave's confirm box). B103 {1}: the talk closes and
## UIIT_STT_EVENTGUIDE / UIIT_MSG_MLEAVE_SUCCESS shows (c:0x889680).
const OP_HAND_OVER := 0x7103
const OP_HAND_OVER_RESULT := 0xB103
## 0x7104 {u8 n, n x {u32 member id, u32 permission}} (SendGuildMsg_104
## c:0x5ace60, the permission pane's Confirm): only the rows that changed.
## B104 {1}: nothing shown (c:0x881cb0).
const OP_PERMISSION := 0x7104
const OP_PERMISSION_RESULT := 0xB104
## 0x7258 {u32 SP} (CIFGuildPointUp c:0x70bcd0: _wtoi of the edit). B258
## {1, u32 SP}: UIIT_MSG_GUILD_GP_SUBSCRIPION_RESULT with it (c:0x88d750).
const OP_DONATE := 0x7258
const OP_DONATE_RESULT := 0xB258

const RESULT_OPCODES := [OP_NOTICE_RESULT, OP_LEVEL_UP_RESULT, OP_HAND_OVER_RESULT, OP_PERMISSION_RESULT, OP_DONATE_RESULT]

## A local "not enough SP" for the donation window (OURS: the original's OK
## sends and the server answers 0x4c32; the window's own
## UIIT_MSG_GUILD_GP_SUBSCRIPION_LIMIT_MAX_SP is shown instead of a send).
const LOCAL_SP_SHORT := -1
const SP_SHORT_KEY := "UIIT_MSG_GUILD_GP_SUBSCRIPION_LIMIT_MAX_SP"

## The level-up window's tables (c:0xdafa44 GP, c:0xdafa58 gold, by the
## current level; READ, the same as guild.md's server tables).
const LEVEL_UP_GP := [5400, 50400, 135000, 378000, 0]
const LEVEL_UP_GOLD := [3000000, 9000000, 15000000, 21000000, 0]

static func encode_notice(title: String, body: String) -> PackedByteArray:
	var b := GuildOpsNet._str(title)
	b.append_array(GuildOpsNet._str(body))
	return b

## changes: [[member id, permission], ...]; at most 255 rows (the count is a
## byte, c:0x5acf6b).
static func encode_permissions(changes: Array) -> PackedByteArray:
	var n := mini(changes.size(), 255)
	var b := PackedByteArray([n])
	for i in n:
		b.append_array(GuildOpsNet._u32(int(changes[i][0])))
		b.append_array(GuildOpsNet._u32(int(changes[i][1])))
	return b

static func encode_hand_over(npc_uid: int, new_master_id: int) -> PackedByteArray:
	var b := GuildOpsNet._u32(npc_uid)
	b.append_array(GuildOpsNet._u32(new_master_id))
	return b

static func encode_donate(sp: int) -> PackedByteArray:
	return GuildOpsNet._u32(sp)

class Result:
	var op := 0
	var ok := false
	var code := 0
	## B258's SP given.
	var amount := 0

## Reads a reply: {1, ...} or {2, u16 code}; null for anything else.
static func decode_result(op: int, data: PackedByteArray) -> Result:
	if data.is_empty():
		return null
	var r := Result.new()
	r.op = op
	if data[0] == 1:
		r.ok = true
		if op == OP_DONATE_RESULT and data.size() >= 5:
			r.amount = data.decode_u32(1)
		return r
	if data[0] != 2 or data.size() < 3:
		return null
	r.code = data.decode_u16(1)
	return r
