extends RefCounted
class_name JobNet

## Round 799: the job guild's messages -- join, leave, the alias, the weekly
## rankings and reward, the previous job's information -- and the job exp
## notice, as sro_client.exe writes and reads them (docs/protocol/jobs.md,
## "The job guild"; the server's twin is server/internal/jobs/wire.go). Every
## reply opens with u8 1 (ok) or u8 2 then a u16 code. A string is a u16
## length and its bytes.

const OP_JOIN := 0x70E1
const OP_JOIN_RESULT := 0xB0E1
const OP_WITHDRAW := 0x70E2
const OP_WITHDRAW_RESULT := 0xB0E2
const OP_ALIAS := 0x70E3
const OP_ALIAS_RESULT := 0xB0E3
const OP_RANKING := 0x70E4
const OP_RANKING_RESULT := 0xB0E4
const OP_REWARD := 0x70E5
const OP_REWARD_RESULT := 0xB0E5
const OP_PREV_JOB := 0x70E6
const OP_PREV_JOB_RESULT := 0xB0E6
const OP_JOB_EXP := 0x30E6
## Round 800: a suit's 10 seconds (c:FUN_008822c0 / FUN_008825d0).
const OP_STRIP_START := 0x3041
const OP_STRIP_CANCEL := 0x3042
## OURS (round 799): the job section of retail's 0x3013 (READ the client's
## reader GlobalDataManager::FUN_009ddc40: the alias, u8 kind, u8 level, u32
## exp, u32 contribution, u32 reward), which OpenSRO's server sends on its own.
const OP_JOB_INFO := 0x00BC

## The job kinds (player +0x7be): 0 none, 1 trader, 2 thief ("Robber"), 3
## hunter.
const KIND_NONE := 0
const KIND_TRADER := 1
const KIND_THIEF := 2
const KIND_HUNTER := 3

## 0x70E4's types.
const RANK_ACTIVITY := 0
const RANK_CONTRIBUTION := 1

## The highest job level (the server's FUN_0060dd90 `cmp bx,7`).
const MAX_LEVEL := 7

## The alias's length in bytes (UI_ALIAS::FUN_0074ae10 `iVar4 - 2U < 0xb`).
const ALIAS_MIN := 2
const ALIAS_MAX := 12

## The alias window's local refusal: the same code the server sends
## (0x4823, ALIAS_CREATE_ERR_NOTRULE).
const ERR_ALIAS_RULE := 0x4823

## The word each kind's UIIT keys use (c:0xddbd68..0xddbd4c, the job exp
## lines; the class names): MERCHANT, THIEF, HUNTER.
const KEY_WORD := {KIND_TRADER: "MERCHANT", KIND_THIEF: "THIEF", KIND_HUNTER: "HUNTER"}

