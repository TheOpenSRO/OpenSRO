extends HudWindow
class_name SilkHistoryWindow

## Round 837: the item mall's Buying list, `CNIFSilkBuyList` -- a
## `HISTORY_FOR_BUYING_SILK` window built from `res_ui\silksearch.2dt`
## (docs/protocol/item_mall.md §4g and its correction W7; item_mall_wire.md
## §5). Every address is sro_client.exe's (md5 2a5794b7...); labels READ
## (seen in code), MEASURED (the archive's file), INFERRED, OURS.
##
## **The file (MEASURED, 65 records).** Root 38 (CNIFSilkBuyList, 462 x 527,
## frame `interface\frame\mall_ms_wnd_`, caption UIIT_STT_SILKMALL_BUY_LIST);
## tab 17 "Inquire" (mall_sub_tab_); 9/10 "Set Inquiry Period" and its
## CNIFComboBox (102 x 20); button 12 (mall_button.ddj,
## UIIT_CTL_SILK_INQUIRY_INQUIRY); the CIFPMLEx 400 under the tab; the status
## static 194 (395 x 20, centred); the column heads 70 / 68 / 69 (Number /
## the silk column / Date); **11** CNIFSilkRecieveListSlot bars (28, 108 ..
## 144: com_bar01_, 402 x 24, y 367..597 step 23), each with the statics 25
## (No.), 26 (amount) and 27 (date); the scroll bar 67 (16 x 230); "Total:"
## (29) and the total 401.
##
## **OnCreate (READ, 0x7ecef0; the message map's 0x8065 entry at 0xec0dd8):**
## +0x7a0 = child 194 (the status line); +0x79c = 400, whose text object
## (+0x348) gets UIIT_STT_SILK_INQUIRY_MONTH_SILK; +0x7b4 = 67 (the scroll);
## +0x7b0 = 10 (the combo); +0x7a4 = 401, set to "%d%s" (total,
## UIIT_STT_ROLL_OF_CLOTH); tab 17 checked; the combo gets ONEDAY, WEEK,
## MONTH, THREE_MONTH in that order (0x7ed00a..0x7ed0a5), current 0
## (0x4872b0(0)); then the reset 0x7ecad0.
## **The message map (READ, .data 0xec0dd8, filled at 0xd73280):** button 12
## -> Inquiry 0x7ecb90; scroll 67 -> 0x7ecb20 (redraw); the wheel is
## vslot_036 0x7ecb40 (one line up or down, then the redraw 0x7ec630).
##
## **The mall side (READ):** the mall loads the file hidden with itself
## (0x7d6eb0(1)); its Buying list button (131) runs 0x7d7130: refused while a
## mall box is up (+0x7c8) or purchases are outstanding (+0x7dc); else any
## open list is closed (0x7d6ff0), this one shown, brought forward, centred on
## the screen (0x798be0: (screen w - w) / 2, (screen h - h) / 2), reset
## (0x7ecad0), and the mall marks itself busy (+0x7c4 = this, +0x7c8 = 1):
## **while it is open the mall is modal** (is_open, the opened / closed
## signals). The X is vslot_043 0x7e9b80 -> the mall's 0x7d6ff0: busy
## cleared, the window hidden. **Closing the list sends nothing**; the mall's
## own close (0x7d7020) sends 0x711a {1, 0xff} when this list's pending flag
## (+0x7bc) is set: mall_closing().
##
## **Inquiry (READ, 0x7ecb90):** the rows cleared (0x7eae50), the slots
## emptied, the total 0 and the status line "" (0x7ebb70), the scroll range
## (0x7ea240) and the redraw (0x7ec630); then, for a combo index 0..3,
## pending = 1, the status line UIIT_MSG_SILK_INQUIRY_WAIT ("Inquiry is in
## process. Please wait.") and 0x711a {1, index + 1}.
##
## **0xB11A (READ, 0x8990c0):** kind, period, result; a non-zero result
## returns at once (nothing changes, the pending flag stays). Kind 1 is this
## list (window 0x26, 0x7d6e30); any other kind the Obtained list (0x53), which
## retail never loads (button 132 disabled, 0x7d6f26..0x7d6f3c), so it is
## dropped here. The rows are cleared, then each {u32 amount, u32 date} is
## stored as row i with No. i + 1 (0x7ec5b0: the status line "", the total
## zeroed at i = 0, the amount added); n = 0 shows
## UIIT_MSG_SILK_INQUIRY_NOT_INQUIRY ("No history is available.") and clears
## pending (0x7ea6c0); then the scroll range and the redraw, which clears
## pending too.
##
## **A row (READ, 0x7ea310):** No. "%03d", the amount "%d", the date
## "%4d/%02d/%02d %02d:%02d" from a **packed u32**: year = (d & 0x3f) + 2000,
## month = d >> 6 & 0xf, day = d >> 10 & 0x1f, hour = d >> 15 & 0x1f,
## minute = d >> 20 & 0x3f (0x7ea31c..0x7ea350). Bits 26..31 are not read
## (INFERRED: seconds). The redraw (0x7ec630) fills slot i from row
## scroll + i while that row exists; the scroll range is rows - 11
## (0x7ea240, 0x478ab0(0, n - slots, 1)).

