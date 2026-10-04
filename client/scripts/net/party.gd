extends RefCounted
class_name PartyNet

## The party messages, on the original's opcodes and byte layouts (round 711,
## lane C1 of the party epic). Every layout below is the one recorded in
## docs/protocol/party_protocol.md, read from the client (`c:`) and the
## server package (`gs:` GameServer, `sm:` ShardManager); the citations are
## that page's. OpenSRO's own 0x0080..0x0089 party messages are retired.
##
## Every message has an encoder and a decoder, both directions, so the tests
## can prove each one byte for byte against the shared golden fixtures
## (client/scripts/net/fixtures/party/, round 710's README).
##
## Strings are the client's narrow strings: a u16 byte length, then the bytes
## (READ, `c:0x883620`'s reads). The text itself is carried as UTF-8 here, as
## every other OpenSRO string is (OURS: the retail client's code page is not
## reproduced).

# --- Opcodes (party_protocol.md, "Opcode table") ---------------------------

const OP_CREATE := 0x7060          ## C->S u32 target world id, u8 flags (c:0x81c6d0)
const OP_CREATE_ACK := 0xb060      ## S->C u8 result; 1: u32 own JID; 2: u16 code (c:0x880010)
const OP_LEAVE := 0x7061           ## C->S empty (c:0x81cad0)
const OP_INVITE := 0x7062          ## C->S u32 target world id (c:0x81c8f0)
const OP_INVITE_ACK := 0xb062      ## S->C u8 result; 2: u16 code (c:0x8800b0)
const OP_KICK := 0x7063            ## C->S u32 member JID (c:0x81cb70)
const OP_JOIN_ACK := 0xb067        ## S->C u8 result; 1: u32 own JID; 2: u16 code (c:0x880120)
const OP_PARTY_INFO := 0x3065      ## S->C the whole party (c:0x883cc0)
const OP_REQUEST := 0x3080         ## S->C invitation; C->S its answer (c:0x88aa60 / c:0x81cc30)
const OP_EVENT := 0x3864           ## S->C u8 kind, then per kind (c:0x886b10)

## The opcodes this module's dispatcher answers (NetClient routes them here).
const SERVER_OPCODES := [OP_CREATE_ACK, OP_INVITE_ACK, OP_JOIN_ACK, OP_PARTY_INFO,
	OP_REQUEST, OP_EVENT]

# --- Party flags, the "party type" byte (party_protocol.md, "Party flags") --

const FLAG_EXP_SHARE := 0x01       ## cap 8 when set, 4 when clear
const FLAG_ITEM_SHARE := 0x02
const FLAG_ANYONE_INVITE := 0x04   ## "Can invite without master status."

## The cap by the exp flag (c:0x987050: exp==0 && count==4, or exp==1 &&
## count==8, is full).
const CAP_EXP_SHARED := 8
const CAP_NOT_SHARED := 4

# --- 0x3080 request kinds the party uses (c:0x88ad8a, jump table c:0x88b1d4)

const REQUEST_FORM := 2            ## a party-less inviter: forming a new party
const REQUEST_JOIN := 3            ## an inviter already in a party

## 0x3080 answers: yes is [1][1]; no is [2][u16 code] -- 0x2c0c for a kind-2
## invitation, 0x2c17 for kind 3 (c:0x81cd20 / c:0x81cef0, asm).
const ANSWER_YES := 1
const ANSWER_NO := 2

# --- 0x3864 kinds (party_protocol.md, "0x3864 kinds") ----------------------

const EVENT_DISSOLVED := 1         ## u16 code (read and unused by the client)
const EVENT_JOINED := 2            ## member record, mask 0xff
const EVENT_LEFT := 3              ## u32 JID, u8 reason
const EVENT_UPDATE := 6            ## u32 JID, member record (update mask)
const EVENT_LEADER := 9            ## u32 new leader JID

## Leave reasons (c:0x8872e8, indexed by reason - 1).
const LEAVE_LOGOUT := 1            ## UIIT_MSG_PARTY_LOGOUT
const LEAVE_SECEDE := 2            ## UIIT_MSG_PARTY_SECEDE
const LEAVE_MIGRATION := 3         ## silent (debug line only)
const LEAVE_BOOTED := 4            ## UIIT_MSG_PARTY_BOOTED

