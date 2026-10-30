extends RefCounted
class_name UnionPane

## Round 844 (lane U): the guild window's union pane, CNIFAllianceGuild --
## guild_r.2dt's record 86 under the relations pane 164, shown by the
## Relations tab (73) with its Union sub-tab (87) checked -- as sro_client.exe
## runs it. Every fact is READ from the client unless it says otherwise.
##
## **The parts** (OnCreate 0x57dd10): +0x78c 158 the lead guild's name,
## +0x790 149 its master's race mark, +0x794 179 its master's name, +0x798
## 151 the guild count, +0x79c 155 the selected guild's name, +0x7a0 162 its
## master's race mark, +0x7a4 148 its master's name, +0x7a8 160 its members,
## +0x7ac 56 the Name header, +0x7b0 60 the Lv header, +0x7b4 51 Apply,
## +0x7b8 52 Secede, +0x7bc 53 Expel, +0x7c0 61 the scroll bar. The ten
## rows are CNIFAllianceSlot (271..307): 127 the name, 128 the level, 131 the
## mark (a union holds at most eight guilds, so the scroll never moves).
##
## **The refresh** (0x57c6f0, with the selected guild): in a union (the
## union map's size, 0x988a50) 175..178 and the four upper parts are shown
## and 137 ("Not in the alliance") hidden; the lead guild's entry (the one
## whose id is the record's +0x240, 0x996ed0 -- 0x3102's third u32) gives
## 158 its name, 179 its master and 149 the race of its master's model
## (entry +0x40 -> 0x93f370 -> +0x9c -> 0x98caa0); 151 reads "%d/%d" with
## the union's size and 8. Out of one, all hidden and 137 shown. Then the
## buttons (0x57bfc0), then the selected guild: with one, 156 / 153 / 159 /
## 161 and the four lower parts shown and 136 ("No guild is selected.")
## hidden -- 155 its name, 162 its master's race, 148 its master, 160 "%d/%d"
## its members (the entry's last byte) over its level's cap (0xd8c434: 15,
## 20, 25, 35, 50); without one, all hidden and 136 shown.
##
## **The buttons** (0x57bfc0): all three disabled; for a guild master
## (0x989ce0: the own name against the guild's master) Apply enabled; in a
## union whose lead guild's master is the player, Secede and Expel too;
## for another union guild's master, Apply disabled again and Secede
## enabled. The dispatcher (0x57d060): Apply sends 0x70FB for the selected
## object at once (0x8201b0); Secede asks UIIT_MSG_GUILD_QUESTION_ALLY_EXIT
## under UIIT_STT_GUILD_RESPECT_ALLY_EXIT, Expel (a guild selected) asks
## UIIT_MSG_QUESTION_GUILD_RESPECT_ALLY_EXPEL with its name under
## UIIT_STT_GUILD_RESPECT_ALLY_EXPULSION (0x57ce70: GInterface 0x788270,
## style 1 Yes / No, one box at a time, +0x7cc); Yes sends 0x70FC or 0x70FD
## with "ban_guild_id" (0x57ac10).
##
## **The rows** (0x5804a0 -> 0x57fff0 -> 0x57e6f0 -> 0x57d0a0): the union's
## guild ids, ordered by the sort mode +0x7c8 -- 2 at construction (0x57f8a9),
## the union map's own order (ascending ids); 0 by name after the Name header
## (56), 1 by level after the Lv header (60; the multimap is walked from its
## end, so the highest first -- INFERRED from the walk) -- each row filled:
## the name and "Lv %d" (UIIT_STT_LV_LEVEL) in 0xffffb451 for the lead guild
## (its id against +0x240, 0x987110) and white for the rest, the mark shown;
## an empty row hides all three. A left press on a filled row (0x57e820, 0x201)
## selects its guild (0x57e680): every row's bar follows (com_bar01select_ for
## it, com_bar01_ for the rest, 0x57d240) and the refresh runs with it.
##
## **When it runs**: its ShowWindow(1) (vslot 23, 0x580600: the rows and the
## refresh with the selection kept); 0x3102 (0x87fd00), 0x38F5 0x0d
## (0x580650) and 0x12 (0x580630 / 0x580720): the rows and the refresh with
## no guild (0x57c6f0(0) -- the selection +0x7c4 is kept, only the lower
## parts empty).

