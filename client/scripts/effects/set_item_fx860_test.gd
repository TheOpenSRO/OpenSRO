extends SceneTree

## SetItemFx (round 860): a set's completion and break (FUN_00a60220 /
## FUN_00a60c60's flags), the handlers' choice (c:0x8a9260 / 0x8a9560), the
## itemeffect row first -- pure, synthetic tables.
## `godot4 --headless --path client --script res://scripts/effects/set_item_fx860_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _utf16(text: String) -> PackedByteArray:
	var out := PackedByteArray([0xFF, 0xFE])
	out.append_array(text.to_utf16_buffer())
	return out

func _initialize() -> void:
	process_frame.connect(_run, CONNECT_ONE_SHOT)

func _run() -> void:
	var t := "1\t11\tITEM_11_SET_A_CH_M_HEAVY\tx\r\n1\t12\tITEM_11_SET_A_ACCESSORY\tx\r\n1\t13\tITEM_11_SET_A_WEAPON\tx\r\n// a comment\r\n"
	var sizes := SetItemFx.parse_set_sizes(_utf16(t))
	_check(sizes == {11: 6, 12: 3, 13: 1}, "set sizes by code name: armour 6, accessories 3, a weapon 1 (%s)" % str(sizes))

	# Items 101..106 the armour set's six pieces, 201..203 the accessories.
	var set_of := func(item: int) -> int:
		if item >= 101 and item <= 106:
			return 11
		if item >= 201 and item <= 203:
			return 12
		return 0
	var five := {0: 101, 1: 102, 2: 103, 3: 104, 4: 105, 6: 999}
	var six := five.duplicate()
	six[5] = 106
	_check(SetItemFx.complete_sets(five, set_of, sizes).is_empty(), "five of six: not complete")
	_check(SetItemFx.complete_sets(six, set_of, sizes) == {11: true}, "the sixth slot: complete")
	var two_in_slot := {0: 101, 1: 101, 2: 103}
	_check(SetItemFx.complete_sets(two_in_slot, set_of, sizes).is_empty(), "slots are counted, not items")
	var before := SetItemFx.complete_sets(five, set_of, sizes)
	var after := SetItemFx.complete_sets(six, set_of, sizes)
	_check(SetItemFx.change(before, after, true) == SetItemFx.ACTIVE, "the completing piece put on: ACTIVE")
	_check(SetItemFx.change(after, before, false) == SetItemFx.DEACTIVE, "a piece of a complete set taken off: DEACTIVE")
	_check(SetItemFx.change(after, before, true) == SetItemFx.DEACTIVE, "a swap out of a complete set (0x3038): DEACTIVE")
	_check(SetItemFx.change(before, after, false) == "", "0x3039 tests only DEACTIVE")
	_check(SetItemFx.change(before, before, true) == "", "nothing changed: nothing")

	# The itemeffect row comes first; the set's look otherwise.
	SetItemFx.set_tables(sizes, {"ITEM_TEST_NASRUN": "ITEMSKILL_TEST_NASRUN_EQUIP"}, {})
	_check(SetItemFx.play(null, "ITEM_TEST_NASRUN", true, before, after) == "", "no body: nothing")
	var body := Node3D.new()
	get_root().add_child(body)
	_check(SetItemFx.play(body, "ITEM_ANY", false, before, before) == "", "no change and no row: nothing")
	_check(SetItemFx.play(body, "ITEM_ANY", true, before, after) == SetItemFx.ACTIVE, "the set completed: ACTIVE plays")
	body.queue_free()
	_finish()

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)