static func _u32(v: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(4)
	out.encode_u32(0, v & 0xffffffff)
	return out

static func _string(s: String) -> PackedByteArray:
	var b := s.to_utf8_buffer()
	var out := PackedByteArray([b.size() & 0xff, (b.size() >> 8) & 0xff])
	out.append_array(b)
	return out

## 0x70E1 {u32 npc, u8 kind} (IF_NPCTalk::SendInstanceCharTrijobMsg_0e1).
static func encode_join(npc: int, kind: int) -> PackedByteArray:
	var out := _u32(npc)
	out.append(kind)
	return out

## 0x70E2 {u32 npc}; 0x70E6 the same.
static func encode_npc(npc: int) -> PackedByteArray:
	return _u32(npc)

## 0x70E3 {u32 npc, u8 op (0 check, 1 set), string alias}
## (UI_ALIAS::SendAliasMsg_0e3).
static func encode_alias(npc: int, op: int, alias: String) -> PackedByteArray:
	var out := _u32(npc)
	out.append(op)
	out.append_array(_string(alias))
	return out

## 0x70E4 {u32 npc, u8 kind, u8 type}.
static func encode_ranking(npc: int, kind: int, type: int) -> PackedByteArray:
	var out := _u32(npc)
	out.append(kind)
	out.append(type)
	return out

## 0x70E5 {u32 npc, u8 op (0 query, 1 collect)}.
static func encode_reward(npc: int, op: int) -> PackedByteArray:
	var out := _u32(npc)
	out.append(op)
	return out

static func _read_string(r: NpcSpawnNet.Reader) -> String:
	var n := r.u16()
	return r.bytes(n).get_string_from_utf8()

static func _head(r: NpcSpawnNet.Reader) -> Dictionary:
	var ok := r.u8() == 1
	return {"ok": ok, "code": 0 if ok else r.u16()}

## 0xB0E1 (JobGuild_OnJoinResult c:0x8890b0): {ok, code, kind, level, exp}.
static func decode_join(data: PackedByteArray) -> Dictionary:
	var r := NpcSpawnNet.Reader.new(data)
	var out := _head(r)
	if out["ok"]:
		out["kind"] = r.u8()
		out["level"] = r.u8()
		out["exp"] = r.u32()
	return out

## 0xB0E2 and 0xB0E6's failure: {ok, code}.
static func decode_plain(data: PackedByteArray) -> Dictionary:
	return _head(NpcSpawnNet.Reader.new(data))

## 0xB0E3 (UI_ALIAS::FUN_00889370): {ok, code, op, alias}.
static func decode_alias(data: PackedByteArray) -> Dictionary:
	var r := NpcSpawnNet.Reader.new(data)
	var out := _head(r)
	out["op"] = r.u8()
	out["alias"] = _read_string(r)
	return out

## 0xB0E4 (c:0x88a130): {ok, code, kind, type, rows}; a row is {rank, alias,
## level, exp, country} (activity) or {rank, alias, level, amount}.
static func decode_ranking(data: PackedByteArray) -> Dictionary:
	var r := NpcSpawnNet.Reader.new(data)
	var out := _head(r)
	out["kind"] = r.u8()
	out["type"] = r.u8()
	var rows: Array = []
	if out["ok"]:
		var n := r.u8()
		for i in n:
			var row := {"rank": r.u8(), "alias": _read_string(r), "level": r.u8()}
			if out["type"] == RANK_ACTIVITY:
				row["exp"] = r.u32()
				row["country"] = r.u8()
			else:
				row["amount"] = r.u32()
			rows.append(row)
	out["rows"] = rows
	return out

## 0xB0E5 (c:0x8830f0): {ok, code, op, gold}.
static func decode_reward(data: PackedByteArray) -> Dictionary:
	var r := NpcSpawnNet.Reader.new(data)
	var out := _head(r)
	out["op"] = r.u8()
	out["gold"] = r.u32() if out["ok"] else 0
	return out

## 0xB0E6 (c:0x881740): {ok, code, levels: [trader, thief, hunter], exps}
## -- the wire's order, trader, robber, hunter.
static func decode_prev_job(data: PackedByteArray) -> Dictionary:
	var r := NpcSpawnNet.Reader.new(data)
	var out := _head(r)
	if out["ok"]:
		var levels: Array = []
		var exps: Array = []
		for i in 3:
			levels.append(r.u8())
			exps.append(r.u32())
		out["levels"] = levels
		out["exps"] = exps
	return out

## 0x30E6 (NetProcessInInterface::FUN_00884dd0): {kind, level, exp}.
static func decode_job_exp(data: PackedByteArray) -> Dictionary:
	var r := NpcSpawnNet.Reader.new(data)
	return {"kind": r.u8(), "level": r.u8(), "exp": r.u32()}

## OP_JOB_INFO: {alias, kind, level, exp, contribution, reward}.
static func decode_job_info(data: PackedByteArray) -> Dictionary:
	var r := NpcSpawnNet.Reader.new(data)
	return {"alias": _read_string(r), "kind": r.u8(), "level": r.u8(), "exp": r.u32(), "contribution": r.u32(),
		"reward": r.u32()}

## 0x3041 (FUN_008822c0): {uid, kind}; kind 2 then {sub}; sub 2 (a job suit's
## change) then {seconds}. Sub 1 (the PvP cape's) is not decoded further.
static func decode_strip_start(data: PackedByteArray) -> Dictionary:
	var r := NpcSpawnNet.Reader.new(data)
	var out := {"uid": r.u32(), "kind": r.u8()}
	if out["kind"] == 2:
		out["sub"] = r.u8()
		if out["sub"] == 2:
			out["seconds"] = r.u8()
	return out
