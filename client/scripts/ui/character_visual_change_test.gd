extends SceneTree

## Round 789: CharacterVisualChange -- which meshes a character draws given
## its worn armour and avatars (AVATAR_RESEARCH.md 6.2) -- on a synthetic
## table: the masks and priorities are the ones the research quotes as the
## table's layout values, the TypeID words come from the packing formula, and
## nothing else of the real file is here. Then CharacterAppearance's use of
## it (arbitrate_wears, the hair block, the default wear's mask) without an
## archive.
##
## NEGATIVE: before round 789 every avatar was drawn on top of every armour
## piece (CharacterAppearance kept them all) and a flag showed beside an
## attachment.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## TypeID words by the formula (READ s:0x48f610).
static func w(t3: int, t4: int, cash: int = 0) -> int:
	return CharacterVisualChange.type_word(PackedInt32Array([3, 1, t3, t4]), cash)

## A row: Service, ID, Name, Cond, AttachType, Pram1..4, StrPram1..4, Slot,
## OverlapSlot, Group, Priority, Material, Animation, BsrM, BsrF.
static func row(id: int, cond: int, pram1: int, pram2: int, slot: int, ov: int, group: int, prio: int, str1: String = "xxx", bsr: String = "xxx") -> String:
	return "\t".join(PackedStringArray(["1", str(id), "row%d" % id, str(cond), "1", str(pram1), "0x%04X" % pram2, "0", "0",
		str1, "xxx", "xxx", "xxx", "0x%04X" % slot, "0x%04X" % ov, str(group), str(prio), "0", "xxx", bsr, bsr]))

static func table() -> CharacterVisualChange:
	var lines := PackedStringArray(["//Service\tID\tName\tConditionID\t..."])
	# Armour by ConditionID 1 (robe helm, mail, shoulder, hands, pants, boots), a sword.
	lines.append(row(1, 1, w(1, 1), 0, 0x0801, 0, 0, 250))
	lines.append(row(2, 1, w(1, 3), 0, 0x0002, 0, 0, 250))
	lines.append(row(3, 1, w(1, 2), 0, 0x0004, 0, 0, 250))
	lines.append(row(4, 1, w(1, 5), 0, 0x0008, 0, 0, 250))
	lines.append(row(5, 1, w(1, 4), 0, 0x0010, 0, 0, 250))
	lines.append(row(6, 1, w(1, 6), 0, 0x0020, 0, 0, 250))
	lines.append(row(7, 1, w(6, 2), 0, 0x0040, 0, 0, 250))
	# Avatars by ConditionID 2: TypeID word and Param7.
	lines.append(row(10, 2, w(13, 1), 0x0201, 0x0A01, 0x0200, 1, 70))
	lines.append(row(11, 2, w(13, 1, 1), 0x0201, 0x0A01, 0x0200, 1, 70))
	lines.append(row(12, 2, w(13, 2), 0x023E, 0x023E, 0x0200, 1, 70))
	lines.append(row(13, 2, w(13, 2), 0x063E, 0x073E, 0x0200, 1, 70))
	lines.append(row(14, 2, w(13, 3), 0x0500, 0x0500, 0x0200, 1, 90))
	lines.append(row(15, 2, w(13, 4), 0x0500, 0x0500, 0x0200, 1, 110))
	# A wing dress's second mesh (ConditionID 4, by code name).
	lines.append(row(20, 4, 0, 0, 0x0000, 0, 0, 70, "ITEM_TEST_WING_DRESS", "item\\avatar\\test_wing.bsr"))
	# Another service's row is ignored.
	lines.append(row(30, 2, w(13, 3), 0x0500, 0x0001, 0, 0, 1).replace("1\t30\t", "0\t30\t"))
	return CharacterVisualChange.from_text("\n".join(lines))

## The keys a wear list draws, by name.
static func drawn_names(t: CharacterVisualChange, wears: Array) -> PackedStringArray:
	var visuals: Array = []
	var names: Array = []
	for e in wears:
		var v := t.visual_for(int(e[1]), int(e[2]))
		if v.is_empty():
			continue
		visuals.append(v)
		names.append(e[0])
	var out := PackedStringArray()
	for i in CharacterVisualChange.arbitrate(visuals)["drawn"]:
		out.append(names[i])
	out.sort()
	return out

