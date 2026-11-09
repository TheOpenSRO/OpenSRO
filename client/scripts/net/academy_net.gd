extends RefCounted
class_name AcademyNet

## Round 865: the academy's ("training camp's") messages as sro_client.exe
## writes and reads them -- docs/protocol/academy.md is the contract (its
## sections 4-7), shared byte for byte with the server's
## server/internal/academy/wire.go. READ unless a line says otherwise; the
## client's handlers are registered at c:0x8a4010 (via c:0x8a1b80) and
## c:0x8980e0 (via c:0x894ac0), 0x3080 at c:0x870b56.
##
## Conventions (academy.md section 1):
## - a string is a u16 length and that many bytes, no NUL (c:0x4f7a70; the
##   client's writer c:0x53d8c0). OURS: OpenSRO's wire carries UTF-8, as every
##   other OpenSRO string does; an ASCII name is the same bytes either way;
## - a date is 16 bytes, i16 year, u16 month, day, hour, minute, second, u32
##   fraction (TIMESTAMP_STRUCT); the client stores it and never shows it;
## - every reply is u8 1 (success, a body may follow) or u8 2 + u16 code
##   (c:0x899630..0x899940); any other first byte is dropped.

# --- Opcodes (academy.md section 4) -----------------------------------------

const OP_OPEN := 0x7470
const OP_DISBAND := 0x7471
const OP_INVITE := 0x7472
const OP_BAN := 0x7473
const OP_LEAVE := 0x7474
const OP_GRADUATE := 0x7475
const OP_GRADUATE_MEMBER := 0x7476
const OP_NOTICE := 0x7477
const OP_HONOR_RANK := 0x7478
const OP_MATCH_REGISTER := 0x747A
const OP_MATCH_MODIFY := 0x747B
const OP_MATCH_DELETE := 0x747C
const OP_MATCH_PAGE := 0x747D
const OP_MATCH_JOIN := 0x747E
## Round 866: the guardian's answer to a board join request (c:0x81d530).
const OP_MATCH_JOIN_ANSWER := 0x347F
const OP_BUFF_TRANSFER := 0x7483
## 0x3080 is the request-box channel both ways (kind 9 down, the answer up).
const OP_REQUEST := 0x3080

const OP_OPEN_RESULT := 0xB470
const OP_DISBAND_RESULT := 0xB471
const OP_INVITE_RESULT := 0xB472
const OP_BAN_RESULT := 0xB473
const OP_LEAVE_RESULT := 0xB474
const OP_GRADUATE_RESULT := 0xB475
const OP_GRADUATE_MEMBER_RESULT := 0xB476
const OP_NOTICE_RESULT := 0xB477
const OP_HONOR_RANK_RESULT := 0xB478
const OP_MATCH_REGISTER_RESULT := 0xB47A
const OP_MATCH_MODIFY_RESULT := 0xB47B
const OP_MATCH_DELETE_RESULT := 0xB47C
const OP_MATCH_PAGE_RESULT := 0xB47D
const OP_MATCH_JOIN_RESULT := 0xB47E
const OP_BUFF_LIST := 0xB483
const OP_PUSH := 0x3C80
const OP_CAMP := 0x3C81
const OP_OWN_BUFF := 0x3C82
const OP_OWN_BUFF_MINUTES := 0x3C86
const OP_RESERVE_BUFF_MINUTES := 0x3C87

## Every message the client reads (NetClient registers each to AcademyState).
## Round 866: 0x747E down, the question a board join request puts to the
## guardian (c:0x890fa0, registered in c:0x8980e0's list beside 0xB47E), is
## read too.
const SERVER_OPCODES := [OP_MATCH_JOIN, OP_OPEN_RESULT, OP_DISBAND_RESULT, OP_INVITE_RESULT,
	OP_BAN_RESULT, OP_LEAVE_RESULT, OP_GRADUATE_RESULT, OP_GRADUATE_MEMBER_RESULT,
	OP_NOTICE_RESULT, OP_HONOR_RANK_RESULT, OP_MATCH_REGISTER_RESULT,
	OP_MATCH_MODIFY_RESULT, OP_MATCH_DELETE_RESULT, OP_MATCH_PAGE_RESULT,
	OP_MATCH_JOIN_RESULT, OP_BUFF_LIST, OP_PUSH, OP_CAMP, OP_OWN_BUFF,
	OP_OWN_BUFF_MINUTES, OP_RESERVE_BUFF_MINUTES]

