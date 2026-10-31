extends RefCounted
class_name KeyMap

## The keyboard, in one table (round 608). Every key the game answers is
## here, and nowhere else: HudPanels asks it which window a key opens,
## KeyInput asks it what every other key does, and HudUnderbar asks it which
## key to name in a caption.
##
## **SLOTS is the retail client's own key table**, slot for slot. Its
## defaults are the 33 dwords `0x7778b0(buf, 0x21)` writes (the asm at
## 0x7778be..0x777991); `0x778310` turns a slot into a fixed command code, the
## slot's default virtual key, so a rebound key still reaches the same
## handler; the key-down dispatcher `0x780610` runs that command. The row
## label is the option window's own label for the slot (`0x5fb9e0`, which
## writes one label per row; `0x5f68e0` copies the 33 live keys into row i,
## so row i is slot i). The retail option window rebinds these rows and
## saves them to `Setting\SROptionSet.dat` (`0x5f7ce0`). Round 833 built that
## window's Key Map tab (OptionKeyPage): `key` below is the slot's DEFAULT,
## and key_of_slot the live one (saved in ClientSettings, not the retail
## file). A rebinding changes the key and nothing else: a slot's action, like
## its retail command, does not move with the key. Round 841 added one OURS
## slot after the 33, the stall network on F (slot 33, `"ours": true`).
##
## Each slot's `state`:
## - "works": the key does what the retail handler does, as far as this
##   client has the feature (the slot's comment says where it stops short);
## - "noop": the feature is not in this client;
##   the key is bound, logs what it would do, and does nothing else;
## - "unbound": retail gives the slot no default key (0 in the defaults).
##
## Addresses are sro_client.exe's (md5 2a5794b72c90908d945be8b3f3f2edd4).
## "read" = from the binary at the address; "inferred" = concluded from what
## was read, with the reason given; "ours" = this project's choice.
const SLOTS: Array = [
	# 0x79ace0 toggles the main popup's character tab (read, round 587).
	{"slot": 0, "key": KEY_C, "cmd": 0x43, "row": "UIIT_STT_CHARACTER", "action": "panel:character", "state": "works"},
	# 0x79b020 toggles the inventory tab (read).
	{"slot": 1, "key": KEY_I, "cmd": 0x49, "row": "UIIT_STT_INVENTORY", "action": "panel:inventory", "state": "works"},
	# 0x79ae00 toggles the skill tab (read).
	{"slot": 2, "key": KEY_S, "cmd": 0x53, "row": "UIIT_STT_SKILL", "action": "panel:skill", "state": "works"},
	# 0x79d5b0 toggles the action tab: emotes and the sit button (read).
	{"slot": 3, "key": KEY_A, "cmd": 0x41, "row": "UIIT_STT_ACTION", "action": "panel:action", "state": "works"},
	# 0x79ae90 toggles the party tab (read).
	{"slot": 4, "key": KEY_P, "cmd": 0x50, "row": "UIIT_STT_PARTY", "action": "panel:party", "state": "works"},
	# 0x7990e0 toggles quest window 0x4c (read).
	{"slot": 5, "key": KEY_Q, "cmd": 0x51, "row": "UIIT_STT_QUEST", "action": "panel:quest", "state": "works"},
	# 0x799120 -> 0x5b4980 opens the guild view of the guild/community window
	# (read). No default key opens the community view.
	{"slot": 6, "key": KEY_U, "cmd": 0x55, "row": "UIIT_STT_COMMUNITY", "action": "panel:guild", "state": "works"},
	# 0x79abe0 toggles the world map (read).
	{"slot": 7, "key": KEY_M, "cmd": 0x4d, "row": "UIIT_STT_WORLDMAP", "action": "worldmap", "state": "works"},
	# 0x778ac0: berserk. With the player's +0x886 gauge at 5 or more it calls
	# 0x81e690(1), which sends 0x70a7 (read). Here the server judges the
	# gauge and answers "not full yet" (World3D's berserk_result handler).
	{"slot": 8, "key": KEY_TAB, "cmd": 0x09, "row": "UIIT_STT_HWANMODE", "action": "berserk", "state": "works"},
	# 0x79f690 toggles child 0x20, GDR_GAMEGUIDE, the client's help window:
	# shown, then raised with 0x79a7e0; or hidden, and 0x79a7e0 run on the
	# system window 0x62 (read). H toggles HelpWindow, which is built in
	# GDR_GAMEGUIDE's own registry frame (help_window.gd's REGISTRY); what it
	# shows inside is this project's documents (ours), and the second step on
	# window 0x62 is not built.
	{"slot": 9, "key": KEY_H, "cmd": 0x48, "row": "UIIT_STT_HELP", "action": "help", "state": "works"},
	# Held: key-down sets DAT_00eef5f5 (0x780a91), key-up clears it
	# (0x77d8d0). While it is set, CIItem::vslot_010 (0x9e15b0) draws a
	# dropped item's name when the item is under 300.0 units away (.rdata
	# 0xd85224, `+0x24c < 300`, strict) (read).
	{"slot": 10, "key": KEY_Z, "cmd": 0x5a, "row": "UIIT_STT_VIEW_DROPPED_ITEM", "action": "item_names", "state": "works", "hold": true},
	# 0x7994e0 -> 0x60bb80(0): fires quick slot 0, the "m" slot (read).
	# TTDESC_09: "Use corresponding button for skill use instead of mouse
	# right button."
	{"slot": 11, "key": KEY_X, "cmd": 0x58, "row": "UIIT_STT_MOUSE_RIGHT_BUTTON", "action": "mouse_slot", "state": "works"},
	# 0x793b00(0x64, 1000) -> 0x9d4a20: sit or stand, 0x704f [04] (read;
	# round 607 built it).
	{"slot": 12, "key": KEY_N, "cmd": 0x4e, "row": "UIIT_STT_TOGGLE_CONTENTS_MENU_SITDOWNSTAND", "action": "sit", "state": "works"},
	# 0x793b00(0x64, 0x3f0) -> 0x9e18f0: the nearest CIItem strictly within
	# 50.0 units (.rdata 0xd851a0), 3-D, then 0x7074 [01 02 01 <u32 uid>]
	# (read). Here: the same search, then this client's own pick path (a walk
	# into the server's 10-unit reach, then its pick request) -- the retail
	# 0x7074 leaves the approach to the server (inferred), which this
	# server does not do.
	{"slot": 13, "key": KEY_G, "cmd": 0x47, "row": "UIIT_STT_TOGGLE_CONTENTS_MENU_AUTOGET", "action": "pickup", "state": "works"},
	# Slots 14..19 are the COS (pet and vehicle) commands through
	# 0x7a0980(n) on the current COS (round 795, HudCos.run_command).
	# Ins: 0x799360 -> 0x811310(0, 0xff) -> 0x7a0980(0), the COS info window
	# (label read; the case body inferred).
	{"slot": 14, "key": KEY_INSERT, "cmd": 0x2d, "row": "UIIT_STT_OPTION_COS_INFO", "action": "pet_info", "state": "works"},
	# Home: 0x7a0980(1), ride or dismount (0x81eb50). Label read.
	{"slot": 15, "key": KEY_HOME, "cmd": 0x24, "row": "UIIT_STT_OPTION_COS_RIDE", "action": "pet_ride", "state": "works"},
	# PgUp: 0x811350 -> 0x7a0980(4 or 5 by COS kind), unsummon. Label read.
	{"slot": 16, "key": KEY_PAGEUP, "cmd": 0x21, "row": "UIIT_STT_OPTION_COS_SUMMONCANCEL", "action": "pet_unsummon", "state": "works"},
	# Del: 0x7a0980(3), follow, sends 0x70c5. Label read.
	{"slot": 17, "key": KEY_DELETE, "cmd": 0x2e, "row": "UIIT_STT_OPTION_COS_FOLLOW", "action": "pet_follow", "state": "works"},
	# End: 0x7a0980(2), attack the target, sends 0x70c5. Label read.
	{"slot": 18, "key": KEY_END, "cmd": 0x23, "row": "UIIT_STT_OPTION_COS_ATTACK", "action": "pet_attack", "state": "works"},
	# PgDn: 0x7a0980(6), toggles the COS AI (0x81ea70). Label read.
	{"slot": 19, "key": KEY_PAGEDOWN, "cmd": 0x22, "row": "UIIT_STT_OPTION_COS_AI", "action": "pet_ai", "state": "works"},
	# Chat child 1 -> 0x7aa2b0 copies the chat board's +0x4b0 string; when it
	# is not empty, 0x777d10 -> 0x7ab470 puts a line into the chat's input
	# box (vslot 0xb4 on +0x4a0) unless the name is the player's own (read).
	# That +0x4b0 is the last whisperer is inferred, from TTDESC_14 ("You
	# can send whisper directly to character who sent you the whisper").
	{"slot": 20, "key": KEY_R, "cmd": 0x52, "row": "UIIT_CTL_REPLY_TT", "action": "whisper_reply", "state": "works"},
	# Child 0x87 -> 0x79c750 toggles the auto-potion window (read).
	{"slot": 21, "key": KEY_T, "cmd": 0x54, "row": "UIIT_PAG_MACROPOTION_TITLE", "action": "panel:autopotion", "state": "works"},
	# 0x811200 walks the COS list at +0x374 and switches to the next one
	# (0x810fd0) (read; round 795, HudCos.switch_next).
	{"slot": 22, "key": KEY_W, "cmd": 0x57, "row": "UIIT_STT_OPTION_COS", "action": "pet_switch", "state": "works"},
	# Child 0x82 -> 0x79c170 toggles party matching (read).
	{"slot": 23, "key": KEY_E, "cmd": 0x45, "row": "UIIT_CTL_PARTYMATCH_MAINBUTTEN", "action": "panel:partymatch", "state": "works"},
	# 0x798e20 toggles the alchemy window 0xa8 (read, round 604).
	{"slot": 24, "key": KEY_Y, "cmd": 0x59, "row": "UIIT_CTL_ALCHEMYBOX", "action": "panel:alchemy", "state": "works"},
	# 25..28 have no default key (read: 0 in the defaults).
	# 0x77c9f0: the nearest hostile CICUser (read).
	{"slot": 25, "key": KEY_NONE, "cmd": 0x8019, "row": "UIIT_STT_ENEMYUSER_SELECT_KEY", "action": "select_enemy_player", "state": "unbound"},
	# Re-selects the last target, +0x630 (read).
	{"slot": 26, "key": KEY_NONE, "cmd": 0x801a, "row": "UIIT_STT_LATEST_TARGET", "action": "select_last_target", "state": "unbound"},
	# Assist: 0x30c4 <u32 id> for a selected CICUser (read).
	{"slot": 27, "key": KEY_NONE, "cmd": 0x801b, "row": "UIIT_STT_ASSIST_TARGET", "action": "assist_target", "state": "unbound"},
	# 0x77b7d0(+0x628): face the target (label read).
	{"slot": 28, "key": KEY_NONE, "cmd": 0x801c, "row": "UIIT_STT_FACE_TARGET", "action": "face_target", "state": "unbound"},
	# Held: key-down sets DAT_00eef5f4 (0x7809c4), key-up clears it
	# (0x77d8d0). While it is set the predicate 0x9d0560 hides other players
	# (exactly CICUser), monsters, CICMonsterNPC, CICRide, and every COS but
	# the one the player rides, and 0x9dd350 skips the stall booth (read);
	# hides_under_v has the rule. "Hide Object".
	{"slot": 29, "key": KEY_V, "cmd": 0x56, "row": "UIIT_STT_USER_MOSTER_BLIND", "action": "hide_objects", "state": "works", "hold": true},
	# 0x79b0b0 toggles the academy tab (read).
	{"slot": 30, "key": KEY_L, "cmd": 0x4c, "row": "UIIT_CTL_TC_TRAININGCAMP", "action": "panel:academy", "state": "works"},
	# 31 and 32 have no default key. They TOGGLE DAT_00eef5f6 / f7, hiding
	# objects whose relation code (0x998280(+0x7a0)) is 0xc9/0xcb or
	# 0xca/0xcc (0x9c6eb0, read; what the codes mean is not read).
	{"slot": 31, "key": KEY_NONE, "cmd": 0x801f, "row": "UIIT_STT_BLIND_ALLY", "action": "hide_allies", "state": "unbound"},
	{"slot": 32, "key": KEY_NONE, "cmd": 0x8020, "row": "UIIT_STT_BLIND_ENEMY", "action": "hide_enemies", "state": "unbound"},
	# Round 841 (lane K), OURS: the stall network, default F -- the one slot
	# past the retail 33 ("ours": true). The original has no key for it
	# (READ: no 0x46 in 0x7778b0's 33 defaults; 0x780610 has no command 0x46
	# and never calls FUN_00799020, whose only caller with 1 is the underbar's
	# hidden item 120, c:0x60ceeb; the WM_CHAR handler 0x78b660 and the key-up
	# handler 0x77d8d0 do not either). Its archive does carry the key's text,
	# unused by the exe (MEASURED, docs/protocol/stall_network.md §0):
	# UIIT_STT_WARENETWORK_TITLE_SHOTCUT "Stall network ( F )" -- hence F --,
	# UIIT_STT_TOGGLE_CONTENTS_MENU_STORENET "Stall network ( %s )" and
	# UIIT_STT_INPUT_TTDESC_31. The row's label is the window's own title,
	# UIIT_STT_WARENETWORK_TITLE "Stall network". F toggles the window
	# (World3D "stall_network" -> StallNetworkController.toggle): open is
	# item 120's FUN_00799020(1) with its town rule and refusal, and with the
	# window up it is 0x799020(0) -- the toggle INFERRED from the retail keys
	# for windows the menu only opens: Y tests window 0xa8 and calls
	# 0x798e20(0) or 0x798e20(1) (READ, 0x780a65..0x780a8c). `cmd` -1: no
	# retail command code.
	{"slot": 33, "key": KEY_F, "cmd": -1, "row": "UIIT_STT_WARENETWORK_TITLE", "action": "stall_network", "state": "works", "ours": true},
]

