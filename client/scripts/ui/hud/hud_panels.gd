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
const HudMainPopup = preload("res://scripts/ui/hud/hud_main_popup.gd")
const ErrorText = preload("res://scripts/net/error_text.gd")
const GuildWindow = preload("res://scripts/ui/hud/guild_window.gd")

## key: the panel id used by the underbar's menu_action and by hotkeys.
## Each entry is [layout path, window title, hotkey action name or ""].
##
## **Inventory, equipment, character, skill, party, action and academy are
## not windows of their own**: they are panes of the client's main popup
## (HudMainPopup, `resinfo\\ifmainpopup.txt` in the registry's GDR_MAINPOPUP
## frame), and their keys select its tabs. Their layout paths here are the
## panes' own layouts, which HudMainPopup.PANE_LAYOUTS builds. The keys are
## this client's: the retail defaults (read from 0x7778be and dispatched in
## 0x780610) are C, I, S, A, P and L for the same six tabs, with no key for
## equipment; skill is K here because S walks backwards.
const PANELS := {
	"inventory": ["resinfo\\ifinventory.txt", "Inventory", KEY_I],
	# The equipment pane, beside the bag on the popup's inventory tab.
	"equipment": ["resinfo\\ifequipment.txt", "Equipment", KEY_O],
	# CIFPlayerInfo::Create (0x6b84ec) loads ifplayerinfo_trijob2.txt; the
	# exe never names ifplayerinfo.txt, in ASCII or UTF-16.
	"character": ["resinfo\\ifplayerinfo_trijob2.txt", "Character", KEY_C],
	"skill": ["resinfo\\ifskill.txt", "Skill", KEY_K],
	"quest": ["resinfo\\ifquest.txt", "Quest list", KEY_Q],
	"party": ["resinfo\\ifparty.txt", "Party", KEY_P],
	# The guild and community are one window, CNIFGuildWnd, built from the
	# client's `res_ui\*.2dt` files (GuildWindow); these two ids are its two
	# views. U is the retail binding and opens the guild view: the default
	# key table at 0x7778be puts 'U' in slot 6, which reaches the guild
	# window's toggle 0x5b4980. No default key opens the community view; the
	# underbar's community button does (_open_guild_window).
	"community": [GuildWindow.GUILD_2DT, "", 0],
	"guild": [GuildWindow.GUILD_2DT, "", KEY_U],
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
	# Opened from a Dimensional Gate's talk line 'Select a teleport area:'
	# (open_teleport_board, round 578). The title is "": the layout has no
	# frame at the origin, so HudWindow._authored_title finds nothing, and the
	# layout's own GDR_TB_STATIC_TITLE (13,17,393,21, UIIT_PAG_TELEPORT)
	# already draws the caption -- a title here would draw a second one over
	# it. Its close button is the authored GDR_TB_BTN_CLOSE (406,15,16,16).
	"teleport": ["resinfo\\ifteleportboard.txt", "", 0],
}

## Keys this project binds that are not the retail client's, each to a panel
## id. **G is ours**: in the retail table G is slot 13, which reaches
## 0x780895 and calls 0x793b00(0x64, 0x3f0) -- not the guild window, and what
## it is was not established. G opened the guild window here before the
## guild window was rebuilt, and nothing else in this client binds it, so it
## keeps opening the guild view as a convenience.
const PROJECT_HOTKEYS := {
	KEY_G: "guild",
}

## The two views of the guild window (GuildWindow), and the key its one
## window is kept under in _windows.
const GUILD_VIEWS := ["guild", "community"]
const GUILD_WINDOW_KEY := "guild"
## The last friend list and guild state the server sent, kept so the guild
## window draws them even when it is built after they arrive (the client
## builds its window at game start and fills it from data it already holds).
var _friends: Array = []
## The last guild reply without an error (null: none yet).
var _guild_result: GuildNet.Result = null
## The last panel id _populate was asked for (a test hook).
var last_populated := ""

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

## Panels the client frames from its window registry, resinfo\ginterface.txt,
## rather than from their own layout (HudWindow.build's `registry`). Each is
## a CIFMainFrame subclass whose Create builds CIFMainFrame's caption, drag
## strip and close button and then its layout, with the window as the parent
## (docs/RE_COMPLETION.md, round 586, has every address):
##
## - **storage**: GDR_STORAGEROOM (CIFStorageRoom, "Create" section), 254x317,
##   UIIT_STT_STORAGEROOM. CIFStorageRoom::Create 0x6cc780 loads
##   ifstorageroom.txt.
## - **exchange**: GDR_EXCHANGE (CIFExchange), UIIT_STT_EXCHANGE. Its rect has
##   three #ifdef branches: 254x361 with APPLY_EXCHANGE_UPDATE_1TH and
##   UI_UPDATE_2009_FIRST, 363x363 with the first alone, 254x361 without it.
##   Both are selected because CIFExchange::Create (0x7b27d0) uses controls
##   only those branches declare with no null check (round 585, the
##   alternates round). CIFExchange::Create loads ifexchange.txt.
## - **system**: GDR_SYSTEM (CIFSystemWnd), UIIT_PAG_SYSTEM, 214 wide.
##   CIFSystemWnd::Create 0x6f6610 then sizes the window in code
##   (_layout_system_window).
## - **partymatch**: GDR_PARTY_MATCH (CIFPartyMatch, the "PartyMatch"
##   section), 785x480, UIIT_PAG_PARTYMATCH_PSEARCH. CIFPartyMatch::Create
##   0x73ae90 builds Create, SearchInfo, SlotListButton and SlotList -- the
##   EXTRA_SECTIONS below, now read rather than swept.
## - **autopotion**: GDR_AUTO_POTION (CIFAutoPotion, the "AutoPotion"
##   section), 394x520, UIIT_PAG_MACROPOTION_TITLE. CIFAutoPotion::Create
##   0x741980 builds Create, AbnormalSlot and PotionDelaySlot.
##
## Not here, each for a stated reason:
## - **community / guild**: the retail windows are CNIFGuildWnd and its child
##   CNIFCommunityWnd, built from `res_ui\*.2dt` (GuildWindow), with
##   CNIFMainFrame's chrome; GDR_COMMUNITY's layout is never loaded.
## - **store**: GDR_STORE's height depends on two #ifdefs this build's data
##   cannot settle -- 317 (neither, or RENEWAL_SHOP_SYSTEM alone), 360
##   (RESTORE_SOLDITEM_INSHOP) or 370 (both) -- and the layout read with
##   nothing defined puts its Repair buttons at y 332-356, below a 317 frame.
## - **alchemy**: GDR_ALCHEMYBOX is a CIFAlchemyBox, a plain CIFWnd drawing
##   alcm_window_1.ddj, not a CIFMainFrame; ifalchemyprocess.txt is loaded by
##   CIFAlchemyProcess, a child the box's own layout (ifnewalchemybox.txt)
##   places at 0,150. A different assembly, not this frame.
const REGISTRY_FRAMES := {
	"storage": {"name": "GDR_STORAGEROOM"},
	"exchange": {"name": "GDR_EXCHANGE",
		"defines": ["APPLY_EXCHANGE_UPDATE_1TH", "UI_UPDATE_2009_FIRST"]},
	"system": {"name": "GDR_SYSTEM"},
	"partymatch": {"name": "GDR_PARTY_MATCH"},
	"autopotion": {"name": "GDR_AUTO_POTION"},
}

## Controls a window's own class hides when it creates the window, so they
## are hidden here once, when the window is built. Each is one member of a
## group of controls authored at the same rect; the others stay as built.
## Read from the class's code (docs/RE_COMPLETION.md, round 585; addresses
## are sro_client.exe's). Groups whose default could not be read are not
## here and are listed there as open.
##
## - **academy**: CIFApprenticeShip::vslot_010 (0x6e9770) fetches
##   GDR_APPRENTICESHIP_PICTURE (ID 41) and hides it at once (0x6e9848,
##   ShowWindow(0)); it is shown only when a member's face is filled in
##   (0x6e9f31). GDR_APPRENTICESHIP_LEADER_STATUS (ID 46), at the same rect,
##   is never shown or hidden -- only its image changes -- so it stays.
## - **alchemy**: CIFAlchemyProcess::vslot_023 (0x725740), the show handler,
##   hides GDR_AB_MANUFACTURING_BUTTON_CANCEL (ID 35) every time the window
##   is shown. FUN_00723bb0 swaps it with Process (ID 30) while a compound
##   runs, which this client does not do, so Process is the one shown.
const HIDDEN_AT_CREATE := {
	"academy": ["GDR_APPRENTICESHIP_PICTURE"],
	"alchemy": ["GDR_AB_MANUFACTURING_BUTTON_CANCEL"],
}

func _hide_at_create(panel_id: String, window: HudWindow) -> void:
	for control_name in HIDDEN_AT_CREATE.get(panel_id, []):
		var node := window.node(control_name) as CanvasItem
		if node != null:
			node.visible = false

## The equipment window's two modes, as CIFEquipment runs them (round 585,
## docs/RE_COMPLETION.md). Its refresh (0x6abde0) reads one flag (+0xf08):
##
## - **equipment** (the flag clear): the thirteen worn slots
##   GDR_EQUIPMENT_SLOT_100..112 and the change-to-avatar button
##   GDR_EQ_BTN_CHANGE_AVATAR_SLOT (ID 13) shown; the avatar slots
##   GDR_AVATAR_SLOT_01..05 (IDs 113-117), the change-to-equipment button
##   GDR_EQ_BTN_CHANGE_EQUIP_SLOT (ID 14) and the avatar skill strip
##   GDR_AVATAR_SKILL_WND (ID 500) hidden (0x6abef0..0x6abf53).
## - **avatar** (the flag set): the worn slots hidden except SLOT_108, the
##   avatar slots and button 14 shown, button 13 hidden (0x6abe10..0x6abee3).
##   The skill strip is shown only for an avatar item of a particular type
##   with a value above zero; this client has no avatar items, so it stays
##   hidden.
##
## The constructor clears the flag (0x6ab569) and so does hiding the window,
## so every open starts in equipment mode. Buttons 13 and 14 both run
## 0x6abf60, which flips the flag and refreshes (the click table entries at
## 0xeb8378 and 0xeb83a0).
const EQUIPMENT_MODE_SLOTS := 13
const EQUIPMENT_MODE_KEPT_SLOT := 108
const AVATAR_SLOT_NAMES := ["GDR_AVATAR_SLOT_01", "GDR_AVATAR_SLOT_02",
	"GDR_AVATAR_SLOT_03", "GDR_AVATAR_SLOT_04", "GDR_AVATAR_SLOT_05"]
const BTN_TO_AVATAR := "GDR_EQ_BTN_CHANGE_AVATAR_SLOT"
const BTN_TO_EQUIPMENT := "GDR_EQ_BTN_CHANGE_EQUIP_SLOT"
const AVATAR_SKILL_STRIP := "GDR_AVATAR_SKILL_WND"
var _equipment_avatar_mode := false
var _equipment_window: HudWindow = null

## `pane` is the equipment pane inside the main popup: switching to another
## tab hides it (0x6a1c70 calls every pane's ShowWindow(0)), which clears the
## flag the same way closing the window does.
func _wire_equipment_modes(window: HudWindow, pane: CanvasItem = null) -> void:
	_equipment_window = window
	for button_name in [BTN_TO_AVATAR, BTN_TO_EQUIPMENT]:
		var button := window.node(button_name) as BaseButton
		if button != null:
			button.pressed.connect(func() -> void:
				set_equipment_avatar_mode(not _equipment_avatar_mode))
	for watched in [window, pane]:
		if watched == null:
			continue
		var item: CanvasItem = watched
		item.visibility_changed.connect(func() -> void:
			if not item.visible:
				set_equipment_avatar_mode(false))
	set_equipment_avatar_mode(false)

## Shows the equipment window's worn slots (false) or its avatar slots
## (true); the comment above EQUIPMENT_MODE_SLOTS has what each mode shows.
func set_equipment_avatar_mode(avatar: bool) -> void:
	_equipment_avatar_mode = avatar
	var window := _equipment_window
	if window == null or not is_instance_valid(window):
		return
	for i in EQUIPMENT_MODE_SLOTS:
		var id := EQUIPMENT_SLOT_BASE + i
		_set_shown(window, "GDR_EQUIPMENT_SLOT_%d" % id,
			not avatar or id == EQUIPMENT_MODE_KEPT_SLOT)
	for avatar_slot in AVATAR_SLOT_NAMES:
		_set_shown(window, avatar_slot, avatar)
	_set_shown(window, BTN_TO_AVATAR, not avatar)
	_set_shown(window, BTN_TO_EQUIPMENT, avatar)
	_set_shown(window, AVATAR_SKILL_STRIP, false)

## Whether the equipment window is showing its avatar slots.
func is_equipment_avatar_mode() -> bool:
	return _equipment_avatar_mode

