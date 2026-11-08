extends RefCounted
class_name AcademyJudgeWindow

## Round 865: the guardian evaluation an apprentice gives when it graduates
## -- CIFApprenticeShipJudge, "ApprenticeShipJudge" (academy.md 10.3). READ
## from sro_client.exe:
## - a CIFMainFrame (RTTI) framed by the registry entry GDR_APPRENTICESHIP_
##   JUDGE (ginterface ID 155, 420 x 174, msgbox2_window_), whose Text
##   UIIT_STT_TC_APPRAISAL_GUARDIAN ("Guardian Evaluation") is the caption
##   (CIFMainFrame slot 45, HudWindow's registry caption);
## - Create (c:0x808740) loads resinfo\ifapprenticeshipjudge.txt and sets the
##   radio (20) up: origin (0, 0) (0x657910), pitch 0x46 (0x657930), the label
##   0x14 right of the dot (0x657940), left-aligned (0x657950(0)), 0x50 wide
##   (0x657960), five items in a row (0x657c40(5, 1)): UIIT_STT_TC_APPRAISAL_
##   VERY_SATISFACTION, _SATISFACTION, _NORMAL, _DESPAIR, _VERY_DESPAIR (the
##   item order INFERRED from the call's argument order), index 1 chosen
##   (0x6579b0(1));
## - the constructor (c:0x808550) sets the evaluation to 3; a radio click
##   (c:0x808620, table c:0x80867c) maps index 0..4 to 4, 3, 2, 1, 0;
## - Evaluate (30, c:0x8085c0): 0x7475 {u8 the evaluation}, then the window
##   closes; Cancel (31, c:0x808600) closes it and sends nothing.

const LAYOUT := "resinfo\\ifapprenticeshipjudge.txt"
const REGISTRY := "GDR_APPRENTICESHIP_JUDGE"
const RADIO := "GDR_APPRENTICESHIP_JUDGE_RADIOBUTTON"
const BTN_CONFIRM := "GDR_APPRENTICESHIP_JUDGE_BTN_CONFIRM"
const BTN_CANCEL := "GDR_APPRENTICESHIP_JUDGE_BTN_CANCEL"
const ITEMS := ["UIIT_STT_TC_APPRAISAL_VERY_SATISFACTION", "UIIT_STT_TC_APPRAISAL_SATISFACTION",
	"UIIT_STT_TC_APPRAISAL_NORMAL", "UIIT_STT_TC_APPRAISAL_DESPAIR", "UIIT_STT_TC_APPRAISAL_VERY_DESPAIR"]
const FALLBACK := ["Very satisfied", "Satisfied", "Average", "Disappointed", "Very disappointed"]
## c:0x80867c: radio index -> the byte 0x7475 carries.
const INDEX_TO_BYTE := [4, 3, 2, 1, 0]
const PITCH := 0x46
const LABEL_DX := 0x14
const LABEL_W := 0x50
const DEFAULT_INDEX := 1
const DOT_SIZE := Vector2(16, 16)
const LABEL_DY := 3.0
const LABEL_H := 12.0
const META := "academy_judge"

## Evaluate pressed: the byte for 0x7475.
signal evaluated(value: int)

var window: HudWindow
var _builder: UiBuilder
var index := DEFAULT_INDEX
var evaluation := 3
var _dots: Array[TextureButton] = []

## Builds the radio into the window HudPanels framed (once per window).
static func compose(w: HudWindow, builder: UiBuilder) -> AcademyJudgeWindow:
	if w == null:
		return null
	if w.has_meta(META):
		return w.get_meta(META) as AcademyJudgeWindow
	var j := AcademyJudgeWindow.new()
	j.window = w
	j._builder = builder
	j._build()
	w.set_meta(META, j)
	return j

static func of(w: HudWindow) -> AcademyJudgeWindow:
	return w.get_meta(META) as AcademyJudgeWindow if w != null and w.has_meta(META) else null

func _build() -> void:
	var group := window.node(RADIO)
	if group != null:
		group.mouse_filter = Control.MOUSE_FILTER_PASS
		for i in ITEMS.size():
			var at := Vector2(PITCH * i, 0)
			var dot := TextureButton.new()
			dot.name = "Item%d" % i
			UiSounds.hook_cif_button(dot, dot.name)
			dot.ignore_texture_size = true
			dot.stretch_mode = TextureButton.STRETCH_SCALE
			dot.position = at
			dot.size = DOT_SIZE
			dot.custom_minimum_size = DOT_SIZE
			dot.pressed.connect(choose.bind(i))
			group.add_child(dot)
			_dots.append(dot)
			var lbl := Label.new()
			lbl.name = "Label%d" % i
			lbl.text = _text(ITEMS[i], FALLBACK[i])
			lbl.vertical_alignment = VERTICAL_ALIGNMENT_TOP
			lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
			lbl.position = at + Vector2(LABEL_DX, LABEL_DY)
			lbl.size = Vector2(LABEL_W, LABEL_H)
			if _builder != null and _builder.font_at(0) != null:
				lbl.add_theme_font_override("font", _builder.font_at(0))
				lbl.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[0])
			group.add_child(lbl)
	var ok := window.node(BTN_CONFIRM) as BaseButton
	if ok != null:
		ok.pressed.connect(press_evaluate)
	var cancel := window.node(BTN_CANCEL) as BaseButton
	if cancel != null:
		cancel.pressed.connect(func() -> void: window.hide())
	reset()

## Each open starts at the constructor's state (index 1, evaluation 3; the
## client builds the window at every open, c:0x79d290).
func reset() -> void:
	index = DEFAULT_INDEX
	evaluation = INDEX_TO_BYTE[DEFAULT_INDEX]
	_paint()

func choose(i: int) -> void:
	if i < 0 or i >= ITEMS.size():
		return
	index = i
	evaluation = INDEX_TO_BYTE[i]
	_paint()

func _paint() -> void:
	var on_tex := _builder.load_texture(PartyMatchBox.RADIO_ON) if _builder != null else null
	var off_tex := _builder.load_texture(PartyMatchBox.RADIO_OFF) if _builder != null else null
	for i in _dots.size():
		_dots[i].texture_normal = on_tex if i == index else off_tex

func press_evaluate() -> void:
	evaluated.emit(evaluation)
	window.hide()

func _text(key: String, fallback: String) -> String:
	if _builder == null:
		return fallback
	var t := _builder.resolve_text(key)
	return fallback if t == "" or t == key else t
