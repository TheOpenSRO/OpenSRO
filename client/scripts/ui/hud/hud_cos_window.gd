extends HudWindow
class_name HudCosWindow

## The COS window (round 795): the client's CIFCOS, registry entry
## `GDR_COS_WND` (ID 120, `0,0,355,390`, `interface\frame\mframe_wnd_`, its own
## ginterface section "COSWnd"), with its three pages Basic Info (CIFCOSInfo),
## Inventory (CIFCOSInventory) and Setting (CIFCOSSetup). READ from
## sro_client.exe and Media.pk2 unless a line says otherwise; client_ui.md
## sections 1c..1g have the addresses.
##
## - The frame and chrome are CIFMainFrame's (HudWindow's registry path);
##   `resinfo\ifcos.txt` "Create" adds GDR_COS_IFRAME (`int_window_` at
##   12,66,331,314). The pages are that file's other sections, each one
##   control at 12,66 (331x314), each loading its own layout at that origin.
## - The tabs are built in code (CIFSelectableArea): x = 18 + 78 i, y 44,
##   72x24, `com_long_tab_off.ddj` / `com_long_tab_on.ddj`, captioned
##   UIIT_STT_COSNEWUI_TABMENU_BASICINFO, UIIT_STT_COS_INVENTORY and
##   UIIT_STT_COSNEWUI_TABMENU_TECHNOLOGY. A tab's caption is laid out as the
##   bag's page tabs are (font 0, centred both ways, white; HudPanels).
## - Show (FUN_0079ff50): the caption is the record's name or "No name"; the
##   Inventory tab is disabled unless kind 1 or 2, Setting unless kind 2; page
##   3 keeps the last page; a disabled page falls back to page 0.
## - Open / close (GInterface 0x79bcd0): the saved position, else centred on
##   the screen ((W - w) / 2, (H - h) / 2); close saves the position.
##
## OURS: a disabled tab's caption is dimmed (the art of a disabled
## CIFSelectableArea is not read); the Inventory page is hidden, not unloaded,
## when another page is chosen (0x79fcd0 unloads its section).

const LAYOUT := "resinfo\\ifcos.txt"
const REGISTRY := "GDR_COS_WND"
const INFO_LAYOUT := "resinfo\\ifcosinfo.txt"
const INVENTORY_LAYOUT := "resinfo\\ifcosinventory.txt"
const SETUP_LAYOUT := "resinfo\\ifcossetup.txt"

const PAGE_INFO := 0
const PAGE_INVENTORY := 1
const PAGE_SETUP := 2
## Show's "keep the last page".
const PAGE_KEEP := 3
const PAGE_ORIGIN := Vector2(12, 66)
const PAGE_SIZE := Vector2(331, 314)

const TAB_OFF := "interface\\ifcommon\\com_long_tab_off.ddj"
const TAB_ON := "interface\\ifcommon\\com_long_tab_on.ddj"
const TAB_X := 18
const TAB_PITCH := 78
const TAB_Y := 44
const TAB_SIZE := Vector2(72, 24)
const TAB_KEYS := ["UIIT_STT_COSNEWUI_TABMENU_BASICINFO", "UIIT_STT_COS_INVENTORY",
	"UIIT_STT_COSNEWUI_TABMENU_TECHNOLOGY"]
const TAB_FALLBACKS := ["Basic Info", "Inventory", "Setting"]

# --- Basic Info (ifcosinfo.txt, FUN_007a5610 / 0x7a3520) ---------------------
const INFO_HP_ROW := [30, 35, 40, 41]
const INFO_HGP_ROW := [31, 36, 42, 43]
const INFO_EXP_ROW := [32, 37, 44, 45]
const INFO_RENT_ROW := [50, 51, 52]
const INFO_STATS := [60, 61, 62, 63, 71, 72, 73, 65, 66, 67, 68, 76, 77, 78]
const INFO_NONE := 100
const ID_HP_GAUGE := 35
const ID_HP_TEXT := 41
const ID_HGP_GAUGE := 36
const ID_HGP_TEXT := 43
const ID_EXP_GAUGE := 37
const ID_EXP_TEXT := 45
const ID_LEVEL := 65
const ID_HIT := 66
const ID_PHY_ATK := 67
const ID_PHY_DEF := 68
const ID_PARRY := 76
const ID_MAG_ATK := 77
const ID_MAG_DEF := 78
const ID_RENT := 52
const ID_NAME := 27
const ID_NAME_BTN := 26
## The stat values' colour while HGP <= 3000 (0x7a3200, 0xff999999).
const STAT_GREY := Color8(0x99, 0x99, 0x99)

# --- Inventory (ifcosinventory.txt, CIFCOSInventory 0x7a7450) ---------------
const INV_SLOTS := 28
const INV_COLS := 7
const INV_ORIGIN := Vector2(41, 59)
const INV_PITCH := 36
const INV_SLOT_SIZE := Vector2(32, 32)
const INV_BLOCK := "interface\\pet\\pt_block.ddj"
const ID_INV_SPIN := 17
const ID_INV_NAME := 6
const ID_ALLSELL := 35
const ID_TOTAL_GOLD := 23
const INV_STARS := [26, 27, 28, 29, 30]

