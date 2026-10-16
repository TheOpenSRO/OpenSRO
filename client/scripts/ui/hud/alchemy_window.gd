extends HudWindow
class_name AlchemyWindow

## The window Y opens: the retail client's `CNIFEnchantWnd`, built from
## `res_ui\nifenchantwnd.2dt` the way its classes assemble it. Every address
## is `sro_client.exe`'s (md5 2a5794b72c90908d945be8b3f3f2edd4);
## docs/RE_COMPLETION.md has this window's round and docs/protocol/
## 2DT_FORMAT.md the file format. Each fact says whether it was **read** out
## of the binary, **measured** in the retail files, or is **inferred** or
## **ours**.
##
## **What Y opens (read).** The default key table (0x7778be) puts 'Y' in slot
## 24; 0x778310 turns slot 24 into command 0x59; the dispatch 0x780610 sends
## a code in 0x52..0x59 through the jump table 0x780e90 (index code - 0x52,
## 0x780999..0x7809a5), and 0x59's entry is 0x780a65. That asks the `.2dt`
## window manager 0x115dd40 for window 0xa8 (0x469020): if it exists, 0x798e20(0) destroys it; if not, 0x798e20(1)
## loads `res_ui\nifenchantwnd.2dt` under the interface (0x469140), unless
## the gate 0x77c8e0(1) refuses. So every open builds the window afresh and
## every close destroys it: 0x798e20(0) destroys window 0xac (the confirm box)
## and then window 0xa8 (0x468c50, 0x798eb8..0x798ed5). The underbar menu's
## item 114 calls 0x798e20(1) only (0x60ce92), so it opens but never closes.
##
## **The older CIFAlchemyBox is never shown** (GDR_ALCHEMYBOX, ID 44, the
## box ifalchemyprocess.txt, this client's alchemy panel until now, belongs
## to): ginterface.txt gives it Style 64, so the layout builder hides it at
## creation (0x8b5710..0x8b5726, round 600); its CGInterface getter 0x799590
## has no caller in the asm text, no rel32 call or jump at any byte of .text,
## and no absolute pointer anywhere in the file; and every other fetch of ID
## 44 on the interface (0x79a9b0, 0x79e620, 0x79eb20) only saves or restores
## its position. The record has the census.
##
## **The window as its OnCreates leave it.** The loader sends 0x8065 to the
## named records last-first (docs/protocol/2DT_FORMAT.md), so the order is:
## the slots and the PML (their classes' maps have no 0x8065 entry: CIFPMLEx
## at 0xee79b8, CIFSlotWithHelpEx at 0xeea508 are end markers only), then
## CNIFSocketWnd (0x593760), CNIFAlchemySubWndType2 (0x59cda0) and Type1
## (0x59cc80) -- slot tables only --, CNIFAlchemyWnd (0x59d3a0) and last
## CNIFEnchantWnd (0x592540). _apply_create_state follows it step by step.
##
## **Not built** (and why): the help text the mode puts in the PML (id 18;
## the text is `<sml2>` markup that CIFPMLEx renders, and that renderer was
## not read); the socket pane's effect sprite (+0x7dc); the other three tabs'
## managers. The strengthening tab works since round 768 -- see the section
## at the end of this file and AlchemyReinforce.

const TwoDtBuilder = preload("res://scripts/ui/twodt_builder.gd")
const ErrorText = preload("res://scripts/net/error_text.gd")

## Round 768: the strengthening tab works (AlchemyReinforce holds its rules).
## A bag item goes in by Alt+click or by being put down on the window; the
## action sends the request (start_requested -> AlchemyNet), and the reply
## (apply_result) plays the outcome. The lines go out through `message`.
signal start_requested(op: int, bag_slots: Array)
signal cancel_requested
signal message(text: String)

const ENCHANT_2DT := "res_ui\\nifenchantwnd.2dt"
const CONFIRM_2DT := "res_ui\\nifenchantalchemymsgbox.2dt"

## Control ids of nifenchantwnd.2dt (measured), as the classes fetch them.
const ID_WINDOW := 168
const ID_MENU_SOCKET := 3
const ID_MENU_ALCHEMY := 4
const ID_ALCHEMY := 5
const ID_SOCKET := 72
const ID_PANE_TYPE1 := 12
const ID_PANE_TYPE2 := 28
const ID_ACTION := 22
const ID_CONFIRM := 172
const ID_SOCKET_NOTE := 68
const ID_SOCKET_HELP := 354
const ID_SOCKET_MAKE := 56
const ID_SOCKET_REMOVE := 57
const ID_SOCKET_GAUGE := 211

## CNIFEnchantWnd's OnCreate puts the window at (0x32, screen height - 0x261)
## through SetPos, vslot 0x98 (0x59254d..0x592565). The height is the
## display mode's +0x28 (0x4f9cd0); that +0x28 is the height is inferred from
## 0x798c50, which halves +0x24 for x and +0x28 for y.
const PLACE_X := 50
const PLACE_BELOW_BOTTOM := 609

