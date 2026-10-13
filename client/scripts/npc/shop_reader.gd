extends RefCounted
class_name ShopReader

## Resolves an NPC's shop -- its tabs and the real items each tab sells --
## from the player's own Media.pk2 textdata. All grounded (the client's own
## shop tables); nothing invented. The chain, traced from a smith:
##
##   refshopgroup          GROUP_STORE_CH_SMITH  <-> NPC_CH_SMITH   [3]group [4]npc
##   refmappingshopgroup   GROUP_STORE_CH_SMITH  -> STORE_CH_SMITH  [2]group [3]shop
##   refmappingshopwithtab STORE_CH_SMITH        -> STORE_CH_SMITH_GROUP1  [2]shop [3]tabgroup
##   refshoptab            STORE_CH_SMITH_TAB1, group ..GROUP1, name SN_TAB_WEAPON  [3]tab [4]group [5]name
##   refshopgoods          STORE_CH_SMITH_TAB1   -> PACKAGE_ITEM_CH_BLADE_01_A  [2]tab [3]pkg [4]slot
##   refscrapofpackageitem PACKAGE_ITEM_..       -> ITEM_CH_BLADE_01_A          [2]pkg [3]item
##
## Then the item codename resolves through itemdata to the real item.

const T_SHOPGROUP := "server_dep\\silkroad\\textdata\\refshopgroup.txt"
const T_MAPGROUP := "server_dep\\silkroad\\textdata\\refmappingshopgroup.txt"
const T_MAPTAB := "server_dep\\silkroad\\textdata\\refmappingshopwithtab.txt"
const T_TAB := "server_dep\\silkroad\\textdata\\refshoptab.txt"
const T_GOODS := "server_dep\\silkroad\\textdata\\refshopgoods.txt"
const T_SCRAP := "server_dep\\silkroad\\textdata\\refscrapofpackageitem.txt"
## refshoptabgroup: [3] the tab group's code (STORE_CH_POTION_GROUP1), [4] its
## name's string id (SN_STORE_POTION_GROUP1) -- the talk menu's store line
## (round 725, store_lines_for).
const T_TABGROUP := "server_dep\\silkroad\\textdata\\refshoptabgroup.txt"

## One tab of a shop: its display-name string id and the item codenames it
## sells, in the archive's slot order.
class Tab:
	var name_strid: String
	var item_codes: PackedStringArray = PackedStringArray()
	## Beside item_codes: the ItemInstance each good is listed as, null for
	## the reference item. Only an NPC of OpenSRO's own fills it (round 786,
	## NpcShopDefNet.OP_SHOP_GOODS); a retail tab leaves it empty.
	var instances: Array = []

	## The instance good `i` is listed as, or null.
	func instance_at(i: int) -> Object:
		return instances[i] as Object if i >= 0 and i < instances.size() else null

## The parsed shop tables. Build once, then query with tabs_for(npc_code).
var _group_by_npc: Dictionary = {}     # NPC code (upper) -> group code
var _shop_by_group: Dictionary = {}    # group -> shop
var _tabgroup_by_shop: Dictionary = {} # shop -> tab group
var _tabs_by_group: Dictionary = {}    # tab group -> Array of [tab_code, name_strid], in order
var _goods_by_tab: Dictionary = {}     # tab code -> Array of [slot, package_code]
var _item_by_pkg: Dictionary = {}      # package code -> item codename
## Every row kept, in file order (round 725): an NPC can run several groups, a
## group map to several shops, a shop to several tab groups (STORE_WC_ARMOR
## has two). The single maps above keep the last row, as before.
var _groups_by_npc: Dictionary = {}    # NPC code (upper) -> Array of group codes
var _shops_by_group: Dictionary = {}   # group -> Array of shops
var _tabgroups_by_shop: Dictionary = {} # shop -> Array of tab groups
var _tabgroup_name: Dictionary = {}    # tab group -> name string id

