extends RefCounted
class_name GrantMagicAttributeWindow

## The blacksmith's "grant magic option on avatar item" window (round 789,
## lane AC): retail's CIFGrantMagicAttributeWnd ("GrantMagicAttribute",
## resinfo\ifgrantmagicattributewnd.txt, framed by ginterface.txt's
## GDR_GRANT_MAGIC_ATTRIBUTE under APPLY_AVATAR_SYSTEM, which config\define.txt
## defines -- MEASURED), over the window HudPanels builds from the player's own
## Media.pk2. Every rule is READ from sro_client.exe in
## /root/opensro-pk3av789/AVATAR_ALCHEMY_RESEARCH.md section 1 unless labelled:
##
## - **Opening**: the talk line kind 0x2f sends 0x7046 {npc, 0x20}; 0xB046
##   {1, 0x20} shows this window and the inventory beside it (c:0x888e30,
##   0x79d4a0, 0x79af20). Cancel (ID 6) hides it and ends the talk (0x704B).
## - **Putting an item in** (vslot_028 c:0x80a320): only a drop from the
##   inventory; a non-bionic 3/1/13 that is not a 13/4, else
##   UIIT_STT_AVATAR_MAGICOPTION_ONLY_AVATAR in the system line. The icon goes
##   in slot ID 8 and ID 9 reads "<kind> - <ADD_COUNT>: <n><UNIT>" (c:0x8092f0),
##   n = MaxMagicOptCount (col 158) - the item's option count.
## - **The list** (c:0x8be3a0, c:0x8bcdf0): the magicoptionassign names of
##   the item's (TypeID3, TypeID4) minus the options it already has (exact
##   name), one row each, its text FUN_0066a8c0's line with the row's column 9
##   as the number (c:0x80a4f7), 23 px apart, five shown (c:0x80a285..0x80a2af).
##   A click selects a row: its bar gil_bar02_select.ddj, the others
##   gil_bar02_deselect.ddj (c:0x808be0).
## - **Confirm** (ID 5, c:0x80a8c0): with an item and a row, sends 0x34A9
##   unless the count has reached MaxMagicOptCount (then
##   UIIT_MSG_AVATAR_MAGICOPTION_ADD_ERORR in the system line, nothing sent).
## - **The reply** 0x34AA (c:0x899f40): granted, the item is replaced, the list
##   refreshed (the granted row gone, the count line updated) and
##   UIIT_MSG_AVATAR_MAGICOPTION_ADD shown; refused, the error box of category
##   0x20 (AvatarNet.GRANT_REFUSAL_KEYS).
##
## OURS, each where it is done: the refusal is shown in the system line, not
## an error box (the box is not built); five bars are the five visible rows'
## and the list scrolls with the wheel (the scroll manager's own bar is not
## built); the window is placed as HudPanels places a panel.

const LAYOUT := "resinfo\\ifgrantmagicattributewnd.txt"
const SLOT_LAYOUT := "resinfo\\ifgrantmagicattributeslot.txt"
const REGISTRY := "GDR_GRANT_MAGIC_ATTRIBUTE"
const SECTION_LIST := "OptionList"
const META := "grant_magic_attribute_window"

## Control names (the layout's own; the research gives their IDs).
const N_ITEM_SLOT := "GDR_GRANT_MAGIC_ATTRIBUTE_ITEM_SLOT"   # ID 8
const N_ITEM_NAME := "GDR_GRANT_MAGIC_ATTRIBUTE_ITEM_NAME"   # ID 9
const N_DESC := "GDR_GRANT_MAGIC_ATTRIBUTE_DESC"             # ID 10
const N_CONFIRM := "GDR_GRANT_MAGIC_ATTRIBUTE_CONFIRM_BTN"   # ID 5
const N_CANCEL := "GDR_GRANT_MAGIC_ATTRIBUTE_CANCEL_BTN"     # ID 6
const N_SCROLL := "GDR_GRANT_MAGIC_ATTRIBUTE_LIST_SCROLLMGR" # ID 32
const N_BARS := ["GDR_GRANT_MAGIC_ATTRIBUTE_SLOT_BAR_01", "GDR_GRANT_MAGIC_ATTRIBUTE_SLOT_BAR_02",
	"GDR_GRANT_MAGIC_ATTRIBUTE_SLOT_BAR_03", "GDR_GRANT_MAGIC_ATTRIBUTE_SLOT_BAR_04",
	"GDR_GRANT_MAGIC_ATTRIBUTE_SLOT_BAR_05"]
