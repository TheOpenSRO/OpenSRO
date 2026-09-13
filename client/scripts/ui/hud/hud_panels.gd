extends Control
class_name HudPanels

## Owns every floating game window: creates them on first use, toggles them
## by hotkey or from the underbar's MENU, and fills them from NetClient.
##
## The panels themselves are authored data (see docs/UI_TODO.md): one
## `resinfo\if*.txt` per window, built by HudWindow. What lives here is the
## wiring -- which layout is which panel, which key opens it, and where its
## contents come from.
##
## **The layout-file mapping below is this project's own wiring, not
## recovered data.** Nothing found in the client's files links a window to
## its `resinfo` file; the real client hardcodes it, and so do we. The
## titles are likewise ours: the layouts carry control text but not the
## window's own title, which the real client draws itself.

const UiBuilder = preload("res://scripts/ui/ui_builder.gd")
const HudWindow = preload("res://scripts/ui/hud/hud_window.gd")

## key: the panel id used by the underbar's menu_action and by hotkeys.
## Each entry is [layout path, window title, hotkey action name or ""].
const PANELS := {
	"inventory": ["resinfo\\ifinventory.txt", "Inventory", KEY_I],
	# The equipment window: the dressed character (the paper doll) with the
	# worn slots around it. Its own window rather than fused to the bag.
	"equipment": ["resinfo\\ifequipment.txt", "Equipment", KEY_O],
	"character": ["resinfo\\ifplayerinfo.txt", "Character", KEY_C],
	"skill": ["resinfo\\ifskill.txt", "Skill", KEY_K],
	"quest": ["resinfo\\ifquest.txt", "Quest list", KEY_Q],
	"party": ["resinfo\\ifparty.txt", "Party", KEY_P],
	"community": ["resinfo\\ifcommunity.txt", "Community", KEY_U],
	"guild": ["resinfo\\ifguild.txt", "Guild", KEY_G],
	"action": ["resinfo\\ifaction.txt", "Action", KEY_A],
	"partymatch": ["resinfo\\ifpartymatch.txt", "Party Matching", KEY_E],
	"academy": ["resinfo\\ifapprenticeship.txt", "Academy", KEY_L],
	"autopotion": ["resinfo\\ifautopotion.txt", "Auto Potion", KEY_T],
	"alchemy": ["resinfo\\ifalchemyprocess.txt", "Alchemy", KEY_Y],
	"exchange": ["resinfo\\ifexchange.txt", "Exchange", 0],
	# Opened by Escape, not a hotkey (see _unhandled_key_input). The system
	# menu the original raises over everything: Option, Help, Restart, Exit.
	"system": ["resinfo\\ifsystemwnd.txt", "System", 0],
	# Opened by clicking an NPC (World3D._try_talk_to_npc), titled with the
	# NPC's name. The authored paper dialogue the original raises.
	"npctalk": ["resinfo\\if_npctalk.txt", "", 0],
	# Opened from the talk box's Buy option (open_shop), titled with the NPC's
	# name. The authored store window: a 6x5 goods grid, a page spinner, and
	# repair. Built with #ifdef selection (see PANEL_DEFINES).
	"store": ["resinfo\\ifstore.txt", "Store", 0],
	# Opened from the talk box's Storage option (open_storage). The authored
	# warehouse window: a 6x5 grid of the character's stored items.
	"storage": ["resinfo\\ifstorageroom.txt", "Storage", 0],
}

## Panels whose layout is read with #ifdef branch selection, mapped to the
## symbols defined for them. ifstore's two slot sets are alternates behind
## RENEWAL_SHOP_SYSTEM; with nothing defined we take the base 30-slot grid and
## drop the RESTORE_SOLDITEM_INSHOP buyback row this project does not implement.
## Both store classes (CIFStore, CIFStoreForPackage) build the same visible
## window -- confirmed by decompiling each: four `com_short_tab` tabs and a 6x5
## grid -- so the branch changes only invisible page capacity. Every other
## window keeps the default (read both branches), which is what they rely on.
const PANEL_DEFINES := {
	"store": [],
}

## Emitted by the System window's buttons, wired in _wire_system. World3D
## connects them: Option opens the settings panel, Restart returns to the
## login screen, Exit quits.
signal system_option_requested
signal system_restart_requested
signal system_exit_requested
signal system_help_requested
## A learned skill in the window was clicked to put it on the hotbar. World3D
## assigns it to the next free underbar quickslot (its icon shown there);
## activating that quickslot is what casts it. basic_code names the cast .ban
## clip; icon is the skill's already-loaded cell texture for the slot.
signal skill_assign_requested(skill_id: int, basic_code: String, icon: Texture2D)
## A talk-box service line other than "End conversation" was chosen; `key` is
## the service's stable key (NpcServiceReader.Service.key -- "shop", "repair",
## ...). World3D acts on it (opens the shop, ...).
signal npc_service_selected(key: String)

## Sections beyond "Create" that a panel's window builds.
##
## A layout can hold several sections; "Create" is the chrome and the rest
## are content and modes. Which of them compose has to be established per
## window rather than assumed, so this table only lists the ones that are:
##
## - **skill**: ifskill has Create, MainSkillWnd and Withdrawal. The last two
##   are alternates -- the client picks between them on `m_bySkillWndType`,
##   one function with type 1 loading Withdrawal and types 2 and 3 loading
##   MainSkillWnd -- so the normal window is Create plus MainSkillWnd.
##
## - **guild**: ifguild has nine extra sections and the client binary this
##   project reverse-engineers has no string for any of them, so the answer
##   came from the authored geometry instead. `sweep_section_overlap.gd`
##   measures how much of each section's control area sits under every
##   other's, and GuildInfo, NotifySubBox, SortBtn, MemberView and Command
##   are **pairwise 0%** -- they tile the window, the guild header at the
##   top, the notice under it, the column headers, the member list, and the
##   buttons down the right. NotifyContents covers 85% of MemberView (and
##   MemberView 100% of it), GrantPower covers 95% of it, and GuildPointUp
##   and PositionGrant overlap each other 79%: those four are the same box
##   shown one at a time, and dialogs over the window.
##
## The same tool run on ifskill puts MainSkillWnd and Withdrawal at 100%,
## which is the answer the binary gives independently -- which is what makes
## the measurement worth trusting on ifguild, where the binary is silent.
## - **partymatch, academy, autopotion**: the same measurement. Party
##   matching composes SearchInfo, SlotListButton and SlotList -- the search
##   bar, the column headers and the list -- leaving JoinProgress,
##   PartyRegister and AutoMatch, which overlap each other 86-100%.
##
## A layout with only *one* extra tells the tool nothing, since there is
## nothing to compare against: ifinventory's ConfirmBuy is its only one and
## is a dialog (`CItemMallConfirmBuy`), so it is not listed here.
const EXTRA_SECTIONS := {
	"skill": ["MainSkillWnd"],
	"guild": ["GuildInfo", "NotifySubBox", "SortBtn", "MemberView", "Command"],
	"partymatch": ["SearchInfo", "SlotListButton", "SlotList"],
	"academy": ["NotifySubBox", "NotifyContents"],
	"autopotion": ["AbnormalSlot", "PotionDelaySlot"],
}

## Order, labels and the client's own menu icon for each MENU popup item,
## mirroring the reference's list. The icon is one of interface\underbar's
## own `ub_new_icon_*` (20x20); the three panels that are underbar buttons in
## this archive (inventory/character/skill) have no such icon here, so they
## show text-only rather than a mismatched one.
const MENU_ITEMS := [
	["party", "Party (P)", "ub_new_icon_pt"],
	["partymatch", "Party Match (E)", "ub_new_icon_ptm"],
	["guild", "Guild (G)", "ub_new_icon_guild"],
	["academy", "Academy (L)", "ub_new_icon_apprenticeship"],
	["action", "Action (A)", "ub_new_icon_action"],
	["community", "Community (U)", "ub_new_icon_commu"],
	["quest", "Quest (Q)", "ub_new_icon_quest"],
	["alchemy", "Alchemy (Y)", "ub_new_icon_alchemy"],
	["inventory", "Inventory (I)", ""],
	["character", "Character (C)", ""],
	["skill", "Skill (K)", ""],
	["autopotion", "Auto Potion (T)", "ub_new_icon_recovery"],
]

var _builder: UiBuilder
var _windows: Dictionary = {} # panel id -> HudWindow
var _unavailable: Dictionary = {} # panel id -> true, for layouts that failed
var _menu: PopupMenu
var _menu_ids: Array[String] = []

func _init(builder: UiBuilder = null) -> void:
	_builder = builder

func _ready() -> void:
	# A transparent full-screen container: it must not eat world clicks.
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_menu()

func _build_menu() -> void:
	_menu = PopupMenu.new()
	_menu.name = "Menu"
	_style_menu(_menu)
	for i in range(MENU_ITEMS.size()):
		var item: Array = MENU_ITEMS[i]
		var icon: Texture2D = null
		if item.size() > 2 and item[2] != "" and _builder != null:
			icon = _builder.load_texture("interface\\underbar\\%s.ddj" % item[2])
		if icon != null:
			_menu.add_icon_item(icon, item[1], i)
		else:
			_menu.add_item(item[1], i)
		_menu_ids.append(item[0])
	_menu.id_pressed.connect(func(id: int) -> void:
		if id >= 0 and id < _menu_ids.size():
			toggle(_menu_ids[id]))
	add_child(_menu)

## Dark, gold-edged styling so the menu reads as the game's rather than a grey
## system popup. A disclosed choice; the ornate authored frame is a later
## polish. The icon size is bumped so the 20x20 art is legible.
func _style_menu(menu: PopupMenu) -> void:
	var panel := StyleBoxFlat.new()
	panel.bg_color = Color(0.06, 0.06, 0.07, 0.97)
	panel.border_color = Color(0.55, 0.45, 0.22)
	panel.set_border_width_all(2)
	panel.set_corner_radius_all(4)
	panel.set_content_margin_all(6)
	menu.add_theme_stylebox_override("panel", panel)
	var hover := StyleBoxFlat.new()
	hover.bg_color = Color(0.20, 0.17, 0.09, 0.98)
	hover.set_corner_radius_all(3)
	menu.add_theme_stylebox_override("hover", hover)
	menu.add_theme_color_override("font_color", Color(0.90, 0.84, 0.60))
	menu.add_theme_color_override("font_hover_color", Color(1.0, 0.96, 0.74))
	menu.add_theme_constant_override("icon_max_width", 22)
	menu.add_theme_constant_override("v_separation", 6)

## Opens the MENU popup above the underbar, where the reference puts it.
func show_menu(near: Vector2) -> void:
	if _menu == null:
		return
	var wanted := Vector2(near.x, near.y - _menu.get_contents_minimum_size().y)
	_menu.position = Vector2i(get_screen_transform() * wanted)
	_menu.popup()

## Shows a panel, building it the first time it is asked for. Does nothing
## if its authored layout isn't in the archive -- a missing panel is a real
## possibility (layout names are our own mapping) and should not be an
## error the player sees.
func open(panel_id: String) -> HudWindow:
	# The client presents the bag and the equipment paper doll as one fused
	# window; we build that by docking the equipment layout inside the inventory
	# window, so the 'O' key and the bag both land on the same combined window.
	if panel_id == "equipment":
		panel_id = "inventory"
	if _unavailable.has(panel_id):
		return null
	var window: HudWindow = _windows.get(panel_id)
	if window == null:
		if not PANELS.has(panel_id):
			push_warning("HudPanels: no panel named %s" % panel_id)
			return null
		var spec: Array = PANELS[panel_id]
		window = HudWindow.new()
		window.name = "Window_" + panel_id
		add_child(window)
		var extra := PackedStringArray(EXTRA_SECTIONS.get(panel_id, []))
		var honor_ifdef: bool = PANEL_DEFINES.has(panel_id)
		var defines := PackedStringArray(PANEL_DEFINES.get(panel_id, []))
		if not window.build(_builder, spec[0], spec[1], extra, defines, honor_ifdef):
			print("HudPanels: %s unavailable (layout %s did not build)" % [panel_id, spec[0]])
			window.queue_free()
			_unavailable[panel_id] = true
			return null
		if panel_id == "inventory":
			# Dock the equipment paper doll flush to the right of the bag: the
			# authored bag frame is INVENTORY_CONTENT_WIDTH wide, so the two
			# read as the client's single fused inventory window.
			_inventory_eq_root = window.dock_companion(
				_builder, PANELS["equipment"][0], INVENTORY_CONTENT_WIDTH)
		window.centre()
		_windows[panel_id] = window
		if panel_id == "system":
			_wire_system(window)
		if panel_id == "inventory":
			_apply_equipment_slot_backgrounds()
			_place_paper_doll_docked()
			_fill_equipment_slots(_equipped_items)
		if panel_id == "skill":
			_fill_skill_masteries(window)
		_populate(panel_id)
	window.show()
	window.move_to_front()
	_populate(panel_id)
	return window

