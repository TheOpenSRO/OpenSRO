extends RefCounted
class_name AcademyMatchWindow

## Round 865: the academy's matching board, "Guardian Matching" -- CIFMentorMatch,
## GDR_MENTOR_MATCH (ginterface ID 153, 785 x 480 on mframe_wnd_, title
## UIIT_STT_TC_MACHING_TITLE), resinfo\ifmentormatch.txt's Create, SearchInfo,
## SlotListButton and SlotList (CIFMentorMatch::Create c:0x770910 builds those
## four) -- and its register box. HudPanels builds the window; this fills it
## from the board's replies (AcademyState.match_reply) and turns its controls
## into the board's requests. docs/protocol/academy.md 7.10 and 10.5. READ from
## sro_client.exe unless a line says otherwise:
##
## **The store** (the object at 0xeeecb4): byte 0 the page shown, byte 1 the
## page count (0xB47D's header, c:0x7738c0: the FIRST byte is the page count,
## the second the page), the pages' rows by page (0x775b00), and the player's
## own entry at +4 (0x7738d0), held apart from the pages:
## - 0xB47A / 0xB47B build it from the reply (c:0x775bc0): the entry id, the
##   flags and the title from the reply, the race from the player's own model
##   (+0x9c), Level / max level from the guardian's member record (+0x58 /
##   +0x59), the assistants and apprentices counted from the camp's members by
##   class, the honor grade from the camp (+0x34), the name the player's own;
##   0xB47A's last u32 is the entry's Graduate column (0x7738e0 writes own
##   +0x14), 0xB47B leaves that field as it was;
## - a 0xB47D page row 0 whose name is the player's becomes the own entry
##   (c:0x7747c0), and later rows of that name are dropped (c:0x890dcb..
##   0x890e19); every other row goes into the page (0x7759a0);
## - asking for a page clears the own entry first (0x769930 -> 0x7747c0(0)).
##
## **The window**:
## - the own entry, when its id is not 0, is pinned in row 0 and every column
##   drawn 0xff87e9ff (135, 233, 255); the rest are the shown list from the
##   scroll position, the own id skipped (c:0x770bc0);
## - a row (c:0x773320): No. "%d" the entry id; Level "%d" the max level when
##   level == max, else "%d(%d)" (level, max); Race UIIT_CTL_PARTYMATCH_
##   AUTOMATCH_RACE_CH for race 0, _EU for 1, else nothing (c:0x772e60); Name;
##   Title fitted to 302 px with "..." (0x8b47c0(.., 0x12e, 1)); Graduate "%d";
##   Member "%d/%d" (assistants + apprentices + 1, 8); Honor Grade
##   com_honor_level_<rank>.ddj (c:0x7731e0) and "(%d)" the rank. An empty row
##   is blank;
## - the shown list is the page's rows (0x771090); its scroll range is the
##   count less 12; the page spin's top is the page count less 1 (the count
##   itself when 0, 0x77121f..0x77123b);
## - Create (c:0x770910): the honor grade combo (45) "1".."5" and
##   UIIT_CTL_PARTYMATCH_PSEARCH_OBJECTALL, "All" chosen (index 5); the
##   condition combo (46) UIIT_STT_TC_STUDENT, UIIT_STT_TC_ASSISTANT_GUARDIAN
##   and "All", "All" chosen (index 2); both texts right-aligned (2); then page
##   0 is asked for (0x769930(0)) and the rules run (0x76f430). The window is
##   made at each open, so each open starts there (on_shown);
## - the enable rules (c:0x76f430): Join with no own entry, the player's level
##   below 60 and rows shown; Whisper with rows shown; Registration with no own
##   entry, in an academy, level 60 or more, the player its guardian and not
##   both roles full (0x993040(1) and (2)); Change entry and Delete entry
##   both when the own entry exists and carries the player's name; Search
##   always;
## - the buttons (message map initialised at c:0xd70e80: 56 -> 0x769f70, 55
##   -> 0x771990, 15 -> 0x770690, 16 -> 0x76f6d0, 18 -> 0x7693d0, 19 ->
##   0x769470, 20 -> 0x769510, the box result 0x8077 -> 0x76fcc0):
##   - Refresh: the spin's page asked for (the own entry cleared first), then
##     Refresh disabled and timer 10 armed for 2000 ms;
##   - Search (0x771270): the page's rows kept when the name edit (47) is
##     empty or equal to the row's name, the honor combo is "All" or its index
##     + 1 equals the row's rank, and the condition combo is "All" or its index
##     + 1 equals the row's flags; none left -> UIIT_STT_TC_MACHING_
##     REFERENCE_ERROR (system line, type 4) and an empty list;
##   - Join: the selected row, found in the page, -> 0x747E {u32 entry id};
##     the joining window (child 200, CIFPartyJoinProgress) opens
##     (0x770050(1, "", "")) and 0xB47E closes it (0x770050(0, ..));
##   - Whisper: the selected row, not the own entry, found in the page -> the
##     chat's whisper line to its name (0x777d10);
##   - Registration / Change entry: the register box (below), state
##     "register" / "modify";
##   - Delete entry: 0x747C {u32 own entry id} at once, no question;
## - the replies: 0xB47A -> own entry, refresh, banner UIIT_STT_TC_MACHING_
##   ENTRY (0x77b580); 0xB47B -> own entry, banner UIIT_STT_TC_MACHING_CORRECT;
##   0xB47C {id}: the own id -> own entry cleared; else removed from the page
##   held, or with no page held that page is asked for again (c:0x88dfce..
##   0x88dff6); the banner UIIT_STT_TC_MACHING_PULL_DELETE when the client
##   deleted it itself (flag 0xeebf20 = 1 or 2) else _DELETE, the flag cleared;
##   0xB47E {s}: 1 banner UIIT_STT_TC_MACHING_COMPLETE, 0 UIIT_MSG_TC_JOIN_
##   CANCEL, 2 UIIT_MSG_TC_JOIN_NOREPLY (both system lines type 4; round 866:
##   AcademyFlow prints them, as c:0x892c50 needs no window), the joining
##   window closed; a refusal -> category 0x1d (AcademyState.refused);
## - the full camp's own delete (c:0x76f7b0, run when a member joins, 0x3C80
##   02 at c:0x8a242b): the guardian with an own entry deletes it (0x747C, flag
##   1) when the assistants are full and the entry recruits assistants (flags
##   2), or (flag 2) when the apprentices are full and it recruits apprentices
##   (flags 1).
##
## **The register box** (c:0x7693d0 / 0x769470): a MsgBox (class 0xee95a0,
## ID 100) 0x168 x 0xd7 (360 x 215), purpose 8 = ifmessagebox.txt's section
## MentorMatchRegister (0x643c20 -> 0x640660): caption UIIT_CTL_TC_MACHING_
## ENTER; the title edit (513) 0x32 characters; check box 507 (Apprentice
## Recruitment) on, 508 (Asst. Guardian Recruitment) off; a click on either
## turns it on and the other off (0x63c150 / 0x63c170). Its OK (c:0x76fcc0):
## the type byte (0x63c1c0) 1 when 507 is on, else 2 when 508 is, else 0; an
## empty title -> UIIT_STT_TC_MACHING_TITLE_ERROR (system line type 0) and the
## box stays; type 2 with the assistants full -> UIIT_MSG_TC_ERROR_SECOND_
## GUARDIAN_COUNT_OVER, type 1 with the apprentices full -> UIIT_MSG_TC_ERROR_
## STUDENT_COUNT_OVER (both on the banner, 0x77b580); else 0x747A {u32 0, u32
## camp id, u8 type, str title}, or in modify mode 0x747B {u32 own entry id,
## u32 camp id, u8 type, str title}; then the box closes. MEASURED: placed
## centred over the matching window (its top 428 under a window at 297, 480
## high). OURS: modify mode starts empty, as the original's (it does not
## pre-fill: nothing sets the edit or the checks there, c:0x769470).
##
## Round 866: the guardian's question (0x747E down, c:0x890fa0) is
## AcademyJoinAskBox and its answer 0x347F AcademyFlow's; the joining window
## runs in the academy's mode (PartyJoinProgress.build_academy).
## OPEN, not built: the column headers' sorting (60..67 -> 0x7727c0 and the
## comparers 0x769550..0x7698d0).

