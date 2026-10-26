extends Control
class_name TargetMenu

## The right-click target menu (round 832): CNIFTargetMenu, window 0xAE (174),
## built from `res_ui\targetmenu.2dt` -- a 102 x 142 frame
## (interface\frame\ub_new_wnd_), a tile, the name box (8,
## interface\exchange\exc_box.ddj) and five 86 x 20 buttons
## (interface\underbar\ub_new_menu_button.ddj and its _focus / _press /
## _disable): 14 Whisper, 15 Exchange, 17 Add friend, 16 Invite party,
## 18 Trace.
##
## READ (sro_client.exe):
##   - CGInterface::vslot_017 (0x77c260) creates it on WM_RBUTTONUP over a
##     CICUser when the option byte +0x1a ("Activate action short cut",
##     ClientSettings.action_shortcut) is set, then vslot 0x98 (0x46cfc0 ->
##     0xb90cf0) moves it so its top-left is the cursor -- no clamping.
##   - The class has no code of its own but its five handlers (message map
##     0xeb4ec8); every one hides the menu, a refusal included.
##   - The name box gets the selected player's name from FUN_00699540
##     (0x699e74 -> FUN_0060a4b0: child 8's set-text with obj+0x110), the
##     target window's update the 0xB045 select reply runs; no colour of its
##     own (the record's applies).
## INFERRED: the root frame's text (UIIT_CTL_AUTOTRACE_TT, read by no code)
## is not drawn -- the name box sits where a caption would; the 2dt's
## per-record comment shows the same Korean word on the Trace button.

const FILE := "res_ui\\targetmenu.2dt"
const ID_NAME := 8
const ID_WHISPER := 14
const ID_EXCHANGE := 15
const ID_PARTY := 16
const ID_FRIEND := 17
const ID_TRACE := 18
const BUTTONS := [ID_WHISPER, ID_EXCHANGE, ID_FRIEND, ID_PARTY, ID_TRACE]
## A right drag farther than this opens no menu (READ, 0x77c260: over 5 px).
const DRAG_PX := 5.0

## A button was pressed (one of BUTTONS); the menu has already hidden itself.
signal chosen(id: int)

var _twodt: TwoDtBuilder
var _file: TwoDtReader.TwoDtFile
var _root: Control

func _init() -> void:
	name = "TargetMenu"
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false

## Builds it once; false when the file is missing.
func build(builder: UiBuilder) -> bool:
	if builder == null:
		return false
	_file = builder.load_2dt(FILE)
	if _file == null or _file.records.is_empty():
		return false
	_twodt = TwoDtBuilder.new(builder)
	_root = _twodt.build(_file, FILE)
	var caption := _root.get_node_or_null(TwoDtBuilder.TEXT_NODE)
	if caption != null:
		caption.queue_free()
	add_child(_root)
	size = Vector2(_file.root().rect.size)
	custom_minimum_size = size
	for id in BUTTONS:
		var b := TwoDtBuilder.find_path(_root, [id]) as BaseButton
		if b != null:
			var which: int = id
			b.pressed.connect(func() -> void: _choose(which))
	UiBuilder.settle_authored_rects(_root)
	return true

func _choose(id: int) -> void:
	hide()
	chosen.emit(id)

## Shown with its top-left at `at` (view pixels), the name box holding
## `target_name` ("" leaves it empty).
func open_at(at: Vector2, target_name: String) -> void:
	position = at
	set_target_name(target_name)
	show()
	move_to_front()

func set_target_name(target_name: String) -> void:
	var box := TwoDtBuilder.find_path(_root, [ID_NAME]) if _root != null else null
	if box == null:
		return
	var rec: TwoDtReader.Record = null
	for r in _file.records:
		if r.id == ID_NAME:
			rec = r
	_twodt.set_text(box, target_name, rec)

func button(id: int) -> BaseButton:
	return TwoDtBuilder.find_path(_root, [id]) as BaseButton if _root != null else null
