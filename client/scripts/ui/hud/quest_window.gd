extends HudWindow
class_name QuestWindow

## The retail Quest window, `CNIFQuest`, built from the client's own
## `res_ui\questlist.2dt` the way its classes assemble it. Every address is
## `sro_client.exe`'s; docs/protocol/2DT_FORMAT.md has the format and
## docs/RE_COMPLETION.md this window's round. Each fact below is read unless
## it says otherwise.
##
## **Which window Q opens.** Q reaches 0x7990e0, which toggles CGInterface's
## window 0x4c (`IsVisible` 0xb8f530: ShowWindow(0) if shown, ShowWindow(1)
## if not). Window 0x4c is loaded at game start by 0x786f30 (0x787029..
## 0x78703e: if 0x4c is not loaded, `res_ui\questlist.2dt`, string 0xdb9144,
## under the interface). The file's record 0 is `CNIFQuest`, a CNIFMainFrame
## (624x369, `mframe_wnd_`, caption UIIT_STT_QUEST_LIST); descriptor
## 0xeeae74, CreateObject 0x6e48a0, size 0x808, vtable 0xda9d94, message map
## 0xda9b1c. The `resinfo\ifquest.txt` layout this client built before is
## CIFQuest, a pane of the main popup (GDR_QUEST) reachable only through a
## tab button the popup hides (HudMainPopup.UNHOSTED_PANES).
##
## **What the file holds.** Record 0 the window, 1 an inner frame (id 2,
## `equip_window_`), 2 a tile (id 3, `com_bg_tile_a.ddj`), 3 a vertical
## scroll (id 6) and ten rows, `CNIFQuestSlot` (ids 5, 77, 85, 93, 101, 109,
## 117, 125, 133, 141, 576x32 at a 31-pixel pitch). Each row carries a small
## box (7), a check box (8), the name (16), a world-map button (18), a
## content-view button (19), a status text (11) and a time text (75).
##
## **The rows' order is file order (read).** Each row's OnCreate (0x6e5a10)
## registers it with its parent through 0x6e3700, which pushes it to the
## FRONT of the window's list at +0x7b8 (0x6e3709..0x6e3739: the new node's
## next is the list's first) and rebuilds the row vector +0x7a8 from the
## list; the OnCreates run in reverse file order (TwoDtBuilder, round 595),
## so the vector ends in file order: row 0 is id 5 at the top.
##
## **Who fills the rows (read).** 0x6e3810 copies the player's quests --
## the quest manager's list, `[0xeef5ec]+0x20d0` (0x9d4c60) + 0x28
## (0x8b5e00) -- into +0x7c4, sets the scroll's range to 0..count-1 with
## step 1 (0x478ab0) and its position to 0 (0x478960), then refreshes
## (0x6e03c0). It runs at create and whenever the manager adds, changes or
## removes a quest (0x778c70 / 0x778cb0 / 0x778d10, from the 0x30d5 handler
## 0x8812b0). The refresh fills row i with quest (scroll position + i) and
## hides the rows past the list.

const TwoDtBuilder = preload("res://scripts/ui/twodt_builder.gd")

const QUESTLIST_2DT := "res_ui\\questlist.2dt"

const ID_QUEST := 76
## The scroll, CNIFVerticalScroll: +0x7d4 (OnCreate, 0x6e3ffd).
const ID_SCROLL := 6
const ROW_CLASS := "CNIFQuestSlot"
## A row's parts.
const ROW_SMALL_BOX := 7
const ROW_CHECK := 8
const ROW_STATUS := 11
const ROW_NAME := 16
const ROW_WORLD_MAP := 18
const ROW_CONTENT_VIEW := 19
const ROW_TIME := 75
## The row's own art in its quest mode, set by 0x6e5830(0) (0x6e5943 pushes
## the string, 0x22 long): the same picture the record names.
const ROW_ART := "interface\\quest\\qst_sub_window.ddj"
## The caption: record 0's text id, which the loader sets with SetText
## (vslot 0xbc) and CNIFMainFrame forwards to its caption (0x479e10 ->
## +0x78c's vslot 0xbc).
const CAPTION := "UIIT_STT_QUEST_LIST"
## OnCreate's x (0x6e403a `push 0x50`).
const LEFT := 0x50

