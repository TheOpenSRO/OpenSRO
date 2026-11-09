extends HudCosBox
class_name AcademyJoinAskBox

## Round 866: the guardian's question when a player asks to join its academy
## through the matching board -- CMessageBoxManager box kind 0xe, opened by
## 0x747E down (c:0x890fa0 -> 0x77f0a0(mgr, 0xe, record)). READ from
## sro_client.exe, UI_SILKMALL::FUN_00644c90's case for kind 0xe (jump table
## 0x648758 index 13 -> c:0x6458c6..0x645c54), unless a line says otherwise:
##
## - the box (section MsgBoxINIF, 0x6ec5d0, placed at screen w / 2 - 0x9a,
##   h / 2 - 0x4a) keeps the record's two leading u32s at +0xad4 / +0xad8
##   (the job id and the requester), is titled UIIT_PAG_PARTYMATCH_JOINREQUEST
##   and resized to 0x168 x 0xd7 (360 x 215);
## - OK (+0x800) moved to (0x65, 0xae), Cancel (+0x804) to (0xbd, 0xae),
##   +0x808 hidden;
## - a text control made at 0x140 x 0x10 and moved to (0xe, 0x3b) carries
##   UIIT_STT_TC_JOIN_REQUEST with the requester's name; one line tall, so
##   the text's second half is cut (MEASURED: "[name] has requested for
##   Academy" shows, the rest of the line and "Approve?" do not);
## - +0x844 UIIT_CTL_WARENETWORK_RESULT_LEVEL ("Level") at (0xf, 0x79) and
##   +0x848 UIIT_CTL_PARTYMATCH_PSEARCH_LIST_RACE ("Race") at (0xb5, 0x79),
##   0x3a x 0xb each;
## - +0x84c and +0x850 on interface\messagebox\msgbox_blackbox.ddj, 0x3a x
##   0x14, at (0x62, 0x79) and (0x108, 0x79): "%d(%d)" of the level and the
##   max level, and the race of the requester's body (byte +0x9c of its
##   model record: 0 UIIT_CTL_PARTYMATCH_AUTOMATCH_RACE_CH, 1 _EU, else
##   nothing);
## - timer 0xa armed for 0x3a98 ms (15 s); when it fires the box answers as
##   No does (c:0x63bf40 -> 0x777dd0 -> 0x797d90 case 0xe: 0x347F with 0;
##   MEASURED: 0x347F {.., 00} 15.0 s after the question). Yes sends 1
##   (c:0x798081..0x7980c2).
## MEASURED: the box, its "Level 30(30)" / "Race CHN" row and Yes / No as
## above. +0x844..+0x850 as the section's MESSAGE2..MESSAGE5 is INFERRED, as
## GuildMsgBox takes +0x840.. for MESSAGE1..5.

const SIZE := Vector2(0x168, 0xd7)
const OK_AT := Vector2(0x65, 0xae)
const CANCEL_AT := Vector2(0xbd, 0xae)
const TEXT_RECT := Rect2(0xe, 0x3b, 0x140, 0x10)
const LEVEL_LABEL_RECT := Rect2(0xf, 0x79, 0x3a, 0xb)
const RACE_LABEL_RECT := Rect2(0xb5, 0x79, 0x3a, 0xb)
const LEVEL_BOX_RECT := Rect2(0x62, 0x79, 0x3a, 0x14)
const RACE_BOX_RECT := Rect2(0x108, 0x79, 0x3a, 0x14)
const BLACKBOX := "interface\\messagebox\\msgbox_blackbox.ddj"
const TIMEOUT_SEC := 15.0

## The answer: true for Yes, false for No or the timer.
signal answered(accept: bool)

var ask: Dictionary = {}
var sml: PmlText
var _left := TIMEOUT_SEC
var _done := false

