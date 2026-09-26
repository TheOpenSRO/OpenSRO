extends RefCounted
class_name HudMainPopup

## The client's main popup -- one framed window whose panes are the
## character, inventory with equipment, skill, action, party and academy
## windows, switched by key. Read from sro_client.exe (the decompile in
## /var/tmp/decomp_client and the linear sro_client.asm on the RE box), with
## every number below taken from the code or the archive's layouts; none was
## fitted by eye. docs/RE_COMPLETION.md (the main popup round) has the full
## record.
##
## **What hosts what (read).** The registry entry `GDR_MAINPOPUP` in
## resinfo\ginterface.txt is a `CIFMainPopup` (ID 25, 388x408, on
## `interface\frame\mframe_wnd_`, empty Text). CGInterface keeps it at +0x728
## (fetched with ID 0x19 at 0x78ca87) and hides it at start (0x78cac8). Its
## RTTI chain runs through CIFMainFrame, and `CIFMainPopup::Create` (0x6a2560)
## calls `CIFMainFrame::vslot_010` (0x816f80, the chrome, round 586) first,
## then loads `resinfo\ifmainpopup.txt` (ASCII string at 0xda693c, pushed at
## 0x6a25a3) into itself (`push esi` 0x6a25af) and builds its "Create". That
## section declares one child per pane, each a class that loads its own
## layout into itself (`push esi` right after the load in every one):
##
##   GDR_INVENTORY      CIFInventory     13, 63,176,333  ifinventory.txt   0x6b244b
##   GDR_EQUIPMENT      CIFEquipment    198, 41,178,355  ifequipment.txt   0x6ac1fa
##   GDR_PLAYERINFO     CIFPlayerInfo    13, 38,364,356  ifplayerinfo_trijob2.txt 0x6b84ec
##   GDR_SKILL          CIFSkill         13, 63,364,333  ifskill.txt       0x6a6e17
##   GDR_ACTION         CIFAction        13, 38,364,357  ifaction.txt      0x6a487f
##   GDR_PARTY          CIFParty         13, 38,364,337  ifparty.txt       0x6d6ffa
##   GDR_APPRENTICESHIP CIFApprenticeShip 13,38,365,355  ifapprenticeship.txt 0x6e979f
##   GDR_QUEST          CIFQuest         13, 38,365,355  ifquest.txt       0x6df82b
##
## plus a tab strip of seven 28x28 buttons (IDs 10-16) and a decoration
## (ID 4) hanging left of the window at x -42..-8, and a background tile
## (ID 3, `com_bg_tile_a.ddj`, 40,154,308,124).
##
## **The define.** The panes for the academy and its tab button exist only
## under `#ifdef APPLY_MENTOR_SYSTEM`. Create stores the button (ID 16) at
## +0x7f4 and calls through it with no null check (0x6a28e4, 0x6a2953), and
## the pane hider 0x6a1c70 calls through the academy pane (+0x7d8) the same
## way; a build without the define would crash there. So the branch is taken
## -- inferred from the class code, as round 585 did for the chat (the define
## table itself, 0xeed4e0, is never visibly filled).
##
## **The tab strip is hidden at create and never shown (read).** After
## fetching them Create sets tooltips on the seven buttons and then hides
## each (ShowWindow(0), `push ebx` with ebx 0, 0x6a290b..0x6a295f), and the
## decoration too (ID 4, 0x6a2974). The seven fields are written and read
## only in Create (every `+0x7dc`..`+0x7f4` reference in 0x6a1000-0x6a3000),
## and CGInterface's popup code (every `+0x728` user, 0x78ca87..0x78cb7f and
## 0x79ace0..0x79df53) reaches the popup's children only through 0x6a1cf0,
## which reads a pane's visibility, the pane getters 0x6a1d20..0x6a1e70 and
## the tab selector. So the panes are switched by keys, not by a visible strip. The
## click table the buttons would use (0xeb8058, entries 0x28 apart) maps
## 10 -> character, 11 -> inventory, 12 -> skill, 13 -> action, 14 -> party,
## 15 -> quest and 16 -> academy (the handlers 0x6a24f0..0x6a2550).