## The scroll's position (+0x380): the first quest drawn in row 0.
var _scroll := 0
var quest_root: Control
var _twodt: TwoDtBuilder

## Builds the window from `res_ui\questlist.2dt` and leaves it in the state
## the OnCreates leave it: every row hidden, at (0x50, centred y), hidden
## itself. False, with nothing built, if the file is missing or empty.
func build_quest(builder: UiBuilder) -> bool:
	_builder = builder
	if builder == null:
		return false
	var file := builder.load_2dt(QUESTLIST_2DT)
	if file == null or file.records.is_empty():
		return false
	_twodt = TwoDtBuilder.new(builder)
	quest_root = _twodt.build(file, QUESTLIST_2DT)
	panel_root = quest_root
	var window_size := Vector2(file.root().rect.size)
	custom_minimum_size = window_size
	size = window_size
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(quest_root)
	# Record 0's text goes to the MainFrame's caption, not over the window
	# (0x479e10): the builder put it on the root, so it moves to the title.
	var root_text := quest_root.get_node_or_null(TwoDtBuilder.TEXT_NODE)
	if root_text != null:
		quest_root.remove_child(root_text)
		root_text.free()
	_apply_create_state()
	_add_title_bar(builder.resolve_text(CAPTION))
	var bar := get_node_or_null("TitleBar") as Label
	if bar != null:
		# CNIFMainFrame's caption: text-object slot 6 is 0 (0x479c0b), the top.
		bar.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	visible = false
	_settle()
	return true

## The OnCreates, last record first (the loader's queue, round 595): every
## row's, then the window's own.
##
## A row (CNIFQuestSlot, 0x6e5a10; map 0xdaa15c, entry 0xeb98d0): +0x354 =
## its check box 8, unchecked (0x482cb0(0)); registered with the window
## (0x6e3700); put in its quest mode (0x6e5830(0)); hidden (vslot 0x5c, 0).
##
## The window (CNIFQuest, 0x6e3ff0; map entry 0xeb96c0): +0x7d4 = the scroll
## 6; centred (0x798c50(0x4c): x = (screen width >> 1) - (width >> 1), y the
## same with the heights, through vslot 0x9c); then moved to x = 0x50 at the
## y it has (0xb8f460 reads +0x40/+0x44, vslot 0x98 at 0x6e403e); hidden
## (0x6e4049); filled (0x6e3810).
func _apply_create_state() -> void:
	for row in rows():
		var box := TwoDtBuilder.child(row, ROW_CHECK) as BaseButton
		if box != null:
			box.set_pressed_no_signal(false)
			var mark := box.get_node_or_null(TwoDtBuilder.MARK_NODE) as CanvasItem
			if mark != null:
				mark.visible = false
			# **Ours:** the check box adds the quest to the quick list
			# (0x6e55d0: `res_ui\questminilist.2dt`, CNIFMiniQuestWnd,
			# at most three, UIIT_CTL_QUEST_HELPER_FULL). That window is
			# not built, so the box takes no click rather than ticking with
			# nothing behind it.
			box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_quest_mode(row)
		row.visible = false
		# A left press on a row selects its quest (OURS wiring of the READ
		# selection, FUN_006e51e0); PASS so the wheel still reaches the window.
		row.mouse_filter = Control.MOUSE_FILTER_PASS
		row.gui_input.connect(func(ev: InputEvent) -> void:
			var mb := ev as InputEventMouseButton
			if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
				var id := int(row.get_meta("quest_id", 0))
				if id != 0:
					select_quest(id))
	place_on_create()
	_rebuild()

