extends Control
class_name HudExtQuickSlot

## One Additional Quick Slot bar (round 788): retail's `CIFExtQuickSlot`
## (`GDR_EXT_QUICK_SLOT`, window 133), built from the player's own
## `resinfo\ifextquickslot.txt` the way its class does it -- or, with
## `bar_index` > 0, one of OpenSRO's own extra bars (OURS), the same window
## with pages of new quick slots and a page footer. Every address is
## sro_client.exe's (md5 2a5794b72c90908d945be8b3f3f2edd4);
## docs/protocol/ext_quick_slot.md has the record, ExtQuickSlotLayout the
## arithmetic. Labels: READ, MEASURED, INFERRED, OURS.
##
## **What it is (READ).** CIFExtQuickSlot : CIFWnd (vtable 0xda0464). Create
## (0x65f720) loads LAYOUT, keeps the bottom bar (window 0xaf), loads the
## options file (0x65f580). The in-game set-up 0x786f30 creates it
## unconditionally (0x79c600(1) at 0x7871d2) and the teardown destroys it
## (0x787946): no menu entry and no key shows or hides it -- it is always
## there and can only be collapsed. Its ten CIFExtQuickSlotSlot are PROXIES
## of the bottom bar's quick slots 41..50 (0x65fc70): drawn at the proxy's
## place with the target's own draw (0x65fb00 -- icon, count, re-use display),
## every event forwarded to the target (vslot 19 0x65fb90), a drop forwarded
## to the target's drop (vslot 28 0x65fb50, no lock test), the right button's
## release on the slot using it (0x65fc20 -> 0x682040). Here the bottom bar
## LENDS the slot's node (HudUnderbar.lend_slot) and it is drawn here, so all
## of that is the slot's own behaviour.
##
## **The hover help (READ, correcting the research note's "no tooltips").**
## vslot 19 forwards the hover message 0x4009 to the target, whose
## CIFSlotWithHelp::vslot_019 (0x667820) shows its help (vslot 48), and then
## re-places the help window (interface +0x730, 0x798db0) beside the PROXY's
## own rect (0x776c00(rect, 0): right of it + 8, or left of it when that
## overflows the screen, 8 below its top, kept above the bottom). So a skill
## on the bar shows its tooltip beside the bar's slot: the lent node keeps
## its help (HudPanels.set_bubble_tip places it beside the node).
##
## **State (READ, ctor 0x65e870):** +0x36c open, +0x36d vertical, +0x36e
## two lines, +0x36f transparent, +0x370 lock slots, +0x371 lock toolbar,
## +0x372 the current type (0xff at first, so the first apply builds).

const ALPHA_META := "ext_alpha"

## Something the options file keeps changed (an option, collapse, the
## orientation): the owner saves it.
signal changed
## A drag by the header ended: the owner keeps the position (OURS).
signal moved
## OURS: an extra bar's option window asked for another bar count or page
## count (its Apply or Confirm).
signal counts_requested(bars: int, pages: int)

## 0 = retail's bar (quick slots 41..50); 1.. = OURS extra bar n.
var bar_index := 0
## Pages of ten (OURS bars; retail's has one).
var page_count := 1
## The page shown, 1..page_count.
var page := 1

var open := true
var vertical := false
var two_lines := false
var transparent := false
var lock_slots := false
var lock_toolbar := false
## +0x372: ExtQuickSlotLayout.type_index of the built section, -1 before.
var current_type := -1
## How many times the section was rebuilt (tests: apply() rebuilds only on a
## type change).
var relayouts := 0
## The alpha the last apply() used (tests).
var last_alpha := -1

## Where the option window is added (the owner, HudExtQuickSlots); the
## parent when unset.
var window_host: Control
## The option window while it is open.
var option_window: HudWindow
## OURS: the counts an extra bar's option window shows and edits.
var counts := [ExtQuickSlotSettings.DEFAULT_BARS, ExtQuickSlotSettings.DEFAULT_PAGES]

var _builder: UiBuilder
var _underbar: HudUnderbar
var _layout: UiLayoutParser.LayoutDef
var _section: Control
var _nodes := {} # id -> Control, the built section's controls
var _slot_rects: Array = []
## Per page (0-based), the ten lent slot nodes.
var _pages: Array = []
var _footer: Control
var _footer_label: Label
var _dragging := false
var _grab := Vector2.ZERO
## The option window's check boxes by id, and the OURS count spins.
var _checks := {}
var _count_values := [0, 0]
var _count_labels: Array = []