func _test_table() -> void:
	var t := table()
	_check(t.rows.size() == 14, "14 Service-1 rows (%d)" % t.rows.size())
	_check(w(13, 1) == 3756 and w(13, 2) == 5804 and w(13, 3) == 7852 and w(13, 4) == 9900 and w(1, 1) == 2220,
		"the packing gives the words the research quotes (3756 hat, 5804 dress, 7852 attachment, 9900 extra, 2220 robe helm)")
	_check(CharacterVisualChange.is_avatar_word(w(13, 2)) and CharacterVisualChange.is_avatar_word(w(13, 2, 1))
		and not CharacterVisualChange.is_avatar_word(w(14, 1)) and not CharacterVisualChange.is_avatar_word(w(13, 2) | 2),
		"the avatar key is 3/1/13 and not bionic; a devil's spirit takes the item key")
	_check(t.row_for(w(13, 1), 0x201) != null and t.row_for(w(13, 1), 0x201).id == 10, "a hat finds its row by word and Param7")
	_check(t.row_for(w(13, 1), 0x200) == null, "the wrong Param7 finds none")
	_check(t.row_for(w(13, 1, 1), 0x201).id == 11, "the cash bit is part of the key")
	_check(t.row_for(w(14, 1), 0) == null and t.visual_for(w(14, 1), 0)["slot"] == 0,
		"a devil's spirit has no row: kept as a visual that covers nothing (it is never attached as an avatar)")
	_check(t.visual_for(w(13, 3), -1).is_empty(), "an avatar with no row is not attached at all")
	_check(CharacterVisualChange.add_attach_path(t.add_attach_row("item_test_wing_dress")) == "item\\avatar\\test_wing.bsr",
		"a wing dress's AddAttach mesh, by code name in any case")

func _test_arbitration() -> void:
	var t := table()
	var armour := [["helm", w(1, 1), 0], ["mail", w(1, 3), 0], ["shoulder", w(1, 2), 0], ["hands", w(1, 5), 0],
		["pants", w(1, 4), 0], ["boots", w(1, 6), 0], ["sword", w(6, 2), 0]]
	_check(drawn_names(t, armour) == PackedStringArray(["boots", "hands", "helm", "mail", "pants", "shoulder", "sword"]),
		"armour alone: everything drawn")
	var hat := armour + [["hat", w(13, 1), 0x201]]
	_check(drawn_names(t, hat) == PackedStringArray(["boots", "hands", "hat", "mail", "pants", "shoulder", "sword"]),
		"a hat (0x0A01) hides the helm (0x0801), nothing else: %s" % drawn_names(t, hat))
	var dress := armour + [["dress", w(13, 2), 0x23E]]
	_check(drawn_names(t, dress) == PackedStringArray(["dress", "helm", "sword"]),
		"a dress (0x023E) hides mail, shoulder, hands, pants and boots; the helm and the sword stay: %s" % drawn_names(t, dress))
	var both := armour + [["dress", w(13, 2), 0x23E], ["hat", w(13, 1), 0x201]]
	_check(drawn_names(t, both) == PackedStringArray(["dress", "hat", "sword"]),
		"hat and dress together, same group: both drawn, only the sword left of the armour: %s" % drawn_names(t, both))
	var att := both + [["attachment", w(13, 3), 0x500], ["flag", w(13, 4), 0x500]]
	_check(drawn_names(t, att) == PackedStringArray(["attachment", "dress", "hat", "sword"]),
		"the flag (prio 110) is hidden while an attachment (prio 90) is worn: %s" % drawn_names(t, att))
	var flag_only := both + [["flag", w(13, 4), 0x500]]
	_check(drawn_names(t, flag_only).has("flag"), "a flag alone is drawn")
	var wings := armour + [["big dress", w(13, 2), 0x63E], ["attachment", w(13, 3), 0x500]]
	_check(drawn_names(t, wings) == PackedStringArray(["big dress", "helm", "sword"]),
		"a 0x063E dress (Slot 0x073E) takes the attachment bits: the attachment is hidden: %s" % drawn_names(t, wings))
	var no_row := armour + [["odd attachment", w(13, 3), -1]]
	_check(drawn_names(t, no_row).size() == 7 and not drawn_names(t, no_row).has("odd attachment"),
		"an attachment with Param7 -1 (no row) draws nothing and hides nothing")
	# Attach order does not matter across priorities; a skill row of group 2
	# (prio 60) hides group-1 avatars whose OverlapSlot collides with it.
	var walk := CharacterVisualChange.arbitrate([
		{"priority": 70, "slot": 0x0A01, "overlap": 0x0200, "group": 1},
		{"priority": 60, "slot": 0x023F, "overlap": 0x0200, "group": 2},
		{"priority": 250, "slot": 0x0040, "overlap": 0, "group": 0}])
	_check(walk["drawn"] == [1, 2] and walk["hidden"] == [0], "a group-2 transform (prio 60) hides a group-1 hat: %s" % [walk])
	var ties := CharacterVisualChange.arbitrate([
		{"priority": 250, "slot": 0x0002, "overlap": 0, "group": 0},
		{"priority": 250, "slot": 0x0002, "overlap": 0, "group": 0}])
	_check(ties["drawn"] == [0] and ties["hidden"] == [1], "equal priorities: the first attached wins")
	_check(int(CharacterVisualChange.arbitrate([{"priority": 70, "slot": 0x0A01, "overlap": 0x0200, "group": 1}])["occupied"]) == 0x0801,
		"the occupied mask leaves the OverlapSlot bits out")

