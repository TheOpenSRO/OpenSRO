extends RefCounted
class_name GameWorldNet

## The client's half of the game worlds and the Forgotten World's gate
## (round 869, lane C1; docs/protocol/game_worlds.md 5, 7 and 14 CLIENT,
## forgotten_world.md 4, 5 and 11 CLIENT). Codecs and tables only -- it never
## touches a window, so the suites run it headless. Every rule is READ from
## sro_client.exe (`c:` addresses) unless it says otherwise. The wire is the
## original's: these opcodes are retail's own.

## 0x300C, the notice push (handler c:0x874ea0). OpenSRO's server has carried
## 0x300C's payload on its own OpUniqueNotice (0x0110) since round 657; the
## client takes these two words on either opcode.
const OP_NOTICE := 0x300C
const OP_NOTICE_OURS := 0x0110
## {u16 0x0C1A, u8 minutes} (c:0x8764da..0x876578): swprintf of
## UIIT_MSG_EGYPT_DUNGEON_DESTROY_ALARM (key at 0xdd98f8) with the minutes,
## shown as the blue banner (GDR_WARNING_WND, c:0x77b580) and then as a
## type-0 system line (c:0x7781b0(0, text)).
const WORD_INSTANCE_CLOSES := 0x0C1A
const DESTROY_ALARM_KEY := "UIIT_MSG_EGYPT_DUNGEON_DESTROY_ALARM"
## {u16 0x0C1C, u8 kind, str key} (c:0x87657d..0x876670): the key a u16-length
## ANSI string (FUN_004f7a70), looked up in the text table (c:0x8c9bb0);
## kind 1 the banner only, kind 2 a type-0 system line only, any other
## nothing.
const WORD_TRIGGER_MESSAGE := 0x0C1C
const TRIGGER_BANNER := 1
const TRIGGER_SYSTEM_LINE := 2

## 0x320C, the timed-job push (c:0x88dad0). Kind 0x0C: {u32 group, u32
## remaining seconds}; remaining > 0 -> c:0x778f90: the group's record from
## groupworld_config_forclient (c:0x9373b0); with one, FUN_00777f20(0xe, group,
## 1, remaining, record +0x00) -- the buff board's entry of kind 0xE.
const OP_TIMED_JOB := 0x320C
const TIMED_JOB_WORLD_GROUP := 0x0C
const BOARD_KIND_WORLD_GROUP := 0x0E

## 0x705A, the teleport request; kind 3 a portal object with a u8 destination
## index (READ c:0x7035f8..0x703690: {u32 object, u8 3, u8 [line +0xc]}).
## 0xB05A its reply (c:0x8809d0): {u8 1} nothing; {u8 2, u16 code} the code's
## text in error category 0xd, colour 0xffdbc99b (FUN_00778190(0xd, ..)).
const OP_TELEPORT_USE := 0x705A
const OP_TELEPORT_USE_ACK := 0xB05A
const TELEPORT_KIND_PORTAL := 3