static func _set_shown(window: HudWindow, control_name: String, shown: bool) -> void:
	var node := window.node(control_name) as CanvasItem
	if node != null:
		node.visible = shown

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
## A learned skill was DRAGGED out of the window and released at a screen
## position: World3D resolves the position against the underbar's quickslots
## and puts the skill there (the original's way onto the hotbar).
signal skill_drop_requested(at: Vector2, skill_id: int, basic_code: String, icon: Texture2D)
## A BAG ITEM was dragged out of the inventory and released somewhere that is
## neither a bag slot nor an equipment slot -- World3D resolves the position
## against the underbar's quickslots and puts the item there.
##
## The quickslots held skills only until now, so a consumable could not reach
## the bar at all: "skills should be drag and drop" and the HP berry that could
## not be used from it (playtest 2026-09-20).
signal item_drop_requested(at: Vector2, item_id: int, inventory_slot: int, icon: Texture2D)
## A talk-box service line other than "End conversation" was chosen; `key` is
## the service's stable key (NpcServiceReader.Service.key -- "shop", "storage",
## ...). World3D acts on it (opens the shop, ...).
signal npc_service_selected(key: String)
## The guild name prompt (open_guild_name_prompt, round 521) was submitted
## with this name. World3D sends it to the server (NetClient.create_guild).
signal guild_create_requested(guild_name: String)
## The guild leave prompt (open_guild_leave_prompt, round 521) was confirmed.
## World3D sends the leave request (NetClient.leave_guild).
signal guild_leave_requested
## A line for the chat's system channel -- today a server refusal of a mastery
## raise, which used to be dropped silently. World3D logs it (_log_system).
signal system_notice(text: String)
## A Move button on the teleport board (open_teleport_board, round 578) was
## pressed: `dest_id` is its row's destination, a teleportdata id. World3D
## sends it with the gate the board was opened at (NetClient.teleport_use).
signal teleport_requested(dest_id: int)

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
## - The guild window used to be built from ifguild's sections here, chosen
##   by `sweep_section_overlap.gd`'s geometry. The client never loads
##   ifguild.txt; the guild window is `res_ui\guild.2dt` (GuildWindow).
##   The tool's check on ifskill -- MainSkillWnd and Withdrawal at 100%,
##   the answer the binary gives -- still stands.
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
	["guild", "Guild (U)", "ub_new_icon_guild"],
	["academy", "Academy (L)", "ub_new_icon_apprenticeship"],
	["action", "Action (A)", "ub_new_icon_action"],
	["community", "Community", "ub_new_icon_commu"],
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
	# The bag, the equipment, the character, skill, action, party and academy
	# are panes of the main popup: one window, a tab each.
	if HudMainPopup.hosts(panel_id):
		return _open_main_popup(panel_id)
	if panel_id in GUILD_VIEWS:
		return _open_guild_window(panel_id)
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
		var registry: Dictionary = REGISTRY_FRAMES.get(panel_id, {})
		if not window.build(_builder, spec[0], spec[1], extra, defines, honor_ifdef, registry):
			print("HudPanels: %s unavailable (layout %s did not build)" % [panel_id, spec[0]])
			window.queue_free()
			_unavailable[panel_id] = true
			return null
		_hide_at_create(panel_id, window)
		if panel_id == "system":
			_layout_system_window(window)
		window.centre()
		_windows[panel_id] = window
		if panel_id == "system":
			_wire_system(window)
		_populate(panel_id)
	window.show()
	window.move_to_front()
	_populate(panel_id)
	return window

## Moves a window this client placed itself. The main popup keeps a wanted
## position that its clamp and every resize rebuild from
## (HudMainPopup.keep_on_screen), so it is moved through that; writing its
## `position` directly would be undone by the next viewport resize.
func place_window(window: HudWindow, at: Vector2) -> void:
	if window == null:
		return
	if _popup != null and window == _popup.window:
		_popup.place_at(at)
	else:
		window.position = at

## The main popup, built on first use (HudMainPopup), and the panel ids its
## tabs answer to.
var _popup: HudMainPopup = null
const MAIN_POPUP_ID := "mainpopup"

## Shows the main popup on `panel_id`'s tab, building it the first time.
## Returns the popup window, or null when its layout is not in the archive.
func _open_main_popup(panel_id: String) -> HudWindow:
	var tab := HudMainPopup.tab_of(panel_id)
	if _unavailable.has(MAIN_POPUP_ID):
		return null
	if _popup == null:
		var window := HudWindow.new()
		window.name = "Window_" + MAIN_POPUP_ID
		add_child(window)
		var popup := HudMainPopup.new()
		for id in HudMainPopup.TABS:
			popup.fallback_titles[id] = PANELS[id][1]
		# A pane's extra sections, as each window composed them before.
		var extras := {
			"GDR_SKILL": EXTRA_SECTIONS.get("skill", []),
			"GDR_APPRENTICESHIP": EXTRA_SECTIONS.get("academy", []),
		}
		if not popup.build(_builder, window, "", extras):
			print("HudPanels: the main popup is unavailable (layout %s did not build)" % HudMainPopup.LAYOUT)
			window.queue_free()
			_unavailable[MAIN_POPUP_ID] = true
			return null
		_popup = popup
		for id in HudMainPopup.TABS.keys() + HudMainPopup.ALIASES.keys():
			_windows[id] = window
		_hide_at_create("academy", window)
		_wire_equipment_modes(window, popup.pane_control("GDR_EQUIPMENT"))
		_apply_equipment_slot_backgrounds()
		_place_paper_doll_docked()
		_fill_equipment_slots(_equipped_items)
	# The skill board reads a few MB of tables, so it is filled the first time
	# its tab is shown, as it was the first time its window opened.
	if tab == "skill" and not _skill_board_filled:
		_skill_board_filled = true
		_fill_skill_masteries(_popup.window)
	_popup.open(tab)
	_populate(tab)
	return _popup.window

var _skill_board_filled := false

## The guild window in one of its two views, built the first time it is
## wanted (the client builds it at game start, hidden, 0x786f30, and U only
## toggles it). `open` shows it in the view asked for.
func _open_guild_window(view: String) -> GuildWindow:
	var window := _guild_window()
	if window == null:
		return null
	if view == "community":
		window.show_community_view()
	else:
		window.show_guild_view()
	window.show()
	window.move_to_front()
	_populate(view)
	return window

## U (0x5b4980) and the underbar's community button (the retail menu's
## community item, 0x5b49c0): set the view, then toggle the window.
func _toggle_guild_window(view: String) -> void:
	var window := _guild_window()
	if window == null:
		return
	if view == "community":
		window.toggle_community_view()
	else:
		window.toggle_guild_view()
	if window.visible:
		window.move_to_front()
		_populate(view)

func _guild_window() -> GuildWindow:
	var window := _windows.get(GUILD_WINDOW_KEY) as GuildWindow
	if window != null:
		return window
	if _unavailable.has(GUILD_WINDOW_KEY):
		return null
	window = GuildWindow.new()
	window.name = "Window_guild"
	add_child(window)
	if not window.build_guild(_builder):
		print("HudPanels: guild unavailable (%s did not build)" % GuildWindow.GUILD_2DT)
		window.queue_free()
		_unavailable[GUILD_WINDOW_KEY] = true
		return null
	window.hide()
	# Centred on every show by the window itself (GuildWindow.place_centred,
	# 0x798c50), not once here.
	_apply_guild(window)
	window.fill_friends(_friends)
	# The window's own left-menu buttons switch views; ask for that view's
	# data as U and the community button do.
	window.view_changed.connect(func(view: String) -> void: _populate(view))
	_windows[GUILD_WINDOW_KEY] = window
	return window

## Opens the NPC dialogue for an NPC of the given name: the authored paper
## window (if_npctalk) titled with the name, greeting and the choices the
## NPC offers. The end line closes the window. Any other line emits
## npc_service_selected, and World3D opens that service's window if it has
## one.
##
## Each call is a new conversation, so a guild prompt left from the last one
## goes (round 521): clicking another NPC -- a potion merchant, say -- while
## the name prompt is up must not leave a create line that still founds a
## guild over that NPC's talk box. A guild reply rebuilds the lines with
## refresh_npc_talk instead, which keeps the prompt.
func open_npc_talk(npc_name: String, greeting: String = "", services: Array = []) -> void:
	var window := open("npctalk")
	if window == null:
		return
	_drop_talk_prompts(window)
	_fill_npc_talk(window, npc_name, greeting, services)

## Rebuilds the lines of a talk box that is already open, for World3D after a
## guild reply changed the player's guild state (round 521). Unlike
## open_npc_talk it does not go through open(), so it neither raises the talk
## box above a window opened from it (the store after Buy) nor drops a guild
## prompt the player may be typing into. A closed talk box stays closed.
func refresh_npc_talk(npc_name: String, greeting: String, services: Array) -> void:
	if not is_open("npctalk"):
		return
	_fill_npc_talk(_windows["npctalk"], npc_name, greeting, services)

func _fill_npc_talk(window: HudWindow, npc_name: String, greeting: String, services: Array) -> void:
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
	# numbered options, then the end line. The numbered lines are built by
	# NpcServiceReader.talk_menu_lines (round 513), which resolves each line's
	# UIIT token through _resolve_ui (the player's own textuisystem.txt) and
	# prints one NPCTALK log line per menu line. World3D acts on the services
	# with a system behind them (Buy opens the shop, storage the warehouse).
	var lines := PackedStringArray()
	lines.append(greeting if greeting != "" else "...")
	lines.append("")
	lines.append_array(NpcServiceReader.talk_menu_lines(npc_name, services, _resolve_ui))
	body.text = "\n".join(lines)

func _on_npc_talk_choice(meta: Variant) -> void:
	var key := str(meta)
	if key == "end":
		close("npctalk")
		return
	# A real service was chosen. The talk box stays open behind the service
	# window (the client keeps it up), so World3D decides what to raise.
	npc_service_selected.emit(key)

## Whether a text line has the keyboard: the focus owner of this viewport is
## a LineEdit or TextEdit -- the guild name prompt (round 521), the warehouse
## gold dialog's amount, the chat's own line, or any other. World3D reads
## movement from the raw key state (Input.get_axis), which a focused line
## does not consume, so without this every "w" typed into the guild name
## prompt walked the character, as it once did in chat (World3D._is_typing).
##
## A line left focused -- the debug panel's teleport field after Enter, the
## options panel's chat-font spinner after a click on its arrows (its inner
## LineEdit takes the focus) -- stopped WASD, click-to-move and the attack walk
## until it lost the focus some other way (round 521's review). World3D now
## takes the focus back on a left click on the world (take_focus_back), and
## the spinner hands it back once its value is set (debug_panel.gd). A
## SpinBox's line still counts while it has the focus: the keys typed there go
## into it, not to quickslots or berserk, so letting W also walk would split
## one key press two ways. A line not visible in the tree does not count
## (Godot already releases a hidden control's focus; this is only a guard).
func is_typing() -> bool:
	if not is_inside_tree():
		return false
	var focus := get_viewport().gui_get_focus_owner()
	if not (focus is LineEdit or focus is TextEdit):
		return false
	return focus.is_visible_in_tree()

## The size the server accepts for a guild name, in bytes: guild.MaxNameLength
## (server/internal/guild/guild.go, 12). The engine's test is
## `if (len - 2u < 0xb)` in the create handler FUN_00514ce0
## (docs/protocol/guild.md, the table's "name length" row). It is the
## server's limit, not a claimed limit of the real client's own prompt, and
## LineEdit counts characters, so a name with non-ASCII text can still be
## refused by the server (its "2 to 12" message says why).
const GUILD_NAME_MAX := 12

## The talk box's own prompts (round 521), by node name. At most one is up at
## a time. Each sits on the talk window, so it hides with it, and a new
## conversation drops it (open_npc_talk).
const TALK_PROMPTS := ["GuildNamePrompt", "GuildLeavePrompt"]

func _drop_talk_prompts(window: HudWindow) -> void:
	for prompt_name in TALK_PROMPTS:
		var old := window.get_node_or_null(prompt_name)
		if old != null:
			old.free()

## A prompt panel for the talk window (round 521), replacing any prompt
## already up: the dark, gold-edged box of the warehouse gold dialog
## (_open_gold_dialog), headed with the talk line's own text. The panel's
## first child is the VBoxContainer "VB" to fill; _show_talk_prompt adds it.
func _talk_prompt(window: HudWindow, prompt_name: String, heading: String) -> PanelContainer:
	_drop_talk_prompts(window)
	var panel := PanelContainer.new()
	panel.name = prompt_name
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
	box.add_child(_shop_label(heading, Color(0.95, 0.9, 0.72)))
	return panel

## A centred row of buttons for a talk prompt, one per [node name, text,
## Callable]; the prompt's own design (round 521).
func _talk_prompt_buttons(panel: PanelContainer, buttons: Array) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	panel.get_node("VB").add_child(row)
	for spec in buttons:
		var btn := Button.new()
		btn.name = str(spec[0])
		btn.text = str(spec[1])
		btn.pressed.connect(spec[2] as Callable)
		row.add_child(btn)

## Puts a talk prompt on the window, gives `focus` the keyboard (null: none)
## and centres the prompt once it has its size.
func _show_talk_prompt(window: HudWindow, panel: PanelContainer, focus: Control) -> void:
	window.add_child(panel)
	panel.reset_size()
	# Outside the scene tree (npc_service_reader_test.gd drives this on a
	# bare window) there is no frame to wait for and nothing to focus.
	if not panel.is_inside_tree():
		return
	if focus != null:
		focus.grab_focus()
	await panel.get_tree().process_frame
	if is_instance_valid(panel):
		panel.position = ((window.size - panel.size) * 0.5).round()

## The name prompt behind the guild NPC's create line (round 521): a line for
## the name, then Create and Cancel. Create (or Enter) emits
## guild_create_requested with the trimmed name and closes the prompt; the
## server's reply goes to chat (World3D._on_guild_create_result). The prompt
## is this project's own design, laid out like the warehouse gold dialog
## (_open_gold_dialog), not the real client's guild-creation window, which
## was not read. The name line takes the keyboard, so World3D's movement
## gate (is_typing) keeps the typed letters from walking the character.
func open_guild_name_prompt(npc_name: String) -> void:
	var window: HudWindow = _windows.get("npctalk")
	if window == null:
		return
	print("GUILDPROMPT %s: name prompt opened" % npc_name)
	# The heading is the create line's own text (the archive's
	# UIIT_CTL_GUILD_CREATE), with the English fallback the talk line uses.
	var panel := _talk_prompt(window, "GuildNamePrompt",
		_resolve_ui(NpcServiceReader.GUILD_CREATE_STRID, "Create a new guild"))
	var name_edit := LineEdit.new()
	name_edit.name = "GuildName"
	name_edit.placeholder_text = "guild name"
	name_edit.max_length = GUILD_NAME_MAX
	name_edit.alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_edit.custom_minimum_size = Vector2(150, 0)
	if _builder != null:
		var font := _builder.font_at(0)
		if font != null:
			name_edit.add_theme_font_override("font", font)
		name_edit.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[0])
	panel.get_node("VB").add_child(name_edit)
	var submit := func() -> void:
		var guild_name := name_edit.text.strip_edges()
		if guild_name.is_empty():
			return
		guild_create_requested.emit(guild_name)
		panel.queue_free()
	name_edit.text_submitted.connect(func(_text: String) -> void: submit.call())
	_talk_prompt_buttons(panel, [
		["Create", "Create", submit],
		["Cancel", "Cancel", func() -> void: panel.queue_free()],
	])
	_show_talk_prompt(window, panel, name_edit)

