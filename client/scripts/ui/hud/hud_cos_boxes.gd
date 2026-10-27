extends PartyMatchBox
class_name HudCosBox

## The COS windows' two CIFMessageBox dialogs (round 795; client_ui.md 1e and
## 3). Both are built from `resinfo\ifmessagebox.txt` in the shell the party
## dialogs share (PartyMatchBox: the `msgbox2_window_` frame and the title
## static at (10, 11), the width less 21 wide, 12 high), with the file's
## "Create" background tile (GDR_MSGBOX_BG at 16,40) sized to (w - 32, h - 56)
## by CIFMessageBox's resize (0x63b420), as PartyMatchConfirm builds it.
## READ from sro_client.exe unless a line says otherwise.
##
## **The naming box** (CIFCOSInfo 0x7a4350(1000): 0x643c20(4) -- mode 4,
## section MsgBoxInsertMsg -- then purpose 6, UI_SILKMALL 0x641f40 case 6 at
## 0x642ace): the title UIIT_STT_INPUT_BOX (set for every purpose, 0x641f94);
## the box 306x151 (`push 0x97; push 0x132`); the static +0x8f4 at (16, 49),
## 275x11, centred, colour 0xffefdaa4, text UIIT_STT_COSPET_MAKENAME; control
## 11 (the edit's frame) at (12, 71) 281x25; control 12 (its backing tile) at
## (16, 75) 273x17; the edit +0x8f8 limited to 12 characters (0x634f80(0xc)),
## emptied, at (24, 78) 245x16, style 2 (0x635150(2), OPEN: what bit 2 does
## in CIFEdit's WM_CHAR was not read) and focused; OK +0x800 at (72, 114) and
## Cancel +0x804 at (160, 114). That +0x8f4 is GDR_MB_INSERT_MSG_TITLE (10),
## +0x8f8 GDR_MB_INSERT_MSG_EDIT (15) and +0x800 / +0x804 the section's OK
## (205) / Cancel (206) is INFERRED from the section's controls (the purpose
## code addresses them by member, not by ID).
##
## **The transport's terminate question** (FUN_007a0980 case 5 for kind 1:
## the request queue 0x77f0a0 with type 0xd, UI_SILKMALL 0x644c90 case 0xd,
## asm 0x64671f..0x6468cf): the MsgBoxINIF box, title UIIT_STT_AGREEMENT_BOX,
## 388x144 (`push 0x90; push 0x184`); +0x840 and +0x844 moved 40 to the right
## and given UIIT_MSG_COS_CLEAN_CONFIRM1 / _CONFIRM2; +0x800 and +0x804 moved
## 40 to the right; +0x808 hidden. +0x840 / +0x844 as MESSAGE1 / MESSAGE2 and
## +0x800 / +0x804 / +0x808 as OK / CANCEL / CERTIFY is INFERRED, as
## PartyInvitePopup takes them.
##
## Without the archive's text table a key shows as itself (OURS: no English
## is invented for these rows).

const LAYOUT := "resinfo\\ifmessagebox.txt"

const NAME_SIZE := Vector2(306, 151)
const NAME_MAX := 12
const NAME_TITLE_RECT := Rect2(16, 49, 275, 11)
const NAME_TITLE_COLOUR := Color8(0xef, 0xda, 0xa4)
const NAME_FRAME_RECT := Rect2(12, 71, 281, 25)
const NAME_BG_RECT := Rect2(16, 75, 273, 17)
const NAME_EDIT_RECT := Rect2(24, 78, 245, 16)
const NAME_OK_AT := Vector2(72, 114)
const NAME_CANCEL_AT := Vector2(160, 114)

