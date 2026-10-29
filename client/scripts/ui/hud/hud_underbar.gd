extends Control
class_name HudUnderbar

## The bottom bar: the client's own `CNIFUnderMenuBar`, built from
## `res_ui\nifundermenubar.2dt` the way its class assembles it. Every address
## is `sro_client.exe`'s (md5 2a5794b72c90908d945be8b3f3f2edd4), in the
## decompile `/var/tmp/decomp_client` and the asm `/var/tmp/sro_client.asm` on
## the RE box; docs/RE_COMPLETION.md has this round's full record. Each fact
## below says whether it was read, measured or inferred.
##
## **This is the only bar.** The game-state enter `0x786f30` loads
## nifundermenubar.2dt unconditionally and places it (read, below). The older
## `CIFUnderBar` (`GDR_UNDERBAR` in resinfo\ginterface.txt's Create section,
## which `0x78c9ce` builds) is still created, but it draws nothing and holds
## nothing: its Create (`0x68d540`) only calls `0xba0e40` and loads no layout,
## its render slot 13 is `ret` (`0x68d980`), its ShowWindow slot 23 is
## `ret 4` (`0x68c850`), its update slot 12 is `ret` (`0x68c5f0`), and its
## quickslot routines (`0x68c740`, `0x68d3a0`, `0x68d990`) have no caller
## outside the class. `resinfo\ifunderbar.txt`, which this bar used to be built
## from, is named nowhere in the exe.
##
## **Placement** (read, `0x7871dc..0x787210`): `SetPos((screen_w - 800) / 2,
## screen_h - 0x44)` -- centred and flush to the bottom, 800x68 (the file's
## own root rect, measured). That the two numbers are the screen size is
## inferred (`0x4f9cd0` returns a mode record whose +0x24 / +0x28 are used).
##
## **OnCreate order** (read, `0x48fc09..0x48fcbd`): the loader queues every
## named record with a push_front and sends `0x8065` from the front, so the
## OnCreates run in **reverse** file order -- the fifteen `CNIFMenuButton`s
## first (each stores its child 200 at +0x3bc, `0x60ac20`), then the bar's own
## (`0x60df30`, record 0) last. `CIFSlotWithHelpEx` has no `0x8065` entry. So
## when the bar's OnCreate captions the menu items, each caption reaches its
## child 200 (the button's SetText, slot 47 `0x60ac40`, forwards there).
##
## **The bar's OnCreate** (`0x60df30`, read): child 14 captioned
## `UIO_CHARINFO_STT_EXP`; the menu popup 59 hidden; the "m" slot 50 is quick
## slot 0; slots 40..49 are quick slots 1..10, hidden; quick slots 11..50 are
## created (`CIFSlotWithHelpEx`, ids 1010..1049) at the positions of slots
## 1..10 in turn, hidden; the slot arrow 103 hidden; the fourteen menu items
## fetched from 59, the stall-network item 120 hidden; 104 shown; the pet bar
## 16 hidden; page 0 selected (`0x60a730`); hover strings on 6..9 (`0x60a620`);
## the menu captions (`0x60d5f0`); the menu fitted to its captions and put at
## the bar's right edge (`0x60afe0`).

const TwoDtReader = preload("res://scripts/ui/twodt_reader.gd")
const TwoDtBuilder = preload("res://scripts/ui/twodt_builder.gd")

signal quickslot_activated(slot_index: int)
signal menu_action(action_name: String)
## A left click on a filled quick slot: pick its icon up onto the cursor
## (round 652). World3D hands it to the shared HeldIcon; the next click puts
## it down -- on another quick slot the two change places, anywhere else it
## comes off the bar. READ: every CIFSlotWithHelp is created pickable
## (0x673cf4), CIFUnderBar::vslot_028 (0x68dd10) swaps two quick slots (kind
## 0x0c), and its release hook vslot_026 (0x68d140) clears a slot let go of
## anywhere else (0x67ece0 -> 0x68cec0).
signal quickslot_pick_requested(slot_index: int)

const UNDERBAR_2DT := "res_ui\\nifundermenubar.2dt"

## The bar's size when its file cannot be read: the root rect of
## nifundermenubar.2dt (measured: `CNIFUnderMenuBar`, 800x68), which is also
## what 0x786f30 places (`- 0x44`). The built bar takes the file's own rect.
const BODY_WIDTH: int = 800
const BODY_HEIGHT: int = 68

# The controls the class fetches (GetChild `0x46e060`, direct children only).
const ID_BAR := 175
const ID_BTN_MENU := 4
const ID_SP_GAUGE := 5
const ID_BTN_CHARACTER := 6
const ID_BTN_INVENTORY := 7
const ID_BTN_SKILL := 8
const ID_BTN_MALL := 9
## `%d` of the whole tens of the level's EXP percent (+0x35c).
const ID_EXP_TENS := 10
## `%d` of the unspent skill points (+0x358).
const ID_SP_VALUE := 12
## `%s. %d` of UIIT_STT_LEVEL_LV and the level (+0x368).
const ID_LEVEL := 13
## Captioned UIO_CHARINFO_STT_EXP by the OnCreate.
const ID_EXP_CAPTION := 14
## `%.2f %%` of the level's EXP percent (+0x354).
const ID_EXP_PERCENT := 15
const ID_PET := 16
## `%d%%` of the progress through the current tenth (+0x360).
const ID_EXP_STEP := 17
const ID_PAGE_DOWN := 18
const ID_PAGE_UP := 19
## The ten EXP gauges, one per tenth of a level (+0x36c..+0x390).
const EXP_GAUGES := [20, 21, 22, 23, 24, 25, 26, 27, 28, 29]
## Quick slots 1..10, the first page's (+0x3d8..).
const PAGE_SLOT_IDS := [40, 41, 42, 43, 44, 45, 46, 47, 48, 49]
## Quick slot 0, the one labelled `ub_number_m` (+0x3d4).
const ID_MOUSE_SLOT := 50
## `F%d` of the page (+0x3d0, `0x60a730`).
const ID_PAGE_LABEL := 57
const ID_MENU := 59
const ID_MENU_TILE := 62
const MENU_LINES := [70, 79, 98]
const ID_SLOT_ARROW := 103
const ID_EXP_LINE := 104
## The menu's items as the OnCreate fetches them into +0x394..+0x3c8, the
## order `0x60afe0` walks when it fits the menu to its captions.
const MENU_ITEMS := [83, 93, 96, 99, 102, 105, 108, 111, 114, 104, 117, 120, 123, 126]
## Hidden by the OnCreate (`0x60e2cd..0x60e2db`), at the very rect of 117
## (open a stall, 789,353) with its own icon `ub_new_icon_stallnet.ddj` and
## an empty caption (0x60d5f0 captions it nothing).
const ID_MENU_STALLNET := 120
const ID_MENU_STALL := 117
## Round 840 (OURS, docs/protocol/stall_network.md §0): the stall network is
## reached from item 120, so it is shown: the menu grows 25 upwards (its row
## pitch), the items down to 117 move up a row and 120 takes 117's old row;
## its caption is UIIT_STT_WARENETWORK_TITLE. False restores the retail menu.
const SHOW_STALL_NETWORK := true
const MENU_ROW := 25
const STALL_NETWORK_CAPTION := "UIIT_STT_WARENETWORK_TITLE"
## A CNIFMenuButton's caption child, the one its SetText forwards to.
const MENU_CAPTION := 200