## The confirmation behind the guild NPC's leave line (round 521): the line's
## own text, then Leave and Cancel. Leave emits guild_leave_requested and
## closes the prompt, so one misclick on the talk line leaves no guild. The
## real client does not leave on the click either. Its item 0x1c case in
## CIF_NPCTalk::FUN_007020c0 (0x702ba9: index byte 0x12 at 0x703d48, entry
## 0x703cb4 of the jump table at 0x703c6c) tests FUN_009870e0 again and then
## opens a window of kind 0x14 (0x702bf9 push 0x14; 0x702c0e call 0x6ec5d0,
## which builds a centred 0x134 x 0x94 gwnd, 0x6ec689-0x6ec6e2), and the
## block holds no call to Net_SendRequestPacket. Item 0x1d's case sends its
## request at once (0x702c31 push 0x7046; call 0x841780,
## Net_SendRequestPacket). What that window shows and how it goes on to the
## leave were not read, so this prompt, its layout and its button text are
## this project's own design.
func open_guild_leave_prompt(npc_name: String) -> void:
	var window: HudWindow = _windows.get("npctalk")
	if window == null:
		return
	print("GUILDPROMPT %s: leave prompt opened" % npc_name)
	# The heading is the leave line's own text (UIIT_CTL_GUILD_SECESSION).
	var panel := _talk_prompt(window, "GuildLeavePrompt",
		_resolve_ui(NpcServiceReader.GUILD_SECESSION_STRID, "Leave guild."))
	var confirm := func() -> void:
		guild_leave_requested.emit()
		panel.queue_free()
	_talk_prompt_buttons(panel, [
		["Leave", "Leave", confirm],
		["Cancel", "Cancel", func() -> void: panel.queue_free()],
	])
	_show_talk_prompt(window, panel, null)

# --- The Revive button (round 548) -------------------------------------------
#
# A monster's killing blow can now leave the player DEAD -- the server's life
# state 2 (docs/protocol/character_state.md, rounds 411-413), HP 0, behind its
# -player-dead-state flag -- instead of putting it back on its feet in the same
# call. World3D holds the death pose and locks movement and attack input
# (World3D._enter_dead_state); this is the one thing left to click. Built in
# the HUD file split (docs/HANDOFF_UI.md): World3D connects revive_requested
# and sends OpRevive (NetClient.revive); the server's OpReviveResult takes the
# prompt down (hide_revive_prompt).
#
# THIS PROJECT'S OWN DESIGN. The retail client's resurrection dialogue -- the
# one behind 0x7053, whose server handler GObjPC_HandleResurrectMsg_053
# (0x50fee0) reads a u8 option: 1 return to the return point, 2 revive here,
# the latter only for a max level of 10 or under (docs/protocol/monster_ai.md,
# "The player's dead state") -- was not read, and srrevamp's server revives in
# place at any level (a disclosed stand-in), so there is one choice to offer.
# The panel is the talk prompts' dark, gold-edged box (_talk_prompt), and its
# wording is this project's.

## The prompt's node name under this HUD; at most one is up at a time.
const REVIVE_PROMPT := "RevivePrompt"

## Whether the player is dead (World3D._player_dead, set by _enter_dead_state
## and cleared by _leave_dead_state; round 550). The bag's right-click use
## reads it: the server refuses a dead player's OpUseItem (Item_HandleUseItem
## 0x510980 answers 0x1889 unless GetLifeState() == 1), so nothing goes out.
var player_dead := false

## The chat line for an item tried while dead: World3D.DEAD_INPUT_LINE's
## wording (World3D has no class_name to read it from).
const DEAD_INPUT_LINE := "You are dead. Revive first."

## The Revive button was clicked. World3D sends OpRevive (_on_revive_requested).
signal revive_requested

## Puts the Revive prompt over the world: `line` (World3D's death line) and
## the button. Replaces a prompt already up. Sits on this HUD, not on a
## window, so it stays while every window closes and is never hidden with one.
func show_revive_prompt(line: String) -> void:
	hide_revive_prompt()
	var panel := PanelContainer.new()
	panel.name = REVIVE_PROMPT
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
	box.add_child(_shop_label(line, Color(0.95, 0.9, 0.72)))
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(row)
	var btn := Button.new()
	btn.name = "Revive"
	btn.text = "Revive"
	btn.custom_minimum_size = Vector2(96, 0)
	btn.pressed.connect(func() -> void: revive_requested.emit())
	row.add_child(btn)
	add_child(panel)
	panel.reset_size()
	# Outside the scene tree (the headless suite drives this on a bare HUD)
	# there is no frame to wait for.
	if not panel.is_inside_tree():
		return
	await panel.get_tree().process_frame
	# Still a live node on a HUD in the tree? Both halves are needed. A
	# prompt hidden in the frame it was shown -- a kill result and a revive
	# result in one NetClient batch, or a second show, which hides first --
	# is FREED by now: hide_revive_prompt's queue_free runs at the end of that
	# frame and this resumes on the next one, so is_inside_tree on it is
	# "Attempt to call function 'is_inside_tree' in base 'previously freed'",
	# a script error (round 551; round 550 dropped the validity test). A valid
	# node off the tree -- the HUD left it, or the prompt was removed but not
	# yet freed -- has no viewport to read (round 550: is_instance_valid alone
	# let get_viewport_rect run off the tree, an engine error).
	if not is_instance_valid(panel) or not panel.is_inside_tree():
		return
	# Centred, a little below the middle, so the fallen body stays in view
	# above it. A placement of this project's own.
	var view := panel.get_viewport_rect().size
	panel.position = Vector2((view.x - panel.size.x) * 0.5, view.y * 0.62).round()

## Takes the Revive prompt down (the revive came through, or a new prompt
## replaces it). Removed from the tree at once, so a prompt shown in the
## same frame is not renamed around a node still on its way out.
func hide_revive_prompt() -> void:
	var old := get_node_or_null(REVIVE_PROMPT)
	if old == null:
		return
	remove_child(old)
	old.queue_free()

# --- The teleport board (round 578) -------------------------------------------
#
# The Dimensional Teleporter: the authored board (ifteleportboard) with its
# five area slots filled from ifteleportareaslot (TeleportBoard), five
# destinations a page, the page spinner stepping through the rest. Each row is
# a destination of the gate the player talked to, in the link table's file
# order, with its fee (World3D._open_teleport_board builds the entries from
# TeleportReader.links_from). Move emits teleport_requested; the board closes
# when the server accepts (World3D._on_teleport_result) and on any zone change.

## The board's destinations, all pages: Dictionaries {dest_id, place, fee,
## waived} (TeleportBoard.fill_rows), and the page shown.
var _teleport_entries: Array = []
var _teleport_page := 0

## Opens the teleport board for the gate `gate_name` with its destinations.
## Returns the window, or null when the archive has no board layout.
func open_teleport_board(gate_name: String, entries: Array) -> HudWindow:
	var window := open("teleport")
	if window == null:
		return null
	_teleport_entries = entries.duplicate()
	_teleport_page = 0
	var spin := window.node(TeleportBoard.SPIN_NAME) as Control
	if not window.has_meta("teleport_rows_built"):
		window.set_meta("teleport_rows_built", true)
		var slot_layout: UiLayoutParser.LayoutDef = _builder.load_layout(TeleportBoard.SLOT_LAYOUT) if _builder != null else null
		var built := TeleportBoard.build_rows(window, _builder, slot_layout,
			func(dest_id: int) -> void: teleport_requested.emit(dest_id))
		print("HudPanels: teleport board built %d of %d area slot(s)%s" % [built, TeleportBoard.SLOT_NAMES.size(),
			"" if slot_layout != null else " -- no %s in the archive, so no Move" % TeleportBoard.SLOT_LAYOUT])
		if spin != null:
			spin.connect("spin_changed", func(value: int) -> void:
				_teleport_page = value
				_fill_teleport_page())
	if spin != null:
		UiBuilder.set_spin_range(spin, 0, maxi(0, TeleportBoard.page_count(_teleport_entries.size()) - 1))
		spin.set_meta("value", 0)
		UiBuilder._spin_refresh(spin)
	_fill_teleport_page()
	print("HudPanels: teleport board for %s -- %d destination(s), %d page(s)" % [
		gate_name, _teleport_entries.size(), TeleportBoard.page_count(_teleport_entries.size())])
	return window

func _fill_teleport_page() -> void:
	var window: HudWindow = _windows.get("teleport")
	if window == null:
		return
	TeleportBoard.fill_rows(window, TeleportBoard.page_rows(_teleport_entries, _teleport_page),
		_resolve_ui(TeleportBoard.RESULT_TOKEN, ""), _resolve_ui(TeleportBoard.FREE_TOKEN, ""))

## SRREVAMP_QA_TELEPORT (World3D): turns the board to the page holding
## dest_id and presses that row's own Move button, so the request goes out
## through the same connection a click takes. False when the board is not
## open or does not list dest_id.
func qa_press_teleport_move(dest_id: int) -> bool:
	var window: HudWindow = _windows.get("teleport")
	if window == null or not window.visible:
		return false
	var index := -1
	for i in range(_teleport_entries.size()):
		if int((_teleport_entries[i] as Dictionary).get("dest_id", 0)) == dest_id:
			index = i
			break
	if index < 0:
		return false
	_teleport_page = floori(float(index) / TeleportBoard.PER_PAGE)
	var spin := window.node(TeleportBoard.SPIN_NAME) as Control
	if spin != null:
		spin.set_meta("value", _teleport_page)
		UiBuilder._spin_refresh(spin)
	_fill_teleport_page()
	# The page as drawn, so a run measures what the board showed.
	for slot_name in TeleportBoard.SLOT_NAMES:
		var slot := window.node(slot_name) as Control
		if slot == null or not slot.visible:
			continue
		var place := slot.find_child(TeleportBoard.PLACE_NAME, true, false) as Label
		var price := slot.find_child(TeleportBoard.PRICE_NAME, true, false) as Label
		print("QA TELEPORT: page %d %s: %s | %s" % [_teleport_page + 1, slot_name,
			place.text if place != null else "", price.text if price != null else ""])
	var move := TeleportBoard.move_button_for(window, dest_id)
	if move == null:
		return false
	move.pressed.emit()
	return true

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
## reused window, like the talk box. `npc_code` is the NPC's codename. It
## decides whether the repair buttons show (_show_repair_buttons); an empty
## code hides them.
func open_shop(npc_name: String, tabs: Array, npc_code: String = "") -> void:
	var window := open("store")
	if window == null:
		return
	window.set_title(npc_name)
	_shop_tabs = tabs
	_shop_selected = 0
	_build_shop_tab_strip(window)
	_build_shop_purse(window)
	_wire_repair_buttons(window)
	_show_repair_buttons(window, npc_code)
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
		place_window(bag, Vector2(view.x * 0.5 + 8.0, (view.y - bag.size.y) * 0.5).round())
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

## Wires the store's two authored repair buttons -- GDR_STORE_BTN_REPAIR
## (the selected worn slot) and GDR_STORE_BTN_REPAIRALL (everything worn) --
## to the repair op. Repair All is the one that always applies; single-slot
## repair uses the last equipment slot the player clicked, or all if none.
## On the result, the equipment list is re-read so the paper doll and the
## tooltips show the restored durability.
##
## Which stores show the two buttons is _show_repair_buttons, below.
func _wire_repair_buttons(window: HudWindow) -> void:
	if not NetClient.repair_result.is_connected(_on_repair_result):
		NetClient.repair_result.connect(_on_repair_result)
	var all_btn := window.node("GDR_STORE_BTN_REPAIRALL") as BaseButton
	if all_btn != null and not all_btn.pressed.is_connected(_on_repair_all_pressed):
		all_btn.pressed.connect(_on_repair_all_pressed)
	var one_btn := window.node("GDR_STORE_BTN_REPAIR") as BaseButton
	if one_btn != null and not one_btn.pressed.is_connected(_on_repair_one_pressed):
		one_btn.pressed.connect(_on_repair_one_pressed)

## Shows Repair and Repair All only at an NPC the server gives interaction 4
## (NpcServiceReader.offers_repair: the town smiths and armour merchants, and
## the eight fortress smiths, site 0x4c736f) and hides them at every other
## store, as the real client does (round 514). The
## client's 0xb045 NPC-select reply handler (FUN_0088b200) hides both buttons
## and then shows them again only for an NPC with id 4. That is FUN_006d2840(0)
## followed by FUN_006d2840(has4), through vtable slot 23, which is show/hide
## and not enable (the full chain is cited on offers_repair). The store is
## reached only through the NPC being talked to, so its codename stands in for
## the selected NPC. A STORE log line records which way each open went.
func _show_repair_buttons(window: HudWindow, npc_code: String) -> void:
	var shown := NpcServiceReader.offers_repair(npc_code)
	for control_name in ["GDR_STORE_BTN_REPAIR", "GDR_STORE_BTN_REPAIRALL"]:
		var btn := window.node(control_name) as Control
		if btn != null:
			btn.visible = shown
	print("STORE %s repair buttons %s (interaction 4: %s)" % [
		npc_code, "shown" if shown else "hidden", shown])

func _on_repair_all_pressed() -> void:
	var who := NetClient.current_character_name
	if who != "":
		NetClient.repair(who, EquipmentNet.REPAIR_ALL)

