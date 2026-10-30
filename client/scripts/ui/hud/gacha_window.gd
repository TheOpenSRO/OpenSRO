extends HudWindow
class_name GachaWindow

## Magic POP, the machine's window (round 838, lane 5; round 843, lane P):
## CIFGhaCha, READ from sro_client.exe (docs/protocol/magic_pop.md) unless
## labelled.
##
## - **The window**: ginterface.txt's GDR_GHACHA (ID 140 = 0x8c), 673 x 428 in
##   mgame_wnd_, caption UIIT_PAG_GACHA_TITLE "Magic POP"; resinfo\ifghacha.txt
##   sections Create and Inventory (Create c:0x746be0), with config\define.txt's
##   GACHA_SECOND_VER (MEASURED: defined) taking the page spinner 700. The
##   Start of the select window (c:0x74a2b0) runs the build c:0x749560 and
##   shows this window.
## - **Its own bag pane** (round 843; c:0x749560, c:0x748790, c:0x747a40,
##   c:0x749030). Opening Magic POP opens no other window (c:0x79c060 reaches
##   none of the inventory's openers): the window draws the bag itself.
##   - **Page tabs**, one per bag page (IFInventory's tab count, `0x6af5e0`):
##     CIFSelectableArea ID 500 + i at (475 + 62 i, 55), 60 x 24, the art
##     `com_tab_on.ddj` selected / `com_tab_off.ddj`, the first one's text
##     UIIT_CTL_BELOINGING ("Page 1"), **every other one's
##     UIIT_STT_INVENTORY_EXTENSION_TEB ("Page 2")** -- the original names a
##     third page "Page 2" too (c:0x748918..0x748941: the two keys only).
##     A tab acts on the press (CIFSelectableArea, WM_LBUTTONDOWN), busy or
##     not (c:0x747e30 has no busy test).
##   - **Cells**: one CIFSlotWithHelp per bag slot the bag window has (its
##     pages x 32, `0x6af620`), ID 200 + i at (494 + 36 (i % 4),
##     91 + 36 ((i % 32) / 4)), 32 x 32, kind 0x8c, index i. A slot at or past
##     the bag's size (`0x6af600`) shows `interface\pet\pt_block.ddj` and is
##     disabled; the others mirror the bag slot (c:0x749030: SetItem with the
##     bag slot's own record, so the seal star and the pet / spirit edges show
##     as in the bag). IFInventory re-mirrors a slot whenever it sets one
##     (c:0x6b7c03 in 0x6b7770).
##   - **Showing a page** (c:0x747a40): the old tab off, the new one on, the
##     page's 32 cells shown and every other cell hidden. The pane starts on
##     page 0 each open (the window is built anew, +0x8e5 = 0).
##   - **The gold** (c:0x7494b2..0x74950b): GDR_CHACHA_STA_MONEY gets the
##     purse grouped by thousands (0x8c1d50(.., 3, 0), the bag's own format),
##     uncoloured (no 0x5d3df0 here), each time a cell is mirrored.
## - **The prizes** (c:0x748a30): the machine's prize set filtered by the
##   select window's kind, twelve to a page in SLOT_100..111 (not pickable,
##   0xb9daf0(0)); each a fresh record with +0x28 set, so a seal prize shows
##   the star. The spinner's range is the list's pages (c:0x748d6b) and a
##   change re-lists and drops the choice (c:0x749000).
## - **Choosing** (CIFSlotWithHelp::vslot_029 c:0x681341 -> message 0xc8 ->
##   c:0x747dd0): a left click on a filled prize slot while not busy keeps it
##   (+0x880) and starts its marker, 0x666680(1): the pet-edge sheet
##   `pt_edge_effect.ddj` turning (9 cells, 50 ms) on that slot (the draw at
##   c:0x67ea55 tests +0x596 and +0x66c).
## - **The status line** (c:0x747940, on static 36) and the state +0x8d8: no
##   prize chosen 0, UIIT_MSG_GACHA_CHOICE "Choose item of desire."; a prize
##   but no card in the card slot 1, UIIT_MSG_GACHA_ENTRY "Register Magic POP
##   card."; a card 2, UIIT_MSG_GACHA_BUTTON_CLICK "Click PLAY button." and
##   PLAY enabled (0x655ec0).
## - **The card** goes in as every item moves in the original: click it up
##   from a cell (the held icon, HeldIcon), click it down on the card slot.
##   CIFGhaCha::vslot_028 (c:0x749a30) takes the put-down, whatever was under
##   the cursor (a slot hands it to its window, 0x666560):
##   - nothing while busy or unless the state is 1 (a prize chosen, the card
##     slot not holding a card);
##   - c:0x7478c0: a cell of the **first 32** put down anywhere but the card
##     slot is refused (the loop stops at 0x20), and nothing is taken while
##     the prize list is empty. So a card from page 2 or 3 is taken wherever
##     in the window it is put down; one from page 1 only on the card slot;
##   - a cell of this window (kind 0x8c) whose index is inside the bag: its
##     item, if a 3/3/14/1 card (0x538510), goes on the card slot, which keeps
##     the bag index (0x6667f0); anything else changes nothing;
##   - the card slot itself (index 0x70, past the bag) put down: emptied;
##   - then the status line (c:0x747940). The put-down is always taken.
## - **The card slot follows its bag slot** (c:0x749030's tail): emptied when
##   the bag slot empties, or when it is set to anything but a 3/3/14/2 coupon.
## - **PLAY** (c:0x7459b0): not busy, the card slot filled, a GachaID, the bag
##   slot still a card (else the card slot is emptied). Busy; the DECO (51)
##   shown; timer 1 (100 ms) the two roll statics through
##   gacha_roll%04d.ddj (frame +0x8dc: reset past 20, shown, then +2);
##   snd_gacha_move; timer 2 (4000 ms); timer 3 (100 ms); snd_gacha_turn.
##   Timer 2 sends 0x7118 {npc uid, GachaID, card slot + 13}, puts
##   gacha_roll_original.ddj back and kills timers 1 and 2 (c:0x746dd2..).
## - **Timer 3** (c:0x746f21): STA_EFFACT (50) shows ga_effect_%02d of its
##   counter +0x8e0 (from 1); during the global tick 7..15 and 23..35 the
##   counter is held; the DECO steps a frame. At tick 41: timer 3 killed,
##   counter 1, tick 0, ga_effect_01.ddj, the DECO hidden; after a win
##   (+0x8e4) the DECO plays ga_effect_sucess.ddj (64 x 81 cells, 15 frames,
##   from frame 1) on timer 4 (100 ms) until frame 14, then hides and goes
##   back to the prepare sheet (c:0x74710c). After a loss the tick is left at
##   1 (the increment after the reset), a quirk the next PLAY inherits.
## - **The DECO** (c:0x7496c5..0x749773): GDR_GHACHA_DECO, a
##   CIFDecoratedStatic over the card slot, `alcm_effect_prepare.ddj` in
##   64 x 64 cells, 16 frames, additive (+0x388 = 1), hidden until PLAY.
## - **The result** 0xB118 (c:0x88d690 -> c:0x748270): the status line, the
##   card slot shows its bag slot (the coupon by now); a win
##   UIIT_MSG_GACHA_WIN and snd_gacha_win, a loss UIIT_MSG_GACHA_LOSE and
##   snd_gacha_end; busy cleared.
## - **The card's change** (0x3040 mask 1 on the bag slot, c:0x88c1e4 ->
##   c:0x747890 -> 0x6665f0): the cell flashes `icon_mall_transgender.ddj`.
## - **Closing** (vslot_043 c:0x7481f0) is refused while busy; the close
##   (c:0x79c060(0)) sounds snd_window_close.
##
## OURS, labelled:
##   - The two result lines have only Korean text in the archive (their
##     English columns are empty, MEASURED); the fallbacks are their meaning,
##     "Congratulations." and "The item you wanted was not won.".
##   - A refusal (any code) clears busy and is written to the log: retail
##     keeps only the code's low byte, shows nothing for these codes and stays
##     busy, which would leave the window unclosable.
##   - OpenSRO's server sends no 0x3040 for the card: the card's change is
##     seen in the bag list that follows the result (World3D), and the cell's
##     flash is played then.
##   - PLAY stays disabled from the result until the status line is redrawn
##     (a choice or a card put down); what the original's button shows in
##     between is OPEN.

