extends HudCosBox
class_name MallEnterBox

## Round 837: F10's "Enter Item Mall" warning (docs/protocol/item_mall.md
## §1e, item_mall_verify.md 1e). c: client addresses, READ unless a line says
## otherwise.
##
## F10 (key dispatcher 0x780610 -> 0x7807aa), with the mall closed and no box
## of kind 0x1e up (0x6ec400(0x1e)), opens CMessageBoxManager box kind 0x1e
## (0x6ec5d0, call at 0x7807ef): section MsgBoxINIF of resinfo\ifmessagebox.
## txt, created at 0x134 x 0x94 and placed at screen w / 2 - 0x9a,
## h / 2 - 0x4a, then set up by UI_SILKMALL 0x644c90 (jump index 29 ->
## 0x647b74):
## - title UIIT_STT_SILKMALL_ENTER, the box resized to 0x190 x 0xd2 (400 x
##   210; the corner stays);
## - OK +0x800 moved to (0x7b, 0xa8) = (123, 168), CANCEL +0x804 to (0xcb,
##   0xa8) = (203, 168); their layout captions stay;
## - +0x840 (MESSAGE1) moved to (0x80, 0x2b) = (128, 43), sized 0x94 x 0x34
##   (148 x 52), its picture interface\mall\mall_pic.ddj;
## - +0x844 / +0x848 / +0x84c (MESSAGE2..4) at (0x14, 0x6c / 0x7d / 0x8e) =
##   (20, 108 / 125 / 142), each 0x167 x 0xf (359 x 15), with
##   UIIT_STT_SILKMALL_WARNING_1 / _2 / _3 (0x6466f2 sets the third);
## - +0x808 (CERTIFY) hidden (0x64871b). No timer is armed on this path.
## OK answers 1, which reaches 0x797d90 case 0x1e (0x7986eb): the mall opens
## (0x79b580(1)) or 0x7121 asks first (item_mall_verify: only when
## shopitemstockquantity.txt has rows for the mall's group). Cancel answers 0
## and nothing happens. Enter answers 1 and Esc 0, as the manager's other
## MsgBoxINIF boxes (docs/protocol/friends.md, box 0x23).
## +0x840..+0x84c as MESSAGE1..4 and +0x800 / +0x804 / +0x808 as OK / CANCEL /
## CERTIFY is INFERRED, as FriendMsgBox and GuildMsgBox take them.

const KIND := 0x1e
const CREATE_SIZE := Vector2(0x134, 0x94)
const BOX_SIZE := Vector2(0x190, 0xd2)
const OK_AT := Vector2(0x7b, 0xa8)
const CANCEL_AT := Vector2(0xcb, 0xa8)
const PICTURE := "interface\\mall\\mall_pic.ddj"
const PICTURE_RECT := Rect2(0x80, 0x2b, 0x94, 0x34)
const LINE_X := 0x14
const LINE_YS := [0x6c, 0x7d, 0x8e]
const LINE_SIZE := Vector2(0x167, 0xf)
const LINES := ["UIIT_STT_SILKMALL_WARNING_1", "UIIT_STT_SILKMALL_WARNING_2", "UIIT_STT_SILKMALL_WARNING_3"]
const MESSAGES := ["GDR_MBIN_STATIC_MESSAGE2", "GDR_MBIN_STATIC_MESSAGE3", "GDR_MBIN_STATIC_MESSAGE4"]

var _on_ok: Callable

## Opens the box on `parent` (the HUD) unless one is up there already; OK
## calls `on_ok`. Null when refused or without the layout.
static func open(builder: UiBuilder, parent: Node, on_ok: Callable) -> MallEnterBox:
	if builder == null or parent == null or is_open(parent):
		return null
	var box := MallEnterBox.new()
	if not box.build_enter(builder):
		box.free()
		return null
	box._on_ok = on_ok
	box.accepted.connect(func(_t: String) -> void:
		if box._on_ok.is_valid():
			box._on_ok.call())
	parent.add_child(box)
	box.place_on(box.get_viewport_rect().size)
	return box

## 0x6ec400(0x1e): a box of this kind is up under `parent`.
static func is_open(parent: Node) -> bool:
	var old := parent.get_node_or_null("MallEnterBox") if parent != null else null
	return old != null and is_instance_valid(old) and not old.is_queued_for_deletion()

func build_enter(builder: UiBuilder) -> bool:
	name = "MallEnterBox"
	if not build_shell(builder, BOX_SIZE, "UIIT_STT_SILKMALL_ENTER", "UIIT_STT_SILKMALL_ENTER", LAYOUT, "MsgBoxINIF"):
		return false
	_add_background(builder, BOX_SIZE)
	var pic := node("GDR_MBIN_STATIC_MESSAGE1")
	if pic != null:
		_place(pic, PICTURE_RECT)
		builder.set_static_text(pic, "")
		var tex := builder.load_texture(PICTURE)
		if tex != null:
			var rect := TextureRect.new()
			rect.name = "Picture"
			rect.texture = tex
			rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			rect.stretch_mode = TextureRect.STRETCH_SCALE
			rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
			rect.set_anchors_preset(Control.PRESET_FULL_RECT)
			pic.add_child(rect)
	for i in MESSAGES.size():
		var n := node(MESSAGES[i])
		if n == null:
			continue
		_place(n, Rect2(Vector2(LINE_X, float(LINE_YS[i])), LINE_SIZE))
		builder.set_static_text(n, text(LINES[i], LINES[i]))
	_wire(node("GDR_MBIN_BTN_OK"), OK_AT, press_ok)
	_wire(node("GDR_MBIN_BTN_CANCEL"), CANCEL_AT, press_cancel)
	var certify := node("GDR_MBIN_BTN_CERTIFY")
	if certify != null:
		certify.visible = false
	return true

## CMessageBoxManager's placement (0x6ec5d0): the creation size's corner.
func place_on(view: Vector2) -> void:
	position = Vector2(floorf(view.x / 2.0) - 0x9a, floorf(view.y / 2.0) - 0x4a)

func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo or not is_visible_in_tree() or is_queued_for_deletion():
		return
	if key.keycode == KEY_ENTER or key.keycode == KEY_KP_ENTER:
		press_ok()
		get_viewport().set_input_as_handled()
	elif key.keycode == KEY_ESCAPE:
		press_cancel()
		get_viewport().set_input_as_handled()

## Out of the name lookups at once (is_open), then gone at the frame's end.
func close() -> void:
	if is_queued_for_deletion():
		return
	name = "MallEnterBox_closing"
	super()