# --- Setting (ifcossetup.txt, CIFCOSSetup 0x7a86c0) -------------------------
const ID_SETUP_OK := 40
const ID_SETUP_CANCEL := 41
const ID_RADIO_ONOFF := 20
const ID_RADIO_SCOPE := 22
const ID_CHECK_GOLD := 25
const ID_CHECK_EQUIP := 26
const ID_CHECK_OTHER := 27
const RADIO_ON := "interface\\ifcommon\\com_radiobutton_on.ddj"
const RADIO_OFF := "interface\\ifcommon\\com_radiobutton_off.ddj"
const RADIO_DOT := Vector2(16, 16)
## CIFRadioButton's item geometry as Create sets it (0x7a8729..0x7a87ec,
## READ): origin (0, 0) (0x657910(0, 0)), two items in a row
## (0x657c40(2, 1)), the pitch 0x47 / 0xa8 (0x657930), the label 0x14 to the
## right (0x657940), left-aligned (0x657950(0)), 0x31 / 0x66 wide (0x657960).
## The label's +3 down and 12 high are round 711's CIFSetPartyMode reading.
const RADIO_SPECS := {
	ID_RADIO_ONOFF: {"pitch": 71, "label_dx": 20, "label_w": 49,
		"keys": ["UIIT_STT_COSNEWUI_PICKUP_SWITCH_ON", "UIIT_STT_COSNEWUI_PICKUP_SWITCH_OFF"],
		"fallbacks": ["ON", "OFF"]},
	ID_RADIO_SCOPE: {"pitch": 168, "label_dx": 20, "label_w": 102,
		"keys": ["UIIT_STT_COSNEWUI_PICKUPITEM_ASSORTMENT_SELF", "UIIT_STT_COSNEWUI_PICKUPITEM_ASSORTMENT_ALL"],
		"fallbacks": ["Grab only my items", "Grab all items"]},
}
const RADIO_LABEL_DY := 3
const RADIO_LABEL_H := 12

## The naming box was confirmed: send 0x7117.
signal rename_requested(uid: int, cos_name: String)
## A name the client's check refused (0x8c3cb0; the client then prints
## system message 0x440e in 0xffdbc99b, whose text is OPEN).
signal name_rejected(uid: int, cos_name: String)
## The Setting page's Confirm: send 0x7420 {uid, 2, flags}.
signal setting_requested(uid: int, kind: int, value: int)
## A left release on a filled pet-bag slot: pick it up.
signal bag_slot_picked(uid: int, slot: int, icon: Texture2D, source: Control, at: Vector2)
## The pointer entered (item, ItemTableReader.Item) or left (null, null) a
## pet-bag slot.
signal bag_slot_hovered(item: ItemInstance, row: ItemTableReader.Item, source: Control)

## Callables the owner gives (HudCos.setup's providers): "text"(key, fallback),
## "cos_row"(ref_id), "item_row"(ref_item_id), "exp_to_next"(level),
## "item_lookup"(bag_index) -> ItemInstance, "cos_stats"(ref_id) -> Dictionary,
## "trade_level"() -> int, "trade_price"(ref_item_id) -> int,
## "special_store_open"() -> bool.
var providers: Dictionary = {}

var cos_uid := 0
var data: CosNet.Data = null
var kind := -1
## The page shown (+0x7c0).
var page := PAGE_INFO
## The inventory page shown, 0-based (+0x7b4).
var inv_page := 0
## The position saved on close (0x79a840); null until the first close.
var saved_position: Variant = null

var tabs: Array = []
var pages: Array = [null, null, null]
var _page_layouts: Array = [null, null, null]
var _info_nodes := {}
var _inv_nodes := {}
var _setup_nodes := {}
var inv_slots: Array = []
var _radio_dots := {}
var _check_boxes := {}
## The Setting page's edited flags (record +0x163a8 until changed).
var edit_flags := 0
var name_box: HudCosBox
var confirm_box: PartyMatchConfirm
var _pending_name := ""

func _init() -> void:
	super._init()
	name = "COSWindow"
	visible = false

## Builds the window from GDR_COS_WND and ifcos.txt. False without them.
func build_window(builder: UiBuilder) -> bool:
	if not build(builder, LAYOUT, "", PackedStringArray(), PackedStringArray(), false, {"name": REGISTRY}):
		return false
	closed.connect(func() -> void: saved_position = position)
	var strip := Control.new()
	strip.name = "COSTabs"
	strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(strip)
	for i in 3:
		var tab := TextureButton.new()
		tab.name = "Tab%d" % i
		tab.ignore_texture_size = true
		tab.stretch_mode = TextureButton.STRETCH_SCALE
		tab.focus_mode = Control.FOCUS_NONE
		tab.action_mode = BaseButton.ACTION_MODE_BUTTON_PRESS
		tab.position = Vector2(TAB_X + TAB_PITCH * i, TAB_Y)
		tab.size = TAB_SIZE
		tab.custom_minimum_size = TAB_SIZE
		var p := i
		tab.pressed.connect(func() -> void: select_page(p))
		var caption := Label.new()
		caption.name = "Text"
		caption.text = _t(TAB_KEYS[i], TAB_FALLBACKS[i])
		caption.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		caption.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var font := builder.font_at(0)
		if font != null:
			caption.add_theme_font_override("font", font)
		caption.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[0])
		tab.add_child(caption)
		strip.add_child(tab)
		tabs.append(tab)
	_paint_tabs()
	return true