## The category-0xd interaction switch (READ: the jump table at 0x7bbaac,
## code - 0x1c07, 0x33 entries; each case pushes its key and joins the common
## tail 0x7bb2ea -> 0x7b89e0). The codes the game worlds' entry and the party
## recall send; a code with no row (1, 2, 3, 0x1c19, ...) goes to the default
## 0x7b913a, which shows nothing.
const INSTANCE_UIIT_BY_CODE := {
	0x1c0b: "UIIT_MSG_INTERACTION_FAIL_IM_BUSY",
	0x1c10: "UIIT_MSG_INTERACTION_FAIL_CANT_USE_TELEPORT_WITH_TRADECART",
	0x1c25: "UIIT_MSG_INTERACTION_FAIL_OUT_OF_REQUIRED_NUMBER_FOR_TELEPORT",
	0x1c26: "UIIT_MSG_EGYPT_MENU_ERROR_UNIONMEMBER",
	0x1c27: "UIIT_MSG_EGYPT_TOMB_ENTRANCE_CONDITION_ERROR_01",
	0x1c28: "UIIT_MSG_EGYPT_TOMB_ENTRANCE_CONDITION_ERROR_02",
	0x1c29: "UIIT_MSG_INSTANCEDUNGEON_ERROR_MSG_01",
	0x1c2a: "UIIT_MSG_EGYPT_TOMB_ENTRANCE_CONDITION_ERROR_05",
	0x1c2b: "UIIT_MSG_FLAGWAR_GAME_JOB_NOT_ENTER",
	0x1c2c: "UIIT_MSG_EGYPT_SHRINE_ENTRANCE_CONDITION_ERROR_01",
	0x1c2d: "UIIT_MSG_EGYPT_SHRINE_ENTRANCE_CONDITION_ERROR_04",
	0x1c2e: "UIIT_MSG_EGYPT_SHRINE_ENTRANCE_CONDITION_ERROR_03",
	0x1c2f: "UIIT_MSG_EGYPT_SHRINE_ENTRANCE_CONDITION_ERROR_02",
	0x1c30: "UIIT_MSG_INTERACTION_FAIL_CANT_USE_TELEPORT_WITH_RIDE",
	0x1c31: "UIIT_MSG_INSTANCEDUNGEON_ERROR_MSG_02",
	0x1c32: "UIIT_MGS_ERR_GOD_LIMIT_TIME",
	0x1c33: "UIIT_MGS_ERR_GOD_TELEPORT_HOLE_NOT_PARTY",
	0x1c34: "UIIT_MSG_PARTYMATCH_RECORD_ERROR_PARTYLEADER",
	0x1c35: "UIIT_MGS_ERR_GOD_INS_WORLD",
	0x1c36: "UIIT_MGS_ERR_GOD_DEADSTATE",
	0x1c37: "UIIT_MGS_ERR_GOD_TELEPORT_HOLE_NOT_TOWN",
	0x1c38: "UIIT_MGS_ERR_GOD_BATTLE_STATE",
	0x1c39: "UIIT_MGS_ERR_GOD_GUILD",
}

## The system line's colour for these refusals (c:0x8809d0 passes 0xffdbc99b).
const REFUSAL_COLOUR := Color8(0xdb, 0xc9, 0x9b)

## The gate's talk window (READ c:0x88b200's CITeleportGate branch and
## c:0x6fac20, c:0x9ea880):
## - the gate's lines are white (0xffffffff, style 1) but the last,
##   UIIT_STT_GOD_TELTOPRT_GATE_2, in 0xffd6ff7e style 2 (bold);
## - a destination line "%d. " + UIIT_CTL_TELEPORT_FREE_RESULT with the place,
##   line kind 0x2a, 0xffefdaa4 (0xffff8a00 under the pointer).
const GATE_NOTE_COLOUR := Color8(0xd6, 0xff, 0x7e)
const DEST_COLOUR := Color8(0xef, 0xda, 0xa4)
const DEST_HOVER_COLOUR := Color8(0xff, 0x8a, 0x00)
const GATE_LINE_1 := "UIIT_STT_GOD_TELTOPRT_GATE_1"
const GATE_LINE_2 := "UIIT_STT_GOD_TELTOPRT_GATE_2"
const PARTY_MASTER_KEY := "UIIT_STT_GOD_PARTY_MASTER"
const LEVEL_KEY := "UIIT_STT_GOD_LV_EXTENT"
const GRADE_KEY := "UIIT_STT_GOD_CLASS"
const FREE_RESULT_KEY := "UIIT_CTL_TELEPORT_FREE_RESULT"
const WADDUNGOT_KEY := "SN_TALK_COMMON_INS_WADDUNGOT"
const DONOTKNOW_KEY := "UIIT_CTL_GUILD_DONOTKNOW"
## The interaction ids the gate's select names (MEASURED 0xB045: {0x1c}).
const ID_TELEPORT := 0x1c
const ID_STRUCTURE_UPDATE := 0x1f

