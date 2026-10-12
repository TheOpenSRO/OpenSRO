extends SceneTree

## Round 779: the return scrolls' casting bar (DelayInfoBar, retail's
## CIFDelayInfo kind 0) and its wire -- the reply's item id, the cancel's
## 0x705B / 0xB05B, the 0x30BF kind 0xb, the two refusal codes' names.
## Synthetic values only, no art or game text (docs/LEGAL.md):
##   godot4 --headless --path client --script res://scripts/ui/hud/return_scroll_cast779_test.gd

const ErrorText = preload("res://scripts/net/error_text.gd")

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	_run()
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)

func _run() -> void:
	_bar_layout()
	_bar_fill()
	_bar_cancel()
	_bar_position()
	_wire()
	_codes()

## The window and its three controls at ifdelayinfo.txt's rects (built
## without an archive: the stand-ins sit where the layout puts them).
func _bar_layout() -> void:
	var bar := DelayInfoBar.new()
	root.add_child(bar)
	bar.build(null, "Test Scroll", 30000, 61)
	_check(bar.size == Vector2(192, 36), "the window is 192 x 36 (0xc0 x 0x24)")
	_check(bar.caption() == "Test Scroll", "the name static shows the item's name")
	_check(bar.item_id == 61 and bar.total_ms == 30000 and bar.remaining_ms == 30000, "total and remaining start at Param1 ms")
	var g := bar.gauge() as TextureProgressBar
	_check(g != null and g.position == Vector2(6, 27) and g.size == Vector2(184, 8), "the gauge at (6, 27) 184 x 8")
	_check(g != null and g.fill_mode == TextureProgressBar.FILL_LEFT_TO_RIGHT, "the gauge fills left to right")
	_check(g != null and g.texture_under == null, "no back behind the fill (kind 0 sets none)")
	_check(is_equal_approx(g.value, 0.0), "the gauge starts empty")
	var c := bar.cancel_button()
	_check(c != null and c.position == Vector2(171, 4) and c.size == Vector2(20, 20), "the cancel button at (171, 4) 20 x 20, right of the name")
	_check(bar.name == "DelayInfo100", "the entry's id is 100 + kind")
	bar.free()

## vslot_012: the frame's ms off the remaining (capped at 3000 a frame), the
## gauge (total - remaining) / total; at 0 it stays full.
func _bar_fill() -> void:
	var bar := DelayInfoBar.new()
	root.add_child(bar)
	bar.build(null, "x", 30000)
	bar.set_process(false)
	for i in 15:
		bar.advance(1000)
	_check(bar.remaining_ms == 15000 and is_equal_approx(bar.fraction(), 0.5), "half way after 15 s of a 30 s cast")
	_check(is_equal_approx(bar.gauge().value, 50.0), "the gauge at 50 %")
	bar.advance(10000)
	_check(bar.remaining_ms == 12000, "a frame counts at most 3000 ms (DAT_0110f7f8's cap)")
	for i in 20:
		bar.advance(1000)
	_check(bar.remaining_ms == 0 and is_equal_approx(bar.fraction(), 1.0), "at the end the bar is full")
	bar.advance(1000)
	_check(bar.remaining_ms == 0 and is_equal_approx(bar.gauge().value, 100.0), "and stays full: kind 0 waits for the server")
	var one := DelayInfoBar.new()
	root.add_child(one)
	one.build(null, "y", 1000)
	one.set_process(false)
	one.advance(16)
	_check(one.remaining_ms == 984, "a 1 s cast (the reverse scroll's Param1 1000) counts down by frames")
	bar.free()
	one.free()

func _bar_cancel() -> void:
	var bar := DelayInfoBar.new()
	root.add_child(bar)
	bar.build(null, "x", 5000)
	var pressed := [0]
	bar.cancel_pressed.connect(func() -> void: pressed[0] += 1)
	bar.cancel_button().emit_signal("pressed")
	_check(pressed[0] == 1, "the cancel button asks for the cancel")
	_check(bar.visible and not bar.is_queued_for_deletion(), "and the bar stays up until the state's 0")
	bar.close()
	_check(not bar.visible and bar.is_queued_for_deletion(), "close hides and frees it")

## FUN_007b1470: centred, x 0x195 at 800 wide, the board at h - 0xa5 and
## entry i at + 0x4c - 0x26 i.
func _bar_position() -> void:
	_check(DelayInfoBar.screen_position(Vector2(1280, 720)) == Vector2(544, 631), "1280 x 720: (544, 631)")
	_check(DelayInfoBar.screen_position(Vector2(1024, 768)) == Vector2(416, 679), "1024 x 768: (416, 679)")
	_check(DelayInfoBar.screen_position(Vector2(800, 600)) == Vector2(405, 511), "800 x 600: x 0x195")
	_check(DelayInfoBar.screen_position(Vector2(1280, 720), 1) == Vector2(544, 593), "a second entry 0x26 higher")

func _wire() -> void:
	# A reply with the round-779 tail: ... code u16, cast u32, item u32.
	var data := PackedByteArray([0, 0])
	var body := PackedByteArray()
	body.resize(44)
	body.fill(0)
	body.encode_s32(24, 4)
	body.encode_u32(36, 30000)
	body.encode_u32(40, 61)
	data.append_array(body)
	var r := UseItemNet.decode_result(data)
	_check(r.error == "" and r.cast_ms == 30000 and r.item_id == 61 and r.remaining == 4, "the reply's item id after the cast")
	var old := UseItemNet.decode_result(data.slice(0, data.size() - 4))
	_check(old.cast_ms == 30000 and old.item_id == 0, "a round-778 reply has no item id")
	_check(UseItemNet.OP_SCROLL_CANCEL == 0x705B and UseItemNet.OP_SCROLL_CANCEL_RESULT == 0xB05B, "the cancel is 0x705B, its refusal 0xB05B")
	_check(UseItemNet.decode_cancel_result(PackedByteArray([2, 6, 0])) == 6, "0xB05B {2, 6}: no scroll working")
	_check(UseItemNet.decode_cancel_result(PackedByteArray([1])) == -1, "a result 1 is not a refusal")
	_check(WorldNet.STATE_KIND_TELEPORT == 0xb, "0x30BF's scroll state is kind 0xb")
	var sc := WorldNet.decode_state_change(PackedByteArray([7, 0, 0, 0, 0xb, 0]))
	_check(sc != null and sc.kind == 0xb and sc.value == 0 and sc.object_id == 7, "a kind 0xb value 0 decodes")

func _codes() -> void:
	_check(ErrorText.SCROLL_UIIT_BY_CODE.get(0x186a, "") == "UIIT_MSG_STRGERR_ONLY_ROBBER_CAN_USE_THIS_ITEM", "0x186a names the thief-den refusal")
	_check(ErrorText.UIIT_BY_CODE.get(0x1c14, "") == "UIIT_MSG_INTERACTION_FAIL_TELESCROLL_ALREADY_WORKING", "0x1c14 names the teleport-while-casting refusal")
	_check(ErrorText.teleport_line(0x1c14, null, "") == "A teleport scroll is already working.", "without a table the teleport line falls back")