# --- Error codes the party system sends (party_protocol.md) ----------------

const ERR_CREATE_REFUSED := 0x2c0c
const ERR_TIMEOUT := 0x2c10
const ERR_JOIN_REFUSED := 0x2c17

## code -> the client's UIIT_* message (docs/protocol/error_codes.md, via
## party_protocol.md "Error codes the party system sends"). A code with no
## client message is absent: the caller says so rather than inventing words.
const ERROR_KEYS := {
	0x2c08: "UIIT_MSG_PARTYERR_ALREADY_FULL",
	0x2c0a: "UIIT_MSG_PARTYERR_TOO_LOW_CREATOR_LEVEL",
	0x2c0c: "UIIT_MSG_PARTYERR_CREATE_PARTY_REFUSED",
	0x2c0d: "UIIT_MSG_PARTYERR_CANT_FIND_PARTY",
	0x2c0e: "UIIT_MSG_PARTYERR_CANT_FIND_CREATER",
	0x2c0f: "UIIT_MSG_PARTYERR_INVALID_USER",
	0x2c10: "UIIT_MSG_PARTYERR_TIMEOUT",
	0x2c12: "UIIT_MSG_PARTYERR_EXISTING_MEMBER",
	0x2c13: "UIIT_MSG_PARTYERR_MEMBER_FULL_EXP_SHARED_PARTY",
	0x2c14: "UIIT_MSG_PARTYERR_MEMBER_FULL_NONEEXP_SHARED_PARTY",
	0x2c17: "UIIT_MSG_PARTYERR_JOIN_PARTY_REFUSED",
	0x2c18: "UIIT_MSG_PARTYERR_MEMBER_OF_ANOTHER_PARTY",
	0x2c1b: "UIIT_MSG_PARTYMATCH_RECORD_ERROR_AGAIN",
	0x2c1c: "UIIT_MSG_PARTYERR_CANT_FIND_PARTY",
	0x2c1d: "UIIT_MSG_PARTYMATCH_RECORD_ERROR_PARTYLEADER",
	0x2c1e: "UIIT_MSG_PARTYMATCH_JOIN_ERROR_LEVEL",
	0x2c1f: "UIIT_MSG_PARTYMATCH_JOIN_ERROR_DUPLE",
	0x2c23: "UIIT_MSG_PARTY_USER_MISSMATCH",
	0x2c24: "UIIT_MSG_PARTYMATCH_JOIN_ERROR_DUPLE",
	0x2c25: "UIIT_MSG_PARTYMATCH_RECORD_ERROR_INVITE",
	0x2c26: "UIIT_MSG_JOBITEM_WEAR_ERR_PARTYMATCH",
	0x2c28: "UIIT_MGS_ARENA_ERR_CANT_PARTY_WITH_OPPONENT_IN_BATTLE_ARENA",
}

# --- The member record (party_protocol.md, "The party member record") ------
#
# One record, a mask byte saying which fields follow, in this order (READ,
# writer gs:0x470ba0, reader c:0x883620, cross-binary exact):

const MASK_NAME := 0x01            ## str name, u32 RefObjID (model)
const MASK_LEVEL := 0x02           ## u8 level
const MASK_HPMP := 0x04            ## u8: low nibble HP tenths, high nibble MP tenths
const MASK_MASTERY := 0x08         ## u32 mastery 1, u32 mastery 2
const MASK_JID := 0x10             ## u32 member JID
const MASK_POSITION := 0x20        ## u16 region, x/y/z, u32 world id
const MASK_GUILD := 0x40           ## str guild name
const MASK_JOB := 0x80             ## u8 job state
const MASK_FULL := 0xff

## Job states (GetJobState, chardata+0xf; party_protocol.md "Job rules"):
## 1 trader, 2 thief, 3 hunter, 4 not in job mode. 0 is not a valid value.
const JOB_NONE := 4

