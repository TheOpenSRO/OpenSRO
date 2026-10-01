extends SceneTree

## The native (Rust) text-table readers against the GDScript ones on
## SYNTHETIC tables (round 671; never real game data; native/src/core/
## tables.rs). Every ported reader runs both ways on tables built to hit the
## traps the port must keep: a BOM, none, two, and a byte-swapped one; CRLF
## and LF; comment, blank and short lines; trailing tabs; padded fields; a
## duplicate id within a part and across parts (the merge keeps the LAST); a
## duplicate UI token (the table keeps the FIRST); a model column listing two
## files; non-Latin text and a surrogate pair; an unpaired surrogate and a
## table that decodes to nothing (both handed back to GDScript, which must
## still answer); and Godot's own number quirks. Results are compared whole
## with var_to_bytes, so key order and float bits count. Then 8 worker tasks
## parse at once. Without the library it checks the fallback instead.
##
##   godot4 --headless --path client --script res://scripts/npc/native_tables_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## UTF-16LE with the FF FE mark, as the archive stores the tables.
func _utf16(text: String, bom := true) -> PackedByteArray:
	var out := PackedByteArray([0xFF, 0xFE]) if bom else PackedByteArray()
	out.append_array(text.to_utf16_buffer())
	return out

## A characterdata-shaped row: `fields` maps column -> text, 60 columns wide.
func _row(fields: Dictionary, width := 60) -> String:
	var cols := PackedStringArray()
	cols.resize(width)
	for k in fields:
		cols[k] = fields[k]
	return "\t".join(cols)

func _chardata(eol: String) -> String:
	return eol.join([
		"// characterdata, synthetic",
		_row({0: "1", 1: " 1907 ", 2: "CHAR_CH_MAN_ADVENTURER", 5: "SN_CHAR_CH_MAN_ADVENTURER", 14: "0", 46: "16", 47: "50", 50: "4", 52: " char\\china\\man.bsr , char\\china\\man_full.bsr"}),
		_row({0: "1", 1: "2000", 2: "MOB_CH_MANGNYANG", 4: "xxx", 5: "SN_MOB_CH_MANGNYANG", 14: "0", 46: "1.5e", 47: "2.5", 50: "6", 52: "mob\\china\\mangnyang.BSR"}),
		_row({0: "1", 1: "2000", 2: "MOB_CH_MANGNYANG_CLON", 4: "MOB_CH_MANGNYANG", 5: "SN_MOB_CH_MANGNYANG", 14: "x", 46: "", 47: "", 50: " 7 ", 52: "xxx"}),
		"",
		"1\t3000\tNPC_SHORT",
		_row({0: "1", 1: "notanid", 2: "NPC_CH_SMITH", 5: "SN_NPC_CH_SMITH", 52: "npc\\smith.bsr"}),
		_row({0: "1", 1: "+12", 2: "CHAR_EU_WOMAN", 5: "SN_CHAR_EU_WOMAN", 14: "1", 46: "-0", 47: "1e3", 50: "-5", 52: "char\\europe\\woman.bsr"}) + "\t\t\t",
		_row({0: "1", 1: "4000", 2: "MOB_KOR", 5: "SN_MOB_KOR", 50: "99999999999999999999", 52: "mob\\몬스터.bsr"}),
	]) + eol

func _names() -> UiTextTable:
	NativeAssets.force_gdscript = true
	var t := UiTextTable.parse(_utf16("\n".join([
		"1\tSN_CHAR_CH_MAN_ADVENTURER\t\t\t\t\t\t\tAdventurer",
		"1\tSN_MOB_CH_MANGNYANG\t\t\t\t\t\t\tMangyang",
		"1\tSN_NPC_CH_SMITH\t\t\t\t\t\t\tBlacksmith Ironsmith",
		"1\tSN_CHAR_EU_WOMAN\t\t\t\t\t\t\tSN_CHAR_EU_WOMAN",
	])))
	NativeAssets.force_gdscript = false
	return t

