extends HudWindow
class_name GachaSelectWindow

## Magic POP's first window, "Choose item" (round 838, lane 5): READ from
## sro_client.exe (docs/protocol/magic_pop.md) unless labelled.
##
## - CIFGhachaSelectWnd (GDR_GHACHA_SELECT_WND, ID 600): ifghacha.txt's
##   section GhachaSelect frames it, 319 x 257 in msgbox2_window_; its
##   controls are resinfo\ifghachaselectwnd.txt's Create -- the titles 602
##   "Choose item that you won." and 604 "Choose item", the three combo boxes
##   41/42/43 (166 x 20 at x 90, y 77/128/179) under the labels Class, Type
##   and Degree (610..612), and the button 10 "Start the game" (116, 222).
##   The Ghacha window (c:0x79c060 on 0xB046 {1, 0x11}) opens this first
##   (Create c:0x746be0); Start (c:0x74a2b0) sets the filter -- the chosen
##   kind's TypeID word and the degree -- builds the main window
##   (c:0x749560) and destroys this one.
## - The combos list refgachatreeforclientuidata.txt (GachaTables.kinds):
##   the class (700, "Others") and its types (701..706, "Avatar Flag", ...).
##
## Round 848: the combo boxes are the client's CIFComboBox (they were Godot
## OptionButtons in Godot's default look): CIFComboBox::vslot_010 (0x6327f0)
## builds the pieces the Option page's combo has -- the com_blacksquare_
## field on its 0xff000000 fill, com_qst_downarrow_button.ddj 20 wide, the
## value in {5, 0, W-30, H} -- and its open list is ComboList
## (OptionVideoPage.make_combo; party_gui.md, round 714). The value is
## centred: the text static's CTextBoard ctor sets +0x4 and +0x8 to 1
## (0x655c2f / 0x655c3b, READ) and this window's create was not seen to
## change them (INFERRED).
## OURS, labelled: the Type box starts at "All", which filters nothing, and
## the Degree box offers only "All" -- how the client fills the degree box
## and what it compares the degree with were not read (OPEN).

signal start_requested(kind: GachaTables.Kind)

const LAYOUT := "resinfo\\ifghachaselectwnd.txt"
const FRAME_LAYOUT := "resinfo\\ifghacha.txt"
const FRAME_SECTION := "GhachaSelect"
const ALL_TEXT := "All"

var _tables: GachaTables
var _class_box: OptionButton
var _type_box: OptionButton
var _degree_box: OptionButton
## The Type box's entries: null ("All") or a GachaTables.Kind.
var _type_kinds: Array = []

func setup(builder: UiBuilder, tables: GachaTables) -> bool:
	_tables = tables
	var frame_layout := builder.load_layout(FRAME_LAYOUT) if builder != null else null
	var frame_sec = frame_layout.get_section(FRAME_SECTION) if frame_layout != null else null
	var registry := {}
	if frame_sec != null and not frame_sec.controls.is_empty():
		registry = {"def": frame_sec.controls[0], "caption": false}
	if not build(builder, LAYOUT, "", PackedStringArray(), PackedStringArray(), false, registry):
		return false
	_class_box = _combo("GDR_GHACHA_SELECT_COMBOBOX1")
	_type_box = _combo("GDR_GHACHA_SELECT_COMBOBOX2")
	_degree_box = _combo("GDR_GHACHA_SELECT_COMBOBOX3")
	_fill()
	var start := node("GDR_GHACHA_SELECT_START_BTN") as BaseButton
	if start != null:
		start.pressed.connect(func() -> void: start_requested.emit(chosen_kind()))
		start.focus_mode = Control.FOCUS_NONE
	visible = false
	return true

func _combo(holder_name: String) -> OptionButton:
	var holder := node(holder_name) as Control
	if holder == null:
		return null
	# The authored rect, not the node's size, which may not be settled yet.
	var r: Rect2 = holder.get_meta(UiBuilder.AUTHORED_RECT_META, Rect2(holder.position, holder.size))
	holder.size = r.size
	var box := OptionVideoPage.make_combo(_builder, holder)
	if box != null:
		box.name = holder_name + "_Box"
	return box

func _t(key: String, fallback: String) -> String:
	var r := _builder.resolve_text(key) if _builder != null else ""
	return r if r != "" and r != key else fallback

func _fill() -> void:
	var classes := {}
	_type_kinds = [null]
	if _type_box != null:
		_type_box.add_item(ALL_TEXT)
	for k in _tables.kinds if _tables != null else []:
		var kind: GachaTables.Kind = k
		if not classes.has(kind.class_id):
			classes[kind.class_id] = true
			if _class_box != null:
				_class_box.add_item(_t(kind.class_key, kind.class_key))
		_type_kinds.append(kind)
		if _type_box != null:
			_type_box.add_item(_t(kind.type_key, kind.type_key))
	if _degree_box != null:
		_degree_box.add_item(ALL_TEXT)

## The chosen kind, null for "All".
func chosen_kind() -> GachaTables.Kind:
	if _type_box == null:
		return null
	var i := _type_box.selected
	return _type_kinds[i] if i >= 0 and i < _type_kinds.size() else null

## Chooses the Type box's entry by its index (QA and tests).
func choose_type(i: int) -> void:
	if _type_box != null and i >= 0 and i < _type_box.item_count:
		_type_box.select(i)

func type_count() -> int:
	return _type_box.item_count if _type_box != null else 0

func open() -> void:
	centre()
	visible = true

func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if visible and key != null and key.pressed and not key.echo and key.keycode == KEY_ESCAPE:
		hide()
		closed.emit()
		get_viewport().set_input_as_handled()
