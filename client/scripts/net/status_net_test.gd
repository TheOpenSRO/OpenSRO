extends SceneTree

## Headless checks for round 659's abnormal-state mask (StatusNet: retail's
## 0x3057 flag-4 block) and how the target window's buff viewer draws it
## (0x699480 -> 0x7fd2e0, icons from 0x7fdab0). The fixture is the server's
## (server/internal/session/status_test.go objectStatusFixture), byte for
## byte. Synthetic data only: no archive.
##
## Everything is reached by name (load / has_method / call), so on a base
## without StatusNet this script still runs and prints FAIL lines instead of
## failing to compile -- the round's negative.

const STATUS_PATH := "res://scripts/net/status_net.gd"
const VIEWER_PATH := "res://scripts/ui/hud/hud_target_buffs.gd"

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## Monster 7, stunned at level 3 and poisoned: kind 1, id 7, cause 0, flags 4,
## mask 0x4010, one level byte (stun's; poison's bit carries none).
const FIXTURE := [0x01, 0x07, 0, 0, 0, 0, 0, 0, 0, 0x00, 0x00, 0x04, 0x10, 0x40, 0x00, 0x00, 0x03]

func _bytes(a: Array) -> PackedByteArray:
	var out := PackedByteArray()
	for b in a:
		out.append(int(b))
	return out

