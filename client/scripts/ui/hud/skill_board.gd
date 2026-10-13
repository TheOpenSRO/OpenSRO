extends Control
class_name SkillBoard

## The skill window's live contents (round 781): the category tabs, the
## mastery tabs, the selected mastery's header and its rows of skills, built
## the way the retail client's CIFSkill / CIFSkillBoard / CIFSkillGroup /
## CIFSkillSlot build them. HudPanels owns the state (the masteries, the skill
## tables, the server's levels) and hands this node a plain model; this node
## only draws it and reports clicks. Labels: READ (decompiled / disassembled
## from sro_client.exe, addresses below), MEASURED, INFERRED, OURS.
##
## **The pane** (`resinfo\ifskill.txt`, built by HudWindow/HudMainPopup): the
## equip_window_ frame 364x333, GDR_SKILL_BOARD (a CIFSkillBoard on
## int_window_ at 6,29,351,270) and the footer (skl_wnd_box at 0,299 and the
## four statics). This node is added to the pane and draws in its coordinates.
##
## **Category tabs** (READ, FUN_006aacf0): one per tab the character's
## masteries fall in (the mastery record's TabID, skillmasterydata col 6), in
## TabID order; each a button on `interface\ifcommon\com_tab_off.ddj` /
## `com_tab_on.ddj` at (i * 0x3e + 4, -0x17), 0x3c x 0x18 -- 60x24 pitched 62,
## 23 px ABOVE the pane (the pane sits at y 63 in the main popup, 25 lower than
## the other panes: ifmainpopup.txt), titled with the tab's own name code
## (skillmasterydata col 5: UIIT_CTL_WEAPON_SKILL "Weapon", ..._FORCE_SKILL
## "Force", UIIT_CTL_EU_SKILLWND_PHYSICAL "Melee", _MASICAL "Caster", _ASSIST
## "Buff"). The first is selected at build.
##
## **Mastery tabs** (READ): per category a CIFSkillMasteryWndManager at
## (12, 4) 330x28 (0x6aaf55: 0xc, 4, 0x14a, 0x1c); its AddMastery (0x6a0400)
## makes a CIFSkillMastery 68x28 (0x44 x 0x1c) per mastery and lays them at
## x + i * 0x44 (0x6a04c4). Each loads `resinfo\ifskill_mastery.txt`: one
## title static (0,9,68,28, centred) holding the mastery's name
## (SetMasteryData 0x69f860). Its art is `skl_mastery_tab_on.ddj` when
## selected, `skl_mastery_tab_off.ddj` when not (0x69f940).
##
## **Header** (READ, CIFSkillBoard::Create 0x69c4e0 loads
## `resinfo\ifskillboard.txt`; 0x69c5f0 fills it): skl_mastery_subject at
## 0,0; the mastery icon (ID 11, 7,7,32,32); the name (ID 12) "%s %s" of the
## mastery name and PARAM_MASTERY ("Bicheon Mastery"); the level (ID 13,
## 291,12,46,24, centred) "%s %d" of UIIT_STT_LEVEL_LV and the level ("Lv
## 100"); LEVEL UP (ID 14, skl_mastery_levelup at 219,13) -- shown at level 0,
## else only while level + 1 <= the character's level, level < 0x78 (120)
## and the next raise's cost (leveldata col 2) <= the skill points; hidden
## otherwise (levelup_visible).
##
## **Rows** (READ, 0x69d7b0): one CIFSkillGroup 328x60 (0x148 x 0x3c) per
## group of the mastery (GroupNum), each on `skl_mastery_bar.ddj`, added to
## the scroll manager (ID 10, 4,41,342,225), which shows 4 rows (0x8123f0(4))
## pitched 0x37 = 55 (0x8124c0), stepping by whole rows and hiding the rest
## (0x81287c..0x81293d). Its scroll bar is 16 wide at the right edge, its up
## arrow 3 below the top and its track 225 - 48 long (0x812420). A group
## (SetGroup 0x69ef80, `resinfo\ifskill_group.txt`) draws its icon at
## 7,8,20,20 with a `_focus.ddj` hover twin and the group's name as its help;
## a slot (CIFSkillSlot, 36x56) per skill at x = column * 0x24 + 0x25, y 3;
## and `skl_mastery_nothing.ddj` (32x32) in every column after the last one
## used, up to 8.
##
## **A slot** (`resinfo\ifskill_slot.txt`; SetSkill 0x6a15f0, button
## 0x6a0f20, level 0x6a0a50) -- see slot_view for the rules: the icon 32x32,
## a button 0,32,32,20, the level on `skl_level_tab.ddj` at 19,17 as digit
## images `skl_lv_number_%d.ddj` (8x8; one digit at 26,24, two at 24,24 and
## 29,24).
##
## The ADD / UP button and LEVEL UP open the practice box (SkillPracticeBox)
## -- 0x6a0700 and 0x69bca0 -- whose Confirm sends the learn / raise.