## The retail table's size: 0x7778b0 writes 33 defaults (READ), and
## ClientSettings held 33 keys before round 841. Slots from here on are OURS.
const RETAIL_SLOTS := 33

## The keys the dispatcher 0x780610 answers outside the slot table, and the
## few this client adds (read unless marked). Kept as a list so the help and
## a future rebinding window can show them; resolve() is what acts on them.
## `mods` is "", "ctrl", "alt" (ours) or "space" (Space held, as GetKeyState(VK_SPACE) at
## 0x780c11 tests it).
const OTHER_KEYS: Array = [
	# 0x60a730(0..3): quick-slot pages 1..4 (raw-VK table 0x780da8/0x780d78).
	{"keys": "F1-F4", "mods": "", "action": "page", "source": "read 0x60a730(0..3)"},
	# '1'..'9' -> 1..9, '0' -> 10 (0x780c47), then 0x60bb80(k), which adds
	# page x 10 for k < 11.
	{"keys": "1-9, 0", "mods": "", "action": "quickslot_key", "source": "read 0x60bb80(1..10)"},
	# With Space held, edi = 0x28 (0x780c1c): 0x60bb80(0x28 + k), and k >= 11
	# is taken as it is -- quick slots 41..50, which no page shows.
	{"keys": "1-9, 0", "mods": "space", "action": "quickslot", "source": "read 0x780c11, 0x60bb80(41..50)"},
	# The first OURS extra quick-slot bar (round 788, HudExtQuickSlots): its
	# page's slot k. Retail's Alt+digit is unread.
	{"keys": "1-9, 0", "mods": "alt", "action": "ext_quickslot", "source": "ours (round 788)"},
	# Ctrl held (GetKeyState(VK_CONTROL), 0x780c21) and '1'..'8' (the range
	# test `key - 0x31 < 8`): 0x77f230. '1' selects the player
	# (0x78f5f0(player+0xf8)); '2'..'8' select the quick party window's
	# member n-2 by name (0x6da850, 0x9c3640).
	{"keys": "1", "mods": "ctrl", "action": "select_self", "source": "read 0x77f230"},
	{"keys": "2-8", "mods": "ctrl", "action": "select_party", "source": "read 0x77f230 -> 0x6da850(n-2)"},
	# 0x780590(-1): the next camera view, free -> third person -> quarter ->
	# free, each announced by 0x780420's UIIT_STT_CHANGED_SIGHT_*_DESC line.
	{"keys": "F9", "mods": "", "action": "camera_cycle", "source": "read 0x780590(-1) -> 0x780420"},
	# Round 837: F10 is the item mall, as retail's (0x780610 -> 0x7807aa:
	# the "Enter Item Mall" box, kind 0x1e, when the mall is not open and no
	# such box is up; UIIT_STT_SILKMALL_SHORT_KEY "Item Mall(F10)"). The
	# Hide UI F10 used to run moved to Shift+F10 (ours; the user's choice).
	{"keys": "F10", "mods": "", "action": "item_mall", "source": "read 0x780610 -> 0x7807aa"},
	{"keys": "F10", "mods": "shift", "action": "hide_ui", "source": "ours (round 837; F10 before)"},
	# WM_KEYUP of VK_SNAPSHOT (0x2c) in the frame's message handler 0xba7240
	# saves `ScreenShot\SRO[YYYY-MM-DD hh-mm-ss]_NN.jpg` -- on the release.
	{"keys": "PrintScreen", "mods": "", "action": "screenshot", "source": "read 0xba7240"},
	# The developer toggle (ours): Shift+F3, the debug panel, only where
	# DevTools.enabled() (round 848; Shift+F1's zone box and Log Out and
	# Shift+F2's debug tabs went with the prototype's native UI). Retail
	# reads no modifier on an F key, so elsewhere Shift+F1-F3 are F1-F3.
	{"keys": "F3", "mods": "shift", "action": "debug_panel", "source": "ours (developer builds only)"},
	# Enter (char 0x0d, 0x78b660 -> 0x7a9a70) opens the chat line -- HudChat,
	# round 606. Escape (char 0x1b, 0x79d620) closes the top window or opens
	# the system menu -- HudPanels, round 600. Listed, not dispatched here.
	{"keys": "Enter", "mods": "", "action": "chat", "source": "read 0x78b660 (HudChat)"},
	{"keys": "Escape", "mods": "", "action": "escape", "source": "read 0x79d620 (HudPanels)"},
]

