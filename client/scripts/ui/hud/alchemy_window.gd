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
## not read); the slots' own icons and hover texts (the inner CIF slots at
## +0x348 of each CIFSlotWithHelpEx, whose drawing was not read); the two
## hidden effect sprites the OnCreates create in code (+0x7a0 of the alchemy
## pane, `alcm_effect_prepare.ddj`, and +0x7dc of the socket pane), both
## hidden at creation. Nothing that needs the server is wired: no item can
## be placed, so every action button stays disabled, as the client leaves it
## with empty slots.

const TwoDtBuilder = preload("res://scripts/ui/twodt_builder.gd")

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
