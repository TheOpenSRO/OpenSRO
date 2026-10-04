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
## - while the progress window is up, Join, Auto match, Form party, Change,
##   Delete, Search and Refresh are disabled (0x738890: IDs 0xf, 0x11..0x14,
##   0x37, 0x38) and come back when it closes, unless an auto-match run is
##   going;
## - while the player's party is full and it holds the registration, the
##   client deletes it (0x7387c0; the line is DELETE_COMPLETE2).
##
## OURS: the scroll bar (GDR_PARTYMATCH_SCROLL, a CIFVerticalScroll) is not
## drawn -- the wheel over the list scrolls it a row; the column headers do
## not sort; the row tooltip (0x740750) is not built; a new page clears the
## Search filter (whether 0x73b5b0 re-applies it was not read).

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
const PROGRESS_DISABLES := [BTN_JOIN, BTN_AUTO, BTN_FORM, BTN_CHANGE, BTN_DELETE, BTN_SEARCH, BTN_REFRESH]

## A whisper to that party's leader (0x7386e0).
signal whisper_requested(leader_name: String)
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
## The selected record's entry number, 0 when none.
var selected_number := 0
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
	state.register_done.connect(_close_register)
	state.join_request.connect(show_join_request)
	state.join_finished.connect(_on_join_finished)
	if party != null:
		party.changed.connect(_on_party_changed)

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
	refresh()

## The window was shown: page 0 (0x73b1ff).
func on_shown() -> void:
	state.request_page(0)

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
		# CIFComboBox drawn with the Option window's combo pieces (OURS: the
		# two classes' art is assumed the same, com_blacksquare_ and the
		# arrow, not read for CIFComboBox).
		_combo = OptionVideoPage.new(null, _builder, null)._make_combo(host_combo)
		if _combo != null:
			for i in 5:
				_combo.add_item(_text(PartyMatchNet.PURPOSE_KEYS[i], PartyMatchNet.PURPOSE_FALLBACKS[i]), i)
			_combo.select(PartyMatchNet.PURPOSE_ALL)

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
	start = clampi(_scroll, 0, maxi(0, recs.size() - (ROWS - out.size())))
	for i in range(start, recs.size()):
		if out.size() >= ROWS:
			break
		out.append(recs[i])
	return out

func refresh() -> void:
	if window == null:
		return
	var rows := shown_rows()
	for i in ROWS:
		var slot := _slots[i] if i < _slots.size() else null
		if slot == null:
			continue
		var row: PartyMatchNet.Row = rows[i] if i < rows.size() else null
		_fill_slot(slot, row, row != null and row == state.registration)
	var spin := node("GDR_PARTYMATCH_SPIN_PAGE")
	if spin != null:
		UiBuilder.set_spin_range(spin, 0, maxi(0, state.page_count - 1))
		spin.set_meta("value", clampi(state.page_index, 0, maxi(0, state.page_count - 1)))
		UiBuilder._spin_refresh(spin)
	update_buttons()

func _fill_slot(slot: Control, row: PartyMatchNet.Row, own: bool) -> void:
	var s := slot.get_node_or_null("MatchSlot")
	var sel := s.get_node_or_null("SelectBar") as CanvasItem if s != null else null
	var selected := row != null and row.number == selected_number and selected_number != 0
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
				lbl.clip_text = true
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
	var busy := progress_box != null and is_instance_valid(progress_box)
	if busy and control_name in PROGRESS_DISABLES:
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

## A click on a row with data selects it (0x73aab0); an empty row does not.
func select_slot(i: int) -> void:
	var rows := shown_rows()
	if i < 0 or i >= rows.size():
		return
	selected_number = (rows[i] as PartyMatchNet.Row).number
	refresh()

func selected_row() -> PartyMatchNet.Row:
	if selected_number == 0:
		return null
	if state.registration != null and state.registration.number == selected_number:
		return state.registration
	for r in records():
		if r.number == selected_number:
			return r
	return null

func scroll_by(step: int) -> void:
	var room := ROWS - (1 if state.registration != null else 0)
	_scroll = clampi(_scroll + step, 0, maxi(0, records().size() - room))
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
			state.register(e))
	register_box.refused.connect(func(k: String) -> void: notice.emit(k, 0, 4))
	_place_box(register_box)

func _close_register() -> void:
	_close_box(register_box)
	register_box = null
	refresh()

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
	var lo := int(lo_edit.text) if lo_edit != null and lo_edit.text.is_valid_int() else PartyMatchNet.LEVEL_MIN
	var hi := int(hi_edit.text) if hi_edit != null and hi_edit.text.is_valid_int() else PartyMatchNet.LEVEL_MAX
	var out: Array[PartyMatchNet.Row] = []
	for r in state.rows:
		if PartyMatchNet.row_matches(r, name, purpose, lo, hi):
			out.append(r)
	return out

func press_search() -> void:
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
	update_buttons()

## Ticks the Refresh cooldown (HudPanels' _process).
func advance(ms: int) -> void:
	if refresh_locked_ms > 0:
		refresh_locked_ms -= ms
		if refresh_locked_ms <= 0:
			refresh_locked_ms = 0
			update_buttons()

func on_page() -> void:
	_filtered = null
	_scroll = 0

# --- Boxes ---------------------------------------------------------------------

func open_progress(own: String, party_name: String) -> void:
	_close_box(progress_box)
	progress_box = PartyJoinProgress.new()
	if not progress_box.build(_builder, own, party_name):
		progress_box.queue_free()
		progress_box = null
		return
	progress_box.finished.connect(func() -> void:
		progress_box = null
		update_buttons())
	_place_box(progress_box)
	update_buttons()

func _on_join_finished() -> void:
	if progress_box != null and is_instance_valid(progress_box):
		progress_box.finish()
	progress_box = null
	update_buttons()

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
	if party != null and party.in_party and party.is_leader() and party.is_full() and owns_registration() \
			and not state.deleted_for_full:
		state.delete_entry(state.registration.number, true)
	update_buttons()