func _on_repair_one_pressed() -> void:
	var who := NetClient.current_character_name
	if who == "":
		return
	# Without a selected slot, "Repair" behaves like "Repair All" rather than
	# doing nothing -- a repair NPC never leaves a broken item unrepairable.
	NetClient.repair(who, _repair_selected_slot if _repair_selected_slot >= 0 else EquipmentNet.REPAIR_ALL)

## A repair's outcome in the store's status line. A refusal shows the game's
## own message where the client has one (0x1c07 not enough gold, 0x1c0b busy
## with a trade, 0x1c11 cannot be repaired, 0x1c12 cannot be revived) and our
## own wording otherwise; the table and its grounding are in
## scripts/net/error_text.gd.
## Until round 515 a refusal went to the log file only and the store showed
## nothing.
func _on_repair_result(code: int, gold_spent: int, _durabilities: Array) -> void:
	var who := NetClient.current_character_name
	if code == 0:
		print("HudPanels: repaired for %d gold" % gold_spent)
		_set_shop_status("Repaired for %s gold." % _grouped(gold_spent))
		if who != "":
			# Refresh the worn list (durability + doll) and the purse.
			NetClient.list_equipment(who)
			NetClient.character_stats(who)
	else:
		print("HudPanels: repair refused (0x%x)" % code)
		_set_shop_status(ErrorText.repair_line(code, _text_table()))

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
# The authored warehouse window (ifstorageroom) shows the ACCOUNT's stored
# items in its 6x5 lattice, one PAGE of 30 at a time: the original's
# CIFStorageRoom::Create builds exactly 0x1e slot controls and addresses a
# warehouse slot as cell + page * 0x1e (client 0x6cd350), the page chosen by
# the authored spin control GDR_STORAGE_SPIN_PAGE. The page count comes from
# the server's capacity (the trailing field of the storage list). Opening it
# puts the bag alongside: click a bag item to deposit it, click a stored item
# to withdraw it. Both moves go through the server (storage.Service), which
# shares the bag's stacking rules.
const STORAGE_PAGE_SLOTS := 30

## The warehouse as last listed, the page shown, and the server's capacity
## (0 until a list arrives -- then one page).
var _storage_slots_cache: Array = []
var _storage_page := 0
var _storage_capacity := 0

func _storage_page_count() -> int:
	return maxi(1, int(ceil(float(_storage_capacity) / STORAGE_PAGE_SLOTS)))

## Wires GDR_STORAGE_SPIN_PAGE once: stepping it redraws the lattice for
## that page.
func _wire_storage_page_spinner(window: HudWindow) -> void:
	var spin := window.node("GDR_STORAGE_SPIN_PAGE") as Control
	if spin == null or spin.has_meta("wh_wired"):
		return
	spin.set_meta("wh_wired", true)
	spin.connect("spin_changed", func(value: int) -> void:
		_storage_page = value
		_fill_storage_grid(_storage_slots_cache))

## Opens the warehouse for an NPC, with the bag beside it. Refills both from
## the server.
func open_storage(npc_name: String) -> void:
	var window := open("storage")
	if window == null:
		return
	window.set_title(npc_name)
	_wire_storage_money_button(window)
	_wire_storage_page_spinner(window)
	window.show()
	window.move_to_front()
	var bag: HudWindow = open("inventory")
	if bag != null:
		var view := get_viewport_rect().size
		window.position = Vector2(view.x * 0.5 - window.size.x - 8.0, (view.y - window.size.y) * 0.5).round()
		place_window(bag, Vector2(view.x * 0.5 + 8.0, (view.y - bag.size.y) * 0.5).round())
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
	# Keep the spinner's range on the server's capacity and the page in it.
	_storage_page = clampi(_storage_page, 0, _storage_page_count() - 1)
	var spin := window.node("GDR_STORAGE_SPIN_PAGE") as Control
	if spin != null and spin.has_meta("value"):
		UiBuilder.set_spin_range(spin, 0, _storage_page_count() - 1)
		if UiBuilder.spin_value(spin) != _storage_page:
			spin.set_meta("value", _storage_page)
			UiBuilder.set_spin_range(spin, 0, _storage_page_count() - 1)
	var first := _storage_page * STORAGE_PAGE_SLOTS
	for entry in slots:
		var index: int = entry.slot_index
		var cell_index := index - first
		if cell_index < 0 or cell_index >= mini(cells, STORAGE_PAGE_SLOTS):
			continue
		var cell := grid.get_child(cell_index)
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

func _on_storage_list_result(slots: Array, error: String, capacity: int) -> void:
	if error != "":
		push_warning("HudPanels: storage list refused: %s" % error)
		return
	# Said in the log so a QA run can read the warehouse's state after a
	# move, instead of inferring it from the absence of a refusal.
	var total := 0
	for sl in slots:
		total += int(sl.quantity)
	_storage_slots_cache = slots
	_storage_capacity = capacity
	print("HudPanels: warehouse lists %d slot(s), %d item(s); capacity %d = %d page(s) of %d" % [
		slots.size(), total, capacity, _storage_page_count(), STORAGE_PAGE_SLOTS])
	_fill_storage_grid(slots)

func _on_storage_deposit_result(ok: bool, reason: String) -> void:
	if ok:
		print("HudPanels: deposit accepted")
		_refresh_storage_and_bag()
	else:
		push_warning("HudPanels: deposit refused: %s" % reason)

func _on_storage_withdraw_result(ok: bool, reason: String) -> void:
	if ok:
		print("HudPanels: withdraw accepted")
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

func set_paper_doll_texture(texture: Texture2D) -> void:
	_paper_doll_texture = texture
	_place_paper_doll_docked()

## The paper doll's place in the equipment pane, relative to the pane (and to
## ifequipment's own origin): x 40..138, y 46..282. This is the placement the
## doll has had since it was docked -- between the two slot columns (x 5 and
## x 141, 32 wide) -- and it was chosen, not read. What the client does is
## read (CIFEquipment::vslot_013, 0x6ad8ae..0x6ad8ed): it renders the model
## into the pane's rect grown by (+2, +0x0f, -2, -0x25), i.e. (2, 15, 176, 318)
## for the 178x355 pane, with a camera that was not read. Until the camera is,
## the doll keeps its old rect rather than a new one fitted to that viewport.
const PAPER_DOLL_RECT := Rect2(40, 46, 98, 236)

## Draws the live 3D paper doll in the equipment pane of the main popup, in
## the central column between its two worn-slot columns.
func _place_paper_doll_docked() -> void:
	if _paper_doll_texture == null or _popup == null:
		return
	var pane := _popup.pane_control("GDR_EQUIPMENT")
	if pane == null or pane.get_child_count() == 0:
		return
	var eq_root := pane.get_child(0) as Control
	var doll := eq_root.get_node_or_null("PaperDoll") as TextureRect
	if doll == null:
		doll = TextureRect.new()
		doll.name = "PaperDoll"
		doll.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		doll.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		doll.mouse_filter = Control.MOUSE_FILTER_IGNORE
		# Between the equipment window's two slot columns (slots at x 5 and
		# x 141, 32 wide, over a 177-wide window): the central column x 40..138,
		# below the title bar to just above the avatar-skill strip.
		doll.position = PAPER_DOLL_RECT.position
		doll.size = PAPER_DOLL_RECT.size
		eq_root.add_child(doll)
	doll.texture = _paper_doll_texture

## The System window as CIFSystemWnd::Create (0x6f6610) leaves it, which is
## not ifsystemwnd.txt's geometry. After building the layout it:
##
## - hides Option, Help, Restart and Quit (IDs 10, 11, 13, 14; ShowWindow(0)
##   at 0x6f66b6..0x6f66e3);
## - fills a map from a row index to a button ID -- 0 -> 10, 1 -> 11,
##   3 -> 13, 4 -> 14 (0x6f66f7..0x6f673e) -- and hands the Customer Center
##   button (ID 12, GDR_SYSTEM_BTN_CAS_HELP) to 0xba0e40, which queues a
##   window on the factory's deferred list (0x110f96c), whose consumer
##   (0xba12b0 -> 0xba1190) destroys it: the client destroys the button, and
##   hiding it here shows the same;
## - for rows 0 to 4 in turn, takes each mapped button that exists, moves it
##   to the window's x + 0x1f and y + 0x3a plus 0x22 for every button placed
##   before it, and shows it (0x6f67d3..0x6f68a6);
## - then sizes the background tile (ID 5, GDR_SYSTEM_BGTILE) to 0x1c per
##   button, the inner frame (ID 6, GDR_SYSTEM_FRAME) to 15 + 0x22 per button
##   and the window itself to 0x3c + 0x26 per button, each keeping its width
##   (SetSize, slot 21, at 0x6f68bf / 0x6f68d4 / 0x6f68e7).
##
## With the four buttons that gives Option, Help, Restart and Quit at y 58,
## 92, 126 and 160, a 180x151 frame, a 148x112 tile and a 214x212 window --
## not the registry's 214x245. The button positions are relative to the
## window, which is also the layout's origin (HudWindow._add_registry_frame).
const SYSTEM_BUTTON_ROWS := ["GDR_SYSTEM_BTN_OPTION", "GDR_SYSTEM_BTN_HELP",
	"GDR_SYSTEM_BTN_RESTART", "GDR_SYSTEM_BTN_QUIT"]
const SYSTEM_DROPPED_BUTTON := "GDR_SYSTEM_BTN_CAS_HELP"
const SYSTEM_BUTTON_ORIGIN := Vector2(31, 58)
const SYSTEM_BUTTON_PITCH := 34.0
const SYSTEM_TILE := "GDR_SYSTEM_BGTILE"
const SYSTEM_TILE_PER_BUTTON := 28.0
const SYSTEM_FRAME := "GDR_SYSTEM_FRAME"
const SYSTEM_FRAME_BASE := 15.0
const SYSTEM_FRAME_PER_BUTTON := 34.0
const SYSTEM_WINDOW_BASE := 60.0
const SYSTEM_WINDOW_PER_BUTTON := 38.0

func _layout_system_window(window: HudWindow) -> void:
	var dropped := window.node(SYSTEM_DROPPED_BUTTON) as CanvasItem
	if dropped != null:
		dropped.visible = false
	var placed := 0
	for control_name in SYSTEM_BUTTON_ROWS:
		var button := window.node(control_name) as Control
		if button == null:
			continue
		_move_authored(button, SYSTEM_BUTTON_ORIGIN + Vector2(0.0, SYSTEM_BUTTON_PITCH * placed))
		button.visible = true
		placed += 1
	var tile := window.node(SYSTEM_TILE) as Control
	if tile != null:
		_resize_authored(tile, Vector2(tile.size.x, SYSTEM_TILE_PER_BUTTON * placed))
	_rebuild_resized(window, PANELS["system"][0], SYSTEM_FRAME,
		SYSTEM_FRAME_BASE + SYSTEM_FRAME_PER_BUTTON * placed)
	window.set_registry_size(Vector2(window.size.x, SYSTEM_WINDOW_BASE + SYSTEM_WINDOW_PER_BUTTON * placed))

## Moves a built control, and the rect the settling pass restores with it.
static func _move_authored(node: Control, at: Vector2) -> void:
	var rect := Rect2(at, node.size)
	if node.has_meta(UiBuilder.AUTHORED_RECT_META):
		rect = node.get_meta(UiBuilder.AUTHORED_RECT_META)
		rect.position = at
		node.set_meta(UiBuilder.AUTHORED_RECT_META, rect)
	node.position = at

## Resizes a built control, and the rect the settling pass restores with it.
static func _resize_authored(node: Control, to: Vector2) -> void:
	var rect := Rect2(node.position, to)
	if node.has_meta(UiBuilder.AUTHORED_RECT_META):
		rect = node.get_meta(UiBuilder.AUTHORED_RECT_META)
		rect.size = to
		node.set_meta(UiBuilder.AUTHORED_RECT_META, rect)
	node.custom_minimum_size = Vector2.ZERO
	node.size = to

## Rebuilds a frame control at a new height: its eight pieces are laid out
## for one size, so it is built again from its own def at the new rect and
## put back at the same place in the draw order.
func _rebuild_resized(window: HudWindow, layout_path: String, control_name: String,
		height: float) -> void:
	var old := window.node(control_name) as Control
	var layout := _builder.load_layout(layout_path) if _builder != null else null
	var sec := layout.get_section("Create") if layout != null else null
	if old == null or sec == null or not sec.control_by_name.has(control_name):
		return
	var def: UiLayoutParser.ControlDef = sec.control_by_name[control_name]
	var fresh := _builder.build_control(def.with_rect(
		Rect2i(def.rect.position, Vector2i(def.rect.size.x, int(height)))))
	if fresh == null:
		return
	var parent := old.get_parent()
	var at := old.get_index()
	parent.remove_child(old)
	old.queue_free()
	parent.add_child(fresh)
	parent.move_child(fresh, at)

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

## Closes a panel. A tab of the main popup closes the popup, but only while
## that tab is the one showing.
func close(panel_id: String) -> void:
	if HudMainPopup.hosts(panel_id):
		if is_open(panel_id):
			_popup.window.hide()
		return
	if panel_id in GUILD_VIEWS:
		panel_id = GUILD_WINDOW_KEY
	var window: HudWindow = _windows.get(panel_id)
	if window != null:
		window.hide()

## Whether this panel's window is on screen. World3D asks it before rebuilding
## the talk menu after a guild reply (round 521). For a tab of the main popup,
## the popup must be up with that tab showing.
func is_open(panel_id: String) -> bool:
	if HudMainPopup.hosts(panel_id):
		return _popup != null and _popup.is_open(panel_id)
	if panel_id in GUILD_VIEWS:
		var guild := _windows.get(GUILD_WINDOW_KEY) as GuildWindow
		return guild != null and guild.visible \
			and guild.is_community_view() == (panel_id == "community")
	var window: HudWindow = _windows.get(panel_id)
	return window != null and window.visible

