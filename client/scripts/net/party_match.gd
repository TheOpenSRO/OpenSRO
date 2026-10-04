extends RefCounted
class_name PartyMatchNet

## The party-matching messages and the client's matching state (round 714,
## lane C2 of the party epic). Layouts are docs/protocol/party_protocol.md's
## (round 709), READ in the client's parsers and senders (`c:`) and the
## server package (`gs:` / `sm:`), and the same bytes as the golden fixtures
## in client/scripts/net/fixtures/party/ (round 710's README). The window
## rules are party_gui.md §3-§5.
##
## The opcodes are registered through NetClient.register_handler (round 711's
## hook), so net_client.gd routes nothing of this itself.

const OP_REGISTER := 0x7069        ## C->S entry (c:0x823d30 -> 0x823c20)
const OP_REGISTER_ACK := 0xb069    ## S->C u8 result; 1: entry; 2: u16 code (c:0x883f90)
const OP_MODIFY := 0x706a          ## C->S entry (c:0x823df0)
const OP_MODIFY_ACK := 0xb06a      ## S->C as 0xb069 (c:0x8840d0)
const OP_DELETE := 0x706b          ## C->S u32 entry number (c:0x81cfd0)
const OP_DELETE_ACK := 0xb06b      ## S->C u8 result; 1: u32 number; 2: u16 code (c:0x8801e0)
const OP_PAGE := 0x706c            ## C->S u8 page (c:0x81d090)
const OP_PAGE_ACK := 0xb06c        ## S->C u8 result; 1: u8 pages, u8 index, u8 n, rows; 2: u16 code (c:0x8841f0)
const OP_JOIN := 0x706d            ## C->S u32 entry number (c:0x81d150); S->C the leader's request (c:0x884660)
const OP_JOIN_ANSWER := 0x306e     ## C->S u32 job id, u32 requester JID, u8 answer (c:0x81d210)
const OP_JOIN_ACK := 0xb06d        ## S->C u8 result; 1: u16 outcome; 2: u16 code (c:0x8847d0)

const SERVER_OPCODES := [OP_REGISTER_ACK, OP_MODIFY_ACK, OP_DELETE_ACK, OP_PAGE_ACK, OP_JOIN, OP_JOIN_ACK]

## Purposes, the entry's u8 (party_protocol.md "Party-match entry"): the
## objective radio's index, unmapped. "All" (4) is only a search-combo index.
const PURPOSE_HUNTING := 0
const PURPOSE_QUEST := 1
const PURPOSE_TRADE := 2
const PURPOSE_THIEF := 3
const PURPOSE_ALL := 4

## 0x306e answers (callers c:0x73fc68 push 1, 0x73fca6 push 0, 0x73fb8d push 2).
const ANSWER_CANCEL := 0
const ANSWER_CONFIRM := 1
const ANSWER_CLOSED := 2

## 0xb06d [1] outcomes (c:0x8847d0's strings).
const OUTCOME_REFUSED := 0         ## UIIT_MSG_PARTYERR_CREATE_PARTY_REFUSED
const OUTCOME_JOINED := 1          ## UIIT_MSG_PARTYMATCH_JOIN_COMPLETE_MASTER
const OUTCOME_NOREPLY := 2         ## UIIT_MSG_PARTYMATCH_JOIN_NOREPLY

## Level bounds of the search and register edits (c:0x73fa45 / 0x73fa50:
## 1..0x6e; defaults "1" and "110").
const LEVEL_MIN := 1
const LEVEL_MAX := 110

## One party-match entry, the register/modify payload and its echo.
class Entry:
	var number: int = 0
	var party_id: int = 0
	var flags: int = 0
	var purpose: int = 0
	var min_level: int = LEVEL_MIN
	var max_level: int = LEVEL_MAX
	var title: String = ""

## One row of a list page (sm:0x44f640 writes, c:0x8841f0 reads, in this
## order): the client stores race at +8, members +9, purpose +0xa, flags
## +0xb, levels +0xc/+0xd.
class Row:
	var number: int = 0
	## entry+0x30, `_time32` seconds at register/change (round 713 review,
	## READ); the client's use of it is not read.
	var time: int = 0
	var leader_name: String = ""
	var race: int = 0
	var members: int = 1
	var flags: int = 0
	var purpose: int = 0
	var min_level: int = LEVEL_MIN
	var max_level: int = LEVEL_MAX
	var title: String = ""

	## The cap the Member column divides by: bit 0 set -> 8, clear -> 4
	## (c:0x740d30, `%d/8` / `%d/4`).
	func cap() -> int:
		return PartyNet.CAP_EXP_SHARED if flags & PartyNet.FLAG_EXP_SHARE else PartyNet.CAP_NOT_SHARED