## The four alchemy tabs. CNIFAlchemyWnd keeps the selected one in a
## process-wide byte, 0xeb1428 -- initialised data, 3 in the file (measured:
## .data, raw size 0x3a000 covers it) -- written only by the four tab
## handlers (0x59d9ae, 0x59da5d, 0x59db1d, 0x59dbdd; every other reference
## reads it). Mode -> [tab id, the pane it shows, the class of its manager
## (RTTI, the objects the constructor 0x59e390 puts in the map at +0x78c)].
const MODE_TABS := [9, 10, 7, 8]
const MODE_PANES := [ID_PANE_TYPE2, ID_PANE_TYPE2, ID_PANE_TYPE1, ID_PANE_TYPE1]
const MODE_CLASSES := ["CAlchemyMgrDecompAccessory", "CAlchemyMgrDecompEquipment",
	"CAlchemyMgrManufacturing", "CAlchemyMgrReinforce"]
## What each manager's activate (vslot 0xa8: 0x57a6b0, 0x57a760, 0x570800,
## 0x5708f0) puts on the action button 22: its caption, then 0x471dc0(0)
## (disabled: +0x378 cleared, the `_disable` piece drawn), then style 0x80 and
## a hover string.
const MODE_ACTION_TEXT := ["UIIT_CTL_ALCHEMYBOX_BUTTON_DISJOINTING_ALLSLOT",
	"UIIT_CTL_ALCHEMYBOX_BUTTON_DISMANTLING", "UIIT_CTL_ALCHEMYBOX_BUTTON_MANUFACTURING",
	"UIIT_CTL_ALCHEMYBOX_BUTTON_STRENGTHENING"]
const MODE_ACTION_TIP := ["UIIT_STT_ALCHEMYBOX_TIP_DISJOINTING_ALLSLOT_BUTTON",
	"UIIT_STT_ALCHEMYBOX_TIP_DISMANTLING_BUTTON", "UIIT_STT_ALCHEMYBOX_TIP_MANUFACTURING_BUTTON",
	"UIIT_STT_ALCHEMYBOX_TIP_STRENGTHENING_BUTTON"]
## The tabs' hover strings, set by CNIFAlchemyWnd's OnCreate with style 0x80
## (0x59d64a..0x59d709: 9, 10, 7, 8).
const TAB_TIPS := {9: "UIIT_CTL_ALCHEMYBOX_TAP_DISJOINTING", 10: "UIIT_CTL_ALCHEMYBOX_TAP_DISMANTLING",
	7: "UIIT_CTL_ALCHEMYBOX_TAP_MANUFACTURING", 8: "UIIT_CTL_ALCHEMYBOX_TAP_STRENGTHENING"}
## Button 22's first caption, set before the modes are wired (0x59d3ce..
## 0x59d400); the active mode's activate replaces it at the end of the same
## OnCreate.
const ACTION_FIRST_TEXT := "UIIT_CTL_ALCHEMYBOX_BUTTON_DISJOINTING_ALLSLOT"

## The captions (SetText, vslot 0xbc): OnCreate (0x592581), the alchemy menu
## button (0x5942f0) and the socket menu button (0x59e2d0).
const CAPTION_CREATE := "UIIT_CTL_ALCHEMYBOX"
const CAPTION_ALCHEMY := "UIIT_CTL_WK_ALCHEMY"
const CAPTION_SOCKET := "UIIT_CTL_SOCKET_TAP_TITLE"
## The side menu's hover strings (style 0x80, 0x5925c5..0x59262a).
const MENU_TIPS := {ID_MENU_SOCKET: "UIIT_STT_SOCKET_TAP", ID_MENU_ALCHEMY: "SN_TAB_ALCHEMY"}

## The socket pane (CNIFSocketWnd 0x593760 and its reset 0x593630): 68 gets
## a single space, 354 the default help (0x592a60(0) -> 0xd8f5a0), the make
## and remove buttons are disabled and carry hover strings (0x59395e..
## 0x5939a7), the three `skl_mastery_nothing` statics 73, 79, 80 are shown
## (0x593705..0x59370f), and the gauge is emptied (+0x368 = +0x36c = 0).
const SOCKET_NOTE_TEXT := " "
const SOCKET_HELP := "UIIT_STT_SOCKET_HELP_SOCKET_DEFAULT"
const SOCKET_TIPS := {ID_SOCKET_MAKE: "UIIT_STT_SOCKET_BUTTON_SOCKET_MAKE",
	ID_SOCKET_REMOVE: "UIIT_STT_SOCKET_BUTTON_SOCKET_REMOVE"}
const SOCKET_NOTHING_STATICS := [73, 79, 80]

## 0xeb1428: the selected alchemy mode, for the whole run (the client's is
## a static byte that outlives the window). Starts at 3, the reinforce tab.
static var tab_mode := 3

var _twodt: TwoDtBuilder
var _file: TwoDtReader.TwoDtFile
## CNIFEnchantWnd +0x7a0: 1 while the socket pane is the one showing.
var _socket_view := false

func _init(builder: UiBuilder = null) -> void:
	super._init()
	_builder = builder

## Resets the process-wide tab byte to its initial value (tests).
static func reset_tab_mode() -> void:
	tab_mode = 3

## The mode the tab byte holds.
static func current_tab_mode() -> int:
	return tab_mode

## Builds the window as 0x798e20(1) loads it. False, with nothing built, if
## nifenchantwnd.2dt is missing or does not parse.
func build_alchemy() -> bool:
	if _builder == null:
		return false
	_file = _builder.load_2dt(ENCHANT_2DT)
	if _file == null or _file.records.is_empty():
		return false
	_twodt = TwoDtBuilder.new(_builder)
	panel_root = _twodt.build(_file, ENCHANT_2DT)
	var window_size := Vector2(_file.root().rect.size)
	custom_minimum_size = window_size
	size = window_size
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(panel_root)
	_apply_create_state()
	_add_title_bar(_builder.resolve_text(CAPTION_CREATE))
	var bar := get_node_or_null("TitleBar") as Label
	if bar != null:
		# The caption's text-object slot 6 is 0 (0x479c0b): top.
		bar.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_wire()
	_settle()
	return true