## 0x3080's kind for an academy invitation (c:0x88aa60, jump table c:0x88b1d4
## -> c:0x88aba8).
const REQUEST_ACADEMY_INVITE := 9

# --- 0x3C80's sub-types (c:0x8a2110, academy.md section 6) --------------------

const PUSH_DISBANDED := 0x01
const PUSH_JOINED := 0x02
const PUSH_REMOVED := 0x03
const PUSH_GRADUATED := 0x04
const PUSH_FIELD := 0x05
const PUSH_NOTICE := 0x07
const PUSH_ENTERED := 0x0a
const PUSH_RANK := 0x0c
const PUSH_POSITION := 0x0d

## Sub 3's reason byte.
const REMOVED_LEFT := 1
const REMOVED_BANNED := 2
const REMOVED_SILENT := 3

## Sub 5's field byte (the jump table c:0x6e9674: 1, 2, 3, 6 and 7 read a
## value; 4 and 5 read nothing -- READ, the table's entries 4 and 5 are the
## exit 0x6e964a).
const FIELD_PLAY_STATE := 1
const FIELD_MAX_LEVEL := 2
const FIELD_HONOR := 3
const FIELD_NAME := 5
const FIELD_CUR_LEVEL := 6
const FIELD_MODEL := 7

## The play state (member +0x74): 0 online, 1 offline (MEASURED both ways).
const ONLINE := 0
const OFFLINE := 1

## MemberClass (member +0x44; c:0x6e8ed0 picks the titles by it).
const CLASS_GUARDIAN := 0
const CLASS_ASSISTANT := 1
const CLASS_APPRENTICE := 2

## Codes the client treats on their own (academy.md section 11).
const CODE_INVALID_TARGET := 3
const CODE_REOPEN_PENALTY := 0x681c
const CODE_DISBAND_WINDOW := 0x681d
const CODE_NO_NOTES := 0x6817
const CODE_TIMEOUT := 0x000e

## Category 0x1d of the error dispatcher (UI_SILKMALL::FUN_007b8b40; its
## table c:0x7bbe14 for 0x6809..0x682a, below that only code 3). A code with
## no row prints nothing (the pre-set empty text, c:0x7b8b7f).
const UIIT_BY_CODE := {
	0x0003: "UIIT_STT_ERR_COMMON_INVALID_TARGET",
	0x6807: "UIIT_MSG_TC_ERROR_DIE_PASSING",
	0x6809: "UIIT_MSG_TC_ERROR_OPEN_LEVEL",
	0x680a: "UIIT_MSG_TC_ERROR_OPEN_GOLD",
	0x680b: "UIIT_MSG_TC_ERROR_TRAININGCAMP_NOTHING",
	0x680f: "UIIT_MSG_TC_ERROR_TRAININGCAMP_ALREADY_ENTRY",
	0x6810: "UIIT_MSG_TC_ERROR_SECOND_GUARDIAN_COUNT_OVER",
	0x6811: "UIIT_MSG_TC_ERROR_INVITE_REJECTION",
	0x6812: "UIIT_MSG_TC_ERROR_OTHER_TRAININGCAMP_ENTRY",
	0x6813: "UIIT_MSG_TC_ERROR_ORDER_WORK",
	0x6814: "UIIT_MSG_TC_ERROR_ORDER_WORK",
	0x6815: "UIIT_MSG_TC_ERROR_ORDER_WORK",
	0x6816: "UIIT_MSG_TC_ERROR_ORDER_WORK",
	0x6817: "UIIT_MSG_GUILD_COMMON_NOTEXIST",
	0x681a: "UIIT_MSG_TC_ERROR_GRADUATION_LEVER",
	0x681c: "UIIT_MSG_TC_ERROR_NOT_OPEN_7D",
	0x681d: "UIIT_MSG_TC_ERROR_NOT_DISORGANIZATION_7D",
	0x681e: "UIIT_MSG_TC_ERROR_NOT_ENTRY_24T",
	0x681f: "UIIT_MSG_TC_ERROR_NOT_INVITE_24T",
	0x6820: "UIIT_MSG_TC_ERROR_NOT_BAN_24T",
	0x6821: "UIIT_MSG_TC_ERROR_NOT_OUT_24T",
	0x6822: "UIIT_MSG_TC_ERROR_POSIBLE_41L",
	0x6823: "UIIT_MSG_TC_ERROR_JOB_DRESS",
	0x6824: "UIIT_MSG_TC_ERROR_NOT_POSITION",
	0x6825: "UIIT_MSG_TC_ERROR_ALREADY_OPEN",
	0x6826: "UIIT_MSG_TC_ERROR_NOT_INFORMATION",
	0x6828: "UIIT_MSG_TC_ERROR_STUDENT_COUNT_OVER",
	0x6829: "UIIT_STT_TC_BAN_MACHING_ERROR",
	0x682a: "UIIT_MSG_TC_ERROR_INVITE_TYPE_DIFFERENT",
}

