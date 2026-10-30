extends RefCounted
class_name GuildWarPanes

## Round 844 (lane V): the guild window's two war panes, filled from the
## hostile map (HostileData). READ in sro_client.exe, MEASURED in
## res_ui\guild_r.2dt / guild_w.2dt (docs/protocol/guild_war.md):
##
## - **Hostility** (tab 73 "Guild rel." -> sub-tab 88, CNIFHostileGuild 2000
##   in pane 164): ten CNIFHostileSlot rows (225 .. 267), each 127 the
##   hostile guild's name, 128 the literal "-" (0xd81ea0: no level in the
##   data) and 131 its crest (row fill 0x5bd740; an empty row's parts hidden
##   and its bar com_bar01_Left); a press on a row selects its war (0x5bdd40
##   -> 0x5bcb80): 156 / 153 / 159 / 161 / 155 / 148 / 160 shown, 135 hidden,
##   155 the name, 148 and 160 UIIT_CTL_GUILD_DONOTKNOW (the leader and the
##   count are never known); with none the reverse. Buttons (0x5bca80): 52
##   "Request to start the war" for the master only (own name == the guild
##   master's), 53 "Request to end the war" for the master with a war and no
##   end countdown running.
## - **Combat** (tab 74, CNIFGuildWar 548): seven CNIFGuildWarSlot rows (518
##   the name), the shown war (the selected row, else the first) in 541 the
##   name, 542 the own points, 543 theirs, 544 the victory points or
##   "Unlimited", 545 the wager "%s %s" (grouped, UIIT_STT_GOLD), 546 the time
##   left "%0.2d : %0.2d : %0.2d" or "Unlimited" (0x5af160); none -> those
##   hidden and 62 "<No hostile Guild>". The contribution rows (250, 506, 510,
##   514: 503 the member, 504 the rank, 505 the points) read the members'
##   contribution; their order and the rank's text are OPEN (OURS: by points,
##   highest first, ranked "%d").

const ID_HOSTILE := 2000
const HOSTILE_PATH := [164, 2000]
const ID_WAR := 548
const HOSTILE_ROWS := [225, 231, 235, 239, 243, 247, 255, 259, 263, 267]
const ROW_NAME := 127
const ROW_LEVEL := 128
const ROW_CREST := 131
const DETAIL_SHOWN := [156, 153, 159, 161, 155, 148, 160]
const DETAIL_NAME := 155
const DETAIL_LEADER := 148
const DETAIL_COUNT := 160
const DETAIL_CREST := 161
const DETAIL_NONE := 135
const BUTTON_DECLARE := 52
const BUTTON_END := 53
const WAR_ROWS := [257, 522, 524, 526, 530, 528, 532]
const WAR_ROW_NAME := 518
const WAR_LABELS := [534, 535, 536, 537, 538, 539, 540]
const WAR_VALUES := [541, 542, 543, 544, 545, 546]
const WAR_NONE := 62
const CONTRIB_ROWS := [250, 506, 510, 514]
const CONTRIB_NAME := 503
const CONTRIB_RANK := 504
const CONTRIB_POINTS := 505
const BAR_EMPTY := "interface\\ifcommon\\com_bar01_Left.ddj"
const BAR_FULL := "interface\\ifcommon\\com_bar01_right.ddj"

var w: GuildWindow
## The hostile pane's selected war (+0x7b8), 0 none.
var selected := 0
## The combat pane's shown war (+0x78c), 0 the first.
var shown := 0

## A guild's crest texture by name (the owner gives the crest cache's).
var crest_for: Callable

signal declare_pressed()
signal end_pressed(war_id: int)

func _init(window: GuildWindow) -> void:
	w = window
	var declare := _h(BUTTON_DECLARE) as BaseButton
	if declare != null:
		declare.pressed.connect(func() -> void: declare_pressed.emit())
	var end := _h(BUTTON_END) as BaseButton
	if end != null:
		end.pressed.connect(func() -> void:
			if selected != 0:
				end_pressed.emit(selected))
	for id in HOSTILE_ROWS:
		var row := _h(int(id))
		if row != null:
			row.mouse_filter = Control.MOUSE_FILTER_STOP
			row.gui_input.connect(_on_row.bind(row, false))
	for id in WAR_ROWS:
		var row := w.control([ID_WAR, int(id)])
		if row != null:
			row.mouse_filter = Control.MOUSE_FILTER_STOP
			row.gui_input.connect(_on_row.bind(row, true))

