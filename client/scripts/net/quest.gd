extends RefCounted
class_name QuestNet

## The quest messages (round 785), the contract in server/internal/quest/
## wire.go. Layouts READ from sro_client.exe's handlers and senders
## (docs/protocol/quests.md, "Messages"); every string is a u16 length and
## its bytes (FUN_004f7a70). Before round 785 this file held OpenSRO's own
## 0x00B0..0x00B4 list/accept/completed messages, which are gone.

## 0x30D5: add (1), change (2) or remove (3, 4) one quest (FUN_008812b0; the
## body FUN_008b94d0).
const OP_UPDATE := 0x30D5
## 0x30D4: an NPC talk page (FUN_00889d90 -> FUN_006fc1c0).
const OP_TALK_PAGE := 0x30D4
## The talk answer {u8 response}. The client builds it with 0x30D4
## (0x7026be..0x702732); the server's handler is index 0x0d4 and OpenSRO's
## server accepts 0x70D4, the request form (npc_gui.md section 8).
const OP_TALK_ANSWER := 0x70D4
## 0x30D6 / 0x30D7: a mark over an object, and its removal.
const OP_MARK := 0x30D6
const OP_UNMARK := 0x30D7
## 0x3514: open the reward window CNIFQuestReward (FUN_00884ca0).
const OP_REWARD_WINDOW := 0x3514
## 0x7515 / 0xB515: take the reward (FUN_008252d0 / FUN_00881570).
const OP_TAKE_REWARD := 0x7515
const OP_TAKE_REWARD_RESULT := 0xB515
## 0x70D9 / 0xB0D9: give a quest up (0x6e4af1 / FUN_008814b0).
const OP_ABANDON := 0x70D9
const OP_ABANDON_RESULT := 0xB0D9
## 0x70D8 / 0xB0D8: the quest window's reward button (FUN_006e4ec0 /
## FUN_00881450).
const OP_CLAIM := 0x70D8
const OP_CLAIM_RESULT := 0xB0D8
## 0x30EC: a quest notice, {string key} (round 819; the server's
## SendQuestEventMessage, s:0x4ed4a0; the client's FUN_00884a30 shows the
## key's text in the quest info notice, 0x77b5b0, and plays snd_quest_end
## for SN_TALK_COMMON_END). READ.
const OP_EVENT_MESSAGE := 0x30EC
## The notice after a paid reward.
const NOTICE_END := "SN_TALK_COMMON_END"
## OURS 0x00B1: the character's quest section at entering the world, in the
## layout retail carries inside its character data (ICPlayer::FUN_009d9830).
const OP_LOG := 0x00B1

## The server-to-client opcodes this file decodes.
const SERVER_OPCODES := [OP_UPDATE, OP_TALK_PAGE, OP_MARK, OP_UNMARK, OP_REWARD_WINDOW,
	OP_TAKE_REWARD_RESULT, OP_ABANDON_RESULT, OP_CLAIM_RESULT, OP_LOG, OP_EVENT_MESSAGE]

## 0x30D5's kinds.
const UPDATE_ADD := 1
const UPDATE_CHANGE := 2
const UPDATE_REMOVE := 3
const UPDATE_DROPPED := 4

## Talk page types (FUN_006fc1c0).
const PAGE_CONFIRM := 1
const PAGE_YES_NO := 3
const PAGE_LIST := 4
const PAGE_LIST_ITEM := 5
## Response ids (READ; define.sct TALK_RESPONSE_LIST_BASE 5).
const RESP_CONFIRM := 1
const RESP_YES := 2
const RESP_NO := 3
const RESP_LIST_BASE := 5

## Mark types (GlobalDataManager::FUN_009c75e0).
const MARK_START := 1
const MARK_GOING := 2
const MARK_END := 3

## QUEST_STATUS_* (the server script's define.sct, READ).
const STATUS_ACHIEVING := 1
const STATUS_ACHIEVED_NOT_PAID := 2
const STATUS_ACHIEVED := 3
const STATUS_ACHIEVING_KILL := 7
const STATUS_ACHIEVED_KILL := 8

## One mission line of a body.
class Mission:
	var index := 0
	## The mission flag: true while under way (UIIT_STT_QUEST_ING), false
	## when done (UIIT_STT_QUEST_END; UI_QUEST::FUN_006e8360).
	var open := true
	## The SN_CON_* objective text id.
	var text := ""
	var values: PackedInt64Array = PackedInt64Array()

