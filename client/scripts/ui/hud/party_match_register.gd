extends PartyMatchBox
class_name PartyMatchRegister

## The Form party / Change entry dialog, CIFPartyMatchRegister (round 714,
## lane C2; party_gui.md §3 "The register dialog"). READ (sro_client.exe):
## - child 105 of the matching window (the PartyRegister section): 314x373 on
##   msgbox2_window_, caption UIIT_PAG_PARTYMATCH_RECORD ("Forming party"),
##   or UIIT_PAG_PARTYMATCH_MODIFY in modify mode; layout
##   ifpartymatchregister.txt (Create 0x73f820); centred on the screen when
##   made (0x7392c0 -> 0x798b70);
## - the objective radio (ID 40): origin (0, 0) (0x73f87c xor edx / xor ecx),
##   pitch 0x42, label x offset 0x16, label width 0x32, 4 items laid
##   horizontally (0x657c40(4, 1)): Hunting, Quest, Trade Union, Thief Union
##   (0xdb3ad0, 0xd9670c, 0xdb3a70, 0xdb3a10). The label alignment is not set
##   by Create (left, INFERRED from the radio's default not being read);
## - the job restriction (0x73f957..0x73fa14): trader / hunter get Trade
##   only, chosen; a thief Thief only; anyone else neither Trade nor Thief;
## - the level edits 42 / 43: 3 digits (0x634f80(3)), 1..0x6e, "1" and "110"
##   (`%d` of 1 and 0x6e, 0x73fa69 / 0x73facc);
## - the type line (0x73f1f0) in statics 45 / 47 from the settings block;
## - the title edit 49 (max 50); its default by objective (0x73f610),
##   replaced only while the title is still one of the defaults;
## - OK (0x73f370): min < 1 or max < min -> RECORD_ERROR_LEVEL, an empty
##   title (spaces pass) -> RECORD_ERROR_TITLE (type 4); else the register
##   (0x7069) or, in modify mode, the modify (0x706a) request, and the dialog
##   closes (vslot 0xac, as the auto dialog after its OK); OK has no upper
##   bound, the edits carry 1..0x6e (0x634ee0(1,0), 0x634f20(0x6e,0)), kept
##   here by clamping as typed (how CIFEdit applies the range was not read:
##   INFERRED).

const SIZE := Vector2(314, 373)
const LAYOUT := "resinfo\\ifpartymatchregister.txt"
const TITLE_MAX := 50

## OK passed the checks: the entry to send (modify true -> 0x706a).
signal submitted(entry: PartyMatchNet.Entry, modify: bool)
## A refusal line for the system message window, type 4.
signal refused(key: String)

var modify_mode := false
var _number := 0
var _flags := 0
var _defaults: Array[String] = []

## `flags` is the type byte the entry carries (the settings block's, or the
## registration's in modify mode); `job` the player's job state;
## `from_entry` fills the dialog in modify mode.
func build(builder: UiBuilder, flags: int, job: int, from_entry: PartyMatchNet.Entry = null) -> bool:
	name = "PartyMatchRegister"
	modify_mode = from_entry != null
	_flags = flags
	var cap_key := "UIIT_PAG_PARTYMATCH_MODIFY" if modify_mode else "UIIT_PAG_PARTYMATCH_RECORD"
	if not build_shell(builder, SIZE, cap_key, "Editing party" if modify_mode else "Forming party", LAYOUT):
		return false
	var labels: Array = []
	for i in 4:
		labels.append(text(PartyMatchNet.PURPOSE_KEYS[i], PartyMatchNet.PURPOSE_FALLBACKS[i]))
	build_radio(node("GDR_PARTYMATCH_REGISTER_OBJECT_RBTN"), "object", labels, Vector2.ZERO, 66, 22, 50, true, false)
	var allowed := PartyMatchNet.allowed_purposes(job)
	for i in 4:
		set_radio_enabled("object", i, allowed.has(i))
	for i in 4:
		_defaults.append(text(PartyMatchNet.DEFAULT_TITLE_KEYS[i], ""))
	for n in ["GDR_PARTYMATCH_REGISTER_LEVEL_MIN_EDIT", "GDR_PARTYMATCH_REGISTER_LEVEL_MAX_EDIT"]:
		var e := setup_edit(n, 3, "%d" % (PartyMatchNet.LEVEL_MIN if n.contains("MIN") else PartyMatchNet.LEVEL_MAX))
		if e != null:
			e.text_changed.connect(clamp_level.bind(e))
	var title := setup_edit("GDR_PARTYMATCH_REGISTER_MSG_EDIT", TITLE_MAX, "")
	radio_chosen.connect(_on_radio)
	choose("object", allowed[0])
	if modify_mode:
		_number = from_entry.number
		if allowed.has(from_entry.purpose):
			choose("object", from_entry.purpose)
		(node("GDR_PARTYMATCH_REGISTER_LEVEL_MIN_EDIT") as LineEdit).text = "%d" % from_entry.min_level
		(node("GDR_PARTYMATCH_REGISTER_LEVEL_MAX_EDIT") as LineEdit).text = "%d" % from_entry.max_level
		if title != null:
			title.text = from_entry.title
	_type_line()
	var ok := button("GDR_PARTYMATCH_REGISTER_OK_BTN")
	if ok != null:
		ok.pressed.connect(press_ok)
	var cancel := button("GDR_PARTYMATCH_REGISTER_CANCEL_BTN")
	if cancel != null:
		cancel.pressed.connect(close)
	return true

