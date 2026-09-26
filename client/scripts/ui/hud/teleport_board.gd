extends RefCounted
class_name TeleportBoard

## The Dimensional Teleporter window's rows (round 578): the authored board
## (resinfo\ifteleportboard.txt, HudPanels.PANELS["teleport"]) holds five
## CIFTeleportAreaSlot controls, and each is filled with the authored slot
## layout (resinfo\ifteleportareaslot.txt) -- the place, the price and a Move
## button -- the way CIFSkillBoard's rows are code-built inside their
## authored rects (HudPanels._build_group_row).
##
## Layouts read from the player's own Media.pk2 (never committed; read on the
## render box from /var/tmp/resinfo, round 578):
##
##   ifteleportboard.txt, section Create
##     GDR_TB_STATIC_TITLE  CIFStatic            13, 17,393,21  UIIT_PAG_TELEPORT
##     GDR_TB_BTN_CLOSE     CIFCloseButton      406, 15, 16,16
##     GDR_TB_STATIC_NAME   CIFStatic             8, 65,432,21  UIIT_CTL_TELEPORT_TARGET
##     GDR_TB_SPIN_PAGE     CIFSpinButtonCtrl   181,520, 80,24
##     GDR_TB_TASLOT1..5    CIFTeleportAreaSlot  47,{105,185,265,345,425},357,76
##   ifteleportareaslot.txt, section Create
##     GDR_TAS_STATIC_ICON  CIFStatic   6, 6, 64,64
##     GDR_TAS_STATIC_PLACE CIFStatic  70,14,182,21
##     GDR_TAS_STATIC_PRICE CIFStatic  70,44,182,21
##     GDR_TAS_BTN_MOVE     CIFButton 252,20, 92,36  UIIT_CTL_MOVE
##
## Disclosed stand-ins: the slot icon (GDR_TAS_STATIC_ICON) stays empty --
## nothing read attributes per-destination art; the board's window art
## (interface\teleport\tpt_window_zangan.ddj exists) is not wired, since its
## use by the board is unread, so the window has no frame of its own; the
## Move button carries no art because its layout names none (DDJ "") and the
## class's default is unread; what the retail slot writes into PLACE and
## PRICE is unread -- PLACE gets the destination's name and PRICE the
## archive's own list wording (price_text).

## The slot layout every CIFTeleportAreaSlot is filled from.
const SLOT_LAYOUT := "resinfo\\ifteleportareaslot.txt"
## The board's five slots, top to bottom (ifteleportboard.txt, IDs 10..14).
const SLOT_NAMES := ["GDR_TB_TASLOT1", "GDR_TB_TASLOT2", "GDR_TB_TASLOT3", "GDR_TB_TASLOT4", "GDR_TB_TASLOT5"]
## Destinations a page: one a slot, so the layout's five.
const PER_PAGE := 5
const SPIN_NAME := "GDR_TB_SPIN_PAGE"
const PLACE_NAME := "GDR_TAS_STATIC_PLACE"
const PRICE_NAME := "GDR_TAS_STATIC_PRICE"
const MOVE_NAME := "GDR_TAS_BTN_MOVE"
## The node each slot's built ifteleportareaslot section is put under.
const ROW_NODE := "AreaSlot"
## The two list formats UI_TELEPORT::FUN_006fd3e0 (0x006fd3e0) chooses between
## (docs/protocol/teleport_network.md, "The client's list, read"):
## UIIT_CTL_TELEPORT_FREE_RESULT when the link's fee word is 0, else
## UIIT_CTL_TELEPORT_RESULT with the fee.
const RESULT_TOKEN := "UIIT_CTL_TELEPORT_RESULT"
const FREE_TOKEN := "UIIT_CTL_TELEPORT_FREE_RESULT"
## The meta a Move button carries: the teleportdata id of its row.
const DEST_META := "teleport_dest_id"

## How many pages n destinations take: ceil(n / per_page), 0 for none.
static func page_count(n: int, per_page: int = PER_PAGE) -> int:
	if n <= 0 or per_page <= 0:
		return 0
	return int(ceil(float(n) / float(per_page)))

## The entries on one 0-based page: at most per_page of them, in the order
## given (the links' file order, the order the retail dialog numbers them in).
## Empty past the last page or for a negative page.
static func page_rows(entries: Array, page: int, per_page: int = PER_PAGE) -> Array:
	if page < 0 or per_page <= 0:
		return []
	var start := page * per_page
	if start >= entries.size():
		return []
	return entries.slice(start, mini(start + per_page, entries.size()))

