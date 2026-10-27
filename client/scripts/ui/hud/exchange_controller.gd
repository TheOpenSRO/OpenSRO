extends RefCounted
class_name ExchangeController

## Round 834: CIFExchange's behaviour over HudPanels' "exchange" window (the
## frame and layout are GDR_EXCHANGE / ifexchange.txt, built by HudPanels).
## docs/protocol/exchange.md §4 and its review exchange_verify.md; READ from
## sro_client.exe unless a line says otherwise.
##
## - The window shows the opponent on top (OTHER_*) and the player below
##   (MY_*), each a 6 x 2 grid of 12 slots, a gold row and a header:
##   UIIT_STT_SOMEONESITEM_GUILD "[%s - %s]'s item" with the name and guild
##   (UIIT_STT_WITH_OUT_GUILD with none), or UIIT_STT_SOMEONESITEM with
##   "*name" out of the normal state (c:0x7b2d00).
## - Retail 1.188's layout parks the portraits, the red effect and the log
##   box at x 9999 and no code moves them (exchange.md §4.3), so the log's
##   lines are seen only where they also go to the system window or a banner.
## - The opening (c:0x7b2530(1), 0x7b36b0, vslot_023 0x7b3790): exchange mode
##   on, the window shown, the main popup on its inventory tab, both golds 0,
##   the flags cleared, the button "Confirm" and enabled; then
##   UIIT_MSG_EXCHANGE_START in orange, the headers, the trust check
##   (UI_EXCHANGE::FUN_007b2270: the opponent in the friend list, the guild or
##   the union -- exchange_verify W6), and an open alchemy window closed.
## - The button (c:0x7b3480): nothing offered on either side and the golds
##   equal -> a local 0xB082 {2, 0x1823}; busy (+0x7bc) -> nothing; not
##   confirmed -> busy, UIIT_MSG_EXCHANGE_DECEPTION_REAFFIRM, 0x7082;
##   confirmed with the opponent confirmed -> busy,
##   UIIT_MSG_EXCHANGE_AGREEMENT_WAIT, 0x7083.
## - 0xB082 {1} (0x7b2700(1)): own side confirmed -- its gold grey, its 12
##   slots blue (com_item_exchange.ddj) and not pickable, the button
##   "Approve", enabled only once the opponent confirmed. 0x3086
##   (0x7b2670(1)): the opponent's side the same, the button enabled if ours
##   is confirmed. 0xB083 {1} or {2}: busy and the button disabled.
## - Cancel and X (0x7b24d0): the bag enabled again, 0x7084; the window stays
##   until 0xB084 {1} or 0x3088.
## - 0x3088 (c:0x880840): 0x7084 sent back if still in exchange mode, the
##   window hidden, the mode off, the HUD requests of kinds 6, 7 and 8 gone
##   (the exchange box and the party boxes), the code's category-1 message.
## - 0x3087 (c:0x88bb50): the window hidden, the mode off, the messages.
##
## OURS, disclosed: at 0x3087 retail moves the items in its own bag copy
## (the opponent's into the first free slots, its own out); this client asks
## the server for its bag list instead, whose placement is the same rule
## (server exchange.go). The union test has no data to test: OpenSRO has no
## unions yet, so only the friend list and the guild can trust a partner.

const WINDOW := "exchange"
const BLUE := "interface\\ifcommon\\com_item_exchange.ddj"
const ORANGE := Color8(0xff, 0xb5, 0x41)   # 0xffffb541
const RED := Color8(0xff, 0x4a, 0x4a)      # 0xffff4a4a
const MY_PREFIX := "GDR_EXCHANGE_MY_SLOT_"
const OTHER_PREFIX := "GDR_EXCHANGE_OTHER_SLOT_"

## The HudPanels this drives (its windows, builder and helpers).
var panels
## GI+0x508: the exchange window is in use.
var active := false
var partner := {}
var own := {}
## index -> ExchangeNet.Offered, as the last 0x308C for each side said.
var my_items := {}
var other_items := {}
var my_gold := 0
var other_gold := 0
## +0x7bc busy, +0x7bd own side confirmed, +0x7be the opponent confirmed.
var busy := false
var mine_confirmed := false
var other_confirmed := false
## Bag slots offered (0-based), disabled in the bag while offered.
var offered_slots := {}

## NetClient, or a stand-in a test gives (its sends and its friend list and
## guild data).
var net = null

func _init(hud_panels) -> void:
	panels = hud_panels