## Opens the NPC dialogue for an NPC of the given name: the authored paper
## window (if_npctalk) titled with the name, greeting and the choices the
## NPC offers. Only "End conversation" acts (it closes) -- the services
## behind the other lines (storage, shop, honour) are their own systems,
## still to come -- so the window greets and lets you leave, which is the
## skeleton the rest hangs on.
func open_npc_talk(npc_name: String, greeting: String = "", services: Array = []) -> void:
	var window := open("npctalk")
	if window == null:
		return
	window.set_title(npc_name)
	# The layout carries two backgrounds one over the other: a quest
	# parchment (GDR_NPCTALK_QUESTBG, `gd_paper_02`) in front of a plain
	# dark tile (GDR_NPCTALK_BGTILE, `com_bg_tile_d`). The parchment is for
	# quest text; a plain talk shows the dark tile, as the user's own client
	# does -- so the quest paper and its title strip are hidden here.
	for hidden in ["GDR_NPCTALK_QUESTBG", "GDR_NPCTALK_QUESTBG_TITLE"]:
		var q := window.node(hidden) as CanvasItem
		if q != null:
			q.visible = false
	var body := window.get_node_or_null("TalkText") as RichTextLabel
	if body == null:
		body = RichTextLabel.new()
		body.name = "TalkText"
		body.bbcode_enabled = true
		body.scroll_active = false
		body.position = Vector2(28, HudWindow.TITLE_BAR_HEIGHT + 8.0)
		body.size = window.size - Vector2(52, HudWindow.TITLE_BAR_HEIGHT + 20.0)
		body.add_theme_color_override("default_color", ROW_TEXT_COLOUR)
		if _builder != null:
			var font := _builder.font_at(0)
			if font != null:
				body.add_theme_font_override("normal_font", font)
			body.add_theme_font_size_override("normal_font_size", UiBuilder.FONT_SIZES[0])
		body.meta_clicked.connect(_on_npc_talk_choice)
		window.add_child(body)
	# The real greeting (from npcchat.txt), then the NPC's real services as
	# numbered options, then End conversation. The service lines are grounded
	# detection (which NPC offers what); only End acts for now -- the services
	# behind them (shop, storage, ...) are their own systems, still to come.
	var lines := PackedStringArray()
	lines.append(greeting if greeting != "" else "...")
	lines.append("")
	var n := 1
	for svc in services:
		# Each service is a clickable link keyed by its stable key; World3D
		# acts on the ones that have a system behind them (Buy opens the shop).
		lines.append("[url=%s]%d. %s[/url]" % [str(svc.key), n, str(svc.label)])
		n += 1
	lines.append("[url=end]%d. End conversation.[/url]" % n)
	body.text = "\n".join(lines)

func _on_npc_talk_choice(meta: Variant) -> void:
	var key := str(meta)
	if key == "end":
		close("npctalk")
		return
	# A real service was chosen. The talk box stays open behind the service
	# window (the client keeps it up), so World3D decides what to raise.
	npc_service_selected.emit(key)

# --- The NPC shop -----------------------------------------------------------
#
# The authored store window (ifstore) shows the NPC's real goods: the 6x5 grid
# (GDR_STORE_LAT) filled with icons, one authored tab per goods category, and
# the item's real name/stats on hover. The goods and the tabs come from the
# client's own shop tables (ShopReader). Buying is Stage 2.
#
# The tab strip is built here rather than read from the layout because the
# store window builds its own tabs in code -- confirmed by decompiling both
# CIFStore and CIFStoreForPackage: a loop from x=16 stepping 56 while x<240,
# each tab a `com_short_tab`, so up to four. Their y is not in any data (the
# layout has no tab controls), so it is placed on the grid frame's top edge --
# ours, disclosed.
const SHOP_TAB_ON := "interface\\ifcommon\\com_short_tab_on.ddj"
const SHOP_TAB_OFF := "interface\\ifcommon\\com_short_tab_off.ddj"
const SHOP_MAX_TABS := 4
const SHOP_TAB_X0 := 16.0
const SHOP_TAB_STEP := 56.0
## The grid frame's authored top edge (GDR_STORE_FRAME y). Tabs sit on it.
const SHOP_TAB_Y_BOTTOM := 60.0
const SHOP_TAB_FALLBACK_SIZE := Vector2(54, 20)

var _shop_tabs: Array = []      # of ShopReader.Tab
var _shop_selected := 0
## item id -> price, from the server catalogue (its own disclosed formula --
## there is no real NPC price table; see docs/GROUNDING_AUDIT.md). Requested
## once and cached.
var _shop_prices: Dictionary = {}

## Opens the store window for an NPC, filled with the tabs of real goods the
## caller resolved (World3D, via ShopReader). Retitles and refills a single
## reused window, like the talk box.
func open_shop(npc_name: String, tabs: Array) -> void:
	var window := open("store")
	if window == null:
		return
	window.set_title(npc_name)
	_shop_tabs = tabs
	_shop_selected = 0
	_build_shop_tab_strip(window)
	_build_shop_purse(window)
	_select_shop_tab(0)
	window.show()
	window.move_to_front()
	# Open the bag alongside, so the player can sell from it -- the client sells
	# by clicking an inventory item while the shop is open. Set side by side so
	# the shop and the bag both read (the client pairs them the same way).
	var bag: HudWindow = open("inventory")
	if bag != null:
		var view := get_viewport_rect().size
		window.position = Vector2(view.x * 0.5 - window.size.x - 8.0, (view.y - window.size.y) * 0.5).round()
		bag.position = Vector2(view.x * 0.5 + 8.0, (view.y - bag.size.y) * 0.5).round()
		bag.move_to_front()
		window.move_to_front()
	# Prices for just this NPC's goods, and the current purse. The catalogue is
	# the server's to compute; the client only displays what it sends. Asking
	# for only these ids (not the whole ~12k catalogue) keeps the reply inside
	# a single frame.
	if NetClient.is_connected_to_server():
		var ids := _shop_item_ids()
		if not ids.is_empty():
			NetClient.list_shop(ids)
		var who := NetClient.current_character_name
		if who != "":
			NetClient.character_stats(who)
			NetClient.list_inventory(who)
	_update_shop_purse()

## The item ids of every good this NPC sells, across all its tabs -- what to
## ask the server to price.
func _shop_item_ids() -> Array:
	_load_items()
	var ids: Array = []
	for tab in _shop_tabs:
		for code in (tab as ShopReader.Tab).item_codes:
			var item: ItemTableReader.Item = _items_by_code.get(code)
			if item != null:
				ids.append(item.id)
	return ids

func _build_shop_tab_strip(window: HudWindow) -> void:
	var old := window.get_node_or_null("ShopTabs")
	if old != null:
		old.free() # free now, not queued -- we rebuild in this same call
	var strip := Control.new()
	strip.name = "ShopTabs"
	strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	window.add_child(strip)
	var on: Texture2D = _builder.load_texture(SHOP_TAB_ON) if _builder != null else null
	var off: Texture2D = _builder.load_texture(SHOP_TAB_OFF) if _builder != null else null
	var tab_size: Vector2 = Vector2(on.get_size()) if on != null else SHOP_TAB_FALLBACK_SIZE
	for i in range(mini(_shop_tabs.size(), SHOP_MAX_TABS)):
		var tab: ShopReader.Tab = _shop_tabs[i]
		var btn := TextureButton.new()
		btn.name = "ShopTab%d" % i
		btn.ignore_texture_size = true
		btn.stretch_mode = TextureButton.STRETCH_SCALE
		btn.texture_normal = off
		btn.focus_mode = Control.FOCUS_NONE
		btn.position = Vector2(SHOP_TAB_X0 + i * SHOP_TAB_STEP, SHOP_TAB_Y_BOTTOM - tab_size.y)
		btn.size = tab_size
		btn.custom_minimum_size = tab_size
		var idx := i
		btn.pressed.connect(func() -> void: _select_shop_tab(idx))
		var lbl := Label.new()
		lbl.name = "Label"
		lbl.text = _builder.resolve_text(tab.name_strid) if _builder != null else tab.name_strid
		lbl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		lbl.add_theme_color_override("font_color", Color(0.93, 0.87, 0.70))
		if _builder != null:
			var font := _builder.font_at(0)
			if font != null:
				lbl.add_theme_font_override("font", font)
			lbl.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[0])
		btn.add_child(lbl)
		strip.add_child(btn)

## Selects a tab: marks it (the `on` texture) and fills the grid with its goods.
func _select_shop_tab(index: int) -> void:
	_shop_selected = index
	var window: HudWindow = _windows.get("store")
	if window == null:
		return
	var strip := window.get_node_or_null("ShopTabs")
	if strip != null and _builder != null:
		var on: Texture2D = _builder.load_texture(SHOP_TAB_ON)
		var off: Texture2D = _builder.load_texture(SHOP_TAB_OFF)
		for child in strip.get_children():
			if child is TextureButton:
				var selected: bool = (child as Node).name == "ShopTab%d" % index
				(child as TextureButton).texture_normal = on if selected else off
	if index >= 0 and index < _shop_tabs.size():
		_fill_shop_grid((_shop_tabs[index] as ShopReader.Tab).item_codes)

## Fills the store's 6x5 grid (GDR_STORE_LAT) with the icons of the goods, in
## the tab's own order. One page for now -- our NPCs' tabs each fit the 30
## cells; the authored page spinner (paging past 30) is Stage 2.
func _fill_shop_grid(codes: PackedStringArray) -> void:
	var window: HudWindow = _windows.get("store")
	if window == null:
		return
	var grid := window.node("GDR_STORE_LAT") as Control
	if grid == null:
		return
	_load_items()
	var cells := grid.get_child_count()
	for ci in range(cells):
		var cell := grid.get_child(ci)
		var icon := cell.get_node_or_null("ItemIcon") as TextureRect
		if icon == null:
			continue
		var item: ItemTableReader.Item = _items_by_code.get(codes[ci]) if ci < codes.size() else null
		if item != null and item.icon_path != "" and _builder != null:
			icon.texture = _builder.load_texture(item.icon_path)
			icon.tooltip_text = _shop_tooltip(item)
			icon.mouse_filter = Control.MOUSE_FILTER_STOP
			icon.set_meta("shop_item_id", item.id)
			# Click to buy. Wired once per cell (the cells persist across tab
			# switches); the meta above carries the current item.
			if not icon.has_meta("shop_click_wired"):
				icon.set_meta("shop_click_wired", true)
				icon.gui_input.connect(func(ev: InputEvent) -> void: _on_shop_cell_input(ev, icon))
		else:
			icon.texture = null
			icon.tooltip_text = ""
			icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
			if icon.has_meta("shop_item_id"):
				icon.remove_meta("shop_item_id")

## The hover tooltip for a shop item: its real stats, plus the price the server
## quotes (when the catalogue has arrived).
func _shop_tooltip(item: ItemTableReader.Item) -> String:
	var lines := PackedStringArray(item.tooltip_lines(_object_names))
	if _shop_prices.has(item.id):
		lines.append("")
		lines.append("Price: %s gold" % _grouped(_shop_prices[item.id]))
	return "\n".join(lines)

func _on_shop_cell_input(event: InputEvent, icon: TextureRect) -> void:
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		if icon.has_meta("shop_item_id"):
			_confirm_buy(int(icon.get_meta("shop_item_id")))

# --- Purse, buy confirmation, results ---------------------------------------
## Where the gold line sits in the store window: the empty band below the grid
## (the buyback row we don't build). Ours, disclosed.
const SHOP_PURSE_POS := Vector2(20, 300)
const SHOP_STATUS_POS := Vector2(20, 316)

func _build_shop_purse(window: HudWindow) -> void:
	if window.get_node_or_null("ShopPurse") != null:
		return
	var purse := Label.new()
	purse.name = "ShopPurse"
	purse.position = SHOP_PURSE_POS
	purse.add_theme_color_override("font_color", Color(0.95, 0.85, 0.45))
	var status := Label.new()
	status.name = "ShopStatus"
	status.position = SHOP_STATUS_POS
	status.add_theme_color_override("font_color", ROW_TEXT_COLOUR)
	for lbl in [purse, status]:
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if _builder != null:
			var font := _builder.font_at(0)
			if font != null:
				lbl.add_theme_font_override("font", font)
			lbl.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[0])
		window.add_child(lbl)

func _update_shop_purse() -> void:
	var window: HudWindow = _windows.get("store")
	if window == null:
		return
	var purse := window.get_node_or_null("ShopPurse") as Label
	if purse != null:
		purse.text = "Gold: %s" % (_grouped(_stats.gold) if _stats != null else "-")

func _set_shop_status(text: String) -> void:
	var window: HudWindow = _windows.get("store")
	if window == null:
		return
	var status := window.get_node_or_null("ShopStatus") as Label
	if status != null:
		status.text = text