class Member:
	## Which fields this record carried (a full record is MASK_FULL).
	var mask: int = 0
	var jid: int = 0
	var member_name: String = ""
	var ref_obj_id: int = 0
	var level: int = 0
	## Tenths of full: a full record's are trunc(cur/max*10), 0..10
	## (gs:0x5bafab); an update's HP nibble is 1 + trunc(10 r), 11 at full HP
	## (gs:FUN_005bb0c0, read in round 710). The windows clamp the ratio to
	## full; how the client draws an 11 was not read (INFERRED).
	var hp_tenths: int = 0
	var mp_tenths: int = 0
	var region: int = 0
	## Integer positions (ftol on the server). u32 when region & 0x8000 (a
	## dungeon), u16 otherwise.
	var x: int = 0
	var y: int = 0
	var z: int = 0
	var world_id: int = 0
	var guild: String = ""
	var job: int = JOB_NONE
	var mastery1: int = 0
	var mastery2: int = 0

	## Copies every field `update` carried onto this member (0x3864 kind 6).
	func apply(update: Member) -> void:
		var m := update.mask
		if m & MASK_JID:
			jid = update.jid
		if m & MASK_NAME:
			member_name = update.member_name
			ref_obj_id = update.ref_obj_id
		if m & MASK_LEVEL:
			level = update.level
		if m & MASK_HPMP:
			hp_tenths = update.hp_tenths
			mp_tenths = update.mp_tenths
		if m & MASK_POSITION:
			region = update.region
			x = update.x
			y = update.y
			z = update.z
			world_id = update.world_id
		if m & MASK_GUILD:
			guild = update.guild
		if m & MASK_JOB:
			job = update.job
		if m & MASK_MASTERY:
			mastery1 = update.mastery1
			mastery2 = update.mastery2
		mask |= m

# --- A tiny reader over a payload: every read fails soft -------------------

class Reader:
	var data: PackedByteArray
	var pos: int = 0
	var bad: bool = false

	func _init(bytes: PackedByteArray, start: int = 0) -> void:
		data = bytes
		pos = start

	func _need(n: int) -> bool:
		if bad or pos + n > data.size():
			bad = true
			return false
		return true

	func u8() -> int:
		if not _need(1):
			return 0
		pos += 1
		return data[pos - 1]

	func u16() -> int:
		if not _need(2):
			return 0
		pos += 2
		return data.decode_u16(pos - 2)

	func u32() -> int:
		if not _need(4):
			return 0
		pos += 4
		return data.decode_u32(pos - 4)

	func string() -> String:
		var n := u16()
		if not _need(n):
			return ""
		pos += n
		return data.slice(pos - n, pos).get_string_from_utf8()

	func done() -> bool:
		return not bad and pos == data.size()

class Writer:
	var data := PackedByteArray()

	func u8(v: int) -> Writer:
		data.append(v & 0xff)
		return self

	func u16(v: int) -> Writer:
		var at := data.size()
		data.resize(at + 2)
		data.encode_u16(at, v & 0xffff)
		return self

	func u32(v: int) -> Writer:
		var at := data.size()
		data.resize(at + 4)
		data.encode_u32(at, v & 0xffffffff)
		return self

	func text(s: String) -> Writer:
		var b := s.to_utf8_buffer()
		u16(b.size())
		data.append_array(b)
		return self

## Reads one member record (mask byte first). Null when it runs short.
static func read_member(r: Reader) -> Member:
	var m := Member.new()
	m.mask = r.u8()
	if m.mask & MASK_JID:
		m.jid = r.u32()
	if m.mask & MASK_NAME:
		m.member_name = r.string()
		m.ref_obj_id = r.u32()
	if m.mask & MASK_LEVEL:
		m.level = r.u8()
	if m.mask & MASK_HPMP:
		# c:0x99a34b: `and ecx,0xf` is HP, `shr eax,4` is MP.
		var hm := r.u8()
		m.hp_tenths = hm & 0x0f
		m.mp_tenths = (hm >> 4) & 0x0f
	if m.mask & MASK_POSITION:
		m.region = r.u16()
		# ftol results, so signed (a dungeon's y can be below zero).
		if m.region & 0x8000:
			m.x = _s32(r.u32())
			m.y = _s32(r.u32())
			m.z = _s32(r.u32())
		else:
			m.x = _s16(r.u16())
			m.y = _s16(r.u16())
			m.z = _s16(r.u16())
		m.world_id = r.u32()
	if m.mask & MASK_GUILD:
		m.guild = r.string()
	if m.mask & MASK_JOB:
		m.job = r.u8()
	if m.mask & MASK_MASTERY:
		m.mastery1 = r.u32()
		m.mastery2 = r.u32()
	return null if r.bad else m