func _items() -> PackedByteArray:
	var r1 := PackedStringArray()
	r1.resize(120)
	r1[1] = "4842"
	r1[2] = "ITEM_CH_M_CLOTHES_01_BA_A_DEF"
	r1[3] = " Cotton Suit "
	r1[5] = "SN_ITEM_CH_M_CLOTHES_01_BA_A"
	r1[9] = "1"
	r1[12] = "3"
	r1[31] = "427"
	r1[32] = "1"
	r1[33] = "5"
	r1[52] = "item/a_ba.bsr,,xxx, item/a_ba_fullset.BSR "
	r1[53] = "item\\a_drop.bsr"
	r1[54] = "item\\china\\a.ddj"
	r1[57] = "0"
	r1[63] = "26"
	r1[65] = "2.5"
	r1[66] = "1.5e"
	r1[74] = "-"
	r1[95] = "15"
	r1[97] = "16"
	r1[118] = "+7"
	var r2 := r1.duplicate()
	r2[3] = "Later Suit"
	return _utf16("\r\n".join([
		"\t".join(r1),
		"1\t5\tNONAME\t\t",
		"1\t6\tSHORT",
		"1\t7\tC\tName",
		"\t".join(r2),
	]) + "\r\n")

## [label, func(data) -> canonical result] for the readers under test.
func _readers(names: UiTextTable) -> Array:
	return [
		["positions", func(d): return _canon_spawns(NpcTableReader.parse_positions(d))],
		["codes", func(d): return NpcTableReader.parse_codes(d, {})],
		["models", func(d): return NpcTableReader.parse_models(d, {})],
		["models_by_code", func(d): return NpcTableReader.parse_models_by_code(d, {}, "")],
		["org_codes", func(d): return NpcTableReader.parse_org_codes(d, {})],
		["speeds", func(d): return NpcTableReader.parse_speeds_by_code(d, {}, "")],
		["country", func(d): return NpcTableReader.parse_country_by_code(d, {}, "")],
		["bc_radius", func(d): return NpcTableReader.parse_bc_radius_by_code(d, {})],
		["names", func(d): return NpcTableReader.parse_names(d, names, {})],
		["name_keys", func(d): return NpcTableReader.parse_name_keys(d, {})],
		["models_by_name", func(d): return NpcTableReader.parse_models_by_name(d, names, {})],
		["items", func(d): return _canon_items(ItemTableReader.parse(d, {}))],
		["ui", func(d): return UiTextTable.parse(d)._strings],
		["ui last", func(d): return UiTextTable.parse(d, 8, false)._strings],
		["skill_effects", func(d): return SkillEffectReader.parse_all(d)],
	]

func _both(label: String, run: Callable, data: PackedByteArray, what: String) -> Array:
	NativeAssets.force_gdscript = true
	var g = run.call(data)
	NativeAssets.force_gdscript = false
	var n = run.call(data)
	_check(var_to_bytes(g) == var_to_bytes(n), "%s: %s agrees both ways" % [what, label])
	return [g, n]

func _canon_spawns(spawns: Array) -> Array:
	var out := []
	for sv in spawns:
		var s: NpcTableReader.Spawn = sv
		out.append([s.npc_id, s.region_x, s.region_y, s.local_position])
	return out

func _canon_items(items: Dictionary) -> Dictionary:
	var out := {}
	for id in items:
		var it: ItemTableReader.Item = items[id]
		out[id] = [it.id, it.code_name, it.item_name, it.name_strid, it.max_stack, it.sell_price,
			it.icon_path, it.model_path, it.model_paths, it.drop_model_path, it.type_ids, it.country,
			it.req_gender, it.req_level_types, it.req_levels, it.durability, it.phys_atk, it.mag_atk,
			it.phys_reinforce, it.mag_reinforce, it.attack_rate, it.critical, it.attack_range,
			it.param1, it.phys_def, it.mag_def, it.block]
	return out