## A small confirmation before spending gold, so a click does not buy by
## accident. Built over the store window; Buy sends the purchase, Cancel closes.
func _confirm_buy(item_id: int) -> void:
	var window: HudWindow = _windows.get("store")
	if window == null:
		return
	_load_items()
	var item: ItemTableReader.Item = _items.get(item_id)
	if item == null:
		return
	var old := window.get_node_or_null("BuyConfirm")
	if old != null:
		old.free()
	var price: int = _shop_prices.get(item_id, -1)
	var gold: int = _stats.gold if _stats != null else -1
	var stackable: bool = item.max_stack > 1
	# The most the player may buy: the item's stack, and (when price and purse
	# are both known) what the gold affords.
	var max_qty: int = maxi(1, item.max_stack)
	if price > 0 and gold >= 0:
		max_qty = clampi(gold / price, 1, maxi(1, item.max_stack))

	var panel := PanelContainer.new()
	panel.name = "BuyConfirm"
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.07, 0.08, 0.98)
	style.border_color = Color(0.55, 0.45, 0.22)
	style.set_border_width_all(2)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(12)
	panel.add_theme_stylebox_override("panel", style)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)
	box.add_child(_shop_label("Buy %s?" % item.display_name(_object_names), Color(0.95, 0.9, 0.72)))
	if price >= 0 and stackable:
		box.add_child(_shop_label("%s gold each" % _grouped(price), Color(0.86, 0.82, 0.7)))

	# Quantity + running total. The total label doubles as the affordability
	# signal (it turns red and disables Buy when the purse can't cover it).
	var qty_box := [1]
	var total_label := _shop_label("", Color(0.95, 0.85, 0.45))
	var buy := Button.new()
	buy.text = "Buy"
	var refresh := func() -> void:
		var q: int = qty_box[0]
		if price >= 0:
			total_label.text = "Total: %s gold" % _grouped(price * q)
			var afford: bool = gold < 0 or price * q <= gold
			total_label.add_theme_color_override("font_color", Color(0.95, 0.85, 0.45) if afford else Color(0.95, 0.5, 0.45))
			buy.disabled = not afford
		else:
			total_label.text = ""

	if stackable and max_qty > 1:
		var qrow := HBoxContainer.new()
		qrow.add_theme_constant_override("separation", 8)
		qrow.alignment = BoxContainer.ALIGNMENT_CENTER
		box.add_child(qrow)
		var minus := Button.new()
		minus.text = "-"
		minus.custom_minimum_size = Vector2(30, 0)
		var qty_label := _shop_label("1", Color(0.96, 0.96, 0.96))
		qty_label.custom_minimum_size = Vector2(52, 0)
		var plus := Button.new()
		plus.text = "+"
		plus.custom_minimum_size = Vector2(30, 0)
		minus.pressed.connect(func() -> void:
			qty_box[0] = maxi(1, qty_box[0] - 1)
			qty_label.text = str(qty_box[0])
			refresh.call())
		plus.pressed.connect(func() -> void:
			qty_box[0] = mini(max_qty, qty_box[0] + 1)
			qty_label.text = str(qty_box[0])
			refresh.call())
		qrow.add_child(minus)
		qrow.add_child(qty_label)
		qrow.add_child(plus)
	box.add_child(total_label)
	refresh.call()

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(row)
	buy.pressed.connect(func() -> void:
		var q: int = qty_box[0]
		panel.free()
		_do_buy(item_id, q))
	row.add_child(buy)
	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.pressed.connect(func() -> void: panel.free())
	row.add_child(cancel)

	window.add_child(panel)
	# Centre it over the window once it has a size.
	panel.reset_size()
	await panel.get_tree().process_frame
	panel.position = ((window.size - panel.size) * 0.5).round()

func _shop_label(text: String, colour: Color) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_color_override("font_color", colour)
	if _builder != null:
		var font := _builder.font_at(0)
		if font != null:
			lbl.add_theme_font_override("font", font)
		lbl.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[0])
	return lbl

func _do_buy(item_id: int, quantity: int = 1) -> void:
	var who := NetClient.current_character_name
	if who == "" or not NetClient.is_connected_to_server():
		_set_shop_status("Not connected.")
		return
	NetClient.shop_buy(who, item_id, maxi(1, quantity))

func _on_shop_list_result(entries: Array, error: String) -> void:
	if error != "":
		push_warning("HudPanels: shop catalogue refused: %s" % error)
		return
	for e in entries:
		_shop_prices[e.item_id] = e.price
	# The catalogue arrived after the grid was drawn, so redraw the open tab to
	# fold prices into the tooltips.
	if _windows.has("store") and _shop_selected >= 0 and _shop_selected < _shop_tabs.size():
		_fill_shop_grid((_shop_tabs[_shop_selected] as ShopReader.Tab).item_codes)

func _on_shop_buy_result(ok: bool, reason: String) -> void:
	if not _windows.has("store"):
		return
	if ok:
		_set_shop_status("Purchased.")
		# Refresh the purse and the bag (if open) from the server.
		var who := NetClient.current_character_name
		if who != "":
			NetClient.character_stats(who)
			NetClient.list_inventory(who)
	else:
		_set_shop_status("Could not buy: %s" % reason)

## A confirmation before selling from the bag: the item, its buy-back price
## and (for a stack) a quantity, then Sell sends it. The gold shown is the
## client's estimate from itemdata; the server's result carries the truth.
func _confirm_sell(slot: int, item_id: int, slot_qty: int) -> void:
	var window: HudWindow = _windows.get("store")
	if window == null:
		return
	_load_items()
	var item: ItemTableReader.Item = _items.get(item_id)
	if item == null:
		return
	var old := window.get_node_or_null("SellConfirm")
	if old != null:
		old.free()
	var unit: int = item.sell_price
	var max_qty: int = maxi(1, slot_qty)

	var panel := PanelContainer.new()
	panel.name = "SellConfirm"
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.07, 0.08, 0.98)
	style.border_color = Color(0.55, 0.45, 0.22)
	style.set_border_width_all(2)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(12)
	panel.add_theme_stylebox_override("panel", style)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)
	box.add_child(_shop_label("Sell %s?" % item.display_name(_object_names), Color(0.95, 0.9, 0.72)))
	if unit > 0 and max_qty > 1:
		box.add_child(_shop_label("%s gold each" % _grouped(unit), Color(0.86, 0.82, 0.7)))

	var qty_box := [1]
	var total_label := _shop_label("", Color(0.95, 0.85, 0.45))
	var refresh := func() -> void:
		total_label.text = "Get: %s gold" % _grouped(unit * qty_box[0]) if unit > 0 else ""

	if max_qty > 1:
		var qrow := HBoxContainer.new()
		qrow.add_theme_constant_override("separation", 8)
		qrow.alignment = BoxContainer.ALIGNMENT_CENTER
		box.add_child(qrow)
		var minus := Button.new()
		minus.text = "-"
		minus.custom_minimum_size = Vector2(30, 0)
		var qty_label := _shop_label("1", Color(0.96, 0.96, 0.96))
		qty_label.custom_minimum_size = Vector2(52, 0)
		var plus := Button.new()
		plus.text = "+"
		plus.custom_minimum_size = Vector2(30, 0)
		minus.pressed.connect(func() -> void:
			qty_box[0] = maxi(1, qty_box[0] - 1)
			qty_label.text = str(qty_box[0])
			refresh.call())
		plus.pressed.connect(func() -> void:
			qty_box[0] = mini(max_qty, qty_box[0] + 1)
			qty_label.text = str(qty_box[0])
			refresh.call())
		qrow.add_child(minus)
		qrow.add_child(qty_label)
		qrow.add_child(plus)
	box.add_child(total_label)
	refresh.call()

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(row)
	var sell := Button.new()
	sell.text = "Sell"
	sell.pressed.connect(func() -> void:
		var q: int = qty_box[0]
		panel.free()
		_do_sell(slot, q))
	row.add_child(sell)
	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.pressed.connect(func() -> void: panel.free())
	row.add_child(cancel)

	window.add_child(panel)
	panel.reset_size()
	await panel.get_tree().process_frame
	panel.position = ((window.size - panel.size) * 0.5).round()

func _do_sell(slot: int, quantity: int) -> void:
	var who := NetClient.current_character_name
	if who == "" or not NetClient.is_connected_to_server():
		_set_shop_status("Not connected.")
		return
	NetClient.sell_item(who, slot, maxi(1, quantity))

func _on_shop_sell_result(ok: bool, reason: String, gold_received: int) -> void:
	if not _windows.has("store"):
		return
	if ok:
		_set_shop_status("Sold for %s gold." % _grouped(gold_received))
		var who := NetClient.current_character_name
		if who != "":
			NetClient.character_stats(who)
			NetClient.list_inventory(who)
	else:
		_set_shop_status("Could not sell: %s" % reason)

## QA only: an item to buy in a render standing in for a click (a render
## cannot click a shop cell). Prefers the cheapest stackable good across the
## NPC's tabs (so the quantity stepper shows and a bulk buy is affordable),
## else the first good. Never used in real play.
func _qa_buy_item_id() -> int:
	_load_items()
	var stack_id := -1
	var stack_price := 1 << 62
	var first_id := -1
	for tab in _shop_tabs:
		for code in (tab as ShopReader.Tab).item_codes:
			var item: ItemTableReader.Item = _items_by_code.get(code)
			if item == null:
				continue
			if first_id < 0:
				first_id = item.id
			var price: int = _shop_prices.get(item.id, 1 << 62)
			if item.max_stack > 1 and price < stack_price:
				stack_price = price
				stack_id = item.id
	return stack_id if stack_id >= 0 else first_id

func qa_confirm_first_item() -> void:
	var id := _qa_buy_item_id()
	if id >= 0:
		_confirm_buy(id)

func qa_buy_first_item() -> void:
	var id := _qa_buy_item_id()
	if id >= 0:
		# A quantity, to exercise the bulk buy and stacking.
		_do_buy(id, 20)

## QA only: the first occupied inventory cell, a stand-in for clicking a bag
## item to sell it. Never used in real play.
func _qa_first_inventory_icon() -> TextureRect:
	var inv: HudWindow = _windows.get("inventory")
	if inv == null:
		return null
	var grid := inv.node("GDR_INVENTORY_LATTICE") as Control
	if grid == null:
		return null
	for cell in grid.get_children():
		var icon := cell.get_node_or_null("ItemIcon") as TextureRect
		if icon != null and icon.has_meta("inv_slot"):
			return icon
	return null

func qa_confirm_sell_first() -> void:
	var icon := _qa_first_inventory_icon()
	if icon != null:
		_confirm_sell(int(icon.get_meta("inv_slot")), int(icon.get_meta("inv_item_id")), int(icon.get_meta("inv_qty")))

func qa_sell_first(quantity: int) -> void:
	var icon := _qa_first_inventory_icon()
	if icon != null:
		_do_sell(int(icon.get_meta("inv_slot")), quantity)

# --- The NPC storage (warehouse) --------------------------------------------
#
# The authored warehouse window (ifstorageroom) shows the character's stored
# items in its 6x5 grid. Opening it puts the bag alongside: click a bag item to
# deposit it, click a stored item to withdraw it. Both moves go through the
# server (storage.Service), which shares the bag's stacking rules.

## Opens the warehouse for an NPC, with the bag beside it. Refills both from
## the server.
func open_storage(npc_name: String) -> void:
	var window := open("storage")
	if window == null:
		return
	window.set_title(npc_name)
	_wire_storage_money_button(window)
	window.show()
	window.move_to_front()
	var bag: HudWindow = open("inventory")
	if bag != null:
		var view := get_viewport_rect().size
		window.position = Vector2(view.x * 0.5 - window.size.x - 8.0, (view.y - window.size.y) * 0.5).round()
		bag.position = Vector2(view.x * 0.5 + 8.0, (view.y - bag.size.y) * 0.5).round()
		bag.move_to_front()
		window.move_to_front()
	if NetClient.is_connected_to_server():
		var who := NetClient.current_character_name
		if who != "":
			NetClient.list_storage(who)
			NetClient.list_inventory(who)
			NetClient.storage_gold(who, StorageNet.GOLD_QUERY, 0)

## Wires the warehouse's gold button (GDR_STORAGE_BTN_MONEY) to the gold
## dialog, once.
func _wire_storage_money_button(window: HudWindow) -> void:
	var btn := window.node("GDR_STORAGE_BTN_MONEY") as BaseButton
	if btn != null and not btn.pressed.is_connected(_open_gold_dialog):
		btn.pressed.connect(_open_gold_dialog)

## Fills the warehouse grid (GDR_STORAGE_LAT) with the stored items; each is
## clickable to withdraw.
func _fill_storage_grid(slots: Array) -> void:
	var window: HudWindow = _windows.get("storage")
	if window == null:
		return
	var grid := window.node("GDR_STORAGE_LAT") as Control
	if grid == null:
		return
	_load_items()
	for cell in grid.get_children():
		var icon0 := cell.get_node_or_null("ItemIcon") as TextureRect
		if icon0 != null:
			icon0.texture = null
			for m in ["wh_slot", "wh_item_id", "wh_qty"]:
				if icon0.has_meta(m):
					icon0.remove_meta(m)
		var count0 := cell.get_node_or_null("CountLabel") as Label
		if count0 != null:
			count0.text = ""
	var cells := grid.get_child_count()
	for entry in slots:
		var index: int = entry.slot_index
		if index < 0 or index >= cells:
			continue
		var cell := grid.get_child(index)
		var icon := cell.get_node_or_null("ItemIcon") as TextureRect
		if icon == null:
			continue
		var item: ItemTableReader.Item = _items.get(entry.item_id)
		icon.texture = _item_icon(entry.item_id)
		icon.tooltip_text = _item_tooltip(entry.item_id)
		icon.mouse_filter = Control.MOUSE_FILTER_STOP
		icon.set_meta("wh_slot", index)
		icon.set_meta("wh_item_id", entry.item_id)
		icon.set_meta("wh_qty", entry.quantity)
		if not icon.has_meta("wh_click_wired"):
			icon.set_meta("wh_click_wired", true)
			icon.gui_input.connect(func(ev: InputEvent) -> void: _on_storage_cell_input(ev, icon))
		var count_label := cell.get_node_or_null("CountLabel") as Label
		if count_label != null and entry.quantity > 1:
			count_label.text = str(entry.quantity)

