extends RefCounted
class_name GuildPart2Net

## Round 844 lane G (part 2): the master-release vote, the GP usage history
## and the guild recall, as sro_client.exe sends and reads them (the
## server's side is session/guildvote.go, guildgphistory.go, guildrecall.go;
## docs/protocol/guild.md). READ unless a line says otherwise.
##
## The vote (c:0x8897c0, 0x8857b0, 0x881d00, 0x881d80):
## - 0x7105 {u32 NPC} (line 0x19's box, c:0x81ff50) -> B105 {1}
##   (UIIT_MSG_MRELEASE_VOTING in a UIIT_STT_EVENTGUIDE box) | {2, 0x4c33}
##   (UIIT_MSG_MRELEASEERR_NOTVOTETIME) | {2, other} (category 0x10).
## - 0x7106 {u32 vote} (line 0x1a with no state yet, c:0x820010) -> B106
##   {1, u32 vote, u32 ms left, u8 n, n x {u32 character, u8 votes}} | {2,
##   code} (category 0x15: 0x5006 nothing, 0x5008 UIIT_MSG_MRELEASEERR_NOTVOTING).
## - 0x7107 {u32 NPC, u32 vote, u8 index} (the window's OK, c:0x8200d0) ->
##   B107 {2, code} only.
## - 0x3908: kind 1 {u32 vote, u8 kind, u32 ms} started; 3 {u32 vote, u8
##   result, [u32 winner]} ended (1 UIIT_MSG_MRELEASE_BEELETED with the guild
##   and the winner, 2 UIIT_MSG_MRELEASE_BROKEN); 4 {u32 vote, u8 old index
##   (0xff none), u8 new index, u8 new count}; 5 {u32 vote, u32 ms}.
## The GP history: 0x7501 {u32 NPC} -> B501 {1, u8 n, n x {u32 time_t, str
## name, u32 GP, u8 kind}} (c:0x885c20).
## The recall: 0x7030 {u32 job, u32 caster, u32 seconds} (c:0x88d840) ->
## 0x7031 {u32 job, u32 caster, u8 yes} (c:0x81d610) -> B031 {1} | {2, code}
## (c:0x88d910).

const OP_VOTE_START := 0x7105
const OP_VOTE_START_RESULT := 0xB105
const OP_VOTE_STATE := 0x7106
const OP_VOTE_STATE_RESULT := 0xB106
const OP_VOTE_BALLOT := 0x7107
const OP_VOTE_BALLOT_RESULT := 0xB107
const OP_VOTE_UPDATE := 0x3908
const OP_GP_HISTORY := 0x7501
const OP_GP_HISTORY_RESULT := 0xB501
const OP_RECALL_ASK := 0x7030
const OP_RECALL_ANSWER := 0x7031
const OP_RECALL_ANSWER_RESULT := 0xB031

const SERVER_OPCODES := [OP_VOTE_START_RESULT, OP_VOTE_STATE_RESULT, OP_VOTE_BALLOT_RESULT, OP_VOTE_UPDATE,
	OP_GP_HISTORY_RESULT, OP_RECALL_ASK, OP_RECALL_ANSWER_RESULT]

const CODE_VOTE_NOT_TIME := 0x4c33
const CODE_VOTE_NOT_VOTER := 0x5008

## The history's kinds, in the window's order (c:0x5b9d70, READ).
const GP_KIND_KEYS := ["UIIT_STT_FORTRESS_BUFF", "UIIT_STT_FORTRESS_GP_HISTORY_STRUCTURE",
	"UIIT_STT_FORTRESS_GP_HISTORY_NPC_EMPLOYMENT", "UIIT_STT_FORTRESS_GP_HISTORY_GUARD_EMPLOYMENT",
	"UIIT_STT_FORTRESS_GP_HISTORY_FORTRESS_ITEM_CREATE", "UIIT_STT_FORTRESS_GP_HISTORY_GROWTH",
	"UIIT_STT_FORTRESS_GP_HISTORY_GUILD_ITEM_BUY", "UIIT_STT_FORTRESS_GP_HISTORY_DUNGEON",
	"UIIT_STT_FORTRESS_GP_HISTORY_ETC"]
## OURS fallbacks, the agent's reading of the English texts.
const GP_KIND_FALLBACK := ["Fortress War Blessing Buff", "Fortress Structures", "Fortress NPC Employment",
	"Fortress Guard Employment", "Fortress Items Production", "Guild Growth", "Guild Item Purchases",
	"Cave of Discipline (Fortress Instance Dungeon)", "Misc."]

## A line or a box for the owner to show: [where, key, args]; where is
## "line" (the system window), "box" (a UIIT_STT_EVENTGUIDE box) or "code"
## (a refusal code, category 0x10 / 0x15).
signal shown(where: String, key: String, args: Array)
## B106: the vote's state is in; the owner opens the election window.
signal vote_state_loaded
## The vote started, changed or ended (the talk menu and the window follow).
signal vote_changed
## B501: the history arrived.
signal gp_history(entries: Array)
## 0x7030: a recall question.
signal recall_asked(job: int, caster: int, seconds: int)
## B031 {1} after a yes: the gauge.
signal recall_accepted(seconds: int)

## The known vote (kind 0): its id (0 none), whether its state is loaded,
## the time left (ms), the list's characters and their counts.
var vote_id := 0
var vote_loaded := false
var vote_ms := 0
var vote_list: Array[int] = []
var vote_counts: Array[int] = []
## The last question's seconds, for the gauge after B031.
var recall_seconds := 0
var _recall_answered_yes := false

