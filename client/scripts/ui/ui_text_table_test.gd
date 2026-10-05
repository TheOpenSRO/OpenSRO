extends SceneTree

const UiTextTable = preload("res://scripts/ui/ui_text_table.gd")

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _init() -> void:
	# Test with synthetic UTF-16LE data
	var s1 := "1\tUIIT_STT_GOLD\t금\t\t\t\t\t\tGold\n1\tUIIS_CTL_EXIT\t종료\t\t\t\t\t\tExit\n"
	var bytes := s1.to_utf16_buffer()

	var table := UiTextTable.parse(bytes)
	_check(table.count() == 2, "parsed 2 tokens")
	_check(table.has("UIIT_STT_GOLD"), "has UIIT_STT_GOLD")
	_check(table.get_text("UIIT_STT_GOLD") == "Gold", "UIIT_STT_GOLD resolves to Gold (got %s)" % table.get_text("UIIT_STT_GOLD"))
	_check(table.get_text("UIIS_CTL_EXIT") == "Exit", "UIIS_CTL_EXIT resolves to Exit (got %s)" % table.get_text("UIIS_CTL_EXIT"))
	_check(table.get_text("NON_EXISTENT") == "NON_EXISTENT", "fallback to token itself")
	_check(table.get_text("NON_EXISTENT", "Default") == "Default", "fallback to custom default")

	# The real file's shape, which the fixed-column reader got wrong. Two
	# rows for the same token, of different widths, where the conventional
	# English column holds the "0" filler in the wider one -- taken
	# verbatim from a real textuisystem.txt.
	var varying := PackedStringArray([
		"1\tUIIT_STT_PHYSICAL_ATTACK\t\u1355\t0\t0\t0\t0\t0\tPhy. Atk:\tPhy. Atk:\t0\t0\t0\t0\t0\t0",
		"1\tUIIT_STT_PHYSICAL_ATTACK\t\u1355\t0\t0\t0\t0\t0\t0\tPhy. atk\t0\t0\t0\t0\t0\t0\t0\t0\t0",
		"1\tUIIT_STT_HIT_RATIO\t\u1355\t0\t0\t0\t0\t0\t0\tHit rate\t0\t0\t0\t0\t0\t0\t0\t0\t0",
	])
	var varying_table := UiTextTable.parse(("\n".join(varying)).to_utf16_buffer())
	# The FIRST row for a key wins, as the client's loader keeps it (round
	# 634's review: 0x8ca120's insert returns the existing entry).
	_check(varying_table.get_text("UIIT_STT_PHYSICAL_ATTACK") == "Phy. Atk:",
		"the first row of a duplicated key wins (got %s)" % varying_table.get_text("UIIT_STT_PHYSICAL_ATTACK"))
	var script: Script = load("res://scripts/ui/ui_text_table.gd")
	var parse_args := 0
	for m in script.get_script_method_list():
		if m["name"] == "parse":
			parse_args = (m["args"] as Array).size()
	if parse_args >= 3:
		var last_table = script.call("parse", ("\n".join(varying)).to_utf16_buffer(), 8, false)
		_check(last_table.get_text("UIIT_STT_PHYSICAL_ATTACK") == "Phy. atk",
			"picks the English column even when it moves; keep_first false keeps the last row (got %s)" % last_table.get_text("UIIT_STT_PHYSICAL_ATTACK"))
	else:
		_check(false, "parse takes keep_first (the old last-row rule as an option)")
	var dup := PackedStringArray([
		"1\tUIIT_CTL_CHATMENU_TRAININGCAMP\t&???\t0\t0\t0\t0\t0\t&Team\t&Team\t0",
		"1\tUIIT_CTL_CHATMENU_TRAININGCAMP\t&x\t0\t0\t0\t0\t0\t0\t&Academy\t0",
	])
	var dup_table := UiTextTable.parse(("\n".join(dup)).to_utf16_buffer())
	_check(dup_table.get_text("UIIT_CTL_CHATMENU_TRAININGCAMP") == "&Team",
		"the private archive's first row is what the table holds (got %s)" % dup_table.get_text("UIIT_CTL_CHATMENU_TRAININGCAMP"))
	_check(varying_table.get_text("UIIT_STT_HIT_RATIO") == "Hit rate",
		"a row whose column 8 is the \"0\" filler still resolves (got %s)" % varying_table.get_text("UIIT_STT_HIT_RATIO"))

	# A multi-language archive: English in column 8 with Spanish and Arabic
	# to its right, a row whose column 8 is the filler and whose English
	# sits at 9 ahead of a Vietnamese column, and a name whose Arabic column
	# also carries the Latin name. Each must come out English -- the old
	# rightmost-first rule labelled every NPC in Jangan in Arabic or Spanish
	# on such an archive.
	var multi := PackedStringArray([
		"1\tSN_NPC_ARENA\tፕ\t0\t0\t0\t0\t0\tArena Manager\t0\tAdministrador de Arena\tمدير\t0",
		"1\tSN_ITEM_BOX\tፕ\t0\t0\t0\t0\t0\t0\tJewel Box\t0\tHép b¸u vËt\t0",
		"1\tSN_NPC_DANGSAM\tፕ\t0\t0\t0\t0\t0\tSoldier Dangsam\t0\t0\tDangsam الجندي\t0",
	])
	var multi_table := UiTextTable.parse(("\n".join(multi)).to_utf16_buffer())
	_check(multi_table.get_text("SN_NPC_ARENA") == "Arena Manager",
		"column 8 wins over a Spanish column to its right (got %s)" % multi_table.get_text("SN_NPC_ARENA"))
	_check(multi_table.get_text("SN_ITEM_BOX") == "Jewel Box",
		"the first Latin field after a filler column 8 wins over a later Vietnamese one (got %s)" % multi_table.get_text("SN_ITEM_BOX"))
	_check(multi_table.get_text("SN_NPC_DANGSAM") == "Soldier Dangsam",
		"an Arabic column carrying the Latin name does not beat column 8 (got %s)" % multi_table.get_text("SN_NPC_DANGSAM"))

	# The service column (TextStringManager 0x8cac30, 0x8cb110..0x8cb118): a
	# row loads only when column 0 reads 1. A disabled first row gives way to
	# the enabled one after it, and a continuation line of a multi-line value
	# (column 0 "<font ...") never becomes a key.
	var svc := PackedStringArray([
		"0\tUIIT_STT_SVC\t\u1355\t0\t0\t0\t0\t0\tDisabled row\t0",
		"1\tUIIT_STT_SVC\t\u1355\t0\t0\t0\t0\t0\tEnabled row\t0",
		"<font color=red>\tFRAGMENT_KEY\t0\t0\t0\t0\t0\t0\tFragment\t0",
	])
	var svc_table := UiTextTable.parse(("\n".join(svc)).to_utf16_buffer())
	_check(svc_table.get_text("UIIT_STT_SVC") == "Enabled row",
		"a row whose service column is not 1 is skipped (got %s)" % svc_table.get_text("UIIT_STT_SVC"))
	_check(not svc_table.has("FRAGMENT_KEY"), "a continuation line never becomes a key")

	# A first row with no Latin text anywhere: the client shows its language
	# column's own field ("0" here), not the Korean column 2 nor the token, and
	# the English row after it is ignored (first row wins). The shape is the
	# box archive's SN_ITEM_ETC_E060823_SATGAT_INT3_M.
	var hat := PackedStringArray([
		"1\tSN_ITEM_HAT\t??? ?? (?)\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0",
		"1\tSN_ITEM_HAT\t\t\t\t\t\t\t\tRebecca Event Hat (M)\t\t\t\t\t\t\t",
		"1\tSN_ITEM_BLANK\t\u1355\t\t\t\t\t\t\t\t",
	])
	var hat_table := UiTextTable.parse(("\n".join(hat)).to_utf16_buffer())
	_check(hat_table.get_text("SN_ITEM_HAT") == "0",
		"a no-Latin first row holds its language column's \"0\", as the client draws it (got %s)" % hat_table.get_text("SN_ITEM_HAT"))
	_check(hat_table.has("SN_ITEM_BLANK") and hat_table.get_text("SN_ITEM_BLANK", "x") == "",
		"a no-Latin first row with a blank language column holds \"\" (got %s)" % hat_table.get_text("SN_ITEM_BLANK", "x"))

	_joined_checks()

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		push_error("%d failure(s)" % _failures)
		quit(1)

