extends PartyMatchBox
class_name GuildMasterLeaveWindow

## Round 844: CIFGuildMasterLeave, the master's hand-over window
## (GDR_GUILDMASTER_LEAVE, ginterface id 58: 249 x 315 on msgbox2_window_;
## resinfo\ifguildmasterleave.txt, each row resinfo\ifguildmasterleaveslot.txt).
## READ in sro_client.exe:
## - opened by the master's talk line 0x18 (UIIT_CTL_MASTERLEAVE, "Transfer
##   leadership"), title UIIT_STT_MLEAVE_WINDOWS; the list's header 22
##   UIIT_CTL_MLEAVE_SELECT and 23 UIIT_STT_GUILDSMAN (the layout's ListWnd
##   section); seven rows 31..37
##   (CIFBarWnd on com_bar01_), each a check box 10 and a name 11, under a
##   scroll manager 41;
## - OK (11, c:0x70a170): a fortress-war position conflict ->
##   UIIT_MSG_FORT_POSITION_GRANT_FAIL_07 (no fortress war: never); the
##   master's own name -> UIIT_MSG_MLEAVEERR_USERNOTEXIST in the chat; else
##   the confirm box "[%s]" + UIIT_MSG_MLEAVE_CONFIRM, whose OK sends 0x7103
##   {u32 NPC, u32 the member's id} (c:0x6f79c0 case 1 -> c:0x81fe80).
## INFERRED: the rows are every member by name, one check at a time (the
## slot's own handlers were not read); the scroll is the wheel over the rows.

const LAYOUT := "resinfo\\ifguildmasterleave.txt"
const SLOT_LAYOUT := "resinfo\\ifguildmasterleaveslot.txt"
const SIZE := Vector2(249, 315)
const ROWS := ["GDR_GUILDMASTER_LEVAE_LIST_SLOT1", "GDR_GUILDMASTER_LEVAE_LIST_SLOT2", "GDR_GUILDMASTER_LEVAE_LIST_SLOT3",
	"GDR_GUILDMASTER_LEVAE_LIST_SLOT4", "GDR_GUILDMASTER_LEVAE_LIST_SLOT5", "GDR_GUILDMASTER_LEVAE_LIST_SLOT6",
	"GDR_GUILDMASTER_LEVAE_LIST_SLOT7"]
const SLOT_CHECK := "GDR_GUILDMASTER_LEAVE_SLOT_CB_SELECT"
const SLOT_NAME := "GDR_GUILDMASTER_LEAVE_SLOT_NAME"
const BTN_OK := "GDR_GUILDMASTER_LEVAE_BTN_OK"
const BTN_CANCEL := "GDR_GUILDMASTER_LEVAE_BTN_CANCEL"
const CHECK_ART := "interface\\ifcommon\\com_checkbutton02_off.ddj"

## OK on the master's own name (UIIT_MSG_MLEAVEERR_USERNOTEXIST, chat).
signal refused(key: String)
## The confirm box to show for a member: its OK sends 0x7103.
signal confirm_wanted(npc_uid: int, member_id: int, member_name: String)

var npc := 0
var master_name := ""
## [[id, name], ...] by name.
var members: Array = []
var chosen := 0
var first := 0
var _checks: Array[TextureButton] = []
## The ListWnd section (the rows and the header).
var list_root: Control
var _names: Array[Control] = []

func build_master_leave(builder: UiBuilder, npc_uid: int, data: GuildData, own_name: String) -> bool:
	name = "GuildMasterLeave"
	npc = npc_uid
	master_name = own_name
	if not build_shell(builder, SIZE, "UIIT_STT_MLEAVE_WINDOWS", "Leader transfer window", LAYOUT):
		return false
	members.clear()
	if data != null:
		for m in data.members:
			members.append([m.character_id, m.member_name])
	members.sort_custom(func(a: Array, b: Array) -> bool: return String(a[1]) < String(b[1]))
	# The list is the layout's second section, ListWnd (READ: the file's
	# "Section = ListWnd" holds the scroll manager, the seven rows and the
	# header), built over the Create section at the same origin.
	var layout: UiLayoutParser.LayoutDef = builder.load_layout(LAYOUT)
	list_root = builder.build_section(layout, "ListWnd") if layout != null and layout.sections.has("ListWnd") else null
	if list_root != null:
		list_root.name = "ListWnd"
		add_child(list_root)
		UiBuilder.settle_authored_rects(list_root)
		# The scroll manager hosts the rows in the original (CIFScrollManager);
		# here it is an empty control laid over them, so it lets the clicks
		# through to the rows' check boxes (OURS).
		var mgr := list_root.get_node_or_null("GDR_GUILDMASTER_LEVAE_LIST_SCROLLMGR") as Control
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
		row.mouse_filter = Control.MOUSE_FILTER_STOP
		row.gui_input.connect(_wheel)
	fill()
	var ok := button(BTN_OK)
	if ok != null:
		ok.pressed.connect(press_ok)
	var cancel := button(BTN_CANCEL)
	if cancel != null:
		cancel.pressed.connect(close)
	return true

func fill() -> void:
	for i in _checks.size():
		var k := first + i
		var has := k < members.size()
		var cb := _checks[i]
		if cb != null:
			cb.visible = has
			cb.set_pressed_no_signal(has and int(members[k][0]) == chosen)
			var mark := cb.get_node_or_null("GDR_STATIC_SELECTED") as Control
			if mark != null:
				mark.visible = cb.button_pressed
		if _names[i] != null and _builder != null:
			_builder.set_static_text(_names[i], String(members[k][1]) if has else "")

func _on_check(i: int, on: bool) -> void:
	var k := first + i
	if k >= members.size():
		return
	chosen = int(members[k][0]) if on else (0 if chosen == int(members[k][0]) else chosen)
	fill()

func _wheel(e: InputEvent) -> void:
	var mb := e as InputEventMouseButton
	if mb == null or not mb.pressed:
		return
	if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		first = clampi(first + 1, 0, maxi(0, members.size() - ROWS.size()))
		fill()
	elif mb.button_index == MOUSE_BUTTON_WHEEL_UP:
		first = clampi(first - 1, 0, maxi(0, members.size() - ROWS.size()))
		fill()

## Picks a member by name (tests and QA).
func choose_name(who: String) -> void:
	for m in members:
		if String(m[1]) == who:
			chosen = int(m[0])
	fill()

func chosen_name() -> String:
	for m in members:
		if int(m[0]) == chosen:
			return String(m[1])
	return ""

## c:0x70a170.
func press_ok() -> void:
	if chosen == 0:
		return
	var who := chosen_name()
	if who == master_name:
		refused.emit("UIIT_MSG_MLEAVEERR_USERNOTEXIST")
		return
	confirm_wanted.emit(npc, chosen, who)
	close()
