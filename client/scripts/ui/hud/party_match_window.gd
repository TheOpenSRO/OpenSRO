extends RefCounted
class_name PartyMatchWindow

## The Party Matching window, CIFPartyMatch (round 714, lane C2;
## docs/protocol/party_gui.md §3, the user's screenshots 02, 06 and 07).
## HudPanels builds GDR_PARTY_MATCH from ifpartymatch.txt (Create,
## SearchInfo, SlotListButton, SlotList); this fills it from the matching
## state (PartyMatchState) and turns its controls into requests. It also owns
## the boxes the matching system opens -- the register and auto-match
## dialogs, the joining progress window and the leader's join popup -- which
## exist with or without the window. READ from sro_client.exe unless marked:
##
## - each CIFPartyMatchSlot loads resinfo\ifpartymatchslot.txt into itself;
##   its fill (0x740d30): No. `%d`, Type pt_association.ddj (bit 0) or
##   pt_eachone.ddj, Race text CHN / EUR (USER DECISION 2026-10-03: text, as
##   this exe draws it), Name (`*%s` for a Trade / Thief party), Title (302
##   px), Purpose text, Member `%d/8` or `%d/4`, Level range `%d~%d`;
## - the player's own registration in row 0 with every column in
##   (135,233,255) (0x740ea1), the other rows skipping it (0x73a770);
## - a click on a row with data selects it: its bar becomes
##   com_bar01select_ (0x73aab0 / 0x740ca0);
## - the enable rules (0x7384a0) and the buttons' handlers (message map
##   0xebc5c8): see party_gui.md §3's button table;
## - opening asks for page 0 (0x73b1ff); Refresh asks for the spin's page and
##   disables itself for 2 s (timer 10, 2000 ms; 0x73ab60); the spin asks for
##   its page (0x732630);
## - Search filters the held records (0x73bb80 -> 0x73b780); nothing left
##   says UIIT_MSG_PARTYMATCH_PSEARCH_NORESULT (type 4);
## - while the joining window is up, Form, Auto match, Join, Search and
##   Refresh are disabled, and its close enables those five outright
##   (0x7390b0: 0x12, 0x11, 0xf, 0x37, 0x38); while an auto-match run lasts,
##   Join, Auto, Form, Change, Delete, Search and Refresh are disabled
##   (0x738890(1), from 0x73ed8f and 0x7384a0's tail at 0x73869f) until it
##   ends (0x8848da / 0x884961 / 0x73edb0);
## - the selection is the SLOT (+0x7ec, 0x73aab0): a click resets the old
##   slot's bar, then selects the clicked slot only if it holds data -- an
##   empty row deselects; Join and Whisper read the selected slot's number;
## - while the player's party is full and it holds the registration, the
##   client deletes it (0x7387c0; the line is DELETE_COMPLETE2).
##
## - a new page empties both lists and refills them, the edits keeping their
##   text and the filter not re-applied (0x73b5b0 -> 0x73aa40, 0x73b4d0);
## - the scroll bar is a CIFVerticalScroll with ifverticalscroll.txt's parts
##   (HudChat.ChatScroll); its range is the records less 12, registration
##   pinned or not (0x73b5b0 / 0x73b780: `count - 0xc`); its length is the
##   record's 232 (INFERRED: CIFPartyMatch::Create sets none, and the down
##   arrow then ends at the list's bottom);
## - Create sets control 0x2b's text to "~" (0x73af56 / 0x73af69, 0xd884b0)
##   and the combo's text alignment to 2, right (0x73b062..0x73b073).
##
## OURS: the column headers do not sort (0x73e050); the row tooltip
## (0x740750) is not built; the Title header's text and the blank DUMY cell
## are set here because UiBuilder's 3-slice path drops a CIFBarWnd's text and
## draws a literal "L" for GDR_PARTYMATCH_SLOTLIST_DUMY (the original shows it
## empty: INFERRED a missing key that resolves to nothing).

const ROWS := 12
const SLOT_LAYOUT := "resinfo\\ifpartymatchslot.txt"
const OWN_ROW_COLOR := Color8(135, 233, 255)
const TYPE_ART_SHARED := "interface\\party\\pt_association.ddj"
const TYPE_ART_EACH := "interface\\party\\pt_eachone.ddj"
const NAME_MAX := 12
const REFRESH_COOLDOWN_MS := 2000