static func _u32(v: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_u32(0, v)
	return b

static func encode_vote_start(npc: int) -> PackedByteArray:
	return _u32(npc)

static func encode_vote_state(vote: int) -> PackedByteArray:
	return _u32(vote)

static func encode_ballot(npc: int, vote: int, index: int) -> PackedByteArray:
	var b := _u32(npc)
	b.append_array(_u32(vote))
	b.append(index & 0xff)
	return b

static func encode_gp_history(npc: int) -> PackedByteArray:
	return _u32(npc)

func encode_recall_answer(job: int, caster: int, yes: bool) -> PackedByteArray:
	_recall_answered_yes = yes
	var b := _u32(job)
	b.append_array(_u32(caster))
	b.append(1 if yes else 0)
	return b

## The guild block's trailing list (FUN_0099d7e0): [[id, kind, ms], ...].
func set_from_block(votes: Array) -> void:
	var had := vote_id
	vote_id = 0
	for v in votes:
		if int(v[1]) == 0:
			if vote_id != int(v[0]):
				vote_loaded = false
			vote_id = int(v[0])
			vote_ms = int(v[2])
	if vote_id == 0:
		_clear()
	if had != vote_id:
		vote_changed.emit()

func _clear() -> void:
	vote_id = 0
	vote_loaded = false
	vote_ms = 0
	vote_list.clear()
	vote_counts.clear()

func handle(op: int, data: PackedByteArray) -> void:
	match op:
		OP_VOTE_START_RESULT:
			if data.size() >= 1 and data[0] == 1:
				shown.emit("box", "UIIT_MSG_MRELEASE_VOTING", [])
			elif data.size() >= 3 and data[0] == 2:
				var code := data.decode_u16(1)
				if code == CODE_VOTE_NOT_TIME:
					shown.emit("box", "UIIT_MSG_MRELEASEERR_NOTVOTETIME", [])
				else:
					shown.emit("code", "", [code, 0x10])
		OP_VOTE_STATE_RESULT:
			_state(data)
		OP_VOTE_BALLOT_RESULT:
			if data.size() >= 3 and data[0] == 2:
				_cat15(data.decode_u16(1))
		OP_VOTE_UPDATE:
			_update(data)
		OP_GP_HISTORY_RESULT:
			_history(data)
		OP_RECALL_ASK:
			if data.size() >= 12:
				recall_seconds = data.decode_u32(8)
				recall_asked.emit(data.decode_u32(0), data.decode_u32(4), recall_seconds)
		OP_RECALL_ANSWER_RESULT:
			if data.size() >= 1 and data[0] == 1:
				if _recall_answered_yes:
					recall_accepted.emit(recall_seconds)
				_recall_answered_yes = false
			elif data.size() >= 3:
				shown.emit("code", "", [data.decode_u16(1), 1])

func _cat15(code: int) -> void:
	if code == CODE_VOTE_NOT_VOTER:
		shown.emit("line", "UIIT_MSG_MRELEASEERR_NOTVOTING", [])

func _state(data: PackedByteArray) -> void:
	if data.size() >= 3 and data[0] == 2:
		_cat15(data.decode_u16(1))
		return
	if data.size() < 10 or data[0] != 1:
		return
	vote_id = data.decode_u32(1)
	vote_ms = data.decode_u32(5)
	var n := data[9]
	vote_list.clear()
	vote_counts.clear()
	var at := 10
	for i in n:
		if at + 5 > data.size():
			return
		vote_list.append(data.decode_u32(at))
		vote_counts.append(data[at + 4])
		at += 5
	vote_loaded = true
	vote_state_loaded.emit()

func _update(data: PackedByteArray) -> void:
	if data.size() < 5:
		return
	var kind := data[0]
	var id := data.decode_u32(1)
	match kind:
		1:
			if data.size() >= 10 and data[5] == 0:
				vote_id = id
				vote_loaded = false
				vote_ms = data.decode_u32(6)
				vote_changed.emit()
		3:
			if data.size() < 6 or id != vote_id:
				return
			var result := data[5]
			var winner := data.decode_u32(6) if data.size() >= 10 else 0
			_clear()
			if result == 1:
				shown.emit("box", "UIIT_MSG_MRELEASE_BEELETED", [winner])
			elif result == 2:
				shown.emit("box", "UIIT_MSG_MRELEASE_BROKEN", [])
			vote_changed.emit()
		4:
			# Only once the state is loaded (READ).
			if data.size() < 8 or id != vote_id or not vote_loaded:
				return
			var old := data[5]
			var idx := data[6]
			if old != 0xff and old < vote_counts.size():
				vote_counts[old] = maxi(0, vote_counts[old] - 1)
			if idx < vote_counts.size():
				vote_counts[idx] = data[7]
			vote_changed.emit()
		5:
			if data.size() >= 9 and id == vote_id:
				vote_ms = data.decode_u32(5)
				vote_changed.emit()

func _history(data: PackedByteArray) -> void:
	if data.size() >= 3 and data[0] == 2:
		shown.emit("code", "", [data.decode_u16(1), 0x10])
		return
	if data.size() < 2 or data[0] != 1:
		return
	var n := data[1]
	var at := 2
	var out: Array = []
	for i in n:
		if at + 6 > data.size():
			break
		var t := data.decode_u32(at)
		var ln := data.decode_u16(at + 4)
		at += 6
		if at + ln + 5 > data.size():
			break
		var who := data.slice(at, at + ln).get_string_from_utf8()
		at += ln
		var gp := data.decode_u32(at)
		var k := data[at + 4]
		at += 5
		out.append({"time": t, "name": who, "gp": gp, "kind": k})
	gp_history.emit(out)