func _t(key: String, fallback: String) -> String:
	var c: Callable = providers.get("text", Callable())
	if c.is_valid():
		return String(c.call(key, fallback))
	if _builder != null:
		var r := _builder.resolve_text(key)
		if r != "" and r != key:
			return r
	return fallback

func _p(key: String) -> Callable:
	return providers.get(key, Callable())

# --- the rules, static so they can be checked without the archive ----------

## Which tabs a kind may use (0x79ff50): [info, inventory, setting].
static func tabs_enabled(client_kind: int) -> Array:
	return [true, client_kind == 1 or client_kind == 2, client_kind == 2]

## The page Ins opens for a kind (FUN_007a0980 case 0): 1 for a transport or
## an ability pet, else 0.
static func info_command_page(client_kind: int) -> int:
	return PAGE_INVENTORY if client_kind == 1 or client_kind == 2 else PAGE_INFO

## The page Show lands on for `requested` (0x79ff50 / 0x79fe10): 3 keeps
## `last`; a page whose tab is disabled falls back to 0.
static func resolve_page(requested: int, last: int, client_kind: int) -> int:
	var p := last if requested == PAGE_KEEP else requested
	if p < 0 or p > 2 or not bool(tabs_enabled(client_kind)[p]):
		return PAGE_INFO
	return p

## The Basic Info page's shown controls for a kind, id -> bool
## (FUN_007a5610 and 0x7a3520).
static func info_visibility(client_kind: int) -> Dictionary:
	var out := {}
	var growth := client_kind == 3
	for id in INFO_HGP_ROW + INFO_EXP_ROW:
		out[id] = growth
	for id in INFO_HP_ROW:
		out[id] = client_kind != 2
	for id in INFO_RENT_ROW:
		out[id] = client_kind == 2
	for id in INFO_STATS:
		out[id] = growth
	out[INFO_NONE] = not growth
	return out

## "%d/%d (%d%%)" (0x7a2e60): HP, MaxHP, trunc(ratio x 100).
static func hp_text(hp: int, max_hp: int) -> String:
	if max_hp <= 0:
		return "100%"
	var ratio := float(hp) / float(max_hp)
	return "%d/%d (%d%%)" % [hp, max_hp, int(ratio * 100.0)]

## The HP gauge's ratio (1.0 with no MaxHP to divide by).
static func hp_ratio(hp: int, max_hp: int) -> float:
	if max_hp <= 0:
		return 1.0
	return float(hp) / float(max_hp)

## The HGP gauge's ratio, HGP / 10000.0 (0x7a2fc0).
static func hgp_ratio(hgp: int) -> float:
	return float(hgp) / float(CosNet.HGP_FULL)

## "%d%% (%d)" (0x7a2fc0): min(100, 1 - trunc(ratio x -100.0)) and the raw
## HGP -- so 5000 shows "51% (5000)" (READ as written; -100.0 is 0xdb9a38).
static func hgp_text(hgp: int) -> String:
	var pct := mini(100, 1 - int(hgp_ratio(hgp) * -100.0))
	return "%d%% (%d)" % [pct, hgp]

## The EXP gauge's ratio, EXP / next (0x7a30a0); 0 with no next (OURS).
static func exp_ratio(exp_now: int, next: int) -> float:
	if next <= 0:
		return 0.0
	return float(exp_now) / float(next)

## "%I64d/%I64d (%.2f%%)" (0x7a30a0): EXP, next, min(ratio x 100, 99.99).
static func exp_text(exp_now: int, next: int) -> String:
	return "%d/%d (%.2f%%)" % [exp_now, next, minf(exp_ratio(exp_now, next) * 100.0, 99.99)]

## "%d%s %d%s %d%s" (0x7a3bd0): days, hours and minutes of `ms`, with the
## Day / Hour / Minute words; "0%s 0%s 0%s" at or below 0.
static func rent_text(ms: int, day: String, hour: String, minute: String) -> String:
	if ms <= 0:
		return "0%s 0%s 0%s" % [day, hour, minute]
	var d := ms / 86400000
	var rem := ms % 86400000
	return "%d%s %d%s %d%s" % [d, day, rem / 3600000, hour, (rem % 3600000) / 60000, minute]

## A stat pair's text (0x7a3200): "%d ~ %d", or "0" when the max is 0.
static func range_text(lo: int, hi: int) -> String:
	return "0" if hi == 0 else "%d ~ %d" % [lo, hi]