## The 0x30D5 body (FUN_008b94d0).
class View:
	## +8: drawn as "%s (%d/%d)", low nibble then high (quest_window.gd).
	var counter := 0
	## +9: the row's colour bar (1 green, 2 red, 3 light green).
	var state := 0
	var flags := 0
	## +0xc when flags & 4: the time limit, -1 for none.
	var time_limit := -1
	## flags & 8: QUEST_STATUS_*.
	var status := 0
	var missions: Array = []
	## flags & 0x40: the NPCs (RefObjIDs) the minimap signs point at.
	var npcs: PackedInt64Array = PackedInt64Array()

## A decoded 0x30D5.
class Update:
	var error := ""
	var kind := 0
	var quest_id := 0
	var view: View = null

## A decoded 0x00B1 log section.
class LogSection:
	var error := ""
	var completed: PackedInt64Array = PackedInt64Array()
	## Of [quest_id: int, View].
	var active: Array = []

## A decoded 0x30D4 page.
class TalkPage:
	var error := ""
	var type := 0
	var text := ""
	var lines: PackedStringArray = PackedStringArray()
	## Type 5's tail (INFERRED: an item codename and a count).
	var item := ""
	var count := 0

## A decoded 0x30D6.
class Mark:
	var object_id := 0
	var flags := 0
	var mark_type := 0
	var region := 0
	var position := Vector3.ZERO
	var extra := 0

## A byte cursor; `ok` drops to false on the first short read.
class Cursor:
	var data: PackedByteArray
	var at := 0
	var ok := true
	func _init(d: PackedByteArray) -> void:
		data = d
	func need(n: int) -> bool:
		if not ok or at + n > data.size():
			ok = false
			return false
		return true
	func u8() -> int:
		if not need(1):
			return 0
		at += 1
		return data[at - 1]
	func u16() -> int:
		if not need(2):
			return 0
		at += 2
		return data.decode_u16(at - 2)
	func u32() -> int:
		if not need(4):
			return 0
		at += 4
		return data.decode_u32(at - 4)
	func f32() -> float:
		if not need(4):
			return 0.0
		at += 4
		return data.decode_float(at - 4)
	func read_string() -> String:
		var n := u16()
		if not need(n):
			return ""
		at += n
		return data.slice(at - n, at).get_string_from_utf8()

static func _read_view(c: Cursor) -> View:
	var v := View.new()
	v.counter = c.u8()
	v.state = c.u8()
	v.flags = c.u8()
	if v.flags & 4:
		v.time_limit = c.u32()
		if v.time_limit == 0xffffffff:
			v.time_limit = -1
	if v.flags & 8:
		v.status = c.u8()
	if v.flags & 0x10:
		var n := c.u8()
		for i in n:
			if not c.ok:
				break
			var m := Mission.new()
			m.index = c.u8()
			m.open = c.u8() != 0
			m.text = c.read_string()
			var k := c.u8()
			for j in k:
				m.values.append(c.u32())
			v.missions.append(m)
	if v.flags & 0x40:
		var n := c.u8()
		for i in n:
			v.npcs.append(c.u32())
	return v

## Decodes 0x30D5.
static func decode_update(data: PackedByteArray) -> Update:
	var u := Update.new()
	var c := Cursor.new(data)
	u.kind = c.u8()
	u.quest_id = c.u32()
	if c.ok and (u.kind == UPDATE_ADD or u.kind == UPDATE_CHANGE):
		u.view = _read_view(c)
	if not c.ok:
		u.error = "truncated"
	return u

## Decodes the 0x00B1 log section.
static func decode_log(data: PackedByteArray) -> LogSection:
	var l := LogSection.new()
	var c := Cursor.new(data)
	var n := c.u16()
	for i in n:
		if not c.ok:
			break
		l.completed.append(c.u32())
	var k := c.u8()
	for i in k:
		if not c.ok:
			break
		var id := c.u32()
		var v := _read_view(c)
		l.active.append([id, v])
	c.u8() # the marks count: 0 (marks go as 0x30D6)
	if not c.ok:
		l.error = "truncated"
	return l

## Decodes 0x30D4.
static func decode_talk_page(data: PackedByteArray) -> TalkPage:
	var p := TalkPage.new()
	var c := Cursor.new(data)
	p.type = c.u8()
	p.text = c.read_string()
	if p.type == PAGE_LIST or p.type == PAGE_LIST_ITEM:
		var n := c.u8()
		for i in n:
			p.lines.append(c.read_string())
		if p.type == PAGE_LIST_ITEM:
			p.item = c.read_string()
			p.count = c.u32()
	if not c.ok:
		p.error = "truncated"
	return p

## Decodes 0x30D6; null when short.
static func decode_mark(data: PackedByteArray) -> Mark:
	var c := Cursor.new(data)
	var m := Mark.new()
	m.object_id = c.u32()
	m.flags = c.u8()
	m.mark_type = c.u8()
	m.region = c.u16()
	m.position = Vector3(c.f32(), c.f32(), c.f32())
	if m.flags & 2:
		m.extra = c.u32()
	return m if c.ok else null