const N_ROW := "GDR_GRANT_MAGIC_ATTRIBUT_SLOT"

## READ: the paths in sro_client.exe's strings.
const BAR_SELECT := "interface\\guild\\gil_bar02_select.ddj"
const BAR_DESELECT := "interface\\guild\\gil_bar02_deselect.ddj"
## READ c:0x80a285..0x80a2af: rows of 0x17 px, five shown.
const ROW_HEIGHT := 23
const VISIBLE_ROWS := 5

const MSG_ONLY_AVATAR := "UIIT_STT_AVATAR_MAGICOPTION_ONLY_AVATAR"
const MSG_CAP := "UIIT_MSG_AVATAR_MAGICOPTION_ADD_ERORR"
const MSG_GRANTED := "UIIT_MSG_AVATAR_MAGICOPTION_ADD"

var window: HudWindow
var _builder: UiBuilder
## The bag index of the item in the slot (-1: none), its row and instance.
var bag_slot := -1
var item: ItemTableReader.Item = null
var instance: ItemInstance = null
## The grantable rows: {"code", "value" (column 9), "text"}.
var rows: Array = []
var selected := -1
var _scroll := 0
var _row_nodes: Array = []

## Hooks HudPanels sets: send(bag_slot, code); message(text) for the system
## line; text(key, fallback) -> String; show_icon(icon: TextureRect, item_id,
## bag_slot) fills slot 8.
var send: Callable
var message: Callable
var text: Callable
var show_icon: Callable
## The tables the list is built from (AvatarTables, MagicOptionTable).
var tables: AvatarTables = null
var options: MagicOptionTable = null

static func of(w: HudWindow) -> GrantMagicAttributeWindow:
	if w == null or not w.has_meta(META):
		return null
	return w.get_meta(META) as GrantMagicAttributeWindow

## Wires the window's controls once and returns the controller.
static func compose(w: HudWindow, builder: UiBuilder) -> GrantMagicAttributeWindow:
	var existing := of(w)
	if existing != null:
		return existing
	var c := GrantMagicAttributeWindow.new()
	c.window = w
	c._builder = builder
	w.set_meta(META, c)
	c._build()
	return c

func _t(key: String, fallback: String = "") -> String:
	if text.is_valid():
		return String(text.call(key, fallback if fallback != "" else key))
	if _builder != null:
		var r := _builder.resolve_text(key)
		if r != "" and r != key:
			return r
	return fallback if fallback != "" else key

func _say(t: String) -> void:
	if message.is_valid():
		message.call(t)

func _build() -> void:
	if window == null:
		return
	var confirm_btn := window.node(N_CONFIRM) as BaseButton
	if confirm_btn != null:
		confirm_btn.pressed.connect(confirm)
	# The bars as Create leaves them: gil_bar02_deselect.ddj.
	for i in N_BARS.size():
		_set_bar(i, false)
	# The rows: CIFGrantMagicAttributeSlot (ifgrantmagicattributeslot.txt, a
	# 215x24 centred static), one per visible position in the scroll manager.
	var host := window.node(N_SCROLL) as Control
	var slot_layout := _builder.load_layout(SLOT_LAYOUT) if _builder != null else null
	if host != null:
		host.mouse_filter = Control.MOUSE_FILTER_STOP
		host.gui_input.connect(_on_list_input)
		for i in VISIBLE_ROWS:
			var row: Control = _builder.build_section(slot_layout, "Create") if slot_layout != null else null
			if row == null:
				row = Control.new()
				row.size = Vector2(215, 24)
			row.name = "GrantRow%d" % i
			row.position = Vector2(0, i * ROW_HEIGHT)
			row.mouse_filter = Control.MOUSE_FILTER_STOP
			var at := i
			row.gui_input.connect(func(ev: InputEvent) -> void:
				var mb := ev as InputEventMouseButton
				if mb != null and mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
					select(_scroll + at))
			host.add_child(row)
			_row_nodes.append(row)
		var bars: Array = []
		for n in N_BARS:
			bars.append(window.node(n))
		raise_list(host, bars)
	clear_item()