## Round 814: the guild's grant-name box -- the same MsgBoxInsertMsg box,
## purpose 3 of UI_SILKMALL 0x641f40 (asm 0x642555..0x642748, READ), which
## CNIFGuildWnd's fourth command button (47 -> 40, the dispatcher 0x5b63e0's
## index 3) opens: 360x170; the static +0x8f4 at (67, 57), 225x14, the
## formatted UIIT_MSG_GUILD_NAME_GRANT_INPUT (0xd9bd30) with the member's
## name; control 11 at (51, 78) 260x28; control 12 at (55, 82) 252x20; the
## edit +0x8f8 limited to 12 (0x634f80(0xc)), emptied, at (58, 82) 243x20,
## style 2; OK +0x800 at (95, 124), Cancel +0x804 at (183, 124). The
## static's colour is not set on this path (OURS: the naming box's).
const GRANT_SIZE := Vector2(360, 170)
const GRANT_TITLE_RECT := Rect2(67, 57, 225, 14)
const GRANT_FRAME_RECT := Rect2(51, 78, 260, 28)
const GRANT_BG_RECT := Rect2(55, 82, 252, 20)
const GRANT_EDIT_RECT := Rect2(58, 82, 243, 20)
const GRANT_OK_AT := Vector2(95, 124)
const GRANT_CANCEL_AT := Vector2(183, 124)

## Round 834: the friend pane's Add friend box -- the same MsgBoxInsertMsg
## box (CNIFFriendWnd 0x5a7160: id 0x51, 0x132 x 0x97, 0x643c20(4)), purpose
## 4 of UI_SILKMALL 0x641f40 (asm 0x64274d..0x64290f, READ): the static
## +0x8f4 at (1, 49), 305x12, centred, colour 0xffefdaa4, text
## UIIT_MSG_FRIEND_IDINPUT; control 11 at (12, 71) 281x25; control 12 at
## (16, 75) 273x17; the edit +0x8f8 emptied, at (19, 73) 266x20, style 2,
## focused, with no length set (the server takes 1..32); OK +0x800 at
## (72, 114), Cancel +0x804 at (160, 114). 0x5a7160 then puts its string
## argument in the edit (0x63c8a0): the selected player's name.
const FRIEND_TITLE_RECT := Rect2(1, 49, 305, 12)
const FRIEND_EDIT_RECT := Rect2(19, 73, 266, 20)

const CLEAN_SIZE := Vector2(388, 144)
const CLEAN_SHIFT := 40.0

## OK on the box: the edit's text for the naming box, "" for the question.
signal accepted(text: String)
signal cancelled

var edit: LineEdit

## Builds the naming box. False without the layout.
func build_name_input(builder: UiBuilder) -> bool:
	name = "COSNameInput"
	if not build_shell(builder, NAME_SIZE, "UIIT_STT_INPUT_BOX", "UIIT_STT_INPUT_BOX", LAYOUT, "MsgBoxInsertMsg"):
		return false
	_add_background(builder, NAME_SIZE)
	var title := node("GDR_MB_INSERT_MSG_TITLE")
	if title != null:
		_place(title, NAME_TITLE_RECT)
		var l := builder.set_static_text(title, text("UIIT_STT_COSPET_MAKENAME", "UIIT_STT_COSPET_MAKENAME"))
		if l != null:
			l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			l.add_theme_color_override("font_color", NAME_TITLE_COLOUR)
	_rebuild(builder, "MsgBoxInsertMsg", "GDR_MB_INSERT_MSG_EDIT_FRAME", NAME_FRAME_RECT)
	_place(node("GDR_MB_INSERT_MSG_EDIT_BG"), NAME_BG_RECT)
	edit = node("GDR_MB_INSERT_MSG_EDIT") as LineEdit
	if edit != null:
		_place(edit, NAME_EDIT_RECT)
		edit.max_length = NAME_MAX
		edit.text = ""
		edit.text_submitted.connect(func(_t: String) -> void: press_ok())
		edit.call_deferred("grab_focus")
	_wire(node("GDR_MB_INSERT_MSG_BTN_OK"), NAME_OK_AT, press_ok)
	_wire(node("GDR_MB_INSERT_MSG_BTN_CANC"), NAME_CANCEL_AT, press_cancel)
	return true

