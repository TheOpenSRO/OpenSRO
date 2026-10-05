extends RefCounted
class_name ItemTypeNames

## The two names an item's tooltip needs from the archive besides its own
## (round 731):
##
## "Sort of item" -- the name of the item's category. INFERRED (round 731's
## review): the builders call FUN_00941240(out, TypeID word, ref+8), which
## tries a map keyed by the ref's code name (owner +0x6b8, FUN_009411d0), then
## one keyed by TypeID & 0xfffe holding a string (owner +0x6a8, FUN_0093acb0);
## what fills either map is not read (OPEN). This file joins
## fmntidgroupmapdata.txt (`service, group, TypeID1..4`) to
## fmncategorytreedata.txt (`service, code, text key, parent, group, ?`) on
## the group: (3,1,6,4) -> group 3 -> UIIT_CTL_WK_CH_WEAPON_SPEAR -> "Spear",
## one key per group and one group per TypeID quadruple over the archive's
## 138 and 72 rows (MEASURED). The reference screenshot reads "Twohand staff"
## (UIIT_CTL_WNETWORK_EU_TSTAFF) where this join gives "Staff": the European
## names may be the WNETWORK set ("Onehand sword", "Light staff", "Twohand
## staff", "Heavy armor") -- Esro's client is modified, so not settled.
##
## The set name -- refsetitemgroup.txt, column 1 the set id (itemdata col 62),
## column 4 the set's name key (SN_ITEM_11_SET_A_WEAPON...). The key's text is
## not in textdata_object.txt but in TextData_Equip&Skill.txt, the other file
## textdataname.txt lists for the client to load (MEASURED, round 731:
## SN_ITEM_11_SET_A_WEAPON "Power" -- the green line in the user's screenshot
## -- and SN_ITEM_11_SET_A_DEFENSE "Destruction").

const GROUP_MAP_PATH := "server_dep\\silkroad\\textdata\\fmntidgroupmapdata.txt"
const CATEGORY_PATH := "server_dep\\silkroad\\textdata\\fmncategorytreedata.txt"
const SET_GROUP_PATH := "server_dep\\silkroad\\textdata\\refsetitemgroup.txt"
const EQUIP_TEXT_PATH := "server_dep\\silkroad\\textdata\\textdata_equip&skill.txt"

## "t1,t2,t3,t4" -> UIIT_CTL_WK_* key.
var type_keys: Dictionary = {}
## set id -> SN_ name key.
var set_keys: Dictionary = {}
## set id -> the set's English name.
var set_names: Dictionary = {}
## Other keys the tooltip needs from the same table -- the mastery names
## UIIT_STT_WARRIOR.. live there, not in textuisystem.txt (MEASURED, round
## 731) -- key -> English.
var equip_texts: Dictionary = {}

static func decode(data: PackedByteArray) -> String:
	if data.size() >= 2 and data[0] == 0xFF and data[1] == 0xFE:
		return data.get_string_from_utf16()
	var s := data.get_string_from_utf8()
	return s.substr(1) if s.begins_with("﻿") else s

static func _rows(data: PackedByteArray) -> Array:
	var out: Array = []
	for line in decode(data).split("\n"):
		var l := line.strip_edges(false, true)
		if l == "" or l.begins_with("//"):
			continue
		out.append(l.split("\t"))
	return out

## Builds the type keys from the two tables' bytes.
func parse_types(group_map: PackedByteArray, categories: PackedByteArray) -> void:
	var key_by_group := {}
	for c in _rows(categories):
		if c.size() >= 5 and c[4] != "0":
			key_by_group[c[4]] = c[2]
	for g in _rows(group_map):
		if g.size() < 6:
			continue
		var key: String = key_by_group.get(g[1], "")
		if key != "":
			type_keys["%s,%s,%s,%s" % [g[2], g[3], g[4], g[5]]] = key

func parse_sets(data: PackedByteArray) -> void:
	for r in _rows(data):
		if r.size() >= 5 and r[1].is_valid_int():
			set_keys[int(r[1])] = r[4]

## Resolves the set keys through the equip text table's rows (token in
## column 1, the language column picked as UiTextTable picks it).
func parse_set_names(data: PackedByteArray, extra_keys: Array = []) -> void:
	var wanted := {}
	for id in set_keys:
		wanted[set_keys[id]] = id
	for k in extra_keys:
		wanted[k] = -1
	for r in _rows(data):
		if r.size() > 2 and wanted.has(r[1]):
			if int(wanted[r[1]]) < 0:
				if not equip_texts.has(r[1]):
					var et := UiTextTable._pick_language_column(r, UiTextTable.COL_ENGLISH)
					if et != "":
						equip_texts[r[1]] = et
				continue
			var text := UiTextTable._pick_language_column(r, UiTextTable.COL_ENGLISH)
			if text != "":
				for id in set_keys:
					if set_keys[id] == r[1] and not set_names.has(id):
						set_names[id] = text

## The category's text key for an item's TypeIDs, or "".
func type_key(type_ids: PackedInt32Array) -> String:
	if type_ids.size() < 4:
		return ""
	return type_keys.get("%d,%d,%d,%d" % [type_ids[0], type_ids[1], type_ids[2], type_ids[3]], "")

## Loads all three tables from the Media archive.
static func load_from(archive) -> ItemTypeNames:
	var n := ItemTypeNames.new()
	if archive == null:
		return n
	var g = ObjectLoader.find_file(archive, GROUP_MAP_PATH)
	var c = ObjectLoader.find_file(archive, CATEGORY_PATH)
	if g != null and c != null:
		n.parse_types(archive.read_file(g), archive.read_file(c))
	var s = ObjectLoader.find_file(archive, SET_GROUP_PATH)
	if s != null:
		n.parse_sets(archive.read_file(s))
		var e = ObjectLoader.find_file(archive, EQUIP_TEXT_PATH)
		if e != null:
			n.parse_set_names(archive.read_file(e), ItemTooltipLines.MASTERY_KEYS.values())
	return n
