extends RefCounted
class_name MallData

## Round 837: the item mall's catalogue from the player's own Media.pk2
## textdata, as the client builds it (docs/protocol/item_mall_data.md, its
## review item_mall_data_verify.md, and item_mall.md §2 / §3 / §7 with their
## corrections). c: client addresses, READ unless marked.
##
##   mallitemmenulistdata  ITEMMALL_MENU_LIST rows -> the left menu (2a)
##                         ITEMMALL_HOTITEM_LIST rows -> the main page's lists (2c)
##   refshop               code -> shop (c:0x926560 looks a menu row's code up)
##   refshopgroup          GROUP_MALL, NPC xxx -> the mall group (c:0x9842e0:
##                         an exact compare; c:0x9262c0 takes the first such
##                         group in ID order)
##   refmappingshopgroup   group -> its shops, in file order (c:0x9379c0: the
##                         request's shop index is the shop's place here)
##   refmappingshopwithtab shop -> tab groups; only the FIRST is built (W10)
##   refshoptab            tab group -> its tabs, in file order; a tab's place
##                         in the first group, empty tabs counted, is the
##                         request's tab byte (CMallItemData +0x8, W11)
##   refshopgoods          tab -> goods at their SlotIndex (c:0x985590)
##   refpackageitem        the good: id, SaleTag (+0x2c), name / desc / icon
##   refscrapofpackageitem the items it gives (Data = the "N Unit")
##   refpricepolicyofitem  one row per payment-device bit: Cost
##
## Service 0 rows are skipped (the loader tests column 0 first, c:0x95739d).
##
## OURS (round 838): the player's archive leaves the Avatar shop's Hat, Dress
## and Attach tabs empty, and sells its avatars, for silk, at an NPC store
## (GROUP_STORE_AVATARS) whose tabs carry the same names. An empty mall tab
## takes the goods of the avatar store's tab of its name (borrowed_goods), so
## the mall shows them and the try-on can wear them. The server's catalogue
## does the same (server internal/mall Build), so a buy names the same slot.

const TD := "server_dep\\silkroad\\textdata\\"
const T_MENU := TD + "mallitemmenulistdata.txt"
const T_SHOP := TD + "refshop.txt"
const T_GROUP := TD + "refshopgroup.txt"
const T_MAPGROUP := TD + "refmappingshopgroup.txt"
const T_MAPTAB := TD + "refmappingshopwithtab.txt"
const T_TABGROUP := TD + "refshoptabgroup.txt"
const T_TAB := TD + "refshoptab.txt"
const T_GOODS := TD + "refshopgoods.txt"
const T_PACKAGE := TD + "refpackageitem.txt"
const T_SCRAP := TD + "refscrapofpackageitem.txt"
const T_PRICE := TD + "refpricepolicyofitem.txt"

## c:0x9843ce..0x9843e6: the mall group's code, an exact compare.
const MALL_GROUP_CODE := "GROUP_MALL"
## OURS (round 838): the shop group whose tabs fill the mall's empty ones.
const AVATAR_STORE_GROUP := "GROUP_STORE_AVATARS"
## The "no value" literal the parsers turn into an empty string (c:0x97f920,
## `xxx` at 0xd81d38).
const NONE := "xxx"

## Payment-device bits (item_mall_data.md §4, READ s:0x617360 and the
## procedures): 1 gold, 2 silk, 4 gift silk, 8 guild point, 16 point
## (mileage), 32 honour point; 64..1024 tokens.
const PAY_GOLD := 1
const PAY_SILK := 2
const PAY_GIFT := 4
const PAY_GUILD := 8
const PAY_POINT := 16
const PAY_HONOR := 32

## SaleTag bits (c:0x7dec60; item_mall.md 3b).
const TAG_NEW := 1
const TAG_BEST := 2
const TAG_SALE := 4
const TAG_POPULAR := 8
const TAG_STOCK := 16
const TAG_PERIOD := 32

class MenuRow:
	var key := 0
	## "" for a row that is not a shop (`xxx`: HOT shop, Reserved).
	var code := ""
	var text_key := ""
	var art := ""
	var icon := ""

