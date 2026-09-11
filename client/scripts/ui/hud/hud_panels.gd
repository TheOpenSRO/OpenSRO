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
}

## Emitted by the System window's buttons, wired in _wire_system. World3D
## connects them: Option opens the settings panel, Restart returns to the
## login screen, Exit quits.
signal system_option_requested
signal system_restart_requested
signal system_exit_requested
signal system_help_requested

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
		if not window.build(_builder, spec[0], spec[1], extra):
			print("HudPanels: %s unavailable (layout %s did not build)" % [panel_id, spec[0]])
			window.queue_free()
			_unavailable[panel_id] = true
			return null
		window.centre()
		_windows[panel_id] = window
		if panel_id == "system":
			_wire_system(window)
		if panel_id == "equipment":
			_place_paper_doll(window)
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
func open_npc_talk(npc_name: String) -> void:
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
	body.text = "...\n\n[url=end]1. End conversation.[/url]"

func _on_npc_talk_choice(meta: Variant) -> void:
	if str(meta) == "end":
		close("npctalk")

## The live paper-doll texture (a SubViewport's), set by World3D whenever
## the dressed character changes. Shown in the equipment window's central
## column, between the two rows of worn slots.
var _paper_doll_texture: Texture2D = null

func set_paper_doll_texture(texture: Texture2D) -> void:
	_paper_doll_texture = texture
	var window: HudWindow = _windows.get("equipment")
	if window != null:
		_place_paper_doll(window)

func _place_paper_doll(window: HudWindow) -> void:
	if _paper_doll_texture == null:
		return
	var doll := window.get_node_or_null("PaperDoll") as TextureRect
	if doll == null:
		doll = TextureRect.new()
		doll.name = "PaperDoll"
		doll.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		doll.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		doll.mouse_filter = Control.MOUSE_FILTER_IGNORE
		# The gap between the equipment window's two slot columns (slots sit
		# at x 5 and x 141, 32 wide, over a 177-wide window): the central
		# column from x 40 to x 138, below the title bar to just above the
		# avatar-skill strip. The character renders here.
		doll.position = Vector2(40, HudWindow.TITLE_BAR_HEIGHT + 4.0)
		doll.size = Vector2(98, 236)
		window.add_child(doll)
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
var _items_loaded := false

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
	return "\n".join(PackedStringArray(item.tooltip_lines()))

func _item_name(item_id: int) -> String:
	_load_items()
	var item: ItemTableReader.Item = _items.get(item_id)
	return item.item_name if item != null else ""

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
		var icon := cell.get_node_or_null("ItemIcon") as TextureRect
		if icon != null:
			icon.texture = _item_icon(int(item_id))
			# A hover tooltip with the item's real stats -- name, attack,
			# durability, reinforce, requirement -- read straight off the
			# item table (ItemTableReader.Item.tooltip_lines). STOP so the
			# hover registers; the cell behind it still takes clicks.
			icon.tooltip_text = _item_tooltip(int(item_id))
			icon.mouse_filter = Control.MOUSE_FILTER_STOP
		var quantity = _first_field(entry, COUNT_FIELDS)
		var count_label := cell.get_node_or_null("CountLabel") as Label
		if count_label != null and quantity != null and int(quantity) > 1:
			count_label.text = str(int(quantity))

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

## Fills the skill window with the real China masteries -- icon and name --
## the way the original organises it, and its bottom labels honestly. The
## per-mastery skill grid and the trained levels are not here: this project's
## server tracks no mastery level or skill point, so the window shows the
## masteries at level 0 and says "not trained" rather than a made-up number.
func _fill_skill_masteries(window: HudWindow) -> void:
	_load_masteries()
	var board := window.node("GDR_SKILL_BOARD") as Control
	var host: Control = board if board != null else window
	var list := host.get_node_or_null("MasteryList") as VBoxContainer
	if list == null:
		list = VBoxContainer.new()
		list.name = "MasteryList"
		list.position = Vector2(10, 10)
		list.add_theme_constant_override("separation", 6)
		host.add_child(list)
	for child in list.get_children():
		child.queue_free()
	for entry in _masteries:
		var mastery: MasteryReader.Mastery = entry
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var icon := TextureRect.new()
		icon.custom_minimum_size = Vector2(28, 28)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		if _builder != null:
			icon.texture = _builder.load_texture(mastery.icon_path)
		row.add_child(icon)
		var label := Label.new()
		label.text = "%s  —  Lv 0 (not trained)" % mastery.display_name(_text_table())
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.add_theme_color_override("font_color", ROW_TEXT_COLOUR)
		if _builder != null:
			var font := _builder.font_at(0)
			if font != null:
				label.add_theme_font_override("font", font)
			label.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[0])
		row.add_child(label)
		list.add_child(row)
	# The bottom labels: this server tracks neither, so 0, plainly.
	_set_label(window, "GDR_SKILL_TEXT_SP_NUM", "0")
	_set_label(window, "GDR_SKILL_TEXT_TOTAL_MASTERYLEV_NUM", "0")

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

func _fill_equipment_slots(items: Array) -> void:
	var window: HudWindow = _windows.get("equipment")
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
	NetClient.inventory_list_result.connect(func(slots: Array, _e: String) -> void:
		_fill_inventory_grid(slots)
		_fill_list("inventory", slots.map(_describe_item)))
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
		"quest":
			NetClient.list_quests(who)
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