## The pet bag's page count for a capacity (OURS, INFERRED: record +0x60 is
## read by 0x7a7e90 but its writer was not traced; 28 a page).
static func inventory_pages(capacity: int) -> int:
	return maxi(1, (capacity + INV_SLOTS - 1) / INV_SLOTS)

## The pet bag's caption (0x7a7e90): "%s (%d/%d)".
static func inventory_caption(title: String, page_index: int, page_count: int) -> String:
	return "%s (%d/%d)" % [title, page_index + 1, page_count]

## The name check: 1..12 characters and no space (OURS: the client's own
## check 0x8c3cb0 was not read; the length is the server's rule, pets.md,
## and the edit's 12-character cap 0x634f80(0xc)).
static func name_valid(cos_name: String) -> bool:
	return cos_name.length() >= 1 and cos_name.length() <= HudCosBox.NAME_MAX \
		and not cos_name.contains(" ") and cos_name.strip_edges() == cos_name

## The pickup flags after a radio or check box change (0x7a83e0 / 0x7a84c0).
static func flags_with_radio(flags: int, radio_id: int, index: int) -> int:
	if radio_id == ID_RADIO_ONOFF:
		return (flags | CosNet.PICK_ON) if index == 0 else (flags & ~CosNet.PICK_ON)
	if radio_id == ID_RADIO_SCOPE:
		return (flags | CosNet.PICK_ALL) if index == 1 else (flags & ~CosNet.PICK_ALL)
	return flags

static func flags_with_check(flags: int, check_id: int, on: bool) -> int:
	var bit := 0
	match check_id:
		ID_CHECK_GOLD: bit = CosNet.PICK_GOLD
		ID_CHECK_EQUIP: bit = CosNet.PICK_EQUIPMENT
		ID_CHECK_OTHER: bit = CosNet.PICK_OTHER
	return (flags | bit) if on else (flags & ~bit)

# --- show, pages, tabs --------------------------------------------------------

## Show (FUN_0079ff50) for `d` on `requested` (3 keeps the last page).
func show_cos(d: CosNet.Data, requested: int) -> void:
	data = d
	cos_uid = d.uid if d != null else 0
	kind = CosNet.client_kind(d.kind) if d != null else -1
	set_title(_display_name())
	page = resolve_page(requested, page, kind)
	edit_flags = d.pet_option if d != null else 0
	_paint_tabs()
	select_page(page)

## Opens the window (0x79bcd0 with open 1): the saved position or centred.
func open_for(d: CosNet.Data, requested: int) -> void:
	show_cos(d, requested)
	if saved_position != null:
		position = saved_position
	else:
		var view := screen_size()
		position = Vector2(floorf((view.x - size.x) / 2.0), floorf((view.y - size.y) / 2.0))
	show()
	move_to_front()

## Closes it, saving the position (0x79bcd0 with open 0).
func close_window() -> void:
	if visible:
		saved_position = position
	hide()

## The screen the window centres on (0x79ac50): the owner's "screen_size"
## provider, else the viewport.
func screen_size() -> Vector2:
	var c := _p("screen_size")
	if c.is_valid():
		var v: Vector2 = c.call()
		if v.x > 0 and v.y > 0:
			return v
	return get_viewport_rect().size if is_inside_tree() else Vector2(1024, 768)

func _display_name() -> String:
	if data != null and data.name != "":
		return data.name
	return _t("UIIT_STT_COSNEWUI_TITLE", "No name")

func _paint_tabs() -> void:
	var en := tabs_enabled(kind)
	for i in tabs.size():
		var tab: TextureButton = tabs[i]
		var on := i == page
		tab.texture_normal = _builder.load_texture(TAB_ON if on else TAB_OFF) if _builder != null else null
		tab.disabled = not bool(en[i])
		var cap := tab.get_node_or_null("Text") as Label
		if cap != null:
			cap.modulate = Color.WHITE if bool(en[i]) else Color(0.6, 0.6, 0.6)

## Selects a page (a tab press, or Show). A disabled page is refused.
func select_page(p: int) -> void:
	if p < 0 or p > 2 or not bool(tabs_enabled(kind)[p]):
		return
	page = p
	_ensure_page(p)
	for i in pages.size():
		if pages[i] != null:
			(pages[i] as Control).visible = i == p
	_paint_tabs()
	refresh()