## The retail keys this client does not bind, and why (for the help and the
## records).
##
## - The arrows are bound since round 808, at the user's request (round 608
##   had left them out believing them WASD-like): Up runs along the facing and
##   Left/Right turn at pi rad/s, through KeyInput's "arrow" path, not a table
##   slot (World3D._on_arrow_key has the reading: 0x780610 / 0x77d8d0, the
##   0x7021 / 0x7023 / 0x7024 sends). Down stays here: it has no key-down case
##   at all (index 3 of 0x780da8 is the default), and its key-up case,
##   0x9ebb90(2), acts on no bit.
## - F12 (0x79e1a0) was not identified. F5-F8 and F11 do nothing.
const NOT_BOUND := ["Down", "F12"]

static var _by_key: Dictionary = {}

## Round 833: the live keys, slot -> keycode, where they differ from SLOTS'
## defaults -- the Option window's Key Map tab rebinds a slot's key and
## nothing else (its action and command stay, as 0x778310's do). Saved in
## ClientSettings (SECTION_KEYMAP, all the table's keys in slot order -- 33
## before round 841, migrate() fills a shorter save); loaded once.
static var _bound: Dictionary = {}
static var _loaded := false
## Round 833: while the Option window's Key Map tab waits for a key, the
## callable that takes it (keycode -> bool, true when it took the key);
## KeyInput asks it before anything else.
static var capture: Callable = Callable()