## The buttons' control names (ifpartymatch.txt).
const BTN_JOIN := "GDR_PARTYMATCH_PARTY_JOIN_BTN"
const BTN_WHISPER := "GDR_PARTYMATCH_WHISPER_BTN"
const BTN_AUTO := "GDR_PARTYMATCH_AUTO_MATCH_BTN"
const BTN_FORM := "GDR_PARTYMATCH_REGISTER_BTN"
const BTN_CHANGE := "GDR_PARTYMATCH_MODIFY_BTN"
const BTN_DELETE := "GDR_PARTYMATCH_DELETE_BTN"
const BTN_SEARCH := "GDR_PARTYMATCH_SEARCH_SEARCH_BTN"
const BTN_REFRESH := "GDR_PARTYMATCH_UPDATE_BTN"
## 0x7390b0's five (the joining window).
const PROGRESS_DISABLES := [BTN_FORM, BTN_AUTO, BTN_JOIN, BTN_SEARCH, BTN_REFRESH]
## 0x738890(1)'s seven (an auto-match run).
const AUTO_DISABLES := [BTN_JOIN, BTN_AUTO, BTN_FORM, BTN_CHANGE, BTN_DELETE, BTN_SEARCH, BTN_REFRESH]
const SCROLL_LENGTH := 232.0

## A whisper to that party's leader (0x7386e0 -> 0x7ab470: the chat line
## "$name " focused, READ).
signal whisper_requested(leader_name: String)
## Party matching's lock on the party window's Set (CIFParty 0x6d5ab0).
signal settings_lock(on: bool)
## A line for the system message window: key, code, type.
signal notice(key: String, code: int, type: int)
## A line for the warning banner.
signal banner(key: String)

var state: PartyMatchState
var party: PartyState
var _builder: UiBuilder
## The built window (a HudWindow in the game; any Control holding the
## layout's controls in the tests).
var window: Control
## Where the boxes go (HudPanels).
var host: Control

## Injected (each optional): the player's level, name and job state (1..4);
## a model's race byte; a region's zone name; a mastery's icon; the view size.
var own_level: Callable
var own_name: Callable
var own_job: Callable
var race_of_model: Callable
var zone_name: Callable
var mastery_icon: Callable
var view_size: Callable

var _slots: Array[Control] = []
## The records shown, after the Search filter (null: no filter).
var _filtered = null
var _scroll := 0
## The selected slot (+0x7ec), -1 when none.
var selected_slot := -1
## The selected slot's entry number (slot+0x36c), 0 when none.
var selected_number := 0
var _scroll_bar: Control
## The joining window's five are off (0x7390b0).
var _progress_up := false
var refresh_locked_ms := 0
var _combo: OptionButton

var register_box: PartyMatchRegister
var auto_box: PartyMatchAuto
var progress_box: PartyJoinProgress
var req_join_box: PartyMatchReqJoin
var confirm_box: PartyMatchConfirm

func _init(builder: UiBuilder, match_state: PartyMatchState, party_state: PartyState, box_host: Control) -> void:
	_builder = builder
	state = match_state
	party = party_state
	host = box_host
	state.changed.connect(refresh)
	state.paged.connect(on_page)
	state.notice.connect(func(k: String, c: int, t: int) -> void: notice.emit(k, c, t))
	state.banner.connect(func(k: String) -> void: banner.emit(k))
	state.register_done.connect(refresh)
	state.join_request.connect(show_join_request)
	state.join_finished.connect(_on_join_finished)
	state.removed.connect(_on_removed)
	state.settings_lock.connect(_on_settings_lock)
	if party != null:
		party.changed.connect(_on_party_changed)
		party.party_event.connect(_on_party_event)

## Lets go of everything this controller hooked (HudPanels' exit): the party
## state is NetClient's and lives for the process, so a controller left
## connected to it would act on every later party change (review B6).
func dispose() -> void:
	if party != null and party.changed.is_connected(_on_party_changed):
		party.changed.disconnect(_on_party_changed)
	if party != null and party.party_event.is_connected(_on_party_event):
		party.party_event.disconnect(_on_party_event)
	for sig in state.get_signal_list():
		for c in state.get_signal_connection_list(sig["name"]):
			state.disconnect(sig["name"], c["callable"])
	for b in [register_box, auto_box, progress_box, req_join_box, confirm_box]:
		_close_box(b)
	window = null