## `ask` is AcademyNet.decode_join_ask's; `race` 0 / 1 / -1 from the body.
func build_join_ask(builder: UiBuilder, the_ask: Dictionary, race: int) -> bool:
	ask = the_ask
	name = "AcademyJoinAsk"
	if not build_shell(builder, SIZE, "UIIT_PAG_PARTYMATCH_JOINREQUEST", "UIIT_PAG_PARTYMATCH_JOINREQUEST", LAYOUT, "MsgBoxINIF"):
		return false
	_add_background(builder, SIZE)
	var msg1 := node("GDR_MBIN_STATIC_MESSAGE1")
	if msg1 != null:
		builder.set_static_text(msg1, "")
	# The one-line text control.
	var holder := Control.new()
	holder.name = "JoinRequestText"
	holder.clip_contents = true
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_place(holder, TEXT_RECT)
	add_child(holder)
	sml = PmlText.new()
	sml.name = "Sml"
	sml.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sml.base_align = PmlText.TAG_CENTER
	sml.position = Vector2.ZERO
	sml.size = Vector2(TEXT_RECT.size.x, 64)
	holder.add_child(sml)
	sml.setup(builder.font_at(0), UiBuilder.FONT_SIZES[0], Color.WHITE)
	sml.set_markup(_format("UIIT_STT_TC_JOIN_REQUEST", String(ask.get("name", ""))))
	var lvl := node("GDR_MBIN_STATIC_MESSAGE2")
	if lvl != null:
		_place(lvl, LEVEL_LABEL_RECT)
		builder.set_static_text(lvl, text("UIIT_CTL_WARENETWORK_RESULT_LEVEL", "UIIT_CTL_WARENETWORK_RESULT_LEVEL"))
	var rce := node("GDR_MBIN_STATIC_MESSAGE3")
	if rce != null:
		_place(rce, RACE_LABEL_RECT)
		builder.set_static_text(rce, text("UIIT_CTL_PARTYMATCH_PSEARCH_LIST_RACE", "UIIT_CTL_PARTYMATCH_PSEARCH_LIST_RACE"))
	var level_text := "%d(%d)" % [int(ask.get("level", 0)), int(ask.get("max_level", 0))]
	var race_text := ""
	if race == 0 or race == 1:
		race_text = text(PartyMatchNet.RACE_KEYS[race], PartyMatchNet.RACE_FALLBACKS[race])
	for spec in [["GDR_MBIN_STATIC_MESSAGE4", LEVEL_BOX_RECT, level_text], ["GDR_MBIN_STATIC_MESSAGE5", RACE_BOX_RECT, race_text]]:
		var n := node(spec[0])
		if n == null:
			continue
		var r: Rect2 = spec[1]
		# The static's own art (its +0x84 texture), drawn at its rect; a
		# Label keeps its font's line height as its least height, so the
		# art is a sibling at the exact rect and the text centred on it.
		var bg := TextureRect.new()
		bg.name = "%s_Blackbox" % n.name
		bg.texture = builder.load_texture(BLACKBOX)
		bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		bg.stretch_mode = TextureRect.STRETCH_SCALE
		bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_place(bg, r)
		n.get_parent().add_child(bg)
		n.get_parent().move_child(bg, n.get_index())
		_place(n, r)
		var l := builder.set_static_text(n, String(spec[2]))
		if l != null:
			l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		var h := maxf(r.size.y, n.get_combined_minimum_size().y)
		_place(n, Rect2(r.position.x, r.position.y + floorf((r.size.y - h) / 2.0), r.size.x, h))
	var certify := node("GDR_MBIN_BTN_CERTIFY")
	if certify != null:
		certify.visible = false
	_wire(node("GDR_MBIN_BTN_OK"), OK_AT, press_yes)
	_wire(node("GDR_MBIN_BTN_CANCEL"), CANCEL_AT, press_no)
	set_process(true)
	return true

## The archive's text for `key` with its one %s filled (the key itself
## without the archive).
func _format(key: String, value: String) -> String:
	var fmt := text(key, key)
	return fmt.replace("%s", value) if fmt.count("%s") == 1 else fmt

## CMessageBoxManager's placement (0x6ec5d0): the 308 x 148 box's top left,
## kept when the kind resizes it.
func place_on(view: Vector2) -> void:
	position = Vector2(floorf(view.x / 2.0) - 0x9a, floorf(view.y / 2.0) - 0x4a)

func press_yes() -> void:
	_answer(true)

func press_no() -> void:
	_answer(false)

func _answer(accept: bool) -> void:
	if _done:
		return
	_done = true
	answered.emit(accept)
	close()

## The box's 15 s timer (timer 0xa): answers as No does.
func advance(sec: float) -> void:
	if _done:
		return
	_left -= sec
	if _left <= 0.0:
		_answer(false)

func _process(delta: float) -> void:
	advance(delta)

## The shown texts, for tests and the QA log.
func shown_text() -> String:
	var parts: Array = [caption.text if caption != null else ""]
	for n in ["GDR_MBIN_STATIC_MESSAGE2", "GDR_MBIN_STATIC_MESSAGE4", "GDR_MBIN_STATIC_MESSAGE3", "GDR_MBIN_STATIC_MESSAGE5"]:
		parts.append(AcademyWindow.text_of(node(n)))
	return "|".join(parts)
