extends PartyMatchBox
class_name JobAliasBox

## Round 799: CIFJobAlias, the alias window (GDR_JOB_ALIAS, registry id 63;
## resinfo\ifjobalias.txt). READ in sro_client.exe (docs/protocol/jobs.md,
## "The alias window"):
## - opened by the talk lines 0x20 (create) and 0x21 (change) through
##   FUN_0079c850(1, mode, npc); mode byte +0x7b0, the NPC at +0x7b4;
## - 297 x 165 (create) or 297 x 180 (change), the caption UIIT_PAG_ALIAS_CREATE
##   or UIIT_PAG_ALIAS_MODIFY (0x74b6c0); a change also loads the layout's
##   AliasModify section, whose cost static (43) shows level x 50,000 grouped
##   (0x74b82d..0x74b881);
## - on open Check is on, OK off (0x74b8f0..0x74b924);
## - Check (20, 0x74ae10): the edit's text 2..12 bytes long and passing the
##   name rule (FUN_008c3cb0) or the local error 0x4823; then 0x70e3 {npc, 0,
##   alias};
## - the 0xB0E3 op-0 success (FUN_0074ad60) marks the name checked: Check off,
##   OK on; an edit change away from the checked name turns them back
##   (0x74afe0);
## - OK (30, 0x74b950 -> 0x74b110) asks UIIT_STT_CONFIRM_BOX with
##   UIIT_STT_ALIAS_CREATE_WINDOW (the character's name, the alias) or
##   _MODIFY_WINDOW (old, new, cost); its yes sends 0x70e3 {npc, 1, alias}
##   (0x74ac80) and closes the window.
## - FUN_008c3cb0 is the abuse filter's name test (the +0x2018 substring list
##   and the +0x2048 word set, flag 1): NameFilter.name_ok, injected as
##   `name_rule` (the server's FUN_004184a0 tests again).

const LAYOUT := "resinfo\\ifjobalias.txt"
const SIZE_CREATE := Vector2(297, 165)
const SIZE_MODIFY := Vector2(297, 180)
const EDIT := "GDR_JOB_ALIAS_EDIT_NAME"
const BTN_CHECK := "GDR_JOB_ALIAS_BTN_CHECK"
const BTN_OK := "GDR_JOB_ALIAS_BTN_OK"
const BTN_CANCEL := "GDR_JOB_ALIAS_BTN_CANCEL"
const COST := "GDR_JOB_ALIAS_COST"

## 0x70e3 op 0 to send.
signal check_requested(npc: int, alias: String)
## The confirm box's yes: 0x70e3 op 1.
signal set_requested(npc: int, alias: String)
## A local refusal (code 0x4823) for the system window.
signal refused(code: int)
## The confirm box to place (the window's host centres it).
signal confirm_opened(box: JobConfirmBox)

var modify := false
var npc := 0
var old_alias := ""
var char_name := ""
var level := 0
var _checked := ""
## NameFilter.name_ok (FUN_008c3cb0); unset, only the length is tested.
var name_rule: Callable

func build_alias(builder: UiBuilder, modify_mode: bool, npc_uid: int, current_alias: String, character: String,
		character_level: int) -> bool:
	modify = modify_mode
	npc = npc_uid
	old_alias = current_alias
	char_name = character
	level = character_level
	name = "JobAlias"
	var cap := "UIIT_PAG_ALIAS_MODIFY" if modify else "UIIT_PAG_ALIAS_CREATE"
	if not build_shell(builder, SIZE_MODIFY if modify else SIZE_CREATE, cap, "Change alias" if modify else "Create alias", LAYOUT):
		return false
	if modify:
		var layout: UiLayoutParser.LayoutDef = builder.load_layout(LAYOUT)
		if layout != null and layout.sections.has("AliasModify"):
			var extra := builder.build_section(layout, "AliasModify")
			if extra != null:
				extra.name = "AliasModify"
				add_child(extra)
				UiBuilder.settle_authored_rects(extra)
				var cost := extra.get_node_or_null(COST)
				if cost != null:
					builder.set_static_text(cost, JobText.grouped(level * 50000))
	var e := setup_edit(EDIT, JobNet.ALIAS_MAX, "")
	if e != null:
		e.text_changed.connect(_on_edit)
	var check := button(BTN_CHECK)
	if check != null:
		check.pressed.connect(press_check)
	var ok := button(BTN_OK)
	if ok != null:
		ok.disabled = true
		ok.pressed.connect(press_ok)
	var cancel := button(BTN_CANCEL)
	if cancel != null:
		cancel.pressed.connect(close)
	return true

func alias_text() -> String:
	var e := node(EDIT) as LineEdit
	return e.text if e != null else ""

## The client's test before 0x70e3 op 0 (0x74ae10): 2..12 bytes, then the
## name rule.
static func locally_ok(alias: String, rule: Callable = Callable()) -> bool:
	var n := alias.to_utf8_buffer().size()
	if n < JobNet.ALIAS_MIN or n > JobNet.ALIAS_MAX:
		return false
	return not rule.is_valid() or bool(rule.call(alias))

func press_check() -> void:
	var a := alias_text()
	if not locally_ok(a, name_rule):
		refused.emit(JobNet.ERR_ALIAS_RULE)
		return
	if a == old_alias:
		return
	check_requested.emit(npc, a)

## 0xB0E3 op 0's success: the name is checked.
func on_checked(alias: String) -> void:
	if alias != alias_text():
		return
	_checked = alias
	var check := button(BTN_CHECK)
	var ok := button(BTN_OK)
	if check != null:
		check.disabled = true
	if ok != null:
		ok.disabled = false

func _on_edit(t: String) -> void:
	if t == _checked:
		return
	_checked = ""
	var check := button(BTN_CHECK)
	var ok := button(BTN_OK)
	if check != null:
		check.disabled = false
	if ok != null:
		ok.disabled = true

func press_ok() -> void:
	if _checked == "" or _checked != alias_text():
		return
	var box := JobConfirmBox.new()
	var sml := ""
	if modify:
		sml = text("UIIT_STT_ALIAS_MODIFY_WINDOW", "<sml2><center>Change alias from [%s]to [%s].<br>[%s]gold will be spent.</center></sml2>")
		sml = _format3(sml, old_alias, _checked, JobText.grouped(level * 50000))
	else:
		sml = text("UIIT_STT_ALIAS_CREATE_WINDOW", "<sml2><center>Create [%s]'s alias as [%s].</center></sml2>")
		sml = _format3(sml, char_name, _checked, "")
	if not box.build_sml(_builder, sml):
		box.queue_free()
		return
	var chosen := _checked
	box.confirmed.connect(func() -> void:
		set_requested.emit(npc, chosen)
		close())
	confirm_opened.emit(box)

## The text's %s in order (the client's _swprintf_s, READ 0x74b110).
static func _format3(fmt: String, a: String, b: String, c: String) -> String:
	var out := fmt
	for v in [a, b, c]:
		var i := out.find("%s")
		if i < 0:
			break
		out = out.substr(0, i) + v + out.substr(i + 2)
	return out