## The text key of a category-0x1d code, "" when the client prints nothing.
static func error_key(code: int) -> String:
	return UIIT_BY_CODE.get(code, "")

# --- Reading ---------------------------------------------------------------

## A cursor over a message. Every read past the end sets `bad` and returns a
## zero value, so a short message is dropped whole (the decoders check it).
class Reader:
	var data: PackedByteArray
	var at := 0
	var bad := false

	func _init(d: PackedByteArray, start: int = 0) -> void:
		data = d
		at = start

	func _need(n: int) -> bool:
		if at + n > data.size():
			bad = true
			return false
		return true

	func u8() -> int:
		if not _need(1):
			return 0
		at += 1
		return data[at - 1]

	func u16() -> int:
		if not _need(2):
			return 0
		at += 2
		return data.decode_u16(at - 2)

	func i16() -> int:
		if not _need(2):
			return 0
		at += 2
		return data.decode_s16(at - 2)

	func u32() -> int:
		if not _need(4):
			return 0
		at += 4
		return data.decode_u32(at - 4)

	func i32() -> int:
		if not _need(4):
			return 0
		at += 4
		return data.decode_s32(at - 4)

	func text() -> String:
		var n := u16()
		if bad or not _need(n):
			return ""
		at += n
		return data.slice(at - n, at).get_string_from_utf8()

	## A 16-byte TIMESTAMP_STRUCT as [y, mo, d, h, mi, s, fraction].
	func ts() -> Array:
		if not _need(16):
			return []
		var out := [data.decode_s16(at), data.decode_u16(at + 2), data.decode_u16(at + 4),
			data.decode_u16(at + 6), data.decode_u16(at + 8), data.decode_u16(at + 10),
			data.decode_u32(at + 12)]
		at += 16
		return out

	func left() -> int:
		return data.size() - at

## One MemberEntry (academy.md section 5; c:0x999550 reads it, c:0x997900
## stores it in the 0x88-byte member object at the offsets noted).
class Member:
	var camp_id := 0           ## +0x00
	var char_id := 0           ## +0x04, the key every update names
	var ref_obj_id := 0        ## +0x08, the body (the portrait)
	var name := ""             ## +0x0c
	var member_class := 0      ## +0x44
	var joined_level := 0      ## +0x46, not shown
	var join_date: Array = []  ## +0x48, not shown
	var cur_level := 0         ## +0x58
	var max_level := 0         ## +0x59
	var honor := 0             ## +0x5c
	var play_state := OFFLINE  ## +0x74
	var world_id := 0          ## +0x78
	var region := 0            ## +0x7c
	var x := 0                 ## +0x7e
	var y := 0                 ## +0x80
	var z := 0                 ## +0x82
	var display_name := ""     ## +0x28 (the live object's name, or its job alias)
	## +0x45, the grade: computed by the client, never sent (c:0x98e120).
	var grade := 0

	func online() -> bool:
		return play_state == ONLINE

