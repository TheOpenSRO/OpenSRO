extends HudCosBox
class_name MsgBoxInif

## CMessageBoxManager's MsgBoxINIF boxes that stood in this client as a dark,
## gold-edged panel of its own (round 848, lane H: the native-GUI census).
## Built from the client's `resinfo\ifmessagebox.txt` section MsgBoxINIF in
## the shell the COS, party and guild boxes share (HudCosBox / PartyMatchBox:
## the `msgbox2_window_` frame, the caption static, the file's "Create" tile).
## READ from sro_client.exe; every purpose is UI_SILKMALL::FUN_00644c90's
## case for it (jump table 0x648758, index purpose - 1, checked against the
## known cases 0x0F -> 0x6468de and 0x12 -> 0x646a27). The box is 0x134 x
## 0x94 (0x6ec5d0) and placed at screen w / 2 - 0x9a, h / 2 - 0x4a (GuildMsgBox
## has the reading). +0x840 / +0x844 as GDR_MBIN_STATIC_MESSAGE1 / 2 and
## +0x800 / +0x804 / +0x808 as OK / CANCEL / CERTIFY are INFERRED, as
## GuildMsgBox, HudCosBox and PartyInvitePopup take them.
##
## - **5, the return point** (case 0x644f93): title UIIT_STT_AGREEMENT_BOX;
##   +0x840 UIIT_MSG_MSGBOX_SETREBIRTH_CURPOS formatted with the player's zone
##   name (0x644fce..0x64505b); +0x844 UIIT_MSG_MSGBOX_SETREBIRTH_ASKCERTIFY;
##   +0x808 hidden (0x64871b with ebp 0). Opened by a town gate's line
##   (CIF_NPCTalk case 9, 0x7027b5); OK sends the request (FUN_00797d90 case 5).
## - **0x1F, an item used on another** (case 0x647d62): title
##   UIIT_STT_CONFIRM_BOX; +0x840 UIIT_MSG_QUESTION_SILKMALL_ITEM_USE
##   (0xd9c320, joining 0x647880); +0x808 hidden.
## - **0x20, a cancellable buff** (case 0x647d9a): title UIIT_STT_CONFIRM_BOX;
##   +0x840 UIIT_MSG_QUESTION_SILKMALL_ITEM_USE_CANCLE_1 (0xd9c2c0); +0x844
##   _CANCLE_2 (0xd9c260, joining case 5's tail at 0x645065); +0x808 hidden.
## The buttons keep the layout's own text (UIIT_CTL_YES / UIIT_CTL_NO).

enum Kind { RETURN_POINT = 0x05, ITEM_USE = 0x1f, BUFF_CANCEL = 0x20 }

const SIZE := Vector2(0x134, 0x94)
const MESSAGES := ["GDR_MBIN_STATIC_MESSAGE1", "GDR_MBIN_STATIC_MESSAGE2", "GDR_MBIN_STATIC_MESSAGE3",
	"GDR_MBIN_STATIC_MESSAGE4", "GDR_MBIN_STATIC_MESSAGE5"]

var kind := 0

## Builds box `box_kind` (Kind) named `box_name`. `zone_name` fills the
## return point's first line. False without the layout or for another kind.
func build_kind(builder: UiBuilder, box_kind: int, box_name: String, zone_name: String = "") -> bool:
	var title := ""
	var lines: Array = []
	match box_kind:
		Kind.RETURN_POINT:
			title = "UIIT_STT_AGREEMENT_BOX"
		Kind.ITEM_USE, Kind.BUFF_CANCEL:
			title = "UIIT_STT_CONFIRM_BOX"
		_:
			return false
	kind = box_kind
	name = box_name
	if not build_shell(builder, SIZE, title, title, LAYOUT, "MsgBoxINIF"):
		return false
	match box_kind:
		Kind.RETURN_POINT:
			var fmt := text("UIIT_MSG_MSGBOX_SETREBIRTH_CURPOS", "UIIT_MSG_MSGBOX_SETREBIRTH_CURPOS")
			lines = [fmt.replace("%s", zone_name) if fmt.count("%s") == 1 else fmt,
				text("UIIT_MSG_MSGBOX_SETREBIRTH_ASKCERTIFY", "UIIT_MSG_MSGBOX_SETREBIRTH_ASKCERTIFY")]
		Kind.ITEM_USE:
			lines = [text("UIIT_MSG_QUESTION_SILKMALL_ITEM_USE", "UIIT_MSG_QUESTION_SILKMALL_ITEM_USE")]
		Kind.BUFF_CANCEL:
			lines = [text("UIIT_MSG_QUESTION_SILKMALL_ITEM_USE_CANCLE_1", "UIIT_MSG_QUESTION_SILKMALL_ITEM_USE_CANCLE_1"),
				text("UIIT_MSG_QUESTION_SILKMALL_ITEM_USE_CANCLE_2", "UIIT_MSG_QUESTION_SILKMALL_ITEM_USE_CANCLE_2")]
	_add_background(builder, SIZE)
	for i in MESSAGES.size():
		var n := node(MESSAGES[i])
		if n != null:
			builder.set_static_text(n, str(lines[i]) if i < lines.size() else "")
	var ok := node("GDR_MBIN_BTN_OK")
	var cancel := node("GDR_MBIN_BTN_CANCEL")
	if ok is BaseButton:
		(ok as BaseButton).pressed.connect(press_ok)
	if cancel is BaseButton:
		(cancel as BaseButton).pressed.connect(press_cancel)
	var certify := node("GDR_MBIN_BTN_CERTIFY")
	if certify != null:
		certify.visible = false
	return true

## A message line's text ("" when it has none).
func line(i: int) -> String:
	var n := node(MESSAGES[i]) if i >= 0 and i < MESSAGES.size() else null
	if n is Label:
		return (n as Label).text
	var l := n.get_node_or_null("Text") as Label if n != null else null
	return l.text if l != null else ""

## CMessageBoxManager's placement (0x6ec5d0).
func place_on(view: Vector2) -> void:
	position = Vector2(floorf(view.x / 2.0) - 0x9a, floorf(view.y / 2.0) - 0x4a)
