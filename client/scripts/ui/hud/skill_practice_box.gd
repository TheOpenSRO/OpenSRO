extends Control
class_name SkillPracticeBox

## The skill window's confirm box (round 781): retail's CIFSkillPracticeBox,
## the registry's GDR_PRACTICEPOPUP (`resinfo\ginterface.txt`: frame
## `interface\messagebox\msgbox2_window_`, 320x310) built from
## `resinfo\ifskillpracticebox.txt` "Create". READ from sro_client.exe unless
## a line says otherwise.
##
## **Who opens it.** A slot's ADD / UP button (CIFSkillSlot 0x6a0700) shows it
## in skill mode for the level that button learns; the board's LEVEL UP
## (0x69bca0) in mastery mode for the selected mastery and its level.
##
## **What it shows** (Show, CIFSkillPracticeBox::vslot_052 0x7063d0, and the
## mode switch vslot_050 0x706290; the member map from Create 0x706870):
## - skill mode: the slot decoration (ID 11), the skill's icon (ID 12), its
##   name (ID 13) and the level it learns (ID 15, "%d"); the mastery
##   decoration (ID 16) and name (ID 17) hidden; the window titled
##   UIIT_STT_CIRCULATION_PRACTICE_SKILL_WND ("Skill Window"); the description
##   (ID 18) the skill's study text; the message (ID 21) UIIT_STT_SKILL_LEARN
##   ("Learn [%s]skill.") with the name when the level is 1, else
##   UIIT_STT_SKILL_REINFORCEMENT_MSG ("reinforce [%s]skill upto level
##   [%d].") with the name and the level; the cost (ID 23, "%d") the level's
##   ReqLearn_SP.
## - mastery mode: the skill controls (11, 12, 13, 15) hidden, 16 and 17
##   shown, 17 the mastery's name; titled ..._PRACTICE_MASTERY_WND ("Mastery
##   Window"); the description the mastery's explanation (skillmasterydata
##   col 4); the message UIIT_STT_SKILL_LEARN with the name (the format has
##   one %s; the call passes the next level too, 0x706798); the cost the
##   leveldata cost at the current level, or 0 at level 0 (0x7067ab..0x706817).
## - The "Lv" static (ID 14) is not touched by either mode, so it stays as
##   authored (shown).
##
## **Confirm** (0x706a20, the Enter key too, 0x706b30): skill points below the
## cost -> a system message (0x778b90 kind 9) and nothing sent; else the
## learn (0x70A1, the skill id) or the raise (0x70A2, the mastery, 1). Then
## the box hides. **Cancel** and Escape hide it (0x7061d0).
##
## OURS: the caption's placement (CIFMainFrame's, 10,12,width-21,12 -- the
## class's base Create 0x705eb0 is not traced), the box's screen position
## (centred; the registry rect is 100,100), and the system message's wording.

enum Mode { SKILL, MASTERY }

const LAYOUT := "resinfo\\ifskillpracticebox.txt"
const FRAME := "interface\\messagebox\\msgbox2_window_"
const SIZE := Vector2(320, 310)
## The fill colour Create gives the description's backing (ID 8: 0xff0f0f0f,
## 0x706988).
const FILL_COLOUR := Color8(15, 15, 15, 255)

## Confirm with enough skill points: HudPanels sends the learn or the raise.
signal confirmed(mode: int, id: int)
## Confirm without enough skill points (the 0x778b90 message).
signal refused(text: String)
signal cancelled

var mode: int = Mode.SKILL
## The skill id (skill mode) or the mastery id (mastery mode).
var target_id := 0
var cost := 0
var skill_points := 0

var _builder: UiBuilder
var _root: Control