## A destination's price line, in the archive's own list wording: the free
## format (UIIT_CTL_TELEPORT_FREE_RESULT; the 19-column row UiTextTable keeps
## reads "Teleport to [%s]area.") when the link's fee is 0 -- the retail
## dialog's rule -- or when `waived`, and the fee format
## (UIIT_CTL_TELEPORT_RESULT, "Teleport to [%s]area. [%d]gold") otherwise.
## Not UIIT_CTL_TELEPORT_RESULT_IMPROVE ("[%s]gold"): UI_TELEPORT::FUN_006fd3e0
## never asks for it. The fee is the raw link fee; the retail list adds a
## surcharge from a short at this+0x804 (FUN_006fc910, unread meaning; 0
## without fortresses) -- docs/protocol/teleport_network.md "The client's
## list, read". `waived` is srrevamp's display of the
## engine's level waiver only (GObjPC::HandleTeleportUse, `cmp al,0x14; ja`
## at 0x5136de); the retail dialog does not apply it, and the GM and testing
## waivers are the server's to report in the receipt. A format that is not
## exactly those placeholders (TeleportNet._fits), or no place, falls back to
## srrevamp's own wording.
static func price_text(place: String, fee: int, waived: bool, result_fmt: String, free_fmt: String) -> String:
	var free := fee <= 0 or waived
	if place != "":
		if free and TeleportNet._fits(free_fmt, false):
			return free_fmt % [place]
		if not free and TeleportNet._fits(result_fmt, true):
			return result_fmt % [place, fee]
	return "No cost" if free else "%d gold" % fee

## Builds the slot layout's Create section inside each of the window's five
## CIFTeleportAreaSlot controls, once, and connects each Move button to
## on_move, called with that row's destination id. Returns how many slots
## hold a row. A missing slot layout builds nothing (0): the board then has
## no Move to press, and the caller says so.
static func build_rows(window: HudWindow, builder: UiBuilder, slot_layout: UiLayoutParser.LayoutDef, on_move: Callable) -> int:
	var count := 0
	for slot_name in SLOT_NAMES:
		var slot := window.node(slot_name) as Control
		if slot == null:
			continue
		if slot.has_node(ROW_NODE):
			count += 1
			continue
		if builder == null or slot_layout == null:
			continue
		var row := builder.build_section(slot_layout, "Create")
		if row == null:
			continue
		row.name = ROW_NODE
		slot.add_child(row)
		var move := row.find_child(MOVE_NAME, true, false) as BaseButton
		if move != null:
			move.pressed.connect(func() -> void:
				if move.has_meta(DEST_META):
					on_move.call(int(move.get_meta(DEST_META))))
		count += 1
	return count

## Shows one page's entries in the slots: each entry is a Dictionary
## {dest_id, place, fee, waived}. A slot past the page's rows is hidden.
static func fill_rows(window: HudWindow, rows: Array, result_fmt: String, free_fmt: String) -> void:
	for i in range(SLOT_NAMES.size()):
		var slot := window.node(SLOT_NAMES[i]) as Control
		if slot == null:
			continue
		if i >= rows.size():
			slot.visible = false
			continue
		var entry: Dictionary = rows[i]
		slot.visible = true
		var place := str(entry.get("place", ""))
		var place_label := slot.find_child(PLACE_NAME, true, false) as Label
		if place_label != null:
			place_label.text = place
		var price_label := slot.find_child(PRICE_NAME, true, false) as Label
		if price_label != null:
			price_label.text = price_text(place, int(entry.get("fee", 0)), bool(entry.get("waived", false)), result_fmt, free_fmt)
			# The archive's sentence is longer than the authored 182-pixel
			# box for a long place name; the whole of it stays reachable.
			price_label.tooltip_text = price_label.text
			price_label.mouse_filter = Control.MOUSE_FILTER_PASS
		var move := slot.find_child(MOVE_NAME, true, false) as BaseButton
		if move != null:
			move.set_meta(DEST_META, int(entry.get("dest_id", 0)))

## The slot whose Move button carries dest_id on the page shown, or null.
static func move_button_for(window: HudWindow, dest_id: int) -> BaseButton:
	for slot_name in SLOT_NAMES:
		var slot := window.node(slot_name) as Control
		if slot == null or not slot.visible:
			continue
		var move := slot.find_child(MOVE_NAME, true, false) as BaseButton
		if move != null and move.has_meta(DEST_META) and int(move.get_meta(DEST_META)) == dest_id:
			return move
	return null