const ROWS := 12
const SLOT_LAYOUT := "resinfo\\ifmentormatchslot.txt"
const OWN_ROW_COLOR := Color8(135, 233, 255)
const HONOR_ART := "interface\\ifcommon\\com_honor_level_%d.ddj"
const REFRESH_COOLDOWN_MS := 2000
const SCROLL_LENGTH := 232.0
const TITLE_FIT := 0x12e
## Level from which the player may register and below which it may join.
const GUARDIAN_LEVEL := 60

const BTN_JOIN := "GDR_MENTORMATCH_JOIN_BTN"
const BTN_WHISPER := "GDR_MENTORMATCH_WHISPER_BTN"
const BTN_REGISTER := "GDR_MENTORMATCH_REGISTER_BTN"
const BTN_MODIFY := "GDR_MENTORMATCH_MODIFY_BTN"
const BTN_DELETE := "GDR_MENTORMATCH_DELETE_BTN"
const BTN_SEARCH := "GDR_MENTORMATCH_SEARCH_BTN"
const BTN_REFRESH := "GDR_MENTORMATCH_UPDATE_BTN"
const SPIN := "GDR_MENTORMATCH_SPIN_PAGE"
const SCROLL := "GDR_MENTORMATCH_SCROLL"
const NAME_EDIT := "GDR_MENTORMATCH_SEARCH_NAME_EDIT"
const GRADE_COMBO := "GDR_MENTORMATCH_SEARCH_COMBOBOX1"
const CONDITION_COMBO := "GDR_MENTORMATCH_SEARCH_COMBOBOX2"
const ALL_BUTTONS := [BTN_JOIN, BTN_WHISPER, BTN_REGISTER, BTN_MODIFY, BTN_DELETE, BTN_SEARCH, BTN_REFRESH]

## A request to send (NetClient.academy_send).
signal send(op: int, payload: PackedByteArray)
## A GDR_WARNING_WND banner (0x77b580).
signal banner(key: String)
## A system line: the key and the window type (0 always, 4 party/academy).
signal notice(key: String, type: int)
## Whisper's chat line to that name.
signal whisper_requested(name: String)