## A tab, mastery tab or LEVEL UP / slot button was pressed: HudPanels acts.
signal category_selected(index: int)
signal mastery_selected(index: int)
signal levelup_pressed
## The ADD / UP button of a slot: `target_id` is the skill level it learns.
signal learn_pressed(target_id: int)
## The rows were scrolled (the first visible row), so a refill keeps it.
signal scrolled(first_row: int)

const TAB_ON := "interface\\ifcommon\\com_tab_on.ddj"
const TAB_OFF := "interface\\ifcommon\\com_tab_off.ddj"
const MASTERY_TAB_ON := "interface\\skill\\skl_mastery_tab_on.ddj"
const MASTERY_TAB_OFF := "interface\\skill\\skl_mastery_tab_off.ddj"
const BOARD_LAYOUT := "resinfo\\ifskillboard.txt"
const GROUP_BAR := "interface\\skill\\skl_mastery_bar.ddj"
const NOTHING := "interface\\skill\\skl_mastery_nothing.ddj"
const LOCKED := "interface\\skill\\skl_mastery_disable.ddj"
const BUTTON_ADD := "interface\\skill\\skl_button_add.ddj"
const BUTTON_UP := "interface\\skill\\skl_button_up.ddj"
const LEVEL_MAX := "interface\\skill\\skl_level_max.ddj"
const LEVEL_TAB := "interface\\skill\\skl_level_tab.ddj"
const DIGIT_DDJ := "interface\\skill\\skl_lv_number_%d.ddj"
const FOCUS_SUFFIX := "_focus.ddj"

## Category tabs (READ, FUN_006aacf0).
const CATEGORY_TAB_X0 := 4.0
const CATEGORY_TAB_PITCH := 62.0
const CATEGORY_TAB_Y := -23.0
const CATEGORY_TAB_SIZE := Vector2(60, 24)
## Mastery tabs (READ, 0x6aaf55 and 0x6a0400).
const MASTERY_STRIP_POS := Vector2(12, 4)
const MASTERY_STRIP_SIZE := Vector2(330, 28)
const MASTERY_TAB_SIZE := Vector2(68, 28)
## ifskill_mastery.txt's title (READ): 0,9,68,28, HAlign 1, VAlign 0.
const MASTERY_TITLE_RECT := Rect2(0, 9, 68, 28)
## The board inside the pane: ifskill.txt's GDR_SKILL_BOARD (READ).
const BOARD_RECT := Rect2(6, 29, 351, 270)
## Rows (READ, 0x69d7b0 / CIFSkillBoard::Create / 0x812420).
const SCROLL_RECT := Rect2(4, 41, 342, 225)
const GROUP_SIZE := Vector2(328, 60)
const ROW_PITCH := 55
const VISIBLE_ROWS := 4
const SCROLLBAR_WIDTH := 16.0
const SCROLLBAR_TOP := 3.0
const SCROLLBAR_LESS := 48.0
## ifskill_group.txt's GDR_SKILLGROUP_ICON (READ).
const GROUP_ICON_RECT := Rect2(7, 8, 20, 20)
## SetGroup's slot placement (READ, 0x69f15c..0x69f17a, 0x69f1ed..0x69f273).
const COLUMNS := 8
const SLOT_X0 := 37.0
const SLOT_PITCH := 36.0
const SLOT_Y := 3.0
const SLOT_SIZE := Vector2(36, 56)
const NOTHING_SIZE := Vector2(32, 32)
## ifskill_slot.txt (READ).
const ICON_RECT := Rect2(0, 0, 32, 32)
const BUTTON_RECT := Rect2(0, 32, 32, 20)
const LEVEL_TAB_POS := Vector2(19, 17)
const DIGIT_MID := Vector2(26, 24)
const DIGIT_FIRST := Vector2(24, 24)
const DIGIT_SECOND := Vector2(29, 24)
const DIGIT_SIZE := Vector2(8, 8)
## An unlearned skill's icon is drawn at 0x80 of 0xff (READ: 0x6a11cf and
## 0x6a14f5 call the icon's drawable +0x24 with 0x80; SetSkill sets 0xff,
## 0x6a165f). Whether that value is the alpha or the brightness is not
## traced (INFERRED: alpha); this draws it as alpha.
const UNLEARNED_ALPHA := 128.0 / 255.0
## LEVEL UP disappears from mastery level 0x78 (READ, 0x69c7c8).
const LEVELUP_LAST_LEVEL := 120