class HotRow:
	var order := 0
	var bit := 0
	var text_key := ""

class Scrap:
	var item_code := ""
	var opt_level := 0
	var variance := 0
	## The stack count of an expendable, else the instance's Data word.
	var data := 0
	var mag_params: Array = []

class Package:
	var id := 0
	var code := ""
	var sale_tag := 0
	var expand_term := ""
	var name_strid := ""
	var desc_strid := ""
	var icon := ""
	var scraps: Array = []          # Scrap
	## bit -> Cost, and bit -> PreviousCost.
	var costs := {}
	var previous := {}
	var devices := 0

	## The price the cell shows: bit 2's Cost (c:0x7de0d0, the data review).
	func silk_price() -> int:
		return int(costs.get(PAY_SILK, 0))

	## More than one item: a bundle (c:0x8bf0d0).
	func is_bundle() -> bool:
		return scraps.size() > 1

class Good:
	var shop_code := ""
	var shop_id := 0
	var shop_index := 0             # the shop's place in the mall group's list
	var tab_code := ""
	var tab_id := 0
	var tab_index := 0              # the tab's place in the shop's first tab group
	var tab_name := ""
	var slot := 0                   # refshopgoods SlotIndex
	var package: Package

class Tab:
	var code := ""
	var id := 0
	var index := 0
	var name_strid := ""
	var goods: Array = []           # Good, by SlotIndex

class Shop:
	var code := ""
	var id := 0
	var index := 0
	var tab_group := ""
	var tab_group_name := ""
	var tabs: Array = []            # Tab, the first tab group's, in file order

	## c:0x7e3090: the shop has a tab with at least one good.
	func has_goods() -> bool:
		for t in tabs:
			if not (t as Tab).goods.is_empty():
				return true
		return false

var menu: Array = []                # MenuRow, by key
var hot: Array = []                 # HotRow, by order
var group_id := 0                   # the mall group's u16 (1051)
var shops := {}                     # code -> Shop
var packages := {}                  # code -> Package
var packages_by_id := {}            # id -> Package
var goods: Array = []               # every Good of every mall shop

