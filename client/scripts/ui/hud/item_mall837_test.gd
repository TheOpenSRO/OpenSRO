extends SceneTree

## Round 837: the item mall window against the real Media.pk2 -- the
## catalogue (MallData), the window (ItemMallController over GDR_RENEWAL_
## ITEM_MALL), its menu, main page, cells, search and the request a buy
## sends.
##   godot4 --headless --path client --script res://scripts/ui/hud/item_mall837_test.gd

const MEDIA := "/opt/sro-files/client/Media.pk2"
const PANELS_PATH := "res://scripts/ui/hud/hud_panels.gd"

var _failures := 0

class FakeNet extends RefCounted:
	var silk_balances: Array = [939, 3731, 0]
	var sent: Array = []
	func mall_buy(b: MallNet.Buy) -> void: sent.append(b)

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	await _run()
	print("FAILURES: %d" % _failures if _failures > 0 else "ALL PASS")
	quit(1 if _failures > 0 else 0)

func _run() -> void:
	if not FileAccess.file_exists(MEDIA):
		print("SKIP (no %s)" % MEDIA)
		return
	var pk2 := Pk2Reader.open(MEDIA)
	var read := func(path: String) -> PackedByteArray:
		var e = ObjectLoader.find_file(pk2, path)
		return pk2.read_file(e) if e != null else PackedByteArray()
	var d := MallData.new().load(read)
	_check(d.group_id == 1051, "the mall group is GROUP_MALL 1051 (got %d)" % d.group_id)
	_check(d.shops.size() == 5 and d.shops.has("MALL_CONSUME"), "five mall shops (got %s)" % str(d.shops.keys()))
	var codes: Array = []
	for s in ["MALL_ARCHEMY", "MALL_AVATAR", "MALL_CONSUME", "MALL_PET", "MALL_PREMIUM"]:
		codes.append((d.shops[s] as MallData.Shop).index if d.shops.has(s) else -1)
	_check(codes == [0, 1, 2, 3, 4], "shop indexes in the mapping's file order (got %s)" % str(codes))
	_check(d.goods.size() == 220, "220 goods (item_mall_data.md: A's mall; got %d)" % d.goods.size())
	var menu_keys: Array = []
	for m in d.visible_menu():
		menu_keys.append((m as MallData.MenuRow).text_key)
	_check(menu_keys.has("UIIT_STT_SILKMALL_HOT_STORE") and menu_keys.has("UIIT_STT_SILKMALL_SHOPPING_BASKET_LIST")
		and not menu_keys.has("UIIT_STT_SILKMALL_PACKAGE") and not menu_keys.has("UIIT_STT_SILKMALL_ARCHEMY"),
		"rows: HOT shop and Reserved shown (empty code), Bundle goods and the goodless Alchemy hidden (got %s)" % str(menu_keys))
	var hot_bits: Array = []
	for h in d.hot:
		hot_bits.append((h as MallData.HotRow).bit)
	_check(hot_bits == [16, 1, 2, 8], "the hot lists in key order, Service-1 rows only (got %s)" % str(hot_bits))
	var rrs: MallData.Package = d.packages.get("PACKAGE_ITEM_MALL_REVERSE_RETURN_SCROLL")
	_check(rrs != null and rrs.id == 25221 and rrs.sale_tag == 2 and rrs.costs.has(MallData.PAY_SILK),
		"PACKAGE_ITEM_MALL_REVERSE_RETURN_SCROLL: id 25221, SaleTag 2, a silk price (got %s)" % (str(rrs.costs) if rrs != null else "none"))
	# The window.
	var builder := UiBuilder.new(pk2, UiTextTable.parse(pk2.read_file(ObjectLoader.find_file(pk2, "server_dep\\silkroad\\textdata\\textuisystem.txt"))))
	root.size = Vector2i(1280, 720)
	var panels: Control = (load(PANELS_PATH) as GDScript).new(builder)
	root.add_child(panels)
	await process_frame
	var mall: ItemMallController = panels.call("_mall")
	var net := FakeNet.new()
	mall.net = net
	var w: HudWindow = panels.call("open_item_mall")
	await process_frame
	await process_frame
	_check(w != null and w.size == Vector2(800, 600), "GDR_RENEWAL_ITEM_MALL: 800 x 600 (got %s)" % str(w.size if w != null else null))
	if w == null:
		return
	_check(mall.active and panels.call("item_mall_open"), "open")
	var silk := w.find_child("GDR_ITEM_MALL_MYINFO_SILK", true, false) as Control
	var gift := w.find_child("GDR_ITEM_MALL_MYINFO_GIFT_SILK", true, false) as Control
	_check(_text(silk) == "939" and _text(gift) == "3731", "the info block's silk and gift silk (got %s / %s)" % [_text(silk), _text(gift)])
	var rows := w.find_child("MallMenu", true, false) as Control
	_check(rows != null and rows.get_child_count() > 0, "menu rows built")
	var first := rows.get_child(0) as Control
	_check(first.position == Vector2(0, 0) and first.size == Vector2(116, 32), "a row is 116 x 32 at the column's top")
	var goods := w.find_child("Content", true, false) as Control
	_check(goods != null and goods.get_child_count() > 1, "the main page has a bar and cells")
	var cells: Array = []
	for c in goods.get_children():
		if c.has_meta("good"):
			cells.append(c)
	_check(cells.size() >= 2 and (cells[0] as Control).position == Vector2(5, 20) and (cells[1] as Control).position == Vector2(204, 20),
		"cells: two per row at x 5 / 204 under a 20-px bar (got %s / %s)" % [str((cells[0] as Control).position) if cells.size() > 0 else "-",
			str((cells[1] as Control).position) if cells.size() > 1 else "-"])
	# A sub-tab: open Expendables and pick its first tab.
	var r0: Dictionary = mall._rows[0]
	mall.click_row(r0)
	_check(bool(r0["open"]) and (r0["subs"] as Array).size() > 0 and ((r0["subs"][0]["node"]) as Control).visible, "a row opens its sub-tabs")
	mall.click_sub(r0["subs"][0], r0)
	var tab_goods: Array = r0["subs"][0]["goods"]
	var good: MallData.Good = tab_goods[0]
	_check(int(mall._view.get("sections", [{}])[0]["goods"].size()) == tab_goods.size(), "the sub-tab shows its goods")
	# The request.
	var req := mall.buy_request(good, 2, 0)
	_check(req.group == 1051 and req.shop_index == good.shop_index and req.tab == good.tab_index and req.slot == good.slot
		and req.package_code == good.package.code and req.count == 2 and req.package_id == good.package.id,
		"a buy names group, shop index, tab index, SlotIndex, package code and id")
	mall.send_buy(good, 2, 0)
	_check(net.sent.size() == 1 and mall.dealing == 2, "send_buy sends and counts the purchase out")
	_check(not mall.close(), "the mall refuses to close while a purchase is out")
	mall.on_buy_result({"ok": true, "group": 1051, "shop": 0, "tab": 0, "slot": 0, "slots": [0], "count": 2})
	_check(mall.dealing == 0, "0xB034 {1} clears the counter")
	# Search.
	var name := mall.package_name(good.package)
	mall.search(name.substr(0, mini(5, name.length())))
	_check(String(mall._view.get("kind", "")) == "search" and (mall._view["sections"][0]["goods"] as Array).size() >= 1,
		"search by part of a name (%s)" % name)
	_check(mall.unit_text(rrs).ends_with("Unit"), "the unit text ' N' + Unit (got '%s')" % mall.unit_text(rrs))
	_check(mall.close() and not panels.call("item_mall_open") and panels.get("_windows").get("itemmall") == null, "closed and dropped")
	panels.queue_free()

func _text(c: Control) -> String:
	if c == null:
		return "<none>"
	if c is Label:
		return (c as Label).text
	var l := c.get_node_or_null("Text") as Label
	return l.text if l != null else "<none>"