const ID_PANE := 86
const ID_RELATIONS := 164
const ID_UNION_TAB := 87

const LEAD_NAME := 158
const LEAD_RACE := 149
const LEAD_MASTER := 179
const COUNT := 151
const SEL_NAME := 155
const SEL_RACE := 162
const SEL_MASTER := 148
const SEL_MEMBERS := 160
const HEAD_NAME := 56
const HEAD_LEVEL := 60
const APPLY := 51
const SECEDE := 52
const EXPEL := 53
## 175..178: the upper labels and the union's mark; 137 "Not in the alliance".
const UPPER := [175, 176, 177, 178]
const NO_UNION := 137
## 156, 153, 159, 161: the lower labels and the guild's mark; 136 "No guild is
## selected."
const LOWER := [156, 153, 159, 161]
const NO_SELECTION := 136
const ROW_CLASS := "CNIFAllianceSlot"
const ROW_NAME := 127
const ROW_LEVEL := 128
const ROW_MARK := 131
const LEAD_COLOUR := 0xffffb451
const OTHER_COLOUR := 0xffffffff
const MAX_GUILDS := 8
const COUNT_FORMAT := "%d/%d"
const MEMBER_CAPS := [15, 20, 25, 35, 50]
const SORT_NAME := 0
const SORT_LEVEL := 1
const SORT_MAP := 2

## Apply (51): the owner sends 0x70FB for the selected object.
signal request_pressed
## Secede's Yes (0x70FC) and Expel's Yes (0x70FD with the guild).
signal leave_confirmed
signal expel_confirmed(guild_id: int)

var window: GuildWindow
## +0x7c4, the selected guild's id (0 none).
var selected := 0
## +0x7c8.
var sort_mode := SORT_MAP
## +0x7cc's box (one question at a time).
var _box: Control

func _init(w: GuildWindow) -> void:
	window = w
	var head_name := _part(HEAD_NAME) as BaseButton
	if head_name != null:
		head_name.pressed.connect(func() -> void: set_sort(SORT_NAME))
	var head_level := _part(HEAD_LEVEL) as BaseButton
	if head_level != null:
		head_level.pressed.connect(func() -> void: set_sort(SORT_LEVEL))
	var apply := _part(APPLY) as BaseButton
	if apply != null:
		apply.pressed.connect(func() -> void: request_pressed.emit())
	var secede := _part(SECEDE) as BaseButton
	if secede != null:
		secede.pressed.connect(open_leave_question)
	var expel := _part(EXPEL) as BaseButton
	if expel != null:
		expel.pressed.connect(open_expel_question)
	for row in rows():
		row.mouse_filter = Control.MOUSE_FILTER_STOP
		row.gui_input.connect(_on_row_input.bind(row))
	var p := pane()
	if p != null:
		# vslot 23: its ShowWindow(1) -- the Union sub-tab's check, or the
		# relations pane coming up with it checked.
		p.visibility_changed.connect(func() -> void:
			if p.is_visible_in_tree():
				on_shown())
	var rel := window.control([ID_RELATIONS])
	if rel != null:
		rel.visibility_changed.connect(func() -> void:
			if p != null and p.is_visible_in_tree():
				on_shown())

func pane() -> Control:
	return window.control([ID_RELATIONS, ID_PANE])

func _part(id: int) -> Control:
	return window.control([ID_RELATIONS, ID_PANE, id])

func _union() -> UnionData:
	return window.data.union if window.data != null else null

## The rows, top to bottom.
func rows() -> Array[Control]:
	var out: Array[Control] = []
	var p := pane()
	if p == null:
		return out
	for c in p.get_children():
		if c is Control and str(c.get_meta(TwoDtBuilder.META_CLASS, "")) == ROW_CLASS:
			out.append(c)
	out.sort_custom(func(a: Control, b: Control) -> bool: return a.position.y < b.position.y)
	return out

