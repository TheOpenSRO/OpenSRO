extends Node
class_name QuestHud

## The quest windows that are not the quest list (round 785), owned by
## HudPanels and driven by NetClient.quest (QuestState):
##
## - **The NPC's quest pages** (0x30D4, FUN_006fc1c0, READ): drawn in the
##   NPC talk box (NpcTalkView) as the page's text and its numbered lines --
##   type 1 one line "1. UIIT_STT_CONFIRM" (response 1), type 3 "1.
##   UIIT_STT_YES" (2) and "2. UIIT_STT_NO" (3), type 4 one line per string
##   "%d. <text>" (5 + i). A list string that names a quest (SN_<CODE>) is
##   coloured by the player's level less the quest's (FUN_006f84d0): below 0
##   0xFFFF4A4A, above 9 0xFF65AFA2, else 0xFFEFDAA4. A click sends 0x70D4.
## - **The quest detail** (CIFQuestReward, resinfo\ifquestreward.txt, READ:
##   UI_QUEST::FUN_006e4c00): the title SN_PAY_<Q>, the contents
##   SN_PAYCON_<Q> in the CIFPML 18 (sml2 markup, drawn as the client draws
##   it -- PmlText, round 845: the record's FontColor black, <font color>
##   runs in their colour, <strong> in the weight-600 face, the 5-pixel line
##   margin, the pixel scroll and its scroll bar 15), the title 17 in the
##   weight-600 face (0x8b44b0(5, 2)), the button UIIT_STT_QUEST_GIVEUP for statuses
##   1/7/8 (0x70D9 after an agreement box) or UIIT_STT_QUEST_REWARD for 2
##   (0x70D8).
## - **The reward window** (0x3514 -> CNIFQuestReward, READ that it opens and
##   draws the basic rewards and the items, FUN_00605250 / FUN_006071d0).
##   OURS: CNIFQuestReward's own 2dt layout is not read, so it is drawn on the
##   same paper as the detail (`res_ui\quest_re.2dt`, a dark CNIF window, is
##   not built; round 845 draws its text through the same PML, so the paper's
##   black): the page text, then the reward lines (gold,
##   EXP, SP EXP, SP from refqusetreward; the items from
##   refquestrewarditems), and the button sends 0x7515 with nothing chosen
##   (the server pays every item; choice rewards are OPEN).
## - **The quest-information guide icon** (GDR_QUESTINFO_GUIDE,
##   CIFQuestInfoGuide, READ): see QuestInfoGuide.
## - **The quest information list** (GDR_QUESTINFO, CIFQuestInfo, id 45,
##   315x142, `mframe_wnd_`; ifquestinfo.txt's scroll area 9,37,298,96 and
##   one ifquestinfoslot.txt slot per quest, 280x96: title SN_<Q>,
##   UIIT_STT_NPC + SN_NN_<Q>, UIIT_STT_QUEST_CONDITION + SN_NC_<Q>; READ
##   FUN_007314f0).

const DETAIL_LAYOUT := "resinfo\\ifquestreward.txt"
const CONTENTS := "GDR_QUESTREWARD_CONTENTS"
## The record's rect (MEASURED, ifquestreward.txt), when the layout is missing.
const CONTENTS_RECT := Rect2(30, 74, 290, 247)
const SCROLL_CONTROL := "GDR_QUESTREWARD_SCROLL"
## CIFQuestReward's OnCreate art for the scroll (0x6e5020..0x6e50b5, READ).
const SCROLL_UP_DDJ := "interface\\guide\\gd_scroll_up.ddj"
const SCROLL_DOWN_DDJ := "interface\\guide\\gd_scroll_down.ddj"
const SCROLL_THUMB_DDJ := "interface\\guide\\gd_scroll_button.ddj"
const SCROLL_TRACK_DDJ := "interface\\quest\\qst_scroll_line.ddj"
## 0x649c30: the scroll's length is the PML's height less 0x30.
const SCROLL_LENGTH_LESS := 48.0
const TITLE_BOLD_META := "quest_title_bold"
## Godot's embolden for the weight-600 title when the system has no bold
## file (OURS: the chat's bold tab's 0.6).
const TITLE_EMBOLDEN := 0.6
const INFO_LAYOUT := "resinfo\\ifquestinfo.txt"
const INFO_SLOT_LAYOUT := "resinfo\\ifquestinfoslot.txt"
const INFO_REGISTRY := {"name": "GDR_QUESTINFO"}
const RESPONSE_KEY := "qresp:"