signal play_requested(npc_uid: int, gacha_id: int, bag_slot: int)
## The card's bag slot turned into its coupon (the cell flashed): the bag
## window's own slot flashes too (0x3040 mask 1 -> 0x6b44d0).
signal coupon_flashed(bag_slot: int)

const LAYOUT := "resinfo\\ifghacha.txt"
const REGISTRY := "GDR_GHACHA"
const PRIZE_SLOTS := 12
const PRIZE_FIRST_ID := 100
## The window's kind on its slots (0x6666f0(0x8c)) and the card slot's index.
const KIND := 0x8c
const CARD_INDEX := 0x70

## The bag pane (c:0x749560, c:0x748790).
const PAGE_SLOTS := 32
const MAX_PAGES := 3
const BAG_COLS := 4
const BAG_ORIGIN := Vector2(494, 91)
const BAG_PITCH := 36.0
const CELL := Vector2(32, 32)
const CELL_FIRST_ID := 200
const BLOCK_DDJ := "interface\\pet\\pt_block.ddj"
const TAB_FIRST_ID := 500
const TAB_ORIGIN := Vector2(475, 55)
const TAB_PITCH := 62.0
const TAB_SIZE := Vector2(60, 24)
const TAB_ON := "interface\\ifcommon\\com_tab_on.ddj"
const TAB_OFF := "interface\\ifcommon\\com_tab_off.ddj"
const TAB_TEXT_FIRST := ["UIIT_CTL_BELOINGING", "Page 1"]
const TAB_TEXT_OTHER := ["UIIT_STT_INVENTORY_EXTENSION_TEB", "Page 2"]
const TABS_NODE := "GachaBagTabs"

const ROLL_FRAME := "interface\\game\\gacha_roll%04d.ddj"
const ROLL_ORIGINAL := "interface\\game\\gacha_roll_original.ddj"
const ROLL_LAST := 20
const ROLL_MS := 100
const SEND_MS := 4000
const EFFECT_FRAME := "interface\\game\\ga_effect_%02d.ddj"
const EFFECT_FIRST := "interface\\game\\ga_effect_01.ddj"
const EFFECT_TICKS := 41
const DECO_PREPARE := "interface\\alchemy\\alcm_effect_prepare.ddj"
const DECO_PREPARE_CELL := Vector2(64, 64)
const DECO_PREPARE_FRAMES := 16
const DECO_WIN := "interface\\game\\ga_effect_sucess.ddj"
const DECO_WIN_CELL := Vector2(64, 81)
const DECO_WIN_FRAMES := 15
const DECO_WIN_LAST := 14

const SND_MOVE := "UI:snd_gacha_move:-:-:-:-"
const SND_TURN := "UI:snd_gacha_turn:-:-:-:-"
const SND_WIN := "UI:snd_gacha_win:-:-:-:-"
const SND_END := "UI:snd_gacha_end:-:-:-:-"