func _on_storage_cell_input(event: InputEvent, icon: TextureRect) -> void:
	if not (event is InputEventMouseButton and (event as InputEventMouseButton).pressed \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT):
		return
	if icon.has_meta("wh_slot") and icon.has_meta("wh_item_id"):
		_confirm_withdraw(int(icon.get_meta("wh_slot")), int(icon.get_meta("wh_item_id")), int(icon.get_meta("wh_qty")))

func _confirm_deposit(bag_slot: int, item_id: int, held: int) -> void:
	_load_items()
	var item: ItemTableReader.Item = _items.get(item_id)
	var name: String = item.display_name(_object_names) if item != null else "item"
	_quantity_move_confirm("DepositConfirm", "Deposit %s?" % name, held, "Deposit",
		func(q: int) -> void: _do_deposit(bag_slot, q))

func _confirm_withdraw(warehouse_slot: int, item_id: int, held: int) -> void:
	_load_items()
	var item: ItemTableReader.Item = _items.get(item_id)
	var name: String = item.display_name(_object_names) if item != null else "item"
	_quantity_move_confirm("WithdrawConfirm", "Withdraw %s?" % name, held, "Withdraw",
		func(q: int) -> void: _do_withdraw(warehouse_slot, q))

## A quantity confirmation for a move (deposit/withdraw), built over whichever
## of the storage/bag windows is topmost. on_action gets the chosen quantity.
func _quantity_move_confirm(dialog_name: String, title: String, max_qty: int, action_label: String, on_action: Callable) -> void:
	var window: HudWindow = _windows.get("storage")
	if window == null:
		return
	var old := window.get_node_or_null(dialog_name)
	if old != null:
		old.free()
	var panel := PanelContainer.new()
	panel.name = dialog_name
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.07, 0.08, 0.98)
	style.border_color = Color(0.55, 0.45, 0.22)
	style.set_border_width_all(2)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(12)
	panel.add_theme_stylebox_override("panel", style)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)
	box.add_child(_shop_label(title, Color(0.95, 0.9, 0.72)))

	var qty_box := [1]
	var cap: int = maxi(1, max_qty)
	if cap > 1:
		var qrow := HBoxContainer.new()
		qrow.add_theme_constant_override("separation", 8)
		qrow.alignment = BoxContainer.ALIGNMENT_CENTER
		box.add_child(qrow)
		var minus := Button.new()
		minus.text = "-"
		minus.custom_minimum_size = Vector2(30, 0)
		var qty_label := _shop_label("1", Color(0.96, 0.96, 0.96))
		qty_label.custom_minimum_size = Vector2(52, 0)
		var plus := Button.new()
		plus.text = "+"
		plus.custom_minimum_size = Vector2(30, 0)
		minus.pressed.connect(func() -> void:
			qty_box[0] = maxi(1, qty_box[0] - 1)
			qty_label.text = str(qty_box[0]))
		plus.pressed.connect(func() -> void:
			qty_box[0] = mini(cap, qty_box[0] + 1)
			qty_label.text = str(qty_box[0]))
		qrow.add_child(minus)
		qrow.add_child(qty_label)
		qrow.add_child(plus)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(row)
	var act := Button.new()
	act.text = action_label
	act.pressed.connect(func() -> void:
		var q: int = qty_box[0]
		panel.free()
		on_action.call(q))
	row.add_child(act)
	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.pressed.connect(func() -> void: panel.free())
	row.add_child(cancel)

	window.add_child(panel)
	panel.reset_size()
	await panel.get_tree().process_frame
	panel.position = ((window.size - panel.size) * 0.5).round()

func _do_deposit(bag_slot: int, quantity: int) -> void:
	var who := NetClient.current_character_name
	if who != "" and NetClient.is_connected_to_server():
		NetClient.deposit_to_storage(who, bag_slot, maxi(1, quantity))

func _do_withdraw(warehouse_slot: int, quantity: int) -> void:
	var who := NetClient.current_character_name
	if who != "" and NetClient.is_connected_to_server():
		NetClient.withdraw_from_storage(who, warehouse_slot, maxi(1, quantity))

func _refresh_storage_and_bag() -> void:
	var who := NetClient.current_character_name
	if who != "" and NetClient.is_connected_to_server():
		NetClient.list_storage(who)
		NetClient.list_inventory(who)

func _on_storage_list_result(slots: Array, error: String) -> void:
	if error != "":
		push_warning("HudPanels: storage list refused: %s" % error)
		return
	_fill_storage_grid(slots)

func _on_storage_deposit_result(ok: bool, reason: String) -> void:
	if ok:
		_refresh_storage_and_bag()
	else:
		push_warning("HudPanels: deposit refused: %s" % reason)

func _on_storage_withdraw_result(ok: bool, reason: String) -> void:
	if ok:
		_refresh_storage_and_bag()
	else:
		push_warning("HudPanels: withdraw refused: %s" % reason)

# --- Warehouse gold ---------------------------------------------------------
var _storage_carried := 0
var _storage_stored := 0

func _on_storage_gold_result(ok: bool, reason: String, carried: int, stored: int) -> void:
	if not ok and reason != "":
		push_warning("HudPanels: warehouse gold: %s" % reason)
	_storage_carried = carried
	_storage_stored = stored
	_update_storage_gold_labels()

## Reflects the two balances in the warehouse window (its stored-gold line),
## the bag window (carried gold), and the open gold dialog if any.
func _update_storage_gold_labels() -> void:
	var window: HudWindow = _windows.get("storage")
	if window != null:
		var stored_label := window.node("GDR_STORAGE_STA_GOLD") as Label
		if stored_label != null:
			stored_label.text = _grouped(_storage_stored)
		var dialog_bal := window.get_node_or_null("GoldDialog/VB/GoldBal") as Label
		if dialog_bal != null:
			dialog_bal.text = "Carried: %s     Stored: %s" % [_grouped(_storage_carried), _grouped(_storage_stored)]
	# Keep the bag's gold line and cached stats in step with the purse.
	if _stats != null:
		_stats.gold = _storage_carried
	var inventory: HudWindow = _windows.get("inventory")
	if inventory != null:
		var carried_label := inventory.node("GDR_INVENTORY_STA_GOLD") as Label
		if carried_label != null:
			carried_label.text = _grouped(_storage_carried)

## The gold dialog: an amount to deposit into or withdraw from the warehouse.
## Stays open so several moves can be made; the balances line refreshes from
## each result.
func _open_gold_dialog() -> void:
	var window: HudWindow = _windows.get("storage")
	if window == null:
		return
	var old := window.get_node_or_null("GoldDialog")
	if old != null:
		old.free()
	var panel := PanelContainer.new()
	panel.name = "GoldDialog"
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.07, 0.08, 0.98)
	style.border_color = Color(0.55, 0.45, 0.22)
	style.set_border_width_all(2)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(12)
	panel.add_theme_stylebox_override("panel", style)
	var box := VBoxContainer.new()
	box.name = "VB"
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)
	box.add_child(_shop_label("Warehouse gold", Color(0.95, 0.9, 0.72)))
	var bal := _shop_label("Carried: %s     Stored: %s" % [_grouped(_storage_carried), _grouped(_storage_stored)], Color(0.95, 0.85, 0.45))
	bal.name = "GoldBal"
	box.add_child(bal)
	var amount := LineEdit.new()
	amount.name = "Amount"
	amount.placeholder_text = "amount"
	amount.alignment = HORIZONTAL_ALIGNMENT_CENTER
	amount.custom_minimum_size = Vector2(150, 0)
	if _builder != null:
		var font := _builder.font_at(0)
		if font != null:
			amount.add_theme_font_override("font", font)
		amount.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[0])
	box.add_child(amount)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(row)
	var deposit := Button.new()
	deposit.text = "Deposit"
	deposit.pressed.connect(func() -> void: _do_gold(StorageNet.GOLD_DEPOSIT, int(amount.text)))
	row.add_child(deposit)
	var withdraw := Button.new()
	withdraw.text = "Withdraw"
	withdraw.pressed.connect(func() -> void: _do_gold(StorageNet.GOLD_WITHDRAW, int(amount.text)))
	row.add_child(withdraw)
	var close := Button.new()
	close.text = "Close"
	close.pressed.connect(func() -> void: panel.free())
	row.add_child(close)

	window.add_child(panel)
	panel.reset_size()
	await panel.get_tree().process_frame
	panel.position = ((window.size - panel.size) * 0.5).round()

func _do_gold(op: int, amount: int) -> void:
	if amount <= 0:
		return
	var who := NetClient.current_character_name
	if who != "" and NetClient.is_connected_to_server():
		NetClient.storage_gold(who, op, amount)

## QA only: deposit/withdraw stand-ins for a render click.
func qa_deposit_first() -> void:
	var icon := _qa_first_inventory_icon()
	if icon != null:
		_confirm_deposit(int(icon.get_meta("inv_slot")), int(icon.get_meta("inv_item_id")), int(icon.get_meta("inv_qty")))

func qa_do_deposit_first(quantity: int) -> void:
	var icon := _qa_first_inventory_icon()
	if icon != null:
		_do_deposit(int(icon.get_meta("inv_slot")), quantity)

func qa_open_gold_dialog() -> void:
	_open_gold_dialog()

func qa_gold_deposit(amount: int) -> void:
	_do_gold(StorageNet.GOLD_DEPOSIT, amount)

## The live paper-doll texture (a SubViewport's), set by World3D whenever
## the dressed character changes. Shown in the equipment section's central
## column, between the two rows of worn slots.
var _paper_doll_texture: Texture2D = null

## The inventory bag's authored content width -- ifinventory's own frame is
## 176 wide, and the equipment paper doll docks flush to its right so the two
## authored windows read as the client's one fused inventory. Grounded in the
## DUCKROAD layout, not eyeballed.
const INVENTORY_CONTENT_WIDTH := 176.0
## The equipment section docked inside the inventory window (see open()).
var _inventory_eq_root: Control = null

func set_paper_doll_texture(texture: Texture2D) -> void:
	_paper_doll_texture = texture
	_place_paper_doll_docked()

## Draws the live 3D paper doll in the equipment section docked inside the
## inventory window, in the central column between its two worn-slot columns.
func _place_paper_doll_docked() -> void:
	if _paper_doll_texture == null or _inventory_eq_root == null:
		return
	var doll := _inventory_eq_root.get_node_or_null("PaperDoll") as TextureRect
	if doll == null:
		doll = TextureRect.new()
		doll.name = "PaperDoll"
		doll.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		doll.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		doll.mouse_filter = Control.MOUSE_FILTER_IGNORE
		# Between the equipment window's two slot columns (slots at x 5 and
		# x 141, 32 wide, over a 177-wide window): the central column x 40..138,
		# below the title bar to just above the avatar-skill strip.
		doll.position = Vector2(40, HudWindow.TITLE_BAR_HEIGHT + 4.0)
		doll.size = Vector2(98, 236)
		_inventory_eq_root.add_child(doll)
	doll.texture = _paper_doll_texture

## Connects the System window's buttons to the signals World3D acts on.
## Each button is looked up by the name the authored layout gives it
## (ifsystemwnd.txt); a button the operator's own layout does not carry --
## the user's DuckRoad build shows four, the stock layout five -- is simply
## skipped, so this works against either.
func _wire_system(window: HudWindow) -> void:
	var wiring := {
		"GDR_SYSTEM_BTN_OPTION": func(): system_option_requested.emit(),
		"GDR_SYSTEM_BTN_HELP": func(): system_help_requested.emit(),
		"GDR_SYSTEM_BTN_CAS_HELP": func(): system_help_requested.emit(),
		"GDR_SYSTEM_BTN_RESTART": func(): close("system"); system_restart_requested.emit(),
		"GDR_SYSTEM_BTN_QUIT": func(): system_exit_requested.emit(),
	}
	for control_name in wiring:
		var button := window.node(control_name) as BaseButton
		if button != null:
			button.pressed.connect(wiring[control_name])

func close(panel_id: String) -> void:
	var window: HudWindow = _windows.get(panel_id)
	if window != null:
		window.hide()

func toggle(panel_id: String) -> void:
	# Equipment is docked in the inventory window (see open()).
	if panel_id == "equipment":
		panel_id = "inventory"
	var window: HudWindow = _windows.get(panel_id)
	if window != null and window.visible:
		window.hide()
		return
	open(panel_id)

## True if any panel is currently on screen -- World3D uses this to decide
## whether Escape should close a window or fall through.
func any_open() -> bool:
	for id in _windows:
		if (_windows[id] as HudWindow).visible:
			return true
	return false

func close_topmost() -> bool:
	var best: HudWindow = null
	for id in _windows:
		var w: HudWindow = _windows[id]
		if w.visible and (best == null or w.get_index() > best.get_index()):
			best = w
	if best == null:
		return false
	best.hide()
	return true