const COLOUR_LOW := 0xffff4a4a
const COLOUR_HIGH := 0xff65afa2
const COLOUR_EVEN := 0xffefdaa4

var panels: Control
var builder: UiBuilder
var tables: QuestTables
var detail: HudWindow = null
var reward: HudWindow = null
var info: HudWindow = null
var guide: QuestInfoGuide = null
## The quest the detail / reward window shows.
var detail_quest := 0
var reward_quest := 0
## The quests the guide counted at the last level-up.
var unlocked: Array = []
## The player's level and country (0 China, 1 Europe), for the colours and
## the guide's count.
var player_level := 0
var country := 0
## How the reward window's response leaves (tests replace it).
var state: QuestState

func _init(p: Control = null, b: UiBuilder = null, s: QuestState = null) -> void:
	panels = p
	builder = b
	state = s
	name = "QuestHud"

func _tables() -> QuestTables:
	if tables == null:
		tables = QuestTables.shared(builder.media_archive() if builder != null else null)
	return tables

func _ui(key: String, fallback: String) -> String:
	if builder == null:
		return fallback
	var v := builder.resolve_text(key)
	return v if v != "" and v != key else fallback

static func _hex(argb: int) -> String:
	return "%02x%02x%02x" % [(argb >> 16) & 0xff, (argb >> 8) & 0xff, argb & 0xff]

## The colour of a list line naming quest `q` (FUN_006f84d0, READ).
static func line_colour(player_lv: int, quest_lv: int) -> int:
	var d := player_lv - quest_lv
	if d < 0:
		return COLOUR_LOW
	if d > 9:
		return COLOUR_HIGH
	return COLOUR_EVEN

## A page's lines as the talk box draws them: the text, a blank line, then
## the numbered response lines as `[url=qresp:<id>]n. text[/url]`.
func page_lines(page: QuestNet.TalkPage) -> PackedStringArray:
	var t := _tables()
	var out := PackedStringArray()
	out.append(TeleportBoard.escape(t.resolve(page.text, page.text)))
	out.append("")
	match page.type:
		QuestNet.PAGE_CONFIRM:
			out.append("[url=%s%d]1. %s[/url]" % [RESPONSE_KEY, QuestNet.RESP_CONFIRM, _ui("UIIT_STT_CONFIRM", "Confirm")])
		QuestNet.PAGE_YES_NO:
			out.append("[url=%s%d]1. %s[/url]" % [RESPONSE_KEY, QuestNet.RESP_YES, _ui("UIIT_STT_YES", "Yes")])
			out.append("[url=%s%d]2. %s[/url]" % [RESPONSE_KEY, QuestNet.RESP_NO, _ui("UIIT_STT_NO", "No")])
		QuestNet.PAGE_LIST, QuestNet.PAGE_LIST_ITEM:
			for i in page.lines.size():
				var token: String = page.lines[i]
				var text := TeleportBoard.escape(t.resolve(token, token))
				var q := t.quest_for_title_id(token)
				if q != null:
					text = "[color=#%s]%s[/color]" % [_hex(line_colour(player_level, q.level)), text]
				out.append("[url=%s%d]%d. %s[/url]" % [RESPONSE_KEY, QuestNet.RESP_LIST_BASE + i, i + 1, text])
		_:
			# Type 2 (a placeholder line in the client, response 4): nothing
			# the server sends.
			pass
	return out

## The response id of a talk line's key, or -1.
static func response_of(key: String) -> int:
	if key.begins_with(RESPONSE_KEY) and key.substr(RESPONSE_KEY.length()).is_valid_int():
		return int(key.substr(RESPONSE_KEY.length()))
	return -1

# --- The detail and reward windows ---------------------------------------------

func _paper(existing: HudWindow, window_name: String) -> HudWindow:
	if existing != null and is_instance_valid(existing):
		return existing
	var w := HudWindow.new()
	w.name = window_name
	panels.add_child(w)
	if not w.build(builder, DETAIL_LAYOUT, ""):
		print("QuestHud: %s did not build" % DETAIL_LAYOUT)
		w.queue_free()
		return null
	# The contents box (GDR_QUESTREWARD_CONTENTS, a CIFPML at 30,74,290,247)
	# drawn as the client's PML (round 845, PmlText): its record's FontColor
	# (255,0,0,0, black) is the colour of every run no <font> recolours.
	var def := _contents_def()
	var body := PmlText.new()
	body.name = "QuestContents"
	body.position = Vector2(def.rect.position) if def != null else CONTENTS_RECT.position
	body.size = Vector2(def.rect.size) if def != null else CONTENTS_RECT.size
	var index := def.font_index if def != null else 0
	var face: Font = builder.font_at(index) if builder != null else null
	if face == null:
		face = ThemeDB.fallback_font
	body.setup(face, UiBuilder.FONT_SIZES[clampi(index, 0, UiBuilder.FONT_SIZES.size() - 1)],
		def.font_color if def != null else Color.BLACK)
	w.add_child(body)
	_link_scroll(w, body)
	_bold_title(w)
	w.centre()
	return w