## The slot's button (READ, 0x6a0f20).
enum Btn { NONE, ADD, UP, MAX }

var builder: UiBuilder
## Round 786: how a control's hover help is shown -- Callable(control, source)
## with source the rows, a Callable returning them, or a String
## (HudPanels.set_bubble_tip: the original's blue CNIFHelperBubbleWindow).
## Unset (a test), the help is kept on the control's meta `tip` and no
## native tooltip is set either way.
var tip_wirer := Callable()
## The first visible row.
var first_row := 0
var _rows: Array = []
var _scroll = null   # HudChat.ChatScroll
var _rows_host: Control

# --- the rules (pure, tested) ----------------------------------------------

## What one slot shows (READ). `learned` is the skill's learned level (0 =
## not learned); the arrays are the skill's per-level ids, required mastery
## levels and learn costs (index = level - 1); `prereqs_met` whether the
## target level's ReqLearn skills are known; `sp` the skill points.
##
## - Learned (SetSkill state 0): its own icon at full strength, the level
##   badge, and the button for the NEXT level: none left -> MAX (shown, not
##   pressable, 0x6a109b); else UP when the mastery has reached that level's
##   requirement (0x6a113f), its prerequisite skills are known (0x6a11a6) and
##   the skill points cover its cost (0x6a1245) -- otherwise no button.
## - Not learned (state 8): no badge; its own icon dimmed (0x80) when the
##   mastery has reached level 1's requirement (0x9c0c80), else the locked
##   book `skl_mastery_disable.ddj` (0x6a1740); ADD under the same three
##   conditions for level 1.
##
## OURS on top of the read rules: a level whose learn cost is 0 offers no
## button (the server refuses it, FUN_0059e450's 0x3409; round 691), and a
## missing level id offers none.
static func slot_view(learned: int, max_level: int, mastery_level: int, level_ids: PackedInt64Array,
		level_reqs: PackedInt32Array, level_sp: PackedInt32Array, prereqs_met: bool, sp: int) -> Dictionary:
	var view := {"button": Btn.NONE, "locked": false, "dim": false, "badge": learned > 0,
		"level": learned, "target_id": 0}
	var target := learned + 1
	var req: int = level_reqs[target - 1] if target - 1 < level_reqs.size() and target >= 1 else 0
	var cost: int = level_sp[target - 1] if target - 1 < level_sp.size() and target >= 1 else 0
	var target_id: int = level_ids[target - 1] if target - 1 < level_ids.size() and target >= 1 else 0
	if learned <= 0:
		var req1: int = level_reqs[0] if level_reqs.size() > 0 else 0
		view["locked"] = mastery_level < req1
		view["dim"] = not view["locked"]
	if learned > 0 and (target > max_level or target_id <= 0):
		view["button"] = Btn.MAX
		return view
	view["target_id"] = target_id
	if target_id <= 0 or mastery_level < req or not prereqs_met or sp < cost or cost <= 0:
		return view
	view["button"] = Btn.UP if learned > 0 else Btn.ADD
	return view

## Whether LEVEL UP shows (READ, 0x69c5f0 mode 1): always at level 0;
## otherwise only while level + 1 <= the character's level (+0x868),
## level < 120 and the raise's cost <= the skill points (+0x880). A
## character level of 0 (not reported yet) skips that one check (OURS).
static func levelup_visible(level: int, char_level: int, sp: int, cost: int) -> bool:
	if level <= 0:
		return true
	if char_level > 0 and level + 1 > char_level:
		return false
	if level >= LEVELUP_LAST_LEVEL:
		return false
	return cost <= sp