## The OnCreates, last named record first (see the header).
func _apply_create_state() -> void:
	# CNIFSocketWnd (0x593760), then its reset 0x593630 and 0x592a60(0).
	var socket := _at([ID_SOCKET])
	if socket != null:
		_set_text([ID_SOCKET, ID_SOCKET_NOTE], SOCKET_NOTE_TEXT)
		var help := _set_text([ID_SOCKET, ID_SOCKET_HELP], _builder.resolve_text(SOCKET_HELP))
		if help != null:
			# 0x59378f..0x59379f: the static's own width goes to its text
			# object's +0x2c. That +0x2c is the width it wraps at is inferred.
			help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		for id in SOCKET_NOTHING_STATICS:
			_set_shown([ID_SOCKET, id], true)
		for id in [ID_SOCKET_MAKE, ID_SOCKET_REMOVE]:
			var b := _at([ID_SOCKET, id]) as BaseButton
			if b != null:
				b.disabled = true
		_tooltips(socket, SOCKET_TIPS)
		var gauge := _at([ID_SOCKET, ID_SOCKET_GAUGE]) as Range
		if gauge != null:
			gauge.value = 0
	# The two sub-panes' OnCreates (0x59cda0, 0x59cc80) fill slot tables and
	# fetch the PML and gauge (0x591670); nothing drawn changes.

	# CNIFAlchemyWnd (0x59d3a0).
	var alchemy := _at([ID_ALCHEMY])
	if alchemy != null:
		_set_text([ID_ALCHEMY, ID_ACTION], _builder.resolve_text(ACTION_FIRST_TEXT))
		var action := _at([ID_ALCHEMY, ID_ACTION]) as BaseButton
		if action != null:
			action.disabled = true                                   # 0x59d40b
		_tooltips(alchemy, TAB_TIPS)
		# nifenchantalchemymsgbox.2dt under this pane (0x59d81e..0x59d82a),
		# then window 0xac hidden (0x59d850). Its record 0 is placed at its
		# authored rect relative to its load parent (0x48f9e0..0x48fa1f).
		var confirm_file := _builder.load_2dt(CONFIRM_2DT)
		if confirm_file != null and not confirm_file.records.is_empty():
			var confirm := _twodt.build(confirm_file, CONFIRM_2DT)
			confirm.position = Vector2(confirm_file.root().rect.position)
			confirm.set_meta(UiBuilder.AUTHORED_RECT_META, Rect2(confirm.position, confirm.size))
			alchemy.add_child(confirm, true)
			confirm.visible = false
		# The tab byte picks the pane and the checked look (0x59d852..
		# 0x59d8f3): 0x47a950(1) is the look alone; the panes are shown and
		# hidden by hand. Then the mode's activate (0x59d8f8..0x59d90e).
		var mode := clampi(tab_mode, 0, MODE_TABS.size() - 1)
		for pane in [ID_PANE_TYPE1, ID_PANE_TYPE2]:
			_set_shown([ID_ALCHEMY, pane], pane == MODE_PANES[mode])
		_set_tab_look(_at([ID_ALCHEMY, MODE_TABS[mode]]), true)
		_activate_mode(mode)

	# CNIFEnchantWnd (0x592540): the alchemy pane shown, the caption set, the
	# socket pane hidden, the side menu's hover strings; then 0x79af20 on the
	# interface, which HudPanels runs (the inventory).
	_socket_view = false
	_set_shown([ID_ALCHEMY], true)
	_set_shown([ID_SOCKET], false)
	_tooltips(panel_root, MENU_TIPS)

## A manager's activate (vslot 0xa8): button 22's caption, disabled, and its
## hover string. The gauge's two values are cleared too (+0x368, +0x36c).
func _activate_mode(mode: int) -> void:
	_set_text([ID_ALCHEMY, ID_ACTION], _builder.resolve_text(MODE_ACTION_TEXT[mode]))
	var action := _at([ID_ALCHEMY, ID_ACTION])
	if action != null:
		if action is BaseButton:
			(action as BaseButton).disabled = true
		action.tooltip_text = _builder.resolve_text(MODE_ACTION_TIP[mode])
	var gauge := _at([ID_ALCHEMY, MODE_PANES[mode], 21]) as Range
	if gauge != null:
		gauge.value = 0

func _wire() -> void:
	_wire_reinforce()
	for mode in MODE_TABS.size():
		var tab := _at([ID_ALCHEMY, MODE_TABS[mode]]) as BaseButton
		if tab != null:
			# After the tab's own click (TwoDtBuilder.click_tab, connected
			# when it was built): the parent's handler for its id.
			var m: int = mode
			tab.pressed.connect(func() -> void: select_mode(m))
	var to_alchemy := _at([ID_MENU_ALCHEMY]) as BaseButton
	if to_alchemy != null:
		to_alchemy.pressed.connect(show_alchemy_view)
	var to_socket := _at([ID_MENU_SOCKET]) as BaseButton
	if to_socket != null:
		to_socket.pressed.connect(show_socket_view)