func _ensure_page(p: int) -> void:
	if pages[p] != null or _builder == null:
		return
	var path: String = [INFO_LAYOUT, INVENTORY_LAYOUT, SETUP_LAYOUT][p]
	var layout := _builder.load_layout(path)
	var holder := Control.new()
	holder.name = ["COSInfoWnd", "COSInventoryWnd", "COSSetupWnd"][p]
	holder.position = PAGE_ORIGIN
	holder.size = PAGE_SIZE
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(holder)
	# The tabs stay in front of the pages (they sit above the page origin).
	var strip := get_node_or_null("COSTabs")
	if strip != null:
		move_child(strip, -1)
	pages[p] = holder
	_page_layouts[p] = layout
	if layout == null:
		return
	var sec_root := _builder.build_section(layout, "Create")
	if sec_root == null:
		return
	holder.add_child(sec_root)
	var nodes := _index(layout.get_section("Create"), sec_root)
	match p:
		PAGE_INFO:
			_info_nodes = nodes
			var btn := nodes.get(ID_NAME_BTN) as BaseButton
			if btn != null:
				btn.pressed.connect(open_name_box)
			for id in [ID_HP_GAUGE, ID_HGP_GAUGE, ID_EXP_GAUGE]:
				var g := nodes.get(id) as TextureProgressBar
				if g != null:
					g.max_value = 1.0
					g.step = 0.0
		PAGE_INVENTORY:
			_inv_nodes = nodes
			# The trade section, for a transport only (0x7a7450).
			if kind == 1 and layout.sections.has("TradeInfo"):
				var trade := _builder.build_section(layout, "TradeInfo")
				if trade != null:
					holder.add_child(trade)
					_inv_nodes.merge(_index(layout.get_section("TradeInfo"), trade), true)
					UiBuilder.settle_authored_rects(trade)
			_build_inventory_slots(holder)
			var spin := _inv_nodes.get(ID_INV_SPIN) as Control
			if spin != null and spin.has_user_signal("spin_changed"):
				spin.connect("spin_changed", func(v: int) -> void:
					inv_page = v
					refresh_inventory())
		PAGE_SETUP:
			_setup_nodes = nodes
			_build_setup_controls()
	UiBuilder.settle_authored_rects(sec_root)

static func _index(sec: UiLayoutParser.SectionDef, built: Control) -> Dictionary:
	var out := {}
	if sec == null or built == null:
		return out
	for def in sec.controls:
		var n := built.get_node_or_null(NodePath(def.name))
		if n != null:
			out[def.id] = n
	return out

## A Basic Info control by layout ID (tests, QA), or null.
func info_node(id: int) -> Control:
	return _info_nodes.get(id) as Control

func inventory_node(id: int) -> Control:
	return _inv_nodes.get(id) as Control

func setup_node(id: int) -> Control:
	return _setup_nodes.get(id) as Control

## Re-reads the record into the shown page (the pages' vslot_012).
func refresh() -> void:
	match page:
		PAGE_INFO:
			refresh_info()
		PAGE_INVENTORY:
			refresh_inventory()
		PAGE_SETUP:
			refresh_setup()

func _process(_delta: float) -> void:
	if visible and data != null and page == PAGE_INFO:
		_refresh_info_values()

# --- Basic Info ---------------------------------------------------------------

func refresh_info() -> void:
	if _info_nodes.is_empty():
		return
	var vis := info_visibility(kind)
	for id in vis:
		var n := _info_nodes.get(id) as CanvasItem
		if n != null:
			n.visible = bool(vis[id])
	_refresh_name()
	_refresh_info_values()

func _refresh_name() -> void:
	var nm := _info_nodes.get(ID_NAME) as Control
	if nm != null and _builder != null:
		_builder.set_static_text(nm, _display_name())
	var btn := _info_nodes.get(ID_NAME_BTN) as BaseButton
	if btn != null:
		btn.disabled = not name_button_enabled()

## The "Create name" button (0x7a3e60): only while the name is empty and the
## COS is a pet (kind 2 or 3).
func name_button_enabled() -> bool:
	return data != null and data.name == "" and (kind == 2 or kind == 3)

func _row() -> CosTable.Row:
	var c := _p("cos_row")
	if data == null or not c.is_valid():
		return null
	return c.call(data.ref_id) as CosTable.Row

func _refresh_info_values() -> void:
	if data == null or _builder == null:
		return
	var row := _row()
	var max_hp := row.max_hp if row != null else 0
	var g := _info_nodes.get(ID_HP_GAUGE) as TextureProgressBar
	if g != null:
		g.value = clampf(hp_ratio(data.hp, max_hp), 0.0, 1.0)
	_set_text(ID_HP_TEXT, hp_text(data.hp, max_hp))
	if kind == 3:
		g = _info_nodes.get(ID_HGP_GAUGE) as TextureProgressBar
		if g != null:
			g.value = clampf(hgp_ratio(data.hgp), 0.0, 1.0)
		_set_text(ID_HGP_TEXT, hgp_text(data.hgp))
		var next := _next_exp(data.level)
		g = _info_nodes.get(ID_EXP_GAUGE) as TextureProgressBar
		if g != null:
			g.value = clampf(exp_ratio(data.exp, next), 0.0, 1.0)
		_set_text(ID_EXP_TEXT, exp_text(data.exp, next))
		_set_text(ID_LEVEL, "%d" % data.level)
		_refresh_stats()
	if kind == 2:
		_set_text(ID_RENT, rent_text(_rent_ms(), _t("PARAM_DAY", "Day"), _t("PARAM_HOUR", "Hour"),
			_t("PARAM_MINUTE", "Minute")))

func _next_exp(level: int) -> int:
	var c := _p("exp_to_next")
	return int(c.call(level)) if c.is_valid() else 0

