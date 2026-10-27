extends HudCosBox
class_name FriendMsgBox

## Round 834: the friend list's two CMessageBoxManager boxes, built from the
## client's own `resinfo\ifmessagebox.txt` in the shell the COS, party and
## guild boxes share. READ from sro_client.exe (UI_SILKMALL::FUN_00644c90,
## jump table 0x648758, index purpose - 1) unless a line says otherwise.
##
## The manager creates a fresh box each time (0x6ec5d0: 0xba20b0, then
## 0x643c20(1), section MsgBoxINIF) at screen w / 2 - 0x9a, h / 2 - 0x4a.
## MsgBoxINIF's members (0x63e570, READ): +0x840..+0x850 are controls 1, 2,
## 3, 4 and 8 (GDR_MBIN_STATIC_MESSAGE1..5), +0x800 / +0x804 / +0x808 are
## 200 / 201 / 202 (GDR_MBIN_BTN_OK, _CANCEL, _CERTIFY; their layout
## captions UIIT_CTL_YES, UIIT_CTL_NO, UIIT_CTL_CONFIRM).
##
## - **0x23, the request** (c:0x886000 queues it; case 0x6482ef): title
##   UIIT_STT_AGREEMENT_BOX, 0x168 x 0x97 (360 x 151). MESSAGE1 is "'%s'"
##   with the asker's name (colour 0xffefdaa4) and MESSAGE2
##   UIIT_MSG_FRIEND_REQUEST_01, both 200 x 12, left-aligned, set side by
##   side on y 49: with w1, w2 their text widths, MESSAGE1 at x
##   8 + (343 - w2 - (w1 + 3)) / 2 and MESSAGE2 w1 + 3 after it (0x8b2f20
##   measures them). MESSAGE3 at (25, 78), 308 x 12, centred,
##   UIIT_MSG_FRIEND_REQUEST_02. OK at (98, 114) captioned UIIT_STT_ACCEPT;
##   CANCEL at (186, 114) with no caption set, so it keeps its layout's
##   UIIT_CTL_NO ("No"); CERTIFY is captioned UIIT_STT_REFUSE and then
##   hidden (0x6485b0 -> 0x6458ad). A retail quirk, kept: the box reads
##   Accept / No. OK answers 1, CANCEL 0 (c:0x798a15 / 0x798a29). The
##   box's timer 10 (0x644650) is 30000 ms here (no simple_msgbox_type);
##   when it fires 0x63bf40 destroys the box without answering, so the
##   server's own 30 s ends the request (0x640b reason 2).
## - **0x22, accepted** (0x3B07 kind 2, c:0x8863da; case 0x648114): title
##   UIIT_STT_CONFIRM_BOX, 360 x 151. MESSAGE1 at (8, 49), 343 x 12,
##   centred, colour 0xffefdaa4: UIIT_MSG_YOUNME "[%s]and [%s]'s" with the
##   new friend's name and then the player's own (0x9d6580 on the player
##   object at 0xeef5ec; that it is the own name is INFERRED from the
##   text). MESSAGE2 at (25, 78), 308 x 12, centred,
##   UIIT_MSG_FRIEND_CONCLUSION. OK at (141, 114), its layout caption;
##   CANCEL and CERTIFY hidden (0x6468c8). No timer.

const BOX_SIZE := Vector2(0x168, 0x97)
const COLOUR := Color8(0xef, 0xda, 0xa4)
const PAIR_SPAN := 0x157
const PAIR_GAP := 3.0
const PAIR_Y := 49.0
const PAIR_W := 200.0
const LINE_H := 12.0
const REQUEST_OK_AT := Vector2(98, 114)
const REQUEST_CANCEL_AT := Vector2(186, 114)
const ADDED_OK_AT := Vector2(141, 114)

enum Kind { ADDED = 0x22, REQUEST = 0x23 }

var kind := 0
## The request the box answers (Kind.REQUEST).
var request: FriendNet.Request

