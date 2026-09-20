extends Control
class_name HudUnderbar

## HudUnderbar renders Silkroad Online's bottom HUD bar using authored layout (resinfo\ifunderbar.txt).
## Manages quickslots, SP/EXP gauges, page flipping, and menu buttons.

const ObjectLoader = preload("res://scripts/assets/object_loader.gd")
const UiBuilder = preload("res://scripts/ui/ui_builder.gd")
const UiLayoutParser = preload("res://scripts/ui/ui_layout_parser.gd")
const UiTextTable = preload("res://scripts/ui/ui_text_table.gd")

signal quickslot_activated(slot_index: int)
signal menu_action(action_name: String)

var _ui_builder: UiBuilder
var _media_pk2: Pk2Reader
var _text_table: UiTextTable

var _gauge_sp: TextureProgressBar
var _lbl_sp: Label
var _lbl_exp: Label
var _lbl_page: Label
var _btn_page_up: TextureButton
var _btn_page_down: TextureButton

## The bar body's authored size, used only if the window registry can't be
## read. Both numbers come from `GDR_UNDERBAR` in resinfo\\ginterface.txt.
const BODY_WIDTH: int = 800
const BODY_HEIGHT: int = 52

var _current_page: int = 1
const MAX_PAGES: int = 4
const SLOTS_PER_PAGE: int = 10

var _slot_nodes: Dictionary = {} # int (0..49) -> Control

func _init(builder: UiBuilder = null, media_pk2: Pk2Reader = null, text_table: UiTextTable = null) -> void:
	_ui_builder = builder
	_media_pk2 = media_pk2
	_text_table = text_table

func _ready() -> void:
	if get_child_count() == 0:
		setup()

func setup(layout_data: Variant = null) -> void:
	# The bar's own size and background come from the client's window
	# registry, not from ifunderbar.txt: that file lists the bar's 76 child
	# controls but never names the bar itself. `GDR_UNDERBAR` in
	# resinfo\\ginterface.txt does -- ub_window_01.ddj, 800x52 -- and
	# ub_window_01.ddj really is 800x52, so it is drawn 1:1.
	#
	# The child coordinates in ifunderbar.txt are relative to this 800x52
	# body, and some are deliberately outside it: ub_deco_left sits at
	# x=-64 and the menu/community/option buttons run up to y=-34. So this
	# control must not clip its children, and its own rect is the bar body
	# rather than the full extent of the artwork.
	var body_size := Vector2(BODY_WIDTH, BODY_HEIGHT)
	var registry_def: UiLayoutParser.ControlDef = null
	if _ui_builder != null:
		registry_def = _ui_builder.window_def("GDR_UNDERBAR")
	if registry_def != null and registry_def.rect.size.x > 0:
		body_size = Vector2(registry_def.rect.size)

	custom_minimum_size = body_size
	size = body_size
	# The root is a transparent container, so it must not swallow mouse
	# input: Godot's default MOUSE_FILTER_STOP made this panel eat every
	# click over its whole rectangle, and World3D drives click-to-move from
	# _unhandled_input, which a consumed event never reaches. IGNORE applies
	# to this node only -- the buttons and slots inside keep their own
	# filters and still receive clicks.
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	# The bar background, behind every child.
	if registry_def != null and registry_def.ddj != "" and _ui_builder != null:
		var bg := TextureRect.new()
		bg.name = "BarBackground"
		bg.texture = _ui_builder.load_texture(registry_def.ddj)
		bg.position = Vector2.ZERO
		bg.size = body_size
		bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		bg.stretch_mode = TextureRect.STRETCH_SCALE
		bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(bg)

	var layout: UiLayoutParser.LayoutDef = null
	if layout_data != null:
		layout = UiLayoutParser.parse(layout_data)
	elif _media_pk2 != null:
		var entry := ObjectLoader.find_file(_media_pk2, "resinfo\\ifunderbar.txt")
		if entry != null:
			var bytes := _media_pk2.read_file(entry)
			layout = UiLayoutParser.parse(bytes)

	var layout_root: Control = null
	if layout != null and _ui_builder != null:
		layout_root = _ui_builder.build_section(layout, "Create")

	if layout_root != null:
		add_child(layout_root)
		_gauge_sp = layout_root.get_node_or_null("GDR_GAUGE_SP") as TextureProgressBar
		_lbl_sp = layout_root.get_node_or_null("GDR_STATIC_SP") as Label
		_lbl_exp = layout_root.get_node_or_null("GDR_STATIC_EXP") as Label
		_lbl_page = layout_root.get_node_or_null("GDR_STATIC_QUICKSLOT") as Label
		_btn_page_up = layout_root.get_node_or_null("GDR_BTN_QUICKSLOTUP") as TextureButton
		_btn_page_down = layout_root.get_node_or_null("GDR_BTN_QUICKSLOTDOWN") as TextureButton

		# Index slot nodes: GDR_TMPQS_0 .. GDR_TMPQS_49
		for i in range(50):
			var slot_name := "GDR_TMPQS_%d" % i
			var node := layout_root.get_node_or_null(slot_name) as Control
			if node != null:
				_slot_nodes[i] = node
				var idx := i
				node.gui_input.connect(func(event: InputEvent) -> void:
					if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
						quickslot_activated.emit(idx)
				)

		# Menu buttons
		var btn_menu := layout_root.get_node_or_null("GDR_BTN_MENU") as TextureButton
		if btn_menu != null:
			btn_menu.pressed.connect(func() -> void: menu_action.emit("menu"))
		var btn_opt := layout_root.get_node_or_null("GDR_BTN_OPTION") as TextureButton
		if btn_opt != null:
			btn_opt.pressed.connect(func() -> void: menu_action.emit("option"))
		var btn_comm := layout_root.get_node_or_null("GDR_BTN_COMMUNITY") as TextureButton
		if btn_comm != null:
			btn_comm.pressed.connect(func() -> void: menu_action.emit("community"))

		if _btn_page_up != null:
			_btn_page_up.pressed.connect(_next_page)
		if _btn_page_down != null:
			_btn_page_down.pressed.connect(_prev_page)

	_update_page_visibility()