## A tab's handler (9 -> 0x59d980, 10 -> 0x59da30, 7 -> 0x59daf0, 8 ->
## 0x59dbb0): nothing if its mode is already the byte's; otherwise the byte
## set, the mode's activate, and its help refreshed (0x59c810, the PML --
## not built). The tab look and the pane were switched by the click itself.
func select_mode(mode: int) -> void:
	if mode < 0 or mode >= MODE_TABS.size() or mode == tab_mode:
		return
	tab_mode = mode
	_activate_mode(mode)

## Clicks the tab of `mode` as the player would (tests, tools).
func click_mode_tab(mode: int) -> void:
	var tab := _at([ID_ALCHEMY, MODE_TABS[mode]]) as BaseButton
	if tab != null:
		tab.pressed.emit()

## The alchemy menu button (id 4 -> 0x5942f0): the socket pane's reset, the
## caption UIIT_CTL_WK_ALCHEMY, the alchemy pane shown and the socket pane
## hidden, +0x7a0 cleared.
func show_alchemy_view() -> void:
	# 0x592b70 (its mode back to 0, then 0x592a60(0): the default help) and
	# 0x593630 (the note blanked, the buttons disabled).
	_set_text([ID_SOCKET, ID_SOCKET_HELP], _builder.resolve_text(SOCKET_HELP))
	_set_text([ID_SOCKET, ID_SOCKET_NOTE], SOCKET_NOTE_TEXT)
	set_title(_builder.resolve_text(CAPTION_ALCHEMY))
	_set_shown([ID_ALCHEMY], true)
	_set_shown([ID_SOCKET], false)
	_socket_view = false

## The socket menu button (id 3 -> 0x59e2d0), unless the socket pane is
## visible with +0x7a0 set (0x59e2d3..0x59e2e9): the alchemy pane hidden, its mode re-activated
## (0x59dc70), the socket pane shown and reset (0x593630, 0x592a60(0)), the
## caption UIIT_CTL_SOCKET_TAP_TITLE, +0x7a0 set.
func show_socket_view() -> void:
	var socket := _at([ID_SOCKET])
	if _socket_view and socket != null and socket.visible:
		return
	_set_shown([ID_ALCHEMY], false)
	_activate_mode(clampi(tab_mode, 0, MODE_TABS.size() - 1))
	_set_shown([ID_SOCKET], true)
	_set_text([ID_SOCKET, ID_SOCKET_NOTE], SOCKET_NOTE_TEXT)
	_set_text([ID_SOCKET, ID_SOCKET_HELP], _builder.resolve_text(SOCKET_HELP))
	set_title(_builder.resolve_text(CAPTION_SOCKET))
	_socket_view = true

func is_socket_view() -> bool:
	return _socket_view

## CNIFEnchantWnd's placement (0x592540), made at every open because every
## open builds the window anew. **Ours:** the result is kept inside the
## viewport, with the side menu that hangs off the window's left edge
## (MENU_OVERHANG) counted as part of the window, so the caption, the close
## button and the menu stay reachable at a small view (at 1152x648 and UI
## scale 1.5 the view is 768x432, and 432 - 0x261 is -177).
const MENU_OVERHANG := 36
func place_initial() -> void:
	var view := get_viewport_rect().size
	var x := PLACE_X
	var y := int(view.y) - PLACE_BELOW_BOTTOM
	position = Vector2(clampi(x, MENU_OVERHANG, maxi(MENU_OVERHANG, int(view.x) - int(size.x))),
		clampi(y, 0, maxi(0, int(view.y) - int(size.y))))

## CNIFMainFrame's chrome (0x479a50): caption (10, 12, W-21, 12), drag area
## (10, 0, W-21, 34), close button (W-26, 10, 16, 16) on com_windowclose.ddj.
func _place_title_bar(bar: Control) -> void:
	var rect := Rect2(Vector2(MAINFRAME_CAPTION_X, MAINFRAME_CAPTION_Y),
		Vector2(size.x - MAINFRAME_STRIP_WIDTH_LESS, MAINFRAME_CAPTION_HEIGHT))
	bar.set_meta(UiBuilder.AUTHORED_RECT_META, rect)
	bar.position = rect.position
	bar.size = rect.size

func _close_position() -> Vector2:
	return Vector2(size.x - MAINFRAME_CLOSE_INSET, MAINFRAME_CLOSE_Y)

func in_drag_strip(local: Vector2) -> bool:
	return Rect2(MAINFRAME_CAPTION_X, 0.0, size.x - MAINFRAME_STRIP_WIDTH_LESS,
		MAINFRAME_DRAG_HEIGHT).has_point(local)

## The close button (CNIFMainFrame's map: id 0xfffd, message 0xc -> 0x479e20,
## vslot 0xac) reaches CNIFEnchantWnd::vslot_043 (0x5942a0), which calls
## 0x798e20(0): the window is destroyed, not hidden. HudPanels does that on
## `closed`.
func _on_close_pressed() -> void:
	closed.emit()

## A control by its GetChild path from the window's root.
func control(path: Array) -> Control:
	return _at(path)

func _at(path: Array) -> Control:
	return TwoDtBuilder.find_path(panel_root, path) if panel_root != null else null

func _set_shown(path: Array, on: bool) -> void:
	var c := _at(path)
	if c != null:
		c.visible = on

func _set_text(path: Array, text: String) -> Label:
	var c := _at(path)
	if c == null:
		return null
	return _twodt.set_text(c, text)