# --- The window --------------------------------------------------------------

## Called when HudPanels has built GDR_PARTY_MATCH, and on each show.
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

## The window was shown: page 0 (0x73b1ff), and Set locked (0x79c252).
func on_shown() -> void:
	state.request_page(0)
	settings_lock.emit(true)

## The window's close (0x79c170(0)): refused while the joining window is up
## (0x732ae0); else its children go with it (the register, auto and joining
## boxes are children 105, 110 and 100) and, with no registration, Set comes
## back (0x79c2fd).
func _on_window_visibility() -> void:
	if window == null or window.visible:
		return
	if progress_box != null and is_instance_valid(progress_box) and not progress_box.is_queued_for_deletion():
		window.call_deferred("show")
		return
	_close_box(register_box)
	_close_box(auto_box)
	register_box = null
	auto_box = null
	if state.registration == null:
		settings_lock.emit(false)

func window_open() -> bool:
	return window != null and window.visible

func _on_settings_lock(on: bool) -> void:
	# The 0xb06b of the own entry enables Set only out of a party with the
	# window closed (0x880268).
	if not on and (_in_party() or window_open()):
		return
	settings_lock.emit(on)

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
		var slot := node("GDR_PARTYMATCH_SLOTLIST_SLOT_%02d" % i)
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
		# The row's own bar is the layout's GDR_PARTYMATCH_SLOT_SELECT (ID 5,
		# com_bar01_); the fill swaps its art to com_bar01select_ for the
		# selected row (0x740ca0). Here the select art is a second 3-slice
		# bar right above it, shown in its place.
		var holder: Control = slot.get_node_or_null("MatchSlot") as Control
		var plain := holder.get_node_or_null("GDR_PARTYMATCH_SLOT_SELECT") as Control if holder != null else null
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
	var name_edit := node("GDR_PARTYMATCH_SEARCH_NAME_EDIT") as LineEdit
	if name_edit != null:
		name_edit.max_length = NAME_MAX
	for pair in [["GDR_PARTYMATCH_SEARCH_MIN_LEVEL_EDIT", PartyMatchNet.LEVEL_MIN], ["GDR_PARTYMATCH_SEARCH_MAX_LEVEL_EDIT", PartyMatchNet.LEVEL_MAX]]:
		var e := node(pair[0]) as LineEdit
		if e != null:
			e.max_length = 3
			e.text = "%d" % int(pair[1])
	var host_combo := node("GDR_PARTYMATCH_SEARCH_COMBOBOX")
	if host_combo != null and _combo == null:
		if host_combo.size == Vector2.ZERO:
			host_combo.size = Vector2(74, 20)
		# CIFComboBox::vslot_010 (0x6327f0) builds the same pieces as the
		# Option page's combo: com_qst_downarrow_button.ddj 20 wide,
		# com_blacksquare_, the fill 0xff000000 (READ, round 714's review).
		_combo = OptionVideoPage.new(null, _builder, null)._make_combo(host_combo)
		if _combo != null:
			_combo.alignment = HORIZONTAL_ALIGNMENT_RIGHT
			for i in 5:
				_combo.add_item(_text(PartyMatchNet.PURPOSE_KEYS[i], PartyMatchNet.PURPOSE_FALLBACKS[i]), i)
			_combo.select(PartyMatchNet.PURPOSE_ALL)
			_build_combo_text(host_combo)
	var div := node("GDR_PARTYMATCH_SEARCH_LEVEL_DIV_STA")
	if div != null and _builder != null:
		_builder.set_static_text(div, "~")
	var subject := node("GDR_PARTYMATCH_SLOTLIST_SUBJECT")
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
	var dumy := node("GDR_PARTYMATCH_SLOTLIST_DUMY")
	if dumy != null and _builder != null:
		_builder.set_static_text(dumy, "")