func _init() -> void:
	var loaded := NativeAssets.library_usable() and ClassDB.class_exists(NativeAssets.TABLES_CLASS)
	print("native tables: %s" % ("loaded" if loaded else "not loaded"))
	var names := _names()
	var chardata := _chardata("\r\n")
	var ui := "\r\n".join([
		"// textuisystem, synthetic",
		"#comment",
		"1\tUIIT_STT_PHYSICAL_ATTACK\t물리\t\t\t\t\t\tPhy. Atk:\tPhy. Atk:",
		"1\tUIIT_STT_PHYSICAL_ATTACK\t\t\t\t\t\t\t0\tPhy. atk",
		"0\tUIIT_OFF\t\t\t\t\t\t\tOff",
		" 1.9 \tUIIT_DOT\t\t\tLeft\t\t\t\t0\t",
		"1\tUIIT_ZERO\t\t\t\t\t\t\t0",
		"1\tUIIT_EMOJI\t\t\t\t\t\t\tSmile 😀",
		"1\t\tNOTOKEN",
		"1",
	])
	var skills := "\r\n".join([
		"#section\tcharacterInfo",
		"CHAR\tSKILL_X\tx.efp",
		"#section\tskillaniset2",
		"1\t0\tSKILL_CH_SWORD_SMASH_A\t5\t\t\tblade\tANI_SKILL_1, none,\tANI_WAIT\tani_attack1\t\t\t\tdef.EFP\thiteffect\\a.efp",
		"1\t0\tskill_ch_low\t\t\t\tSKILL_G\tani_run\t\t",
		"1\t0\tSKILL_CH_SWORD_SMASH_A\t7\t\t\tSPEAR\tANI_STAND1\t\t",
		"#section\tskillaniset",
		"0\tSKILL_CH_SWORD_SMASH_A\t9\t\t\tsword\tANI_WALK\t\t",
	])
	var npcpos := "//npcpos\r\n2001\t25000\t1002.5\t-3\t1020\r\nx\t1\t2\t3\t4\r\n7\t25257\t1e\t \t-\r\n2001\t25001\t1\t2\t3\r\n1\t2\t3\t4\r\n"
	var cases := {
		"characterdata (CRLF, BOM)": _utf16(chardata),
		"characterdata (LF, no BOM)": _utf16(_chardata("\n"), false),
		"characterdata (BOM twice)": _utf16("﻿" + chardata),
		"ui table": _utf16(ui),
		"items": _items(),
		"skilleffect": _utf16(skills),
		"npcpos": _utf16(npcpos),
		"empty": PackedByteArray(),
		"BOM only": PackedByteArray([0xFF, 0xFE]),
		"NUL first (decodes to nothing)": PackedByteArray([0xFF, 0xFE, 0x00, 0x00, 0x78, 0x00]),
		"UTF-8 text": "1\t2000\tMOB_UTF8\t\t\tSN_MOB_UTF8\tmob\\u.bsr".to_utf8_buffer(),
	}
	# A byte-swapped (big-endian) table behind the FF FE mark, and a lone
	# surrogate: both decoded by Godot's own rules, the second handed back.
	var be := PackedByteArray([0xFF, 0xFE, 0xFE, 0xFF])
	for b in chardata.to_utf16_buffer():
		be.append(b)
	for i in range(4, be.size() - 1, 2):
		var lo := be[i]
		be[i] = be[i + 1]
		be[i + 1] = lo
	cases["characterdata (byte-swapped)"] = be
	var lone := _utf16("1\t2000\tMOB_A\t\t\tSN_MOB_A\tmob\\a.bsr\n")
	# A lone TRAIL surrogate: Godot keeps it as a character (a lone lead before
	# another character leaves an unwritten one, which would not compare).
	lone.append_array(PackedByteArray([0x00, 0xDC, 0x41, 0x00]))
	cases["lone surrogate"] = lone

	for what in cases:
		for reader in _readers(names):
			_both(reader[0], reader[1], cases[what], what)

	# What the rows must hold, not only that the two agree.
	var data: PackedByteArray = cases["characterdata (CRLF, BOM)"]
	var models := NpcTableReader.parse_models(data, {})
	_check(models.get(2000) == "mob\\china\\mangnyang.BSR" and models.get(1907) == "char\\china\\man.bsr",
		"a model column listing two files gives the first; padded ids and fields are stripped (%s)" % str(models))
	var codes := NpcTableReader.parse_codes(data, {})
	_check(codes.get(2000) == "MOB_CH_MANGNYANG_CLON", "a duplicate id keeps the LAST row (%s)" % str(codes.get(2000)))
	_check(codes.get(12) == "CHAR_EU_WOMAN" and codes.get(3000) == "NPC_SHORT" and not codes.has(0),
		"'+12' is the id 12; three fields are enough for a code; 'notanid' is no id")
	_check(not NpcTableReader.parse_bc_radius_by_code(data, {}).has("NPC_SHORT"), "a row too short for column 50 is skipped")
	var merged := NpcTableReader.parse_codes(_utf16("1\t2000\tFIRST\n1\t9\tNINE\n"), {})
	merged = NpcTableReader.parse_codes(data, merged)
	_check(merged.get(2000) == "MOB_CH_MANGNYANG_CLON" and merged.keys()[0] == 2000,
		"across parts the later part wins, at the first part's position")
	var speeds := NpcTableReader.parse_speeds_by_code(data, {}, "")
	_check(speeds.get("MOB_CH_MANGNYANG") == [15.0, 2.5], "\"1.5e\" is Godot's float 15 (its parse skips the scaling on a dangling e) -- %s" % str(speeds.get("MOB_CH_MANGNYANG")))
	_check(var_to_bytes(speeds.get("CHAR_EU_WOMAN", [0, 0])[0]) == var_to_bytes(-0.0), "\"-0\" is -0.0")
	var radius := NpcTableReader.parse_bc_radius_by_code(data, {})
	_check(radius.get("MOB_KOR") == 9223372036854775807, "an int past 64 bits clamps as Godot's to_int does")
	var org := NpcTableReader.parse_org_codes(data, {})
	_check(org.size() == 1 and org.get("MOB_CH_MANGNYANG_CLON") == "MOB_CH_MANGNYANG", "xxx names no Org row")
	var table := UiTextTable.parse(cases["ui table"])
	_check(table.get_text("UIIT_STT_PHYSICAL_ATTACK") == "Phy. Atk:", "a duplicate UI token keeps the FIRST row")
	_check(table.get_text("UIIT_DOT") == "Left" and not table.has("UIIT_OFF"), "service ' 1.9 ' reads as 1; service 0 is skipped")
	_check(table.get_text("UIIT_EMOJI") == "Smile 😀", "a surrogate pair decodes")
	var by_name := NpcTableReader.parse_models_by_name(data, names, {})
	_check(by_name.has("blacksmıth ıronsmith") or by_name.has("blacksmith ironsmith"), "names are lower-cased by Godot's own to_lower (%s)" % str(by_name.keys()))
	var fx := SkillEffectReader.parse_all(cases["skilleffect"])
	var smash: Dictionary = fx["aniset"].get("SKILL_CH_SWORD_SMASH_A", {})
	_check(smash.get("group") == "sword" and smash.get("priority") == 9 and smash.get("defense") == "def.EFP",
		"a repeated SkillID overwrites its scalars and keeps an earlier DefenseEfp (%s)" % str(smash))
	_check(fx["aniset"].has("SKILL_CH_LOW"), "a lower-case SkillID is upper-cased")
	var items := ItemTableReader.parse(cases["items"], {})
	var suit: ItemTableReader.Item = items.get(4842)
	_check(suit != null and suit.item_name == "Later Suit" and suit.model_paths.size() == 2 and suit.phys_def == Vector2(2.5, 15.0),
		"items: the last duplicate wins, both set models are kept, '1.5e' reads 15")
	_check(items.has(7) and not items.has(5) and not items.has(6), "items: a nameless iconless row and a short row are skipped")

	if not loaded:
		_check(NativeAssets.new_tables() == null, "without the library there is no native table reader")
		print("SKIP native-only checks: the library is not loaded")
	else:
		var nt := NativeAssets.new_tables()
		_check(nt.call("char_codes", cases["lone surrogate"]).has("fallback"), "a lone surrogate is handed back to GDScript")
		_check(nt.call("char_codes", cases["NUL first (decodes to nothing)"]).has("fallback"), "an empty decode is handed back (GDScript tries UTF-8)")
		_check(not nt.call("char_codes", cases["characterdata (byte-swapped)"]).has("fallback"), "a byte-swapped table is read natively")
		_check(not nt.call("ui_text_rows", cases["ui table"], 8).has("fallback") and nt.call("ui_text_rows", cases["ui table"], -1).has("fallback"),
			"a negative language column is handed back")
		# Worker threads: 8 tasks parse at once and agree with the main thread.
		NativeAssets.force_gdscript = true
		var want := var_to_bytes(NpcTableReader.parse_name_keys(data, {}))
		NativeAssets.force_gdscript = false
		var results := []
		results.resize(8)
		var tasks := []
		for k in range(8):
			tasks.append(WorkerThreadPool.add_task(func() -> void:
				var ok := true
				for _r in range(50):
					ok = ok and var_to_bytes(NpcTableReader.parse_name_keys(data, {})) == want
				results[k] = ok))
		for t in tasks:
			WorkerThreadPool.wait_for_task_completion(t)
		_check(results.all(func(r): return r == true), "8 worker tasks x 50 native parses agree with GDScript")

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
