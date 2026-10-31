extends RefCounted
class_name MsgBoxFixture

## Test support (round 848, lane H): a UiBuilder whose layout cache holds a
## synthetic resinfo\ifmessagebox.txt -- the Create, MsgBoxSimple, MsgBoxINIF
## and MsgBoxInsertMsg sections with the controls' real names, types, IDs and
## rects (MEASURED from Media.pk2 with tools/dump_layout.gd), no art -- and a
## text table giving each key in angle brackets ("<KEY>") plus the few rows
## whose own text a test reads. Nothing from the archive is committed.

static func _c(control_name: String, type: String, rect: String, id: int, text: String = "",
		ddj: String = "", halign: int = 0, colour: String = "") -> String:
	var fc := "\t\tFontColor=COLOR,\"%s\"\n" % colour if colour != "" else ""
	return "\t%s:%s\n\t{\n\t\tDDJ=STRING,\"%s\"\n\t\tFontIndex=INTEGER,\"0\"\n%s\t\tHAlign=INTEGER,\"%d\"\n\t\tID=INTEGER,\"%d\"\n\t\tRect=RECT,\"%s\"\n\t\tText=STRING,\"%s\"\n\t}\n" % [
		control_name, type, ddj, fc, halign, id, rect, text]

static func _section(section: String, body: String) -> String:
	return "Section = %s,\"0,0,0,0\",\"0\"\n{\n%s}\n" % [section, body]

static func ifmessagebox() -> String:
	var inif := ""
	inif += _c("GDR_MBIN_STATIC_MESSAGE5", "CIFStatic", "6,154,294,12", 8, "", "", 1)
	inif += _c("GDR_MBIN_BTN_CERTIFY", "CIFButton", "112,99,76,24", 202, "UIIT_CTL_CONFIRM", "", 1)
	inif += _c("GDR_MBIN_BTN_CANCEL", "CIFButton", "152,99,76,24", 201, "UIIT_CTL_NO", "", 1)
	inif += _c("GDR_MBIN_BTN_OK", "CIFButton", "72,99,76,24", 200, "UIIT_CTL_YES", "", 1)
	inif += _c("GDR_MBIN_STATIC_MESSAGE_PML", "CIFPML", "6,82,300,60", 9, "", "", 1)
	inif += _c("GDR_MBIN_STATIC_MESSAGE4", "CIFStatic", "6,66,288,12", 4, "", "", 1)
	inif += _c("GDR_MBIN_STATIC_MESSAGE3", "CIFStatic", "6,66,288,12", 3, "", "", 1)
	inif += _c("GDR_MBIN_STATIC_MESSAGE2", "CIFStatic", "6,70,300,12", 2, "", "", 1)
	inif += _c("GDR_MBIN_STATIC_MESSAGE1", "CIFStatic", "0,52,300,12", 1, "", "", 1)
	var simple := ""
	simple += _c("GDR_SIMPLE_BTN_CANCEL", "CIFButton", "152,99,76,24", 253, "UIIT_CTL_NO", "", 1)
	simple += _c("GDR_SIMPLE_BTN_OK", "CIFButton", "72,99,76,24", 252, "UIIT_CTL_YES", "", 1)
	simple += _c("GDR_SIMPLE_TEXTBOX_MESSAGE", "CIFTextBox", "0,52,240,14", 251)
	var ins := ""
	ins += _c("GDR_MB_INSERT_MSG_BTN_CANC", "CIFButton", "216,104,76,24", 206, "UIIT_CTL_CANCEL", "", 1)
	ins += _c("GDR_MB_INSERT_MSG_BTN_OK", "CIFButton", "128,104,76,24", 205, "UIIT_CTL_CONFIRM", "", 1)
	ins += _c("GDR_MB_INSERT_MSG_EDIT", "CIFEdit", "9,62,100,20", 15, "", "", 0, "255,250,240,200")
	ins += _c("GDR_MB_INSERT_MSG_EDIT_BG", "CIFNormalTile", "13,70,396,24", 12, "", "interface\\ifcommon\\bg_tile\\com_bg_tile_e.ddj")
	ins += _c("GDR_MB_INSERT_MSG_EDIT_FRAME", "CIFFrame", "9,66,400,28", 11, "", "interface\\frame\\frame_msg_")
	ins += _c("GDR_MB_INSERT_MSG_TITLE", "CIFStatic", "0,48,420,12", 10, "UIIT_STT_INSERT_OWNER_MESSAGE", "", 1)
	var create := _c("GDR_MSGBOX_BG", "CIFNormalTile", "16,40,284,122", 0, "", "interface\\ifcommon\\bg_tile\\com_bg_tile_b.ddj")
	return "Interface Text\n\n" + _section("Create", create) + _section("MsgBoxSimple", simple) \
		+ _section("MsgBoxINIF", inif) + _section("MsgBoxInsertMsg", ins)

## The keys every box here reads, each shown as "<KEY>".
const KEYS := ["UIIT_STT_AGREEMENT_BOX", "UIIT_STT_CONFIRM_BOX", "UIIT_STT_INPUT_BOX", "UIIT_CTL_YES", "UIIT_CTL_NO",
	"UIIT_CTL_CANCEL", "UIIT_CTL_CONFIRM", "UIIT_MSG_MSGBOX_SETREBIRTH_ASKCERTIFY", "UIIT_MSG_QUESTION_SILKMALL_ITEM_USE",
	"UIIT_MSG_QUESTION_SILKMALL_ITEM_USE_CANCLE_1", "UIIT_MSG_QUESTION_SILKMALL_ITEM_USE_CANCLE_2",
	"UIIT_MSG_GUILD_NAME_INPUT", "UIIT_MSG_MSGBOX_REBIRTH_POINT_BUTTON", "UIIT_MSG_MSGBOX_REBIRTH_STANDING_BUTTON",
	"UIIT_MSG_MSGBOX_REBIRTH_HELP_BUTTON", "UIIT_MSG_QUEST_GIVEUP_WINDOW_1"]

## The builder; `extra_keys` adds more "<KEY>" rows.
static func builder(extra_keys: Array = []) -> UiBuilder:
	var rows := PackedStringArray()
	for k in KEYS + extra_keys:
		rows.append("1\t%s\t\t\t\t\t\t\t<%s>" % [k, k])
	rows.append("1\tUIIT_MSG_MSGBOX_SETREBIRTH_CURPOS\t\t\t\t\t\t\tThe current position : [%s]")
	rows.append("1\tUIIT_MSG_MSGBOX_ASK_SELF_REBIRTH_1\t\t\t\t\t\t\t\"\"\"<sml2>the character <font color=\"\"\"\"255,255,217,83\"\"\"\"> is now </font>paralyzed.</sml2>\"\"\"")
	var builder := UiBuilder.new(null, UiTextTable.parse(("\n".join(rows)).to_utf16_buffer()))
	var cache: Dictionary = builder.get("_layout_cache")
	cache["resinfo\\ifmessagebox.txt"] = UiLayoutParser.parse(ifmessagebox())
	return builder

