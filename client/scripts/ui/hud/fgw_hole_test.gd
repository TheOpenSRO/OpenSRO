extends SceneTree

## Round 869, lane C1: the Dimension hole on the client (DimensionHole,
## MsgBoxInif.Kind.MAGIC_HOLE, HudPanels.open_magic_hole_box / use_magic_hole,
## ItemTooltipLines.compose_dimension_hole, UiSounds.item_used). The layouts
## are MsgBoxFixture's synthetic ifmessagebox.txt; the item rows are fakes
## with the measured hole's fields. No game data.
##   godot4 --headless --path client --script res://scripts/ui/hud/fgw_hole_test.gd

const ErrorText = preload("res://scripts/net/error_text.gd")

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## A fake hole row: ITEM_ETC_TELEPORT_HOLE_TOGUI_35_50_LEVEL_<grade>.
func _hole(id: int, grade: int) -> ItemTableReader.Item:
	var it := ItemTableReader.Item.new()
	it.id = id
	it.code_name = "ITEM_ETC_TELEPORT_HOLE_TOGUI_35_50_LEVEL_%d" % grade
	it.item_name = "Dimension Hole (Togui Village)"
	it.type_ids = PackedInt32Array([3, 3, 12, 7])
	it.param1 = grade
	it.param3 = 35
	it.param4 = 50
	it.param5 = 4
	it.cool_group = 0x71
	it.cool_ms = 18000000
	it.req_gender = ItemTableReader.REQ_GENDER_ANY
	return it

## The archive's English rows these lines read (textuisystem.txt).
func _t(key: String, fallback: String) -> String:
	var rows := {
		"UIIT_STT_GOD_LV_EXTENT": "Level : %s",
		"UIIT_STT_GOD_CLASS": "Grade : %s",
		"UIIT_STT_GOD_CLASS_1": "★",
		"UIIT_STT_GOD_CLASS_2": "★★",
		"UIIT_STT_PARTY_SUMMON": "Number of Players Allowed: 1-%d",
		"UIIT_STT_ITEM_FORMAT_COOLTIME": "Reuse time",
		"PARAM_SECOND": "Second",
		"UIIT_STT_ITEM_TYPE": "Sort of item",
	}
	return rows.get(key, fallback)

func _initialize() -> void:
	_types()
	_tooltip()
	_reuse()
	_box()
	_yes()
	_sound()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

func _types() -> void:
	var t := PackedInt32Array([3, 3, 12, 7])
	_check(DimensionHole.is_hole(t), "3/3/12/7 is a hole (c:0x666f80)")
	_check(DimensionHole.type_word(t) == 0x3E6C, "its type word is 0x3E6C (got 0x%X)" % DimensionHole.type_word(t))
	_check(not DimensionHole.is_hole(PackedInt32Array([3, 3, 12, 3])), "the guild recall scroll 3/3/12/3 is not")

func _tooltip() -> void:
	var t := Callable(self, "_t")
	var g1 := DimensionHole.tooltip_lines(_hole(35883, 1), t, 0)
	_check(g1 == ["Level : 35 - 50", "Grade : ★", "Number of Players Allowed: 1-4", "Reuse time 18000Second"],
		"grade 1, idle: the measured four lines (got %s)" % str(g1))
	var g2 := DimensionHole.tooltip_lines(_hole(35884, 2), t, 16956000)
	_check(g2 == ["Level : 35 - 50", "Grade : ★★", "Number of Players Allowed: 1-4", "Reuse time 16956Second"],
		"grade 2 with the group's time running: the time left (MEASURED 16956Second) (got %s)" % str(g2))
	var odd := _hole(1, 7)
	var g7 := DimensionHole.tooltip_lines(odd, t, 0)
	_check(g7[1] == "Grade : 35 - 50", "a Param1 outside 1..4 keeps the level's text (the switch's default, c:0x66f52b)")
	var none := _hole(2, 1)
	none.cool_ms = 0
	_check(DimensionHole.tooltip_lines(none, t, 0).size() == 3, "no re-use line without a cool time (+0x540 == 0)")
	var lines := ItemTooltipLines.compose(_hole(35883, 1), {"text": t, "type_name": "Dimension Hole",
		"description": "Creates a teleport gate to the Forgotten World."})
	var text := ItemTooltipLines.as_text(lines)
	_check(text == "Dimension Hole (Togui Village)\n\nSort of item: Dimension Hole\n\nCreates a teleport gate to the Forgotten World.\n\n" \
		+ "Level : 35 - 50\nGrade : ★\nNumber of Players Allowed: 1-4\nReuse time 18000Second",
		"the whole tooltip in 0x6860a0's order (got %s)" % text.replace("\n", " | "))
	_check(lines[2]["color"] == ItemTooltipLines.BEIGE and lines[6]["color"] == ItemTooltipLines.WHITE, "type beige, the hole's lines white")