## What each item and button does, read from the message map's one handler
## `0x60cd10` (entries at 0xeb50b8..0xeb5360, written by 0xd69d89..), mapped
## onto this client's panel ids. The retail target of each is the one the
## same key reaches (the key dispatcher 0x780610's tables, read): 6 C
## `0x79ace0`, 7 I `0x79b020`, 8 S `0x79ae00`, 83 P `0x79ae90`, 93 E
## `0x79c170(1)`, 96 `0x5b4980` (the guild view), 99 L `0x79b0b0`, 105 A
## `0x79d5b0`, 108 `0x5b49c0` (the community view), 111 Q `0x7990e0`, 114 Y
## `0x798e20(1)`, 123 `0x79c750(1)`, 126 the system window (GetChild 0x62).
## 9, the item mall button, puts up the "Enter Item Mall" box (READ
## `0x60ce04`: push 0x1e, `0x6ec5d0`, the box F10 opens; round 837).
## Items with no window in this client emit nothing: 102 academy matching (`0x79c420(1)`), 104 the collection
## book (window 0xd2), 117 open a stall (`0x793b00(100, 0x3f1)`), 120 the
## stall network (hidden).
## Round 837: button 9's action, the item mall's entry box (not a panel).
const MALL_ENTRY_ACTION := "itemmall_entry"
## Round 840: item 120, the stall network (0x60cee3 -> FUN_00799020(1)).
const STALL_NETWORK_ACTION := "stallnetwork"
const MENU_ACTIONS := {
	6: "character", 7: "inventory", 8: "skill", 9: MALL_ENTRY_ACTION,
	83: "party", 93: "partymatch", 96: "guild", 99: "academy", 105: "action",
	108: "community", 111: "quest", 114: "alchemy", 120: STALL_NETWORK_ACTION, 123: "autopotion", 126: "system",
}

## The captions `0x60d5f0` gives the items: the text-table format with the
## name of a key from the key table (`0x778c00`, copied at [esp+0x14]) filled
## in. The table slot each reads was read off its load (party [esp+0x24] =
## slot 4 'P', party match slot 23 'E', guild slot 6 'U', academy slot 30
## 'L', action slot 3 'A', **community slot 6 'U'** -- the guild's key --,
## quest slot 5 'Q', alchemy slot 24 'Y', auto potion slot 21 'T'). Here the
## key is read from this client's copy of that table (KeyMap.SLOTS), so the
## caption names the key that really opens it; the value is the panel whose
## key it names. Items not listed keep their record's own text id.
const MENU_CAPTIONS := {
	83: ["UIIT_STT_TOGGLE_CONTENTS_MENU_PARTY", "party"],
	93: ["UIIT_STT_TOGGLE_CONTENTS_MENU_PARTYMATCH", "partymatch"],
	96: ["UIIT_STT_TOGGLE_CONTENTS_MENU_GUILD", "guild"],
	99: ["UIIT_STT_TOGGLE_CONTENTS_MENU_TRAININGCAMP", "academy"],
	105: ["UIIT_STT_TOGGLE_CONTENTS_MENU_ACTION", "action"],
	108: ["UIIT_STT_TOGGLE_CONTENTS_MENU_COMMUNITY", "guild"],
	111: ["UIIT_STT_TOGGLE_CONTENTS_MENU_QUEST", "quest"],
	114: ["UIIT_STT_TOGGLE_CONTENTS_MENU_ENCHANT", "alchemy"],
	123: ["UIIT_STT_TOGGLE_CONTENTS_MENU_AUTOPOTION", "autopotion"],
}
## Hover strings on the four buttons: `0x60a620` sets style 0x80 and
## TOGGLE_CHARACTER / _INVENTORY / _SKILL / SILKMALL_SHORT_KEY, then
## `0x60d5f0` replaces the first three with the key-filled CONTENTS_MENU
## forms (key table slots 0, 1, 2). That style 0x80 plus the string is a hover
## tooltip is inferred (the guild round's reading of `0x46d7d0`).
const BUTTON_TOOLTIPS := {
	6: ["UIIT_STT_TOGGLE_CONTENTS_MENU_CHARACTER", "character"],
	7: ["UIIT_STT_TOGGLE_CONTENTS_MENU_INVENTORY", "inventory"],
	8: ["UIIT_STT_TOGGLE_CONTENTS_MENU_SKILL", "skill"],
	9: ["UIIT_STT_SILKMALL_SHORT_KEY", ""],
}

const EXP_CAPTION := "UIO_CHARINFO_STT_EXP"
const LEVEL_TEXT := "UIIT_STT_LEVEL_LV"

## 0x33, `MAX_QUICKSLOT` (the assert at 0x68cef3 names it): quick slot 0 (the
## "m" slot) and quick slots 1..50.
const MAX_QUICKSLOT := 51
## The "m" slot. Quick slot 0 is what the middle button fires (WM_MBUTTONDOWN
## 0x207 -> `0x77c4cc` -> `0x60bb80(0)`), unless the interface's +0x4f9 flag
## is set, when the right button does instead (0x204 -> `0x77c73e`); the flag
## is 0 when the interface is built (`0x78d383`) and set through `0x778be0`
## by the option code and by `0x77c190`, which loads the player's saved
## options from Setting\SROptionSet.dat; this client has neither, so it stays
## 0. Command 0x58 also fires it
## (0x780610's table at 0x780e90, entry 6); it is slot 11's command, and
## slot 11's default key is X (KeyMap, round 608).
const MOUSE_SLOT := 0
const SLOTS_PER_PAGE := 10
## Pages 0..3 (`0x60a730` keeps its page in 0..3, wrapping), F1..F4 select
## them (0x780610's raw-key table: VK_F1..VK_F4 -> `0x60a730(0..3)`), and the
## page label reads `F%d` of page + 1 (the wide string at 0xd98580). Quick
## slots 41..50 exist but no page shows them.
const MAX_PAGES := 4
const PAGE_LABEL_FORMAT := "F%d"
## The EXP readout caps the percent at 99.99 (`fcom` against 0xd986f8, then
## 0xd986f0 loaded, 0x60b4b8..0x60b4c7).
const EXP_PERCENT_CAP := 99.99
## The skill-point gauge's fill is the character's SP experience over 400.0
## (0xd878a8, 0x60b7ff). This server sends no SP experience, so the gauge is
## filled only when a caller passes progress.
const SP_EXP_PER_POINT := 400.0
## `0x60afe0` widens the menu by this much plus the widest caption's overrun.
const MENU_FIT_MARGIN := 10

## The Additional Quick Slot bar (CIFExtQuickSlot, round 788; HudExtQuickSlot)
## shows quick slots 41..50 -- the ones no page shows. READ: its ten
## CIFExtQuickSlotSlot are proxies bound to this bar's slots 41..50 (0x65fc70,
## binding loop 0x65ef70 over +0x478..+0x49c), drawing the target at the
## proxy's place (0x65fb00). Here the slot's own node is lent to that window
## (lend_slot) and drawn there; this bar keeps it registered, so every call
## by index (icons, counts, re-use display, seals, drops, the right-click use)
## reaches it unchanged.
const EXT_FIRST_SLOT := 41
## OURS (round 788): the extra bars past retail's one (HudExtQuickSlots) take
## quick slots from 51 on, P pages of ten each -- room reserved for
## EXT_BARS_MAX bars of EXT_PAGES_MAX pages, so raising either count changes
## no stored format. Retail's MAX_QUICKSLOT 0x33 (0..50) is unchanged.
const EXT_SLOT_BASE := 51
const EXT_BARS_MAX := 4
const EXT_PAGES_MAX := 5
## Every quick slot index this client knows: 0..50 (retail's) and 51..250
## (OURS).
const SLOT_COUNT := EXT_SLOT_BASE + EXT_BARS_MAX * EXT_PAGES_MAX * 10

## Children every quick-slot node gets for its icon and stack count, as the
## `.txt` builder's slots had them (UiBuilder._build_slot).
const ICON_NODE := "ItemIcon"
const COUNT_NODE := "CountLabel"

