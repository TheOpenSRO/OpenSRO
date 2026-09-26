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

## The quests the rows are drawn from: the last list the server sent,
## narrowed to the ones the player has (see fill_quests).
var _quests: Array = []
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
	place_on_create()
	_rebuild()

## 0x6e5830(0), a row's quest mode (+0x358 = 0): the check box 8 shown
## (+0x354, vslot 0x5c, 1), the status 11 hidden, the world-map button 18,
## the content-view button 19 and the small box 7 shown, and the row's art
## set to ROW_ART (+0x84 vslot 0x34). Its other mode, 0x6e5830(1), is an
## objective line under a quest (0x6e0570): the check box, 18, 19 and 7
## hidden, 11 shown, no art. This client has no objective text to put there
## (see refresh), so rows are only ever in quest mode.
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

## The quests the player has, from a quest list reply: each entry an object
## with `quest_id`, `quest_name`, `accepted` and `completed`
## (QuestNet.Entry).
##
## **Which quests (read, one step inferred).** The client's rows are the
## quest manager's list (+0x20d0 +0x28), which holds only live quests: at
## login finished ids go to +0x38 and the live ones are pushed to the back
## of +0x28 (0x8ba1f0, from ICPlayer 0x9d9830); the 0x30d5 handler 0x8812b0
## adds on case 1 (0x778c70), changes on case 2 (0x778cb0) and deletes on
## cases 3 and 4 (both 0x8813fa: 0x778d10 -> 0x8b91b0, the id then kept at
## +0x38); the server sends case 3 for statuses 4, 5 and 6 (GObjPC
## 0x5709c0). This server's reply is its whole catalogue with the
## character's progress folded in, so a row is drawn for a quest the
## character has accepted and not completed. **Inferred:** that our
## `completed` is the client's delete (our server pays the reward on
## completion, OpQuestCompleted, so nothing is left to hand in).
##
## **Order (ours).** The client keeps the order the quests arrive in
## (0x8ba1f0 pushes to the back). This server builds its reply from a Go
## map (`handleQuestList` walks `quest.Catalog`), so the reply's order
## changes from one reply to the next; the rows are sorted by quest id so
## the same quests always sit on the same rows.
##
## **The scroll (read, then ours).** 0x6e3810 puts the scroll back on the
## first quest, and it runs when the client's list changes (an add, a
## change or a delete); ShowWindow (0x6e12b0) only refreshes, keeping the
## scroll. **Ours:** this client asks for the whole list again every time
## the window opens and after every kill (World3D), so a reply that draws
## the same quests (the same ids and names -- what the rows show) keeps the
## scroll where it was, clamped to the new count, and one that draws
## different quests starts from the first quest. Retail's change message
## (0x778cb0 -> 0x6e3810) resets too, so it may reset on progress; whether
## the server sends a change per kill is not read.
func fill_quests(entries: Array) -> void:
	var pairs: Array = []
	for e in entries:
		if e is Object and "accepted" in e and bool(e.get("accepted")) \
				and not ("completed" in e and bool(e.get("completed"))):
			pairs.append([_id_of(e), e])
	pairs.sort_custom(func(x: Array, y: Array) -> bool: return int(x[0]) < int(y[0]))
	var kept: Array = pairs.map(func(pair: Array) -> Object: return pair[1])
	var same := _signature(kept) == _signature(_quests)
	_quests = kept
	if same:
		set_scroll(_scroll)
	else:
		_rebuild()

static func _id_of(e: Object) -> int:
	return int(e.get("quest_id")) if "quest_id" in e else 0

## What a row list draws (ids and names), to tell the reply opening asks
## for from a change (ours).
static func _signature(list: Array) -> Array:
	var out := []
	for e in list:
		out.append([_id_of(e), str(e.get("quest_name")) if "quest_name" in e else ""])
	return out

func quest_count() -> int:
	return _quests.size()

## 0x6e3810's tail: range 0..count-1, position 0, then the refresh.
func _rebuild() -> void:
	_scroll = 0
	refresh()