## A tab of the main popup toggles the way the client's keys do
## (HudMainPopup.toggle): its key hides the popup only when its own tab is the
## one showing, and otherwise brings the popup up on it.
func toggle(panel_id: String) -> void:
	if HudMainPopup.hosts(panel_id):
		if is_open(panel_id):
			_popup.window.hide()
		else:
			open(panel_id)
		return
	if panel_id in GUILD_VIEWS:
		_toggle_guild_window(panel_id)
		return
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
	if PROJECT_HOTKEYS.has(key.keycode):
		toggle(PROJECT_HOTKEYS[key.keycode])
		get_viewport().set_input_as_handled()

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
## The item's tooltip. When cur >= 0 the item is a specific instance whose
## durability the server reported (session/durability.go's trailing block),
## so the placeholder "Durability L / L" line off the reference row is
## replaced with the instance's real current / max -- and marked broken at 0.
func _item_tooltip(item_id: int, cur: int = -1, maximum: int = -1) -> String:
	_load_items()
	var item: ItemTableReader.Item = _items.get(item_id)
	if item == null:
		return "Item %d" % item_id
	var lines := PackedStringArray(item.tooltip_lines(_object_names))
	if cur >= 0 and maximum > 0:
		for i in range(lines.size()):
			if lines[i].begins_with("Durability "):
				lines[i] = "Durability %d / %d%s" % [cur, maximum, "  (broken)" if cur == 0 else ""]
				break
	return "\n".join(lines)

## Builds slot index -> [current, max] from the durability block a list
## result stashed on NetClient, for the tooltip and the broken-icon tint.
func _durability_map(entries: Array) -> Dictionary:
	var out := {}
	for d in entries:
		out[int(d.slot)] = [int(d.current), int(d.maximum)]
	return out

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
	var durability := _durability_map(NetClient.last_inventory_durabilities)
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
			var dur: Array = durability.get(index, [])
			if dur.size() == 2:
				icon.tooltip_text = _item_tooltip(int(item_id), dur[0], dur[1])
				# A broken item (0 durability) is dimmed. The exact treatment
				# the original uses is not recovered; this grey is ours.
				icon.modulate = Color(0.45, 0.45, 0.45) if dur[0] == 0 else Color.WHITE
			else:
				icon.tooltip_text = _item_tooltip(int(item_id))
				icon.modulate = Color.WHITE
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

## A click on an inventory item. Left, while an NPC service window is open:
## sell it (shop) or deposit it (storage) -- the bag is how the client moves
## items to a vendor or the warehouse. Right: use it, which is what a potion
## is for; the server decides whether the item is usable at all, so a
## right-click on a sword is simply refused rather than doing something odd.
func _on_inventory_cell_input(event: InputEvent, icon: TextureRect) -> void:
	if not (event is InputEventMouseButton and (event as InputEventMouseButton).pressed):
		return
	if not (icon.has_meta("inv_slot") and icon.has_meta("inv_item_id")):
		return
	var button := (event as InputEventMouseButton).button_index
	var slot := int(icon.get_meta("inv_slot"))
	var item_id := int(icon.get_meta("inv_item_id"))
	var qty := int(icon.get_meta("inv_qty"))
	if button == MOUSE_BUTTON_RIGHT:
		if player_dead:
			system_notice.emit(DEAD_INPUT_LINE)
			return
		if NetClient.current_character_name != "":
			NetClient.use_item(NetClient.current_character_name, slot)
		return
	if button != MOUSE_BUTTON_LEFT:
		return
	var store: HudWindow = _windows.get("store")
	var storage_win: HudWindow = _windows.get("storage")
	if store != null and store.visible:
		_confirm_sell(slot, item_id, qty)
	elif storage_win != null and storage_win.visible:
		_confirm_deposit(slot, item_id, qty)
	else:
		# No vendor open: a press is the start of a drag -- to another bag
		# slot (move / merge / swap, the server's call) or onto a worn slot
		# of the docked paper doll (equip). Nothing is sent until it is
		# dropped somewhere that means something.
		_arm_bag_drag(slot, item_id, icon, (event as InputEventMouseButton).global_position)

# --- Dragging in the bag -----------------------------------------------------
#
# Godot's own drag-and-drop wants _get_drag_data/_can_drop_data on the
# controls involved, and the bag's cells are plain Controls built from the
# authored layout by UiBuilder. So the drag is done by hand: a press on a
# filled cell arms it, moving a few pixels starts it (a copy of the icon
# follows the mouse), and the release is resolved against the cells' own
# rects -- the 4x8 lattice at its authored 36-pixel pitch -- or the docked
# paper doll's worn slots. The server owns the outcome: a bag drop is
# OP_MOVE (move / merge / swap, its rule), a doll drop is OP_EQUIP (which it
# refuses for the wrong kind of item), and the window redraws from what it
# answers, never from what the drag assumed.

## Pixels the mouse must move before a press becomes a drag, so a plain
## click never spawns a ghost icon.
const BAG_DRAG_THRESHOLD := 4.0

var _bag_drag_slot := -1
## >= 0 while the armed drag started on a WORN item (the paper doll) rather
## than a bag cell; the value is the EquipmentNet.SLOT_* it came off.
## Dragging INTO a doll slot already worked, but dragging back out did not
## exist at all, so worn gear could not be taken off in the window at all
## (playtest 2026-09-20, item 7).
var _bag_drag_worn_slot := -1
var _bag_drag_item_id := 0
var _bag_drag_icon: TextureRect = null
var _bag_drag_origin := Vector2.ZERO
var _bag_drag_preview: TextureRect = null

func _arm_bag_drag(slot: int, item_id: int, icon: TextureRect, at: Vector2) -> void:
	_cancel_bag_drag()
	_bag_drag_slot = slot
	_bag_drag_item_id = item_id
	_bag_drag_icon = icon
	_bag_drag_origin = at

func _start_bag_drag() -> void:
	if _bag_drag_preview != null or _bag_drag_icon == null:
		return
	var preview := TextureRect.new()
	preview.texture = _bag_drag_icon.texture
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.custom_minimum_size = Vector2(32, 32)
	preview.size = Vector2(32, 32)
	preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	preview.top_level = true
	preview.z_index = 4096
	preview.modulate = Color(1, 1, 1, 0.85)
	add_child(preview)
	_bag_drag_preview = preview
	_bag_drag_icon.modulate = Color(1, 1, 1, 0.35)
	_position_bag_drag_preview(get_global_mouse_position())

func _position_bag_drag_preview(mouse: Vector2) -> void:
	if _bag_drag_preview != null:
		_bag_drag_preview.global_position = mouse - Vector2(16, 16)

func _cancel_bag_drag() -> void:
	if _bag_drag_preview != null:
		_bag_drag_preview.queue_free()
		_bag_drag_preview = null
	if _bag_drag_icon != null and is_instance_valid(_bag_drag_icon):
		_bag_drag_icon.modulate = Color.WHITE
	_bag_drag_icon = null
	_bag_drag_slot = -1
	_bag_drag_worn_slot = -1
	_bag_drag_item_id = 0

## Which bag cell (its slot index) is under a screen point, or -1. Cells are
## GDR_INVENTORY_LATTICE's children in slot order, the same indexing
## _fill_inventory_grid draws by.
func _bag_slot_at(point: Vector2) -> int:
	var window: HudWindow = _windows.get("inventory")
	if window == null or not is_open("inventory"):
		return -1
	var grid := window.node("GDR_INVENTORY_LATTICE") as Control
	if grid == null:
		return -1
	for i in range(grid.get_child_count()):
		var cell := grid.get_child(i) as Control
		if cell != null and cell.get_global_rect().has_point(point):
			return i
	return -1

## Which worn slot of the docked paper doll is under a screen point (an
## EquipmentNet.SLOT_* index), or -1.
func _equipment_slot_at(point: Vector2) -> int:
	var window: HudWindow = _windows.get("inventory")
	if window == null or not is_open("inventory"):
		return -1
	for i in range(17):
		var slot := window.node("GDR_EQUIPMENT_SLOT_%d" % (EQUIPMENT_SLOT_BASE + i)) as Control
		if slot != null and slot.is_visible_in_tree() and slot.get_global_rect().has_point(point):
			return i
	return -1

## The drag's motion and release arrive here rather than on the cell, since
## the mouse has left it by then. Nothing is consumed unless a drag actually
## ends on a release, so ordinary clicks elsewhere are unaffected.
# --- Dragging a skill out of the skill window --------------------------------
#
# The same hand-rolled drag as the bag's: a press on a learned skill arms it,
# moving past the threshold starts it (a ghost of the icon follows the mouse),
# and the release is handed to World3D with the screen position -- it owns the
# underbar and resolves the quickslot. A release without movement is a click,
# and keeps the "next free slot" shortcut.

var _skill_drag_id := 0
var _skill_drag_code := ""
var _skill_drag_icon: Texture2D = null
var _skill_drag_source: Control = null
var _skill_drag_origin := Vector2.ZERO
var _skill_drag_preview: TextureRect = null
var _skill_drag_armed := false

func _arm_skill_drag(skill_id: int, basic_code: String, icon: Texture2D, source: Control, at: Vector2) -> void:
	_cancel_skill_drag()
	_skill_drag_id = skill_id
	_skill_drag_code = basic_code
	_skill_drag_icon = icon
	_skill_drag_source = source
	_skill_drag_origin = at
	_skill_drag_armed = true

func _start_skill_drag() -> void:
	if _skill_drag_preview != null or _skill_drag_icon == null:
		return
	var preview := TextureRect.new()
	preview.texture = _skill_drag_icon
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.custom_minimum_size = Vector2(32, 32)
	preview.size = Vector2(32, 32)
	preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	preview.top_level = true
	preview.z_index = 4096
	preview.modulate = Color(1, 1, 1, 0.85)
	add_child(preview)
	_skill_drag_preview = preview
	if _skill_drag_source != null:
		_skill_drag_source.modulate = Color(1, 1, 1, 0.35)
	_skill_drag_preview.global_position = get_global_mouse_position() - Vector2(16, 16)

func _cancel_skill_drag() -> void:
	if _skill_drag_preview != null:
		_skill_drag_preview.queue_free()
		_skill_drag_preview = null
	if _skill_drag_source != null and is_instance_valid(_skill_drag_source):
		_skill_drag_source.modulate = Color(1, 1, 1, 1)
	_skill_drag_source = null
	_skill_drag_armed = false

func _skill_drag_input(event: InputEvent) -> bool:
	if not _skill_drag_armed:
		return false
	if event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		if _skill_drag_preview == null:
			if motion.global_position.distance_to(_skill_drag_origin) >= BAG_DRAG_THRESHOLD:
				_start_skill_drag()
		if _skill_drag_preview != null:
			_skill_drag_preview.global_position = motion.global_position - Vector2(16, 16)
		return true
	if event is InputEventKey and (event as InputEventKey).pressed and (event as InputEventKey).keycode == KEY_ESCAPE:
		if _skill_drag_preview != null:
			_cancel_skill_drag()
			get_viewport().set_input_as_handled()
		return true
	if event is InputEventMouseButton and not (event as InputEventMouseButton).pressed \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var dragging := _skill_drag_preview != null
		var at := (event as InputEventMouseButton).global_position
		var id := _skill_drag_id
		var code := _skill_drag_code
		var icon := _skill_drag_icon
		_cancel_skill_drag()
		if dragging:
			get_viewport().set_input_as_handled()
			skill_drop_requested.emit(at, id, code, icon)
		else:
			skill_assign_requested.emit(id, code, icon)
		return true
	return false

func _input(event: InputEvent) -> void:
	if _skill_drag_input(event):
		return
	# A worn drag arms with a bag slot of -1 (it has none), so the guard has
	# to admit it too or the drag is never driven.
	if _bag_drag_slot < 0 and _bag_drag_worn_slot < 0:
		return
	if event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		if _bag_drag_preview == null:
			if motion.global_position.distance_to(_bag_drag_origin) >= BAG_DRAG_THRESHOLD:
				_start_bag_drag()
		_position_bag_drag_preview(motion.global_position)
		return
	if event is InputEventKey and (event as InputEventKey).pressed and (event as InputEventKey).keycode == KEY_ESCAPE:
		if _bag_drag_preview != null:
			_cancel_bag_drag()
			get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton and not (event as InputEventMouseButton).pressed \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var dragging := _bag_drag_preview != null
		var from := _bag_drag_slot
		var worn_from := _bag_drag_worn_slot
		var at := (event as InputEventMouseButton).global_position
		_cancel_bag_drag()
		if not dragging:
			return  # a click, not a drag: nothing to do
		get_viewport().set_input_as_handled()
		if worn_from >= 0:
			_drop_worn_item(worn_from, at)
		else:
			_drop_bag_item(from, at)

## A worn item dragged off the paper doll and released. Anywhere over the bag
## takes it off; a release back on the doll, or outside the window, does
## nothing rather than erroring.
##
## Which bag slot it lands in is the server's to choose, so the drop point
## inside the grid is not passed on: unequip means "take this off", and the
## bag redraws from the answer.
func _drop_worn_item(worn_slot: int, at: Vector2) -> void:
	var who := NetClient.current_character_name
	if who == "" or not NetClient.is_connected_to_server():
		return
	if _equipment_slot_at(at) >= 0:
		return
	# ANYWHERE over the inventory window takes it off, not just dead-on a grid
	# cell. Requiring an exact cell is why "i cant unequip my clothes" and "when
	# i drag and unequip my sword, it doesnt go off of my character" were both
	# reported (playtest 2026-09-20): a release a few pixels into a gutter did
	# nothing at all, and said nothing either. The server still chooses the bag
	# slot -- the drop point was never passed on -- so accepting a looser target
	# changes where you may let go, not where the item lands.
	if _bag_slot_at(at) < 0 and not _over_inventory_window(at):
		return
	NetClient.unequip(who, worn_slot)
	NetClient.list_inventory(who)

## Whether a global point is over the open inventory window at all.
func _over_inventory_window(at: Vector2) -> bool:
	var win: HudWindow = _windows.get("inventory")
	if win == null or not is_open("inventory"):
		return false
	return win.get_global_rect().has_point(at)