## 0x6e5830(0), a row's quest mode (+0x358 = 0): the check box 8 shown
## (+0x354, vslot 0x5c, 1), the status 11 hidden, the world-map button 18,
## the content-view button 19 and the small box 7 shown, and the row's art
## set to ROW_ART (+0x84 vslot 0x34). Its other mode, 0x6e5830(1), is an
## objective line under a quest (0x6e0570): the check box, 18, 19 and 7
## hidden, 11 shown, no art (_objective_mode; round 785 draws the objectives
## the server's 0x30D5 carries).
func _quest_mode(row: Control) -> void:
	for pair in [[ROW_CHECK, true], [ROW_STATUS, false], [ROW_WORLD_MAP, true],
			[ROW_CONTENT_VIEW, true], [ROW_SMALL_BOX, true]]:
		var part := TwoDtBuilder.child(row, int(pair[0]))
		if part != null:
			part.visible = bool(pair[1])
	if row is TextureRect:
		(row as TextureRect).texture = _builder.load_texture(ROW_ART)

## Where OnCreate leaves the window (see _apply_create_state), in the
## viewport's own units (what the UI scale changes). The halves are integer
## halves, as the client's `cdq / sub / sar 1` are. **Ours:** the result is
## kept inside the viewport, so the caption and close button stay reachable
## when the window does not fit (624x369 fits the default 1152x648 view at
## every UI scale up to 1.5, 768x432 -- (80, 32) there -- so the clamp only
## acts in a smaller one). The client does this once, when it builds the
## window at game start; showing it does not move it (0x6e12b0).
func place_on_create() -> void:
	var view := get_viewport_rect().size
	var x := LEFT
	var y := int(view.y) / 2 - int(size.y) / 2
	position = Vector2(clampi(x, 0, maxi(0, int(view.x) - int(size.x))),
		clampi(y, 0, maxi(0, int(view.y) - int(size.y))))

## The rows, in the order they fill (file order; see the header).
func rows() -> Array[Control]:
	var out: Array[Control] = []
	if quest_root == null:
		return out
	for c in quest_root.get_children():
		if c is Control and str(c.get_meta(TwoDtBuilder.META_CLASS, "")) == ROW_CLASS:
			out.append(c)
	return out

## A control by its GetChild path from the window (`[5, 16]` is the first
## row's name).
func control(path: Array) -> Control:
	return TwoDtBuilder.find_path(quest_root, path)

## The player's live quests (round 785): the client's quest manager list
## (QuestState.entries(), [quest_id, QuestNet.View] pairs in arrival order),
## fed by the login section and 0x30D5.
##
## **Which quests (READ).** The rows are the manager's list +0x28, which holds
## only live quests: at login the finished ids go to +0x38 and the live ones
## are pushed to the back of +0x28 (0x8ba1f0, from ICPlayer 0x9d9830); the
## 0x30d5 handler 0x8812b0 adds on case 1 (0x778c70), changes on case 2
## (0x778cb0) and deletes on cases 3 and 4 (0x778d10). Arrival order is kept
## (0x8ba1f0 pushes to the back).
##
## **The scroll (READ).** 0x6e3810 runs on every add, change and delete and
## puts the scroll back on the first quest (0x478960); ShowWindow (0x6e12b0)
## only refreshes. So a fill whose quests (ids) are the same keeps the scroll
## clamped (OURS: a change of counts redraws in place -- retail's 0x778cb0 ->
## 0x6e3810 resets; keeping it is kinder to a player reading a long list), and
## one that adds or removes a quest starts from the first.
signal quest_selected(quest_id: int)
signal detail_requested(quest_id: int)

## [quest_id, View] pairs.
var _views: Array = []
## The quest tables names, levels and objective texts come from (QuestTables).
var tables: QuestTables = null
## The player's level, for the content-view button's colour (0x6e5760).
var player_level := 0
## The quest the player last selected (tracked; the minimap's signs).
var selected_quest := 0

