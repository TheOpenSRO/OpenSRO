extends HudWindow
class_name SummonPartyWindow

## Round 869 (lane C1): the party recall NPC's window, CNIFSummonPartyUserWnd
## (window 0xd6), built from the client's own `res_ui\nifsummonpartyuserwnd.2dt`
## the way its classes assemble it. Every address is sro_client.exe's; labels
## READ / MEASURED / INFERRED / OURS / OPEN.
##
## **The file** (MEASURED, Media.pk2, 49,780 bytes = 4 + 51 x 976): record 0
## the window (CNIFSummonPartyUserWnd, CNIFMainFrame 496 x 320 on
## `mframe_wnd_`, caption UIIT_PAG_PARTY_SUMMON, authored at (362, 176)); the
## Summon button 7 (`com_mid_button03.ddj`, 96 x 28, UIIT_CTL_PARTY_SUMMON);
## four column headers 9..12 (UIIT_STT_PARTY_SUMMON_MEMBER_NAME,
## UIIT_STT_PARTY_SUMMON_ENTRANCE, PARAM_LV, UIIT_STT_PARTY_SUMMON_LIMIT_TIME);
## eight rows, CNIFSummonPartyUserSlot (ids 13, 18, 23, 28, 33, 38, 43, 48,
## 451 x 24 on `com_bar01_left.ddj`, a 23-pixel pitch), each with the statics
## 14 (name), 15 (state), 16 (level) and 17 (minutes).
##
## **Loaded** at game start under the interface (READ c:0x787119..0x787154:
## if window 0xd6 is not loaded, `res_ui\nifsummonpartyuserwnd.2dt` -- string
## 0xdb90bc -- then ShowWindow(0)). Its OnCreate (map entry 0x8065 ->
## c:0x607660) only disables button 7; nothing centres or moves it, so it
## stays at its authored rect (INFERRED from the loader's placement of record
## 0, TwoDtBuilder's header). Escape hides it (c:0x607780, key 0x1b).
## ShowWindow(1) (vslot_023, c:0x6077a0) disables button 7 again.
##
## **The rows** (READ): a row's OnCreate (c:0x60a100) keeps 14..17 at
## +0x4e4..+0x4f0 and registers itself at the FRONT of the window's list
## (c:0x609ff0 -> c:0x608570 before the first node); the OnCreates run last
## record first, so the vector +0x7a4 ends in file order -- row 0 is id 13 at
## the top (as QuestWindow's rows, round 595). 0xB519 clears the entry list
## (c:0x609d40), appends each entry (c:0x609d60 push_back) and refreshes
## (c:0x609ac0): row i shows entry i through c:0x608780 --
##   name (14) = the party member's name for the char id
##     (CharacterDependentData::FUN_009921e0; here PartyState.member(jid));
##   state 1 -> 15 = UIIT_STT_FORT_SMITH_COMPLETE in 0xff80da11,
##   state 2 -> UIIT_CTL_PARTY_SUMMON_POSSILBE in 0xff02da11,
##   state 3 -> UIIT_CTL_PARTY_SUMMON_IMPOSSILBE in 0xffd40000 with the
##     tooltip UIIT_STT_PARTY_SUMMON_IMPOSSILBE (c:0x608954..0x608979; which
##     control takes the tooltip is INFERRED: the state text);
##   any other state -> the row keeps only its name (c:0x6088fe jumps past);
##   16 = "%d" of the u8 (0xe18b1c is "%d"), 17 = "%d %s" with the u16 and
##     UIIT_STT_MINUTE;
## and a row past the list has all four texts emptied.
## Then every row's art goes back to `com_bar01_Left.ddj` (c:0x6096e0(0)).
##
## **Selecting and summoning** (READ): a left button-down (0x201) on a row
## that holds an entry selects it (CNIFSummonPartyUserSlot::vslot_017,
## c:0x609a80 -> c:0x6096e0): every row to `com_bar01_Left.ddj`, the row to
## `com_bar01select_Left.ddj`, the selection +0x7c0 = the row, and button 7
## enabled only when the row is not waiting (+0x4f8 == 0) and its state is 2
## (c:0x607630, c:0x607730). Button 7 (map entry -> c:0x607c80) on the
## selected row: the row waits -- timer 100 for 20,000 ms, +0x4f8 = 1, button
## 7 disabled (c:0x607c20) -- and 0x751A {the entry's char id} goes
## (c:0x823350). When the row's timer fires (vslot_005, c:0x607c50): +0x4f8 =
## 0 and button 7 is re-evaluated for the SELECTED row (c:0x607730(1): enabled
## when that row's state is 2, whatever its own wait). A refill keeps +0x7c0
## (c:0x6096e0(0) does not clear it).