const LAYOUT := "resinfo\\ifmainpopup.txt"
const REGISTRY := {"name": "GDR_MAINPOPUP"}
const DEFINES := ["APPLY_MENTOR_SYSTEM"]

## Each pane's own layout, and the class that loads it (see above).
const PANE_LAYOUTS := {
	"GDR_INVENTORY": "resinfo\\ifinventory.txt",
	"GDR_EQUIPMENT": "resinfo\\ifequipment.txt",
	"GDR_PLAYERINFO": "resinfo\\ifplayerinfo_trijob2.txt",
	"GDR_SKILL": "resinfo\\ifskill.txt",
	"GDR_ACTION": "resinfo\\ifaction.txt",
	"GDR_PARTY": "resinfo\\ifparty.txt",
	"GDR_APPRENTICESHIP": "resinfo\\ifapprenticeship.txt",
}

## GDR_QUEST is declared, built by the client and hidden with the rest, but
## nothing this client can reach shows it: its only opener is tab button 15,
## which Create hides, and the Q key goes elsewhere -- 0x7990e0 toggles
## CGInterface's window 0x4c, a different window (the .2dt quest list,
## docs/UI_TODO.md). Its layout is not built here; the `quest` panel keeps
## building ifquest.txt as its own window until that item is done.
const UNHOSTED_PANES := ["GDR_QUEST"]

## Controls CIFMainPopup::Create hides once it has built them (read above).
const HIDDEN_AT_CREATE := ["GDR_BTN_CHAR", "GDR_BTN_INV", "GDR_BTN_SKILL", "GDR_BTN_ACT",
	"GDR_BTN_PARTY", "GDR_BTN_QUEST", "GDR_BTN_APPRENTICE", "GDR_MAINPOPUP_LEFT_DECO_STATIC"]

## The background tile (ID 3), which the tab selector moves per tab.
const BG_TILE := "GDR_MAINPOPUP_BG_TILE"

## The tabs, as the selector 0x6a1f70 runs them. It first hides every pane
## (0x6a1c70), then per tab code (its jump table 0x6a236c, codes 0x46..0x4d):
##
## - stores the tab's index at +0x7fc (the one ShowWindow(1) re-selects);
## - sets the window's caption through slot 45 (0xb4) to a UIIT string;
## - shows the tab's panes (ShowWindow(1));
## - shows or hides the background tile and, for two tabs, moves it with
##   slot 0x98 to the window's position plus an offset and sizes it with
##   slot 21 (0x54) -- inventory: (0xbd, 0x44), 9x0x124, the strip between
##   the bag (13..189) and the equipment frame (198..376); action: (0x28,
##   0x9a), 0x134x0x7c, the layout's own rect;
## - moves the window with slot 0x98: the right-hand tabs to x = screen width
##   - window width - 0x50, the left-hand ones to x = 0x50, keeping y. The
##   screen width is the display mode's +0x24 (0x4f9cd0), read as the width
##   because a centring routine halves it for x and +0x28 for y (0x4f8de3,
##   0x4f8dfc).
##
## `index` is +0x7fc's value, `code` the tab code, `caption` the UIIT key,
## `right` the side, `tile` the tile's rect relative to the window (null:
## hidden). The academy's case shows the tile and then hides it again
## (0x6a2311..0x6a2331), so it ends hidden. Code 0x47 (the equipment pane's
## ID) falls to the jump table's default: no pane, no move.
const TABS := {
	"character": {"index": 0, "code": 0x4b, "panes": ["GDR_PLAYERINFO"],
		"caption": "UIIT_STT_CHARACTER", "right": false, "tile": null},
	"inventory": {"index": 1, "code": 0x46, "panes": ["GDR_INVENTORY", "GDR_EQUIPMENT"],
		"caption": "UIIT_STT_INVENTORY", "right": true, "tile": Rect2(0xbd, 0x44, 9, 0x124)},
	"skill": {"index": 2, "code": 0x49, "panes": ["GDR_SKILL"],
		"caption": "UIIT_STT_SKILL", "right": true, "tile": null},
	"action": {"index": 3, "code": 0x4a, "panes": ["GDR_ACTION"],
		"caption": "UIIT_STT_ACTION", "right": true, "tile": Rect2(0x28, 0x9a, 0x134, 0x7c)},
	"party": {"index": 4, "code": 0x48, "panes": ["GDR_PARTY"],
		"caption": "UIIT_STT_PARTY", "right": true, "tile": null},
	"academy": {"index": 6, "code": 0x4d, "panes": ["GDR_APPRENTICESHIP"],
		"caption": "UIIT_CTL_TC_TRAININGCAMP", "right": false, "tile": null},
}

