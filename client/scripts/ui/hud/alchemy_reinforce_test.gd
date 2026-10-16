extends SceneTree

## The alchemy window's strengthening tab (round 768): AlchemyReinforce's
## rules, AlchemyNet's wire shapes, and the window driven through a whole
## attempt on a synthetic nifenchantwnd.2dt (the real ids, types and parents
## of the records the tab uses; no art, every text a "tt ..." of this test's
## own -- docs/LEGAL.md):
##   godot4 --headless --path client --script res://scripts/ui/hud/alchemy_reinforce_test.gd

const READER_PATH := "res://scripts/ui/twodt_reader.gd"
const RECORD := 0x3d0

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	# One frame first: the Audio autoload's _ready (its options) runs then,
	# and the window plays its sounds through it.
	await process_frame
	_rules()
	_wire()
	_window()
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)

# A degree-1 sword, the weapon elixir (MEASURED Param1 0x06000000, Param5
# -1), the armour elixir, a degree-1 powder, a degree-1 STR stone, a degree-1
# PA attribute stone and a degree-2 one.
func _sword(bag: int = 0) -> Dictionary:
	return {"bag": bag, "item_id": 100, "tids": [3, 1, 6, 2], "item_class": 1, "plus": 3, "durability": 40, "code": "ITEM_X_SWORD"}
func _elixir(bag: int = 1) -> Dictionary:
	return {"bag": bag, "item_id": 200, "tids": [3, 3, 10, 1], "param1": 0x06000000, "param5": -1}
func _armour_elixir() -> Dictionary:
	return {"bag": 2, "item_id": 201, "tids": [3, 3, 10, 1], "param1": 0x01020300, "param5": -1}
func _powder(degree: int = 1) -> Dictionary:
	return {"bag": 3, "item_id": 300, "tids": [3, 3, 10, 2], "param1": degree}
func _stone(degree: int = 1) -> Dictionary:
	return {"bag": 4, "item_id": 400, "tids": [3, 3, 11, 1], "param1": degree, "desc1": "MATTR_STR"}
func _attr(desc4: String) -> Dictionary:
	return {"bag": 5, "item_id": 500, "tids": [3, 3, 11, 2], "param1": 1, "desc1": "NATTR_PA", "desc4": desc4}

func _table() -> MagicOptionTable:
	var row := PackedStringArray()
	row.resize(50)
	row[1] = "69"; row[2] = "MATTR_STR"; row[4] = "1"; row[8] = "65538"; row[9] = "196608"; row[10] = "0"
	row[29] = "weapon"; row[31] = "armor"; row[33] = "xxx"
	var blk := PackedStringArray(row)
	blk[1] = "70"; blk[2] = "MATTR_BLOCKRATE"; blk[29] = "shield"; blk[31] = "xxx"
	var text := "\t".join(row) + "\n" + "\t".join(blk)
	var data := PackedByteArray([0xFF, 0xFE])
	data.append_array(text.to_utf16_buffer())
	return MagicOptionTable.new().load(data)