## Round 789 lane E (MEASURED live, OURS fix): the OptionList section builds the
## five bars (IDs 40..44) after the scroll manager (ID 32) that holds the rows,
## so the bars' opaque com_bar01_ art drew over every row: the list showed five
## empty bars, its labels set but unseen (`QA GRANT drawn`, docs/rounds/r789e.md),
## and the bars took the rows' clicks. The rows must be over the bars for the
## window to work at all (INFERRED: how retail orders its scroll manager's
## children against the bars is not READ), so the scroll manager is moved to
## draw after the last bar that is its sibling.
static func raise_list(host: Control, bars: Array) -> void:
	if host == null or host.get_parent() == null:
		return
	var parent := host.get_parent()
	var top := host.get_index()
	for b in bars:
		var bar := b as Control
		if bar != null and bar.get_parent() == parent:
			top = maxi(top, bar.get_index())
	if top != host.get_index():
		parent.move_child(host, top)

func _set_bar(i: int, on: bool) -> void:
	var bar := window.node(N_BARS[i]) as Control if window != null else null
	if bar == null or _builder == null:
		return
	apply_bar(bar, _builder.load_texture(BAR_SELECT if on else BAR_DESELECT))

## Puts a gil_bar02 texture on a bar (READ c:0x808be0 via the research: the
## bar's texture is SET to it, at Create and on each click). Round 789 lane E
## (MEASURED live): the art used to go in under the bar's own com_bar01_
## 3-slice (opaque, UiBuilder's row bar pieces), so neither texture was ever
## seen and the selected row looked like the rest. The bar's own pieces are
## hidden now and the art is its top child -- a replacement, as the client's
## set is.
static func apply_bar(bar: Control, tex: Texture2D) -> TextureRect:
	if bar == null:
		return null
	var art := bar.get_node_or_null("GrantBar") as TextureRect
	if art == null:
		art = TextureRect.new()
		art.name = "GrantBar"
		art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		art.stretch_mode = TextureRect.STRETCH_SCALE
		art.mouse_filter = Control.MOUSE_FILTER_IGNORE
		bar.add_child(art)
		for c in bar.get_children():
			if c != art and c is CanvasItem:
				(c as CanvasItem).visible = false
	art.texture = tex
	return art

# --- the rules ----------------------------------------------------------------

## Whether the window takes an item (READ c:0x80a3a2..0x80a3d3, c:0x808f60):
## a non-bionic 3/1/13 that is not a 13/4.
static func accepts(it: ItemTableReader.Item) -> bool:
	return it != null and it.is_avatar() and it.bionic == 0 and it.type_ids[3] != 4

## The item's option count as the window counts it (SOItem +0xa5, c:0x8bcdf0):
## MagParamNum minus the options whose magicoption sign is '-' (INFERRED that
## the '-' it looks for is column 3, the sign; every avatar row is '+',
## MEASURED).
static func option_count(inst: ItemInstance, table: MagicOptionTable) -> int:
	if inst == null:
		return 0
	var n := 0
	for i in inst.option_count():
		var r := table.row(inst.option_id(i)) if table != null else null
		if r != null and r.sign == "-":
			continue
		n += 1
	return n

## The grantable rows of an item: its kind's magicoptionassign names minus the
## options it has (exact MATTR name), each with the magicoption row at the
## item's degree, (ItemClass - 1) / 3 + 1, and that row's column 9.
static func grantable(it: ItemTableReader.Item, inst: ItemInstance, t: AvatarTables, table: MagicOptionTable) -> Array:
	var out: Array = []
	if it == null or t == null or it.type_ids.size() < 4:
		return out
	var have := {}
	if inst != null and table != null:
		for i in inst.option_count():
			var r := table.row(inst.option_id(i))
			if r != null:
				have[r.code] = true
	var degree := floori((maxi(it.item_class, 1) - 1) / 3.0) + 1
	for name in t.assign_names(it.type_ids[2], it.type_ids[3]):
		if have.has(name):
			continue
		var r: MagicOptionTable.Row = table.record(name, degree) if table != null else null
		var value := int(r.ranges[1]) if r != null and r.ranges.size() > 1 else 0
		out.append({"code": name, "value": value})
	return out

