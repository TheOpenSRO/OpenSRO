extends SceneTree

## Round 781: action-window buttons on the quick slot bar (retail slot kind
## 0x4a, its u32 the action id, READ 0x60bace) are kept with the skills and
## items (HotbarStore, OURS: retail keeps the bar on the server). A temporary
## file under user://; nothing from the archive.

const TMP := "user://quickslots_actions_test.cfg"

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP))
	var key := HotbarStore.key_for("127.0.0.1:15989", "Aria")
	var skills := {1: {"id": 3, "code": "SKILL_X_01"}}
	var items := {2: {"item": 4, "slot": 13}}
	var actions := {3: 1000, 14: 4001, 40: 1001}
	_check(HotbarStore.save(key, skills, items, TMP, actions), "the bar with actions is written")
	var back := HotbarStore.load_bar(key, TMP)
	_check(back["actions"] == actions, "every action slot comes back with its id (got %s)" % [back.get("actions")])
	_check(back["skills"] == skills and back["items"] == items, "the skills and items beside them too")
	var enc := HotbarStore.encode(skills, items, actions)
	var kinds: Array = []
	for e in enc:
		kinds.append([int(e["slot"]), String(e["kind"])])
	_check(kinds == [[1, "skill"], [2, "item"], [3, "action"], [14, "action"], [40, "action"]], "sorted by slot (got %s)" % [kinds])
	# A slot two tables claim is written once: a skill wins over an action.
	var both := HotbarStore.encode({5: {"id": 9, "code": "S"}}, {}, {5: 1000})
	_check(both.size() == 1 and String(both[0]["kind"]) == "skill", "one entry per slot")
	var dec := HotbarStore.decode([{"slot": 4, "kind": "action", "id": 0}, {"slot": 5, "kind": "action", "id": "1000"},
		{"slot": 6, "kind": "action", "id": 4002}])
	_check(dec["actions"] == {6: 4002}, "an action entry with a bad id is skipped (got %s)" % [dec["actions"]])
	_check(HotbarStore.encode(skills, items) == HotbarStore.encode(skills, items, {}), "callers without actions are unchanged")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP))
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)