# USER DECISION (2026-10-05, round 725): in a table that is two whole tables
# joined -- a private server's reworded block, then the stock one -- the
# stock row wins; a single table keeps every first row as before.
func _row16(key: String, english: String) -> String:
	return "1\t%s\t\u1355\t0\t0\t0\t0\t0\t%s\t%s\t0\t0\t0\t0\t0\t0" % [key, english, english]

func _row19(key: String, english: String) -> String:
	return "1\t%s\t\u1355\t0\t0\t0\t0\t0\t0\t%s\t0\t0\t0\t0\t0\t0\t0\t0\t0" % [key, english]

func _joined_checks() -> void:
	var first := PackedStringArray(["//Private block"])
	var second := PackedStringArray(["//Stock block"])
	for i in 10:
		first.append(_row16("UIIT_K%d" % i, "Reworded %d" % i))
	first.append(_row16("UIIT_PRIVATE_ONLY", "Private only"))
	for i in 10:
		if i == 5:
			# A stock row with no English (Korean only, as UIO_MSG_AUTOLOGIN).
			second.append("1\tUIIT_K5\t\u1355\u1356")
		else:
			second.append(_row19("UIIT_K%d" % i, "Stock %d" % i))
	second.append(_row19("UIIT_STOCK_ONLY", "Stock only"))
	var joined := UiTextTable.parse(("\n".join(first + second)).to_utf16_buffer())
	_check(joined.get_text("UIIT_K1") == "Stock 1" and joined.get_text("UIIT_K0") == "Stock 0",
		"a joined table: the stock (later) table's row wins (got %s, %s)" % [joined.get_text("UIIT_K0"), joined.get_text("UIIT_K1")])
	_check(joined.get_text("UIIT_K5") == "Reworded 5",
		"OURS: a stock row with no English does not replace an English one (got %s)" % joined.get_text("UIIT_K5"))
	_check(joined.get_text("UIIT_PRIVATE_ONLY") == "Private only" and joined.get_text("UIIT_STOCK_ONLY") == "Stock only",
		"keys in only one of the two tables keep their row")
	var toks := PackedStringArray()
	for i in 10:
		toks.append("K%d" % i)
	toks.append("P")
	for i in 10:
		toks.append("K%d" % i)
	_check(UiTextTable.joined_table_start(toks) == 11, "the second table starts where the opening keys restart in order (got %d)" % UiTextTable.joined_table_start(toks))
	var last := UiTextTable.parse(("\n".join(first + second)).to_utf16_buffer(), 8, false)
	_check(last.get_text("UIIT_K5") == "", "keep_first false still keeps the last row, whatever it holds (got %s)" % last.get_text("UIIT_K5"))

	# A single table is unchanged: a stray repeated key, even of the stock
	# 19-column shape, does not make it joined -- the first row wins.
	var single := first.duplicate()
	single.append(_row19("UIIT_K3", "Stock 3"))
	var one := UiTextTable.parse(("\n".join(single)).to_utf16_buffer())
	_check(one.get_text("UIIT_K3") == "Reworded 3", "NEGATIVE: a single table keeps the first row (got %s)" % one.get_text("UIIT_K3"))
	# Nor does a restart of the first key that does not repeat the opening
	# keys in order for JOINED_MIN_RUN rows.
	var short := first.duplicate()
	for i in 3:
		short.append(_row19("UIIT_K%d" % i, "Stock %d" % i))
	var short_t := UiTextTable.parse(("\n".join(short)).to_utf16_buffer())
	_check(short_t.get_text("UIIT_K0") == "Reworded 0", "NEGATIVE: a 3-key restart is not a second table (got %s)" % short_t.get_text("UIIT_K0"))