## Builds the Add friend box, its edit holding `prefill`. False without the
## layout.
func build_friend_add_input(builder: UiBuilder, prefill: String) -> bool:
	name = "FriendAddInput"
	if not build_shell(builder, NAME_SIZE, "UIIT_STT_INPUT_BOX", "UIIT_STT_INPUT_BOX", LAYOUT, "MsgBoxInsertMsg"):
		return false
	_add_background(builder, NAME_SIZE)
	var title := node("GDR_MB_INSERT_MSG_TITLE")
	if title != null:
		_place(title, FRIEND_TITLE_RECT)
		var l := builder.set_static_text(title, text("UIIT_MSG_FRIEND_IDINPUT", "UIIT_MSG_FRIEND_IDINPUT"))
		if l != null:
			l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			l.add_theme_color_override("font_color", NAME_TITLE_COLOUR)
	_rebuild(builder, "MsgBoxInsertMsg", "GDR_MB_INSERT_MSG_EDIT_FRAME", NAME_FRAME_RECT)
	_place(node("GDR_MB_INSERT_MSG_EDIT_BG"), NAME_BG_RECT)
	edit = node("GDR_MB_INSERT_MSG_EDIT") as LineEdit
	if edit != null:
		_place(edit, FRIEND_EDIT_RECT)
		edit.max_length = 0
		edit.text = prefill
		edit.text_submitted.connect(func(_t: String) -> void: press_ok())
		edit.call_deferred("grab_focus")
	_wire(node("GDR_MB_INSERT_MSG_BTN_OK"), NAME_OK_AT, press_ok)
	_wire(node("GDR_MB_INSERT_MSG_BTN_CANC"), NAME_CANCEL_AT, press_cancel)
	return true

## Builds the guild's grant-name box for `member` (round 814). False without
## the layout. The title's key is formatted with the name when the archive's
## text has one %s (else the key's text alone).
func build_grant_name_input(builder: UiBuilder, member: String) -> bool:
	name = "GuildGrantNameInput"
	if not build_shell(builder, GRANT_SIZE, "UIIT_STT_INPUT_BOX", "UIIT_STT_INPUT_BOX", LAYOUT, "MsgBoxInsertMsg"):
		return false
	_add_background(builder, GRANT_SIZE)
	var title := node("GDR_MB_INSERT_MSG_TITLE")
	if title != null:
		_place(title, GRANT_TITLE_RECT)
		var fmt := text("UIIT_MSG_GUILD_NAME_GRANT_INPUT", "UIIT_MSG_GUILD_NAME_GRANT_INPUT")
		var shown := fmt % member if fmt.count("%s") == 1 and fmt.count("%") == 1 else fmt
		var l := builder.set_static_text(title, shown)
		if l != null:
			l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			l.add_theme_color_override("font_color", NAME_TITLE_COLOUR)
	_rebuild(builder, "MsgBoxInsertMsg", "GDR_MB_INSERT_MSG_EDIT_FRAME", GRANT_FRAME_RECT)
	_place(node("GDR_MB_INSERT_MSG_EDIT_BG"), GRANT_BG_RECT)
	edit = node("GDR_MB_INSERT_MSG_EDIT") as LineEdit
	if edit != null:
		_place(edit, GRANT_EDIT_RECT)
		edit.max_length = NAME_MAX
		edit.text = ""
		edit.text_submitted.connect(func(_t: String) -> void: press_ok())
		edit.call_deferred("grab_focus")
	_wire(node("GDR_MB_INSERT_MSG_BTN_OK"), GRANT_OK_AT, press_ok)
	_wire(node("GDR_MB_INSERT_MSG_BTN_CANC"), GRANT_CANCEL_AT, press_cancel)
	return true