var _ui_builder: UiBuilder
var _media_pk2: Pk2Reader
var _text_table: UiTextTable
var _twodt: TwoDtBuilder

## The built bar (record 0's node), or null when the file was not there.
var bar_root: Control
var _menu: Control
var _gauge_sp: TextureProgressBar
var _exp_gauges: Array[TextureProgressBar] = []
var _nodes := {} # id -> Control, the bar's direct children the class fetches

## Current page, 0..3, as the class keeps it (+0x348).
var _page := 0
var _slot_nodes: Dictionary = {} # quick slot index (0..50) -> Control
## The quick slots the page last shown made visible.
var _page_slots: Array[int] = []
## Quick slots whose node another window draws (lend_slot): index -> true.
## No page shows or hides them.
var _lent := {}

## Whether setup() has run. It builds once: World3D adds the bar to the tree,
## whose _ready runs setup, and it used to call setup again after placing it,
## which built a second bar stacked exactly on the first (round 585). A later
## call does nothing.
var _built := false

func _init(builder: UiBuilder = null, media_pk2: Pk2Reader = null, text_table: UiTextTable = null) -> void:
	_ui_builder = builder
	_media_pk2 = media_pk2
	_text_table = text_table

func _ready() -> void:
	set_process(false)
	setup()
	if OS.get_environment("OPENSRO_QA_SLOTS") != "":
		add_to_group("qa_slots")

## Builds the bar. `file` is a parsed `.2dt` (or its bytes) for a caller that
## has one; otherwise the archive's own nifundermenubar.2dt is loaded.
func setup(file: Variant = null) -> void:
	if _built:
		return
	_built = true
	var body := Vector2(BODY_WIDTH, BODY_HEIGHT)
	custom_minimum_size = body
	size = body
	# The bar's body consumes the clicks on it (round 529): this control's
	# rect is the body, so STOP covers it and nothing else. Godot 4.2 returns
	# a control for a click only inside its own rect, so the space above the
	# bar still reaches the world; what hangs outside it (the two end
	# decorations, statics) is hit-tested on its own filter and is IGNORE. A
	# PASS child (the bar's own art) bubbles here and stops.
	mouse_filter = Control.MOUSE_FILTER_STOP
	# The middle button fires the "m" slot wherever the cursor is; STOP keeps
	# a press on the body from reaching World3D, so the body fires it here.
	relay_middle_button(self)
	var twodt := _load(file) if _ui_builder != null else null
	if twodt == null or twodt.records.is_empty():
		# No file, no bar: say so, and let clicks through rather than keep an
		# empty 800x68 rectangle that swallows the world under it.
		push_warning("HudUnderbar: %s is not in the archive -- no bottom bar" % UNDERBAR_2DT)
		print("HudUnderbar: %s not found; the bar is empty and takes no clicks" % UNDERBAR_2DT)
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		return
	_twodt = TwoDtBuilder.new(_ui_builder)
	twodt = _fitted(twodt)
	bar_root = _twodt.build(twodt, UNDERBAR_2DT)
	if bar_root == null:
		return
	bar_root.position = Vector2.ZERO
	bar_root.set_meta(UiBuilder.AUTHORED_RECT_META, Rect2(Vector2.ZERO, bar_root.size))
	body = Vector2(twodt.root().rect.size)
	custom_minimum_size = body
	size = body
	add_child(bar_root)
	for c in bar_root.get_children():
		if c.has_meta(TwoDtBuilder.META_ID):
			_nodes[int(c.get_meta(TwoDtBuilder.META_ID))] = c
	_menu = _nodes.get(ID_MENU)
	_apply_create_state()
	_wire()
	UiBuilder.settle_authored_rects(bar_root)

func _load(file: Variant) -> TwoDtReader.TwoDtFile:
	if file is TwoDtReader.TwoDtFile:
		return file
	if file is PackedByteArray:
		return TwoDtReader.parse(file)
	return _ui_builder.load_2dt(UNDERBAR_2DT)

# --- the OnCreate -----------------------------------------------------------

func _apply_create_state() -> void:
	# The menu buttons' OnCreates ran first (reverse file order): their
	# captions land on child 200, which is what _caption writes to.
	var exp_caption: Control = _nodes.get(ID_EXP_CAPTION)
	if exp_caption != null:
		_twodt.set_text(exp_caption, _ui_builder.resolve_text(EXP_CAPTION))
	_gauge_sp = _nodes.get(ID_SP_GAUGE) as TextureProgressBar
	for id in EXP_GAUGES:
		var g := _nodes.get(id) as TextureProgressBar
		if g != null:
			_exp_gauges.append(g)
	# A CNIFGauge's fill is a float ratio (+0x368 / +0x36c); Godot's Range
	# rounds to its step, 1 by default, which would snap a tenth to whole
	# percents.
	for g in _exp_gauges + [_gauge_sp]:
		if g != null:
			(g as Range).step = 0.0
	for id in [ID_MENU, ID_PET, ID_SLOT_ARROW]:
		_set_shown(_nodes.get(id), false)
	_set_shown(_nodes.get(ID_EXP_LINE), true)
	if _menu != null:
		_set_shown(TwoDtBuilder.child(_menu, ID_MENU_STALLNET), SHOW_STALL_NETWORK)
	_build_slots()
	_select_page(0)
	_apply_hover_strings()
	_apply_menu_captions()

## Quick slots: the "m" slot is 0, the authored ten are 1..10, and 11..50 are
## made at the authored ten's positions in turn (0x60e0d0..0x60e17a: id
## index + 999, rect (0, 0, 32, 32) moved to slot ((index - 1) % 10) + 1's
## position), all but the "m" slot hidden.
func _build_slots() -> void:
	var mouse: Control = _nodes.get(ID_MOUSE_SLOT)
	if mouse != null:
		_register_slot(MOUSE_SLOT, mouse)
	for k in PAGE_SLOT_IDS.size():
		var node: Control = _nodes.get(PAGE_SLOT_IDS[k])
		if node != null:
			_register_slot(k + 1, node)
			node.visible = false
	for index in range(SLOTS_PER_PAGE + 1, MAX_QUICKSLOT):
		var model: Control = _slot_nodes.get((index - 1) % SLOTS_PER_PAGE + 1)
		if model == null:
			continue
		var node := Control.new()
		var id := index + 999
		node.name = "Wnd%d" % id
		node.set_meta(TwoDtBuilder.META_ID, id)
		node.set_meta(TwoDtBuilder.META_CLASS, "CIFSlotWithHelpEx")
		var rect := Rect2(model.position, Vector2(32, 32))
		node.position = rect.position
		node.size = rect.size
		node.set_meta(UiBuilder.AUTHORED_RECT_META, rect)
		bar_root.add_child(node, true)
		# Round 786: sent to the FRONT of the bar's child list, under every
		# other child -- in particular under the key numbers 92..101, so a
		# filled slot on F2..F4 keeps its number as F1's do. READ: the
		# OnCreate calls 0xb90c30 on each made slot (0x60e157..0x60e159),
		# which marks it mode 2 (+0x28 = 2); the main frame's tick
		# (CGFXMainFrame::vslot_011 -> CGWndBase::vslot_012 0xb92070, which
		# recurses into every shown child) moves a mode-2 child to the front
		# of its parent's list (0xb92228 -> map 0x110f650, inserted before
		# the first node at 0xb92373..), and 0xba0300 draws the list first
		# to last. The authored ten (records 33..42) already come before the
		# numbers (records 96..105) in file order.
		bar_root.move_child(node, 0)
		node.visible = false
		_register_slot(index, node)