## ID 9's line (READ c:0x8092f0): "<kind> - " for a hat, dress or attachment,
## then "%s: %d%s" ADD_COUNT, MaxMagicOptCount - count, UNIT.
static func count_line(it: ItemTableReader.Item, count: int, t: Callable) -> String:
	var line := ""
	var kind: String = ItemTooltipLines.AVATAR_KIND_KEYS.get(it.type_ids[3], "") if it.type_ids.size() >= 4 else ""
	if kind != "":
		line = "%s - " % String(t.call(kind, kind))
	return line + "%s: %d%s" % [String(t.call("UIIT_STT_AVATAR_MAGICOPTION_ADD_COUNT", "Additional")),
		(it.max_magic_options & 0xff) - (count & 0xff), String(t.call("UIIT_STT_UNIT", "Unit"))]

## Whether Confirm may send (READ c:0x80a8c0: SOItem +0xa5 < ref +0x534).
static func can_send(it: ItemTableReader.Item, count: int) -> bool:
	return it != null and count < it.max_magic_options

# --- the window -----------------------------------------------------------------

## An inventory item put down on the window: refused with ONLY_AVATAR, or put
## in. Returns whether it went in.
func offer(slot: int, it: ItemTableReader.Item, inst: ItemInstance) -> bool:
	if not accepts(it):
		_say(_t(MSG_ONLY_AVATAR))
		return false
	bag_slot = slot
	item = it
	instance = inst
	selected = -1
	_scroll = 0
	refresh()
	return true

func clear_item() -> void:
	bag_slot = -1
	item = null
	instance = null
	rows = []
	selected = -1
	_scroll = 0
	_draw()

## The rows and the count line again (READ 0x80a6f0, also run on a reply).
func refresh() -> void:
	rows = []
	if item != null:
		var t := Callable(self, "_t")
		for r in grantable(item, instance, tables, options):
			r["text"] = ItemTooltipLines.avatar_line(String(r["code"]), int(r["value"]), t)
			rows.append(r)
	if selected >= rows.size():
		selected = -1
	_draw()

func _draw() -> void:
	if window == null:
		return
	var slot := window.node(N_ITEM_SLOT) as Control
	var icon := slot.get_node_or_null("ItemIcon") as TextureRect if slot != null else null
	if icon != null:
		if show_icon.is_valid():
			show_icon.call(icon, item.id if item != null else -1, bag_slot)
		elif item == null:
			icon.texture = null
	if _builder != null:
		_builder.set_static_text(window.node(N_ITEM_NAME) as Control,
			count_line(item, option_count(instance, options), Callable(self, "_t")) if item != null else "")
	for i in _row_nodes.size():
		var at: int = _scroll + i
		var node: Control = _row_nodes[i]
		var label := node if node is Label else node.find_child(N_ROW, true, false) as Control
		var line: String = String(rows[at]["text"]) if at < rows.size() else ""
		if _builder != null and label != null:
			_builder.set_static_text(label, line)
		node.visible = at < rows.size()
		_set_bar(i, at == selected)

## A row clicked (c:0x80a810): +0x7d4 = its index; its bar selected.
func select(index: int) -> void:
	if index < 0 or index >= rows.size():
		return
	selected = index
	_draw()

func _on_list_input(ev: InputEvent) -> void:
	var mb := ev as InputEventMouseButton
	if mb == null or not mb.pressed:
		return
	if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
		_scroll = maxi(_scroll - 1, 0)
		_draw()
	elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		_scroll = clampi(_scroll + 1, 0, maxi(rows.size() - VISIBLE_ROWS, 0))
		_draw()

## Confirm (c:0x80a8c0 -> c:0x822a30). Returns whether a request went out.
func confirm() -> bool:
	if item == null or bag_slot < 0 or selected < 0 or selected >= rows.size():
		return false
	if not can_send(item, option_count(instance, options)):
		_say(_t(MSG_CAP))
		return false
	if send.is_valid():
		send.call(bag_slot, String(rows[selected]["code"]))
	return true

## The 0x34AA reply (AvatarNet.decode_grant_ack).
func apply_result(r: Dictionary) -> void:
	if bool(r.get("ok", false)):
		var it = r.get("item")
		if it != null and (it as ItemInstance).slot == bag_slot:
			instance = it
		selected = -1
		refresh()
		_say(_t(MSG_GRANTED))
	else:
		_say(AvatarNet.grant_refusal_line(int(r.get("code", 0)), Callable(self, "_t")))