## Panel ids that are other names for a tab. The equipment key lands on the
## inventory tab: CGInterface's equipment toggle (0x79ad70) checks the
## inventory pane and selects code 0x46, which shows both.
const ALIASES := {"equipment": "inventory"}

## The window's distance from the screen edge its tab puts it against.
const SIDE_MARGIN := 0x50

## The first tab: the constructor (0x6a1bc0) clears +0x7fc, and index 0 is
## the character tab.
const FIRST_TAB := "character"

var window: HudWindow = null
var current := FIRST_TAB
## Where the window should be: the selector's x, and y from the registry's 262
## or wherever the player last dragged it. keep_on_screen draws this, clamped;
## the clamp never feeds back into it, so a clamp for a small viewport is
## undone when the viewport grows again.
var wanted := Vector2.ZERO
var _builder: UiBuilder = null
var _captions := {}
## A tab's caption when the text table cannot resolve its UIIT key: the
## panel's own title (HudPanels.PANELS), tab -> title.
var fallback_titles := {}

## Whether a panel id is one of the popup's tabs.
static func hosts(panel_id: String) -> bool:
	return TABS.has(tab_of(panel_id))

## The tab a panel id selects (an alias resolved), or the id itself.
static func tab_of(panel_id: String) -> String:
	return ALIASES.get(panel_id, panel_id)

## Builds the popup into `win` (a fresh HudWindow): the registry frame and
## CIFMainFrame chrome, ifmainpopup's Create with APPLY_MENTOR_SYSTEM, and
## each hosted pane's own layout at the pane's origin, `extra_sections`
## (pane name -> section names) built into the same pane. Returns false,
## having built nothing usable, when the popup's layout is missing.
func build(builder: UiBuilder, win: HudWindow, title: String,
		extra_sections: Dictionary = {}) -> bool:
	_builder = builder
	window = win
	if not win.build(builder, LAYOUT, title, PackedStringArray(), PackedStringArray(DEFINES),
			true, REGISTRY):
		return false
	for pane_name in PANE_LAYOUTS:
		var pane := pane_control(pane_name)
		if pane == null:
			continue
		# A pane is a CIFWnd with no art of its own; it passes clicks to its
		# children and the window behind it.
		pane.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var layout := builder.load_layout(PANE_LAYOUTS[pane_name])
		if layout == null:
			push_warning("HudMainPopup: %s has no layout %s" % [pane_name, PANE_LAYOUTS[pane_name]])
			continue
		var root := builder.build_section(layout, "Create")
		if root == null:
			continue
		for extra in extra_sections.get(pane_name, []):
			var extra_root := builder.build_section(layout, extra)
			if extra_root != null:
				root.add_child(extra_root)
		pane.add_child(root)
		UiBuilder.settle_authored_rects(root)
	for control_name in HIDDEN_AT_CREATE:
		var node := win.node(control_name) as CanvasItem
		if node != null:
			node.visible = false
	# Every pane is hidden until a tab shows it (0x6a1c70), the quest pane
	# included.
	for pane_name in PANE_LAYOUTS.keys() + UNHOSTED_PANES:
		var pane := pane_control(pane_name)
		if pane != null:
			pane.visible = false
	var reg := win.registry_def
	if reg != null:
		# The window's starting y is its registry rect's; x follows the tab.
		wanted.y = reg.rect.position.y
		win.position.y = wanted.y
	var vp := win.get_viewport()
	if vp != null:
		vp.size_changed.connect(keep_on_screen)
	# A drag is the player's own placement: it becomes the wanted position.
	win.dragged.connect(func() -> void: wanted = win.position)
	return true