static func _s32(v: int) -> int:
	return v - 0x100000000 if v >= 0x80000000 else v

static func _s16(v: int) -> int:
	return v - 0x10000 if v >= 0x8000 else v

## Writes `m` with its own mask (a full record: set m.mask = MASK_FULL).
static func write_member(w: Writer, m: Member) -> void:
	w.u8(m.mask)
	if m.mask & MASK_JID:
		w.u32(m.jid)
	if m.mask & MASK_NAME:
		w.text(m.member_name)
		w.u32(m.ref_obj_id)
	if m.mask & MASK_LEVEL:
		w.u8(m.level)
	if m.mask & MASK_HPMP:
		w.u8((m.hp_tenths & 0x0f) | ((m.mp_tenths & 0x0f) << 4))
	if m.mask & MASK_POSITION:
		w.u16(m.region)
		if m.region & 0x8000:
			w.u32(m.x)
			w.u32(m.y)
			w.u32(m.z)
		else:
			w.u16(m.x)
			w.u16(m.y)
			w.u16(m.z)
		w.u32(m.world_id)
	if m.mask & MASK_GUILD:
		w.text(m.guild)
	if m.mask & MASK_JOB:
		w.u8(m.job)
	if m.mask & MASK_MASTERY:
		w.u32(m.mastery1)
		w.u32(m.mastery2)

# --- Client -> server ------------------------------------------------------

## 0x7060: create a party with the selected player. `flags` is the settings
## block's exp | item << 1 | anyone << 2 (c:0x81c7f0..0x81c82e).
static func encode_create(target_world_id: int, flags: int) -> PackedByteArray:
	return Writer.new().u32(target_world_id).u8(flags).data

## 0x7062: invite the selected player into my party.
static func encode_invite(target_world_id: int) -> PackedByteArray:
	return Writer.new().u32(target_world_id).data

## 0x7061: leave. Empty (c:0x81cad0 writes nothing).
static func encode_leave() -> PackedByteArray:
	return PackedByteArray()

## 0x7063: banish a member (leader only).
static func encode_kick(member_jid: int) -> PackedByteArray:
	return Writer.new().u32(member_jid).data

## 0x3080 answer to a party invitation: yes [1][1], no [2][u16 code] where
## the code is 0x2c0c for a kind-2 invitation and 0x2c17 for kind 3.
static func encode_answer(request_kind: int, accept: bool) -> PackedByteArray:
	if accept:
		return Writer.new().u8(ANSWER_YES).u8(1).data
	var code := ERR_CREATE_REFUSED if request_kind == REQUEST_FORM else ERR_JOIN_REFUSED
	return Writer.new().u8(ANSWER_NO).u16(code).data

class Answer:
	var accept: bool = false
	var code: int = 0

static func decode_answer(data: PackedByteArray) -> Answer:
	var r := Reader.new(data)
	var a := Answer.new()
	var kind := r.u8()
	if kind == ANSWER_YES:
		r.u8()
		a.accept = true
	else:
		a.code = r.u16()
	return null if r.bad else a

static func decode_create(data: PackedByteArray) -> Array:
	var r := Reader.new(data)
	var target := r.u32()
	var flags := r.u8()
	return [] if r.bad else [target, flags]

static func decode_u32_only(data: PackedByteArray) -> int:
	var r := Reader.new(data)
	var v := r.u32()
	return -1 if r.bad else v

# --- Server -> client ------------------------------------------------------

## 0xb060 / 0xb062 / 0xb067: u8 result; 1: u32 own JID (0xb060, 0xb067 only);
## 2: u16 code. 0xb062 is sent only for errors.
class Ack:
	var ok: bool = false
	var jid: int = 0
	var code: int = 0

