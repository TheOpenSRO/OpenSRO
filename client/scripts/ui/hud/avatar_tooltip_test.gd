extends SceneTree

## Round 789: the avatar and devil's spirit tooltips (ItemTooltipLines.
## compose_avatar / compose_devil_spirit, READ c:0x682410 / c:0x67b460), the
## avatar blue-line table (c:0x669e20 / c:0x66a8c0) and the "(+x%)" cut
## (c:0x6720fe..0x6721ce), and the grant window's rules and list
## (GrantMagicAttributeWindow, READ c:0x80a320, c:0x8092f0, c:0x80a8c0). Text
## keys come back as "<KEY>" so the line order and formats are checked
## without the archive.
##
## NEGATIVE: before round 789 an avatar's tooltip was the generic "other
## item" one (name, type, requirements) with no blue lines.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

static func key_text(key: String, _fallback: String) -> String:
	return "<%s>" % key

static func item(id: int, t3: int, t4: int) -> ItemTableReader.Item:
	var it := ItemTableReader.Item.new()
	it.id = id
	it.code_name = "ITEM_TEST_%d" % id
	it.item_name = "Test Avatar"
	it.type_ids = PackedInt32Array([3, 1, t3, t4])
	it.item_class = 1
	it.req_gender = 1
	it.country = 3
	for i in 4:
		it.req_level_types.append(-1)
		it.req_levels.append(-1)
	return it