func _net():
	if net != null:
		return net
	var tree := Engine.get_main_loop() as SceneTree
	return tree.root.get_node_or_null("/root/NetClient") if tree != null else null

func window():
	return panels._windows.get(WINDOW) if panels != null else null

func node(control_name: String) -> Control:
	var w = window()
	return w.node(control_name) as Control if w != null else null

## The partner's id, or -1.
func partner_id() -> int:
	return int(partner.get("id", -1)) if active else -1

# --- opening and closing ---------------------------------------------------------

func open(partner_info: Dictionary, own_info: Dictionary) -> void:
	partner = partner_info
	own = own_info
	active = true
	panels.open_exchange_window()
	reset()
	_headers()
	panels.exchange_line("UIIT_MSG_EXCHANGE_START", [_display_name(partner)], ORANGE)
	if not _trusted():
		var key := "UIIT_MSG_EXCHANGE_DECEPTION_COMPARE" if bool(partner.get("normal", true)) else "UIIT_MSG_EXCHANGE_NAME_WARNING"
		panels.exchange_warning(key, RED)

## 0x7b36b0: both golds 0, the flags cleared, the button "Confirm" and
## enabled, the slots un-tinted, the grids empty.
func reset() -> void:
	my_items = {}
	other_items = {}
	my_gold = 0
	other_gold = 0
	busy = false
	mine_confirmed = false
	other_confirmed = false
	offered_slots = {}
	panels.set_exchange_money(0, 0)
	panels.exchange_gold_greyed(false, false)
	_set_button("UIIT_CTL_CONFIRM", true)
	_redraw()

func _display_name(info: Dictionary) -> String:
	var n := String(info.get("name", ""))
	return n if bool(info.get("normal", true)) else "*" + n

## UI_EXCHANGE::FUN_007b2270 in its order (exchange_verify W6): friend,
## guild, union. A partner out of the normal state is never trusted.
func _trusted() -> bool:
	if not bool(partner.get("normal", true)):
		return false
	var who := String(partner.get("name", ""))
	for f in _net().last_friend_list:
		if String(f.friend_name) == who:
			return true
	var g = _net().guild_data
	if g != null and g.in_guild:
		for m in g.members:
			if String(m.member_name) == who:
				return true
	return false

func _headers() -> void:
	panels.exchange_header(true, _header_text(own))
	panels.exchange_header(false, _header_text(partner))

func _header_text(info: Dictionary) -> String:
	if not bool(info.get("normal", true)):
		var plain: String = panels._resolve_ui("UIIT_STT_SOMEONESITEM", "UIIT_STT_SOMEONESITEM")
		return plain.replace("%s", _display_name(info)) if plain.count("%s") == 1 else plain
	var fmt: String = panels._resolve_ui("UIIT_STT_SOMEONESITEM_GUILD", "UIIT_STT_SOMEONESITEM_GUILD")
	var guild := String(info.get("guild", ""))
	if guild == "":
		guild = String(panels._resolve_ui("UIIT_STT_WITH_OUT_GUILD", "UIIT_STT_WITH_OUT_GUILD"))
	if fmt.count("%s") == 2:
		return fmt % [String(info.get("name", "")), guild]
	return fmt

## 0x3087 (code 1) or 0x3088 (the code).
func closed(code: int) -> void:
	var was := active
	active = false
	if code == 1:
		panels.exchange_line("UIIT_MSG_EXCHANGE_END", [_display_name(partner)], Color.WHITE, false)
		panels.exchange_done_notice()
		panels.refresh_bag_after_exchange()
	elif was:
		# c:0x880840: still in exchange mode, so 0x7084 goes back.
		_net().exchange_cancel()
	panels.close_exchange_window()
	panels.close_request_boxes_6_7_8()
	offered_slots = {}
	panels.redraw_bag()
	if code != 1:
		panels.exchange_code_message(code)

# --- the server's messages ---------------------------------------------------------

func on_offer(d: Dictionary) -> void:
	if not active:
		return
	var items := {}
	for o in d.get("items", []):
		items[int(o.index)] = o
	if bool(d.get("own", false)):
		# 0x6b3f40(1), then 0x6b3f00(slot, 0) for each entry: the offered
		# bag slots disabled.
		my_items = items
		offered_slots = {}
		for o in items.values():
			if int(o.bag_slot) >= 0:
				offered_slots[int(o.bag_slot)] = true
		panels.redraw_bag()
	else:
		other_items = items
	_redraw()