## 0x47a950: a tab's checked look, without its pane.
static func _set_tab_look(tab: Control, checked: bool) -> void:
	if tab == null:
		return
	tab.set_meta(TwoDtBuilder.META_CHECKED, checked)
	var key := TwoDtBuilder.META_TAB_ON if checked else TwoDtBuilder.META_TAB_OFF
	if tab is TextureButton and tab.has_meta(key):
		(tab as TextureButton).texture_normal = tab.get_meta(key)

## Hover strings set with style 0x80 (0x46d840 / 0x46d880, then 0x46d7d0).
## The strings are read; that the client shows them on hover is **inferred**,
## as for the guild window.
func _tooltips(root: Control, table: Dictionary) -> void:
	for id in table:
		var node := TwoDtBuilder.child(root, int(id))
		if node == null:
			continue
		node.tooltip_text = _builder.resolve_text(table[id])
		if node.mouse_filter == Control.MOUSE_FILTER_IGNORE:
			node.mouse_filter = Control.MOUSE_FILTER_PASS


# --- The strengthening tab (round 768) -----------------------------------------
#
# CAlchemyMgrReinforce (vtable 0xd8bf7c) and the alchemy pane's timers, READ
# (docs/protocol/alchemy.md, "Round 768", "The client"):
#   - the slots: controls 17 (the target), 26 (the elixir or stone) and 27
#     (the lucky powder) of pane 12; the reset (0x5757a0) gives every slot the
#     `skl_mastery_nothing.ddj` art, not pickable, then opens 17; equipment
#     opens 26, an elixir (not a stone) opens 27 (0x578500);
#   - the action (0x59f910): the request at the click, then the caption
#     UIO_COMMON_CTL_CANCEL, the prepare effect and snd_elixir_use; timer 10
#     steps the effect every 50 ms over 16 frames (an 800 ms loop, the sound
#     again at each wrap), timer 0xb fills the gauge over 3.0 s (0xd8adc4) and
#     then clears the busy flag and disables the button;
#   - the reply (0x59eb20): the success or fail effect and sound, the lines,
#     the target copied again from the bag; at frame 8 the elixir and powder
#     slots are cleared and the caption is back, at the wrap the effect hides.
# Round 789: the devil's spirit (Nasrun) refusal, message 0xe, is built (its
# ref +0x2b8 is itemdata's Param2, ItemTableReader.COL_PARAM2). Not built: the
# advanced elixir's confirm box (the server refuses op 8), the
# stone's option-change lines (0x594f40, 29 KB, not read), the effect on a
# drag back onto the bag (Alt+click takes an item out).

const NOTHING_ART := "interface\\skill\\skl_mastery_nothing.ddj"
const EFFECT_PREPARE := "interface\\alchemy\\alcm_effect_prepare.ddj"
const EFFECT_SUCCESS := "interface\\alchemy\\alcm_effect_success.ddj"
const EFFECT_FAIL := "interface\\alchemy\\alcm_effect_fail_1.ddj"
## The pane's other two slots (keys 3 and 4 of 0x59cc80), unused by this tab:
## the reset leaves them on the `nothing` art, not pickable.
const UNUSED_SLOTS := [28, 29]
const SLOT_TIPS := ["UIIT_STT_ALCHEMYBOX_TIP_STRENGTHENING_EQUIPMENT_SLOT",
	"UIIT_STT_ALCHEMYBOX_TIP_STRENGTHENING_ITEM_SLOT", "UIIT_STT_ALCHEMYBOX_TIP_STRENGTHENING_ITEM_SLOT2"]
const CAPTION_CANCEL := "UIO_COMMON_CTL_CANCEL"
const MSG_CANCELLED := "UIIT_MSG_ALCHEMY_CANCELED_COMPOUND"
const SND_USE := "UI:snd_elixir_use:-:-:-:-"
const SND_SUCCESS := "UI:snd_elixir_success:-:-:-:-"
const SND_FAIL := "UI:snd_elixir_failure:-:-:-:-"
## The timers (READ, 0xb93320 pushes 0x32): 50 ms each.
const TICK_MS := 50
## The effect sheet: 4 x 4 cells of 64 x 64 (MEASURED, 256 x 256 sheets),
## drawn in a 96 x 96 window (READ, 0x59d797..0x59d7e8) 0x20 up and left of
## the stuff slot (vslot 47, 0x578190).
const EFFECT_FRAMES := 16
const EFFECT_CELL := 64
const EFFECT_SIZE := 96
const EFFECT_OFFSET := 32
## The frame at which a shown result clears the stuff and powder slots.
const CLEAR_FRAME := 8
const GAUGE_SECONDS := 3.0

## The magic option table the stone checks read (MagicOptionTable.shared).
var options: MagicOptionTable = null
## The three slots: AlchemyReinforce item dictionaries, or null.
var _slots: Array = [null, null, null]
## Which slots are open (pickable).
var _open: Array = [true, false, false]
## +0x7ac: an attempt is out. +0x7af: its outcome is playing.
var _busy := false
var _showing := false
## The snapshot at the send (0x57a390): the plus and the durability.
var _sent_plus := 0
var _sent_durability := 0
var _sent_elixir := true
## A request is out and its reply has not come (OURS, round 768's review F7):
## the slots and the action stay locked until it does -- this server answers
## 4 s after the request, a second after the gauge frees the window.
var _awaiting := false
var _await_ms := 0.0
## OURS (review F6): a reply that never comes (no server, a dropped request)
## ends the attempt after this long instead of looping the prepare effect.
const REPLY_TIMEOUT_MS := 10000.0
var _effect: TextureRect = null
var _effect_atlas := AtlasTexture.new()
var _effect_sheet := ""
var _frame := 0
var _effect_ms := 0.0
var _effect_on := false
var _gauge_ms := 0.0
var _gauge_on := false