## **The Purpose value, right-aligned and clipped on its LEFT** (round 718).
## The user, 2026-10-04: "in the purpose tab the original game has the text
## aligned to the right and then hides the left of the text that would
## overflow ... let's replicate it for now". The combo's own drawing code
## was not read: this is the user's description of the original, labelled
## so. A Godot Button clips a too-long text on its right (TextLine "Clip
## right"), so the OptionButton keeps the clicks and the list and draws no
## text; the value is a Label inside a clipping box over the combo's READ
## text rect ({5, 0, W-30, H}, OptionVideoPage.combo_text_rect), placed with
## its right edge on the box's: a wider text starts left of the box and its
## left part is cut. Vertically centred, as the combo's value was.
var _combo_clip: Control = null
var _combo_label: Label = null

func _build_combo_text(host: Control) -> void:
	for c in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color", "font_disabled_color"]:
		_combo.add_theme_color_override(c, Color(0, 0, 0, 0))
	_combo_clip = Control.new()
	_combo_clip.name = "PurposeText"
	_combo_clip.clip_contents = true
	_combo_clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var r := OptionVideoPage.combo_text_rect(host.size)
	_combo_clip.position = r.position
	_combo_clip.size = r.size
	_combo_label = Label.new()
	_combo_label.name = "Value"
	_combo_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_combo_label.clip_text = false
	var font := _builder.font_at(0) if _builder != null else null
	if font != null:
		_combo_label.add_theme_font_override("font", font)
	_combo_label.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[0])
	_combo_label.add_theme_color_override("font_color", Color.WHITE)
	UiBuilder.crisp_text(_combo_label)
	_combo_clip.add_child(_combo_label)
	host.add_child(_combo_clip)
	_combo.item_selected.connect(func(_i: int) -> void: _update_combo_text())
	_update_combo_text()

func _update_combo_text() -> void:
	if _combo == null or _combo_label == null:
		return
	_combo_label.text = _combo.get_item_text(_combo.selected) if _combo.selected >= 0 else ""
	var need := _combo_label.get_combined_minimum_size()
	_combo_label.size = need
	_combo_label.position = Vector2(_combo_clip.size.x - need.x, floorf((_combo_clip.size.y - need.y) * 0.5))

## The Purpose value's text as drawn, and how many pixels of it the clipping
## box hides on its left (tests).
func combo_text_overflow() -> float:
	if _combo_label == null or _combo_clip == null:
		return 0.0
	return maxf(0.0, -_combo_label.position.x)

func _build_scroll() -> void:
	var host_scroll := node("GDR_PARTYMATCH_SCROLL")
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
	var map := {BTN_JOIN: press_join, BTN_WHISPER: press_whisper, BTN_AUTO: press_auto, BTN_FORM: press_form,
		BTN_CHANGE: press_change, BTN_DELETE: press_delete, BTN_SEARCH: press_search, BTN_REFRESH: press_refresh}
	for n in map:
		var b := node(n) as BaseButton
		if b != null:
			b.pressed.connect(map[n])
	var spin := node("GDR_PARTYMATCH_SPIN_PAGE")
	if spin != null and spin.has_user_signal("spin_changed"):
		spin.connect("spin_changed", func(v: int) -> void: state.request_page(v))
	var list := node("GDR_PARTYMATCH_SLOTLIST_BLACKSQUARE")
	if list != null:
		list.gui_input.connect(_on_list_input)

func _text(key: String, fallback: String) -> String:
	if _builder == null:
		return fallback
	var t := _builder.resolve_text(key)
	return fallback if t == "" or t == key else t

# --- What the window shows -----------------------------------------------------

func records() -> Array[PartyMatchNet.Row]:
	if _filtered != null:
		return _filtered
	return state.rows

## The rows in the twelve slots: the registration first (pinned), then the
## records from the scroll position.
func shown_rows() -> Array:
	var out: Array = []
	var start := 0
	if state.registration != null:
		out.append(state.registration)
	var recs := records()
	start = clampi(_scroll, 0, scroll_max())
	for i in range(start, recs.size()):
		if out.size() >= ROWS:
			break
		out.append(recs[i])
	return out