## `opts`: icon (Texture2D), name, level (int: the level learned, or the
## mastery's current level), description, cost (int), sp (int).
func build(builder: UiBuilder, box_mode: int, id: int, opts: Dictionary) -> bool:
	_builder = builder
	mode = box_mode
	target_id = id
	cost = int(opts.get("cost", 0))
	skill_points = int(opts.get("sp", 0))
	name = "SkillPracticeBox"
	size = SIZE
	custom_minimum_size = SIZE
	mouse_filter = Control.MOUSE_FILTER_STOP
	if _builder == null:
		return false
	var def := UiLayoutParser.ControlDef.new()
	def.name = "Frame"
	def.type = "CIFFrame"
	def.ddj = FRAME
	def.rect = Rect2i(Vector2i.ZERO, Vector2i(SIZE))
	var frame := _builder.build_control(def)
	if frame != null:
		frame.mouse_filter = Control.MOUSE_FILTER_PASS
		add_child(frame)
	var layout := _builder.load_layout(LAYOUT)
	if layout == null:
		return false
	_root = _builder.build_section(layout, "Create")
	if _root == null:
		return false
	add_child(_root)
	var fill := _root.get_node_or_null("GDR_SKLPB_FILL_COLOR") as Control
	if fill != null:
		var rect := ColorRect.new()
		rect.name = "Fill"
		rect.color = FILL_COLOUR
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		fill.add_child(rect)
	var skill_ids := ["GDR_SKLPB_SLOTDECO", "GDR_SKLPB_SLOT", "GDR_SKLPB_SKILLNAME", "GDR_SKLPB_SKILLLEV"]
	var mastery_ids := ["GDR_SKLPB_MNDECO", "GDR_SKLPB_MASTERYNAME"]
	for n in skill_ids:
		_show(n, mode == Mode.SKILL)
	for n in mastery_ids:
		_show(n, mode == Mode.MASTERY)
	var nm := String(opts.get("name", ""))
	var level := int(opts.get("level", 0))
	_title(_text("UIIT_STT_CIRCULATION_PRACTICE_SKILL_WND" if mode == Mode.SKILL
		else "UIIT_STT_CIRCULATION_PRACTICE_MASTERY_WND", "Skill Window" if mode == Mode.SKILL else "Mastery Window"))
	if mode == Mode.SKILL:
		_icon(_root.get_node_or_null("GDR_SKLPB_SLOT"), opts.get("icon"))
		_static("GDR_SKLPB_SKILLNAME", nm)
		_static("GDR_SKLPB_SKILLLEV", "%d" % level)
		_static("GDR_SKLPB_NEXTSTATEMSG", message(mode, nm, level,
			_text("UIIT_STT_SKILL_LEARN", "Learn [%s]skill."),
			_text("UIIT_STT_SKILL_REINFORCEMENT_MSG", "reinforce [%s]skill upto level [%d].")))
	else:
		_static("GDR_SKLPB_MASTERYNAME", nm)
		_static("GDR_SKLPB_NEXTSTATEMSG", message(mode, nm, level + 1,
			_text("UIIT_STT_SKILL_LEARN", "Learn [%s]skill."), ""))
	_static("GDR_SKLPB_NEEDSP_AMOUNT", "%d" % cost)
	var desc := _root.get_node_or_null("GDR_SKLPB_DESCRIPTION")
	if desc is LineEdit:
		# The description is a CIFEdit the box only fills; a LineEdit holds
		# one line, so the text goes on a wrapping label over it (OURS).
		var e := desc as LineEdit
		e.editable = false
		e.focus_mode = Control.FOCUS_NONE
		e.mouse_filter = Control.MOUSE_FILTER_IGNORE
		e.text = ""
		var lbl := Label.new()
		lbl.name = "DescriptionText"
		lbl.text = String(opts.get("description", ""))
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		lbl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		if _builder.font_at(0) != null:
			lbl.add_theme_font_override("font", _builder.font_at(0))
		lbl.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[0])
		e.add_child(lbl)
	var ok := _root.get_node_or_null("GDR_SKLPB_BTN_PRACTICE") as BaseButton
	if ok != null:
		ok.pressed.connect(confirm)
	var cancel := _root.get_node_or_null("GDR_SKLPB_BTN_CANCEL") as BaseButton
	if cancel != null:
		cancel.pressed.connect(cancel_box)
	UiBuilder.settle_authored_rects(_root)
	return true