func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key := event as InputEventKey
	if not key.pressed or key.echo or key.ctrl_pressed or key.alt_pressed:
		return
	if key.keycode == KEY_ESCAPE:
		# Escape closes the topmost open window; with nothing open it raises
		# the System menu, the way the original does.
		if not close_topmost():
			open("system")
		get_viewport().set_input_as_handled()
		return
	for panel_id in PANELS:
		var spec: Array = PANELS[panel_id]
		if spec[2] != 0 and key.keycode == spec[2]:
			toggle(panel_id)
			get_viewport().set_input_as_handled()
			return

# --- Filling panels from the server -------------------------------------
#
# Each panel asks NetClient for its data when opened. The replies arrive as
# signals, wired once in connect_net(), so a panel that is open when the
# data changes updates in place.

var _net_connected := false

## {item id -> ItemTableReader.Item}, read once from the player's own
## Media.pk2. Lets a slot show an item's real name and icon from the id the
## server sends, instead of the id itself.
var _items: Dictionary = {}
## The same items keyed by code name, for the shop (whose tables name goods by
## code, not id).
var _items_by_code: Dictionary = {}
var _items_loaded := false
## The object-name table (textdata_object.txt): resolves an item's name string
## id to its real English name, since itemdata's own name column is Korean for
## many consumables. See ItemTableReader.Item.display_name.
const OBJECT_NAME_TABLE_PATH := "server_dep\\silkroad\\textdata\\textdata_object.txt"
var _object_names: UiTextTable = null

func _load_items() -> void:
	if _items_loaded:
		return
	_items_loaded = true
	if _builder == null:
		return
	var archive := _builder.media_archive()
	if archive == null:
		return
	for path in ItemTableReader.TABLE_PATHS:
		var entry := ObjectLoader.find_file(archive, path)
		if entry != null:
			_items = ItemTableReader.parse(archive.read_file(entry), _items)
	for item in _items.values():
		_items_by_code[(item as ItemTableReader.Item).code_name] = item
	var names_entry := ObjectLoader.find_file(archive, OBJECT_NAME_TABLE_PATH)
	if names_entry != null:
		_object_names = UiTextTable.parse(archive.read_file(names_entry))
	print("HudPanels: %d item(s) resolvable by id" % _items.size())

## The icon for an item id, or null. Icons are ordinary .ddj textures, so
## the builder's own cache serves them.
func _item_icon(item_id: int) -> Texture2D:
	_load_items()
	var item: ItemTableReader.Item = _items.get(item_id)
	if item == null or item.icon_path == "" or _builder == null:
		return null
	return _builder.load_texture(item.icon_path)

## The multi-line hover tooltip for an item id -- its real stats -- or just
## the id when the item table does not know it.
func _item_tooltip(item_id: int) -> String:
	_load_items()
	var item: ItemTableReader.Item = _items.get(item_id)
	if item == null:
		return "Item %d" % item_id
	return "\n".join(PackedStringArray(item.tooltip_lines(_object_names)))

func _item_name(item_id: int) -> String:
	_load_items()
	var item: ItemTableReader.Item = _items.get(item_id)
	return item.display_name(_object_names) if item != null else ""

## Fills the inventory window's authored slot grid with the icons of what
## the character is carrying.
##
## This is the authored presentation rather than the plain list: the grid is
## GDR_INVENTORY_LATTICE, which UiBuilder already builds as one Control per
## cell, each with a named "ItemIcon" child.
func _fill_inventory_grid(slots: Array) -> void:
	var window: HudWindow = _windows.get("inventory")
	if window == null:
		return
	var grid := window.node("GDR_INVENTORY_LATTICE") as Control
	if grid == null:
		return
	for cell in grid.get_children():
		var icon := cell.get_node_or_null("ItemIcon") as TextureRect
		if icon != null:
			icon.texture = null
			for m in ["inv_slot", "inv_item_id", "inv_qty"]:
				if icon.has_meta(m):
					icon.remove_meta(m)
		var count := cell.get_node_or_null("CountLabel") as Label
		if count != null:
			count.text = ""
	var cells := grid.get_child_count()
	for entry in slots:
		var index := int(_first_field(entry, ["slot", "slot_index", "index"]) if _first_field(entry, ["slot", "slot_index", "index"]) != null else -1)
		if index < 0 or index >= cells:
			continue
		var cell := grid.get_child(index)
		var item_id = _first_field(entry, ["item_id", "id"])
		if item_id == null:
			continue
		var quantity = _first_field(entry, COUNT_FIELDS)
		var qty: int = int(quantity) if quantity != null else 1
		var icon := cell.get_node_or_null("ItemIcon") as TextureRect
		if icon != null:
			icon.texture = _item_icon(int(item_id))
			# A hover tooltip with the item's real stats -- name, attack,
			# durability, reinforce, requirement -- read straight off the
			# item table (ItemTableReader.Item.tooltip_lines). STOP so the
			# hover registers; the cell behind it still takes clicks.
			icon.tooltip_text = _item_tooltip(int(item_id))
			icon.mouse_filter = Control.MOUSE_FILTER_STOP
			# The slot's identity, so a click can sell it while a shop is open.
			icon.set_meta("inv_slot", index)
			icon.set_meta("inv_item_id", int(item_id))
			icon.set_meta("inv_qty", qty)
			if not icon.has_meta("inv_click_wired"):
				icon.set_meta("inv_click_wired", true)
				icon.gui_input.connect(func(ev: InputEvent) -> void: _on_inventory_cell_input(ev, icon))
		var count_label := cell.get_node_or_null("CountLabel") as Label
		if count_label != null and qty > 1:
			count_label.text = str(qty)

## A click on an inventory item, while an NPC service window is open: sell it
## (shop) or deposit it (storage). The bag is how the client moves items to a
## vendor or the warehouse.
func _on_inventory_cell_input(event: InputEvent, icon: TextureRect) -> void:
	if not (event is InputEventMouseButton and (event as InputEventMouseButton).pressed \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT):
		return
	if not (icon.has_meta("inv_slot") and icon.has_meta("inv_item_id")):
		return
	var slot := int(icon.get_meta("inv_slot"))
	var item_id := int(icon.get_meta("inv_item_id"))
	var qty := int(icon.get_meta("inv_qty"))
	var store: HudWindow = _windows.get("store")
	var storage_win: HudWindow = _windows.get("storage")
	if store != null and store.visible:
		_confirm_sell(slot, item_id, qty)
	elif storage_win != null and storage_win.visible:
		_confirm_deposit(slot, item_id, qty)

## QA only: fills the bag grid with sample items so a render can show a
## populated inventory without needing kills or a seeded server. The item IDs
## are real (the private-server consumables the loot table drops), so their
## icons resolve. Never used in real play -- driven by SRREVAMP_QA_FAKEITEMS.
func qa_fill_sample_inventory() -> void:
	var window: HudWindow = _windows.get("inventory")
	if window == null:
		return
	var grid := window.node("GDR_INVENTORY_LATTICE") as Control
	if grid == null:
		return
	var ids := [4, 11, 6, 13, 4, 11, 4, 11, 6, 13, 4, 11]
	var qtys := [50, 50, 25, 25, 999, 720, 120, 88, 40, 15, 200, 333]
	var cells := grid.get_child_count()
	for i in range(mini(ids.size(), cells)):
		var cell := grid.get_child(i)
		var icon := cell.get_node_or_null("ItemIcon") as TextureRect
		if icon != null:
			icon.texture = _item_icon(ids[i])
		var count := cell.get_node_or_null("CountLabel") as Label
		if count != null and qtys[i] > 1:
			count.text = str(qtys[i])

## The worn items as last reported, so opening the equipment window fills
## its slots even if the list arrived while it was closed.
var _equipped_items: Array = []

## China's masteries, read once from the player's own Media.pk2.
var _masteries: Array = []
var _masteries_loaded := false

func _load_masteries() -> void:
	if _masteries_loaded:
		return
	_masteries_loaded = true
	if _builder == null:
		return
	var archive := _builder.media_archive()
	if archive == null:
		return
	var entry := ObjectLoader.find_file(archive, MasteryReader.TABLE_PATH)
	if entry != null:
		_masteries = MasteryReader.parse_china(archive.read_file(entry))
	print("HudPanels: %d China mastery(ies) read" % _masteries.size())

## Which tab of the skill board is showing (0 = Weapon, 1 = Force for China) and
## which mastery within it -- the real window's two rows of tabs.
var _skill_active_tab := 0
var _skill_active_mastery := 0

## The real skill tree, read once from the player's own Media.pk2: the groups
## (the rows of a mastery's board) and the skills in each (the columns). See
## SkillDataReader -- recovered from skillgroup.txt + skilldata_*.txt.
var _skill_groups: Dictionary = {}   ## mastery id -> Array[SkillDataReader.SkillGroup]
var _skill_grid: Dictionary = {}     ## "<mastery>:<row>" -> Array[SkillDataReader.BaseSkill]
var _skill_catalog_loaded := false

## The player's skill state as the server reports it: skill points, and each
## mastery's trained level. Empty until the server sends it (set_skill_state),
## so a fresh window shows every skill greyed -- as the real one does.
var _skill_points: int = 0
var _skill_mastery_levels: Dictionary = {}   ## mastery id -> level
## The character level the mastery-total cap (3 x level) is shown against; 0
## until the server reports it (set_skill_state).
var _skill_char_level: int = 0
## The unique skill ids the character has learned (a set), from the server --
## a learned skill shows its level badge instead of a "+" learn button.
var _skill_known: Dictionary = {}

## The mastery-total cap per character level: the sum of a character's mastery
## levels can reach 3 x its level. Grounded -- retail 80-cap total = 240 = 3x80;
## matches the server's MasteryTotalCapPerLevel. The pserver's 440 is a mod.
const MASTERY_TOTAL_CAP_PER_LEVEL := 3

## Skill-board geometry inside the CIFSkillBoard area (GDR_SKILL_BOARD). The grid
## metrics are the real client's, decompiled from CIFSkillGroup::SetGroup: eight
## columns pitched 36px from x=37, 32px cells in a 56px-tall row bar. The tab and
## header bands are chrome the EXE draws, sized to match the original's window.
const SKILL_TAB_H := 21.0
const SKILL_HEADER_Y := 46.0
const SKILL_HEADER_H := 30.0
const SKILL_ROW_H := 56.0
const SKILL_CELL := 32.0
const SKILL_COL_X0 := 37.0
const SKILL_COL_PITCH := 36.0
const SKILL_BOARD_H := 270.0
# The skill cell's own parts, from ifskill_slot.txt (relative to the cell):
# the 32x32 icon (GDR_STMS_SLOT_SKILL "0,0,32,32"), the 32x20 "+" level-up
# button beneath it (GDR_STMS_BTN_LEVELUP "0,32,32,20"), and the level badge
# over the icon's lower-right (GDR_STMS_LEVEL_BOARD at 19,17 -> skl_level_tab).
const SKILL_LEVELUP_H := 20.0
const SKILL_CELL_CONTENT_H := 52.0   # icon (32) + "+" strip (20)
const SKILL_BADGE_POS := Vector2(19, 17)

## Reads the skill tree once: the groups (skillgroup.txt) and the skills in each
## (skilldata_*.txt), kept to the player's own masteries. Lazy -- the first time
## the skill window opens -- because it scans a few MB of archive.
func _load_skill_catalog() -> void:
	if _skill_catalog_loaded:
		return
	_skill_catalog_loaded = true
	if _builder == null:
		return
	var archive := _builder.media_archive()
	if archive == null:
		return
	var gentry := ObjectLoader.find_file(archive, SkillDataReader.GROUP_TABLE)
	if gentry != null:
		_skill_groups = SkillDataReader.parse_groups(archive.read_file(gentry))
	_load_masteries()
	var ids := PackedInt32Array()
	for entry in _masteries:
		ids.append((entry as MasteryReader.Mastery).id)
	var datas: Array = []
	for path in SkillDataReader.SKILL_TABLES:
		var e := ObjectLoader.find_file(archive, path)
		if e != null:
			datas.append(archive.read_file(e))
	_skill_grid = SkillDataReader.parse_skills(datas, ids)
	print("HudPanels: skill catalog -- %d masteries with groups, %d group-rows of skills"
		% [_skill_groups.size(), _skill_grid.size()])
	if OS.has_environment("SRREVAMP_QA_PANELS"):
		var dbg := ""
		for r in range(9):
			var k := "257:%d" % r
			if _skill_grid.has(k):
				dbg += " row%d=%d" % [r, (_skill_grid[k] as Array).size()]
		print("HudPanels: Bicheon(257) rows:%s" % dbg)

## The server's skill state -- skill points and per-mastery levels. Refills the
## open window so learnable skills light up (their real icon instead of the grey
## disable book) and the totals show.
func set_skill_state(skill_points: int, mastery_levels: Dictionary, char_level: int = 0, known: Dictionary = {}) -> void:
	_skill_points = skill_points
	_skill_mastery_levels = mastery_levels.duplicate()
	_skill_known = known.duplicate()
	if char_level > 0:
		_skill_char_level = char_level
	_refill_skill()

## The server's OpSkillState arrived -- apply points, mastery levels, learned
## skills and the character level (for the 3 x level cap).
func _apply_skill_state(state: SkillNet.SkillState) -> void:
	set_skill_state(state.skill_points, state.mastery_levels, state.level, state.known_skills)