## Parses the shop tables from an open Media.pk2 (via a reader callback that
## returns the raw bytes for a textdata path, or an empty array). Returns self.
func load(read: Callable) -> ShopReader:
	var _pp := ParseProfile.t0()
	for r in _rows(read.call(T_SHOPGROUP)):
		if r.size() > 4 and r[4].begins_with("NPC_"):
			var npc: String = r[4].strip_edges().to_upper()
			_group_by_npc[npc] = r[3].strip_edges()
			_append_unique(_groups_by_npc, npc, r[3].strip_edges())
	for r in _rows(read.call(T_MAPGROUP)):
		if r.size() > 3:
			_shop_by_group[r[2].strip_edges()] = r[3].strip_edges()
			_append_unique(_shops_by_group, r[2].strip_edges(), r[3].strip_edges())
	for r in _rows(read.call(T_MAPTAB)):
		if r.size() > 3:
			_tabgroup_by_shop[r[2].strip_edges()] = r[3].strip_edges()
			_append_unique(_tabgroups_by_shop, r[2].strip_edges(), r[3].strip_edges())
	for r in _rows(read.call(T_TABGROUP)):
		if r.size() > 4:
			_tabgroup_name[r[3].strip_edges()] = r[4].strip_edges()
	for r in _rows(read.call(T_TAB)):
		if r.size() > 5:
			var grp: String = r[4].strip_edges()
			if not _tabs_by_group.has(grp):
				_tabs_by_group[grp] = []
			_tabs_by_group[grp].append([r[3].strip_edges(), r[5].strip_edges()])
	for r in _rows(read.call(T_GOODS)):
		if r.size() > 4:
			var tab: String = r[2].strip_edges()
			if not _goods_by_tab.has(tab):
				_goods_by_tab[tab] = []
			var slot: int = int(r[4]) if r[4].strip_edges().is_valid_int() else 0
			_goods_by_tab[tab].append([slot, r[3].strip_edges()])
	for r in _rows(read.call(T_SCRAP)):
		if r.size() > 3:
			_item_by_pkg[r[2].strip_edges()] = r[3].strip_edges()
	ParseProfile.add("text.shop_goods", _pp)
	return self

## True when the NPC (by codename) runs a shop with resolvable goods.
func has_shop(npc_code: String) -> bool:
	return _group_by_npc.has(npc_code.to_upper())

## The talk menu's store lines for an NPC (round 725): one per tab group of
## each shop the NPC runs, in table order, each `{"tabgroup": code,
## "name_strid": SN_STORE_*}`. READ: the client's store-line builder
## FUN_006fb630 walks the NPC's shops (GlobalDataManager::FUN_00983cb0) and,
## inside each, its tab groups (FUN_00982760), writing "%d. " and then the
## group's own name (FUN_0093fa50(group) -> +0x24, resolved by FUN_008c9bb0);
## refshoptabgroup's [4] is that name (SN_STORE_POTION_GROUP1 "Purchase/ Sell
## recovery liquid medicine"). INFERRED: the walk's order is the tables' row
## order. Empty for an NPC with no resolvable tab group.
func store_lines_for(npc_code: String) -> Array:
	var out: Array = []
	for group in _groups_by_npc.get(npc_code.to_upper(), []):
		for shop in _shops_by_group.get(group, []):
			for tabgroup in _tabgroups_by_shop.get(shop, []):
				out.append({"tabgroup": tabgroup, "name_strid": _tabgroup_name.get(tabgroup, "")})
	return out

## The shop's tabs for an NPC codename, each with its real item codenames.
## Empty when the NPC has no shop. `tabgroup` (round 725) picks one store
## line's tab group (store_lines_for); empty takes the NPC's last-listed one,
## as before.
func tabs_for(npc_code: String, tabgroup: String = "") -> Array:
	var out: Array = []
	if tabgroup == "":
		var group: String = _group_by_npc.get(npc_code.to_upper(), "")
		if group == "":
			return out
		var shop: String = _shop_by_group.get(group, "")
		tabgroup = _tabgroup_by_shop.get(shop, "")
	if tabgroup == "":
		return out
	for pair in _tabs_by_group.get(tabgroup, []):
		var tab_code: String = pair[0]
		var t := Tab.new()
		t.name_strid = pair[1]
		var goods: Array = _goods_by_tab.get(tab_code, [])
		goods.sort_custom(func(a, b): return a[0] < b[0])
		for g in goods:
			var pkg: String = g[1]
			var item: String = _item_by_pkg.get(pkg, "")
			if item != "":
				t.item_codes.append(item)
		out.append(t)
	return out

static func _append_unique(map: Dictionary, key: String, value: String) -> void:
	if not map.has(key):
		map[key] = []
	if not (map[key] as Array).has(value):
		(map[key] as Array).append(value)

static func _rows(data: PackedByteArray) -> Array:
	if data == null or data.is_empty():
		return []
	var raw := data
	if raw.size() >= 2 and raw[0] == 0xFF and raw[1] == 0xFE:
		raw = raw.slice(2)
	var text := TextDecode.utf16(raw)
	if text.is_empty():
		text = raw.get_string_from_utf8()
	var out: Array = []
	for line in text.replace("\r", "").split("\n"):
		if line.strip_edges() == "" or line.begins_with("//"):
			continue
		out.append(line.split("\t"))
	return out
