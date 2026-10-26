extends SceneTree

## Round 829: RepairQuote (SOItem::FUN_008bacc0, 0x6abd50 / 0x6b6050,
## 0x8bd0e0), RepairFlash (0x6665d0, 0x67e305) and RepairBox (purpose 0x0C).
##   godot4 --headless --path client --script res://scripts/ui/hud/repair829_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	# ITEM_CH_SWORD_01_A: CostRepair 198, CostRevive 297, max 76.
	_check(RepairQuote.cost(62, 76, 198, 297) == int(14 * (198.0 / 76.0)), "14 points short: 14 x 198/76, cut (got %d)" % RepairQuote.cost(62, 76, 198, 297))
	_check(RepairQuote.cost(76, 76, 198, 297) == 0, "at its maximum: nothing")
	_check(RepairQuote.cost(0, 76, 198, 297) == int(75 * (198.0 / 76.0)) + 297, "broken: the revive fee and the rest from 1 (got %d)" % RepairQuote.cost(0, 76, 198, 297))
	_check(RepairQuote.cost(10, 500, 100, 0) == 490, "a unit price under 1 is held at 1")
	var arm := PackedInt32Array([3, 1, 1, 3])
	_check(RepairQuote.counts(arm) and RepairQuote.counts(PackedInt32Array([3, 1, 6, 2])), "armour and weapons count")
	_check(not RepairQuote.counts(PackedInt32Array([3, 1, 12, 3])) and not RepairQuote.counts(PackedInt32Array([3, 1, 5, 1]))
		and not RepairQuote.counts(PackedInt32Array([3, 3, 1, 1])), "accessories and potions do not")
	_check(RepairQuote.can_be_repaired(arm, []) and RepairQuote.can_be_repaired(arm, [{"code": "MATTR_REPAIR", "value": 2}]),
		"an item with no ban, or MATTR_REPAIR above 1, can be repaired")
	_check(not RepairQuote.can_be_repaired(arm, [{"code": "MATTR_NOT_REPARABLE", "value": 1}])
		and not RepairQuote.can_be_repaired(arm, [{"code": "MATTR_REPAIR", "value": 1}]),
		"MATTR_NOT_REPARABLE, or MATTR_REPAIR at 1, cannot")
	# The flash: 20 frames of 50 ms, cells (f % 8, f / 8), 72 x 72 at (-20, -20).
	var icon := Control.new()
	icon.size = Vector2(32, 32)
	root.add_child(icon)
	var img := Image.create(256, 128, false, Image.FORMAT_RGBA8)
	var f := RepairFlash.play_on(icon, ImageTexture.create_from_image(img))
	_check(f != null and f.frame() == 0 and f.position == Vector2(-20, -20) and f.size == Vector2(72, 72),
		"the flash starts at frame 0, 72 x 72 at (-20, -20)")
	f.step(49.0)
	_check(f.frame() == 0, "49 ms: still frame 0")
	f.step(1.0)
	_check(f.frame() == 1, "50 ms: frame 1")
	f.step(450.0)
	_check(f.frame() == 10, "500 ms: frame 10, the glint's first")
	_check(RepairFlash.play_on(icon, f.sheet) == f and f.frame() == 0, "a second repair starts it again")
	f.step(1000.0)
	_check(f.is_queued_for_deletion(), "1 s: gone")
	icon.free()
	print("FAILURES: %d" % _failures if _failures > 0 else "ALL PASS")
	quit(1 if _failures > 0 else 0)