var state: AcademyState
var _builder: UiBuilder
var window: Control
var host: Control

## Injected (each optional): the player's name, level and own race byte
## (0 China, 1 Europe); a model's race byte; the view size.
var own_name: Callable
var own_level: Callable
var own_race: Callable
var race_of_model: Callable
var view_size: Callable

## The pages' rows by page number (0x775b00).
var pages := {}
var page := 0
var page_count := 0
## The own entry (+4); null or id 0 when none.
var own: AcademyNet.MatchRow = null
## The shown list (+0x7c4): rows of the page, or the Search result.
var shown: Array = []
var _scroll := 0
var selected_slot := -1
## 0xeebf20: 1 / 2 when the client deleted its own entry for a full role.
var pull_flag := 0
var refresh_locked_ms := 0

var _slots: Array[Control] = []
var _scroll_bar: Control
var _grade_combo: OptionButton
var _condition_combo: OptionButton
var register_box: AcademyMatchRegister
var progress_box: PartyJoinProgress

func _init(builder: UiBuilder, academy: AcademyState, box_host: Control) -> void:
	_builder = builder
	state = academy
	host = box_host
	state.match_reply.connect(on_reply)
	state.line.connect(_on_state_line)
	state.changed.connect(update_buttons)

func dispose() -> void:
	for pair in [[state.match_reply, on_reply], [state.line, _on_state_line], [state.changed, update_buttons]]:
		if (pair[0] as Signal).is_connected(pair[1]):
			(pair[0] as Signal).disconnect(pair[1])
	_close_box(register_box)
	_close_box(progress_box)
	window = null

# --- The window ----------------------------------------------------------------

## Called when HudPanels has built GDR_MENTOR_MATCH, and on each show.
func attach(win: Control) -> void:
	if win == null:
		return
	if window != win:
		window = win
		_build_slots()
		_build_search()
		_wire_buttons()
		_build_scroll()
		window.visibility_changed.connect(_on_window_visibility)
	refresh()

## A show: the original creates the window at each open (Create c:0x770910),
## so the spin is at 0, the combos on "All", the name edit empty, and page 0
## is asked for (the own entry cleared, 0x769930(0)).
func on_shown() -> void:
	var spin := node(SPIN)
	if spin != null:
		spin.set_meta("value", 0)
		UiBuilder._spin_refresh(spin)
	var e := node(NAME_EDIT) as LineEdit
	if e != null:
		e.text = ""
	if _grade_combo != null:
		_grade_combo.select(5)
	if _condition_combo != null:
		_condition_combo.select(2)
	selected_slot = -1
	_scroll = 0
	request_page(0)
	refresh()

## The window's close takes its boxes with it (children 105 and 200).
func _on_window_visibility() -> void:
	if window == null or window.visible:
		return
	_close_box(register_box)
	register_box = null

func node(control_name: String) -> Control:
	if window == null:
		return null
	if window.has_method("node"):
		return window.call("node", control_name) as Control
	return window.find_child(control_name, true, false) as Control

func _build_slots() -> void:
	_slots.clear()
	var layout: UiLayoutParser.LayoutDef = _builder.load_layout(SLOT_LAYOUT) if _builder != null else null
	for i in ROWS:
		var slot := node("GDR_MENTORMATCH_SLOTLIST_SLOT_%02d" % i)
		_slots.append(slot)
		if slot == null:
			continue
		if layout != null:
			var built := _builder.build_section(layout, "Create")
			if built != null:
				built.name = "MatchSlot"
				slot.add_child(built)
				UiBuilder.settle_authored_rects(built)
				for n in built.get_children():
					if n is Control:
						(n as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
		# The row bar is the layout's GDR_MENTORMATCH_SLOT_SELECT (com_bar01_);
		# the selected row's is com_bar01select_ (0x7730d0), a second bar here.
		var holder := slot.get_node_or_null("MatchSlot") as Control
		var plain := holder.get_node_or_null("GDR_MENTORMATCH_SLOT_SELECT") as Control if holder != null else null
		if _builder != null and holder != null and holder.get_node_or_null("SelectBar") == null:
			var before := holder.get_child_count()
			_builder._add_row_bar_from(holder, UiBuilder.ROW_BAR_SELECTED_DDJ, Vector2(715, 24))
			if holder.get_child_count() > before:
				var sel := holder.get_child(holder.get_child_count() - 1) as Control
				sel.name = "SelectBar"
				sel.visible = false
				sel.mouse_filter = Control.MOUSE_FILTER_IGNORE
				holder.move_child(sel, plain.get_index() + 1 if plain != null else 0)
		slot.mouse_filter = Control.MOUSE_FILTER_STOP
		slot.gui_input.connect(_on_slot_input.bind(i))

func _build_search() -> void:
	_grade_combo = _combo(node(GRADE_COMBO), ["1", "2", "3", "4", "5",
		_text("UIIT_CTL_PARTYMATCH_PSEARCH_OBJECTALL", "All")], 5)
	_condition_combo = _combo(node(CONDITION_COMBO), [_text("UIIT_STT_TC_STUDENT", "Novice apprentice"),
		_text("UIIT_STT_TC_ASSISTANT_GUARDIAN", "Asst. guardian"),
		_text("UIIT_CTL_PARTYMATCH_PSEARCH_OBJECTALL", "All")], 2)
	# The headers the 3-slice path leaves without text (as PartyMatchWindow).
	var subject := node("GDR_MENTORMATCH_SLOTLIST_SUBJECT")
	if subject != null and subject.get_node_or_null("HeaderText") == null:
		var lbl := Label.new()
		lbl.name = "HeaderText"
		lbl.text = _text("UIIT_STT_LETTER_TITLE", "Title")
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		lbl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if _builder != null and _builder.font_at(0) != null:
			lbl.add_theme_font_override("font", _builder.font_at(0))
		lbl.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[0])
		subject.add_child(lbl)
	var dumy := node("GDR_MENTORMATCH_SLOTLIST_DUMY")
	if dumy != null and _builder != null:
		_builder.set_static_text(dumy, "")