## The 0x300C notice of the game worlds: {"word", "minutes"} for 0x0C1A,
## {"word", "kind", "key"} for 0x0C1C, {} for any other word or a short one.
static func decode_notice(data: PackedByteArray) -> Dictionary:
	if data.size() < 3:
		return {}
	var word := data.decode_u16(0)
	if word == WORD_INSTANCE_CLOSES:
		return {"word": word, "minutes": int(data[2])}
	if word == WORD_TRIGGER_MESSAGE:
		if data.size() < 5:
			return {}
		var n := data.decode_u16(3)
		if data.size() < 5 + n:
			return {}
		return {"word": word, "kind": int(data[2]), "key": data.slice(5, 5 + n).get_string_from_ascii()}
	return {}

## Whether a 0x300C payload is one of the two words above.
static func is_world_notice(data: PackedByteArray) -> bool:
	return data.size() >= 2 and data.decode_u16(0) in [WORD_INSTANCE_CLOSES, WORD_TRIGGER_MESSAGE]

## The banner text and the system line text a notice shows ("" for none):
## {"banner": String, "line": String}. `text` resolves a key.
static func notice_texts(n: Dictionary, text: Callable) -> Dictionary:
	var out := {"banner": "", "line": ""}
	if n.is_empty():
		return out
	if int(n["word"]) == WORD_INSTANCE_CLOSES:
		var fmt := String(text.call(DESTROY_ALARM_KEY))
		var s := fmt % [int(n["minutes"])] if fmt.contains("%d") else fmt
		out["banner"] = s
		out["line"] = s
	elif int(n["word"]) == WORD_TRIGGER_MESSAGE:
		var s := String(text.call(String(n["key"])))
		if int(n["kind"]) == TRIGGER_BANNER:
			out["banner"] = s
		elif int(n["kind"]) == TRIGGER_SYSTEM_LINE:
			out["line"] = s
	return out

## A 0x300C payload (the tests; the server's twin).
static func encode_notice_closes(minutes: int) -> PackedByteArray:
	var b := PackedByteArray([0, 0, minutes & 0xff])
	b.encode_u16(0, WORD_INSTANCE_CLOSES)
	return b

static func encode_notice_trigger(kind: int, key: String) -> PackedByteArray:
	var k := key.to_ascii_buffer()
	var b := PackedByteArray([0, 0, kind & 0xff, 0, 0])
	b.encode_u16(0, WORD_TRIGGER_MESSAGE)
	b.encode_u16(3, k.size())
	b.append_array(k)
	return b

## 0x320C: {"kind", "group", "remaining_s"} for kind 0x0C, {"kind"} for any
## other, {} when short.
static func decode_timed_job(data: PackedByteArray) -> Dictionary:
	if data.is_empty():
		return {}
	var kind := int(data[0])
	if kind == TIMED_JOB_WORLD_GROUP:
		if data.size() < 9:
			return {}
		return {"kind": kind, "group": data.decode_u32(1), "remaining_s": data.decode_s32(5)}
	return {"kind": kind}