static func read_member(r: Reader) -> Member:
	var m := Member.new()
	m.camp_id = r.u32()
	m.char_id = r.u32()
	m.ref_obj_id = r.u32()
	m.name = r.text()
	m.member_class = r.u8()
	m.joined_level = r.u8()
	m.join_date = r.ts()
	m.cur_level = r.u8()
	m.max_level = r.u8()
	m.honor = r.i32()
	m.play_state = r.u8()
	m.world_id = r.u32()
	m.region = r.u16()
	m.x = r.i16()
	m.y = r.i16()
	m.z = r.i16()
	m.display_name = r.text()
	m.grade = grade_of(m.member_class, m.max_level, 0)
	return m

## The camp record (CampInfo, c:0x99ace0 into the store's +0x268 block).
class Camp:
	var camp_id := 0             ## +0x00
	var creation_date: Array = [] ## +0x24..+0x33, not shown
	var rank := 5                ## +0x34, the honor grade: com_honor_level_<n>
	var notice_title := ""       ## +0x38
	var notice_content := ""     ## +0x54
	var members: Array = []      ## [Member] in wire order (guardian first)

static func read_camp(r: Reader) -> Camp:
	var c := Camp.new()
	c.camp_id = r.u32()
	c.creation_date = r.ts()
	c.rank = r.u8()
	c.notice_title = r.text()
	c.notice_content = r.text()
	var n := r.u8()
	# c:0x999550 asserts "TraningCampMember is Over than 8" and reads on.
	for i in n:
		if r.bad:
			break
		c.members.append(read_member(r))
	return c

## A camp from a whole message (0x3C81, or the body after 0xB470's 1).
static func decode_camp(data: PackedByteArray, start: int = 0) -> Camp:
	var r := Reader.new(data, start)
	var c := read_camp(r)
	return null if r.bad else c

## The grade (member +0x45), c:0x98e120 (READ in asm): from the class and
## the max level (+0x59); `was` stays when no rule applies.
##   apprentice  1..10 -> 1, 11..20 -> 2, 21..30 -> 3, >= 31 -> 4 (0 keeps);
##   assistant   40..49 -> 5, >= 50 -> 6 (< 40 keeps);
##   guardian    >= 60 -> 7.
static func grade_of(member_class: int, max_level: int, was: int) -> int:
	match member_class:
		CLASS_APPRENTICE:
			if max_level >= 31:
				return 4
			if max_level >= 21:
				return 3
			if max_level >= 11:
				return 2
			if max_level >= 1:
				return 1
		CLASS_ASSISTANT:
			if max_level >= 50:
				return 6
			if max_level >= 40:
				return 5
		CLASS_GUARDIAN:
			if max_level >= 60:
				return 7
	return was

## The grade's title key (the slot's RANK_NAME, c:0x6eab30 per +0x45).
const GRADE_TITLES := {
	1: "UIIT_STT_TC_FIRST_STUDENT", 2: "UIIT_STT_TC_STUDENT", 3: "UIIT_STT_TC_SECOND_STUDENT",
	4: "UIIT_STT_TC_THIRD_STUDENT", 5: "UIIT_STT_TC_FIRST_GUARDIAN",
	6: "UIIT_STT_TC_SECOND_GUARDIAN", 7: "UIIT_STT_TC_GUARDIAN",
}
## The class titles of the log-on lines (c:0x6e8ed0).
const CLASS_TITLES := {
	CLASS_GUARDIAN: "UIIT_STT_TC_GUARDIAN",
	CLASS_ASSISTANT: "UIIT_STT_TC_ASSISTANT_GUARDIAN",
	CLASS_APPRENTICE: "UIIT_STT_TC_STUDENT",
}

## A reply: ok, or the code (and the u32 of seconds 0xB470 carries with
## 0x681c and 0xB471 with 0x681d: read and discarded by the client).
class Result:
	var ok := false
	var code := 0
	var seconds := 0
	## Where the success body starts (after the 1).
	var body_at := 1