## The key a slot answers to now (KEY_NONE when it has none).
static func key_of_slot(slot: int) -> int:
	_ensure_loaded()
	if _bound.has(slot):
		return int(_bound[slot])
	return int(SLOTS[slot]["key"]) if slot >= 0 and slot < SLOTS.size() else KEY_NONE

## The default keys, in slot order (0x7778b0's 33 dwords, then the OURS slots).
static func default_keys() -> PackedInt32Array:
	var out := PackedInt32Array()
	for slot in SLOTS:
		out.append(int(slot["key"]))
	return out

## The live keys, in slot order.
static func live_keys() -> PackedInt32Array:
	var out := PackedInt32Array()
	for i in SLOTS.size():
		out.append(key_of_slot(i))
	return out

## Puts `keys` (SLOTS.size(), slot order) in force, and saves them when `save`.
static func set_keys(keys: PackedInt32Array, save: bool = true) -> void:
	_loaded = true
	_bound.clear()
	for i in mini(keys.size(), SLOTS.size()):
		if int(keys[i]) != int(SLOTS[i]["key"]):
			_bound[i] = int(keys[i])
	_by_key.clear()
	if save:
		ClientSettings.set_value(ClientSettings.SECTION_KEYMAP, ClientSettings.KEY_KEYMAP_SLOTS, Array(keys))