## Decodes 0x30D7: the object id, or -1.
static func decode_unmark(data: PackedByteArray) -> int:
	return data.decode_u32(0) if data.size() >= 4 else -1

## Decodes 0x3514: {quest_id, text}, {} when short.
## Decodes 0x30EC: the notice's key, or "" for a malformed one.
static func decode_event_message(data: PackedByteArray) -> String:
	var c := Cursor.new(data)
	var key := c.read_string()
	return key if c.ok else ""

static func decode_reward_window(data: PackedByteArray) -> Dictionary:
	var c := Cursor.new(data)
	var id := c.u32()
	var n := c.u8()
	var extra := PackedByteArray()
	for i in n:
		extra.append(c.u8())
	var text := c.read_string()
	if not c.ok:
		return {}
	return {"quest_id": id, "text": text}

## Decodes 0xB515: {ok, error}.
static func decode_take_reward_result(data: PackedByteArray) -> Dictionary:
	if data.is_empty():
		return {"ok": false, "error": -1}
	if data[0] == 1:
		return {"ok": true, "error": 0}
	return {"ok": false, "error": data[1] if data.size() >= 2 else -1}

## Decodes 0xB0D9 ({u8 1, u32 id} or {u8 2, u8 code}) and 0xB0D8 ({u8 1,
## u32 id} or {u8 2, u16 code}): {ok, quest_id, error}.
static func decode_id_result(data: PackedByteArray, wide_error: bool) -> Dictionary:
	if data.size() >= 5 and data[0] == 1:
		return {"ok": true, "quest_id": data.decode_u32(1), "error": 0}
	var code := -1
	if wide_error and data.size() >= 3:
		code = data.decode_u16(1)
	elif not wide_error and data.size() >= 2:
		code = data[1]
	return {"ok": false, "quest_id": 0, "error": code}

## 0x70D4 {u8 response}.
static func encode_talk_answer(response: int) -> PackedByteArray:
	return PackedByteArray([response & 0xff])

static func _u32(v: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_u32(0, v)
	return b

## 0x7515 {u32 quest, u8 n, n x u32 chosen}.
static func encode_take_reward(quest_id: int, chosen: Array = []) -> PackedByteArray:
	var b := _u32(quest_id)
	b.append(chosen.size() & 0xff)
	for id in chosen:
		b.append_array(_u32(int(id)))
	return b

## 0x70D9 / 0x70D8 {u32 quest}.
static func encode_quest_id(quest_id: int) -> PackedByteArray:
	return _u32(quest_id)

# --- Encoders for the server's side, for tests and the QA feed ---------------

static func _str(s: String) -> PackedByteArray:
	var bytes := s.to_utf8_buffer()
	var b := PackedByteArray()
	b.resize(2)
	b.encode_u16(0, bytes.size())
	b.append_array(bytes)
	return b

## A body as the server writes it (wire.go EncodeBody).
static func encode_view(v: View) -> PackedByteArray:
	var b := PackedByteArray([v.counter & 0xff, v.state & 0xff, 0x08 | 0x10 | 0x40, v.status & 0xff])
	b.append(v.missions.size())
	for m in v.missions:
		b.append((m as Mission).index)
		b.append(1 if (m as Mission).open else 0)
		b.append_array(_str((m as Mission).text))
		b.append((m as Mission).values.size())
		for x in (m as Mission).values:
			b.append_array(_u32(int(x)))
	b.append(v.npcs.size())
	for n in v.npcs:
		b.append_array(_u32(int(n)))
	return b

static func encode_update(kind: int, quest_id: int, v: View = null) -> PackedByteArray:
	var b := PackedByteArray([kind])
	b.append_array(_u32(quest_id))
	if v != null and (kind == UPDATE_ADD or kind == UPDATE_CHANGE):
		b.append_array(encode_view(v))
	return b

static func encode_talk_page(type: int, text: String, lines: PackedStringArray = PackedStringArray()) -> PackedByteArray:
	var b := PackedByteArray([type])
	b.append_array(_str(text))
	if type == PAGE_LIST or type == PAGE_LIST_ITEM:
		b.append(lines.size())
		for l in lines:
			b.append_array(_str(l))
	return b

## The %d in an objective text replaced by its value, as the client's
## swprintf(fmt, value) does with one value (MEASURED: textquest_queststring's
## objective texts hold one %d, the current count; the target is in the text).
static func format_objective(fmt: String, values: PackedInt64Array) -> String:
	if values.is_empty():
		return fmt
	var out := fmt
	for v in values:
		var at := out.find("%d")
		if at < 0:
			break
		out = out.substr(0, at) + str(v) + out.substr(at + 2)
	return out