func load(read: Callable) -> MallData:
	var shop_ids := {}
	for r in _rows(read.call(T_SHOP)):
		if r.size() > 3:
			shop_ids[_s(r[3])] = int(r[2])
	# The mall group: the first in ID order whose NPC is none and whose code
	# is GROUP_MALL exactly.
	var best := -1
	for r in _rows(read.call(T_GROUP)):
		if r.size() > 4 and _s(r[3]) == MALL_GROUP_CODE and _s(r[4]) == NONE:
			var id := int(r[2])
			if best < 0 or id < best:
				best = id
	group_id = maxi(best, 0)
	var shop_list: Array = []
	var store_shops: Array = []
	for r in _rows(read.call(T_MAPGROUP)):
		if r.size() > 3 and _s(r[2]) == MALL_GROUP_CODE:
			shop_list.append(_s(r[3]))
		elif r.size() > 3 and _s(r[2]) == AVATAR_STORE_GROUP:
			store_shops.append(_s(r[3]))
	var tabgroups_by_shop := {}
	for r in _rows(read.call(T_MAPTAB)):
		if r.size() > 3:
			var sc := _s(r[2])
			if not tabgroups_by_shop.has(sc):
				tabgroups_by_shop[sc] = []
			(tabgroups_by_shop[sc] as Array).append(_s(r[3]))
	var tabgroup_name := {}
	for r in _rows(read.call(T_TABGROUP)):
		if r.size() > 4:
			tabgroup_name[_s(r[3])] = _s(r[4])
	var tabs_by_group := {}
	for r in _rows(read.call(T_TAB)):
		if r.size() > 5:
			var g := _s(r[4])
			if not tabs_by_group.has(g):
				tabs_by_group[g] = []
			(tabs_by_group[g] as Array).append([_s(r[3]), int(r[2]), _s(r[5])])
	var goods_by_tab := {}
	for r in _rows(read.call(T_GOODS)):
		if r.size() > 4:
			var t := _s(r[2])
			if not goods_by_tab.has(t):
				goods_by_tab[t] = []
			(goods_by_tab[t] as Array).append([int(r[4]), _s(r[3])])
	for r in _rows(read.call(T_PACKAGE)):
		if r.size() > 8:
			var p := Package.new()
			p.id = int(r[2])
			p.code = _s(r[3])
			p.sale_tag = int(r[4])
			p.expand_term = _s(r[5])
			p.name_strid = _none(_s(r[6]))
			p.desc_strid = _none(_s(r[7]))
			p.icon = _none(_s(r[8]))
			packages[p.code] = p
			packages_by_id[p.id] = p
	for r in _rows(read.call(T_SCRAP)):
		if r.size() > 7:
			var p: Package = packages.get(_s(r[2]))
			if p == null:
				continue
			var sc := Scrap.new()
			sc.item_code = _s(r[3])
			sc.opt_level = int(r[4])
			sc.variance = int(r[5])
			sc.data = int(r[6])
			var n := int(r[7])
			for k in mini(n, 12):
				if 8 + k < r.size():
					sc.mag_params.append(int(r[8 + k]))
			p.scraps.append(sc)
	for r in _rows(read.call(T_PRICE)):
		var f := _fields(r)
		if f.size() < 5:
			continue
		var p: Package = packages.get(_s(r[2]))
		if p == null:
			continue
		var bit := int(r[3])
		# 14 columns (the player's archive): PreviousCost at 4, Cost at 5;
		# a 13-column copy has no PreviousCost (item_mall_data.md §1.9).
		var cost := int(r[5]) if f.size() >= 14 else int(r[4])
		p.costs[bit] = cost
		p.previous[bit] = int(r[4]) if f.size() >= 14 else 0
		p.devices |= bit
	var borrowed := borrowed_goods(store_shops, tabgroups_by_shop, tabs_by_group, goods_by_tab)
	for i in shop_list.size():
		var code: String = shop_list[i]
		var shop := Shop.new()
		shop.code = code
		shop.id = int(shop_ids.get(code, 0))
		shop.index = i
		var groups: Array = tabgroups_by_shop.get(code, [])
		shop.tab_group = String(groups[0]) if not groups.is_empty() else ""
		shop.tab_group_name = String(tabgroup_name.get(shop.tab_group, ""))
		var tabs: Array = tabs_by_group.get(shop.tab_group, [])
		for k in tabs.size():
			var t := Tab.new()
			t.code = tabs[k][0]
			t.id = tabs[k][1]
			t.index = k
			t.name_strid = tabs[k][2]
			var list: Array = goods_by_tab.get(t.code, [])
			if list.is_empty():
				list = borrowed.get(t.name_strid, [])
			list.sort_custom(func(a, b): return int(a[0]) < int(b[0]))
			for g in list:
				var pkg: Package = packages.get(String(g[1]))
				if pkg == null:
					continue
				var good := Good.new()
				good.shop_code = code
				good.shop_id = shop.id
				good.shop_index = i
				good.tab_code = t.code
				good.tab_id = t.id
				good.tab_index = k
				good.tab_name = t.name_strid
				good.slot = int(g[0])
				good.package = pkg
				t.goods.append(good)
				goods.append(good)
			shop.tabs.append(t)
		shops[code] = shop
	_load_menu(read.call(T_MENU))
	return self

## OURS (round 838): the avatar store's goods by tab name, [SlotIndex,
## package code] each, only those with a silk price: what an empty mall tab
## of that name shows (the class comment).
func borrowed_goods(store_shops: Array, tabgroups_by_shop: Dictionary, tabs_by_group: Dictionary, goods_by_tab: Dictionary) -> Dictionary:
	var out := {}
	for sc in store_shops:
		var groups: Array = tabgroups_by_shop.get(sc, [])
		if groups.is_empty():
			continue
		for t in tabs_by_group.get(groups[0], []):
			var name := String(t[2])
			if name == "" or out.has(name):
				continue
			var list: Array = []
			for g in goods_by_tab.get(t[0], []):
				var pkg: Package = packages.get(String(g[1]))
				if pkg != null and pkg.devices & (PAY_SILK | PAY_GIFT):
					list.append(g)
			if not list.is_empty():
				out[name] = list
	return out