func fill_log(entries: Array) -> void:
	var same := _ids(entries) == _ids(_views)
	_views = entries.duplicate()
	if same:
		set_scroll(_scroll)
	else:
		_rebuild()

static func _ids(list: Array) -> Array:
	return list.map(func(pair: Array) -> int: return int(pair[0]))

func quest_count() -> int:
	return _views.size()

## 0x6e3810's tail: range 0..count-1, position 0, then the refresh.
func _rebuild() -> void:
	_scroll = 0
	refresh()

## A quest's row name: its SN_ title through the quest text, then the two
## nibbles of +8, low then high, as "%s (%d/%d)" (UTF-16 at 0xd95a80, READ).
func row_name(quest_id: int, v: QuestNet.View) -> String:
	var title := tables.title_of(quest_id) if tables != null else "Quest %d" % quest_id
	return "%s (%d/%d)" % [title, v.counter & 0x0f, (v.counter >> 4) & 0x0f]

## An objective line: its SN_CON_ text with the count put in (QuestNet.
## format_objective, the client's swprintf with one value).
func objective_text(m: QuestNet.Mission) -> String:
	var fmt := tables.resolve(m.text, m.text) if tables != null else m.text
	return QuestNet.format_objective(fmt, m.values)

## The content-view button's art by the player's level less the quest's
## (0x6e5760, READ): above 9 the blue button, below 0 the red one, else the
## plain one.
static func content_view_art(level_diff: int) -> String:
	if level_diff > 9:
		return "interface\\quest\\qst_contentviewblue_button"
	if level_diff < 0:
		return "interface\\quest\\qst_contentviewred_button"
	return "interface\\quest\\qst_contentview_button"

## The colours of an objective's status (UI_QUEST::FUN_006e8360, READ).
const STATUS_ING := "UIIT_STT_QUEST_ING"
const STATUS_END := "UIIT_STT_QUEST_END"
const COLOUR_ING := 0xffefdaa4
const COLOUR_END := 0xffff9c68

## The rows to draw from the scroll on: [kind, quest_id, View, Mission] with
## kind "quest" or "mission"; a quest's objectives follow it (0x6e0570 per
## objective, while rows remain, 0x6dcd50).
func display_rows() -> Array:
	var out: Array = []
	for qi in range(_scroll, _views.size()):
		var pair: Array = _views[qi]
		out.append(["quest", int(pair[0]), pair[1], null])
		for m in (pair[1] as QuestNet.View).missions:
			out.append(["mission", int(pair[0]), pair[1], m])
	return out

## 0x6e5830(1), a row's objective mode: the check box, 18, 19 and 7 hidden,
## the status 11 shown, no art.
func _objective_mode(row: Control) -> void:
	for pair in [[ROW_CHECK, false], [ROW_STATUS, true], [ROW_WORLD_MAP, false],
			[ROW_CONTENT_VIEW, false], [ROW_SMALL_BOX, false]]:
		var part := TwoDtBuilder.child(row, int(pair[0]))
		if part != null:
			part.visible = bool(pair[1])
	if row is TextureRect:
		(row as TextureRect).texture = null