const MSG_CHOICE := ["UIIT_MSG_GACHA_CHOICE", "Choose item of desire."]
const MSG_ENTRY := ["UIIT_MSG_GACHA_ENTRY", "Register Magic POP card."]
const MSG_PLAY := ["UIIT_MSG_GACHA_BUTTON_CLICK", "Click PLAY button."]
const MSG_WIN := ["UIIT_MSG_GACHA_WIN", "Congratulations."]
const MSG_LOSE := ["UIIT_MSG_GACHA_LOSE", "The item you wanted was not won."]

## The held icon's kinds for this window's slots (HeldIcon payloads).
const HELD_CELL := "gacha_bag"
const HELD_CARD := "gacha_card"

## Hooks the opener sets:
##   icon_of(ref) -> Texture2D; types_of(ref) -> PackedInt32Array;
##   bag_of() -> Array of InventoryNet.Slot-like entries (slot_index,
##     item_id, quantity);
##   size_of() -> int, the bag's size (0: not known, every page open);
##   gold_of() -> int, the purse;
##   slot_fx(icon, ref, bag slot) -- the item slot's effects (the bag slot's
##     record; -1 for a prize's bare record, -1 ref to clear);
##   tip_of(icon, ref, bag slot) -- the hover tooltip (-1 ref clears);
##   count_shows(ref, qty) -> bool -- whether the slot draws its count;
##   pick_up(what, icon, source, at) -> bool -- the held icon.
var icon_of: Callable
var types_of: Callable
var bag_of: Callable
var size_of: Callable
var gold_of: Callable
var slot_fx: Callable
var tip_of: Callable
var count_shows: Callable
var pick_up: Callable

var npc_uid := 0
var prizes: Array = []     # GachaTables.Prize
var page := 0              # the prize spinner's page
var bag_page := 0          # +0x8e5
var chosen := -1           # index into prizes (+0x880's slot)
var card_slot := -1        # the card slot's bag index (0x6667f0), -1 empty
var busy := false          # DAT_00eeb9ac
var _won := false          # +0x8e4
var _prize_nodes: Array = []
var _bag_cells: Array = []     # Control per bag slot (pages x 32)
var _tabs: Array = []          # TextureButton per page
var _pages := 0
var _snapshot: Dictionary = {} # bag slot -> [ref, qty] as last mirrored
var _roll_timer: Timer
var _send_timer: Timer
var _effect_timer: Timer
var _win_timer: Timer
var _roll_frame := 0       # +0x8dc
var _effect_counter := 1   # +0x8e0
## DAT_00eeb9d0: a global in the original, kept across windows.
static var _effect_tick := 0
var _status: Control
var _play: BaseButton
var _spin: Control
var _deco: TextureRect
var _deco_atlas := AtlasTexture.new()
var _deco_sheet := DECO_PREPARE
var _deco_cell := DECO_PREPARE_CELL
var _deco_frames := DECO_PREPARE_FRAMES
var _deco_frame := 0
var _switch_sheet: Texture2D = null
## The card slot's bag slot is to flash when its card turns into the
## coupon (set by an answered draw, cleared by the next bag list).
var _await_coupon := false

func setup(builder: UiBuilder) -> bool:
	if not build(builder, LAYOUT, "Magic POP", PackedStringArray(["Inventory"]), builder.archive_defines(), true,
			{"name": REGISTRY, "archive_defines": true}):
		return false
	for i in PRIZE_SLOTS:
		var s := node("GDR_GHACHA_SLOT_%d" % (PRIZE_FIRST_ID + i)) as Control
		_prize_nodes.append(s)
		if s != null:
			s.mouse_filter = Control.MOUSE_FILTER_STOP
			s.gui_input.connect(_on_prize_input.bind(i))
	_status = node("GDR_GHACHA_GRADATION") as Control
	_play = node("GDR_GHACHA_BTN_START") as BaseButton
	if _play != null:
		_play.pressed.connect(play)
		_play.focus_mode = Control.FOCUS_NONE
	_spin = node("GDR_GHACHA_SPIN_PAGE") as Control
	if _spin != null and _spin.has_user_signal("spin_changed"):
		_spin.connect("spin_changed", _on_spin_changed)
	var card := node("GDR_GHACHA_CARD_SLOT") as Control
	if card != null:
		card.mouse_filter = Control.MOUSE_FILTER_STOP
		card.gui_input.connect(_on_card_input)
	_build_deco()
	_roll_timer = _timer(ROLL_MS, _on_roll_tick)
	_send_timer = _timer(SEND_MS, _on_send_due)
	_send_timer.one_shot = true
	_effect_timer = _timer(ROLL_MS, _on_effect_tick)
	_win_timer = _timer(ROLL_MS, _on_win_tick)
	visible = false
	return true

func _timer(ms: int, f: Callable) -> Timer:
	var t := Timer.new()
	t.wait_time = ms / 1000.0
	t.timeout.connect(f)
	add_child(t)
	return t

func _t(pair: Array) -> String:
	var r := _builder.resolve_text(String(pair[0])) if _builder != null else ""
	return r if r != "" and r != String(pair[0]) else String(pair[1])

# --- The bag pane --------------------------------------------------------------

## The bag's size as the pane draws it (0x6af600): the server's, or every
## page open while none is known (as HudPanels draws the bag).
func bag_size() -> int:
	var n := int(size_of.call()) if size_of.is_valid() else 0
	return n if n > 0 else PAGE_SLOTS * MAX_PAGES

## The bag's pages (IFInventory's 0x6b6620 arithmetic, at most 3; the
## same as HudPanels.bag_pages, which this window does not load).
func bag_pages() -> int:
	var size := bag_size()
	return 1 if size <= 1 else mini(((size - 1) >> 5) + 1, MAX_PAGES)

