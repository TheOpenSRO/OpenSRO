extends SceneTree

## Round 826: the item re-use timers (ItemCooldowns, READ 0x87a7b0 /
## 0x67cbf0) and the item reader's COOLTIME pair -- no game data.
## `godot4 --headless --path client --script res://scripts/world/item_cooldowns826_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	var hp := PackedInt32Array([3, 3, 1, 1])
	var mp := PackedInt32Array([3, 3, 1, 2])
	_check(ItemCooldowns.arms_of(5, hp, 0, 0, 0, 0, false, 0) == [["k1", 1000]], "a China HP potion: kind 1 for 1000 ms")
	_check(ItemCooldowns.arms_of(5, hp, 0, 0, 0, 0, true, 0) == [["k1", 15000]], "a Europe one: 15000 ms")
	_check(ItemCooldowns.arms_of(5, hp, 0, 0, 30, 0, true, 0) == [["k1", 4000]], "a percentage potion: 4000 ms either way")
	_check(ItemCooldowns.arms_of(5, hp, 0, 0, 0, 0, false, ItemCooldowns.PANIC) == [["k1", 5000]], "in panic: + 4000")
	_check(ItemCooldowns.arms_of(6, mp, 0, 0, 0, 0, false, ItemCooldowns.COMBUSTION) == [["k2", 5000]], "an MP potion in combustion: kind 2, + 4000")
	_check(ItemCooldowns.arms_of(7, PackedInt32Array([3, 3, 1, 3]), 9, 2000, 0, 0, false, 0) == [["g9", 2000]],
		"a vigor potion with a COOLTIME: the group's entry, not kind 3")
	_check(ItemCooldowns.arms_of(8, PackedInt32Array([3, 3, 2, 1]), 0, 0, 0, 0, true, 0) == [["k13", 20000]], "pill TypeID4 1: kind 0xd, 20000")
	_check(ItemCooldowns.arms_of(9, PackedInt32Array([3, 3, 3, 1]), 0, 23000, 0, 0, false, 0) == [["r9", 23000]],
		"any item with a COOLTIME of group 0: its own id's entry")
	_check(ItemCooldowns.arms_of(9, PackedInt32Array([1, 1, 1, 1]), 0, 0, 0, 0, false, 0).is_empty(), "armour: nothing")
	# The key a slot shows.
	_check(ItemCooldowns.key_of(5, hp, 0, 0) == "k1" and ItemCooldowns.key_of(7, PackedInt32Array([3, 3, 1, 7]), 0, 0) == "k6",
		"slot keys: TypeID4 1 kind 1, 7 kind 6")
	_check(ItemCooldowns.key_of(7, PackedInt32Array([3, 3, 1, 6]), 0, 0) == "", "TypeID4 6 shows none")
	_check(ItemCooldowns.key_of(7, PackedInt32Array([3, 3, 1, 3]), 9, 2000) == "g9", "a COOLTIME vigor potion shows its group")
	# The timer.
	var c := ItemCooldowns.new()
	c.arm("k1", 1000)
	c.tick(250)
	_check(c.left_ms("k1") == 750 and is_equal_approx(c.ratio("k1"), 0.75), "250 ms in: 750 left, ratio 0.75")
	c.tick(800)
	_check(c.left_ms("k1") == 0 and c.count() == 0, "at 0 the entry goes")
	# The reader's COOLTIME pair.
	var cols := PackedStringArray()
	cols.resize(160)
	for i in cols.size():
		cols[i] = "0"
	cols[128] = "20000"
	cols[129] = "COOLTIME:0x00000010"
	_check(ItemTableReader.cooltime_of(cols) == [16, 20000], "COOLTIME:0x10 over Param6 20000 -> group 16, 20000 ms")
	cols[129] = "cooltime:A"
	_check(ItemTableReader.cooltime_of(cols) == [10, 20000], "any case, the group in base 16")
	cols[129] = "xxx"
	_check(ItemTableReader.cooltime_of(cols) == [0, 0], "no descriptor: none")
	print("ALL PASS" if _failures == 0 else "FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)
