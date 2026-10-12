extends RefCounted
class_name QuestState

## The client's quest log (round 785): what the quest manager
## (`[0xeef5ec]+0x20d0`) holds -- the live quests at +0x28 and the finished
## ids at +0x38 (quest_window.gd's header, READ) -- fed by the login section
## (QuestNet.OP_LOG) and 0x30D5, plus the marks the server put over objects
## (0x30D6/0x30D7) and the quest the player tracks (DAT_00eeae70, set by a
## quest window selection, FUN_006e51e0, INFERRED the row click).

signal log_changed()
## One quest added, changed or removed (QuestNet.Update).
signal quest_updated(update: QuestNet.Update)
## An open mission's count changed on a change message: the progress notice
## (GDR_UPDATE_QUEST_INFO, READ: shown when the mission flag is non-zero and
## its formatted text changes on an existing quest).
signal mission_progress(quest_id: int, mission: QuestNet.Mission)
signal talk_page(page: QuestNet.TalkPage)
signal reward_window(quest_id: int, text: String)
signal reward_result(ok: bool, error: int)
signal abandon_result(ok: bool, quest_id: int, error: int)
signal claim_result(ok: bool, quest_id: int, error: int)
signal marks_changed()
## A message that moves items in or out of the bag server-side (an add, a
## removal, a reward taken): the inventory should be asked for again.
signal bag_may_have_changed()

## quest id -> QuestNet.View, in arrival order (order).
var active: Dictionary = {}
var order: Array = []
var completed: Dictionary = {}
## object id -> QuestNet.Mark.
var marks: Dictionary = {}
## The tracked quest, 0 for none.
var tracked := 0
var has_log := false
## How messages leave (op, payload); NetClient sets it.
var send: Callable

func reset() -> void:
	active.clear()
	order.clear()
	completed.clear()
	marks.clear()
	tracked = 0
	has_log = false

func register_with(net: Node) -> void:
	for op in QuestNet.SERVER_OPCODES:
		net.register_handler(op, handle.bind(op))

func _send(op: int, payload: PackedByteArray) -> void:
	if send.is_valid():
		send.call(op, payload)

## The talk answer (0x70D4).
func answer(response: int) -> void:
	_send(QuestNet.OP_TALK_ANSWER, QuestNet.encode_talk_answer(response))

## Take the reward (0x7515), with the chosen item ids (none: all).
func take_reward(quest_id: int, chosen: Array = []) -> void:
	_send(QuestNet.OP_TAKE_REWARD, QuestNet.encode_take_reward(quest_id, chosen))

## Give the quest up (0x70D9).
func abandon(quest_id: int) -> void:
	_send(QuestNet.OP_ABANDON, QuestNet.encode_quest_id(quest_id))

## The quest window's reward button (0x70D8).
func claim(quest_id: int) -> void:
	_send(QuestNet.OP_CLAIM, QuestNet.encode_quest_id(quest_id))

func view_of(quest_id: int) -> QuestNet.View:
	return active.get(quest_id) as QuestNet.View

## The live quests as [id, View] pairs, in arrival order (0x8ba1f0 pushes to
## the back, READ).
func entries() -> Array:
	var out: Array = []
	for id in order:
		if active.has(id):
			out.append([id, active[id]])
	return out

func set_tracked(quest_id: int) -> void:
	if tracked == quest_id:
		return
	tracked = quest_id
	marks_changed.emit()

## The NPC RefObjIDs of the tracked quest (the minimap's signs, READ:
## CIFMinimap::vslot_013 draws only the tracked quest's list).
func tracked_npcs() -> PackedInt64Array:
	var v := view_of(tracked)
	return v.npcs if v != null else PackedInt64Array()

func handle(data: PackedByteArray, op: int) -> void:
	match op:
		QuestNet.OP_LOG:
			var l := QuestNet.decode_log(data)
			if l.error != "":
				print("Quest: malformed log (%d bytes)" % data.size())
				return
			reset()
			for id in l.completed:
				completed[int(id)] = true
			for pair in l.active:
				_put(int(pair[0]), pair[1])
			has_log = true
			print("Quest: log -- %d active, %d completed" % [active.size(), completed.size()])
			log_changed.emit()
		QuestNet.OP_UPDATE:
			var u := QuestNet.decode_update(data)
			if u.error != "":
				print("Quest: malformed 0x30d5 (%d bytes)" % data.size())
				return
			apply_update(u)
		QuestNet.OP_TALK_PAGE:
			var p := QuestNet.decode_talk_page(data)
			if p.error != "":
				print("Quest: malformed talk page (%d bytes)" % data.size())
				return
			talk_page.emit(p)
		QuestNet.OP_MARK:
			var m := QuestNet.decode_mark(data)
			if m == null:
				return
			marks[m.object_id] = m
			marks_changed.emit()
		QuestNet.OP_UNMARK:
			var id := QuestNet.decode_unmark(data)
			if id >= 0 and marks.erase(id):
				marks_changed.emit()
		QuestNet.OP_REWARD_WINDOW:
			var r := QuestNet.decode_reward_window(data)
			if not r.is_empty():
				reward_window.emit(int(r["quest_id"]), str(r["text"]))
		QuestNet.OP_TAKE_REWARD_RESULT:
			var r := QuestNet.decode_take_reward_result(data)
			reward_result.emit(bool(r["ok"]), int(r["error"]))
			if bool(r["ok"]):
				bag_may_have_changed.emit()
		QuestNet.OP_ABANDON_RESULT:
			var r := QuestNet.decode_id_result(data, false)
			abandon_result.emit(bool(r["ok"]), int(r["quest_id"]), int(r["error"]))
		QuestNet.OP_CLAIM_RESULT:
			var r := QuestNet.decode_id_result(data, true)
			claim_result.emit(bool(r["ok"]), int(r["quest_id"]), int(r["error"]))

func _put(id: int, v: QuestNet.View) -> void:
	if not active.has(id):
		order.append(id)
	active[id] = v

## 0x30D5 applied: add (1, 0x778c70), change (2, 0x778cb0), remove (3 and 4,
## 0x778d10 -- the id then kept with the finished ones when it was a
## completion, 4; OURS: 3 is a give-up and is not kept).
func apply_update(u: QuestNet.Update) -> void:
	match u.kind:
		QuestNet.UPDATE_ADD, QuestNet.UPDATE_CHANGE:
			var old := view_of(u.quest_id)
			_put(u.quest_id, u.view)
			if u.kind == QuestNet.UPDATE_CHANGE and old != null:
				for m in u.view.missions:
					var mm := m as QuestNet.Mission
					var before := _mission(old, mm.index)
					if before != null and mm.open and before.values != mm.values:
						mission_progress.emit(u.quest_id, mm)
					elif before != null and not mm.open and before.open:
						mission_progress.emit(u.quest_id, mm)
			if u.kind == QuestNet.UPDATE_ADD:
				bag_may_have_changed.emit()
		QuestNet.UPDATE_REMOVE, QuestNet.UPDATE_DROPPED:
			active.erase(u.quest_id)
			order.erase(u.quest_id)
			if u.kind == QuestNet.UPDATE_DROPPED:
				completed[u.quest_id] = true
			if tracked == u.quest_id:
				tracked = 0
				marks_changed.emit()
			bag_may_have_changed.emit()
	quest_updated.emit(u)
	log_changed.emit()

static func _mission(v: QuestNet.View, index: int) -> QuestNet.Mission:
	for m in v.missions:
		if (m as QuestNet.Mission).index == index:
			return m
	return null