## The pane's tabs and cells for `pages` pages (c:0x749560's loop, 0x748790).
func _build_pane(pages: int) -> void:
	if panel_root == null:
		return
	for c in _bag_cells:
		(c as Node).queue_free()
	_bag_cells.clear()
	var old := panel_root.get_node_or_null(TABS_NODE)
	if old != null:
		panel_root.remove_child(old)
		old.queue_free()
	_tabs.clear()
	_pages = pages
	var strip := Control.new()
	strip.name = TABS_NODE
	strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel_root.add_child(strip)
	var on: Texture2D = _builder.load_texture(TAB_ON) if _builder != null else null
	var off: Texture2D = _builder.load_texture(TAB_OFF) if _builder != null else null
	for i in pages:
		var tab := TextureButton.new()
		tab.name = "GachaBagTab%d" % (TAB_FIRST_ID + i)
		tab.set_meta("tex_on", on)
		tab.set_meta("tex_off", off)
		tab.ignore_texture_size = true
		tab.stretch_mode = TextureButton.STRETCH_SCALE
		tab.focus_mode = Control.FOCUS_NONE
		# CIFSelectableArea acts on the press (0x64cb80 answers 0x201).
		tab.action_mode = BaseButton.ACTION_MODE_BUTTON_PRESS
		var rect := Rect2(TAB_ORIGIN + Vector2(TAB_PITCH * i, 0), TAB_SIZE)
		tab.set_meta(UiBuilder.AUTHORED_RECT_META, rect)
		tab.position = rect.position
		tab.size = rect.size
		tab.custom_minimum_size = rect.size
		tab.pressed.connect(select_bag_page.bind(i))
		var caption := Label.new()
		caption.name = "Text"
		caption.text = _t(TAB_TEXT_FIRST if i == 0 else TAB_TEXT_OTHER)
		caption.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		caption.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if _builder != null:
			var font := _builder.font_at(0)
			if font != null:
				caption.add_theme_font_override("font", font)
		caption.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[0])
		tab.add_child(caption)
		strip.add_child(tab)
		_tabs.append(tab)
	if _builder != null:
		ItemCountLabel.ensure_digits(_builder)
	for i in pages * PAGE_SLOTS:
		var cell := Control.new()
		cell.name = "GachaBag%d" % (CELL_FIRST_ID + i)
		cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var r := i % PAGE_SLOTS
		var rect := Rect2(BAG_ORIGIN + Vector2(r % BAG_COLS, r / BAG_COLS) * BAG_PITCH, CELL)
		cell.set_meta(UiBuilder.AUTHORED_RECT_META, rect)
		cell.position = rect.position
		cell.size = rect.size
		var icon := TextureRect.new()
		icon.name = "ItemIcon"
		icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.mouse_filter = Control.MOUSE_FILTER_STOP
		icon.gui_input.connect(_on_cell_input.bind(i))
		cell.add_child(icon)
		var count := ItemCountLabel.new()
		count.name = "CountLabel"
		count.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		cell.add_child(count)
		panel_root.add_child(cell)
		_bag_cells.append(cell)
	UiBuilder.settle_authored_rects(panel_root)
	print("GACHA: bag pane -- %d page(s), %d cell(s), size %d" % [pages, _bag_cells.size(), bag_size()])

## c:0x747a40: the tab of `p` selected, its 32 cells shown, the rest hidden.
func select_bag_page(p: int) -> void:
	if p < 0 or p >= _pages:
		return
	bag_page = p
	for i in _tabs.size():
		var tab: TextureButton = _tabs[i]
		tab.texture_normal = tab.get_meta("tex_on" if i == p else "tex_off")
	for i in _bag_cells.size():
		(_bag_cells[i] as Control).visible = i / PAGE_SLOTS == p
	print("GACHA: bag page %d of %d" % [p + 1, _pages])

## The pane's cell of bag slot `slot` (shown or not), or null.
func cell_of(slot: int) -> Control:
	return _bag_cells[slot] if slot >= 0 and slot < _bag_cells.size() else null

## The tab of page `p`, or null.
func tab_of(p: int) -> Control:
	return _tabs[p] if p >= 0 and p < _tabs.size() else null

## c:0x749030 for every cell: the bag's item, or the lock past its size.
func _mirror_cells() -> void:
	var size := bag_size()
	var block: Texture2D = null
	var items := _bag_map()
	for i in _bag_cells.size():
		var cell: Control = _bag_cells[i]
		var icon := cell.get_node_or_null("ItemIcon") as TextureRect
		var count := cell.get_node_or_null("CountLabel") as Label
		if icon == null:
			continue
		if i >= size:
			if block == null and _builder != null:
				block = _builder.load_texture(BLOCK_DDJ)
			icon.texture = block
			icon.set_meta("gacha_locked", true)
			_fx(icon, -1, -1)
			_tip(icon, -1, -1)
			if count != null:
				count.text = ""
			continue
		icon.set_meta("gacha_locked", false)
		var it: Array = items.get(i, [-1, 0])
		var ref := int(it[0])
		icon.texture = _icon(ref) if ref >= 0 else null
		_fx(icon, ref, i)
		_tip(icon, ref, i)
		if count != null:
			count.text = str(int(it[1])) if ref >= 0 and _shows_count(ref, int(it[1])) else ""
	_set_gold()

func _set_gold() -> void:
	var money := node("GDR_CHACHA_STA_MONEY") as Control
	if money == null or _builder == null or not gold_of.is_valid():
		return
	_builder.set_static_text(money, grouped(int(gold_of.call())))

## 0x8c1d50(.., 3, 0): grouped by thousands with commas (HudPanels._grouped's
## rule).
static func grouped(value: int) -> String:
	var digits := str(absi(value))
	var out := ""
	for i in range(digits.length() - 1, -1, -1):
		out = digits[i] + out
		var n := digits.length() - i
		if n % 3 == 0 and i > 0:
			out = "," + out
	return ("-" + out) if value < 0 else out