## 0x73f610: the default title follows the objective while the title is one.
func _on_radio(group: String, index: int) -> void:
	if group != "object":
		return
	var title := node("GDR_PARTYMATCH_REGISTER_MSG_EDIT") as LineEdit
	if title == null:
		return
	if title.text == "" or _defaults.has(title.text):
		title.text = _defaults[index] if index < _defaults.size() else ""

func _type_line() -> void:
	set_static("GDR_PARTYMATCH_REGISTER_EXP_STA", text("UIIT_STT_PARTY_EXP_SHARE", "Exp Auto Share") if _flags & PartyNet.FLAG_EXP_SHARE
		else text("UIIT_STT_PARTY_EXP_SELF", "Exp Free-For-All"))
	set_static("GDR_PARTYMATCH_REGISTER_ITEM_STA", text("UIIT_STT_PARTY_ITEM_SHARE", "Item Auto Share") if _flags & PartyNet.FLAG_ITEM_SHARE
		else text("UIIT_STT_PARTY_ITEM_SELF", "Item Free-For-All"))

## The edits' range 1..110 kept as typed (INFERRED, see the header).
static func clamp_level(text_now: String, e: LineEdit) -> void:
	if text_now == "":
		return
	var digits := ""
	for ch in text_now:
		if ch >= "0" and ch <= "9":
			digits += ch
	var v := clampi(int(digits) if digits != "" else 0, PartyMatchNet.LEVEL_MIN, PartyMatchNet.LEVEL_MAX)
	if str(v) != text_now:
		e.text = str(v)
		e.caret_column = e.text.length()

func entry() -> PartyMatchNet.Entry:
	var e := PartyMatchNet.Entry.new()
	e.number = _number
	e.flags = _flags
	e.purpose = choice("object")
	var lo := node("GDR_PARTYMATCH_REGISTER_LEVEL_MIN_EDIT") as LineEdit
	var hi := node("GDR_PARTYMATCH_REGISTER_LEVEL_MAX_EDIT") as LineEdit
	e.min_level = int(lo.text) if lo != null and lo.text.is_valid_int() else 0
	e.max_level = int(hi.text) if hi != null and hi.text.is_valid_int() else 0
	var title := node("GDR_PARTYMATCH_REGISTER_MSG_EDIT") as LineEdit
	e.title = title.text if title != null else ""
	return e

func press_ok() -> void:
	var e := entry()
	if e.min_level < PartyMatchNet.LEVEL_MIN or e.max_level < e.min_level:
		refused.emit("UIIT_MSG_PARTYMATCH_RECORD_ERROR_LEVEL")
		return
	if e.title == "":
		refused.emit("UIIT_MSG_PARTYMATCH_RECORD_ERROR_TITLE")
		return
	submitted.emit(e, modify_mode)
	close()
