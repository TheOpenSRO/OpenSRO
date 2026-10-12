extends RefCounted
class_name SkillDeco

## One cast's body animation and effect timeline, as the retail client's skill
## decoration (IDecoSkill) runs it (round 785). Pure: it decides WHAT plays and
## WHEN, and hands the caller a list of actions to carry out on the body.
## Labels: READ (sro_client.exe), MEASURED, INFERRED, OURS, OPEN.
##
## THE START (READ, FUN_00a54f00 for a cast from 0xB070, and its twin
## GlobalDataManager::FUN_00a53610):
## - the skill's skillaniset2 record (FUN_00a95dc0 by the skill id) is looked
##   up; NO record ends the decoration with an error line and the body plays
##   NOTHING (no fallback swing). SkillEffectReader.aniset_for is that lookup;
## - the record's AniGroup (+4) is the group every clip is played in; the body
##   resolves it against its own animation set (BsrReader.animation_entry_for:
##   the named group, else `default`);
## - one entry of each list is taken: READY (+0xe), WAIT (+0x20) and SHOT
##   (+0x32) each at index `pick % count`, where `pick` is the decoration's
##   byte +0xe4, set to rand() by the cast's reader (FUN_00a54be0). A list with
##   no entry is -1;
## - READY, WAIT and SHOT all empty (and the id not a system one) ends the
##   decoration at once (vslot 8): no clip, no effect -- Grass Walk, the
##   imbues;
## - a WAIT entry is played on the body at once (vslot 0xb4(group, WAIT, 200)),
##   then the phase machine starts at READY.
##
## THE PHASES (READ, FUN_00a534d0 / FUN_00a53480 / FUN_00a52fe0):
## - entering phase p (0 READY, 1 WAIT, 2 SHOT): phase p's clip is played
##   (vslot 0xb4) unless p is WAIT (already playing) or it has none; then the
##   phase's effect group 0 fires (the rows whose StartEvent is 0: the loader
##   GlobalEffectManager::FUN_00a9d0f0 files each row in the vector at its
##   StartEvent, so group n IS StartEvent n, empty slots skipped);
## - a phase whose list has an entry waits: each type-1 event of the clip
##   playing fires the phase's next group (FUN_00a59970 -> FUN_00a52fe0), and
##   the clip's end runs the machine on to the next phase. A phase with no
##   entry advances at once;
## - WAIT has no clip end of its own: it holds until the server's skill action
##   (0xB071 kind 1, FUN_00a56680 -> FUN_00a53090) forces SHOT -- `shot()`;
## - past SHOT the decoration ends (FUN_00a4ffe0) and every hit not yet shown
##   is applied (FUN_00a50a00).
## HERE the READY clip plays once and the WAIT clip loops under it from its
## end (INFERRED: retail starts WAIT first and READY over it with the same
## vslot; the order the body shows them in was not read), and a deco with a
## WAIT entry and no shot() before `shot_due_ms` forces SHOT then (OURS: the
## retail server sends 0xB071 PreparingTime + CastingTime after 0xB070 --
## skill_buffs.md -- and OpenSRO's server answers a cast at once; the caller
## sets the due time from the row's timing).
##
## THE ACTIONS tick() returns, in order:
##   ["clip", phase, action_type, loop]  play this action type of the record's
##                                       group on the body (loop: WAIT)
##   ["group", phase, event]             fire effect group `event` of `phase`
##                                       (SkillEffects.play_phase,
##                                       SkillAudio.play_phase)
##   ["stop_loops"]                      the READY/WAIT loops end (SHOT starts)
##   ["end"]                             the decoration is over
## The caller resolves a clip's length and event times through `clip_info`:
## Callable(action_type: int) -> {"ms": int, "events": Array of int ms} or
## {} when the body has no clip of that type (then the phase advances at
## once, as retail's -1 does).

const READY := 0
const WAIT := 1
const SHOT := 2
const DONE := 3

## The record's start plan (see the header). {"kind": "none"} (no clip, no
## effect: the record names nothing, or there is no record), else
## {"kind": "anim", "group": g, "ready": t, "wait": t, "shot": t} with -1 for
## a list that names nothing. `pick` is the decoration's random byte.
static func plan(row: Dictionary, pick: int, system_id: bool = false) -> Dictionary:
	if row.is_empty():
		return {"kind": "none", "why": "no skillaniset2 record (FUN_00a54f00 ends the decoration)"}
	var ready := _entry(row.get("ready", []), pick)
	var wait := _entry(row.get("wait", []), pick)
	var shot := _entry(row.get("shot", []), pick)
	if ready < 0 and wait < 0 and shot < 0 and not system_id:
		return {"kind": "none", "why": "READY, WAIT and SHOT all none (FUN_00a54f00 vslot 8)"}
	return {"kind": "anim", "group": String(row.get("group", "")), "ready": ready, "wait": wait, "shot": shot}