func _register_slot(index: int, node: Control) -> void:
	_slot_nodes[index] = node
	# Unclipped (round 786): the original draws a slot's count from
	# 1 px left of it for four digits (ItemCountLabel, READ 0x67bd70) and
	# clips nothing; the icon and the re-use display fill the slot exactly.
	node.clip_contents = false
	# A slot consumes its clicks: it fires its quick slot and the world never
	# sees the press (round 522's review measured the release walking the
	# character when it did).
	node.mouse_filter = Control.MOUSE_FILTER_STOP
	var icon := TextureRect.new()
	icon.name = ICON_NODE
	icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	node.add_child(icon)
	# The stack count (round 786): the original's own digit images at the
	# slot's top left, as the bag draws them (ItemCountLabel, READ: the
	# quick slot is a CIFSlotWithHelp, whose vslot_013 0x685e50 draws the
	# count with 0x67bd70). It was a font Label at the bottom right that no
	# caller ever gave a count.
	ItemCountLabel.ensure_digits(_ui_builder)
	var count := ItemCountLabel.new()
	count.name = COUNT_NODE
	count.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	node.add_child(count)
	node.gui_input.connect(func(event: InputEvent) -> void:
		if not (event is InputEventMouseButton):
			return
		var mb := event as InputEventMouseButton
		var inside := node.get_global_rect().has_point(mb.global_position)
		# Retail's quick slots are used with the RIGHT button (round 652):
		# CIFSlotWithHelp's right-button-up (vslot 33, 0x685ee0) runs
		# 0x682040, whose quick-slot case (0x0c) is the use (0x60bb80). The
		# LEFT click picks the icon up instead (0x652540's release).
		if mb.button_index == MOUSE_BUTTON_RIGHT and not mb.pressed and inside:
			# Round 826: the use's number is the slot's own (+0x374): 1..10
			# for the first page's, which moves the frame (0x60bb80).
			if index >= 1 and index <= SLOTS_PER_PAGE:
				select_slot_frame(index - 1)
			quickslot_activated.emit(index)
		elif mb.button_index == MOUSE_BUTTON_LEFT and inside and HeldIcon.is_pick_click(mb) and slot_has_item(index) \
				and not bool(node.get_meta(PICK_LOCK_META, false)):
			quickslot_pick_requested.emit(index)
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_MIDDLE and mouse_slot_button == MOUSE_BUTTON_MIDDLE:
			activate_mouse_slot())

func _apply_hover_strings() -> void:
	for id in BUTTON_TOOLTIPS:
		var btn: Control = _nodes.get(id)
		if btn == null:
			continue
		var spec: Array = BUTTON_TOOLTIPS[id]
		btn.tooltip_text = _with_key(_ui_builder.resolve_text(spec[0]), spec[1])

func _apply_menu_captions() -> void:
	if _menu == null:
		return
	for id in MENU_CAPTIONS:
		var spec: Array = MENU_CAPTIONS[id]
		var caption := TwoDtBuilder.child(TwoDtBuilder.child(_menu, int(id)), MENU_CAPTION)
		if caption != null:
			_twodt.set_text(caption, _with_key(_ui_builder.resolve_text(spec[0]), spec[1]))
	if SHOW_STALL_NETWORK:
		var c120 := TwoDtBuilder.child(TwoDtBuilder.child(_menu, ID_MENU_STALLNET), MENU_CAPTION)
		if c120 != null:
			_twodt.set_text(c120, _ui_builder.resolve_text(STALL_NETWORK_CAPTION))

## A caption format with its `%s` filled by the key this client binds to
## `panel_id` (Godot's name for it). `0x60d020`'s own key naming is not read.
static func _with_key(format: String, panel_id: String) -> String:
	if not format.contains("%s"):
		return format
	return format.replace("%s", key_name(panel_id))

## The key this client binds to a panel, by name, from the key table
## (KeyMap's "panel:<id>" slot, round 608); "" for a panel with no key.
static func key_name(panel_id: String) -> String:
	if panel_id == "":
		return ""
	var key := KeyMap.key_for("panel:" + panel_id)
	if key == KEY_NONE:
		return ""
	return OS.get_keycode_string(key)

## The file with the menu fitted to its captions, the way `0x60afe0` does it
## after the captions are set: the widest caption's overrun past its child
## 200 (`0x60ac70`: text width less the static's width, else 0), plus
## MENU_FIT_MARGIN, widens the menu 59, its tile 62, the fourteen items and
## the lines 70 / 79 / 98; then the menu moves so its right edge is the bar's
## (x = bar.x + bar.w - menu.w, y kept; 0x60b167..0x60b1b7, GetRect
## `0xb8f420`). The widths are this client's font's -- the mechanism is the
## client's, the font metrics are ours. The cached file is not changed: the
## records that move are copied.
func _fitted(file: TwoDtReader.TwoDtFile) -> TwoDtReader.TwoDtFile:
	var menu := file.child_with_id(0, ID_MENU)
	if menu == null:
		return file
	var overrun := 0
	for id in MENU_ITEMS:
		var item := file.child_with_id(menu.index, int(id))
		var caption := file.child_with_id(item.index, MENU_CAPTION) if item != null else null
		if caption == null:
			continue
		var text := ""
		if MENU_CAPTIONS.has(id):
			var spec: Array = MENU_CAPTIONS[id]
			text = _with_key(_ui_builder.resolve_text(spec[0]), spec[1])
		elif int(id) == ID_MENU_STALLNET and SHOW_STALL_NETWORK:
			text = _ui_builder.resolve_text(STALL_NETWORK_CAPTION)
		elif caption.text_id != "":
			text = _ui_builder.resolve_text(caption.text_id)
		var width := _text_width(text, caption.font_index)
		overrun = maxi(overrun, width - caption.rect.size.x)
	var changes := {}
	if SHOW_STALL_NETWORK:
		_make_stall_network_row(file, menu, changes)
	var grow := MENU_FIT_MARGIN + overrun if overrun > 0 else 0
	if grow > 0:
		var widen := [menu]
		for id in [ID_MENU_TILE] + MENU_ITEMS + MENU_LINES:
			var r := file.child_with_id(menu.index, int(id))
			if r != null:
				widen.append(r)
		for r in widen:
			var at: Rect2i = changes.get(r.index, r.rect)
			changes[r.index] = Rect2i(at.position, at.size + Vector2i(grow, 0))
	var bar := file.root().rect
	var menu_rect: Rect2i = changes.get(menu.index, menu.rect)
	var menu_x := bar.position.x + bar.size.x - menu_rect.size.x
	var delta := menu_x - menu_rect.position.x
	if delta != 0:
		# The menu's own SetPos (vslot 0x98); its children go with it, as a
		# moved window's do (0xb90cf0).
		_shift(file, menu.index, Vector2i(delta, 0), changes)
	if changes.is_empty():
		return file
	return _copy_with(file, changes)

## Round 840 (OURS, SHOW_STALL_NETWORK): the menu and its tile 25 taller
## upwards, every item and line from the top down to 117 a row up, so 120
## keeps the row it shares with 117 in the file.
func _make_stall_network_row(file: TwoDtReader.TwoDtFile, menu: TwoDtReader.Record, changes: Dictionary) -> void:
	var stall := file.child_with_id(menu.index, ID_MENU_STALL)
	if stall == null or file.child_with_id(menu.index, ID_MENU_STALLNET) == null:
		return
	var row_y := stall.rect.position.y
	var up := Vector2i(0, -MENU_ROW)
	changes[menu.index] = Rect2i(menu.rect.position + up, menu.rect.size + Vector2i(0, MENU_ROW))
	var tile := file.child_with_id(menu.index, ID_MENU_TILE)
	if tile != null:
		changes[tile.index] = Rect2i(tile.rect.position + up, tile.rect.size + Vector2i(0, MENU_ROW))
	for c in menu.children:
		var r := file.records[c]
		if r.id == ID_MENU_STALLNET or r.id == ID_MENU_TILE:
			continue
		if r.rect.position.y < row_y or r.id == ID_MENU_STALL:
			_shift(file, c, up, changes)