func _fx(icon: Control, ref: int, slot: int) -> void:
	if slot_fx.is_valid():
		slot_fx.call(icon, ref, slot)

func _tip(icon: Control, ref: int, slot: int) -> void:
	if tip_of.is_valid():
		tip_of.call(icon, ref, slot)

func _shows_count(ref: int, qty: int) -> bool:
	return bool(count_shows.call(ref, qty)) if count_shows.is_valid() else qty > 1

# --- Opening -------------------------------------------------------------------

## Opens the window for the machine `uid` with these prizes (c:0x74a2b0 ->
## c:0x749560, on a window built anew).
func open_for(uid: int, list: Array) -> void:
	npc_uid = uid
	prizes = list
	page = 0
	chosen = -1
	card_slot = -1
	busy = false
	_won = false
	_roll_frame = 0
	_effect_counter = 1
	_await_coupon = false
	close_hides = true
	_roll_timer.stop()
	_send_timer.stop()
	_effect_timer.stop()
	_win_timer.stop()
	_show_roll(ROLL_ORIGINAL)
	_set_effect(EFFECT_FIRST)
	_deco_reset()
	if _spin != null:
		_spin.set_meta("value", 0)
		UiBuilder.set_spin_range(_spin, 0, max_prize_page())
	var pages := bag_pages()
	if pages != _pages or _bag_cells.is_empty():
		_build_pane(pages)
	_snapshot = _bag_map()
	select_bag_page(0)
	refresh()
	centre()
	visible = true

## The spinner's top page (c:0x748d6b): 0 under 12 prizes, else the pages
## less one when they divide evenly, else the whole pages.
func max_prize_page() -> int:
	var n := prizes.size()
	if n < PRIZE_SLOTS:
		return 0
	if n % PRIZE_SLOTS == 0:
		return n / PRIZE_SLOTS - 1
	return n / PRIZE_SLOTS

func _on_spin_changed(value: int) -> void:
	# c:0x749000: the choice dropped, the status line, the list again.
	page = value
	chosen = -1
	refresh()

func _icon(ref: int) -> Texture2D:
	return icon_of.call(ref) if icon_of.is_valid() else null

func _bag() -> Array:
	return bag_of.call() if bag_of.is_valid() else []

static func _field(e, names: Array):
	for n in names:
		if e is Dictionary and (e as Dictionary).has(n):
			return e[n]
		if e is Object and n in e:
			return e.get(n)
	return null

## bag slot -> [ref, qty] of what the bag holds now.
func _bag_map() -> Dictionary:
	var out := {}
	for e in _bag():
		var i = _field(e, ["slot_index", "slot", "index"])
		var id = _field(e, ["item_id", "id"])
		if i == null or id == null:
			continue
		var q = _field(e, ["quantity", "count"])
		out[int(i)] = [int(id), int(q) if q != null else 1]
	return out

## The item in bag slot `slot`: [item id, quantity], or [-1, 0].
func bag_item(slot: int) -> Array:
	return _bag_map().get(slot, [-1, 0])

func _types(item_id: int) -> PackedInt32Array:
	return types_of.call(item_id) if types_of.is_valid() and item_id >= 0 else PackedInt32Array()

## 0x538510: TypeID 3/3/14/1, the Magic POP card.
func is_card(item_id: int) -> bool:
	var t := _types(item_id)
	return t.size() >= 4 and t[0] == 3 and t[1] == 3 and t[2] == 14 and t[3] == 1

## 0x666fc0: TypeID 3/3/14/2, the coupon.
func is_coupon(item_id: int) -> bool:
	var t := _types(item_id)
	return t.size() >= 4 and t[0] == 3 and t[1] == 3 and t[2] == 14 and t[3] == 2

# --- Drawing -------------------------------------------------------------------

## Redraws the prizes, the pane, the card slot and the gold, and (when not
## busy) the status line and PLAY.
func refresh() -> void:
	for i in PRIZE_SLOTS:
		var s: Control = _prize_nodes[i]
		if s == null:
			continue
		var k := page * PRIZE_SLOTS + i
		var p: GachaTables.Prize = prizes[k] if k < prizes.size() else null
		var icon := s.get_node_or_null("ItemIcon") as TextureRect
		if icon != null:
			icon.texture = _icon(p.ref_id) if p != null else null
			_fx(icon, p.ref_id if p != null else -1, -1)
			_tip(icon, p.ref_id if p != null else -1, -1)
			_set_chosen_marker(icon, p != null and k == chosen)
		# No count on a prize: 0x680da0's kind-0x8c case draws one only for
		# a slot whose source kind is the bag (0x46), and the prize slots'
		# is 0x8c (c:0x74652c).
		var count := s.get_node_or_null("CountLabel") as Label
		if count != null:
			count.text = ""
	_mirror_cells()
	_draw_card_slot()
	if not busy:
		_say(status_pair())
	if _play != null:
		_play.disabled = not can_play()

func _draw_card_slot() -> void:
	var card := node("GDR_GHACHA_CARD_SLOT") as Control
	if card == null:
		return
	var icon := card.get_node_or_null("ItemIcon") as TextureRect
	var ref := int(bag_item(card_slot)[0]) if card_slot >= 0 else -1
	if icon != null:
		icon.texture = _icon(ref) if ref >= 0 else null
		_fx(icon, ref, card_slot if ref >= 0 else -1)
		_tip(icon, ref, card_slot if ref >= 0 else -1)