## The contents record of ifquestreward.txt (its rect, font and FontColor).
func _contents_def() -> UiLayoutParser.ControlDef:
	if builder == null:
		return null
	var layout := builder.load_layout(DETAIL_LAYOUT)
	var sec := layout.get_section("Create") if layout != null else null
	if sec == null:
		return null
	return sec.control_by_name.get(CONTENTS, null) as UiLayoutParser.ControlDef

## CIFQuestReward's OnCreate (0x6e4f40, READ): the scroll 15 gets
## gd_scroll_up / gd_scroll_down / gd_scroll_button and the track
## qst_scroll_line (0x6593c0, vslot 0x34); the PML's text sets its range
## 0..content - 247 in pixels, step 1, and its length 247 - 48 (0x649c30 ->
## 0x65a390; INFERRED that the PML's linked scroll, +0x370, is this one).
## Drawn as the NPC talk's CIFVerticalScroll is (HudChat.ChatScroll, the up
## arrow 16 above the record).
func _link_scroll(w: HudWindow, body: PmlText) -> void:
	var bar := w.node(SCROLL_CONTROL) as Control
	if bar == null:
		return
	var scroll := HudChat.ChatScroll.new()
	scroll.name = "QuestContentsScroll"
	if builder != null:
		scroll.up_texture = builder.load_texture(SCROLL_UP_DDJ)
		scroll.down_texture = builder.load_texture(SCROLL_DOWN_DDJ)
		scroll.bar_texture = builder.load_texture(SCROLL_TRACK_DDJ)
		scroll.thumb_texture = builder.load_texture(SCROLL_THUMB_DDJ)
	scroll.length = maxf(body.size.y - SCROLL_LENGTH_LESS, 0.0)
	scroll.position = bar.position - Vector2(0, HudChat.SCROLL_BUTTON.y)
	scroll.size = Vector2(HudChat.SCROLL_BUTTON.x, HudChat.SCROLL_BUTTON.y * 3 + scroll.length)
	scroll.moved.connect(func(pos: int) -> void: body.set_scroll(pos))
	body.scrolled.connect(func(pos: int) -> void: scroll.set_range(body.max_scroll(), pos))
	w.add_child(scroll)
	body.set_meta("scroll_bar", scroll)

## The title 17 (0x6e4fa4..0x6e4fb4, READ): its text object gets text flag 2
## in all five states (0x8b44b0(5, 2)) -- the weight-600 face.
func _bold_title(w: HudWindow) -> void:
	var n := w.node("GDR_QUESTREWARD_TITLE") as Control
	if n != null:
		n.set_meta(TITLE_BOLD_META, true)

## The contents set: the markup laid out from the top and the scroll's range.
static func _set_contents(w: HudWindow, markup: String) -> void:
	var body := w.get_node_or_null("QuestContents") as PmlText
	if body == null:
		return
	body.set_markup(markup)
	var scroll := (body.get_meta("scroll_bar") if body.has_meta("scroll_bar") else null) as HudChat.ChatScroll
	if scroll != null:
		scroll.set_range(body.max_scroll(), body.scroll)

func _set_label(w: HudWindow, control: String, text: String) -> void:
	var n := w.node(control) as Control
	if n == null:
		return
	var l := n.get_node_or_null("Text") as Label
	if l == null:
		l = Label.new()
		l.name = "Text"
		l.size = n.size
		n.add_child(l)
		# The record's FontColor (the title's 255,255,255,255) and, for the
		# title, the weight-600 face (_bold_title): the system's bold file,
		# else Godot's embolden as the chat's bold tab draws it (OURS).
		l.add_theme_color_override("font_color", Color.WHITE)
		var face: Font = builder.font_at(0) if builder != null else null
		if face != null:
			l.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[0])
			if n.get_meta(TITLE_BOLD_META, false):
				var bold := HudNotice.bold_file(face)
				l.add_theme_font_override("font", bold if bold != null else FontOversampling.bold(face, TITLE_EMBOLDEN))
			else:
				l.add_theme_font_override("font", face)
		UiBuilder.crisp_text(l)
	l.text = text