const TwoDtBuilder = preload("res://scripts/ui/twodt_builder.gd")

const FILE := "res_ui\\nifsummonpartyuserwnd.2dt"
const CAPTION := "UIIT_PAG_PARTY_SUMMON"
const ID_SUMMON := 7
const ROW_IDS := [13, 18, 23, 28, 33, 38, 43, 48]
const ID_NAME := 14
const ID_STATE := 15
const ID_LEVEL := 16
const ID_MINUTES := 17
const ROW_ART := "interface\\ifcommon\\com_bar01_"
const ROW_SELECT_ART := "interface\\ifcommon\\com_bar01select_"
## The row's wait after a summon (READ c:0x607c20: FUN_00b93320(100, 20000)).
const SUMMON_WAIT_MS := 20000
const STATE_KEYS := {1: ["UIIT_STT_FORT_SMITH_COMPLETE", 0xff80da11],
	2: ["UIIT_CTL_PARTY_SUMMON_POSSILBE", 0xff02da11], 3: ["UIIT_CTL_PARTY_SUMMON_IMPOSSILBE", 0xffd40000]}
const IMPOSSIBLE_TIP := "UIIT_STT_PARTY_SUMMON_IMPOSSILBE"

## Button 7: summon this member (0x751A).
signal summon_requested(char_id: int)

var _twodt: TwoDtBuilder
var root: Control
## The rows (bar nodes), in file order.
var rows: Array[Control] = []
## The entries (InstanceTalkNet.Entry), in message order.
var entries: Array = []
## The selected row (+0x7c0), -1 none.
var selected := -1
## Each row's wait end in ms (Time.get_ticks_msec scale), 0 when not waiting.
var _wait_until: Array[int] = []
## Resolves a char id to its name (OURS hook: World3D binds the party store).
var name_of: Callable
## The clock (OURS: a test sets it).
var now_ms: Callable = func() -> int: return Time.get_ticks_msec()

func build_window(builder: UiBuilder) -> bool:
	_builder = builder
	if builder == null:
		return false
	var file := builder.load_2dt(FILE)
	if file == null or file.records.is_empty():
		return false
	_twodt = TwoDtBuilder.new(builder)
	root = _twodt.build(file, FILE)
	panel_root = root
	var sz := Vector2(file.root().rect.size)
	custom_minimum_size = sz
	size = sz
	position = Vector2(file.root().rect.position)
	mouse_filter = Control.MOUSE_FILTER_STOP
	name = "SummonPartyWindow"
	add_child(root)
	# Record 0's text is the MainFrame's caption (0x479e10), as QuestWindow.
	var root_text := root.get_node_or_null(TwoDtBuilder.TEXT_NODE)
	if root_text != null:
		root.remove_child(root_text)
		root_text.free()
	_add_title_bar(builder.resolve_text(CAPTION))
	rows.clear()
	_wait_until.clear()
	for id in ROW_IDS:
		var row := TwoDtBuilder.child(root, id)
		if row == null:
			continue
		var select_art := Control.new()
		select_art.name = "SelectArt"
		select_art.mouse_filter = Control.MOUSE_FILTER_IGNORE
		select_art.visible = false
		builder._add_row_bar_from(select_art, ROW_SELECT_ART, row.size)
		row.add_child(select_art)
		row.move_child(select_art, 0)
		row.gui_input.connect(_on_row_input.bind(rows.size()))
		rows.append(row)
		_wait_until.append(0)
	var btn := summon_button()
	if btn != null:
		btn.pressed.connect(_on_summon_pressed)
		btn.disabled = true
	visible = false
	_settle()
	refresh()
	return true

func summon_button() -> BaseButton:
	return TwoDtBuilder.child(root, ID_SUMMON) as BaseButton if root != null else null

## The row's statics.
func row_text(row: int, id: int) -> Control:
	if row < 0 or row >= rows.size():
		return null
	return TwoDtBuilder.child(rows[row], id)

## 0xB519's success: the list replaced, refreshed, the window shown
## (c:0x89a5c7..0x89a674: vslot 0x5c(1), vslot 0x50, then the rows).
func fill(new_entries: Array) -> void:
	entries = new_entries.duplicate()
	refresh()
	show_window()

## 0xB519's refusal clears the list too (c:0x89a5b7 runs before the result
## test), without showing the window.
func clear_entries() -> void:
	entries = []
	refresh()