func _init(builder: UiBuilder = null, underbar: HudUnderbar = null, index: int = 0, pages: int = 1) -> void:
	_builder = builder
	_underbar = underbar
	bar_index = index
	page_count = clampi(pages, 1, HudUnderbar.EXT_PAGES_MAX) if index > 0 else 1
	# The window's own rect is the header (READ: 0x65f12e sizes it from the
	# WND control); it takes no click itself, its controls do.
	mouse_filter = Control.MOUSE_FILTER_IGNORE

## Builds the bar with `values` (ExtQuickSlotSettings' six, retail's order)
## and applies them. False, having lent nothing, when the layout or the
## bottom bar's slots are not there.
func setup(values: Array = ExtQuickSlotSettings.DEFAULT_OPTIONS) -> bool:
	if _builder == null or _underbar == null:
		return false
	_layout = _builder.load_layout(ExtQuickSlotLayout.LAYOUT)
	if _layout == null:
		return false
	for t in 4:
		if not _layout.sections.has(ExtQuickSlotLayout.section_name(t)):
			push_warning("HudExtQuickSlot: %s has no %s" % [ExtQuickSlotLayout.LAYOUT, ExtQuickSlotLayout.section_name(t)])
			return false
	_slot_rects.resize(ExtQuickSlotLayout.SLOTS)
	for p in page_count:
		var nodes: Array = []
		for k in ExtQuickSlotLayout.SLOTS:
			var node := _underbar.lend_slot(quick_slot(p + 1, k))
			if node == null:
				release_slots()
				return false
			if node.get_parent() != null:
				node.get_parent().remove_child(node)
			add_child(node)
			nodes.append(node)
		_pages.append(nodes)
	set_options(values)
	apply()
	return true

## The quick slot page p's (1-based) k-th slot is: retail's bar 41 + k (READ,
## 0x65ef70's binding loop), an OURS bar ExtQuickSlotLayout.slot_for.
func quick_slot(p: int, k: int) -> int:
	if bar_index == 0:
		return HudUnderbar.EXT_FIRST_SLOT + k
	return ExtQuickSlotLayout.slot_for(bar_index, p, k)

## Every quick slot this bar shows, all pages.
func lent_indices() -> Array:
	var out: Array = []
	for p in _pages.size():
		for k in ExtQuickSlotLayout.SLOTS:
			out.append(quick_slot(p + 1, k))
	return out

## Gives every lent slot back to the bottom bar (the bar is going away).
func release_slots() -> void:
	for p in _pages.size():
		for k in (_pages[p] as Array).size():
			_underbar.release_slot(quick_slot(p + 1, k))
	_pages.clear()

## The six values in retail's order (ExtQuickSlotSettings).
func options() -> Array:
	return [int(open), int(vertical), int(two_lines), int(transparent), int(lock_slots), int(lock_toolbar)]

func set_options(values: Array) -> void:
	var v := values if values.size() == 6 else ExtQuickSlotSettings.DEFAULT_OPTIONS
	open = bool(v[ExtQuickSlotSettings.OPEN])
	vertical = bool(v[ExtQuickSlotSettings.VERTICAL])
	two_lines = bool(v[ExtQuickSlotSettings.TWO_LINES])
	transparent = bool(v[ExtQuickSlotSettings.TRANSPARENT])
	lock_slots = bool(v[ExtQuickSlotSettings.LOCK_SLOTS])
	lock_toolbar = bool(v[ExtQuickSlotSettings.LOCK_TOOLBAR])

## A control of the built section by its layout id, or null.
func control(id: int) -> Control:
	return _nodes.get(id)

## A lent slot node: page p (1-based), key k.
func slot_node(p: int, k: int) -> Control:
	if p < 1 or p > _pages.size():
		return null
	return (_pages[p - 1] as Array)[k]

# --- apply (0x65f390) ---------------------------------------------------------

