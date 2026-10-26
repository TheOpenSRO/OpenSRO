extends HudCosBox
class_name RepairBox

## Round 829: the store's Repair All question, CMessageBoxManager purpose
## 0x0C, built from the client's own `resinfo\ifmessagebox.txt` (section
## MsgBoxINIF, mode 1: 0x6ec5d0 -> 0x643c20(1)). READ from sro_client.exe:
##
## - Opened by CIFStore's Repair All (control 0xc -> 0x6cfc00) with the quote
##   (RepairQuote) at +0x858 (0x63bc00); a quote of 0 opens nothing and says
##   UIIT_MSG_STRGERR_THERE_IS_NO_ITEM_TO_REPAIR instead. The client never
##   holds the quote against the purse: the server refuses (0x1c07).
## - Set up by UI_SILKMALL::FUN_00644c90's case 0x0C (0x646400..0x64671a):
##   resized to 400 x 210 and moved by (-46, -33) from the manager's place
##   (w / 2 - 154, h / 2 - 74); title UIIT_STT_AGREEMENT_BOX;
##   - +0x840 UIIT_CTL_REPAIR_ALL on `interface\messagebox\msgbox_skillname.ddj`
##     at (94, 46), 212 x 26, centred both ways;
##   - +0x844 UIIT_MSG_MSGBOX_REPAIR_ITEM at (0, 100), 400 x 12, centred;
##   - +0x848 the quote ("%d", 0xe18b1c: no separators) on
##     `interface\messagebox\msgbox_blackbox_04.ddj` at (149, 124), 124 x 24,
##     right-aligned and centred down, margins {0, 2, 9, 0} (0x6527d0; their
##     order left, top, right, bottom INFERRED);
##   - +0x84c UIIT_STT_GOLD at (278, 131), 30 x 12;
##   - Yes (+0x800) at (123, 168), No (+0x804) at (203, 168); +0x808 (CERTIFY)
##     hidden by the shared tail 0x64871b.
## - Yes (0x63b6e0 -> 0x63b733) sends the repair of everything (0x78fcf0(2,
##   -1, -1)) and closes the box; No closes it.
## +0x840..+0x84c as MESSAGE1..MESSAGE4 and +0x800 / +0x804 as OK / CANCEL is
## INFERRED, as GuildMsgBox takes them.

const SIZE := Vector2(400, 210)
const MANAGER_SIZE := Vector2(308, 148)
const MOVE := Vector2(-46, -33)
const BAR_DDJ := "interface\\messagebox\\msgbox_skillname.ddj"
const AMOUNT_DDJ := "interface\\messagebox\\msgbox_blackbox_04.ddj"
const BAR_RECT := Rect2(94, 46, 212, 26)
const BODY_RECT := Rect2(0, 100, 400, 12)
const AMOUNT_RECT := Rect2(149, 124, 124, 24)
## {left, top, right, bottom} (INFERRED order).
const AMOUNT_MARGINS := [0, 2, 9, 0]
const GOLD_RECT := Rect2(278, 131, 30, 12)
const YES_AT := Vector2(123, 168)
const NO_AT := Vector2(203, 168)

var quote := 0

func build_repair_all(builder: UiBuilder, total: int) -> bool:
	quote = total
	name = "RepairAllBox"
	if not build_shell(builder, SIZE, "UIIT_STT_AGREEMENT_BOX", "UIIT_STT_AGREEMENT_BOX", LAYOUT, "MsgBoxINIF"):
		return false
	_add_background(builder, SIZE)
	var bar := node("GDR_MBIN_STATIC_MESSAGE1")
	if bar != null:
		_art(builder, bar, BAR_DDJ, BAR_RECT)
		_place(bar, BAR_RECT)
		builder.set_static_text(bar, text("UIIT_CTL_REPAIR_ALL", "UIIT_CTL_REPAIR_ALL"))
		_align(bar, HORIZONTAL_ALIGNMENT_CENTER, VERTICAL_ALIGNMENT_CENTER)
	var body := node("GDR_MBIN_STATIC_MESSAGE2")
	if body != null:
		_place(body, BODY_RECT)
		builder.set_static_text(body, text("UIIT_MSG_MSGBOX_REPAIR_ITEM", "UIIT_MSG_MSGBOX_REPAIR_ITEM"))
		_align(body, HORIZONTAL_ALIGNMENT_CENTER, VERTICAL_ALIGNMENT_TOP)
	var amount := node("GDR_MBIN_STATIC_MESSAGE3")
	if amount != null:
		_art(builder, amount, AMOUNT_DDJ, AMOUNT_RECT)
		var m: Array = AMOUNT_MARGINS
		_place(amount, Rect2(AMOUNT_RECT.position + Vector2(m[0], m[1]),
			AMOUNT_RECT.size - Vector2(m[0] + m[2], m[1] + m[3])))
		builder.set_static_text(amount, "%d" % total)
		_align(amount, HORIZONTAL_ALIGNMENT_RIGHT, VERTICAL_ALIGNMENT_CENTER)
	var gold := node("GDR_MBIN_STATIC_MESSAGE4")
	if gold != null:
		_place(gold, GOLD_RECT)
		builder.set_static_text(gold, text("UIIT_STT_GOLD", "UIIT_STT_GOLD"))
	var fifth := node("GDR_MBIN_STATIC_MESSAGE5")
	if fifth != null:
		builder.set_static_text(fifth, "")
	_wire(node("GDR_MBIN_BTN_OK"), YES_AT, press_ok)
	_wire(node("GDR_MBIN_BTN_CANCEL"), NO_AT, press_cancel)
	var certify := node("GDR_MBIN_BTN_CERTIFY")
	if certify != null:
		certify.visible = false
	return true

## Where the manager puts it (0x6ec5d0), then the purpose's move.
func place_on(view: Vector2) -> void:
	position = Vector2(floorf(view.x / 2.0) - MANAGER_SIZE.x / 2.0, floorf(view.y / 2.0) - MANAGER_SIZE.y / 2.0) + MOVE

## The amount shown (QA, tests).
func amount_text() -> String:
	var n := node("GDR_MBIN_STATIC_MESSAGE3")
	return (n as Label).text if n is Label else ""

## A static's art, under it among its siblings.
func _art(builder: UiBuilder, over: Control, ddj: String, r: Rect2) -> void:
	var tex: Texture2D = builder.load_texture(ddj)
	if tex == null:
		return
	var art := TextureRect.new()
	art.name = String(over.name) + "Art"
	art.texture = tex
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_SCALE
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var parent := over.get_parent()
	parent.add_child(art)
	parent.move_child(art, over.get_index())
	_place(art, r)

static func _align(n: Control, h: HorizontalAlignment, v: VerticalAlignment) -> void:
	if n is Label:
		(n as Label).horizontal_alignment = h
		(n as Label).vertical_alignment = v
