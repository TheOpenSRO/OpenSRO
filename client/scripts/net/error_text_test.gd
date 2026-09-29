extends SceneTree

## ErrorText (scripts/net/error_text.gd) against a SYNTHETIC UI text table:
## the rows below are shaped like textuisystem.txt (token in column 1, the
## English in column 8) but every string is made up, so a pass proves the
## text came from the table and not from the fallback wording.

const UiTextTable = preload("res://scripts/ui/ui_text_table.gd")
const ErrorText = preload("res://scripts/net/error_text.gd")
const UiBuilder = preload("res://scripts/ui/ui_builder.gd")

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## One textuisystem-shaped row: token at 1, "0" filler, English at 8.
func _row(token: String, english: String) -> String:
	return "1\t%s\t0\t0\t0\t0\t0\t0\t%s\t0" % [token, english]

func _table(rows: PackedStringArray) -> UiTextTable:
	return UiTextTable.parse(("\n".join(rows)).to_utf16_buffer())

func _init() -> void:
	var fixture := _table(PackedStringArray([
		_row("UIIT_MSG_STRGERR_CANNOT_BE_PICKED", "Fixture cannot pick "),
		_row("UIIT_MSG_STRGERR_LOCKED_BY_OTHER_ONE", "Fixture not yours"),
		_row("UIIT_MSG_INTERACTION_FAIL_NOT_ENOUGH_MONEY", "Fixture no gold"),
		_row("UIIT_MSG_INTERACTION_FAIL_CANNOT_BE_REPAIRED", "Fixture unrepairable"),
		_row("UIIT_MSG_INTERACTION_FAIL_IM_BUSY", "Fixture on other business"),
		# Present so the guards below prove they are NOT borrowed by analogy.
		_row("UIIT_MSG_STRGERR_BUSY", "Fixture busy"),
		_row("UIIT_MSG_STRGERR_INVALID_TARGET", "Fixture invalid target"),
		_row("UIIT_STT_ERR_COMMON_TOO_FAR", "Fixture too far"),
		# A row with no usable text anywhere: the parser stores its language
		# column's "0" filler, as the client's loader does (0x8c6a90 keeps the
		# field as it stands) -- never the token.
		"1\tUIIT_MSG_INTERACTION_FAIL_CANNOT_BE_REVIVED\t0\t0\t0\t0\t0\t0\t0\t0",
	]))

	# NEGATIVE (fails before round 515, when every line was our own wording):
	# the game's own text, read from the table, for the four codes the
	# client has a case for.
	var picked := ErrorText.pick_up_line(0x1839, fixture)
	_check(picked == "Fixture cannot pick", "0x1839 pick-up shows the table's CANNOT_BE_PICKED text; UiTextTable.parse strips the trailing space (got %s)" % picked)
	var locked := ErrorText.pick_up_line(0x1812, fixture)
	_check(locked == "Fixture not yours", "0x1812 pick-up shows the table's LOCKED_BY_OTHER_ONE text (got %s)" % locked)
	var no_gold := ErrorText.repair_line(0x1c07, fixture)
	_check(no_gold == "Fixture no gold", "0x1c07 repair shows the table's NOT_ENOUGH_MONEY text (got %s)" % no_gold)
	var unrepairable := ErrorText.repair_line(0x1c11, fixture)
	_check(unrepairable == "Fixture unrepairable", "0x1c11 repair shows the table's CANNOT_BE_REPAIRED text (got %s)" % unrepairable)

	# NEGATIVE (fails before round 518, when 0x1c0b had no row and showed
	# "Repair refused (code 0x1c0b)."): the busy refusal a trade causes is the
	# interaction table's entry 4, 0x7ba09d push 0xdc24d0.
	# The key is echoed only on a miss: it contains "FAIL", which
	# remote_godot.sh's result grep would read as a failing suite.
	var busy_key := ErrorText.uiit_key(0x1c0b)
	var busy_key_ok := busy_key == "UIIT_MSG_INTERACTION_FAIL_IM_BUSY"
	_check(busy_key_ok, "0x1c0b's message name is the interaction switch's IM_BUSY key"
		+ ("" if busy_key_ok else " (got '%s')" % busy_key))
	var busy_repair := ErrorText.repair_line(0x1c0b, fixture)
	_check(busy_repair == "Fixture on other business", "0x1c0b repair shows the table's IM_BUSY text (got %s)" % busy_repair)
	var busy_fallback := ErrorText.repair_line(0x1c0b, _table(PackedStringArray([_row("UIIT_MSG_INTERACTION_FAIL_NOT_ENOUGH_MONEY", "Fixture no gold")])))
	_check(busy_fallback == "You are busy with something else.", "0x1c0b without an IM_BUSY row gives its own fallback, not the code (got %s)" % busy_fallback)

	# 0x1c12 read from a row that HAS text. The fixture's REVIVED row below is
	# deliberately empty, and a fallback there would also pass with a key typo;
	# this one cannot.
	var revivable := _table(PackedStringArray([_row("UIIT_MSG_INTERACTION_FAIL_CANNOT_BE_REVIVED", "Fixture unrevivable")]))
	var unrevivable := ErrorText.repair_line(0x1c12, revivable)
	_check(unrevivable == "Fixture unrevivable", "0x1c12 repair shows the table's CANNOT_BE_REVIVED text (got %s)" % unrevivable)

	# resolve()'s own strip. UiTextTable.parse already strips every field, so
	# the table is filled directly here, with padding parse would have removed.
	var padded := UiTextTable.new()
	padded._strings["UIIT_MSG_INTERACTION_FAIL_NOT_ENOUGH_MONEY"] = "  Fixture padded gold \t"
	padded._strings["UIIT_MSG_INTERACTION_FAIL_CANNOT_BE_REPAIRED"] = "   "
	var stripped := ErrorText.resolve(0x1c07, padded, "fallback")
	_check(stripped == "Fixture padded gold", "resolve strips the stored text itself (got '%s')" % stripped)
	var blank := ErrorText.resolve(0x1c11, padded, "fallback")
	_check(blank == "fallback", "a stored text that strips to nothing gives the fallback (got '%s')" % blank)

	# Guards: the codes the client has no case for keep our own wording.
	_check(ErrorText.uiit_key(0x1813) == "", "0x1813 has no client message name (the storage switch's default)")
	var busy := ErrorText.pick_up_line(0x1813, fixture)
	_check(busy == "Someone else is picking that up.", "0x1813 keeps its fallback even with STRGERR_BUSY in the table (got %s)" % busy)
	_check(ErrorText.uiit_key(0x1c09) == "", "0x1c09 has no client message name (the interaction switch's default)")
	var whole := ErrorText.repair_line(0x1c09, fixture)
	_check(whole == "Nothing needs repairing.", "0x1c09 repair gives its fallback (got %s)" % whole)
	_check(ErrorText.uiit_key(4) == "", "4 has no message name here (category-dependent)")
	var far := ErrorText.pick_up_line(4, fixture)
	_check(far == "That drop is out of reach.", "4 pick-up keeps its fallback even with ERR_COMMON_TOO_FAR in the table (got %s)" % far)
	var gone := ErrorText.pick_up_line(3, fixture)
	_check(gone == "That drop is no longer there.", "3 pick-up keeps its fallback even with STRGERR_INVALID_TARGET in the table (got %s)" % gone)

	# The missing-key trap: get_text() answers the raw token for a key the
	# table lacks. A table without CANNOT_BE_PICKED must give the fallback.
	var sparse := _table(PackedStringArray([_row("UIIT_MSG_STRGERR_LOCKED_BY_OTHER_ONE", "Fixture not yours")]))
	var missing := ErrorText.pick_up_line(0x1839, sparse)
	_check(missing == "That item cannot be picked up.", "a table without CANNOT_BE_PICKED gives the fallback (got %s)" % missing)
	_check(missing.find("UIIT_") < 0, "the raw token is never shown for a missing key")
	# ...and a row with no usable text (the fixture's all-"0" REVIVED row)
	# shows what the client draws for it, the "0" filler, never the token
	# (rounds 633-635 integration review; no real key ErrorText resolves has
	# such a first row on the box's archive).
	var revived := ErrorText.repair_line(0x1c12, fixture)
	_check(revived == "0" and revived.find("UIIT_") < 0, "a row with no usable text shows the client's \"0\", not the token (got %s)" % revived)

	# No table at all (an archive not loaded yet).
	var no_table := ErrorText.pick_up_line(0x1812, null)
	_check(no_table == "That drop still belongs to someone else.", "a null table gives the fallback (got %s)" % no_table)
	_check(ErrorText.repair_line(0x1c07, null) == "Not enough gold.", "a null table gives the repair fallback")

	# Codes nobody names.
	var unknown := ErrorText.repair_line(0x1234, fixture)
	_check(unknown == "Repair refused (code 0x1234).", "an unknown repair code names itself (got %s)" % unknown)
	var unknown_pick := ErrorText.pick_up_line(0x1234, fixture)
	_check(unknown_pick == "Could not pick that up (code 0x1234).", "an unknown pick-up code names itself (got %s)" % unknown_pick)

	# Round 528: the guild switch's rows (category 0x10, the category the
	# level-up reply's own handler passes: Guild_OnLevelUpResult 0x881c53).
	# NEGATIVE (fails before round 528, when these codes had no row): the
	# table's text, not the server's words.
	var guild_table := _table(PackedStringArray([
		_row("UIIT_MSG_GUILDERR_IM_DEAD", "Fixture guild dead"),
		_row("UIIT_MSG_GUILDERR_PERMISSION_DENIED", "Fixture not the master"),
		_row("UIIT_MSG_ERROR_GUILD_LEVEL_UP_FULL", "Fixture top level"),
		_row("UIIT_MSG_ERROR_GUILD_LEVEL_UP_GOLD_DEFICIT", "Fixture guild gold short"),
		_row("UIIT_MSG_ERROR_GUILD_LEVEL_UP_GP_DEFICIT", "Fixture guild points short"),
	]))
	for pair in [[0x4c07, "Fixture guild dead"], [0x4c1e, "Fixture not the master"],
			[0x4c21, "Fixture top level"], [0x4c31, "Fixture guild gold short"],
			[0x4c32, "Fixture guild points short"]]:
		var code: int = pair[0]
		var want: String = pair[1]
		var got: String = ErrorText.guild_level_up_line(code, guild_table, "server words")
		_check(got == want, "0x%x level-up refusal shows the table's text (got %s)" % [code, got])
	# 0x4c0d goes to the guild switch's default (index byte 0x41 at 0x7bbc87):
	# the server's own words stand.
	_check(ErrorText.uiit_key(0x4c0d) == "", "0x4c0d has no client message name (the guild switch's default)")
	var guildless := ErrorText.guild_level_up_line(0x4c0d, guild_table, "not in a guild")
	_check(guildless == "not in a guild", "0x4c0d keeps the server's words (got %s)" % guildless)
	var own := ErrorText.guild_level_up_line(0, guild_table, "failed to level up the guild")
	_check(own == "failed to level up the guild", "code 0 keeps the server's words (got %s)" % own)
	var no_row := ErrorText.guild_level_up_line(0x4c32, sparse, "not enough guild points to level up the guild")
	_check(no_row == "not enough guild points to level up the guild", "a table without the GP row gives the server's words (got %s)" % no_row)

	# The wiring (World3D, HudPanels) is checked in _initialize, below, which
	# also reports the result.