func hostile() -> HostileData:
	return w.data.hostile if w != null and w.data != null else null

func _h(id: int) -> Control:
	return w.control([164, ID_HOSTILE, id])

func _text(key: String) -> String:
	var t := w._builder.resolve_text(key) if w._builder != null else ""
	return t if t != "" else key

func _put(node: Control, value: String) -> void:
	if node != null:
		w._twodt.set_text(node, value)

## Every war part again (the refreshes after each war message: 0x5b3c50,
## 0x5b3c70).
func refresh() -> void:
	var h := hostile()
	if h == null:
		return
	if selected != 0 and h.war(selected) == null:
		selected = 0
	if shown != 0 and h.war(shown) == null:
		shown = 0
	_fill_hostile(h)
	_fill_details(h)
	_buttons(h)
	_fill_war(h)

func _fill_hostile(h: HostileData) -> void:
	for i in HOSTILE_ROWS.size():
		var row := _h(int(HOSTILE_ROWS[i]))
		if row == null:
			continue
		var war: GuildWarNet.War = h.wars[i] if i < h.wars.size() else null
		row.set_meta("guild_war", war.war_id if war != null else 0)
		w._set_texture(row, BAR_FULL if war != null else BAR_EMPTY)
		for id in [ROW_NAME, ROW_LEVEL, ROW_CREST]:
			var part := TwoDtBuilder.child(row, id)
			if part != null:
				part.visible = war != null
		if war == null:
			_mark(row, false)
			continue
		_put(TwoDtBuilder.child(row, ROW_NAME), war.name)
		_put(TwoDtBuilder.child(row, ROW_LEVEL), "-")
		_crest(TwoDtBuilder.child(row, ROW_CREST), war.name)
		_mark(row, war.war_id == selected)

func _fill_details(h: HostileData) -> void:
	var war := h.war(selected)
	for id in DETAIL_SHOWN:
		var n := _h(int(id))
		if n != null:
			n.visible = war != null
	var none := _h(DETAIL_NONE)
	if none != null:
		none.visible = war == null
	if war == null:
		return
	_put(_h(DETAIL_NAME), war.name)
	_put(_h(DETAIL_LEADER), _text("UIIT_CTL_GUILD_DONOTKNOW"))
	_put(_h(DETAIL_COUNT), _text("UIIT_CTL_GUILD_DONOTKNOW"))
	_crest(_h(DETAIL_CREST), war.name)

## 0x5bca80: both disabled, then 52 for the master, 53 for the master with a
## war and no countdown.
func _buttons(h: HostileData) -> void:
	var master := is_master()
	var declare := _h(BUTTON_DECLARE) as BaseButton
	if declare != null:
		declare.disabled = not master
	var end := _h(BUTTON_END) as BaseButton
	if end != null:
		end.disabled = not (master and h.count() > 0 and not h.ending)

## The player's own name is the guild master's (CDD+0x148 +0x48).
func is_master() -> bool:
	var d := w.data
	if d == null or not d.in_guild:
		return false
	var me := w._me()
	for m in d.members:
		if m.member_class == GuildData.CLASS_MASTER:
			return m.member_name == me
	return false