static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	var saved = ClientSettings.get_value(ClientSettings.SECTION_KEYMAP, ClientSettings.KEY_KEYMAP_SLOTS, null)
	if saved is Array and (saved as Array).size() >= RETAIL_SLOTS and (saved as Array).size() <= SLOTS.size():
		set_keys(migrate(PackedInt32Array(saved)), false)

## Round 841 (OURS): a saved key map from before a slot was added (the 33
## retail keys before the stall network's slot 33) made whole. Each missing
## slot gets its default key unless the saved keys already give that key to
## another row -- a key is never bound twice -- in which case it starts
## unbound. Kept in memory; the next Apply saves the full table.
static func migrate(saved: PackedInt32Array) -> PackedInt32Array:
	var out := saved.duplicate()
	if out.size() > SLOTS.size():
		out.resize(SLOTS.size())
	for i in range(out.size(), SLOTS.size()):
		var k := int(SLOTS[i]["key"])
		out.append(KEY_NONE if k != KEY_NONE and out.has(k) else k)
	return out

## Back to the defaults in memory only (tests).
static func reset_to_defaults_unsaved() -> void:
	set_keys(default_keys(), false)

## The slot a key is bound to now, or null. Keys are Godot keycodes (the
## retail table follows the key's scan code, 0xba62d0; that bindings follow
## key position is inferred and not copied here).
static func slot_for_key(keycode: int) -> Variant:
	_ensure_loaded()
	if _by_key.is_empty():
		for slot in SLOTS:
			var k := key_of_slot(int(slot["slot"]))
			if k != KEY_NONE:
				_by_key[k] = slot
	return _by_key.get(keycode)