func _slot_control(i: int) -> Control:
	return _at([ID_ALCHEMY, ID_PANE_TYPE1, AlchemyReinforce.SLOT_CONTROLS[i]])

func _wire_reinforce() -> void:
	var action := _at([ID_ALCHEMY, ID_ACTION]) as BaseButton
	if action != null:
		action.pressed.connect(press_action)
	for i in 3:
		var c := _slot_control(i)
		if c == null:
			continue
		c.mouse_filter = Control.MOUSE_FILTER_STOP
		var icon := TextureRect.new()
		icon.name = "ItemIcon"
		icon.set_anchors_preset(Control.PRESET_FULL_RECT)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		c.add_child(icon)
		var k: int = i
		c.gui_input.connect(func(e: InputEvent) -> void: _on_slot_input(k, e))
	var pane := _at([ID_ALCHEMY, ID_PANE_TYPE1])
	if pane != null:
		_effect = TextureRect.new()
		_effect.name = "AlchemyEffect"
		_effect.size = Vector2(EFFECT_SIZE, EFFECT_SIZE)
		_effect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_effect.stretch_mode = TextureRect.STRETCH_SCALE
		_effect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_effect.visible = false
		pane.add_child(_effect)
	reset_slots()

## 0x5757a0: every slot emptied and closed, then the target's opened.
func reset_slots() -> void:
	_slots = [null, null, null]
	_open = [true, false, false]
	_refresh_slots()

func _refresh_slots() -> void:
	for i in 3:
		var c := _slot_control(i)
		if c == null:
			continue
		var icon := c.get_node_or_null("ItemIcon") as TextureRect
		var it: Variant = _slots[i]
		if icon != null:
			if it != null:
				icon.texture = (it as Dictionary).get("_icon", null)
			elif not _open[i] and _builder != null:
				icon.texture = _builder.load_texture(NOTHING_ART)
			else:
				icon.texture = null
			if _builder != null:
				ItemSealEdge.show_on(icon, _builder, it != null and bool((it as Dictionary).get("seal", false)),
					int((it as Dictionary).get("item_id", -1)) if it != null else -1)
		c.tooltip_text = _builder.resolve_text(SLOT_TIPS[i]) if (_open[i] and _builder != null) else ""
	for id in UNUSED_SLOTS:
		var c := _at([ID_ALCHEMY, ID_PANE_TYPE1, id])
		if c == null or _builder == null:
			continue
		var icon := c.get_node_or_null("ItemIcon") as TextureRect
		if icon == null:
			icon = TextureRect.new()
			icon.name = "ItemIcon"
			icon.set_anchors_preset(Control.PRESET_FULL_RECT)
			icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
			c.add_child(icon)
		icon.texture = _builder.load_texture(NOTHING_ART)
	var action := _at([ID_ALCHEMY, ID_ACTION]) as BaseButton
	if action != null and not _busy and not _showing:
		action.disabled = not AlchemyReinforce.action_enabled(_slots)

## Whether the tab is the one showing (the strengthening tab, mode 3).
func _reinforce_mode() -> bool:
	return tab_mode == 3 and not _socket_view

## A bag item offered (Alt+click or a put-down; CNIFAlchemyWnd vslot 28,
## 0x59dca0 -> 0x57a490): refused while busy; the slot is picked from the
## item's kind; a refusal writes its line. True when it went in.
func offer_item(it: Dictionary, icon: Texture2D) -> bool:
	if _busy or _showing or _awaiting or not _reinforce_mode():
		return false
	return _place(it, icon)

## 0x57a490: the slot from the kind, the check, then the copy (and, for a
## target, every slot reset first). The reply's re-offer of the target after
## a lost stone roll comes here directly, as the client hands it to slot
## 17's own drop handler (0x59ef2d..0x59ef83).
func _place(it: Dictionary, icon: Texture2D) -> bool:
	var slot := AlchemyReinforce.pick_slot(it, _slots)
	if slot < 0:
		return false
	var err := AlchemyReinforce.validate(slot, it, _slots, options)
	if err != 0:
		_say(String(AlchemyReinforce.MESSAGES.get(err, "")), [])
		return false
	var copy := it.duplicate()
	copy["_icon"] = icon
	if slot == AlchemyReinforce.SLOT_TARGET:
		reset_slots()
	_slots[slot] = copy
	# vslot 43 (0x578500): the next slot opens.
	if slot == AlchemyReinforce.SLOT_TARGET:
		_open[AlchemyReinforce.SLOT_STUFF] = true
	elif slot == AlchemyReinforce.SLOT_STUFF:
		_open[AlchemyReinforce.SLOT_POWDER] = AlchemyReinforce.is_elixir(copy) or AlchemyReinforce.is_magic_cube(copy) \
			or AlchemyReinforce.is_upper_elixir(copy)
		# A stone over an elixir closes the powder slot and takes its powder
		# out (review F5: the request names only open slots, as the client's
		# skips the slots on the `nothing` art).
		if not _open[AlchemyReinforce.SLOT_POWDER]:
			_slots[AlchemyReinforce.SLOT_POWDER] = null
	_refresh_slots()
	return true