## Null for an empty reply or a first byte other than 1 or 2.
static func decode_result(op: int, data: PackedByteArray) -> Result:
	if data.is_empty():
		return null
	var r := Result.new()
	if data[0] == 1:
		r.ok = true
		return r
	if data[0] != 2 or data.size() < 3:
		return null
	r.code = data.decode_u16(1)
	var carries := (op == OP_OPEN_RESULT and r.code == CODE_REOPEN_PENALTY) \
		or (op == OP_DISBAND_RESULT and r.code == CODE_DISBAND_WINDOW)
	if carries and data.size() >= 7:
		r.seconds = data.decode_u32(3)
	return r

## One 0x3C80. `sub` and the fields of its kind; `bad` for a short one.
class Push:
	var sub := 0
	var bad := false
	var member: Member = null    ## sub 2
	var char_id := 0             ## subs 3, 4, 5, 0x0d
	var reason := 0              ## sub 3
	var kind := 0                ## sub 4 (OPEN which value is which)
	var field := 0               ## sub 5
	var value := 0               ## sub 5 fields 1, 2, 3, 6, 7
	var title := ""              ## sub 7
	var content := ""            ## sub 7
	var ok := false              ## sub 0x0a: 1 joined, 2 refused
	var code := 0                ## sub 0x0a's refusal
	var camp: Camp = null        ## sub 0x0a
	var rank := 0                ## sub 0x0c
	var display_name := ""       ## sub 0x0d
	var world_id := 0
	var region := 0
	var x := 0
	var y := 0
	var z := 0

static func decode_push(data: PackedByteArray) -> Push:
	var p := Push.new()
	var r := Reader.new(data)
	p.sub = r.u8()
	match p.sub:
		PUSH_JOINED:
			p.member = read_member(r)
		PUSH_REMOVED:
			p.char_id = r.u32()
			p.reason = r.u8()
		PUSH_GRADUATED:
			p.char_id = r.u32()
			p.kind = r.u8()
		PUSH_FIELD:
			p.char_id = r.u32()
			p.field = r.u8()
			match p.field:
				FIELD_PLAY_STATE, FIELD_MAX_LEVEL, FIELD_CUR_LEVEL:
					p.value = r.u8()
				FIELD_HONOR:
					p.value = r.i32()
				FIELD_MODEL:
					p.value = r.u32()
		PUSH_NOTICE:
			p.title = r.text()
			p.content = r.text()
		PUSH_ENTERED:
			var res := r.u8()
			if res == 1:
				p.ok = true
				p.camp = read_camp(r)
			elif res == 2:
				p.code = r.u16()
			else:
				p.sub = -1
		PUSH_RANK:
			p.rank = r.u8()
		PUSH_POSITION:
			# c:0x8a3044..0x8a3151: u32 key, str, u32, u16 x 4, into +0x28,
			# +0x78, +0x7c..+0x82 (c:0x997b20).
			p.char_id = r.u32()
			p.display_name = r.text()
			p.world_id = r.u32()
			p.region = r.u16()
			p.x = r.i16()
			p.y = r.i16()
			p.z = r.i16()
	p.bad = r.bad
	return p

## 0x3080 kind 9: [inviter unique id, inviter name], or [] when the message
## is not an academy invitation.
static func decode_invitation(data: PackedByteArray) -> Array:
	if data.is_empty() or data[0] != REQUEST_ACADEMY_INVITE:
		return []
	var r := Reader.new(data, 1)
	var uid := r.u32()
	var who := r.text()
	return [] if r.bad else [uid, who]

## One honor ranking row (0xB478, c:0x993230).
class HonorRow:
	var ranking := 0
	var rank := 0
	var guardian := ""
	var cur_level := 0
	var max_level := 0
	var graduates := 0
	var guild := ""

## 0xB478's rows after the 1, or null when short.
static func decode_honor_rows(data: PackedByteArray) -> Array:
	var r := Reader.new(data, 1)
	var n := r.u8()
	var out: Array = []
	for i in n:
		var h := HonorRow.new()
		h.ranking = r.u32()
		h.rank = r.u8()
		h.guardian = r.text()
		h.cur_level = r.u8()
		h.max_level = r.u8()
		h.graduates = r.u32()
		h.guild = r.text()
		if r.bad:
			return []
		out.append(h)
	return out