const SILK_2DT := "res_ui\\silksearch.2dt"
const ID_TAB := 17
const ID_COMBO := 10
const ID_INQUIRY := 12
const ID_SCROLL := 67
const ID_STATUS := 194
const ID_NOTE := 400
const ID_TOTAL := 401
const SLOT_CLASS := "CNIFSilkRecieveListSlot"
const SLOT_NO := 25
const SLOT_AMOUNT := 26
const SLOT_DATE := 27

## 0x711a's kind for this list (READ 0x7ecb90) and the cancel (0x7eabe0).
const KIND_BUY := 1
const PERIOD_CANCEL := 0xff

## The combo's entries in order (READ 0x7ed00a..0x7ed0a5); the period sent is
## the index + 1 (READ 0x7ecc3f). The English is the archive's own text.
const PERIOD_KEYS := ["UIIT_CTL_SILK_INQUIRY_ONEDAY", "UIIT_CTL_SILK_INQUIRY_WEEK",
	"UIIT_CTL_SILK_INQUIRY_MONTH", "UIIT_CTL_SILK_INQUIRY_THREE_MONTH"]
const PERIOD_FALLBACK := ["1 day", "7 days", "1 month", "3 months"]
const WAIT_KEY := "UIIT_MSG_SILK_INQUIRY_WAIT"
const WAIT_FALLBACK := "Inquiry is in process. Please wait."
const EMPTY_KEY := "UIIT_MSG_SILK_INQUIRY_NOT_INQUIRY"
const EMPTY_FALLBACK := "No history is available."
const UNIT_KEY := "UIIT_STT_ROLL_OF_CLOTH"
const UNIT_FALLBACK := "Silk"
const NOTE_KEY := "UIIT_STT_SILK_INQUIRY_MONTH_SILK"

## Emitted when the window is shown (the mall goes busy, +0x7c8 = 1).
signal opened

## NetClient, or a stand-in a test gives: mall_history_request(kind, period)
## and the mall_history(result) signal.
var net = null
## +0x7bc: an inquiry is out and not answered.
var pending := false
## +0x7c0: the sum of the rows' amounts.
var total := 0
## The rows as 0xB11A gave them: [no, amount, date].
var rows: Array = []

var _twodt: TwoDtBuilder
var _file: TwoDtReader.TwoDtFile
var _slots: Array[Control] = []
var _scroll: VScroll2dt
var _combo: OptionButton
var _built := false

func _init(builder: UiBuilder = null) -> void:
	super._init()
	_builder = builder
	visible = false

func _net():
	if net != null:
		return net
	var tree := Engine.get_main_loop() as SceneTree
	return tree.root.get_node_or_null("/root/NetClient") if tree != null else null