## Builds box 0x23 for `req`. False without the layout.
func build_request(builder: UiBuilder, req: FriendNet.Request) -> bool:
	kind = Kind.REQUEST
	request = req
	name = "FriendRequest"
	if not build_shell(builder, BOX_SIZE, "UIIT_STT_AGREEMENT_BOX", "UIIT_STT_AGREEMENT_BOX", LAYOUT, "MsgBoxINIF"):
		return false
	_add_background(builder, BOX_SIZE)
	var m1 := node("GDR_MBIN_STATIC_MESSAGE1")
	var m2 := node("GDR_MBIN_STATIC_MESSAGE2")
	var l1 := builder.set_static_text(m1, "'%s'" % req.asker_name) if m1 != null else null
	var l2 := builder.set_static_text(m2, text("UIIT_MSG_FRIEND_REQUEST_01", "UIIT_MSG_FRIEND_REQUEST_01")) if m2 != null else null
	if l1 != null:
		l1.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		l1.add_theme_color_override("font_color", COLOUR)
	if l2 != null:
		l2.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	var w1 := _width(l1)
	var w2 := _width(l2)
	var x := 8.0 + floorf((float(PAIR_SPAN) - w2 - (w1 + PAIR_GAP)) / 2.0)
	_place(m1, Rect2(Vector2(x, PAIR_Y), Vector2(PAIR_W, LINE_H)))
	_place(m2, Rect2(Vector2(x + w1 + PAIR_GAP, PAIR_Y), Vector2(PAIR_W, LINE_H)))
	var m3 := node("GDR_MBIN_STATIC_MESSAGE3")
	if m3 != null:
		_place(m3, Rect2(25, 78, 308, LINE_H))
		var l3 := builder.set_static_text(m3, text("UIIT_MSG_FRIEND_REQUEST_02", "UIIT_MSG_FRIEND_REQUEST_02"))
		if l3 != null:
			l3.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	for extra in ["GDR_MBIN_STATIC_MESSAGE4", "GDR_MBIN_STATIC_MESSAGE5"]:
		var n := node(extra)
		if n != null:
			builder.set_static_text(n, "")
	var ok := node("GDR_MBIN_BTN_OK")
	_wire(ok, REQUEST_OK_AT, press_ok)
	if ok is BaseButton:
		builder.set_button_text(ok as BaseButton, text("UIIT_STT_ACCEPT", "UIIT_STT_ACCEPT"))
	_wire(node("GDR_MBIN_BTN_CANCEL"), REQUEST_CANCEL_AT, press_cancel)
	var certify := node("GDR_MBIN_BTN_CERTIFY")
	if certify is BaseButton:
		builder.set_button_text(certify as BaseButton, text("UIIT_STT_REFUSE", "UIIT_STT_REFUSE"))
	if certify != null:
		certify.visible = false
	return true

## Round 834: the exchange's request box, HUD request kind 7 (c:0x644c90 case
## 7, 0x64602e..0x646181; docs/protocol/exchange_boxes.md A, READ): the
## manager's MsgBoxINIF box at 308 x 148, kind 7 setting only texts --
## UIIT_STT_CONFIRM_BOX; MESSAGE1 UIIT_STT_PARTY_SOMEUSER with the asker's
## name; MESSAGE2 UIIT_MSG_DEAL_ASK; OK UIIT_STT_ACCEPT and CANCEL
## UIIT_STT_REFUSE at their layout places; CERTIFY hidden; no timer (tail
## 0x64871b). Accept answers 1, Refuse 0 (exchange_verify, 0x63b6e0 /
## 0x63b8b0).
const EXCHANGE_BOX_SIZE := Vector2(0x134, 0x94)

