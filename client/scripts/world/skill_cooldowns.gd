extends RefCounted
class_name SkillCooldowns

## This client's own skill re-use timers (round 785), as the retail client's
## CSkillCoolTimeManager keeps them. Labels: READ, MEASURED, INFERRED, OURS.
##
## ARMED (READ): when the player's own cast begins -- the 0xB070 handler
## NetProcessInNavAndSkill::FUN_008a5fd0 calls FUN_00778910(skill) for the
## player's own caster id -- FUN_009bb470 adds a record {skill, total =
## remaining = the client ref's +0x78, tail 500} and FUN_009ba460 arms the
## ref's cooldown group (+0x8b) with the same time. The client ref sits four
## bytes below the server's record (the group byte +0x8b is the server's
## Action_Overlap high byte +0x8f, skill_fields.md), so +0x78 is skilldata's
## Action_ReuseDelay (column 14) and the group is Action_Overlap (column 18)
## >> 24. MEASURED: player skills' column 15 (CoolTime) is 0 on every row;
## each skill line's levels share one group (SWORD_SMASH_A_xx group 2, _B 3).
## HERE armed when this client's own cast is ACCEPTED (OpenSRO's answer to its
## OpUseSkill), its 0xB070.
##
## REFUSED (READ): the skill use FUN_0081ba10 asks
## SkillCoolTimeManager::FUN_009bba90 first, which returns the remaining ms
## of a record of the skill itself or of any skill of the same group (or of
## the group's own record); non-zero refuses with 0x3005
## UIIT_SKILL_USE_FAIL_TIMEDELAY_COOL_TIME, "Still have time to reuse the
## skill." (MEASURED, textuisystem.txt), and NOTHING is sent.
##
## COUNTED DOWN (READ, FUN_009bb870 every frame by the frame's ms): the
## remaining time falls to 0; then the tail (500) falls to 0; then the record
## goes. FUN_009bb9c0 is remaining / total (the slot's dark sweep),
## FUN_009bbb60 is tail / 500.0 (the slot's "charged" flash).

const TAIL_MS := 500

## Records: {skill, group, total, left, tail}.
var _records: Array = []

## Arms `skill_id` (and its group, when not 0) for `reuse_ms`. A re-arm of the
## same skill replaces its record.
func arm(skill_id: int, group: int, reuse_ms: int) -> void:
	if reuse_ms <= 0:
		return
	for i in range(_records.size() - 1, -1, -1):
		if int(_records[i]["skill"]) == skill_id:
			_records.remove_at(i)
	_records.append({"skill": skill_id, "group": group, "total": reuse_ms, "left": reuse_ms, "tail": TAIL_MS})

## The record that governs `skill_id` (itself, or its group), or {}.
func _record_for(skill_id: int, group: int) -> Dictionary:
	for r in _records:
		if int(r["skill"]) == skill_id:
			return r
	if group != 0:
		for r in _records:
			if int(r["group"]) == group:
				return r
	return {}

## The re-use time left (ms) that refuses a cast of `skill_id`; 0 when free.
func remaining_ms(skill_id: int, group: int = 0) -> int:
	var r := _record_for(skill_id, group)
	return int(r["left"]) if not r.is_empty() else 0

## remaining / total, 0..1 (the slot's sweep); 0 when free.
func ratio(skill_id: int, group: int = 0) -> float:
	var r := _record_for(skill_id, group)
	if r.is_empty() or int(r["total"]) <= 0:
		return 0.0
	return clampf(float(r["left"]) / float(r["total"]), 0.0, 1.0)

## tail / 500 once the time is up, 0..1 (the slot's charged flash); 0 while
## counting or when there is no record.
func flash(skill_id: int, group: int = 0) -> float:
	var r := _record_for(skill_id, group)
	if r.is_empty() or int(r["left"]) > 0:
		return 0.0
	return clampf(float(r["tail"]) / float(TAIL_MS), 0.0, 1.0)

## One frame of `ms` milliseconds.
func tick(ms: int) -> void:
	if ms <= 0 or _records.is_empty():
		return
	for i in range(_records.size() - 1, -1, -1):
		var r: Dictionary = _records[i]
		if int(r["left"]) > 0:
			r["left"] = maxi(int(r["left"]) - ms, 0)
		elif int(r["tail"]) > 0:
			r["tail"] = maxi(int(r["tail"]) - ms, 0)
		else:
			_records.remove_at(i)

func count() -> int:
	return _records.size()

func clear() -> void:
	_records.clear()

## The frame of a 16 x 16 sheet of 32-pixel cells (skill_delay.ddj, 512 x
## 512) for a sweep at `r` (READ, UI_SILKMALL::FUN_0067cfb0: frame =
## ftol(239 - r * 239), column = frame & 15, row = frame >> 4, UV step
## 32 / 512). -1 when r is 0 (nothing drawn).
static func delay_frame(r: float) -> int:
	if r <= 0.0:
		return -1
	return clampi(int(239.0 - r * 239.0), 0, 239)

## The frame of the charged flash (skill_charge.ddj, 64 x 64, a 4 x 4 sheet
## of 16-pixel cells): ftol(15 - f * 15) (READ, the same function). -1 when f
## is 0.
static func charge_frame(f: float) -> int:
	if f <= 0.0:
		return -1
	return clampi(int(15.0 - f * 15.0), 0, 15)
