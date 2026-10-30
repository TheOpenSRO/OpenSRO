extends PartyMatchBox
class_name GuildElectionWindow

## Round 844 lane G (part 2): CIFGuildMasterElection, the master-release
## vote's window (GDR_GUILDMASTER_ELECTION, ginterface id 57: 274 x 315 on
## msgbox2_window_; resinfo\ifguildmasterelection.txt with its ListWnd
## section, each row resinfo\ifguildmasterelectionslot.txt). READ
## (c:0x708d50, 0x709990, 0x709600, 0x708310):
## - title UIIT_CTL_MRELEASE_PROGRESSWINDOW; headers 22 (the check column),
##   23 UIIT_STT_GUILDSMAN, 24 UIIT_STT_MRELEASE_VOTERS; seven rows 31..37,
##   each a check 10, the member's name 11 (by character id from the guild
##   record) and the votes 12 ("%d");
## - 13 UIIT_STT_REMAIN_TIME and 14 "%d%s" (ms / 60000, truncated, and
##   PARAM_MINUTE);
## - the checks are radio buttons; OK (11) is enabled only with one checked
##   and sends 0x7107 {NPC, vote, index}, then closes; Cancel (12) closes.
## OURS: the rows scroll by the wheel (the scroll manager 41 is not built).

const LAYOUT := "resinfo\\ifguildmasterelection.txt"
const SLOT_LAYOUT := "resinfo\\ifguildmasterelectionslot.txt"
const SIZE := Vector2(274, 315)
const ROWS := ["GDR_GUILDMASTER_ELECTION_LIST_SLOT1", "GDR_GUILDMASTER_ELECTION_LIST_SLOT2", "GDR_GUILDMASTER_ELECTION_LIST_SLOT3",
	"GDR_GUILDMASTER_ELECTION_LIST_SLOT4", "GDR_GUILDMASTER_ELECTION_LIST_SLOT5", "GDR_GUILDMASTER_ELECTION_LIST_SLOT6",
	"GDR_GUILDMASTER_ELECTION_LIST_SLOT7"]
const SLOT_CHECK := "GDR_GUILDMASTER_ELECTION_SLOT_CB_VOTE"
const SLOT_NAME := "GDR_GUILDMASTER_ELECTION_SLOT_NAME"
const SLOT_SCORE := "GDR_GUILDMASTER_ELECTION_SLOT_SCORE"
const TIME := "GDR_GUILDMASTER_ELECTION_REMAIN_TIME"
const BTN_OK := "GDR_GUILDMASTER_ELECTION_BTN_OK"
const BTN_CANCEL := "GDR_GUILDMASTER_ELECTION_BTN_CANCEL"
const CHECK_ART := "interface\\ifcommon\\com_checkbutton02_off.ddj"

## OK: the owner sends 0x7107.
signal voted(npc_uid: int, vote: int, index: int)

var npc := 0
var vote := 0
var state: GuildPart2Net
var names := Callable()
var chosen := -1
var first := 0
var list_root: Control
var _checks: Array[TextureButton] = []
var _names: Array[Control] = []
var _scores: Array[Control] = []

func build_election(builder: UiBuilder, npc_uid: int, votes: GuildPart2Net, name_of: Callable) -> bool:
	name = "GuildElection"
	npc = npc_uid
	state = votes
	vote = votes.vote_id
	names = name_of
	if not build_shell(builder, SIZE, "UIIT_CTL_MRELEASE_PROGRESSWINDOW", "Participated in selection of leader", LAYOUT):
		return false
	var layout: UiLayoutParser.LayoutDef = builder.load_layout(LAYOUT)
	list_root = builder.build_section(layout, "ListWnd") if layout != null and layout.sections.has("ListWnd") else null
	if list_root != null:
		list_root.name = "ListWnd"
		add_child(list_root)
		UiBuilder.settle_authored_rects(list_root)
		var mgr := list_root.get_node_or_null("GDR_GUILDMASTER_ELECTION_LIST_SCROLLMGR") as Control
		if mgr != null:
			mgr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var slot_layout: UiLayoutParser.LayoutDef = builder.load_layout(SLOT_LAYOUT)
	for row_name in ROWS:
		var row := list_root.get_node_or_null(row_name) as Control if list_root != null else null
		if row == null or slot_layout == null:
			continue
		var built := builder.build_section(slot_layout, "Create")
		if built == null:
			continue
		built.name = "Slot"
		row.add_child(built)
		UiBuilder.settle_authored_rects(built)
		var holder := built.get_node_or_null(SLOT_CHECK) as Control
		var cb: TextureButton = builder.make_checkbox(holder, CHECK_ART, false) if holder != null else null
		var i := _checks.size()
		if cb != null:
			cb.toggled.connect(func(on: bool) -> void: _on_check(i, on))
		_checks.append(cb)
		_names.append(built.get_node_or_null(SLOT_NAME) as Control)
		_scores.append(built.get_node_or_null(SLOT_SCORE) as Control)
		row.mouse_filter = Control.MOUSE_FILTER_STOP
		row.gui_input.connect(_wheel)
	var ok := button(BTN_OK)
	if ok != null:
		ok.pressed.connect(press_ok)
	var cancel := button(BTN_CANCEL)
	if cancel != null:
		cancel.pressed.connect(close)
	fill()
	return true

func fill() -> void:
	var list := state.vote_list if state != null else []
	for i in _checks.size():
		var k := first + i
		var has := k < list.size()
		var cb := _checks[i]
		if cb != null:
			cb.visible = has
			cb.set_pressed_no_signal(has and k == chosen)
			var mark := cb.get_node_or_null("GDR_STATIC_SELECTED") as Control
			if mark != null:
				mark.visible = cb.button_pressed
		if _builder != null:
			if _names[i] != null:
				_builder.set_static_text(_names[i], String(names.call(int(list[k]))) if has and names.is_valid() else "")
			if _scores[i] != null:
				_builder.set_static_text(_scores[i], "%d" % int(state.vote_counts[k]) if has else "")
	var minute := text("PARAM_MINUTE", "Minute")
	set_static(TIME, "%d%s" % [int(state.vote_ms / 60000) if state != null else 0, minute])
	var ok := button(BTN_OK)
	if ok != null:
		ok.disabled = chosen < 0

func _on_check(i: int, on: bool) -> void:
	var k := first + i
	chosen = k if on else (-1 if chosen == k else chosen)
	fill()

func _wheel(e: InputEvent) -> void:
	var mb := e as InputEventMouseButton
	if mb == null or not mb.pressed or state == null:
		return
	var top := maxi(0, state.vote_list.size() - ROWS.size())
	if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		first = clampi(first + 1, 0, top)
	elif mb.button_index == MOUSE_BUTTON_WHEEL_UP:
		first = clampi(first - 1, 0, top)
	fill()

## Picks the index-th candidate (tests and QA).
func choose_candidate(index: int) -> void:
	chosen = index
	fill()

func press_ok() -> void:
	if chosen < 0:
		return
	voted.emit(npc, vote, chosen)
	close()