## After a mastery is raised, re-read the state so the totals and the lit/greyed
## skills refresh.
func _on_raise_mastery_result(result: SkillNet.RaiseMasteryResult) -> void:
	if result.error != "":
		return
	var who := NetClient.current_character_name
	if who != "":
		NetClient.skill_state(who)

## A mastery's trained level -- the server's, or a QA override for demoing the
## window lit up (SRREVAMP_QA_MASTERY applies one level to every mastery). The
## board greys any skill whose required mastery level is above this (the real
## availability rule, recovered from CIFSkillSlot).
func _mastery_level(mastery_id: int) -> int:
	var lvl: int = int(_skill_mastery_levels.get(mastery_id, 0))
	if OS.has_environment("SRREVAMP_QA_MASTERY"):
		lvl = maxi(lvl, int(OS.get_environment("SRREVAMP_QA_MASTERY")))
	return lvl

## Builds the skill window's board the way the real client's CIFSkillBoard does:
## the Weapon/Force tabs, then the masteries within the active tab
## (Bicheon/Heuksal/Pacheon...), then the selected mastery's own board -- its
## icon, name and level and a scrolling grid of one row per skill group, each
## holding that group's skills as cells. Structure and metrics are recovered
## (resinfo + decompiled CIFSkillBoard/Group/Slot); levels are the server's to
## fill, so at mastery level 0 the skills show greyed (skl_mastery_disable),
## exactly as a fresh character's window does.
func _fill_skill_masteries(window: HudWindow) -> void:
	_load_masteries()
	_load_skill_catalog()
	var board := window.node("GDR_SKILL_BOARD") as Control
	if board == null:
		return
	board.clip_contents = true

	# Group the masteries by their tab (Weapon/Force), in first-seen order.
	var tab_keys: Array = []
	var tabs: Dictionary = {}
	for entry in _masteries:
		var m: MasteryReader.Mastery = entry
		if not tabs.has(m.tab):
			tabs[m.tab] = {"code": m.tab_name_code, "masteries": []}
			tab_keys.append(m.tab)
		tabs[m.tab]["masteries"].append(m)
	if tab_keys.is_empty():
		return
	_skill_active_tab = clampi(_skill_active_tab, 0, tab_keys.size() - 1)
	var masteries: Array = tabs[tab_keys[_skill_active_tab]]["masteries"]
	_skill_active_mastery = clampi(_skill_active_mastery, 0, maxi(masteries.size() - 1, 0))

	# Rebuild the board fresh each fill (the selected tab/mastery may change).
	for child in board.get_children():
		if str(child.name).begins_with("Skill"):
			child.queue_free()

	_add_skill_board_bg(board)

	# Two rows of tabs: Weapon/Force, then the masteries within the active one.
	var top := _skill_tab_strip(board, 2.0, "SkillTopTabs")
	for i in range(tab_keys.size()):
		var group: Dictionary = tabs[tab_keys[i]]
		_add_skill_tab(top, _resolve_ui(group["code"], _skill_tab_fallback(tab_keys[i])),
			i == _skill_active_tab, _on_skill_tab.bind(i))

	var sub := _skill_tab_strip(board, 2.0 + SKILL_TAB_H + 2.0, "SkillMasteryTabs")
	for i in range(masteries.size()):
		var mm: MasteryReader.Mastery = masteries[i]
		_add_skill_tab(sub, mm.display_name(_text_table()), i == _skill_active_mastery,
			_on_skill_mastery_tab.bind(i))

	# The selected mastery's board -- header + grid of group rows.
	if _skill_active_mastery < masteries.size():
		_build_mastery_board(board, masteries[_skill_active_mastery] as MasteryReader.Mastery)

	# Skill points and total mastery level (with the 3 x level cap once the
	# server has reported the character's level), from the server's state.
	_set_label(window, "GDR_SKILL_TEXT_SP_NUM", str(_skill_points))
	# The real server total (a QA lighting override must not pollute it).
	var total := 0
	for lvl in _skill_mastery_levels.values():
		total += int(lvl)
	var total_text := str(total)
	if _skill_char_level > 0:
		total_text = "%d / %d" % [total, MASTERY_TOTAL_CAP_PER_LEVEL * _skill_char_level]
	_set_label(window, "GDR_SKILL_TEXT_TOTAL_MASTERYLEV_NUM", total_text)

## A dark backing so the world does not show through the board (the layout names
## no tile for the CIFSkillBoard area -- the EXE draws its own).
func _add_skill_board_bg(board: Control) -> void:
	var bg := TextureRect.new()
	bg.name = "SkillBoardBg"
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_TILE
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _builder != null:
		bg.texture = _builder.load_texture("interface\\ifcommon\\bg_tile\\com_bg_tile_d.ddj")
	if bg.texture == null:
		bg.queue_free()
		var flat := ColorRect.new()
		flat.name = "SkillBoardBg"
		flat.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		flat.color = Color(0.05, 0.05, 0.06, 1.0)
		flat.mouse_filter = Control.MOUSE_FILTER_IGNORE
		board.add_child(flat)
	else:
		board.add_child(bg)

func _skill_tab_strip(board: Control, y: float, strip_name: String) -> HBoxContainer:
	var strip := HBoxContainer.new()
	strip.name = strip_name
	strip.position = Vector2(6, y)
	strip.add_theme_constant_override("separation", 3)
	board.add_child(strip)
	return strip

func _add_skill_tab(strip: HBoxContainer, text: String, active: bool, on_press: Callable) -> void:
	var btn := Button.new()
	btn.text = text
	btn.toggle_mode = true
	btn.button_pressed = active
	btn.focus_mode = Control.FOCUS_NONE
	btn.custom_minimum_size = Vector2(80, SKILL_TAB_H)
	_style_skill_tab(btn)
	btn.pressed.connect(on_press)
	strip.add_child(btn)

## The selected mastery's board: its icon and name and level at the top, then a
## scrolling grid of one row per skill group.
func _build_mastery_board(board: Control, mastery: MasteryReader.Mastery) -> void:
	var host := Control.new()
	host.name = "SkillMasteryBoard"
	host.position = Vector2(0, SKILL_HEADER_Y)
	host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	board.add_child(host)

	# Header: mastery icon (left), name, and mastery level.
	var icon := TextureRect.new()
	icon.position = Vector2(9, 0)
	icon.size = Vector2(32, 32)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _builder != null:
		icon.texture = _builder.load_texture(mastery.icon_path)
	host.add_child(icon)

	var name_lbl := Label.new()
	name_lbl.text = mastery.display_name(_text_table())
	name_lbl.position = Vector2(48, 6)
	name_lbl.size = Vector2(100, 20)
	_style_skill_label(name_lbl)
	host.add_child(name_lbl)

	# The mastery LEVEL UP button (skl_mastery_levelup in ifskillboard): spends
	# skill points to raise this mastery a level, which unlocks more skills.
	var levelup := Button.new()
	levelup.text = _resolve_ui("UIIT_CTL_SKILL_MASTERY_LEVELUP", "LEVEL UP")
	levelup.position = Vector2(150, 3)
	levelup.custom_minimum_size = Vector2(80, 22)
	levelup.focus_mode = Control.FOCUS_NONE
	_style_skill_tab(levelup)
	levelup.pressed.connect(_on_mastery_levelup.bind(mastery.id))
	# Grey it and say why when the mastery can't be raised: a single mastery
	# can't pass the character's level, and the total is capped at 3 x level
	# (both server-enforced -- this just explains it before the click).
	var real_level := int(_skill_mastery_levels.get(mastery.id, 0))
	var total_now := 0
	for lvl in _skill_mastery_levels.values():
		total_now += int(lvl)
	var reason := ""
	if _skill_char_level > 0 and real_level >= _skill_char_level:
		reason = "This mastery is at your character-level cap (Lv %d). Level up your character to raise it." % _skill_char_level
	elif _skill_char_level > 0 and total_now >= MASTERY_TOTAL_CAP_PER_LEVEL * _skill_char_level:
		reason = "Total mastery cap reached (%d / %d)." % [total_now, MASTERY_TOTAL_CAP_PER_LEVEL * _skill_char_level]
	elif _skill_points <= 0:
		reason = "Not enough skill points."
	if reason != "":
		levelup.disabled = true
		levelup.tooltip_text = reason
	host.add_child(levelup)

	var lvl_lbl := Label.new()
	lvl_lbl.text = "Lv %d" % _mastery_level(mastery.id)
	lvl_lbl.position = Vector2(238, 6)
	lvl_lbl.size = Vector2(100, 20)
	lvl_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_style_skill_label(lvl_lbl)
	host.add_child(lvl_lbl)

	# The scrolling grid of group rows.
	var board_h: float = board.size.y if board.size.y > 0.0 else SKILL_BOARD_H
	var scroll := ScrollContainer.new()
	scroll.position = Vector2(4, SKILL_HEADER_H)
	scroll.size = Vector2(343, maxf(board_h - SKILL_HEADER_Y - SKILL_HEADER_H, SKILL_ROW_H))
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	host.add_child(scroll)
	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 0)
	rows.custom_minimum_size = Vector2(325, 0)
	scroll.add_child(rows)

	var groups: Array = _skill_groups.get(mastery.id, [])
	if groups.is_empty():
		var none := Label.new()
		none.text = "No skills for this mastery in the archive."
		_style_skill_label(none)
		rows.add_child(none)
		return
	for g in groups:
		_build_group_row(rows, mastery, g as SkillDataReader.SkillGroup)

## One group's row: the bar background, the group's pack icon at the left, and
## its skills in columns -- an unavailable skill greyed (skl_mastery_disable),
## empty columns filled (skl_mastery_nothing), exactly as CIFSkillGroup lays it.
## The mastery level is 0 until the server tracks it, so every skill is greyed.
func _build_group_row(host: Control, mastery: MasteryReader.Mastery, group: SkillDataReader.SkillGroup) -> void:
	var row := Control.new()
	row.custom_minimum_size = Vector2(325, SKILL_ROW_H)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	host.add_child(row)

	var bar := TextureRect.new()
	bar.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bar.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bar.stretch_mode = TextureRect.STRETCH_SCALE
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _builder != null:
		bar.texture = _builder.load_texture("interface\\skill\\skl_mastery_bar.ddj")
	row.add_child(bar)

	var pack := TextureRect.new()
	pack.position = Vector2(6, 8)
	pack.size = Vector2(24, 24)
	pack.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	pack.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	pack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pack.texture = _load_skill_icon(group.icon_path)
	pack.tooltip_text = _resolve_ui(group.name_code, "")
	row.add_child(pack)

	var skills: Array = _skill_grid.get("%d:%d" % [mastery.id, group.row], [])
	var by_col: Dictionary = {}
	for s in skills:
		by_col[(s as SkillDataReader.BaseSkill).column] = s
	var mastery_level := _mastery_level(mastery.id)
	var disable_tex: Texture2D = _builder.load_texture("interface\\skill\\skl_mastery_disable.ddj") if _builder != null else null
	var nothing_tex: Texture2D = _builder.load_texture("interface\\skill\\skl_mastery_nothing.ddj") if _builder != null else null
	var levelup_tex: Texture2D = _builder.load_texture("interface\\skill\\skl_button_add.ddj") if _builder != null else null
	var badge_tex: Texture2D = _builder.load_texture("interface\\skill\\skl_level_tab.ddj") if _builder != null else null
	for col in range(SkillDataReader.COLUMNS):
		# The cell is the 32x32 icon with the 32x20 "+" strip beneath it, centred
		# in the bar row (ifskill_slot.txt geometry).
		var cell := Control.new()
		cell.position = Vector2(SKILL_COL_X0 + col * SKILL_COL_PITCH, (SKILL_ROW_H - SKILL_CELL_CONTENT_H) / 2.0)
		cell.size = Vector2(SKILL_CELL, SKILL_CELL_CONTENT_H)
		cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(cell)

		var icon := TextureRect.new()
		icon.position = Vector2.ZERO
		icon.size = Vector2(SKILL_CELL, SKILL_CELL)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		cell.add_child(icon)

		if not by_col.has(col):
			icon.texture = nothing_tex
			icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
			continue

		var s: SkillDataReader.BaseSkill = by_col[col]
		var learned := _skill_learned_level(s)
		var available := s.min_req_mastery_level > 0 and mastery_level >= s.min_req_mastery_level
		if learned > 0 or available:
			icon.texture = _load_skill_icon(s.icon_path)
		elif disable_tex != null:
			icon.texture = disable_tex   # the real "locked" book
		else:
			icon.texture = _load_skill_icon(s.icon_path)
			icon.modulate = Color(0.45, 0.45, 0.45, 0.85)
		icon.mouse_filter = Control.MOUSE_FILTER_PASS
		icon.tooltip_text = _skill_cell_tooltip(s, learned)

		# A learned skill shows its level badge over the icon's lower-right, and
		# clicking it casts that skill (World3D picks the target and animates).
		if learned > 0 and badge_tex != null:
			_add_level_badge(cell, badge_tex, learned)
		if learned > 0:
			var cast_id: int = s.level_ids[learned - 1]
			var cast_code: String = s.basic_code
			var cast_icon: Texture2D = icon.texture
			icon.gui_input.connect(func(ev: InputEvent) -> void:
				if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
					skill_assign_requested.emit(cast_id, cast_code, cast_icon))

		# The "+" appears when the next level is within the current mastery level;
		# the server enforces the SP cost (refdata ReqLearnSP) and refunds on fail.
		var next_level := learned + 1
		var can_learn := next_level <= s.max_level and next_level <= s.level_reqs.size() \
			and mastery_level >= s.level_reqs[next_level - 1] and s.level_ids[next_level - 1] > 0
		if can_learn and levelup_tex != null:
			var add_btn := TextureButton.new()
			add_btn.texture_normal = levelup_tex
			add_btn.position = Vector2(0, SKILL_CELL)
			add_btn.size = Vector2(SKILL_CELL, SKILL_LEVELUP_H)
			add_btn.ignore_texture_size = true
			add_btn.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
			add_btn.mouse_filter = Control.MOUSE_FILTER_STOP
			var target_id: int = s.level_ids[next_level - 1]
			add_btn.pressed.connect(func(): _on_skill_learn(target_id))
			add_btn.tooltip_text = "Learn %s Lv %d" % [s.display_name(_text_table()), next_level]
			cell.add_child(add_btn)