## The summon item's remaining rent in ms (0x8ba5b0 on the linked item).
func _rent_ms() -> int:
	var c := _p("item_lookup")
	if data == null or data.item_slot < 0 or not c.is_valid():
		return 0
	var it = c.call(data.item_slot)
	if it is ItemInstance:
		return (it as ItemInstance).rent_left_secs() * 1000
	return 0

## The stat block (0x7a3200). The values are the record's +0x38..+0x4e, which
## 0x9a0be0 computes from the row and halves while HGP <= 3000; that
## computation is not reproduced here, so the values come from the owner's
## "cos_stats"(ref_id) -> {"pa": [lo, hi], "ma": [lo, hi], "pd", "md", "hr",
## "er"} (OURS hook) and are halved here (INFERRED: integer halving). With no
## hook the value rows stay empty.
func _refresh_stats() -> void:
	var c := _p("cos_stats")
	var s: Dictionary = {}
	if c.is_valid():
		var got = c.call(data.ref_id)
		if got is Dictionary:
			s = got
	var low := data.hgp <= CosNet.HGP_LOW
	var colour := STAT_GREY if low else Color.WHITE
	if s.is_empty():
		for id in [ID_HIT, ID_PHY_ATK, ID_PHY_DEF, ID_PARRY, ID_MAG_ATK, ID_MAG_DEF]:
			_set_text(id, "")
		return
	var h := func(v: int) -> int: return v / 2 if low else v
	var pa: Array = s.get("pa", [0, 0])
	var ma: Array = s.get("ma", [0, 0])
	_set_text(ID_PHY_ATK, range_text(h.call(int(pa[0])), h.call(int(pa[1]))), colour)
	_set_text(ID_MAG_ATK, range_text(h.call(int(ma[0])), h.call(int(ma[1]))), colour)
	_set_text(ID_PHY_DEF, "%d" % h.call(int(s.get("pd", 0))), colour)
	_set_text(ID_MAG_DEF, "%d" % h.call(int(s.get("md", 0))), colour)
	_set_text(ID_HIT, "%d" % h.call(int(s.get("hr", 0))), colour)
	_set_text(ID_PARRY, "%d" % h.call(int(s.get("er", 0))), colour)

func _set_text(id: int, text: String, colour: Variant = null) -> void:
	var n := _info_nodes.get(id) as Control
	if n == null or _builder == null:
		return
	var l := _builder.set_static_text(n, text)
	if l != null and colour != null:
		l.add_theme_color_override("font_color", colour)

## A Basic Info row's text as shown (tests, QA).
func info_text(id: int) -> String:
	var n := _info_nodes.get(id) as Node
	if n is Label:
		return (n as Label).text
	var l := n.get_node_or_null("Text") as Label if n != null else null
	return l.text if l != null else ""

# --- naming (1e) --------------------------------------------------------------

## GDR_COS_INFO_NAME_BTN (0x7a4500): close any open box, open the input box.
func open_name_box() -> void:
	if not name_button_enabled():
		return
	_close_boxes()
	name_box = HudCosBox.new()
	if not name_box.build_name_input(_builder):
		name_box.free()
		name_box = null
		return
	name_box.accepted.connect(submit_name)
	_box_host().add_child(name_box)
	name_box.centre_on(screen_size())

## OK on the input box (0x7a4550): validate, then ask for confirmation.
func submit_name(cos_name: String) -> bool:
	if not name_valid(cos_name):
		name_rejected.emit(cos_uid, cos_name)
		return false
	_pending_name = cos_name
	_close_boxes()
	confirm_box = PartyMatchConfirm.new()
	var msg := "%s\n%s" % [_t("UIIT_MSG_COSPET_NOTREVISION_NAME", "Cannot change pet's name any more."),
		_t("UIIT_MSG_COSPET_CHOOSE_NAME", "Confirm pet's name?")]
	if _builder == null or not confirm_box.build(_builder, msg):
		confirm_box.free()
		confirm_box = null
		# No box to show (no archive): the confirmation is taken as given.
		confirm_name()
		return true
	confirm_box.confirmed.connect(confirm_name)
	_box_host().add_child(confirm_box)
	confirm_box.centre_on(screen_size())
	return true

## Yes on the confirmation (0x7a4170 sends 0x7117).
func confirm_name() -> void:
	if _pending_name == "":
		return
	rename_requested.emit(cos_uid, _pending_name)
	_pending_name = ""

func _close_boxes() -> void:
	for b in [name_box, confirm_box]:
		if b != null and is_instance_valid(b) and not b.is_queued_for_deletion():
			b.close()
	name_box = null
	confirm_box = null

func _box_host() -> Node:
	return get_parent() if get_parent() != null else self

# --- Inventory (1f) -------------------------------------------------------------