## The refresh, 0x6e03c0 (also the scroll's notification, map entry 0xeb96e8:
## message 2 from id 6, and CNIFQuest's ShowWindow, 0x6e12b0). Row i gets
## 0x6e5830(0) and then 0x6e5bf0(quest scroll + i); a row past the list gets
## 0x6e5bf0(0), which hides it (0x6e5c35..0x6e5c3d).
##
## A filled row, 0x6e5bf0 (read) against what this client has:
## - 19's art: first a colour bar by the quest's state byte +9 (1
##   `qst_colorbar_green`, 2 `_red`, 3 `_lightgreen`, 0x6e5c5d..0x6e5cf4),
##   then, unconditionally, 0x6e5760 sets it again by the player's level
##   (`[0xeef5ec]+0x868`) less the quest's (RefQuest +0x20): above 9
##   `qst_contentviewblue_button`, below 0 `qst_contentviewred_button`,
##   else `qst_contentview_button`. Our reply carries no quest level, so the
##   record's own `qst_contentview_button` stays. **Not the level colour.**
## - 16, the name: colour 0xffffffff (0x475ce0(-1)) and
##   `%s (%d/%d)` (UTF-16 at 0xd95a80) with the quest's name
##   (RefQuest +0x24 through the text table) and the two nibbles of the
##   packet's byte +8, low then high. The server packs that byte as
##   (the quest object's vslot 0x28 << 4) | CGObjPC::GetQuestCounter
##   (SR_GameServer 0x5705be..0x5705d6); what the two numbers mean is not
##   established, and our reply carries neither, so the name is drawn
##   alone rather than with a guessed pair.
## - 8 unchecked (0x482cb0(0)), then checked if the quick list (0xad) holds
##   the quest (0x5c7b90); there is no quick list here.
## - The quest's objectives (its list at +0x14) fill the following rows in
##   objective mode (0x6e0570: UIIT_STT_QUEST_ING in 0xffefdaa4 or
##   UIIT_STT_QUEST_END in 0xffff9c68 on 11, the objective's text on 16),
##   while rows remain (0x6dcd50). Our quests carry no objective text (the
##   objectives are this server's own design), so none are drawn.
## - The row shown (vslot 0x5c, 1, 0x6e600d).
## - 75, the time left: the row's update (vslot 0x30, 0x6e5a60) hides it
##   unless the quest is timed (+0xc != -1: read from the packet when
##   `flags & 4`, and turned from -1 to 0 when the quest's RefQuest
##   +0xb2 is non-zero, 0x8b94d0); ours are not, so it is hidden.
func refresh() -> void:
	var list := rows()
	for i in list.size():
		var row := list[i]
		var q := _scroll + i
		if q >= _quests.size():
			row.visible = false
			continue
		_quest_mode(row)
		var entry: Variant = _quests[q]
		var name_node := TwoDtBuilder.child(row, ROW_NAME)
		if name_node != null:
			var label := _twodt.set_text(name_node, str(entry.get("quest_name")) if entry is Object and "quest_name" in entry else str(entry))
			if label != null:
				label.add_theme_color_override("font_color", TwoDtBuilder.argb(0xffffffff))
		var box := TwoDtBuilder.child(row, ROW_CHECK) as BaseButton
		if box != null:
			box.set_pressed_no_signal(false)
			var mark := box.get_node_or_null(TwoDtBuilder.MARK_NODE) as CanvasItem
			if mark != null:
				mark.visible = false
		var time := TwoDtBuilder.child(row, ROW_TIME)
		if time != null:
			time.visible = false
		row.visible = true

## The first quest row 0 shows.
func scroll_position() -> int:
	return _scroll

## The scroll's position set and clamped to its range (0x478960: into
## [+0x370, +0x374], here 0..count-1), then the window told (0xb8f150),
## whose map sends it to the refresh.
func set_scroll(to: int) -> void:
	_scroll = clampi(to, 0, maxi(0, _quests.size() - 1))
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