## The key bound to an action (e.g. "panel:skill") now, or KEY_NONE.
static func key_for(action: String) -> int:
	for slot in SLOTS:
		if slot["action"] == action:
			return key_of_slot(int(slot["slot"]))
	return KEY_NONE

## The slot whose action is `action`, or null.
static func slot_for_action(action: String) -> Variant:
	for slot in SLOTS:
		if slot["action"] == action:
			return slot
	return null

## The panel id a plain key opens (the "panel:" slots), or "".
static func panel_for_key(keycode: int) -> String:
	var slot = slot_for_key(keycode)
	if slot == null or not String(slot["action"]).begins_with("panel:"):
		return ""
	return String(slot["action"]).substr(6)

## Whether a key-down is a hold (V, Z): acting while held, not per press.
static func is_hold(action: String) -> bool:
	var slot = slot_for_action(action)
	return slot != null and bool(slot.get("hold", false))

## What a key press does: [action, arg], or [] when nothing.
##
## `space_held`: whether Space is down (the Space+digit quick slots).
##
## **Modifiers, as retail reads them.** Neither 0x778310 nor 0x780610 tests
## a modifier for a table key or an F-key (read), so Ctrl, Shift and Alt
## change nothing there: Ctrl+S opens the skill window, Ctrl+G picks up.
## The only modifier retail reads is in the path for keys the table does
## not bind (0x778310 returned -1): GetKeyState(VK_SPACE) at 0x780c11 and
## GetKeyState(VK_CONTROL) at 0x780c21, where Ctrl+'1'..'8' selects and
## Ctrl+'9'/'0' does nothing; the digits are that path. Ours on top: Shift+F3
## is the debug panel where DevTools.enabled() (in retail it is F3, the page;
## round 699 moved the developer toggles from Ctrl, which macOS keeps for
## itself -- Ctrl+F1/F2/F3 are its keyboard-access, menu-bar and Dock
## shortcuts, so under CrossOver they never reached the game; round 848 kept
## Shift+F3 alone, and only in a developer build, so Shift+F1, Shift+F2 and a
## release build's Shift+F3 are retail's pages), Shift+F10 hides the
## interface, and a key with Meta (the Windows key) does nothing -- the OS
## owns those. Alt: the retail message map (0xd71100) registers WM_CHAR,
## WM_KEYDOWN and WM_KEYUP only, and Win32 sends a key with Alt held (and F10)
## as WM_SYSKEYDOWN; since 0x780610 does have an F10 case, how system keys
## reach it was not read. Alt is treated like Ctrl and Shift here (the
## user's "as the original"), except for the three window combinations the
## OS owns, which do nothing (is_os_combination; ours). PrintScreen resolves
## on its release only (resolve_release).
static func resolve(keycode: int, ctrl: bool, alt: bool, meta: bool, space_held: bool, shift := false) -> Array:
	if meta or is_os_combination(keycode, alt):
		return []
	if shift:
		match keycode:
			KEY_F3:
				if DevTools.enabled():
					return ["debug_panel", 0]
			KEY_F10:
				return ["hide_ui", 0]
	if ctrl:
		var d := _digit(keycode)
		if d == 1:
			return ["select_self", 0]
		if d >= 2 and d <= 8:
			return ["select_party", d - 1]
		if d >= 0:
			return []
	if keycode >= KEY_F1 and keycode <= KEY_F4:
		return ["page", keycode - KEY_F1 + 1]
	var digit := _digit(keycode)
	if digit >= 0:
		# k = 1..9 for '1'..'9', 10 for '0'.
		if space_held:
			return ["quickslot", 40 + digit]
		# OURS (round 788): Alt+digit fires the first extra quick-slot bar's
		# slot k on its page (HudExtQuickSlots). Retail's own Alt+digit is
		# unread (its message map has no WM_SYSKEYDOWN); every other
		# modifier+digit is taken -- Space (41..50) and Ctrl (select) by
		# retail, Shift by retail's plain digit (0x780610 tests no Shift).
		if alt:
			return ["ext_quickslot", digit]
		return ["quickslot_key", digit]
	if keycode == KEY_F9:
		return ["camera_cycle", 0]
	if keycode == KEY_F10:
		return ["item_mall", 0]
	var slot = slot_for_key(keycode)
	if slot == null:
		return []
	return [String(slot["action"]), int(slot["slot"])]

