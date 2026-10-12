extends RefCounted
class_name NpcShopDefNet

## OpNpcShopDef 0x00BA (round 783, OURS; server/internal/testnpc): the store
## lines, tabs and goods of an NPC the player's archives do not describe --
## OpenSRO's own Test Items NPC. A retail NPC's lines and tabs come from the
## client's own Media.pk2 (ShopReader: refshopgroup .. refshopgoods); this
## NPC is in no archive, so the server sends them just before its 0xB045
## select reply. docs/protocol/test_items_npc.md has the layout:
##
##   u32 NPC unique id
##   u16 n, n bytes   the greeting (UTF-8)
##   u8 lines
##     u16 n, n bytes   the line's label (a text key or text)
##     u8 tabs
##       u16 n, n bytes   the tab's label (a text key, SN_TAB_*, or text)
##       u16 goods, goods x u32 item id

const OP_SHOP_DEF := 0x00ba

## The prefix of a store line's tab group for such an NPC: "custom:<line>"
## (NpcServiceReader's "shop:" key then carries it, as a retail line carries
## its tab group's code).
const TABGROUP_PREFIX := "custom:"

## Decodes the payload: {} when short or malformed, else {"uid": int,
## "greeting": String, "lines": [{"label": String, "tabs": [{"label":
## String, "ids": PackedInt32Array}]}]}.
static func decode(data: PackedByteArray) -> Dictionary:
	var at := [0]
	var ok := [true]
	var take := func(n: int) -> PackedByteArray:
		if not ok[0] or at[0] + n > data.size():
			ok[0] = false
			return PackedByteArray()
		var b := data.slice(at[0], at[0] + n)
		at[0] += n
		return b
	var u8 := func() -> int:
		var b: PackedByteArray = take.call(1)
		return int(b[0]) if b.size() == 1 else 0
	var u16 := func() -> int:
		var b: PackedByteArray = take.call(2)
		return b.decode_u16(0) if b.size() == 2 else 0
	var u32 := func() -> int:
		var b: PackedByteArray = take.call(4)
		return b.decode_u32(0) if b.size() == 4 else 0
	var text := func() -> String:
		var n: int = u16.call()
		var b: PackedByteArray = take.call(n)
		return b.get_string_from_utf8()
	var out := {"uid": u32.call(), "greeting": text.call(), "lines": []}
	var nlines: int = u8.call()
	for _i in range(nlines):
		var line := {"label": text.call(), "tabs": []}
		var ntabs: int = u8.call()
		for _j in range(ntabs):
			var label: String = text.call()
			# Built in a local and stored after: a packed array is a value, so
			# appending through the dictionary's copy would be lost.
			var ids := PackedInt32Array()
			var ng: int = u16.call()
			for _k in range(ng):
				ids.append(u32.call())
			(line["tabs"] as Array).append({"label": label, "ids": ids})
		(out["lines"] as Array).append(line)
	if not ok[0] or at[0] != data.size():
		return {}
	return out

## The talk window's store lines for a definition: one per line, keyed
## "custom:<i>" with its label (NpcServiceReader.services_from_ids's
## store_lines shape).
static func store_lines(def: Dictionary) -> Array:
	var out: Array = []
	var lines: Array = def.get("lines", [])
	for i in range(lines.size()):
		out.append({"tabgroup": "%s%d" % [TABGROUP_PREFIX, i], "name_strid": str((lines[i] as Dictionary).get("label", ""))})
	return out

## The line index a "custom:<i>" tab group names, -1 for any other.
static func line_of(tabgroup: String) -> int:
	if not tabgroup.begins_with(TABGROUP_PREFIX):
		return -1
	var rest := tabgroup.substr(TABGROUP_PREFIX.length())
	return int(rest) if rest.is_valid_int() else -1

## The store tabs of line `index` as ShopReader.Tab objects (what the store
## window takes): the label as the tab's name key and each item id turned into
## its code name by `code_of` (Callable(id: int) -> String; an id it does not
## know is skipped). Empty for a line the definition lacks.
static func tabs(def: Dictionary, index: int, code_of: Callable) -> Array:
	var out: Array = []
	var lines: Array = def.get("lines", [])
	if index < 0 or index >= lines.size():
		return out
	for tab_v in (lines[index] as Dictionary).get("tabs", []):
		var tab: Dictionary = tab_v
		var t := ShopReader.Tab.new()
		t.name_strid = str(tab.get("label", ""))
		for id in (tab.get("ids", PackedInt32Array()) as PackedInt32Array):
			var code: String = code_of.call(int(id))
			if code != "":
				t.item_codes.append(code)
		out.append(t)
	return out