## READ, 0x65f390, in this order:
## 1. the layout rebuilt, only if the type changed (0x65ef70);
## 2. alpha 0x6e if Transparent else 0xff, to the WND strip and the four
##    buttons, and -- only while open -- to END, the ten slots and the boards
##    (0x655460 stores it per control, 0x6526b1 multiplies it by the parent's).
##    So Transparent changed while collapsed leaves the slots and boards at
##    their old alpha until the next apply while open: reproduced here.
## 3. each slot's pick-up flag = !Lock Slots (0xb9daf0, +0x64);
## 4. the WND strip's input = !Lock Toolbar (0xb8f540, +0x62): no drag.
## A slot's alpha is kept (ALPHA_META) but not drawn: the proxy draws the
## bottom bar's slot with that slot's own alpha (0x65fb00 calls the target's
## draw), so the icons do not fade -- INFERRED from the delegation, and the
## user's screenshots show full-colour icons on a transparent bar; OPEN.
func apply() -> void:
	var t := ExtQuickSlotLayout.type_index(vertical, two_lines)
	if t != current_type:
		_relayout(t)
	var a := ExtQuickSlotLayout.alpha_for(transparent)
	for id in [ExtQuickSlotLayout.ID_WND, ExtQuickSlotLayout.ID_OPT, ExtQuickSlotLayout.ID_HORI,
			ExtQuickSlotLayout.ID_VERT, ExtQuickSlotLayout.ID_ONOFF]:
		_set_alpha(_nodes.get(id), a)
	if open:
		_set_alpha(_nodes.get(ExtQuickSlotLayout.ID_END), a)
		for nodes in _pages:
			for node in nodes:
				(node as Control).set_meta(ALPHA_META, a)
		for b in ExtQuickSlotLayout.board_count(current_type):
			_set_alpha(_nodes.get(ExtQuickSlotLayout.ID_BOARD + b), a)
		# OURS: the footer follows the boards.
		_set_alpha(_footer, a)
	for idx in lent_indices():
		_underbar.set_slot_pick_locked(idx, lock_slots)
	var wnd := _nodes.get(ExtQuickSlotLayout.ID_WND) as Control
	if wnd != null:
		wnd.set_meta("input_enabled", not lock_toolbar)
	last_alpha = a

static func _set_alpha(node: Control, a: int) -> void:
	if node == null:
		return
	node.set_meta(ALPHA_META, a)
	node.modulate.a = a / 255.0

## The alpha a control was last given, or -1.
static func alpha_of(node: Control) -> int:
	return int(node.get_meta(ALPHA_META, -1)) if node != null else -1

## 0x65ef70: the old Type section destroyed, the new one built, the window
## sized from its WND control, the proxies bound at the slots' rects, and the
## open state applied again (0x65ecd0).
func _relayout(t: int) -> void:
	if _section != null:
		remove_child(_section)
		_section.queue_free()
	_nodes.clear()
	_section = Control.new()
	_section.name = ExtQuickSlotLayout.section_name(t)
	_section.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_section)
	move_child(_section, 0)
	var sec: UiLayoutParser.SectionDef = _layout.sections[ExtQuickSlotLayout.section_name(t)]
	# Front to back in the file: built reversed (UI_TODO rule 9) -- WND,
	# the buttons, END, the boards; the slots (first in the file) are the
	# lent nodes, drawn over all of it.
	for i in range(sec.controls.size() - 1, -1, -1):
		var def: UiLayoutParser.ControlDef = sec.controls[i]
		var k := def.id - ExtQuickSlotLayout.ID_SLOT
		if k >= 0 and k < ExtQuickSlotLayout.SLOTS:
			_slot_rects[k] = Rect2(Vector2(def.rect.position), Vector2(def.rect.size))
			continue
		var node: Control = _build_wnd(def) if def.id == ExtQuickSlotLayout.ID_WND else _builder.build_control(def)
		if node == null:
			continue
		_section.add_child(node)
		_nodes[def.id] = node
		if def.id >= ExtQuickSlotLayout.ID_BOARD and def.id < ExtQuickSlotLayout.ID_BOARD + 10:
			# OURS: a click between the slots does not walk the player.
			node.mouse_filter = Control.MOUSE_FILTER_STOP
	var wnd := _nodes.get(ExtQuickSlotLayout.ID_WND) as Control
	var body := wnd.size if wnd != null else Vector2.ZERO
	custom_minimum_size = body
	size = body
	for nodes in _pages:
		for k in (nodes as Array).size():
			var node := (nodes as Array)[k] as Control
			var r: Rect2 = _slot_rects[k] if _slot_rects[k] != null else Rect2(0, 0, 32, 32)
			node.position = r.position
			node.size = r.size
	_wire_buttons()
	current_type = t
	relayouts += 1
	_build_footer(t)
	UiBuilder.settle_authored_rects(_section)
	_set_open(open)