## The OS's window combinations, left to the OS (ours): Alt+Tab (switching
## away must not burn the berserk gauge), Alt+F4 (closing must not select
## page 4) and Alt+Space (the window menu must not start a Space chord).
## Retail's handling of them is unread: its message map (0xd71100)
## registers no WM_SYSKEYDOWN/WM_SYSKEYUP.
static func is_os_combination(keycode: int, alt: bool) -> bool:
	return alt and keycode in [KEY_TAB, KEY_F4, KEY_SPACE]

## Whether a key still runs while a text line has the keyboard: the keys a
## line never takes -- F1-F12 (with or without a modifier) and PrintScreen. Letters,
## digits, Tab, Space and the editing keys go to the line. Ours: retail's
## +0x3ce flag, which makes 0x778310 return -1 for the letter scan codes
## (0x10-0x19, 0x1e-0x26, 0x2c-0x32; the table at 0x77856c, read) and lets
## the digits through, is not known to mean "typing" -- the key-up handler
## 0x77d8d0 also branches on it to change a speed value on numpad 1-4 and to
## Beep and dump the camera on F8, which looks like a developer camera mode.
static func runs_while_typing(keycode: int) -> bool:
	return (keycode >= KEY_F1 and keycode <= KEY_F12) or keycode == KEY_PRINT