# --- opening and closing -----------------------------------------------------------

## The mall's Buying list button (0x7d7130): builds the window on first use
## (under `parent`, HudPanels), shows it centred and in front, and resets it.
## False when the archive has no silksearch.2dt.
func open(parent: Node) -> bool:
	if not _built:
		if _builder == null and parent != null:
			_builder = parent.get("_builder") as UiBuilder
		if not build_window():
			return false
	if parent != null and get_parent() != parent:
		if get_parent() != null:
			get_parent().remove_child(self)
		parent.add_child(self)
	_bind_net()
	show()
	place_centred()
	move_to_front()
	reset()
	opened.emit()
	return true

## The X (vslot_043 0x7e9b80 -> 0x7d6ff0): hidden, the mall no longer busy.
## Nothing is sent, even with an inquiry out (see the header).
func close() -> void:
	if not visible:
		return
	hide()
	closed.emit()

func _on_close_pressed() -> void:
	close()

## Whether the list is up: the mall's +0x7c8 / +0x7c4 (the mall is modal).
func is_open() -> bool:
	return _built and visible

## The mall's own close (CIFNewItemMall::vslot_043 0x7d7020): 0x711a
## {1, 0xff} when an inquiry is pending (0x7eabe0), then the list goes with
## the mall. Returns whether the cancel was sent.
func mall_closing() -> bool:
	var sent := false
	if pending:
		var n = _net()
		if n != null and n.has_method("mall_history_request"):
			n.mall_history_request(KIND_BUY, PERIOD_CANCEL)
			sent = true
		pending = false
	close()
	return sent

# --- building ----------------------------------------------------------------------

## Builds the file as 0x7d6eb0(1) loads it and runs OnCreate (0x7ecef0).
func build_window() -> bool:
	if _builder == null:
		return false
	_file = _builder.load_2dt(SILK_2DT)
	if _file == null or _file.records.is_empty():
		return false
	_twodt = TwoDtBuilder.new(_builder)
	panel_root = _twodt.build(_file, SILK_2DT)
	var window_size := Vector2(_file.root().rect.size)
	custom_minimum_size = window_size
	size = window_size
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(panel_root)
	# The caption is the chrome's (CNIFMainFrame), as OptionWindow does for
	# the other .2dt windows; the root's own text would draw it twice.
	var root_text := panel_root.get_node_or_null(TwoDtBuilder.TEXT_NODE)
	if root_text != null:
		panel_root.remove_child(root_text)
		root_text.queue_free()
	_add_title_bar(_text(_file.root().text_id, "Buying list"))
	var bar := get_node_or_null("TitleBar") as Label
	if bar != null:
		bar.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	# 400 (CIFPMLEx): its text object gets UIIT_STT_SILK_INQUIRY_MONTH_SILK
	# (READ 0x7ecf16..0x7ecf52), an sml2 text (MEASURED: "<sml2>You can check
	# your Silk charge history for the most recent 3 months.</sml2>"). Drawn
	# as the party-match boxes draw a PML record (PartyMatchBox.fill_pml:
	# centred; CIFPMLEx's own draw is not read, INFERRED).
	var note := _at([ID_NOTE])
	if note != null:
		var rt := RichTextLabel.new()
		rt.name = "PmlText"
		rt.bbcode_enabled = true
		rt.scroll_active = false
		rt.fit_content = false
		rt.autowrap_mode = TextServer.AUTOWRAP_OFF
		rt.mouse_filter = Control.MOUSE_FILTER_IGNORE
		rt.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		var font := _builder.font_at(0)
		if font != null:
			rt.add_theme_font_override("normal_font", font)
		rt.add_theme_font_size_override("normal_font_size", UiBuilder.FONT_SIZES[0])
		UiBuilder.crisp_text(rt)
		rt.text = "[center]%s[/center]" % PartyMatchBox.sml2_to_bbcode(_text(NOTE_KEY, ""))
		note.add_child(rt)
	_slots.clear()
	for c in panel_root.get_children():
		if c is Control and str(c.get_meta(TwoDtBuilder.META_CLASS, "")) == SLOT_CLASS:
			_slots.append(c as Control)
	var host := _at([ID_COMBO])
	if host != null:
		_combo = OptionVideoPage.new(null, _builder, null)._make_combo(host)
		if _combo != null:
			for i in PERIOD_KEYS.size():
				_combo.add_item(_text(PERIOD_KEYS[i], PERIOD_FALLBACK[i]))
			_combo.select(0)
	var inquiry := _at([ID_INQUIRY]) as BaseButton
	if inquiry != null:
		inquiry.pressed.connect(press_inquiry)
	_scroll = VScroll2dt.build_on(_at([ID_SCROLL]), _builder, panel_root)
	if _scroll != null:
		_scroll.changed.connect(func(_l: int) -> void: redraw())
	_settle()
	_built = true
	reset()
	return true