## A CIFComboBox with `items`, `chosen` selected, its text right-aligned
## (c:0x770a89..0x770aad: +0x84 vslot 0x14 with 2).
func _combo(host_combo: Control, items: Array, chosen: int) -> OptionButton:
	if host_combo == null:
		return null
	if host_combo.size == Vector2.ZERO:
		host_combo.size = Vector2(74, 20)
	var c := OptionVideoPage.make_combo(_builder, host_combo)
	if c == null:
		return null
	c.alignment = HORIZONTAL_ALIGNMENT_RIGHT
	for i in items.size():
		c.add_item(String(items[i]), i)
	c.select(chosen)
	return c

func _build_scroll() -> void:
	var host_scroll := node(SCROLL)
	if host_scroll == null or _scroll_bar != null:
		return
	var bar := HudChat.ChatScroll.new()
	bar.name = "MatchScroll"
	if _builder != null:
		bar.up_texture = _builder.load_texture(HudChat.ARROW_UP_DDJ)
		bar.down_texture = _builder.load_texture(HudChat.ARROW_DOWN_DDJ)
		bar.bar_texture = _builder.load_texture(HudChat.SCROLL_BAR_DDJ)
		bar.thumb_texture = _builder.load_texture(HudChat.SCROLL_THUMB_DDJ)
	bar.length = SCROLL_LENGTH
	bar.position = Vector2(0, -HudChat.SCROLL_BUTTON.y)
	bar.size = Vector2(HudChat.SCROLL_BUTTON.x, HudChat.SCROLL_BUTTON.y * 3 + SCROLL_LENGTH)
	bar.moved.connect(func(pos: int) -> void:
		_scroll = pos
		refresh())
	host_scroll.add_child(bar)
	_scroll_bar = bar

func _wire_buttons() -> void:
	var map := {BTN_JOIN: press_join, BTN_WHISPER: press_whisper, BTN_REGISTER: press_register,
		BTN_MODIFY: press_modify, BTN_DELETE: press_delete, BTN_SEARCH: press_search, BTN_REFRESH: press_refresh}
	for n in map:
		var b := node(n) as BaseButton
		if b != null:
			b.pressed.connect(map[n])
	var list := node("GDR_MENTORMATCH_SLOTLIST_BLACKSQUARE")
	if list != null:
		list.gui_input.connect(_on_list_input)

func _text(key: String, fallback: String) -> String:
	if _builder == null:
		return fallback
	var t := _builder.resolve_text(key)
	return fallback if t == "" or t == key else t

func _me() -> String:
	return String(own_name.call()) if own_name.is_valid() else ""

func _level() -> int:
	return int(own_level.call()) if own_level.is_valid() else 0

func has_own() -> bool:
	return own != null and own.entry_id != 0

# --- What the window shows -----------------------------------------------------

## The rows in the twelve slots: the own entry pinned, then the shown list from
## the scroll position, the own id skipped (c:0x770bc0).
func shown_rows() -> Array:
	var out: Array = []
	if has_own():
		out.append(own)
	var start := clampi(_scroll, 0, scroll_max())
	for i in range(start, shown.size()):
		if out.size() >= ROWS:
			break
		var r: AcademyNet.MatchRow = shown[i]
		if has_own() and r.entry_id == own.entry_id:
			continue
		out.append(r)
	return out

func scroll_max() -> int:
	return maxi(0, shown.size() - ROWS)

func refresh() -> void:
	if window == null:
		return
	var rows := shown_rows()
	if selected_slot >= rows.size():
		selected_slot = -1
	for i in ROWS:
		var slot := _slots[i] if i < _slots.size() else null
		if slot == null:
			continue
		var row: AcademyNet.MatchRow = rows[i] if i < rows.size() else null
		_fill_slot(slot, row, row != null and row == own, i == selected_slot)
	if _scroll_bar != null:
		_scroll_bar.call("set_range", scroll_max(), clampi(_scroll, 0, scroll_max()))
	var spin := node(SPIN)
	if spin != null:
		spin.set_meta("max", page_count - 1 if page_count > 0 else page_count)
	update_buttons()