## The WND strip (CIFDragableArea, its art the header): dragged by the left
## button, unless Lock Toolbar turned its input off.
func _build_wnd(def: UiLayoutParser.ControlDef) -> Control:
	var wnd := TextureRect.new()
	wnd.name = def.name
	wnd.texture = _builder.load_texture(def.ddj)
	wnd.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	wnd.stretch_mode = TextureRect.STRETCH_SCALE
	wnd.position = Vector2(def.rect.position)
	var s := Vector2(def.rect.size)
	if s == Vector2.ZERO and wnd.texture != null:
		s = wnd.texture.get_size()
	wnd.size = s
	wnd.custom_minimum_size = s
	wnd.set_meta(UiBuilder.AUTHORED_RECT_META, Rect2(wnd.position, s))
	wnd.mouse_filter = Control.MOUSE_FILTER_STOP
	wnd.gui_input.connect(_on_wnd_input)
	return wnd

## READ: the position follows the mouse less the grab offset (0x6a1a30 ->
## 0xb90cf0), with NO screen clamp while dragging. The option window, a
## child of the bar in retail, moves with it (INFERRED: 0xb90cf0 moves a
## window's children with it).
func _on_wnd_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.button_index == MOUSE_BUTTON_LEFT:
		if mb.pressed:
			if lock_toolbar:
				return
			_dragging = true
			_grab = mb.global_position - global_position
		elif _dragging:
			_dragging = false
			moved.emit()
		accept_event()
		return
	var mm := event as InputEventMouseMotion
	if mm != null and _dragging:
		drag_to(mm.global_position - _grab)
		accept_event()

## Moves the bar's top-left to `at` (canvas coordinates), the option window
## along with it.
func drag_to(at: Vector2) -> void:
	var delta := at - global_position
	global_position = at
	if option_window != null and is_instance_valid(option_window):
		option_window.position += delta

func _wire_buttons() -> void:
	var map := {
		ExtQuickSlotLayout.ID_OPT: toggle_option,
		ExtQuickSlotLayout.ID_HORI: set_vertical.bind(false),
		ExtQuickSlotLayout.ID_VERT: set_vertical.bind(true),
		ExtQuickSlotLayout.ID_ONOFF: toggle_open,
	}
	for id in map:
		var b := _nodes.get(id) as BaseButton
		if b != null:
			b.focus_mode = Control.FOCUS_NONE
			# Deferred: HORI and VERT rebuild the section, the button itself
			# included, and a button must not be freed in its own signal.
			b.pressed.connect(map[id], CONNECT_DEFERRED)

# --- collapse (0x65eed0 -> 0x65ecd0) ----------------------------------------

## ONOFF: open toggles; nothing else is re-applied (0x65eed0 calls only
## 0x65ecd0) -- which is what leaves the quirk above in place.
func toggle_open() -> void:
	_set_open(not open)
	changed.emit()

## READ, 0x65ecd0: the state stored, the collapse button's art swapped (open:
## the close art, collapsed: the open art; every button has _focus and
## _press), the slots and boards shown or hidden (ten each for the one-line
## types, ten slots and five boards for the two-line ones), then END. Only
## the header stays when collapsed. OURS: an extra bar shows only its page's
## slots, and its footer goes with the boards.
func _set_open(o: bool) -> void:
	open = o
	var onoff := _nodes.get(ExtQuickSlotLayout.ID_ONOFF) as TextureButton
	if onoff != null and current_type >= 0:
		var art := ExtQuickSlotLayout.onoff_art(current_type, o)
		onoff.texture_normal = _builder.load_texture(art)
		onoff.texture_hover = _builder.load_texture(art.replace(".ddj", "_focus.ddj"))
		onoff.texture_focused = onoff.texture_hover
		onoff.texture_pressed = _builder.load_texture(art.replace(".ddj", "_press.ddj"))
	_show_page_slots()
	for b in ExtQuickSlotLayout.board_count(current_type):
		var board := _nodes.get(ExtQuickSlotLayout.ID_BOARD + b) as Control
		if board != null:
			board.visible = o
	if _footer != null:
		_footer.visible = o
	var end := _nodes.get(ExtQuickSlotLayout.ID_END) as Control
	if end != null:
		end.visible = o