## The chosen prize's marker: the pet-edge sheet turning on its slot
## (0x666680(1) / (0)).
func _set_chosen_marker(icon: Control, on: bool) -> void:
	var edge := icon.get_node_or_null("GachaChosenEdge") as ItemStateEdge
	if not on:
		if edge != null:
			edge.clear()
		return
	if edge == null:
		ItemStateEdge.ensure_texture(_builder, ItemStateEdge.Mode.PET)
		edge = ItemStateEdge.new()
		edge.mode = ItemStateEdge.Mode.PET
		edge.name = "GachaChosenEdge"
		icon.add_child(edge)
	edge.set_item(chosen)

## +0x8d8 (c:0x747940): 0 no prize, 1 a prize and no card, 2 ready.
func state() -> int:
	if chosen < 0 or chosen < page * PRIZE_SLOTS or chosen >= (page + 1) * PRIZE_SLOTS:
		return 0
	if card_slot < 0 or not is_card(int(bag_item(card_slot)[0])):
		return 1
	return 2

## The status line's pair for the window's state (c:0x747940).
func status_pair() -> Array:
	match state():
		0:
			return MSG_CHOICE
		1:
			return MSG_ENTRY
	return MSG_PLAY

func can_play() -> bool:
	return not busy and state() == 2

func _say(pair: Array) -> void:
	_say_text(_t(pair))

func _say_text(t: String) -> void:
	if _status != null and _builder != null:
		var l := _builder.set_static_text(_status, t)
		if l != null:
			l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			l.add_theme_color_override("font_color", Color.WHITE)

## The text the status line shows now (tests and the QA log).
func status_text() -> String:
	var l: Label = null
	if _status is Label:
		l = _status as Label
	elif _status != null:
		l = _status.get_node_or_null("Text") as Label
	return l.text if l != null else ""

# --- Input ---------------------------------------------------------------------

## c:0x747dd0: a prize slot clicked while not busy.
func choose_prize(i: int) -> void:
	if busy:
		return
	var k := page * PRIZE_SLOTS + i
	if k < prizes.size():
		chosen = k
		print("GACHA: prize %d chosen (gacha id %d, item %d)" % [k, (prizes[k] as GachaTables.Prize).gacha_id,
			(prizes[k] as GachaTables.Prize).ref_id])
		refresh()

func _on_prize_input(event: InputEvent, i: int) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
		choose_prize(i)

## A cell's click: the pick-up (HeldIcon.is_pick_click) of a filled,
## enabled cell.
func _on_cell_input(event: InputEvent, i: int) -> void:
	var cell := cell_of(i)
	var icon := cell.get_node_or_null("ItemIcon") as TextureRect if cell != null else null
	if icon == null or not HeldIcon.is_pick_click(event) or bool(icon.get_meta("gacha_locked", false)):
		return
	if not icon.get_global_rect().has_point((event as InputEventMouseButton).global_position):
		return
	var it := bag_item(i)
	if int(it[0]) < 0 or not pick_up.is_valid():
		return
	var at := (event as InputEventMouseButton).global_position
	if bool(pick_up.call({"kind": HELD_CELL, "slot": i, "item_id": int(it[0]), "qty": int(it[1]),
			"keep_on_hide": true}, icon.texture, icon, at)):
		accept_event()

## The card slot's click: it can be picked up too (a CIFSlotWithHelp).
func _on_card_input(event: InputEvent) -> void:
	if not HeldIcon.is_pick_click(event) or card_slot < 0 or not pick_up.is_valid():
		return
	var card := node("GDR_GHACHA_CARD_SLOT") as Control
	var icon := card.get_node_or_null("ItemIcon") as TextureRect if card != null else null
	if icon == null or icon.texture == null:
		return
	var at := (event as InputEventMouseButton).global_position
	if bool(pick_up.call({"kind": HELD_CARD, "slot": card_slot, "item_id": int(bag_item(card_slot)[0]),
			"qty": 1, "keep_on_hide": true}, icon.texture, icon, at)):
		accept_event()

## Whether a click at `at` goes to a control here rather than to the held
## icon (0x6523d0: a CIFButton or a CIFSelectableArea -- PLAY, the X, the
## spinner's arrows, the page tabs).
func passes_at(at: Vector2) -> bool:
	if not is_visible_in_tree() or not get_global_rect().has_point(at):
		return false
	return _button_under(self, at)

func _button_under(n: Node, at: Vector2) -> bool:
	for child in n.get_children():
		if child is CanvasItem and not (child as CanvasItem).visible:
			continue
		if child is BaseButton and (child as Control).get_global_rect().has_point(at) and not (child as BaseButton).disabled:
			return true
		if _button_under(child, at):
			return true
	return false

## CIFGhaCha::vslot_028 (c:0x749a30): the held icon put down at `at`. True
## when the window took it (it is over the window; the original's answer is
## always yes).
func accept_drop(what: Dictionary, at: Vector2) -> bool:
	if not is_visible_in_tree() or not get_global_rect().has_point(at):
		return false
	var kind := String(what.get("kind", ""))
	var target := _drop_target(at)
	print("GACHA: put down %s (slot %d) on %s" % [kind, int(what.get("slot", -1)), target])
	if busy or state() != 1:
		return true
	# c:0x7478c0: a cell of the first 32 only onto the card slot; nothing
	# while the prize list is empty.
	if kind == HELD_CELL and int(what.get("slot", -1)) < PAGE_SLOTS and target != "card":
		print("GACHA: a page-1 cell must go on the card slot (c:0x7478c0)")
		return true
	if prizes.is_empty():
		return true
	if kind != HELD_CELL and kind != HELD_CARD:
		# Not this window's slot (kind 0x8c): the status line only.
		refresh()
		return true
	var index := CARD_INDEX if kind == HELD_CARD else int(what.get("slot", -1))
	if index >= 0 and index < bag_size():
		var ref := int(bag_item(index)[0])
		if ref < 0:
			return true
		if is_card(ref):
			card_slot = index
			print("GACHA: card registered from bag slot %d" % index)
	elif index == CARD_INDEX:
		card_slot = -1
		print("GACHA: the card slot emptied")
	refresh()
	return true