## Alt+click on a loaded slot takes its item out (case 0xa8 of 0x680fa0 ->
## 0x59e130 -> vslot 39, 0x577f20): the target resets every slot, the
## elixir takes the powder with it. Refused while busy.
func _on_slot_input(i: int, e: InputEvent) -> void:
	var mb := e as InputEventMouseButton
	if mb == null or mb.button_index != MOUSE_BUTTON_LEFT or mb.pressed or not mb.alt_pressed:
		return
	take_out(i)

func take_out(i: int) -> void:
	if _busy or _showing or _awaiting or _slots[i] == null:
		return
	if i == AlchemyReinforce.SLOT_TARGET:
		reset_slots()
		return
	_slots[i] = null
	if i == AlchemyReinforce.SLOT_STUFF:
		_slots[AlchemyReinforce.SLOT_POWDER] = null
		_open[AlchemyReinforce.SLOT_POWDER] = false
	_refresh_slots()

func loaded(i: int) -> Variant:
	return _slots[i]

func is_busy() -> bool:
	return _busy

## A request is out with no reply yet.
func is_awaiting() -> bool:
	return _awaiting

## The bag changed: each slot's copy follows its bag slot (`lookup(bag)`
## gives the item there, {} when empty); a slot whose item left is emptied
## (OURS: retail locks the bag slot while it is loaded).
func bag_changed(lookup: Callable) -> void:
	var changed := false
	for i in 3:
		var it: Variant = _slots[i]
		if it == null:
			continue
		var now: Dictionary = lookup.call(int(it["bag"]))
		if now.is_empty() or int(now["item_id"]) != int(it["item_id"]):
			if i == AlchemyReinforce.SLOT_TARGET:
				reset_slots()
				return
			_slots[i] = null
			changed = true
			continue
		var icon: Variant = (it as Dictionary).get("_icon", null)
		now["_icon"] = icon
		_slots[i] = now
	if changed:
		_refresh_slots()

## The action button (0x59f910).
func press_action() -> void:
	if not _reinforce_mode():
		return
	var action := _at([ID_ALCHEMY, ID_ACTION]) as BaseButton
	if _busy:
		# "Cancel": the request to stop the attempt (vslot 40).
		if action != null:
			action.disabled = true
		cancel_requested.emit()
		return
	if _showing or _awaiting or not AlchemyReinforce.action_enabled(_slots):
		return
	var target: Dictionary = _slots[AlchemyReinforce.SLOT_TARGET]
	var stuff: Dictionary = _slots[AlchemyReinforce.SLOT_STUFF]
	_busy = true
	_sent_plus = int(target.get("plus", 0))
	_sent_durability = int(target.get("durability", 0))
	var op := AlchemyReinforce.op_for(stuff)
	_sent_elixir = op == AlchemyNet.OP_REINFORCE or op == AlchemyNet.OP_UPPER
	var sent: Array = []
	for i in 3:
		sent.append(_slots[i] if _open[i] else null)
	_awaiting = true
	_await_ms = 0.0
	start_requested.emit(op, AlchemyReinforce.request_slots(sent))
	_set_text([ID_ALCHEMY, ID_ACTION], _builder.resolve_text(CAPTION_CANCEL) if _builder != null else "Cancel")
	if action != null:
		action.disabled = false
	_set_gauge(0.0)
	_gauge_ms = 0.0
	_gauge_on = true
	_start_effect(EFFECT_PREPARE)
	UiSounds.play(SND_USE, "alchemy: the attempt starts (0x59f910)")

func _set_gauge(ratio: float) -> void:
	var gauge := _at([ID_ALCHEMY, ID_PANE_TYPE1, 21]) as Range
	if gauge != null:
		gauge.value = clampf(ratio, 0.0, 1.0) * gauge.max_value

## The sprite's draw mode, CIFDecoratedStatic +0x388 (its draw, slot 13
## 0x634640, READ): 1 draws additively (D3DRS_SRCBLEND 5 SRCALPHA,
## D3DRS_DESTBLEND 2 ONE, restored to INVSRCALPHA after), 0 with the plain
## alpha blend. The click sets 1 for the prepare effect (0x59fcb1); the
## outcome (0x59eb20) sets 1, keeps it for a success and sets 0 again for a
## failure, a breakdown and a stone's lost roll. The sheets are opaque
## (MEASURED: every DXT3 alpha of the three is 15), so mode 0 shows their
## black and mode 1 drops it.
func _set_effect_additive(on: bool) -> void:
	if _effect == null:
		return
	var m := CanvasItemMaterial.new()
	m.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD if on else CanvasItemMaterial.BLEND_MODE_MIX
	_effect.material = m

func _start_effect(sheet: String, additive: bool = true) -> void:
	_set_effect_additive(additive)
	_effect_sheet = sheet
	_frame = 0
	_effect_ms = 0.0
	_effect_on = true
	if _effect == null:
		return
	var stuff := _slot_control(AlchemyReinforce.SLOT_STUFF)
	if stuff != null:
		_effect.position = stuff.position - Vector2(EFFECT_OFFSET, EFFECT_OFFSET)
	_effect.visible = true
	_draw_frame()

func _draw_frame() -> void:
	if _effect == null or _builder == null:
		return
	var tex := _builder.load_texture(_effect_sheet)
	if tex == null:
		_effect.texture = null
		return
	# One atlas, its sheet and cell changed (review F11: not a new texture
	# every 50 ms).
	_effect_atlas.atlas = tex
	var per_row := maxi(1, int(tex.get_width()) / EFFECT_CELL)
	_effect_atlas.region = Rect2((_frame % per_row) * EFFECT_CELL, (_frame / per_row) * EFFECT_CELL, EFFECT_CELL, EFFECT_CELL)
	if _effect.texture != _effect_atlas:
		_effect.texture = _effect_atlas