## The level's digit images and where they go (READ, 0x6a0a50): one digit at
## the MID spot below 10, else the tens at FIRST and the units at SECOND.
static func level_digits(level: int) -> Array:
	if level < 0:
		return []
	if level < 10:
		return [[DIGIT_MID, level]]
	return [[DIGIT_FIRST, (level / 10) % 10], [DIGIT_SECOND, level % 10]]

## The footer's total (READ, FUN_006aa3e0: "%d/%d", no spaces).
static func total_text(total: int, cap: int) -> String:
	return "%d/%d" % [total, cap]

## The header's name (READ, "%s %s": the mastery's name, PARAM_MASTERY).
static func header_name(mastery_name: String, mastery_word: String) -> String:
	return "%s %s" % [mastery_name, mastery_word]

## The header's level (READ, "%s %d": UIIT_STT_LEVEL_LV, the level).
static func level_text(lv_word: String, level: int) -> String:
	return "%s %d" % [lv_word, level]

## Where a category tab sits in the pane (READ).
static func category_tab_rect(index: int) -> Rect2:
	return Rect2(Vector2(CATEGORY_TAB_X0 + CATEGORY_TAB_PITCH * index, CATEGORY_TAB_Y), CATEGORY_TAB_SIZE)

## Where a mastery tab sits in the pane (READ).
static func mastery_tab_rect(index: int) -> Rect2:
	return Rect2(MASTERY_STRIP_POS + Vector2(MASTERY_TAB_SIZE.x * index, 0), MASTERY_TAB_SIZE)

## A slot's rect in its row (READ).
static func slot_rect(column: int) -> Rect2:
	return Rect2(Vector2(SLOT_X0 + SLOT_PITCH * column, SLOT_Y), SLOT_SIZE)

## The highest first row the scroll can reach.
static func max_first_row(row_count: int) -> int:
	return maxi(0, row_count - VISIBLE_ROWS)

# --- building --------------------------------------------------------------

## Builds everything. `model`:
##   categories: Array[String]            the category tab titles
##   category: int                        the selected one
##   masteries: Array[String]             the selected category's mastery names
##   mastery: int                         the selected mastery
##   header: {icon: Texture2D, name: String, level: String, levelup: bool,
##            tooltip: String}            (null/absent: no mastery)
##   rows: Array of {icon: Texture2D, focus: Texture2D, name: String,
##        slots: Array (COLUMNS entries, null = no skill) of
##        {icon: Texture2D, view: slot_view(...), tip: Callable -> rows
##         (SkillTooltipLines) or tooltip: String,
##         button_tooltip: String, meta: Dictionary}}
##   first_row: int
## `on_icon_input(event, icon, meta)` handles a slot icon's mouse input
## (pick up / cast) and may be invalid.
func build(model: Dictionary, on_icon_input: Callable = Callable()) -> void:
	name = "SkillBoardView"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	position = Vector2.ZERO
	_build_category_tabs(model.get("categories", []), int(model.get("category", 0)))
	_build_mastery_tabs(model.get("masteries", []), int(model.get("mastery", 0)))
	var board := Control.new()
	board.name = "SkillBoardContent"
	board.position = BOARD_RECT.position
	board.size = BOARD_RECT.size
	board.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(board)
	var header = model.get("header")
	if header is Dictionary:
		_build_header(board, header)
	_build_rows(board, model.get("rows", []), int(model.get("first_row", 0)), on_icon_input)

func _tex(path: String) -> Texture2D:
	return builder.load_texture(path) if builder != null and path != "" else null

func _font_label(text: String, colour: Color = Color.WHITE) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lbl.add_theme_color_override("font_color", colour)
	if builder != null:
		var font := builder.font_at(0)
		if font != null:
			lbl.add_theme_font_override("font", font)
	lbl.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[0])
	return lbl

## A text tab: its art, its title centred. Pressing an unselected one emits.
func _tab(art_on: String, art_off: String, rect: Rect2, title: String, title_rect: Rect2,
		selected: bool, valign: VerticalAlignment) -> TextureButton:
	var btn := TextureButton.new()
	btn.ignore_texture_size = true
	btn.stretch_mode = TextureButton.STRETCH_SCALE
	btn.focus_mode = Control.FOCUS_NONE
	btn.texture_normal = _tex(art_on if selected else art_off)
	btn.position = rect.position
	btn.size = rect.size
	var lbl := _font_label(title)
	lbl.name = "Title"
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = valign
	lbl.position = title_rect.position
	lbl.size = title_rect.size
	btn.add_child(lbl)
	btn.set_meta("selected", selected)
	return btn

