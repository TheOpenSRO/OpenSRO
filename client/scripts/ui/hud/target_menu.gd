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
##     CICUser when the option byte +0x1a ("Activate action short cut") is
##     set -- OpenSRO opens it always (round 834) --, then vslot 0x98 (0x46cfc0 ->
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
##
## OURS (round 834, the user's call): the menu is always on (no option), and
## takes entries of OpenSRO's own below retail's five, the way private
## servers add "View items". EXTRA_ENTRIES lists them; each is a copy of the
## Trace button's record one row lower, and the frame and its tile grow by
## the rows added. Retail's own five are untouched.

const FILE := "res_ui\\targetmenu.2dt"
const ID_NAME := 8
const ID_WHISPER := 14
const ID_EXCHANGE := 15
const ID_PARTY := 16
const ID_FRIEND := 17
const ID_TRACE := 18
const BUTTONS := [ID_WHISPER, ID_EXCHANGE, ID_FRIEND, ID_PARTY, ID_TRACE]
const ID_TILE := 3
## OURS: the entries after Trace, in order: [key, label text or text id].
## World3D._on_target_menu_extra runs the key. Add a row here and a branch
## there to add an entry.
const EXTRA_ENTRIES: Array = []
## The first extra entry's control id (OURS; no retail record uses 100+).
const ID_EXTRA_BASE := 100
## The rows' steps in the file: 353, 373, 392, 412, 431 -- 20 and 19 in turn
## (READ, targetmenu.2dt). The extras carry the same rhythm on.
const ROW_STEPS := [20, 19]
## A right drag farther than this opens no menu (READ, 0x77c260: over 5 px).
const DRAG_PX := 5.0

## A button was pressed (one of BUTTONS); the menu has already hidden itself.
signal chosen(id: int)
## One of EXTRA_ENTRIES was pressed (its key); the menu has hidden itself.
signal chosen_extra(key: String)

var _twodt: TwoDtBuilder
var _file: TwoDtReader.TwoDtFile
var _root: Control
var _extras: Array = []

func _init() -> void:
	name = "TargetMenu"
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false

## Builds it once; false when the file is missing.
func build(builder: UiBuilder, extras: Array = EXTRA_ENTRIES) -> bool:
	if builder == null:
		return false
	_file = builder.load_2dt(FILE)
	if _file == null or _file.records.is_empty():
		return false
	_extras = extras.duplicate()
	if not _extras.is_empty():
		_file = extended(_file, _extras.size())
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
	for k in _extras.size():
		var eb := TwoDtBuilder.find_path(_root, [ID_EXTRA_BASE + k]) as BaseButton
		if eb == null:
			continue
		var label := String(_extras[k][1])
		_twodt.set_text(eb, builder.resolve_text(label) if label.begins_with("UIIT_") else label, _record(ID_EXTRA_BASE + k))
		var key := String(_extras[k][0])
		eb.pressed.connect(func() -> void: _choose_extra(key))
	UiBuilder.settle_authored_rects(_root)
	return true

## The file with `count` rows added after Trace: copies of its record, each
## one row step lower, and the root and its tile as much taller. The parsed
## file is left as it is (UiBuilder caches it).
static func extended(file: TwoDtReader.TwoDtFile, count: int) -> TwoDtReader.TwoDtFile:
	var out := TwoDtReader.TwoDtFile.new()
	var trace_index := -1
	for r in file.records:
		out.records.append(r.copy())
		if r.id == ID_TRACE and r.parent_index == 0:
			trace_index = r.index
	if trace_index < 0 or count <= 0:
		return out
	var grow := 0
	var y := file.records[trace_index].rect.position.y
	for k in count:
		var step: int = ROW_STEPS[k % ROW_STEPS.size()]
		y += step
		grow += step
		var row := file.records[trace_index].copy()
		row.index = out.records.size()
		row.id = ID_EXTRA_BASE + k
		row.text_id = ""
		row.rect.position.y = y
		row.children.clear()
		out.records.append(row)
		out.records[0].children.append(row.index)
	out.records[0].rect.size.y += grow
	for r in out.records:
		if r.id == ID_TILE and r.parent_index == 0:
			r.rect.size.y += grow
	return out

func _record(id: int) -> TwoDtReader.Record:
	for r in _file.records:
		if r.id == id:
			return r
	return null

func _choose_extra(key: String) -> void:
	hide()
	chosen_extra.emit(key)

## The extra entry's button by key, or null.
func extra_button(key: String) -> BaseButton:
	for k in _extras.size():
		if String(_extras[k][0]) == key:
			return button(ID_EXTRA_BASE + k)
	return null

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
	_twodt.set_text(box, target_name, _record(ID_NAME))

func button(id: int) -> BaseButton:
	return TwoDtBuilder.find_path(_root, [id]) as BaseButton if _root != null else null