## **Our deviation, not the client's.** The selector's placement (x at the
## screen's right less 0x50 or at 0x50, y from the registry's 262) assumes
## the client's own screen sizes. Here the logical viewport can be smaller:
## the project's default window is 1152x648, and the F3 UI scale (0.5-3.0)
## divides the window's size. At y 262 the 408-tall window needs a logical
## height of 670, so it overflows at 1152x648, at 1366x768 above scale
## ~1.15 and at 1920x1080 above ~1.61; either x needs a logical width of 468.
## So after every placement, and whenever the viewport resizes, the window is
## pulled back inside the viewport (to the top or left edge when it cannot
## fit). The client does none of this. What is clamped is `wanted`, never the
## drawn position, so growing the viewport again brings the window back to
## where the selector (or the player) put it.
func keep_on_screen() -> void:
	if window == null or not window.is_inside_tree():
		return
	var view := window.get_viewport_rect().size
	window.position = Vector2(
		clampf(wanted.x, 0.0, maxf(0.0, view.x - window.size.x)),
		clampf(wanted.y, 0.0, maxf(0.0, view.y - window.size.y)))

## The pane control the layout declared under `pane_name`, or null.
func pane_control(pane_name: String) -> Control:
	if window == null or window.panel_root == null:
		return null
	return window.panel_root.get_node_or_null(pane_name) as Control

## Whether `panel_id`'s tab is the one showing (the window may be hidden).
func tab_shown(panel_id: String) -> bool:
	var tab := tab_of(panel_id)
	if not TABS.has(tab):
		return false
	for pane_name in TABS[tab]["panes"]:
		var pane := pane_control(pane_name)
		if pane == null or not pane.visible:
			return false
	return true

## Whether the window is on screen with `panel_id`'s tab showing.
func is_open(panel_id: String) -> bool:
	return window != null and window.visible and tab_shown(panel_id)

## Selects a tab exactly as 0x6a1f70 does (see TABS).
func select(panel_id: String) -> void:
	var tab := tab_of(panel_id)
	if window == null or not TABS.has(tab):
		return
	var spec: Dictionary = TABS[tab]
	current = tab
	for pane_name in PANE_LAYOUTS.keys() + UNHOSTED_PANES:
		var pane := pane_control(pane_name)
		if pane != null:
			pane.visible = false
	window.set_title(_caption(spec["caption"], fallback_titles.get(tab, "")))
	for pane_name in spec["panes"]:
		var pane := pane_control(pane_name)
		if pane != null:
			pane.visible = true
	var tile := window.node(BG_TILE) as Control
	if tile != null:
		var rect = spec["tile"]
		tile.visible = rect != null
		if rect != null:
			var r: Rect2 = rect
			tile.set_meta(UiBuilder.AUTHORED_RECT_META, r)
			tile.custom_minimum_size = Vector2.ZERO
			tile.position = r.position
			tile.size = r.size
	var view_w := window.get_viewport_rect().size.x
	if spec["right"]:
		wanted.x = view_w - window.size.x - SIDE_MARGIN
	else:
		wanted.x = SIDE_MARGIN
	keep_on_screen()

## Shows the window for `panel_id` the way the key handlers do (C 0x79ace0,
## I 0x79b020, S 0x79ae00, A 0x79d5b0, P 0x79ae90, L 0x79b0b0): ShowWindow(1)
## re-selects the current tab (CIFMainPopup::vslot_023, 0x6a2390), then the
## key's tab is selected unless its pane is already the one showing.
func open(panel_id: String) -> void:
	if window == null:
		return
	window.show()
	select(current)
	if not tab_shown(panel_id):
		select(panel_id)
	window.move_to_front()

## The key handlers' toggle: with the window up and the key's pane showing,
## the key hides the window; otherwise it opens it on that tab.
func toggle(panel_id: String) -> void:
	if is_open(panel_id):
		window.hide()
		return
	open(panel_id)

## The client's caption for a tab, resolved through the text table, or the
## fallback when the table does not know the key.
func _caption(key: String, fallback: String) -> String:
	if _captions.has(key):
		return _captions[key]
	var text := fallback if fallback != "" else key
	if _builder != null:
		var resolved := _builder.resolve_text(key)
		if resolved != "" and resolved != key:
			text = resolved
	_captions[key] = text
	return text
