extends SceneTree

## Round 838: the skin change window's choices (SkinChangeModel) and its use's
## bytes (UseItemNet.encode_use_skin).

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _init() -> void:
	_run()
	if _failures == 0:
		print("ALL PASS")
	quit(1 if _failures > 0 else 0)

func _run() -> void:
	# The usable-id file: "<service>\t<id>" rows (BOM, CRLF), service 0 dropped.
	var ids := SkinChangeModel.parse_usable_ids("﻿1\t1907\r\n1\t1909\r\n0\t1910\r\n1\t1923\r\n1\t14875\r\n1\t3632\r\n")
	_check(ids == [1907, 1909, 1923, 14875, 3632], "parse keeps service-1 ids in order (got %s)" % str(ids))
	var bodies := {1907: {"race": 0, "sex": 1}, 1909: {"race": 0, "sex": 1}, 1923: {"race": 0, "sex": 0},
		14875: {"race": 1, "sex": 1}}
	var m := SkinChangeModel.from_ids(ids, 0, func(id: int) -> Dictionary: return bodies.get(id, {}))
	_check(m.men == [1907, 1909] and m.women == [1923], "China's lists by sex, items and Europe out (men %s women %s)" % [str(m.men), str(m.women)])
	m.start(1909, SkinChangeModel.SEX_MAN, 0x22)
	_check(m.figure == 2 and m.chosen_id() == 1909, "FIGURE starts on the player's own body")
	_check(m.height() == 2 and m.weight() == 2, "HEIGHT and WEIGHT start on the scale byte's nibbles")
	_check(not m.can_confirm(), "Confirm is off while nothing changed")
	m.set_height(4)
	_check(m.scale == 0x24 and m.can_confirm(), "a height change enables Confirm (scale 0x%02x)" % m.scale)
	m.set_height(2)
	m.set_figure(1)
	_check(m.chosen_id() == 1907 and m.can_confirm(), "another body enables Confirm")
	_check(m.precheck([0, 6], 0) == 0, "the same sex sends with gear on")
	m.set_sex(SkinChangeModel.SEX_WOMAN)
	_check(m.figure == 1 and m.chosen_id() == 1923 and m.figure_count() == 1, "Female shows the woman's list from 1")
	_check(m.precheck([6, 7], 0) == 0, "a change of sex with only the weapon and shield on sends")
	_check(m.precheck([0], 0) == SkinChangeModel.ERR_ARMOR, "a change of sex with a helm on is refused 0x1892")
	_check(m.precheck([8], 0) == SkinChangeModel.ERR_ARMOR, "... with slot 8 on")
	_check(m.precheck([], 1) == SkinChangeModel.ERR_ARMOR, "... with an avatar held")
	m.set_weight(9)
	_check(m.weight() == 4, "WEIGHT clamps to 4")
	# The wire: the plain use, 0xFC, u32 ref, u8 scale.
	var b := UseItemNet.encode_use_skin("Aria", 4, 1923, 0x34)
	var plain := UseItemNet.encode_use("Aria", 4)
	_check(b.size() == plain.size() + 6, "the use carries 6 more bytes (got %d)" % (b.size() - plain.size()))
	_check(b.slice(0, plain.size()) == plain, "it starts with the plain use")
	_check(b[plain.size()] == 0xFC, "then the option 0xFC")
	_check(b.decode_u32(plain.size() + 1) == 1923 and b[plain.size() + 5] == 0x34, "then the ref and the scale")
