extends SceneTree

## The quick-slot bar kept on the client (round 639, HotbarStore -- OURS at
## the user's request; retail keeps it on the server, packet 0x7158): skills
## and items on every page, per server and character, written and read back.
## Reached by path, so against a client without it this reports FAIL lines
## (the negative, run against dev 5a82339). A temporary file under user://;
## nothing from the archive.

const STORE_PATH := "res://scripts/ui/hud/hotbar_store.gd"
const TMP := "user://quickslots_test.cfg"

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	if not ResourceLoader.exists(STORE_PATH):
		_check(false, "the quick-slot bar is kept between sessions (hotbar_store.gd)")
		_finish()
		return
	var store := load(STORE_PATH) as Script
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP))
	var key_a := String(store.call("key_for", "127.0.0.1:15989", "Aria"))
	var key_b := String(store.call("key_for", "127.0.0.1:15989", "Bram [GM]"))
	var key_c := String(store.call("key_for", "10.0.0.2:15779", "Aria"))
	_check(key_a != key_b and key_a != key_c, "one entry per server and character")
	# Skills on pages 1 and 4 and the "m" slot, items on pages 1 and 2.
	var skills := {1: {"id": 3, "code": "SKILL_CH_SWORD_SMASH_A_01"}, 0: {"id": 177, "code": "SKILL_CH_SWORD_CHAIN_A_01"},
		40: {"id": 90, "code": "SKILL_CH_COLD_GIGONGSUL_A_01"}}
	var items := {2: {"item": 4, "slot": 13}, 17: {"item": 9, "slot": 20}}
	_check(bool(store.call("save", key_a, skills, items, TMP)), "the bar is written")
	_check(bool(store.call("save", key_b, {5: {"id": 8, "code": "X"}}, {}, TMP)), "a second character is written beside it")
	var back: Dictionary = store.call("load_bar", key_a, TMP)
	_check(back["skills"] == skills, "every skill slot comes back with its id and code (got %s)" % [back["skills"]])
	_check(back["items"] == items, "every item slot comes back with its item id and bag slot (got %s)" % [back["items"]])
	var other: Dictionary = store.call("load_bar", key_b, TMP)
	_check(other["skills"] == {5: {"id": 8, "code": "X"}} and (other["items"] as Dictionary).is_empty(),
		"the other character's bar is its own")
	var none: Dictionary = store.call("load_bar", key_c, TMP)
	_check((none["skills"] as Dictionary).is_empty() and (none["items"] as Dictionary).is_empty(),
		"the same name on another server has no bar")
	# Clearing a slot is a save without it.
	skills.erase(40)
	store.call("save", key_a, skills, items, TMP)
	back = store.call("load_bar", key_a, TMP)
	_check(not (back["skills"] as Dictionary).has(40) and (back["skills"] as Dictionary).size() == 2, "a cleared slot stays cleared")
	# Malformed or out-of-range entries are skipped (51 slots, 0x33).
	var dec: Dictionary = store.call("decode", [{"slot": 51, "kind": "skill", "id": 3}, {"slot": -1, "kind": "item", "item": 1, "bag": 13},
		{"slot": 3, "kind": "skill", "id": 0}, "junk", {"slot": 4, "kind": "item", "item": 2, "bag": 14}])
	_check((dec["skills"] as Dictionary).is_empty() and dec["items"] == {4: {"item": 2, "slot": 14}},
		"only the valid entry survives decode (got %s)" % [dec])
	# An item's binding is its bag slot first, then the item anywhere (retail
	# binds the slot; 0x60c430 follows a moved item).
	_check(HudUnderbar.resolve_item_binding(9, 20, {20: 9, 21: 4}) == 20, "an unmoved item keeps its bag slot")
	_check(HudUnderbar.resolve_item_binding(9, 20, {20: 4, 25: 9}) == 25, "a moved item is found at its new slot")
	_check(HudUnderbar.resolve_item_binding(9, 20, {20: 4}) == -1, "a spent item drops its binding")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP))
	_finish()

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)