## What a key release does: PrintScreen saves a screenshot on WM_KEYUP
## (0xba7240 tests message 0x101 with wParam 0x2c, read).
static func resolve_release(keycode: int) -> Array:
	if keycode == KEY_PRINT:
		return ["screenshot", 0]
	return []

## '1'..'9' -> 1..9 and '0' -> 10 (0x780c47's jump table), else -1.
static func _digit(keycode: int) -> int:
	if keycode >= KEY_1 and keycode <= KEY_9:
		return keycode - KEY_0
	if keycode == KEY_0:
		return 10
	return -1

## What V hides (0x9d0560, read), by this client's kinds of object. It keeps
## the player (CICPlayer is not exactly CICUser), NPCs and guards (CICNPC),
## fortress structures (CICATStruct), script objects and dropped items
## (CIItem::vslot_010 never reads DAT_00eef5f4); it hides other players
## (exactly CICUser), monsters, CICMonsterNPC, CICRide, and every COS but the
## one the player rides (+0x2ac; that it is the ridden one is inferred from
## CICUser::vslot_010's height offset). A hidden object's draw (0x9d20d0)
## skips its body, its attachments and its name, and its vslot 0x50 makes it
## unpickable; the minimap and the target window ask vslot 0x54 instead,
## which has no V test, so they keep it (round 771, READ: 0x662bd0, 0x9c75a0).
## Kinds this client does not draw (pets, COS, stalls, fortress structures)
## are listed for when it does.
static func hides_under_v(kind: String) -> bool:
	return kind in ["other_player", "monster", "monster_npc", "ride", "pet", "stall"]

## The camera view after `current` in F9's cycle (0x780590(-1): +1, and past
## 2 back to 0; 0 free, 1 third person, 2 quarter, per 0x780420's strings).
static func next_camera_view(current: int) -> int:
	return 0 if current + 1 > 2 else current + 1

## The UI-string id 0x780420 shows for a camera view.
static func camera_view_string(view: int) -> String:
	match view:
		0:
			return "UIIT_STT_CHANGED_SIGHT_FREE_DESC"
		1:
			return "UIIT_STT_CHANGED_SIGHT_THIRD_PERSON_DESC"
		2:
			return "UIIT_STT_CHANGED_SIGHT_QUARTER_VIEW_DESC"
	return ""

## The screenshot's file name (0xba7240: "SRO[%04d-%02d-%02d %02d-%02d-%02d]_
## %02d.jpg" of year, month, day, hour, minute, second and rand() % 100 --
## the remainder of `idiv 0x64` at 0xba731d is the last push, read).
static func screenshot_name(t: Dictionary, rnd: int) -> String:
	return "SRO[%04d-%02d-%02d %02d-%02d-%02d]_%02d.jpg" % [
		int(t.get("year", 0)), int(t.get("month", 0)), int(t.get("day", 0)),
		int(t.get("hour", 0)), int(t.get("minute", 0)), int(t.get("second", 0)), posmod(rnd, 100)]

## The value 0xba7240 passes the JPEG writer 0xbaabf0 (DAT_00ed7de0 = 80,
## read); that it is the quality, 0..100, is inferred from its place in the
## call. Godot's save_jpg takes 0..1.
const SCREENSHOT_JPEG_QUALITY := 80

## The chat line R puts in the input box for a reply, or "" for none: no
## whisper yet (0x7aa2b0's copy is empty, `je 0x780a15`), or the last
## whisperer is the player (0x7ab470's compare, read). The line is "$", the
## name and a space (round 634, READ: 0x7ab470 joins L"$" at 0xdbb848 and the
## name with 0x5412c0, appends L" " at 0xe19330 with 0x4780b0 and sets the
## input box's text through vslot 0xb4) -- the whisper syntax the chat's input
## handler parses (0x7ad400: "$" is type 2, 0x7ab230 splits the name off).
static func reply_line(last_whisperer: String, own_name: String) -> String:
	if last_whisperer == "" or last_whisperer == own_name:
		return ""
	return "$%s " % last_whisperer