func _drop_target(at: Vector2) -> String:
	var card := node("GDR_GHACHA_CARD_SLOT") as Control
	if card != null and card.get_global_rect().has_point(at):
		return "card"
	for i in _bag_cells.size():
		var c: Control = _bag_cells[i]
		if c.visible and c.get_global_rect().has_point(at):
			return "cell %d" % i
	for i in PRIZE_SLOTS:
		var s: Control = _prize_nodes[i]
		if s != null and s.get_global_rect().has_point(at):
			return "prize %d" % i
	return "window"

## The pane's first shown cell holding a Magic POP card that is not in the
## card slot (QA), or null.
func card_cell() -> Control:
	for i in _bag_cells.size():
		var c: Control = _bag_cells[i]
		if c.visible and i != card_slot and is_card(int(bag_item(i)[0])):
			return c.get_node_or_null("ItemIcon") as Control
	return null

# --- PLAY and the effects ------------------------------------------------------

## PLAY (c:0x7459b0).
func play() -> void:
	if busy or card_slot < 0:
		return
	if chosen < 0 or chosen >= prizes.size():
		return
	if not is_card(int(bag_item(card_slot)[0])):
		card_slot = -1
		_draw_card_slot()
		return
	busy = true
	close_hides = false
	if _deco != null:
		_deco.visible = true
	_roll_timer.start()
	UiSounds.play(SND_MOVE, "Magic POP: PLAY (c:0x745a61)")
	_send_timer.start()
	_effect_timer.start()
	UiSounds.play(SND_TURN, "Magic POP: PLAY (c:0x745a8c)")
	print("GACHA: PLAY -- rolling for %d ms" % SEND_MS)

## Timer 1 (c:0x746cd5).
func _on_roll_tick() -> void:
	if _roll_frame > ROLL_LAST:
		_roll_frame = 0
	_show_roll(ROLL_FRAME % _roll_frame)
	_roll_frame += 2

func _show_roll(path: String) -> void:
	for n in ["GDR_GHACHA_STA_ROLLING_L", "GDR_GHACHA_STA_ROLLING_R"]:
		var s := node(n) as Control
		if s == null or _builder == null:
			continue
		var tex := s.get_node_or_null("GachaRoll") as TextureRect
		if tex == null:
			tex = TextureRect.new()
			tex.name = "GachaRoll"
			tex.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
			s.add_child(tex)
		tex.texture = _builder.load_texture(path)

## Timer 2 (c:0x746dd2).
func _on_send_due() -> void:
	_roll_timer.stop()
	_show_roll(ROLL_ORIGINAL)
	if chosen < 0 or card_slot < 0:
		busy = false
		return
	var p: GachaTables.Prize = prizes[chosen]
	print("GACHA: send 0x7118 npc %d gacha id %d card slot %d" % [npc_uid, p.gacha_id, card_slot])
	play_requested.emit(npc_uid, p.gacha_id, card_slot)

## Timer 3 (c:0x746f21).
func _on_effect_tick() -> void:
	var path := EFFECT_FRAME % _effect_counter
	var t := _effect_tick
	if (t - 7 >= 0 and t - 7 < 9) or (t - 23 >= 0 and t - 23 < 13):
		_effect_counter -= 1
	_set_effect(path)
	if t < EFFECT_TICKS:
		_effect_counter += 1
	else:
		_effect_timer.stop()
		_effect_counter = 1
		_effect_tick = 0
		_set_effect(EFFECT_FIRST)
		if _deco != null:
			_deco.visible = false
		if _won:
			_deco_start(DECO_WIN, DECO_WIN_CELL, DECO_WIN_FRAMES, 1)
			if _deco != null:
				_deco.visible = true
			_win_timer.start()
			return
	_effect_tick += 1
	_deco_step()

## Timer 4 (c:0x74710c): the win sheet to frame 14, then hidden.
func _on_win_tick() -> void:
	if _deco_frame == DECO_WIN_LAST:
		_win_timer.stop()
		if _deco != null:
			_deco.visible = false
		_deco_start(DECO_PREPARE, DECO_PREPARE_CELL, DECO_PREPARE_FRAMES, 0)
		return
	_deco_step()

## The effect static's paths, newest last (tests and QA; capped).
var effect_log := PackedStringArray()

func _set_effect(path: String) -> void:
	effect_log.append(path)
	if effect_log.size() > 128:
		effect_log.remove_at(0)
	var s := node("GDR_GHACHA_STA_EFFACT") as Control
	if s == null or _builder == null:
		return
	var tex := _builder.load_texture(path)
	if tex == null:
		return
	if s is TextureRect:
		(s as TextureRect).texture = tex
	else:
		var t := s.get_node_or_null("GachaEffect") as TextureRect
		if t == null:
			t = TextureRect.new()
			t.name = "GachaEffect"
			t.mouse_filter = Control.MOUSE_FILTER_IGNORE
			s.add_child(t)
		t.texture = tex

## The effect static's texture path now (tests).
func effect_texture() -> Texture2D:
	var s := node("GDR_GHACHA_STA_EFFACT") as Control
	if s is TextureRect:
		return (s as TextureRect).texture
	var t := s.get_node_or_null("GachaEffect") as TextureRect if s != null else null
	return t.texture if t != null else null

func _build_deco() -> void:
	var holder := node("GDR_GHACHA_DECO") as Control
	if holder == null:
		return
	_deco = TextureRect.new()
	_deco.name = "GachaDeco"
	_deco.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_deco.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_deco.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# +0x388 = 1: drawn additively (CIFDecoratedStatic's draw, round 768).
	var m := CanvasItemMaterial.new()
	m.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	_deco.material = m
	_deco.visible = false
	holder.add_child(_deco)