func refresh() -> void:
	if window == null:
		return
	var rows := shown_rows()
	# 0x740d30: a slot the fill leaves empty drops the selection.
	if selected_slot >= rows.size():
		selected_slot = -1
	selected_number = (rows[selected_slot] as PartyMatchNet.Row).number if selected_slot >= 0 else 0
	for i in ROWS:
		var slot := _slots[i] if i < _slots.size() else null
		if slot == null:
			continue
		var row: PartyMatchNet.Row = rows[i] if i < rows.size() else null
		_fill_slot(slot, row, row != null and row == state.registration, i == selected_slot)
	if _scroll_bar != null:
		_scroll_bar.call("set_range", scroll_max(), clampi(_scroll, 0, scroll_max()))
	var spin := node("GDR_PARTYMATCH_SPIN_PAGE")
	if spin != null:
		UiBuilder.set_spin_range(spin, 0, maxi(0, state.page_count - 1))
		spin.set_meta("value", clampi(state.page_index, 0, maxi(0, state.page_count - 1)))
		UiBuilder._spin_refresh(spin)
	update_buttons()

func _fill_slot(slot: Control, row: PartyMatchNet.Row, own: bool, selected: bool) -> void:
	var s := slot.get_node_or_null("MatchSlot")
	var sel := s.get_node_or_null("SelectBar") as CanvasItem if s != null else null
	if sel != null:
		sel.visible = selected
		var plain := s.get_node_or_null("GDR_PARTYMATCH_SLOT_SELECT") as CanvasItem
		if plain != null:
			plain.visible = not selected
	if s == null:
		return
	var cols := {
		"GDR_PARTYMATCH_SLOT_ID": "%d" % row.number if row != null else "",
		"GDR_PARTYMATCH_SLOT_RACE": _text(PartyMatchNet.RACE_KEYS[row.race], PartyMatchNet.RACE_FALLBACKS[row.race]) if row != null and row.race in [0, 1] else "",
		"GDR_PARTYMATCH_SLOT_NAME": PartyMatchNet.shown_name(row) if row != null else "",
		"GDR_PARTYMATCH_SLOT_SUBJECT": row.title if row != null else "",
		"GDR_PARTYMATCH_SLOT_OBJECT": _text(PartyMatchNet.PURPOSE_KEYS[row.purpose], PartyMatchNet.PURPOSE_FALLBACKS[row.purpose]) if row != null and row.purpose in [0, 1, 2, 3] else "",
		"GDR_PARTYMATCH_SLOT_NUMBER": "%d/%d" % [row.members, row.cap()] if row != null else "",
		"GDR_PARTYMATCH_SLOT_LEVEL": "%d~%d" % [row.min_level, row.max_level] if row != null else "",
	}
	for n in cols:
		var lbl := _builder.set_static_text(s.get_node_or_null(n) as Control, cols[n]) if _builder != null else null
		if lbl != null:
			lbl.add_theme_color_override("font_color", OWN_ROW_COLOR if own else Color.WHITE)
			if n == "GDR_PARTYMATCH_SLOT_SUBJECT":
				# 0x8b47c0(.., 0x12e, 1): fitted to 302 px with "..." when
				# cut (L"..." at 0xe17a40), READ; the static is 306 wide.
				lbl.clip_text = true
				lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
				lbl.custom_minimum_size.x = 0
				lbl.size.x = 302
	var mark := s.get_node_or_null("GDR_PARTYMATCH_SLOT_MARK") as Control
	if mark != null:
		var icon := mark.get_node_or_null("TypeIcon") as TextureRect
		if icon == null:
			icon = TextureRect.new()
			icon.name = "TypeIcon"
			icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			icon.size = Vector2(16, 16)
			icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
			mark.add_child(icon)
		icon.texture = null if row == null or _builder == null else _builder.load_texture(
			TYPE_ART_SHARED if row.flags & PartyNet.FLAG_EXP_SHARE else TYPE_ART_EACH)

# --- Enable rules (0x7384a0) ---------------------------------------------------

func _in_party() -> bool:
	return party != null and party.in_party

func _level() -> int:
	return int(own_level.call()) if own_level.is_valid() else 0

func _own_name() -> String:
	return String(own_name.call()) if own_name.is_valid() else ""

func _job() -> int:
	return int(own_job.call()) if own_job.is_valid() else PartyNet.JOB_NONE

func has_records() -> bool:
	return not records().is_empty()

## The registration is the player's own (Change / Delete): its name is the
## player's.
func owns_registration() -> bool:
	return state.registration != null and state.registration.leader_name == _own_name()