## Resolves where a bag drag ended and asks the server for it.
func _drop_bag_item(from: int, at: Vector2) -> void:
	var who := NetClient.current_character_name
	if who == "" or not NetClient.is_connected_to_server():
		return
	var to := _bag_slot_at(at)
	if to >= 0:
		if to != from:
			NetClient.move_item(who, from, to)
		return
	var worn := _equipment_slot_at(at)
	if worn >= 0:
		# Equip out of that bag slot; the server refuses a wrong kind of
		# item for the slot. Its equipment result redraws the doll, and the
		# bag is re-read since the item left it.
		NetClient.equip(who, worn, from)
		NetClient.list_inventory(who)
		return
	# Neither a bag slot nor the doll: offer it to the quickslot bar, which
	# World3D owns. It ignores a release that is not over a slot.
	var icon := _bag_icon_at_slot(from)
	item_drop_requested.emit(at, _bag_item_id_at_slot(from), from, icon)

## The ItemIcon drawn for a bag slot, or null. The icons live on the cells of
## the inventory lattice and carry inv_slot/inv_item_id metadata, which is what
## _fill_inventory_grid puts there.
func _bag_icon_node(slot: int) -> TextureRect:
	var window: HudWindow = _windows.get("inventory")
	if window == null:
		return null
	var grid := window.node("GDR_INVENTORY_LATTICE") as Control
	if grid == null:
		return null
	for cell in grid.get_children():
		var icon := cell.get_node_or_null("ItemIcon") as TextureRect
		if icon != null and icon.has_meta("inv_slot") and int(icon.get_meta("inv_slot")) == slot:
			return icon
	return null

## The icon texture currently drawn in a bag slot, or null.
func _bag_icon_at_slot(slot: int) -> Texture2D:
	var icon := _bag_icon_node(slot)
	return icon.texture if icon != null else null

## The item id in a bag slot, or -1.
func _bag_item_id_at_slot(slot: int) -> int:
	var icon := _bag_icon_node(slot)
	if icon == null or not icon.has_meta("inv_item_id"):
		return -1
	return int(icon.get_meta("inv_item_id"))

## The server's answer to a move: the whole bag as it now stands, or the
## refusal. Drawn from the answer, so a refused move leaves the grid as it was.
func _on_inventory_move_result(slots: Array, error: String) -> void:
	if error != "":
		push_warning("HudPanels: bag move refused: %s" % error)
		print("HudPanels: bag move refused: %s" % error)
		return
	_fill_inventory_grid(slots)
	print("HudPanels: bag after move: %s" % _describe_bag(slots))

## "slot:item xqty" per occupied slot, for the log lines the QA hooks read.
static func _describe_bag(slots: Array) -> String:
	var parts := PackedStringArray()
	for entry in slots:
		var index = _first_field(entry, ["slot", "slot_index", "index"])
		var item_id = _first_field(entry, ["item_id", "id"])
		var quantity = _first_field(entry, COUNT_FIELDS)
		parts.append("%s:%s x%s" % [str(index), str(item_id), str(quantity) if quantity != null else "1"])
	return "{" + ", ".join(parts) + "}"

## QA only (SRREVAMP_QA_MOVE="from,to"): exercises a bag move end to end with
## a REAL item and nothing seeded. A new character's bag is empty -- its kit
## is equipped straight out of it -- so the sequence first unequips the boots
## (real OP_UNEQUIP; they land in the lowest free slot, 0), lists the bag,
## sends the move, and prints the bag before and after from the server's own
## answers. Both lines are what a render's log is checked against. Never
## fires in real play.
var _qa_move_from := -1
var _qa_move_to := -1
var _qa_move_stage := 0  # 0 idle, 1 unequipping, 2 listing, 3 moved

func qa_move_sequence(spec: String) -> void:
	var parts := spec.split(",", false)
	if parts.size() != 2 or not parts[0].strip_edges().is_valid_int() or not parts[1].strip_edges().is_valid_int():
		printerr("QA MOVE: bad spec '%s' (want from,to)" % spec)
		return
	_qa_move_from = int(parts[0].strip_edges())
	_qa_move_to = int(parts[1].strip_edges())
	var who := NetClient.current_character_name
	if who == "" or not NetClient.is_connected_to_server():
		printerr("QA MOVE: no connected character")
		return
	_qa_move_stage = 1
	NetClient.equipment_result.connect(_qa_move_on_equipment)
	NetClient.inventory_list_result.connect(_qa_move_on_list)
	NetClient.inventory_move_result.connect(_qa_move_on_moved)
	print("QA MOVE: unequipping boots so the bag holds something real")
	NetClient.unequip(who, EquipmentNet.SLOT_BOOTS)

func _qa_move_on_equipment(_items: Array, error: String) -> void:
	if _qa_move_stage != 1:
		return
	if error != "":
		printerr("QA MOVE: unequip refused: %s" % error)
		_qa_move_stage = 0
		return
	_qa_move_stage = 2
	NetClient.list_inventory(NetClient.current_character_name)

func _qa_move_on_list(slots: Array, error: String) -> void:
	if _qa_move_stage != 2 and _qa_move_stage != 4:
		return
	if error != "":
		printerr("QA MOVE: list refused: %s" % error)
		_qa_move_stage = 0
		return
	if _qa_move_stage == 4:
		# The bag after the drop onto the doll: the boots left it again.
		_qa_move_stage = 0
		print("QA MOVE equip-drop: bag %s (dropped slot %d on the doll's boots rect)" % [_describe_bag(slots), _qa_move_to])
		return
	print("QA MOVE before: %s" % _describe_bag(slots))
	_qa_move_stage = 3
	NetClient.move_item(NetClient.current_character_name, _qa_move_from, _qa_move_to)

func _qa_move_on_moved(slots: Array, error: String) -> void:
	if _qa_move_stage != 3:
		return
	if error != "":
		_qa_move_stage = 0
		print("QA MOVE after: REFUSED (%s)" % error)
		return
	print("QA MOVE after: %s (asked %d -> %d)" % [_describe_bag(slots), _qa_move_from, _qa_move_to])
	# Then put them back on by "dropping" the moved slot onto the doll's
	# boots slot -- through _drop_bag_item and the same rect hit-test a real
	# drag resolves against -- and read the bag once more. Stage 4 is set
	# at the drop itself, not here: the panel's own opening lists the bag in
	# between, and that answer must not be mistaken for the drop's.
	_qa_move_stage = 5
	_qa_move_drop_when_doll_ready()

## The network round trips above finish before the QA harness has opened
## the inventory window, so the doll's slot controls may not exist yet: wait
## for them (up to ~20 s) rather than report a drop target that is merely
## not built yet.
func _qa_move_drop_when_doll_ready() -> void:
	var slot_name := "GDR_EQUIPMENT_SLOT_%d" % (EQUIPMENT_SLOT_BASE + EquipmentNet.SLOT_BOOTS)
	for _attempt in range(80):
		var window: HudWindow = _windows.get("inventory")
		if window != null and window.visible:
			var boots := window.node(slot_name) as Control
			if boots != null and boots.is_visible_in_tree():
				var at := boots.get_global_rect().get_center()
				print("QA MOVE equip-drop: dropping bag slot %d at %s (the doll's boots rect)" % [_qa_move_to, str(at.round())])
				_qa_move_stage = 4
				_drop_bag_item(_qa_move_to, at)
				return
		await get_tree().create_timer(0.25).timeout
	_qa_move_stage = 0
	print("QA MOVE equip-drop: the inventory window never opened, nothing to drop on")

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
## The worn slot the store's single "Repair" button acts on, or -1 for
## "repair all" (no per-slot selection UI exists yet -- disclosed).
var _repair_selected_slot: int = -1

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

## leveldata.txt's column 2 -- the skill points raising a mastery costs, by the
## mastery's current level -- read once from the player's own Media.pk2 (see
## LevelDataReader for the grounding). Empty when the archive lacks the table;
## the LEVEL UP button then shows no cost rather than a made-up one.
var _level_mastery_costs: Dictionary = {}
var _level_data_loaded := false

func _load_level_data() -> void:
	if _level_data_loaded:
		return
	_level_data_loaded = true
	if _builder == null:
		return
	var archive := _builder.media_archive()
	if archive == null:
		return
	var entry := ObjectLoader.find_file(archive, LevelDataReader.TABLE_PATH)
	if entry != null:
		_level_mastery_costs = LevelDataReader.parse_mastery_costs(archive.read_file(entry))
	print("HudPanels: %d mastery cost(s) read from leveldata" % _level_mastery_costs.size())

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
## Every level's unique skill id -> {"range", "approach"} for THAT level: its
## Range (skilldata col 21, CRefSkill +0x92; 0 = use the weapon's) and whether
## the skill tick walks into reach before casting it
## (CombatNet.skill_tick_approaches, from Target_Required col 22 and
## TargetType_Land col 24). Built from _skill_grid. The id is the one a cast
## sends, so World3D can decide the approach before it sends (skill_reach).
var _skill_reach_by_id: Dictionary = {}

## The player's skill state as the server reports it: skill points, and each
## mastery's trained level. Empty until the server sends it (set_skill_state),
## so a fresh window shows every skill greyed -- as the real one does.
var _skill_points: int = 0
var _skill_mastery_levels: Dictionary = {}   ## mastery id -> level
## The character level, which no single mastery may pass (the LEVEL UP button's
## per-mastery check); 0 until the server reports it (set_skill_state).
var _skill_char_level: int = 0
## The unique skill ids the character has learned (a set), from the server --
## a learned skill shows its level badge instead of a "+" learn button.
var _skill_known: Dictionary = {}

## How an unlearned skill's icon is dimmed. The locked tint is the darker of
## the two -- it stands in for the authored "locked book" art when the archive
## has none; the unlearned tint keeps a met-but-unlearned skill legible.
## Neither is read out of the client: they are ours, and are a display choice
## rather than a recovered value.
const SKILL_UNLEARNED_TINT := Color(0.62, 0.62, 0.62, 0.9)
const SKILL_LOCKED_TINT := Color(0.45, 0.45, 0.45, 0.85)

## Whether the server has told us this exact skill id is learned. World3D asks
## before putting a skill on a quickslot, so no path can shortcut a skill onto
## the hotbar that the character does not have (playtest 2026-09-20, item 3).
func is_skill_known(skill_id: int) -> bool:
	return _skill_known.has(skill_id)

## The mastery-total cap: the sum of a China character's mastery levels may reach
## 330, flat, whatever its level. Recovered from the server's Mastery_LevelUp
## (0x0059c4e0): for Country 0 (China) it refuses unless `sum + requested < 0x14b`;
## Europe's rule is min(240, 2 x level), but every srrevamp character is China.
## Matches the server's session.MasteryTotalCapChina; docs/RE_COMPLETION.md,
## round 483. (It was "3 x level" before -- an extrapolation from a retail
## account, not a reading of the binary.)
const MASTERY_TOTAL_CAP := 330

## The highest mastery level whose raise costs skill points: 120. Not a cap on the
## mastery. Mastery_LevelUp (0x0059c4e0) sums leveldata column 2 in a loop whose
## `cmp esi,0x78 ; jg` (0x59c64e) jumps to the skill-point check, not a refusal,
## so a raise from above 120 is free; and a level-0 mastery skips the loop and the
## check entirely (0x59c628), so a mastery's first point is free too. Matches the
## server's session.MasteryCostLevelCeiling; docs/RE_COMPLETION.md, round 484.
## One value with LevelDataReader's, which applies the same bound to the cost.
const MASTERY_COST_LEVEL_CEILING := LevelDataReader.MASTERY_COST_LAST_LEVEL

## Why the mastery LEVEL UP button is greyed, or "" when the server would take
## the raise. Checked in Mastery_LevelUp's (0x0059c4e0) own order, so the reason
## is the one the server would refuse with: the total (0x3805), then the
## character level (0x3804), then the skill points (0x3802). total_cap is the
## flat MASTERY_TOTAL_CAP (round 483). cost is LevelDataReader.mastery_up_cost
## for the mastery's current level -- 0 when the engine charges nothing (a
## mastery's first point, or a level past MASTERY_COST_LEVEL_CEILING) or the
## archive has no leveldata.
static func mastery_levelup_block_reason(real_level: int, char_level: int, total_now: int,
		total_cap: int, skill_points: int, cost: int) -> String:
	if total_now >= total_cap:
		return "Total mastery cap reached (%d / %d)." % [total_now, total_cap]
	if char_level > 0 and real_level >= char_level:
		return "This mastery is at your character-level cap (Lv %d). Level up your character to raise it." % char_level
	if skill_points <= 0 and real_level > 0 and real_level <= MASTERY_COST_LEVEL_CEILING:
		return "Not enough skill points."
	# 0x3802 is refused only when the cost is ABOVE the points: `cmp eax,[ecx+0x80]
	# ; jbe 0x59c6a9` at 0x59c694 lets cost == points through, hence strict <.
	if cost > 0 and skill_points < cost:
		return "Needs %d skill points to raise this mastery (you have %d)." % [cost, skill_points]
	return ""

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
## The skill-name table (textdata_equip&skill.txt): a skill's UI_SkillName
## (skilldata col 62, an `SN_SKILL_*` id) and its SN_ description resolve here,
## not in the UI system table -- without it every tooltip showed the raw key.
## Same file family as textdata_object.txt for items; parsed the same way.
const SKILL_NAME_TABLE_PATH := "server_dep\\silkroad\\textdata\\textdata_equip&skill.txt"
var _skill_names: UiTextTable = null

## The table a skill's name or description id resolves through: the
## equip&skill table when it loaded, else the UI system table.
func _skill_text_table() -> UiTextTable:
	return _skill_names if _skill_names != null else _text_table()