func on_moved(r: Dictionary) -> void:
	if r.has("code"):
		panels.exchange_code_message(int(r["code"]))
		return
	if int(r.get("type", -1)) == ExchangeNet.MOVE_GOLD:
		my_gold = int(r["gold"])
		panels.set_exchange_money(my_gold, -1)

func on_partner_gold(gold: int) -> void:
	other_gold = gold
	panels.set_exchange_money(-1, gold)

## 0x3086 (0x7b2670(1)): the opponent's gold grey and grid blue; the button
## is enabled when this side has confirmed (0x7b2310 -> 0x655ec0(1)) and
## otherwise left alone -- its caption and state stay as they were, so a
## side that has not confirmed yet can still press Confirm.
func on_partner_confirmed() -> void:
	other_confirmed = true
	panels.exchange_gold_greyed(mine_confirmed, true)
	_redraw()
	if mine_confirmed:
		panels.exchange_button_enabled(true)

## 0xB082 / 0xB083 / 0xB084: the request's opcode (0x3082...) and 1 or the
## code.
func on_result(op: int, code: int) -> void:
	match op:
		0x3082:
			busy = false
			if code == 1:
				mine_confirmed = true
				panels.exchange_gold_greyed(true, other_confirmed)
				_redraw()
				_set_button("UIIT_CTL_ACKNOWLEDGMENT", other_confirmed)
			else:
				panels.exchange_code_message(code)
		0x3083:
			# 0xB083 {1} and {2} both set +0x7bc and disable the button
			# (exchange_verify, "the client sets +0x7bc on 0xb083 [2] too").
			busy = true
			_set_button("UIIT_CTL_ACKNOWLEDGMENT", false)
			if code != 1:
				panels.exchange_code_message(code)
		0x3084:
			if code == 1:
				panels.close_exchange_window()

# --- the player's actions ----------------------------------------------------------

## Button 11 (c:0x7b3480).
func press_button() -> void:
	if not active:
		return
	if my_items.is_empty() and other_items.is_empty() and my_gold == other_gold:
		panels.exchange_code_message(0x1823)
		return
	if busy:
		return
	if not mine_confirmed:
		busy = true
		panels.exchange_warning("UIIT_MSG_EXCHANGE_DECEPTION_REAFFIRM", ORANGE)
		_net().exchange_confirm()
	elif other_confirmed:
		busy = true
		panels.exchange_line("UIIT_MSG_EXCHANGE_AGREEMENT_WAIT", [], ORANGE)
		_net().exchange_approve()

## Cancel (12) and the X (0x7b24d0).
func press_cancel() -> void:
	if not active:
		return
	offered_slots = {}
	panels.redraw_bag()
	_net().exchange_cancel()

## The gold button (15, c:0x7b2500): the quantity box, purpose 8, only while
## this side has not confirmed.
func press_gold() -> void:
	if active and not mine_confirmed:
		panels.open_exchange_gold_box()

## A bag item put down on the window or Alt+clicked (vslot_028 c:0x7b2600,
## c:0x681b7a): only before this side confirms; CanTrade and the devil's
## spirit refuse it here (SOItem::FUN_008baf10), else the quantity box,
## purpose 7, whose OK sends 0x7034 {4, slot}.
func offer_from_bag(slot: int, item_id: int, qty: int) -> void:
	if not active or mine_confirmed:
		return
	var refusal: int = panels.exchange_item_refusal(slot, item_id)
	if refusal != 0:
		panels.exchange_code_message(refusal)
		return
	panels.open_exchange_item_box(slot, item_id, qty)

## Alt+click on an own slot, allowed only while neither side confirmed
## (c:0x681de8); a slot picked up and put on the bag while this side has not
## confirmed (CIFInventory::vslot_028, kind 0x1a).
func remove_index(index: int, by_alt: bool) -> void:
	if not active or mine_confirmed or (by_alt and other_confirmed):
		return
	if my_items.has(index):
		_net().exchange_remove(index)

## The item a slot of either grid shows (tooltips), or null.
func instance_at(own_side: bool, index: int) -> Object:
	var items := my_items if own_side else other_items
	return (items[index] as ExchangeNet.Offered).item if items.has(index) else null

# --- drawing -------------------------------------------------------------------------

func _set_button(key: String, enabled: bool) -> void:
	panels.exchange_button(key, enabled)

func _redraw() -> void:
	panels.exchange_draw_grid(true, my_items, mine_confirmed)
	panels.exchange_draw_grid(false, other_items, other_confirmed)