## The text of one row's column (tests, the QA log).
func slot_text(i: int, col: String) -> String:
	var slot := _slots[i] if i >= 0 and i < _slots.size() else null
	var n := slot.get_node_or_null("MatchSlot/" + col) if slot != null else null
	if n == null:
		return ""
	if n is Label:
		return (n as Label).text
	var l := n.get_node_or_null("Text") as Label
	return l.text if l != null else ""

## c:0x773320.
func _fill_slot(slot: Control, row: AcademyNet.MatchRow, is_own: bool, selected: bool) -> void:
	var s := slot.get_node_or_null("MatchSlot")
	if s == null:
		return
	var sel := s.get_node_or_null("SelectBar") as CanvasItem
	if sel != null:
		sel.visible = selected
		var plain := s.get_node_or_null("GDR_MENTORMATCH_SLOT_SELECT") as CanvasItem
		if plain != null:
			plain.visible = not selected
	var cols := {
		"GDR_MENTORMATCH_SLOT_ID": "", "GDR_MENTORMATCH_SLOT_LEVEL": "", "GDR_MENTORMATCH_SLOT_RACE": "",
		"GDR_MENTORMATCH_SLOT_NAME": "", "GDR_MENTORMATCH_SLOT_SUBJECT": "", "GDR_MENTORMATCH_SLOT_STUDENT": "",
		"GDR_MENTORMATCH_SLOT_NUMBER": "", "GDR_MENTORMATCH_SLOT_GRADE_NUM": "",
	}
	if row != null:
		cols["GDR_MENTORMATCH_SLOT_ID"] = "%d" % row.entry_id
		cols["GDR_MENTORMATCH_SLOT_LEVEL"] = "%d" % row.max_level if row.max_level == row.level \
			else "%d(%d)" % [row.level, row.max_level]
		cols["GDR_MENTORMATCH_SLOT_RACE"] = race_text(_race(row))
		cols["GDR_MENTORMATCH_SLOT_NAME"] = row.guardian
		cols["GDR_MENTORMATCH_SLOT_SUBJECT"] = row.title
		cols["GDR_MENTORMATCH_SLOT_STUDENT"] = "%d" % row.graduates
		cols["GDR_MENTORMATCH_SLOT_NUMBER"] = "%d/%d" % [row.assistants + row.apprentices + 1, 8]
		cols["GDR_MENTORMATCH_SLOT_GRADE_NUM"] = "(%d)" % row.rank
	for n in cols:
		var c := s.get_node_or_null(n) as Control
		var lbl := _builder.set_static_text(c, cols[n]) if _builder != null and c != null else (c as Label)
		if lbl == null:
			continue
		if _builder == null:
			lbl.text = cols[n]
		lbl.add_theme_color_override("font_color", OWN_ROW_COLOR if is_own else Color.WHITE)
		if n == "GDR_MENTORMATCH_SLOT_SUBJECT":
			lbl.clip_text = true
			lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			lbl.custom_minimum_size.x = 0
			lbl.size.x = TITLE_FIT
	var grade := s.get_node_or_null("GDR_MENTORMATCH_SLOT_GRADE") as Control
	if grade != null:
		var icon := grade.get_node_or_null("GradeIcon") as TextureRect
		if icon == null:
			icon = TextureRect.new()
			icon.name = "GradeIcon"
			icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			icon.size = Vector2(16, 16)
			icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
			grade.add_child(icon)
		var art := HONOR_ART % row.rank if row != null else ""
		icon.set_meta("ddj", art)
		icon.texture = _builder.load_texture(art) if _builder != null and art != "" else null

## The row's race byte: the own entry's from the player's model, a page
## row's from its RefObjID (c:0x890d66 -> +0x9c).
func _race(row: AcademyNet.MatchRow) -> int:
	if row == own and own_race.is_valid():
		return int(own_race.call())
	if race_of_model.is_valid():
		return int(race_of_model.call(row.ref_obj_id))
	return -1

## c:0x772e60: 0 China, 1 Europe, else nothing.
func race_text(race: int) -> String:
	match race:
		0:
			return _text("UIIT_CTL_PARTYMATCH_AUTOMATCH_RACE_CH", "CHN")
		1:
			return _text("UIIT_CTL_PARTYMATCH_AUTOMATCH_RACE_EU", "EUR")
	return ""

# --- The enable rules (c:0x76f430) ---------------------------------------------

func enabled(control_name: String) -> bool:
	match control_name:
		BTN_JOIN:
			return not has_own() and _level() < GUARDIAN_LEVEL and not shown.is_empty()
		BTN_WHISPER:
			return not shown.is_empty()
		BTN_REGISTER:
			return not has_own() and state.in_academy() and _level() >= GUARDIAN_LEVEL and state.am_guardian() \
				and not (state.role_full(AcademyNet.CLASS_ASSISTANT) and state.role_full(AcademyNet.CLASS_APPRENTICE))
		BTN_MODIFY, BTN_DELETE:
			return has_own() and own.guardian == _me()
		BTN_REFRESH:
			return refresh_locked_ms <= 0
	return true

func update_buttons() -> void:
	# The rules' tail re-arms timer 10 (2000 ms); a running Refresh lock
	# restarts with every pass (as PartyMatchWindow reads its twin).
	if refresh_locked_ms > 0:
		refresh_locked_ms = REFRESH_COOLDOWN_MS
	_apply_buttons()

