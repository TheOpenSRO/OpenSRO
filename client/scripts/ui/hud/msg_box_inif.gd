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
## - **0x2E, the Dimension hole** (round 869; the case at c:0x6478c2): opened
##   at once by a bag use of a TypeID 3/3/12/7 item (c:0x677006 -> 0x666f80,
##   then `push 0x2e` at c:0x677039). Title UIIT_STT_CONFIRM_BOX (0xd89140,
##   c:0x64798b); +0x840 UIIT_MSG_USE_MAGIC_HOLE_CREATE_GATE (0xd9c500,
##   c:0x6479b9); +0x808 hidden (c:0x6479f1). The case resizes the box to
##   0x1f4 x 0x90 (c:0x6478c7), moves +0x840 to (0x14, 0x37) at 0x1cc x 0xf
##   (c:0x6478d5..0x647907), and moves +0x800 right by 0x50 and +0x804 by 0x64
##   (c:0x647909..0x647989). MEASURED at 1280 x 1024: the box 500 wide from x
##   487, Yes from x 640 and No from x 739 -- the layout's OK (72) and CANCEL
##   (152) plus those shifts.
## - **DUNGEON_TICKET, the Forgotten World timer reset** (round 872, OURS: no
##   box of the original asks it -- its binaries never reference the
##   entrance ticket or its text, forgotten_world.md 9): box 0x2e's shell and
##   title with the action's text key, by default
##   UIIT_STT_DUNGEON_FREE_TICKET_ENTER_FORGOTTEN ("If you use the Dungeon
##   entrance ticket, dungeon cooltime will  disappear. Do you want to use the
##   entrance ticket?", the archive's own text). Too long for box 0x2e's one
##   line, it is split after its first sentence onto two lines (OURS layout:
##   0x2e's text rect raised by 9 and a second line 0x12 below it).
## The buttons keep the layout's own text (UIIT_CTL_YES / UIIT_CTL_NO).

enum Kind { RETURN_POINT = 0x05, ITEM_USE = 0x1f, BUFF_CANCEL = 0x20, MAGIC_HOLE = 0x2e, DUNGEON_TICKET = 0x1001 }

## The Forgotten World reset's default text (round 872).
const DUNGEON_TICKET_TEXT := "UIIT_STT_DUNGEON_FREE_TICKET_ENTER_FORGOTTEN"
## Its two lines' rects (OURS, see the header).
const DUNGEON_TICKET_RECTS := [Rect2(0x14, 0x2e, 0x1cc, 0xf), Rect2(0x14, 0x40, 0x1cc, 0xf)]

## Box 0x2e's own size and moves (READ, see the header).
const MAGIC_HOLE_SIZE := Vector2(0x1f4, 0x90)
const MAGIC_HOLE_TEXT_RECT := Rect2(0x14, 0x37, 0x1cc, 0xf)
const MAGIC_HOLE_OK_SHIFT := 0x50
const MAGIC_HOLE_CANCEL_SHIFT := 0x64

const SIZE := Vector2(0x134, 0x94)
const MESSAGES := ["GDR_MBIN_STATIC_MESSAGE1", "GDR_MBIN_STATIC_MESSAGE2", "GDR_MBIN_STATIC_MESSAGE3",
	"GDR_MBIN_STATIC_MESSAGE4", "GDR_MBIN_STATIC_MESSAGE5"]

var kind := 0

## Builds box `box_kind` (Kind) named `box_name`. `zone_name` fills the
## return point's first line; `text_key` is DUNGEON_TICKET's text (its
## default when ""). False without the layout or for another kind.
func build_kind(builder: UiBuilder, box_kind: int, box_name: String, zone_name: String = "", text_key: String = "") -> bool:
	var title := ""
	var lines: Array = []
	match box_kind:
		Kind.RETURN_POINT:
			title = "UIIT_STT_AGREEMENT_BOX"
		Kind.ITEM_USE, Kind.BUFF_CANCEL, Kind.MAGIC_HOLE, Kind.DUNGEON_TICKET:
			title = "UIIT_STT_CONFIRM_BOX"
		_:
			return false
	kind = box_kind
	name = box_name
	var wide := box_kind == Kind.MAGIC_HOLE or box_kind == Kind.DUNGEON_TICKET
	var box_size := MAGIC_HOLE_SIZE if wide else SIZE
	if not build_shell(builder, box_size, title, title, LAYOUT, "MsgBoxINIF"):
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
		Kind.MAGIC_HOLE:
			lines = [text("UIIT_MSG_USE_MAGIC_HOLE_CREATE_GATE", "UIIT_MSG_USE_MAGIC_HOLE_CREATE_GATE")]
		Kind.DUNGEON_TICKET:
			var key := text_key if text_key != "" else DUNGEON_TICKET_TEXT
			lines = split_sentence(text(key, key))
	_add_background(builder, box_size)
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
	if box_kind == Kind.DUNGEON_TICKET:
		for i in DUNGEON_TICKET_RECTS.size():
			_place(node(MESSAGES[i]), DUNGEON_TICKET_RECTS[i])
	if wide:
		if box_kind == Kind.MAGIC_HOLE:
			_place(node(MESSAGES[0]), MAGIC_HOLE_TEXT_RECT)
		for pair in [["GDR_MBIN_BTN_OK", MAGIC_HOLE_OK_SHIFT], ["GDR_MBIN_BTN_CANCEL", MAGIC_HOLE_CANCEL_SHIFT]]:
			var b := node(String(pair[0]))
			if b != null:
				var r: Rect2 = b.get_meta(UiBuilder.AUTHORED_RECT_META, Rect2(b.position, b.size))
				r.position.x += float(pair[1])
				_place(b, r)
	return true

## DUNGEON_TICKET's two lines (OURS): `s` split after its first sentence
## (". "), or the whole text on one line when it has no second sentence.
static func split_sentence(s: String) -> Array:
	var at := s.find(". ")
	if at < 0:
		return [s]
	return [s.substr(0, at + 1), s.substr(at + 2).strip_edges()]

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

## The OK (true) or CANCEL button, for OPENSRO_QA_INPUT's `boxyes:` / `boxno:`
## (round 869: `boxyes:MagicHoleConfirm`).
func _find_button(ok: bool) -> BaseButton:
	return button("GDR_MBIN_BTN_OK" if ok else "GDR_MBIN_BTN_CANCEL")