static func encode_timed_job_group(group: int, remaining_s: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(9)
	b[0] = TIMED_JOB_WORLD_GROUP
	b.encode_u32(1, group)
	b.encode_s32(5, remaining_s)
	return b

## The gauge c:0x805a40 case 0xe sets: total = the record's cool time (s) x
## 1000; elapsed = total - remaining x 1000 (READ). {"total_ms", "remaining_ms"}.
static func group_gauge(cool_s: int, remaining_s: int) -> Dictionary:
	return {"total_ms": cool_s * 1000, "remaining_ms": remaining_s * 1000}

## 0x705A {u32 object, u8 3, u8 index}.
static func encode_portal_use(object: int, index: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(6)
	b.encode_u32(0, object)
	b[4] = TELEPORT_KIND_PORTAL
	b[5] = index & 0xff
	return b

## 0xB05A: {"result", "code"} (code -1 on a 1), {} when short.
static func decode_teleport_ack(data: PackedByteArray) -> Dictionary:
	if data.is_empty():
		return {}
	var result := int(data[0])
	if result == 2:
		if data.size() < 3:
			return {}
		return {"result": result, "code": data.decode_u16(1)}
	return {"result": result, "code": -1}

## The key category 0xd shows for `code` ("" for the default: nothing).
static func refusal_key(code: int) -> String:
	return String(INSTANCE_UIIT_BY_CODE.get(code, ""))

## The CITeleportGate select reply 0xB045 (READ c:0x88b200, the branch for
## class 0xef1dac, then c:0x6fac20): u8 1, u32 entity, u8 n, n ids; a u16
## when 0x1f is among them (c:0x88b659..0x88b691); then, when 0x1c is among
## them, the destinations: u8 count, each a u8 kind -- 0 nothing more
## (SN_TALK_COMMON_INS_WADDUNGOT), 1 a u16-length ANSI text key, 2 u16 region
## and i32 x, y, z (12 bytes). MEASURED (the gate): {01, uid, 01 1c, 01, 02,
## u16 0x7EE4, i32 1063, 693, 1125}. The branch's service-country reads
## (c:0x88b4e1..0x88b5ec, three GlobalDataManager flags) and the u16 its
## ref's +0x120 gates (c:0x88b716) were absent from the measured reply and
## are not read (OPEN for another service). {} when it does not read.
static func decode_gate_select(data: PackedByteArray) -> Dictionary:
	var r := NpcSpawnNet.Reader.new(data)
	if r.u8() != 1:
		return {}
	var out := {"entity": r.u32(), "ids": PackedByteArray(), "structure_word": 0, "dests": []}
	var n := r.u8()
	out["ids"] = r.bytes(n)
	if (out["ids"] as PackedByteArray).has(ID_STRUCTURE_UPDATE):
		out["structure_word"] = r.u16()
	if (out["ids"] as PackedByteArray).has(ID_TELEPORT):
		var count := r.u8()
		for i in count:
			var kind := r.u8()
			var d := {"kind": kind, "key": "", "region": 0, "pos": Vector3i.ZERO}
			if kind == 1:
				d["key"] = r.bytes(r.u16()).get_string_from_ascii()
			elif kind == 2:
				d["region"] = r.u16()
				var x := _s32(r.u32())
				var y := _s32(r.u32())
				var z := _s32(r.u32())
				d["pos"] = Vector3i(x, y, z)
			(out["dests"] as Array).append(d)
	if r.error != "":
		return {}
	return out

static func _s32(v: int) -> int:
	return v - 0x100000000 if v >= 0x80000000 else v

## A destination's place name (c:0x6fac20): kind 0 the WADDUNGOT text; kind 1
## its key's text; kind 2 the text keyed by the region id in decimal (a field
## region, or a dungeon region not the player's own); a dungeon region the
## player stands in names its floor (OPEN here: UIIT_CTL_GUILD_DONOTKNOW).
static func dest_place(d: Dictionary, text: Callable, own_region: int) -> String:
	match int(d["kind"]):
		0:
			return String(text.call(WADDUNGOT_KEY))
		1:
			return String(text.call(String(d["key"])))
		2:
			var region := int(d["region"]) & 0xffff
			if region & 0x8000 and region == own_region:
				return String(text.call(DONOTKNOW_KEY))
			return String(text.call(str(region)))
	return ""

## The gate's own talk lines (c:0x9ea880, built by c:0x9e9eb0 at its spawn):
## GATE_1, a blank, the party master's line (type 7 only), the level line and
## the grade line (from the hole: Param3 - Param4, Param1), a blank, GATE_2.
## An empty piece is left out, as the original skips an empty string
## (FUN_004ecf90 only for a non-empty +0x2e4 / +0x300 / +0x31c / +0x338).
## Each {"text", "colour", "bold"}.
static func gate_lines(text: Callable, master_name: String, hole_band: Vector2i, grade: int) -> Array:
	var out: Array = []
	out.append({"text": String(text.call(GATE_LINE_1)), "colour": Color.WHITE, "bold": false})
	out.append({"text": "", "colour": Color.WHITE, "bold": false})
	if master_name != "":
		out.append({"text": _fmt(String(text.call(PARTY_MASTER_KEY)), master_name), "colour": Color.WHITE, "bold": false})
	if hole_band != Vector2i.ZERO:
		out.append({"text": _fmt(String(text.call(LEVEL_KEY)), "%d - %d" % [hole_band.x, hole_band.y]), "colour": Color.WHITE, "bold": false})
		if grade >= 1 and grade <= 4:
			out.append({"text": _fmt(String(text.call(GRADE_KEY)), String(text.call("UIIT_STT_GOD_CLASS_%d" % grade))), "colour": Color.WHITE, "bold": false})
	out.append({"text": "", "colour": Color.WHITE, "bold": false})
	out.append({"text": String(text.call(GATE_LINE_2)), "colour": GATE_NOTE_COLOUR, "bold": true})
	return out

static func _fmt(fmt: String, arg: String) -> String:
	return fmt % [arg] if fmt.contains("%s") else fmt

## A destination line's text: "%d. " + the free result's format with the place.
static func dest_line(n: int, place: String, text: Callable) -> String:
	var fmt := String(text.call(FREE_RESULT_KEY))
	return "%d. %s" % [n, _fmt(fmt, place)]

## groupworld_config_forclient.txt (READ c:0x958a13..0x958bad: a record per
## group; +0x00 TIMEDJOB_COOL_TIME_FORCLIENT x 60 s, +0x04 the subject key,
## +0x20 the explanation key, +0x3c the icon): group id -> {"cool_s",
## "subject", "explanation", "icon"}. MEASURED: group 1 (the Forgotten World)
## 480 minutes in our archive.
static func parse_group_config(data: PackedByteArray) -> Dictionary:
	var out := {}
	for line in TextDecode.utf16(data).split("\n"):
		var cols := line.strip_edges().split("\t")
		if cols.size() < 3 or not cols[0].strip_edges().is_valid_int():
			continue
		var g := int(cols[0].strip_edges())
		if not out.has(g):
			out[g] = {"cool_s": 0, "subject": "", "explanation": "", "icon": ""}
		var key := cols[1].strip_edges()
		var value := cols[2].strip_edges()
		match key:
			"TIMEDJOB_COOL_TIME_FORCLIENT":
				out[g]["cool_s"] = int(value) * 60
			"TIMEDJOB_SUBJECT_FORCLIENT":
				out[g]["subject"] = value
			"TIMEDJOB_EXPANATION_FORCLIENT":
				out[g]["explanation"] = value
			"TIMEDJOB_ICONURL_FORCLIENT":
				out[g]["icon"] = value
	return out

## The icon's tooltip (READ c:0x800a10's kind-0xe arm, c:0x803a3d..0x803b4b):
## the subject (style 1), the explanation, and "%s: %d%s %d%s %d%s" --
## UIIT_STT_REMAIN_TIME, hours PARAM_HOUR, minutes PARAM_MINUTE, seconds
## PARAM_SECOND of the time left.
static func group_tooltip(rec: Dictionary, remaining_ms: int, text: Callable) -> PackedStringArray:
	var out := PackedStringArray()
	out.append(String(text.call(String(rec.get("subject", "")))))
	out.append(String(text.call(String(rec.get("explanation", "")))))
	var left := maxi(remaining_ms, 0)
	var h := left / 3600000
	var m := (left % 3600000) / 60000
	var s := (left / 1000) % 60
	out.append("%s: %d%s %d%s %d%s" % [String(text.call("UIIT_STT_REMAIN_TIME")), h, String(text.call("PARAM_HOUR")),
		m, String(text.call("PARAM_MINUTE")), s, String(text.call("PARAM_SECOND"))])
	return out