func enabled(control_name: String) -> bool:
	if _progress_up and control_name in PROGRESS_DISABLES:
		return false
	if state.auto_running and control_name in AUTO_DISABLES:
		return false
	match control_name:
		BTN_JOIN, BTN_AUTO:
			return state.registration == null and not _in_party() and _level() >= 1 and has_records()
		BTN_WHISPER:
			return has_records()
		BTN_FORM:
			if state.registration != null:
				return false
			if not _in_party():
				return _level() >= 5
			return party.is_leader() and not party.is_full()
		BTN_CHANGE, BTN_DELETE:
			return owns_registration()
		BTN_REFRESH:
			return refresh_locked_ms <= 0
	return true

func update_buttons() -> void:
	# 0x7384a0's tail re-arms timer 10 for 2000 ms (0x7386a4): a Refresh lock
	# that is running restarts with every rules pass (READ).
	if refresh_locked_ms > 0:
		refresh_locked_ms = REFRESH_COOLDOWN_MS
	_apply_buttons()

func _apply_buttons() -> void:
	for n in [BTN_JOIN, BTN_WHISPER, BTN_AUTO, BTN_FORM, BTN_CHANGE, BTN_DELETE, BTN_SEARCH, BTN_REFRESH]:
		var b := node(n) as BaseButton
		if b != null:
			b.disabled = not enabled(n)

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

## A click (0x73aab0): the old slot's bar off, then the clicked slot
## selected if it holds data; an empty slot leaves nothing selected.
func select_slot(i: int) -> void:
	var rows := shown_rows()
	selected_slot = i if i >= 0 and i < rows.size() else -1
	refresh()

func selected_row() -> PartyMatchNet.Row:
	var rows := shown_rows()
	if selected_slot < 0 or selected_slot >= rows.size():
		return null
	return rows[selected_slot]

## The scroll range: the records less 12, the pinned row or not (READ, see
## the header).
func scroll_max() -> int:
	return maxi(0, records().size() - ROWS)

func scroll_by(step: int) -> void:
	_scroll = clampi(_scroll + step, 0, scroll_max())
	refresh()

# --- Buttons -------------------------------------------------------------------

## Join party (0x739500): the selected record's join request, then the
## progress window with (own name, the leader's name), `*` for a job party.
func press_join() -> void:
	var row := selected_row()
	if row == null or row == state.registration or not enabled(BTN_JOIN):
		return
	state.join(row.number)
	var star := "*" if row.purpose == PartyMatchNet.PURPOSE_TRADE or row.purpose == PartyMatchNet.PURPOSE_THIEF else ""
	open_progress(star + _own_name(), star + row.leader_name)

## Whisper (0x7386e0): to the selected party's name, not the player's own.
func press_whisper() -> void:
	var row := selected_row()
	if row == null or row.leader_name == _own_name():
		return
	if state.registration != null and row.number == state.registration.number:
		return
	whisper_requested.emit(row.leader_name)

func press_auto() -> void:
	if not enabled(BTN_AUTO):
		return
	_close_box(auto_box)
	auto_box = PartyMatchAuto.new()
	if not auto_box.build(_builder, _job(), party):
		auto_box.queue_free()
		auto_box = null
		return
	auto_box.submitted.connect(_on_auto_submitted)
	_place_box(auto_box)

## 0x73ebc0: candidates from the held records, up to 10, tried in turn.
func _on_auto_submitted(purpose: int, race_choice: int, flags: int) -> void:
	var picked: Array[int] = []
	for r in records():
		if PartyMatchNet.auto_candidate(r, purpose, race_choice, flags, _level()):
			picked.append(r.number)
	if state.start_auto(picked):
		notice.emit("UIIT_MSG_PARTYMATCH_AUTO_PROGRESS", 0, 4)
		update_buttons()
	else:
		notice.emit("UIIT_MSG_PARTYMATCH_PSEARCH_NORESULT", 0, 4)