static func decode_ack(data: PackedByteArray) -> Ack:
	var r := Reader.new(data)
	var a := Ack.new()
	var result := r.u8()
	if result == 1:
		a.ok = true
		if data.size() >= 5:
			a.jid = r.u32()
	else:
		a.code = r.u16()
	return null if r.bad else a

static func encode_ack_ok(own_jid: int) -> PackedByteArray:
	return Writer.new().u8(1).u32(own_jid).data

static func encode_ack_error(code: int) -> PackedByteArray:
	return Writer.new().u8(2).u16(code).data

## 0x3080 invitation (kinds 2 and 3): u8 kind, u32 inviter world id, u8 flags.
class Invitation:
	var kind: int = 0
	var inviter_id: int = 0
	var flags: int = 0

static func decode_invitation(data: PackedByteArray) -> Invitation:
	var r := Reader.new(data)
	var inv := Invitation.new()
	inv.kind = r.u8()
	inv.inviter_id = r.u32()
	if inv.kind == REQUEST_FORM or inv.kind == REQUEST_JOIN:
		inv.flags = r.u8()
	return null if r.bad else inv

static func encode_invitation(kind: int, inviter_id: int, flags: int) -> PackedByteArray:
	return Writer.new().u8(kind).u32(inviter_id).u8(flags).data

## 0x3065: u8 mask, u32 party id, [mask&1: u32 leader JID, u8 flags],
## [mask&2: u8 count, count records]. The client reads the party id before it
## tests the mask (c:0x883cc0); the server always sends mask 0xff.
class PartyInfo:
	var mask: int = 0
	var party_id: int = 0
	var leader_jid: int = 0
	var flags: int = 0
	var members: Array[Member] = []

static func decode_party_info(data: PackedByteArray) -> PartyInfo:
	var r := Reader.new(data)
	var p := PartyInfo.new()
	p.mask = r.u8()
	p.party_id = r.u32()
	if p.mask & 1:
		p.leader_jid = r.u32()
		p.flags = r.u8()
	if p.mask & 2:
		var count := r.u8()
		for _i in count:
			var m := read_member(r)
			if m == null:
				return null
			p.members.append(m)
	return null if r.bad else p

static func encode_party_info(p: PartyInfo) -> PackedByteArray:
	var w := Writer.new().u8(p.mask).u32(p.party_id)
	if p.mask & 1:
		w.u32(p.leader_jid).u8(p.flags)
	if p.mask & 2:
		w.u8(p.members.size())
		for m in p.members:
			write_member(w, m)
	return w.data

## 0x3864: one party event.
class Event:
	var kind: int = 0
	var code: int = 0          ## kind 1
	var jid: int = 0           ## kinds 3, 6, 9
	var reason: int = 0        ## kind 3
	var member: Member = null  ## kinds 2, 6

static func decode_event(data: PackedByteArray) -> Event:
	var r := Reader.new(data)
	var e := Event.new()
	e.kind = r.u8()
	match e.kind:
		EVENT_DISSOLVED:
			e.code = r.u16()
		EVENT_JOINED:
			e.member = read_member(r)
			if e.member != null:
				e.jid = e.member.jid
		EVENT_LEFT:
			e.jid = r.u32()
			e.reason = r.u8()
		EVENT_UPDATE:
			e.jid = r.u32()
			e.member = read_member(r)
		EVENT_LEADER:
			e.jid = r.u32()
		_:
			# Kinds the client's switch does not handle for the party window
			# (the server-internal 7/8/0xf..0x12 never reach a client).
			pass
	if r.bad or ((e.kind == EVENT_JOINED or e.kind == EVENT_UPDATE) and e.member == null):
		return null
	return e

static func encode_event(e: Event) -> PackedByteArray:
	var w := Writer.new().u8(e.kind)
	match e.kind:
		EVENT_DISSOLVED:
			w.u16(e.code)
		EVENT_JOINED:
			write_member(w, e.member)
		EVENT_LEFT:
			w.u32(e.jid).u8(e.reason)
		EVENT_UPDATE:
			w.u32(e.jid)
			write_member(w, e.member)
		EVENT_LEADER:
			w.u32(e.jid)
	return w.data

## The UIIT key the client shows for `code`, or "" when it has none.
static func error_key(code: int) -> String:
	return String(ERROR_KEYS.get(code, ""))