static func _entry(list: Array, pick: int) -> int:
	if list.is_empty():
		return -1
	return int(list[posmod(pick, list.size())])

var skill_id := 0
var group := ""
var types := [-1, -1, -1]
var phase := READY
var clip_info: Callable
## When the phase being timed began (ms), and its clip's events still to come.
var _phase_t0 := 0
var _events: Array = []
var _next_event := 1
var _clip_ms := -1
## WAIT: forced to SHOT at this time (ms) unless shot() comes first; -1 holds.
var shot_due_ms := -1
var _shot_now := false
var _pending: Array = []
## The phase the WAIT hold was left in, for logs.
var held_wait := false

## A deco for `skill_id` from its plan (plan() kind "anim"), started at
## `now_ms`. The first tick() returns the WAIT clip (if any), then READY's.
func _init(skill: int, p: Dictionary, info: Callable, now_ms: int, due_ms: int = -1) -> void:
	skill_id = skill
	group = String(p.get("group", ""))
	types = [int(p.get("ready", -1)), int(p.get("wait", -1)), int(p.get("shot", -1))]
	clip_info = info
	shot_due_ms = due_ms
	_phase_t0 = now_ms
	if types[WAIT] >= 0 and types[READY] < 0:
		# READ: the WAIT entry is played at the decoration's start.
		_pending.append(["clip", WAIT, types[WAIT], true])
	_enter(READY, now_ms)

func is_done() -> bool:
	return phase >= DONE

## The server's skill action (0xB071 kind 1 / OpSkillCast act): WAIT goes to
## SHOT now. READ (FUN_00a53090): only a deco with a WAIT entry is forced;
## one without has no hold to end.
func shot() -> void:
	if types[WAIT] >= 0:
		_shot_now = true

## Ends the deco where it stands (a refusal, the body gone): no more groups.
func cancel() -> Array:
	if phase >= DONE:
		return []
	phase = DONE
	return [["stop_loops"], ["end"]]

## Runs the machine to `now_ms`. Returns the actions due, in order.
func tick(now_ms: int) -> Array:
	var out: Array = _pending
	_pending = []
	var guard := 0
	while phase < DONE and guard < 16:
		guard += 1
		if phase == WAIT:
			if types[WAIT] < 0:
				_enter(SHOT, now_ms)
				out.append_array(_take())
				continue
			if _shot_now or (shot_due_ms >= 0 and now_ms >= shot_due_ms):
				_enter(SHOT, now_ms)
				out.append_array(_take())
				continue
			break
		# READY or SHOT: the clip's events, then its end.
		if _clip_ms < 0:
			_enter(phase + 1, now_ms)
			out.append_array(_take())
			continue
		var at := now_ms - _phase_t0
		while _next_event - 1 < _events.size() and at >= int(_events[_next_event - 1]):
			out.append(["group", phase, _next_event])
			_next_event += 1
		if at >= _clip_ms:
			_enter(phase + 1, now_ms)
			out.append_array(_take())
			continue
		break
	return out

## Time (ms from now) until the next thing this deco does by itself, or -1.
func next_due(now_ms: int) -> int:
	if phase >= DONE:
		return -1
	if phase == WAIT:
		return maxi(shot_due_ms - now_ms, 0) if shot_due_ms >= 0 else -1
	if _clip_ms < 0:
		return 0
	var at := now_ms - _phase_t0
	if _next_event - 1 < _events.size():
		return maxi(int(_events[_next_event - 1]) - at, 0)
	return maxi(_clip_ms - at, 0)

func _take() -> Array:
	var out := _pending
	_pending = []
	return out

func _enter(p: int, now_ms: int) -> void:
	phase = p
	_phase_t0 = now_ms
	_events = []
	_next_event = 1
	_clip_ms = -1
	if p >= DONE:
		_pending.append(["stop_loops"])
		_pending.append(["end"])
		return
	if p == SHOT:
		_pending.append(["stop_loops"])
	var t: int = types[p]
	if t >= 0 and p != WAIT:
		var info: Dictionary = clip_info.call(t) if clip_info.is_valid() else {}
		if not info.is_empty():
			_pending.append(["clip", p, t, false])
			_clip_ms = maxi(int(info.get("ms", 0)), 0)
			_events = (info.get("events", []) as Array).duplicate()
			_events.sort()
	if p == WAIT and t >= 0:
		held_wait = true
		if types[READY] >= 0:
			# OURS: the WAIT loop is (re)started when READY's clip ends.
			_pending.append(["clip", WAIT, t, true])
	_pending.append(["group", p, 0])