class Page:
	var ok: bool = false
	var code: int = 0
	var page_count: int = 0
	var page_index: int = 0
	var rows: Array[Row] = []

## The leader's join request (S->C 0x706d, c:0x884660 reads 4, 4, 4, 4, 4,
## 1, then the member record with mask 0xff).
class JoinRequest:
	var job_id: int = 0
	var requester_jid: int = 0
	var entry: int = 0
	var mastery1: int = 0
	var mastery2: int = 0
	var job_state: int = PartyNet.JOB_NONE
	var member: PartyNet.Member = null

## A u8-result reply: ok + payload, or a u16 code.
class Result:
	var ok: bool = false
	var code: int = 0
	var entry: Entry = null
	var number: int = 0
	var outcome: int = 0

# --- Codecs ------------------------------------------------------------------

static func write_entry(w: PartyNet.Writer, e: Entry) -> void:
	w.u32(e.number).u32(e.party_id).u8(e.flags).u8(e.purpose).u8(e.min_level).u8(e.max_level).text(e.title)

static func read_entry(r: PartyNet.Reader) -> Entry:
	var e := Entry.new()
	e.number = r.u32()
	e.party_id = r.u32()
	e.flags = r.u8()
	e.purpose = r.u8()
	e.min_level = r.u8()
	e.max_level = r.u8()
	e.title = r.string()
	return null if r.bad else e

static func encode_entry(e: Entry) -> PackedByteArray:
	var w := PartyNet.Writer.new()
	write_entry(w, e)
	return w.data

static func encode_delete(number: int) -> PackedByteArray:
	return PartyNet.Writer.new().u32(number).data

static func encode_page(page: int) -> PackedByteArray:
	return PartyNet.Writer.new().u8(page).data

static func encode_join(number: int) -> PackedByteArray:
	return PartyNet.Writer.new().u32(number).data

static func encode_answer(job_id: int, requester_jid: int, answer: int) -> PackedByteArray:
	return PartyNet.Writer.new().u32(job_id).u32(requester_jid).u8(answer).data

## 0xb069 / 0xb06a. Every reply decoder returns null for a result byte other
## than 1 or 2: the client's handlers test `== 1`, then `== 2`, and do nothing
## else (`c:0x883f90`, `0x8841f0`, `0x8801e0`, `0x8847d0`; review M1).
static func decode_entry_result(data: PackedByteArray) -> Result:
	var r := PartyNet.Reader.new(data)
	var res := Result.new()
	var kind := r.u8()
	if kind == 1:
		res.entry = read_entry(r)
		res.ok = res.entry != null
	elif kind == 2:
		res.code = r.u16()
	else:
		return null
	return null if r.bad else res

## 0xb06b.
static func decode_delete_result(data: PackedByteArray) -> Result:
	var r := PartyNet.Reader.new(data)
	var res := Result.new()
	var kind := r.u8()
	if kind == 1:
		res.ok = true
		res.number = r.u32()
	elif kind == 2:
		res.code = r.u16()
	else:
		return null
	return null if r.bad else res

## 0xb06d to the requester (and the leader on success).
static func decode_join_result(data: PackedByteArray) -> Result:
	var r := PartyNet.Reader.new(data)
	var res := Result.new()
	var kind := r.u8()
	if kind == 1:
		res.ok = true
		res.outcome = r.u16()
	elif kind == 2:
		res.code = r.u16()
	else:
		return null
	return null if r.bad else res

static func read_row(r: PartyNet.Reader) -> Row:
	var row := Row.new()
	row.number = r.u32()
	row.time = r.u32()
	row.leader_name = r.string()
	row.race = r.u8()
	row.members = r.u8()
	row.flags = r.u8()
	row.purpose = r.u8()
	row.min_level = r.u8()
	row.max_level = r.u8()
	row.title = r.string()
	return null if r.bad else row

static func write_row(w: PartyNet.Writer, row: Row) -> void:
	w.u32(row.number).u32(row.time).text(row.leader_name).u8(row.race).u8(row.members)
	w.u8(row.flags).u8(row.purpose).u8(row.min_level).u8(row.max_level).text(row.title)

## 0xb06c: [1][u8 pages][u8 index][u8 n] + n rows, or [2][u16 code]. The
## client reads the page count first, then the index (c:0x8841f0: the first
## read goes to +5 and the second to +4 through 0x97b930(index, count)).
static func decode_page(data: PackedByteArray) -> Page:
	var r := PartyNet.Reader.new(data)
	var p := Page.new()
	var kind := r.u8()
	if kind == 1:
		p.ok = true
		p.page_count = r.u8()
		p.page_index = r.u8()
		var n := r.u8()
		for i in n:
			var row := read_row(r)
			if row == null:
				return null
			p.rows.append(row)
	elif kind == 2:
		p.code = r.u16()
	else:
		return null
	return null if r.bad else p