func show_window() -> void:
	show()
	move_to_front()
	# vslot_023 (c:0x6077a0): ShowWindow(1) disables button 7.
	var btn := summon_button()
	if btn != null:
		btn.disabled = true

## c:0x609ac0: each row from its entry, then every row unselected in art.
func refresh() -> void:
	for i in rows.size():
		_fill_row(i, entries[i] if i < entries.size() else null)
	for i in rows.size():
		_set_row_art(i, false)

func _fill_row(i: int, e) -> void:
	var name_c := row_text(i, ID_NAME)
	var state_c := row_text(i, ID_STATE)
	var level_c := row_text(i, ID_LEVEL)
	var min_c := row_text(i, ID_MINUTES)
	if state_c != null:
		state_c.tooltip_text = ""
	if e == null:
		for c in [name_c, state_c, level_c, min_c]:
			if c != null:
				_twodt.set_text(c, "")
		return
	var entry: InstanceTalkNet.Entry = e
	if name_c != null:
		_twodt.set_text(name_c, String(name_of.call(entry.char_id)) if name_of.is_valid() else str(entry.char_id))
	if not STATE_KEYS.has(entry.state):
		return
	var spec: Array = STATE_KEYS[entry.state]
	if state_c != null:
		var lbl := _twodt.set_text(state_c, _builder.resolve_text(String(spec[0])))
		if lbl != null:
			lbl.add_theme_color_override("font_color", TwoDtBuilder.argb(int(spec[1])))
		if entry.state == InstanceTalkNet.STATE_IMPOSSIBLE:
			state_c.tooltip_text = _builder.resolve_text(IMPOSSIBLE_TIP)
			state_c.mouse_filter = Control.MOUSE_FILTER_PASS
	if level_c != null:
		_twodt.set_text(level_c, "%d" % entry.level)
	if min_c != null:
		_twodt.set_text(min_c, "%d %s" % [entry.minutes, _builder.resolve_text("UIIT_STT_MINUTE")])

func _set_row_art(i: int, on: bool) -> void:
	var row := rows[i]
	for c in row.get_children():
		if c.name == "SelectArt":
			(c as CanvasItem).visible = on
		elif c.name.begins_with("RowBar") and c is CanvasItem:
			(c as CanvasItem).visible = not on

func _on_row_input(event: InputEvent, i: int) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
		select_row(i)
		accept_event()

## A press on row `i` (vslot_017): only a row that holds an entry.
func select_row(i: int) -> void:
	if i < 0 or i >= rows.size() or i >= entries.size():
		return
	for k in rows.size():
		_set_row_art(k, false)
	selected = i
	_set_row_art(i, true)
	_set_button(not waiting(i) and _selected_state() == InstanceTalkNet.STATE_POSSIBLE)

func _selected_state() -> int:
	if selected < 0 or selected >= entries.size():
		return 0
	return (entries[selected] as InstanceTalkNet.Entry).state

func _set_button(on: bool) -> void:
	var btn := summon_button()
	if btn != null:
		btn.disabled = not on

## Whether row `i` waits after a summon (+0x4f8).
func waiting(i: int) -> bool:
	return i >= 0 and i < _wait_until.size() and _wait_until[i] != 0

## Button 7 (c:0x607c80).
func _on_summon_pressed() -> void:
	if selected < 0 or selected >= entries.size():
		return
	_wait_until[selected] = int(now_ms.call()) + SUMMON_WAIT_MS
	_set_button(false)
	var id := (entries[selected] as InstanceTalkNet.Entry).char_id
	print("SUMMON window: 0x751A for row %d (char %d), the row waits %d ms" % [selected, id, SUMMON_WAIT_MS])
	summon_requested.emit(id)

## The rows' timers (vslot_005 on timer 100).
func tick() -> void:
	var t := int(now_ms.call())
	for i in _wait_until.size():
		if _wait_until[i] != 0 and t >= _wait_until[i]:
			_wait_until[i] = 0
			print("SUMMON window: row %d's wait is over" % i)
			_set_button(_selected_state() == InstanceTalkNet.STATE_POSSIBLE)

func _process(_dt: float) -> void:
	tick()

func _input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if visible and k != null and k.pressed and k.keycode == KEY_ESCAPE:
		hide()

## The rows as text, for the QA log and the tests.
func report() -> Array:
	var out: Array = []
	for i in rows.size():
		out.append([TwoDtBuilder.text_of(row_text(i, ID_NAME)), TwoDtBuilder.text_of(row_text(i, ID_STATE)),
			TwoDtBuilder.text_of(row_text(i, ID_LEVEL)), TwoDtBuilder.text_of(row_text(i, ID_MINUTES))])
	return out

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