func build_exchange_request(builder: UiBuilder, asker_name: String) -> bool:
	kind = 7
	name = "ExchangeRequest"
	if not build_shell(builder, EXCHANGE_BOX_SIZE, "UIIT_STT_CONFIRM_BOX", "UIIT_STT_CONFIRM_BOX", LAYOUT, "MsgBoxINIF"):
		return false
	_add_background(builder, EXCHANGE_BOX_SIZE)
	var m1 := node("GDR_MBIN_STATIC_MESSAGE1")
	if m1 != null:
		var fmt := text("UIIT_STT_PARTY_SOMEUSER", "UIIT_STT_PARTY_SOMEUSER")
		builder.set_static_text(m1, fmt.replace("%s", asker_name) if fmt.count("%s") == 1 else fmt)
	var m2 := node("GDR_MBIN_STATIC_MESSAGE2")
	if m2 != null:
		builder.set_static_text(m2, text("UIIT_MSG_DEAL_ASK", "UIIT_MSG_DEAL_ASK"))
	for extra in ["GDR_MBIN_STATIC_MESSAGE3", "GDR_MBIN_STATIC_MESSAGE4", "GDR_MBIN_STATIC_MESSAGE5"]:
		var n := node(extra)
		if n != null:
			builder.set_static_text(n, "")
	var ok := node("GDR_MBIN_BTN_OK")
	var cancel := node("GDR_MBIN_BTN_CANCEL")
	if ok is BaseButton:
		builder.set_button_text(ok as BaseButton, text("UIIT_STT_ACCEPT", "UIIT_STT_ACCEPT"))
		(ok as BaseButton).pressed.connect(press_ok)
	if cancel is BaseButton:
		builder.set_button_text(cancel as BaseButton, text("UIIT_STT_REFUSE", "UIIT_STT_REFUSE"))
		(cancel as BaseButton).pressed.connect(press_cancel)
	var certify := node("GDR_MBIN_BTN_CERTIFY")
	if certify != null:
		certify.visible = false
	return true

## Builds box 0x22: `friend_name` and `own_name` were made friends.
func build_added(builder: UiBuilder, friend_name: String, own_name: String) -> bool:
	kind = Kind.ADDED
	name = "FriendAdded"
	if not build_shell(builder, BOX_SIZE, "UIIT_STT_CONFIRM_BOX", "UIIT_STT_CONFIRM_BOX", LAYOUT, "MsgBoxINIF"):
		return false
	_add_background(builder, BOX_SIZE)
	var m1 := node("GDR_MBIN_STATIC_MESSAGE1")
	if m1 != null:
		_place(m1, Rect2(8, 49, 0x157, LINE_H))
		var fmt := text("UIIT_MSG_YOUNME", "UIIT_MSG_YOUNME")
		var shown := fmt % [friend_name, own_name] if fmt.count("%s") == 2 and fmt.count("%") == 2 else fmt
		var l1 := builder.set_static_text(m1, shown)
		if l1 != null:
			l1.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			l1.add_theme_color_override("font_color", COLOUR)
	var m2 := node("GDR_MBIN_STATIC_MESSAGE2")
	if m2 != null:
		_place(m2, Rect2(25, 78, 308, LINE_H))
		var l2 := builder.set_static_text(m2, text("UIIT_MSG_FRIEND_CONCLUSION", "UIIT_MSG_FRIEND_CONCLUSION"))
		if l2 != null:
			l2.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	for extra in ["GDR_MBIN_STATIC_MESSAGE3", "GDR_MBIN_STATIC_MESSAGE4", "GDR_MBIN_STATIC_MESSAGE5"]:
		var n := node(extra)
		if n != null:
			builder.set_static_text(n, "")
	_wire(node("GDR_MBIN_BTN_OK"), ADDED_OK_AT, press_ok)
	for hidden in ["GDR_MBIN_BTN_CANCEL", "GDR_MBIN_BTN_CERTIFY"]:
		var b := node(hidden)
		if b != null:
			b.visible = false
	return true

const REQUEST_TIMEOUT_SEC := 30.0

## Box 0x23's timer: closed, unanswered, after 30 s (call once in the tree).
func arm_request_timer() -> void:
	if kind != Kind.REQUEST or not is_inside_tree():
		return
	get_tree().create_timer(REQUEST_TIMEOUT_SEC).timeout.connect(func() -> void:
		if is_instance_valid(self) and not is_queued_for_deletion():
			close())

## CMessageBoxManager's placement (0x6ec5d0).
func place_on(view: Vector2) -> void:
	position = Vector2(floorf(view.x / 2.0) - 0x9a, floorf(view.y / 2.0) - 0x4a)

static func _width(l: Label) -> float:
	if l == null:
		return 0.0
	var f := l.get_theme_font("font")
	var fs := l.get_theme_font_size("font_size")
	return f.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x if f != null else 0.0
