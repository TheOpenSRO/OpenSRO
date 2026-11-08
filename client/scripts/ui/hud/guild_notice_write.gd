extends PartyMatchBox
class_name GuildNoticeWrite

## Round 844: CIFGuildNotifyWrite, the guild notice's write window
## (GDR_GUILD_NOTIFY_WRITE, ginterface id 47: 439 x 307 on msgbox2_window_;
## resinfo\ifguildnotifywrite.txt). READ in sro_client.exe:
## - opened by the notice bar's pencil (47 -> 222 -> 81, message map 0x51 ->
##   0x5b3cb0 -> 0x79b380(1, 1)), mode 1 (+0x7cc; mode 2 is the academy's
##   training camp notice, SendTrainingCamp_HandleNoticeUpdate: round 865,
##   set_mode);
## - Create (0x70ba50): the title edit 10 (+0x7b0) takes 0x7f characters, the
##   body edit 11 (+0x7b4) 0x3ff (0x634f80 at 0x70bbea / 0x70bbfa);
## - every frame (vslot_012 0x70b6c0) the line 2 shows
##   UIIT_MSG_GUILD_COMMON_KNOW_REMIND with the body's length and 0x3ff;
## - Completed (12, UIIT_CTL_GUILD_WRITE_END; 0x70b7b0): an empty title is the
##   local error 0x4c22, an empty body 0x4c23 (category 0x10), else 0x70F9
##   {title, body} is sent (SendGuild_HandleNoticeUpdate 0x824360) and the
##   window closes; Cancel (13) closes it.
## OURS: the body edit is a TextEdit (Godot's LineEdit is one line), given
## CIFEdit's caret, colour and rules (round 848, CifEdit.style_text_edit: no
## selection, menu, shortcuts or click placement); the window starts empty
## (whether the original pre-fills the current notice was not read -- OPEN).
## OPEN: the multi-line CIFEdit's line pitch and its own scroll bar (style
## 0x40's 0x635070); Enter makes a new line, as that style's WM_CHAR does
## (0x637290 case 0xd, READ).

const LAYOUT := "resinfo\\ifguildnotifywrite.txt"
const SIZE := Vector2(439, 307)
const TITLE_EDIT := "GDR_GUILD_NOTIFY_WRITE_SUBJECT"
const BODY_EDIT := "GDR_GUILD_NOTIFY_WRITE_CONTENTS"
const COUNT_LINE := "GDR_GUILD_NOTIFY_WRITE_STA_CONTENTS"
const BTN_OK := "GDR_GUILD_NOTIFY_WRITE_OK_BTN"
const BTN_CANCEL := "GDR_GUILD_NOTIFY_WRITE_CANCEL_BTN"
const TITLE_MAX := 0x7f
const BODY_MAX := 0x3ff
const CODE_NO_TITLE := 0x4c22
const CODE_NO_BODY := 0x4c23

## Completed with both filled: the owner sends 0x70F9.
signal submitted(title: String, body: String)
## A local refusal (0x4c22 / 0x4c23) for the system window.
signal refused(code: int)

var body_edit: TextEdit

func build_write(builder: UiBuilder) -> bool:
	name = "GuildNoticeWrite"
	if not build_shell(builder, SIZE, "", "", LAYOUT):
		return false
	caption.visible = false
	var t := setup_edit(TITLE_EDIT, TITLE_MAX, "")
	if t == null:
		t = _find_edit(TITLE_EDIT)
	if t != null:
		t.max_length = TITLE_MAX
	_body_edit()
	var ok := button(BTN_OK)
	if ok != null:
		ok.pressed.connect(press_ok)
	var cancel := button(BTN_CANCEL)
	if cancel != null:
		cancel.pressed.connect(close)
	_count()
	return true

func _find_edit(control_name: String) -> LineEdit:
	return node(control_name) as LineEdit