func _load_skill_catalog() -> void:
	if _skill_catalog_loaded:
		return
	_skill_catalog_loaded = true
	if _builder == null:
		return
	var archive := _builder.media_archive()
	if archive == null:
		return
	var names_entry := ObjectLoader.find_file(archive, SKILL_NAME_TABLE_PATH)
	if names_entry != null:
		_skill_names = UiTextTable.parse(archive.read_file(names_entry))
		print("HudPanels: skill names read from %s" % SKILL_NAME_TABLE_PATH.get_file())
	else:
		print("HudPanels: no %s -- skill names show their SN_ ids" % SKILL_NAME_TABLE_PATH.get_file())
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
	for key in _skill_grid:
		for entry in _skill_grid[key]:
			var bs: SkillDataReader.BaseSkill = entry
			# Per level, not the level-1 range_val: the server measures a cast
			# with that level's own row (session/skill.go, ref.Range), and the
			# four SKILL_CH_BOW_SPECIAL skills' Range rises 2 a level.
			for i in bs.level_ids.size():
				var level_id := int(bs.level_ids[i])
				if level_id > 0:
					_skill_reach_by_id[level_id] = {
						"range": int(bs.level_range[i]),
						"approach": CombatNet.skill_tick_approaches(
							int(bs.level_target_required[i]), int(bs.level_target_land[i])),
					}
	print("HudPanels: skill catalog -- %d masteries with groups, %d group-rows of skills"
		% [_skill_groups.size(), _skill_grid.size()])
	if OS.has_environment("SRREVAMP_QA_PANELS"):
		var dbg := ""
		for r in range(9):
			var k := "257:%d" % r
			if _skill_grid.has(k):
				dbg += " row%d=%d" % [r, (_skill_grid[k] as Array).size()]
		print("HudPanels: Bicheon(257) rows:%s" % dbg)

## How a cast meets its target, by the unique per-level id the cast sends:
## {"range": that level's Range (skilldata col 21, world units; 0 = the
## weapon's), "approach": whether the skill tick walks into reach first
## (CombatNet.skill_tick_approaches)}, or {} when the archive's catalog does
## not carry that id. Loads the catalog on first use, so a cast works without
## the window ever being opened.
func skill_reach(skill_id: int) -> Dictionary:
	_load_skill_catalog()
	return _skill_reach_by_id.get(skill_id, {})

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
## skills and the character level (for the per-mastery level cap).
func _apply_skill_state(state: SkillNet.SkillState) -> void:
	set_skill_state(state.skill_points, state.mastery_levels, state.level, state.known_skills)

## After a mastery raise, re-read the state so the totals and the lit/greyed
## skills refresh. A refusal is said in chat (it was dropped silently before)
## and still refreshes: the window may be showing state the server has moved
## past, which is the likeliest reason it offered a raise that was refused.
func _on_raise_mastery_result(result: SkillNet.RaiseMasteryResult) -> void:
	if result.error != "":
		print("HudPanels: mastery raise refused: %s" % result.error)
		system_notice.emit("The mastery was not raised: %s." % result.error)
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
	_load_level_data()
	_load_skill_catalog()
	# QA: SRREVAMP_QA_SKILL_STATE="sp=9,level=3,257=3" sets the points, the
	# character level and any mastery levels (id=level) the board explains
	# against, so a render can show a given player's window without a server.
	if OS.has_environment("SRREVAMP_QA_SKILL_STATE"):
		for part in OS.get_environment("SRREVAMP_QA_SKILL_STATE").split(",", false):
			var kv: PackedStringArray = String(part).split("=")
			if kv.size() != 2 or not kv[1].strip_edges().is_valid_int():
				continue
			var key := kv[0].strip_edges()
			match key:
				"sp": _skill_points = int(kv[1])
				"level": _skill_char_level = int(kv[1])
				_:
					if key.is_valid_int():   # "257=3": mastery id 257 at level 3
						_skill_mastery_levels[int(key)] = int(kv[1])
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

	# Skill points and total mastery level against the flat 330 total cap, from
	# the server's state.
	_set_label(window, "GDR_SKILL_TEXT_SP_NUM", str(_skill_points))
	# The real server total (a QA lighting override must not pollute it).
	var total := 0
	for lvl in _skill_mastery_levels.values():
		total += int(lvl)
	var total_text := "%d / %d" % [total, MASTERY_TOTAL_CAP]
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
	levelup.name = "SkillMasteryLevelUp"
	levelup.text = _resolve_ui("UIIT_CTL_SKILL_MASTERY_LEVELUP", "LEVEL UP")
	levelup.position = Vector2(150, 3)
	levelup.custom_minimum_size = Vector2(80, 22)
	levelup.focus_mode = Control.FOCUS_NONE
	_style_skill_tab(levelup)
	levelup.pressed.connect(_on_mastery_levelup.bind(mastery.id))
	# Grey it and say why when the mastery can't be raised: the flat 330 total,
	# the character's level, and the skill points against the raise's real cost
	# (leveldata column 2 at the current level) -- all server-enforced; this just
	# explains it before the click. See mastery_levelup_block_reason for the
	# order and the grounding.
	var real_level := int(_skill_mastery_levels.get(mastery.id, 0))
	var total_now := 0
	for lvl in _skill_mastery_levels.values():
		total_now += int(lvl)
	var cost := LevelDataReader.mastery_up_cost(_level_mastery_costs, real_level)
	var reason := mastery_levelup_block_reason(real_level, _skill_char_level, total_now,
		MASTERY_TOTAL_CAP, _skill_points, cost)
	if reason != "":
		levelup.disabled = true
		levelup.tooltip_text = reason
	elif cost > 0:
		levelup.tooltip_text = "Raising this mastery to Lv %d costs %d skill points (you have %d)." % [
			real_level + 1, cost, _skill_points]
	elif real_level == 0 or real_level > MASTERY_COST_LEVEL_CEILING:
		# The two raises the engine never charges (LevelDataReader.mastery_up_cost).
		levelup.tooltip_text = "Raising this mastery to Lv %d costs no skill points." % (real_level + 1)
	if OS.has_environment("SRREVAMP_QA_SKILL_STATE"):
		print("QA SKILL: %s Lv %d, %d SP, char Lv %d, total %d/%d, cost %d -> LEVEL UP %s%s" % [
			mastery.display_name(_text_table()), real_level, _skill_points, _skill_char_level, total_now,
			MASTERY_TOTAL_CAP, cost, "disabled: " if reason != "" else "enabled", reason])
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
			# A skill whose mastery requirement is met but which has NOT been
			# learned drew in full colour, identical to a learned one bar the
			# level badge (playtest 2026-09-20, item 4). Dim it: the icon is
			# still readable, and "you do not have this yet" is visible at a
			# glance rather than inferred from a missing badge.
			if learned == 0:
				icon.modulate = SKILL_UNLEARNED_TINT
		elif disable_tex != null:
			icon.texture = disable_tex   # the real "locked" book
		else:
			icon.texture = _load_skill_icon(s.icon_path)
			icon.modulate = SKILL_LOCKED_TINT
		icon.mouse_filter = Control.MOUSE_FILTER_PASS
		icon.tooltip_text = _skill_cell_tooltip(s, learned, mastery)
		if OS.has_environment("SRREVAMP_QA_SKILL_STATE") and group.row == 0 and col == 0:
			print("QA SKILL: first cell (%s) state: learned=%d available=%s; tooltip:\n%s" % [
				s.basic_code, learned, str(available), icon.tooltip_text])

		# A learned skill shows its level badge over the icon's lower-right, and
		# clicking it casts that skill (World3D picks the target and animates).
		if learned > 0 and badge_tex != null:
			_add_level_badge(cell, badge_tex, learned)
		if learned > 0:
			var cast_id: int = s.level_ids[learned - 1]
			var cast_code: String = s.basic_code
			var cast_icon: Texture2D = icon.texture
			# A press arms a drag (see _input): moving starts it and the release
			# drops the skill on a quickslot; a plain click keeps the shortcut of
			# putting it on the next free slot.
			icon.gui_input.connect(func(ev: InputEvent) -> void:
				if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
					_arm_skill_drag(cast_id, cast_code, cast_icon, icon, (ev as InputEventMouseButton).global_position))

		# The "+" appears when the next level is within the current mastery level;
		# the server enforces the SP cost (refdata ReqLearnSP) and refunds on fail.
		var next_level := learned + 1
		var can_learn := next_level <= s.max_level and next_level <= s.level_reqs.size() \
			and mastery_level >= s.level_reqs[next_level - 1] and s.level_ids[next_level - 1] > 0
		# The real prerequisites too (skilldata ReqLearn_Skill1..3): another
		# skill group known at a level. The server refuses these as well; the
		# window simply doesn't offer the "+" and says so in the tooltip.
		var missing := _missing_prerequisites(s, next_level)
		if not missing.is_empty():
			can_learn = false
			icon.tooltip_text += "\nRequires: " + ", ".join(missing)
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
			add_btn.tooltip_text = "Learn %s Lv %d" % [s.display_name(_skill_text_table()), next_level]
			cell.add_child(add_btn)

## The highest contiguous level of a skill the character has learned (0 = not
## learned). Learning is sequential, so this is how many of the skill's levels
## from level 1 up are in the server's known-skills set.
## The prerequisite groups of s's level `level` that the character has not
## reached, as "Name Lv N" strings (the group's name when the window knows the
## group, else its id). Empty when the level is learnable on that count.
func _missing_prerequisites(s: SkillDataReader.BaseSkill, level: int) -> Array:
	var out: Array = []
	if level < 1 or level > s.level_prereqs.size():
		return out
	for pair in s.level_prereqs[level - 1]:
		var group_id := int(pair[0])
		var need := int(pair[1])
		var have := 0
		var other: SkillDataReader.BaseSkill = _skill_by_base_id(group_id)
		if other != null:
			have = _skill_learned_level(other)
		if have < need:
			var label := other.display_name(_skill_text_table()) if other != null else "skill %d" % group_id
			out.append("%s Lv %d" % [label, need])
	return out

## The board's BaseSkill for a skill group id (skilldata GroupID / base id),
## or null when the archive's board does not carry it.
func _skill_by_base_id(base_id: int) -> SkillDataReader.BaseSkill:
	for key in _skill_grid:
		for entry in _skill_grid[key]:
			var bs: SkillDataReader.BaseSkill = entry
			if bs.base_id == base_id:
				return bs
	return null

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
func _skill_cell_tooltip(s: SkillDataReader.BaseSkill, learned: int, mastery: MasteryReader.Mastery = null) -> String:
	var names := _skill_text_table()
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
	# The next level's real learn gate, stated against what the player HAS --
	# so a locked skill says why it is locked instead of only what it costs.
	# The numbers are skilldata's own (ReqCommon_MasteryLevel1 col 36,
	# ReqLearn_SP col 46); the SP label is the client's own UIIT_STT_NEED_SP.
	# A level-3 fighter asked why Bicheon 3 offered nothing: its first skill,
	# SKILL_CH_SWORD_SMASH_A_01, needs Bicheon 5, and a mastery cannot pass the
	# character's level (Mastery_LevelUp refuses with 0x3804) -- both were true
	# and neither was on screen.
	if learned < s.max_level:
		var nxt: int = learned + 1
		var sp: int = s.level_sp[nxt - 1] if nxt - 1 < s.level_sp.size() else 0
		var req: int = s.level_reqs[nxt - 1] if nxt - 1 < s.level_reqs.size() else s.min_req_mastery_level
		var mname: String = mastery.display_name(_text_table()) if mastery != null else "mastery"
		var have: int = _mastery_level(mastery.id) if mastery != null else 0
		lines.append("Learn Lv %d: %s Lv %d required (yours: Lv %d)" % [nxt, mname, req, have])
		lines.append("%s: %d" % [_resolve_ui("UIIT_STT_NEED_SP", "Skill point needed"), sp])
		if req > have:
			if _skill_char_level > 0 and req > _skill_char_level:
				lines.append("A mastery cannot pass your character level (Lv %d). Reach character level %d, then raise %s to Lv %d." % [
					_skill_char_level, req, mname, req])
			else:
				lines.append("Raise %s to Lv %d (LEVEL UP) first." % [mname, req])
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
	if not is_open("skill"):
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
	if not is_open("skill"):
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
	# The equipment is a pane of the main popup, shown with the bag on its
	# inventory tab; its slots hang under the popup's panel_root, so node() finds them.
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
	var durability := _durability_map(NetClient.last_equipment_durabilities)
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
			var dur: Array = durability.get(int(slot_index), [])
			if dur.size() == 2:
				icon.tooltip_text = _item_tooltip(int(item_id), dur[0], dur[1])
				icon.modulate = Color(0.45, 0.45, 0.45) if dur[0] == 0 else Color.WHITE
			else:
				icon.tooltip_text = _item_tooltip(int(item_id))
				icon.modulate = Color.WHITE
			icon.mouse_filter = Control.MOUSE_FILTER_STOP
			# Press to arm a drag OFF the doll -- the same hand-rolled drag
			# the bag uses, with the worn slot as its source. Without this
			# the worn icons took clicks and did nothing, so nothing could
			# be removed in the window (playtest 2026-09-20, item 7).
			var worn_slot := int(slot_index)
			if not icon.has_meta("worn_drag_wired"):
				icon.set_meta("worn_drag_wired", true)
				icon.gui_input.connect(func(ev: InputEvent) -> void:
					if ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed \
							and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
						_arm_worn_drag(worn_slot, icon, (ev as InputEventMouseButton).global_position))