func _init() -> void:
	var exists := ResourceLoader.exists(STATUS_PATH)
	_check(exists, "status_net.gd exists (the 0x3057 abnormal-state decoder)")
	var S = load(STATUS_PATH) if exists else null
	if S != null:
		_check(int(S.OP_OBJECT_STATUS) == 0x3057, "the opcode is retail's 0x3057")
		var st = S.decode_object_status(_bytes(FIXTURE))
		_check(st.error == "", "the fixture decodes (error '%s')" % st.error)
		_check(st.owner_kind == 1 and st.owner_id == 7, "owner: monster 7")
		_check(st.mask == 0x4010, "mask 0x4010 (got 0x%x)" % st.mask)
		_check(st.levels.size() == 1 and int(st.levels.get(14, -1)) == 3,
			"one level byte, for stun (bit 14), none for poison (bit 4) -- 0x9d2220's 0x17fefc0")
		# Every elemental bit carries none, every other applied one does.
		var lv_bits := int(S.LEVEL_BITS)
		_check(lv_bits == 0x17fefc0, "LEVEL_BITS is 0x9d2220's 0x17fefc0")
		for bit in [0, 1, 2, 3, 4, 5, 12, 23]:
			_check(lv_bits & (1 << bit) == 0, "bit %d carries no level byte" % bit)
		# A mask of three level-carrying bits reads three bytes, in bit order.
		var three := _bytes([0x01, 0x09, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x04, 0xc0, 0x00, 0x00, 0x01, 2, 3, 4])
		var t3 = S.decode_object_status(three)
		_check(t3.error == "" and t3.mask == 0x10000c0 and t3.levels.size() == 3 and int(t3.levels.get(6, -1)) == 2
			and int(t3.levels.get(7, -1)) == 3 and int(t3.levels.get(24, -1)) == 4,
			"sleep, root and incubation read their levels low bit first (got %s)" % str(t3.levels))
		var short = S.decode_object_status(_bytes(FIXTURE.slice(0, 16)))
		_check(short.error != "", "a mask missing its level byte is refused")
		var cleared = S.decode_object_status(_bytes([0, 5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x04, 0, 0, 0, 0]))
		_check(cleared.error == "" and cleared.mask == 0 and cleared.owner_kind == 0,
			"a character's empty mask: every state gone")
		# 0x7fdab0: the icon and label per bit, and the bits it has no case for.
		_check(S.drawn_bits(0x4010 | 0x1000 | 0x800000) == [4, 14], "bits 12 and 23 draw nothing")
		_check(String(S.icon_path(14)) == "icon\\stateodd\\s_stun_icon.ddj", "stun's icon")
		_check(String(S.icon_path(3)) == "icon\\stateodd\\s_burn_icon.ddj", "bit 3 is burn (the server's slot 2)")
		_check(String(S.label(22)) == "CURSIE_MP", "bit 22's label keeps the engine's typo")
		_check(String(S.category(14)) == "PARAM_ETC" and String(S.category(0)) == "PARAM_RESTRICTION"
			and String(S.category(4)) == "PARAM_WEAKLY" and String(S.category(9)) == "PARAM_CURSING",
			"categories as 0x7fdab0 gives them")
		var tt := String(S.tooltip(14, 3, func(t: String) -> String: return "<%s>" % t))
		_check(tt == "<PARAM_STUN> 3<UIIT_STT_GRADE>\n<PARAM_ETC> <UIIT_STT_MACROPOTION_ABNORMAL>",
			"tooltip (0x7fc260 kind 2): got '%s'" % tt.c_escape())
		_check(not String(S.tooltip(4, 0, Callable())).contains("GRADE"), "no level, no grade")

	# --- The viewer: abnormal icons after the skill buffs, in the second list. ---
	var Viewer = load(VIEWER_PATH) if ResourceLoader.exists(VIEWER_PATH) else null
	var has_entries: bool = Viewer != null and S != null and (Viewer as Script).get_script_method_list().any(
		func(m: Dictionary) -> bool: return String(m["name"]) == "abnormal_entries")
	_check(has_entries, "the buff viewer takes abnormal states (abnormal_entries)")
	if has_entries:
		var entries: Array = Viewer.abnormal_entries(0x4010, {14: 3})
		_check(entries.size() == 2 and int(entries[0]["skill_id"]) == Viewer.abnormal_id(4)
			and int(entries[1]["skill_id"]) == Viewer.abnormal_id(14) and int(entries[1]["level"]) == 3,
			"entries in bit order, poison then stun, stun with its level")
		var v = Viewer.new(null, null)
		v.set("ui_text", func(t: String) -> String: return t)
		v.rebuild(entries)
		_check(v.count(true) == 0 and v.count(false) == 2, "abnormal icons go to the second list (0x7fd2e0)")
		_check(v.slot_of(Viewer.abnormal_id(4)).position == Vector2(0, 2)
			and v.slot_of(Viewer.abnormal_id(14)).position == Vector2(23, 2), "laid out as any second-list icon")
		_check(String(v.tooltip_for(Viewer.abnormal_id(14))).begins_with("PARAM_STUN 3UIIT_STT_GRADE"),
			"the slot's tooltip is the abnormal one (got '%s')" % String(v.tooltip_for(Viewer.abnormal_id(14))).c_escape())
		# The per-second diff: the stun ends, the poison stays in its slot.
		var kept = v.slot_of(Viewer.abnormal_id(4))
		v.sync(Viewer.abnormal_entries(0x10, {}))
		_check(v.count(false) == 1 and v.slot_of(Viewer.abnormal_id(4)) == kept, "diff: the ended state goes, the other keeps its slot")
		v.free()

	# --- Round 659's review (H3): a death by a state's tick arrives as
	# OpMonsterAttacked with the status-tick flag 0x08, which draws no swing. ---
	var raw := PackedByteArray()
	raw.resize(33)
	raw.encode_s64(0, 7)
	raw.encode_s64(8, 42)
	raw.encode_s32(16, 16)
	raw[20] = 0x0c
	raw.encode_s32(21, 0)
	var ma = CombatNet.decode_monster_attacked(raw)
	_check(ma != null and ma.target_died and ma.get("status_tick") == true and not ma.critical and not ma.blocked,
		"OpMonsterAttacked flags 0x0c: a death by a state's tick (status_tick), not a swing")
	raw[20] = 0x04
	var blow = CombatNet.decode_monster_attacked(raw)
	_check(blow != null and blow.target_died and blow.get("status_tick") != true, "flags 0x04: a blow's death, no tick")

	if _failures == 0:
		print("ALL PASS")
	else:
		print("%d FAILURE(S)" % _failures)
	quit(1 if _failures > 0 else 0)