func _wear(name: String, id: int, slot: int, t3: int, t4: int, param7: int, code: String = "") -> Dictionary:
	return {"id": id, "plus": 0, "slot": slot, "type_ids": PackedInt32Array([3, 1, t3, t4]), "code": code if code != "" else name,
		"models": PackedStringArray(["item\\%s.bsr" % name]), "nodes": [], "word": w(t3, t4), "param7": param7}

func _test_appearance() -> void:
	var a := CharacterAppearance.new()
	var wears := [_wear("helm", 1, CharacterAppearance.SLOT_HEAD, 1, 1, 0), _wear("mail", 2, CharacterAppearance.SLOT_CHEST, 1, 3, 0),
		_wear("pants", 3, CharacterAppearance.SLOT_LEGS, 1, 4, 0), _wear("hat", 10, CharacterAppearance.SLOT_AVATAR, 13, 1, 0x201),
		_wear("dress", 11, CharacterAppearance.SLOT_AVATAR, 13, 2, 0x23E, "ITEM_TEST_WING_DRESS"),
		_wear("spirit", 12, CharacterAppearance.SLOT_AVATAR, 14, 1, 0)]
	var kept := a.arbitrate_wears(wears.duplicate(true))
	_check(kept.size() == 6, "without a table every wear is kept, as before")
	a.visual_change = table()
	kept = a.arbitrate_wears(wears.duplicate(true))
	var ids := []
	for k in kept:
		ids.append(int(k["id"]))
	_check(ids == [10, 11], "with it: the hat and the dress, armour under them and the devil's spirit gone (%s)" % [ids])
	var dress: Dictionary = kept[1]
	_check((dress["models"] as PackedStringArray).has("item\\avatar\\test_wing.bsr"), "the wing dress carries its second mesh")
	_check(CharacterAppearance.avatar_cover_mask(kept) == (0x0A01 | 0x023E), "the drawn avatars' Slot bits (0x%x)" % CharacterAppearance.avatar_cover_mask(kept))
	var hair := a.hair_block_for(kept[0])
	_check(hair != null and hair.hides_body() and hair.keys() == PackedInt32Array([CharacterAppearance.HAIR_PIECE_KEY]),
		"a hat (Slot 0x0A01 outside OverlapSlot 0x0200 holds 0x0800) hides the hair piece (INFERRED)")
	_check(a.hair_block_for(kept[1]) == null, "a dress does not")
	a.hide_hair_by_mask = false
	_check(a.hair_block_for(kept[0]) == null, "and with the rule off, a hat does not either")
	_check(CharacterAppearance.is_avatar_key(CharacterAppearance.AVATAR_KEY_BASE + 4) and not CharacterAppearance.is_avatar_key(8)
		and not CharacterAppearance.is_avatar_key(CharacterAppearance.AVATAR_KEY_BASE + 5), "the avatar keys are 200..204")

func _test_default_wear() -> void:
	# Default clothes rows (ConditionID 6) for a China body: mail 6316 -> word with TypeID3 1.
	var text := "\n".join(PackedStringArray([
		row(40, 6, DefaultWear.default_type_id(CharCatalog.RACE_CHINA, 0, 0), 0, 0x0002, 0, 0, 250, "xxx", "item\\clothes_ba.bsr"),
		row(41, 6, DefaultWear.default_type_id(CharCatalog.RACE_CHINA, 1, 0), 0, 0x0010, 0, 0, 250, "xxx", "item\\clothes_la.bsr")]))
	var dw := DefaultWear.from_text(text)
	_check(dw.wear_for(CharCatalog.RACE_CHINA, false, []).size() == 2, "nothing worn: both default clothes")
	_check(dw.wear_for(CharCatalog.RACE_CHINA, false, [], false, 0x023E).is_empty(), "a dress's Slot covers mail and pants: none (FUN_00a5e010)")
	_check(dw.wear_for(CharCatalog.RACE_CHINA, false, [], false, 0x0A01).size() == 2, "a hat's covers neither: both")

func _init() -> void:
	_test_table()
	_test_arbitration()
	_test_appearance()
	_test_default_wear()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