## vslot 23 (0x580600): the rows, then the refresh with the selection.
func on_shown() -> void:
	fill_rows()
	refresh(selected)

## 0x3102 / 0x38F5 0x0d / 0x12: the rows, then the refresh with none.
func on_union_changed() -> void:
	var un := _union()
	if un != null and selected != 0 and not un.guilds.has(selected):
		# OURS: a guild gone from the union takes the selection with it (the
		# original keeps the stale id in +0x7c4).
		selected = 0
	fill_rows()
	refresh(0)

## The header buttons (0x580470): the order, then the rows.
func set_sort(mode: int) -> void:
	sort_mode = mode
	fill_rows()

## The ids in the rows' order (0x57fff0).
func ordered_ids() -> Array:
	var un := _union()
	if un == null:
		return []
	var ids: Array = un.guilds.keys()
	ids.sort()
	match sort_mode:
		SORT_NAME:
			ids.sort_custom(func(a: int, b: int) -> bool:
				return (un.guilds[a] as UnionData.Entry).guild_name < (un.guilds[b] as UnionData.Entry).guild_name)
		SORT_LEVEL:
			ids.sort_custom(func(a: int, b: int) -> bool:
				return (un.guilds[a] as UnionData.Entry).level > (un.guilds[b] as UnionData.Entry).level)
	return ids

## 0x57e6f0 -> 0x57d0a0 for each row.
func fill_rows() -> void:
	var ids := ordered_ids()
	var list := rows()
	for i in list.size():
		_fill_row(list[i], int(ids[i]) if i < ids.size() else 0)

func _fill_row(row: Control, id: int) -> void:
	row.set_meta("union_guild", id)
	var name_node := TwoDtBuilder.child(row, ROW_NAME)
	var level_node := TwoDtBuilder.child(row, ROW_LEVEL)
	var mark := TwoDtBuilder.child(row, ROW_MARK)
	var un := _union()
	var e: UnionData.Entry = un.guilds.get(id) if un != null and id != 0 else null
	window._mark_row(row, e != null and id == selected)
	if e == null:
		for c in [name_node, level_node, mark]:
			if c != null:
				c.visible = false
		return
	var colour := LEAD_COLOUR if id == un.leader_guild_id else OTHER_COLOUR
	var fmt := window._builder.resolve_text("UIIT_STT_LV_LEVEL")
	if fmt == "" or fmt == "UIIT_STT_LV_LEVEL":
		fmt = "Lv %d"
	for pair in [[name_node, e.guild_name], [level_node, fmt.replace("%d", str(e.level))]]:
		var c: Control = pair[0]
		if c == null:
			continue
		var label := window._twodt.set_text(c, str(pair[1]))
		if label != null:
			label.add_theme_color_override("font_color", TwoDtBuilder.argb(colour))
		c.visible = true
	if mark != null:
		mark.visible = true

## 0x57e820 -> 0x57e680: a left press on a filled row selects its guild.
func _on_row_input(event: InputEvent, row: Control) -> void:
	var mb := event as InputEventMouseButton
	if mb == null or not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	var id := int(row.get_meta("union_guild", 0))
	if id != 0:
		select(id)

func select(id: int) -> void:
	if id == selected:
		return
	for row in rows():
		window._mark_row(row, id != 0 and int(row.get_meta("union_guild", 0)) == id)
	selected = id
	refresh(id)

func _show_ids(ids: Array, shown: bool) -> void:
	for id in ids:
		var c := _part(int(id))
		if c != null:
			c.visible = shown

func _text(id: int, text: String) -> void:
	var c := _part(id)
	if c != null:
		window._twodt.set_text(c, text)