## Form party (0x7397b0): the client's own refusals, type 4, else the
## register dialog.
func press_form() -> void:
	if state.registration != null:
		notice.emit("UIIT_MSG_PARTYMATCH_RECORD_ERROR_AGAIN", 0, 4)
		return
	if not _in_party() and _level() < 5:
		notice.emit("UIIT_MSG_PARTYMATCH_JOIN_ERROR_LEVEL", 0, 4)
		return
	if _in_party() and not party.is_leader():
		notice.emit("UIIT_MSG_PARTYMATCH_JOIN_ERROR_PARTY", 0, 4)
		return
	if _in_party() and party.is_full():
		notice.emit("UIIT_MSG_PARTYERR_ALREADY_FULL", 0, 4)
		return
	_open_register(null)

## Change entry (0x739900): the dialog in modify mode, filled from the record.
func press_change() -> void:
	if not owns_registration():
		return
	var e := state.registration_entry
	if e == null:
		e = PartyMatchNet.Entry.new()
		var r := state.registration
		e.number = r.number
		e.flags = r.flags
		e.purpose = r.purpose
		e.min_level = r.min_level
		e.max_level = r.max_level
		e.title = r.title
	_open_register(e)

func _open_register(from_entry: PartyMatchNet.Entry) -> void:
	_close_box(register_box)
	register_box = PartyMatchRegister.new()
	# The settings block's byte; in a party it holds the party's own flags
	# (0x3065 overwrites it, 0x986f60), which the entry must carry (0x2c20).
	var flags := 0
	if from_entry != null:
		flags = from_entry.flags
	elif party != null:
		flags = party.flags_byte()
	if not register_box.build(_builder, flags, _job(), from_entry):
		register_box.queue_free()
		register_box = null
		return
	register_box.submitted.connect(func(e: PartyMatchNet.Entry, modify: bool) -> void:
		if modify:
			state.modify(e)
		else:
			state.register(e)
		register_box = null)
	register_box.refused.connect(func(k: String) -> void: notice.emit(k, 0, 4))
	_place_box(register_box)

## Delete entry (0x738a30 -> 0x738940): the question, then 0x706b.
func press_delete() -> void:
	if not owns_registration():
		return
	_close_box(confirm_box)
	confirm_box = PartyMatchConfirm.new()
	if not confirm_box.build(_builder, _text("UIIT_STT_PARTYMATCH_DELETE_CONFIRM", "Delete this party?")):
		confirm_box.queue_free()
		confirm_box = null
		return
	var number := state.registration.number
	confirm_box.confirmed.connect(func() -> void: state.delete_entry(number))
	_place_box(confirm_box)

func search_filter() -> Array[PartyMatchNet.Row]:
	var name_edit := node("GDR_PARTYMATCH_SEARCH_NAME_EDIT") as LineEdit
	var lo_edit := node("GDR_PARTYMATCH_SEARCH_MIN_LEVEL_EDIT") as LineEdit
	var hi_edit := node("GDR_PARTYMATCH_SEARCH_MAX_LEVEL_EDIT") as LineEdit
	var name := name_edit.text if name_edit != null else ""
	var purpose := _combo.get_selected_id() if _combo != null and _combo.selected >= 0 else PartyMatchNet.PURPOSE_ALL
	var lv := search_levels()
	var lo: int = lv[0]
	var hi: int = lv[1]
	var out: Array[PartyMatchNet.Row] = []
	for r in state.rows:
		if PartyMatchNet.row_matches(r, name, purpose, lo, hi):
			out.append(r)
	return out

## 0x73b780's levels: min = atoi, below 2 -> 1; max = atoi, 0 -> 110.
func search_levels() -> Array[int]:
	var lo_edit := node("GDR_PARTYMATCH_SEARCH_MIN_LEVEL_EDIT") as LineEdit
	var hi_edit := node("GDR_PARTYMATCH_SEARCH_MAX_LEVEL_EDIT") as LineEdit
	var lo := _atoi(lo_edit.text) if lo_edit != null else 0
	var hi := _atoi(hi_edit.text) if hi_edit != null else 0
	if lo < 2:
		lo = PartyMatchNet.LEVEL_MIN
	if hi == 0:
		hi = PartyMatchNet.LEVEL_MAX
	return [lo, hi]

static func _atoi(t: String) -> int:
	var digits := ""
	for ch in t.strip_edges():
		if ch < "0" or ch > "9":
			break
		digits += ch
	return int(digits) if digits != "" else 0