func _show_page_slots() -> void:
	for p in _pages.size():
		for node in _pages[p]:
			(node as Control).visible = open and p + 1 == page

## HORI / VERT (READ, 0x65f700 / 0x65f710): vertical 0 or 1, then apply().
func set_vertical(v: bool) -> void:
	vertical = v
	apply()
	changed.emit()

# --- the option window (CIFExtQuickSlotOption) ------------------------------

## OPT (READ, 0x65eea0): the option window, child 5, is built if it is not
## there and destroyed if it is -- the second press closes it WITHOUT
## applying.
func toggle_option() -> void:
	if option_window != null and is_instance_valid(option_window):
		close_option()
	else:
		open_option()

## OURS: the extra bars' option window has one more row (the bar and page
## counts) and is this much taller; retail's bar's window is as authored.
const COUNT_ROW_HEIGHT := 30
const COUNT_ROW_Y := 175

## READ, 0x65eb10(1): section Option of LAYOUT built, its child 5 the window
## (CIFExtQuickSlotOption : CIFMainFrame, 290x223 on msgbox2_window_,
## caption UIIT_STT_ADD_QUICKSLOT_ADD), whose Create (0x65f9d0) loads section
## Create of OPTION_LAYOUT; the check boxes set from the state (0x65f800);
## placed by ExtQuickSlotLayout.option_position.
func open_option() -> HudWindow:
	if _layout == null or not _layout.sections.has(ExtQuickSlotLayout.OPTION_SECTION):
		return null
	var sec: UiLayoutParser.SectionDef = _layout.sections[ExtQuickSlotLayout.OPTION_SECTION]
	var def := ExtQuickSlotLayout.def_by_id(sec, ExtQuickSlotLayout.ID_OPTION_WINDOW)
	if def == null:
		return null
	if bar_index > 0:
		def = def.with_rect(Rect2i(def.rect.position, def.rect.size + Vector2i(0, COUNT_ROW_HEIGHT)))
	var w := HudWindow.new()
	w.name = "ExtQuickSlotOption%d" % bar_index
	var host: Node = window_host if window_host != null else get_parent()
	if host == null:
		return null
	host.add_child(w)
	if not w.build(_builder, ExtQuickSlotLayout.OPTION_LAYOUT, "", PackedStringArray(), PackedStringArray(), false,
			{"def": def}):
		w.queue_free()
		return null
	option_window = w
	_checks.clear()
	var opt_layout := _builder.load_layout(ExtQuickSlotLayout.OPTION_LAYOUT)
	var create: UiLayoutParser.SectionDef = opt_layout.get_section("Create") if opt_layout != null else null
	var states := {
		ExtQuickSlotLayout.ID_CHECK_TRANS: transparent,
		ExtQuickSlotLayout.ID_CHECK_LOCK: lock_slots,
		ExtQuickSlotLayout.ID_CHECK_FIX: lock_toolbar,
		ExtQuickSlotLayout.ID_CHECK_DOUBLELINE: two_lines,
	}
	for id in states:
		var cdef := ExtQuickSlotLayout.def_by_id(create, id)
		var holder := w.node(cdef.name) as Control if cdef != null else null
		if holder != null:
			_checks[id] = _builder.make_checkbox(holder, cdef.ddj, bool(states[id]))
	var ok := _option_control(create, ExtQuickSlotLayout.ID_OPTION_OK) as BaseButton
	if ok != null:
		ok.pressed.connect(confirm_option)
	var apply_btn := _option_control(create, ExtQuickSlotLayout.ID_OPTION_APPLY) as BaseButton
	if apply_btn != null:
		apply_btn.pressed.connect(apply_option)
	# The close X closes without applying (INFERRED: CIFMainFrame's close
	# reaches vslot 43, which 0x65f7e0 is).
	w.closed.connect(close_option)
	if bar_index > 0:
		_add_count_row(w, create)
	var screen := get_viewport_rect().size
	var at := ExtQuickSlotLayout.option_position(Rect2(global_position, size), vertical, w.size, screen)
	w.position = at - (host as Control).global_position if host is Control else at
	return w