## The body: a TextEdit over the layout's CIFEdit, capped at BODY_MAX.
func _body_edit() -> void:
	var host := node(BODY_EDIT)
	if host == null:
		return
	if host is LineEdit:
		(host as LineEdit).editable = false
		(host as LineEdit).visible = false
	body_edit = TextEdit.new()
	body_edit.name = "BodyText"
	body_edit.position = host.position
	body_edit.size = host.size
	body_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	# Round 848: ifguildnotifywrite.txt gives the body no scroll control
	# (MEASURED: its 14 controls hold no CIFVerticalScroll), so no bar shows;
	# the text still scrolls with the caret and the wheel.
	OriginalScroll.hide_bars(body_edit)
	for style in ["normal", "focus", "read_only"]:
		body_edit.add_theme_stylebox_override(style, StyleBoxEmpty.new())
	# The record's FontColor (the hidden CIFEdit's), CIFEdit's caret and rules.
	CifEdit.style_text_edit(body_edit, (host as CifEdit).colour() if host is CifEdit else Color.WHITE)
	if _builder != null and _builder.font_at(0) != null:
		body_edit.add_theme_font_override("font", _builder.font_at(0))
	body_edit.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[0])
	body_edit.text_changed.connect(func() -> void:
		if body_edit.text.length() > BODY_MAX:
			body_edit.text = body_edit.text.left(BODY_MAX)
			body_edit.set_caret_line(body_edit.get_line_count() - 1)
			body_edit.set_caret_column(body_edit.get_line(body_edit.get_line_count() - 1).length())
		_count())
	host.get_parent().add_child(body_edit)

func title_text() -> String:
	var e := node(TITLE_EDIT) as LineEdit
	return e.text if e != null else ""

func body_text() -> String:
	return body_edit.text if body_edit != null else ""

func set_texts(title: String, body: String) -> void:
	var e := node(TITLE_EDIT) as LineEdit
	if e != null:
		e.text = title.left(TITLE_MAX)
	if body_edit != null:
		body_edit.text = body.left(BODY_MAX)
	_count()

## 0x70b6c0: "(%d/Max.%d)" with the body's length and 0x3ff.
func _count() -> void:
	var fmt := text("UIIT_MSG_GUILD_COMMON_KNOW_REMIND", "Please enter the contents of the note.(%d/Max.%d)")
	if fmt.count("%d") >= 2:
		set_static(COUNT_LINE, fmt % [body_text().length(), BODY_MAX])

## Round 865: the window's mode (+0x7cc), set by 0x70b720 when it opens:
## 1 the guild's, 2 the academy's (the pencil of the academy window,
## c:0x6e8a90 -> 0x79b380(1, 2)). The mode sets the title static 53
## (GDR_GUILD_NOTIFY_WRITE_TITLE): UIIT_STT_GUILD_COMMON_KNOW in mode 1,
## UIIT_CTL_TC_COMMON ("Notice") in mode 2 (READ c:0x70b720). In mode 2
## Completed refuses an empty title or body with category 0x1d's 0x6817
## (UIIT_MSG_GUILD_COMMON_NOTEXIST, READ c:0x70b8a3) and otherwise sends
## 0x7477 {title, body} (SendTrainingCamp_HandleNoticeUpdate, c:0x824560).
const MODE_GUILD := 1
const MODE_ACADEMY := 2
const TITLE_STATIC := "GDR_GUILD_NOTIFY_WRITE_TITLE"
const CODE_ACADEMY_EMPTY := 0x6817
var mode := MODE_GUILD

func set_mode(m: int) -> void:
	mode = m
	if m == MODE_ACADEMY:
		set_static(TITLE_STATIC, text("UIIT_CTL_TC_COMMON", "Notice"))

## 0x70b7b0.
func press_ok() -> void:
	var t := title_text()
	var b := body_text()
	if mode == MODE_ACADEMY:
		if t == "" or b == "":
			refused.emit(CODE_ACADEMY_EMPTY)
			return
		submitted.emit(t, b)
		close()
		return
	if t == "":
		refused.emit(CODE_NO_TITLE)
		return
	if b == "":
		refused.emit(CODE_NO_BODY)
		return
	submitted.emit(t, b)
	close()