## The message line (READ, see the header): the learn text for a skill's
## level 1 and for a mastery, the reinforce text otherwise.
static func message(box_mode: int, skill_name: String, level: int, learn_fmt: String, reinforce_fmt: String) -> String:
	if box_mode == Mode.MASTERY or level <= 1:
		return _format(learn_fmt, [skill_name])
	return _format(reinforce_fmt, [skill_name, level])

## A C-style "%s"/"%d" format with the arguments it names, so a table text
## with fewer specifiers than the call passes (the mastery's learn text)
## formats as the client's printf would.
static func _format(fmt: String, args: Array) -> String:
	var out := ""
	var i := 0
	var a := 0
	while i < fmt.length():
		var ch := fmt[i]
		if ch == "%" and i + 1 < fmt.length():
			var spec := fmt[i + 1]
			if spec == "%":
				out += "%"
				i += 2
				continue
			if spec == "s" or spec == "d":
				out += str(args[a]) if a < args.size() else ""
				a += 1
				i += 2
				continue
		out += ch
		i += 1
	return out

## Whether Confirm would send (READ, 0x706a53: `SP >= cost`, jae).
func can_afford() -> bool:
	return skill_points >= cost

func confirm() -> void:
	if not can_afford():
		refused.emit("Not enough skill points.")
	else:
		confirmed.emit(mode, target_id)
	close()

func cancel_box() -> void:
	cancelled.emit()
	close()

## Hidden now and freed at the end of the frame: the box is an ancestor of
## the pressed button (round 631's crash, HudPanels._close_confirm_box).
func close() -> void:
	if is_queued_for_deletion():
		return
	name = "%s_closing" % name
	visible = false
	queue_free()

func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k == null or not k.pressed or not visible:
		return
	if k.keycode == KEY_ENTER or k.keycode == KEY_KP_ENTER:
		get_viewport().set_input_as_handled()
		confirm()
	elif k.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		cancel_box()

func _show(node_name: String, on: bool) -> void:
	var n := _root.get_node_or_null(node_name) as CanvasItem
	if n != null:
		n.visible = on

func _static(node_name: String, text: String) -> void:
	var n := _root.get_node_or_null(node_name) as Control
	if n != null:
		_builder.set_static_text(n, text)

func _title(text: String) -> void:
	var def := UiLayoutParser.ControlDef.new()
	def.name = "Title"
	def.type = "CIFStatic"
	def.halign = 1
	def.rect = Rect2i(10, 12, int(SIZE.x) - 21, 12)
	var title := _builder.build_control(def)
	if title != null:
		title.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(title)
		_builder.set_static_text(title, text)

func _icon(holder: Node, tex) -> void:
	var c := holder as Control
	if c == null or not (tex is Texture2D):
		return
	var it := c.get_node_or_null("ItemIcon") as TextureRect
	if it == null:
		it = TextureRect.new()
		it.name = "ItemIcon"
		it.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		it.mouse_filter = Control.MOUSE_FILTER_IGNORE
		it.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		c.add_child(it)
	it.texture = tex

func _text(key: String, fallback: String) -> String:
	if _builder == null:
		return fallback
	var t := _builder.resolve_text(key)
	return fallback if t == "" or t == key else t

## The button carrying `caption` (its ButtonLabel), for tests and QA.
func button(caption: String) -> BaseButton:
	for b in find_children("*", "BaseButton", true, false):
		var lbl := (b as Node).get_node_or_null("ButtonLabel") as Label
		if lbl != null and lbl.text == caption:
			return b as BaseButton
	return null