func _build_category_tabs(titles: Array, selected: int) -> void:
	var strip := Control.new()
	strip.name = "SkillCategoryTabs"
	strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(strip)
	for i in range(titles.size()):
		# OURS: the title's placement in the tab -- centred both ways in the
		# tab's 60x24 (CIFButton draws its caption with the static's draw).
		var btn := _tab(TAB_ON, TAB_OFF, category_tab_rect(i), String(titles[i]),
			Rect2(Vector2.ZERO, CATEGORY_TAB_SIZE), i == selected, VERTICAL_ALIGNMENT_CENTER)
		btn.name = "CategoryTab%d" % i
		btn.pressed.connect(func() -> void: category_selected.emit(i))
		strip.add_child(btn)

func _build_mastery_tabs(titles: Array, selected: int) -> void:
	var strip := Control.new()
	strip.name = "SkillMasteryTabs"
	strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(strip)
	for i in range(titles.size()):
		var btn := _tab(MASTERY_TAB_ON, MASTERY_TAB_OFF, mastery_tab_rect(i), String(titles[i]),
			MASTERY_TITLE_RECT, i == selected, VERTICAL_ALIGNMENT_TOP)
		btn.name = "MasteryTab%d" % i
		btn.pressed.connect(func() -> void: mastery_selected.emit(i))
		strip.add_child(btn)

## ifskillboard.txt's Create, built from the archive, then filled.
func _build_header(board: Control, header: Dictionary) -> void:
	var root: Control = null
	if builder != null:
		var layout := builder.load_layout(BOARD_LAYOUT)
		if layout != null:
			root = builder.build_section(layout, "Create")
	if root == null:
		# No layout (a test without the archive): the same five controls by
		# hand at the layout's rects, so the logic stays exercised.
		root = Control.new()
		for spec in [["GDR_SKILLBOARD_ICON", Rect2(7, 7, 32, 32)], ["GDR_SKILLBOARD_MASTERYNAME", Rect2(48, 12, 175, 24)],
				["GDR_SKILLBOARD_MASTERYLEV", Rect2(291, 12, 46, 24)], ["GDR_SKILLBOARD_BOARD", SCROLL_RECT]]:
			var c: Control = Label.new() if String(spec[0]).contains("NAME") or String(spec[0]).contains("LEV") else Control.new()
			c.name = spec[0]
			c.position = (spec[1] as Rect2).position
			c.size = (spec[1] as Rect2).size
			root.add_child(c)
		var lv := TextureButton.new()
		lv.name = "GDR_SKILLBOARD_BTNLEVUP"
		lv.position = Vector2(219, 13)
		lv.size = Vector2(64, 20)
		root.add_child(lv)
	root.name = "SkillHeader"
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	board.add_child(root)
	var icon := root.get_node_or_null("GDR_SKILLBOARD_ICON") as Control
	if icon != null:
		var it := icon.get_node_or_null("ItemIcon") as TextureRect
		if it == null:
			it = TextureRect.new()
			it.name = "ItemIcon"
			it.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			it.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			it.mouse_filter = Control.MOUSE_FILTER_IGNORE
			icon.add_child(it)
		it.texture = header.get("icon")
		icon.mouse_filter = Control.MOUSE_FILTER_PASS
		_tip(icon, String(header.get("tooltip", "")))
	_set_text(root.get_node_or_null("GDR_SKILLBOARD_MASTERYNAME"), String(header.get("name", "")))
	_set_text(root.get_node_or_null("GDR_SKILLBOARD_MASTERYLEV"), String(header.get("level", "")))
	var lv_btn := root.get_node_or_null("GDR_SKILLBOARD_BTNLEVUP") as BaseButton
	if lv_btn != null:
		lv_btn.visible = bool(header.get("levelup", false))
		lv_btn.focus_mode = Control.FOCUS_NONE
		_tip(lv_btn, String(header.get("levelup_tooltip", "")))
		lv_btn.pressed.connect(func() -> void: levelup_pressed.emit())
	UiBuilder.settle_authored_rects(root)

