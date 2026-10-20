extends RefCounted
class_name SpecialtyFlow

const ErrorText = preload("res://scripts/net/error_text.gd")

## Round 801: the specialty trade on the client -- the specialty store's
## buy into the transport, the sale of the transport's goods, the quotation
## list, the trade scale's stars, the leash's and the town's lines and the
## trade-info window. World3D owns one. READ in sro_client.exe unless a line
## says otherwise (docs/protocol/jobs.md, "Specialty trade"):
## - the store line at an NPC whose set holds 0xc opens 0xc, not 1
##   (CIF_NPCTalk::FUN_007020c0 case 1, c:0x7022d6..0x702330: FUN_00534e70
##   on 0xc, then 0x7046 {npc, 0xc});
## - the buy of a good sends 0x7034 type 0x13 {own transport, tab, slot,
##   count, npc} (c:0x7923a0); its 0xB034 names the transport slots the
##   goods went into and the client places them from its own store data
##   (c:0x87eb50, the server sends no item record);
## - the sale sends type 0x14 {transport, slot, count, npc};
## - every refusal goes to the error dispatcher (TradeNet / ErrorText.trade_line);
## - 0x30E7 kind 1: UIIT_MSG_COSERR_TOO_FAR_FROM_TRADECART with 100
##   (c:0x883b10);
## - 0x300C 0x0c01: UIIT_MSG_JSERR_ROBBER_CANT_ENTER_TOWN_WITH_CART (the
##   0x300C handler's default, c:0x874ea0 -> the dispatcher).
## OURS, disclosed: the goods dropped on the store are sold through the
## store's own count box (the original's transport window opens
## CIFSpecialtyDeal there, whose OK path is not read); Sell All sends one
## sale per goods slot (its packets are not read).

var world: Node
var hud: HudPanels
var hud_cos: HudCos
## The open specialty store: its NPC's unique id and code, 0 / "" when none.
var store_npc := 0
var store_code := ""
var trade_info_box: TradeInfoBox

func _init(w: Node, h: HudPanels, c: HudCos) -> void:
	world = w
	hud = h
	hud_cos = c
	h.specialty_buy_hook = buy
	NetClient.trade_result.connect(_on_result)
	NetClient.trade_scale_changed.connect(func(_s: int) -> void: _refresh_cos())
	NetClient.trade_prices.connect(func(_p: Dictionary) -> void: _refresh_cos())
	NetClient.trade_leash.connect(_on_leash)
	NetClient.trade_info.connect(_on_info)

func _text(key: String, fallback: String) -> String:
	return String(world.call("_resolve_any_text", key, fallback))

func _syslog(text: String, type: int = HudSystemMessage.TYPE_ALWAYS) -> void:
	world.call("_log_system", text, type)

## The 0xB046 of 0xc: the store is the specialty store.
func store_opened(npc_uid: int, code: String) -> void:
	store_npc = npc_uid
	store_code = code
	_refresh_cos()

func store_closed() -> void:
	store_npc = 0
	store_code = ""
	_refresh_cos()

## The player's own transport: its uid and data, or [0, null].
func own_transport() -> Array:
	for uid in NetClient.cos_own:
		var d: CosNet.Data = NetClient.cos_own[uid]
		if d.kind == CosNet.KIND_TRANSPORT:
			return [int(uid), d]
	return [0, null]

## HudPanels._do_buy's hook: a good bought at the specialty store goes into
## the transport. True when taken.
func buy(item_id: int, count: int) -> bool:
	if store_npc == 0:
		return false
	var row := hud.item_row(item_id)
	if row == null or not SpecialtyNet.is_good(Array(row.type_ids)):
		return false
	var at := hud.shop_good_position(item_id)
	if at.x < 0:
		return false
	var t := own_transport()
	print("TRADE: buy item %d x%d at tab %d slot %d (transport %d)" % [item_id, count, at.x, at.y, t[0]])
	NetClient.send_specialty_buy(int(t[0]), at.x, at.y, count, store_npc)
	return true