## The highest contiguous level of a skill the character has learned (0 = not
## learned). Learning is sequential, so this is how many of the skill's levels
## from level 1 up are in the server's known-skills set.
func _skill_learned_level(s: SkillDataReader.BaseSkill) -> int:
	# QA only: pretend the first N levels of every skill are learned, so a render
	# can show the learned badge + the next level's "+" without a live server.
	if OS.has_environment("SRREVAMP_QA_LEARNED"):
		return mini(int(OS.get_environment("SRREVAMP_QA_LEARNED")), s.max_level)
	var lvl := 0
	for i in range(s.level_ids.size()):
		var id := s.level_ids[i]
		if id > 0 and _skill_known.has(id):
			lvl = i + 1
		else:
			break
	return lvl

## The cell hover text -- an authentic skill tooltip built from the client's own
## skilldata: name + level, the description, real cast stats (MP, cast time,
## cooldown, range), and the next level's SP/mastery requirement. All grounded
## (see the skilldata-columns note); no invented numbers.
func _skill_cell_tooltip(s: SkillDataReader.BaseSkill, learned: int) -> String:
	var names := _text_table()
	var nm := s.display_name(names)
	var lines := PackedStringArray()
	if learned >= s.max_level and s.max_level > 0:
		lines.append("%s (Lv %d, mastered)" % [nm, learned])
	elif learned > 0:
		lines.append("%s (Lv %d/%d)" % [nm, learned, s.max_level])
	else:
		lines.append(nm)
	var desc := s.description(names)
	if desc != "":
		lines.append(desc)
	# Real cast stats for the shown level (learned level, else level 1).
	var shown: int = learned if learned > 0 else 1
	var stats := PackedStringArray()
	var mp: int = s.level_mp[shown - 1] if shown - 1 < s.level_mp.size() else 0
	if mp > 0:
		stats.append("MP %d" % mp)
	if s.cast_time_ms > 0:
		stats.append("Cast %.2fs" % (s.cast_time_ms / 1000.0))
	if s.cooldown_ms > 0:
		stats.append("Cooldown %.1fs" % (s.cooldown_ms / 1000.0))
	var rng: String = "Melee" if s.range_val == 0 else ("Range %d" % s.range_val)
	stats.append(rng)
	if not stats.is_empty():
		lines.append(" · ".join(stats))
	# The next level's real learn cost, for the ADD button.
	if learned < s.max_level:
		var nxt: int = learned + 1
		var sp: int = s.level_sp[nxt - 1] if nxt - 1 < s.level_sp.size() else 0
		var req: int = s.level_reqs[nxt - 1] if nxt - 1 < s.level_reqs.size() else s.min_req_mastery_level
		lines.append("Learn Lv %d: %d SP (mastery Lv %d)" % [nxt, sp, req])
	return "\n".join(lines)

## Draws the learned-level badge (skl_level_tab) over the icon's lower-right,
## with the level number on it (ifskill_slot.txt GDR_STMS_LEVEL_BOARD at 19,17).
func _add_level_badge(cell: Control, badge_tex: Texture2D, learned: int) -> void:
	var badge := TextureRect.new()
	badge.texture = badge_tex
	badge.position = SKILL_BADGE_POS
	badge.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	badge.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cell.add_child(badge)
	var num := Label.new()
	num.text = str(learned)
	num.position = SKILL_BADGE_POS
	num.size = Vector2(13, 12)
	num.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	num.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	num.add_theme_font_size_override("font_size", 9)
	num.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cell.add_child(num)

## The "+" on a skill cell was pressed -- learn (or level up) that skill. The
## server validates the mastery requirement and SP cost; learn_skill_result
## comes back and we re-read the state to repaint the board.
func _on_skill_learn(skill_id: int) -> void:
	var who := NetClient.current_character_name
	if who != "":
		NetClient.learn_skill(who, skill_id)

## A learn succeeded (or failed) -- re-read the skill state so a newly learned
## skill shows its badge and the next level's "+" (or SP is restored on fail).
func _on_learn_skill_result(_ok: bool, _reason: String) -> void:
	var window: HudWindow = _windows.get("skill")
	if window == null or not window.visible:
		return
	var who := NetClient.current_character_name
	if who != "":
		NetClient.skill_state(who)

## Loads a skillgroup/skilldata icon. Those tables name their icons without the
## `icon\` root the archive stores them under (unlike the mastery table), so it
## is prepended.
func _load_skill_icon(path: String) -> Texture2D:
	if _builder == null or path == "":
		return null
	var full := path if path.to_lower().begins_with("icon\\") else "icon\\" + path
	return _builder.load_texture(full)

func _on_skill_tab(index: int) -> void:
	if index != _skill_active_tab:
		_skill_active_tab = index
		_skill_active_mastery = 0
	_refill_skill()

func _on_skill_mastery_tab(index: int) -> void:
	_skill_active_mastery = index
	_refill_skill()

func _refill_skill() -> void:
	var window: HudWindow = _windows.get("skill")
	if window != null:
		_fill_skill_masteries(window)

## The mastery LEVEL UP button was pressed -- ask the server to spend skill
## points raising it. The result comes back as raise_mastery_result, which
## re-reads the state and refreshes the window.
func _on_mastery_levelup(mastery_id: int) -> void:
	var who := NetClient.current_character_name
	if who != "":
		NetClient.raise_mastery(who, mastery_id)

## After an attack (a kill grants skill points), re-read the skill state so the
## open window's "Skill point" total stays current.
func _on_attack_refresh_skill(_result) -> void:
	var window: HudWindow = _windows.get("skill")
	if window == null or not window.visible:
		return
	var who := NetClient.current_character_name
	if who != "":
		NetClient.skill_state(who)

## Titles a tab from its own name code, falling back to the plain English when
## the archive has no text for the token.
func _skill_tab_fallback(tab: int) -> String:
	return "Weapon Skill" if tab == MasteryReader.TAB_WEAPON else "Force Skill"

func _resolve_ui(token: String, fallback: String) -> String:
	if token == "" or token == "xxx" or _text_table() == null:
		return fallback
	var resolved := _text_table().get_text(token)
	return resolved if resolved != "" and resolved != token else fallback

func _style_skill_label(label: Label) -> void:
	label.add_theme_color_override("font_color", ROW_TEXT_COLOUR)
	if _builder != null:
		var font := _builder.font_at(0)
		if font != null:
			label.add_theme_font_override("font", font)
		label.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[0])

func _style_skill_tab(btn: Button) -> void:
	btn.add_theme_color_override("font_color", Color(0.93, 0.87, 0.70))
	btn.add_theme_color_override("font_pressed_color", Color(1, 0.95, 0.75))
	if _builder != null:
		var font := _builder.font_at(0)
		if font != null:
			btn.add_theme_font_override("font", font)
		btn.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[0])

## The UI text table, for resolving a mastery's own name where the archive
## has it. The builder holds it.
func _text_table() -> UiTextTable:
	return _builder.text_table() if _builder != null else null

## The base of the equipment window's slot control names: a worn slot's
## index i is drawn in GDR_EQUIPMENT_SLOT_(100 + i). Anchored to the user's
## own equipment window -- the weapon (slot 6) sits in SLOT_106 at the
## top-left and the shield (slot 7) in SLOT_107 at the top-right, exactly
## where the screenshot shows them -- so the rest of the +index run
## (helm 0, mail 1, shoulderguard 2, gauntlet 3, pants 4, boots 5) follows.
const EQUIPMENT_SLOT_BASE := 100

## The empty-slot silhouette each worn slot draws when nothing is in it. These
## are real client art (interface\equipment\equip_slot_*.ddj, named in
## sro_client.exe) that the CIFSlotWithHelp control has no `DDJ` for in the
## layout -- the EXE supplies them per slot, the same way it hardcodes the
## close button's default. The slot index -> type mapping is the game's own
## equip-slot order, confirmed against the starter kit the server gives
## (slot 1=mail, 4=pants, 5=boots, 6=weapon). Keyed by slot index i, drawn in
## GDR_EQUIPMENT_SLOT_(100+i).
const EQUIP_SLOT_TEXTURES := {
	0: "interface\\equipment\\equip_slot_helm.ddj",
	1: "interface\\equipment\\equip_slot_mail.ddj",
	2: "interface\\equipment\\equip_slot_shoulderguard.ddj",
	3: "interface\\equipment\\equip_slot_gauntlet.ddj",
	4: "interface\\equipment\\equip_slot_pants.ddj",
	5: "interface\\equipment\\equip_slot_boots.ddj",
	6: "interface\\equipment\\equip_slot_weapon.ddj",
	7: "interface\\equipment\\equip_slot_shield.ddj",
	8: "interface\\equipment\\equip_slot_earring.ddj",
	9: "interface\\equipment\\equip_slot_necklace.ddj",
	10: "interface\\equipment\\equip_slot_l_ring.ddj",
	11: "interface\\equipment\\equip_slot_r_ring.ddj",
	12: "interface\\equipment\\equip_slot_specialdress.ddj",
}

## Draws each worn slot's empty silhouette behind its item icon. A filled
## slot's icon covers it; an empty slot shows the silhouette -- which is what
## makes the paper doll read as the real equipment panel rather than bare
## squares on black.
func _apply_equipment_slot_backgrounds() -> void:
	var window: HudWindow = _windows.get("inventory")
	if window == null or _builder == null:
		return
	for i in EQUIP_SLOT_TEXTURES:
		var slot := window.node("GDR_EQUIPMENT_SLOT_%d" % (EQUIPMENT_SLOT_BASE + i)) as Control
		if slot == null:
			continue
		var bg := slot.get_node_or_null("EmptySlotBg") as TextureRect
		if bg == null:
			bg = TextureRect.new()
			bg.name = "EmptySlotBg"
			bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
			slot.add_child(bg)
			slot.move_child(bg, 0) # behind the ItemIcon
		bg.texture = _builder.load_texture(EQUIP_SLOT_TEXTURES[i])

func _fill_equipment_slots(items: Array) -> void:
	# Equipment is docked inside the inventory window (see open()); its slots
	# hang under that window's panel_root, so node() finds them there.
	var window: HudWindow = _windows.get("inventory")
	if window == null:
		return
	# Clear first, so an unequip empties its slot.
	for i in range(17):
		var slot := window.node("GDR_EQUIPMENT_SLOT_%d" % (EQUIPMENT_SLOT_BASE + i)) as Control
		if slot != null:
			var icon := slot.get_node_or_null("ItemIcon") as TextureRect
			if icon != null:
				icon.texture = null
	for entry in items:
		var slot_index = _first_field(entry, ["slot", "slot_index", "index"])
		var item_id = _first_field(entry, ["item_id", "id"])
		if slot_index == null or item_id == null:
			continue
		var slot := window.node("GDR_EQUIPMENT_SLOT_%d" % (EQUIPMENT_SLOT_BASE + int(slot_index))) as Control
		if slot == null:
			continue
		var icon := slot.get_node_or_null("ItemIcon") as TextureRect
		if icon != null:
			icon.texture = _item_icon(int(item_id))
			icon.tooltip_text = _item_tooltip(int(item_id))
			icon.mouse_filter = Control.MOUSE_FILTER_STOP