func _rules() -> void:
	var R := AlchemyReinforce
	var empty := [null, null, null]
	_check(R.pick_slot(_sword(), empty) == 0, "equipment goes to the target slot (0x5781f0)")
	_check(R.pick_slot(_elixir(), empty) == 0 and R.validate(0, _elixir(), empty, null) == 8,
		"an elixir with no target is offered to the first slot and refused: LOAD_EQUIP_FIRST")
	# Round 789: an avatar is refused as retail refuses it (index 8,
	# LOAD_EQUIP_FIRST), a devil's spirit with Param2 0 with 0xe.
	_check(R.validate(0, {"tids": [3, 1, 13, 2]}, empty, null) == 8, "an avatar is refused: LOAD_EQUIP_FIRST")
	_check(R.validate(0, {"tids": [3, 1, 14, 1], "param2": 0}, empty, null) == 0xe
		and R.validate(0, {"tids": [3, 1, 14, 1], "param2": 1}, empty, null) == 0,
		"a devil's spirit with Param2 0 is refused: NASRUN_EVENTNASRUN_NOT_UPGRADE; with 1 it goes in")
	var withsword := [_sword(), null, null]
	_check(R.pick_slot(_elixir(), withsword) == 1 and R.validate(1, _elixir(), withsword, null) == 0, "the weapon elixir suits the sword")
	_check(R.validate(1, _armour_elixir(), withsword, null) == 0xa, "the armour elixir does not: RECIPE_MISMATCH")
	_check(R.pick_slot(_powder(), withsword) == 1 and R.validate(1, _powder(), withsword, null) == 9,
		"a powder before an elixir lands in the stuff slot and is refused: NOT_LOAD_INGREDIENT")
	var full := [_sword(), _elixir(), null]
	_check(R.pick_slot(_powder(), full) == 2 and R.validate(2, _powder(), full, null) == 0, "the powder of the sword's degree")
	_check(R.validate(2, _powder(2), full, null) == 0xb, "a powder of another degree: NOT_LOAD_INGREDIENT2")
	_check(R.validate(1, _stone(2), withsword, null) == 0xc, "a stone of another degree: EQUIPCLASS_MISMATCH")
	var t := _table()
	_check(t.size() == 2 and t.record("mattr_str", 1) != null and t.record("MATTR_STR", 1).kinds == PackedStringArray(["weapon", "armor"]),
		"the option table reads the kinds until xxx")
	_check(R.validate(1, _stone(), withsword, t) == 0, "a STR stone suits a weapon")
	var blk_stone := _stone()
	blk_stone["desc1"] = "MATTR_BLOCKRATE"
	_check(R.validate(1, blk_stone, withsword, t) == 0xd, "a block stone does not: CANNOT_BE_USED_TO_TARGET")
	_check(R.validate(1, _attr("weapon"), withsword, t) == 0 and R.validate(1, _attr("armor,shield"), withsword, t) == 0xd,
		"an attribute stone's class list decides")
	_check(not R.action_enabled(withsword) and R.action_enabled(full), "the action lights with a target and a stuff (0x578670)")
	_check(R.op_for(_elixir()) == 3 and R.op_for(_stone()) == 4 and R.op_for(_attr("weapon")) == 5, "the ops")
	_check(R.request_slots([_sword(7), _elixir(9), _powder()]) == [7, 9, 3], "the request names the bag slots in key order")
	# Outcomes (0x8729e0 / 0x872cd0).
	var ok := AlchemyNet.Result.new()
	ok.ok = true
	ok.success = true
	_check(R.outcome(ok, 3, 40) == R.OUT_SUCCESS, "success is 0x10")
	var lost := AlchemyNet.Result.new()
	lost.ok = true
	lost.record = ItemInstance.new()
	lost.record.opt_level = 0
	lost.record.durability = 40
	_check(R.outcome(lost, 3, 40) == (R.OUT_FAIL | R.OUT_PLUS), "a failure that took the plus is 0x21")
	lost.record.durability = 30
	_check(R.outcome(lost, 3, 40) == (R.OUT_FAIL | R.OUT_PLUS | R.OUT_DURABILITY), "and the durability 0x23")
	var gone := AlchemyNet.Result.new()
	gone.ok = true
	gone.destroyed = true
	_check(R.outcome(gone, 6, 40) == R.OUT_BREAKDOWN, "destroyed is 0x40")
	var stone_lost := AlchemyNet.Result.new()
	stone_lost.reinforce = false
	stone_lost.code = 0x5423
	_check(R.outcome(stone_lost, 0, 0) == R.OUT_STONE_FAIL, "a stone's lost roll is 0x80")
	var lines := R.outcome_lines(R.OUT_FAIL | R.OUT_PLUS | R.OUT_DURABILITY, true, 0, 3, 30, 40)
	_check(lines.size() == 2 and lines[0][0] == "UIIT_MSG_REINFORCERR_FAIL_RESULT_OPTLV_ZERO"
		and lines[1] == ["UIIT_MSG_REINFORCERR_FAILDOWN_DURABILITY", [30, 10]], "the failure lines (ShowOutcome 0x592650)")
	_check(R.outcome_lines(R.OUT_SUCCESS, false, 0, 0, 0, 0).is_empty(), "a stone's success writes no SUCCESS line")
	_check(R.fill("Success! [%d]", [4]) == "Success! [4]" and R.fill("a %s b %d", [1, 2]) == "a %s b 1"
		and R.fill("plain", [1]) == "plain", "fill replaces %d only")

func _wire() -> void:
	_check(AlchemyNet.OP_REQUEST == 0x0113 and AlchemyNet.OP_REINFORCE_RESULT == 0x0114 and AlchemyNet.OP_STONE_RESULT == 0x0115,
		"the opcodes the server pins")
	_check(AlchemyNet.encode_start(3, [0, 5]) == PackedByteArray([2, 3, 2, 13, 18]), "a start is u8 2, op, n, bag + 13")
	_check(AlchemyNet.encode_cancel() == PackedByteArray([1]), "a cancel is u8 1")
	var refused := AlchemyNet.decode_result(PackedByteArray([2, 0x09, 0x54]), true)
	_check(refused != null and not refused.ok and refused.code == 0x5409, "a refusal")
	var cancelled := AlchemyNet.decode_result(PackedByteArray([1, 1]), true)
	_check(cancelled != null and cancelled.cancelled, "a cancel")
	var destroyed := AlchemyNet.decode_result(PackedByteArray([1, 2, 0, 20, 1]), true)
	_check(destroyed != null and destroyed.destroyed and destroyed.bag_slot == 7 and destroyed.record == null, "destroyed: no record")
	var rec := PackedByteArray([1, 2, 1, 13])
	var body := PackedByteArray()
	body.resize(4 + 4 + 1 + 8 + 4 + 1)
	body.encode_u32(4, 100)
	body[8] = 4                 # +4
	body.encode_u32(17, 33)     # durability
	rec.append_array(body)
	rec.append_array(PackedByteArray([1, 0, 2, 0]))  # two empty binding blocks
	var won := AlchemyNet.decode_result(rec, false)
	_check(won != null and won.success and won.record != null and won.record.opt_level == 4 and won.record.durability == 33
		and won.bag_slot == 0, "a stone's success carries the record")