## The under-bar's skill-point readout.
##
## What the two controls are, read out of a retail `resinfo\ifunderbar.txt`
## on 2026-09-20: the layout has exactly one `CIFGauge`, `GDR_GAUGE_SP`, at
## `"17,11,144,8"` with its own artwork (`interface\underbar\ub_sp_bar.ddj`),
## and `GDR_STATIC_SP` sits immediately to its right at `"167,9,48,12"` --
## same row. `GDR_STATIC_EXP` is a separate text line *below* both, at
## `"18,31,198,12"`. So the bar belongs to SP, not to experience.
##
## **The number is a plain total.** It read `13/13` because the caller passed
## `maxi(sp, 1)` as a maximum (playtest 2026-09-20, item 10). That also left
## the bar permanently full, which is what was being seen as a green EXP bar
## filling up (item 19) -- the authored art for it is olive.
##
## `progress_percent` is how far the character is toward the *next* skill
## point. The server sends only the unspent total, so callers leave it out
## and the bar draws EMPTY: a full bar would claim a skill point is about to
## land, which is a state we would be inventing.
func set_sp(points: int, progress_percent: float = -1.0) -> void:
	if _gauge_sp != null:
		_gauge_sp.min_value = 0
		_gauge_sp.max_value = 100
		_gauge_sp.value = clampf(progress_percent, 0.0, 100.0) if progress_percent >= 0.0 else 0.0
	if _lbl_sp != null:
		_lbl_sp.text = str(points)

func set_exp(percent: float) -> void:
	if _lbl_exp != null:
		_lbl_exp.text = "EXP: %.2f%%" % percent

func set_slot_item(slot_index: int, icon: Texture2D, count: int = 1) -> void:
	if not _slot_nodes.has(slot_index):
		return
	var node: Control = _slot_nodes[slot_index]
	var icon_rect := node.get_node_or_null("ItemIcon") as TextureRect
	if icon_rect != null:
		icon_rect.texture = icon
	var count_lbl := node.get_node_or_null("CountLabel") as Label
	if count_lbl != null:
		count_lbl.text = str(count) if count > 1 else ""

func clear_slot(slot_index: int) -> void:
	set_slot_item(slot_index, null, 0)

func _next_page() -> void:
	_current_page = (_current_page % MAX_PAGES) + 1
	_update_page_visibility()

func _prev_page() -> void:
	_current_page = MAX_PAGES if _current_page <= 1 else _current_page - 1
	_update_page_visibility()

func _update_page_visibility() -> void:
	if _lbl_page != null:
		_lbl_page.text = str(_current_page)
	# The layout carries all 50 slot controls (GDR_TMPQS_0..49); only the
	# current page's ten are shown -- slots (page-1)*10 .. +9.
	for i in _slot_nodes:
		var node: Control = _slot_nodes[i]
		node.visible = _page_of_slot(int(i)) == _current_page

## Selects a quickslot page directly, 1..MAX_PAGES. Out-of-range is ignored
## rather than clamped, so a stray key cannot silently move the bar.
##
## This is what F1..F4 do: "hotbars are assigned to f keys ... when you press
## f1-f4 you can scroll through them" (playtest 2026-09-20). The up/down
## buttons were the only way to change page before.
func set_page(page: int) -> void:
	if page < 1 or page > MAX_PAGES or page == _current_page:
		return
	_current_page = page
	_update_page_visibility()

## The page currently shown, 1-based.
func current_page() -> int:
	return _current_page

## The 1-based page a slot index belongs to.
func _page_of_slot(slot_index: int) -> int:
	return slot_index / SLOTS_PER_PAGE + 1

## The absolute slot index of the current page's k-th slot (0..9): what the
## number keys 1..9,0 address.
func slot_for_key(k: int) -> int:
	return (_current_page - 1) * SLOTS_PER_PAGE + k

## The number key k (0..9, where the "0" key is the tenth slot) was pressed:
## activate that slot of the current page.
func activate_key(k: int) -> void:
	quickslot_activated.emit(slot_for_key(k))

## The visible quickslot under a screen position, or -1. This is what a skill
## dragged out of the skill window is dropped onto.
func slot_index_at(global_pos: Vector2) -> int:
	for i in _slot_nodes:
		var node: Control = _slot_nodes[i]
		if node.visible and node.get_global_rect().has_point(global_pos):
			return int(i)
	return -1

## Whether a slot currently shows an icon.
func slot_has_item(slot_index: int) -> bool:
	if not _slot_nodes.has(slot_index):
		return false
	var icon_rect := (_slot_nodes[slot_index] as Control).get_node_or_null("ItemIcon") as TextureRect
	return icon_rect != null and icon_rect.texture != null