static func _button(w: HudWindow) -> BaseButton:
	return w.node("GDR_QUESTREWARD_GIVEUP") as BaseButton

## The detail of quest `id` (the content-view button).
func open_detail(id: int) -> HudWindow:
	detail = _paper(detail, "Window_questdetail")
	if detail == null:
		return null
	detail_quest = id
	var t := _tables()
	var q := t.quest(id)
	var v := state.view_of(id) if state != null else null
	_set_label(detail, "GDR_QUESTREWARD_TITLE", t.resolve(q.pay, t.title_of(id)) if q != null else t.title_of(id))
	_set_contents(detail, t.resolve(q.paycon, "") if q != null else "")
	var b := _button(detail)
	var status := v.status if v != null else 0
	var key := "UIIT_STT_QUEST_REWARD" if status == QuestNet.STATUS_ACHIEVED_NOT_PAID else "UIIT_STT_QUEST_GIVEUP"
	if b != null:
		_set_button_text(b, _ui(key, "Reward" if key.ends_with("REWARD") else "Give up"))
		b.visible = status != 0
		if not b.has_meta("quest_wired"):
			b.set_meta("quest_wired", true)
			b.pressed.connect(_on_detail_button)
	detail.set_meta("quest_button", key)
	detail.show()
	detail.move_to_front()
	return detail

func _set_button_text(b: BaseButton, text: String) -> void:
	if builder != null:
		builder.set_button_text(b, text)

## The detail's button: the reward (0x70D8) for an achieved quest, else the
## give-up after the agreement box. Round 848: the box is the original's, where
## it was a Godot ConfirmationDialog. READ: CIFQuestReward's button
## (0x6e4ec0) for a quest of status 1, 7 or 8 calls 0x6e4d10(100), or (0x65)
## when the quest's RefQuest byte +0xb1 (kept at +0x378 by 0x6e4c00) is set;
## that asks GInterface 0x788270 with UIIT_STT_AGREEMENT_BOX (0xd938d0), the
## text UIIT_MSG_QUEST_GIVEUP_WINDOW_1 (0xdaa05c) for 100 or _WINDOW_2
## (0xdaa01c) for 0x65, through "%s", and style 1 (`push 0x1` at 0x6e4df1:
## Yes / No) -- the MsgBoxSimple box, 360 x 151, centred (PartyMatchConfirm).
## OPEN: which RefQuest column +0xb1 is, so _WINDOW_1 ("you will be unable to
## take it again") is shown for every quest.
func _on_detail_button() -> void:
	if state == null or detail_quest == 0:
		return
	var v := state.view_of(detail_quest)
	if v == null:
		return
	if v.status == QuestNet.STATUS_ACHIEVED_NOT_PAID:
		state.claim(detail_quest)
		return
	if builder == null:
		return
	var old := panels.get_node_or_null(GIVEUP_BOX) if panels != null else null
	if old != null:
		old.free()
	var box := PartyMatchConfirm.new()
	if not box.build(builder, _ui("UIIT_MSG_QUEST_GIVEUP_WINDOW_1", "UIIT_MSG_QUEST_GIVEUP_WINDOW_1"),
			PartyMatchConfirm.SIZE, "UIIT_STT_AGREEMENT_BOX"):
		box.free()
		return
	box.name = GIVEUP_BOX
	var id := detail_quest
	box.confirmed.connect(func() -> void: state.abandon(id))
	panels.add_child(box)
	box.centre_on(panels.get_viewport_rect().size if panels.is_inside_tree() else Vector2(1024, 768))

## The give-up question's node name under the HUD.
const GIVEUP_BOX := "QuestGiveUpBox"

## The reward lines of quest `id` (refqusetreward / refquestrewarditems).
func reward_lines(id: int) -> PackedStringArray:
	var out := PackedStringArray()
	var q := _tables().quest(id)
	if q == null:
		return out
	if q.exp > 0:
		out.append("%s %d" % [_ui("UIIT_STT_EXP", "EXP"), q.exp])
	if q.sp_exp > 0:
		out.append("%s %d" % [_ui("UIIT_STT_SKILL_EXP", "SP EXP"), q.sp_exp])
	if q.gold > 0:
		out.append("%s %d" % [_ui("UIIT_STT_GOLD", "Gold"), q.gold])
	if q.sp > 0:
		out.append("%s %d" % [_ui("UIIT_STT_SP", "SP"), q.sp])
	for it in q.items:
		out.append("%s x%d" % [str(it[0]), int(it[1])])
	return out

