extends SceneTree

## Round 805: the job fixes, against what the round read out of the original.
##   - JobMobDress: an NPC thief's or hunter's dressing (ICMonster::FUN_009d3470,
##     icscriptobj::FUN_009e3c40) and its table readers;
##   - the monster record's body byte (CombatNet, MONSTER_LIST_FLAG_BODY);
##   - a dropped trade good's creator after its name (GroundItems,
##     GroundItemsNet; CIItem::vslot_025);
##   - the pet items that name the current COS (UseItemNet.is_cos_target_item);
##   - the OURS Job Titles on Names row (VideoOptions.JOB_TITLES).
## Synthetic rows only; no archive is read.
##   godot4 --headless --path client --script res://scripts/world/job_mob_dress_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	await process_frame
	_test_rules()
	_test_outfit()
	_test_tables()
	_test_body_byte()
	_test_creator()
	_test_cos_items()
	_test_job_titles_row()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

func _test_rules() -> void:
	_check(JobMobDress.degree(1) == 1 and JobMobDress.degree(7) == 1 and JobMobDress.degree(8) == 2, "degree: 1 below 8, 2 from 8 (FUN_009e2260)")
	_check(JobMobDress.degree(41) == 5 and JobMobDress.degree(42) == 6 and JobMobDress.degree(119) == 11 and JobMobDress.degree(120) == 12,
		"degree: 41 -> 5, 42 -> 6, 119 -> 11, 120 -> 12")
	_check(JobMobDress.degree(163) == 13 and JobMobDress.degree(164) == 14 and JobMobDress.degree(255) == 14, "degree: 163 -> 13, 164 and up 14")
	_check(JobMobDress.race_word(0) == "CH" and JobMobDress.race_word(3) == "CH" and JobMobDress.race_word(1) == "EU" and JobMobDress.race_word(2) == "",
		"race: Country 0 and 3 China, 1 Europe")
	_check(JobMobDress.armour_class(2) == 1 and JobMobDress.armour_class(4) == 1 and JobMobDress.armour_class(6) == 3
		and JobMobDress.armour_class(3) == 3 and JobMobDress.armour_class(12) == 2 and JobMobDress.armour_class(0) == -1,
		"armour class: sword/spear clothes, bow/blade heavy, crossbow light, none otherwise")
	_check(JobMobDress.has_shield(2) and JobMobDress.has_shield(3) and JobMobDress.has_shield(7) and JobMobDress.has_shield(15)
		and not JobMobDress.has_shield(6), "a shield for weapon types 2, 3, 7, 15 only")
	_check(JobMobDress.suit_number("CH", 1, 0) == 2 and JobMobDress.suit_number("CH", 1, 1) == 3, "China's suit: 02 or 03 by the coin")
	_check(JobMobDress.suit_number("EU", 39, 0) == 1 and JobMobDress.suit_number("EU", 59, 0) == 3
		and JobMobDress.suit_number("EU", 79, 0) == 5 and JobMobDress.suit_number("EU", 80, 0) == 7, "Europe's suit by level: 01 / 03 / 05 / 07")
	var list := [[100, true], [101, false], [102, true]]
	_check(JobMobDress.pick_body(list, 4) == [101, false] and JobMobDress.pick_body(list, 255) == [100, true], "the body is byte % n")
	_check(JobMobDress.maybe_job_code("MOB_THIEF_NPC_0001") and JobMobDress.maybe_job_code("MOB_EU_HUNTER_NPC_0003")
		and not JobMobDress.maybe_job_code("MOB_CH_MANGNYANG"), "only thief and hunter codes are looked up")
	_check(JobMobDress.pick_body([], 4).is_empty() and JobMobDress.pick_body(list, -1).is_empty(), "no list or no byte: no body")

func _row(type4: int, level: int, country: int = 3) -> JobMobDress.Row:
	var r := JobMobDress.Row.new()
	r.code = "MOB_THIEF_NPC_0001" if type4 == JobMobDress.TYPE4_THIEF else "MOB_HUNTER_NPC_0001"
	r.type4 = type4
	r.level = level
	r.country = country
	return r