## A control's hover help, through tip_wirer (round 786) -- never Godot's
## tooltip_text, whose popup is the native grey box.
func _tip(control: Control, source: Variant) -> void:
	control.tooltip_text = ""
	control.set_meta("tip", source)
	if tip_wirer.is_valid():
		tip_wirer.call(control, source)

func _set_text(node: Node, text: String) -> void:
	if node == null:
		return
	if builder != null and node is Control and (node as Control).has_meta(UiBuilder.STATIC_DEF_META):
		builder.set_static_text(node as Control, text)
	elif node is Label:
		(node as Label).text = text

func _build_rows(board: Control, rows: Array, first: int, on_icon_input: Callable) -> void:
	var host: Control = board.find_child("GDR_SKILLBOARD_BOARD", true, false) as Control
	if host == null:
		host = Control.new()
		host.name = "GDR_SKILLBOARD_BOARD"
		host.position = SCROLL_RECT.position
		host.size = SCROLL_RECT.size
		board.add_child(host)
	host.mouse_filter = Control.MOUSE_FILTER_PASS
	_rows_host = Control.new()
	_rows_host.name = "SkillRows"
	_rows_host.mouse_filter = Control.MOUSE_FILTER_PASS
	_rows_host.size = SCROLL_RECT.size
	host.add_child(_rows_host)
	_rows.clear()
	for r in rows:
		_rows.append(_build_row(r as Dictionary, on_icon_input))
	# The scroll bar (CIFScrollManager +0x7d4, a CIFVerticalScroll on
	# ifverticalscroll.txt's art): 16 wide at the right, its up arrow 3 below
	# the top, its track 225 - 48 long, stepping one row (READ, 0x812420).
	_scroll = HudChat.ChatScroll.new()
	_scroll.name = "SkillScroll"
	if builder != null:
		_scroll.up_texture = builder.load_texture(HudChat.ARROW_UP_DDJ)
		_scroll.down_texture = builder.load_texture(HudChat.ARROW_DOWN_DDJ)
		_scroll.bar_texture = builder.load_texture(HudChat.SCROLL_BAR_DDJ)
		_scroll.thumb_texture = builder.load_texture(HudChat.SCROLL_THUMB_DDJ)
	_scroll.length = SCROLL_RECT.size.y - SCROLLBAR_LESS
	_scroll.position = Vector2(SCROLL_RECT.size.x - SCROLLBAR_WIDTH, SCROLLBAR_TOP)
	_scroll.size = Vector2(SCROLLBAR_WIDTH, SCROLLBAR_WIDTH * 3 + _scroll.length)
	_scroll.moved.connect(func(pos: int) -> void: set_first_row(pos))
	host.add_child(_scroll)
	# OURS: the wheel over the rows scrolls them a row at a time.
	host.gui_input.connect(_on_rows_input)
	set_first_row(first)

func _on_rows_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb == null or not mb.pressed:
		return
	if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
		set_first_row(first_row - 1)
	elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		set_first_row(first_row + 1)

## Shows rows first..first+3 at their places and hides the rest (READ,
## 0x81287c: a row outside the window is hidden, not clipped).
func set_first_row(n: int) -> void:
	var top := max_first_row(_rows.size())
	var was := first_row
	first_row = clampi(n, 0, top)
	for i in range(_rows.size()):
		var row: Control = _rows[i]
		var k := i - first_row
		row.visible = k >= 0 and k < VISIBLE_ROWS
		row.position = Vector2(0, k * ROW_PITCH)
	if _scroll != null:
		_scroll.set_range(top, first_row)
	if was != first_row:
		scrolled.emit(first_row)

func row_count() -> int:
	return _rows.size()