## The two sections of mallitemmenulistdata.txt (c:0x97fbe0, 0x957444).
func _load_menu(data: PackedByteArray) -> void:
	var section := ""
	var rows := {}
	var hot_rows := {}
	for r in _rows(data, true):
		var first := String(r[0]).strip_edges()
		if first.begins_with("#section"):
			section = first.substr(8).strip_edges()
			continue
		if first.begins_with("#") or first == "0" or r.size() < 2:
			continue
		if section == "ITEMMALL_MENU_LIST" and r.size() > 5:
			var m := MenuRow.new()
			m.key = int(r[1])
			m.code = _none(_s(r[2]))
			m.text_key = _s(r[3])
			m.art = _none(_s(r[4]))
			m.icon = _none(_s(r[5]))
			rows[m.key] = m
		elif section == "ITEMMALL_HOTITEM_LIST" and r.size() > 4:
			var h := HotRow.new()
			h.order = int(r[2])
			h.bit = int(r[3])
			h.text_key = _s(r[4])
			hot_rows[h.order] = h
	var keys := rows.keys()
	keys.sort()
	for k in keys:
		menu.append(rows[k])
	var orders := hot_rows.keys()
	orders.sort()
	for k in orders:
		hot.append(hot_rows[k])

## The menu rows the window creates (c:0x7e5160 -> 0x7e5220..0x7e5287): an
## empty code always; a shop's code only when the shop is in the mall group
## and has a tab with a good.
func visible_menu() -> Array:
	var out: Array = []
	for m in menu:
		var row: MenuRow = m
		if row.code == "":
			out.append(row)
		elif shops.has(row.code) and (shops[row.code] as Shop).has_goods():
			out.append(row)
	return out

## The goods of the main page's list for `bit`, in build order (the shops'
## tabs, then SlotIndex; c:0x7e4dc8). Bits 16 and 32 share one list.
func goods_with_tag(bit: int) -> Array:
	var out: Array = []
	for g in goods:
		var tag := (g as Good).package.sale_tag
		if bit == TAG_STOCK:
			if tag & (TAG_STOCK | TAG_PERIOD):
				out.append(g)
		elif tag & bit:
			out.append(g)
	return out

## Every good whose package name (through `name_of`) contains `text`, no
## de-duplication (c:0x7e32d0). Retail matches case as typed: the name's
## std::wstring::find (c:0x7e34ee -> 0x4ee310), which no case folding
## precedes, so "wings" never found "Wings of Azure" (the user, round 838:
## "the item mall search doesn't seem to work"). OURS: any case matches.
func search(text: String, name_of: Callable) -> Array:
	var out: Array = []
	if text == "":
		return out
	for g in goods:
		var n := String(name_of.call((g as Good).package))
		if n.findn(text) >= 0:
			out.append(g)
	return out

static func _s(v) -> String:
	return String(v).strip_edges()

static func _none(v: String) -> String:
	return "" if v == NONE or v == "XXX" else v

## The fields of a row without the trailing empty one a tab-ended row has.
static func _fields(r: Array) -> Array:
	var out := r.duplicate()
	while not out.is_empty() and String(out[-1]).strip_edges() == "":
		out.pop_back()
	return out

static func _rows(data: PackedByteArray, keep_sections := false) -> Array:
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
		var t := line.strip_edges()
		if t == "" or t.begins_with("//"):
			continue
		if t.begins_with("#"):
			if keep_sections:
				out.append([t])
			continue
		var cols := line.split("\t")
		# Column 0 is Service: a 0 row is skipped by the loader.
		if not keep_sections and String(cols[0]).strip_edges() == "0":
			continue
		out.append(cols)
	return out