func _apply_buttons() -> void:
	if window == null:
		return
	for n in ALL_BUTTONS:
		var b := node(n) as BaseButton
		if b != null:
			b.disabled = not enabled(n)

## Ticks the Refresh lock (HudPanels' _process).
func advance(ms: int) -> void:
	if refresh_locked_ms > 0:
		refresh_locked_ms -= ms
		if refresh_locked_ms <= 0:
			refresh_locked_ms = 0
			_apply_buttons()

# --- Selection and scrolling ---------------------------------------------------

func _on_slot_input(e: InputEvent, i: int) -> void:
	var mb := e as InputEventMouseButton
	if mb == null or not mb.pressed:
		return
	if mb.button_index == MOUSE_BUTTON_LEFT:
		select_slot(i)
	elif mb.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		scroll_by(-1 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1)

func _on_list_input(e: InputEvent) -> void:
	var mb := e as InputEventMouseButton
	if mb != null and mb.pressed and mb.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		scroll_by(-1 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1)

## A click (0x770e40): the old selection's bar off, the clicked slot's on when
## it holds a row.
func select_slot(i: int) -> void:
	var rows := shown_rows()
	selected_slot = i if i >= 0 and i < rows.size() else -1
	refresh()

func selected_row() -> AcademyNet.MatchRow:
	var rows := shown_rows()
	if selected_slot < 0 or selected_slot >= rows.size():
		return null
	return rows[selected_slot]

func scroll_by(step: int) -> void:
	_scroll = clampi(_scroll + step, 0, scroll_max())
	refresh()

## The selected row if the page held holds it (0x775aa0), else null.
func _selected_in_page() -> AcademyNet.MatchRow:
	var row := selected_row()
	if row == null or row == own:
		return null
	for r in pages.get(page, []):
		if (r as AcademyNet.MatchRow).entry_id == row.entry_id:
			return r
	return null

# --- The buttons -------------------------------------------------------------------

## 0x769930(page): the own entry cleared, then 0x747D {page}.
func request_page(p: int) -> void:
	own = null
	send.emit(AcademyNet.OP_MATCH_PAGE, AcademyNet.encode_page(p))

## Refresh (c:0x769f70).
func press_refresh() -> void:
	if refresh_locked_ms > 0:
		return
	var spin := node(SPIN)
	request_page(UiBuilder.spin_value(spin) if spin != null else 0)
	refresh_locked_ms = REFRESH_COOLDOWN_MS
	refresh()

## Join (c:0x770690).
func press_join() -> void:
	if not enabled(BTN_JOIN):
		return
	var row := _selected_in_page()
	if row == null:
		return
	send.emit(AcademyNet.OP_MATCH_JOIN, AcademyNet.encode_entry(row.entry_id))
	_open_progress()

## Whisper (c:0x76f6d0).
func press_whisper() -> void:
	var row := _selected_in_page()
	if row != null:
		whisper_requested.emit(row.guardian)

func press_register() -> void:
	if enabled(BTN_REGISTER):
		_open_register(false)

func press_modify() -> void:
	if enabled(BTN_MODIFY):
		_open_register(true)

## Delete entry (c:0x769510): at once, no question.
func press_delete() -> void:
	if not enabled(BTN_DELETE):
		return
	send.emit(AcademyNet.OP_MATCH_DELETE, AcademyNet.encode_entry(own.entry_id))

## Search (c:0x771270).
func press_search() -> void:
	var e := node(NAME_EDIT) as LineEdit
	var want_name := e.text if e != null else ""
	var g := _grade_combo.selected if _grade_combo != null else 5
	var g_all := (_grade_combo.item_count - 1) if _grade_combo != null else 5
	var c := _condition_combo.selected if _condition_combo != null else 2
	var c_all := (_condition_combo.item_count - 1) if _condition_combo != null else 2
	var out: Array = []
	for r_v in pages.get(page, []):
		var r: AcademyNet.MatchRow = r_v
		if want_name != "" and r.guardian != want_name:
			continue
		if g != g_all and g + 1 != r.rank:
			continue
		if c != c_all and c + 1 != r.flags:
			continue
		out.append(r)
	shown = out
	_scroll = 0
	selected_slot = -1
	if out.is_empty():
		notice.emit("UIIT_STT_TC_MACHING_REFERENCE_ERROR", 4)
	refresh()

# --- The replies -------------------------------------------------------------------

