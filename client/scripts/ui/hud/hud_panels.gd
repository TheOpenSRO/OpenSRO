extends Control
class_name HudPanels

## Owns every floating game window: creates them on first use, toggles them
## by hotkey or from the underbar's buttons and menu (HudUnderbar, whose
## menu_action names a panel here), and fills them from NetClient.
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
const QuestWindow = preload("res://scripts/ui/hud/quest_window.gd")
const AlchemyWindow = preload("res://scripts/ui/hud/alchemy_window.gd")
const OptionWindow = preload("res://scripts/ui/hud/option_window.gd")
const GoldColor = preload("res://scripts/ui/gold_color.gd")

## key: the panel id used by the underbar's menu_action and by the keys.
## Each entry is [layout path, window title].
##
## **The keys are not here**: they are the retail client's key table,
## KeyMap.SLOTS (round 608), whose "panel:<id>" slots name these ids --
## C character, I inventory, S skill, A action, P party, Q quest, U guild,
## T auto potion, E party matching, Y alchemy, L academy. Equipment has no
## key, as in retail (it is the pane beside the bag); nor do the windows an
## NPC or Escape opens.
##
## **Inventory, equipment, character, skill, party, action and academy are
## not windows of their own**: they are panes of the client's main popup
## (HudMainPopup, `resinfo\\ifmainpopup.txt` in the registry's GDR_MAINPOPUP
## frame), and their keys select its tabs. Their layout paths here are the
## panes' own layouts, which HudMainPopup.PANE_LAYOUTS builds.
const PANELS := {
	"inventory": ["resinfo\\ifinventory.txt", "Inventory"],
	# The equipment pane, beside the bag on the popup's inventory tab.
	"equipment": ["resinfo\\ifequipment.txt", "Equipment"],
	# CIFPlayerInfo::Create (0x6b84ec) loads ifplayerinfo_trijob2.txt; the
	# exe never names ifplayerinfo.txt, in ASCII or UTF-16.
	"character": ["resinfo\\ifplayerinfo_trijob2.txt", "Character"],
	"skill": ["resinfo\\ifskill.txt", "Skill"],
	# Q toggles CNIFQuest, window 0x4c, built from the client's own
	# `res_ui\\questlist.2dt` (QuestWindow): 0x7990e0 (ShowWindow(0) if it is
	# shown, else ShowWindow(1)). The retail binding is Q (slot 5 of 0x7778be).
	"quest": [QuestWindow.QUESTLIST_2DT, ""],
	"party": ["resinfo\\ifparty.txt", "Party"],
	# The guild and community are one window, CNIFGuildWnd, built from the
	# client's `res_ui\*.2dt` files (GuildWindow); these two ids are its two
	# views. U is the retail binding and opens the guild view: the default
	# key table at 0x7778be puts 'U' in slot 6, which reaches the guild
	# window's toggle 0x5b4980. No default key opens the community view; the
	# underbar menu's community item (108, 0x60ce67 -> 0x5b49c0) does.
	"community": [GuildWindow.GUILD_2DT, ""],
	"guild": [GuildWindow.GUILD_2DT, ""],
	"action": ["resinfo\\ifaction.txt", "Action"],
	"partymatch": ["resinfo\\ifpartymatch.txt", "Party Matching"],
	"academy": ["resinfo\\ifapprenticeship.txt", "Academy"],
	"autopotion": ["resinfo\\ifautopotion.txt", "Auto Potion"],
	# Y opens the client's alchemy window, CNIFEnchantWnd, built from
	# `res_ui\nifenchantwnd.2dt` (AlchemyWindow): slot 24 of the default key
	# table is 'Y', command 0x59, which 0x780610 sends to 0x780a65 and on to
	# 0x798e20 -- destroy window 0xa8 if it exists, load the file if not. The
	# window is built at every open and freed at every close (open_alchemy,
	# close_alchemy). ifalchemyprocess.txt, the panel this id used to build,
	# belongs to GDR_ALCHEMYBOX, which the client never shows.
	"alchemy": [AlchemyWindow.ENCHANT_2DT, ""],
	"exchange": ["resinfo\\ifexchange.txt", "Exchange"],
	# Opened by Escape, not a hotkey (see _unhandled_key_input). The system
	# menu the original raises over everything: Option, Help, Restart, Exit.
	"system": ["resinfo\\ifsystemwnd.txt", "System"],
	# Opened by clicking an NPC (World3D._try_talk_to_npc), titled with the
	# NPC's name. GDR_NPCWINDOW (registry-framed, REGISTRY_FRAMES) built from
	# if_npcwindow.txt, its CIF_NPCTalk box filled from if_npctalk.txt
	# (NpcTalkView, round 725). A Dimensional Gate's destinations are this
	# box's own lines (open_teleport_list, round 603): the client has no
	# teleport window. PANEL_FALLBACKS builds the talk box alone where the
	# archive (or a test's) has no if_npcwindow.txt.
	"npctalk": ["resinfo\\if_npcwindow.txt", ""],
	# Opened from the talk box's store lines (open_shop), titled with the
	# NPC's name. GDR_STORE (registry-framed, 254x370) with ifstore.txt's
	# renewal + buy-back branch, by config\define.txt (ARCHIVE_DEFINE_PANELS).
	"store": ["resinfo\\ifstore.txt", "Store"],
	# Opened from the talk box's Storage option (open_storage). The authored
	# warehouse window: a 6x5 grid of the character's stored items.
	"storage": ["resinfo\\ifstorageroom.txt", "Storage"],
	# Round 789: the blacksmith's grant window (GrantMagicAttributeWindow),
	# opened by the talk line kind 0x2f's 0xB046 {1, 0x20} (open_grant_window).
	"grant": [GrantMagicAttributeWindow.LAYOUT, "GrantMagicAttribute"],
	# Round 837: the item mall, CIFNewItemMall (GDR_RENEWAL_ITEM_MALL, ID
	# 167, 800x600; ItemMallController). F10's warning box opens it.
	"itemmall": [ItemMallController.LAYOUT, "Item Mall"],
}

## M opens the world map, the retail binding (read): the default key table
## at 0x7778be puts 'M' in slot 7, 0x778310 turns slot 7 into command 0x4d,
## and 0x780610 sends 0x4d (jump table 0x780e48 / 0x780e00) to 0x78087d,
## which calls 0x79abe0 -- CNIFWorldMap's toggle, the same function the
## minimap's map button reaches. The window is World3D's (HudWorldmap, beside
## the minimap), so this only asks for it. The key is KeyMap's slot 7.
signal world_map_toggle_requested
## The world map window (World3D's HudWorldmap), set by World3D so Escape can
## close it (_escape_close).
var world_map: Control

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
## The quest windows besides the list (round 785, QuestHud): the NPC's quest
## pages, the detail, the reward window, the guide icon under the minimap and
## the quest information list. The list itself (QuestWindow) draws
## NetClient.quest, the client's quest log.
var quest_hud: QuestHud = null
## The last panel id _populate was asked for (a test hook).
var last_populated := ""

## Panels whose layout is read with #ifdef branch selection, mapped to the
## symbols defined for them. Every other window keeps the default (read both
## branches), which is what they rely on.
const PANEL_DEFINES := {}

## Panels whose layout and registry entry take their #ifdef branches from the
## client's own symbol table, `config\define.txt` (UiBuilder.archive_defines;
## round 725, docs/protocol/npc_gui.md §0). Round 724 read that the file is
## the define source; it defines RENEWAL_SHOP_SYSTEM and
## RESTORE_SOLDITEM_INSHOP, so the store is CIFStoreForPackage's 254x370 with
## the buy-back row (READ) -- before this the store took neither branch by a
## guess (`PANEL_DEFINES "store": []`). if_npcwindow, if_npctalk and
## ifstorageroom have no #ifdef, so they are read as before; GDR_STORE's and
## GDR_NPCWINDOW's registry entries take the table too (REGISTRY_FRAMES). The
## other #ifdef windows keep their hand-picked defines (HudChat, "exchange"
## below), which the archive's table also defines (round 725's census,
## docs/rounds/r725.md).
const ARCHIVE_DEFINE_PANELS := ["store", "itemmall"]

## A panel to build instead when its own layout does not build (round 725):
## the NPC talk box alone, self-framed, as before GDR_NPCWINDOW.
const PANEL_FALLBACKS := {
	"npctalk": ["resinfo\\if_npctalk.txt", ""],
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
## - **store** (round 725): GDR_STORE (CIFStoreForPackage), 254x370 under
##   RENEWAL_SHOP_SYSTEM + RESTORE_SOLDITEM_INSHOP, which config\define.txt
##   defines (§0 of docs/protocol/npc_gui.md). Its Text is empty: the store
##   is titled with the NPC's name (0x704050 -> 0x6d2a90, READ). Until round
##   725 it was left out because the two #ifdefs looked unsettled.
## - **npctalk** (round 725): GDR_NPCWINDOW (CIF_NPCWindow), 386x451, empty
##   Text; CIF_NPCWindow::Create 0x704b40 loads if_npcwindow.txt
##   (NpcTalkView). Titled with the NPC's name.
##
## Not here, each for a stated reason:
## - **community / guild**: the retail windows are CNIFGuildWnd and its child
##   CNIFCommunityWnd, built from `res_ui\*.2dt` (GuildWindow), with
##   CNIFMainFrame's chrome; GDR_COMMUNITY's layout is never loaded.
## - **alchemy**: the retail window is CNIFEnchantWnd, built from
##   `res_ui\nifenchantwnd.2dt` with CNIFMainFrame's chrome (AlchemyWindow).
##   GDR_ALCHEMYBOX (CIFAlchemyBox) is created hidden and never shown.
##
## `"archive_defines": true` reads the entry's #ifdef branches with
## config\define.txt (ARCHIVE_DEFINE_PANELS).
const REGISTRY_FRAMES := {
	"store": {"name": "GDR_STORE", "archive_defines": true},
	"npctalk": {"name": "GDR_NPCWINDOW", "archive_defines": true},
	"storage": {"name": "GDR_STORAGEROOM"},
	"exchange": {"name": "GDR_EXCHANGE",
		"defines": ["APPLY_EXCHANGE_UPDATE_1TH", "UI_UPDATE_2009_FIRST"]},
	"system": {"name": "GDR_SYSTEM"},
	"partymatch": {"name": "GDR_PARTY_MATCH"},
	"autopotion": {"name": "GDR_AUTO_POTION"},
	# Round 789: GDR_GRANT_MAGIC_ATTRIBUTE (CIFGrantMagicAttributeWnd), 272x395,
	# UIIT_STT_ALCHEMYBOX_ENCHANT_MAGIC_PARAM, under APPLY_AVATAR_SYSTEM, which
	# config\define.txt defines (MEASURED).
	"grant": {"name": GrantMagicAttributeWindow.REGISTRY, "archive_defines": true},
	# Round 837: ginterface's NewItemMall section, under #ifdef NEW_ITEMMALL
	# (config\define.txt defines it).
	"itemmall": {"name": "GDR_RENEWAL_ITEM_MALL", "archive_defines": true},
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
## - **exchange** (round 834's fix): CIFExchange::Create (0x7b27d0) fetches
##   GDR_EXCHANGE_USER_NAME (ID 153, `effect\icon\icon_effect1.ddj` at the
##   opponent grid's rect) into +0x33e0 and hides it at once (0x7b29c0..
##   0x7b29dd, vslot +0x5c with 0) -- the only control Create hides. Left
##   shown, its dark blue art covered the opponent's grid from the start.
##   0x7b2210 shows it again only while 0x81a620 holds for control 14
##   (+0x7c4): that control's +0x7b0 set and equal to the global at
##   0x110f608. What sets those is OPEN (exchange.md OPEN 8); it stays
##   hidden here.
##
## (The alchemy entry went with the panel it hid a button of: that panel was
## ifalchemyprocess.txt, CIFAlchemyProcess inside GDR_ALCHEMYBOX, which the
## client never shows; Y opens CNIFEnchantWnd, AlchemyWindow.)
const HIDDEN_AT_CREATE := {
	"academy": ["GDR_APPRENTICESHIP_PICTURE"],
	"exchange": ["GDR_EXCHANGE_USER_NAME"],
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
##   with a value above zero (round 789, READ c:0x6abde0: a worn, awake
##   devil's spirit; AvatarEquipment.skill_strip_shown).
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
	if avatar != _equipment_avatar_mode:
		print("HudPanels: equipment %s view" % ("avatar" if avatar else "equipment"))
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
	_set_shown(window, AVATAR_SKILL_STRIP, _avatar_skill_strip_shown())
	_show_equipment_backdrops()

# --- the avatar slots (round 789) ----------------------------------------------
#
# AvatarEquipment holds the rules (READ c:0x6abcd0, c:0x6ad180, c:0x6abde0);
# here they are drawn and sent. The avatar inventory is NetClient's
# (last_avatar_instances: storage slot -> ItemInstance). Each display window
# GDR_AVATAR_SLOT_01..05 shows the item of its TYPE (hat, dress, attachment,
# flag, devil's spirit) whatever storage slot it sits in; the storage slot is
# what goes on the wire.

## Whether the devil's spirit's skill strip shows now (AvatarEquipment). Its
## four skill slots stay empty: which skills fill them needs the skill
## table's +0x61 and +0xfc bytes, not READ (OPEN, docs/rounds/r789ac.md).
func _avatar_skill_strip_shown() -> bool:
	return AvatarEquipment.skill_strip_shown(_equipment_avatar_mode, NetClient.last_avatar_instances, item_types)

## A display window's control (0 hat .. 4 devil's spirit), or null.
func _avatar_slot_control(display: int) -> Control:
	var window: HudWindow = _windows.get("inventory")
	if window == null or display < 0 or display >= AVATAR_SLOT_NAMES.size():
		return null
	return window.node(AVATAR_SLOT_NAMES[display]) as Control

## ChildItemCount of an item id (itemdata col 159), 0 when unknown.
func _child_item_count(item_id: int) -> int:
	_load_items()
	var item: ItemTableReader.Item = _items.get(item_id)
	return item.child_item_count if item != null else 0

## Draws the avatar inventory into the five display windows, greys the
## attachment window under a dress that takes none, and shows or hides the
## skill strip. A left click on a filled window picks it up (kind "avatar");
## putting it down on the bag sends 0x23 (_drop_avatar_to_bag). A right click
## does nothing, as on a worn slot (OURS: the avatar slots' right click is not
## READ, AVATAR_RESEARCH.md OPEN 1).
func _fill_avatar_slots() -> void:
	var window: HudWindow = _windows.get("inventory")
	if window == null:
		return
	var storage: Dictionary = NetClient.last_avatar_instances
	var shown := AvatarEquipment.by_display(storage, item_types)
	for d in AvatarEquipment.DISPLAYS:
		var slot := _avatar_slot_control(d)
		if slot == null:
			continue
		var icon := slot.get_node_or_null("ItemIcon") as TextureRect
		if icon == null:
			continue
		if not shown.has(d):
			icon.texture = null
			_set_item_tip(icon, -1)
			_set_item_seal_edge(icon, -1)
			if icon.has_meta("avatar_slot"):
				icon.remove_meta("avatar_slot")
			continue
		var storage_slot: int = shown[d]
		var it: ItemInstance = storage[storage_slot]
		var ref := it.ref_item_id
		icon.texture = _item_icon(ref)
		_set_item_seal_edge(icon, ref)
		_set_item_tip(icon, ref, "avatar", storage_slot)
		icon.modulate = Color.WHITE
		icon.mouse_filter = Control.MOUSE_FILTER_STOP
		icon.set_meta("avatar_slot", storage_slot)
		icon.set_meta("avatar_item_id", ref)
		if not icon.has_meta("avatar_click_wired"):
			icon.set_meta("avatar_click_wired", true)
			icon.gui_input.connect(func(ev: InputEvent) -> void:
				if _is_pick_click_on(ev, icon) and icon.texture != null and icon.has_meta("avatar_slot"):
					pick_up_icon({"kind": "avatar", "slot": int(icon.get_meta("avatar_slot")),
						"item_id": int(icon.get_meta("avatar_item_id", 0)), "icon": icon.texture},
						icon.texture, icon, (ev as InputEventMouseButton).global_position))
	# The attachment window under a dress whose ChildItemCount is 0 (READ
	# c:0x6ae6a3: FUN_00b8f540(0) + FUN_006668f0(1) on window 2). How the
	# disabled window is drawn is not READ (OURS: greyed, as a broken item).
	var att := _avatar_slot_control(AvatarEquipment.DISPLAY_ATTACHMENT)
	if att != null:
		att.modulate = Color(0.45, 0.45, 0.45) if AvatarEquipment.attachment_disabled(storage, item_types, _child_item_count) else Color.WHITE
	_set_shown(window, AVATAR_SKILL_STRIP, _avatar_skill_strip_shown())
	# The held avatar is let go when its slot no longer holds it.
	if held_icon != null and held_icon.is_holding() and held_icon.kind() == "avatar":
		var held_slot := int(held_icon.payload.get("slot", -1))
		if not storage.has(held_slot) or (storage[held_slot] as ItemInstance).ref_item_id != int(held_icon.payload.get("item_id", -2)):
			cancel_held_icon("the avatar slot changed")

## Whether a point is over the equipment pane, shown. The pane control
## GDR_EQUIPMENT carries the authored rect (198,41,178,355); its layout's root
## (_equipment_root) is a 0x0 holder, so testing that missed every drop --
## round 791, MEASURED: `root [P: (644, 197), S: (0, 0)]`, the avatar put down
## on GDR_AVATAR_SLOT_01 and nothing sent.
func _over_equipment_pane(at: Vector2) -> bool:
	var pane := _popup.pane_control("GDR_EQUIPMENT") if _popup != null else null
	return pane != null and pane.is_visible_in_tree() and pane.get_global_rect().has_point(at)

## Round 829: a bag item put down on the equipment window, or a quick slot
## holding it pressed (0x60b850 case 0x46 -> the same CIFEquipment::vslot_028,
## 0x6ad180): the worn slot its TypeIDs choose (EquipTarget.worn_slot_for --
## the ring to slot 11, else 12 when 11 is worn, else 11 again), 0x7034 type
## 0 to it; an avatar to its storage slot (_drop_avatar_from_bag). The server
## swaps out what is worn there. False when the item has no slot (nothing is
## sent and nothing said, as in the original).
func equip_from_bag(from: int) -> bool:
	var types := bag_item_types(from)
	if AvatarEquipment.is_avatar_item(types):
		_drop_avatar_from_bag(from)
		return true
	var worn := EquipTarget.worn_slot_for(types, func(s: int) -> bool: return not worn_item_types(s).is_empty())
	if worn < 0:
		print("HudPanels: bag slot %d (%s) has no worn slot -- nothing sent" % [from, str(types)])
		return false
	var who := NetClient.current_character_name
	if who == "" or not NetClient.is_connected_to_server():
		return false
	# The server swaps with what is worn there; its equipment result redraws
	# the doll, and the bag is re-read since the item left it.
	UiSounds.expect_move(types, "equipped (bag -> equipment)")
	print("HudPanels: equip bag slot %d into worn slot %d" % [from, worn])
	var id := _bag_item_id_at_slot(from)
	if id >= 0:
		equip_pending[id] = true
	NetClient.equip(who, worn, from)
	NetClient.list_inventory(who)
	return true

## Round 829: items whose equip is on its way (until the next equipment
## reply), so a quick slot holding one is not cleared by a bag list that
## arrives before the worn list does (World3D._resync_quickslot_items).
var equip_pending := {}
## Whether an equipment list has come in this session (before it, a quick
## slot holding a worn item cannot be told from one whose item is gone).
var equipment_known := false

## The item ids worn now (the server's last equipment list).
func worn_item_ids() -> Dictionary:
	var out := {}
	for e in _equipped_items:
		if e is EquipmentNet.Equipped:
			out[(e as EquipmentNet.Equipped).item_id] = (e as EquipmentNet.Equipped).slot
	return out

## A bag avatar put down on the equipment window (READ CIFEquipment::vslot_028
## c:0x6ad180, either mode -- the research names no mode test, and the hovered
## slot is not looked at): the client's own refusal in the system line, or
## 0x7034 type 0x24 to the storage slot AvatarEquipment.drop_target picks.
func _drop_avatar_from_bag(from: int) -> void:
	var types := bag_item_types(from)
	var target := AvatarEquipment.drop_target(types, NetClient.last_avatar_instances, item_types)
	if target.is_empty():
		return
	if target.has("refuse"):
		var key := String(target["refuse"])
		print("HudPanels: avatar drop refused by the client (%s)" % key)
		system_notice.emit(_tip_text(key, key))
		return
	if not NetClient.is_connected_to_server():
		return
	UiSounds.expect_move(types, "equipped (bag -> avatar)")
	print("HudPanels: avatar equip bag slot %d -> avatar slot %d" % [from, int(target["dst"])])
	NetClient.avatar_equip(from, int(target["dst"]))

## A worn avatar put down on the bag: 0x7034 type 0x23 with the bag cell
## clicked (READ c:0x7950b0: the server puts it in the first free slot anyway,
## s:0x525ac0). Over the bag window but not on a cell, the first empty bag
## slot is named (OURS, as a worn item's drop there, _drop_worn_item).
func _drop_avatar_to_bag(avatar_slot: int, at: Vector2) -> void:
	if not NetClient.is_connected_to_server() or _over_equipment_pane(at):
		return
	var to := _bag_slot_at(at)
	if to < 0:
		to = maxi(first_empty_bag_slot(), 0)
	var it = NetClient.last_avatar_instances.get(avatar_slot)
	UiSounds.expect_move(item_types((it as ItemInstance).ref_item_id) if it != null else PackedInt32Array(),
		"unequipped (avatar -> bag)")
	print("HudPanels: avatar unequip avatar slot %d -> bag slot %d" % [avatar_slot, to])
	NetClient.avatar_unequip(avatar_slot, to)

## An avatar move's reply (NetClient.avatar_move_result): a refusal's line in
## the system line (AvatarNet.MOVE_REFUSAL_KEYS); a success redraws the avatar
## slots and asks for the bag (OpenSRO's bag list draws the grid).
func _on_avatar_move_result(r: Dictionary) -> void:
	UiSounds.move_replied(bool(r.get("ok", false)))
	if not bool(r.get("ok", false)):
		system_notice.emit(AvatarNet.move_refusal_line(int(r.get("code", 0)), Callable(self, "_tip_text")))
		return
	_fill_avatar_slots()
	var who := NetClient.current_character_name
	if who != "" and NetClient.is_connected_to_server():
		NetClient.list_inventory(who)

# --- The party window (round 711, lane C1) -------------------------------
#
# The GDR_PARTY pane is filled by HudPartyPane from the client's party state
# (PartyState, NetClient.party), built with the main popup. Its requests go
# out through these signals; World3D sends them (NetClient.party_create ...).
# The settings dialog (CIFSetPartyMode, child 70 of the pane) and the
# invitation box (HUD request kind 6) are shown from here too.

## Invite out of a party: create a party with this player (0x7060).
signal party_create_requested(target_world_id: int)
## Invite into this party (0x7062).
signal party_invite_requested(target_world_id: int)
## Leave (0x7061), also the leader's Dismiss.
signal party_leave_requested
## Banish a member (0x7063).
signal party_kick_requested(member_jid: int)
## The Party match button: the matching window (lane C2's).
signal party_match_requested
## The invitation box's answer (0x3080).
signal party_answer_requested(accept: bool)

## The party state the pane draws; NetClient.party when not set (tests set
## their own).
var party_state: PartyState = null
## The world's hooks for the pane (HudPartyPane's Callables: selected_target,
## race_of_model, own_vitals, own_guild, own_portrait), kept so a pane built
## later takes them.
var party_hooks := {}
var party_pane: HudPartyPane = null
var _party_settings: PartySettingsDialog = null
var _party_invitation: PartyInvitePopup = null

func _party() -> PartyState:
	if party_state == null:
		party_state = NetClient.party
	return party_state

## Sets the world's hooks on the pane (now, and on one built later).
func set_party_hooks(hooks: Dictionary) -> void:
	for k in hooks:
		party_hooks[k] = hooks[k]
	_apply_party_hooks()

func _apply_party_hooks() -> void:
	if party_pane == null:
		return
	for k in party_hooks:
		party_pane.set(k, party_hooks[k])
	party_pane.refresh()

func _wire_party_pane(pane: Control) -> void:
	if pane == null or party_pane != null:
		return
	party_pane = HudPartyPane.new(_builder, pane, _party())
	party_pane.create_requested.connect(func(t: int) -> void: party_create_requested.emit(t))
	party_pane.invite_requested.connect(func(t: int) -> void: party_invite_requested.emit(t))
	party_pane.leave_requested.connect(func() -> void: party_leave_requested.emit())
	party_pane.kick_requested.connect(func(j: int) -> void: party_kick_requested.emit(j))
	party_pane.match_requested.connect(func() -> void: party_match_requested.emit())
	party_pane.settings_requested.connect(func() -> void: open_party_settings(pane))
	_apply_party_hooks()

## The settings dialog (0x6d61e0): child 70 of the party pane; one at a time.
func open_party_settings(pane: Control = null) -> PartySettingsDialog:
	if is_instance_valid(_party_settings) and not _party_settings.is_queued_for_deletion():
		return _party_settings
	var parent: Control = pane if pane != null else (_popup.pane_control("GDR_PARTY") if _popup != null else null)
	if parent == null or _builder == null:
		return null
	var dlg := PartySettingsDialog.new()
	if not dlg.build(_builder, _party()):
		dlg.queue_free()
		return null
	dlg.confirmed.connect(func(e: int, i: int, a: int) -> void: _party().set_preferences(e, i, a))
	parent.add_child(dlg)
	_party_settings = dlg
	return dlg

## The invitation box (HUD request kind 6), centred as CMessageBoxManager
## places a box (0x6ec5d0: x = width / 2 - 0x9a, y = height / 2 - 0x4a).
func show_party_invitation(who: String, flags: int) -> PartyInvitePopup:
	close_party_invitation()
	if _builder == null:
		return null
	var box := PartyInvitePopup.new()
	if not box.build(_builder, who, flags):
		box.queue_free()
		return null
	box.answered.connect(func(accept: bool) -> void: party_answer_requested.emit(accept))
	box.expired.connect(func() -> void: _party().forget_invitation())
	var view := get_viewport_rect().size if is_inside_tree() else Vector2(1024, 768)
	box.position = Vector2(floorf(view.x / 2.0) - 0x9a, floorf(view.y / 2.0) - 0x4a)
	add_child(box)
	_party_invitation = box
	return box

## The player's own bars changed: the party window's own rows follow
## (HudPartyPane.refresh_vitals).
func party_vitals_changed() -> void:
	if party_pane != null:
		party_pane.refresh_vitals()

func close_party_invitation() -> void:
	if is_instance_valid(_party_invitation):
		_party_invitation.close()
	_party_invitation = null

# --- Party matching (round 714, lane C2) ------------------------------------

## The matching state (registered on NetClient's dispatcher) and the window's
## controller, which also owns the matching boxes (PartyMatchWindow).
var party_match_state: PartyMatchState = null
var party_match: PartyMatchWindow = null
var _match_ms_acc := 0.0
var _zone_names: Dictionary = {}
var _zone_names_loaded := false

func _ensure_party_match() -> PartyMatchWindow:
	if party_match != null:
		return party_match
	party_match_state = PartyMatchState.new()
	party_match_state.send = func(op: int, payload: PackedByteArray) -> void:
		if NetClient.is_connected_to_server():
			NetClient._send(op, payload)
	party_match_state.registration_key = _party_match_key
	# 0x97c530: the echo's row takes the player's race and the party's size.
	party_match_state.own_race = func() -> int: return _skill_race
	party_match_state.party_size = func() -> int:
		var p := _party()
		return p.members.size() if p.in_party and not p.members.is_empty() else 1
	if not Engine.is_editor_hint():
		party_match_state.register_with(NetClient)
	party_match = PartyMatchWindow.new(_builder, party_match_state, _party(), self)
	party_match.own_level = _party_match_level
	party_match.own_name = func() -> String: return NetClient.current_character_name
	party_match.own_job = func() -> int:
		var p := _party()
		return int(p.own_job_state.call()) if p.own_job_state.is_valid() else PartyNet.JOB_NONE
	party_match.race_of_model = func(ref_id: int) -> int:
		var c: Callable = party_hooks.get("race_of_model", Callable())
		return int(c.call(ref_id)) if c.is_valid() else -1
	party_match.zone_name = _party_match_zone
	party_match.mastery_icon = _party_match_mastery_icon
	party_match.view_size = func() -> Vector2: return get_viewport_rect().size if is_inside_tree() else Vector2(1024, 768)
	party_match.notice.connect(func(k: String, code: int, type: int) -> void:
		# Through the party state's notice: World3D draws it in the system
		# message window, type 0 (ALWAYS) for a server code, 4 otherwise.
		_party().notice.emit(k, "", code if type == 0 else 0))
	party_match.banner.connect(_party_match_banner)
	party_match.whisper_requested.connect(_party_match_whisper)
	party_match.settings_lock.connect(func(on: bool) -> void:
		if party_pane != null:
			party_pane.set_match_lock(on))
	return party_match

## Lets the matching controller go with this HudPanels (review B6): it is
## hooked to NetClient.party, which outlives every HudPanels.
func _exit_tree() -> void:
	_wait_skill_parses()
	if party_match != null:
		party_match.dispose()
		party_match = null

## c:0x8841f0's compare: the leader's name in a party, the player's otherwise.
func _party_match_key() -> String:
	var p := _party()
	if p.in_party:
		var l := p.leader()
		if l != null:
			return l.member_name
	return NetClient.current_character_name

func _party_match_level() -> int:
	if _stats != null:
		return _stats.level
	var scene := get_tree().current_scene if is_inside_tree() else null
	var lv = scene.get("_player_level") if scene != null else null
	return int(lv) if lv != null else 0

## 0x740030: the region id as text, looked up in textzonename (keyed by
## region id, TextZoneNameReader).
func _party_match_zone(region: int) -> String:
	if not _zone_names_loaded:
		_zone_names_loaded = true
		var archive := _builder.media_archive() if _builder != null else null
		var entry = ObjectLoader.find_file(archive, "server_dep\\silkroad\\textdata\\textzonename.txt") if archive != null else null
		if entry != null:
			_zone_names = TextZoneNameReader.parse(archive.read_file(entry))
	return String(_zone_names.get(region & 0xffff, ""))

## 0x73fed0 -> 0x937010: the mastery's record, its icon (skillmasterydata
## column 11, MasteryReader).
func _party_match_mastery_icon(id: int) -> Texture2D:
	_load_masteries()
	for m in _mastery_table:
		if (m as MasteryReader.Mastery).id == id and _builder != null:
			return _builder.load_texture((m as MasteryReader.Mastery).icon_path)
	return null

## 0x77b580: the warning banner (GDR_WARNING_WND, World3D's HudWarning).
func _party_match_banner(key: String) -> void:
	var text := _builder.resolve_text(key) if _builder != null else key
	var w := get_parent().get_node_or_null("HudWarning") if get_parent() != null else null
	if w != null and w.has_method("show_notice") and text != "" and text != key:
		w.show_notice(text)
	else:
		print("HudPanels: party match banner %s" % key)

## Whisper (0x7386e0 -> 0x777d10 -> 0x7ab470, READ): the chat input set to
## L"$" + the name + L" " (0xdbb848, 0xe19330) and focused -- the same line
## KeyMap.reply_line builds for R.
func _party_match_whisper(leader_name: String) -> void:
	var chat := get_parent().get_node_or_null("HudChat") if get_parent() != null else null
	if chat != null and chat.has_method("open_with"):
		chat.open_with("$%s " % leader_name)

func _party_match_opened(window: HudWindow, was_shown: bool) -> void:
	_ensure_party_match().attach(window)
	if not was_shown:
		party_match.on_shown()

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
## The Option window's Video tab was stored (Apply / Confirm; round 694).
signal video_options_applied(options: VideoOptions)
## Round 832: the Option window's Extra tab on Apply / Confirm.
signal extra_options_applied(values: Dictionary)
## Round 833: the Key Map tab's mouse mode put in force.
signal mouse_mode_changed(mode: int)
signal system_restart_requested
signal system_exit_requested
signal system_help_requested
## Put a skill on the next free underbar quickslot. Nothing in the window
## emits it since round 652 (a click picks the skill up instead; retail has
## no "next free slot" shortcut); World3D's QA hotbar hook calls its handler.
signal skill_assign_requested(skill_id: int, basic_code: String, icon: Texture2D)
## A learned skill was put down at a screen position: World3D resolves the
## position against the underbar's quickslots and puts the skill there.
signal skill_drop_requested(at: Vector2, skill_id: int, basic_code: String, icon: Texture2D)
## A BAG ITEM was put down somewhere that is
## neither a bag slot nor an equipment slot -- World3D resolves the position
## against the underbar's quickslots and puts the item there.
##
## The quickslots held skills only until now, so a consumable could not reach
## the bar at all: "skills should be drag and drop" and the HP berry that could
## not be used from it (playtest 2026-09-20).
signal item_drop_requested(at: Vector2, item_id: int, inventory_slot: int, icon: Texture2D)
## The held icon (HeldIcon, round 652) was put down somewhere these windows
## do not own: the quick slot bar or the world. World3D resolves it -- a
## skill or a bag item onto a quick slot, a quick slot onto another (the two
## change places) or off the bar (removed), a worn item on the ground (the
## retail refusal line). `what` is the HeldIcon payload.
signal held_dropped_outside(what: Dictionary, at: Vector2)
## A learned skill in the skill window was RIGHT-clicked: cast it. READ:
## CIFSlotWithHelp's right-button-up (vslot 33, 0x685ee0) runs 0x682040,
## whose skill-window case (0x19) is 0x81ba10 -- the same call a quick slot
## holding a skill makes when used (0x60b850, case 0x19).
signal skill_use_requested(skill_id: int, basic_code: String)
## A talk-box service line other than "End conversation" was chosen; `key` is
## the service's stable key (NpcServiceReader.Service.key -- "shop", "storage",
## ...). World3D acts on it (opens the shop, ...).
signal npc_service_selected(key: String)
## The talk window, the store or the storage was hidden (round 727): World3D
## sends the end request 0x704B for a server NPC (NpcTalkNet.end, which holds
## it while an open is in flight, as the original's close slot does).
signal npc_window_hidden(panel_id: String)
## A quest line's answer is out and its page not yet back (round 819).
var quest_answer_in_flight := false
## The guild name prompt (open_guild_name_prompt, round 521) was submitted
## with this name. World3D sends it to the server (NetClient.create_guild).
signal guild_create_requested(guild_name: String)
## Round 814: the guild window's grant-name box was accepted (own name).
signal guild_grant_name_requested(nickname: String)
## Round 822: the guild window's Invite (37) and the ban question's Yes (39),
## and the client's own refusal of a ban (0x4c1f).
signal guild_invite_requested
signal guild_expel_requested(member_name: String)
signal guild_expel_refused(code: int)
## The guild leave prompt (open_guild_leave_prompt, round 521) was confirmed.
## World3D sends the leave request (NetClient.leave_guild).
signal guild_leave_requested
## The return-point box (open_recall_designate_prompt, round 686) was
## confirmed. World3D sends the designate request (NetClient.recall_designate).
signal recall_designate_requested
## A line for the chat's system channel -- today a server refusal of a mastery
## raise, which used to be dropped silently. World3D logs it (_log_system).
signal system_notice(text: String)
## A global chatting item (TypeID 3/3/3/5) was used from bag slot `slot`
## holding `count` (round 634): retail opens the "Chat to all" window for it
## (IFSlotWithHelp 0x676570's case 5 -> 0x79b8a0) instead of using it.
signal global_chat_requested(slot: int, count: int)
## An item used on the current COS (is_cos_target_item, round 805) was used
## from bag slot `slot`: World3D names the pet (World3D._use_cos_item).
signal cos_item_requested(slot: int)
## A destination line of a gate's talk box (open_teleport_list, round 603) was
## clicked: `dest_id` is its destination, a teleportdata id. World3D sends it
## with the gate the list was opened at (NetClient.teleport_use).
signal teleport_requested(dest_id: int)
## An action-window button was used (round 781): a right click on its slot
## (CIFSlotWithHelp vslot 33 -> 0x682040, kind 0x4a -> 0x793b00). World3D runs
## it (ActionCommands).
signal action_use_requested(action_id: int)

## The main popup's action pane (round 781, HudActionPane), built with the
## popup; null until then.
var action_pane: HudActionPane = null

## Fills GDR_ACTION from the player's actionwnddata.txt (CIFAction::Create).
func _wire_action_pane(pane: Control) -> void:
	if pane == null or action_pane != null or _builder == null:
		return
	var rows := ActionWndData.load_from(_builder.media_archive())
	action_pane = HudActionPane.new(_builder, pane, rows)
	action_pane.use_requested.connect(func(id: int) -> void: action_use_requested.emit(id))
	action_pane.pick_requested.connect(func(what: Dictionary, icon: Texture2D, source: Control, at: Vector2) -> void:
		pick_up_icon(what, icon, source, at))
	# The player's motion as the world knows it now (sit / walk), so a pane
	# built while seated or walking shows the swapped buttons.
	if action_motion_now.is_valid():
		for v in action_motion_now.call():
			action_pane.set_motion(int(v))
	print("HudPanels: action pane filled from %s: %d buttons" % [ActionWndData.PATH, action_pane.slots.size()])

## World3D's hook: the motion values the action pane should show now
## ([sit 4 / stand 0, walk 2 / run 3]).
var action_motion_now: Callable = Callable()

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
	# Round 789: the grant window's list (AVATAR_ALCHEMY_RESEARCH.md 1).
	"grant": [GrantMagicAttributeWindow.SECTION_LIST],
	# Round 837: the mall's info block (GDR_ITEM_MALL_MYINFO, section MyInfo).
	"itemmall": ["MyInfo"],
}

var _builder: UiBuilder
var _windows: Dictionary = {} # panel id -> HudWindow
var _unavailable: Dictionary = {} # panel id -> true, for layouts that failed

func _init(builder: UiBuilder = null) -> void:
	_builder = builder

func _ready() -> void:
	# A transparent full-screen container: it must not eat world clicks.
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ensure_held_icon()
	# Round 836: the exchange's layout option rebuilds its window.
	extra_options_applied.connect(_on_exchange_layout_option)
	_qa_slots = OS.get_environment("OPENSRO_QA_SLOTS") != ""
	if _qa_slots:
		add_to_group(QA_SLOTS_GROUP)
	_ensure_party_match()
	# Round 837: the item chest and its icon under the minimap (OURS).
	_build_item_chest()

## OPENSRO_QA_SLOTS is set (read once): F11 prints the slots, Shift+F11
## opens the warehouse. QA only.
var _qa_slots := false

## The one icon-on-the-cursor controller every icon window shares (round
## 652): see held_icon.gd for what is READ of retail's.
var held_icon: HeldIcon = null

func _ensure_held_icon() -> HeldIcon:
	if held_icon == null:
		held_icon = HeldIcon.new()
		held_icon.name = "HeldIcon"
		held_icon.drop_handler = _on_held_dropped
		held_icon.passes_through = _click_passes_through
		add_child(held_icon)
	return held_icon

## Picks an icon up onto the cursor (a left click on a filled slot).
func pick_up_icon(what: Dictionary, icon: Texture2D, source: CanvasItem, at: Vector2) -> bool:
	if not _ensure_held_icon().pick_up(what, icon, source, at):
		return false
	# The original holds the slot itself and draws it at the cursor with its
	# own draw (0xb9d810 -> 0xb9d7f0 -> vslot_013 0x685e50), so a seal item's
	# star rides along, at the slot's phase.
	var ghost := held_icon.ghost()
	if ghost != null:
		_set_item_seal_edge(ghost, int(what.get("item_id", -1)))
		ItemSealEdge.copy_phase(source as Node, ghost)
	# Let go when the window the icon came from goes away (closed, or its
	# tab switched): a drop after that would act on a slot nobody sees. A
	# quick slot is exempt -- the bar's page arrows hide the slot while its
	# icon is carried to another page. OURS (retail's handling not read).
	if String(what.get("kind", "")) != "quickslot":
		_watch_held_source(source)
	return true

## Watches a control an icon can be picked up from: when it stops being
## visible (its window closed, its tab switched) while it is the held icon's
## source, the icon is let go. Connected once per control.
func _watch_held_source(source: CanvasItem) -> void:
	if source == null or source.has_meta("held_watch"):
		return
	source.set_meta("held_watch", true)
	source.visibility_changed.connect(func() -> void: _on_held_source_visibility(source))

func _on_held_source_visibility(source: CanvasItem) -> void:
	if held_icon != null and held_icon.is_holding() and held_icon.source() == source \
			and is_instance_valid(source) and not source.is_visible_in_tree():
		cancel_held_icon("its window closed")

## Lets go of whatever is on the cursor (a death, a zone change, a window
## closing, the slot's contents changing under it). OURS: when retail lets go
## in these cases is not read; ours does so nothing stale is ever dropped.
func cancel_held_icon(why: String = "") -> void:
	if held_icon != null and held_icon.is_holding():
		print("HudPanels: the held icon is let go (%s)" % why)
		held_icon.cancel()

## Extra places a click passes through while an icon is held, each a
## Callable(at: Vector2) -> bool: the quick slot bar's buttons, which are not
## one of these windows (World3D registers HudUnderbar.button_at).
var click_pass_through: Array[Callable] = []

## The windows of an NPC interaction, whose hiding ends it (round 727).
const NPC_INTERACTION_WINDOWS := ["npctalk", "store", "storage", "grant"]

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
	if panel_id == QUEST_ID:
		return _open_quest_window()
	if panel_id == ALCHEMY_ID:
		return open_alchemy()
	if _unavailable.has(panel_id):
		return null
	var window: HudWindow = _windows.get(panel_id)
	# Whether this open is a show (a window built now is visible at once,
	# so its visibility cannot be read after the build).
	var was_shown := window != null and window.visible
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
		var archive_defined: bool = panel_id in ARCHIVE_DEFINE_PANELS and _builder != null
		if archive_defined:
			honor_ifdef = true
			defines = _builder.archive_defines()
		var registry: Dictionary = REGISTRY_FRAMES.get(panel_id, {})
		if registry.get("archive_defines", false):
			registry = registry.duplicate()
			registry.erase("archive_defines")
			if _builder != null:
				registry["defines"] = Array(_builder.archive_defines())
		# Round 836 (OURS): the exchange with its portraits and log on screen.
		var exchange_full := panel_id == ExchangeController.WINDOW and exchange_full_layout()
		if exchange_full:
			registry = registry.duplicate()
			registry["rects"] = EXCHANGE_FULL_RECTS
			registry["size"] = EXCHANGE_FULL_SIZE
		window.set_meta(EXCHANGE_FULL_META, exchange_full)
		var built := window.build(_builder, spec[0], spec[1], extra, defines, honor_ifdef, registry)
		if not built and PANEL_FALLBACKS.has(panel_id):
			# The fallback is self-framed (no registry): a fresh window, since a
			# failed build may have sized this one.
			remove_child(window)
			window.queue_free()
			window = HudWindow.new()
			window.name = "Window_" + panel_id
			add_child(window)
			var fallback: Array = PANEL_FALLBACKS[panel_id]
			print("HudPanels: %s built from %s (%s did not build)" % [panel_id, fallback[0], spec[0]])
			built = window.build(_builder, fallback[0], fallback[1], extra, defines, honor_ifdef)
		if not built:
			print("HudPanels: %s unavailable (layout %s did not build)" % [panel_id, spec[0]])
			window.queue_free()
			_unavailable[panel_id] = true
			return null
		if panel_id == "npctalk":
			NpcTalkView.compose(window, _builder)
		_hide_at_create(panel_id, window)
		if panel_id == "system":
			_layout_system_window(window)
		window.centre()
		_windows[panel_id] = window
		if panel_id == "system":
			_wire_system(window)
		if panel_id == "exchange":
			# CIFExchange::Create sets both offers to 0 (0x7b2941 / 0x7b294c).
			set_exchange_money(0, 0)
		_wire_close_sound(panel_id, window)
		if panel_id in NPC_INTERACTION_WINDOWS:
			window.visibility_changed.connect(func() -> void:
				if not window.visible:
					if panel_id == "npctalk":
						quest_answer_in_flight = false
					npc_window_hidden.emit(panel_id))
		_populate(panel_id)
	if panel_id == "exchange" and not was_shown:
		# CIFExchange::vslot_023, showing: the alchemy window is destroyed if
		# it exists (0x7b3a37..0x7b3a4d -> 0x798e20(0)). The first show of a
		# session, when the window is built here, counts too.
		close_alchemy()
	window.show()
	window.move_to_front()
	_populate(panel_id)
	if panel_id == "partymatch":
		_party_match_opened(window, was_shown)
	if panel_id == AUTO_POTION_ID and not was_shown:
		_auto_potion_opened(window)
	return window

## The Auto potion window (round 786, AutoPotionWindow): its controls built
## into the registry frame once, refilled from the settings at every open
## (the client builds it at every open, 0x79c750 -> 0x741880), and its Confirm
## handed out (auto_potion_confirmed: World3D applies and saves).
const AUTO_POTION_ID := "autopotion"
signal auto_potion_confirmed(values: Dictionary)
## The settings the window shows (World3D's AutoPotion); null shows the
## controls as built.
var auto_potion: AutoPotion = null

func _auto_potion_opened(window: HudWindow) -> void:
	var c := AutoPotionWindow.compose(window, _builder)
	if c == null:
		return
	if not c.on_confirm.is_valid():
		c.on_confirm = func(values: Dictionary) -> void: auto_potion_confirmed.emit(values)
	if auto_potion != null:
		c.fill(auto_potion.values())

## The open window's controller, or null (tests, QA).
func auto_potion_window() -> AutoPotionWindow:
	return AutoPotionWindow.of(_windows.get(AUTO_POTION_ID) as HudWindow)

## The alchemy window (AlchemyWindow), while it exists. The client builds it
## at every open and destroys it at every close (0x798e20), so this is null
## whenever it is closed.
const ALCHEMY_ID := "alchemy"
var _alchemy: AlchemyWindow = null

## 0x798e20(1): Y from closed, and the underbar menu's alchemy item (114).
## The gate 0x77c8e0(1) refuses when the window already exists (0x799580)
## or GDR_EXCHANGE (0x1a) is up (0x77c941..0x77c95c); its other checks are on
## windows and modes this client does not build (GDR_STALL 0x21, 0x8c,
## the stall network 0x96, GDR_DELAY_GAUGE_BOARD's +0x36c, the open market
## 0xbe, the interface's +0x504 and the list at 0xeec03c). Then the file is
## loaded, and the window's own OnCreate places it and ends with 0x79af20,
## which shows the main popup on its inventory tab (ShowWindow(1), then
## 0x6a1f70(0x46) unless the inventory pane is already up, then 0x79a7e0:
## the same steps as I, HudMainPopup.open). Returns the window, or null.
func open_alchemy() -> AlchemyWindow:
	if _alchemy != null and is_instance_valid(_alchemy):
		return _alchemy
	var exchange: HudWindow = _windows.get("exchange")
	if exchange != null and exchange.visible:
		return null
	if _unavailable.has(ALCHEMY_ID):
		return null
	var window := AlchemyWindow.new(_builder)
	window.name = "Window_alchemy"
	add_child(window)
	if not window.build_alchemy():
		print("HudPanels: alchemy unavailable (%s did not build)" % AlchemyWindow.ENCHANT_2DT)
		remove_child(window)
		window.queue_free()
		_unavailable[ALCHEMY_ID] = true
		return null
	window.place_initial()
	window.closed.connect(close_alchemy)
	# Round 768: the strengthening tab's requests and lines.
	window.start_requested.connect(func(op: int, bag_slots: Array) -> void:
		if NetClient.is_connected_to_server():
			print("HudPanels: alchemy op %d slots %s" % [op, bag_slots])
			NetClient.alchemy_start(op, bag_slots))
	window.cancel_requested.connect(func() -> void:
		if NetClient.is_connected_to_server():
			NetClient.alchemy_cancel())
	window.message.connect(func(text: String) -> void: system_notice.emit(text))
	window.options = MagicOptionTable.shared
	_alchemy = window
	window.show()
	window.move_to_front()
	# 0x79af20: the inventory -- ShowWindow(1), its tab, then the toggle
	# helper 0x79a7e0 on the main popup, which sounds snd_window_open (read).
	var popup_window := open("inventory")
	if popup_window != null:
		UiSounds.window_toggled(popup_window.visible, _interface_shown(), "alchemy opened: 0x79af20 raises the inventory")
	return window

## 0x798e20(0): Y from open, the window's close button (CNIFEnchantWnd
## vslot_043, 0x5942a0), Escape (0x79d97c..0x79d984) and the exchange
## window's show. The window is destroyed, not hidden.
func close_alchemy() -> void:
	var window := _alchemy
	_alchemy = null
	if window == null or not is_instance_valid(window):
		return
	if window.get_parent() == self:
		remove_child(window)
	window.queue_free()
	# 0x798e20(0) plays snd_window_close itself (0x798eb2), before it destroys
	# the windows (read). Every caller asks first whether the window exists.
	UiSounds.window_closed("alchemy closed: 0x798e20(0)")

## The Option window (OptionWindow, res_ui\optionwnd.2dt), while it exists.
## Like the alchemy window it is loaded at every open and destroyed at every
## close (0x6f5100(1) / (0)).
var _option: OptionWindow = null

## The System window's Option button (id 10 -> 0x6f5190): destroy window 0x62
## if it exists, else load it, centre it, bring it forward and hide the
## System window. Silent both ways (read; OptionWindow's header).
func toggle_option() -> OptionWindow:
	if option_window() != null:
		close_option()
		return null
	var window := OptionWindow.new(_builder)
	window.name = "Window_option"
	add_child(window)
	if not window.build_option():
		print("HudPanels: option window unavailable (%s did not build)" % OptionWindow.OPTION_2DT)
		remove_child(window)
		window.queue_free()
		return null
	window.closed.connect(close_option)
	window.video_applied.connect(func(o: VideoOptions) -> void: video_options_applied.emit(o))
	window.extra_applied.connect(func(v: Dictionary) -> void: extra_options_applied.emit(v))
	window.mouse_mode_changed.connect(func(m: int) -> void: mouse_mode_changed.emit(m))
	_option = window
	window.show()
	window.place_centred()
	window.move_to_front()
	var system: HudWindow = _windows.get("system")
	if system != null:
		system.hide()
	print("HudPanels: option window opened (%s)" % OptionWindow.OPTION_2DT)
	if qa_rects_on():
		_qa_print_option_rects.call_deferred()
	return window

## OPENSRO_QA_UI_RECTS=1 (round 694, OURS): print the screen rect of the
## controls a real-input run clicks -- the System window's Option button,
## the Option window's tabs, buttons and Video rows -- as `QA RECT <window>
## <name> <centre x> <centre y> <w> <h>` in window pixels, so an xdotool
## driver clicks what is drawn, at any UI scale.
static func qa_rects_on() -> bool:
	return OS.get_environment("OPENSRO_QA_UI_RECTS") == "1"

func _qa_print_rects(tag: String, controls: Dictionary) -> void:
	var k := get_window().content_scale_factor if is_inside_tree() else 1.0
	for key in controls:
		var c := controls[key] as Control
		if c == null or not is_instance_valid(c) or not c.is_visible_in_tree():
			print("QA RECT %s %s none" % [tag, key])
			continue
		var r := c.get_global_rect()
		print("QA RECT %s %s %d %d %d %d" % [tag, key, roundi(r.get_center().x * k), roundi(r.get_center().y * k), roundi(r.size.x * k), roundi(r.size.y * k)])

func _qa_print_option_rects() -> void:
	var w := option_window()
	if w == null:
		return
	var controls := {"tab_video": w.control([10]), "tab_audio": w.control([14]), "default": w.control([5]),
		"confirm": w.control([6]), "cancel": w.control([8]), "apply": w.control([9]),
		"g1": w.control([78, 24]), "g2": w.control([78, 25]), "fullscreen": w.control([78, 203]),
		"windowed": w.control([78, 204]), "view_free": w.control([78, 207]), "view_third": w.control([78, 208]),
		"view_quarter": w.control([78, 209]), "resolution": w.control([78, 14, 15]), "brightness": w.control([78, 462, 15]),
		"scroll_up": w.control([78, 465]).get_node_or_null("Up") if w.control([78, 465]) != null else null,
		"scroll_down": w.control([78, 465]).get_node_or_null("Down") if w.control([78, 465]) != null else null}
	if w.video != null:
		for n in w.video.slot_count():
			controls["slot%d" % n] = w.video.slot_combo(n)
	_qa_print_rects("option", controls)

func close_option() -> void:
	var window := _option
	_option = null
	if window == null or not is_instance_valid(window):
		return
	# Every way out puts the saved volumes back unless Confirm/Apply stored
	# the edit (then saved == edit): the Option button pressed again, Cancel,
	# the close button, Escape (ours; OptionWindow's header).
	window.restore_saved()
	if window.get_parent() == self:
		remove_child(window)
	window.queue_free()

func option_window() -> OptionWindow:
	return _option if _option != null and is_instance_valid(_option) else null

## The alchemy window, or null when it is closed (tests, tools).
func alchemy_window() -> AlchemyWindow:
	return _alchemy if _alchemy != null and is_instance_valid(_alchemy) else null

## Round 768: whether a global point is over the alchemy window, in front of
## any panel window that is there too. The window is not one of _windows
## (it is built at every open), so the topmost test does not see it.
func _over_alchemy(at: Vector2, _on_bag: bool) -> bool:
	var w := alchemy_window()
	if w == null or not w.is_visible_in_tree() or not w.get_global_rect().has_point(at):
		return false
	# In front of whatever panel window is under the point too -- the
	# inventory, the store, the warehouse (round 768's review F12).
	var top := _topmost_window_at(at)
	return top == null or _drawn_above(w, top)

## The alchemy window's description of bag `slot` (AlchemyReinforce's item
## dictionary), or {} when the slot is empty or its item unknown.
func alchemy_item(slot: int) -> Dictionary:
	var item_id := _bag_item_id_at_slot(slot)
	if item_id < 0:
		return {}
	_load_items()
	var item: ItemTableReader.Item = _items.get(item_id)
	if item == null:
		return {}
	var inst := _item_instance("bag", slot) as ItemInstance
	return {"bag": slot, "item_id": item_id, "tids": Array(item.type_ids), "item_class": item.item_class,
		"param1": item.param1, "param2": item.param2, "param5": item.param5, "desc1": item.desc1, "desc4": item.desc4,
		"code": item.code_name, "plus": inst.opt_level if inst != null else 0,
		"durability": inst.durability if inst != null else 0, "seal": is_seal_item(item_id)}

## Offers bag `slot` to the alchemy window (Alt+click or a put-down).
func _alchemy_offer(slot: int) -> void:
	var w := alchemy_window()
	if w == null:
		return
	var it := alchemy_item(slot)
	if it.is_empty():
		return
	w.offer_item(it, _item_icon(int(it["item_id"])))

## The alchemy reply (round 768): to the window, then the bag again -- the
## reply carries the target's record but not the spent elixir, powder or
## stone (retail updates those by a packet not read; OURS: the whole bag).
func _on_alchemy_result(r: AlchemyNet.Result) -> void:
	var w := alchemy_window()
	if w != null:
		w.apply_result(r)
	if r.ok and not r.cancelled or (not r.ok and r.code == AlchemyNet.CODE_ENCHANT_FAILED):
		if NetClient.current_character_name != "":
			NetClient.list_inventory(NetClient.current_character_name)

## The underbar's buttons and menu items (HudUnderbar.menu_action). Each
## toggles its panel as its key does, except the alchemy item (114), which
## calls 0x798e20(1) (0x60ce92..0x60ce9a): it opens the window, and does
## nothing while the window exists.
func menu_action(panel_id: String) -> void:
	if panel_id == ALCHEMY_ID:
		open_alchemy()
		return
	# Round 837: the bottom bar's item mall button (9) -> the entry box.
	if panel_id == HudUnderbar.MALL_ENTRY_ACTION:
		open_item_mall_entry()
		return
	toggle(panel_id)

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
		_wire_close_sound(MAIN_POPUP_ID, window)
		_wire_equipment_modes(window, popup.pane_control("GDR_EQUIPMENT"))
		_wire_doll_rotation(window)
		_apply_equipment_slot_backgrounds()
		_place_paper_doll_docked()
		_wire_party_pane(popup.pane_control("GDR_PARTY"))
		_wire_action_pane(popup.pane_control("GDR_ACTION"))
		_fill_equipment_slots(_equipped_items)
		# The bag's page tabs and its shown page (0x6b6620 builds them with
		# the bag; 0x6b3d00(0) selects the first).
		_build_bag_tabs()
		_draw_bag_page()
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

## U (0x5b4980) and the underbar menu's community item (108, 0x5b49c0):
## set the view, then toggle the window.
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
	# Round 821: the guild record the window draws, and the race lookup its
	# marks use (the party pane's).
	window.data = NetClient.guild_data
	window.race_of_model = func(ref_id: int) -> int:
		var c: Callable = party_hooks.get("race_of_model", Callable())
		return int(c.call(ref_id)) if c.is_valid() else -1
	NetClient.guild_data.changed.connect(window.refresh_guild)
	# Centred on every show by the window itself (GuildWindow.place_centred,
	# 0x798c50), not once here.
	_apply_guild(window)
	window.fill_friends(_friends)
	# The window's own left-menu buttons switch views; ask for that view's
	# data as U and the community button do.
	window.view_changed.connect(func(view: String) -> void: _populate(view))
	window.grant_name_submitted.connect(func(nick: String) -> void: guild_grant_name_requested.emit(nick))
	window.friend_whisper_requested.connect(_friend_whisper)
	window.friend_add_requested.connect(open_friend_add)
	window.friend_delete_requested.connect(open_friend_delete)
	# Round 822: Invite and the ban question's Yes.
	window.own_name = NetClient.current_character_name
	window.invite_requested.connect(func() -> void: guild_invite_requested.emit())
	window.expel_requested.connect(func(who: String) -> void: guild_expel_requested.emit(who))
	window.expel_refused.connect(func(code: int) -> void: guild_expel_refused.emit(code))
	_windows[GUILD_WINDOW_KEY] = window
	return window

## Keeps every window this node holds drawn above the chat window, and hit
## first where the two overlap, by putting `chat` directly below this node
## in their shared parent (World3D adds the chat after this node, so the
## chat drew over, and took the clicks and the wheel of, every window it
## overlapped: at 1152x648 the quest window at (80, 140) and the main popup
## at x 80). **Ours:** the retail order was not read -- the quest window
## (0x786f30, game start) is created after the registry windows (0x78c9ce)
## and GDR_MAINPOPUP comes before GDR_CHAT_BOARD in ginterface.txt, and the
## draw loop and any bring-to-front on click were not read, so neither
## order settles it. This node is a full-screen IGNORE container, so where
## no window lies the chat takes its clicks as before, and the chat moves
## only below this node: it is drawn above nothing it was not above before.
func stack_over(chat: Control) -> void:
	if chat == null or get_parent() == null or chat.get_parent() != get_parent():
		return
	if chat.get_index() > get_index():
		get_parent().move_child(chat, get_index())

const QUEST_ID := "quest"

## The quest window, built the first time it is wanted (the client builds it
## at game start, hidden, 0x786f30, and Q only toggles it), then shown. It
## places itself once, when built (QuestWindow.place_on_create); showing it
## does not move it.
func _open_quest_window() -> QuestWindow:
	var window := _quest_window()
	if window == null:
		return null
	window.show()
	window.move_to_front()
	_populate(QUEST_ID)
	return window

func _quest_window() -> QuestWindow:
	var window := _windows.get(QUEST_ID) as QuestWindow
	if window != null:
		return window
	if _unavailable.has(QUEST_ID):
		return null
	window = QuestWindow.new()
	window.name = "Window_quest"
	add_child(window)
	if not window.build_quest(_builder):
		print("HudPanels: quest unavailable (%s did not build)" % QuestWindow.QUESTLIST_2DT)
		window.queue_free()
		_unavailable[QUEST_ID] = true
		return null
	window.tables = _quest_hud().tables if _quest_hud().tables != null else QuestTables.shared(_builder.media_archive() if _builder != null else null)
	window.player_level = _party_match_level()
	window.quest_selected.connect(func(id: int) -> void: NetClient.quest.set_tracked(id))
	window.detail_requested.connect(func(id: int) -> void: _quest_hud().open_detail(id))
	window.fill_log(NetClient.quest.entries())
	_windows[QUEST_ID] = window
	return window

## The quest log changed (NetClient.quest, round 785): the list redraws.
func _on_quest_log_changed() -> void:
	var window := _windows.get(QUEST_ID) as QuestWindow
	if window != null:
		window.player_level = _party_match_level()
		window.fill_log(NetClient.quest.entries())
	var hud := _quest_hud()
	if hud.detail != null and is_instance_valid(hud.detail) and hud.detail.visible:
		if NetClient.quest.active.has(hud.detail_quest):
			hud.open_detail(hud.detail_quest)
		else:
			hud.detail.hide()

## The QuestHud, made on first use.
func _quest_hud() -> QuestHud:
	if quest_hud == null:
		quest_hud = QuestHud.new(self, _builder, NetClient.quest)
		add_child(quest_hud)
		quest_hud.tables = QuestTables.shared(_builder.media_archive() if _builder != null else null)
	quest_hud.country = _skill_race
	if quest_hud.player_level == 0:
		quest_hud.player_level = _party_match_level()
	return quest_hud

## A level-up (World3D._on_level_up): the guide icon's count (QuestHud).
func quest_level_up(level: int) -> void:
	_quest_hud().on_level_up(level)

## The progress notice's text for an objective (GDR_UPDATE_QUEST_INFO): its
## SN_CON_ text with the count put in.
## A quest text key's text (the quest tables, keep-first; the key itself
## when no table has it): 0x30EC's notice (round 819).
func quest_text(key: String) -> String:
	var t := _quest_hud()._tables()
	return QuestTables.plain(t.resolve(key, key)) if t != null else key

func quest_progress_text(m: QuestNet.Mission) -> String:
	var t := _quest_hud().tables
	var fmt := t.resolve(m.text, m.text) if t != null else m.text
	return QuestNet.format_objective(fmt, m.values)

## An NPC's quest page (0x30D4, QuestHud.page_lines): the talk box's lines
## replaced by the page's. False when the talk box is not open.
func show_quest_page(page: QuestNet.TalkPage) -> bool:
	quest_answer_in_flight = false
	var window := _windows.get("npctalk") as HudWindow
	if window == null or not window.visible:
		window = open("npctalk")
	if window == null:
		return false
	var body := _talk_body(window)
	if body == null:
		return false
	var hud := _quest_hud()
	hud.player_level = _party_match_level()
	var lines := hud.page_lines(page)
	NpcTalkView.show_lines(window, lines)
	window.set_meta(TELEPORT_LIST_META, false)
	print("HudPanels: quest page type %d '%s', %d line(s)" % [page.type, page.text, page.lines.size()])
	_qa_print_talk_lines.call_deferred(body)
	return true

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
##
## `tax` (round 725) is the fortress tax line's text, already formatted
## (SN_FORTRESS_SHOP_TAX), or "" for none; it goes after the greeting, in
## green, with a blank line (NpcTalkView).
func open_npc_talk(npc_name: String, greeting: String = "", services: Array = [], tax: String = "") -> void:
	var window := open("npctalk")
	if window == null:
		return
	_drop_talk_prompts(window)
	_fill_npc_talk(window, npc_name, greeting, services, tax)

## Rebuilds the lines of a talk box that is already open, for World3D after a
## guild reply changed the player's guild state (round 521). Unlike
## open_npc_talk it does not go through open(), so it neither raises the talk
## box above a window opened from it (the store after Buy) nor drops a guild
## prompt the player may be typing into. A closed talk box stays closed.
func refresh_npc_talk(npc_name: String, greeting: String, services: Array, tax: String = "") -> void:
	if not is_open("npctalk"):
		return
	# A gate's destination list (round 603) holds no guild line, and a guild
	# reply must not turn it back into the gate's menu.
	if teleport_list_shown():
		return
	_fill_npc_talk(_windows["npctalk"], npc_name, greeting, services, tax)

## The talk box's label (NpcTalkView.compose made it; the window composes it
## on its first open).
func _talk_body(window: HudWindow) -> RichTextLabel:
	var body := NpcTalkView.body_of(window)
	if body == null and window != null:
		body = NpcTalkView.compose(window, _builder)
	if body != null and not body.meta_clicked.is_connected(_on_npc_talk_choice):
		body.meta_clicked.connect(_on_npc_talk_choice)
	return body

func _fill_npc_talk(window: HudWindow, npc_name: String, greeting: String, services: Array, tax: String = "") -> void:
	window.set_title(npc_name)
	var body := _talk_body(window)
	if body == null:
		return
	# The real greeting (from npcchat.txt), the fortress tax line when there is
	# one, then the NPC's real services as numbered options, then the end
	# line (FUN_00700440's order, READ). The numbered lines are built by
	# NpcServiceReader.talk_menu_lines (round 513), which resolves each line's
	# token through _resolve_ui (the player's own textuisystem.txt) and prints
	# one NPCTALK log line per menu line. World3D acts on the services with a
	# system behind them (a store line opens the store, storage the warehouse).
	var lines := PackedStringArray()
	lines.append(TeleportBoard.escape(greeting if greeting != "" else "..."))
	lines.append("")
	if tax != "":
		# READ: the tax line and then a blank line (DAT_00e19330).
		lines.append(NpcTalkView.tax_line(tax))
		lines.append("")
	lines.append_array(NpcServiceReader.talk_menu_lines(npc_name, services, _resolve_ui))
	NpcTalkView.show_lines(window, lines)
	# The text on top is kept for a gate's destination list (open_teleport_list).
	window.set_meta(TALK_TEXT_META, lines[0])
	window.set_meta(TELEPORT_LIST_META, false)
	_qa_print_talk_lines.call_deferred(body)

func _on_npc_talk_choice(meta: Variant) -> void:
	var key := str(meta)
	# A quest page's line (round 785): its response id goes as 0x70D4.
	var response := QuestHud.response_of(key)
	if response >= 0:
		# Round 819: one answer at a time (CIF_NPCTalk's +0x7f0, set when a
		# quest line is sent, c:0x7026b1..0x702766, and cleared by the next
		# page, FUN_006fc1c0; READ).
		if quest_answer_in_flight:
			return
		quest_answer_in_flight = true
		print("HudPanels: quest answer %d" % response)
		NetClient.quest.answer(response)
		return
	if key == "end":
		close("npctalk")
		# Inferred: the talk menu's end line closes the NPC window the way its
		# close button does (CIF_NPCWindow::vslot_043 -> 0x652c00: the close).
		# The talk box's OPEN is silent: nothing that shows GDR_NPCWINDOW
		# (+0x724) calls the helper or names a sound (read).
		UiSounds.window_toggled(false, _interface_shown(), "npctalk end line")
		return
	# A gate's destination line (round 603): the request goes at once, as the
	# client's does, and the talk box stays up.
	var dest_id := TeleportBoard.dest_from_key(key)
	if dest_id >= 0:
		teleport_requested.emit(dest_id)
		return
	# Round 725, the chaining READ in CIF_NPCTalk::FUN_007020c0's switch on
	# the line's kind (docs/protocol/npc_gui.md §1, §5):
	# - a store line (kind 1): the parent CIF_NPCWindow runs its close slot
	#   (vtable +0xac, vslot_043 0x7040b0 -- 0x704b while the talk box is up,
	#   then the hide), and only then the store's request goes out
	#   (0x702316..0x702323). The close sounds as the close button's does
	#   (vslot_043, _wire_close_sound's reading).
	# - the warehouse line (kind 3): the parent is hidden by ShowWindow(0)
	#   (`+0x5c`, 0x702438), not vslot_043 -- no close sound -- then the
	#   request goes out.
	# - every other line: the talk box stays (talk, recall point's box, the
	#   destination list in place). Six more kinds close it first through
	#   +0xac (0x7029aa .. 0x703aa7); which kinds is OPEN, so the guild and job
	#   lines keep the box up (ours).
	# The store and the storage are not closed by the NPC window's hide (READ,
	# 0x704100), so they stay up from here on.
	#
	# Round 727: the store line's close ends the selection (0x704B, through
	# npc_window_hidden) before the store's request goes. The original's
	# warehouse line hides the window FIRST (+0x5c(0), 0x70242f..0x70243c),
	# and that hide sends nothing (ShowWindow, not the close slot), then sends
	# 0x7046 {3} (0x702466..). OURS: here the request goes first and the hide
	# after it, because this window's hide reaches npc_window_hidden; the end
	# is held while the request is in flight (NpcTalkNet.end), so the bytes
	# are the original's.
	if NpcServiceReader.is_shop_key(key):
		close("npctalk")
		UiSounds.window_toggled(false, _interface_shown(), "npctalk store line (vslot_043)")
	elif key == "storage" or key == "avatar_magic_option":
		# Round 789: the grant line (kind 0x2f, c:0x7034f3..0x70358d) runs the
		# talk window's close slot and sends 0x7046 {npc, 0x20}, as the
		# warehouse line does.
		npc_service_selected.emit(key)
		close("npctalk")
		return
	npc_service_selected.emit(key)

## Whether a text line has the keyboard: the focus owner of this viewport is
## a LineEdit or TextEdit -- the guild name prompt (round 521), a confirm
## box's count or gold amount (round 726), the chat's own line, or any other. Until round 608
## World3D read movement from the raw key state (Input.get_axis), which a
## focused line does not consume, so without this every "w" typed into the
## guild name prompt walked the character, as it once did in chat
## (World3D._is_typing). Now KeyInput runs no key while it holds.
##
## A line left focused -- the debug panel's teleport field after Enter, the
## options panel's chat-font spinner after a click on its arrows (its inner
## LineEdit takes the focus) -- stopped the keys, click-to-move and the attack walk
## until it lost the focus some other way (round 521's review). World3D now
## takes the focus back on a left click on the world (take_focus_back), and
## the spinner hands it back once its value is set (debug_panel.gd). A
## SpinBox's line still counts while it has the focus: the keys typed there go
## into it, not to quickslots or berserk, so letting a key also act would
## split one key press two ways. A line not visible in the tree does not count
## (Godot already releases a hidden control's focus; this is only a guard).
func is_typing() -> bool:
	if not is_inside_tree():
		return false
	var focus := get_viewport().gui_get_focus_owner()
	if not (focus is LineEdit or focus is TextEdit):
		return false
	return focus.is_visible_in_tree()

## A left press anywhere but the window a text line sits in takes the
## keyboard back from that line (round 605). The chat's line keeps the focus
## after Enter (LineEdit does not release it on text_submitted), and until
## rounds 595-604 almost every HUD button took it away on the next click: the
## underbar and the windows were built by UiBuilder, whose TextureButtons
## are FOCUS_ALL, so a click on one moved the focus to the button and the
## panel keys reached _unhandled_key_input again. The rebuilt HUD's controls
## -- the underbar and its menu, the guild, quest, alchemy and world map
## windows (TwoDtBuilder) and every window's close button -- are FOCUS_NONE,
## so after a line of chat the focus stayed in the chat through every click
## on them, and I, C, K, Q, U, M, Y, the number keys and WASD all went into
## the chat line until the player happened to click the open world
## (World3D.take_focus_back). Measured in the world with OPENSRO_QA_INPUT
## (docs/RE_COMPLETION.md, round 605): on v0.1.450 a click on the bar's
## community button left the focus on that button and K opened the skill
## window; on d4d1303 a click on the bar's inventory button left it in the
## chat and K and C opened nothing.
##
## "The window it sits in" is the HUD surface -- a child of HudPanels (a
## window) or of the HUD container beside it (the chat, the bar, the
## minimap) -- that holds the line, and a press counts as on it when that
## surface is the topmost one under the press (_surface_at). The line's own
## rect counts as its surface's, but only where the walk reaches the surface:
## a window drawn over the line -- over the chat (stack_over), or over a
## party-match field -- takes the press, and with it the keyboard, even on
## the covered part of the line (round 606; round 605 tested the line's rect
## first, so a press on a window covering it kept the focus in a line the
## player could not see). Where nothing covers it the line keeps the focus
## for a press on itself, including the chat line's strip that hangs over
## the bar (the chat comes after the bar in the tree, so the walk reaches it
## first). A press on the chat's own scrollback or frame keeps the line
## (round 522's review). A line outside the HUD -- the debug panel's
## teleport field and font spin box, under World3D's $UI rather than the HUD
## container -- keeps the focus only for a press on the line: _surface_at
## cannot see that panel, nor the help window (its root is IGNORE), so a
## press anywhere off such a line releases it. Only the left button, as take_focus_back: a right drag
## orbits the camera and the wheel zooms, and neither should end a message.
## The focus is released before the GUI sees the press, so a press on another
## text line hands the focus straight to it, and the press itself carries on
## to whatever it landed on. Our rule: whether the retail client ends chat
## input on a click elsewhere was not read.
func release_text_focus_on_press(event: InputEvent) -> bool:
	var mb := event as InputEventMouseButton
	if mb == null or not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT or not is_inside_tree():
		return false
	var focus := get_viewport().gui_get_focus_owner()
	if not (focus is LineEdit or focus is TextEdit):
		return false
	var at := mb.position
	var host := _surface_of(focus)
	if host == null:
		if focus.get_global_rect().has_point(at):
			return false
	elif _surface_at(at, host, focus) == host:
		return false
	focus.release_focus()
	return true

## The HUD surface a control belongs to: its ancestor (or itself) that is a
## window of this node or a child of the HUD container this node sits in.
## Null for a control outside both.
func _surface_of(node: Node) -> Control:
	var container := get_parent()
	while node != null:
		var parent := node.get_parent()
		if parent == self or (parent == container and node != self):
			return node as Control
		node = parent
	return null

## The topmost visible HUD surface whose rect holds `at`, in draw order: the
## container's later children first, and this node's windows where this node
## stands among them. Surfaces that ignore the mouse are passed over, as
## Godot's own hit test passes them. `host`, when given, also answers for
## `line`'s rect (a line can hang outside its surface, as the chat's does
## over the bar), at its own place in the order. Null over the open world.
func _surface_at(at: Vector2, host: Control = null, line: Control = null) -> Control:
	var container := get_parent()
	if container == null:
		return null
	for i in range(container.get_child_count() - 1, -1, -1):
		var child := container.get_child(i)
		if child == self:
			for j in range(get_child_count() - 1, -1, -1):
				var window := get_child(j) as Control
				if _takes_press(window, at) or _line_takes_press(window, host, line, at):
					return window
		elif _takes_press(child as Control, at) or _line_takes_press(child as Control, host, line, at):
			return child as Control
	return null

static func _line_takes_press(c: Control, host: Control, line: Control, at: Vector2) -> bool:
	return c != null and c == host and line != null and line.is_visible_in_tree() \
		and line.get_global_rect().has_point(at)

static func _takes_press(c: Control, at: Vector2) -> bool:
	return c != null and c.is_visible_in_tree() and c.mouse_filter != Control.MOUSE_FILTER_IGNORE \
		and c.get_global_rect().has_point(at)

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
## already up: a dark, gold-edged box of this project's own design, headed
## with the talk line's own text. The panel's
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
		_qa_print_buttons(panel, str(panel.name))

## The name prompt behind the guild NPC's create line (round 521): a line for
## the name, then Create and Cancel. Create (or Enter) emits
## guild_create_requested with the trimmed name and closes the prompt; the
## server's reply goes to chat (World3D._on_guild_create_result). The prompt
## is this project's own design (a dark, gold-edged panel), not the real
## client's guild-creation window, which
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
	KeyInput.line_edit_as_42(name_edit)  # round 754
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

## The confirmation behind the guild NPC's leave line: round 822 makes it
## the original's box 0x14 (CIF_NPCTalk::FUN_007020c0 case 0x1c opens it
## with 0x6ec5d0; GuildMsgBox has its text). OK emits guild_leave_requested.
func open_guild_leave_prompt(npc_name: String) -> void:
	print("GUILDPROMPT %s: leave box 0x14 opened" % npc_name)
	var box := open_guild_box(GuildMsgBox.Kind.LEAVE)
	if box != null:
		box.accepted.connect(func(_t: String) -> void: guild_leave_requested.emit())

## Round 822: one of the guild's CMessageBoxManager boxes (GuildMsgBox.Kind)
## over the HUD, placed as 0x6ec5d0 places it; null without the layout. The
## caller connects `accepted`. An open box of the same kind is closed first.
func open_guild_box(kind: int, what: String = "", who: String = "") -> GuildMsgBox:
	if _builder == null:
		return null
	var old: GuildMsgBox = _guild_boxes.get(kind)
	if is_instance_valid(old):
		old.close()
	var box := GuildMsgBox.new()
	if not box.build_guild_box(_builder, kind, who, what):
		box.free()
		return null
	add_child(box)
	box.place_on(get_viewport_rect().size if is_inside_tree() else Vector2(1024, 768))
	_guild_boxes[kind] = box
	_qa_print_buttons(box, str(box.name))
	return box

var _guild_boxes := {}

## Round 822: 0x3080 kind 5's box 0x0F; its answer goes out as
## guild_invitation_answered, its own timer's close as
## guild_invitation_expired.
signal guild_invitation_answered(accept: bool)
signal guild_invitation_expired

func show_guild_invitation(who: String, guild_name: String) -> GuildMsgBox:
	var box := open_guild_box(GuildMsgBox.Kind.INVITE, guild_name, who)
	if box == null:
		return null
	box.accepted.connect(func(_t: String) -> void: guild_invitation_answered.emit(true))
	box.cancelled.connect(func() -> void: guild_invitation_answered.emit(false))
	box.expired.connect(func() -> void: guild_invitation_expired.emit())
	box.arm_timer()
	return box

## B0F8's 0x4c10: the open box 0x0F goes, unanswered (0x6ec7f0(0xf)).
func close_guild_invitation() -> void:
	var box: GuildMsgBox = _guild_boxes.get(GuildMsgBox.Kind.INVITE)
	if is_instance_valid(box):
		box.close()
	_guild_boxes.erase(GuildMsgBox.Kind.INVITE)

## The box behind a town gate's "Designate as return/recall point" line (round
## 686). READ: retail's line opens message box kind 5 (CIF_NPCTalk::
## FUN_007020c0 case 9, 0x7027b5) over the talk box, which stays open (its
## OK takes the target from it, FUN_00797d90 case 5); kind 5
## (UI_SILKMALL::FUN_00644c90, entry 0x644f93) is titled UIIT_STT_AGREEMENT_BOX
## and says UIIT_MSG_MSGBOX_SETREBIRTH_CURPOS with the current region's zone
## name, then UIIT_MSG_MSGBOX_SETREBIRTH_ASKCERTIFY; OK sends the request,
## anything else nothing. OURS: the box is the talk prompts' dark, gold-edged
## panel, not the msgbox art, and its buttons read "OK" / "Cancel" (kind 5's
## button controls were not read for their labels). `zone_name` is the
## player's current zone's name (World3D._current_zone_name).
func open_recall_designate_prompt(npc_name: String, zone_name: String) -> void:
	var window: HudWindow = _windows.get("npctalk")
	if window == null:
		return
	print("RECALLPROMPT %s: opened at '%s'" % [npc_name, zone_name])
	var panel := _talk_prompt(window, "RecallDesignatePrompt",
		_resolve_ui(RecallNet.TITLE_STRID, RecallNet.TITLE_FALLBACK))
	var vb: VBoxContainer = panel.get_node("VB")
	var curpos := _shop_label(RecallNet.current_position_line(
		_resolve_ui(RecallNet.CURPOS_STRID, RecallNet.CURPOS_FALLBACK), zone_name), Color(0.86, 0.82, 0.7))
	curpos.name = "CurrentPosition"
	vb.add_child(curpos)
	var ask := _shop_label(_resolve_ui(RecallNet.ASK_STRID, RecallNet.ASK_FALLBACK), Color(0.86, 0.82, 0.7))
	ask.name = "Ask"
	vb.add_child(ask)
	var confirm := func() -> void:
		print("RECALLPROMPT %s: confirmed" % npc_name)
		recall_designate_requested.emit()
		panel.queue_free()
	_talk_prompt_buttons(panel, [
		["OK", "OK", confirm],
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
# RETAIL'S CHOICES (round 665; docs/protocol/character_state.md, "The
# resurrect choices"). READ: the retail dead window is message box kind 3
# (UI_SILKMALL::FUN_00644c90 case 3): the line UIIT_MSG_MSGBOX_ASK_SELF_REBIRTH_2
# ("Choose a method to resurrect yourself.") and two buttons. Control 0xc9 is
# UIIT_MSG_MSGBOX_REBIRTH_POINT_BUTTON ("Resurrect at the specified point.",
# pushed at 0x6455ed) and sends the option 1; control 0xca is
# UIIT_MSG_MSGBOX_REBIRTH_STANDING_BUTTON ("Resurrect at the present point.")
# while the player's max level is at most 10 (`cmp al,0xa; ja` at 0x645688)
# and sends the option 2, else UIIT_MSG_MSGBOX_REBIRTH_HELP_BUTTON ("Waiting
# for other player's help.") and sends nothing (FUN_00797d90: 0x797e30 /
# 0x797eec / 0x797efd). The wording is the player's own textuisystem.txt
# through _resolve_ui; the English fallbacks are that table's English column.
# OURS: the panel is the talk prompts' dark, gold-edged box, not the retail
# msgbox art (interface\messagebox\msgbox_rebirth_button.ddj is not drawn);
# our death line stays above retail's; and the help button is shown disabled
# and the box stays up, where retail's click closes the box (INFERRED, the
# result goes through FUN_00777dd0) -- no one can resurrect another player in
# OpenSRO yet, so the return point must stay one click away.

## The prompt's node name under this HUD; at most one is up at a time.
const REVIVE_PROMPT := "RevivePrompt"

## Whether the player is dead (World3D._player_dead, set by _enter_dead_state
## and cleared by _leave_dead_state; round 550). The bag's right-click use
## reads it: the server refuses a dead player's OpUseItem (Item_HandleUseItem
## 0x510980 answers 0x1889 unless GetLifeState() == 1), so nothing goes out.
var player_dead := false:
	set(value):
		player_dead = value
		# Nothing stays on the cursor through a death (round 652's review:
		# a stale drop could move whatever is in the slot by then).
		if value:
			cancel_held_icon("death")

## The chat line for an item tried while dead: World3D.DEAD_INPUT_LINE's
## wording (World3D has no class_name to read it from).
const DEAD_INPUT_LINE := "You are dead. Revive first."

## A resurrect button was clicked, with retail's option byte: 1 the return
## point, 2 the present point. World3D sends OpRevive (_on_revive_requested).
signal revive_requested(option: int)

## Retail's options (the server's GObjPC_HandleResurrectMsg_053 byte).
const REVIVE_OPTION_RETURN_POINT := 1
const REVIVE_OPTION_PRESENT_POINT := 2
## The highest max level the present point is offered at (READ, 0x645688).
const REVIVE_PRESENT_POINT_MAX_LEVEL := 10

## The buttons' node names, for the suite and the QA hooks.
const REVIVE_BUTTON_POINT := "RevivePoint"
const REVIVE_BUTTON_HERE := "ReviveHere"
const REVIVE_BUTTON_HELP := "ReviveHelp"

## Puts the dead window over the world: `line` (World3D's death line), retail's
## "Choose a method" line and its two buttons for a character of max level
## `level` (0: unknown, taken as 10 or under -- the server refuses the
## present point above it anyway). Replaces a prompt already up. Sits on this
## HUD, not on a window, so it stays while every window closes and is never
## hidden with one.
func show_revive_prompt(line: String, level: int = 0) -> void:
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
	box.add_child(_shop_label(_resolve_ui("UIIT_MSG_MSGBOX_ASK_SELF_REBIRTH_2",
		"Choose a method to resurrect yourself."), Color(0.95, 0.9, 0.72)))
	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 4)
	box.add_child(col)
	var point := Button.new()
	point.name = REVIVE_BUTTON_POINT
	point.text = _resolve_ui("UIIT_MSG_MSGBOX_REBIRTH_POINT_BUTTON", "Resurrect at the specified point.")
	point.pressed.connect(func() -> void: revive_requested.emit(REVIVE_OPTION_RETURN_POINT))
	col.add_child(point)
	var second := Button.new()
	if level <= REVIVE_PRESENT_POINT_MAX_LEVEL:
		second.name = REVIVE_BUTTON_HERE
		second.text = _resolve_ui("UIIT_MSG_MSGBOX_REBIRTH_STANDING_BUTTON", "Resurrect at the present point.")
		second.pressed.connect(func() -> void: revive_requested.emit(REVIVE_OPTION_PRESENT_POINT))
	else:
		second.name = REVIVE_BUTTON_HELP
		second.text = _resolve_ui("UIIT_MSG_MSGBOX_REBIRTH_HELP_BUTTON", "Waiting for other player's help.")
		second.disabled = true
	col.add_child(second)
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
	_qa_print_buttons(panel, "REVIVE")

## Takes the Revive prompt down (the revive came through, or a new prompt
## replaces it). Removed from the tree at once, so a prompt shown in the
## same frame is not renamed around a node still on its way out.
func hide_revive_prompt() -> void:
	var old := get_node_or_null(REVIVE_PROMPT)
	if old == null:
		return
	remove_child(old)
	old.queue_free()

# --- The gate's destinations (round 603) ------------------------------------
#
# 'Select teleport area' lists the gate's destinations in the talk box itself,
# as the retail client does (UI_TELEPORT::FUN_006fd3e0, TeleportBoard's
# header): the box's own text stays on top, then one numbered line per
# destination of the gate the player talked to, in the link table's file order
# with its fee (World3D._open_teleport_list builds the entries from
# TeleportReader.links_from), then the end line. Clicking a destination line
# emits teleport_requested. The talk box stays up; it closes on any zone
# change (World3D._close_gate_ui) or on its end line.

## The talk box's meta: the text shown above its lines (_fill_npc_talk), which
## the destination list keeps on top, as FUN_006fb530 re-adds this+0x7d4.
const TALK_TEXT_META := "talk_text"
## The talk box's meta: true while it shows a gate's destinations.
const TELEPORT_LIST_META := "teleport_list"

## Replaces the open talk box's lines with the gate's destinations (entries:
## Dictionaries {dest_id, place, fee, waived}) and the end line. False, and
## nothing drawn, when the talk box is not open.
func open_teleport_list(gate_name: String, entries: Array) -> bool:
	if not is_open("npctalk"):
		return false
	var window: HudWindow = _windows["npctalk"]
	var body := _talk_body(window)
	if body == null:
		return false
	var lines := PackedStringArray()
	# The same text, drawn as _fill_npc_talk drew it. No tax line: the list's
	# rebuild re-adds only the box's own text (FUN_006fb530 re-adds +0x7d4,
	# READ, round 603), as hWWsCP0.png shows.
	lines.append(str(window.get_meta(TALK_TEXT_META, "...")))
	lines.append("")
	lines.append_array(TeleportBoard.list_lines(gate_name, entries, _resolve_ui))
	NpcTalkView.show_lines(window, lines)
	window.set_meta(TELEPORT_LIST_META, true)
	print("HudPanels: teleport list for %s -- %d destination(s) in the talk box" % [gate_name, entries.size()])
	_qa_print_talk_lines.call_deferred(body)
	return true

## OPENSRO_QA_TALK_LINES, for a prompt (round 686): each button of `panel`
## with the screen point at its middle (`QA PROMPT <tag> BUTTON <name> at
## x,y`), a frame after it is placed, so a real X click can be aimed at it.
## QA only; prints nothing without the variable.
func _qa_print_buttons(panel: Control, tag: String) -> void:
	if OS.get_environment("OPENSRO_QA_TALK_LINES") == "" or not is_instance_valid(panel) or not panel.is_inside_tree():
		return
	await get_tree().process_frame
	if not is_instance_valid(panel):
		return
	for node in panel.find_children("*", "Button", true, false):
		var b := node as Button
		var c := b.get_global_rect().get_center()
		print("QA PROMPT %s BUTTON %s at %d,%d: %s" % [tag, b.name, int(c.x), int(c.y), b.text])

## OPENSRO_QA_TALK_LINES (round 642): each paragraph of the talk box as drawn,
## with the screen point at its middle, so a real X click can be aimed at a
## line (`QA TALK LINE <n> at x,y: <text>`). QA only; prints nothing without
## the variable.
func _qa_print_talk_lines(body: RichTextLabel) -> void:
	if OS.get_environment("OPENSRO_QA_TALK_LINES") == "" or not is_instance_valid(body):
		return
	await get_tree().process_frame
	await get_tree().process_frame
	var texts := body.get_parsed_text().split("\n")
	var count: int = body.get_paragraph_count()
	var rect := body.get_global_rect()
	for i in range(count):
		var top: float = body.get_paragraph_offset(i)
		var bottom: float = body.get_paragraph_offset(i + 1) if i + 1 < count else float(body.get_content_height())
		var text: String = texts[i] if i < texts.size() else ""
		print("QA TALK LINE %d at %d,%d: %s" % [i, int(rect.position.x + 40.0), int(rect.position.y + (top + bottom) * 0.5), text])

## Whether the talk box is up and shows a gate's destinations.
func teleport_list_shown() -> bool:
	return is_open("npctalk") and bool((_windows["npctalk"] as HudWindow).get_meta(TELEPORT_LIST_META, false))

## OPENSRO_QA_TALK_PICK (World3D, round 725): presses the talk box's numbered
## line `n` (1 = the first menu line) through the label's meta_clicked, the
## signal a click raises. Returns the line's key, or "" when there is none.
func qa_press_talk_line(n: int) -> String:
	if not is_open("npctalk"):
		return ""
	var body := NpcTalkView.body_of(_windows["npctalk"])
	if body == null:
		return ""
	var lines: PackedStringArray = body.get_meta(NpcTalkView.META_LINES, PackedStringArray())
	var seen := 0
	for line in lines:
		if line.begins_with("[url="):
			seen += 1
			if seen == n:
				var key := line.substr(5, line.find("]") - 5)
				body.meta_clicked.emit(key)
				return key
	return ""

## OPENSRO_QA_TELEPORT (World3D): prints the talk box's lines as drawn and
## clicks dest_id's line through the label's own meta_clicked, the signal a
## click raises. False when the list is not shown or does not hold dest_id.
func qa_press_teleport_line(dest_id: int) -> bool:
	if not teleport_list_shown():
		return false
	var body := NpcTalkView.body_of(_windows["npctalk"])
	if body == null:
		return false
	var key := "%s%d" % [TeleportBoard.DEST_KEY_PREFIX, dest_id]
	for line in body.get_parsed_text().split("\n"):
		print("QA TELEPORT: talk line: %s" % line)
	if body.text.find("[url=%s]" % key) < 0:
		return false
	body.meta_clicked.emit(key)
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
# each tab a `com_short_tab`, so up to four. Round 725 read the rest of the
# rect from CIFStoreForPackage::vslot_010: {16 + 56 i, 0x26, 0x38, 0x18} at
# 0x6d2d69..0x6d2d7d, the rect gwnd 0xba20b0 creates each tab with -- y 38,
# 56x24. The caption is white, READ: the same create path (0x6d2da4..0x6d2dfa)
# sets only its font and alignment, so it keeps the CTextBoard default
# 0xffffffff (0x655b50 -> 0x8b4f30 -> 0x8b46d0; HudWindow's caption note).
# The user's original (3Gw7Ene.png) measures both: the tab's top 38 below the
# window's, the caption 255,255,255. Round 724's build had it 2 px higher
# (the texture's height up from the grid frame's top, ours) and beige (ours).
const SHOP_TAB_ON := "interface\\ifcommon\\com_short_tab_on.ddj"
const SHOP_TAB_OFF := "interface\\ifcommon\\com_short_tab_off.ddj"
const SHOP_MAX_TABS := 4
const SHOP_TAB_X0 := 16.0
const SHOP_TAB_STEP := 56.0
## The tab's y and size (READ, 0x6d2d6d..0x6d2d7d; see above).
const SHOP_TAB_Y := 38.0
const SHOP_TAB_SIZE := Vector2(56, 24)
## The caption colour: the CTextBoard default white (READ, see above).
const SHOP_TAB_CAPTION := Color(1, 1, 1)

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
	_close_window_boxes(window)
	_shop_tabs = tabs
	_shop_selected = 0
	_build_shop_tab_strip(window)
	_wire_repair_buttons(window)
	_show_repair_buttons(window, npc_code)
	_lattice_takes_clicks(window, "GDR_STORE_SLOT_")
	_select_shop_tab(0)
	window.show()
	window.move_to_front()
	# 0x79dbd0(1, kind): the store (registry 0xf) shown, the inventory tab of
	# the main popup shown, then the helper on the store: the open (read,
	# 0x79dcfe). The popup gets no helper call of its own there.
	UiSounds.window_toggled(window.visible, _interface_shown(), "store opened (0x79dbd0)")
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
	# The buy-back row is the client's own list (round 728 review; c:0x78d900).
	_fill_buyback_row()

## Round 801: where the open store lists item_id -- the shown tab's index and
## the good's own slot (ShopReader.Tab.slots) -- or (-1, -1).
func shop_good_position(item_id: int) -> Vector2i:
	var code := item_code_for_id(item_id)
	if code == "" or _shop_selected < 0 or _shop_selected >= _shop_tabs.size():
		return Vector2i(-1, -1)
	var tab: ShopReader.Tab = _shop_tabs[_shop_selected]
	var i := tab.item_codes.find(code)
	if i < 0 or i >= tab.slots.size():
		return Vector2i(-1, -1)
	return Vector2i(_shop_selected, tab.slots[i])

## Round 801: the item id the open store lists at a tab and slot, -1 when none.
func shop_item_at(tab_index: int, slot: int) -> int:
	if tab_index < 0 or tab_index >= _shop_tabs.size():
		return -1
	var tab: ShopReader.Tab = _shop_tabs[tab_index]
	var i := tab.slots.find(slot)
	if i < 0:
		return -1
	_load_items()
	var item: ItemTableReader.Item = _items_by_code.get(tab.item_codes[i])
	return item.id if item != null else -1

## Round 801: whether a screen point is over the store window, frontmost.
func over_store(at: Vector2) -> bool:
	return _window_shown("store") and _over_window("store", at)

## Round 801: the count box for goods put down on the specialty store (the
## store's own sell box with the quoted unit price; OURS: the original's
## path from the transport's window opens CIFSpecialtyDeal, whose OK is not
## read).
func confirm_sell_goods(item_id: int, qty: int, unit_price: int, on_ok: Callable) -> void:
	_load_items()
	var item: ItemTableReader.Item = _items.get(item_id)
	if item == null:
		return
	_open_store_box("store", "SellConfirm", StoreMessageBox.Kind.SELL, {
		"icon": _item_icon(item_id), "name": item.display_name(_object_names),
		"count": maxi(1, qty), "max": maxi(1, qty), "unit_price": unit_price, "tax_rate": 0.0,
	}, on_ok)

## The item row of id (round 801), null when the table has none.
func item_row(id: int) -> ItemTableReader.Item:
	_load_items()
	return _items.get(id)

## The code name of item `id` in the player's own item table, "" when it has
## none (round 783: the Test Items NPC's goods come as ids, NpcShopDefNet).
func item_code_for_id(id: int) -> String:
	_load_items()
	var item: ItemTableReader.Item = _items.get(id)
	return item.code_name if item != null else ""

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
	var off: Texture2D = _builder.load_texture(SHOP_TAB_OFF) if _builder != null else null
	var tab_size: Vector2 = SHOP_TAB_SIZE
	for i in range(mini(_shop_tabs.size(), SHOP_MAX_TABS)):
		var tab: ShopReader.Tab = _shop_tabs[i]
		var btn := TextureButton.new()
		btn.name = "ShopTab%d" % i
		btn.ignore_texture_size = true
		btn.stretch_mode = TextureButton.STRETCH_SCALE
		btn.texture_normal = off
		btn.focus_mode = Control.FOCUS_NONE
		btn.position = Vector2(SHOP_TAB_X0 + i * SHOP_TAB_STEP, SHOP_TAB_Y)
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
		lbl.add_theme_color_override("font_color", SHOP_TAB_CAPTION)
		if _builder != null:
			var font := _builder.font_at(0)
			if font != null:
				lbl.add_theme_font_override("font", font)
			lbl.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[0])
		btn.add_child(lbl)
		strip.add_child(btn)

## The store and the warehouse each author 30 CIFSlotWithHelp controls,
## GDR_STORE_SLOT_100..129 (ifstore.txt) and GDR_STORAGE_SLOT_100..129
## (ifstorageroom.txt), on exactly the 30 cells of their lattice (READ: slot
## 100 at 21,71,32,32 = the lattice's first cell, step 36). This client draws
## and clicks the goods in the lattice cells (_fill_shop_grid,
## _fill_storage_grid). The slot controls come later in the tree, so Godot
## hit-tests them first, and with MOUSE_FILTER_PASS a click goes on to the
## slot's PARENTS, never to the cell under it: round 631 MEASURED a real X
## click on the first good land on GDR_STORE_SLOT_100 and never reach the
## cell's ItemIcon, so no good could be clicked to buy. The slots stay drawn;
## they just stop taking the mouse. OURS: which of the two controls takes the
## click is this client's arrangement, not the original's.
func _lattice_takes_clicks(window: HudWindow, slot_prefix: String) -> void:
	if window == null or window.panel_root == null:
		return
	for slot in window.panel_root.find_children(slot_prefix + "*", "Control", true, false):
		(slot as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE

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
	# Round 829: the store hiding ends the hammer (CIFStore::vslot_023,
	# 0x6d0166: +0x7c8 = 0, 0x777e70(-1)) and closes its question.
	if not window.has_meta("repair_hide_wired"):
		window.set_meta("repair_hide_wired", true)
		window.visibility_changed.connect(func() -> void:
			if not window.is_visible_in_tree():
				_end_repair_mode("the store closed")
				if is_instance_valid(_repair_box):
					_repair_box.close())

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

## Round 829: Repair All (CIFStore control 0xc -> 0x6cfc00, READ): the
## client's own quote of every worn (0..7) and bag item it would mend
## (RepairQuote); 0 says UIIT_MSG_STRGERR_THERE_IS_NO_ITEM_TO_REPAIR in the
## system window and opens nothing; otherwise the agreement box (RepairBox),
## whose Yes sends the repair of everything. Until round 829 it sent at once.
func _on_repair_all_pressed() -> void:
	if NetClient.current_character_name == "":
		return
	var total := repair_all_quote()
	print("HudPanels: Repair All quotes %d gold" % total)
	if total <= 0:
		system_notice.emit(_resolve_ui("UIIT_MSG_STRGERR_THERE_IS_NO_ITEM_TO_REPAIR", "No item needs repairing."))
		return
	if is_instance_valid(_repair_box):
		_repair_box.close()
	if _builder == null:
		return
	var box := RepairBox.new()
	if not box.build_repair_all(_builder, total):
		box.free()
		return
	add_child(box)
	box.place_on(get_viewport_rect().size if is_inside_tree() else Vector2(1024, 768))
	box.accepted.connect(func(_t: String) -> void: _send_repair(EquipmentNet.REPAIR_ALL))
	_repair_box = box
	_qa_print_buttons(box, str(box.name))

var _repair_box: RepairBox = null

## QA (OPENSRO_QA_SHOP_STEPS' "repair:<what>", round 829).
func qa_repair_step(what: String) -> String:
	match what:
		"all":
			_on_repair_all_pressed()
			return "quote %d, box %s (%s)" % [repair_all_quote(), "up" if is_instance_valid(_repair_box) else "none",
				_repair_box.amount_text() if is_instance_valid(_repair_box) else ""]
		"yes":
			if not is_instance_valid(_repair_box):
				return "no box"
			var ok := _repair_box.button("GDR_MBIN_BTN_OK")
			if ok != null:
				ok.emit_signal("pressed")
			return "Yes pressed"
		"hammer":
			_on_repair_one_pressed()
			return "repair mode %s, forced cursor 0x%x" % [_repair_mode, GameCursor.forced_id]
	if what.begins_with("worn"):
		_repair_click("worn", int(what.trim_prefix("worn")))
		return "clicked worn %s" % what.trim_prefix("worn")
	if what.begins_with("bag"):
		_repair_click("bag", int(what.trim_prefix("bag")))
		return "clicked bag %s" % what.trim_prefix("bag")
	return "unknown"

## Round 829: Repair (control 0xb -> 0x6cea60, READ) is a toggle: with a
## forced cursor up it clears it (0x777e70(-1)); otherwise it sets the store's
## repair mode (+0x7c8) and the hammer (0x777e70(0x96)). The store hiding
## (CIFStore::vslot_023 0x6d0166) ends it too. A slot clicked meanwhile is
## repaired (_repair_click). Until round 829 the button repaired everything.
func _on_repair_one_pressed() -> void:
	if GameCursor.forced_id >= 0 or _repair_mode:
		_end_repair_mode("the Repair button again")
		return
	_repair_mode = true
	GameCursor.force(CursorSet.ID_REPAIR, get_window())
	print("HudPanels: repair mode on (the hammer)")

var _repair_mode := false

func _end_repair_mode(why: String) -> void:
	if not _repair_mode:
		return
	_repair_mode = false
	GameCursor.force(-1, get_window())
	print("HudPanels: repair mode off (%s)" % why)

## Whether the store's hammer is up.
func repair_mode() -> bool:
	return _repair_mode

## Round 829: a slot clicked under the hammer (CIFSlotWithHelp::vslot_029,
## branch 0x6811e9, READ): a worn or bag slot holding an item; CanRepair
## (column 22) 0 does nothing; an item that cannot be repaired
## (RepairQuote.can_be_repaired) says 0x1c11 as the server would (the client
## posts itself 0xB03E {2, 0x1c11}); one at its maximum does nothing;
## otherwise the repair goes at once, with no box, and the hammer stays up.
## `where` is "worn" or "bag".
func _repair_click(where: String, slot: int) -> void:
	var item_id := _worn_item_id_at(slot) if where == "worn" else _bag_item_id_at_slot(slot)
	if item_id < 0:
		return
	_load_items()
	var item: ItemTableReader.Item = _items.get(item_id)
	if item == null or item.can_repair == 0:
		return
	var types := item_types(item_id)
	var inst := _item_instance("equipment" if where == "worn" else "bag", slot)
	var options: Array = ItemTooltipInstance.option_entries(inst, item.item_class) if inst != null else []
	if not RepairQuote.can_be_repaired(types, options):
		system_notice.emit(ErrorText.repair_line(0x1c11, _text_table()))
		return
	var dur := _durability_of(where, slot)
	if dur.size() != 2 or int(dur[0]) >= int(dur[1]):
		return
	_send_repair(slot if where == "worn" else REPAIR_BAG_BASE + slot)

## The bag's slot numbering in a repair (the original's: bag slot + 13).
const REPAIR_BAG_BASE := 13

## [current, maximum] of a worn ("worn") or bag ("bag") slot, or [].
func _durability_of(where: String, slot: int) -> Array:
	var list: Array = NetClient.last_equipment_durabilities if where == "worn" else NetClient.last_inventory_durabilities
	for d in list:
		if d != null and d.get("slot") != null and int(d.get("slot")) == slot:
			return [int(d.get("current")), int(d.get("maximum"))]
	return []

func _worn_item_id_at(slot: int) -> int:
	for e in _equipped_items:
		if e is EquipmentNet.Equipped and (e as EquipmentNet.Equipped).slot == slot:
			return (e as EquipmentNet.Equipped).item_id
	return -1

## The client's Repair All quote (RepairQuote's rules over the worn slots
## 0..7 and every bag slot).
func repair_all_quote() -> int:
	_load_items()
	var total := 0
	var parts := [["worn", _equipped_worn_pairs()], ["bag", _bag_pairs()]]
	for part in parts:
		var where: String = part[0]
		for pair in part[1]:
			var slot := int(pair[0])
			var item_id := int(pair[1])
			if where == "worn" and slot >= RepairQuote.WORN_SLOTS:
				continue
			var item: ItemTableReader.Item = _items.get(item_id)
			if item == null:
				continue
			var types := item_types(item_id)
			if not RepairQuote.counts(types):
				continue
			var inst := _item_instance("equipment" if where == "worn" else "bag", slot)
			var options: Array = ItemTooltipInstance.option_entries(inst, item.item_class) if inst != null else []
			if not RepairQuote.can_be_repaired(types, options):
				continue
			var dur := _durability_of(where, slot)
			if dur.size() != 2:
				continue
			total += RepairQuote.cost(int(dur[0]), int(dur[1]), item.cost_repair, item.cost_revive)
	return total

func _equipped_worn_pairs() -> Array:
	var out: Array = []
	for e in _equipped_items:
		if e is EquipmentNet.Equipped:
			out.append([(e as EquipmentNet.Equipped).slot, (e as EquipmentNet.Equipped).item_id])
	return out

func _bag_pairs() -> Array:
	var out: Array = []
	for d in NetClient.last_inventory_durabilities:
		if d != null and d.get("slot") != null:
			var s := int(d.get("slot"))
			var id := _bag_item_id_at_slot(s)
			if id >= 0:
				out.append([s, id])
	return out

## Sends a repair (a worn slot, a bag slot + 13, or EquipmentNet.REPAIR_ALL),
## noting every item's durability first so the reply can tell which rose.
func _send_repair(slot: int) -> void:
	var who := NetClient.current_character_name
	if who == "":
		return
	_repair_before = {}
	for d in NetClient.last_equipment_durabilities:
		if d != null and d.get("slot") != null:
			_repair_before[int(d.get("slot"))] = int(d.get("current"))
	for d in NetClient.last_inventory_durabilities:
		if d != null and d.get("slot") != null:
			_repair_before[REPAIR_BAG_BASE + int(d.get("slot"))] = int(d.get("current"))
	print("HudPanels: repair %s" % ("everything" if slot == EquipmentNet.REPAIR_ALL else "slot %d" % slot))
	NetClient.repair(who, slot)

var _repair_before := {}

## A repair's outcome. Round 829 (READ): 0xB03E's result 1 shows nothing
## (0x880a20) -- every item whose durability rose sounds snd_repair (from 0:
## snd_revive) and plays its slot's flash (0x3052's handler 0x8adf50 ->
## 0x6ab8a0 / 0x6b44a0, RepairFlash), worn and bag alike; any other result's
## code goes to the system window (0x778190(0xd, code)): 0x1c07 not enough
## gold, 0x1c0b busy, 0x1c11 cannot be repaired, 0x1c12 cannot be revived
## (ErrorText). Before round 829 a success put our own "Repaired for X gold."
## in the store and a refusal went there too.
func _on_repair_result(code: int, gold_spent: int, durabilities: Array) -> void:
	var who := NetClient.current_character_name
	if code != 0:
		print("HudPanels: repair refused (0x%x)" % code)
		system_notice.emit(ErrorText.repair_line(code, _text_table()))
		return
	var after := {}
	for d in durabilities:
		if d != null and d.get("slot") != null:
			after[int(d.get("slot"))] = int(d.get("current"))
	var rose := 0
	var keys := after.keys()
	keys.sort()
	for k in keys:
		if not _repair_before.has(k) or int(after[k]) <= int(_repair_before[k]):
			continue
		rose += 1
		_flash_repaired(int(k))
	UiSounds.durability_changed(_repair_before, after, "repair reply")
	for k in after:
		if int(k) < REPAIR_BAG_BASE:
			UiSounds.worn_durability[int(k)] = after[k]
	print("HudPanels: repaired %d item(s) for %d gold" % [rose, gold_spent])
	if who != "":
		# Refresh the worn list (durability + doll), the bag and the purse.
		NetClient.list_equipment(who)
		NetClient.list_inventory(who)
		NetClient.character_stats(who)

## Round 829: 0x3052, one item's durability (0x8adf50, READ): the sound
## (UiSounds.durability_key), a rise's flash, the slot's mark redrawn, and --
## a worn slot -- the HUD's figure (worn_durability_changed; 0x778b20 from
## 0x8ae126).
signal worn_durability_changed

func _on_durability_changed(slot: int, durability: int, was: int) -> void:
	var worn := slot < REPAIR_BAG_BASE
	var key := UiSounds.durability_key(was, durability, worn)
	if key != "":
		UiSounds.play(key, "0x3052 slot %d %d -> %d" % [slot, was, durability])
	if was >= 0 and durability > was:
		_flash_repaired(slot)
	if worn:
		UiSounds.worn_durability[slot] = durability
		_fill_equipment_slots(_equipped_items)
		worn_durability_changed.emit()
	else:
		_draw_bag_page()

## Round 829: an item's worn-out mark on its slot icon (DurabilityMark).
func _mark_durability(icon: Control, item_id: int, cur: int, maximum: int, animated := true) -> void:
	var st := DurabilityMark.state_for(item_types(item_id), cur, maximum)
	if st != DurabilityMark.State.NONE and _mark_broken_tex == null and _builder != null:
		_mark_broken_tex = _builder.load_texture(DurabilityMark.BROKEN_DDJ)
		_mark_warning_tex = _builder.load_texture(DurabilityMark.WARNING_DDJ)
	DurabilityMark.apply(icon, st, _mark_broken_tex, _mark_warning_tex, animated)

var _mark_broken_tex: Texture2D = null
var _mark_warning_tex: Texture2D = null

## The mark a bag slot's item gets on a quick slot (no counter there: frame
## 0), for World3D's bar.
func mark_quick_slot(icon: Control, bag_slot: int) -> void:
	var item_id := _bag_item_id_at_slot(bag_slot) if bag_slot >= 0 else -1
	var dur := _durability_of("bag", bag_slot) if item_id >= 0 else []
	if dur.size() != 2:
		DurabilityMark.apply(icon, DurabilityMark.State.NONE, null, null)
		return
	_mark_durability(icon, item_id, int(dur[0]), int(dur[1]), false)

## The flash on the slot of `key` (a worn slot, or bag slot + 13), if shown.
func _flash_repaired(key: int) -> void:
	var icon := _repair_slot_icon(key)
	if icon == null:
		return
	if _repair_sheet == null and _builder != null:
		_repair_sheet = _builder.load_texture(RepairFlash.DDJ)
	RepairFlash.play_on(icon, _repair_sheet)

var _repair_sheet: Texture2D = null

## The icon control of a worn slot (key < 13) or of bag slot key - 13 on the
## page shown, or null.
func _repair_slot_icon(key: int) -> Control:
	var window: HudWindow = _windows.get("inventory")
	if window == null:
		return null
	if key < REPAIR_BAG_BASE:
		var slot := window.node("GDR_EQUIPMENT_SLOT_%d" % (EQUIPMENT_SLOT_BASE + key)) as Control
		return slot.get_node_or_null("ItemIcon") as Control if slot != null else null
	var grid := window.node("GDR_INVENTORY_LATTICE") as Control
	if grid == null:
		return null
	for c in grid.find_children("*", "TextureRect", true, false):
		if (c as Control).has_meta("inv_slot") and int((c as Control).get_meta("inv_slot")) == key - REPAIR_BAG_BASE:
			return c as Control
	return null

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
			_set_item_seal_edge(icon, item.id)
			_set_item_tip(icon, item.id, "store", ci, -1, -1, int(_shop_prices.get(item.id, -1)))
			icon.mouse_filter = Control.MOUSE_FILTER_STOP
			icon.set_meta("shop_item_id", item.id)
			# Click to buy. Wired once per cell (the cells persist across tab
			# switches); the meta above carries the current item.
			if not icon.has_meta("shop_click_wired"):
				icon.set_meta("shop_click_wired", true)
				icon.gui_input.connect(func(ev: InputEvent) -> void: _on_shop_cell_input(ev, icon))
		else:
			icon.texture = null
			_set_item_seal_edge(icon, -1)
			_set_item_tip(icon, -1)
			icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
			if icon.has_meta("shop_item_id"):
				icon.remove_meta("shop_item_id")

## A click on a store item picks it up onto the cursor; putting it down on
## the bag opens the buy dialog (HeldIcon, round 652; CIFInventory::vslot_028
## 0x6b5b80 takes kind 0x0f, the store, into the buy path).
func _on_shop_cell_input(event: InputEvent, icon: TextureRect) -> void:
	# Round 726: Ctrl+click buys with no box (_ctrl_buy).
	if _is_ctrl_click_on(event, icon) and icon.has_meta("shop_item_id") \
			and (held_icon == null or not held_icon.is_holding()):
		_ctrl_buy(int(icon.get_meta("shop_item_id")))
		return
	if _is_pick_click_on(event, icon) and icon.has_meta("shop_item_id"):
		pick_up_icon({"kind": "shop", "item_id": int(icon.get_meta("shop_item_id")), "icon": icon.texture},
			icon.texture, icon, (event as InputEventMouseButton).global_position)

# --- Buy confirmation, results ---------------------------------------------
## Round 725: the store carried two labels of ours under its grid -- "Gold:
## <purse>" and a status line -- on the band where the original draws its
## buy-back row (GDR_STORE_STRETCH_REDEEM, the five GDR_STORE_ICON_SLOT_0n
## and "Buy back", RESTORE_SOLDITEM_INSHOP). Both are gone (npc_gui.md gap
## 7); the purse is the bag's own GDR_INVENTORY_STA_MONEY beside the store.
## A store outcome (a repair, a refusal) is a line for the chat's system
## channel instead (system_notice, ours: the original's per-code lines are
## lane C's, docs/protocol/npc_gui.md).
func _set_shop_status(text: String) -> void:
	var window: HudWindow = _windows.get("store")
	if window == null:
		return
	system_notice.emit(text)
	var status := window.get_node_or_null("ShopStatus") as Label
	if status != null:
		status.text = text

## The buy box: the original's CItemMallConfirmBuy (round 726, StoreMessageBox),
## opened when a good is put down on the bag (CIFInventory::vslot_028
## 0x6b5b80 -> 0x6b2570 -> 0x6b24c0(1), message_box.md). The count starts
## at 1 (MEASURED, the user's 3Gw7Ene.png) and runs to the item's stack;
## the price is the server's quote times the count. Buy sends the purchase;
## the server refuses what the purse cannot pay (OURS: the box does not grey
## Buy out, the original's box has no such state that was read).
func _confirm_buy(item_id: int) -> void:
	_load_items()
	var item: ItemTableReader.Item = _items.get(item_id)
	if item == null:
		return
	_open_store_box("store", "BuyConfirm", StoreMessageBox.Kind.BUY, {
		"icon": _item_icon(item_id), "name": item.display_name(_object_names),
		"count": 1, "max": maxi(1, item.max_stack), "unit_price": _shop_prices.get(item_id, -1),
	}, func(q: int) -> void: _do_buy(item_id, q))

## Opens one of the store's or the warehouse's confirm boxes on `host_id`'s
## window (round 726): built by StoreMessageBox from the client's layouts,
## placed where the original places it (StoreMessageBox.screen_position,
## READ), closed with its window (round 631). `on_ok` gets the box's count. Null
## when the window is not open or a layout is missing.
func _open_store_box(host_id: String, box_name: String, box_kind: int, opts: Dictionary, on_ok: Callable) -> StoreMessageBox:
	var window: HudWindow = _windows.get(host_id)
	if window == null:
		return null
	var old := window.get_node_or_null(box_name) as Control
	if old != null:
		_close_confirm_box(old)
	# Every box but the buy box is the one CIFInventory +0x390, destroyed
	# before each new one (0x6af530 -> 0x6aef20 -> 0xba0e40): one at a time,
	# across the store and the warehouse (READ, round 726 review).
	# ConfirmBuy is a separate object (ID 400) and stays separate.
	if box_kind != StoreMessageBox.Kind.BUY:
		for host in ["store", "storage", "inventory"]:
			var w: HudWindow = _windows.get(host)
			if w == null:
				continue
			for other in INVENTORY_BOXES:
				var o := w.get_node_or_null(other) as Control
				if o != null:
					_close_confirm_box(o)
	var box := StoreMessageBox.new()
	box.name = box_name
	if not box.build(_builder, box_kind, opts):
		push_warning("HudPanels: the %s box could not be built (a layout is missing)" % box_name)
		box.free()
		return null
	box.confirmed.connect(on_ok)
	window.add_child(box)
	# The box is the host window's child; the original's is a window of its
	# own over the rest. Raise the host so no other window (the bag beside
	# the warehouse) draws over the box or takes its clicks (round 726 live
	# run: the gold box sat under the inventory).
	window.move_to_front()
	_track_confirm_boxes(window)
	_message_box_sounds(box)
	_place_box_on_screen(box)
	print("HudPanels: %s opened (%s), count %d of %d, price '%s'" % [box_name,
		StoreMessageBox.Kind.keys()[box_kind], box.count, box.max_count, box.price_text()])
	return box

## Puts a confirm box where the original does (READ: 0x798b70 on the box's
## creation size; StoreMessageBox.screen_position).
func _place_box_on_screen(box: StoreMessageBox) -> void:
	if not box.is_inside_tree():
		return
	box.global_position = box.screen_position(box.get_viewport_rect().size)

## Ctrl+click on a good buys it with no box (round 726; READ
## CIFSlotWithHelpForPackage::vslot_029 0x68a6c0: VK_CONTROL held, the store
## open, the target the bag 0x46, the count the item's stack (+0x1c0) or 1).
func _ctrl_buy(item_id: int) -> void:
	_load_items()
	var item: ItemTableReader.Item = _items.get(item_id)
	var n: int = maxi(1, item.max_stack) if item != null else 1
	print("HudPanels: ctrl+click buys item %d x%d with no box" % [item_id, n])
	_do_buy(item_id, n)

## Whether an event is a left click released with Ctrl held (no Shift or
## Alt) over `control`: the original's Ctrl+click on a slot.
func _is_ctrl_click_on(event: InputEvent, control: Control) -> bool:
	if not (event is InputEventMouseButton):
		return false
	var mb := event as InputEventMouseButton
	return mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed and mb.ctrl_pressed \
		and not mb.shift_pressed and not mb.alt_pressed and control != null \
		and (not control.is_inside_tree() or control.get_global_rect().has_point(mb.global_position))

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

## Round 801: a specialty store's buy of a good goes into the transport
## (SpecialtyFlow.buy, 0x7034 type 0x13); the hook answers true when it took
## the buy.
var specialty_buy_hook: Callable

func _do_buy(item_id: int, quantity: int = 1) -> void:
	if specialty_buy_hook.is_valid() and bool(specialty_buy_hook.call(item_id, maxi(1, quantity))):
		return
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
	print("HudPanels: buy result ok=%s %s" % [ok, reason])
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

## The sell box: CIFMessageBox mode 6, purpose 2 (round 726, StoreMessageBox),
## opened when a bag item is put down on the store (CIFStore::vslot_028
## 0x6d1400 -> 0x6b07d0). A stack is prefilled with its size and capped
## there (0x6b0a52..0x6b0a87, READ); the price is the item's sell price
## (itemdata's SellPrice; the original reads its reference +0xb8, INFERRED to
## be the same column) times the count, less the store's tax
## (StoreMessageBox.price_text, READ 0x63bd60), the server's result the
## truth. On Sell the slot must still hold the item (OURS: the box is not
## modal, so the slot can change under it -- round 726 review).
func _confirm_sell(slot: int, item_id: int, slot_qty: int) -> void:
	_load_items()
	var item: ItemTableReader.Item = _items.get(item_id)
	if item == null:
		return
	var held := maxi(1, slot_qty)
	_open_store_box("store", "SellConfirm", StoreMessageBox.Kind.SELL, {
		"icon": _item_icon(item_id), "name": item.display_name(_object_names),
		"count": held, "max": held, "unit_price": item.sell_price,
		"tax_rate": shop_tax_rate,
	}, func(q: int) -> void:
		if _bag_slot_still_holds(slot, item_id, q, "sell"):
			_do_sell(slot, q))

## Ctrl+click on a bag item while the store is open sells it with no box
## (round 726; READ CIFSlotWithHelp::vslot_029 0x680fa0: VK_CONTROL, the store
## open, the source the bag 0x46), the whole stack (0x6815ff..0x68160f,
## FUN_008ba460, the slot's count). The original first asks, with
## UIIT_MSG_CANNOT_BUYBACK_ITEM_SELL, before selling an item the store will
## not buy back: CIFSlotWithHelp::vslot_029 looks the item up in the set
## UI_SILKMALL 0x67cf30 searches and, when it is there, asks through
## GInterface 0x788270 (MsgBoxSimple, 360x151, style 1 Yes / No, caption
## UIIT_STT_CONFIRM_BOX, the text UIIT_MSG_CANNOT_BUYBACK_ITEM_SELL formatted
## with the item's name; 0x6814ae..0x681597, READ round 728 review). The set
## is taken to be the server's never-booked one (ItemOpNet.never_booked, READ
## on the server, gs:0x6b2950); that the client's set 0x67b3d0 holds the same
## items is INFERRED (not compared).
func _ctrl_sell(slot: int, qty: int) -> void:
	_load_items()
	var item: ItemTableReader.Item = _items.get(_bag_item_id_at_slot(slot))
	if item != null and is_cash_item(item):
		var line := _builder.resolve_text(CANT_QUICKSELL_CASHITEM) if _builder != null else ""
		print("HudPanels: ctrl+click quick-sell refused, a cash item (bag slot %d)" % slot)
		system_notice.emit(line if line != "" and line != CANT_QUICKSELL_CASHITEM else "Item mall items cannot be quick-sold.")
		return
	if item != null and ItemOpNet.never_booked(item.type_ids, item.bionic != 0, item.code_name):
		_ask_cannot_buyback(slot, maxi(1, qty), item)
		return
	print("HudPanels: ctrl+click sells bag slot %d x%d with no box" % [slot, maxi(1, qty)])
	_do_sell(slot, maxi(1, qty))

## The question before quick-selling an item that cannot be bought back
## (see _ctrl_sell): Yes sells.
func _ask_cannot_buyback(slot: int, qty: int, item: ItemTableReader.Item) -> void:
	var old := get_node_or_null("BuybackWarning")
	if old != null:
		old.queue_free()
	var fmt := _ui_line("UIIT_MSG_CANNOT_BUYBACK_ITEM_SELL", "%s cannot be bought back once sold. Sell it?")
	var box := PartyMatchConfirm.new()
	if not box.build(_builder, fmt.replace("%s", item.display_name(_object_names))):
		box.queue_free()
		return
	box.name = "BuybackWarning"
	box.confirmed.connect(func() -> void:
		print("HudPanels: ctrl+click sells bag slot %d x%d after the buy-back warning" % [slot, qty])
		_do_sell(slot, qty))
	box.centre_on(get_viewport_rect().size)
	add_child(box)
	print("HudPanels: BuybackWarning opened for bag slot %d (item %d)" % [slot, item.id])

## The server's reason for a deposit short of its fee (session.StorageNotEnoughGold).
const STORAGE_NOT_ENOUGH_GOLD_REASON := "not enough gold"
const STRGERR_NOT_ENOUGH_GOLD := "UIIT_MSG_STRGERR_NOT_ENOUGH_GOLD"

## A textuisystem line by key, or `fallback` when the table lacks it.
func _ui_line(key: String, fallback: String) -> String:
	var line := _builder.resolve_text(key) if _builder != null else ""
	return line if line != "" and line != key else fallback

## The refusal CIFSlotWithHelp::vslot_029's bag branch shows (0xda4060, through
## 0x7781b0) before a Ctrl+click quick-sell of a cash item (READ, round 726
## review).
const CANT_QUICKSELL_CASHITEM := "UIIT_MSG_STRGERR_CANT_QUICKSELL_CASHITEM"

## The store's tax rate for the sell box (the tax line's short / 100.0, 0x6b0871
## -- READ); 0 until lane C brings the store's tax data (OPEN, npc_gui.md OPEN 1).
var shop_tax_rate := 0.0

## Whether Ctrl+click may not quick-sell `item`: 0x5dd660 on its type word --
## not bionic, TypeID1 3 (an item), the CashItem bit (itemdata columns 7, 8
## and 9; characterdata.md packs them into the u16 at +0x00). The original
## also refuses when its reference +0xa0 is 2 or 6 (0x8ba600), a field not
## mapped to an itemdata column (OPEN).
static func is_cash_item(item: ItemTableReader.Item) -> bool:
	return item.bionic == 0 and item.type_ids.size() >= 1 and item.type_ids[0] == 3 and item.cash_item != 0

## Whether an item stacks by the fills' type test, (b&2)==0 && (b&0x1c)==0xc
## && (b&0x60)==0x60: not bionic, TypeID1 3, TypeID2 3 (READ 0x6b0e90,
## 0x6b15b0, 0x6b07d0).
static func is_stack_item(item: ItemTableReader.Item) -> bool:
	return item != null and item.bionic == 0 and item.type_ids.size() >= 2 and item.type_ids[0] == 3 and item.type_ids[1] == 3

## Whether bag `slot` still holds `item_id`, at least `q` of it, when a box's
## OK is pressed (OURS, round 726 review: the boxes are not modal). Logs and
## refuses otherwise.
func _bag_slot_still_holds(slot: int, item_id: int, q: int, what: String) -> bool:
	for entry in _bag_slots:
		var index = _first_field(entry, ["slot", "slot_index", "index"])
		if index == null or int(index) != slot:
			continue
		var id = _first_field(entry, ["item_id", "id"])
		var n = _first_field(entry, COUNT_FIELDS)
		if id != null and int(id) == item_id and (n == null or int(n) >= q):
			return true
		break
	print("HudPanels: %s not sent -- bag slot %d no longer holds item %d x%d" % [what, slot, item_id, q])
	return false

## Sells on the retail 0x7034 type 9 (round 728 review, ItemOpNet): the
## result's book byte decides whether the sale enters the buy-back list.
func _do_sell(slot: int, quantity: int) -> void:
	if not NetClient.is_connected_to_server():
		_set_shop_status("Not connected.")
		return
	_pending_sells[slot] = {"item_id": _bag_item_id_at_slot(slot), "count": maxi(1, quantity)}
	NetClient.sell_item_retail(slot, maxi(1, quantity), npc_uid)

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

## The NPC whose store or warehouse is open: its unique id, which the retail
## sell, deposit and buy back carry (World3D sets it; 0 when unknown -- the
## server does not check it yet, r728.md OPEN).
var npc_uid := 0
## Sells in flight, by bag slot: {"item_id", "count"} -- the result names the
## slot and the count, the list needs the item.
var _pending_sells := {}

## A retail item operation's result (0xB034, ItemOpNet.decode_result).
func _on_item_op_result(r: Dictionary) -> void:
	if r.is_empty():
		return
	var who := NetClient.current_character_name
	if not bool(r.get("ok", false)):
		var code := int(r.get("code", 0))
		print("HudPanels: item operation refused, code 0x%x" % code)
		_item_error_notice(code)
		if who != "":
			NetClient.list_inventory(who)
		return
	match int(r.get("type", -1)):
		ItemOpNet.TYPE_BAG_TO_BAG:
			print("HudPanels: split %d from bag slot %d into %d" % [int(r.count), int(r.src), int(r.dst)])
			if who != "":
				NetClient.list_inventory(who)
		ItemOpNet.TYPE_SELL:
			var sold: Dictionary = _pending_sells.get(int(r.src), {})
			_pending_sells.erase(int(r.src))
			_buyback_book = ItemOpNet.book_sale(_buyback_book, int(sold.get("item_id", -1)), int(r.count), int(r.book))
			print("HudPanels: sold bag slot %d x%d, book byte 0x%x, buy-back list %s" % [int(r.src), int(r.count), int(r.book), _book_text()])
			_set_shop_status("Sold.")
			if who != "":
				NetClient.character_stats(who)
				NetClient.list_inventory(who)
			_fill_buyback_row()
		ItemOpNet.TYPE_BUYBACK:
			var index := int(r.index)
			if index >= 0 and index < _buyback_book.size():
				_buyback_book.remove_at(index)
			print("HudPanels: bought back entry %d x%d into bag slot %d, buy-back list %s" % [index, int(r.count), int(r.dst), _book_text()])
			if who != "":
				NetClient.character_stats(who)
				NetClient.list_inventory(who)
			_fill_buyback_row()
		ItemOpNet.TYPE_DEPOSIT:
			print("HudPanels: deposit accepted (bag slot %d -> warehouse slot %d)" % [int(r.src), int(r.dst)])
			_refresh_storage_and_bag()
			if who != "":
				NetClient.character_stats(who)

## A buy back's failure (0xB168).
func _on_buyback_failed(code: int) -> void:
	print("HudPanels: buy back refused, code 0x%x" % code)
	_item_error_notice(code)

## The line for a refusal code (ItemOpNet.ERROR_TEXT), to the system channel
## as the store's refusals go (OURS: where the original shows it).
func _item_error_notice(code: int) -> void:
	if ItemOpNet.ERROR_TEXT.has(code):
		var key: String = ItemOpNet.ERROR_TEXT[code]
		system_notice.emit(_ui_line(key, key))

func _book_text() -> String:
	var said := PackedStringArray()
	for e in _buyback_book:
		said.append("%d x%d" % [int(e.item_id), int(e.quantity)])
	return "[%s]" % ", ".join(said)

# --- Buy back (round 728) ----------------------------------------------------
## The store's buy-back row: the five GDR_STORE_ICON_SLOT_01..05 under
## "Buy back" (resinfo\ifstore.txt, #ifdef RESTORE_SOLDITEM_INSHOP; the
## user's 3Gw7Ene.png). READ (round 728 review): the list is the CLIENT's,
## built from the sell results (c:0x87f370 -> 0x78d900, ItemOpNet.book_sale)
## and never requested; it is drawn newest at the left (c:0x6d4360 walks it
## backwards), and an entry's index counts from the oldest. A slot (kind 0x45)
## is picked up and put down on the bag, which opens the purpose-0x14 box:
## CIFInventory::vslot_028 (0x6b5b80) -> the fill 0x6b0520, the inventory's
## one box (+0x390), priced "%I64d" of the reference's +0xb8 (the sell price)
## times the count, the count the slot's own -- fixed: 0x7168 carries no
## count and the server restores the stored item whole.
const BUYBACK_SLOT_FMT := "GDR_STORE_ICON_SLOT_%02d"
const BUYBACK_SLOTS := 5
## {"item_id", "quantity"}, oldest first.
var _buyback_book: Array = []

## Draws the list on the row's five slots, newest at the left.
func _fill_buyback_row() -> void:
	var window: HudWindow = _windows.get("store")
	if window == null:
		return
	_load_items()
	for i in range(BUYBACK_SLOTS):
		var slot := window.node(BUYBACK_SLOT_FMT % (i + 1)) as Control
		if slot == null:
			continue
		var icon := slot.get_node_or_null("ItemIcon") as TextureRect
		var count := slot.get_node_or_null("CountLabel") as Label
		if icon == null:
			continue
		if not icon.has_meta("buyback_click_wired"):
			icon.set_meta("buyback_click_wired", true)
			icon.gui_input.connect(func(ev: InputEvent) -> void: _on_buyback_cell_input(ev, icon))
		var index := _buyback_book.size() - 1 - i
		if index < 0:
			icon.texture = null
			_set_item_tip(icon, -1)
			_set_item_seal_edge(icon, -1)
			icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
			if icon.has_meta("buyback_index"):
				icon.remove_meta("buyback_index")
			if count != null:
				count.text = ""
				count.queue_redraw()
			continue
		var e: Dictionary = _buyback_book[index]
		icon.texture = _item_icon(int(e.item_id))
		_set_item_tip(icon, int(e.item_id), "buyback", index)
		_set_item_seal_edge(icon, int(e.item_id))
		icon.mouse_filter = Control.MOUSE_FILTER_STOP
		icon.set_meta("buyback_index", index)
		if count != null:
			# The row's kind 0x45 is under the bag's expendable test
			# (c:0x680da0, READ).
			count.text = str(int(e.quantity)) if _shows_count(int(e.item_id), int(e.quantity)) else ""
			count.queue_redraw()

func _on_buyback_cell_input(event: InputEvent, icon: TextureRect) -> void:
	if _is_pick_click_on(event, icon) and icon.has_meta("buyback_index"):
		var index := int(icon.get_meta("buyback_index"))
		if index >= _buyback_book.size():
			return
		var e: Dictionary = _buyback_book[index]
		pick_up_icon({"kind": "buyback", "index": index, "item_id": int(e.item_id), "qty": int(e.quantity), "icon": icon.texture},
			icon.texture, icon, (event as InputEventMouseButton).global_position)

## The buy-back box (purpose 0x14), for list entry `index`.
func _confirm_buyback(index: int, item_id: int) -> void:
	if index < 0 or index >= _buyback_book.size() or int(_buyback_book[index].item_id) != item_id:
		return
	_load_items()
	var item: ItemTableReader.Item = _items.get(item_id)
	var n: int = maxi(1, int(_buyback_book[index].quantity))
	_open_store_box("store", "BuybackConfirm", StoreMessageBox.Kind.BUY_BACK, {
		"icon": _item_icon(item_id), "name": item.display_name(_object_names) if item != null else "",
		"count": n, "min": n, "max": n, "unit_price": item.sell_price if item != null else 0,
	}, func(_q: int) -> void:
		_do_buyback(index, item_id))

func _do_buyback(index: int, item_id: int) -> void:
	if not NetClient.is_connected_to_server():
		_set_shop_status("Not connected.")
		return
	# OURS (the box is not modal): the list may have changed under it.
	if index >= _buyback_book.size() or int(_buyback_book[index].item_id) != item_id:
		print("HudPanels: buy back not sent -- entry %d no longer holds item %d" % [index, item_id])
		return
	print("HudPanels: buy back entry %d (item %d)" % [index, item_id])
	NetClient.buyback_retail(npc_uid, index)

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

## QA only (round 783): selects the open store's tab `index`; says which
## tab and how many goods it shows.
func qa_select_shop_tab(index: int) -> String:
	if not _windows.has("store") or index < 0 or index >= _shop_tabs.size():
		return "no such tab (%d tab(s))" % _shop_tabs.size()
	_select_shop_tab(index)
	var tab: ShopReader.Tab = _shop_tabs[index]
	var label := _builder.resolve_text(tab.name_strid) if _builder != null else tab.name_strid
	return "tab %d '%s', %d good(s): %s" % [index, label, tab.item_codes.size(), ", ".join(tab.item_codes)]

## QA only (round 783): buys one of the current tab's cell `cell` (the
## lattice's order), the send a confirmed buy box makes; says what and at
## what listed price.
func qa_buy_shop_cell(cell: int) -> String:
	if not _windows.has("store") or _shop_selected < 0 or _shop_selected >= _shop_tabs.size():
		return "no store open"
	var codes: PackedStringArray = (_shop_tabs[_shop_selected] as ShopReader.Tab).item_codes
	if cell < 0 or cell >= codes.size():
		return "no good in cell %d" % cell
	_load_items()
	var item: ItemTableReader.Item = _items_by_code.get(codes[cell])
	if item == null:
		return "cell %d: %s not in the item table" % [cell, codes[cell]]
	_do_buy(item.id, 1)
	return "item %d %s '%s' at listed price %d" % [item.id, item.code_name, item.display_name(_object_names),
		int(_shop_prices.get(item.id, -1))]

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
	# Round 725: the registry entry's own caption, UIIT_STT_STORAGEROOM
	# "Storage" (READ, ginterface.txt; MEASURED "Storage" in the original's
	# MKtR5Kd.png) -- not the keeper's name, which this used to set.
	print("HudPanels: storage opened at %s" % npc_name)
	_close_window_boxes(window)
	_wire_storage_money_button(window)
	_wire_storage_page_spinner(window)
	_lattice_takes_clicks(window, "GDR_STORAGE_SLOT_")
	window.show()
	window.move_to_front()
	# 0x79dbd0 with the storage (registry 0x13): the helper on it (0x79dd8f).
	UiSounds.window_toggled(window.visible, _interface_shown(), "storage opened (0x79dbd0)")
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

## Wires the warehouse's gold buttons, once (round 726, message_box.md):
## the warehouse's own (GDR_STORAGE_BTN_MONEY) takes gold out -- withdraw,
## MsgBoxStoreMoney purpose 4 (0x6b29f0); the bag's (GDR_INVENTORY_BTN_MONEY)
## puts gold in while the warehouse is open -- deposit, purpose 3
## (0x6b2800, from the bag's 0x6b2e74). The bag's button with no warehouse
## open is the original's drop-gold box (purpose 9), not built here.
func _wire_storage_money_button(window: HudWindow) -> void:
	var btn := window.node("GDR_STORAGE_BTN_MONEY") as BaseButton
	if btn != null and not btn.pressed.is_connected(_open_gold_withdraw):
		btn.pressed.connect(_open_gold_withdraw)
	var inventory: HudWindow = _windows.get("inventory")
	if inventory != null:
		var bag_btn := inventory.node("GDR_INVENTORY_BTN_MONEY") as BaseButton
		if bag_btn != null and not bag_btn.pressed.is_connected(_on_bag_money_button):
			bag_btn.pressed.connect(_on_bag_money_button)

func _on_bag_money_button() -> void:
	if _window_shown("storage"):
		_open_gold_deposit()

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
			_set_item_tip(icon0, -1)
			_set_item_seal_edge(icon0, -1)
			icon0.mouse_filter = Control.MOUSE_FILTER_IGNORE
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
		_set_item_tip(icon, entry.item_id, "storage", index)
		_set_item_seal_edge(icon, entry.item_id)
		icon.mouse_filter = Control.MOUSE_FILTER_STOP
		icon.set_meta("wh_slot", index)
		icon.set_meta("wh_item_id", entry.item_id)
		icon.set_meta("wh_qty", entry.quantity)
		if not icon.has_meta("wh_click_wired"):
			icon.set_meta("wh_click_wired", true)
			icon.gui_input.connect(func(ev: InputEvent) -> void: _on_storage_cell_input(ev, icon))
		var count_label := cell.get_node_or_null("CountLabel") as Label
		if count_label != null and _shows_count(int(entry.item_id), int(entry.quantity)):
			count_label.text = str(entry.quantity)

## A click on a warehouse item picks it up onto the cursor; putting it down
## on the bag opens the withdraw dialog (HeldIcon, round 652).
func _on_storage_cell_input(event: InputEvent, icon: TextureRect) -> void:
	if _is_pick_click_on(event, icon) and icon.has_meta("wh_slot") and icon.has_meta("wh_item_id"):
		pick_up_icon({"kind": "storage", "slot": int(icon.get_meta("wh_slot")), "item_id": int(icon.get_meta("wh_item_id")),
			"qty": int(icon.get_meta("wh_qty")), "icon": icon.texture},
			icon.texture, icon, (event as InputEventMouseButton).global_position)

## The deposit box: CIFMessageBox mode 6, purpose 5 (round 726), opened when
## a bag item is put down on the warehouse (CIFStorageRoom::vslot_028
## 0x6cd350 -> 0x6b0e90). Its spin buttons are hidden by the purpose and its
## count edit restyled 0x81 and left unfocused (READ; whether the count can be
## changed is not settled); a stack starts at its size (INFERRED, as the sell
## box's); an item that does not stack hides the whole quantity group (READ).
## The price field is the fee: the item reference's +0xcc times the count,
## floored at 1 (0x6b0fe8..0x6b101c, 0x63d676; READ). The fee is itemdata's
## KeepingFee, column 30 (READ on the server, ref +0xac; round 728 review).
## The server charges KeepingFee x the WHOLE stack clamped to 1..10,000,000
## (gs:0x524160 / 0x524300), so above the cap this box shows more than is
## charged, as the original's does.
func _confirm_deposit(bag_slot: int, item_id: int, held: int) -> void:
	_load_items()
	var item: ItemTableReader.Item = _items.get(item_id)
	var n := maxi(1, held)
	_open_store_box("storage", "DepositConfirm", StoreMessageBox.Kind.DEPOSIT, {
		"icon": _item_icon(item_id), "name": item.display_name(_object_names) if item != null else "",
		"count": n, "max": n, "unit_price": item.keeping_fee if item != null else 0,
		"stackable": is_stack_item(item),
	}, func(q: int) -> void:
		if _bag_slot_still_holds(bag_slot, item_id, q, "deposit"):
			_do_deposit(bag_slot, q))

## The withdraw box: mode 6, purpose 6 (round 726), opened when a warehouse
## item is put down on the bag (0x6b15b0). The purpose hides the spin
## buttons, the "Price" label and the item's name (READ, 0x63ee85..0x63ee9f)
## and restyles the count 0x81; an item that does not stack hides the whole
## quantity group (READ); the price field is "%d" of 0 (0x6b1636..0x6b1641).
func _confirm_withdraw(warehouse_slot: int, item_id: int, held: int) -> void:
	_load_items()
	var item: ItemTableReader.Item = _items.get(item_id)
	var n := maxi(1, held)
	_open_store_box("storage", "WithdrawConfirm", StoreMessageBox.Kind.WITHDRAW, {
		"icon": _item_icon(item_id), "name": item.display_name(_object_names) if item != null else "",
		"count": n, "max": n, "fixed_price": 0, "stackable": is_stack_item(item),
	}, func(q: int) -> void:
		if _storage_slot_still_holds(warehouse_slot, item_id, q):
			_do_withdraw(warehouse_slot, q))

## As _bag_slot_still_holds, for a warehouse slot (the last storage list).
func _storage_slot_still_holds(slot: int, item_id: int, q: int) -> bool:
	for entry in _storage_slots_cache:
		if int(entry.slot_index) == slot:
			if int(entry.item_id) == item_id and int(entry.quantity) >= q:
				return true
			break
	print("HudPanels: withdraw not sent -- warehouse slot %d no longer holds item %d x%d" % [slot, item_id, q])
	return false

## The retail deposit (0x7034 type 2, round 728 review): the whole stack --
## the request carries no count (c:0x7950b0 0x46 -> 0x13 sets none, READ) --
## into the warehouse's first empty slot (OURS: the original names the slot
## the item was put down on).
func _do_deposit(bag_slot: int, _quantity: int) -> void:
	if not NetClient.is_connected_to_server():
		return
	var taken := {}
	for entry in _storage_slots_cache:
		taken[int(entry.slot_index)] = true
	var dst := -1
	for i in range(maxi(_storage_capacity, 1)):
		if not taken.has(i):
			dst = i
			break
	if dst < 0:
		print("HudPanels: deposit not sent -- the warehouse has no empty slot")
		return
	NetClient.deposit_retail(bag_slot, dst, npc_uid)

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
		# Round 728: the deposit fee left the purse.
		if NetClient.current_character_name != "":
			NetClient.character_stats(NetClient.current_character_name)
	else:
		push_warning("HudPanels: deposit refused: %s" % reason)
		# Round 728: short of the fee. The server's storage handlers refuse it
		# with UIIT_MSG_STRGERR_NOT_ENOUGH_GOLD (0x180f; SR_GameServer 0x524160,
		# error_attributed_functions.md); the line goes to the system channel
		# as the store's refusals do (OURS: where the original shows it).
		if reason == STORAGE_NOT_ENOUGH_GOLD_REASON:
			system_notice.emit(_ui_line(STRGERR_NOT_ENOUGH_GOLD, "Not enough gold."))

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
## and the bag window (carried gold).
func _update_storage_gold_labels() -> void:
	var window: HudWindow = _windows.get("storage")
	if window != null:
		# The amount goes on GDR_STORAGE_STA_MONEY (id 10, its ClientRect
		# "95,7,44,6" right-aligning it at x 104..192); GDR_STORAGE_STA_GOLD
		# keeps its authored "Gold" (UIIT_STT_GOLD) after it. It used to be
		# written over the "Gold" (round 630 review).
		_set_money_text(window, "GDR_STORAGE_STA_MONEY", _storage_stored)
	# Keep the bag's gold line and cached stats in step with the purse.
	if _stats != null:
		_stats.gold = _storage_carried
	var inventory: HudWindow = _windows.get("inventory")
	if inventory != null:
		_set_money_text(inventory, "GDR_INVENTORY_STA_MONEY", _storage_carried)

## Writes a purse amount where the client does. READ: the amount is its own
## static -- ifinventory's GDR_INVENTORY_STA_MONEY (0,305 176x28 over
## int_window_downbox, ClientRect "36,7,39,5", HAlign 2, so right-aligned
## ending at x 137), ifstorageroom's GDR_STORAGE_STA_MONEY -- and the
## 24-pixel GDR_*_STA_GOLD beside it carries the word "Gold". The amount
## was written into the "Gold" label, whose 24 pixels a large purse
## overran (round 630 review). UiBuilder.set_static_text puts the text in
## the static's ClientRect by the client's layout.
func _set_purse_text(window: HudWindow, control_name: String, text: String) -> Label:
	if window == null or _builder == null:
		return null
	return _builder.set_static_text(window.node(control_name) as Control, text)

## A gold amount on its money static, grouped by thousands and in the colour
## the client gives that amount (GoldColor: 0x5d3df0, applied with 0x8b2b70 by
## the bag's 0x6b03a0, the warehouse's 0x6cc470 and the exchange's 0x7b2350 /
## 0x7b23a0 -- the number's static only, never the "Gold" caption).
func _set_money_text(window: HudWindow, control_name: String, amount: int) -> Label:
	var label := _set_purse_text(window, control_name, _grouped(amount))
	if label != null:
		label.add_theme_color_override("font_color", GoldColor.of(amount))
	return label

## The exchange window's two offered amounts (GDR_EXCHANGE_STATIC_MYMONEY,
## ID 19, and _OTHERMONEY, ID 18), in the gold colours. READ: CIFExchange's
## Create and its clear path set both to 0 (0x7b2941 / 0x7b294c, 0x7b370f /
## 0x7b3718), so a new exchange starts at 0 in white; an offer update sets
## the one that changed (the net handlers 0x87caac, 0x880674). A negative
## amount leaves that box as it is.
func set_exchange_money(mine: int, other: int) -> void:
	var window: HudWindow = _windows.get("exchange")
	if window == null:
		return
	if mine >= 0:
		_set_money_text(window, "GDR_EXCHANGE_STATIC_MYMONEY", mine)
	if other >= 0:
		_set_money_text(window, "GDR_EXCHANGE_STATIC_OTHERMONEY", other)

# --- The exchange (round 834; ExchangeController, docs/protocol/exchange.md) -----

## A banner on GDR_WARNING_WND (0x77b580), then the same text as a system
## line of `line_type` (World3D's _show_banner / _log_system).
signal exchange_banner(text: String)
signal exchange_system_line(text: String, line_type: int)

var exchange: ExchangeController

func _exchange() -> ExchangeController:
	if exchange == null:
		exchange = ExchangeController.new(self)
	return exchange

## GI+0x508.
func exchange_mode() -> bool:
	return exchange != null and exchange.active

func open_exchange(partner: Dictionary, own: Dictionary) -> void:
	if not exchange_mode():
		_exchange_layout_check()
	_exchange().open(partner, own)

func exchange_closed(code: int) -> void:
	if exchange != null:
		exchange.closed(code)
	else:
		exchange_code_message(code)

## The window shown (built at its first use), the main popup on its
## inventory tab beside it (c:0x7b2530(1), 0x79df10(1): 0x6a1f70(0x46)).
func open_exchange_window() -> void:
	var window := open(ExchangeController.WINDOW)
	if window == null:
		return
	_wire_exchange(window)
	open("inventory")
	window.move_to_front()

func close_exchange_window() -> void:
	var window: HudWindow = _windows.get(ExchangeController.WINDOW)
	if window != null:
		window.hide()
	if _exchange_rebuild_pending:
		_drop_exchange_window()

func _wire_exchange(window: HudWindow) -> void:
	if window.has_meta("exchange_wired"):
		return
	window.set_meta("exchange_wired", true)
	window.close_hides = false
	window.closed.connect(func() -> void: _exchange().press_cancel())
	var wiring := {"GDR_EXCHANGE_BUTTON_EXCHANGE": func() -> void: _exchange().press_button(),
		"GDR_EXCHANGE_BUTTON_CANCEL": func() -> void: _exchange().press_cancel(),
		"GDR_EXCHANGE_BUTTON_MONEYBTN": func() -> void: _exchange().press_gold()}
	for n in wiring:
		var b := window.node(n) as BaseButton
		if b != null:
			b.pressed.connect(wiring[n])
	# The grids' cells take the clicks (as the warehouse's, _lattice_takes_clicks).
	_lattice_takes_clicks(window, ExchangeController.MY_PREFIX)
	_lattice_takes_clicks(window, ExchangeController.OTHER_PREFIX)
	for own_side in [true, false]:
		var grid := window.node("GDR_EXCHANGE_LAT_MY" if own_side else "GDR_EXCHANGE_LAT_OTHER") as Control
		if grid == null:
			continue
		var tint_tex: Texture2D = _builder.load_texture(ExchangeController.BLUE) if _builder != null else null
		for i in grid.get_child_count():
			var cell := grid.get_child(i) as Control
			var tint := TextureRect.new()
			tint.name = "ExchangeTint"
			tint.texture = tint_tex
			tint.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			tint.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tint.mouse_filter = Control.MOUSE_FILTER_IGNORE
			tint.visible = false
			cell.add_child(tint)
			var bg := cell.get_node_or_null("SlotBg")
			cell.move_child(tint, bg.get_index() + 1 if bg != null else 0)
			var icon := cell.get_node_or_null("ItemIcon") as TextureRect
			if icon != null and own_side:
				var index: int = i
				icon.gui_input.connect(func(ev: InputEvent) -> void: _on_exchange_cell_input(ev, icon, index))
	if bool(window.get_meta(EXCHANGE_FULL_META, false)):
		_install_exchange_extras(window)

## A grid's 12 cells drawn from the side's items, blue when that side's
## confirm was accepted (CIFSlotWithHelp +0x595 -> +0x61c, c:0x67cfcc).
func exchange_draw_grid(own_side: bool, items: Dictionary, blue: bool) -> void:
	var window: HudWindow = _windows.get(ExchangeController.WINDOW)
	var grid := window.node("GDR_EXCHANGE_LAT_MY" if own_side else "GDR_EXCHANGE_LAT_OTHER") as Control if window != null else null
	if grid == null:
		return
	_load_items()
	var where := "exchange_my" if own_side else "exchange_other"
	for i in grid.get_child_count():
		var cell := grid.get_child(i) as Control
		var tint := cell.get_node_or_null("ExchangeTint") as Control
		if tint != null:
			tint.visible = blue
		var icon := cell.get_node_or_null("ItemIcon") as TextureRect
		var count := cell.get_node_or_null("CountLabel") as Label
		if icon == null:
			continue
		var o = items.get(i)
		if o == null:
			icon.texture = null
			_set_item_tip(icon, -1)
			_set_item_seal_edge(icon, -1)
			icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
			if count != null:
				count.text = ""
			continue
		var it: ItemInstance = (o as ExchangeNet.Offered).item
		icon.texture = _item_icon(it.ref_item_id)
		_set_item_tip(icon, it.ref_item_id, where, i)
		_set_item_seal_edge(icon, it.ref_item_id)
		icon.mouse_filter = Control.MOUSE_FILTER_STOP
		if count != null:
			count.text = str(it.count) if not it.is_equipment and _shows_count(it.ref_item_id, it.count) else ""

## An own cell: picked up (until this side confirms) to be put back on the
## bag, or Alt+clicked out while neither side confirmed (c:0x681de8).
func _on_exchange_cell_input(event: InputEvent, icon: TextureRect, index: int) -> void:
	if exchange == null or not exchange.active:
		return
	if _is_alt_click_on(event, icon) and (held_icon == null or not held_icon.is_holding()):
		exchange.remove_index(index, true)
		return
	if _is_pick_click_on(event, icon) and not exchange.mine_confirmed and exchange.my_items.has(index):
		var it: ItemInstance = (exchange.my_items[index] as ExchangeNet.Offered).item
		pick_up_icon({"kind": "exchange", "index": index, "item_id": it.ref_item_id, "icon": icon.texture},
			icon.texture, icon, (event as InputEventMouseButton).global_position)

func exchange_header(own_side: bool, text: String) -> void:
	var window: HudWindow = _windows.get(ExchangeController.WINDOW)
	if window == null:
		return
	if _builder != null:
		_builder.set_subframe_text(window.node("GDR_EXCHANGE_MY_SUBFRAME" if own_side else "GDR_EXCHANGE_OTHER_SUBFRAME") as Control, text)

## The button's caption and state (0x7b2700 / 0x7b2670 / 0x7b22f0).
func exchange_button(key: String, enabled: bool) -> void:
	var window: HudWindow = _windows.get(ExchangeController.WINDOW)
	var b := window.node("GDR_EXCHANGE_BUTTON_EXCHANGE") as BaseButton if window != null else null
	if b == null:
		return
	if _builder != null:
		_builder.set_button_text(b, _resolve_ui(key, key))
	b.disabled = not enabled

## The button's state alone (0x655ec0), its caption kept.
func exchange_button_enabled(enabled: bool) -> void:
	var window: HudWindow = _windows.get(ExchangeController.WINDOW)
	var b := window.node("GDR_EXCHANGE_BUTTON_EXCHANGE") as BaseButton if window != null else null
	if b != null:
		b.disabled = not enabled

# --- The item mall (round 837; ItemMallController, docs/protocol/item_mall.md) ---

var item_mall: ItemMallController
## World3D's: a fresh MallPreview for the window (null: no preview).
var mall_preview_factory: Callable = Callable()
## The player's level, set by World3D with the player block's.
var player_level := 0

func _mall() -> ItemMallController:
	if item_mall == null:
		item_mall = ItemMallController.new(self)
	return item_mall

func open_item_mall() -> HudWindow:
	return _mall().open()

## F10 (0x7807aa): the "Enter Item Mall" warning box (kind 0x1e); its OK
## opens the mall. With no 0x7121 stock rows -- this client keeps no stock
## table, as the archive's is empty -- OK opens it at once (0x798771).
func open_item_mall_entry() -> void:
	if item_mall_open():
		return
	if MallEnterBox.open(_builder, self, func() -> void: open_item_mall()) == null and not item_mall_open():
		# A box already up refuses a second (0x6ec400(0x1e)).
		return


## The cell's Buy: the confirm box (ID 1200).
func open_mall_confirm_box(good: MallData.Good) -> MallConfirmBuy:
	return MallConfirmBuy.open(self, _mall(), good)

## Buy (worn) / Reserved's Buy All: the lump box (ID 122 / 306).
func open_mall_lump_box(goods: Array, reserved: bool) -> MallMessageBox:
	return MallMessageBox.open_lump(self, _mall(), goods, reserved)

## Pre-select / Delete: the reserve box (ID 1202 / 1203).
func open_mall_reserve_box(good: MallData.Good, add: bool) -> MallMessageBox:
	return MallMessageBox.open_reserve(self, _mall(), good, add)

func item_mall_open() -> bool:
	return item_mall != null and item_mall.active

## The window is built afresh at each open (0x79b580 loads and unloads its
## ginterface section), so it is dropped on close.
func drop_item_mall_window() -> void:
	var w: HudWindow = _windows.get(ItemMallController.WINDOW)
	if w == null:
		return
	_windows.erase(ItemMallController.WINDOW)
	remove_child(w)
	w.queue_free()

func make_mall_preview():
	return mall_preview_factory.call() if mall_preview_factory.is_valid() else null

func mall_player_name() -> String:
	return NetClient.current_character_name if NetClient != null else ""

func mall_player_level() -> int:
	return player_level

## A package's NameStrID through the object text tables.
func mall_text(strid: String) -> String:
	_load_items()
	if strid == "":
		return ""
	var t := _object_names.get_text(strid) if _object_names != null else ""
	if t == "" or t == strid:
		t = _resolve_ui(strid, strid)
	return t

func mall_item_id(code: String) -> int:
	_load_items()
	var item: ItemTableReader.Item = _items_by_code.get(code)
	return item.id if item != null else 0

## The 16-bit packed TID (the masks 0x1c, 0x60, 0x780, 0xf800 the try list
## and the buy list compare, c:0x7d891a / 0x7d87bc): CashItem bit 0, Bionic
## bit 1, TypeID1..4 above.
func mall_item_tid(item_id: int) -> int:
	_load_items()
	var item: ItemTableReader.Item = _items.get(item_id)
	if item == null or item.type_ids.size() < 4:
		return 0
	return (item.cash_item & 1) | ((item.bionic & 1) << 1) | ((item.type_ids[0] & 7) << 2) \
		| ((item.type_ids[1] & 3) << 5) | ((item.type_ids[2] & 0xf) << 7) | ((item.type_ids[3] & 0x1f) << 11)

## Free bag slots (the confirm box's check and the chest's Inventory
## Remaining).
func mall_free_bag_slots() -> int:
	return free_bag_slots()

# --- Round 837: the Buying list and the item chest (OURS) ---
var silk_history: SilkHistoryWindow = null
var item_chest: ItemChestWindow = null
var item_chest_icon: ItemChestIcon = null

## The mall's Buying list button (131 -> 0x7d7130). The mall itself refuses it
## while a mall box is up (+0x7c8) or purchases are outstanding (+0x7dc).
func open_silk_history() -> SilkHistoryWindow:
	if silk_history == null or not is_instance_valid(silk_history):
		silk_history = SilkHistoryWindow.new(_builder)
		silk_history.name = "Window_silk_history"
	return silk_history if silk_history.open(self) else null

## The mall is modal while this is true (+0x7c8).
func silk_history_open() -> bool:
	return silk_history != null and is_instance_valid(silk_history) and silk_history.is_open()

## The mall's own close (CIFNewItemMall::vslot_043 0x7d7020): 0x711a {1,
## 0xff} if an inquiry is pending; the list goes with the mall.
func close_silk_history() -> void:
	if silk_history != null and is_instance_valid(silk_history):
		silk_history.mall_closing()
		silk_history.close()

func _build_item_chest() -> void:
	if _builder == null or item_chest != null:
		return
	item_chest = ItemChestWindow.new(_builder)
	item_chest.free_slots = free_bag_slots
	item_chest.item_name = item_name
	item_chest.message.connect(func(t: String) -> void: system_notice.emit(t))
	item_chest.attach_net()
	item_chest_icon = ItemChestIcon.new(_builder)
	add_child(item_chest_icon)
	item_chest_icon.bind(item_chest, self)
	# Placed from the screen's size, not anchored: HudPanels itself can be
	# zero-sized under its layer, which put an anchored icon off screen.
	_place_chest_icon()
	if is_inside_tree():
		get_viewport().size_changed.connect(_place_chest_icon)

func _place_chest_icon() -> void:
	if item_chest_icon == null or not is_inside_tree():
		return
	item_chest_icon.set_anchors_preset(Control.PRESET_TOP_LEFT)
	item_chest_icon.size = ItemChestIcon.ICON_SIZE
	item_chest_icon.position = ItemChestIcon.slot_position(get_viewport_rect().size) - get_global_transform().origin

## Free bag slots, read the way first_empty_bag_slot reads the bag.
func free_bag_slots() -> int:
	var taken := {}
	for entry in _bag_slots:
		var index = _first_field(entry, ["slot", "slot_index", "index"])
		if index != null:
			taken[int(index)] = true
	return maxi(_bag_size_shown() - taken.size(), 0)

func mall_system_line(text: String) -> void:
	exchange_system_line.emit(text, HudSystemMessage.TYPE_GAME)

## A refusal's code (0x778190): the category-1 table's text, as the
## exchange's; codes with no text show nothing (item_mall_wire_verify).
func mall_code_message(code: int) -> void:
	exchange_code_message(code)

## A purchase's 0xB034 {1}: the bag re-read (OURS, as the exchange's: retail
## builds the items from its own tables) -- or, n = 0, it went to the chest.
func mall_after_buy(r: Dictionary) -> void:
	refresh_bag_after_exchange()

## 0x3154 (c:0x882e50): one system line by reason, the offset printed in.
func _on_mall_silk_changed(c: Dictionary) -> void:
	if c.is_empty():
		return
	var reason := int(c.get("reason", -1))
	var key: String = "UIIT_MSG_STRGERR_TRADE_FAILURE" if reason == 0xff else \
		(MallNet.SILK_REASON_KEYS[reason] if reason >= 0 and reason < MallNet.SILK_REASON_KEYS.size() else "")
	if key == "":
		return
	var text := _resolve_ui(key, "")
	if text == "":
		return
	if text.contains("%d"):
		text = text.replace("%d", str(int(c.get("offset", 0))))
	mall_system_line(text)

# --- The exchange's portraits and log (round 836, OURS layout) -------------------
#
# Retail's CIFExchange has both players' portraits (live renders aimed at the
# "Bip01 Head" bone, c:0x7b2a20), a red warning effect behind a stranger's
# (control 155, c:0x7b399f), a hover tooltip with the warning (156) and a
# message log (304) -- and its own layout parks all of them at x 9999, so
# retail shows none (exchange.md 4.3). The user's private-server screenshots
# show them on a 365 x 500 window. The rects below are MEASURED from those
# screenshots (each exactly 2x: window origin found by matching the
# window's corner, then every control by matching our own render of it; the
# portraits, lines and log by their edges); the y positions and sizes all
# equal ifexchange.txt's own, only the x positions, the subframes' width, the
# window's size and the buttons' row are the private layout's. The content
# is retail's: the controls, art, colours and messages are READ. Settings >
# Extra Settings turns it off (ClientSettings.KEY_EXCHANGE_PORTRAITS).

const EXCHANGE_FULL_META := &"exchange_full"
const EXCHANGE_FULL_SIZE := Vector2i(365, 500)
const EXCHANGE_FULL_RECTS := {
	"GDR_EXCHANGE_OTHER_SUBFRAME": Rect2i(9, 38, 346, 141),
	"GDR_EXCHANGE_MY_SUBFRAME": Rect2i(9, 182, 346, 141),
	"GDR_EXCHANGE_USER_LINE": Rect2i(238, 61, 8, 116),
	"GDR_EXCHANGE_PLAYER_LINE": Rect2i(238, 205, 8, 116),
	"GDR_EXCHANGE_USER_NORMAL": Rect2i(247, 70, 100, 104),
	"GDR_EXCHANGE_USER_VISUAL": Rect2i(247, 70, 100, 104),
	"GDR_EXCHANGE_USER_VISUAL_EFFECT": Rect2i(247, 70, 128, 128),
	"GDR_EXCHANGE_USER_VISUAL_TOOLTIP": Rect2i(247, 70, 100, 104),
	"GDR_EXCHANGE_PLAYER_NORMAL": Rect2i(247, 214, 100, 104),
	"GDR_EXCHANGE_PLAYER_VISUAL": Rect2i(247, 214, 100, 104),
	"GDR_EXCHANGE_TEXT_BOX_FRAME": Rect2i(10, 339, 345, 95),
	"GDR_EXCHANGE_TEXT_BOX_FRAME_BG": Rect2i(14, 342, 337, 87),
	"GDR_EXCHANGE_TEXT_BOX": Rect2i(14, 342, 337, 87),
	# The log's two background strips (com_bg_tile_a) fill the window's body
	# above and below it, where the frame has no centre: their y and size
	# are the file's; x centres them as the log frame is (INFERRED, the tile
	# is too like the frame's to measure an edge in the screenshots).
	"GDR_EXCHANGE_TEXT_BOX_BG_1": Rect2i(28, 315, 310, 29),
	"GDR_EXCHANGE_TEXT_BOX_BG_2": Rect2i(28, 426, 310, 32),
	"GDR_EXCHANGE_BUTTON_EXCHANGE": Rect2i(96, 450, 76, 24),
	"GDR_EXCHANGE_BUTTON_CANCEL": Rect2i(194, 450, 76, 24),
}
## The portrait is drawn into its control inset by 2, 2 at the top left and
## 4, 4 off the size (READ, exchange.md 4.3: c:0x7b21b0).
const EXCHANGE_PORTRAIT_INSET := Rect2i(2, 2, 4, 4)
## ch_red.ddj (MEASURED from Media.pk2): 512 x 512, a 4 x 4 sheet of 128 x
## 128 cells, 9 frames used, each red only in the cell's top-left 100 x 104
## (the portrait's rect); frames 0 and 1 are empty, then the alpha runs 51,
## 85, 119, 153, 119, 85, 51 -- a pulse. The layout gives it Style 512,
## Speed 100, loop (READ, ifexchange.txt): 100 ms a frame.
const EXCHANGE_RED_CELL := 128
const EXCHANGE_RED_COLUMNS := 4
const EXCHANGE_RED_FRAMES := 9
const EXCHANGE_RED_FRAME_MS := 100
## The log's lines (READ: 0x638c20(0xe), the pitch 14) and how many it keeps
## (OURS: the chat's 100).
const EXCHANGE_LOG_PITCH := 14
## The tooltip's wrap width (OURS).
const EXCHANGE_TIP_WRAP := 220.0

var _exchange_rebuild_pending := false
var _exchange_log: HudChat.ChatList
var _exchange_red: TextureRect
var _exchange_red_frames: Array[Texture2D] = []
var _exchange_red_ms := 0.0
## [opponent, own] PlayerPortrait SubViewports and the rects that show them.
var _exchange_portraits: Array = [null, null]
var _exchange_portrait_views: Array = [null, null]

## Whether the exchange window is built with its portraits and log: the
## option on and the window fitting the UI's canvas (the screen in UI units:
## at a high UI scale on a small screen the 500-pixel window would run off
## it, and the compact one is built instead).
func exchange_full_layout() -> bool:
	return ClientSettings.exchange_portraits_shown() and exchange_full_fits()

## The canvas size the fit is judged on; zero reads the viewport's (a
## headless test's viewport is 64 x 64, so tests set it).
var exchange_canvas := Vector2.ZERO

## The canvas has room for the full window (OURS: its size plus 8 a side).
func exchange_full_fits() -> bool:
	var canvas := exchange_canvas
	if canvas == Vector2.ZERO:
		canvas = get_viewport_rect().size if is_inside_tree() else Vector2(1280, 720)
	return canvas.x >= EXCHANGE_FULL_SIZE.x + 16 and canvas.y >= EXCHANGE_FULL_SIZE.y + 16

## Before a window is shown for a new exchange: built again when the layout
## it was built with is no longer the one to use (the option changed, or
## the screen or UI scale did).
func _exchange_layout_check() -> void:
	var w: HudWindow = _windows.get(ExchangeController.WINDOW)
	if w != null and bool(w.get_meta(EXCHANGE_FULL_META, false)) != exchange_full_layout():
		_drop_exchange_window()

## The window's layout as built.
func exchange_window_full() -> bool:
	var w: HudWindow = _windows.get(ExchangeController.WINDOW)
	return w != null and bool(w.get_meta(EXCHANGE_FULL_META, false))

## The Extra Settings row changed: the window is built again the next time
## it opens -- now, or when the exchange in progress ends.
func _on_exchange_layout_option(values: Dictionary) -> void:
	if not values.has("exchange_portraits"):
		return
	var w: HudWindow = _windows.get(ExchangeController.WINDOW)
	if w == null or bool(w.get_meta(EXCHANGE_FULL_META, false)) == exchange_full_layout():
		return
	if exchange_mode():
		_exchange_rebuild_pending = true
	else:
		_drop_exchange_window()

func _drop_exchange_window() -> void:
	_exchange_rebuild_pending = false
	var w: HudWindow = _windows.get(ExchangeController.WINDOW)
	if w == null:
		return
	_windows.erase(ExchangeController.WINDOW)
	_exchange_log = null
	_exchange_red = null
	for i in 2:
		if _exchange_portraits[i] != null and is_instance_valid(_exchange_portraits[i]):
			(_exchange_portraits[i] as Node).queue_free()
		_exchange_portraits[i] = null
		_exchange_portrait_views[i] = null
	remove_child(w)
	w.queue_free()

func _install_exchange_extras(window: HudWindow) -> void:
	# The log: CIFTextBox 304's lines, from the top, no hanging indent.
	var box := window.node("GDR_EXCHANGE_TEXT_BOX") as Control
	if box != null:
		_exchange_log = HudChat.ChatList.new()
		_exchange_log.name = "ExchangeLog"
		_exchange_log.font = _builder.font_at(0) if _builder != null else ThemeDB.fallback_font
		_exchange_log.font_size = UiBuilder.FONT_SIZES[0]
		_exchange_log.hover_enabled = false
		_exchange_log.stack_from_bottom = false
		_exchange_log.hanging_indent = false
		_exchange_log.rows = int(floor(float(box.size.y if box.size.y > 0.0 else 87.0) / EXCHANGE_LOG_PITCH))
		_exchange_log.mouse_filter = Control.MOUSE_FILTER_PASS
		_exchange_log.set_anchors_preset(Control.PRESET_FULL_RECT)
		_exchange_log.gui_input.connect(_on_exchange_log_input)
		box.mouse_filter = Control.MOUSE_FILTER_PASS
		box.add_child(_exchange_log)
	# The red effect (155): its frames cut from the sheet, hidden until the
	# trust check shows it.
	var red := window.node("GDR_EXCHANGE_USER_VISUAL_EFFECT") as Control
	if red != null:
		var sheet: Texture2D = _builder.load_texture("interface\\exchange\\ch_red.ddj") if _builder != null else null
		_exchange_red_frames.clear()
		if sheet != null:
			for f in EXCHANGE_RED_FRAMES:
				var at := AtlasTexture.new()
				at.atlas = sheet
				at.region = Rect2((f % EXCHANGE_RED_COLUMNS) * EXCHANGE_RED_CELL, (f / EXCHANGE_RED_COLUMNS) * EXCHANGE_RED_CELL,
					EXCHANGE_RED_CELL, EXCHANGE_RED_CELL)
				_exchange_red_frames.append(at)
		_exchange_red = TextureRect.new()
		_exchange_red.name = "RedPulse"
		_exchange_red.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_exchange_red.stretch_mode = TextureRect.STRETCH_SCALE
		_exchange_red.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_exchange_red.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_exchange_red.texture = _exchange_red_frames[0] if not _exchange_red_frames.is_empty() else null
		red.add_child(_exchange_red)
		red.mouse_filter = Control.MOUSE_FILTER_IGNORE
		red.visible = false
	var tip := window.node("GDR_EXCHANGE_USER_VISUAL_TOOLTIP") as Control
	if tip != null:
		tip.visible = false
	# The portraits, over everything else in their boxes (drawn by the
	# window after its controls, c:0x7b21b0), each a PlayerPortrait whose
	# buffer follows its picture's physical size (ViewportPixels): sharp at
	# any UI scale.
	for k in 2:
		var holder := window.node("GDR_EXCHANGE_USER_VISUAL" if k == 0 else "GDR_EXCHANGE_PLAYER_VISUAL") as Control
		if holder == null:
			continue
		var view := TextureRect.new()
		view.name = "ExchangePortrait%d" % k
		view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		view.stretch_mode = TextureRect.STRETCH_SCALE
		view.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var r := Rect2(Vector2(holder.position) + Vector2(EXCHANGE_PORTRAIT_INSET.position),
			holder.size - Vector2(EXCHANGE_PORTRAIT_INSET.size))
		var authored = holder.get_meta(UiBuilder.AUTHORED_RECT_META, null)
		if authored is Rect2:
			r = Rect2((authored as Rect2).position + Vector2(EXCHANGE_PORTRAIT_INSET.position),
				(authored as Rect2).size - Vector2(EXCHANGE_PORTRAIT_INSET.size))
		view.position = r.position
		view.size = r.size
		view.set_meta(UiBuilder.AUTHORED_RECT_META, r)
		view.visible = false
		holder.get_parent().add_child(view)
		var portrait := PlayerPortrait.new()
		portrait.name = "ExchangePortraitView%d" % k
		portrait.size = Vector2i(r.size)
		portrait.set_transparent(true)
		portrait.set_framing(EXCHANGE_PORTRAIT_DISTANCE, EXCHANGE_PORTRAIT_FOV, 0.0, EXCHANGE_PORTRAIT_LIFT, 0.0)
		view.add_child(portrait)
		ViewportPixels.attach(view, portrait, exchange_portrait_buffer_for)
		view.texture = portrait.get_texture()
		_exchange_portraits[k] = portrait
		_exchange_portrait_views[k] = view
	# The tooltip (156) is the topmost: it takes the hover.
	if tip != null:
		tip.move_to_front()

## The bust's framing (OURS, MEASURED against the screenshots: a
## head-and-shoulders view with the head mid-height, about 39 of the 104
## pixels from the hat's top to the chin; the target lifted 1.0 over the
## head bone, as the player block's READ lift, centres the head as they do).
## Retail moves the model by
## (0, -h^2/34, -425/h) for a head at height h (c:0x7b2b2d..0x7b2b7b: 17.0,
## 0.5, 25.0) and renders through a camera object (+0x33e8) whose field of
## view was not read.
const EXCHANGE_PORTRAIT_DISTANCE := 15.0
const EXCHANGE_PORTRAIT_FOV := 30.0
const EXCHANGE_PORTRAIT_LIFT := 1.0

## The buffer for a portrait covering `physical` screen pixels: at least
## its rect (96 x 100), larger with the UI scale.
static func exchange_portrait_buffer_for(physical: Vector2i) -> Vector2i:
	return Vector2i(maxi(physical.x, 96), maxi(physical.y, 100))

## One side's portrait (`own_side`: the player's, below; else the
## opponent's, on top): a dressed body copy this takes, posed, rendered once.
func set_exchange_portrait(own_side: bool, skeleton: Skeleton3D, pose: BanReader.ParsedAnimation,
		zone_light: Array = []) -> void:
	var k := 1 if own_side else 0
	var portrait: PlayerPortrait = _exchange_portraits[k]
	var view: TextureRect = _exchange_portrait_views[k]
	if portrait == null or view == null:
		if skeleton != null and is_instance_valid(skeleton) and skeleton.get_parent() == null:
			skeleton.queue_free()
		return
	if zone_light.size() == 2:
		portrait.set_zone_light(zone_light[0], zone_light[1])
	portrait.set_character(skeleton, pose)
	view.visible = skeleton != null

func exchange_portrait(own_side: bool) -> PlayerPortrait:
	return _exchange_portraits[1 if own_side else 0]

func exchange_portrait_view(own_side: bool) -> TextureRect:
	return _exchange_portrait_views[1 if own_side else 0]

## The trust check's display (c:0x7b38f2..0x7b39d4): a stranger's portrait
## gets the red pulse behind it and the warning as its tooltip; a trusted
## one neither.
func exchange_trust_effect(untrusted: bool, text: String) -> void:
	var w: HudWindow = _windows.get(ExchangeController.WINDOW)
	if w == null or not bool(w.get_meta(EXCHANGE_FULL_META, false)):
		return
	var red := w.node("GDR_EXCHANGE_USER_VISUAL_EFFECT") as Control
	if red != null:
		red.visible = untrusted
	_exchange_red_ms = 0.0
	var tip := w.node("GDR_EXCHANGE_USER_VISUAL_TOOLTIP") as Control
	if tip != null:
		tip.visible = untrusted
		set_bubble_tip(tip, text if untrusted else "", EXCHANGE_TIP_WRAP)

## The red pulse's frame now (QA and tests), or -1 when it is not shown.
func exchange_red_frame() -> int:
	if _exchange_red == null or not _exchange_red.is_visible_in_tree():
		return -1
	return _exchange_red_frames.find(_exchange_red.texture)

func _process_exchange_red(delta: float) -> void:
	if _exchange_red == null or _exchange_red_frames.is_empty() or not _exchange_red.is_visible_in_tree():
		return
	_exchange_red_ms += delta * 1000.0
	var f := int(_exchange_red_ms / EXCHANGE_RED_FRAME_MS) % EXCHANGE_RED_FRAMES
	if _exchange_red.texture != _exchange_red_frames[f]:
		_exchange_red.texture = _exchange_red_frames[f]

func exchange_log_clear() -> void:
	if _exchange_log != null:
		_exchange_log.clear()

func exchange_log_add(text: String, colour: Color) -> void:
	if _exchange_log != null:
		_exchange_log.add_line(text, colour)

## The log's lines as drawn (tests and QA).
func exchange_log_lines() -> Array:
	return _exchange_log.lines if _exchange_log != null else []

## The mouse wheel scrolls the log a line at a time (OURS: the log shows no
## scroll bar in the screenshots).
func _on_exchange_log_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb == null or not mb.pressed or _exchange_log == null:
		return
	if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
		_exchange_log.set_first(_exchange_log.first - 1)
		accept_event()
	elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		_exchange_log.set_first(_exchange_log.first + 1)
		accept_event()

## The gold amounts greyed once their side confirmed (+0x36c).
func exchange_gold_greyed(mine: bool, other: bool) -> void:
	var window: HudWindow = _windows.get(ExchangeController.WINDOW)
	if window == null:
		return
	for pair in [["GDR_EXCHANGE_STATIC_MYMONEY", mine], ["GDR_EXCHANGE_STATIC_OTHERMONEY", other]]:
		var n := window.node(pair[0]) as Control
		if n != null:
			n.modulate = EXCHANGE_GREYED if bool(pair[1]) else Color.WHITE

## A category-1 code's message (ExchangeNet.CODE_TEXTS): the banner first for
## the codes that have one, then the system line, type 5.
func exchange_code_message(code: int) -> void:
	var key := String(ExchangeNet.CODE_TEXTS.get(code, ""))
	if key == "":
		print("HudPanels: exchange code 0x%x -- the client shows nothing for it" % code)
		return
	var text := _resolve_ui(key, "")
	if text == "":
		return
	if code in ExchangeNet.CODE_BANNER:
		exchange_banner.emit(text)
	exchange_system_line.emit(text, HudSystemMessage.TYPE_GAME)

func refresh_bag_after_exchange() -> void:
	if NetClient.current_character_name != "" and NetClient.is_connected_to_server():
		NetClient.list_inventory(NetClient.current_character_name)

func redraw_bag() -> void:
	if is_open("inventory"):
		_draw_bag_page()

## The dim quad over a bag cell, above the icon and below the count.
func _exchange_dim(cell: Node, on: bool) -> void:
	var dim := cell.get_node_or_null("ExchangeDim") as ColorRect
	if dim == null and on:
		dim = ColorRect.new()
		dim.name = "ExchangeDim"
		dim.color = EXCHANGE_DIM
		dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
		dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		cell.add_child(dim)
		var icon := cell.get_node_or_null("ItemIcon")
		cell.move_child(dim, icon.get_index() + 1 if icon != null else cell.get_child_count() - 1)
	if dim != null:
		dim.visible = on

## Whether a bag slot is offered (disabled while it is, 0x6b3f00).
func exchange_offered(slot: int) -> bool:
	return exchange != null and exchange.active and exchange.offered_slots.has(slot)

## The client's own refusal before the box (SOItem::FUN_008baf10): the
## item's CanTrade (ref +0xa4) 0x183a; 0 to go on. The devil's spirit's
## awakened period (0x18fa) is not tested here: the bag's period word is the
## server's, which refuses it (exchange.go).
func exchange_item_refusal(_slot: int, item_id: int) -> int:
	_load_items()
	var item: ItemTableReader.Item = _items.get(item_id)
	if item != null and not item.can_trade:
		return 0x183a
	return 0

## The offered bag slot's dim (0x6b3f00 -> slot+0x574 = 0): CIFSlotWithHelp
## draws an untextured 0x80000000 quad over the slot after the icon
## (c:0x67cfb0 -> 0x654d10), black at half alpha, so the slot reads at about
## half brightness; the count is drawn after it, undimmed
## (exchange_boxes.md Q1). The gold static's +0x36c is the same quad over
## its rect (c:0x64d940, Q2): white text becomes about (127, 127, 127).
const EXCHANGE_DIM := Color(0, 0, 0, 128.0 / 255.0)
const EXCHANGE_GREYED := Color(127.0 / 255.0, 127.0 / 255.0, 127.0 / 255.0)

## A message's display (exchange_boxes.md Q3, READ): the warning banner
## (0x77b580) and / or a system line of type 0 (0x7781b0(0, ...)); the
## window's own log (control 304) is parked at x 9999 by retail's layout and
## never seen, so a log-only line shows nothing.
## Round 836: with the portraits and log on (exchange_full_layout) the log's
## lines are seen too, in the colours retail writes them.
func exchange_line(key: String, args: Array, log_colour: Color, also_log: bool = true) -> void:
	var text := _exchange_text(key, args)
	if text != "" and key != "UIIT_MSG_EXCHANGE_AGREEMENT_WAIT":
		exchange_system_line.emit(text, HudSystemMessage.TYPE_ALWAYS)
	if text != "" and also_log:
		exchange_log_add(text, log_colour)

func exchange_warning(key: String, log_colour: Color) -> void:
	var text := _exchange_text(key, [])
	if text == "":
		return
	exchange_banner.emit(text)
	exchange_system_line.emit(text, HudSystemMessage.TYPE_ALWAYS)
	exchange_log_add(text, log_colour)

## 0x3087's notice: UIIT_MSG_STGRERR_ITEM_EXCHANGE_SUCCEED on the banner
## only (c:0x88bb50).
func exchange_done_notice() -> void:
	var text := _exchange_text("UIIT_MSG_STGRERR_ITEM_EXCHANGE_SUCCEED", [])
	if text != "":
		exchange_banner.emit(text)

func _exchange_text(key: String, args: Array) -> String:
	var fmt := _resolve_ui(key, "")
	if fmt == "":
		return ""
	for a in args:
		fmt = fmt.replace("%s", String(a)) if fmt.contains("%s") else fmt
	return fmt

## 0x3088 removes HUD requests of kinds 8, 6 and 7 (c:0x880840): the
## exchange's request box and the party's invitation boxes.
func close_request_boxes_6_7_8() -> void:
	close_party_invitation()
	close_exchange_request()

var _exchange_request_box: FriendMsgBox

## 0x3080 kind 1's box (HUD request kind 7, c:0x644c90 case 7;
## exchange_boxes.md A): MsgBoxINIF at 308 x 148; Accept answers 1, Refuse 0.
func show_exchange_request(asker_id: int, asker_name: String) -> FriendMsgBox:
	close_exchange_request()
	if _builder == null:
		return null
	var box := FriendMsgBox.new()
	if not box.build_exchange_request(_builder, asker_name):
		box.queue_free()
		return null
	box.set_meta("asker_id", asker_id)
	box.accepted.connect(func(_t: String) -> void: NetClient.exchange_answer(true))
	box.cancelled.connect(func() -> void: NetClient.exchange_answer(false))
	box.place_on(get_viewport_rect().size if is_inside_tree() else Vector2(1024, 768))
	add_child(box)
	_exchange_request_box = box
	return box

func close_exchange_request() -> void:
	if is_instance_valid(_exchange_request_box):
		_exchange_request_box.close()
	_exchange_request_box = null

func exchange_request_box() -> FriendMsgBox:
	return _exchange_request_box if is_instance_valid(_exchange_request_box) else null

## The item box (purpose 7, StoreMessageBox.Kind.EXCHANGE_ITEM); its OK
## offers the slot (0x7034 {4, slot}) when the count is above 0.
func open_exchange_item_box(slot: int, item_id: int, qty: int) -> StoreMessageBox:
	_load_items()
	var item: ItemTableReader.Item = _items.get(item_id)
	var stacks := item != null and is_stack_item(item)
	return _open_store_box("inventory", "ExchangeItem", StoreMessageBox.Kind.EXCHANGE_ITEM, {
		"icon": _item_icon(item_id), "name": item.display_name(_object_names) if item != null else "",
		"stack": maxi(1, qty) if stacks else 0,
	}, func(n: int) -> void:
		if n > 0 and exchange_mode():
			NetClient.exchange_add(slot))

## The gold box (purpose 8, Kind.EXCHANGE_GOLD): it opens at "1" (c:0x6b2ce5),
## no minimum, at most min(the gold carried, 1,000,000,000); OK sends a
## positive amount (c:0x6b4b3c -> 0x825f50(0x46, 0x1a, amount)).
func open_exchange_gold_box() -> StoreMessageBox:
	var carried: int = _stats.gold if _stats != null else _storage_carried
	return _open_store_box("inventory", "ExchangeGold", StoreMessageBox.Kind.EXCHANGE_GOLD,
		{"count": 1, "min": 0, "max": mini(maxi(0, carried), StoreMessageBox.GOLD_CAP)},
		func(n: int) -> void:
			if n > 0 and exchange_mode():
				NetClient.exchange_gold(n))

## The warehouse gold boxes: CIFMessageBox mode 3, MsgBoxStoreMoney (round
## 726), one move per box -- OK sends it and the box closes (round 631).
## Deposit (purpose 3) from the bag's gold button while the warehouse is
## open, withdraw (purpose 4) from the warehouse's. The amount is typed and
## held to what can move -- the carried gold, or the stored -- (OURS: the
## original's bound is not read).
func _open_gold_deposit() -> void:
	_open_gold_box(true)

func _open_gold_withdraw() -> void:
	_open_gold_box(false)

func _open_gold_box(deposit: bool) -> void:
	var balance := _storage_carried if deposit else _storage_stored
	# READ (0x6b2800 / 0x6b29f0): the amount opens at "0" (0x6b28c8), with no
	# minimum (0x634ff0(0)) and a maximum of min(the carried or stored gold,
	# 1,000,000,000) (0x6b295b..0x6b298a, 0x6b2bb6..0x6b2bf5, 0x634f20). The
	# send refuses 0 (_do_gold).
	_open_store_box("storage", "GoldDialog",
		StoreMessageBox.Kind.GOLD_DEPOSIT if deposit else StoreMessageBox.Kind.GOLD_WITHDRAW,
		{"count": 0, "min": 0, "max": mini(maxi(0, balance), StoreMessageBox.GOLD_CAP)},
		func(q: int) -> void: _do_gold(StorageNet.GOLD_DEPOSIT if deposit else StorageNet.GOLD_WITHDRAW, q))

## Kept for the QA hook and the tests: the deposit box.
func _open_gold_dialog() -> void:
	_open_gold_deposit()

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
## The SubViewport behind that texture (round 695), kept at the picture's
## physical size by a ViewportPixels on the TextureRect.
var _paper_doll_viewport: SubViewport = null

func set_paper_doll_texture(texture: Texture2D, viewport: SubViewport = null) -> void:
	_paper_doll_texture = texture
	_paper_doll_viewport = viewport
	_place_paper_doll_docked()

## The paper doll's viewport in the equipment pane. READ (round 633):
## CIFEquipment::vslot_013 renders the model into the pane's rect grown by
## (+2, +0x0f, -2, -0x25) (0x6ad8ca..0x6ad8d3) -- (2, 15, 176, 318) for the
## 178x355 pane -- with a Z clear only (0x6ad94b), so the frame and tile drawn
## before it show behind the model. PaperDoll.use_equipment_view renders at
## exactly this size with the client's camera, so the texture is drawn 1:1
## -- at UI scale 1.0. At any other scale the buffer follows the rect's size
## in physical pixels (round 695, ViewportPixels): at the user's 2.0 the doll
## renders 352x636 for the 352x636 pixels it covers, not 176x318 magnified
## twice. The camera keeps its height (KEEP_HEIGHT), so the picture is the
## same, with more pixels.
## (It was 98x236 at (40, 46), chosen by hand and framed on the bones.)
const PAPER_DOLL_RECT := Rect2(2, 15, 176, 318)

## Draws the live 3D paper doll in the equipment pane of the main popup, where
## vslot_013 draws it: in front of the frame and tile, behind the slot art and
## the slots.
func _place_paper_doll_docked() -> void:
	if _paper_doll_texture == null or _popup == null:
		return
	var eq_root := _equipment_root()
	if eq_root == null:
		return
	var doll := eq_root.get_node_or_null("PaperDoll") as TextureRect
	if doll == null:
		doll = TextureRect.new()
		doll.name = "PaperDoll"
		doll.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		doll.stretch_mode = TextureRect.STRETCH_SCALE
		doll.mouse_filter = Control.MOUSE_FILTER_IGNORE
		doll.position = PAPER_DOLL_RECT.position
		doll.size = PAPER_DOLL_RECT.size
		eq_root.add_child(doll)
		eq_root.move_child(doll, _after_equipment_background(eq_root))
		# Its visibility follows the pane and the window (a hidden parent
		# propagates visibility_changed to its children).
		doll.visibility_changed.connect(func() -> void:
			paper_doll_shown_changed.emit(doll.is_visible_in_tree()))
	doll.texture = _paper_doll_texture
	if _paper_doll_viewport != null:
		ViewportPixels.attach(doll, _paper_doll_viewport)
	paper_doll_shown_changed.emit(doll.is_visible_in_tree())

## Emitted when the paper doll comes on screen or leaves it: the preview
## renders only while it shows (PaperDoll.set_active; CIFEquipment's model is
## drawn by its window's draw, and its pose steps only while it is visible,
## vslot_012 0x6ab6b0 testing 0xb8f530).
signal paper_doll_shown_changed(shown: bool)

## Whether the paper doll is on screen now.
func paper_doll_shown() -> bool:
	var root := _equipment_root()
	var doll := root.get_node_or_null("PaperDoll") as CanvasItem if root != null else null
	return doll != null and doll.is_visible_in_tree()

# --- Turning the paper doll (round 633) ---------------------------------------
#
# READ: the pane's arrows and circle are GDR_EQ_BTN_ROTATE_LEFT (ID 10,
# 54,327,28,16), _RIGHT (ID 11, 96,327) and _RESET (ID 12, 81,327,16,16);
# Create keeps them at +0x26a4/+0x26a8/+0x26ac. Their handlers (the click
# table filled at 0xd6c570):
#
#   left  0x6ab920   yaw = yaw - frame_ms * 0.0015
#   right 0x6ab960   yaw = yaw + frame_ms * 0.0015
#   reset 0x6ab9a0   yaw = 0
#
# with the yaw at +0x578, handed to the model through 0xa5a8c0 (its vslot
# 0x30). 0.0015 is the double at 0xda6fa8; frame_ms is the int at 0x110f7f8,
# the frame's duration in milliseconds, clamped to 3000 (0xba4101) -- so a
# step is one frame's worth, 0.025 rad (1.4 degrees) at 60 frames a second.
# The yaw starts at 0 (the constructor, 0x6ab555) and nothing resets it on a
# show (0x6ac010), so a turned doll stays turned.
#
# Create sets flag 0x20 on the two arrows (0x6ac341, 0x6ac34e; not on the
# circle), and CIFButton's mouse handler then repeats them: the command is
# sent on the press (0x201/0x203), a 1000 ms timer starts (0x6561c9..0x656219),
# when it fires it gives way to a 50 ms one that re-sends the command each time
# it fires (OnTimer 0x655f40), and the release kills both without a click
# (0x656259..0x6562a3). Leaving the button pauses the timers and coming back
# resumes them (0xb93290 / 0xb93240). A timer fires when at least its period
# has passed since it last fired, once per tick (0xb933d0). The circle is a
# plain button: it acts on the release.
#
# Which way a positive yaw turns the model on screen is READ: 0x6ab960 (the
# right arrow) adds to the yaw and 0x6ab920 (the left) subtracts, both through
# 0xa5a8c0 -> vslot 0x30 -> CCompChar::FUN_00c26e70, the model's Y rotation;
# PaperDoll.set_yaw has the mapping into Godot (round 633's review).
#
# **The step is OURS (round 639, the user's request).** Retail's step, one
# frame's worth (frame_ms * 0.0015 rad, about 1.4 degrees a click at 60 fps),
# "moves too slow"; the user asked for 36 degrees a click, so ten clicks make
# a full turn. Each repeat of a held arrow steps the same 36 degrees at the
# retail's first delay (1000 ms) and then every 250 ms -- 144 degrees a second
# (OURS, round 639's review: retail's 50 ms made 720 degrees a second, too fast
# to aim). The reset still returns the yaw to 0 (0x6ab9a0).
signal paper_doll_yaw_changed(yaw: float)
## Retail's rate, kept for the record (0xda6fa8; not used since round 639).
const DOLL_YAW_PER_MS := 0.0015
## OURS (the user's request, round 639): one click, one tenth of a turn.
const DOLL_STEP_DEGREES := 36.0
const DOLL_REPEAT_DELAY_MS := 1000
## Retail's repeat period (OnTimer 0x655f40), kept for the record.
const DOLL_REPEAT_MS := 50
## OURS (round 639's review): the held arrow's repeat, 36 degrees every 250 ms.
const DOLL_HOLD_REPEAT_MS := 250
const DOLL_BTN_LEFT := "GDR_EQ_BTN_ROTATE_LEFT"
const DOLL_BTN_RIGHT := "GDR_EQ_BTN_ROTATE_RIGHT"
const DOLL_BTN_RESET := "GDR_EQ_BTN_ROTATE_RESET"
## The model's yaw in radians (+0x578).
var paper_doll_yaw := 0.0
## -1 while the left arrow is held, +1 the right, 0 neither.
var _doll_turn := 0
var _doll_turn_hovered := true
## When the repeat timer last fired (or was started), and its period.
var _doll_turn_last_ms := 0
var _doll_turn_period_ms := DOLL_REPEAT_DELAY_MS

func _wire_doll_rotation(window: HudWindow) -> void:
	for pair in [[DOLL_BTN_LEFT, -1], [DOLL_BTN_RIGHT, 1]]:
		var button := window.node(pair[0]) as BaseButton
		if button == null:
			continue
		var dir: int = pair[1]
		button.button_down.connect(func() -> void: _doll_turn_start(dir))
		button.button_up.connect(func() -> void: _doll_turn_stop(dir))
		button.mouse_exited.connect(func() -> void:
			if _doll_turn == dir:
				_doll_turn_hovered = false)
		button.mouse_entered.connect(func() -> void:
			if _doll_turn == dir:
				_doll_turn_hovered = true)
	var reset := window.node(DOLL_BTN_RESET) as BaseButton
	if reset != null:
		reset.pressed.connect(func() -> void: set_paper_doll_yaw(0.0))

## `measure` logs the yaw and asks for the pose line: on an arrow's press and
## release and on the reset, not on each 50 ms repeat of a held arrow (which
## wrote about 40 lines a second into the tester log).
func set_paper_doll_yaw(yaw: float, measure: bool = true) -> void:
	paper_doll_yaw = yaw
	paper_doll_yaw_changed.emit(yaw)
	if measure:
		_measure_paper_doll()

## The measurement a real-input run reads (round 633).
func _measure_paper_doll() -> void:
	print("HudPanels: doll yaw %.4f at %d ms" % [paper_doll_yaw, Time.get_ticks_msec()])
	paper_doll_measure_requested.emit()

## Asks World3D to log where the doll's hands and head land (round 633's
## review: the weapon hand and the turn direction are measured, not seen).
signal paper_doll_measure_requested

## One arrow command, 0x6ab920 (dir -1) or 0x6ab960 (dir +1), stepping
## DOLL_STEP_DEGREES (OURS, see above) instead of retail's frame's worth. The
## yaw is kept in [0, TAU) so ten steps land back on exactly 0.
func _doll_turn_step(dir: int, measure: bool = false) -> void:
	var yaw := fposmod(paper_doll_yaw + float(dir) * deg_to_rad(DOLL_STEP_DEGREES), TAU)
	if is_equal_approx(yaw, TAU) or absf(yaw) < 1e-6 or absf(yaw - TAU) < 1e-6:
		yaw = 0.0
	set_paper_doll_yaw(yaw, measure)

func _doll_turn_start(dir: int) -> void:
	_doll_turn = dir
	_doll_turn_hovered = true
	_doll_turn_step(dir, true)
	_doll_turn_last_ms = Time.get_ticks_msec()
	_doll_turn_period_ms = DOLL_REPEAT_DELAY_MS

func _doll_turn_stop(dir: int) -> void:
	if _doll_turn == dir:
		_doll_turn = 0
		_measure_paper_doll()

## The repeat timers, run each frame while an arrow is held.
func _doll_turn_tick(now_ms: int) -> void:
	if _doll_turn == 0 or not _doll_turn_hovered:
		return
	if now_ms - _doll_turn_last_ms < _doll_turn_period_ms:
		return
	_doll_turn_last_ms = now_ms
	_doll_turn_period_ms = DOLL_HOLD_REPEAT_MS
	_doll_turn_step(_doll_turn)

func _process(_delta: float) -> void:
	_doll_turn_tick(Time.get_ticks_msec())
	_process_exchange_red(_delta)
	if item_mall != null and item_mall.active:
		item_mall.tick()
	if party_match != null:
		# Whole milliseconds from an accumulated float (review M2: truncating
		# each frame's delta ran the 2 s lock about 2.08 s at 60 fps).
		_match_ms_acc += _delta * 1000.0
		var whole := int(_match_ms_acc)
		_match_ms_acc -= whole
		party_match.advance(whole)

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
	if panel_id == ALCHEMY_ID:
		close_alchemy()
		return
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
	if panel_id == ALCHEMY_ID:
		return alchemy_window() != null
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
		# Every tab key's routine (C 0x79ace0, I 0x79b020, S 0x79ae00,
		# A 0x79d5b0, P 0x79ae90, L 0x79b0b0) ends in the toggle helper
		# 0x79a7e0 on the popup: a key that hides it sounds the close, and a
		# key that shows it -- or switches the tab of a popup already up,
		# ShowWindow(1) again (0x79b062..0x79b09d) -- sounds the open (read).
		if _popup != null:
			UiSounds.window_toggled(_popup.window.visible, _interface_shown(), "main popup (%s key)" % panel_id)
		return
	# U and the community item (0x799120 -> 0x5b4980, 0x5b49c0) and Q
	# (0x7990e0) only ShowWindow: no call to the helper and no sound string
	# in either (read) -- the guild and quest windows open and close silently.
	if panel_id in GUILD_VIEWS:
		_toggle_guild_window(panel_id)
		return
	if panel_id == ALCHEMY_ID:
		# Y (0x780a65): destroy window 0xa8 if it exists, else open it.
		if alchemy_window() != null:
			close_alchemy()
		else:
			open_alchemy()
		return
	var window: HudWindow = _windows.get(panel_id)
	if window != null and window.visible:
		window.hide()
		_toggle_sound(panel_id, false)
		return
	var shown := open(panel_id)
	if shown != null:
		_toggle_sound(panel_id, shown.visible)

## Keys whose toggle routine ends in the helper 0x79a7e0 (read): E, party
## matching (0x79c170: open through the helper, close with its own
## snd_window_close at 0x79c299) and T, auto potion (0x79c750, the helper on
## both paths). The system item of the underbar menu reaches no helper
## (0x60cd10 shows the window itself), and Q's window is silent (above).
const TOGGLE_SOUNDS := {"partymatch": "0x79c170", "autopotion": "0x79c750"}

func _toggle_sound(panel_id: String, shown_now: bool) -> void:
	if TOGGLE_SOUNDS.has(panel_id):
		UiSounds.window_toggled(shown_now, _interface_shown(), "%s (%s)" % [panel_id, TOGGLE_SOUNDS[panel_id]])

## The interface's own shown flag, which the helper tests first (0x79a7e0's
## first 0xb8f530 is on the interface): hidden with the rest of the UI, the
## windows toggle silently.
func _interface_shown() -> bool:
	return is_visible_in_tree()

## A window's close button (CIFCloseButton, id 2 -> 0x817240 -> vslot_043,
## read). CIFWnd's vslot_043 (0x652c00, shared by 236 classes, the main
## popup, the system window, CIF_NPCWindow after its own checks, CIFStore,
## the message box) hides the window and runs the helper: snd_window_close.
## CIFStorageRoom (0x6cc080) and CIFStoreForPackage (0x6d2800) play it
## themselves while an NPC conversation is open, which is the only way this
## client opens them; CIFPartyMatch (0x7333f0) and CIFAutoPotion (0x7413b0)
## run 0x652c00 first. CIFExchange's (0x7b2660 -> 0x7b24d0) was not traced
## to a sound, so its close button stays silent. The .2dt windows (quest,
## world map, community: 0x46d7c0; the guild: 0x5b4cc0) only hide, silently;
## the alchemy window's is close_alchemy.
const SILENT_CLOSE_BUTTONS := ["exchange"]

func _wire_close_sound(panel_id: String, window: HudWindow) -> void:
	if panel_id in SILENT_CLOSE_BUTTONS or not window.has_signal("closed"):
		return
	window.closed.connect(func() -> void:
		UiSounds.window_toggled(false, _interface_shown(), "%s close button (vslot_043)" % panel_id))

## True if any panel is currently on screen -- World3D uses this to decide
## whether Escape should close a window or fall through.
func any_open() -> bool:
	if option_window() != null:
		return true
	if alchemy_window() != null:
		return true
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
	# The rest of the client's Escape list closes each of these through the
	# helper or its vslot_043 (read, see _escape_close); the quest and guild
	# windows are not in that list, and their own close is silent.
	var closed_id := ""
	for id in _windows:
		if _windows[id] == best:
			closed_id = id
			break
	if best == (_popup.window if _popup != null else null) or closed_id in ["store", "partymatch", "autopotion", "system", "npctalk", "storage"]:
		UiSounds.window_toggled(false, _interface_shown(), "Escape: %s" % (closed_id if closed_id != "" else best.name))
	return true

## One Escape press. The client's VK_ESCAPE (0x78b6c7) calls 0x79d620, which
## closes the first open window of a fixed list and returns (read). Ahead of
## the world map (window 28 of the `.2dt` manager, hidden at
## 0x79d785..0x79d7c2 and then 0x79ab80) the list has an interface mode
## (+0x50c, 0x777e70), **GDR_SYSTEM** (ID 0x62, hidden at 0x79d657..0x79d698),
## a +0x748 list gated on the item mall (0xa7), an interface child with id 38
## (0x7993f0) and GDR_GAMEGUIDE (help, 0x79d744). This client builds none of
## those but the System window, and World3D's help window is not closed by
## Escape here (open). After the map, the list goes on (read, 0x79d7d9..
## 0x79d99b): GDR_SKILLWITHDRAWAL (0x2b) and the item mall (0xa7); then, when
## the interface's +0x7b4 flag is set, GDR_STORAGEROOM (0x13) is closed with
## 0x7058c0 run on GDR_NPCWINDOW (0x79d837..0x79d85d); the guild storage
## (0x91); **GDR_NPCWINDOW** (+0x724, ID 30) if visible (0x79d89f); GDR_STALL
## (0x21) and **GDR_EXCHANGE** (0x1a) if visible; GDR_COMMUNITY (0x17); then
## **the alchemy window**, if it exists (0x79d97c -> 0x798e20(0)); then the
## main popup (+0x728) and the rest. Of these this client builds the storage,
## the NPC talk box, the exchange and the alchemy window, and closes them in
## that order. The NPC talk box stands for GDR_NPCWINDOW: CIF_NPCWindow::
## Create (0x704b40) loads if_npcwindow.txt, whose one control is
## GDR_NW_NPCTALK:CIF_NPCTalk, the class that loads if_npctalk.txt (0x6fa124). That +0x7b4 is "an NPC conversation is open" is **inferred**:
## the NPC window's open path 0x79dbd0 sets it (0x79dc25) and 0x79e350
## clears it; here the storage is closed when it is up. Every other window
## this client builds keeps its own rule after these: the topmost one
## closes (ours).
##
## The sounds (read): the System window and the world map are hidden and
## then handed to the helper (0x79d657..0x79d698 -> 0x79a7e0, 0x79d785..
## 0x79d7c2 -> 0x79ab80): snd_window_close. The storage and the NPC window
## are closed through their vslot_043 (0xac), which sounds the close (see
## _wire_close_sound); the exchange's is not traced, so it is silent. The
## main popup is hidden and handed to the helper (0x79db29). With nothing
## open, the System window is shown and handed to the helper: the open.
func _escape_close() -> bool:
	# Ours: the Option window takes Escape first -- its own key handler
	# (0x5f6470, character 0x1b) closes it -- and it closes silently.
	if option_window() != null:
		option_window().press_cancel()
		return true
	var system: HudWindow = _windows.get("system")
	if system != null and system.visible:
		system.hide()
		UiSounds.window_toggled(false, _interface_shown(), "Escape: system")
		return true
	if world_map != null and is_instance_valid(world_map) and world_map.visible:
		world_map.hide()
		UiSounds.window_toggled(false, _interface_shown(), "Escape: world map")
		return true
	for panel_id in ["storage", "npctalk", "exchange"]:
		var window: HudWindow = _windows.get(panel_id)
		if window != null and window.visible:
			if panel_id == "exchange" and exchange_mode():
				# Round 834: vslot_043 is the X, 0x7b24d0: the cancel, the
				# window kept until the answer.
				exchange.press_cancel()
				return true
			window.hide()
			if panel_id != "exchange":
				UiSounds.window_toggled(false, _interface_shown(), "Escape: %s (vslot_043)" % panel_id)
			return true
	if alchemy_window() != null:
		close_alchemy()
		return true
	return close_topmost()

func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key := event as InputEventKey
	if not key.pressed or key.echo:
		return
	if key.keycode == KEY_ESCAPE:
		if key.ctrl_pressed or key.alt_pressed:
			return
		# Escape closes one window (_escape_close); with nothing open it
		# raises the System menu, the way the original does.
		if not _escape_close():
			var system := open("system")
			if system != null:
				UiSounds.window_toggled(system.visible, _interface_shown(), "Escape: system")
				if qa_rects_on():
					_qa_print_rects.call_deferred("system", {"option": system.node("GDR_SYSTEM_BTN_OPTION")})
		get_viewport().set_input_as_handled()
		return
	# The windows' keys, from the one key table (KeyMap, round 608). A text
	# line with the keyboard keeps them: a focused LineEdit consumes a letter
	# before it gets here, and this makes that a rule rather than a side
	# effect (a SpinBox's line, a key a line lets through).
	if is_typing():
		return
	# With Ctrl, Shift or Alt too: retail tests no modifier for a table key
	# (KeyMap.resolve has the reading).
	var hit := KeyMap.resolve(key.keycode, key.ctrl_pressed, key.alt_pressed, key.meta_pressed, false, key.shift_pressed)
	if hit.is_empty():
		return
	var action := String(hit[0])
	if action.begins_with("panel:"):
		toggle(action.substr(6))
		get_viewport().set_input_as_handled()
	elif action == "worldmap":
		world_map_toggle_requested.emit()
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
	# Every part the archive's index names, parsed once and shared with the
	# world (round 741; read-only here).
	_items = ItemTableReader.load_all(archive)
	for item in _items.values():
		_items_by_code[(item as ItemTableReader.Item).code_name] = item
	# Round 731: both files the client's text map holds (ItemTableReader.
	# load_object_names); the equip one names 4,540 of the items.
	_object_names = ItemTableReader.load_object_names(archive)
	print("HudPanels: %d item(s) resolvable by id" % _items.size())

## Closes one of this client's own confirm boxes from its own buttons (Buy,
## Sell, Deposit/Take, Cancel). The box is an
## ANCESTOR of the pressed button, so freeing it there deletes the Button
## while BaseButton is still emitting `pressed` and the Viewport is still
## routing the click: round 631 reproduced that with a real X click on Sell as
## "~Object: ... was freed or unreferenced while a signal is being emitted from
## it" followed by "Program crashed with signal 11" (MEASURED, Godot 4.2.2).
## So the box is hidden now and deleted by the engine at the end of the frame,
## after the click has finished with it.
func _close_confirm_box(box: Control) -> void:
	if not is_instance_valid(box) or box.is_queued_for_deletion():
		return
	# Out of the name lookups at once (open_shop, a reopen of the same box),
	# so a new box keeps its plain name and a closing one is never reused.
	box.name = "%s_closing" % box.name
	box.hide()
	box.queue_free()

## The confirm boxes a store or warehouse window can carry, by node name.
const CONFIRM_BOXES := ["BuyConfirm", "SellConfirm", "DepositConfirm", "WithdrawConfirm", "GoldDialog", "BuybackConfirm", "SplitConfirm"]
## The boxes that are the inventory's one message box (+0x390) in the original.
const INVENTORY_BOXES := ["SellConfirm", "DepositConfirm", "WithdrawConfirm", "GoldDialog", "BuybackConfirm", "SplitConfirm",
	"ExchangeItem", "ExchangeGold"]

## Closes every confirm box on `window`. A box holds what it was opened on --
## the sell box a bag SLOT, not the item -- so one left behind a closed
## window and shown again on reopen acted on whatever had moved into that
## slot since (round 631 review). Called when the window hides (Escape, its
## X, close()) and when open_shop/open_storage reuse it for a new NPC.
func _close_window_boxes(window: HudWindow) -> void:
	if window == null:
		return
	for box_name in CONFIRM_BOXES:
		var box := window.get_node_or_null(box_name) as Control
		if box != null:
			_close_confirm_box(box)

## Hooks `window`'s hide to _close_window_boxes, once per window.
func _track_confirm_boxes(window: HudWindow) -> void:
	var on_hidden := _on_box_host_visibility.bind(window)
	if not window.visibility_changed.is_connected(on_hidden):
		window.visibility_changed.connect(on_hidden)

func _on_box_host_visibility(window: HudWindow) -> void:
	if is_instance_valid(window) and not window.visible:
		_close_window_boxes(window)

## The confirm boxes this client draws itself (buy, sell, a quantity to
## move, the warehouse's gold). Retail's CIFMessageBox sounds
## snd_window_open when shown and snd_window_close when hidden, if the
## interface is up (its ShowWindow, 0x63b630, read). **Inferred:** that
## retail raises a message box at these four points is not read; these boxes
## stand in for it. A box freed with the whole HUD (a scene change) is
## silent: the close is decided a frame later, by whether the box's window
## is still there (UiSounds.message_box_left).
func _message_box_sounds(box: Control) -> void:
	UiSounds.window_toggled(true, _interface_shown(), "message box %s shown (0x63b630)" % box.name)
	var what := "message box %s hidden (0x63b630)" % box.name
	var window_ref: WeakRef = weakref(box.get_parent())
	var tree := get_tree()
	# Two boxes of one name leaving in one frame (a reopen over a box that is
	# already closing) bind the same arguments, so the second connect is the
	# same Callable: Godot errors "already connected" (round 631, measured in
	# confirm_box_test.gd). One close sound for them is enough.
	box.tree_exiting.connect(func() -> void:
		if tree == null:
			return
		var left := UiSounds.message_box_left.bind(window_ref, what)
		if not tree.process_frame.is_connected(left):
			tree.process_frame.connect(left, CONNECT_ONE_SHOT))

## An item's TypeID1..4 (itemdata), or empty when the item is not known.
func item_types(item_id: int) -> PackedInt32Array:
	_load_items()
	var item: ItemTableReader.Item = _items.get(item_id)
	return item.type_ids if item != null else PackedInt32Array()

## Whether TypeIDs are the global chatting item's, 3/3/3/5 (0x7901c0's
## type-word test; round 634).
static func is_global_chat_item(types: PackedInt32Array) -> bool:
	return types.size() >= 4 and types[0] == 3 and types[1] == 3 and types[2] == 3 and types[3] == 5

## Whether TypeIDs are a reverse return scroll's, 3/3/3/3 (round 778: the
## client's own test FUN_0078e870 -- `(tid & 0x780) == 0x180` and
## `(tid & 0xf800) == 0x1800` over 3/3).
static func is_reverse_return_scroll(types: PackedInt32Array) -> bool:
	return types.size() >= 4 and types[0] == 3 and types[1] == 3 and types[2] == 3 and types[3] == 3

## Whether TypeIDs are a repair hammer's, 3/3/13/7 (round 838).
static func is_repair_hammer(types: PackedInt32Array) -> bool:
	return types.size() >= 4 and types[0] == 3 and types[1] == 3 and types[2] == 13 and types[3] == 7

## Round 838: the repair hammer asks first. READ (sro_client): the bag's use
## path (IFSlotWithHelp::FUN_00676570, 0x676a09) opens message box kind 0x1f
## for a 3/3/13 item whose CanUse byte is 129 (every hammer row's) --
## UIIT_STT_CONFIRM_BOX, UIIT_MSG_QUESTION_SILKMALL_ITEM_USE "Will you use
## the selected item?", OK and Cancel -- and its OK (0x797d90 case 0x1f)
## reaches SendItem_HandleUseItem (0x796660), whose case 7 sums the repair
## quote of the worn and carried items first and, at 0, says
## UIIT_MSG_STRGERR_THERE_IS_NO_ITEM_TO_REPAIR without sending.
## OURS: the box is the generic question box (PartyMatchConfirm, Yes / No);
## kind 0x1f's own size and button words were not read. Retail asks the same
## box for every CanUse-129 3/3/13 item but TypeID4 8, 12, 15 and 16; only
## the hammer is routed here.
func open_hammer_confirm(slot: int) -> PartyMatchConfirm:
	if _builder == null:
		return null
	var box := PartyMatchConfirm.new()
	if not box.build(_builder, _resolve_ui("UIIT_MSG_QUESTION_SILKMALL_ITEM_USE", "Will you use the selected item?")):
		box.free()
		return null
	box.name = "HammerConfirm"
	box.confirmed.connect(func() -> void:
		if repair_all_quote() <= 0:
			system_notice.emit(_resolve_ui("UIIT_MSG_STRGERR_THERE_IS_NO_ITEM_TO_REPAIR", "No item needs repairing."))
			return
		if NetClient.current_character_name != "":
			print("HudPanels: the repair hammer at bag slot %d" % slot)
			NetClient.use_item(NetClient.current_character_name, slot))
	add_child(box)
	box.centre_on(get_viewport_rect().size if is_inside_tree() else Vector2(1024, 768))
	return box

## Whether TypeIDs are an item used on the current COS (round 805,
## UseItemNet.is_cos_target_item).
static func is_cos_target_item(types: PackedInt32Array) -> bool:
	return UseItemNet.is_cos_target_item(types)

# --- The reverse return scroll (round 778) -----------------------------------
#
# The box (ReverseReturnBox, message box kind 0x21) and the world map's
# selection mode (HudWorldmap.enter_select_mode). READ: a destination button
# sends the use with option 2 or 3 (FUN_00797d90 case 0x21); the map button
# hides the box and puts the map in its selection mode with the box's kind
# (0x63b9a0 -> 0x622dd0(1, kind)); a popup button there sends option 7 with
# the row's id and closes the box (0x60f5f0 -> FUN_00777dd0); hiding the map
# meanwhile destroys the box unsent (vslot_023 0x624550 -> FUN_006ec860).
# World3D sends the use (NetClient.use_item_option).

## The use to send: the scroll's bag slot, the option (2, 3 or 7) and, for 7,
## the refoptionalteleport id.
signal reverse_return_requested(slot: int, option: int, target: int)

var _reverse_box: ReverseReturnBox
var _optional_teleports: OptionalTeleportReader
var _optional_teleports_loaded := false

# --- The crest items (round 824) ---------------------------------------------

## The crest items' boxes by code name (READ, FUN_00676570).
const CREST_ITEM_BOXES := {
	"ITEM_ETC_GUILD_CREST_USER": GuildMsgBox.Kind.CREST,
	"ITEM_ETC_GUILD_CREST_DELETE": GuildMsgBox.Kind.CREST_DELETE,
	"ITEM_ETC_UNION_CREST_USER": GuildMsgBox.Kind.UNION_CREST,
	"ITEM_ETC_UNION_CREST_DELETE": GuildMsgBox.Kind.UNION_CREST_DELETE,
}

## A crest box's OK: World3D runs 0x797d90's case for `kind` with the item in
## bag slot `slot` (the checks, the bitmap, the use).
signal crest_confirmed(slot: int, kind: int)

## The box for the crest item in bag slot `slot` (Kind.CREST..UNION_CREST_
## DELETE), placed as CMessageBoxManager places a box.
func open_crest_box(slot: int, kind: int) -> GuildMsgBox:
	if _builder == null:
		return null
	var old: GuildMsgBox = _guild_boxes.get(kind)
	if is_instance_valid(old):
		old.close()
	var box := GuildMsgBox.new()
	if not box.build_crest_box(_builder, kind):
		box.free()
		return null
	box.accepted.connect(func(_t: String) -> void: crest_confirmed.emit(slot, kind))
	add_child(box)
	box.place_on(get_viewport_rect().size if is_inside_tree() else Vector2(1024, 768))
	_guild_boxes[kind] = box
	print("CRESTBOX %x opened for bag slot %d" % [kind, slot])
	return box

## A crest item's accepted use (Item_OnUseItemResult 0x87b15c..0x87b327): a
## register opens box 0x1a / 0x1b, a delete the generic notice with
## UIIT_MSG_GUILD_ / UNION_CREST_DELETE_COMPLETE.
func crest_used(code_name: String) -> void:
	match code_name:
		"ITEM_ETC_GUILD_CREST_USER", "ITEM_ETC_UNION_CREST_USER":
			var kind := GuildMsgBox.Kind.CREST_DONE if code_name == "ITEM_ETC_GUILD_CREST_USER" else GuildMsgBox.Kind.UNION_CREST_DONE
			var box := GuildMsgBox.new()
			if _builder == null or not box.build_crest_box(_builder, kind):
				box.free()
				return
			add_child(box)
			box.place_on(get_viewport_rect().size if is_inside_tree() else Vector2(1024, 768))
			_guild_boxes[kind] = box
		"ITEM_ETC_GUILD_CREST_DELETE", "ITEM_ETC_UNION_CREST_DELETE":
			var note := GuildMsgBox.notice_box(_builder, "UIIT_MSG_GUILD_CREST_DELETE_COMPLETE"
				if code_name == "ITEM_ETC_GUILD_CREST_DELETE" else "UIIT_MSG_UNION_CREST_DELETE_COMPLETE")
			if note != null:
				add_child(note)
				note.centre_on(get_viewport_rect().size if is_inside_tree() else Vector2(1024, 768))

## The box for the reverse return scroll in bag slot `slot`, replacing one
## already up. Sits on this HUD, centred (ReverseReturnBox.screen_position).
func open_reverse_return_box(slot: int) -> ReverseReturnBox:
	close_reverse_return_box()
	var box := ReverseReturnBox.new()
	# Round 838: the special scroll's box has the add-on's two more buttons.
	var special := is_special_reverse_scroll(_bag_item_id_at_slot(slot))
	box.build(_builder, slot, special)
	box.option_chosen.connect(func(option: int) -> void:
		reverse_return_requested.emit(slot, option, 0))
	box.map_requested.connect(_on_reverse_map_requested)
	box.party_requested.connect(_open_reverse_party.bind(slot))
	box.saved_requested.connect(_open_reverse_saved.bind(slot))
	add_child(box)
	if box.is_inside_tree():
		box.position = box.screen_position(get_viewport_rect().size)
	_reverse_box = box
	print("REVERSEBOX opened for bag slot %d: %s" % [slot, ", ".join(
		["LastReturn", "LastDeath", "MapPoint", "Cancel"].map(func(m): return "'%s'" % box.caption_of(m)))])
	return box

## Round 838: whether item_id is the special reverse return scroll
## (ITEM_MALL_REVERSE_RETURN_SCROLL_SPECIAL: the plain scroll's row but its
## id, code and icon -- the server's IsSpecialReverseReturnScroll).
func is_special_reverse_scroll(item_id: int) -> bool:
	return item_id >= 0 and item_code_for_id(item_id).to_upper().ends_with("_REVERSE_RETURN_SCROLL_SPECIAL")

# --- The special scroll's add-on options (round 838, OURS; ReverseAddonBox) --

## Injected by the world: a region id's zone name (World3D's
## _zone_name_for_region), for the positions the lists show.
var region_namer: Callable
## The add-on list up, or null.
var _reverse_addon: ReverseAddonBox = null
## What the saved-location list asked for is wanted for: "register" or
## "move", "" when nothing waits.
var _reverse_saved_wanted := ""
var _reverse_saved_bag := -1
var _reverse_saved_slots: Array = []

func reverse_addon_box() -> ReverseAddonBox:
	if _reverse_addon != null and is_instance_valid(_reverse_addon) and not _reverse_addon.is_queued_for_deletion():
		return _reverse_addon
	return null

func _show_reverse_addon(box: ReverseAddonBox) -> void:
	var old := reverse_addon_box()
	if old != null:
		old.close()
	add_child(box)
	if box.is_inside_tree():
		box.position = box.screen_position(get_viewport_rect().size)
	_reverse_addon = box

## A place's words: its zone's name, else the region id (a dungeon's too).
func _reverse_place_text(region: int) -> String:
	if region == 0:
		return ""
	var zone := ""
	if region > 0 and (region & 0x8000) == 0 and region_namer.is_valid():
		zone = String(region_namer.call(region >> 8, region & 0xff))
	return zone if zone != "" else "Region %d" % region

## Option 4: "Movement of Party Members" -- one Move row per other member,
## "Character Name (Position)"; a row sends the use with the member's JID.
func _open_reverse_party(slot: int) -> void:
	close_reverse_return_box()
	var party: PartyState = NetClient.party
	var rows: Array = []
	var jids: Array = []
	if party != null and party.in_party:
		for m in party.members:
			if m.jid == party.own_jid:
				continue
			rows.append({"text": "%s  (%s)" % [m.member_name, _reverse_place_text(m.region)], "enabled": true})
			jids.append(m.jid)
	if rows.is_empty():
		# OURS words: the add-on's own line for this is not in the archive.
		system_notice.emit("There is no party member to move to.")
		return
	var box := ReverseAddonBox.new()
	box.header = "%s / %s / %s" % [_resolve_ui("VPLUS_UI_REVERSE_PARTY_MEMBERS_COLUMN_CHARACTER_NAME_TEXT", "Character Name"),
		_resolve_ui("VPLUS_UI_REVERSE_PARTY_MEMBERS_COLUMN_POSITION_TEXT", "Position"),
		_resolve_ui("VPLUS_UI_REVERSE_PARTY_MEMBERS_COLUMN_MOVE_TEXT", "Move")]
	box.build_list(_builder, slot, "VPLUS_UI_REVERSE_PARTY_MEMBERS_CAPTION_TEXT", "Movement of Party Members", "", "", rows)
	box.name = "ReversePartyBox"
	box.row_chosen.connect(func(i: int) -> void:
		print("REVERSEBOX party member %d chosen for bag slot %d" % [int(jids[i]), slot])
		reverse_return_requested.emit(slot, ReverseReturnBox.OPTION_PARTY, int(jids[i]))
		box.close())
	_show_reverse_addon(box)

## Option 5: the "User Setting Window" -- Setting Location / Movement, each
## asking the server for the slots first.
func _open_reverse_saved(slot: int) -> void:
	close_reverse_return_box()
	if not NetClient.reverse_saved_result.is_connected(_on_reverse_saved_result):
		NetClient.reverse_saved_result.connect(_on_reverse_saved_result)
	var box := ReverseAddonBox.new()
	box.build_list(_builder, slot, "VPLUS_UI_REVERSE_SAVED_LOCATION_CAPTION_TEXT", "User Setting Window",
		"VPLUS_UI_REVERSE_SAVED_LOCATION_DESC_TEXT", "Setting Location: Register current location...", [
			{"text": _resolve_ui("VPLUS_UI_REVERSE_SAVED_LOCATION_BUTTON_SETTING_TEXT", "Setting Location")},
			{"text": _resolve_ui("VPLUS_UI_REVERSE_SAVED_LOCATION_BUTTON_MOVEMENT_TEXT", "Movement")}])
	box.name = "ReverseSavedBox"
	box.row_chosen.connect(func(i: int) -> void:
		_reverse_saved_wanted = "register" if i == 0 else "move"
		_reverse_saved_bag = slot
		NetClient.reverse_saved(UseItemNet.SAVED_LIST, 0, slot))
	_show_reverse_addon(box)

## The server's slots: a refusal is said; a registration says the add-on's
## line; then the list the player asked for is shown.
func _on_reverse_saved_result(r: Dictionary) -> void:
	if not bool(r.get("ok", false)):
		system_notice.emit(String(r.get("reason", "")))
		return
	_reverse_saved_slots = r.get("slots", [])
	if bool(r.get("registered", false)):
		system_notice.emit(_resolve_ui("VPLUS_MSG_REVERSE_SCROLL_LOCATION_UPDATED", "Saved location has got updated."))
	print("REVERSEBOX saved slots: %s" % [_reverse_saved_slots.map(func(s): return int(s["region"]))])
	match _reverse_saved_wanted:
		"register":
			_open_reverse_slot_list(true)
		"move":
			_open_reverse_slot_list(false)

func _open_reverse_slot_list(register: bool) -> void:
	var rows: Array = []
	for s in _reverse_saved_slots:
		var region := int(s["region"])
		var label := _reverse_place_text(region) if region != 0 \
			else _resolve_ui("VPLUS_UI_REVERSE_EMPTY_SLOT_TEXT", "Empty Slot")
		rows.append({"text": "%d. %s" % [rows.size() + 1, label], "enabled": register or region != 0})
	var box := ReverseAddonBox.new()
	if register:
		box.build_list(_builder, _reverse_saved_bag, "VPLUS_UI_REVERSE_REGISTER_CAPTION_TEXT", "Location Registration Information Window",
			"VPLUS_UI_REVERSE_REGISTER_DESC_TEXT", "Click the button to save location.", rows)
	else:
		box.build_list(_builder, _reverse_saved_bag, "VPLUS_UI_REVERSE_MOVE_CAPTION_TEXT", "Location Movement Information Window",
			"VPLUS_UI_REVERSE_MOVE_DESC_TEXT", "You may move to the saved location on the button.", rows)
	box.name = "ReverseRegisterBox" if register else "ReverseMoveBox"
	var bag := _reverse_saved_bag
	box.row_chosen.connect(func(i: int) -> void:
		if not register:
			print("REVERSEBOX saved slot %d chosen for bag slot %d" % [i, bag])
			_reverse_saved_wanted = ""
			reverse_return_requested.emit(bag, ReverseReturnBox.OPTION_SAVED, i)
			box.close()
			return
		var send := func() -> void:
			print("REVERSEBOX registering slot %d" % i)
			NetClient.reverse_saved(UseItemNet.SAVED_REGISTER, i, bag)
		if i < _reverse_saved_slots.size() and int(_reverse_saved_slots[i]["region"]) != 0:
			var ask := PartyMatchConfirm.new()
			if ask.build(_builder, _resolve_ui("VPLUS_UI_REVERSE_REGISTER_CONFIRMATION_DESC_TEXT", "Do you confirm updating this slot?")):
				ask.name = "ReverseRegisterConfirm"
				ask.confirmed.connect(send)
				add_child(ask)
				ask.centre_on(get_viewport_rect().size if is_inside_tree() else Vector2(1024, 768))
				return
			ask.free()
		send.call())
	box.cancelled.connect(func() -> void: _reverse_saved_wanted = "")
	_show_reverse_addon(box)

## The box up, or null.
func reverse_return_box() -> ReverseReturnBox:
	if _reverse_box != null and is_instance_valid(_reverse_box) and not _reverse_box.is_queued_for_deletion():
		return _reverse_box
	return null

func close_reverse_return_box() -> void:
	var box := reverse_return_box()
	if box != null:
		box.close()
	_reverse_box = null

## The table the map's icons come from, read from the archive once.
func optional_teleports() -> OptionalTeleportReader:
	if not _optional_teleports_loaded:
		_optional_teleports_loaded = true
		var archive := _builder.media_archive() if _builder != null else null
		if archive != null:
			_optional_teleports = OptionalTeleportReader.new().load(func(path: String) -> PackedByteArray:
				var entry := ObjectLoader.find_file(archive, path)
				return archive.read_file(entry) if entry != null else PackedByteArray())
			print("HudPanels: refoptionalteleport -- %d rows, %d map points" % [
				_optional_teleports.size(), _optional_teleports.map_points().size()])
	return _optional_teleports

## The box's map button (0x63b9a0): the box hidden, the map shown in its
## selection mode.
func _on_reverse_map_requested() -> void:
	var box := reverse_return_box()
	var map := world_map as HudWorldmap
	if box == null or map == null or not is_instance_valid(map):
		return
	box.visible = false
	map.optional_reader = optional_teleports()
	if not map.select_point_chosen.is_connected(_on_reverse_point_chosen):
		map.select_point_chosen.connect(_on_reverse_point_chosen)
		map.select_cancelled.connect(_on_reverse_select_cancelled)
	if not map.visible:
		map.open()
	map.enter_select_mode()

func _on_reverse_point_chosen(id: int) -> void:
	var box := reverse_return_box()
	if box == null:
		return
	print("REVERSEBOX map point %d chosen for bag slot %d" % [id, box.slot])
	reverse_return_requested.emit(box.slot, ReverseReturnBox.OPTION_MAP, id)
	close_reverse_return_box()

func _on_reverse_select_cancelled() -> void:
	close_reverse_return_box()

# --- The return scrolls' casting bar (round 779) -----------------------------
#
# Retail's CIFDelayGaugeBoard holding one CIFDelayInfo of kind 0
# (DelayInfoBar has every address). READ: Item_OnUseItemResult opens it for
# an accepted 3/3/3/1 or 3/3/3/3 use with the item's name and Param1 (ms);
# its cancel sends 0x705B; the 0x30BF kind 0xb value 0 for this player ends
# it with UIIT_MSG_TRANSITION_CANCEL_RESULT when one was up; the zone reset
# and this player's death clear it silently. World3D drives the three.

## The bar's cancel button was pressed: World3D sends 0x705B.
signal cast_cancel_requested

var _cast_bar: DelayInfoBar

## Opens the bar for the item `item_id`: its name and its Param1 as the
## total in ms (READ: FUN_007b1bf0 case 0 reads the client's own row, the
## ref's +0x60 and +0x2b4). `fallback_ms` is the server's cast length, used
## when this client's table lacks the row (OURS). A bar already up is
## replaced (retail removes the kind's entry first, FUN_007b15a0's loop).
func open_cast_bar(item_id: int, fallback_ms: int, fallback_name: String = "") -> DelayInfoBar:
	close_cast_bar()
	var ms := item_param1(item_id) if item_id > 0 else 0
	if ms <= 0:
		ms = fallback_ms
	var title := item_name(item_id) if item_id > 0 else ""
	if title == "":
		title = fallback_name
	var bar := DelayInfoBar.new()
	add_child(bar)
	bar.build(_builder, title, ms, item_id)
	bar.position = DelayInfoBar.screen_position(get_viewport_rect().size)
	bar.cancel_pressed.connect(func() -> void: cast_cancel_requested.emit())
	_cast_bar = bar
	print("CASTBAR opened: '%s' item %d, %d ms, at %s" % [bar.caption(), item_id, bar.total_ms, str(bar.position)])
	return bar

## The bar up, or null.
func cast_bar() -> DelayInfoBar:
	if _cast_bar != null and is_instance_valid(_cast_bar) and not _cast_bar.is_queued_for_deletion():
		return _cast_bar
	return null

## Closes the bar; reports whether one was up.
func close_cast_bar() -> bool:
	var bar := cast_bar()
	_cast_bar = null
	if bar == null:
		return false
	bar.close()
	return true

## The TypeIDs of what lies in a bag slot, or empty.
func bag_item_types(slot: int) -> PackedInt32Array:
	var id := _bag_item_id_at_slot(slot)
	return item_types(id) if id >= 0 else PackedInt32Array()

## The TypeIDs of what is worn in an equipment slot, or empty.
func worn_item_types(worn_slot: int) -> PackedInt32Array:
	for e in _equipped_items:
		if e is EquipmentNet.Equipped and (e as EquipmentNet.Equipped).slot == worn_slot:
			return item_types((e as EquipmentNet.Equipped).item_id)
	return PackedInt32Array()

## slot -> current durability, from InventoryNet.Durability entries.
static func _durability_by_slot(entries: Array) -> Dictionary:
	var out := {}
	for d in entries:
		if d != null and d.get("slot") != null:
			out[int(d.get("slot"))] = int(d.get("current"))
	return out

## The icon for an item id, or null. Icons are ordinary .ddj textures, so
## the builder's own cache serves them.
func _item_icon(item_id: int) -> Texture2D:
	_load_items()
	var item: ItemTableReader.Item = _items.get(item_id)
	if item == null or item.icon_path == "" or _builder == null:
		return null
	return _builder.load_texture(item.icon_path)

## The seal star on an item slot's icon (ItemSealEdge, READ 0x6871d0 /
## 0x67cfb0): an item whose ref passes 0x8ba600 (Rarity 2 or 6), on every
## slot that holds one -- the bag, the worn slots, the warehouse, the store's
## goods (0x6d1ff0 sets their +0x28), the buy-back row and the held icon (the
## quick slots go through is_seal_item). item_id < 0 clears it.
func _set_item_seal_edge(icon: Control, item_id: int) -> void:
	ItemSealEdge.show_on(icon, _builder, is_seal_item(item_id), item_id)

## Whether an item id is a seal item (0x8ba600: Rarity 2 or 6).
func is_seal_item(item_id: int) -> bool:
	if item_id < 0:
		return false
	_load_items()
	var item: ItemTableReader.Item = _items.get(item_id)
	return item != null and ItemTooltipLines.is_seal(item)

## **Item tooltips** (round 731, docs/protocol/item_tooltip.md): every item
## icon's hover shows the original's CNIFHelperBubbleWindow (ItemTooltipBubble)
## with the lines ItemTooltipLines composes, instead of Godot's tooltip_text
## popup (blurry at DPI 2.0, wrong face, no frame). Each site calls
## _set_item_tip with what it knows of the item; the hover reads it back.
const ITEM_TIP_META := &"item_tip"
const ITEM_TIP_WIRED_META := &"item_tip_wired"
var _tip_bubble: ItemTooltipBubble = null
var _type_names: ItemTypeNames = null
## A test or tool's override (round 731): Callable(where: String, slot: int,
## item_id: int) -> Dictionary of extra "instance" fields, merged over what
## ItemTooltipInstance builds from NetClient's round-732 instance lists.
var item_instance_lookup := Callable()

## Marks `icon` as showing `item_id`'s tooltip; item_id < 0 clears it.
## where/slot name the instance for item_instance_lookup; cur/maximum are the
## instance's durability when the server reported it; price is a store's.
func _set_item_tip(icon: Control, item_id: int, where: String = "", slot: int = -1,
		cur: int = -1, maximum: int = -1, price: int = -1) -> void:
	if icon == null:
		return
	icon.tooltip_text = ""
	if item_id < 0:
		if icon.has_meta(ITEM_TIP_META):
			icon.remove_meta(ITEM_TIP_META)
		if _tip_bubble != null and _tip_bubble.source == icon:
			_tip_bubble.hide_bubble()
		return
	icon.set_meta(ITEM_TIP_META, {"id": item_id, "where": where, "slot": slot,
		"cur": cur, "max": maximum, "price": price})
	if not icon.has_meta(ITEM_TIP_WIRED_META):
		icon.set_meta(ITEM_TIP_WIRED_META, true)
		icon.mouse_entered.connect(func() -> void: _show_item_tip(icon))
		icon.mouse_exited.connect(func() -> void: _hide_item_tip(icon))
	if _tip_bubble != null and _tip_bubble.source == icon and _tip_bubble.visible:
		_show_item_tip(icon)

func _show_item_tip(icon: Control) -> void:
	if not is_instance_valid(icon) or not icon.has_meta(ITEM_TIP_META):
		return
	var m: Dictionary = icon.get_meta(ITEM_TIP_META)
	var lines := item_tip_lines(int(m["id"]), String(m["where"]), int(m["slot"]),
		int(m["cur"]), int(m["max"]), int(m["price"]))
	if _tip_bubble == null:
		_tip_bubble = ItemTooltipBubble.new(_builder)
		add_child(_tip_bubble)
	_tip_bubble.show_lines(lines, icon.get_global_rect(), icon)

func _hide_item_tip(icon: Control) -> void:
	if _tip_bubble != null and _tip_bubble.source == icon:
		_tip_bubble.hide_bubble()

## The tooltip on show, for tests and QA (empty when hidden).
func item_tip_shown() -> Array:
	return _tip_bubble.shown_lines() if _tip_bubble != null else []

## **Any control's hover help in the original's window** (round 786, the
## user: "when hovering over skills you should see the blue windows but it
## shows the native game gui instead"). The item tips' mechanism above,
## for every other help: `source` is the rows (ItemTooltipLines' shape), a
## Callable returning them at hover time (so a skill's tooltip reads the
## points and levels of that moment), or a plain String drawn as white rows.
## Empty clears the help. tooltip_text is emptied, so Godot's own popup -- a
## grey sub-window in its default face -- never shows on these controls.
## `wrap` > 0 breaks long rows (ItemTooltipBubble.wrapped).
const BUBBLE_TIP_META := &"bubble_tip"
const BUBBLE_TIP_WIRED_META := &"bubble_tip_wired"
func set_bubble_tip(control: Control, source: Variant, wrap: float = 0.0) -> void:
	if control == null:
		return
	control.tooltip_text = ""
	var empty: bool = source == null or (source is String and String(source) == "") \
		or (source is Array and (source as Array).is_empty())
	if empty:
		if control.has_meta(BUBBLE_TIP_META):
			control.remove_meta(BUBBLE_TIP_META)
		if _tip_bubble != null and _tip_bubble.source == control:
			_tip_bubble.hide_bubble()
		return
	control.set_meta(BUBBLE_TIP_META, {"source": source, "wrap": wrap})
	if control.mouse_filter == Control.MOUSE_FILTER_IGNORE:
		control.mouse_filter = Control.MOUSE_FILTER_PASS
	if not control.has_meta(BUBBLE_TIP_WIRED_META):
		control.set_meta(BUBBLE_TIP_WIRED_META, true)
		control.mouse_entered.connect(func() -> void: show_bubble_tip(control))
		control.mouse_exited.connect(func() -> void:
			if _tip_bubble != null and _tip_bubble.source == control:
				_tip_bubble.hide_bubble())

## The rows `control`'s help shows now ([] for none).
func bubble_tip_lines(control: Control) -> Array:
	if not is_instance_valid(control) or not control.has_meta(BUBBLE_TIP_META):
		return []
	var src: Variant = (control.get_meta(BUBBLE_TIP_META) as Dictionary)["source"]
	if src is Callable:
		src = (src as Callable).call()
	if src is String:
		var rows: Array = []
		for line in String(src).split("\n"):
			rows.append({"text": line, "color": ItemTooltipLines.WHITE, "bold": false, "icon": false})
		return rows
	return src if src is Array else []

## Shows `control`'s help beside it (the hover; tests and QA call it too).
func show_bubble_tip(control: Control) -> void:
	var lines := bubble_tip_lines(control)
	if lines.is_empty():
		if _tip_bubble != null and _tip_bubble.source == control:
			_tip_bubble.hide_bubble()
		return
	if _tip_bubble == null:
		_tip_bubble = ItemTooltipBubble.new(_builder)
		add_child(_tip_bubble)
	_tip_bubble.show_lines(lines, control.get_global_rect(), control,
		float((control.get_meta(BUBBLE_TIP_META) as Dictionary).get("wrap", 0.0)))

func item_tip_bubble() -> ItemTooltipBubble:
	return _tip_bubble

## OPENSRO_QA_ITEM_TIP (round 731): the tooltips of `spec`'s items --
## "<id or code name>[:where[:cur/max[:price]]]", comma separated -- in bubbles of their
## own, side by side from the top-left, for a render; each one's lines and
## rect logged as `QA ITEM_TIP`.
func qa_show_item_tips(spec: String) -> void:
	var view := get_viewport_rect().size
	var at := Vector2(8, 8)
	var row_h := 0.0
	for part in spec.split(",", false):
		var f := part.split(":")
		var cur := -1
		var mx := -1
		if f.size() > 2 and f[2].contains("/"):
			cur = int(f[2].get_slice("/", 0))
			mx = int(f[2].get_slice("/", 1))
		_load_items()
		var id: int = int(f[0]) if f[0].is_valid_int() else (_items_by_code[f[0]].id if _items_by_code.has(f[0]) else -1)
		var lines := item_tip_lines(id, f[1] if f.size() > 1 else "bag", -1, cur, mx,
			int(f[3]) if f.size() > 3 else -1)
		var b := ItemTooltipBubble.new(_builder)
		add_child(b)
		b.show_lines(lines, Rect2())
		if at.x + b.size.x > view.x and at.x > 8:
			at = Vector2(8, at.y + row_h + 8)
			row_h = 0.0
		b.position = at
		at.x += b.size.x + 8
		row_h = maxf(row_h, b.size.y)
		print("QA ITEM_TIP %s at %s size %s: %s" % [part, str(b.position), str(b.size),
			ItemTooltipLines.as_text(lines).replace("\n", " | ")])

## Round 789 (QA, OPENSRO_QA_AVATAR_VIEW): each avatar's tooltip, as its
## window's hover shows it, drawn down the right edge and printed as a
## `QA AVATAR TIP` line; and where each avatar window is (`QA SLOT avatar`).
func qa_show_avatar_tips() -> void:
	qa_hide_avatar_tips()
	var view := get_viewport_rect().size
	var y := 8.0
	var storage: Dictionary = NetClient.last_avatar_instances
	var shown := AvatarEquipment.by_display(storage, item_types)
	for d in AvatarEquipment.DISPLAYS:
		var slot_ctl := _avatar_slot_control(d)
		if slot_ctl != null and slot_ctl.is_visible_in_tree():
			print("QA SLOT avatar:%d at %s holds storage %s" % [d, _qa_xy(slot_ctl), str(shown.get(d, -1))])
		if not shown.has(d):
			continue
		var it: ItemInstance = storage[shown[d]]
		var lines := item_tip_lines(it.ref_item_id, "avatar", int(shown[d]))
		var b := ItemTooltipBubble.new(_builder)
		add_child(b)
		_qa_avatar_tip_bubbles.append(b)
		b.show_lines(lines, Rect2())
		b.position = Vector2(view.x - b.size.x - 8, y)
		y += b.size.y + 8
		print("QA AVATAR TIP window %d storage %d item %d: %s" % [d, int(shown[d]), it.ref_item_id,
			ItemTooltipLines.as_text(lines).replace("\n", " | ")])
	print("QA AVATAR SKILL STRIP %s" % ("shown" if _avatar_skill_strip_shown() else "hidden"))

## The bubbles qa_show_avatar_tips drew (round 789 lane E: a live run shows
## the avatar view more than once -- after the equip, after a grant -- and
## each show replaces the last one's bubbles rather than stacking them).
var _qa_avatar_tip_bubbles: Array = []

func qa_hide_avatar_tips() -> void:
	for b in _qa_avatar_tip_bubbles:
		if is_instance_valid(b):
			(b as Node).queue_free()
	_qa_avatar_tip_bubbles.clear()

## The lines of an item's tooltip (ItemTooltipLines.compose) with this
## client's text tables, type names, player and instance.
func item_tip_lines(item_id: int, where: String = "", slot: int = -1,
		cur: int = -1, maximum: int = -1, price: int = -1) -> Array:
	_load_items()
	var item: ItemTableReader.Item = _items.get(item_id)
	if item == null:
		return [{"text": "Item %d" % item_id, "color": ItemTooltipLines.WHITE, "bold": true, "icon": true}]
	if _type_names == null:
		_type_names = ItemTypeNames.load_from(_builder.media_archive() if _builder != null else null)
	var type_key := _type_names.type_key(item.type_ids)
	var set_name: String = _type_names.set_names.get(item.set_id, "")
	# An owned item (any site but the store) whose instance the client has
	# not got shows its reference values without a "(+x%)" (OURS, until lane
	# B); the store's goods are reference items, variance 0 -- except a good
	# an NPC of OpenSRO's own lists with its instance (round 786,
	# OpNpcShopGoods: the Test Items NPC's +12 full-blue pieces), which reads
	# as that owned item would. The original's store slot holds a whole item
	# object too, plus and blue options set from the package (c:0x8bf3a0).
	var instance := {}
	if where != "store":
		instance["unknown_variance"] = true
	if cur >= 0 and maximum > 0:
		instance["durability"] = [cur, maximum]
	var listed: Object = _item_instance(where, slot) if where == "store" else null
	if listed != null:
		instance.merge(ItemTooltipInstance.fields(item, listed), true)
	if where != "store":
		var extra := ItemTooltipInstance.fields(item, _item_instance(where, slot))
		if item_instance_lookup.is_valid():
			var given = item_instance_lookup.call(where, slot, item_id)
			if given is Dictionary:
				extra.merge(given, true)
		if not extra.is_empty():
			instance.erase("unknown_variance")
			instance.merge(extra, true)
	var ctx := {
		"text": Callable(self, "_tip_text"),
		"names": _object_names,
		"type_name": _resolve_ui(type_key, "") if type_key != "" else "",
		"set_name": set_name,
		"player": _tip_player(),
		"instance": instance,
		"price": price,
		"description": _item_description(item),
	}
	# Round 789: a devil's spirit's ability lines (AvatarTables, READ
	# c:0x67b460) at its plus.
	if item.is_devil_spirit():
		ctx["ability_groups"] = ItemTooltipInstance.spirit_groups(avatar_tables(), item_id, int(instance.get("plus", 0)))
	return ItemTooltipLines.compose(item, ctx)

## Round 789: the grant window (GrantMagicAttributeWindow). 0xB046 {1, 0x20}
## shows it and the inventory beside it (READ c:0x888e30 -> 0x79d4a0(1),
## 0x79af20). Returns its controller, or null when the layout does not build.
func open_grant_window() -> GrantMagicAttributeWindow:
	var window := open("grant")
	if window == null:
		return null
	var c := GrantMagicAttributeWindow.compose(window, _builder)
	c.tables = avatar_tables()
	c.options = MagicOptionTable.shared
	if not c.send.is_valid():
		c.send = func(bag_slot: int, code: String) -> void:
			if NetClient.is_connected_to_server():
				print("HudPanels: avatar grant %s to bag slot %d" % [code, bag_slot])
				NetClient.avatar_grant(bag_slot, code)
		c.message = func(t: String) -> void: system_notice.emit(t)
		c.text = Callable(self, "_tip_text")
		c.show_icon = func(icon: TextureRect, item_id: int, bag_slot: int) -> void:
			icon.texture = _item_icon(item_id) if item_id >= 0 else null
			_set_item_tip(icon, item_id, "bag", bag_slot)
			_set_item_seal_edge(icon, item_id)
		# Cancel (ID 6, c:0x808cb0): hidden and the talk ended (0x704B, through
		# npc_window_hidden).
		var cancel_btn := window.node(GrantMagicAttributeWindow.N_CANCEL) as BaseButton
		if cancel_btn != null:
			cancel_btn.pressed.connect(func() -> void: close("grant"))
		window.visibility_changed.connect(func() -> void:
			if not window.visible:
				c.clear_item())
	c.clear_item()
	# 0x79af20: the inventory beside it.
	open("inventory")
	return c

## The open grant window's controller, or null.
func grant_window() -> GrantMagicAttributeWindow:
	var window: HudWindow = _windows.get("grant")
	if window == null or not window.is_visible_in_tree():
		return null
	return GrantMagicAttributeWindow.of(window)

## Whether a point is over the open grant window, in front.
func _over_grant_window(at: Vector2) -> bool:
	return grant_window() != null and _over_window("grant", at)

## A bag item put down on the grant window (vslot_028 c:0x80a320).
func _grant_offer(from: int) -> void:
	var c := grant_window()
	if c == null:
		return
	_load_items()
	var item: ItemTableReader.Item = _items.get(_bag_item_id_at_slot(from))
	c.offer(from, item, _item_instance("bag", from) as ItemInstance)

## 0x34AA (NetClient.avatar_grant_result): the window refreshes and says so;
## the bag is asked for again (the granted item's tooltip reads the new
## instance at once, NetClient replaced it).
func _on_avatar_grant_result(r: Dictionary) -> void:
	var c := grant_window()
	if c != null:
		c.apply_result(r)
	elif not bool(r.get("ok", false)):
		system_notice.emit(AvatarNet.grant_refusal_line(int(r.get("code", 0)), Callable(self, "_tip_text")))

## Round 789: the avatar tables (AvatarTables) from the player's Media.pk2,
## loaded once.
func avatar_tables() -> AvatarTables:
	if AvatarTables.shared == null:
		AvatarTables.shared = AvatarTables.from_archive(_builder.media_archive() if _builder != null else null)
	return AvatarTables.shared

## The ItemInstance (round 732) the server sent for this site's slot, or null:
## NetClient's last bag, equipment and warehouse lists, keyed by slot.
const _INSTANCE_LISTS := {"bag": "last_inventory_instances", "equipment": "last_equipment_instances",
	"storage": "last_storage_instances", "avatar": "last_avatar_instances"}

func _item_instance(where: String, slot: int) -> Object:
	# The store: the instance the open tab lists its good `slot` as (round
	# 786, ShopReader.Tab.instances; null for a reference good).
	if where == "store":
		if _shop_selected < 0 or _shop_selected >= _shop_tabs.size():
			return null
		return (_shop_tabs[_shop_selected] as ShopReader.Tab).instance_at(slot)
	# Round 834: the exchange's grids (ExchangeController).
	if where == "exchange_my" or where == "exchange_other":
		return exchange.instance_at(where == "exchange_my", slot) if exchange != null else null
	if slot < 0 or not _INSTANCE_LISTS.has(where):
		return null
	var list = NetClient.get(_INSTANCE_LISTS[where])
	if list is Dictionary and (list as Dictionary).has(slot):
		return list[slot] as Object
	return null

## A tooltip key's text: the UI table, else the equip text table's rows the
## tooltip asked for (the client looks keys up across every text file).
func _tip_text(key: String, fallback: String) -> String:
	var text := _resolve_ui(key, "")
	if text == "" and _type_names != null:
		text = String(_type_names.equip_texts.get(key, ""))
	return text if text != "" else fallback

## Column 6's description through the object text table (0x66f850 prints
## it when it resolves), or "".
func _item_description(item: ItemTableReader.Item) -> String:
	if _object_names == null or item.desc_strid == "" or item.desc_strid == "xxx":
		return ""
	var text := _object_names.get_text(item.desc_strid)
	return "" if text == item.desc_strid else text

## The player's level, Str, Int, gender (0 woman, 1 man) and country (0
## Chinese, 1 European) for the requirement lines' colours; -1 where unknown
## (the line is then white).
func _tip_player() -> Dictionary:
	var p := {"level": -1, "str": -1, "int": -1, "gender": -1, "country": -1}
	if _stats != null:
		p["level"] = _stats.level
		p["str"] = _stats.str
		p["int"] = _stats.intel
	if not _skill_mastery_levels.is_empty():
		p["masteries"] = _skill_mastery_levels
	var scene := get_tree().current_scene if is_inside_tree() else null
	if scene == null:
		return p
	if int(p["level"]) < 0:
		var lv = scene.get("_player_level")
		if lv != null and int(lv) > 0:
			p["level"] = int(lv)
	var g = scene.get("_player_gender")
	if g is String:
		if (g as String).ends_with("_woman"):
			p["gender"] = ItemTableReader.REQ_GENDER_WOMAN
		elif (g as String).ends_with("_man"):
			p["gender"] = ItemTableReader.REQ_GENDER_MAN
	var body = scene.get("_player_body")
	var countries = scene.get("_country_by_code")
	if body is String and countries is Dictionary and (countries as Dictionary).has(body):
		p["country"] = int(countries[body])
	return p

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

## An item's display name, icon path (itemdata's, under `icon\`) and Param1,
## for the item-grant icons and the CompositeItem window (round 632 review).
func item_name(item_id: int) -> String:
	return _item_name(item_id)

func item_icon_path(item_id: int) -> String:
	_load_items()
	var item: ItemTableReader.Item = _items.get(item_id)
	return item.icon_path if item != null else ""

func item_param1(item_id: int) -> int:
	_load_items()
	var item: ItemTableReader.Item = _items.get(item_id)
	return item.param1 if item != null else 0

# --- The bag's pages (round 633) -------------------------------------------
#
# READ from sro_client.exe. The character-data handler reads the inventory
# size byte, takes 13 off it for the equipment slots (0x9d9aee `sub dl,0xd`)
# and hands the bag's size to IFInventory 0x6b6620, which builds the bag:
#
#   - pages = ((size - 1) >> 5) + 1, one for a size of 0 or 1, asserting at
#     most 3 (IFInventory.cpp line 0xa7);
#   - one tab per page, a CIFSelectableArea (class 0xee96c0) placed in code
#     relative to the pane, above its frame (the TABS below);
#   - pages * 32 slots, CIFSlotWithHelp (0xee9b18) ID 100 + i, each 32x32 at
#     (18 + 36 * col, 13 + 36 * row) for col i % 4 and row (i % 32) / 4: the
#     top-left of the lattice cell it sits on (GDR_INVENTORY_LATTICE is
#     18,13, 36-pixel cells) -- so an icon is 32 pixels in a 36-pixel cell;
#   - a slot at or past the size shows `interface\pet\pt_block.ddj` and is
#     disabled (0xb8f540(0)): the part of the last page the size does not
#     reach is locked;
#   - page 0 selected (0x6b3d00(0) at 0x6b6d16).
#
# 0x6b3d00(page) is the selector: the old tab deselected and the new one
# selected (0x64cc30), the page kept at +0x3cc, and the slots of that page
# shown, every other slot hidden. A tab click reaches it through 0x6b45b0,
# which finds the clicked tab by its ID. An expansion (0x6b7020, the new size
# from the size-change packet at 0x8a759c, again less 13) adds the new pages'
# tabs and slots and re-selects the current page.
#
# Here the lattice's 32 cells are the page's 32 slots: cell i shows bag slot
# page * 32 + i. The server's bag slots start at 0 (it keeps the equipment
# apart), so bag slot n is the client's slot 13 + n.
const BAG_PAGE_SLOTS := 32
## The client's own ceiling (the assert above): three pages, 96 slots.
const BAG_MAX_PAGES := 3
## The slot icon's rect inside its lattice cell (the slot's 32x32 at the
## cell's top-left, above).
const BAG_SLOT_ICON := Rect2(0, 0, 32, 32)
## The locked slot's art (0x6b6e2a).
const BAG_BLOCK_DDJ := "interface\\pet\\pt_block.ddj"
## The page tabs, READ from 0x6b6620 (0x6b6a1a..0x6b6b65): ID, rect relative
## to the pane (x, y, w, h), the selected and unselected art (0x64ce30 stores
## its first texture as the selected one, +0x380, and its second as the
## unselected, +0x384), and the caption's text key. The first tab is the wide
## `com_tab`, the other two `com_short_tab`.
const BAG_TABS := [
	{"id": 0x50, "rect": Rect2(4, -23, 60, 24), "on": "interface\\ifcommon\\com_tab_on.ddj",
		"off": "interface\\ifcommon\\com_tab_off.ddj", "text": "UIIT_CTL_BELOINGING"},
	{"id": 0x51, "rect": Rect2(64, -23, 56, 24), "on": "interface\\ifcommon\\com_short_tab_on.ddj",
		"off": "interface\\ifcommon\\com_short_tab_off.ddj", "text": "UIIT_STT_INVENTORY_EXTENSION_TEB"},
	{"id": 0x52, "rect": Rect2(118, -23, 57, 24), "on": "interface\\ifcommon\\com_short_tab_on.ddj",
		"off": "interface\\ifcommon\\com_short_tab_off.ddj", "text": "UIIT_STT_INVENTORY_EXTENSION_TEB2"},
]
## Each tab's caption when the text table cannot resolve its key (the three
## keys' English, from the archive's textuisystem.txt, are what a real
## archive resolves to).
const BAG_TAB_FALLBACK := ["Page 1", "Page 2", "Page 3"]
const BAG_TABS_NODE := "BagPageTabs"

## The bag's size in slots as the server last sent it (the trailing capacity
## of the bag list); 0 until one arrives. With none -- an older server --
## the grid shows all three pages and locks nothing (OURS: a slot the server
## may use is never hidden behind a lock the client guessed).
var _bag_size := 0
## The page shown, 0-based (+0x3cc). Kept across closing and opening the
## window, as the client keeps it.
var _bag_page := 0
## The bag as the server last sent it, redrawn on a page change.
var _bag_slots: Array = []

## The number of pages a bag of `size` slots has (0x6b6620's arithmetic).
static func bag_pages(size: int) -> int:
	if size <= 1:
		return 1
	return mini(((size - 1) >> 5) + 1, BAG_MAX_PAGES)

func _bag_size_shown() -> int:
	return _bag_size if _bag_size > 0 else BAG_PAGE_SLOTS * BAG_MAX_PAGES

## The page shown (a test hook and the QA log).
func bag_page() -> int:
	return _bag_page

## The bag's size as the grid draws it.
func bag_size() -> int:
	return _bag_size

## Sets the bag's size: the tabs are rebuilt for the new page count and the
## page kept (0x6b7020 re-selects +0x3cc). A page the new size no longer has
## falls back to the last one (OURS: the client only ever grows the bag).
func set_bag_size(size: int) -> void:
	_bag_size = maxi(size, 0)
	var pages := bag_pages(_bag_size_shown())
	if _bag_page >= pages:
		_bag_page = pages - 1
	_build_bag_tabs()
	_draw_bag_page()

## Builds the page tabs on the inventory pane: one per page, the shown one
## selected. READ (0x6b6bff..0x6b6c7d): a tab's ClientRect is empty, its font
## index 0 (0xba5460(0)), its text centred both ways (slots 0x14 and 0x18
## with 1). Its text colour is never set there, so it is the text board's
## default -- INFERRED white, which the tabs of the retail screenshot show.
## A selected tab also sets the text flag 2 (0x64cc30 -> 0x8b44b0(0, 2)),
## which switches the glyph mode (0x8b39e0); what that mode draws is not
## read, so nothing here changes with it (OPEN).
func _build_bag_tabs() -> void:
	var window: HudWindow = _windows.get("inventory")
	if window == null:
		return
	var pane := window.node("GDR_INVENTORY") as Control
	if pane == null:
		return
	var old := pane.get_node_or_null(BAG_TABS_NODE)
	if old != null:
		pane.remove_child(old)
		old.queue_free()
	var strip := Control.new()
	strip.name = BAG_TABS_NODE
	strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pane.add_child(strip)
	for i in range(bag_pages(_bag_size_shown())):
		var spec: Dictionary = BAG_TABS[i]
		var rect: Rect2 = spec["rect"]
		var tab := TextureButton.new()
		tab.name = "BagTab%d" % i
		tab.set_meta("ctrl_id", int(spec["id"]))
		tab.set_meta("tex_on", _builder.load_texture(spec["on"]) if _builder != null else null)
		tab.set_meta("tex_off", _builder.load_texture(spec["off"]) if _builder != null else null)
		tab.ignore_texture_size = true
		tab.stretch_mode = TextureButton.STRETCH_SCALE
		tab.focus_mode = Control.FOCUS_NONE
		# READ: CIFSelectableArea acts on the press (0x64cb80 answers message
		# 0x201, WM_LBUTTONDOWN), not the release.
		tab.action_mode = BaseButton.ACTION_MODE_BUTTON_PRESS
		tab.position = rect.position
		tab.size = rect.size
		tab.custom_minimum_size = rect.size
		var page := i
		tab.pressed.connect(func() -> void: select_bag_page(page))
		var caption := Label.new()
		caption.name = "Text"
		var key: String = spec["text"]
		var text := _builder.resolve_text(key) if _builder != null else key
		caption.text = BAG_TAB_FALLBACK[i] if text == "" or text == key else text
		caption.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		caption.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
		caption.clip_text = false
		if _builder != null:
			var font := _builder.font_at(0)
			if font != null:
				caption.add_theme_font_override("font", font)
		caption.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[0])
		tab.add_child(caption)
		strip.add_child(tab)
	_show_selected_bag_tab()

func _show_selected_bag_tab() -> void:
	var window: HudWindow = _windows.get("inventory")
	var strip := window.node(BAG_TABS_NODE) as Control if window != null else null
	if strip == null:
		return
	for tab in strip.get_children():
		var button := tab as TextureButton
		if button == null:
			continue
		var selected := button.name == "BagTab%d" % _bag_page
		button.texture_normal = button.get_meta("tex_on" if selected else "tex_off")

## 0x6b3d00: shows `page`'s 32 slots and selects its tab.
func select_bag_page(page: int) -> void:
	if page < 0 or page >= bag_pages(_bag_size_shown()):
		return
	_bag_page = page
	_show_selected_bag_tab()
	_draw_bag_page()
	print("HudPanels: bag page %d of %d (size %d)" % [page + 1, bag_pages(_bag_size_shown()), _bag_size])

## Fills the inventory window's authored slot grid with the icons of what
## the character is carrying: the shown page's 32 slots (see above).
##
## This is the authored presentation rather than the plain list: the grid is
## GDR_INVENTORY_LATTICE, which UiBuilder already builds as one Control per
## cell, each with a named "ItemIcon" child.
func _fill_inventory_grid(slots: Array) -> void:
	_bag_slots = slots
	if item_chest != null and item_chest.is_open():
		item_chest.refresh_inventory()
	# Round 768: the alchemy window's copies follow the bag.
	if alchemy_window() != null:
		_alchemy.bag_changed(alchemy_item)
	# A held bag item whose slot no longer holds it (spent, moved, sold by
	# another path): let go rather than drop from a slot that changed.
	if held_icon != null and held_icon.kind() == "bag" \
			and _bag_item_id_at_slot(int(held_icon.payload.get("slot", -1))) != int(held_icon.payload.get("item_id", -2)):
		cancel_held_icon("its bag slot changed")
	var capacity := int(NetClient.last_inventory_capacity) if NetClient != null else 0
	if capacity > 0 and capacity != _bag_size:
		set_bag_size(capacity)
		return
	_draw_bag_page()

func _draw_bag_page() -> void:
	var window: HudWindow = _windows.get("inventory")
	if window == null:
		return
	var grid := window.node("GDR_INVENTORY_LATTICE") as Control
	if grid == null:
		return
	var base := _bag_page * BAG_PAGE_SLOTS
	var size := _bag_size_shown()
	var block: Texture2D = null
	for i in range(grid.get_child_count()):
		var cell := grid.get_child(i)
		var icon := cell.get_node_or_null("ItemIcon") as TextureRect
		var locked := base + i >= size
		if icon != null:
			_place_bag_icon(icon)
			icon.texture = null
			_set_item_tip(icon, -1)
			_set_item_seal_edge(icon, -1)
			icon.modulate = Color.WHITE
			DurabilityMark.apply(icon, DurabilityMark.State.NONE, null, null)
			icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_exchange_dim(cell, false)
			for m in ["inv_slot", "inv_item_id", "inv_qty"]:
				if icon.has_meta(m):
					icon.remove_meta(m)
			if locked:
				if block == null and _builder != null:
					block = _builder.load_texture(BAG_BLOCK_DDJ)
				icon.texture = block
			icon.set_meta("inv_locked", locked)
		var count := cell.get_node_or_null("CountLabel") as Label
		if count != null:
			_place_bag_icon(count)
			count.text = ""
	var durability := _durability_map(NetClient.last_inventory_durabilities)
	var cells := grid.get_child_count()
	for entry in _bag_slots:
		var slot_field = _first_field(entry, ["slot", "slot_index", "index"])
		var index := int(slot_field) if slot_field != null else -1
		var cell_index := index - base
		if index < 0 or index >= size or cell_index < 0 or cell_index >= cells:
			continue
		var cell := grid.get_child(cell_index)
		var item_id = _first_field(entry, ["item_id", "id"])
		if item_id == null:
			continue
		var quantity = _first_field(entry, COUNT_FIELDS)
		var qty: int = int(quantity) if quantity != null else 1
		var icon := cell.get_node_or_null("ItemIcon") as TextureRect
		if icon != null:
			icon.texture = _item_icon(int(item_id))
			_set_item_seal_edge(icon, int(item_id))
			# The hover tooltip (round 731, _set_item_tip). STOP so the
			# hover registers; the cell behind it still takes clicks.
			var dur: Array = durability.get(index, [])
			if dur.size() == 2:
				_set_item_tip(icon, int(item_id), "bag", index, dur[0], dur[1])
				# Round 829: a worn-out item's mark over the icon, which is
				# never darkened (DurabilityMark, READ 0x67dfb8..; the grey
				# that stood here was ours).
				_mark_durability(icon, int(item_id), dur[0], dur[1])
			else:
				_set_item_tip(icon, int(item_id), "bag", index)
				icon.modulate = Color.WHITE
			icon.mouse_filter = Control.MOUSE_FILTER_STOP
			# Round 834: an item offered to the exchange is drawn dimmed
			# (0x6b3f00(slot, 0), EXCHANGE_DIM).
			_exchange_dim(cell, exchange_offered(index))
			# The slot's identity, so a click can sell it while a shop is open.
			icon.set_meta("inv_slot", index)
			icon.set_meta("inv_item_id", int(item_id))
			icon.set_meta("inv_qty", qty)
			# The slot the held icon came from stays dimmed across a page turn.
			if held_icon != null and held_icon.kind() == "bag" and int(held_icon.payload.get("slot", -1)) == index:
				held_icon.retarget_source(icon)
				_watch_held_source(icon)
			if not icon.has_meta("inv_click_wired"):
				icon.set_meta("inv_click_wired", true)
				icon.gui_input.connect(func(ev: InputEvent) -> void: _on_inventory_cell_input(ev, icon))
		var count_label := cell.get_node_or_null("CountLabel") as Label
		if count_label != null and _shows_count(int(item_id), qty):
			count_label.text = str(qty)

## Whether a bag-type slot shows this stack's count (round 728): the original
## draws it for an expendable, a stack of 1 included (ItemCountLabel.shows_count,
## READ FUN_00680da0). An item the table does not know falls back to the old
## rule, a stack of two or more (OURS).
func _shows_count(item_id: int, qty: int) -> bool:
	return shows_count(item_id, qty)

## Whether a quick slot on the bar draws this stack's count (round 786,
## HudUnderbar.item_counts), READ: 0x680da0's quick-slot case (kind 0x0c,
## an item 0x46) tests the same type word as the bag, `0x538410` (not
## bionic, TypeID1 3, TypeID2 3), and a non-zero stack; and the slot's
## +0x679, which `vslot_013` (0x685e50 -> 0x67bd70) needs too, is set by
## the SetItem every bar item goes through (0x60c430 -> 0x6871d0) to
## `max stack > 1` (`cmp [ref+0x1c0], 1; setg` at 0x6875cd..0x6875d7; ref
## +0x1c0 the max stack, round 726's reading of 0x68a6c0). An item the table
## does not know falls back to a stack of two or more (OURS).
func bar_shows_count(item_id: int, qty: int) -> bool:
	_load_items()
	var item: ItemTableReader.Item = _items.get(item_id)
	if item == null:
		return qty > 1
	return ItemCountLabel.shows_on_bar(Array(item.type_ids), item.bionic != 0, item.max_stack, qty)

## The bag's rule (round 728), public.
func shows_count(item_id: int, qty: int) -> bool:
	_load_items()
	var item: ItemTableReader.Item = _items.get(item_id)
	if item == null:
		return qty > 1
	return ItemCountLabel.shows_count(Array(item.type_ids), item.bionic != 0, qty)

## Puts a bag cell's icon (or count) on the slot's 32x32 at the cell's
## top-left (BAG_SLOT_ICON), where the client's slot sits.
static func _place_bag_icon(node: Control) -> void:
	node.set_anchors_preset(Control.PRESET_TOP_LEFT)
	node.position = BAG_SLOT_ICON.position
	node.size = BAG_SLOT_ICON.size

## A click on an inventory item. LEFT (released, no Ctrl/Shift/Alt): pick it
## up onto the cursor -- the next click puts it down (HeldIcon, round 652).
## That holds with a store or the warehouse open too: retail's pick-up
## (0x652540) does not look at them; the bag item is SOLD by putting it down
## on the store window and DEPOSITED by putting it down on the warehouse.
## RIGHT: use it, which is what a potion is for; the server decides whether
## the item is usable at all, so a right-click on a sword is simply refused.
func _on_inventory_cell_input(event: InputEvent, icon: TextureRect) -> void:
	if not (event is InputEventMouseButton):
		return
	if not (icon.has_meta("inv_slot") and icon.has_meta("inv_item_id")):
		return
	var mb := event as InputEventMouseButton
	var slot := int(icon.get_meta("inv_slot"))
	var item_id := int(icon.get_meta("inv_item_id"))
	var qty := int(icon.get_meta("inv_qty"))
	# Round 829: under the store's hammer a left click repairs the item.
	if _repair_mode and mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
		_repair_click("bag", slot)
		return
	# Used on the right RELEASE, over the slot: CIFSlotWithHelp's right press
	# (vslot 32, 0x6665b0) only captures the mouse and its release (vslot 33,
	# 0x685ee0) uses (READ) -- the same as the quick slots.
	if mb.button_index == MOUSE_BUTTON_RIGHT and not mb.pressed \
			and (not icon.is_inside_tree() or icon.get_global_rect().has_point(mb.global_position)):
		if player_dead:
			system_notice.emit(DEAD_INPUT_LINE)
			return
		if is_global_chat_item(item_types(item_id)):
			global_chat_requested.emit(slot, qty)
			return
		# Round 778: a reverse return scroll opens its box instead of being
		# used (IFSlotWithHelp::FUN_00676570, case 3 -> message box 0x21).
		if is_reverse_return_scroll(item_types(item_id)):
			open_reverse_return_box(slot)
			return
		# Round 824: a crest item opens its box (IFSlotWithHelp::FUN_00676570,
		# 0x676dcb..0x676efe: by code name, boxes 0x15 / 0x16 / 0x18 / 0x19).
		var crest_kind := int(CREST_ITEM_BOXES.get(item_code_for_id(item_id), 0))
		if crest_kind != 0:
			open_crest_box(slot, crest_kind)
			return
		# Round 805: a pet's potion, food or cure names the current COS.
		if is_cos_target_item(item_types(item_id)):
			cos_item_requested.emit(slot)
			return
		# Round 838: the repair hammer asks first (open_hammer_confirm).
		if is_repair_hammer(item_types(item_id)):
			open_hammer_confirm(slot)
			return
		if NetClient.current_character_name != "":
			UiSounds.expect_use(item_types(item_id))
			NetClient.use_item(NetClient.current_character_name, slot)
		return
	# Round 726: Ctrl+click sells with no box while the store is open
	# (_ctrl_sell).
	if _is_ctrl_click_on(event, icon) and _window_shown("store") \
			and (held_icon == null or not held_icon.is_holding()):
		_ctrl_sell(slot, qty)
		return
	# Round 728: Shift+click splits a stack (_open_split).
	if _is_shift_click_on(event, icon) and (held_icon == null or not held_icon.is_holding()):
		_open_split(slot, item_id, qty)
		return
	# Round 834: an offered item's slot is disabled (0x6b3f00): no clicks.
	if exchange_offered(slot):
		return
	# Round 834: Alt+click offers it to the exchange (c:0x681b7a -> the
	# window's vslot 0x70).
	if _is_alt_click_on(event, icon) and exchange_mode() and (held_icon == null or not held_icon.is_holding()):
		exchange.offer_from_bag(slot, item_id, qty)
		return
	# Round 768: Alt+click puts the item in the alchemy window while it is
	# open (CIFSlotWithHelp::vslot_029 0x680fa0: GetKeyState(VK_MENU) at
	# 0x681912, a bag slot -> the alchemy pane's vslot 0x70, READ).
	if _is_alt_click_on(event, icon) and alchemy_window() != null \
			and (held_icon == null or not held_icon.is_holding()):
		_alchemy_offer(slot)
		return
	if _is_pick_click_on(event, icon):
		pick_up_icon({"kind": "bag", "slot": slot, "item_id": item_id, "qty": qty, "icon": icon.texture},
			icon.texture, icon, mb.global_position)

## Whether an event is a left click released with Alt held (no Ctrl or
## Shift) over `control` (round 768, 0x681912).
func _is_alt_click_on(event: InputEvent, control: Control) -> bool:
	if not (event is InputEventMouseButton):
		return false
	var mb := event as InputEventMouseButton
	return mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed and mb.alt_pressed \
		and not mb.ctrl_pressed and not mb.shift_pressed and control != null \
		and (not control.is_inside_tree() or control.get_global_rect().has_point(mb.global_position))

## Whether an event is a left click released with Shift held (no Ctrl or
## Alt) over `control`: the original's Shift+click on a slot (0x681903).
func _is_shift_click_on(event: InputEvent, control: Control) -> bool:
	if not (event is InputEventMouseButton):
		return false
	var mb := event as InputEventMouseButton
	return mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed and mb.shift_pressed \
		and not mb.ctrl_pressed and not mb.alt_pressed and control != null \
		and (not control.is_inside_tree() or control.get_global_rect().has_point(mb.global_position))

## The split box (round 728): CIFMessageBox mode 5, MsgBoxDivideCount, the
## inventory's one box (+0x390), for a stackable item of more than one
## (0x6b3fa0, READ; StoreMessageBox._build_divide). OK moves the typed count
## into the bag's first empty slot (the 0x8076 owner, READ); none free, or a
## count of 0, sends nothing (c:0x6b62d0 sends only on the 1 flag, READ).
## Sent as the retail 0x7034 type 0 (ItemOpNet).
func _open_split(slot: int, item_id: int, qty: int) -> void:
	_load_items()
	var item: ItemTableReader.Item = _items.get(item_id)
	if item == null or not is_stack_item(item) or qty <= 1:
		return
	_open_store_box("inventory", "SplitConfirm", StoreMessageBox.Kind.DIVIDE, {
		"icon": _item_icon(item_id), "name": item.display_name(_object_names),
		"stack": qty, "count": 1, "min": 0, "max": qty - 1,
	}, func(q: int) -> void:
		if q < 1 or not _bag_slot_still_holds(slot, item_id, q + 1, "split"):
			return
		var to := first_empty_bag_slot()
		if to < 0:
			print("HudPanels: split not sent -- no empty bag slot")
			return
		if NetClient.is_connected_to_server():
			print("HudPanels: split %d off bag slot %d into slot %d" % [q, slot, to])
			NetClient.split_item(slot, to, q))

## The bag's first empty slot (the open pages' order), or -1.
func first_empty_bag_slot() -> int:
	var taken := {}
	for entry in _bag_slots:
		var index = _first_field(entry, ["slot", "slot_index", "index"])
		if index != null:
			taken[int(index)] = true
	for s in range(_bag_size_shown()):
		if not taken.has(s):
			return s
	return -1

## Whether `event` is the click that picks `control`'s icon up: a plain left
## release (HeldIcon.is_pick_click, READ) that is still over the control --
## Godot hands a release to the control the press was on, and a release
## somewhere else is not a click on this slot (retail's slots take no press
## at all, so there is no dragging one away; INFERRED).
func _is_pick_click_on(event: InputEvent, control: Control) -> bool:
	return HeldIcon.is_pick_click(event) and control != null \
		and control.get_global_rect().has_point((event as InputEventMouseButton).global_position)

# --- The held icon (round 652) ------------------------------------------------
#
# Retail's icons are clicked up and clicked down, never dragged: see
# held_icon.gd. The controller swallows the clicks while it holds something;
# this is where they are routed. The server owns every outcome: a bag drop is
# OP_MOVE (move / merge / swap), a doll drop OP_EQUIP (a swap when the slot is
# filled, refused for the wrong kind of item), a worn item dropped on the bag
# OP_UNEQUIP naming the clicked slot (the server, like retail's, puts it in
# the first free slot), and the windows redraw from what it answers, never
# from what the drop assumed.

func _input(event: InputEvent) -> void:
	# Before anything else, and without consuming the press (see the function).
	release_text_focus_on_press(event)
	if held_icon != null and held_icon.handle(event):
		get_viewport().set_input_as_handled()
		return
	if _qa_slots and event is InputEventKey \
			and (event as InputEventKey).pressed and not (event as InputEventKey).echo \
			and (event as InputEventKey).keycode == KEY_F11:
		# QA only: Shift+F11 opens the warehouse (no NPC walk in a run),
		# F11 prints where every slot is, for xdotool to click.
		if (event as InputEventKey).shift_pressed:
			open_storage("Warehouse Keeper")
		get_tree().call_group(QA_SLOTS_GROUP, "qa_print_slots")
		get_viewport().set_input_as_handled()

## Whether a left click at `at` goes to the control under it rather than to
## the held icon: a button, or the bag's page tabs. READ: 0x6523d0 lets a
## press over a CIFButton (0xee9828) or a CIFSelectableArea (0xee96c0, the
## tabs) through, and a release over one too -- which is how retail carries an
## item to another page of the bag: turn the page, then click the slot.
func _click_passes_through(at: Vector2) -> bool:
	var win := _topmost_window_at(at)
	if win != null:
		return _button_under(win, at)
	for extra in click_pass_through:
		if extra.is_valid() and bool(extra.call(at)):
			return true
	return false

func _button_under(node: Node, at: Vector2) -> bool:
	for child in node.get_children():
		if child is CanvasItem and not (child as CanvasItem).visible:
			continue
		if child is BaseButton and (child as Control).get_global_rect().has_point(at) \
				and not (child as BaseButton).disabled:
			return true
		if _button_under(child, at):
			return true
	return false

## The frontmost open window under a global point, or null. Windows overlap
## (the warehouse opens over the store), and a click belongs to the one drawn
## on top: the windows are siblings under these panels, so the later child
## (move_to_front) is in front.
func _topmost_window_at(at: Vector2) -> HudWindow:
	var best: HudWindow = null
	for id in _windows:
		var win: HudWindow = _windows[id]
		if win == null or not win.is_visible_in_tree() or not win.get_global_rect().has_point(at):
			continue
		if best == null or _drawn_above(win, best):
			best = win
	return best

static func _drawn_above(a: Control, b: Control) -> bool:
	if a.z_index != b.z_index:
		return a.z_index > b.z_index
	if a.get_parent() == b.get_parent():
		return a.get_index() > b.get_index()
	return false

## Whether a global point is over any open window of these panels.
func _over_any_window(at: Vector2) -> bool:
	return _topmost_window_at(at) != null

## Whether `panel_id`'s window is the frontmost one under a global point.
func _over_window(panel_id: String, at: Vector2) -> bool:
	var win: HudWindow = _windows.get(panel_id)
	return win != null and win == _topmost_window_at(at)

## Whether a window is on screen (the store or the warehouse a held item
## came from may have been closed under it).
func _window_shown(panel_id: String) -> bool:
	var win: HudWindow = _windows.get(panel_id)
	return win != null and win.is_visible_in_tree()

## The held icon was put down at `at`: act on what is under it -- in the
## frontmost window there. Each case names the retail drop handler it follows.
func _on_held_dropped(what: Dictionary, at: Vector2) -> void:
	var k := String(what.get("kind", ""))
	var from := int(what.get("slot", -1))
	var item_id := int(what.get("item_id", -1))
	var qty := int(what.get("qty", 1))
	var on_bag := _over_inventory_window(at)
	if k == "bag" and AvatarEquipment.is_avatar_item(bag_item_types(from)):
		print("HudPanels: avatar put down at %s: on_bag=%s bag_cell=%d equipment_pane=%s" % [at, on_bag,
			_bag_slot_at(at), _over_equipment_pane(at)])
	# Round 795: the COS window's own held icons (HudCos: a pet-bag slot, a
	# command) are World3D's to place -- on the inventory, the pet bag, a
	# quick slot.
	if k == "cos_bag" or k == "cos_command":
		held_dropped_outside.emit(what, at)
		return
	match k:
		"bag":
			# CIFInventory::vslot_028 (0x6b5b80) for a bag or doll target,
			# the store's and the warehouse's for theirs. Round 768: put down
			# on the alchemy window, it is offered to it (the held slot goes
			# to the window under the cursor's vslot 28 -> CNIFAlchemyWnd
			# 0x59dca0, READ); the bag keeps it.
			if _over_alchemy(at, on_bag):
				_alchemy_offer(from)
			elif _over_grant_window(at):
				# Round 789: the grant window takes a bag item (READ
				# CIFGrantMagicAttributeWnd::vslot_028 c:0x80a320, source kind
				# 0x46 only).
				_grant_offer(from)
			elif on_bag and _bag_slot_at(at) < 0 and (_over_equipment_pane(at) or _equipment_slot_at(at) >= 0):
				# Round 829: put down anywhere on the equipment window -- a
				# worn slot or the character picture -- the item goes where
				# its TypeIDs say (EquipTarget, READ CIFEquipment::vslot_028
				# 0x6ad180: the hovered slot is not looked at); round 789's
				# avatars through the same handler.
				equip_from_bag(from)
			elif on_bag and (_bag_slot_at(at) >= 0 or _equipment_slot_at(at) >= 0):
				_dropping_item_id = item_id
				_drop_bag_item(from, at)
				_dropping_item_id = -1
			elif _over_window("store", at):
				_confirm_sell(from, item_id, qty)       # 0x46 -> 0x0f: type 9, sell
			elif _over_window("storage", at):
				_confirm_deposit(from, item_id, qty)    # 0x46 -> 0x13: type 2
			elif _over_window("exchange", at) and exchange_mode():
				_exchange().offer_from_bag(from, item_id, qty)   # 0x46 -> 0x1a: type 4
			elif not _over_any_window(at):
				held_dropped_outside.emit(what, at)     # a quick slot, or the ground (OPEN)
		"exchange":
			# Round 834: an own exchange slot put down on the bag (0x1a ->
			# 0x46, CIFInventory::vslot_028 c:0x6b5b80): type 5.
			if on_bag and exchange_mode():
				exchange.remove_index(int(what.get("index", -1)), false)
		"worn":
			if on_bag:
				_drop_worn_item(from, at)
			elif not _over_any_window(at):
				held_dropped_outside.emit(what, at)
		"avatar":
			# Round 789: only back to the bag (no other move takes the avatar
			# inventory, kind 0x4e: READ c:0x7950b0, c:0x871940).
			if on_bag:
				_drop_avatar_to_bag(from, at)
		"storage":
			# 0x13 -> 0x46 (type 3). The retail packet names the bag slot;
			# ours has no field for it, so the server places it (OPEN).
			if on_bag and _window_shown("storage"):
				_confirm_withdraw(from, item_id, qty)
		"shop":
			# 0x0f -> 0x46 (type 8): the retail packet carries no bag slot
			# (FUN_007950b0 case 0x0f sets none), so the server places it.
			if on_bag and _window_shown("store"):
				_confirm_buy(item_id)
		"buyback":
			# Round 728: a buy-back slot (source kind 0x45) put down on the
			# bag: CIFInventory::vslot_028 0x6b5b80 -> 0x6b0520 (READ).
			if on_bag and _window_shown("store"):
				_confirm_buyback(int(what.get("index", -1)), item_id)
		"skill", "action":
			# An action's icon goes where a skill's does: the quick slot bar
			# takes kind 0x4a (CIFUnderBar::vslot_028, round 781).
			if not _over_any_window(at):
				held_dropped_outside.emit(what, at)
		"quickslot":
			held_dropped_outside.emit(what, at)

## A worn item put down. On a bag cell: taken off, the clicked slot sent as
## retail's client sends it (FUN_007950b0, `bag slot + 13`); the server puts
## the item in the first free slot anyway, as retail's DetachEquipItem does
## (0x5258c6, READ -- round 652, the user chose the original's rule; see
## equipment/placement.go). Elsewhere over the bag window: taken off with no
## slot named (OURS, the playtest 2026-09-20 fix: a click a few pixels into a
## gutter still takes it off). Back on the doll, or outside the window: nothing.
func _drop_worn_item(worn_slot: int, at: Vector2) -> void:
	var who := NetClient.current_character_name
	if who == "" or not NetClient.is_connected_to_server():
		return
	# Round 829: the equipment window takes only a bag item (CIFEquipment::
	# vslot_028 0x6ad180 puts anything else back): a worn item put down on a
	# worn slot or the character picture stays worn.
	if _equipment_slot_at(at) >= 0 or _over_equipment_pane(at):
		return
	var to := _bag_slot_at(at)
	if to < 0 and not _over_inventory_window(at):
		return
	UiSounds.expect_move(worn_item_types(worn_slot), "unequipped (equipment -> bag)")
	print("HudPanels: unequip worn slot %d into bag slot %d" % [worn_slot, to])
	NetClient.unequip(who, worn_slot, to)
	NetClient.list_inventory(who)

## Whether a global point is over the open inventory window, in front of
## any other window there.
func _over_inventory_window(at: Vector2) -> bool:
	var win: HudWindow = _windows.get("inventory")
	if win == null or not is_open("inventory"):
		return false
	return win == _topmost_window_at(at)

## Which bag cell (its slot index) is under a screen point, or -1. Cells are
## GDR_INVENTORY_LATTICE's children in slot order on the shown page, the same
## indexing _draw_bag_page draws by.
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
			# The shown page's slot; a locked one takes nothing (0xb8f540(0)).
			var slot := _bag_page * BAG_PAGE_SLOTS + i
			return -1 if slot >= _bag_size_shown() else slot
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

## The item id a bag drop from `from` carries: the one it was picked up with
## (it may have come from another page), else the bag list's.
var _dropping_item_id := -1
func _bag_drag_item_id_or(from: int) -> int:
	return _dropping_item_id if _dropping_item_id > 0 else _bag_item_id_at_slot(from)

## Resolves where a bag item was put down and asks the server for it.
func _drop_bag_item(from: int, at: Vector2) -> void:
	var who := NetClient.current_character_name
	if who == "" or not NetClient.is_connected_to_server():
		return
	var to := _bag_slot_at(at)
	if to >= 0:
		# The same slot sends nothing (FUN_007950b0's src != dst test).
		if to != from:
			UiSounds.expect_move(bag_item_types(from), "moved in the bag")
			NetClient.move_item(who, from, to)
		return
	if _equipment_slot_at(at) >= 0:
		# Round 829: whichever worn slot it was put on, the item's own
		# (equip_from_bag).
		equip_from_bag(from)
		return
	# Neither a bag slot nor the doll: offer it to the quickslot bar, which
	# World3D owns. It ignores a release that is not over a slot.
	var item_id := _bag_drag_item_id_or(from)
	var icon := _item_icon(item_id) if item_id >= 0 else null
	item_drop_requested.emit(at, item_id, from, icon)

## QA only (OPENSRO_QA_SLOTS): where every slot of the open windows is, so a
## live run can click them with xdotool (HudUnderbar prints the bar's).
const QA_SLOTS_GROUP := "qa_slots"
func qa_print_slots() -> void:
	var inv: HudWindow = _windows.get("inventory")
	if inv != null and is_open("inventory"):
		var grid := inv.node("GDR_INVENTORY_LATTICE") as Control
		if grid != null:
			for i in range(grid.get_child_count()):
				var cell := grid.get_child(i) as Control
				var slot := _bag_page * BAG_PAGE_SLOTS + i
				if cell != null and cell.is_visible_in_tree() and slot < _bag_size_shown():
					print("QA SLOT bag:%d at %s item %d" % [slot, _qa_xy(cell), _bag_item_id_at_slot(slot)])
		# Round 728: every stack's count, so a live run reads a split.
		var said := PackedStringArray()
		for entry in _bag_slots:
			var index = _first_field(entry, ["slot", "slot_index", "index"])
			var id = _first_field(entry, ["item_id", "id"])
			var n = _first_field(entry, COUNT_FIELDS)
			said.append("%s=%s x%s" % [str(index), str(id), str(n)])
		print("QA BAG %s" % " ".join(said))
		for i in range(17):
			var ws := inv.node("GDR_EQUIPMENT_SLOT_%d" % (EQUIPMENT_SLOT_BASE + i)) as Control
			if ws != null and ws.is_visible_in_tree():
				print("QA SLOT worn:%d at %s" % [i, _qa_xy(ws)])
	for id in _windows:
		var win: HudWindow = _windows[id]
		if win != null and win.is_visible_in_tree():
			print("QA SLOT window:%s at %s rect %s" % [id, _qa_xy(win), str(win.get_global_rect())])
			for icon in win.find_children("ItemIcon", "TextureRect", true, false):
				var tr := icon as TextureRect
				if tr.texture == null or not tr.is_visible_in_tree():
					continue
				if tr.has_meta("wh_slot"):
					print("QA SLOT storage:%d at %s item %d" % [int(tr.get_meta("wh_slot")), _qa_xy(tr), int(tr.get_meta("wh_item_id"))])
				elif tr.has_meta("buyback_index"):
					print("QA SLOT buyback:%d at %s" % [int(tr.get_meta("buyback_index")), _qa_xy(tr)])
				elif tr.has_meta("shop_item_id"):
					print("QA SLOT shop:%s at %s item %d" % [tr.get_parent().name, _qa_xy(tr), int(tr.get_meta("shop_item_id"))])
			for b in win.find_children("*", "BaseButton", true, false):
				var btn := b as BaseButton
				if btn.is_visible_in_tree() and btn is Button and (btn as Button).text != "":
					print("QA SLOT button:%s at %s" % [(btn as Button).text, _qa_xy(btn)])
				elif btn.is_visible_in_tree() and btn.get_node_or_null("ButtonLabel") is Label \
						and (btn.get_node("ButtonLabel") as Label).text != "":
					# The client's own buttons (round 726: the confirm boxes).
					print("QA SLOT button:%s at %s" % [(btn.get_node("ButtonLabel") as Label).text, _qa_xy(btn)])
			for money in ["GDR_INVENTORY_BTN_MONEY", "GDR_STORAGE_BTN_MONEY"]:
				var mb := win.find_child(money, true, false) as Control
				if mb != null and mb.is_visible_in_tree():
					print("QA SLOT money:%s at %s" % [id, _qa_xy(mb)])
			# Round 726: every open confirm box's controls, relative to the box,
			# so a live run measures the built geometry.
			for box in win.find_children("*", "StoreMessageBox", true, false):
				var bc := box as Control
				if not bc.is_visible_in_tree():
					continue
				print("QA BOX %s rect %s" % [bc.name, str(bc.get_global_rect())])
				for c in bc.find_children("*", "Control", true, false):
					var cc := c as Control
					if cc.is_visible_in_tree() and (String(cc.name).begins_with("GDR_") or String(cc.name) in ["Title", "PriceRow"]):
						var r := cc.get_global_rect()
						var text := ""
						if cc is Label:
							text = (cc as Label).text
						elif cc is LineEdit:
							text = (cc as LineEdit).text
						elif cc.get_node_or_null("ButtonLabel") is Label:
							text = (cc.get_node("ButtonLabel") as Label).text
						print("QA BOX %s %s at %d,%d size %dx%d text '%s'" % [bc.name, cc.name,
							int(r.position.x - bc.global_position.x), int(r.position.y - bc.global_position.y),
							int(r.size.x), int(r.size.y), text])
	var skill: HudWindow = _windows.get("skill")
	if skill != null and skill.is_visible_in_tree():
		for c in skill.find_children("*", "TextureRect", true, false):
			if (c as Control).has_meta("qa_skill_id") and (c as Control).is_visible_in_tree():
				print("QA SLOT skill:%d at %s" % [int((c as Control).get_meta("qa_skill_id")), _qa_xy(c as Control)])

static func _qa_xy(c: Control) -> String:
	var p := c.get_global_rect().get_center().round()
	return "%d,%d" % [int(p.x), int(p.y)]

## The icon of the item in a bag slot, or null -- from the bag as the server
## last sent it, on any page (round 633's review: the cells only hold the
## shown page, so a drag carried to another page lost its item).
func _bag_icon_at_slot(slot: int) -> Texture2D:
	var id := _bag_item_id_at_slot(slot)
	return _item_icon(id) if id >= 0 else null

## The item id in a bag slot on any page, or -1: the server's last bag list
## (_bag_slots), not the lattice's cells.
## The shown page's cell holding `item_id`, or null (QA_INPUT's bagitem).
func _bag_cell_of_item(item_id: int) -> Control:
	var window: HudWindow = _windows.get("inventory")
	var grid := window.node("GDR_INVENTORY_LATTICE") as Control if window != null else null
	if grid == null:
		return null
	for i in range(grid.get_child_count()):
		if _bag_item_id_at_slot(_bag_page * BAG_PAGE_SLOTS + i) == item_id:
			return grid.get_child(i) as Control
	return null

## Round 824 (QA): the bag slot holding an item with code name `code`, or -1.
func bag_slot_of_code(code: String) -> int:
	for entry in _bag_slots:
		var index = _first_field(entry, ["slot", "slot_index", "index"])
		var item_id = _first_field(entry, ["item_id", "id"])
		if index != null and item_id != null and item_code_for_id(int(item_id)) == code:
			return int(index)
	return -1

func _bag_item_id_at_slot(slot: int) -> int:
	for entry in _bag_slots:
		var index = _first_field(entry, ["slot", "slot_index", "index"])
		if index != null and int(index) == slot:
			var item_id = _first_field(entry, ["item_id", "id"])
			return int(item_id) if item_id != null else -1
	return -1

## The server's answer to a move: the whole bag as it now stands, or the
## refusal. Drawn from the answer, so a refused move leaves the grid as it was.
func _on_inventory_move_result(slots: Array, error: String) -> void:
	UiSounds.move_replied(error == "")
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

## QA only (OPENSRO_QA_MOVE="from,to"): exercises a bag move end to end with
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
## icons resolve. Never used in real play -- driven by OPENSRO_QA_FAKEITEMS.
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
		if count != null and _shows_count(ids[i], qtys[i]):
			count.text = str(qtys[i])

## The worn items as last reported, so opening the equipment window fills
## its slots even if the list arrived while it was closed.
var _equipped_items: Array = []

## The masteries the window shows: the player's race's (round 691), from the
## whole table read once from the player's own Media.pk2 (_mastery_table).
var _masteries: Array = []
var _mastery_table: Array = []
var _masteries_loaded := false

## The player's race as the window lays it out: MasteryReader.RACE_CHINA until
## the server's OpSkillState names masteries of another race (the retail
## window lays out the server's own mastery list, FUN_006aa3e0 -- READ; the
## list is the race's, _AddNewChar), or set_skill_race says otherwise.
var _skill_race := MasteryReader.RACE_CHINA

var _masteries_race := -1

func _load_masteries() -> void:
	if not _masteries_loaded:
		_masteries_loaded = true
		var archive := _builder.media_archive() if _builder != null else null
		if archive != null:
			var entry := ObjectLoader.find_file(archive, MasteryReader.TABLE_PATH)
			if entry != null:
				_mastery_table = MasteryReader.parse_all(archive.read_file(entry))
	if _masteries_race == _skill_race:
		return
	_masteries_race = _skill_race
	_masteries = MasteryReader.for_race(_mastery_table, _skill_race)
	print("HudPanels: %d mastery(ies) for race %d (of %d read)" % [_masteries.size(), _skill_race, _mastery_table.size()])

## Lays the window out for `race` (MasteryReader.RACE_*): its masteries, its
## skill tables and its mastery total cap. A change of race resets the tab.
func set_skill_race(race: int) -> void:
	if race != MasteryReader.RACE_CHINA and race != MasteryReader.RACE_EUROPE:
		return
	if race == _skill_race:
		return
	_skill_race = race
	_skill_active_tab = 0
	_skill_active_mastery = 0
	if _masteries_loaded:
		_load_masteries()
	if _skill_catalog_loaded:
		_load_skill_catalog_for(race)

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

## Whether the server has told us this exact skill id is learned. World3D asks
## before putting a skill on a quickslot, so no path can shortcut a skill onto
## the hotbar that the character does not have (playtest 2026-09-20, item 3).
func is_skill_known(skill_id: int) -> bool:
	return _skill_known.has(skill_id)

## The mastery-total cap: the sum of a China character's mastery levels may reach
## 330, flat, whatever its level. Recovered from the server's Mastery_LevelUp
## (0x0059c4e0): for Country 0 (China) it refuses unless `sum + requested < 0x14b`;
## Europe's rule is min(240, 2 x level). Matches the server's
## session.MasteryTotalCapChina; docs/RE_COMPLETION.md, round 483. (It was
## "3 x level" before -- an extrapolation from a retail account, not a reading
## of the binary.)
const MASTERY_TOTAL_CAP := 330
const MASTERY_TOTAL_CAP_EUROPE := 240

## The total the window shows the mastery levels against, by race (round 691).
## READ from the client's own skill window, CIFSkill FUN_006aa3e0: it reads the
## player's ref-object race byte (+0x9c) and for 1 computes
## `fild [player+0x868] ; fadd st,st` -- twice the level -- and keeps it only
## below 0xf0 (240), else 240 (0x6aa474..0x6aa4a8); for 0 it uses 0x14a (330)
## (0x6aa4ba..0x6aa4c3); then prints "%d/%d". The server's rule is the same
## (masteryTotalRefusal). A level of 0 (not reported yet) gives Europe 0.
static func mastery_total_cap(race: int, char_level: int) -> int:
	if race == MasteryReader.RACE_EUROPE:
		return mini(MASTERY_TOTAL_CAP_EUROPE, 2 * maxi(char_level, 0))
	return MASTERY_TOTAL_CAP

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

## The skill-name table (textdata_equip&skill.txt), read once and shared: the
## skill window and the buff bar's tooltip (round 618) both resolve through
## it. Null without an archive or the file.
var _skill_names_loaded := false
func skill_names_table() -> UiTextTable:
	if _skill_names_loaded:
		return _skill_names
	_skill_names_loaded = true
	var archive := _builder.media_archive() if _builder != null else null
	if archive == null:
		return null
	var names_entry := ObjectLoader.find_file(archive, SKILL_NAME_TABLE_PATH)
	if names_entry != null:
		_skill_names = UiTextTable.parse(archive.read_file(names_entry))
		print("HudPanels: skill names read from %s" % SKILL_NAME_TABLE_PATH.get_file())
	else:
		print("HudPanels: no %s -- skill names show their SN_ ids" % SKILL_NAME_TABLE_PATH.get_file())
	return _skill_names

## Which races' skills _skill_grid holds (round 691): the player's race's
## tables, read on the first lookup -- at world entry, by the hotbar restore --
## and the other race's only if the window is laid out for it. A lookup of an
## id the player's race does not carry answers "unknown" rather than parsing
## ~10 MB of the other race's files mid-game (the round 691 review).
var _skill_catalog_races: Dictionary = {}

func _load_skill_catalog() -> void:
	if _skill_catalog_loaded:
		return
	_skill_catalog_loaded = true
	if _builder == null:
		return
	var archive := _builder.media_archive()
	if archive == null:
		return
	skill_names_table()
	var gentry := ObjectLoader.find_file(archive, SkillDataReader.GROUP_TABLE)
	if gentry != null:
		_skill_groups = SkillDataReader.parse_groups(archive.read_file(gentry))
	_load_masteries()
	_load_skill_catalog_for(_skill_race)

## One race's board rows: its masteries' rows of the race's skilldata files
## (plain data: safe on a worker).
##
## Round 746's review, finding 1: the board reads the race's LEGACY cover
## (SkillDataReader.tables_for_race without an archive), not the plain
## index. Retail's board rows come from `skilldataenc.txt` (READ,
## Client_LoadAllRefData 0x844cd0); the cover matches those on every
## player-mastery row, where the plain index adds 35004/35005 (a Europe
## cleric's leftovers in the plain twin of skilldata_36000) and takes 36791's
## required mastery level 10 instead of 110 (MEASURED by the review).
static func _parse_skill_board(archive: Pk2Reader, race: int) -> Dictionary:
	var ids := PackedInt32Array()
	for id in MasteryReader.RACE_MASTERIES.get(race, []):
		ids.append(int(id))
	var datas: Array = []
	for path in SkillDataReader.tables_for_race(race):
		var e := ObjectLoader.find_file(archive, path)
		if e != null:
			datas.append(archive.read_file(e))
	return SkillDataReader.parse_skills(datas, ids)

## race -> [task id, [grid]]: board parses started by preload_skill_catalog.
var _skill_parse_tasks: Dictionary = {}

## Round 746's review, finding 3: parses `race`'s board on a worker at world
## entry, so the first cast, the hotbar restore or the first K waits for it
## (if at all) instead of parsing ~170 ms on the main thread then.
func preload_skill_catalog(race: int) -> void:
	if _skill_catalog_races.has(race) or _skill_parse_tasks.has(race) or _builder == null:
		return
	var archive := _builder.media_archive()
	if archive == null:
		return
	var box: Array = [{}]
	var task := WorkerThreadPool.add_task(func() -> void:
		box[0] = HudPanels._parse_skill_board(archive, race), false, "skill board %d" % race)
	_skill_parse_tasks[race] = [task, box]

## Waits for the board parses still under way (leaving the tree).
func _wait_skill_parses() -> void:
	for race in _skill_parse_tasks.keys():
		PoolWait.task(int((_skill_parse_tasks[race] as Array)[0]))
	_skill_parse_tasks.clear()

## Reads one race's skills (its masteries' rows of its skilldata files) into
## _skill_grid and _skill_reach_by_id, once.
func _load_skill_catalog_for(race: int) -> void:
	if _skill_catalog_races.has(race) or _builder == null:
		return
	var archive := _builder.media_archive()
	if archive == null:
		return
	_skill_catalog_races[race] = true
	var grid: Dictionary
	if _skill_parse_tasks.has(race):
		# Started at world entry (preload_skill_catalog): wait for it.
		var pending: Array = _skill_parse_tasks[race]
		PoolWait.task(int(pending[0]))
		_skill_parse_tasks.erase(race)
		grid = (pending[1] as Array)[0]
	else:
		grid = _parse_skill_board(archive, race)
	for key in grid:
		_skill_grid[key] = grid[key]
	for key in grid:
		for entry in grid[key]:
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
						# The two columns themselves (round 617): SelfCast.plan
						# casts a Target_Required 0 row with nothing selected
						# and puts a land row into ground-pick mode.
						"target_required": int(bs.level_target_required[i]),
						"target_land": int(bs.level_target_land[i]),
						# Round 622: the target groups (SkillDataReader.TARGET_BIT_*),
						# for SelfCast.plan's friendly-target rules.
						"target_groups": int(bs.level_target_groups[i]) if i < bs.level_target_groups.size() else 0,
						# Round 832: Basic_Activity (level 1's): a cast of 2
						# takes the action queue's place, so it ends a trace;
						# another runs at once beside it (0x4ad870, READ).
						"activity": int(bs.activity),
					}
	print("HudPanels: skill catalog (race %d) -- %d masteries with groups, %d group-rows of skills"
		% [race, _skill_groups.size(), _skill_grid.size()])
	if OS.has_environment("OPENSRO_QA_PANELS"):
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
	# The race whose masteries the server lists (round 691): it sends every
	# mastery the character holds, a level-0 one included.
	var race := MasteryReader.race_of_masteries(mastery_levels.keys())
	if race >= 0:
		set_skill_race(race)
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
## window lit up (OPENSRO_QA_MASTERY applies one level to every mastery). The
## board greys any skill whose required mastery level is above this (the real
## availability rule, recovered from CIFSkillSlot).
func _mastery_level(mastery_id: int) -> int:
	var lvl: int = int(_skill_mastery_levels.get(mastery_id, 0))
	if OS.has_environment("OPENSRO_QA_MASTERY"):
		lvl = maxi(lvl, int(OS.get_environment("OPENSRO_QA_MASTERY")))
	return lvl

## The skill window's live contents, laid out the way the retail client lays
## them (round 781; SkillBoard has the reading): the category tabs (Weapon /
## Force, Melee / Caster / Buff) above the pane, the selected category's
## mastery tabs, the selected mastery's header (icon, "<name> Mastery",
## LEVEL UP, "Lv N") and its rows of skills, four at a time, each slot with
## its level digits and its ADD / UP / MAX button. This gathers the model from
## the state the server reported and hands it to SkillBoard.
func _fill_skill_masteries(window: HudWindow) -> void:
	_load_masteries()
	_load_level_data()
	_load_skill_catalog()
	# QA: OPENSRO_QA_SKILL_STATE="sp=9,level=3,257=3" sets the points, the
	# character level and any mastery levels (id=level) the board explains
	# against, so a render can show a given player's window without a server.
	if OS.has_environment("OPENSRO_QA_SKILL_STATE"):
		for part in OS.get_environment("OPENSRO_QA_SKILL_STATE").split(",", false):
			var kv: PackedStringArray = String(part).split("=")
			if kv.size() != 2 or not kv[1].strip_edges().is_valid_int():
				continue
			var key := kv[0].strip_edges()
			match key:
				"sp": _skill_points = int(kv[1])
				"level": _skill_char_level = int(kv[1])
				"race": set_skill_race(int(kv[1]))
				_:
					if key.is_valid_int():   # "257=3": mastery id 257 at level 3
						_skill_mastery_levels[int(key)] = int(kv[1])
	var board := window.node("GDR_SKILL_BOARD") as Control
	if board == null:
		return
	var pane := board.get_parent() as Control
	if pane == null:
		return

	# Group the masteries by their tab, in tab order (_masteries is sorted by
	# tab, then id: FUN_006aacf0 walks the id-keyed mastery map and files each
	# under its TabID, READ).
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
	var mastery: MasteryReader.Mastery = masteries[_skill_active_mastery] if _skill_active_mastery < masteries.size() else null

	var categories: Array = []
	for i in range(tab_keys.size()):
		categories.append(_resolve_ui(tabs[tab_keys[i]]["code"], _skill_tab_fallback(int(tab_keys[i]))))
	var mastery_names: Array = []
	for mm in masteries:
		mastery_names.append((mm as MasteryReader.Mastery).display_name(_text_table(), _skill_text_table()))

	var model := {"categories": categories, "category": _skill_active_tab,
		"masteries": mastery_names, "mastery": _skill_active_mastery, "rows": [], "first_row": 0}
	if mastery != null:
		if _skill_first_row_mastery != mastery.id:
			_skill_first_row_mastery = mastery.id
			_skill_first_row = 0
		model["first_row"] = _skill_first_row
		model["header"] = _skill_header_model(mastery)
		model["rows"] = _skill_rows_model(mastery)

	# The old view out (renamed first, so a lookup this frame finds the new).
	for child in pane.get_children():
		if str(child.name).begins_with("SkillBoardView"):
			child.name = "SkillBoardView_old"
			child.queue_free()
	var view := SkillBoard.new()
	view.builder = _builder
	# Round 786: every help on the board in the original's bubble.
	view.tip_wirer = func(c: Control, src: Variant) -> void: set_bubble_tip(c, src, SkillTooltipLines.WRAP_WIDTH)
	view.build(model, _on_skill_icon_input)
	_skill_board_view = view
	if _skill_cooldown_frames.is_valid():
		view.set_cooldowns(_skill_cooldown_frames)
	# The view draws in the pane's coordinates; the board sits at its own
	# authored place in the pane (6,29), so the pane's origin is found from it.
	view.position = board.position - SkillBoard.BOARD_RECT.position
	pane.add_child(view)
	view.category_selected.connect(_on_skill_tab)
	view.mastery_selected.connect(_on_skill_mastery_tab)
	view.scrolled.connect(func(first: int) -> void: _skill_first_row = first)
	if mastery != null:
		var mid := mastery.id
		view.levelup_pressed.connect(func() -> void: _open_skill_practice(SkillPracticeBox.Mode.MASTERY, mid))
	view.learn_pressed.connect(func(target: int) -> void: _open_skill_practice(SkillPracticeBox.Mode.SKILL, target))

	# The footer (READ, FUN_006aa3e0): the skill points "%d", and the mastery
	# total "%d/%d" against the race's cap (mastery_total_cap).
	_set_label(window, "GDR_SKILL_TEXT_SP_NUM", "%d" % _skill_points)
	# The real server total (a QA lighting override must not pollute it).
	var total := 0
	for lvl in _skill_mastery_levels.values():
		total += int(lvl)
	_set_label(window, "GDR_SKILL_TEXT_TOTAL_MASTERYLEV_NUM",
		SkillBoard.total_text(total, mastery_total_cap(_skill_race, _skill_char_level)))
	if OS.has_environment("OPENSRO_QA_SKILL_STATE") or OS.has_environment("OPENSRO_QA_SKILL_PRESS"):
		_qa_skill_board_report(model)
	if OS.has_environment("OPENSRO_QA_SKILL_PRESS") and not _qa_skill_press_started:
		_qa_skill_press_started = true
		_qa_skill_press(OS.get_environment("OPENSRO_QA_SKILL_PRESS"))

## The skill window's current SkillBoard (null before the first fill).
var _skill_board_view: SkillBoard = null
## The last frames_for apply_skill_cooldowns was given, so a refilled board
## draws the running sweeps at once.
var _skill_cooldown_frames := Callable()

## The skill window's re-use displays (round 786): every learned slot draws
## the skill_delay sweep / skill_charge flash as a hotbar skill slot does
## (READ, the skill window's slot is a CIFSlotWithHelp of the skill kind 0x49 --
## the bar's quick slots hold skills as sub-kind 0x49 -- drawn by the same
## 0x67cfb0; SkillBoard's header).
## `frames_for(skill_id)` returns [delay_frame, charge_frame]. World3D calls it
## from the same tick that draws the bar.
func apply_skill_cooldowns(frames_for: Callable) -> void:
	_skill_cooldown_frames = frames_for
	if _skill_board_view != null and is_instance_valid(_skill_board_view):
		_skill_board_view.set_cooldowns(frames_for)

## The skill window's current SkillBoard, or null (tests, QA).
func skill_board_view() -> SkillBoard:
	return _skill_board_view if _skill_board_view != null and is_instance_valid(_skill_board_view) else null

## The first visible row and the mastery it belongs to, so a refill (after a
## learn) keeps the rows where they were and a new mastery starts at the top.
var _skill_first_row := 0
var _skill_first_row_mastery := -1
## The practice box (one at a time: retail's is one object, 0x782620).
var _skill_practice_box: SkillPracticeBox = null

## The header's model (READ, 0x69c5f0; SkillBoard).
func _skill_header_model(mastery: MasteryReader.Mastery) -> Dictionary:
	var real_level := int(_skill_mastery_levels.get(mastery.id, 0))
	var cost := LevelDataReader.mastery_up_cost(_level_mastery_costs, real_level)
	var show_up := SkillBoard.levelup_visible(real_level, _skill_char_level, _skill_points, cost)
	var nm := mastery.display_name(_text_table(), _skill_text_table())
	var tip := nm
	var explanation := _resolve_any(mastery.desc_code)
	if explanation != "":
		tip += "\n" + explanation
	var up_tip := ""
	if show_up:
		# OURS: retail's LEVEL UP carries no help that was read.
		up_tip = "Raise %s to Lv %d (%d skill points)." % [nm, real_level + 1, cost]
	if OS.has_environment("OPENSRO_QA_SKILL_STATE"):
		print("QA SKILL: %s Lv %d, %d SP, char Lv %d, cost %d -> LEVEL UP %s" % [
			nm, real_level, _skill_points, _skill_char_level, cost, "shown" if show_up else "hidden"])
	return {"icon": _builder.load_texture(mastery.icon_path) if _builder != null else null,
		"name": SkillBoard.header_name(nm, _resolve_ui("PARAM_MASTERY", "Mastery")),
		"level": SkillBoard.level_text(_resolve_ui("UIIT_STT_LEVEL_LV", "Lv"), _mastery_level(mastery.id)),
		"levelup": show_up, "tooltip": tip, "levelup_tooltip": up_tip}

## The rows' model: one per group of the mastery (skillgroup.txt, ordered by
## row), each skill at its own column (skilldata col 60, SkillDataReader).
func _skill_rows_model(mastery: MasteryReader.Mastery) -> Array:
	var rows: Array = []
	var mastery_level := _mastery_level(mastery.id)
	for g in _skill_groups.get(mastery.id, []):
		var group: SkillDataReader.SkillGroup = g
		var slots: Array = []
		slots.resize(SkillBoard.COLUMNS)
		for entry in _skill_grid.get("%d:%d" % [mastery.id, group.row], []):
			var s: SkillDataReader.BaseSkill = entry
			if s.column < 0 or s.column >= SkillBoard.COLUMNS:
				continue
			var learned := _skill_learned_level(s)
			var missing := _missing_prerequisites(s, learned + 1)
			var view := SkillBoard.slot_view(learned, s.max_level, mastery_level, s.level_ids,
				s.level_reqs, s.level_sp, missing.is_empty(), _skill_points)
			# Round 786: the retail skill tooltip (SkillTooltipLines, 0x67a970),
			# composed when hovered, in the original's window.
			var bs := s
			var tip := func() -> Array: return skill_tip_lines(bs, _skill_learned_level(bs), true)
			var meta := {}
			if learned > 0:
				var cast_id: int = s.level_ids[learned - 1]
				meta = {"qa_skill_id": cast_id, "skill_id": cast_id, "code": s.basic_code}
			slots[s.column] = {"icon": _load_skill_icon(s.icon_path), "view": view, "tip": tip,
				"button_tooltip": _skill_button_tooltip(s, int(view["target_id"]), int(view["button"])),
				"meta": meta}
		var focus := ""
		if group.icon_path.length() > 4:
			# The hover twin (READ, 0x69f04d: the path less its last four
			# characters, plus "_focus.ddj").
			focus = group.icon_path.substr(0, group.icon_path.length() - 4) + "_focus.ddj"
		rows.append({"icon": _load_skill_icon(group.icon_path), "focus": _load_skill_icon(focus),
			"name": _resolve_any(group.name_code), "slots": slots})
	return rows

## The ADD / UP button's help: retail fills it with the target level's
## PARAM_REQ_HP / PARAM_REQ_MP lines when they are not 0 (READ, 0x6a12ba..
## 0x6a147e); the HP costs are not parsed here, so only the MP line is.
func _skill_button_tooltip(s: SkillDataReader.BaseSkill, target_id: int, which: int) -> String:
	if which != SkillBoard.Btn.ADD and which != SkillBoard.Btn.UP:
		return ""
	var i := s.level_ids.find(target_id)
	if i < 0 or i >= s.level_mp.size() or s.level_mp[i] <= 0:
		return ""
	return SkillPracticeBox._format(_resolve_ui("PARAM_REQ_MP", "Consumed MP: %d"), [s.level_mp[i]])

## A name code through the UI table, then the skill table; "" when neither
## knows it.
func _resolve_any(code: String) -> String:
	var t := _resolve_ui(code, "")
	if t != "":
		return t
	var st := _skill_text_table()
	if st != null and code != "" and code != "xxx":
		var r := st.get_text(code)
		if r != "" and r != code:
			return r
	return ""

## A slot icon's mouse input: a learned skill picks up on a left click (the
## next click puts it on a quick slot, HeldIcon, round 652; the bar's drop
## handler CIFUnderBar::vslot_028 takes kind 0x19, the skill window) and
## casts on a right click (vslot 33 -> 0x682040, case 0x19 -> 0x81ba10, READ).
func _on_skill_icon_input(ev: InputEvent, icon: TextureRect, meta: Dictionary) -> void:
	if not meta.has("skill_id"):
		return
	var cast_id := int(meta["skill_id"])
	var cast_code := String(meta.get("code", ""))
	if _is_pick_click_on(ev, icon):
		pick_up_icon({"kind": "skill", "skill_id": cast_id, "code": cast_code, "icon": icon.texture},
			icon.texture, icon, (ev as InputEventMouseButton).global_position)
	elif ev is InputEventMouseButton and not ev.pressed and ev.button_index == MOUSE_BUTTON_RIGHT \
			and icon.get_global_rect().has_point((ev as InputEventMouseButton).global_position):
		skill_use_requested.emit(cast_id, cast_code)

## Opens the practice box (READ: a slot's ADD / UP, 0x6a0700, and LEVEL UP,
## 0x69bca0, both show CIFSkillPracticeBox): for a skill level `id` is that
## level's skill id, for a mastery the mastery id.
func _open_skill_practice(mode: int, id: int) -> SkillPracticeBox:
	if _skill_practice_box != null and is_instance_valid(_skill_practice_box):
		_skill_practice_box.close()
	_skill_practice_box = null
	var opts := {"sp": _skill_points}
	if mode == SkillPracticeBox.Mode.SKILL:
		var s := _board_skill_with_level_id(id)
		if s == null:
			return null
		var level := s.level_ids.find(id) + 1
		opts["name"] = s.display_name(_skill_text_table())
		opts["level"] = level
		opts["icon"] = _load_skill_icon(s.icon_path)
		# INFERRED: retail shows the level's study text (its record +0x178);
		# the reader keeps the tooltip description (col 64), shown here.
		opts["description"] = s.description(_skill_text_table())
		opts["cost"] = s.level_sp[level - 1] if level - 1 < s.level_sp.size() else 0
	else:
		var m: MasteryReader.Mastery = null
		for entry in _masteries:
			if (entry as MasteryReader.Mastery).id == id:
				m = entry
		if m == null:
			return null
		var lvl := int(_skill_mastery_levels.get(id, 0))
		opts["name"] = m.display_name(_text_table(), _skill_text_table())
		opts["level"] = lvl
		opts["description"] = _resolve_any(m.desc_code)
		# The leveldata cost at the current level, 0 at level 0 (READ,
		# 0x7067ab..0x706817).
		opts["cost"] = int(_level_mastery_costs.get(lvl, 0)) if lvl > 0 else 0
	var box := SkillPracticeBox.new()
	if not box.build(_builder, mode, id, opts):
		push_warning("HudPanels: the practice box could not be built (%s missing)" % SkillPracticeBox.LAYOUT)
		box.free()
		return null
	box.confirmed.connect(_on_skill_practice_confirmed)
	box.refused.connect(func(text: String) -> void: system_notice.emit(text))
	add_child(box)
	box.position = ((get_viewport_rect().size - box.size) / 2.0).floor()
	_skill_practice_box = box
	# The box goes with the skill window.
	var window: HudWindow = _windows.get("skill")
	if window != null:
		var close_with := func() -> void:
			if is_instance_valid(box) and (not is_instance_valid(window) or not window.visible):
				box.close()
		if not window.visibility_changed.is_connected(close_with):
			window.visibility_changed.connect(close_with, CONNECT_ONE_SHOT)
	_message_box_sounds(box)
	print("HudPanels: practice box %s %d: '%s' Lv %s, cost %d, SP %d" % [
		"skill" if mode == SkillPracticeBox.Mode.SKILL else "mastery", id, opts.get("name", ""),
		str(opts.get("level", 0)), int(opts.get("cost", 0)), _skill_points])
	return box

## The practice box's Confirm with enough points: send the learn (a skill
## level) or the raise (a mastery). The results re-read the state.
func _on_skill_practice_confirmed(mode: int, id: int) -> void:
	print("HudPanels: practice box confirmed (%s %d)" % ["skill" if mode == SkillPracticeBox.Mode.SKILL else "mastery", id])
	if mode == SkillPracticeBox.Mode.SKILL:
		_on_skill_learn(id)
	else:
		_on_mastery_levelup(id)

## QA: one line per row of the board as the model has it -- each column's
## button (A add, U up, M max, - none), lock (L) and level -- so a render's
## log says what the picture should show.
var _qa_skill_press_started := false
func _qa_skill_board_report(model: Dictionary) -> void:
	print("QA SKILL BOARD: tabs %s [%d], masteries %s [%d], header %s, %d rows from %d" % [
		str(model.get("categories")), int(model.get("category")), str(model.get("masteries")),
		int(model.get("mastery")), str((model.get("header", {}) as Dictionary).get("name", "")) + " / " +
		str((model.get("header", {}) as Dictionary).get("level", "")) + " / LEVEL UP " +
		str((model.get("header", {}) as Dictionary).get("levelup", false)),
		(model.get("rows", []) as Array).size(), int(model.get("first_row"))])
	var i := 0
	for r in model.get("rows", []):
		var cells := PackedStringArray()
		for s in (r as Dictionary).get("slots", []):
			if s == null:
				cells.append(".")
				continue
			var v: Dictionary = (s as Dictionary)["view"]
			cells.append("%s%s%d" % ["-AUM"[int(v["button"])], "L" if v["locked"] else "", int(v["level"])])
		print("QA SKILL ROW %d %s: %s" % [i, str((r as Dictionary).get("name", "")), " ".join(cells)])
		i += 1

## QA: OPENSRO_QA_SKILL_PRESS="<step>[,<step>...]" presses the window's own
## buttons one second apart, the way a player would: "add" / "up" the first
## slot button of that kind, "levelup" the header's LEVEL UP, "confirm" /
## "cancel" the practice box's buttons, "tab:<i>" / "mastery:<i>" the tabs,
## "wait:<s>" a further pause. Each step prints the frame it ran on.
func _qa_skill_press(spec: String) -> void:
	var steps := spec.split(",", false)
	for step in steps:
		await get_tree().create_timer(1.0).timeout
		if String(step).begins_with("wait:"):
			await get_tree().create_timer(float(String(step).substr(5))).timeout
			continue
		var window: HudWindow = _windows.get("skill")
		var view: SkillBoard = null
		if window != null:
			view = window.find_child("SkillBoardView", true, false) as SkillBoard
		var st := String(step).strip_edges()
		var done := false
		if st == "add" or st == "up" or st == "levelup":
			if view != null:
				for b in view.find_children("*", "BaseButton", true, false):
					var btn := b as BaseButton
					var is_lv := st == "levelup" and str(btn.name) == "GDR_SKILLBOARD_BTNLEVUP"
					var is_slot := String(btn.get_meta("kind", "")).to_lower() == st
					if (is_lv or is_slot) and btn.is_visible_in_tree() and not btn.disabled:
						btn.pressed.emit()
						done = true
						break
		elif st == "confirm" or st == "cancel":
			if _skill_practice_box != null and is_instance_valid(_skill_practice_box):
				if st == "confirm":
					_skill_practice_box.confirm()
				else:
					_skill_practice_box.cancel_box()
				done = true
		elif st.begins_with("tab:") and view != null:
			view.category_selected.emit(int(st.substr(4)))
			done = true
		elif st.begins_with("mastery:") and view != null:
			view.mastery_selected.emit(int(st.substr(8)))
			done = true
		elif st.begins_with("tip:") and view != null:
			# Round 786: "tip:<shown row>:<column>" hovers that slot's icon
			# (its bubble, as the mouse would show it).
			var f := st.split(":")
			var rows := view.find_child("SkillRows", true, false)
			var shown: Array = rows.get_children().filter(func(r): return (r as Control).visible) if rows != null else []
			var r := int(f[1]) if f.size() > 1 else 0
			var icon: Control = (shown[r] as Node).get_node_or_null("Slot%d/Icon" % (int(f[2]) if f.size() > 2 else 0)) if r < shown.size() else null
			if icon != null:
				show_bubble_tip(icon)
				done = not item_tip_shown().is_empty()
				print("QA SKILL TIP %s: %s" % [st, ItemTooltipLines.as_text(item_tip_shown()).replace("\n", " | ")])
		elif st.begins_with("bartip:"):
			# Round 786: "bartip:<quick slot>" hovers that slot of the bar
			# (QA only; the bar is the panels' sibling, World3D's HudUnderbar).
			var bar := get_parent().get_node_or_null("HudUnderbar") if get_parent() != null else null
			var node: Control = bar.call("slot_node", int(st.substr(7))) if bar != null else null
			if node != null:
				show_bubble_tip(node)
				done = not item_tip_shown().is_empty()
				print("QA SKILL TIP %s: %s" % [st, ItemTooltipLines.as_text(item_tip_shown()).replace("\n", " | ")])
		print("QA SKILL PRESS %s: %s (frame %d)" % [st, "done" if done else "nothing to press", Engine.get_frames_drawn()])

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

## The icon path (under `icon\`) of the skill whose per-level id is
## `skill_id`, or "" when the tables do not carry it -- what the quick-slot
## bar restores a saved skill's icon from (round 639).
func skill_icon_path(skill_id: int) -> String:
	var bs := _board_skill_with_level_id(skill_id)
	if bs == null or bs.icon_path == "":
		return ""
	return bs.icon_path if bs.icon_path.to_lower().begins_with("icon\\") else "icon\\" + bs.icon_path

## Every level's id of the skill whose per-level id is `skill_id` (index i =
## level i + 1), or empty -- the group the quick-slot rebind walks (round
## 639's review, HotbarStore.rebind_for_skill).
func skill_level_ids(skill_id: int) -> PackedInt64Array:
	var bs := _board_skill_with_level_id(skill_id)
	return bs.level_ids if bs != null else PackedInt64Array()

## The board skill one of whose levels is `skill_id`, from the tables read so
## far (the player's race's; round 691). Null when they do not carry it.
func _board_skill_with_level_id(skill_id: int) -> SkillDataReader.BaseSkill:
	_load_skill_catalog()
	for key in _skill_grid:
		for entry in _skill_grid[key]:
			var bs: SkillDataReader.BaseSkill = entry
			if bs.level_ids.has(skill_id):
				return bs
	return null

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
	if OS.has_environment("OPENSRO_QA_LEARNED"):
		return mini(int(OS.get_environment("OPENSRO_QA_LEARNED")), s.max_level)
	var lvl := 0
	for i in range(s.level_ids.size()):
		var id := s.level_ids[i]
		if id > 0 and _skill_known.has(id):
			lvl = i + 1
		else:
			break
	return lvl

## **A skill's tooltip rows** (round 786; SkillTooltipLines has the reading,
## docs/protocol/skill_tooltip.md): the record a slot holds -- the learned
## level, or level 1 for a skill not learned -- composed as UI_SILKMALL
## 0x67a970 composes it. `in_window` is the skill window's slot (kind 0x49),
## which adds the learn / next-level conditions; a quick slot (kind 0x0c with
## content 0x19) stops before them (READ, 0x67adb4..0x67adce). This replaces
## round 691's string tooltip ("Learn Lv %d: ... (yours: Lv %d)", "Cast
## %.2fs", "Requires: ...") -- OUR wording, shown in Godot's native popup.
func skill_tip_lines(s: SkillDataReader.BaseSkill, learned: int, in_window: bool) -> Array:
	if s == null:
		return []
	_load_masteries()
	var mastery: MasteryReader.Mastery = null
	for entry in _mastery_table:
		if (entry as MasteryReader.Mastery).id == s.mastery_id:
			mastery = entry
	var text := func(k: String, f: String) -> String:
		var r := _resolve_any(k)
		return r if r != "" else f
	var name_of := func(g: int) -> String:
		var other := _skill_by_base_id(g)
		return SkillTooltipLines.name_of(other, _skill_text_table()) if other != null else "%d" % g
	var level_of := func(g: int) -> int:
		var other := _skill_by_base_id(g)
		return _skill_learned_level(other) if other != null else 0
	var ctx := {
		"text": text,
		"names": _skill_text_table(),
		"conditions": in_window,
		"learned": learned,
		"mastery_name": mastery.display_name(_text_table(), _skill_text_table()) if mastery != null else "",
		"mastery_level": _mastery_level(s.mastery_id),
		"mastery_held": _skill_mastery_levels.is_empty() or _skill_mastery_levels.has(s.mastery_id),
		"sp": _skill_points,
		"skill_name_of": name_of,
		"skill_level_of": level_of,
	}
	return SkillTooltipLines.compose(s, maxi(learned, 1), ctx)

## A quick slot's skill tooltip (the bar's slot holding per-level skill id
## `skill_id`): that level's record, no conditions (READ, 0x67adb4: a
## content kind of 0x19 ends the help there). [] for an id the tables lack.
func quickslot_skill_tip_lines(skill_id: int) -> Array:
	var bs := _board_skill_with_level_id(skill_id)
	if bs == null:
		return []
	return skill_tip_lines(bs, bs.level_ids.find(skill_id) + 1, false)

## Learn (or level up) a skill: sent from the practice box's Confirm (round
## 781). The server validates the mastery requirement and SP cost;
## learn_skill_result comes back and we re-read the state to repaint the board.
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
	_refill_skill.call_deferred()

func _on_skill_mastery_tab(index: int) -> void:
	_skill_active_mastery = index
	_refill_skill.call_deferred()

func _refill_skill() -> void:
	var window: HudWindow = _windows.get("skill")
	if window != null:
		_fill_skill_masteries(window)

## Raise a mastery: sent from the practice box's Confirm (round 781; LEVEL UP
## opens the box). The result comes back as raise_mastery_result, which
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

## A tab's label when the UI table cannot resolve its token: China's two tabs,
## Europe's three (the English textuisystem.txt gives the tokens -- Weapon,
## Force, Melee, Caster, Buff -- written here as fallbacks).
func _skill_tab_fallback(tab: int) -> String:
	if _skill_race == MasteryReader.RACE_EUROPE:
		return ["Melee", "Caster", "Buff"][clampi(tab, 0, 2)]
	return "Weapon" if tab == MasteryReader.TAB_WEAPON else "Force"

func _resolve_ui(token: String, fallback: String) -> String:
	if token == "" or token == "xxx" or _text_table() == null:
		return fallback
	var resolved := _text_table().get_text(token)
	return resolved if resolved != "" and resolved != token else fallback

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

## The equipment pane's slot art, as CIFEquipment draws it (round 633; the
## previous version put each texture INSIDE its 32x32 slot, shrunk to fit, and
## gave slots 8..12 the wrong art -- the earring on 108, the special dress on
## 112 -- and the avatar slots none).
##
## READ: the slots themselves carry no art (their layout DDJ is empty). The
## window's own draw, CIFEquipment::vslot_013 (0x6ad860), paints a backdrop for
## each slot after the frame and tile and the 3D model and before the slots
## (its children), which draw the item on top:
##
##   - the worn loop (0x6adc02..0x6adf35), i = 0..12, the textures CIFEquipment
##     ::Create (0x6ac1c0) loads into +0x594 + 4i (0x6ac51a..0x6ac8f2), at the
##     window's origin plus the pair at 0xda6e20 + 8i, 0x28 (40) square, or
##     0x38 (56) for 6 and 7 (0x6adc2a..0x6adc39) -- each 32x32 slot centred in
##     it, the weapon's and shield's in a bigger box. Drawn whether the slot
##     is filled or not; in avatar mode (+0xf08) only i == 8 (0x6ade59);
##   - the avatar loop (0x6adf3b..0x6ae191), avatar mode only, the five at
##     +0x5d0 + 4k (0x6ac380..0x6ac4c8), at the pairs from 0xda6df8, 40.0
##     square (0xe1b8f8). k 4's y of 169 rather than 168 is the table's own.
##
## The textures are drawn at their own size: every one is 40x40 but the
## weapon's and shield's 56x56 (MEASURED from their headers), the size the
## loop asks for. The window scale the loop multiplies by (+0x1fc/+0x200) is
## INFERRED to be 1.
const EQUIP_BACKDROPS := [
	["interface\\equipment\\equip_slot_helm.ddj", Vector2(1, 82), 40],
	["interface\\equipment\\equip_slot_mail.ddj", Vector2(1, 125), 40],
	["interface\\equipment\\equip_slot_shoulderguard.ddj", Vector2(137, 82), 40],
	["interface\\equipment\\equip_slot_gauntlet.ddj", Vector2(137, 125), 40],
	["interface\\equipment\\equip_slot_pants.ddj", Vector2(1, 168), 40],
	["interface\\equipment\\equip_slot_boots.ddj", Vector2(137, 168), 40],
	["interface\\equipment\\equip_slot_weapon.ddj", Vector2(0, 0), 56],
	["interface\\equipment\\equip_slot_shield.ddj", Vector2(122, 0), 56],
	["interface\\equipment\\equip_slot_specialdress.ddj", Vector2(137, 304), 40],
	["interface\\equipment\\equip_slot_earring.ddj", Vector2(1, 211), 40],
	["interface\\equipment\\equip_slot_necklace.ddj", Vector2(137, 211), 40],
	["interface\\equipment\\equip_slot_l_ring.ddj", Vector2(1, 254), 40],
	["interface\\equipment\\equip_slot_r_ring.ddj", Vector2(137, 254), 40],
]
## The avatar backdrops, k = 0..4, framing GDR_AVATAR_SLOT_01..05: hat, dress,
## accessory (pandernt), flag (plag) and the extra (extraneous01) slot.
const AVATAR_BACKDROPS := [
	["interface\\equipment\\equip_slot_helm.ddj", Vector2(1, 82), 40],
	["interface\\equipment\\equip_slot_cloth.ddj", Vector2(1, 125), 40],
	["interface\\equipment\\equip_slot_pandernt.ddj", Vector2(137, 125), 40],
	["interface\\equipment\\equip_slot_plag.ddj", Vector2(137, 82), 40],
	["interface\\equipment\\equip_slot_extraneous01.ddj", Vector2(1, 169), 40],
]
## The one worn backdrop avatar mode keeps (0x6ade59: i == 8).
const EQUIP_BACKDROP_KEPT := 8
const EQUIP_BACKDROP_PREFIX := "EquipBackdrop"
const AVATAR_BACKDROP_PREFIX := "AvatarBackdrop"
## The avatar buttons' tooltips, set by Create with 0x653dc0 (button 13 from
## the UTF-16 key at 0xda73d0, button 14 from 0xda738c).
const BTN_TO_AVATAR_TIP := "UIIT_STT_AVATAR_VIEW_AVATARSLOT"
const BTN_TO_EQUIPMENT_TIP := "UIIT_STT_AVATAR_VIEW_EQUIPSLOT"

## The equipment pane's own root (its layout's "Create" section), or null.
func _equipment_root() -> Control:
	if _popup == null:
		return null
	var pane := _popup.pane_control("GDR_EQUIPMENT")
	if pane == null or pane.get_child_count() == 0:
		return null
	return pane.get_child(0) as Control

## Where vslot_013's own drawing goes in the pane's draw order: just in front
## of the frame (ID 4) and the tile (ID 5), which it draws first
## (0x6ad871..0x6ad89d), and behind every other child.
static func _after_equipment_background(root: Control) -> int:
	var at := 0
	for name in ["GDR_EQ_FRAME", "GDR_EQ_NORMALTILE_BG"]:
		var n := root.get_node_or_null(name)
		if n != null:
			at = maxi(at, n.get_index() + 1)
	return at

## Builds the pane's backdrops (EQUIP_BACKDROPS, AVATAR_BACKDROPS) once, in
## vslot_013's order -- worn, then avatar -- right in front of the frame, the
## tile and the paper doll.
func _apply_equipment_slot_backgrounds() -> void:
	var root := _equipment_root()
	if root == null or _builder == null:
		return
	var at := _after_equipment_background(root)
	var doll := root.get_node_or_null("PaperDoll")
	if doll != null:
		at = maxi(at, doll.get_index() + 1)
	for set_spec in [[EQUIP_BACKDROPS, EQUIP_BACKDROP_PREFIX], [AVATAR_BACKDROPS, AVATAR_BACKDROP_PREFIX]]:
		var specs: Array = set_spec[0]
		for i in range(specs.size()):
			var node_name := "%s%d" % [set_spec[1], i]
			var bd := root.get_node_or_null(node_name) as TextureRect
			if bd == null:
				bd = TextureRect.new()
				bd.name = node_name
				bd.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
				bd.stretch_mode = TextureRect.STRETCH_SCALE
				bd.mouse_filter = Control.MOUSE_FILTER_IGNORE
				root.add_child(bd)
			root.move_child(bd, at)
			at += 1
			var spec: Array = specs[i]
			bd.texture = _builder.load_texture(spec[0])
			bd.position = spec[1]
			bd.size = Vector2(spec[2], spec[2])
	var window: HudWindow = _windows.get("inventory")
	if window != null:
		for pair in [[BTN_TO_AVATAR, BTN_TO_AVATAR_TIP], [BTN_TO_EQUIPMENT, BTN_TO_EQUIPMENT_TIP]]:
			var button := window.node(pair[0]) as Control
			if button != null:
				var tip := _builder.resolve_text(pair[1])
				if tip != "" and tip != pair[1]:
					button.tooltip_text = tip
	_show_equipment_backdrops()

## The backdrops of the current mode (vslot_013's two loops).
func _show_equipment_backdrops() -> void:
	var root := _equipment_root()
	if root == null:
		return
	for i in range(EQUIP_BACKDROPS.size()):
		var bd := root.get_node_or_null("%s%d" % [EQUIP_BACKDROP_PREFIX, i]) as CanvasItem
		if bd != null:
			bd.visible = not _equipment_avatar_mode or i == EQUIP_BACKDROP_KEPT
	for k in range(AVATAR_BACKDROPS.size()):
		var bd := root.get_node_or_null("%s%d" % [AVATAR_BACKDROP_PREFIX, k]) as CanvasItem
		if bd != null:
			bd.visible = _equipment_avatar_mode

func _fill_equipment_slots(items: Array) -> void:
	# The equipment is a pane of the main popup, shown with the bag on its
	# inventory tab; its slots hang under the popup's panel_root, so node() finds them.
	var window: HudWindow = _windows.get("inventory")
	if window == null:
		return
	# Round 789: the avatar windows are drawn with it.
	_fill_avatar_slots()
	# Clear first, so an unequip empties its slot.
	for i in range(17):
		var slot := window.node("GDR_EQUIPMENT_SLOT_%d" % (EQUIPMENT_SLOT_BASE + i)) as Control
		if slot != null:
			var icon := slot.get_node_or_null("ItemIcon") as TextureRect
			if icon != null:
				icon.texture = null
				_set_item_tip(icon, -1)
				_set_item_seal_edge(icon, -1)
				DurabilityMark.apply(icon, DurabilityMark.State.NONE, null, null)
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
			_set_item_seal_edge(icon, int(item_id))
			var dur: Array = durability.get(int(slot_index), [])
			if dur.size() == 2:
				_set_item_tip(icon, int(item_id), "equipment", int(slot_index), dur[0], dur[1])
				icon.modulate = Color.WHITE
				_mark_durability(icon, int(item_id), dur[0], dur[1])
			else:
				_set_item_tip(icon, int(item_id), "equipment", int(slot_index))
				icon.modulate = Color.WHITE
			icon.mouse_filter = Control.MOUSE_FILTER_STOP
			# A left click picks the worn item up onto the cursor; the next
			# click on the bag takes it off -- into the first free slot, as
			# retail's server puts it (HeldIcon, round 652). Without a
			# handler here the worn icons took clicks and did nothing
			# (playtest 2026-09-20, item 7).
			icon.set_meta("worn_slot", int(slot_index))
			icon.set_meta("worn_item_id", int(item_id))
			if not icon.has_meta("worn_click_wired"):
				icon.set_meta("worn_click_wired", true)
				icon.gui_input.connect(func(ev: InputEvent) -> void:
					# Round 829: under the store's hammer a left click repairs it.
					if _repair_mode and ev is InputEventMouseButton and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT \
							and not (ev as InputEventMouseButton).pressed and icon.texture != null and icon.has_meta("worn_slot"):
						_repair_click("worn", int(icon.get_meta("worn_slot")))
						return
					if _is_pick_click_on(ev, icon) and icon.texture != null and icon.has_meta("worn_slot"):
						pick_up_icon({"kind": "worn", "slot": int(icon.get_meta("worn_slot")),
							"item_id": int(icon.get_meta("worn_item_id", 0)), "icon": icon.texture},
							icon.texture, icon, (ev as InputEventMouseButton).global_position))

func connect_net() -> void:
	if _net_connected:
		return
	_net_connected = true
	# The inventory's authored presentation is its lattice grid
	# (GDR_INVENTORY_LATTICE), filled with item icons -- the same as the real
	# client.
	NetClient.inventory_list_result.connect(func(slots: Array, _e: String) -> void:
		_fill_inventory_grid(slots))
	NetClient.alchemy_result.connect(_on_alchemy_result)
	# A drag's outcome comes back as the whole bag (see _drop_bag_item).
	NetClient.inventory_move_result.connect(_on_inventory_move_result)
	# Round 789: the avatar inventory, its moves and the grant.
	NetClient.avatar_list_result.connect(func(_items: Dictionary) -> void: _fill_avatar_slots())
	NetClient.avatar_move_result.connect(_on_avatar_move_result)
	NetClient.avatar_grant_result.connect(_on_avatar_grant_result)
	NetClient.avatar_spirit_expired.connect(func(_slot: int) -> void: _fill_avatar_slots())
	NetClient.durability_changed.connect(_on_durability_changed)
	NetClient.equipment_result.connect(func(items: Array, error: String) -> void:
		equip_pending.clear()
		# An equip or unequip reply sounds the moved item (0x87ba20, read).
		if UiSounds.has_pending_move():
			UiSounds.move_replied(error == "")
		# A refusal carries no item list. Redrawing from it blanked every
		# worn slot on the doll while the body stayed dressed -- so a refused
		# equip is logged and the last known equipment stays on screen.
		if error != "":
			push_warning("HudPanels: equipment: %s" % error)
			print("HudPanels: equipment refused: %s" % error)
			return
		_equipped_items = items
		equipment_known = true
		if held_icon != null and held_icon.kind() == "worn":
			var still := false
			for e in items:
				var es = _first_field(e, ["slot", "slot_index", "index"])
				var ei = _first_field(e, ["item_id", "id"])
				if es != null and ei != null and int(es) == int(held_icon.payload.get("slot", -1)) \
						and int(ei) == int(held_icon.payload.get("item_id", -2)):
					still = true
			if not still:
				cancel_held_icon("the worn slot changed")
		# A list (not an equip/unequip ack, which carries no items and no
		# durability) is the worn durability as it stands.
		if not items.is_empty() or not NetClient.last_equipment_durabilities.is_empty():
			UiSounds.note_worn_list(_durability_by_slot(NetClient.last_equipment_durabilities))
		_fill_equipment_slots(items))
	# The skill window shows the masteries (client data, _fill_skill_masteries),
	# not the server's small skill catalogue, so its list result is not drawn
	# here -- it would overlap the mastery rows.
	# The quest log fills the quest window's rows (QuestWindow.fill_log), and
	# the quest messages drive the talk pages, the reward window and the
	# detail (round 785, QuestHud).
	NetClient.quest.log_changed.connect(_on_quest_log_changed)
	NetClient.quest.talk_page.connect(func(page: QuestNet.TalkPage) -> void: show_quest_page(page))
	NetClient.quest.reward_window.connect(func(id: int, text: String) -> void: _quest_hud().open_reward(id, text))
	NetClient.quest.reward_result.connect(func(ok: bool, error: int) -> void:
		_quest_hud().on_reward_result(ok, error)
		# The reward taken, the talk ends as the NPC window's close ends it
		# (0x704B through npc_window_hidden; READ that closing
		# CNIFQuestReward sends the close, FUN_0078fc20).
		if ok and is_open("npctalk"):
			close("npctalk"))
	NetClient.quest.abandon_result.connect(func(ok: bool, id: int, error: int) -> void:
		print("HudPanels: give up quest %d: %s" % [id, "ok" if ok else "refused %d" % error])
		if ok and quest_hud != null and quest_hud.detail != null and is_instance_valid(quest_hud.detail):
			quest_hud.detail.hide())
	NetClient.quest.claim_result.connect(func(ok: bool, id: int, error: int) -> void:
		print("HudPanels: claim quest %d: %s" % [id, "ok" if ok else "refused %d" % error]))
	# Round 834: the friend list (0x3305 and the 0x3B07 pushes) fills the
	# community view's friend rows (GuildWindow.fill_friends).
	NetClient.friend_list_changed.connect(_on_friend_list_changed)
	# Round 834: the exchange's messages (ExchangeController).
	NetClient.exchange_offer.connect(func(d: Dictionary) -> void: _exchange().on_offer(d))
	NetClient.exchange_moved.connect(func(r: Dictionary) -> void: _exchange().on_moved(r))
	NetClient.exchange_partner_gold.connect(func(g: int) -> void: _exchange().on_partner_gold(g))
	NetClient.exchange_partner_confirmed.connect(func() -> void: _exchange().on_partner_confirmed())
	NetClient.exchange_result.connect(func(op: int, code: int) -> void: _exchange().on_result(op, code))
	# Round 837: the item mall's replies (ItemMallController).
	NetClient.mall_buy_result.connect(func(r: Dictionary) -> void: _mall().on_buy_result(r))
	NetClient.mall_silk.connect(func(_a: int, _b: int, _c: int) -> void:
		if item_mall != null and item_mall.active:
			item_mall.refresh_info())
	NetClient.mall_silk_changed.connect(_on_mall_silk_changed)
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
		_on_friend_list_changed(NetClient.last_friend_list)
	if NetClient.quest.has_log:
		_on_quest_log_changed()
	# The race the skill tables are read for, from the body the server put
	# in the world (round 691's review): known at world entry, before the
	# first skill state, so the hotbar restore and the first cast look up the
	# right race's skills. The skill state confirms it (set_skill_state).
	var entered: WorldNet.EnterWorldResult = NetClient.last_enter_world_result
	if entered != null and entered.ok:
		set_skill_race(MasteryReader.RACE_EUROPE if entered.gender.begins_with("europe") else MasteryReader.RACE_CHINA)
	preload_skill_catalog(_skill_race)
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
	NetClient.item_op_result.connect(_on_item_op_result)
	NetClient.buyback_failed.connect(_on_buyback_failed)
	NetClient.storage_list_result.connect(_on_storage_list_result)
	NetClient.storage_deposit_result.connect(_on_storage_deposit_result)
	NetClient.storage_withdraw_result.connect(_on_storage_withdraw_result)
	NetClient.storage_gold_result.connect(_on_storage_gold_result)

## The friend list changed (round 834): kept, and drawn on the guild
## window's friend rows if the window exists (it is drawn from the kept list
## when it is built later).
func _on_friend_list_changed(friends: Array) -> void:
	_friends = friends.duplicate()
	var guild := _windows.get(GUILD_WINDOW_KEY) as GuildWindow
	if guild != null:
		guild.fill_friends(_friends)

# --- Friends' boxes (round 834; FriendMsgBox, docs/protocol/friends.md) --------

## The Add box's OK: ask this name (World3D.friend_ask).
signal friend_ask_requested(target_name: String)
## The request box's answer (World3D.friend_answer).
signal friend_answer_requested(request: FriendNet.Request, accept: bool)
## The name the Add box starts with: the selected player's (0x5a7160's
## argument), or "" -- World3D sets it.
var selected_player_name := func() -> String: return ""

## The player's own name (World3D sets it at world entry).
var own_name_for_friends := ""
var _friend_request_box: FriendMsgBox
var _friend_request_queue: Array = []

## Box 0x23 for an incoming request. CMessageBoxManager shows one box at a
## time and queues the rest (0x77f0a0); a request that comes while one is
## up waits for it.
func show_friend_request(request: FriendNet.Request) -> void:
	if is_instance_valid(_friend_request_box):
		_friend_request_queue.append(request)
		return
	_open_friend_request(request)

func _open_friend_request(request: FriendNet.Request) -> void:
	if _builder == null or request == null:
		return
	var box := FriendMsgBox.new()
	if not box.build_request(_builder, request):
		box.queue_free()
		return
	box.accepted.connect(func(_t: String) -> void: friend_answer_requested.emit(request, true))
	box.cancelled.connect(func() -> void: friend_answer_requested.emit(request, false))
	box.tree_exited.connect(_next_friend_request)
	box.place_on(get_viewport_rect().size if is_inside_tree() else Vector2(1024, 768))
	add_child(box)
	box.arm_request_timer()
	_friend_request_box = box

func _next_friend_request() -> void:
	_friend_request_box = null
	if not _friend_request_queue.is_empty() and is_inside_tree():
		_open_friend_request(_friend_request_queue.pop_front())

## 0xB302 reason 2 with the flag at 2: box 0x23 closed (c:0x778b90(0x23)).
func close_friend_request() -> void:
	if is_instance_valid(_friend_request_box):
		_friend_request_box.close()

func friend_request_box() -> FriendMsgBox:
	return _friend_request_box if is_instance_valid(_friend_request_box) else null

## Box 0x22: the proposal was accepted.
func show_friend_added(friend_name: String, own_name: String) -> FriendMsgBox:
	if _builder == null:
		return null
	var box := FriendMsgBox.new()
	if not box.build_added(_builder, friend_name, own_name):
		box.queue_free()
		return null
	box.place_on(get_viewport_rect().size if is_inside_tree() else Vector2(1024, 768))
	add_child(box)
	return box

var _friend_add_box: HudCosBox

## The friend pane's Add friend (0x5a7160): the input box, holding the
## selected player's name.
func open_friend_add() -> HudCosBox:
	if is_instance_valid(_friend_add_box):
		_friend_add_box.close()
	if _builder == null:
		return null
	var box := HudCosBox.new()
	if not box.build_friend_add_input(_builder, str(selected_player_name.call())):
		box.queue_free()
		return null
	box.accepted.connect(func(who: String) -> void: friend_ask_requested.emit(who))
	add_child(box)
	box.centre_on(get_viewport_rect().size if is_inside_tree() else Vector2(1024, 768))
	_friend_add_box = box
	return box

## The friend pane's Delete friend (0x5a76c0): GInterface 0x788270, style 1
## (Yes / No), UIIT_STT_CONFIRM_BOX with UIIT_MSG_FRIEND_IDDELET about the
## name; Yes sends 0x7304 (0x5a87c0).
func open_friend_delete(character_id: int, friend_name: String) -> PartyMatchConfirm:
	if _builder == null:
		return null
	var fmt := _builder.resolve_text("UIIT_MSG_FRIEND_IDDELET")
	if fmt == "":
		fmt = "UIIT_MSG_FRIEND_IDDELET"
	var box := PartyMatchConfirm.new()
	if not box.build(_builder, fmt.replace("%s", friend_name) if fmt.count("%s") == 1 else fmt):
		box.free()
		return null
	box.name = "FriendDeleteConfirm"
	box.confirmed.connect(func() -> void: NetClient.friend_delete(character_id))
	add_child(box)
	box.centre_on(get_viewport_rect().size if is_inside_tree() else Vector2(1024, 768))
	return box

## The friend pane's Whisper (0x5a6350): "$name " on the chat line, not for
## the player's own name.
func _friend_whisper(friend_name: String) -> void:
	if friend_name == "" or friend_name == own_name_for_friends:
		return
	_party_match_whisper(friend_name)

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
		NetClient.guild_data.clear()
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
	window.own_name = NetClient.current_character_name
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
		var gold := _set_money_text(inventory, "GDR_INVENTORY_STA_MONEY", stats.gold)
		if gold != null:
			# The number on the authored gold row, so a render's log can be
			# held against the frame (and against the server's own value).
			print("HudPanels: inventory gold readout %s (server gold %d)" % [gold.text, stats.gold])

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
##   Phy./Mag. balance   computed from Str/Int and the level by the client's
##                    own formula (HudPlayerInfo.balance_percent; round 629
##                    READ it in CIFPlayerInfo at 0x006b8ee3..0x006b90fc, the
##                    same code as the player block's). CICPlayer+0x20d8, which
##                    an earlier note called a stored byte of unknown source,
##                    is only its level input: FUN_009d4d50 keeps it at
##                    max(itself, the level).
##
##   Hit rate / Parry    hit_rate / parry_rate: params 11 / 9 as combat places
##                    blows with them (innate 10 + level + the weapon's
##                    HitRateMin / the body armour's parry), retail's 0x303D
##                    +0x14 / +0x16 (round 629's review). OPEN: retail also
##                    adds buffs and masteries to both.
##
## LEFT AS THE LAYOUT DREW THEM, each with its reason:
##   (round 799: the job rows are set_character_job's.)
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
		_set_label(window, "GDR_PI_TEXT_PHYBAL_DAT", "%d %%" % HudPlayerInfo.balance_percent(s.str, s.level, false))
		_set_label(window, "GDR_PI_TEXT_MAGBAL_DAT", "%d %%" % HudPlayerInfo.balance_percent(s.intel, s.level, true))
	else:
		# A server too old to send the rows: the one number it does send.
		_set_label(window, "GDR_PI_TEXT_PHYATT_DAT", str(s.phys_attack))
	if s.has_rates:
		_set_label(window, "GDR_PI_TEXT_HIT_DAT", str(s.hit_rate))
		_set_label(window, "GDR_PI_TEXT_PARRY_DAT", str(s.parry_rate))
	_wire_stat_buttons(window)
	_apply_character_job()
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
	# QA: OPENSRO_QA_SPEND_STAT=1 presses the Str "+" once as soon as there is
	# a point to spend, so a render's log shows the round trip (str +1, pool
	# -1, MaxHP up) against the server's own reply.
	if OS.get_environment("OPENSRO_QA_SPEND_STAT") != "" and not _qa_spent_stat \
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

# --- The job guild (round 799) ------------------------------------------------

## The job windows' builder and host (JobGuildFlow): each box is centred on the
## view as the client's own job windows are (0x798b70).
func job_builder() -> UiBuilder:
	return _builder

func open_job_box(box: PartyMatchBox) -> void:
	box.centre_on(get_viewport_rect().size if is_inside_tree() else Vector2(1024, 768))
	add_child(box)
	# Round 801: an opened window comes out over the COS window (HudCos, a
	# sibling, raises itself the same way; OURS).
	move_to_front()

## The player's race for the class titles (refobj +0x9c: 1 European).
func own_race_europe() -> bool:
	return _skill_race == MasteryReader.RACE_EUROPE

var _job_view := {}

## The character window's job rows, CIFPlayerInfo::vslot_012 (READ
## 0x6b9147..0x6b95fd): the alias (GDR_PI_JOB_ALIAS) or `<%s>` of
## UIIT_STT_NONE; with no job the icon cleared, the title `<%s>` of
## UIIT_STT_NONE, the grade empty, "0%" and an empty gauge; with a job the
## icon com_job_{merchant,thief,hunter}.ddj, the class title by level and
## race, `%d %s` (level, UIIT_STT_GRADE), and `%d%% (%d)` over exp / need, or
## "100%" and a full gauge when the need is -1 (JobText).
func set_character_job(kind: int, level: int, exp: int, alias: String, table: Dictionary) -> void:
	_job_view = {"kind": kind, "level": level, "exp": exp, "alias": alias, "table": table}
	_apply_character_job()

func _apply_character_job() -> void:
	var window: HudWindow = _windows.get("character")
	if window == null or _job_view.is_empty():
		return
	var kind := int(_job_view["kind"])
	var level := int(_job_view["level"])
	var exp := int(_job_view["exp"])
	var alias := String(_job_view["alias"])
	var none := "<%s>" % _resolve_ui("UIIT_STT_NONE", "Nothing")
	_set_label(window, "GDR_PI_JOB_ALIAS", alias if alias != "" else none)
	var icon := window.node("GDR_PI_JOB_ICON")
	var tex: Texture2D = null
	if kind >= 1 and kind <= 3 and _builder != null:
		tex = _builder.load_texture(String(JobText.ICONS[kind]))
	if icon is TextureRect:
		(icon as TextureRect).texture = tex
	elif icon != null:
		var tr := icon.get_node_or_null("JobIcon") as TextureRect
		if tr == null:
			tr = TextureRect.new()
			tr.name = "JobIcon"
			tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
			tr.stretch_mode = TextureRect.STRETCH_KEEP
			icon.add_child(tr)
		tr.texture = tex
	if kind < 1 or kind > 3:
		_set_label(window, "GDR_PI_JOB_TITLE", none)
		_set_label(window, "GDR_PI_JOB_GRADE", "")
		_set_label(window, "GDR_PI_JOB_EXP", "0%")
		_set_gauge(window, "GDR_PI_JOB_EXP_GAUGE", 0, 1)
		return
	var key := JobText.class_key(kind, level, own_race_europe())
	_set_label(window, "GDR_PI_JOB_TITLE", _resolve_ui(key, key))
	_set_label(window, "GDR_PI_JOB_GRADE", "%d %s" % [level, _resolve_ui("UIIT_STT_GRADE", "Level")])
	var need := JobText.need_of(_job_view["table"], kind, level)
	if need == -1 or need == 0xFFFFFFFF:
		_set_label(window, "GDR_PI_JOB_EXP", "100%")
		_set_gauge(window, "GDR_PI_JOB_EXP_GAUGE", 1, 1)
	else:
		_set_label(window, "GDR_PI_JOB_EXP", "%d%% (%d)" % [JobText.percent(exp, need), exp])
		var gauge := window.node("GDR_PI_JOB_EXP_GAUGE") as TextureProgressBar
		if gauge != null:
			gauge.value = JobText.ratio(exp, need) * 100.0
	print("HudPanels: character job: kind %d level %d exp %d alias '%s'" % [kind, level, exp, alias])

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
			# The log is the server's to send (the login section and 0x30D5):
			# nothing to ask (round 785).
			pass
		"skill":
			NetClient.skill_state(who)
		"community":
			# Round 834: the list came at world entry (0x3305) and the pushes
			# keep it; opening the window asks for nothing.
			pass
		# "party": nothing to ask. The window draws the client's own party
		# state (NetClient.party), which the party messages keep current
		# (round 711; the retail window sends no request either).
		"guild":
			NetClient.guild_info(who)
		"character":
			_apply_character_fields()
		"equipment":
			# Fill from what we already have, then ask the server for fresh.
			_fill_equipment_slots(_equipped_items)
			NetClient.list_equipment(who)

## The colour of the text this client draws itself in these windows (the
## talk box's body, the prompts' status lines, the stat labels).
const ROW_TEXT_COLOUR := Color(0.92, 0.88, 0.76)

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