func connect_net() -> void:
	if _net_connected:
		return
	_net_connected = true
	# The inventory's authored presentation is its lattice grid
	# (GDR_INVENTORY_LATTICE), filled with item icons -- the same as the real
	# client. It has no authored list area (no scroll manager in
	# ifinventory.txt), so the old _fill_list fallback dropped a full-window
	# ItemList of "slot_index=.., Item_id=.." debug text *over* the grid,
	# hiding it. That debug overlay is gone: the grid is the window.
	NetClient.inventory_list_result.connect(func(slots: Array, _e: String) -> void:
		_fill_inventory_grid(slots))
	NetClient.equipment_result.connect(func(items: Array, _e: String) -> void:
		_equipped_items = items
		_fill_equipment_slots(items))
	# The skill window shows the masteries (client data, _fill_skill_masteries),
	# not the server's small skill catalogue, so its list result is not drawn
	# here -- it would overlap the mastery rows.
	NetClient.quest_list_result.connect(func(entries: Array, _e: String) -> void:
		_fill_list("quest", entries.map(_describe_named)))
	NetClient.friend_list_result.connect(func(friends: Array, _e: String) -> void:
		_fill_list("community", friends.map(_describe_named)))
	NetClient.character_stats_result.connect(_apply_stats)
	NetClient.skill_state_result.connect(_apply_skill_state)
	NetClient.raise_mastery_result.connect(_on_raise_mastery_result)
	NetClient.learn_skill_result.connect(_on_learn_skill_result)
	# Keep the skill window's points live: a kill grants skill points, so
	# re-read the state after an attack while the window is open.
	NetClient.attack_result.connect(_on_attack_refresh_skill)
	# Shop: the catalogue carries each item's price (the server's own disclosed
	# formula -- there is no real price table); a buy result refreshes the purse.
	NetClient.shop_list_result.connect(_on_shop_list_result)
	NetClient.shop_buy_result.connect(_on_shop_buy_result)
	NetClient.shop_sell_result.connect(_on_shop_sell_result)
	NetClient.storage_list_result.connect(_on_storage_list_result)
	NetClient.storage_deposit_result.connect(_on_storage_deposit_result)
	NetClient.storage_withdraw_result.connect(_on_storage_withdraw_result)
	NetClient.storage_gold_result.connect(_on_storage_gold_result)

## The character panel's own control names, from resinfo\\ifplayerinfo.txt.
## Every value field is a `_DAT` sibling of its label.
const CHARACTER_FIELDS := {
	"GDR_PI_TEXT_LEVEL": "level",
	"GDR_PI_TEXT_HP_DAT": "hp",
	"GDR_PI_TEXT_MP_DAT": "mp",
	"GDR_PI_TEXT_STRENGTH_DAT": "strength",
	"GDR_PI_TEXT_INTELLECT_DAT": "intellect",
	"GDR_PI_TEXT_CURXP": "current_exp",
}

## Fills the character panel from what the client actually knows.
##
## Only some of these have a server behind them: HP and MaxHP arrive with
## EnterWorldResult and on every attack, and the character's name and level
## come from the character list. Strength, intellect, the attack/defence
## rows and the job grades are **not sent by this project's server at all**,
## so their fields are left as the layout drew them rather than filled with
## invented numbers. See docs/UI_TODO.md.
func set_character_vitals(hp: int, max_hp: int, level: int) -> void:
	_character_hp = hp
	_character_max_hp = max_hp
	_character_level = level
	_apply_character_fields()

var _character_hp := 0
var _character_max_hp := 0
var _character_level := 1

func _apply_character_fields() -> void:
	var window: HudWindow = _windows.get("character")
	if window == null:
		return
	var values := {}
	if _character_max_hp > 0:
		values["GDR_PI_TEXT_HP_DAT"] = "%d / %d" % [_character_hp, _character_max_hp]
	if _character_level > 0:
		values["GDR_PI_TEXT_LEVEL"] = "Lv %d" % _character_level
	for control_name in values:
		var label := window.node(control_name) as Label
		if label != null:
			label.text = values[control_name]

## Fills every field the server actually has a number for.
##
## The character panel has thirteen more rows -- strength, intelligence, the
## magical and balance and hit-rate figures, the three job grades -- and
## nothing computes them, so they stay as the layout drew them. Filling them
## with a plausible number would be indistinguishable from a real one.
func _apply_stats(stats: StatsNet.Stats) -> void:
	if stats == null or stats.error != "":
		if stats != null and stats.error != "":
			push_warning("HudPanels: character stats refused: %s" % stats.error)
		return
	_stats = stats

	var inventory: HudWindow = _windows.get("inventory")
	if inventory != null:
		var gold := inventory.node("GDR_INVENTORY_STA_GOLD") as Label
		if gold != null:
			gold.text = _grouped(stats.gold)
	# The shop's own purse line, if the store is open.
	_update_shop_purse()

	var character: HudWindow = _windows.get("character")
	if character != null:
		_set_label(character, "GDR_PI_TEXT_PHYATT_DAT", str(stats.phys_attack))
		_set_label(character, "GDR_PI_TEXT_PHYDEF_DAT", str(stats.phys_defense))
		if stats.max_hp > 0:
			_set_label(character, "GDR_PI_TEXT_HP_DAT", "%d / %d" % [stats.hp, stats.max_hp])

var _stats: StatsNet.Stats = null

func _set_label(window: HudWindow, control_name: String, text: String) -> void:
	var label := window.node(control_name) as Label
	if label != null:
		label.text = text

## Thousands separators, which is how the client's own gold readout reads.
static func _grouped(value: int) -> String:
	var digits := str(absi(value))
	var out := ""
	var count := 0
	for i in range(digits.length() - 1, -1, -1):
		out = digits[i] + out
		count += 1
		if count % 3 == 0 and i > 0:
			out = "," + out
	return ("-" + out) if value < 0 else out

func _populate(panel_id: String) -> void:
	# Every one of these requests is addressed by character name, which is
	# also what identifies the session server-side, so there is nothing to
	# ask for before a character is chosen.
	var who := NetClient.current_character_name
	if who == "" or not NetClient.is_connected_to_server():
		return
	# Gold and the combat numbers feed both the inventory's gold readout and
	# the character panel's attack and defence rows, so either opening asks.
	if panel_id == "inventory" or panel_id == "character":
		NetClient.character_stats(who)
	match panel_id:
		"inventory":
			NetClient.list_inventory(who)
			# The equipment paper doll is docked in this window; refresh it too.
			_fill_equipment_slots(_equipped_items)
			NetClient.list_equipment(who)
		"quest":
			NetClient.list_quests(who)
		"skill":
			NetClient.skill_state(who)
		"community":
			NetClient.friend_list(who)
		"party":
			NetClient.party_info(who)
		"guild":
			NetClient.guild_info(who)
		"character":
			_apply_character_fields()
		"equipment":
			# Fill from what we already have, then ask the server for fresh.
			_fill_equipment_slots(_equipped_items)
			NetClient.list_equipment(who)

## Renders a list of strings into a panel, as a plain scrolling list laid
## over the authored frame.
##
## This is deliberately not the authored presentation: the real windows put
## items in a CIFLattice of icon slots, or in tabled rows with per-column
## art, and wiring each one properly is per-panel work. A readable list in
## the right window is the honest intermediate -- it shows real server data
## in the real frame, and says plainly that the slot rendering is not done.
## Lays a panel's entries out on the layout's own list geometry.
##
## This used to drop an `ItemList` over the window, sized by hand from the
## title bar down. Every one of these windows already says where its list
## goes and how tall a row is:
##
##   ifquest   GDR_QUEST_SCROLLMGR at 4,27,356,323, with eleven 2-pixel
##             divider tiles at y = 52, 79, 106 ... 322 -- a 27-pixel pitch
##   ifguild   GDR_GUILD_USERVIEW_SCROLLMGR at 17,163,328,139
##
## So the rows go inside the scroll manager, at the pitch its own dividers
## give. A window with no scroll manager keeps the overlay, because there is
## nothing authored to put the rows on.
func _fill_list(panel_id: String, lines: Array) -> void:
	var window: HudWindow = _windows.get(panel_id)
	if window == null:
		return
	var area := _list_area(window)
	if area == null:
		_fill_list_overlay(panel_id, window, lines)
		return

	var host := area.get_node_or_null("Rows") as Control
	if host == null:
		host = Control.new()
		host.name = "Rows"
		host.set_anchors_preset(Control.PRESET_FULL_RECT)
		host.mouse_filter = Control.MOUSE_FILTER_IGNORE
		area.add_child(host)
	for child in host.get_children():
		child.queue_free()

	var pitch := _row_pitch(window, area)
	var rows: int = maxi(1, int(area.size.y / pitch))
	for i in range(mini(lines.size(), rows)):
		var label := Label.new()
		label.text = str(lines[i])
		label.position = Vector2(ROW_TEXT_INSET, i * pitch)
		label.size = Vector2(area.size.x - ROW_TEXT_INSET * 2.0, pitch)
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.clip_text = true
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		label.add_theme_color_override("font_color", ROW_TEXT_COLOUR)
		if _builder != null:
			var font := _builder.font_at(0)
			if font != null:
				label.add_theme_font_override("font", font)
			label.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[0])
		host.add_child(label)

## Text inset inside a row, and the colour of it. The inset matches the
## authored dividers, which start 12 pixels inside their scroll manager
## (ifquest's are at x=16 against a manager at x=4). The colour is the one
## every other label in these windows already uses.
const ROW_TEXT_INSET := 12.0
const ROW_TEXT_COLOUR := Color(0.92, 0.88, 0.76)

## Fallback row height when a window declares no dividers to measure.
const ROW_PITCH_FALLBACK := 18.0

## The panel's authored list area: its scroll manager, by name.
func _list_area(window: HudWindow) -> Control:
	if window.panel_root == null:
		return null
	for node in _walk(window.panel_root):
		if node is Control and node.name.to_upper().contains("SCROLLMGR"):
			return node as Control
	return null

## The row pitch, taken from the spacing of the window's own divider tiles
## where it has them.
func _row_pitch(window: HudWindow, area: Control) -> float:
	var ys: Array[float] = []
	for node in _walk(window.panel_root):
		if not (node is Control) or not node.name.to_upper().contains("BG_"):
			continue
		var c := node as Control
		# Only the horizontal dividers: the vertical edge line in ifquest is
		# 1x303 and would otherwise be counted as a row boundary.
		if c.size.x > c.size.y and c.size.y <= DIVIDER_MAX_THICKNESS:
			ys.append(c.position.y)
	if ys.size() < 2:
		return ROW_PITCH_FALLBACK
	ys.sort()
	var gaps: Array[float] = []
	for i in range(1, ys.size()):
		var gap := ys[i] - ys[i - 1]
		if gap > 0.0:
			gaps.append(gap)
	if gaps.is_empty():
		return ROW_PITCH_FALLBACK
	gaps.sort()
	return gaps[gaps.size() / 2]

## How thin a control has to be to count as a divider rather than content.
const DIVIDER_MAX_THICKNESS := 4.0

func _walk(root: Node) -> Array[Node]:
	var out: Array[Node] = []
	for child in root.get_children():
		out.append(child)
		out.append_array(_walk(child))
	return out

## For a window with no authored list area. Kept because several panels do
## not have one, and an unreadable list is worse than a plain one.
func _fill_list_overlay(panel_id: String, window: HudWindow, lines: Array) -> void:
	var list := window.get_node_or_null("ContentList") as ItemList
	if list == null:
		list = ItemList.new()
		list.name = "ContentList"
		list.position = Vector2(12, HudWindow.TITLE_BAR_HEIGHT + 8.0)
		list.size = window.size - Vector2(24, HudWindow.TITLE_BAR_HEIGHT + 20.0)
		list.add_theme_color_override("font_color", ROW_TEXT_COLOUR)
		if _builder != null:
			var font := _builder.font_at(0)
			if font != null:
				list.add_theme_font_override("font", font)
			list.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[0])
		window.add_child(list)
	list.clear()
	for line in lines:
		list.add_item(str(line))

## Names for the fields these snapshots actually use. `get("name")` was
## wrong: the net snapshots call it `item_name`, `skill_name` and so on, so
## every lookup missed and the panels listed Godot's default object
## description -- "<RefCounted#-9223348498956899638>" -- straight to the
## player.
const NAME_FIELDS := ["item_name", "skill_name", "quest_name", "char_name", "friend_name", "name", "title"]
const COUNT_FIELDS := ["count", "quantity", "stack_count", "amount"]

## The first of field_names that entry actually has, or "".
static func _first_field(entry: Variant, field_names: Array) -> Variant:
	if not (entry is Object):
		return null
	var obj := entry as Object
	for field in field_names:
		if field in obj:
			var value = obj.get(field)
			if value != null and str(value) != "":
				return value
	return null

func _describe_item(slot: Variant) -> String:
	# The tables know the name even when the snapshot only carries an id.
	var by_id = _first_field(slot, ["item_id", "id"])
	if by_id != null:
		var resolved := _item_name(int(by_id))
		if resolved != "":
			var n = _first_field(slot, COUNT_FIELDS)
			return "%s x%d" % [resolved, int(n)] if n != null and int(n) > 1 else resolved
	var item_name = _first_field(slot, NAME_FIELDS)
	if item_name == null:
		return _describe_unknown(slot)
	var count = _first_field(slot, COUNT_FIELDS)
	if count != null and int(count) > 1:
		return "%s x%d" % [item_name, int(count)]
	return str(item_name)

func _describe_named(entry: Variant) -> String:
	var entry_name = _first_field(entry, NAME_FIELDS)
	return str(entry_name) if entry_name != null else _describe_unknown(entry)

## A snapshot with no field this code knows about. Says so, rather than
## printing Godot's object description, which is meaningless to a player
## and hides the fact that the binding is incomplete.
func _describe_unknown(entry: Variant) -> String:
	if entry is Object:
		var fields := PackedStringArray()
		for prop in (entry as Object).get_property_list():
			var field_name: String = prop["name"]
			if prop["usage"] & PROPERTY_USAGE_SCRIPT_VARIABLE:
				fields.append("%s=%s" % [field_name, (entry as Object).get(field_name)])
		if not fields.is_empty():
			return ", ".join(fields)
	return str(entry)