func _option_control(create: UiLayoutParser.SectionDef, id: int) -> Control:
	var def := ExtQuickSlotLayout.def_by_id(create, id)
	if option_window == null or def == null:
		return null
	return option_window.node(def.name) as Control

## Closes the option window, applying nothing (the X, and OPT pressed again).
func close_option() -> void:
	if option_window != null and is_instance_valid(option_window):
		option_window.queue_free()
		if option_window.get_parent() != null:
			option_window.get_parent().remove_child(option_window)
	option_window = null
	_checks.clear()
	_count_labels.clear()

## Apply (READ, 0x65f870): the check boxes into the state -- 25 Transparent,
## 26 Lock Slots, 27 Lock Toolbar, 28 Two Lines -- and apply(); the window
## stays open. Neither Apply nor Confirm writes the options file in retail
## (it is written at teardown); here `changed` saves at once (OURS).
func apply_option() -> void:
	if _checks.is_empty():
		return
	transparent = _checked(ExtQuickSlotLayout.ID_CHECK_TRANS)
	lock_slots = _checked(ExtQuickSlotLayout.ID_CHECK_LOCK)
	lock_toolbar = _checked(ExtQuickSlotLayout.ID_CHECK_FIX)
	two_lines = _checked(ExtQuickSlotLayout.ID_CHECK_DOUBLELINE)
	apply()
	changed.emit()
	if bar_index > 0 and not _count_labels.is_empty() \
			and (_count_values[0] != int(counts[0]) or _count_values[1] != int(counts[1])):
		counts_requested.emit(_count_values[0], _count_values[1])

## Confirm (READ, 0x65f9b0): Apply, then the window closes (vslot 43,
## 0x65f7e0).
func confirm_option() -> void:
	apply_option()
	close_option()

func _checked(id: int) -> bool:
	var b := _checks.get(id) as BaseButton
	return b != null and b.button_pressed

## Ticks a check box of the open option window (tests, QA).
func set_option_check(id: int, on: bool) -> void:
	var b := _checks.get(id) as BaseButton
	if b != null:
		b.button_pressed = on

## OURS: the extra bars' count row -- "Bars" and "Pages", each a value
## between the quick slot art's left and right arrows (qsl_left_arrow /
## qsl_right_arrow, 12x20, referenced by nothing in retail) -- in a band
## inserted at y 175 (the frame's bottom), the authored button band and
## buttons moved down by its height. The values take effect on Apply or
## Confirm. No text-table row names them, so the captions are English.
const COUNT_CAPTIONS := ["Bars", "Pages"]
const COUNT_LABEL_X := [46, 160]
const COUNT_ARROW_X := [100, 214]
const ARROW_LEFT := "interface\\quick_slot\\qsl_left_arrow.ddj"
const ARROW_RIGHT := "interface\\quick_slot\\qsl_right_arrow.ddj"

func _add_count_row(w: HudWindow, create: UiLayoutParser.SectionDef) -> void:
	if create != null:
		for c in create.controls:
			if c.rect.position.y >= COUNT_ROW_Y:
				var n := w.node(c.name) as Control
				if n != null:
					var r: Rect2 = n.get_meta(UiBuilder.AUTHORED_RECT_META, Rect2(n.position, n.size))
					r.position.y += COUNT_ROW_HEIGHT
					n.set_meta(UiBuilder.AUTHORED_RECT_META, r)
					n.position = r.position
	var row := Control.new()
	row.name = "CountRow"
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.position = Vector2(0, COUNT_ROW_Y)
	w.panel_root.add_child(row)
	_count_values = [int(counts[0]), int(counts[1])]
	_count_labels.clear()
	var limits := [[1, HudUnderbar.EXT_BARS_MAX], [1, HudUnderbar.EXT_PAGES_MAX]]
	for i in 2:
		var cap := _text_label(COUNT_CAPTIONS[i], Rect2(COUNT_LABEL_X[i], 8, 52, 16), HORIZONTAL_ALIGNMENT_LEFT)
		row.add_child(cap)
		var ax: int = COUNT_ARROW_X[i]
		var prev := _arrow_button(ARROW_LEFT, false, Vector2(ax, 5))
		var value := _text_label(str(_count_values[i]), Rect2(ax + 12, 8, 20, 16), HORIZONTAL_ALIGNMENT_CENTER)
		var nxt := _arrow_button(ARROW_RIGHT, false, Vector2(ax + 32, 5))
		row.add_child(prev)
		row.add_child(value)
		row.add_child(nxt)
		_count_labels.append(value)
		var lo: int = limits[i][0]
		var hi: int = limits[i][1]
		var at := i
		prev.pressed.connect(func() -> void: _step_count(at, -1, lo, hi))
		nxt.pressed.connect(func() -> void: _step_count(at, 1, lo, hi))