## 0x57c6f0 with the guild `sel` (0: none).
func refresh(sel: int) -> void:
	var un := _union()
	var in_union := un != null and un.in_union()
	_show_ids(UPPER + [LEAD_NAME, LEAD_RACE, LEAD_MASTER, COUNT], in_union)
	_show_ids([NO_UNION], not in_union)
	if in_union:
		var lead: UnionData.Entry = un.guilds.get(un.leader_guild_id)
		if lead != null:
			window._set_art(_part(LEAD_RACE), window._race_art(lead.master_model))
			_text(LEAD_NAME, lead.guild_name)
			_text(LEAD_MASTER, lead.master)
			_text(COUNT, COUNT_FORMAT % [un.guilds.size(), MAX_GUILDS])
	buttons()
	var e: UnionData.Entry = un.guilds.get(sel) if in_union and sel != 0 else null
	var shown := e != null
	_show_ids(LOWER + [SEL_NAME, SEL_RACE, SEL_MASTER, SEL_MEMBERS], shown)
	_show_ids([NO_SELECTION], not shown)
	if shown:
		_text(SEL_NAME, e.guild_name)
		window._set_art(_part(SEL_RACE), window._race_art(e.master_model))
		_text(SEL_MASTER, e.master)
		var cap: int = MEMBER_CAPS[clampi(e.level, 1, 5) - 1]
		_text(SEL_MEMBERS, COUNT_FORMAT % [e.members, cap])

## Whether the player masters their guild (0x989ce0).
func _is_master() -> bool:
	var d := window.data
	if d == null or not d.in_guild:
		return false
	var m := d.master()
	return m != null and m.member_name == window._me()

## 0x57bfc0.
func buttons() -> void:
	var apply := _part(APPLY) as BaseButton
	var secede := _part(SECEDE) as BaseButton
	var expel := _part(EXPEL) as BaseButton
	for b in [apply, secede, expel]:
		if b != null:
			b.disabled = true
	if not _is_master():
		return
	if apply != null:
		apply.disabled = false
	var un := _union()
	if un == null or not un.in_union():
		return
	var lead: UnionData.Entry = un.guilds.get(un.leader_guild_id)
	if lead == null:
		return
	if lead.master == window._me():
		if secede != null:
			secede.disabled = false
		if expel != null:
			expel.disabled = false
	else:
		if apply != null:
			apply.disabled = true
		if secede != null:
			secede.disabled = false

## 0x57ce70(1): Secede's question.
func open_leave_question() -> void:
	_question("UIIT_STT_GUILD_RESPECT_ALLY_EXIT", _resolved("UIIT_MSG_GUILD_QUESTION_ALLY_EXIT"),
		func() -> void: leave_confirmed.emit(), "UnionLeaveConfirm")

## 0x57ce70(2): Expel's question, with a guild selected.
func open_expel_question() -> void:
	var un := _union()
	if selected == 0 or un == null or not un.guilds.has(selected):
		return
	var e: UnionData.Entry = un.guilds[selected]
	var fmt := _resolved("UIIT_MSG_QUESTION_GUILD_RESPECT_ALLY_EXPEL")
	var msg := fmt.replace("%s", e.guild_name) if fmt.count("%s") == 1 else fmt
	var id := selected
	_question("UIIT_STT_GUILD_RESPECT_ALLY_EXPULSION", msg, func() -> void: expel_confirmed.emit(id), "UnionExpelConfirm")

func _resolved(key: String) -> String:
	var t := window._builder.resolve_text(key) if window._builder != null else ""
	return t if t != "" else key

## GInterface 0x788270: MsgBoxSimple at 360 x 151, style 1 (Yes / No), the
## caption the key's; one at a time (+0x7cc).
func _question(caption_key: String, message: String, yes: Callable, box_name: String) -> void:
	if is_instance_valid(_box):
		return
	var box := PartyMatchConfirm.new()
	if not box.build(window._builder, message):
		box.free()
		return
	box.name = box_name
	if box.caption != null:
		box.caption.text = box.text(caption_key, caption_key)
	box.confirmed.connect(yes)
	var host: Node = window.get_parent() if window.get_parent() != null else window
	host.add_child(box)
	box.centre_on(window.get_viewport_rect().size)
	_box = box