## Search (0x73b780): nothing at all when min > max.
func press_search() -> void:
	var lv := search_levels()
	if lv[0] > lv[1]:
		return
	var out := search_filter()
	if out.is_empty():
		notice.emit("UIIT_MSG_PARTYMATCH_PSEARCH_NORESULT", 0, 4)
	_filtered = out
	_scroll = 0
	refresh()

## Refresh (0x732a80): the spin's page, then 2 s disabled.
func press_refresh() -> void:
	if refresh_locked_ms > 0:
		return
	var spin := node("GDR_PARTYMATCH_SPIN_PAGE")
	state.request_page(UiBuilder.spin_value(spin) if spin != null else 0)
	refresh_locked_ms = REFRESH_COOLDOWN_MS
	_apply_buttons()

## Ticks the Refresh cooldown (HudPanels' _process).
func advance(ms: int) -> void:
	if refresh_locked_ms > 0:
		refresh_locked_ms -= ms
		if refresh_locked_ms <= 0:
			refresh_locked_ms = 0
			_apply_buttons()

func on_page() -> void:
	_filtered = null
	_scroll = 0

## A 0x3864 event (round 718): the registration follows the party as
## UI_PARTY::FUN_00886b10 moves it (PartyMatchState.on_party_event).
func _on_party_event(kind: int, jid: int) -> void:
	state.on_party_event(kind, jid != 0 and jid == party.own_jid, party.in_party, party.members.size())

## 0xb06b for another number: the record leaves the displayed list too
## (0x73a700).
func _on_removed(number: int) -> void:
	if _filtered != null:
		for i in (_filtered as Array).size():
			if (_filtered[i] as PartyMatchNet.Row).number == number:
				(_filtered as Array).remove_at(i)
				break
	refresh()

# --- Boxes ---------------------------------------------------------------------

func open_progress(own: String, party_name: String) -> void:
	_close_box(progress_box)
	progress_box = PartyJoinProgress.new()
	if not progress_box.build(_builder, own, party_name):
		progress_box.queue_free()
		progress_box = null
		return
	progress_box.finished.connect(_on_progress_closed)
	_place_box(progress_box)
	_progress_up = true
	_apply_buttons()

## The joining window's close (0x7390b0(0)): its five enabled outright, or,
## with an auto run going, the run's disable (0x738890(1)).
func _on_progress_closed() -> void:
	progress_box = null
	_progress_up = false
	if state.auto_running:
		_apply_buttons()
		return
	for n in PROGRESS_DISABLES:
		var b := node(n) as BaseButton
		if b != null:
			b.disabled = n == BTN_REFRESH and refresh_locked_ms > 0

func _on_join_finished() -> void:
	if progress_box != null and is_instance_valid(progress_box):
		progress_box.finish()
	else:
		# An auto run's join opens no joining window (0x786e70); its end
		# brings the buttons back (0x738890(0)).
		_apply_buttons()

## The leader's popup (S->C 0x706d).
func show_join_request(q: PartyMatchNet.JoinRequest) -> void:
	_close_box(req_join_box)
	req_join_box = PartyMatchReqJoin.new()
	if not req_join_box.build(_builder, q, race_of_model, zone_name, mastery_icon):
		req_join_box.queue_free()
		req_join_box = null
		return
	req_join_box.answered.connect(func(code: int) -> void:
		state.answer(q, code)
		req_join_box = null)
	_place_box(req_join_box)

func _place_box(box: PartyMatchBox) -> void:
	var view: Vector2 = view_size.call() if view_size.is_valid() else Vector2(1024, 768)
	box.centre_on(view)
	if host != null:
		host.add_child(box)

func _close_box(box: PartyMatchBox) -> void:
	if box != null and is_instance_valid(box) and not box.is_queued_for_deletion():
		box.close()

# --- The party -------------------------------------------------------------------

## 0x7387c0: a full party's leader deletes its own registration.
func _on_party_changed() -> void:
	# Its only caller is UI_PARTY 0x886b10's member-joined branch (0x886c79);
	# testing on every party change is equivalent.
	if party != null and party.in_party and party.is_leader() and party.is_full() and owns_registration() \
			and not state.deleted_for_full:
		state.delete_entry(state.registration.number, true)
	update_buttons()