## The refresh, 0x6e03c0 (also the scroll's notification and ShowWindow).
## Row i gets the i-th display row: a quest in quest mode (0x6e5bf0: its name
## in 0xffffffff, the content-view button's level colour, the check box
## unchecked), or one of its objectives in objective mode (the objective
## text on 16, the status on 11). Rows past the list are hidden. The time 75
## stays hidden: no timed quest is sent (flags & 4 never set).
func refresh() -> void:
	var list := rows()
	var shown := display_rows()
	for i in list.size():
		var row := list[i]
		row.set_meta("quest_id", 0)
		if i >= shown.size():
			row.visible = false
			continue
		var d: Array = shown[i]
		var quest_id := int(d[1])
		var v := d[2] as QuestNet.View
		row.set_meta("quest_id", quest_id)
		var name_node := TwoDtBuilder.child(row, ROW_NAME)
		var time := TwoDtBuilder.child(row, ROW_TIME)
		if time != null:
			time.visible = false
		if str(d[0]) == "quest":
			_quest_mode(row)
			if name_node != null:
				var label := _twodt.set_text(name_node, row_name(quest_id, v))
				if label != null:
					label.add_theme_color_override("font_color", TwoDtBuilder.argb(0xffffffff))
			var box := TwoDtBuilder.child(row, ROW_CHECK) as BaseButton
			if box != null:
				box.set_pressed_no_signal(false)
				var mark := box.get_node_or_null(TwoDtBuilder.MARK_NODE) as CanvasItem
				if mark != null:
					mark.visible = false
			_set_view_art(row, quest_id)
		else:
			_objective_mode(row)
			var m := d[3] as QuestNet.Mission
			if name_node != null:
				var label := _twodt.set_text(name_node, objective_text(m))
				if label != null:
					label.add_theme_color_override("font_color", TwoDtBuilder.argb(0xffffffff))
			var status := TwoDtBuilder.child(row, ROW_STATUS)
			if status != null:
				var key := STATUS_ING if m.open else STATUS_END
				var label := _twodt.set_text(status, _builder.resolve_text(key) if _builder != null else key)
				if label != null:
					label.add_theme_color_override("font_color", TwoDtBuilder.argb(COLOUR_ING if m.open else COLOUR_END))
		row.visible = true

func _set_view_art(row: Control, quest_id: int) -> void:
	var button := TwoDtBuilder.child(row, ROW_CONTENT_VIEW) as TextureButton
	if button == null:
		return
	if not button.has_meta("quest_wired"):
		button.set_meta("quest_wired", true)
		button.pressed.connect(func() -> void:
			var id := int(row.get_meta("quest_id", 0))
			if id != 0:
				select_quest(id)
				detail_requested.emit(id))
	var q := tables.quest(quest_id) if tables != null else null
	if q == null or _builder == null:
		return
	var base := content_view_art(player_level - q.level)
	var tex := _builder.load_texture(base + ".ddj")
	if tex != null:
		button.texture_normal = tex
		button.texture_hover = _builder.load_texture(base + "_focus.ddj")
		button.texture_pressed = _builder.load_texture(base + "_press.ddj")
	button.set_meta("view_art", base)

## The tracked quest (DAT_00eeae70; set by a selection in this window,
## FUN_006e51e0 -- INFERRED the row click).
func select_quest(quest_id: int) -> void:
	selected_quest = quest_id
	quest_selected.emit(quest_id)
## The first quest row 0 shows.
func scroll_position() -> int:
	return _scroll

## The scroll's position set and clamped to its range (0x478960: into
## [+0x370, +0x374], here 0..count-1), then the window told (0xb8f150),
## whose map sends it to the refresh.
func set_scroll(to: int) -> void:
	_scroll = clampi(to, 0, maxi(0, _views.size() - 1))
	refresh()

## CNIFQuest's wheel slot (vslot 0x90, 0x6dbe00): a positive delta steps the
## scroll up one (0x4794d0: position - step, the step 1 that 0x6e3810 set),
## a negative one down (0x4794f0). That it runs for the wheel over the
## window is **inferred** from its argument's sign test.
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			set_scroll(_scroll - 1)
			accept_event()
			return
		if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			set_scroll(_scroll + 1)
			accept_event()
			return
	super(event)

## CNIFQuest's ShowWindow (vslot 0x5c, 0x6e12b0): the base, then the
## refresh. It does not move the window.
func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and visible and quest_root != null:
		refresh()

## CNIFMainFrame's chrome (0x479a50): caption (10, 12, W-21, 12), drag area
## (10, 0, W-21, 34), close button (W-26, 10, 16, 16) on com_windowclose.ddj
## (HudWindow.MAINFRAME_*, the same numbers as CIFMainFrame's).
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