func _reuse() -> void:
	var cd := ItemCooldowns.new()
	var hole := _hole(35883, 1)
	var left := func(key: String) -> int: return cd.left_ms(key)
	_check(DimensionHole.reuse_left_ms(hole, left) == 0, "nothing running: 0")
	cd.arm(ItemCooldowns.data_key(35884, 0x71), 18000000)
	_check(DimensionHole.reuse_left_ms(hole, left) == 18000000, "another grade's use runs the shared group 0x71 (c:0x7972c7 -> 0x9ba5c0)")
	var lone := _hole(9, 1)
	lone.cool_group = 0
	cd.arm(ItemCooldowns.data_key(9, 0), 5000)
	_check(DimensionHole.reuse_left_ms(lone, left) == 5000, "no group: the item's own id's entry (c:0x797306 -> 0x9ba6e0)")

func _box() -> void:
	var builder := MsgBoxFixture.builder()
	var box := MsgBoxInif.new()
	_check(box.build_kind(builder, MsgBoxInif.Kind.MAGIC_HOLE, "MagicHoleConfirm"), "box 0x2e builds")
	_check(box.size == Vector2(500, 144), "box 0x2e is 0x1f4 x 0x90 (c:0x6478c7) (got %s)" % str(box.size))
	_check(box.caption.text == "<UIIT_STT_CONFIRM_BOX>" and box.line(0) in ["<UIIT_MSG_USE_MAGIC_HOLE_CREATE_GATE>", "UIIT_MSG_USE_MAGIC_HOLE_CREATE_GATE"],
		"title UIIT_STT_CONFIRM_BOX, line UIIT_MSG_USE_MAGIC_HOLE_CREATE_GATE (got %s / %s)" % [box.caption.text, box.line(0)])
	var msg := box.node("GDR_MBIN_STATIC_MESSAGE1")
	_check(msg != null and msg.position == Vector2(0x14, 0x37) and msg.size.x == 0x1cc and msg.size.y >= 0xf,
		"the line at (0x14, 0x37), 0x1cc wide (0xf high, or the font's line when taller) (got %s %s)" % [msg.position if msg != null else "-", msg.size if msg != null else "-"])
	_check(box.button("GDR_MBIN_BTN_OK").position.x == 72 + 0x50 and box.button("GDR_MBIN_BTN_CANCEL").position.x == 152 + 0x64,
		"Yes at 72 + 0x50 and No at 152 + 0x64 (MEASURED x 640 / 739 from the box's 487)")
	_check(not box.node("GDR_MBIN_BTN_CERTIFY").visible, "+0x808 hidden")
	_check(box._find_button(true) == box.button("GDR_MBIN_BTN_OK"), "the QA hook's Yes is the OK button")
	var said: Array = []
	box.accepted.connect(func(_t: String) -> void: said.append("yes"))
	box.button("GDR_MBIN_BTN_OK").pressed.emit()
	_check(said == ["yes"], "Yes accepts")
	box.free()

func _sound() -> void:
	UiSounds.clear_fired()
	UiSounds.expect_use(PackedInt32Array([3, 3, 12, 7]))
	UiSounds.use_replied(true)
	_check(UiSounds.fired.has(DimensionHole.SUCCESS_SOUND_TAG), "a hole's accepted use plays gacha_change_2.wav (c:0x87b485)")
	UiSounds.clear_fired()
	UiSounds.expect_use(PackedInt32Array([3, 3, 12, 7]))
	UiSounds.use_replied(false)
	_check(UiSounds.fired.is_empty(), "a refused use plays nothing")

func _yes() -> void:
	var cd := ItemCooldowns.new()
	var left := func(key: String) -> int: return cd.left_ms(key)
	var sent: Array = []
	var refused: Array = []
	var send := func(s: int) -> void: sent.append(s)
	var refuse := func(code: int) -> void: refused.append(code)
	var hole := _hole(35883, 1)
	_check(DimensionHole.on_yes(hole, 13, left, send, refuse) == "sent" and sent == [13] and refused.is_empty(),
		"Yes with nothing running sends the use of the box's slot")
	_check(DimensionHole.retail_use_payload(13) == PackedByteArray([13, 0x6C, 0x3E]), "retail 0x704C {u8 13, u16 0x3E6C}")
	_check(UseItemNet.encode_use("Hole1", 13) == PackedByteArray([5, 0, 0x48, 0x6F, 0x6C, 0x65, 0x31, 13, 0, 0, 0, 0, 0, 0, 0]),
		"OpenSRO's use request 0x008a for that slot: {u16 5, 'Hole1', s64 13} (got %s)" % UseItemNet.encode_use("Hole1", 13).hex_encode())
	sent.clear()
	cd.arm(ItemCooldowns.data_key(35884, 0x71), 1000)
	_check(DimensionHole.on_yes(hole, 13, left, send, refuse) == "reuse" and sent.is_empty() and refused == [0x185b],
		"a running group 0x71: refused with category 1's 0x185b, nothing sent (c:0x7972e9)")
	var tbl := UiTextTable.new()
	_check(ErrorText.scroll_line(0x185b, tbl, DimensionHole.REUSE_FALLBACK) == "Still have time to reuse the item.",
		"the line's words without the archive row")
	_check(ErrorText.SCROLL_UIIT_BY_CODE[0x185b] == "UIIT_MSG_STRGERR_WAIT_FOR_REUSE_DELAY", "0x185b is UIIT_MSG_STRGERR_WAIT_FOR_REUSE_DELAY")