## The two callers, driven with the same fixture. This runs in _initialize,
## not _init: both scripts name the NetClient autoload, which a --script
## suite registers only after _init (measured in round 514, recorded in
## npc_service_reader_test.gd's check (j)). Both are loaded by path, so
## nothing compiles them before the autoload exists, and reached through
## call(): a caller without the wiring shows the old line or none, and FAILS.
func _initialize() -> void:
	var fixture := _table(PackedStringArray([
		_row("UIIT_MSG_STRGERR_LOCKED_BY_OTHER_ONE", "Fixture not yours"),
		_row("UIIT_MSG_INTERACTION_FAIL_NOT_ENOUGH_MONEY", "Fixture no gold"),
		_row("UIIT_MSG_INTERACTION_FAIL_IM_BUSY", "Fixture on other business"),
	]))

	# World3D._pick_up_refusal_line reads the world's UI text table.
	var world_script := load("res://scripts/World3D.gd") as GDScript
	var world_ok := world_script != null and world_script.can_instantiate()
	_check(world_ok, "World3D compiles in _initialize")
	if world_ok:
		var world: Node = world_script.new()
		world.set("_ui_text_table", fixture)
		var line: String = world.call("_pick_up_refusal_line", 0x1812)
		_check(line == "Fixture not yours", "World3D's 0x1812 refusal line is the table's text (got %s)" % line)

		# A level-up refused 0x4c32 (round 528) goes on the Guild tab, in the
		# table's words.
		world.set("_ui_text_table", _table(PackedStringArray([
			_row("UIIT_MSG_ERROR_GUILD_LEVEL_UP_GP_DEFICIT", "Fixture guild points short"),
		])))
		var status := Label.new()
		var chat := RichTextLabel.new()
		world.set("guild_status_label", status)
		world.set("chat_log", chat)
		var refused := GuildNet.LevelResult.new()
		refused.error = "not enough guild points to level up the guild"
		refused.code = 0x4c32
		world.call("_on_guild_level_result", refused)
		_check(status.text == "Guild level: Fixture guild points short",
			"World3D shows a 0x4c32 level-up refusal in the table's words (got '%s')" % status.text)
		world.free()
		status.free()
		chat.free()

	# HudPanels._on_repair_result writes the store's status line. The store is
	# a bare HudWindow holding the ShopStatus label _build_shop_purse makes;
	# with no character name set, a result sends no request.
	var panels_script := load("res://scripts/ui/hud/hud_panels.gd") as GDScript
	var panels_ok := panels_script != null and panels_script.can_instantiate()
	_check(panels_ok, "HudPanels compiles in _initialize")
	if panels_ok:
		var panels: Node = panels_script.new()
		var store := HudWindow.new()
		var status := Label.new()
		status.name = "ShopStatus"
		store.add_child(status)
		(panels.get("_windows") as Dictionary)["store"] = store
		panels.set("_builder", UiBuilder.new(null, fixture))
		panels.call("_on_repair_result", 0x1c07, 0, [])
		_check(status.text == "Fixture no gold", "a 0x1c07 repair refusal shows the table's text in the store (got '%s')" % status.text)
		panels.call("_on_repair_result", 0x1c09, 0, [])
		_check(status.text == "Nothing needs repairing.", "a 0x1c09 repair refusal shows its fallback (got '%s')" % status.text)
		# NEGATIVE (round 518): a repair refused while trading.
		panels.call("_on_repair_result", 0x1c0b, 0, [])
		_check(status.text == "Fixture on other business", "a 0x1c0b repair refusal shows the table's IM_BUSY text in the store (got '%s')" % status.text)
		panels.call("_on_repair_result", 0, 1234, [])
		_check(status.text == "Repaired for 1,234 gold.", "a repair shows its cost (got '%s')" % status.text)
		store.free()
		panels.free()

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
