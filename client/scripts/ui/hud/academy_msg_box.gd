extends PartyMatchConfirm
class_name AcademyMsgBox

## Round 865: the academy's questions -- GInterface 0x788270's MsgBoxSimple
## (PartyMatchConfirm's box: 0x643e50(0x168, 0x97), style 1 Yes / No, READ
## c:0x788270) with the text set by 0x643250, which lays the text out and
## sizes the box to it (0x6413a0, READ: the box is the text's width + 0x3c by
## its height + 0x7a, never smaller than 360 x 151; Yes at the centre - 0x51,
## No at the centre + 5, both 0x25 above the bottom).
## MEASURED: a one-line text gives 151 high, a two-line one 168 (the line
## pitch 23 of the box's list control, +0x39c); boxes: the disband question
## 498 x 168, the leave question 618 x 151, the invitation 402 x 167. The
## texts are the archive's own `<sml2>` (PmlText draws them, centred, white).
##
## The boxes (each READ):
## - Dismiss (c:0x6e8da0): UIIT_STT_TC_DISSOLUTION, caption
##   UIIT_STT_CONFIRM_BOX, window type 100; Yes -> 0x7471 (c:0x6e8830);
## - a row's button (c:0x6eb0f0, callback c:0x6ea6f0, types 100..103):
##   UIIT_MSG_TC_GRADUATION_COMPULSION(name) -> 0x7476, UIIT_STT_TC_BAN_
##   TRAININGCAMP(name) -> 0x7473, UIIT_STT_TC_OUT_TRAININGCAMP -> 0x7474,
##   UIIT_STT_TC_GRADUATION -> 0x7475 {0};
## - the invitation (0x3080 kind 9, c:0x88aba8): caption UIIT_PAG_PARTYMATCH_
##   JOINREQUEST, UIIT_STT_TC_JOIN_REQUEST(inviter), simple_msgbox_type 8, the
##   box's timer armed (0x644650); Yes {1, 1}, otherwise {2, 0, 0} (c:0x788840
##   case 8);
## - the founding fee (talk line 0x2d, c:0x6f8cb0(6)): UIIT_MSG_TC_
##   TRAININGCAMP_OPEN.

const LINE_PITCH := 23
const MIN_SIZE := Vector2(0x168, 0x97)
const TEXT_MARGIN := Vector2(0x3c, 0x7a)
## The invitation box's own timer (0x644650; 30 s as the party and guild
## boxes read it, INFERRED). The server answers 0x000E at 30 s regardless.
const INVITE_SECONDS := 30.0

## Yes pressed (the owner sends).
signal yes
## No pressed, or the box closed some other way.
signal no
## The invitation box's timer ran out.
signal expired

var kind := ""
var sml: PmlText
var _yes: BaseButton
var _no: BaseButton
var _timer := 0.0

## Builds the box with `markup` (an archive `<sml2>` text or plain text) and
## `caption_key`. False without the layout.
func build_academy(builder: UiBuilder, markup: String, caption_key: String = "UIIT_STT_CONFIRM_BOX",
		box_kind: String = "") -> bool:
	kind = box_kind
	if not build(builder, "", MIN_SIZE, caption_key):
		return false
	name = "AcademyBox"
	var plain := get_node_or_null("Message") as Label
	if plain != null:
		plain.visible = false
	sml = PmlText.new()
	sml.name = "Sml"
	sml.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sml.base_align = PmlText.TAG_CENTER
	add_child(sml)
	sml.setup(builder.font_at(0) if builder != null else null, UiBuilder.FONT_SIZES[0], Color.WHITE)
	var lines := text_lines(markup)
	var widest := 0.0
	for l in lines:
		widest = maxf(widest, sml.text_width(plain(l), 0))
	var text_size := Vector2(ceilf(widest), LINE_PITCH * lines.size())
	var box := Vector2(maxf(MIN_SIZE.x - TEXT_MARGIN.x, text_size.x), maxf(MIN_SIZE.y - TEXT_MARGIN.y, text_size.y)) + TEXT_MARGIN
	_resize(box)
	sml.position = Vector2(30, 65)
	sml.size = Vector2(box.x - 60, box.y - 122)
	sml.set_markup(markup)
	confirmed.connect(func() -> void: yes.emit())
	declined.connect(func() -> void: no.emit())
	return true

## The text's lines as 0x643250 breaks them: at `<br>` (and a newline).
static func text_lines(markup: String) -> Array:
	var s := markup.replace("<sml2>", "").replace("</sml2>", "").replace("\n", "<br>")
	return Array(s.split("<br>"))

## A line without its tags.
static func plain(line: String) -> String:
	var re := RegEx.new()
	re.compile("<[^>]*>")
	return re.sub(line, "", true)

func _resize(box: Vector2) -> void:
	var grow := box - size
	size = box
	custom_minimum_size = box
	var frame := get_node_or_null("Frame") as Control
	if frame != null:
		frame.set_meta(UiBuilder.AUTHORED_RECT_META, Rect2(Vector2.ZERO, box))
		frame.size = box
	if caption != null:
		caption.size = Vector2(box.x - 21, 12)
	for base in get_children():
		var tile := base.get_node_or_null("GDR_MSGBOX_BG") as Control
		if tile != null:
			var r := Rect2(tile.position, Vector2(box.x - 32, box.y - 56))
			tile.set_meta(UiBuilder.AUTHORED_RECT_META, r)
			tile.size = r.size
	# The buttons keep their distance from the bottom, at the new centre.
	# Both found before either moves (_find_button orders them by x).
	var centre := box.x / 2.0
	var yes_b := _find_button(true)
	var no_b := _find_button(false)
	for spec in [[yes_b, centre - 0x51], [no_b, centre + 5]]:
		var b: BaseButton = spec[0]
		if b == null:
			continue
		var at := Vector2(float(spec[1]), b.position.y + grow.y)
		b.position = at
		b.set_meta(UiBuilder.AUTHORED_RECT_META, Rect2(at, b.size))
	_yes = yes_b
	_no = no_b

## The invitation's timer.
func arm_timer(seconds: float = INVITE_SECONDS) -> void:
	_timer = seconds
	set_process(true)

func _process(delta: float) -> void:
	if _timer <= 0.0:
		return
	_timer -= delta
	if _timer <= 0.0:
		expired.emit()
		close()

## The Yes and No buttons as placed (QA, tests).
func yes_button() -> BaseButton:
	return _yes

func no_button() -> BaseButton:
	return _no

## Yes / No by code (tests).
func press(accept: bool) -> void:
	var b := _yes if accept else _no
	if b != null:
		b.pressed.emit()