func _step_count(i: int, by: int, lo: int, hi: int) -> void:
	_count_values[i] = clampi(int(_count_values[i]) + by, lo, hi)
	if i < _count_labels.size():
		(_count_labels[i] as Label).text = str(_count_values[i])

## The OURS count row's values as edited (tests): [bars, pages].
func count_row_values() -> Array:
	return _count_values.duplicate()

## Steps an OURS count (tests, QA): 0 bars, 1 pages.
func step_count(i: int, by: int) -> void:
	var hi := HudUnderbar.EXT_BARS_MAX if i == 0 else HudUnderbar.EXT_PAGES_MAX
	_step_count(i, by, 1, hi)

func _text_label(text: String, rect: Rect2, align: HorizontalAlignment) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = align
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.clip_text = false
	var font := _builder.font_at(0) if _builder != null else null
	if font != null:
		l.add_theme_font_override("font", font)
	l.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[0])
	l.add_theme_color_override("font_color", Color.WHITE)
	l.position = rect.position
	l.size = rect.size
	l.set_meta(UiBuilder.AUTHORED_RECT_META, rect)
	UiBuilder.crisp_text(l)
	return l

## A quick_slot arrow as a button with its _focus / _press / _disable art,
## turned a quarter clockwise when `turned` (OURS: no up/down art exists).
func _arrow_button(art: String, turned: bool, at: Vector2) -> TextureButton:
	var b := TextureButton.new()
	b.focus_mode = Control.FOCUS_NONE
	b.ignore_texture_size = true
	b.stretch_mode = TextureButton.STRETCH_SCALE
	var tex := func(path: String) -> Texture2D:
		var t := _builder.load_texture(path)
		return _builder.rotated_cw(t) if turned and t != null else t
	b.texture_normal = tex.call(art)
	b.texture_hover = tex.call(art.replace(".ddj", "_focus.ddj"))
	b.texture_pressed = tex.call(art.replace(".ddj", "_press.ddj"))
	b.texture_disabled = tex.call(art.replace(".ddj", "_disable.ddj"))
	var s := ExtQuickSlotLayout.ARROW_SIZE
	if turned:
		s = Vector2(s.y, s.x)
	b.position = at
	b.size = s
	b.custom_minimum_size = s
	return b

# --- OURS: the page footer of the extra bars ---------------------------------

## The footer (OURS, ExtQuickSlotLayout.footer_rects): the backing composed
## from the header art, the two arrows and the page label "F5".. in the
## client's font 0, white. On a horizontal bar it covers the slot area's END
## cap, which is not built there.
func _build_footer(t: int) -> void:
	if _footer != null:
		remove_child(_footer)
		_footer.queue_free()
		_footer = null
		_footer_label = null
	if bar_index == 0:
		return
	var vert := ExtQuickSlotLayout.is_vertical(t)
	var wnd := _nodes.get(ExtQuickSlotLayout.ID_WND) as TextureRect
	var across := (wnd.size.x if vert else wnd.size.y) if wnd != null else 0.0
	var slot_end := 0.0
	for b in ExtQuickSlotLayout.board_count(t):
		var board := _nodes.get(ExtQuickSlotLayout.ID_BOARD + b) as Control
		if board != null:
			slot_end = maxf(slot_end, (board.position.y + board.size.y) if vert else (board.position.x + board.size.x))
	if not vert:
		var end := _nodes.get(ExtQuickSlotLayout.ID_END) as Control
		if end != null:
			_nodes.erase(ExtQuickSlotLayout.ID_END)
			end.get_parent().remove_child(end)
			end.queue_free()
	var rects := ExtQuickSlotLayout.footer_rects(vert, across, slot_end)
	_footer = Control.new()
	_footer.name = "PageFooter"
	_footer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_footer)
	move_child(_footer, 1)
	var band := TextureRect.new()
	band.name = "Band"
	var img := ExtQuickSlotLayout.compose_footer(wnd.texture.get_image() if wnd != null and wnd.texture != null else null, vert)
	if img != null:
		band.texture = ImageTexture.create_from_image(img)
	band.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	band.stretch_mode = TextureRect.STRETCH_SCALE
	var br: Rect2 = rects["band"]
	band.position = br.position
	band.size = br.size
	band.mouse_filter = Control.MOUSE_FILTER_STOP
	_footer.add_child(band)
	var prev := _arrow_button(ARROW_LEFT, not vert, (rects["prev"] as Rect2).position)
	prev.name = "PagePrev"
	var nxt := _arrow_button(ARROW_RIGHT, not vert, (rects["next"] as Rect2).position)
	nxt.name = "PageNext"
	prev.pressed.connect(func() -> void: set_page(page - 1))
	nxt.pressed.connect(func() -> void: set_page(page + 1))
	_footer.add_child(prev)
	_footer.add_child(nxt)
	_footer_label = _text_label(ExtQuickSlotLayout.page_label(page), rects["label"], HORIZONTAL_ALIGNMENT_CENTER)
	_footer_label.name = "PageLabel"
	_footer.add_child(_footer_label)