func _test_outfit() -> void:
	# A level-20 bow thief: no armour, no shield; a bow stepping down from degree 3.
	var thief := JobMobDress.outfit(_row(JobMobDress.TYPE4_THIEF, 20), 6, true, 1, false)
	_check(thief["weapon"] == ["ITEM_CH_BOW_03_A", "ITEM_CH_BOW_02_A", "ITEM_CH_BOW_01_A"], "the thief's bow, degree 3 down to 1: %s" % str(thief["weapon"]))
	_check((thief["armour"] as Array).is_empty() and (thief["shield"] as Array).is_empty(), "a thief wears no armour and no shield")
	_check(thief["suit"] == "ITEM_CH_M_TRADE_THIEF_03", "the thief's suit: man, coin 1 -> 03")
	# A level-8 sword hunter woman: clothes, a shield, the hunter suit.
	var hunter := JobMobDress.outfit(_row(JobMobDress.TYPE4_HUNTER, 8), 2, false, 0, false)
	_check(hunter["weapon"] == ["ITEM_CH_SWORD_02_A", "ITEM_CH_SWORD_01_A"], "the hunter's sword: %s" % str(hunter["weapon"]))
	_check(hunter["shield"] == ["ITEM_CH_SHIELD_02_A", "ITEM_CH_SHIELD_01_A"], "a sword carries a shield")
	var pieces: Array = hunter["armour"]
	_check(pieces.size() == 6 and pieces[0][0] == "ITEM_CH_W_CLOTHES_02_CA_A" and pieces[5][1] == "ITEM_CH_W_CLOTHES_01_FA_A",
		"six clothes pieces for a woman, CA first, FA last: %s" % str(pieces))
	_check(hunter["suit"] == "ITEM_CH_F_TRADE_HUNTER_02", "the hunter's suit: F, coin 0 -> 02")
	var ha := JobMobDress.outfit(_row(JobMobDress.TYPE4_HUNTER, 8), 2, true, 0, true)
	_check((ha["armour"] as Array)[0][0] == "ITEM_CH_M_CLOTHES_02_HA_A" and (ha["armour"] as Array)[1][0] == "ITEM_CH_M_CLOTHES_02_SA_A",
		"after the swap the first piece is HA")
	_check(JobMobDress.outfit(_row(JobMobDress.TYPE4_THIEF, 20, 2), 6, true, 0, false)["suit"] == "", "an unknown race dresses nothing")

## A characterdata line with the columns JobMobDress reads.
func _char_line(id: int, code: String, type3: int, type4: int, country: int, scale: int, level: int, skill: int) -> String:
	var cols := PackedStringArray()
	cols.resize(JobMobDress.COL_SKILL + 5)
	for i in cols.size():
		cols[i] = "0"
	cols[0] = "1"
	cols[1] = str(id)
	cols[JobMobDress.COL_CODE] = code
	cols[JobMobDress.COL_TYPE3] = str(type3)
	cols[JobMobDress.COL_TYPE4] = str(type4)
	cols[JobMobDress.COL_COUNTRY] = str(country)
	cols[JobMobDress.COL_SCALE] = str(scale)
	cols[JobMobDress.COL_LEVEL] = str(level)
	cols[JobMobDress.COL_SKILL] = str(skill)
	return "\t".join(cols)

## The game's text tables are UTF-16LE with a byte-order mark.
func _utf16(text: String) -> PackedByteArray:
	var out := PackedByteArray([0xFF, 0xFE])
	out.append_array(text.to_utf16_buffer())
	return out

## The line with its OrgCodeName column (4) set.
func _org_line(line: String, org: String) -> String:
	var cols := line.split("\t")
	cols[4] = org
	return "\t".join(cols)

func _skill_line(id: int, code: String, weapon: int) -> String:
	var cols := PackedStringArray()
	cols.resize(JobMobDress.SKILL_COL_WEAPON + 4)
	for i in cols.size():
		cols[i] = "0"
	cols[0] = "1"
	cols[JobMobDress.SKILL_COL_ID] = str(id)
	cols[3] = code
	cols[JobMobDress.SKILL_COL_WEAPON] = str(weapon)
	return "\t".join(cols)

func _test_tables() -> void:
	var text := "\n".join([
		_char_line(2222, "MOB_THIEF_NPC_0001", 1, 2, 3, 94, 1, 1631),
		_char_line(7624, "MOB_HUNTER_NPC_0040", 1, 3, 3, 102, 4, 4048),
		# A quest monster whose Org code names a thief row is not one.
		_org_line(_char_line(22874, "MOB_QT_TQ_THIEF_01", 1, 2, 3, 100, 1, 1631), "MOB_THIEF_NPC_0001"),
		_char_line(1, "MOB_CH_MANGNYANG", 1, 2, 3, 100, 1, 0)]) + "\n"
	var rows := JobMobDress.parse_rows(_utf16(text))
	_check(rows.size() == 2 and rows.has("MOB_THIEF_NPC_0001") and rows.has("MOB_HUNTER_NPC_0040"), "the thief and hunter rows only: %s" % str(rows.keys()))
	var t: JobMobDress.Row = rows.get("MOB_THIEF_NPC_0001")
	_check(t != null and t.type4 == 2 and t.country == 3 and t.scale == 94 and t.level == 1 and t.skill == 1631,
		"the thief row's type, Country, Scale, level and DefaultSkill_1")
	var skills := "\n".join([_skill_line(1631, "TSKILL_BOW_MAGIC_0001", 6), _skill_line(4048, "HSKILL_SWORD_PHYSICAL_0040", 2),
		_skill_line(9, "SKILL_CH_SWORD_01", 2)]) + "\n"
	var w := JobMobDress.parse_skill_weapons(_utf16(skills), {1631: true, 4048: true, 9: true})
	_check(w.get(1631) == 6 and w.get(4048) == 2 and not w.has(9), "ReqCast_Weapon1 of the NPC skills: %s" % str(w))