# --- the window ---------------------------------------------------------------

func _rec(f: Dictionary) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(RECORD)
	b.fill(0)
	for pair in [[0x000, "name"], [0x040, "base"], [0x140, "tex"]]:
		var bytes: PackedByteArray = str(f.get(pair[1], "")).to_ascii_buffer()
		for i in bytes.size():
			b[pair[0] + i] = bytes[i]
	b.encode_u32(0x340, f.get("type", 5))
	b.encode_u32(0x344, f.get("id", 0))
	b.encode_u32(0x348, f.get("parent", 0))
	b.encode_u32(0x34c, f.get("gp", 0))
	b.encode_u32(0x358, 0xffffffff)
	var r: Rect2i = f.get("rect", Rect2i())
	b.encode_s32(0x35c, r.position.x)
	b.encode_s32(0x360, r.position.y)
	b.encode_s32(0x364, r.size.x)
	b.encode_s32(0x368, r.size.y)
	b.encode_u32(0x390, 0xffffffff)
	b.encode_u32(0x394, 1 if f.get("root", false) else 0)
	b[0x3cd] = 1
	b[0x3ce] = 1
	return b

func _enchant() -> PackedByteArray:
	var recs := [
		{"type": 0, "id": 168, "name": "CNIFEnchantWnd", "root": true, "rect": Rect2i(413, 82, 389, 421)},
		{"type": 1, "id": 5, "name": "CNIFAlchemyWnd", "parent": 168, "rect": Rect2i(425, 146, 366, 343)},
		{"type": 4, "id": 22, "parent": 5, "gp": 168, "rect": Rect2i(552, 446, 112, 24)},
		{"type": 18, "id": 12, "name": "CNIFAlchemySubWndType1", "parent": 5, "gp": 168, "rect": Rect2i(435, 161, 343, 312)},
		{"type": 10, "id": 21, "parent": 12, "gp": 5, "rect": Rect2i(442, 413, 333, 12)},
		{"type": 18, "id": 17, "name": "CIFSlotWithHelpEx", "parent": 12, "gp": 5, "rect": Rect2i(451, 179, 32, 32)},
		{"type": 18, "id": 26, "name": "CIFSlotWithHelpEx", "parent": 12, "gp": 5, "rect": Rect2i(473, 343, 32, 32)},
		{"type": 18, "id": 27, "name": "CIFSlotWithHelpEx", "parent": 12, "gp": 5, "rect": Rect2i(552, 343, 32, 32)},
	]
	var out := PackedByteArray()
	out.resize(4)
	out.encode_u32(0, recs.size())
	for r in recs:
		out.append_array(_rec(r))
	return out

func _builder() -> UiBuilder:
	var rows := PackedStringArray()
	for pair in [["UIIT_MSG_REINFORCERR_SUCCESS", "tt success [%d]"], ["UIIT_MSG_REINFORCERR_FAIL", "tt fail"],
			["UIIT_MSG_REINFORCERR_FAIL_RESULT_OPTLV_ZERO", "tt zero"], ["UIIT_MSG_REINFORCERR_RECIPE_MISMATCH", "tt mismatch"],
			["UIIT_MSG_ENCHANT_LOAD_EQUIP_FIRST", "tt equip first"],
			["UIIT_CTL_ALCHEMYBOX_BUTTON_STRENGTHENING", "tt act 3"], ["UIO_COMMON_CTL_CANCEL", "tt cancel"],
			["UIIT_MSG_ALCHEMY_CANCELED_COMPOUND", "tt cancelled"]]:
		rows.append("1\t%s\t\t\t\t\t\t\t%s" % pair)
	var builder := UiBuilder.new(null, UiTextTable.parse(("\n".join(rows)).to_utf16_buffer()))
	var cache = builder.get("_twodt_cache")
	cache["res_ui\\nifenchantwnd.2dt"] = load(READER_PATH).parse(_enchant())
	return builder