## One matching board row (0xB47D, c:0x890ab0; the consumer c:0x773320).
class MatchRow:
	var entry_id := 0          ## +0x00, the No. column
	var unknown_b := 0         ## not stored (OPEN)
	var flags := 0             ## +0x21: bit 0 apprentices, bit 1 assistants
	var title := ""            ## +0x40
	var unknown_d := 0         ## +0x04: the entry's registration time, Unix seconds (MEASURED round 866; not shown)
	var level := 0             ## +0x08
	var max_level := 0         ## +0x09
	var ref_obj_id := 0        ## +0x0c, the race from it
	var guardian := ""         ## +0x24
	var graduates := 0         ## +0x14
	var rank := 0              ## +0x20
	var assistants := 0        ## +0x18
	var apprentices := 0       ## +0x1c

## 0xB47D's success: {"a": u8, "b": u8, "rows": [MatchRow]} -- the first two
## bytes go to c:0x7738c0 as (second, first); page and page count, order OPEN.
static func decode_match_page(data: PackedByteArray) -> Dictionary:
	var r := Reader.new(data, 1)
	var a := r.u8()
	var b := r.u8()
	var n := r.u8()
	var rows: Array = []
	for i in n:
		var m := MatchRow.new()
		m.entry_id = r.u32()
		m.unknown_b = r.u32()
		m.flags = r.u8()
		m.title = r.text()
		m.unknown_d = r.u32()
		m.level = r.u8()
		m.max_level = r.u8()
		m.ref_obj_id = r.u32()
		m.guardian = r.text()
		m.graduates = r.u32()
		m.rank = r.u8()
		m.assistants = r.u32()
		m.apprentices = r.u32()
		if r.bad:
			return {}
		rows.append(m)
	return {} if r.bad else {"a": a, "b": b, "rows": rows}

## Round 866: 0x747E down, a board join request put to the guardian
## (c:0x890fa0): u32 job id, u32 requester -- the record's +0x2c / +0x30,
## read first (c:0x890fed / c:0x890ffb) -- then the record c:0x88f4d0 reads:
## u32 entry, u32 requester again, u8 level, u8 max level, u32 RefObjID (the
## race), str name. MEASURED for a level-30 requester: the two requester
## u32s equal. {} when short.
static func decode_join_ask(data: PackedByteArray) -> Dictionary:
	var r := Reader.new(data)
	var d := {"job_id": r.u32(), "requester": r.u32(), "entry_id": r.u32(), "requester2": r.u32(),
		"level": r.u8(), "max_level": r.u8(), "ref_obj_id": r.u32(), "name": r.text()}
	return {} if r.bad else d

## 0xB47A / 0xB47B's success body (c:0x8907f0 / c:0x890960): u32, u32, u8,
## str, and on 0xB47A a last u32. {} when short.
static func decode_match_entry(op: int, data: PackedByteArray) -> Dictionary:
	var r := Reader.new(data, 1)
	var d := {"entry_id": r.u32(), "camp_id": r.u32(), "flags": r.u8(), "title": r.text()}
	if op == OP_MATCH_REGISTER_RESULT:
		d["tail"] = r.u32()
	return {} if r.bad else d

## The cumulated / accumulated buff messages (academy.md 7.11).
## 0x3C82 {u8 sub; 0/1/7: u32 minutes, u32 points} (c:0x89bcc0).
static func decode_own_buff(data: PackedByteArray) -> Dictionary:
	var r := Reader.new(data)
	var sub := r.u8()
	var d := {"sub": sub}
	if sub in [0, 1, 7]:
		d["minutes"] = r.u32()
		d["points"] = r.u32()
	return {} if r.bad else d

## 0xB483 {u8 sub; 0, 1, 5, 8, 9: u8 n, n x {u32 minutes, u32 donor, u32
## points}; 2: nothing} (c:0x89b7b0).
static func decode_buff_list(data: PackedByteArray) -> Dictionary:
	var r := Reader.new(data)
	var sub := r.u8()
	var d := {"sub": sub, "rows": []}
	if sub in [0, 1, 5, 8, 9]:
		var n := r.u8()
		for i in n:
			(d["rows"] as Array).append({"minutes": r.u32(), "donor": r.u32(), "points": r.u32()})
	return {} if r.bad else d