## A monster record (CombatNet._decode_monster_snapshot's layout).
func _monster_record(rarity_word: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(8)
	out.encode_s64(0, 77)
	for s in ["Thief", "MOB_THIEF_NPC_0001"]:
		var b: PackedByteArray = s.to_utf8_buffer()
		var n := PackedByteArray()
		n.resize(2)
		n.encode_u16(0, b.size())
		out.append_array(n)
		out.append_array(b)
	var tail := PackedByteArray()
	tail.resize(28)
	tail.encode_float(0, 1.0)
	tail.encode_u32(12, 100)
	tail.encode_u32(16, 100)
	tail.encode_u32(20, 1)
	tail.encode_u32(24, rarity_word)
	out.append_array(tail)
	return out

func _test_body_byte() -> void:
	_check((CombatNet.encode_monster_list()[0] & CombatNet.MONSTER_LIST_FLAG_BODY) != 0, "the list request asks for the body byte")
	var with_body: CombatNet.MonsterSnapshot = CombatNet._decode_monster_snapshot(_monster_record(0xa70301), 0)[0]
	_check(with_body != null and with_body.body == 0xa7 and with_body.rarity == 1 and with_body.party, "body 0xa7, rank 1, party, from 0xa70301")
	var without: CombatNet.MonsterSnapshot = CombatNet._decode_monster_snapshot(_monster_record(0x101), 0)[0]
	_check(without != null and without.body == -1 and without.rarity == 1 and without.party, "no body bit: body -1")

func _snapshot(id: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(41)
	b.encode_s64(0, id)
	b.encode_s64(8, 7)
	b.encode_u32(16, 100)
	return b

func _string(s: String) -> PackedByteArray:
	var b: PackedByteArray = s.to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, b.size())
	out.append_array(b)
	return out

func _test_creator() -> void:
	var spawned := _snapshot(9)
	spawned.append_array(_string("Merchy"))
	var s := GroundItemsNet.decode_snapshot(spawned)
	_check(s != null and s.id == 9 and s.creator == "Merchy", "a spawned good carries its creator")
	var old := GroundItemsNet.decode_snapshot(_snapshot(9))
	_check(old != null and old.creator == "", "an older server's spawn: no creator")
	var list := PackedByteArray([2, 0])
	list.append_array(_snapshot(1))
	list.append_array(_snapshot(2))
	list.append_array(_string(""))
	list.append_array(_string("Merchy"))
	var r := GroundItemsNet.decode_list_result(list)
	_check(r.error == "" and r.items.size() == 2 and r.items[0].creator == "" and r.items[1].creator == "Merchy", "the list's creators, in order")
	var good := PackedInt32Array([3, 3, 8, 1])
	_check(GroundItems.creator_suffix(good, "Merchy") == "(*Merchy)", "a trade good: (*alias)")
	_check(GroundItems.creator_suffix(PackedInt32Array([3, 3, 9, 1]), "Quester") == "(Quester)", "a quest item: (name)")
	_check(GroundItems.creator_suffix(PackedInt32Array([3, 3, 1, 1]), "X") == "" and GroundItems.creator_suffix(good, "") == "",
		"any other item, or no name: nothing")
	var gi := GroundItems.new()
	gi.setup(null, {}, func(_id: int) -> String: return "Silk", func(_t: String, _a: float) -> Label3D: return null,
		func(_p: Vector3) -> float: return 0.0)
	gi.set_types_for(func(_id: int) -> PackedInt32Array: return good)
	s.quantity = 1
	_check(gi.label_text(s) == "Silk(*Merchy)", "the label: the name, then (*alias) with no space: %s" % gi.label_text(s))
	gi.free()

func _test_cos_items() -> void:
	for t in [[3, 3, 1, 4], [3, 3, 1, 5], [3, 3, 1, 7], [3, 3, 1, 9], [3, 3, 2, 7]]:
		_check(UseItemNet.is_cos_target_item(PackedInt32Array(t)), "%s names the current COS" % str(t))
	for t in [[3, 3, 1, 1], [3, 3, 1, 6], [3, 3, 2, 1], [3, 3, 13, 12]]:
		_check(not UseItemNet.is_cos_target_item(PackedInt32Array(t)), "%s does not" % str(t))

func _test_job_titles_row() -> void:
	var o := VideoOptions.new()
	_check(o.value(VideoOptions.JOB_TITLES) == 1, "Job Titles on Names defaults to On (the user's choice)")
	_check(VideoOptions.OURS_ENTRIES.has(VideoOptions.JOB_TITLES), "it is an OURS row no preset names")
	var row := VideoOptions.row_of(VideoOptions.JOB_TITLES)
	_check(String(row.get("key", "")) == "job_titles" and (row.get("fallback", []) as Array).size() == 3, "its key and its Off / On choices")