static func texts(lines: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for l in lines:
		out.append(String(l["text"]))
	return out

func _test_lines() -> void:
	var t := Callable(self, "key_text")
	_check(ItemTooltipLines.avatar_line("MATTR_AVATAR_STR", 1, t) == "<PARAM_STR> 1 <PARAM_INCREASE>", "STR: \"%s %d %s\"")
	_check(ItemTooltipLines.avatar_line("MATTR_AVATAR_HP", 150, t) == "<PARAM_HP> 150 <PARAM_INCREASE>", "HP: \"%s %d %s\"")
	_check(ItemTooltipLines.avatar_line("MATTR_AVATAR_HR", 5, t) == "<PARAM_HR> 5% <PARAM_INCREASE>", "HR: \"%s %d%% %s\"")
	_check(ItemTooltipLines.avatar_line("MATTR_AVATAR_MDIA_3", 1, t) == "<PARAM_AVATAR_MDIA> 1% <UIIT_STT_PROBABILITY>",
		"MDIA: its unit is UIIT_STT_PROBABILITY")
	_check(ItemTooltipLines.avatar_line("MATTR_AVATAR_INT_4", 1, t) == "<PARAM_INT> 1 <PARAM_INCREASE>", "INT_4 by the STR/INT rule")
	_check(ItemTooltipLines.avatar_line("MATTR_STR", 3, t) == "", "a code the table lacks builds nothing")
	_check(ItemTooltipLines.cut_plus("Str 3 Increase (+50%)") == "Str 3 Increase ", "the cut erases from the '(' before the '+', the space kept")
	_check(ItemTooltipLines.cut_plus("no plus here") == "no plus here" and ItemTooltipLines.cut_plus("a (+1%)", false) == "a (+1%)",
		"no '+', or a format without the percent: unchanged")
	var opts := [{"code": "MATTR_AVATAR_STR", "value": 1, "pct": 0, "level": 1}, {"code": "MATTR_STR", "value": 2, "pct": 40, "level": 1},
		{"code": "MATTR_STR_AVATAR", "value": 0, "pct": 0, "level": 5}]
	var blue := ItemTooltipLines.avatar_blue_lines(opts, t, true)
	_check(blue == PackedStringArray(["<PARAM_STR> 1 <PARAM_INCREASE>", "<PARAM_STR> 2 <PARAM_INCREASE> ", "<PARAM_STR> 5 <PARAM_INCREASE>"]),
		"an avatar's lines: the table's, a generic one cut, STR_AVATAR at 0 shows its row's level: %s" % [blue])

func _test_avatar_tooltip() -> void:
	var t := Callable(self, "key_text")
	var dress := item(5804, 13, 2)
	dress.max_magic_options = 4
	dress.child_item_count = 1
	var ctx := {"text": t, "type_name": "Dress", "description": "", "player": {},
		"instance": {"plus": 0, "avatar_options": [{"code": "MATTR_AVATAR_HP", "value": 150, "pct": 0, "level": 1}]}}
	var lines := ItemTooltipLines.compose(dress, ctx)
	var got := texts(lines)
	var want := PackedStringArray(["Test Avatar", "", "<UIIT_STT_ITEM_TYPE>: Dress", "",
		"<UIIT_STT_SILKMALL_ATTACH>: <UIIT_STT_AVATAR_WEAR>",
		"<UIIT_STT_AVATAR_MAGICOPTION_MAXCOUNT>: 4<UIIT_STT_UNIT>", "", "<UIO_NEWCHAR_CTL_MALE>", "",
		"<PARAM_HP> 150 <PARAM_INCREASE>"])
	_check(got == want, "the dress's lines in c:0x682410's order:\n  got  %s\n  want %s" % [got, want])
	_check(lines[0]["color"] == ItemTooltipLines.CYAN and lines[0]["bold"] and lines[2]["color"] == ItemTooltipLines.BEIGE
		and lines[4]["color"] == ItemTooltipLines.BEIGE and lines[9]["color"] == ItemTooltipLines.CYAN,
		"the name cyan with options, the type and the dress lines beige, the option cyan")
	dress.child_item_count = 0
	_check(texts(ItemTooltipLines.compose(dress, ctx)).has("<UIIT_STT_SILKMALL_ATTACH>: <UIIT_STT_AVATAR_NOT_WEAR>"),
		"a dress that takes no attachment says NOT_WEAR")
	var hat := item(3756, 13, 1)
	hat.max_magic_options = 2
	var hat_lines := texts(ItemTooltipLines.compose(hat, {"text": t, "type_name": "Hat", "instance": {}}))
	_check(not hat_lines.has("<UIIT_STT_SILKMALL_ATTACH>: <UIIT_STT_AVATAR_WEAR>") and hat_lines.has("<UIIT_STT_AVATAR_MAGICOPTION_MAXCOUNT>: 2<UIIT_STT_UNIT>")
		and hat_lines[0] == "Test Avatar", "a hat: no attachment line, its own count; white name without options")

func _test_spirit_tooltip() -> void:
	var t := Callable(self, "key_text")
	var spirit := item(24971, 14, 1)
	spirit.param1 = 2419200
	var groups := [[{"code": "MATTR_NASRUN_HPNA", "value": 14, "pct": 0, "level": 1, "text": ""}],
		[{"code": "MATTR_NASRUN_MPNA", "value": 15, "pct": 0, "level": 1, "text": ""}], []]
	var ctx := {"text": t, "type_name": "Devil's Spirit", "ability_groups": groups, "instance": {"plus": 1}}
	var got := texts(ItemTooltipLines.compose(spirit, ctx))
	var want := PackedStringArray(["Test Avatar (+1)", "", "<UIIT_STT_ITEM_TYPE>: Devil's Spirit", "",
		"<UIIT_STT_NASRUN_BASIC_OPTION>", "<PARAM_MAX><PARAM_HP> 14% <PARAM_INCREASE>", "",
		"<UIIT_STT_NASRUN_ADD_OPTION>", "<PARAM_MAX><PARAM_MP> 15% <PARAM_INCREASE>", "",
		"<UIIT_STT_NASRUN_AWAKE_TIME>", "28<PARAM_DAY>"])
	_check(got == want, "a devil's spirit never activated, c:0x67b460's order:\n  got  %s\n  want %s" % [got, want])
	ctx["instance"] = {"plus": 0, "period": (1 << 31) | (2 * 86400 + 3 * 3600 + 4 * 60 + 5)}
	ctx["ability_groups"] = []
	var active := texts(ItemTooltipLines.compose(spirit, ctx))
	_check(active[active.size() - 1] == "2<PARAM_DAY> 3<PARAM_HOUR> 4<PARAM_MINUTE>", "active: days, hours, minutes left (%s)" % active[active.size() - 1])
	ctx["instance"] = {"plus": 0, "period": 1 << 31}
	var over := texts(ItemTooltipLines.compose(spirit, ctx))
	_check(over[over.size() - 1] == "<UIIT_STT_NASRUN_AWAKE_TIMEOVER>", "active with no time left: TIMEOVER")
	spirit.param1 = -1
	ctx["instance"] = {}
	var never := texts(ItemTooltipLines.compose(spirit, ctx))
	_check(never[never.size() - 1] == "<UIIT_STT_NASRUN_NOT_AWAKE>", "Param1 -1 and not active: NOT_AWAKE")

## A synthetic magicoption table (test rows: id, code, sign, degree, cols 8..10).
static func options() -> MagicOptionTable:
	var rows := PackedStringArray()
	for r in [[291, "MATTR_AVATAR_STR", "+", 1, 1, 1, 1], [292, "MATTR_AVATAR_INT", "+", 1, 1, 1, 1],
			[293, "MATTR_AVATAR_HP", "+", 1, 1, 150, 150], [294, "MATTR_AVATAR_HR", "+", 1, 6, 5, 5],
			[295, "MATTR_TEST_MINUS", "-", 1, 1, 1, 1]]:
		var cols := PackedStringArray(["1", str(r[0]), r[1], r[2], str(r[3]), "0", "0", "0", str(r[4]), str(r[5]), str(r[6])])
		rows.append("\t".join(cols))
	var data := PackedByteArray([0xFF, 0xFE])
	data.append_array("\n".join(rows).to_utf16_buffer())
	return MagicOptionTable.new().load(data)

static func tables() -> AvatarTables:
	var t := AvatarTables.new()
	t.parse_assign("1\t3\t13\t1\tMATTR_AVATAR_STR\tMATTR_AVATAR_INT\txxx\n1\t3\t13\t2\tMATTR_AVATAR_STR\tMATTR_AVATAR_HP\tMATTR_AVATAR_HR\txxx\n")
	t.parse_abilities("1\t7\t24971\t0\n1\t8\t24971\t3\n")
	t.parse_ability_options("7\t354\t14\t0\txxx\n7\t355\t15\t1\txxx\n8\t354\t20\t0\txxx\n")
	return t

func _test_grant() -> void:
	var G := GrantMagicAttributeWindow
	var t := Callable(self, "key_text")
	var dress := item(5804, 13, 2)
	dress.max_magic_options = 4
	var flag := item(9900, 13, 4)
	var spirit := item(24971, 14, 1)
	var bionic := item(5805, 13, 2)
	bionic.bionic = 1
	_check(G.accepts(dress) and not G.accepts(flag) and not G.accepts(spirit) and not G.accepts(bionic) and not G.accepts(null),
		"the window takes a hat, dress or attachment only (not 13/4, 14, bionic)")
	var table := options()
	var inst := ItemInstance.new()
	inst.ref_item_id = 5804
	inst.mag_params.append(291 | (1 << 32))
	inst.mag_params.append(295 | (1 << 32))
	_check(G.option_count(inst, table) == 1, "the count leaves out a '-' option (INFERRED)")
	var rows := G.grantable(dress, inst, tables(), table)
	var codes := []
	for r in rows:
		codes.append([r["code"], r["value"]])
	_check(codes == [["MATTR_AVATAR_HP", 150], ["MATTR_AVATAR_HR", 5]],
		"the dress's names minus the STR it has, each with column 9 (%s)" % [codes])
	_check(G.count_line(dress, 1, t) == "<UIIT_STT_SILKMALL_DRESS> - <UIIT_STT_AVATAR_MAGICOPTION_ADD_COUNT>: 3<UIIT_STT_UNIT>",
		"ID 9's line (c:0x8092f0): \"%s - \" then \"%s: %d%s\"")
	_check(G.can_send(dress, 3) and not G.can_send(dress, 4), "Confirm sends below MaxMagicOptCount only (c:0x80a8c0)")
	var sent := []
	var said := []
	var w := G.new()
	w.tables = tables()
	w.options = table
	w.text = t
	w.send = func(slot: int, code: String) -> void: sent.append([slot, code])
	w.message = func(m: String) -> void: said.append(m)
	_check(not w.offer(3, flag, null) and said == ["<UIIT_STT_AVATAR_MAGICOPTION_ONLY_AVATAR>"], "a flag is refused with ONLY_AVATAR")
	_check(w.offer(3, dress, inst) and w.rows.size() == 2 and String(w.rows[0]["text"]) == "<PARAM_HP> 150 <PARAM_INCREASE>",
		"the dress goes in; its rows read through the avatar table")
	_check(not w.confirm() and sent.is_empty(), "no row selected: nothing sent")
	w.select(1)
	_check(w.confirm() and sent == [[3, "MATTR_AVATAR_HR"]], "Confirm sends 0x34A9 for the selected row (%s)" % [sent])
	var granted := ItemInstance.new()
	granted.ref_item_id = 5804
	granted.slot = 3
	granted.mag_params = inst.mag_params.duplicate()
	granted.mag_params.append(294 | (5 << 32))
	w.apply_result({"ok": true, "flag": 1, "slot": 16, "item": granted})
	_check(w.rows.size() == 1 and String(w.rows[0]["code"]) == "MATTR_AVATAR_HP" and said[said.size() - 1] == "<UIIT_MSG_AVATAR_MAGICOPTION_ADD>",
		"the reply: the granted row is gone, ADD shown")
	w.apply_result({"ok": false, "code": 0xa})
	_check(said[said.size() - 1] == "<UIIT_STT_AVATAR_MAGICOPTION_WRONG>", "a refusal (0xa) names WRONG")
	var capped := ItemInstance.new()
	capped.ref_item_id = 5804
	for id in [291, 292, 293, 294]:
		capped.mag_params.append(id | (1 << 32))
	var dress2 := item(5804, 13, 2)
	dress2.max_magic_options = 4
	w.offer(5, dress2, capped)
	w.rows = [{"code": "MATTR_AVATAR_LUCK", "value": 1, "text": "x"}]
	w.select(0)
	_check(not w.confirm() and said[said.size() - 1] == "<UIIT_MSG_AVATAR_MAGICOPTION_ADD_ERORR>", "at the cap: ADD_ERORR, nothing sent")
	var ab := tables()
	_check(ab.ability_of(24971, 0) == 7 and ab.ability_of(24971, 2) == 7 and ab.ability_of(24971, 5) == 8 and ab.ability_of(1, 0) == -1,
		"the ability of (RefItemID, plus) falls back to the highest lower plus (FUN_008bf680)")
	_check(ab.ability_entries(7, 0).size() == 1 and int(ab.ability_entries(7, 1)[0]["option"]) == 355, "an ability's entries by group")

func _init() -> void:
	_test_lines()
	_test_avatar_tooltip()
	_test_spirit_tooltip()
	_test_grant()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