# --- Writing -------------------------------------------------------------------

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

## 0x7470 / 0x7478: the talk NPC's unique id (c:0x821e40, c:0x8222e0).
static func encode_npc(npc_uid: int) -> PackedByteArray:
	return _u32(npc_uid)

## 0x7472: the target's unique id (c:0x821f00).
static func encode_invite(target_uid: int) -> PackedByteArray:
	return _u32(target_uid)

## 0x7473 / 0x7476: the member's name (c:0x824f80, c:0x825100).
static func encode_name(member_name: String) -> PackedByteArray:
	return _str(member_name)

## 0x7475: the evaluation byte (c:0x822180).
static func encode_graduate(evaluation: int) -> PackedByteArray:
	return PackedByteArray([evaluation & 0xff])

## 0x7477: title then content (c:0x824560).
static func encode_notice(title: String, content: String) -> PackedByteArray:
	var b := _str(title)
	b.append_array(_str(content))
	return b

## 0x7471 / 0x7474 / 0x7483: no payload.
static func encode_empty() -> PackedByteArray:
	return PackedByteArray()

## 0x3080's answer to kind 9 (c:0x788840 case 8): yes {1, 1}, else {2, u16 0}.
static func encode_answer(accept: bool) -> PackedByteArray:
	return PackedByteArray([1, 1]) if accept else PackedByteArray([2, 0, 0])

## 0x747A / 0x747B (c:0x823cc0's struct): u32, u32, u8 flags, str title.
static func encode_match(first: int, second: int, flags: int, title: String) -> PackedByteArray:
	var b := _u32(first)
	b.append_array(_u32(second))
	b.append(flags & 0xff)
	b.append_array(_str(title))
	return b

## 0x747C / 0x747E: u32 entry id.
static func encode_entry(entry_id: int) -> PackedByteArray:
	return _u32(entry_id)

## 0x347F (c:0x81d530): the question's two leading u32s echoed (the box keeps
## them at +0xad4 / +0xad8), then the answer: 1 for Yes, 0 for No and for the
## box's own timeout (c:0x798081..0x7980c2; MEASURED both).
static func encode_join_answer(job_id: int, requester: int, accept: bool) -> PackedByteArray:
	var b := _u32(job_id)
	b.append_array(_u32(requester))
	b.append(1 if accept else 0)
	return b

## 0x747D: u8 page.
static func encode_page(page: int) -> PackedByteArray:
	return PackedByteArray([page & 0xff])

# --- Server-side shapes (tests and the QA fixtures build messages with these) ---

static func _ts(t: Array) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(16)
	if t.size() >= 7:
		b.encode_s16(0, int(t[0]))
		for i in 5:
			b.encode_u16(2 + 2 * i, int(t[1 + i]))
		b.encode_u32(12, int(t[6]))
	return b

static func encode_member(m: Member) -> PackedByteArray:
	var b := _u32(m.camp_id)
	b.append_array(_u32(m.char_id))
	b.append_array(_u32(m.ref_obj_id))
	b.append_array(_str(m.name))
	b.append(m.member_class)
	b.append(m.joined_level)
	b.append_array(_ts(m.join_date))
	b.append(m.cur_level)
	b.append(m.max_level)
	var h := PackedByteArray()
	h.resize(4)
	h.encode_s32(0, m.honor)
	b.append_array(h)
	b.append(m.play_state)
	b.append_array(_u32(m.world_id))
	var loc := PackedByteArray()
	loc.resize(8)
	loc.encode_u16(0, m.region)
	loc.encode_s16(2, m.x)
	loc.encode_s16(4, m.y)
	loc.encode_s16(6, m.z)
	b.append_array(loc)
	b.append_array(_str(m.display_name))
	return b

static func encode_camp(c: Camp) -> PackedByteArray:
	var b := _u32(c.camp_id)
	b.append_array(_ts(c.creation_date))
	b.append(c.rank)
	b.append_array(_str(c.notice_title))
	b.append_array(_str(c.notice_content))
	b.append(c.members.size())
	for m in c.members:
		b.append_array(encode_member(m))
	return b