func _build_inventory_slots(holder: Control) -> void:
	inv_slots.clear()
	for i in INV_SLOTS:
		var def := UiLayoutParser.ControlDef.new()
		def.name = "COSInvSlot%d" % i
		def.type = "CIFSlotWithHelp"
		def.id = 100 + i
		var at := INV_ORIGIN + Vector2(INV_PITCH * (i % INV_COLS), INV_PITCH * (i / INV_COLS))
		def.rect = Rect2i(Vector2i(at), Vector2i(INV_SLOT_SIZE))
		var slot := _builder.build_control(def)
		if slot == null:
			continue
		slot.mouse_filter = Control.MOUSE_FILTER_STOP
		holder.add_child(slot)
		var index := i
		slot.gui_input.connect(func(ev: InputEvent) -> void: _on_inv_slot_input(ev, index))
		slot.mouse_entered.connect(func() -> void: _on_inv_slot_hover(index, true))
		slot.mouse_exited.connect(func() -> void: _on_inv_slot_hover(index, false))
		inv_slots.append(slot)

func capacity() -> int:
	return data.inv_size if data != null else 0

func refresh_inventory() -> void:
	if _inv_nodes.is_empty() and inv_slots.is_empty():
		return
	var cap := capacity()
	var count := inventory_pages(cap)
	inv_page = clampi(inv_page, 0, count - 1)
	var spin := _inv_nodes.get(ID_INV_SPIN) as Control
	if spin != null and spin.has_meta("value"):
		spin.set_meta("value", inv_page)
		UiBuilder.set_spin_range(spin, 0, count - 1)
	var title := _t("UIIT_STT_SPECIALTY_INVENTORY", "Special Item Inventory") if kind == 1 \
		else _t("UIIT_STT_SILKMALL_PET", "Pet")
	var cap_node := _inv_nodes.get(ID_INV_NAME) as Control
	if cap_node != null and _builder != null:
		_builder.set_static_text(cap_node, inventory_caption(title, inv_page, count))
	var block := _builder.load_texture(INV_BLOCK) if _builder != null else null
	var item_row := _p("item_row")
	for i in inv_slots.size():
		var slot: Control = inv_slots[i]
		var index := inv_page * INV_SLOTS + i
		var icon := slot.get_node_or_null("ItemIcon") as TextureRect
		var count_lbl := slot.get_node_or_null("CountLabel") as Label
		if count_lbl != null:
			count_lbl.text = ""
		var locked := index >= cap
		slot.set_meta("cos_locked", locked)
		if icon == null:
			continue
		if locked:
			icon.texture = block
			continue
		icon.texture = null
		var it: ItemInstance = data.items.get(index) if data != null else null
		if it == null:
			continue
		var row = item_row.call(it.ref_item_id) if item_row.is_valid() else null
		if row is ItemTableReader.Item and _builder != null:
			icon.texture = _builder.load_texture((row as ItemTableReader.Item).icon_path)
		if count_lbl != null and not it.is_equipment and it.count > 1:
			count_lbl.text = str(it.count)
	_refresh_trade()

## The transport's trade rows (TradeInfo): the total (count x the item's
## price, OURS hook "trade_price": the record's +0xb0 is not mapped to an
## itemdata column), the stars (0x9c7a80's trade level, hook "trade_level";
## that the first n stars show is INFERRED) and Sell All, enabled only while
## the specialty store is open (0x7a7970; hook "special_store_open").
func _refresh_trade() -> void:
	if kind != 1 or data == null:
		return
	var price := _p("trade_price")
	var total_node := _inv_nodes.get(ID_TOTAL_GOLD) as Control
	if total_node != null and _builder != null:
		if price.is_valid():
			var total := 0
			for slot in data.items:
				var it: ItemInstance = data.items[slot]
				total += maxi(1, it.count) * int(price.call(it.ref_item_id))
			_builder.set_static_text(total_node, "%d" % total)
		else:
			_builder.set_static_text(total_node, "")
	var lv_c := _p("trade_level")
	var level := int(lv_c.call()) if lv_c.is_valid() else 0
	for i in INV_STARS.size():
		var star := _inv_nodes.get(INV_STARS[i]) as CanvasItem
		if star != null:
			star.visible = i < level
	var sell := _inv_nodes.get(ID_ALLSELL) as BaseButton
	if sell != null:
		var open_c := _p("special_store_open")
		sell.disabled = not (open_c.is_valid() and bool(open_c.call()))

## The pet-bag slot index under a global position, -1 when none (a locked
## slot included: -1).
func bag_slot_at(global_pos: Vector2) -> int:
	if not visible or page != PAGE_INVENTORY:
		return -1
	for i in inv_slots.size():
		var slot: Control = inv_slots[i]
		if slot.is_visible_in_tree() and slot.get_global_rect().has_point(global_pos):
			var index := inv_page * INV_SLOTS + i
			return index if index < capacity() else -1
	return -1

## Whether a global position is over the window at all.
func covers(global_pos: Vector2) -> bool:
	return visible and get_global_rect().has_point(global_pos)

func _on_inv_slot_input(event: InputEvent, i: int) -> void:
	if not HeldIcon.is_pick_click(event) or data == null:
		return
	var index := inv_page * INV_SLOTS + i
	if index >= capacity() or not data.items.has(index):
		return
	var slot: Control = inv_slots[i]
	var icon := slot.get_node_or_null("ItemIcon") as TextureRect
	bag_slot_picked.emit(cos_uid, index, icon.texture if icon != null else null, slot,
		(event as InputEventMouseButton).global_position)