## OURS: the page shown, wrapping past either end as the bottom bar's pages
## do (0x60a730).
func set_page(p: int) -> void:
	if page_count <= 0:
		return
	page = ((p - 1) % page_count + page_count) % page_count + 1
	if _footer_label != null:
		_footer_label.text = ExtQuickSlotLayout.page_label(page)
	_show_page_slots()

func page_text() -> String:
	return _footer_label.text if _footer_label != null else ""

func footer() -> Control:
	return _footer

# --- use ----------------------------------------------------------------------

## The quick slot key k (1..10, '0' is 10) fires on the page shown; -1 when
## out of range. Retail's bar is Space+digit's (KeyMap), OURS the first extra
## bar's Alt+digit.
func slot_for_key(k: int) -> int:
	if k < 1 or k > ExtQuickSlotLayout.SLOTS:
		return -1
	return quick_slot(page, k - 1)

func activate_key(k: int) -> int:
	var idx := slot_for_key(k)
	if idx >= 0:
		_underbar.activate_slot(idx)
	return idx

## Whether an enabled, shown button of the bar is under a global point (a
## held icon lets such a click through, READ 0x6523d0 -- the pager included).
func button_at(at: Vector2) -> bool:
	return HudUnderbar._button_under(self, at)

## QA: the bar and its buttons where a run's clicks find them.
func qa_print() -> void:
	print("QA EXTBAR %d at %d,%d size %dx%d type %d open %s page %d/%d alpha %d" % [bar_index,
		int(global_position.x), int(global_position.y), int(size.x), int(size.y), current_type + 1, str(open),
		page, page_count, last_alpha])
	var named := {"opt": ExtQuickSlotLayout.ID_OPT, "hori": ExtQuickSlotLayout.ID_HORI,
		"vert": ExtQuickSlotLayout.ID_VERT, "onoff": ExtQuickSlotLayout.ID_ONOFF, "wnd": ExtQuickSlotLayout.ID_WND}
	for n in named:
		var c := _nodes.get(named[n]) as Control
		if c != null and c.is_visible_in_tree():
			var p := c.get_global_rect().get_center().round()
			print("QA EXTBTN %d:%s at %d,%d" % [bar_index, n, int(p.x), int(p.y)])
	if _footer != null and _footer.is_visible_in_tree():
		for n in ["PagePrev", "PageNext"]:
			var c := _footer.get_node_or_null(n) as Control
			if c != null:
				var p := c.get_global_rect().get_center().round()
				print("QA EXTBTN %d:%s at %d,%d" % [bar_index, n, int(p.x), int(p.y)])
	for k in ExtQuickSlotLayout.SLOTS:
		var node := slot_node(page, k)
		if node != null and node.is_visible_in_tree():
			var p := node.get_global_rect().get_center().round()
			print("QA EXTSLOT %d:%d quick:%d at %d,%d" % [bar_index, k + 1, quick_slot(page, k), int(p.x), int(p.y)])