func _shift(file: TwoDtReader.TwoDtFile, i: int, by: Vector2i, changes: Dictionary) -> void:
	var r: Rect2i = changes.get(i, file.records[i].rect)
	changes[i] = Rect2i(r.position + by, r.size)
	for c in file.records[i].children:
		_shift(file, c, by, changes)

func _text_width(text: String, font_index: int) -> int:
	if text == "":
		return 0
	var font: Font = _ui_builder.font_at(font_index)
	if font == null:
		font = ThemeDB.fallback_font
	var fs: int = UiBuilder.FONT_SIZES[font_index] if font_index >= 0 and font_index < UiBuilder.FONT_SIZES.size() \
		else UiBuilder.FONT_SIZE_FALLBACK
	return int(ceil(font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x))

static func _copy_with(file: TwoDtReader.TwoDtFile, changes: Dictionary) -> TwoDtReader.TwoDtFile:
	var out := TwoDtReader.TwoDtFile.new()
	out.unresolved = file.unresolved
	out.ambiguous = file.ambiguous
	for r in file.records:
		if not changes.has(r.index):
			out.records.append(r)
			continue
		var copy := TwoDtReader.Record.new()
		for p in r.get_property_list():
			if int(p["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE:
				copy.set(p["name"], r.get(p["name"]))
		copy.rect = changes[r.index]
		out.records.append(copy)
	return out

# --- behaviour --------------------------------------------------------------

func _wire() -> void:
	var menu_btn := _nodes.get(ID_BTN_MENU) as BaseButton
	if menu_btn != null:
		# 0x60a700: the menu shows if hidden and hides if shown.
		menu_btn.pressed.connect(toggle_menu)
	var up := _nodes.get(ID_PAGE_UP) as BaseButton
	if up != null:
		up.pressed.connect(_next_page)
	var down := _nodes.get(ID_PAGE_DOWN) as BaseButton
	if down != null:
		down.pressed.connect(_prev_page)
	for id in [ID_BTN_CHARACTER, ID_BTN_INVENTORY, ID_BTN_SKILL, ID_BTN_MALL]:
		var btn := _nodes.get(id) as BaseButton
		if btn != null:
			btn.pressed.connect(_on_command.bind(int(id)))
	if _menu != null:
		for id in MENU_ITEMS:
			var item := TwoDtBuilder.child(_menu, int(id)) as BaseButton
			if item != null:
				item.pressed.connect(_on_command.bind(int(id)))

## 0x60cd10: every button and item runs its window's toggle, then hides the
## menu (0x60cf2b..0x60cf3a).
func _on_command(id: int) -> void:
	if MENU_ACTIONS.has(id):
		menu_action.emit(String(MENU_ACTIONS[id]))
	hide_menu()

func toggle_menu() -> void:
	if _menu == null:
		return
	if _menu.visible:
		hide_menu()
	else:
		show_menu()

func show_menu() -> void:
	if _menu == null:
		return
	_menu.visible = true
	_clamp_menu()

## The menu closes as the client closes it (see _input).
func hide_menu() -> void:
	if _menu != null and _menu.visible:
		_menu.visible = false
		if _menu.has_meta(UiBuilder.AUTHORED_RECT_META):
			_menu.position = (_menu.get_meta(UiBuilder.AUTHORED_RECT_META) as Rect2).position

## Keeps the open menu inside the view. **This project's own rule**, not the
## client's: the client lays the UI out for its own resolution and was not
## read clamping this menu, but here a UI scale of 1.5 on a 1152x648 window
## put its top 30 pixels above the screen. It moves only as far as needed,
## from its authored place, and goes back there when it closes.
func _clamp_menu() -> void:
	if _menu == null or not _menu.is_inside_tree():
		return
	if _menu.has_meta(UiBuilder.AUTHORED_RECT_META):
		_menu.position = (_menu.get_meta(UiBuilder.AUTHORED_RECT_META) as Rect2).position
	var view := get_viewport().get_visible_rect()
	var r := _menu.get_global_rect()
	var shift := Vector2.ZERO
	if r.position.y < view.position.y:
		shift.y = view.position.y - r.position.y
	elif r.end.y > view.end.y:
		shift.y = view.end.y - r.end.y
	if r.position.x < view.position.x:
		shift.x = view.position.x - r.position.x
	elif r.end.x > view.end.x:
		shift.x = view.end.x - r.end.x
	_menu.position += shift

## The client hides this menu on every left and right press its interface
## handles: CGInterface::vslot_017 (0x77c260) runs, for WM_LBUTTONDOWN (0x201,
## 0x77c44d..0x77c49f) and WM_RBUTTONDOWN (0x204, 0x77c67f..0x77c6d2),
## `GetWindow(0xaf)` and `0x60a610`, a thunk that jumps to the menu's
## (+0x3cc) ShowWindow with 0. **Whether that handler also sees a press that
## lands on another window was not read**; here any left or right press that
## is not on the menu itself or on its button (4, which toggles it) closes it,
## over the world or over another window alike -- a choice, and the old Godot
## popup's behaviour.
##
## Escape closes it too, before anything else takes the key (HudPanels would
## otherwise open the system window) -- unless a text line has the keyboard,
## which takes that Escape first (round 606). **Also this project's choice**:
## the client's Escape handling for this menu was not read.
func _input(event: InputEvent) -> void:
	if _menu == null or not _menu.visible:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if not mb.pressed or (mb.button_index != MOUSE_BUTTON_LEFT and mb.button_index != MOUSE_BUTTON_RIGHT):
			return
		var at := mb.position
		var btn: Control = _nodes.get(ID_BTN_MENU)
		if _menu.get_global_rect().has_point(at) or (btn != null and btn.get_global_rect().has_point(at)):
			return
		hide_menu()
	elif event is InputEventKey:
		var key := event as InputEventKey
		if key.pressed and not key.echo and key.keycode == KEY_ESCAPE:
			# A text line with the keyboard -- the chat line, opened by Enter
			# while the menu is up -- takes Escape first and ends its input
			# (round 606); the next Escape closes the menu. Ours, like the
			# rest of this Escape.
			var focus := get_viewport().gui_get_focus_owner()
			if (focus is LineEdit or focus is TextEdit) and focus.is_visible_in_tree():
				return
			hide_menu()
			get_viewport().set_input_as_handled()

func is_menu_open() -> bool:
	return _menu != null and _menu.visible

## The bar's menu button, for a caller that decorates it (World3D's command
## tooltip, which is this project's own wording).
func menu_button() -> Control:
	return _nodes.get(ID_BTN_MENU)

## A direct child of the bar by its id, or of the menu by [59, id].
func control(path: Array) -> Control:
	return TwoDtBuilder.find_path(bar_root, path) if bar_root != null else null

static func _set_shown(node: Control, shown: bool) -> void:
	if node != null:
		node.visible = shown

## Makes a middle press on `surface` fire the "m" slot, as it does over the
## world (World3D._unhandled_input) and over a slot. A STOP surface consumes
## the press, so World3D never sees it (round 529). The bar's body and
## World3D's other STOP surfaces -- the minimap, the player-info block and the
## target window -- share this one path (round 531). Connected once, however
## often it is asked, so a surface fires once per press.
## Round 833: the button that fires the "m" slot on the bar's body and the
## relayed surfaces -- the middle one, or the right one in mouse mode 1 (the
## Key Map tab, World3D.set_mouse_mode). A slot's own right button stays its
## use.
var mouse_slot_button := MOUSE_BUTTON_MIDDLE

func relay_middle_button(surface: Control) -> void:
	if surface == null or surface.gui_input.is_connected(_on_body_gui_input):
		return
	surface.gui_input.connect(_on_body_gui_input)

func _on_body_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == mouse_slot_button:
		activate_mouse_slot()

# --- the readouts (CNIFUnderMenuBar::vslot_012, 0x60b440) -------------------

## The skill points: `%d` of the unspent total on 12, and the gauge 5 filled
## with the progress toward the next point (retail: SP experience / 400).
## `progress_percent` is 0..100; the server sends no SP experience, so callers
## leave it out and the gauge is drawn empty rather than invented.
func set_sp(points: int, progress_percent: float = -1.0) -> void:
	if _gauge_sp != null:
		_gauge_sp.min_value = 0
		_gauge_sp.max_value = 100
		_gauge_sp.value = clampf(progress_percent, 0.0, 100.0) if progress_percent >= 0.0 else 0.0
	_set_label(ID_SP_VALUE, "%d" % points)

## The level's experience, the way the update reads it: the percent (exp x
## 100 / the level's requirement) capped at 99.99; 15 shows it `%.2f %%`; 10
## shows its whole tens (ftol, then / 10); x = percent - tens x 10 + 0.005 is
## the progress through the current tenth, 17 shows `%d%%` of x x 10, and
## the ten gauges fill as x's whole part full, the next one x's fraction, the
## rest empty (0x60b4d2..0x60b76e). Retail writes the fraction one past the
## last gauge when x reaches 10 (+0x394, which is not a gauge); here it is
## dropped.
func set_exp(percent: float) -> void:
	var pct := maxf(percent, 0.0)
	if pct >= EXP_PERCENT_CAP:
		pct = EXP_PERCENT_CAP
	var tens := int(pct) / 10
	var x := pct - tens * 10 + 0.005
	var full := int(x)
	for i in _exp_gauges.size():
		var fill := 1.0 if i < full else 0.0
		if i == full:
			fill = x - full
		_exp_gauges[i].min_value = 0
		_exp_gauges[i].max_value = 100
		_exp_gauges[i].value = fill * 100.0
	_set_label(ID_EXP_PERCENT, "%.2f %%" % pct)
	_set_label(ID_EXP_TENS, "%d" % tens)
	_set_label(ID_EXP_STEP, "%d%%" % int(x * 10.0))

## 13: `%s. %d` of UIIT_STT_LEVEL_LV and the level (0x60b774..0x60b7aa).
func set_level(level: int) -> void:
	var lv := _ui_builder.resolve_text(LEVEL_TEXT) if _ui_builder != null else LEVEL_TEXT
	_set_label(ID_LEVEL, "%s. %d" % [lv, level])

func _set_label(id: int, text: String) -> void:
	var node: Control = _nodes.get(id)
	if node != null and _twodt != null:
		_twodt.set_text(node, text)

## The text a bar control shows, or "".
func text_of(id: int) -> String:
	return TwoDtBuilder.text_of(_nodes.get(id))

# --- quick slots ------------------------------------------------------------

## Puts an icon on a quick slot with the count it draws: `count` > 0 is
## drawn (a 1 too, as the original does for an expendable), 0 draws none.
## A caller that does not know the count passes none; apply_item_counts
## sets every slot's from the bag.
func set_slot_item(slot_index: int, icon: Texture2D, count: int = 0) -> void:
	if not _slot_nodes.has(slot_index):
		return
	var node: Control = _slot_nodes[slot_index]
	var icon_rect := node.get_node_or_null(ICON_NODE) as TextureRect
	if icon_rect != null:
		icon_rect.texture = icon
	set_slot_count(slot_index, count if icon != null else 0)
	# An emptied slot drops its re-use display (round 785).
	if icon == null:
		var over := node.get_node_or_null(DELAY_NODE) as Control
		if over != null:
			over.visible = false

## The count a quick slot draws, 0 for none.
func set_slot_count(slot_index: int, count: int) -> void:
	var node: Control = _slot_nodes.get(slot_index)
	var count_lbl := node.get_node_or_null(COUNT_NODE) as Label if node != null else null
	if count_lbl == null:
		return
	var text := str(count) if count > 0 else ""
	if count_lbl.text != text:
		count_lbl.text = text
		count_lbl.queue_redraw()

## The count a quick slot draws, 0 for none (tests, QA).
func slot_count(slot_index: int) -> int:
	var node: Control = _slot_nodes.get(slot_index)
	var count_lbl := node.get_node_or_null(COUNT_NODE) as Label if node != null else null
	return int(count_lbl.text) if count_lbl != null and count_lbl.text.is_valid_int() else 0

## What each item quick slot draws (round 786): the stack of the bag slot it
## is bound to, when `shows(item_id, quantity)` says the original draws one
## (HudPanels.bar_shows_count: a stackable expendable, a 1 included --
## 0x680da0's kind 0x0c / 0x46 case and the +0x679 max-stack flag, READ),
## else 0. `quickslot_items` is World3D's
## {quick slot: {"item", "slot"}}; `bag_slots` the bag's entries (anything
## with slot_index, item_id and quantity). READ: the slot keeps the bag's
## own SOItem (0x6871d0 stores it at +0x390, from 0x60c430 for every quick
## slot bound to the bag slot), so what it draws is that slot's stack, live,
## not a total over the bag.
static func item_counts(quickslot_items: Dictionary, bag_slots: Array, shows: Callable) -> Dictionary:
	var by_slot := {}
	for e in bag_slots:
		by_slot[int(e.get("slot_index"))] = e
	var out := {}
	for qs in quickslot_items:
		var bind: Dictionary = quickslot_items[qs]
		var e = by_slot.get(int(bind.get("slot", -1)))
		var n := 0
		if e != null and int(e.get("item_id")) == int(bind.get("item", -2)):
			var qty := int(e.get("quantity"))
			if shows.call(int(e.get("item_id")), qty):
				n = qty
		out[int(qs)] = n
	return out

## Sets every quick slot's count on every page from the bag (item_counts);
## a slot no item is bound to draws none. World3D calls it whenever the bag
## or the bar changes -- the original reads the count each frame, so a
## change shows at once.
func apply_item_counts(quickslot_items: Dictionary, bag_slots: Array, shows: Callable) -> void:
	var counts := item_counts(quickslot_items, bag_slots, shows)
	for qs in _slot_nodes:
		set_slot_count(int(qs), int(counts.get(int(qs), 0)))

## A quick slot's re-use display (round 785; corrected round 786): while a
## skill's re-use time runs, one cell of interface\skill\skill_delay.ddj
## over the icon, the cell SkillCooldowns.delay_frame picks; for 500 ms after
## it ends, one cell of interface\skill\skill_charge.ddj,
## SkillCooldowns.charge_frame. -1 hides either. SkillDelayOverlay has the
## reading (READ, UI_SILKMALL::FUN_0067cfb0: the cell is 1/16 -- 1/4 for the
## charge -- of the sheet, MEASURED 256 x 256 and 64 x 64, so 16-pixel cells
## in both) and draws one cell stretched over the slot's whole 32 x 32 (the
## slot's own rect, as the icon is). It sits under the count (round 786):
## 0x685e50 draws the overlays (0x67cfb0) before the count (0x67bd70), READ.
const DELAY_NODE := SkillDelayOverlay.NODE

## Round 826: `left_ms`, the time left, is drawn in figures after the sweep
## and before the count (CoolTimeText, READ: 0x67c920 for a quick slot).
func set_slot_cooldown(slot_index: int, delay_frame: int, charge_frame: int, left_ms: int = 0) -> void:
	if not _slot_nodes.has(slot_index):
		return
	var node: Control = _slot_nodes[slot_index]
	var sheet_for := Callable()
	if _ui_builder != null:
		sheet_for = _ui_builder.load_texture
	SkillDelayOverlay.apply(node, sheet_for, delay_frame, charge_frame, Rect2(),
		node.get_node_or_null(ICON_NODE))
	CoolTimeText.apply(node, sheet_for, left_ms, node.get_node_or_null(COUNT_NODE))

## The figures a slot's re-use shows now ("" for none), for tests.
func slot_cool_time(slot_index: int) -> String:
	var t: CoolTimeText = (_slot_nodes[slot_index] as Control).get_node_or_null(CoolTimeText.NODE) \
			if _slot_nodes.has(slot_index) else null
	return t.shown_text() if t != null and t.visible else ""

## The cell a slot's re-use display shows, for tests: [sheet, frame] or [].
func slot_cooldown_cell(slot_index: int) -> Array:
	if not _slot_nodes.has(slot_index):
		return []
	var shown := SkillDelayOverlay.shown(_slot_nodes[slot_index] as Control)
	return shown.slice(0, 2)

func clear_slot(slot_index: int) -> void:
	set_slot_item(slot_index, null, 0)

## The seal star on the quick slots (ItemSealEdge): `seals` maps a slot index
## to the seal item it holds; every other slot's star is hidden. READ: an
## item on the bar is set from its bag item (0x60c430 -> SetItem 0x6871d0),
## whose +0x28 is set, so a seal item there gets the star as in the bag.
func set_slot_seals(seals: Dictionary) -> void:
	for slot_index in _slot_nodes:
		var icon := slot_icon_rect(int(slot_index))
		var id := int(seals.get(slot_index, -1))
		ItemSealEdge.show_on(icon, _ui_builder, id >= 0, id)

func _next_page() -> void:
	_select_page(_page + 1)

func _prev_page() -> void:
	_select_page(_page - 1)

## 0x60a730: below 0 wraps to 3, above 3 to 0; the label reads `F%d` of the
## page + 1; every page slot is hidden and the page's ten shown (quick slots
## page x 10 + 1 .. + 10).
func _select_page(page: int) -> void:
	if page < 0:
		page = MAX_PAGES - 1
	elif page >= MAX_PAGES:
		page = 0
	_page = page
	_set_label(ID_PAGE_LABEL, PAGE_LABEL_FORMAT % (page + 1))
	_page_slots.clear()
	for index in _slot_nodes:
		if int(index) == MOUSE_SLOT or _lent.has(int(index)):
			continue
		(_slot_nodes[index] as Control).visible = false
	for k in SLOTS_PER_PAGE:
		var index := page * SLOTS_PER_PAGE + k + 1
		_page_slots.append(index)
		if _slot_nodes.has(index):
			(_slot_nodes[index] as Control).visible = true

## Selects a page by number, 1..MAX_PAGES (F1..F4). Out of range is ignored
## rather than wrapped, so a stray key cannot move the bar.
func set_page(page: int) -> void:
	if page < 1 or page > MAX_PAGES or page - 1 == _page:
		return
	_select_page(page - 1)

## The page shown, 1-based.
func current_page() -> int:
	return _page + 1

## The quick slot a page's k-th slot (0..9) is: page x 10 + k + 1.
static func slot_index(page: int, k: int) -> int:
	return (page - 1) * SLOTS_PER_PAGE + k + 1

## The quick slot the number key for k (0..9; the "0" key is 9) addresses on
## the current page (0x780c47: '1'..'9' -> 1..9, '0' -> 10, then
## `0x60bb80`: + page x 10).
func slot_for_key(k: int) -> int:
	return slot_index(_page + 1, k)

func activate_key(k: int) -> void:
	select_slot_frame(k)
	quickslot_activated.emit(slot_for_key(k))

## Round 826: the selection frame, child 103 (`ub_slot_arrow.ddj`), on page
## slot `k` (0..9). READ, FUN_0060a820(k): the frame is shown (+0x5c(1)) and
## moved (+0x9c) to the k-th of the first page's slots (+0x3d8 + k x 4, whose
## positions every page's slots share) less 4 across and 3 down, and a fade
## started on it: 0x46ca80(255, 0, 4.0, 0.0, 0) (round 827, `step_slot_frame`).
## The quick-slot use FUN_0060bb80(n) calls it first for a use numbered 1..10
## -- abs = n + page x 10, then 0x60a820((abs - 1) % 10) -- whether or not the
## use goes through: the number keys (n = 1..10 on any page) and a right-click
## on a first-page slot (n = the slot's own number, 1..10). The "m" slot (n 0),
## slots 11..50 (n 11..50) and a page flip (0x60a730) leave it. Nothing else
## touches +0x4a4: once shown it stays (faded out) until the bar is rebuilt.
func select_slot_frame(k: int) -> void:
	if k < 0 or k >= PAGE_SLOT_IDS.size():
		return
	var arrow := _nodes.get(ID_SLOT_ARROW) as Control
	var slot := _nodes.get(PAGE_SLOT_IDS[k]) as Control
	if arrow == null or slot == null:
		return
	# OURS: it takes no mouse input, so the slot under it is still the one
	# right-clicked.
	arrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for c in arrow.find_children("*", "Control", true, false):
		(c as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	arrow.position = slot.position + SLOT_FRAME_OFFSET
	_set_shown(arrow, true)
	_slot_frame = k
	# 0x46ca80: from 255 (+0x130), now 255 (+0x131), to 0 (+0x132), over 4.0
	# (+0x134, 0xd8ada8), 0.0 gone (+0x138), no hide at the end (+0x18c 0).
	_frame_alpha = SLOT_FRAME_FROM
	_frame_length = SLOT_FRAME_LENGTH
	_frame_gone = 0.0
	arrow.modulate.a = _frame_alpha / 255.0
	set_process(true)

## The frame's place against its slot (READ, 0x60a820: x - 4, y - 3).
const SLOT_FRAME_OFFSET := Vector2(-4, -3)
## The page slot the frame is on, -1 before the first use.
var _slot_frame := -1

## Round 827: the frame's fade, the window fade every CGWnd carries (READ;
## the fields on its +0x84 part). Each frame the window's update (vslot 12,
## 0x46cd80) hands the part (+0x84 vslot 1, 0x470780) the frame's seconds
## (DAT_0110f7fc, held at 3.0 -- 0xd8adc4 -- beside the 3000 ms cap on the
## ms one, 0xba4101..0xba412f): with a length not 0, gone += seconds; gone
## > 0 sets the alpha by 0x470a00 -- the end alpha once gone >= length,
## else trunc(from x (1 - gone / length) + to x gone / length) (the x87
## round mode forced to chop, 0x470a65) -- and gone <= 0 the start alpha;
## then gone >= length zeroes gone and length (the fade stops) and calls
## +0x1c (0x46cd10: message 0x8064, and a hide only when +0x18c is 1 and the
## end alpha 0 -- here +0x18c is 0, so the frame stays shown, at alpha 0).
## A new use starts it over at 255. So the frame fades linearly from full to
## nothing over 4 seconds after each use.
const SLOT_FRAME_FROM := 255
const SLOT_FRAME_TO := 0
const SLOT_FRAME_LENGTH := 4.0
const FRAME_SECONDS_CAP := 3.0
var _frame_alpha := SLOT_FRAME_FROM
var _frame_length := 0.0
var _frame_gone := 0.0

func _process(delta: float) -> void:
	step_slot_frame(minf(delta, FRAME_SECONDS_CAP))

## One frame of the frame's fade, `seconds` long (0x470780).
func step_slot_frame(seconds: float) -> void:
	if _frame_length == 0.0:
		set_process(false)
		return
	_frame_gone += seconds
	if _frame_gone > 0.0:
		if _frame_gone >= _frame_length:
			_frame_alpha = SLOT_FRAME_TO
		else:
			var t := _frame_gone / _frame_length
			_frame_alpha = int(SLOT_FRAME_FROM * (1.0 - t) + SLOT_FRAME_TO * t)
	else:
		_frame_alpha = SLOT_FRAME_FROM
	if _frame_gone >= _frame_length:
		_frame_gone = 0.0
		_frame_length = 0.0
	var arrow := _nodes.get(ID_SLOT_ARROW) as Control
	if arrow != null:
		arrow.modulate.a = _frame_alpha / 255.0

## The frame's alpha now, 0..255 (+0x131).
func slot_frame_alpha() -> int:
	return _frame_alpha

## The page slot (0..9) the selection frame is on, -1 when hidden.
func slot_frame() -> int:
	return _slot_frame

## The middle button's slot, the "m" slot (0x60bb80(0) -> 0x60b850(0)).
func activate_mouse_slot() -> void:
	quickslot_activated.emit(MOUSE_SLOT)

## Fires a quick slot by its index, 0..50 (0x60bb80 with k >= 11 takes k as
## it is: Space+digit's 41..50, which no page shows), or an OURS extra bar's
## slot (51.., HudExtQuickSlots).
func activate_slot(slot_index: int) -> void:
	if slot_index >= 0 and slot_index < SLOT_COUNT:
		quickslot_activated.emit(slot_index)

# --- slots drawn by another window (round 788) ------------------------------

## Set on a slot node whose pick-up is off: the Additional Quick Slot's Lock
## Slots (READ: 0x65f390 sets each proxy's +0x64 through 0xb9daf0, and the
## left-button release 0x6525b1 picks up only while it is set).
const PICK_LOCK_META := "opensro_pick_locked"

## Hands quick slot `index`'s node to another window to draw (the caller
## re-parents it), or null. 41..50 are the bar's own hidden slots (the
## Additional Quick Slot's, READ); 51..SLOT_COUNT-1 are made here on first
## asking (OURS extra bars). The node stays registered: every call by index
## reaches it, and no page shows or hides it from now on.
func lend_slot(index: int) -> Control:
	if index < EXT_FIRST_SLOT or index >= SLOT_COUNT:
		return null
	var node: Control = _slot_nodes.get(index)
	if node == null:
		if index < MAX_QUICKSLOT or bar_root == null:
			return null
		node = Control.new()
		node.name = "ExtSlot%d" % index
		node.size = Vector2(32, 32)
		_register_slot(index, node)
	_lent[index] = true
	return node

## Takes back a lent slot whose window is going away: an OURS slot (51..) is
## forgotten -- its node goes with its window, and what it held stays in the
## caller's tables -- and one of 41..50 comes back to the bar, hidden.
func release_slot(index: int) -> void:
	if not _lent.has(index):
		return
	_lent.erase(index)
	var node: Control = _slot_nodes.get(index)
	if index >= MAX_QUICKSLOT:
		_slot_nodes.erase(index)
		return
	if node != null and bar_root != null and is_instance_valid(node):
		if node.get_parent() != null:
			node.get_parent().remove_child(node)
		bar_root.add_child(node)
		bar_root.move_child(node, 0)
		node.visible = false
		node.set_meta(PICK_LOCK_META, false)

## Whether another window draws this quick slot.
func is_lent(index: int) -> bool:
	return _lent.has(index)

## Every quick slot that has a node, ascending.
func slot_indices() -> Array:
	var out: Array = _slot_nodes.keys()
	out.sort()
	return out

## Turns a slot's pick-up off or on (PICK_LOCK_META).
func set_slot_pick_locked(index: int, locked: bool) -> void:
	var node: Control = _slot_nodes.get(index)
	if node != null:
		node.set_meta(PICK_LOCK_META, locked)

## How a quick slot is named to the player: "M" for the "m" slot, else its
## number key on its page (1..9, 10).
static func slot_label(slot: int) -> String:
	if slot == MOUSE_SLOT:
		return "M"
	return str((slot - 1) % SLOTS_PER_PAGE + 1)

## Where a quickslot-bound item now lives in the bag, or -1 if it is gone.
##
## A quickslot binding stores the BAG SLOT, because that is what OpUseItem
## addresses -- but spending, moving or selling shifts what lives in a slot, so
## a binding left alone would point at whatever took its place and use the
## wrong item. `bag` maps bag slot -> item id.
##
## Prefers the slot the binding already names, so an unmoved item keeps its
## binding; otherwise finds the item anywhere; otherwise -1.
static func resolve_item_binding(item_id: int, current_slot: int, bag: Dictionary) -> int:
	if int(bag.get(current_slot, -1)) == item_id:
		return current_slot
	for slot in bag:
		if int(bag[slot]) == item_id:
			return int(slot)
	return -1

## The visible quick slot under a screen position, or -1. This is what a
## skill or an item dragged onto the bar is dropped onto.
func slot_index_at(global_pos: Vector2) -> int:
	for i in _slot_nodes:
		var node: Control = _slot_nodes[i]
		if node.is_visible_in_tree() and node.get_global_rect().has_point(global_pos):
			return int(i)
	return -1

## Whether a slot currently shows an icon.
func slot_has_item(slot_index: int) -> bool:
	if not _slot_nodes.has(slot_index):
		return false
	var icon_rect := (_slot_nodes[slot_index] as Control).get_node_or_null(ICON_NODE) as TextureRect
	return icon_rect != null and icon_rect.texture != null

## A quick slot's node, or null.
func slot_node(slot_index: int) -> Control:
	return _slot_nodes.get(slot_index)

## Whether an enabled, visible button of the bar (the page arrows, the menu
## button, the menu's lines) is under a global point. HudPanels lets a click
## there through while an icon is held (retail's held-icon filter 0x6523d0
## lets any CIFButton take its click, READ), so a quick slot or a skill can be
## carried to another page of the bar.
func button_at(at: Vector2) -> bool:
	return _button_under(self, at)

static func _button_under(node: Node, at: Vector2) -> bool:
	for child in node.get_children():
		if child is CanvasItem and not (child as CanvasItem).visible:
			continue
		if child is BaseButton and not (child as BaseButton).disabled \
				and (child as Control).get_global_rect().has_point(at):
			return true
		if _button_under(child, at):
			return true
	return false

## A quick slot's icon texture, or null.
func slot_icon(slot_index: int) -> Texture2D:
	var rect := slot_icon_rect(slot_index)
	return rect.texture if rect != null else null

## A quick slot's icon control, or null.
func slot_icon_rect(slot_index: int) -> TextureRect:
	if not _slot_nodes.has(slot_index):
		return null
	return (_slot_nodes[slot_index] as Control).get_node_or_null(ICON_NODE) as TextureRect

## QA only (OPENSRO_QA_SLOTS, F11 -- HudPanels): where the shown quick slots
## are, for a live run's xdotool clicks.
func qa_print_slots() -> void:
	for i in _slot_nodes:
		var node: Control = _slot_nodes[i]
		if node.is_visible_in_tree():
			var p := node.get_global_rect().get_center().round()
			print("QA SLOT quick:%d at %d,%d filled %s" % [int(i), int(p.x), int(p.y), str(slot_has_item(int(i)))])
	for pair in [["up", ID_PAGE_UP], ["down", ID_PAGE_DOWN]]:
		var b := _nodes.get(pair[1]) as Control
		if b != null and b.is_visible_in_tree():
			var c := b.get_global_rect().get_center().round()
			print("QA SLOT barpage:%s at %d,%d page %d" % [pair[0], int(c.x), int(c.y), current_page()])