## Builds the transport's terminate question. False without the layout.
func build_clean_confirm(builder: UiBuilder) -> bool:
	name = "COSCleanConfirm"
	if not build_shell(builder, CLEAN_SIZE, "UIIT_STT_AGREEMENT_BOX", "UIIT_STT_AGREEMENT_BOX", LAYOUT, "MsgBoxINIF"):
		return false
	_add_background(builder, CLEAN_SIZE)
	for spec in [["GDR_MBIN_STATIC_MESSAGE1", "UIIT_MSG_COS_CLEAN_CONFIRM1"],
			["GDR_MBIN_STATIC_MESSAGE2", "UIIT_MSG_COS_CLEAN_CONFIRM2"]]:
		var n := node(spec[0])
		if n != null:
			_shift(n)
			builder.set_static_text(n, text(spec[1], spec[1]))
	var ok := node("GDR_MBIN_BTN_OK")
	var cancel := node("GDR_MBIN_BTN_CANCEL")
	for b in [ok, cancel]:
		if b != null:
			_shift(b)
	if ok is BaseButton:
		(ok as BaseButton).pressed.connect(press_ok)
	if cancel is BaseButton:
		(cancel as BaseButton).pressed.connect(press_cancel)
	var certify := node("GDR_MBIN_BTN_CERTIFY")
	if certify != null:
		certify.visible = false
	return true

## The edit's text as typed.
func typed() -> String:
	return edit.text if edit != null else ""

func press_ok() -> void:
	accepted.emit(typed())
	close()

func press_cancel() -> void:
	cancelled.emit()
	close()

## The file's "Create" (GDR_MSGBOX_BG), behind the section, sized by 0x63b420.
func _add_background(builder: UiBuilder, box: Vector2) -> void:
	var layout: UiLayoutParser.LayoutDef = builder.load_layout(LAYOUT)
	if layout == null or not layout.sections.has("Create"):
		return
	var base := builder.build_section(layout, "Create")
	if base == null:
		return
	add_child(base)
	move_child(base, root.get_index())
	var tile := base.get_node_or_null("GDR_MSGBOX_BG") as Control
	if tile != null:
		var r := Rect2(tile.position, Vector2(box.x - 32, box.y - 56))
		tile.set_meta(UiBuilder.AUTHORED_RECT_META, r)
		tile.custom_minimum_size = Vector2.ZERO
		tile.size = r.size
	UiBuilder.settle_authored_rects(base)

## An 8-slice frame resized in code is laid out again at its new size (its
## pieces are placed when it is built), in the same place among its siblings.
func _rebuild(builder: UiBuilder, section: String, control_name: String, r: Rect2) -> void:
	var old := node(control_name)
	var layout: UiLayoutParser.LayoutDef = builder.load_layout(LAYOUT)
	var sec := layout.get_section(section) if layout != null else null
	if old == null or sec == null or not sec.control_by_name.has(control_name):
		_place(old, r)
		return
	var def: UiLayoutParser.ControlDef = sec.control_by_name[control_name]
	var fresh := builder.build_control(def.with_rect(Rect2i(r)))
	if fresh == null:
		_place(old, r)
		return
	var parent := old.get_parent()
	var at := old.get_index()
	parent.remove_child(old)
	old.queue_free()
	parent.add_child(fresh)
	parent.move_child(fresh, at)

static func _place(n: Control, r: Rect2) -> void:
	if n == null:
		return
	n.set_meta(UiBuilder.AUTHORED_RECT_META, r)
	n.custom_minimum_size = Vector2.ZERO
	n.position = r.position
	n.size = r.size

func _shift(n: Control) -> void:
	var r: Rect2 = n.get_meta(UiBuilder.AUTHORED_RECT_META, Rect2(n.position, n.size))
	r.position.x += CLEAN_SHIFT
	_place(n, r)

static func _wire(n: Control, at: Vector2, handler: Callable) -> void:
	if n == null:
		return
	var r: Rect2 = n.get_meta(UiBuilder.AUTHORED_RECT_META, Rect2(n.position, n.size))
	_place(n, Rect2(at, r.size))
	if n is BaseButton:
		(n as BaseButton).pressed.connect(handler)
