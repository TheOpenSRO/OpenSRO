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
}

## Order and labels for the MENU popup, mirroring the reference's list.
const MENU_ITEMS := [
	["party", "Party (P)"],
	["partymatch", "Party Match (E)"],
	["guild", "Guild (G)"],
	["academy", "Academy (L)"],
	["action", "Action (A)"],
	["community", "Community (U)"],
	["quest", "Quest (Q)"],
	["alchemy", "Alchemy (Y)"],
	["inventory", "Inventory (I)"],
	["character", "Character (C)"],
	["skill", "Skill (K)"],
	["autopotion", "Auto Potion (T)"],
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
	for i in range(MENU_ITEMS.size()):
		var item: Array = MENU_ITEMS[i]
		_menu.add_item(item[1], i)
		_menu_ids.append(item[0])
	_menu.id_pressed.connect(func(id: int) -> void:
		if id >= 0 and id < _menu_ids.size():
			toggle(_menu_ids[id]))
	add_child(_menu)

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
		if not window.build(_builder, spec[0], spec[1]):
			print("HudPanels: %s unavailable (layout %s did not build)" % [panel_id, spec[0]])
			window.queue_free()
			_unavailable[panel_id] = true
			return null
		window.centre()
		_windows[panel_id] = window
		_populate(panel_id)
	window.show()
	window.move_to_front()
	_populate(panel_id)
	return window

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
		if close_topmost():
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

func connect_net() -> void:
	if _net_connected:
		return
	_net_connected = true
	NetClient.inventory_list_result.connect(func(slots: Array, _e: String) -> void:
		_fill_list("inventory", slots.map(_describe_item)))
	NetClient.skill_list_result.connect(func(skills: Array, _e: String) -> void:
		_fill_list("skill", skills.map(_describe_named)))
	NetClient.quest_list_result.connect(func(entries: Array, _e: String) -> void:
		_fill_list("quest", entries.map(_describe_named)))
	NetClient.friend_list_result.connect(func(friends: Array, _e: String) -> void:
		_fill_list("community", friends.map(_describe_named)))

func _populate(panel_id: String) -> void:
	# Every one of these requests is addressed by character name, which is
	# also what identifies the session server-side, so there is nothing to
	# ask for before a character is chosen.
	var who := NetClient.current_character_name
	if who == "" or not NetClient.is_connected_to_server():
		return
	match panel_id:
		"inventory":
			NetClient.list_inventory(who)
		"skill":
			NetClient.list_skills(who)
		"quest":
			NetClient.list_quests(who)
		"community":
			NetClient.friend_list(who)
		"party":
			NetClient.party_info(who)
		"guild":
			NetClient.guild_info(who)

## Renders a list of strings into a panel, as a plain scrolling list laid
## over the authored frame.
##
## This is deliberately not the authored presentation: the real windows put
## items in a CIFLattice of icon slots, or in tabled rows with per-column
## art, and wiring each one properly is per-panel work. A readable list in
## the right window is the honest intermediate -- it shows real server data
## in the real frame, and says plainly that the slot rendering is not done.
func _fill_list(panel_id: String, lines: Array) -> void:
	var window: HudWindow = _windows.get(panel_id)
	if window == null:
		return
	var list := window.get_node_or_null("ContentList") as ItemList
	if list == null:
		list = ItemList.new()
		list.name = "ContentList"
		list.position = Vector2(12, HudWindow.TITLE_BAR_HEIGHT + 8.0)
		list.size = window.size - Vector2(24, HudWindow.TITLE_BAR_HEIGHT + 20.0)
		list.add_theme_color_override("font_color", Color(0.92, 0.88, 0.76))
		window.add_child(list)
	list.clear()
	for line in lines:
		list.add_item(str(line))

func _describe_item(slot: Variant) -> String:
	if slot is Object and (slot as Object).has_method("get"):
		var name_value = slot.get("name")
		var count_value = slot.get("count")
		if name_value != null:
			if count_value != null and int(count_value) > 1:
				return "%s x%d" % [name_value, int(count_value)]
			return str(name_value)
	return str(slot)

func _describe_named(entry: Variant) -> String:
	if entry is Object and (entry as Object).has_method("get"):
		var name_value = entry.get("name")
		if name_value != null:
			return str(name_value)
	return str(entry)