func _bind_net() -> void:
	var n = _net()
	if n == null or not n.has_signal("mall_history"):
		return
	if not n.is_connected("mall_history", on_history):
		n.connect("mall_history", on_history)

## The text of a table key, or `fallback` when the table has none.
func _text(key: String, fallback: String) -> String:
	var table := _builder.text_table() if _builder != null else null
	if key == "" or table == null or not table.has(key):
		return fallback if fallback != "" else key
	return table.get_text(key)

func _at(path: Array) -> Control:
	return TwoDtBuilder.find_path(panel_root, path) if panel_root != null else null

# --- behaviour ---------------------------------------------------------------------

## 0x7ecad0: tab 17 checked, pending cleared, the combo back to 1 day, the
## rows and the total cleared, the scroll range and the redraw.
func reset() -> void:
	TwoDtBuilder.set_tab_checked(_at([ID_TAB]), true)
	pending = false
	if _combo != null and _combo.item_count > 0:
		_combo.select(0)
	_clear()
	_set_range()
	redraw()

## 0x7eae50 + 0x7ebb70: no rows, empty slots, total 0, status "".
func _clear() -> void:
	rows.clear()
	total = 0
	for s in _slots:
		for id in [SLOT_NO, SLOT_AMOUNT, SLOT_DATE]:
			var cell := TwoDtBuilder.child(s, id)
			if cell != null:
				_twodt.set_text(cell, "")
	set_status("")

## Inquiry (button 12, 0x7ecb90).
func press_inquiry() -> void:
	_clear()
	_set_range()
	redraw()
	var index := _combo.selected if _combo != null else -1
	if index < 0 or index >= 4:
		return
	pending = true
	set_status(_text(WAIT_KEY, WAIT_FALLBACK))
	var n = _net()
	if n != null and n.has_method("mall_history_request"):
		n.mall_history_request(KIND_BUY, index + 1)

## The combo's current index (0 = 1 day .. 3 = 3 months).
func period_index() -> int:
	return _combo.selected if _combo != null else -1

func select_period(index: int) -> void:
	if _combo != null and index >= 0 and index < _combo.item_count:
		_combo.select(index)

## 0xB11A, as MallNet.decode_history gives it: {"kind", "result", "rows"}.
func on_history(result: Dictionary) -> void:
	if result.is_empty() or int(result.get("result", 1)) != 0:
		return
	if int(result.get("kind", 0)) != KIND_BUY:
		return
	if not _built:
		return
	rows.clear()
	var list: Array = result.get("rows", [])
	for i in list.size():
		var r: Array = list[i]
		# 0x7ec5b0: the status line "", the total zeroed at row 0.
		if i == 0:
			total = 0
			set_status("")
		var amount := _s32(int(r[0]))
		rows.append([i + 1, amount, int(r[1])])
		total += amount
	if list.is_empty():
		set_status(_text(EMPTY_KEY, EMPTY_FALLBACK))
		pending = false
	_set_range()
	redraw()

## 0x7ea240: lines 0 .. rows - slots.
func _set_range() -> void:
	if _scroll != null:
		_scroll.set_max_line(rows.size() - _slots.size())