func on_reply(op: int, ok: bool, body: Dictionary) -> void:
	if not ok:
		if op == AcademyNet.OP_MATCH_JOIN_RESULT:
			_close_progress()
		return
	match op:
		AcademyNet.OP_MATCH_REGISTER_RESULT, AcademyNet.OP_MATCH_MODIFY_RESULT:
			if body.is_empty():
				return
			_build_own(body, op == AcademyNet.OP_MATCH_REGISTER_RESULT)
			_close_box(register_box)
			register_box = null
			refresh()
			banner.emit("UIIT_STT_TC_MACHING_ENTRY" if op == AcademyNet.OP_MATCH_REGISTER_RESULT
				else "UIIT_STT_TC_MACHING_CORRECT")
		AcademyNet.OP_MATCH_DELETE_RESULT:
			if body.is_empty():
				return
			var id := int(body["entry_id"])
			if has_own() and own.entry_id == id:
				own = null
			elif pages.has(page):
				pages[page] = (pages[page] as Array).filter(func(r: AcademyNet.MatchRow) -> bool: return r.entry_id != id)
			else:
				send.emit(AcademyNet.OP_MATCH_PAGE, AcademyNet.encode_page(page))
			shown = shown.filter(func(r: AcademyNet.MatchRow) -> bool: return r.entry_id != id)
			refresh()
			banner.emit("UIIT_STT_TC_MACHING_PULL_DELETE" if pull_flag == 1 or pull_flag == 2
				else "UIIT_STT_TC_MACHING_DELETE")
			pull_flag = 0
		AcademyNet.OP_MATCH_PAGE_RESULT:
			if body.is_empty():
				return
			_on_page(body)
		AcademyNet.OP_MATCH_JOIN_RESULT:
			# Round 866: the texts are AcademyFlow's (UI_TC::FUN_00892c50
			# prints them with no window, the guardian's included); the
			# window only closes its joining window.
			_close_progress()

## c:0x890ab0: the header (page count, page) and the rows.
func _on_page(body: Dictionary) -> void:
	page_count = int(body["a"])
	page = int(body["b"])
	var rows: Array = []
	var found_own := false
	var me := _me()
	var rows_in: Array = body["rows"]
	for i in rows_in.size():
		var r: AcademyNet.MatchRow = rows_in[i]
		if i == 0 and r.guardian == me and me != "":
			own = r
			found_own = true
			continue
		if found_own and r.guardian == me:
			continue
		rows.append(r)
	pages[page] = rows
	shown = rows.duplicate()
	_scroll = 0
	refresh()

## c:0x775bc0: the own entry from a register / modify reply.
func _build_own(body: Dictionary, register: bool) -> void:
	var keep_graduates := own.graduates if own != null else 0
	var r := AcademyNet.MatchRow.new()
	r.entry_id = int(body["entry_id"])
	r.flags = int(body["flags"])
	r.title = String(body["title"])
	r.guardian = _me()
	var g := state.guardian()
	if g != null:
		r.level = g.cur_level
		r.max_level = g.max_level
	r.assistants = state.of_class(AcademyNet.CLASS_ASSISTANT).size()
	r.apprentices = state.of_class(AcademyNet.CLASS_APPRENTICE).size()
	r.rank = state.camp.rank if state.camp != null else 0
	r.graduates = int(body.get("tail", 0)) if register else keep_graduates
	own = r

## c:0x76f7b0, run when a member joins (0x3C80 02): the full role's own entry
## is deleted by the client itself.
func on_member_joined() -> void:
	if not state.in_academy() or not state.am_guardian() or not has_own():
		return
	if state.role_full(AcademyNet.CLASS_ASSISTANT) and own.flags == 2:
		pull_flag = 1
		send.emit(AcademyNet.OP_MATCH_DELETE, AcademyNet.encode_entry(own.entry_id))
	elif state.role_full(AcademyNet.CLASS_APPRENTICE) and own.flags == 1:
		pull_flag = 2
		send.emit(AcademyNet.OP_MATCH_DELETE, AcademyNet.encode_entry(own.entry_id))
	else:
		pull_flag = 0

func _on_state_line(key: String, _args: Array) -> void:
	# AcademyState says a member joined with this line (c:0x8a23d5); the
	# original runs 0x76f7b0 right after it (c:0x8a242b).
	if key == "UIIT_MSG_TC_MACHING_JOINING_MEMBER":
		on_member_joined()

# --- The boxes ---------------------------------------------------------------------

func _open_register(modify: bool) -> void:
	_close_box(register_box)
	register_box = AcademyMatchRegister.new()
	if not register_box.build_register(_builder, modify):
		register_box.queue_free()
		register_box = null
		return
	register_box.submitted.connect(_on_register_ok)
	if window != null and window.is_inside_tree():
		register_box.position = window.global_position + (window.size - register_box.size) / 2.0
		register_box.position = register_box.position.floor()
	else:
		var view: Vector2 = view_size.call() if view_size.is_valid() else Vector2(1024, 768)
		register_box.centre_on(view)
	if host != null:
		host.add_child(register_box)

## c:0x76fcc0: OK's checks, then the request; the box closes unless the title
## was empty.
func _on_register_ok(kind: int, title: String, modify: bool) -> void:
	if title == "":
		notice.emit("UIIT_STT_TC_MACHING_TITLE_ERROR", 0)
		return
	var camp_id := state.camp.camp_id if state.camp != null else 0
	if kind == 2 and state.role_full(AcademyNet.CLASS_ASSISTANT):
		banner.emit("UIIT_MSG_TC_ERROR_SECOND_GUARDIAN_COUNT_OVER")
	elif kind == 1 and state.role_full(AcademyNet.CLASS_APPRENTICE):
		banner.emit("UIIT_MSG_TC_ERROR_STUDENT_COUNT_OVER")
	elif modify:
		var id := own.entry_id if own != null else 0
		send.emit(AcademyNet.OP_MATCH_MODIFY, AcademyNet.encode_match(id, camp_id, kind, title))
	else:
		send.emit(AcademyNet.OP_MATCH_REGISTER, AcademyNet.encode_match(0, camp_id, kind, title))
	_close_box(register_box)
	register_box = null