func _build_row(r: Dictionary, on_icon_input: Callable) -> Control:
	var row := Control.new()
	row.name = "SkillRow%d" % _rows.size()
	row.size = GROUP_SIZE
	row.mouse_filter = Control.MOUSE_FILTER_PASS
	_rows_host.add_child(row)
	var bar := TextureRect.new()
	bar.name = "Bar"
	bar.texture = _tex(GROUP_BAR)
	bar.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bar.size = GROUP_SIZE
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(bar)
	# The group icon, with its focus twin on hover and the group's name as
	# its help (READ, 0x69effd..0x69f0f6).
	var gi := TextureButton.new()
	gi.name = "GroupIcon"
	gi.ignore_texture_size = true
	gi.stretch_mode = TextureButton.STRETCH_SCALE
	gi.focus_mode = Control.FOCUS_NONE
	gi.texture_normal = r.get("icon")
	gi.texture_hover = r.get("focus")
	gi.position = GROUP_ICON_RECT.position
	gi.size = GROUP_ICON_RECT.size
	_tip(gi, String(r.get("name", "")))
	row.add_child(gi)
	var slots: Array = r.get("slots", [])
	var last := -1
	for c in range(mini(slots.size(), COLUMNS)):
		if slots[c] != null:
			last = c
	for c in range(COLUMNS):
		if c < slots.size() and slots[c] != null:
			row.add_child(_build_slot(c, slots[c] as Dictionary, on_icon_input))
		elif c > last:
			var empty := TextureRect.new()
			empty.name = "Nothing%d" % c
			empty.texture = _tex(NOTHING)
			empty.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			empty.position = slot_rect(c).position
			empty.size = NOTHING_SIZE
			empty.mouse_filter = Control.MOUSE_FILTER_IGNORE
			row.add_child(empty)
	return row

func _build_slot(column: int, s: Dictionary, on_icon_input: Callable) -> Control:
	var view: Dictionary = s.get("view", {})
	var slot := Control.new()
	slot.name = "Slot%d" % column
	var r := slot_rect(column)
	slot.position = r.position
	slot.size = r.size
	slot.mouse_filter = Control.MOUSE_FILTER_PASS
	var icon := TextureRect.new()
	icon.name = "Icon"
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.position = ICON_RECT.position
	icon.size = ICON_RECT.size
	icon.texture = _tex(LOCKED) if bool(view.get("locked", false)) else s.get("icon")
	if bool(view.get("dim", false)):
		icon.modulate = Color(1, 1, 1, UNLEARNED_ALPHA)
	icon.mouse_filter = Control.MOUSE_FILTER_PASS
	_tip(icon, s.get("tip", String(s.get("tooltip", ""))))
	var meta: Dictionary = s.get("meta", {})
	for k in meta:
		icon.set_meta(String(k), meta[k])
	if on_icon_input.is_valid():
		icon.gui_input.connect(func(ev: InputEvent) -> void: on_icon_input.call(ev, icon, meta))
	slot.add_child(icon)
	if bool(view.get("badge", false)):
		var tab := TextureRect.new()
		tab.name = "LevelTab"
		tab.texture = _tex(LEVEL_TAB)
		tab.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tab.position = LEVEL_TAB_POS
		tab.size = tab.texture.get_size() if tab.texture != null else Vector2(16, 16)
		tab.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(tab)
		for d in level_digits(int(view.get("level", 0))):
			var digit := TextureRect.new()
			digit.name = "Digit%d" % slot.get_child_count()
			digit.texture = _tex(DIGIT_DDJ % int(d[1]))
			digit.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			digit.position = d[0]
			digit.size = DIGIT_SIZE
			digit.mouse_filter = Control.MOUSE_FILTER_IGNORE
			digit.set_meta("digit", int(d[1]))
			slot.add_child(digit)
	var which: int = int(view.get("button", Btn.NONE))
	if which != Btn.NONE:
		var art: String = {Btn.ADD: BUTTON_ADD, Btn.UP: BUTTON_UP, Btn.MAX: LEVEL_MAX}[which]
		var btn := TextureButton.new()
		btn.name = "Button"
		btn.ignore_texture_size = true
		btn.stretch_mode = TextureButton.STRETCH_SCALE
		btn.focus_mode = Control.FOCUS_NONE
		btn.texture_normal = _tex(art)
		if which != Btn.MAX:
			btn.texture_hover = _tex(art.replace(".ddj", FOCUS_SUFFIX))
			btn.texture_pressed = _tex(art.replace(".ddj", "_press.ddj"))
			var target := int(view.get("target_id", 0))
			btn.pressed.connect(func() -> void: learn_pressed.emit(target))
		else:
			# MAX is drawn but not pressable (READ, 0x6a10c3: b8f540(0)).
			btn.disabled = true
			btn.texture_disabled = btn.texture_normal
		btn.position = BUTTON_RECT.position
		btn.size = BUTTON_RECT.size
		_tip(btn, String(s.get("button_tooltip", "")))
		btn.set_meta("kind", ["", "ADD", "UP", "MAX"][which])
		slot.add_child(btn)
	return slot