static func encode_page_ack(p: Page) -> PackedByteArray:
	var w := PartyNet.Writer.new()
	if not p.ok:
		return w.u8(2).u16(p.code).data
	w.u8(1).u8(p.page_count).u8(p.page_index).u8(p.rows.size())
	for row in p.rows:
		write_row(w, row)
	return w.data

## S->C 0x706d.
static func decode_join_request(data: PackedByteArray) -> JoinRequest:
	var r := PartyNet.Reader.new(data)
	var q := JoinRequest.new()
	q.job_id = r.u32()
	q.requester_jid = r.u32()
	q.entry = r.u32()
	q.mastery1 = r.u32()
	q.mastery2 = r.u32()
	q.job_state = r.u8()
	q.member = PartyNet.read_member(r)
	return null if r.bad or q.member == null else q

static func encode_join_request(q: JoinRequest) -> PackedByteArray:
	var w := PartyNet.Writer.new()
	w.u32(q.job_id).u32(q.requester_jid).u32(q.entry).u32(q.mastery1).u32(q.mastery2).u8(q.job_state)
	PartyNet.write_member(w, q.member)
	return w.data

# --- Rules the window applies (party_gui.md §3) ------------------------------

## The Name column: `*%s` when the purpose is Trade or Thief (a job alias,
## c:0x740d30).
static func shown_name(row: Row) -> String:
	if row.purpose == PURPOSE_TRADE or row.purpose == PURPOSE_THIEF:
		return "*" + row.leader_name
	return row.leader_name

## Search (c:0x73b780): an exact, case-sensitive whole-name match when `name`
## is not empty (0x47ec20), the purpose unless All, and the level ranges
## overlapping.
static func row_matches(row: Row, name: String, purpose: int, lo: int, hi: int) -> bool:
	if name != "" and row.leader_name != name:
		return false
	if purpose != PURPOSE_ALL and row.purpose != purpose:
		return false
	return row.min_level <= hi and row.max_level >= lo

## The objective radio's items the player's job allows (c:0x73f957..0x73fa14,
## the job byte 1 trader / 2 thief / 3 hunter / 4 none) and the one chosen.
static func allowed_purposes(job: int) -> Array[int]:
	if job == 1 or job == 3:
		return [PURPOSE_TRADE]
	if job == 2:
		return [PURPOSE_THIEF]
	return [PURPOSE_HUNTING, PURPOSE_QUEST]

## Auto match's candidate test (c:0x73ebc0): the purpose equal, the race equal
## unless Open (race_choice 2), the flags equal, the player's level inside
## the range. `flags` already carries the player's own "anyone" bit.
static func auto_candidate(row: Row, purpose: int, race_choice: int, flags: int, level: int) -> bool:
	if row.purpose != purpose:
		return false
	if race_choice != 2 and row.race != race_choice:
		return false
	if row.flags != flags:
		return false
	return level >= row.min_level and level <= row.max_level

## The default titles by objective (c:0x73f610): Hunting DEFAULT1, Quest
## DEFAULT3, Trade DEFAULT2, Thief DEFAULT4.
const DEFAULT_TITLE_KEYS := ["UIIT_MSG_PARTYMATCH_RECORD_DEFAULT1", "UIIT_MSG_PARTYMATCH_RECORD_DEFAULT3",
	"UIIT_MSG_PARTYMATCH_RECORD_DEFAULT2", "UIIT_MSG_PARTYMATCH_RECORD_DEFAULT4"]

## The objective labels (the radio's and the list's Purpose column, c:0x740910).
const PURPOSE_KEYS := ["UIIT_CTL_PARTYMATCH_PSEARCH_OBJECTCOMBAT", "UIIT_STT_QUEST",
	"UIIT_CTL_PARTYMATCH_PSEARCH_FIND_OBJECTTRADER", "UIIT_CTL_PARTYMATCH_PSEARCH_FIND_OBJECTTHIEF",
	"UIIT_CTL_PARTYMATCH_PSEARCH_OBJECTALL"]
const PURPOSE_FALLBACKS := ["Hunting", "Quest", "Trade Union", "Thief Union", "All"]
## Race text, the Race column and the popup (USER DECISION 2026-10-03: text,
## as this exe draws it).
const RACE_KEYS := ["UIIT_CTL_PARTYMATCH_AUTOMATCH_RACE_CH", "UIIT_CTL_PARTYMATCH_AUTOMATCH_RACE_EU"]
const RACE_FALLBACKS := ["CHN", "EUR"]