func _on_inv_slot_hover(i: int, entered: bool) -> void:
	var slot: Control = inv_slots[i]
	if not entered or data == null:
		bag_slot_hovered.emit(null, null, slot)
		return
	var index := inv_page * INV_SLOTS + i
	var it: ItemInstance = data.items.get(index)
	if it == null:
		bag_slot_hovered.emit(null, null, slot)
		return
	var item_row := _p("item_row")
	var row = item_row.call(it.ref_item_id) if item_row.is_valid() else null
	bag_slot_hovered.emit(it, row as ItemTableReader.Item, slot)

# --- Setting (1g) ----------------------------------------------------------------

func _build_setup_controls() -> void:
	for id in RADIO_SPECS:
		var group := _setup_nodes.get(id) as Control
		if group == null:
			continue
		var spec: Dictionary = RADIO_SPECS[id]
		var dots: Array = []
		for i in 2:
			var at := Vector2(float(spec["pitch"]) * i, 0)
			var dot := TextureButton.new()
			dot.name = "Item%d" % i
			dot.ignore_texture_size = true
			dot.stretch_mode = TextureButton.STRETCH_SCALE
			dot.focus_mode = Control.FOCUS_NONE
			dot.position = at
			dot.size = RADIO_DOT
			dot.custom_minimum_size = RADIO_DOT
			dot.pressed.connect(choose_radio.bind(id, i))
			group.add_child(dot)
			dots.append(dot)
			var def := UiLayoutParser.ControlDef.new()
			def.name = "Label%d" % i
			def.type = "CIFStatic"
			def.halign = 0
			def.rect = Rect2i(Vector2i(at) + Vector2i(int(spec["label_dx"]), RADIO_LABEL_DY),
				Vector2i(int(spec["label_w"]), RADIO_LABEL_H))
			var label := _builder.build_control(def)
			if label is Label:
				(label as Label).text = _t(spec["keys"][i], spec["fallbacks"][i])
				UiBuilder.place_label(label as Label, Rect2(def.rect))
			if label != null:
				group.add_child(label)
		group.mouse_filter = Control.MOUSE_FILTER_PASS
		_radio_dots[id] = dots
	for id in [ID_CHECK_GOLD, ID_CHECK_EQUIP, ID_CHECK_OTHER]:
		var holder := _setup_nodes.get(id) as Control
		if holder == null:
			continue
		var box := _builder.make_checkbox(holder, "interface\\ifcommon\\com_checkbutton_off.ddj", false)
		var cid: int = id
		box.toggled.connect(func(on: bool) -> void: set_check(cid, on))
		_check_boxes[id] = box
	var ok := _setup_nodes.get(ID_SETUP_OK) as BaseButton
	if ok != null:
		ok.pressed.connect(press_setup_ok)
	var cancel := _setup_nodes.get(ID_SETUP_CANCEL) as BaseButton
	if cancel != null:
		cancel.pressed.connect(press_setup_cancel)

## The radios' and boxes' state from `edit_flags` (0x7a8290's load).
func refresh_setup() -> void:
	for id in _radio_dots:
		var chosen := radio_choice(id)
		var dots: Array = _radio_dots[id]
		for i in dots.size():
			(dots[i] as TextureButton).texture_normal = _builder.load_texture(RADIO_ON if i == chosen else RADIO_OFF)
	for id in _check_boxes:
		var box: TextureButton = _check_boxes[id]
		box.set_pressed_no_signal(check_state(id))
		var mark := box.get_node_or_null("GDR_STATIC_SELECTED") as CanvasItem
		if mark != null:
			mark.visible = box.button_pressed
	var ok := _setup_nodes.get(ID_SETUP_OK) as BaseButton
	if ok != null:
		ok.disabled = not setup_changed()

## The chosen item of a radio group by the edited flags.
func radio_choice(radio_id: int) -> int:
	if radio_id == ID_RADIO_ONOFF:
		return 0 if edit_flags & CosNet.PICK_ON else 1
	return 1 if edit_flags & CosNet.PICK_ALL else 0

func check_state(check_id: int) -> bool:
	return flags_with_check(0, check_id, true) & edit_flags != 0

## Confirm is enabled only while the edit differs from the record.
func setup_changed() -> bool:
	return data != null and edit_flags != data.pet_option

func choose_radio(radio_id: int, index: int) -> void:
	edit_flags = flags_with_radio(edit_flags, radio_id, index)
	refresh_setup()

func set_check(check_id: int, on: bool) -> void:
	edit_flags = flags_with_check(edit_flags, check_id, on)
	refresh_setup()

## Confirm (0x7a85c0 -> 0x81ea70(id, 2, flags)).
func press_setup_ok() -> void:
	if not setup_changed():
		return
	setting_requested.emit(cos_uid, CosNet.SETTING_PICKUP, edit_flags)

## Cancel: back to the record's flags (OPEN: the handler was not read).
func press_setup_cancel() -> void:
	edit_flags = data.pet_option if data != null else 0
	refresh_setup()