func _deco_reset() -> void:
	_deco_start(DECO_PREPARE, DECO_PREPARE_CELL, DECO_PREPARE_FRAMES, 0)
	if _deco != null:
		_deco.visible = false

func _deco_start(sheet: String, cell: Vector2, frames: int, frame: int) -> void:
	_deco_sheet = sheet
	_deco_cell = cell
	_deco_frames = frames
	_deco_frame = frame
	_deco_draw()

## 0x634300: the next frame, wrapping at the sheet's count.
func _deco_step() -> void:
	_deco_frame += 1
	if _deco_frame >= _deco_frames:
		_deco_frame = 0
	_deco_draw()

func _deco_draw() -> void:
	if _deco == null or _builder == null:
		return
	var tex := _builder.load_texture(_deco_sheet)
	if tex == null:
		_deco.texture = null
		return
	_deco_atlas.atlas = tex
	var per_row := maxi(1, int(tex.get_width() / _deco_cell.x))
	_deco_atlas.region = Rect2(Vector2(_deco_frame % per_row, _deco_frame / per_row) * _deco_cell, _deco_cell)
	if _deco.texture != _deco_atlas:
		_deco.texture = _deco_atlas

## The DECO's sheet, frame and visibility (tests and QA).
func deco_state() -> Dictionary:
	return {"sheet": _deco_sheet, "frame": _deco_frame, "visible": _deco != null and _deco.visible}

# --- The answers ---------------------------------------------------------------

## 0xB118 (c:0x88d690 -> c:0x748270).
func on_result(result: Dictionary) -> void:
	if not bool(result.get("ok", false)):
		busy = false
		close_hides = true
		print("GACHA: refused, code 0x%x" % int(result.get("code", 0)))
		refresh()
		return
	_won = bool(result.get("win", false))
	busy = false
	close_hides = true
	_await_coupon = card_slot >= 0
	print("GACHA: result %s" % ("WIN" if _won else "LOSE"))
	_say(MSG_WIN if _won else MSG_LOSE)
	UiSounds.play(SND_WIN if _won else SND_END, "Magic POP: the result (c:0x748432 / c:0x74847b)")
	if _play != null:
		_play.disabled = true

## The bag changed (a list arrived): each slot whose item changed is
## mirrored again (c:0x6b7770 -> c:0x749030), and the card slot follows its
## bag slot. The status line keeps the result until the next redraw of it.
func on_bag_changed() -> void:
	if not visible:
		return
	if bag_pages() != _pages:
		_build_pane(bag_pages())
		select_bag_page(mini(bag_page, _pages - 1))
	var now := _bag_map()
	var changed: Array = []
	for k in now.keys() + _snapshot.keys():
		if not changed.has(k) and now.get(k, [-1, 0]) != _snapshot.get(k, [-1, 0]):
			changed.append(k)
	var was_card := int(_snapshot.get(card_slot, [-1, 0])[0])
	_snapshot = now
	var keep := status_text()
	if card_slot >= 0 and changed.has(card_slot):
		var ref := int(now.get(card_slot, [-1, 0])[0])
		if ref < 0 or not is_coupon(ref):
			print("GACHA: the card slot emptied (its bag slot %d changed)" % card_slot)
			card_slot = -1
			_mirror_cells()
			_draw_card_slot()
			_say(status_pair())
			if _play != null:
				_play.disabled = not can_play()
			return
		if _await_coupon and is_card(was_card):
			# 0x3040 mask 1 (a new RefItemID) on the card's bag slot: the
			# cell's flash (c:0x747890 -> 0x6665f0).
			_flash_cell(card_slot)
	_await_coupon = false
	_mirror_cells()
	_draw_card_slot()
	if keep != "":
		_say_text(keep)

func _flash_cell(slot: int) -> void:
	var cell := cell_of(slot)
	var icon := cell.get_node_or_null("ItemIcon") as Control if cell != null else null
	if icon == null:
		return
	if _switch_sheet == null and _builder != null:
		_switch_sheet = _builder.load_texture(RepairFlash.SWITCH_DDJ)
	RepairFlash.play_switch_on(icon, _switch_sheet)
	print("GACHA: cell %d flashes (the card became its coupon)" % slot)
	coupon_flashed.emit(slot)

## One line of the window's state (the QA report).
func qa_state() -> String:
	var shown: Array = []
	for i in _bag_cells.size():
		var c: Control = _bag_cells[i]
		if c.visible and int(bag_item(i)[0]) >= 0:
			shown.append("%d:%d" % [i, int(bag_item(i)[0])])
	return "page=%d/%d state=%d busy=%s chosen=%d card_slot=%d card_item=%d status='%s' play=%s deco=%s shown=[%s]" % [
		bag_page + 1, _pages, state(), busy, chosen, card_slot, int(bag_item(card_slot)[0]) if card_slot >= 0 else -1,
		status_text(), "on" if _play != null and not _play.disabled else "off", str(deco_state()), ",".join(shown)]

# --- Closing -------------------------------------------------------------------

## vslot_043 (c:0x7481f0): refused while busy; else c:0x79c060(0).
func _on_close_pressed() -> void:
	close_window()

func close_window() -> bool:
	if busy or not visible:
		return false
	UiSounds.play(UiSounds.KEY_WINDOW_CLOSE, "Magic POP closed (c:0x79c11f)")
	hide()
	closed.emit()
	return true

func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if visible and key != null and key.pressed and not key.echo and key.keycode == KEY_ESCAPE:
		close_window()
		get_viewport().set_input_as_handled()
