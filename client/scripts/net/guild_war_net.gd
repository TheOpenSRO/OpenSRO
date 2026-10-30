extends RefCounted
class_name GuildWarNet

## Round 844 (lane V): guild war on the wire, as sro_client.exe sends and
## reads it (READ, docs/protocol/guild_war.md; the server's side is
## server/internal/guild/war*.go and session/guildwar.go).
##
## Requests:
## - 0x7110 the proclamation (c:0x824a30, from the request box's confirm
##   state): str the target guild's name, u8 0 (INFERRED WarType), u32 the
##   packed period (0x71a810), u8 the victory-point index (0..7), u32 the
##   wager's low dword.
## - 0x3080 the proclaimed-on master's answer (c:0x820450): u8 1, u8 1 accept
##   / 0 refuse.
## - 0x7112 the end proposal (c:0x5bbf80): u32 the war id.
## - 0x7114 the guild manager's "War reward gold received" line (c:0x7020c0
##   case 0x1b): u32 the NPC; 0x7113 its question's OK (c:0x6f79c0 case 3):
##   u32 the NPC.
## Replies: u8 1, or u8 2 + u16 code (category 0x10). B114's success carries
## u32 the amount (c:0x885ae0); its 0x4c45 is "No refundable rewards."

const OP_DECLARE := 0x7110
const OP_DECLARE_RESULT := 0xB110
const OP_END := 0x7112
const OP_END_RESULT := 0xB112
const OP_CLAIM := 0x7113
const OP_CLAIM_RESULT := 0xB113
const OP_ASK_REWARD := 0x7114
const OP_ASK_REWARD_RESULT := 0xB114
const OP_HOSTILE_LIST := 0x3109
const OP_REQUEST := 0x3080
const RESULT_OPCODES := [OP_DECLARE_RESULT, OP_END_RESULT, OP_CLAIM_RESULT, OP_ASK_REWARD_RESULT]

## 0x3080's kind for a proclamation (c:0x88b1d4 index 9 -> 0x88aea8).
const REQUEST_WAR := 10

## 0x38F5's war types (FUN_00887330, tables 0x888b00 / 0x888ab4).
const UPDATE_WAR_STARTED := 0x19
const UPDATE_WAR_ENDING := 0x1a
const UPDATE_WAR_ENDING_B := 0x1b
const UPDATE_WAR_ENDED := 0x1c
const UPDATE_WAR_KILL := 0x1d
const UPDATE_WAR_TIME := 0x1f
const UPDATE_HOSTILE_RENAMED := 0x23
const UPDATE_WAR_REQUEST := 0x32
const WAR_UPDATE_TYPES := [UPDATE_WAR_STARTED, UPDATE_WAR_ENDING, UPDATE_WAR_ENDING_B, UPDATE_WAR_ENDED,
	UPDATE_WAR_KILL, UPDATE_WAR_TIME, UPDATE_HOSTILE_RENAMED, UPDATE_WAR_REQUEST]
## 0x32's sub bytes.
const REQUEST_REFUSED := 0
const REQUEST_TIMED_OUT := 2
const REQUEST_NO_GOLD := 3

const CODE_NO_REWARD := 0x4c45

## A period part the box shows as "Unlimited", and the whole period then.
const UNLIMITED := 0x7fffffff
## The victory-point choices (the display table 0xd91e24; index 0 is
## "Unlimited", the combo's first row).
const VICTORY_POINTS := [0, 5000, 10000, 50000, 100000, 150000, 250000, 300000]
## The wager's cap (c:0x71c5c0; the server's own, s:0x5c6c9e).
const MAX_WAGER := 500000000
## The day / hour / minute combos' last rows are "Unlimited".
const DAY_ROWS := 31
const HOUR_ROWS := 24
const MINUTE_ROWS := 6

## The period word (0x71a810 / 0x71a780): any part Unlimited -> 0x7fffffff;
## else day << 10 | hour << 15 | minutes << 20 (minutes = the combo's index
## x 10).
static func pack_period(day: int, hour: int, minute_index: int) -> int:
	if day < 0 or day >= DAY_ROWS or hour < 0 or hour >= HOUR_ROWS or minute_index < 0 or minute_index >= MINUTE_ROWS:
		return UNLIMITED
	return (day & 0x1f) << 10 | (hour & 0x1f) << 15 | (minute_index * 10) << 20

## The period's parts {day, hour, minute}; {} for Unlimited.
static func unpack_period(word: int) -> Dictionary:
	if word == UNLIMITED:
		return {}
	return {"day": (word >> 10) & 0x1f, "hour": (word >> 15) & 0x1f, "minute": (word >> 20) & 0x3f}

static func victory_points(index: int) -> int:
	return int(VICTORY_POINTS[index]) if index >= 0 and index < VICTORY_POINTS.size() else 0

static func encode_declare(guild_name: String, period: int, point_index: int, gold: int) -> PackedByteArray:
	var b := _str(guild_name)
	b.append(0)
	b.append_array(_u32(period))
	b.append(point_index & 0xff)
	b.append_array(_u32(gold))
	return b

static func encode_answer(accept: bool) -> PackedByteArray:
	return PackedByteArray([1, 1 if accept else 0])

static func encode_u32(v: int) -> PackedByteArray:
	return _u32(v)

## One war as SGuildWarDef carries it (0x87ff10) and the hostile entry
## keeps it (0x999260; +0x30 the own guild's points, +0x34 theirs).
class War:
	var war_id := 0
	var remain := 0
	var victory_index := 0
	var gold := 0
	var guild_a := 0
	var guild_b := 0
	var points_a := 0
	var points_b := 0
	var name := ""
	## Filled by HostileData: the other guild's id and the two sides' points.
	var other_id := 0
	var own_points := 0
	var their_points := 0

## SGuildWarDef (0x87ff10): u32 id, and when it is not 0 u32 the seconds
## left, u8 the victory index, u32 the wager, u32 guild A, u32 guild B, u32
## A's points, u32 B's points. The name is the caller's.
static func read_def(r: GuildData._Reader) -> War:
	var w := War.new()
	w.war_id = r.u32()
	if w.war_id != 0:
		w.remain = r.u32()
		w.victory_index = r.u8()
		w.gold = r.u32()
		w.guild_a = r.u32()
		w.guild_b = r.u32()
		w.points_a = r.u32()
		w.points_b = r.u32()
	return w if r.ok else null

## 0x3080 kind 10 (0x885920): u32 the declarer's world id, str its guild's
## name, u8 0, u32 the period, u8 the victory index, u32 the wager. {} when
## it is not a proclamation.
static func decode_proclamation(data: PackedByteArray) -> Dictionary:
	if data.is_empty() or data[0] != REQUEST_WAR:
		return {}
	var r := GuildData._Reader.new(data)
	r.u8()
	var who := r.u32()
	var gname := r.s()
	r.u8()
	var period := r.u32()
	var idx := r.u8()
	var gold := r.u32()
	if not r.ok:
		return {}
	return {"declarer": who, "guild_name": gname, "period": period, "victory_index": idx, "gold": gold}

## A reply: {ok, code, amount}.
static func decode_result(op: int, data: PackedByteArray) -> Dictionary:
	var r := GuildData._Reader.new(data)
	var flag := r.u8()
	if not r.ok:
		return {}
	if flag == 1:
		var amount := r.u32() if op == OP_ASK_REWARD_RESULT else 0
		return {"ok": true, "code": 0, "amount": amount}
	var code := r.u16()
	return {"ok": false, "code": code if r.ok else 0, "amount": 0}

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
	b.encode_u32(0, v & 0xffffffff)
	return b