## 0x3514: the reward window.
func open_reward(id: int, text: String) -> HudWindow:
	reward = _paper(reward, "Window_questreward")
	if reward == null:
		return null
	reward_quest = id
	var t := _tables()
	_set_label(reward, "GDR_QUESTREWARD_TITLE", t.title_of(id))
	# OURS layout (see the header): the page text, a blank line, then the
	# reward lines, as PML lines (`<br>`) in the paper's black.
	var lines := PackedStringArray([t.resolve(text, text), ""])
	for l in reward_lines(id):
		lines.append(l)
	_set_contents(reward, "<br>".join(lines))
	var b := _button(reward)
	if b != null:
		_set_button_text(b, _ui("UIIT_STT_QUEST_REWARD", "Reward"))
		b.visible = true
		if not b.has_meta("quest_wired"):
			b.set_meta("quest_wired", true)
			b.pressed.connect(func() -> void:
				if state != null and reward_quest != 0:
					state.take_reward(reward_quest))
	reward.show()
	reward.move_to_front()
	print("QuestHud: reward window for quest %d (%s): %s" % [id, t.title_of(id), ", ".join(reward_lines(id))])
	return reward

func on_reward_result(ok: bool, error: int) -> void:
	if ok:
		if reward != null and is_instance_valid(reward):
			reward.hide()
		reward_quest = 0
	else:
		print("QuestHud: reward refused, error %d (%s)" % [error, _ui("UIIT_STT_QUESTREWARD_ERROR", "")])

# --- The guide icon and the information list ---------------------------------

## Client_ApplyExpAndLevelUp -> FUN_00798f60(1) (READ): count the quests the
## new level unlocks for this country that the player does not have; show
## the icon when there are any, remove it when there are none.
func on_level_up(new_level: int) -> void:
	player_level = new_level
	var t := _tables()
	unlocked = t.unlocked_at(new_level, country, func(id: int) -> bool:
		return state != null and (state.active.has(id) or state.completed.has(id)))
	if guide == null or not is_instance_valid(guide):
		guide = QuestInfoGuide.new(builder)
		panels.add_child(guide)
		guide.clicked.connect(_on_guide_clicked)
	guide.place(panels.get_viewport_rect().size if panels.is_inside_tree() else Vector2(1152, 648))
	guide.visible = not unlocked.is_empty()
	print("QuestHud: level %d unlocks %d quest(s) for country %d -- guide icon %s" % [
		new_level, unlocked.size(), country, "shown" if guide.visible else "hidden"])

## The icon's click (vslot_029, READ): the information list opens with the
## counted quests, and the icon hides and leaves the column.
func _on_guide_clicked() -> void:
	open_info(unlocked)
	guide.visible = false

func open_info(quests: Array) -> HudWindow:
	if info == null or not is_instance_valid(info):
		info = HudWindow.new()
		info.name = "Window_questinfo"
		panels.add_child(info)
		if not info.build(builder, INFO_LAYOUT, "", PackedStringArray(), PackedStringArray(), false, INFO_REGISTRY):
			info.queue_free()
			info = null
			return null
		info.centre()
	var area := info.get_node_or_null("QuestInfoSlots") as Control
	if area == null:
		area = Control.new()
		area.name = "QuestInfoSlots"
		area.position = Vector2(9, 37)
		area.size = Vector2(298, 96)
		area.clip_contents = true
		info.add_child(area)
	for c in area.get_children():
		c.queue_free()
	var layout := builder.load_layout(INFO_SLOT_LAYOUT) if builder != null else null
	var t := _tables()
	var y := 0.0
	for qv in quests:
		var q := qv as QuestTables.Quest
		var slot := builder.build_section(layout, "Create") if layout != null else Control.new()
		if slot == null:
			continue
		slot.position = Vector2(0, y)
		area.add_child(slot)
		UiBuilder.settle_authored_rects(slot)
		_slot_text(slot, "GDR_QUESTINFO_SLOT_TITLE", t.resolve(q.title, q.code))
		_slot_text(slot, "GDR_QUESTINFO_SLOT_NPC", t.resolve(q.npc_line, ""))
		_slot_text(slot, "GDR_QUESTINFO_SLOT_CONDITION", t.resolve(q.condition, ""))
		y += 96.0
	area.set_meta("slots", quests.size())
	info.show()
	info.move_to_front()
	return info

func _slot_text(slot: Control, control: String, text: String) -> void:
	var n := slot.find_child(control, true, false) as Control
	if n == null:
		return
	if builder != null:
		builder.set_static_text(n, text)
