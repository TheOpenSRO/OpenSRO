extends SceneTree

## Round 826: a quick slot's re-use time in figures (CoolTimeText, READ
## 0x67c920) -- synthetic textures, no game data.
## `godot4 --headless --path client --script res://scripts/ui/cool_time826_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	process_frame.connect(_run, CONNECT_ONE_SHOT)

func _run() -> void:
	_check(CoolTimeText.display(0).is_empty(), "0 ms: nothing")
	var d := CoolTimeText.display(999)
	_check(d["text"] == "0" and d["colour"] == CoolTimeText.SECONDS_COLOUR and d["veil"] == CoolTimeText.VEIL_DDJ,
		"the last second reads 0, white, over the veil")
	_check(CoolTimeText.display(60999)["text"] == "60" and CoolTimeText.display(60999)["colour"] == CoolTimeText.SECONDS_COLOUR,
		"60 s is still seconds (s <= 60)")
	var m := CoolTimeText.display(61000)
	_check(m["text"] == "1" and m["colour"] == Color8(0xe1, 0xe7, 0x00), "61 s reads 1 in 0xffe1e700 (minutes, truncated)")
	_check(CoolTimeText.display(3600999)["text"] == "60" and CoolTimeText.display(3600999)["veil"] == CoolTimeText.VEIL_DDJ,
		"3600 s is still minutes: 60")
	var h := CoolTimeText.display(3601000)
	_check(h["text"] == "1" and h["colour"] == Color8(0x00, 0x0c, 0xa9) and h["veil"] == CoolTimeText.HOUR_VEIL_DDJ,
		"3601 s reads 1 in 0xff000ca9 over int_effect")
	# Placement in a 32 x 32 slot: one figure 12..20, two 8..16 and 16..24; top 10.
	var r := Rect2(0, 0, 32, 32)
	_check(CoolTimeText.digit_origin(r, 0, 1) == Vector2(12, 10), "one figure: left 12, top 10")
	_check(CoolTimeText.digit_origin(r, 0, 2) == Vector2(8, 10) and CoolTimeText.digit_origin(r, 1, 2) == Vector2(16, 10),
		"two figures: 8 and 16, centred")
	# On a slot node: made before the count, hidden at 0.
	var slot := Control.new()
	slot.size = Vector2(32, 32)
	get_root().add_child(slot)
	var count := Control.new()
	count.name = "CountLabel"
	slot.add_child(count)
	var asked: Array = []
	var tex := ImageTexture.create_from_image(Image.create(8, 12, false, Image.FORMAT_RGBA8))
	var sheet := func(p: String) -> Texture2D:
		asked.append(p)
		return tex
	CoolTimeText.apply(slot, sheet, 12500, count)
	var t := slot.get_node_or_null(CoolTimeText.NODE) as CoolTimeText
	_check(t != null and t.visible and t.shown_text() == "12" and t.get_index() < count.get_index(),
		"12.5 s: '12', under the count")
	await process_frame
	_check(asked.has("effect\\icon\\icon_effect.ddj") and asked.has("effect\\icon\\cool_time_1.ddj")
		and asked.has("effect\\icon\\cool_time_2.ddj"), "it draws the veil and cool_time_1, cool_time_2")
	CoolTimeText.apply(slot, sheet, 0, count)
	_check(not t.visible, "0 hides it")
	slot.free()
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)