## Goods put down on the store from the transport's bag: the count box,
## then the sale.
func sell_from(uid: int, slot: int, item_id: int, qty: int) -> void:
	if store_npc == 0:
		return
	var price := int(NetClient.trade_prices_now.get(item_id, 0))
	if price == 0:
		var row := hud.item_row(item_id)
		price = row.sell_price if row != null else 0
	var npc := store_npc
	hud.confirm_sell_goods(item_id, qty, price, func(q: int) -> void:
		print("TRADE: sell transport slot %d x%d to npc %d" % [slot, q, npc])
		NetClient.send_specialty_sell(uid, slot, q, npc))

## The transport window's Sell All: every goods slot sold (OURS: one sale a
## slot; the button's packets are not read).
func sell_all(uid: int) -> void:
	if store_npc == 0:
		return
	var d: CosNet.Data = NetClient.cos_own.get(uid)
	if d == null:
		return
	for slot in d.items:
		var it: ItemInstance = d.items[slot]
		NetClient.send_specialty_sell(uid, int(slot), maxi(1, it.count), store_npc)

func _on_result(d: Dictionary) -> void:
	if d.is_empty():
		return
	if not bool(d.get("ok", false)):
		var code := int(d.get("code", 0))
		var line := ErrorText.trade_line(code, world.get("_ui_text_table"))
		print("TRADE: refused, code 0x%x (%s)" % [code, line if line != "" else "no message in the client"])
		if line != "":
			_syslog(line)
		return
	var uid := int(d["cos"])
	var data: CosNet.Data = NetClient.cos_own.get(uid)
	if data == null:
		return
	match int(d["type"]):
		SpecialtyNet.TYPE_BUY:
			var item_id := hud.shop_item_at(int(d["tab"]), int(d["slot"]))
			for dest in d.get("dests", []):
				var it := ItemInstance.new()
				it.ref_item_id = item_id
				it.is_equipment = false
				it.count = int(d["count"])
				it.creator = NetClient.job_alias
				it.slot = int(dest)
				data.items[int(dest)] = it
		SpecialtyNet.TYPE_SELL:
			var slot := int(d["slot"])
			var it: ItemInstance = data.items.get(slot)
			if it != null:
				it.count -= int(d["count"])
				if it.count <= 0:
					data.items.erase(slot)
	_refresh_cos()

func _refresh_cos() -> void:
	if hud_cos != null:
		hud_cos.refresh_trade()

func _on_leash(kind: int) -> void:
	if kind != 1:
		return
	var fmt := _text("UIIT_MSG_COSERR_TOO_FAR_FROM_TRADECART", "A character cannot move if he is %d m away from his transport.")
	_syslog(fmt.replace("%d", str(SpecialtyNet.LEASH_METRES)))

## 0x300C's words the trade sends (0x0c01).
func on_notice_word(word: int) -> bool:
	if word != SpecialtyNet.NOTICE_ROBBER_CART_TOWN:
		return false
	_syslog(_text("UIIT_MSG_JSERR_ROBBER_CANT_ENTER_TOWN_WITH_CART",
		"Thieves are not permitted to enter Safe Zones with transports active!"))
	return true

# --- The trade-info window ---------------------------------------------------------

## The talk line 0x39 (UIIT_PAG_SPECIAL_PRICE_CONDITION_INFO) opens it with no
## request (c:0x79e510).
func open_trade_info() -> void:
	if trade_info_box != null and is_instance_valid(trade_info_box):
		trade_info_box.close()
	trade_info_box = TradeInfoBox.new()
	var npcs: Array = world.call("_special_npc_ids")
	if not trade_info_box.build_info(hud.job_builder(), npcs, func(ref: int) -> String:
			return String(world.call("_special_npc_store_name", ref)),
			func(item: int) -> String: return String(world.call("_trade_item_name", item)),
			func(item: int) -> String: return String(world.call("_trade_item_origin", item))):
		trade_info_box.queue_free()
		trade_info_box = null
		return
	trade_info_box.refresh_requested.connect(func(ref: int) -> void: NetClient.send_trade_info(ref))
	hud.open_job_box(trade_info_box)

func _on_info(rows: Array) -> void:
	if trade_info_box != null and is_instance_valid(trade_info_box):
		trade_info_box.set_rows(rows)