func _fill_war(h: HostileData) -> void:
	for i in WAR_ROWS.size():
		var row := w.control([ID_WAR, int(WAR_ROWS[i])])
		if row == null:
			continue
		var war: GuildWarNet.War = h.wars[i] if i < h.wars.size() else null
		row.set_meta("guild_war", war.war_id if war != null else 0)
		var part := TwoDtBuilder.child(row, WAR_ROW_NAME)
		if part != null:
			part.visible = war != null
		if war != null:
			_put(part, war.name)
		_mark(row, war != null and war.war_id == _shown_id(h))
	var war := h.war(_shown_id(h))
	for id in WAR_LABELS + WAR_VALUES:
		var n := w.control([ID_WAR, int(id)])
		if n != null:
			n.visible = war != null
	var none := w.control([ID_WAR, WAR_NONE])
	if none != null:
		none.visible = war == null
	if war != null:
		_put(w.control([ID_WAR, 541]), war.name)
		_put(w.control([ID_WAR, 542]), "%d" % war.own_points)
		_put(w.control([ID_WAR, 543]), "%d" % war.their_points)
		var vp := GuildWarNet.victory_points(war.victory_index)
		_put(w.control([ID_WAR, 544]), _text("UIIT_CTL_GUILDWAR_UNLIMITED") if vp == 0 else "%d" % vp)
		_put(w.control([ID_WAR, 545]), "%s %s" % [group_digits(war.gold), _text("UIIT_STT_GOLD")])
		_put(w.control([ID_WAR, 546]), time_left(war.remain, _text("UIIT_CTL_GUILDWAR_UNLIMITED")))
	_fill_contribution()

func _shown_id(h: HostileData) -> int:
	if shown != 0 and h.war(shown) != null:
		return shown
	return (h.wars[0] as GuildWarNet.War).war_id if not h.wars.is_empty() else 0

## OURS order (OPEN): the members by their contribution, highest first.
func _fill_contribution() -> void:
	var list: Array = []
	if w.data != null and w.data.in_guild:
		list = w.data.members.duplicate()
		list.sort_custom(func(a: GuildData.Member, b: GuildData.Member) -> bool:
			return a.contribution > b.contribution if a.contribution != b.contribution else a.member_name < b.member_name)
	for i in CONTRIB_ROWS.size():
		var row := w.control([ID_WAR, int(CONTRIB_ROWS[i])])
		if row == null:
			continue
		var m: GuildData.Member = list[i] if i < list.size() else null
		for id in [CONTRIB_NAME, CONTRIB_RANK, CONTRIB_POINTS]:
			var part := TwoDtBuilder.child(row, id)
			if part != null:
				part.visible = m != null
		if m != null:
			_put(TwoDtBuilder.child(row, CONTRIB_NAME), m.member_name)
			_put(TwoDtBuilder.child(row, CONTRIB_RANK), "%d" % (i + 1))
			_put(TwoDtBuilder.child(row, CONTRIB_POINTS), "%d" % m.contribution)

func _on_row(event: InputEvent, row: Control, war_pane: bool) -> void:
	var mb := event as InputEventMouseButton
	if mb == null or not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	var id := int(row.get_meta("guild_war", 0))
	if id == 0:
		return
	if war_pane:
		shown = id
	else:
		selected = id
	refresh()

func _crest(node: Control, guild_name: String) -> void:
	if node == null:
		return
	var tex: Texture2D = crest_for.call(guild_name) if crest_for.is_valid() else null
	# No crest: the record's own art (gil_mark01) stays.
	if tex != null and node is TextureRect:
		(node as TextureRect).texture = tex

## The selected bar over a row (INFERRED: the member list's own,
## com_bar01select_, 0x5b7090).
func _mark(row: Control, on: bool) -> void:
	var bar := row.get_node_or_null("WarSelectBar") as Control
	if bar == null and on and w._builder != null:
		var before := row.get_child_count()
		w._builder._add_row_bar_from(row, UiBuilder.ROW_BAR_SELECTED_DDJ, row.size)
		if row.get_child_count() > before:
			bar = row.get_child(row.get_child_count() - 1) as Control
			bar.name = "WarSelectBar"
			bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
			row.move_child(bar, 0)
	if bar != null:
		bar.visible = on

## 0x8c1d50(.., 3, 0): groups of three with commas.
static func group_digits(n: int) -> String:
	var s := str(absi(n))
	var out := ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return ("-" if n < 0 else "") + s + out

## 546's "%0.2d : %0.2d : %0.2d" (hours, minutes, seconds), or Unlimited.
static func time_left(seconds: int, unlimited: String) -> String:
	if seconds == GuildWarNet.UNLIMITED:
		return unlimited
	var s := maxi(0, seconds)
	return "%02d : %02d : %02d" % [s / 3600, (s / 60) % 60, s % 60]