func _process(delta: float) -> void:
	tick(delta * 1000.0)

## Advances the two timers by `ms` (tests drive it directly). Fractions are
## kept (review F11).
func tick(ms: float) -> void:
	if _awaiting:
		_await_ms += ms
		if _await_ms >= REPLY_TIMEOUT_MS:
			print("AlchemyWindow: no reply in %d ms -- the attempt is ended (OURS)" % int(REPLY_TIMEOUT_MS))
			_stop_attempt()
			return
	if _gauge_on:
		_gauge_ms += ms
		_set_gauge(_gauge_ms / 1000.0 / GAUGE_SECONDS)
		if _gauge_ms >= GAUGE_SECONDS * 1000.0:
			# 0x59deec: the attempt can no longer be cancelled.
			_gauge_on = false
			_busy = false
			var action := _at([ID_ALCHEMY, ID_ACTION]) as BaseButton
			if action != null:
				action.disabled = true
	if not _effect_on:
		return
	_effect_ms += ms
	while _effect_ms >= TICK_MS and _effect_on:
		_effect_ms -= TICK_MS
		_frame += 1
		if _showing and _frame == CLEAR_FRAME:
			_clear_after_result()
		if _frame >= EFFECT_FRAMES:
			_frame = 0
			if _showing:
				_effect_on = false
				_showing = false
				if _effect != null:
					_effect.visible = false
				_refresh_slots()
				return
			UiSounds.play(SND_USE, "alchemy: the prepare effect loops (0x59df8e)")
		_draw_frame()

## 0x59c8e0 at frame 8: the stuff and powder slots emptied, the caption
## back, the button off.
func _clear_after_result() -> void:
	_slots[AlchemyReinforce.SLOT_STUFF] = null
	_slots[AlchemyReinforce.SLOT_POWDER] = null
	_open[AlchemyReinforce.SLOT_POWDER] = false
	_busy = false
	_set_text([ID_ALCHEMY, ID_ACTION], _builder.resolve_text(MODE_ACTION_TEXT[3]) if _builder != null else "")
	var action := _at([ID_ALCHEMY, ID_ACTION]) as BaseButton
	if action != null:
		action.disabled = true
	_refresh_slots()

## Back to idle without an outcome: a refusal or a cancel (OURS: what
## 0x59c5d0 resets on a cancel was not read; the loaded slots stay).
func _stop_attempt() -> void:
	_busy = false
	_awaiting = false
	_showing = false
	_gauge_on = false
	_effect_on = false
	if _effect != null:
		_effect.visible = false
	_set_gauge(0.0)
	_set_text([ID_ALCHEMY, ID_ACTION], _builder.resolve_text(MODE_ACTION_TEXT[3]) if _builder != null else "")
	_refresh_slots()

## The server's reply (0x8729e0 / 0x872cd0, then 0x59eb20).
func apply_result(r: AlchemyNet.Result) -> void:
	_awaiting = false
	if r.ok and r.cancelled:
		_stop_attempt()
		_say(MSG_CANCELLED, [])
		return
	var bits := AlchemyReinforce.outcome(r, _sent_plus, _sent_durability)
	if bits < 0:
		# A refusal: its line (0x778190, category 0x12).
		_stop_attempt()
		message.emit(ErrorText.alchemy_line(r.code, _builder.text_table() if _builder != null else null))
		return
	var new_plus := _sent_plus
	var new_dur := _sent_durability
	if r.record != null:
		new_plus = r.record.opt_level
		new_dur = r.record.durability
		var target: Variant = _slots[AlchemyReinforce.SLOT_TARGET]
		if target != null:
			(target as Dictionary)["plus"] = new_plus
			(target as Dictionary)["durability"] = new_dur
	_showing = true
	var action := _at([ID_ALCHEMY, ID_ACTION]) as BaseButton
	if action != null:
		action.disabled = true
	if bits & AlchemyReinforce.OUT_SUCCESS:
		_start_effect(EFFECT_SUCCESS)
		UiSounds.play(SND_SUCCESS, "alchemy: success (0x59eb20)")
	else:
		_start_effect(EFFECT_FAIL, false)
		UiSounds.play(SND_FAIL, "alchemy: failure (0x59eb20)")
	for line in AlchemyReinforce.outcome_lines(bits, _sent_elixir, new_plus, _sent_plus, new_dur, _sent_durability):
		_say(String(line[0]), line[1])
	if bits & (AlchemyReinforce.OUT_BREAKDOWN | AlchemyReinforce.OUT_STONE_FAIL):
		# Slot 17 emptied (0x67ece0). After a breakdown the client then offers
		# the bag's item at the target's slot to slot 17 again (0x59ef2d..
		# 0x59ef83) -- the slot the item was destroyed out of, so nothing
		# comes back; this client's bag has not been re-read yet at this
		# point and would still show the item, so the re-offer is left out.
		# A stone's lost roll (0x80) only empties it.
		reset_slots()
	_refresh_slots()

## A line from the archive's text, its %d's filled.
func _say(key: String, args: Array) -> void:
	if key == "":
		return
	var text := _builder.resolve_text(key) if _builder != null else key
	message.emit(AlchemyReinforce.fill(text, args))