## Arms a drag that starts on a worn item. The bag's drag machinery does the
## rest; _bag_drag_worn_slot is what tells the release which way it went.
func _arm_worn_drag(worn_slot: int, icon: TextureRect, at: Vector2) -> void:
	_arm_bag_drag(-1, 0, icon, at)
	_bag_drag_worn_slot = worn_slot

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
	# A drag's outcome comes back as the whole bag (see _drop_bag_item).
	NetClient.inventory_move_result.connect(_on_inventory_move_result)
	NetClient.equipment_result.connect(func(items: Array, error: String) -> void:
		# A refusal carries no item list. Redrawing from it blanked every
		# worn slot on the doll while the body stayed dressed -- so a refused
		# equip is logged and the last known equipment stays on screen.
		if error != "":
			push_warning("HudPanels: equipment: %s" % error)
			print("HudPanels: equipment refused: %s" % error)
			return
		_equipped_items = items
		_fill_equipment_slots(items))
	# The skill window shows the masteries (client data, _fill_skill_masteries),
	# not the server's small skill catalogue, so its list result is not drawn
	# here -- it would overlap the mastery rows.
	NetClient.quest_list_result.connect(func(entries: Array, _e: String) -> void:
		_fill_list("quest", entries.map(_describe_named)))
	# The friend list fills the community view's friend rows (GuildWindow.
	# fill_friends, the client's own row fill), as it filled the old
	# window's list overlay.
	NetClient.friend_list_result.connect(_on_friend_list_result)
	# Every reply that says which guild the player is in: info, create and
	# join carry it, a successful leave means none.
	NetClient.guild_info_result.connect(_on_guild_info_result)
	NetClient.guild_create_result.connect(_on_guild_info_result)
	NetClient.guild_join_result.connect(_on_guild_info_result)
	NetClient.guild_leave_result.connect(_on_guild_leave_result)
	# Replies that arrived before this node existed (World3D asks for the
	# guild and the friends before its loading screen and builds the HUD
	# after it): NetClient keeps the last of each.
	if NetClient.last_guild_result != null:
		_on_guild_info_result(NetClient.last_guild_result)
	if NetClient.has_friend_list:
		_on_friend_list_result(NetClient.last_friend_list, "")
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

## A friend list from the server: kept, and drawn on the guild window's
## friend rows if the window exists (it is drawn from the kept list when it
## is built later). A refused list changes nothing.
func _on_friend_list_result(friends: Array, error: String) -> void:
	if error != "":
		return
	_friends = friends.duplicate()
	var guild := _windows.get(GUILD_WINDOW_KEY) as GuildWindow
	if guild != null:
		guild.fill_friends(_friends)

## A guild reply (info, create or join): whether the player is in a guild
## (guild id not 0), its name and its master, which the guild window's
## information draws (0x5b5eb0). World3D still handles the rest of the
## reply. A refused reply changes nothing.
func _on_guild_info_result(result: GuildNet.Result) -> void:
	if result == null or result.error != "":
		return
	_guild_result = result
	var guild := _windows.get(GUILD_WINDOW_KEY) as GuildWindow
	if guild != null:
		_apply_guild(guild)

## A successful leave: no guild.
func _on_guild_leave_result(ok: bool, _reason: String) -> void:
	if ok:
		_on_guild_info_result(GuildNet.Result.new())

func _apply_guild(window: GuildWindow) -> void:
	var r := _guild_result
	if r == null or r.guild_id == 0:
		window.set_guild(false)
		return
	var master := ""
	for m in r.members:
		if m.role == GuildNet.ROLE_LEADER or (r.leader_id != 0 and m.character_id == r.leader_id):
			master = m.member_name
			break
	window.set_guild(true, r.guild_name, master)

## The character pane's own control names, from resinfo\\ifplayerinfo_trijob2.txt,
## the layout CIFPlayerInfo::Create (0x6b84ec) loads. Every name wired below is
## in it at the same rect as in the older ifplayerinfo.txt, which the exe
## never loads. The full difference (every property of every control
## compared, docs/RE_COMPLETION.md round 591): trijob2 drops the trader,
## hunter and thief rows (their _TITLE, _GRADE, name, _EXP, gauge, _BOARD and
## _ICON, 21 controls), GDR_PI_ARRANGE_ICON / _DATA and GDR_PI_DECO_MID_DOWN
## (16,320,332x36); it adds GDR_PI_JOB_ALIAS/_TITLE/_GRADE/_ICON/_EXP, their
## three _STA labels, GDR_PI_JOB_EXP_GAUGE, GDR_PI_DECO_JOB_AREA (0,260, drawn
## 364x96 from chr_job_window.ddj) and two CIFCheckBoxes (93434, 93435); it
## moves the STR/INT labels (x 17 -> 5) and the honour label; and it changes
## the editor Color ids of the tiles, frame and decorations and the
## decorations' FontColor. Every value field is the `_DAT` -- or
## `2` -- sibling of its label: the label `GDR_PI_TEXT_CURXP` sits at (32, 41)
## and the VALUE `GDR_PI_TEXT_CURXP2` at (96, 41), likewise `NEXTXP`/`NEXTXP2`
## and `STAT`/`STAT2`. The "+" buttons beside Str and Int are named
## `BTN_ADDHP` / `BTN_ADDMP` in the layout -- a point on Str raises HP, on Int
## raises MP -- and sit at (62, 109) and (62, 138), the Str and Int rows.
const CHARACTER_FIELDS := {
	"GDR_PI_TEXT_LEVEL": "level",
	"GDR_PI_TEXT_HP_DAT": "hp",
	"GDR_PI_TEXT_MP_DAT": "mp",
	"GDR_PI_TEXT_STRENGTH_DAT": "strength",
	"GDR_PI_TEXT_INTELLECT_DAT": "intellect",
	"GDR_PI_TEXT_CURXP2": "current_exp",
	"GDR_PI_TEXT_NEXTXP2": "next_exp",
	"GDR_PI_TEXT_STAT2": "stat_points",
}

## Fills the character panel's vitals from the world's own knowledge (HP and
## MaxHP arrive with EnterWorldResult and on every attack). The level the
## world passes is a placeholder 1; the real level, and every other row, come
## with the server's stats result (_apply_stats), which is authoritative
## once it has arrived.
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
		_set_gauge(window, "GDR_PI_GAUGE_HPGAUGE", _character_hp, _character_max_hp)
	# The title row is the server's once its stats have arrived; before that
	# the world's placeholder level is all there is.
	if _character_level > 0 and _stats == null:
		values["GDR_PI_TEXT_LEVEL"] = _level_title(_character_level)
	for control_name in values:
		var label := window.node(control_name) as Label
		if label != null:
			label.text = values[control_name]

## Fills every field the server actually has a number for -- see
## _fill_character_window for the row-by-row account of what is shown, from
## where, and what is deliberately left as the layout drew it.
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
			# The number on the authored gold row, so a render's log can be
			# held against the frame (and against the server's own value).
			print("HudPanels: inventory gold readout %s (server gold %d)" % [gold.text, stats.gold])
	# The shop's own purse line, if the store is open.
	_update_shop_purse()

	var character: HudWindow = _windows.get("character")
	if character != null:
		_fill_character_window(character, stats)

var _stats: StatsNet.Stats = null
var _stat_buttons_wired := false

## The character window, row by row, from the server's stats result.
##
## SHOWN, each from a real source:
##   title            level                 (the client formats UIIT_STT_LV_LEVEL
##                                          with the level byte -- CIFPlayerInfo)
##   Current Exp.     exp                   absolute, as the client's own %I64d
##   Next Exp.        exp_to_next           leveldata's exp to advance from this level
##   Stat point       stat_points           the unspent pool; the "+" buttons spend it
##   Str / Int        str / intel           the stored stats
##   HP / MP          hp/max, mp/max        "%d / %d" over the chr_hp / chr_mp gauges
##   Phy. atk         phys_attack_min ~ max combat.WeaponRange, physical (Str reinforce)
##   Mag. atk         mag_attack_min ~ max  combat.WeaponRange, magical (Int reinforce)
##   Phy. def.        phys_defense          the armour sum combat mitigates with
##   Mag. def.        mag_defense           the same sum over the magical column
##
## LEFT AS THE LAYOUT DREW THEM, each with its reason:
##   Phy./Mag. balance   the client shows a stored byte (CICPlayer+0x20d8) whose
##                       source is unread; this server computes no balance.
##   Hit rate / Parry    engine params 11 / 9: a base of 10.0 plus each worn
##                       item's own per-instance rate, which needs the item
##                       variance this server does not carry -- and the engine
##                       never reads either param (docs/RE_COMPLETION.md).
##   Job alias/grade/exp  (GDR_PI_JOB_*) no job system on this server.
##   Honor point         no honour system on this server.
## A guessed number in any of these would be indistinguishable from a real one.
func _fill_character_window(window: HudWindow, s: StatsNet.Stats) -> void:
	_set_label(window, "GDR_PI_TEXT_LEVEL", _level_title(s.level))
	_set_label(window, "GDR_PI_TEXT_CURXP2", _grouped(s.exp))
	_set_label(window, "GDR_PI_TEXT_NEXTXP2", _grouped(s.exp_to_next) if s.exp_to_next > 0 else "")
	if s.max_hp > 0:
		_set_label(window, "GDR_PI_TEXT_HP_DAT", "%d / %d" % [s.hp, s.max_hp])
		_set_gauge(window, "GDR_PI_GAUGE_HPGAUGE", s.hp, s.max_hp)
	if s.max_mp > 0:
		_set_label(window, "GDR_PI_TEXT_MP_DAT", "%d / %d" % [s.mp, s.max_mp])
		_set_gauge(window, "GDR_PI_GAUGE_MPGAUGE", s.mp, s.max_mp)
	_set_label(window, "GDR_PI_TEXT_PHYDEF_DAT", str(s.phys_defense))
	if s.has_character_rows:
		_set_label(window, "GDR_PI_TEXT_STAT2", str(s.stat_points))
		_set_label(window, "GDR_PI_TEXT_STRENGTH_DAT", str(s.str))
		_set_label(window, "GDR_PI_TEXT_INTELLECT_DAT", str(s.intel))
		_set_label(window, "GDR_PI_TEXT_PHYATT_DAT", "%d ~ %d" % [s.phys_attack_min, s.phys_attack])
		_set_label(window, "GDR_PI_TEXT_MAGATT_DAT", "%d ~ %d" % [s.mag_attack_min, s.mag_attack_max])
		_set_label(window, "GDR_PI_TEXT_MAGDEF_DAT", str(s.mag_defense))
	else:
		# A server too old to send the rows: the one number it does send.
		_set_label(window, "GDR_PI_TEXT_PHYATT_DAT", str(s.phys_attack))
	_wire_stat_buttons(window)
	for button_name in ["GDR_PI_BTN_ADDHP", "GDR_PI_BTN_ADDMP"]:
		var button := window.node(button_name) as BaseButton
		if button != null:
			button.disabled = not s.has_character_rows or s.stat_points <= 0
	# Every row next to the server's number, so a render's log is checked
	# against the frame and against the server rather than by eye.
	print("HudPanels: character window: %s | exp %d / next %d | stat points %d | str %d int %d | hp %d/%d mp %d/%d | phy %d~%d def %d | mag %d~%d def %d | rows sent: %s" % [
		_level_title(s.level), s.exp, s.exp_to_next, s.stat_points, s.str, s.intel,
		s.hp, s.max_hp, s.mp, s.max_mp, s.phys_attack_min, s.phys_attack, s.phys_defense,
		s.mag_attack_min, s.mag_attack_max, s.mag_defense, str(s.has_character_rows)])
	# QA: SRREVAMP_QA_SPEND_STAT=1 presses the Str "+" once as soon as there is
	# a point to spend, so a render's log shows the round trip (str +1, pool
	# -1, MaxHP up) against the server's own reply.
	if OS.get_environment("SRREVAMP_QA_SPEND_STAT") != "" and not _qa_spent_stat \
			and s.has_character_rows and s.stat_points > 0:
		_qa_spent_stat = true
		_spend_stat_point(1, 0)

var _qa_spent_stat := false

## The title row: the client's own UIIT_STT_LV_LEVEL string with the level in
## it (CIFPlayerInfo formats that key with the level byte). Falls back to a
## plain "Lv N" when the text table is not loaded.
func _level_title(level: int) -> String:
	var fmt := _resolve_ui("UIIT_STT_LV_LEVEL", "")
	if fmt.contains("%d"):
		return fmt % level
	if fmt != "":
		return "%s %d" % [fmt, level]
	return "Lv %d" % level

## A TextureProgressBar built for a CIFGauge (UiBuilder._build_gauge, max 100).
func _set_gauge(window: HudWindow, control_name: String, value: int, maximum: int) -> void:
	var gauge := window.node(control_name) as TextureProgressBar
	if gauge == null or maximum <= 0:
		return
	gauge.value = clampf(float(value) / float(maximum), 0.0, 1.0) * 100.0

## The "+" buttons spend one stat point each: BTN_ADDHP is the Str row's, and
## a point on Str raises HP; BTN_ADDMP is the Int row's, raising MP -- which
## is why the layout names them so. The server applies the engine's rule
## (GObjPC_SpendStatPoints: refused unless the spend fits the pool, else a
## plain increment) and answers with the refreshed stats, which redraws.
func _wire_stat_buttons(window: HudWindow) -> void:
	if _stat_buttons_wired:
		return
	var plus_str := window.node("GDR_PI_BTN_ADDHP") as BaseButton
	var plus_int := window.node("GDR_PI_BTN_ADDMP") as BaseButton
	if plus_str == null and plus_int == null:
		return
	_stat_buttons_wired = true
	if plus_str != null:
		plus_str.pressed.connect(func() -> void: _spend_stat_point(1, 0))
	if plus_int != null:
		plus_int.pressed.connect(func() -> void: _spend_stat_point(0, 1))

func _spend_stat_point(str_points: int, int_points: int) -> void:
	if not NetClient.is_connected_to_server() or NetClient.current_character_name == "":
		return
	if _stats != null and _stats.stat_points <= 0:
		return
	print("HudPanels: spending %d stat point(s) on %s" % [str_points + int_points, "Str" if str_points > 0 else "Int"])
	NetClient.spend_stat_points(NetClient.current_character_name, str_points, int_points)

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
	last_populated = panel_id
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
			# The equipment pane shows with the bag; refresh it too.
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
##
## (The guild window was the other example; it is built from
## res_ui\\guild.2dt now and fills its own rows, GuildWindow.)
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