## 0x7ec630: slot i shows row scroll + i; the total "%d%s"; pending cleared.
func redraw() -> void:
	var first := _scroll.line if _scroll != null else 0
	for i in _slots.size():
		var k := first + i
		var texts := ["", "", ""]
		if k < rows.size():
			var r: Array = rows[k]
			texts = [format_no(int(r[0])), str(int(r[1])), format_date(int(r[2]))]
		var ids := [SLOT_NO, SLOT_AMOUNT, SLOT_DATE]
		for j in 3:
			var cell := TwoDtBuilder.child(_slots[i], ids[j])
			if cell != null:
				_twodt.set_text(cell, texts[j])
	var total_node := _at([ID_TOTAL])
	if total_node != null:
		_twodt.set_text(total_node, "%d%s" % [total, _text(UNIT_KEY, UNIT_FALLBACK)])
	pending = false

func set_status(text: String) -> void:
	var node := _at([ID_STATUS])
	if node != null and _twodt != null:
		_twodt.set_text(node, text)

func status_text() -> String:
	return TwoDtBuilder.text_of(_at([ID_STATUS]))

## The CIFPMLEx line under the tab, as plain text.
func note_text() -> String:
	var rt := _at([ID_NOTE]).get_node_or_null("PmlText") as RichTextLabel if _at([ID_NOTE]) != null else null
	return rt.get_parsed_text() if rt != null else ""

func total_text() -> String:
	return TwoDtBuilder.text_of(_at([ID_TOTAL]))

## The CNIFSilkRecieveListSlot bars in file order.
func slots() -> Array[Control]:
	return _slots

## The three texts slot `i` shows.
func slot_texts(i: int) -> Array:
	if i < 0 or i >= _slots.size():
		return []
	return [TwoDtBuilder.text_of(TwoDtBuilder.child(_slots[i], SLOT_NO)),
		TwoDtBuilder.text_of(TwoDtBuilder.child(_slots[i], SLOT_AMOUNT)),
		TwoDtBuilder.text_of(TwoDtBuilder.child(_slots[i], SLOT_DATE))]

func scroll_line() -> int:
	return _scroll.line if _scroll != null else 0

func scroll_to(line: int) -> void:
	if _scroll != null:
		_scroll.scroll_to(line)

## A control by its GetChild path from the window's root.
func control(path: Array) -> Control:
	return _at(path)

## 0x798be0: centred on the screen.
func place_centred() -> void:
	var view := get_viewport_rect().size
	position = Vector2(maxi(0, (int(view.x) >> 1) - (int(size.x) >> 1)),
		maxi(0, (int(view.y) >> 1) - (int(size.y) >> 1)))

## CNIFMainFrame's chrome, as OptionWindow places it.
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

# --- formats (READ 0x7ea310) -------------------------------------------------------

static func format_no(no: int) -> String:
	return "%03d" % (no & 0xffff)

## The packed date (see the header) as "%4d/%02d/%02d %02d:%02d".
static func format_date(d: int) -> String:
	return "%4d/%02d/%02d %02d:%02d" % [(d & 0x3f) + 2000, (d >> 6) & 0xf, (d >> 10) & 0x1f,
		(d >> 15) & 0x1f, (d >> 20) & 0x3f]

## The inverse, for a server or a test: year 2000..2063. The seconds go in
## bits 26..31 (INFERRED; the client does not read them).
static func pack_date(year: int, month: int, day: int, hour: int, minute: int, second: int = 0) -> int:
	return ((year - 2000) & 0x3f) | ((month & 0xf) << 6) | ((day & 0x1f) << 10) \
		| ((hour & 0x1f) << 15) | ((minute & 0x3f) << 20) | ((second & 0x3f) << 26)

## A u32 the client prints with "%d" (READ: the amount and total are ints).
static func _s32(v: int) -> int:
	v &= 0xffffffff
	return v - 0x100000000 if v >= 0x80000000 else v