func _window() -> void:
	AlchemyWindow.reset_tab_mode()
	var w := AlchemyWindow.new(_builder())
	root.add_child(w)
	_check(w.build_alchemy(), "the window builds")
	var lines: Array = []
	var starts: Array = []
	w.message.connect(func(t: String) -> void: lines.append(t))
	w.start_requested.connect(func(op: int, s: Array) -> void: starts.append([op, s]))
	var action := w.control([5, 22]) as BaseButton
	var gauge := w.control([5, 12, 21]) as Range
	_check(action != null and action.disabled, "the action starts disabled")
	_check(not w.offer_item(_elixir(), null) and lines.back() == "tt equip first", "an elixir first is refused: LOAD_EQUIP_FIRST")
	_check(w.offer_item(_sword(), null) and w.loaded(0) != null, "the sword goes in")
	_check(not w.offer_item(_armour_elixir(), null) and lines.back() == "tt mismatch", "the armour elixir is refused with its line")
	_check(w.offer_item(_elixir(), null) and not action.disabled, "the weapon elixir goes in and the action lights")
	w.press_action()
	_check(starts == [[3, [0, 1]]] and w.is_busy(), "the click sends op 3 with the two bag slots and the window is busy")
	w.tick(1500)
	_check(absf(gauge.value - 50.0) < 0.1, "the gauge is half full at 1.5 s (3.0 s, 0xd8adc4)")
	w.tick(1500)
	_check(not w.is_busy() and action.disabled, "at 3.0 s the attempt can no longer be cancelled")
	var r := AlchemyNet.Result.new()
	r.ok = true
	r.success = true
	r.record = ItemInstance.new()
	r.record.opt_level = 4
	w.apply_result(r)
	_check(lines.back() == "tt success [4]", "the success line names the new plus")
	var fx_on := w.find_child("AlchemyEffect", true, false) as TextureRect
	_check(fx_on != null and fx_on.visible and (fx_on.material as CanvasItemMaterial).blend_mode == CanvasItemMaterial.BLEND_MODE_ADD,
		"the success effect draws additively (mode 1)")
	_check(w.loaded(1) != null, "the elixir slot is still loaded while the effect plays")
	w.tick(8 * 50)
	_check(w.loaded(1) == null and w.loaded(0) != null and int(w.loaded(0)["plus"]) == 4,
		"at frame 8 the elixir slot is cleared; the target keeps its new plus")
	var effect := w.find_child("AlchemyEffect", true, false) as Control
	w.tick(8 * 50)
	_check(effect != null and not effect.visible, "at the wrap the effect hides")
	# A stone's lost roll: the fail line, and the target loaded again.
	_check(w.offer_item(_stone(), null), "a stone goes in")
	w.press_action()
	_check(starts.back() == [4, [0, 4]], "a stone sends op 4")
	var lost := AlchemyNet.Result.new()
	lost.reinforce = false
	lost.code = 0x5423
	w.apply_result(lost)
	_check(lines.back() == "tt fail" and w.loaded(0) == null and w.loaded(1) == null,
		"a lost stone roll shows the failure line and empties the window (0x59eb20's 0x80 branch)")
	var fx := effect as TextureRect
	_check(fx != null and fx.material is CanvasItemMaterial
		and (fx.material as CanvasItemMaterial).blend_mode == CanvasItemMaterial.BLEND_MODE_MIX,
		"the failure effect draws with the plain blend (mode 0)")
	w.tick(16 * 50)
	# A cancel before the run.
	w.offer_item(_sword(), null)
	w.offer_item(_elixir(), null)
	w.press_action()
	w.apply_result(AlchemyNet.decode_result(PackedByteArray([1, 1]), true))
	_check(lines.back() == "tt cancelled" and not w.is_busy() and w.loaded(1) != null, "a cancel keeps the slots")
	# Review F5: a stone over an elixir takes the powder out with it.
	w.offer_item(_powder(), null)
	_check(w.loaded(2) != null, "the powder goes in after the elixir")
	_check(w.offer_item(_stone(), null) and w.loaded(2) == null, "a stone over the elixir empties the powder slot")
	w.press_action()
	_check(starts.back() == [4, [0, 4]], "and the request names only the target and the stone")
	# Review F7 / F6: while the reply is out the window stays locked, past the
	# gauge; with no reply the attempt ends after the timeout.
	w.tick(3000.0)
	_check(not w.is_busy() and w.is_awaiting() and not w.offer_item(_elixir(), null), "after the gauge, still locked until the reply")
	w.tick(7000.0)
	_check(not w.is_awaiting() and not w.is_busy(), "no reply in 10 s ends the attempt")
	w.queue_free()