func _open_progress() -> void:
	_close_box(progress_box)
	progress_box = PartyJoinProgress.new()
	# Round 866: the academy's mode, kind 2 (c:0x77011d `push 0x2` ->
	# 0x732000): "Registration is in process." for 15 s. Round 865 built the
	# party's kind 1, whose line ("[]You [] has requested to join this
	# party.") the joiner then saw.
	if not progress_box.build_academy(_builder):
		progress_box.queue_free()
		progress_box = null
		return
	progress_box.finished.connect(func() -> void: progress_box = null)
	var view: Vector2 = view_size.call() if view_size.is_valid() else Vector2(1024, 768)
	progress_box.centre_on(view)
	if host != null:
		host.add_child(progress_box)

func _close_progress() -> void:
	if progress_box != null and is_instance_valid(progress_box):
		progress_box.finish()
	progress_box = null

func _close_box(box: Control) -> void:
	if box != null and is_instance_valid(box) and not box.is_queued_for_deletion():
		if box.has_method("close"):
			box.call("close")
		else:
			box.queue_free()


## The register box (ifmessagebox.txt's MentorMatchRegister in a MsgBox, READ
## c:0x7693d0 / 0x640660 / 0x63c150 / 0x63c170 / 0x63c1c0 / 0x76fcc0; see the
## header).
class AcademyMatchRegister extends PartyMatchBox:
	const SIZE := Vector2(0x168, 0xd7)
	const LAYOUT := "resinfo\\ifmessagebox.txt"
	const SECTION := "MentorMatchRegister"
	const TITLE_MAX := 0x32
	const EDIT := "GDR_MB_MENTOR_MATCH_EDIT"
	const CHECK_APPRENTICE := "GDR_MB_MENTOR_MATCH_CHBTN1"
	const CHECK_ASSISTANT := "GDR_MB_MENTOR_MATCH_CHBTN2"
	const BTN_OK := "GDR_MB_MENTOR_MATCH_BTN_CONFIRM"
	const BTN_CANCEL := "GDR_MB_MENTOR_MATCH_BTN_CANCLE"

	## OK pressed: the type byte, the title, the mode (the owner checks).
	signal submitted(kind: int, title: String, modify: bool)

	var modify_mode := false
	var check_apprentice: TextureButton
	var check_assistant: TextureButton

	func build_register(builder: UiBuilder, modify: bool) -> bool:
		name = "AcademyMatchRegister"
		modify_mode = modify
		if not build_shell(builder, SIZE, "UIIT_CTL_TC_MACHING_ENTER", "Registration", LAYOUT, SECTION):
			return false
		# The "Create" background tile, sized (w - 32, h - 56) as the
		# MsgBox's own (PartyMatchConfirm, 0x63b420).
		var layout: UiLayoutParser.LayoutDef = builder.load_layout(LAYOUT)
		if layout != null and layout.sections.has("Create"):
			var base := builder.build_section(layout, "Create")
			if base != null:
				add_child(base)
				move_child(base, root.get_index())
				var tile := base.get_node_or_null("GDR_MSGBOX_BG") as Control
				if tile != null:
					var r := Rect2(tile.position, Vector2(SIZE.x - 32, SIZE.y - 56))
					tile.set_meta(UiBuilder.AUTHORED_RECT_META, r)
					tile.custom_minimum_size = Vector2.ZERO
					tile.size = r.size
				UiBuilder.settle_authored_rects(base)
		setup_edit(EDIT, TITLE_MAX, "")
		check_apprentice = _check(CHECK_APPRENTICE, true)
		check_assistant = _check(CHECK_ASSISTANT, false)
		if check_apprentice != null:
			check_apprentice.pressed.connect(func() -> void: choose_kind(1))
		if check_assistant != null:
			check_assistant.pressed.connect(func() -> void: choose_kind(2))
		var ok := button(BTN_OK)
		if ok != null:
			ok.pressed.connect(press_ok)
		var cancel := button(BTN_CANCEL)
		if cancel != null:
			cancel.pressed.connect(close)
		return true

	func _check(control_name: String, on: bool) -> TextureButton:
		var holder := node(control_name)
		if holder == null or _builder == null:
			return null
		return _builder.make_checkbox(holder, "interface\\ifcommon\\com_radiobutton_off.ddj", on)

	## 0x63c150 / 0x63c170: the clicked one on, the other off.
	func choose_kind(kind: int) -> void:
		if check_apprentice != null:
			check_apprentice.set_pressed(kind == 1)
		if check_assistant != null:
			check_assistant.set_pressed(kind == 2)

	## 0x63c1c0: 1 when the first is on, else 2 when the second is, else 0.
	func kind() -> int:
		if check_apprentice != null and check_apprentice.button_pressed:
			return 1
		if check_assistant != null and check_assistant.button_pressed:
			return 2
		return 0

	func title_text() -> String:
		var e := node(EDIT) as LineEdit
		return e.text if e != null else ""

	func press_ok() -> void:
		submitted.emit(kind(), title_text(), modify_mode)
