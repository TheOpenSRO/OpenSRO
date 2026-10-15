extends RefCounted

## A synthetic `resinfo\ifextquickslot.txt` and `resinfo\ifextquickslotoption.txt`
## for the Additional Quick Slot suite (round 788): the ids, types, rects and
## art NAMES of the controls CIFExtQuickSlot and CIFExtQuickSlotOption touch,
## generated here from the measured tables in docs/protocol/ext_quick_slot.md
## -- no file of the archive is copied (docs/LEGAL.md). The art is blank
## images of the measured sizes, put in the builder's texture cache; the text
## rows are made up ("tt").

const LAYOUT := "resinfo\\ifextquickslot.txt"
const OPTION_LAYOUT := "resinfo\\ifextquickslotoption.txt"
const QS := "interface\\quick_slot\\"

## Per type (Type1..Type4): WND art and rect, OPT / HORI / VERT / ONOFF at,
## the collapse art, END art and at, board art, the boards' origin and step,
## the slots' origins (MEASURED, round 788).
const TYPES := [
	{"wnd": "qsl_hriz01_windo", "wnd_rect": Rect2i(0, 0, 44, 40), "opt": Vector2i(14, 1), "hori": Vector2i(14, 13),
		"vert": Vector2i(14, 25), "onoff": Vector2i(26, 1), "onoff_art": "qsl_hopen_button", "end": "qsl_hriz01_end",
		"end_at": Vector2i(401, 0), "board": "qsl_hriz01_slot_tile", "boards": 10, "board_at": Vector2i(41, 0),
		"step": Vector2i(36, 0)},
	{"wnd": "qsl_hriz02_windo", "wnd_rect": Rect2i(0, 0, 32, 76), "opt": Vector2i(14, 37), "hori": Vector2i(14, 49),
		"vert": Vector2i(14, 61), "onoff": Vector2i(14, 1), "onoff_art": "qsl_hopen_button", "end": "qsl_hriz02_end",
		"end_at": Vector2i(209, 0), "board": "qsl_hriz02_slot_tile", "boards": 5, "board_at": Vector2i(29, 0),
		"step": Vector2i(36, 0)},
	{"wnd": "qsl_vrtl01_windo", "wnd_rect": Rect2i(0, 0, 44, 44), "opt": Vector2i(2, 14), "hori": Vector2i(14, 14),
		"vert": Vector2i(26, 14), "onoff": Vector2i(2, 26), "onoff_art": "qsl_vopen_button", "end": "qsl_vrtl01_end",
		"end_at": Vector2i(0, 41), "board": "qsl_vrtl01_slot_tile", "boards": 10, "board_at": Vector2i(0, 41),
		"step": Vector2i(0, 36)},
	{"wnd": "qsl_vrtl02_windo", "wnd_rect": Rect2i(0, 0, 80, 32), "opt": Vector2i(38, 14), "hori": Vector2i(50, 14),
		"vert": Vector2i(62, 14), "onoff": Vector2i(2, 14), "onoff_art": "qsl_vopen_button", "end": "qsl_vrtl02_end",
		"end_at": Vector2i(0, 29), "board": "qsl_vrtl02_slot_tile", "boards": 5, "board_at": Vector2i(0, 29),
		"step": Vector2i(0, 36)},
]

## The art's sizes (MEASURED from the archive's own files, round 788).
const ART_SIZES := {
	"qsl_hriz01_windo": Vector2i(44, 40), "qsl_hriz02_windo": Vector2i(32, 76),
	"qsl_vrtl01_windo": Vector2i(44, 44), "qsl_vrtl02_windo": Vector2i(80, 32),
	"qsl_opt_button": Vector2i(16, 16), "qsl_hriz_button": Vector2i(16, 16), "qsl_vrtl_button": Vector2i(16, 16),
	"qsl_hopen_button": Vector2i(16, 40), "qsl_hclose_button": Vector2i(16, 40),
	"qsl_vopen_button": Vector2i(40, 14), "qsl_vclose_button": Vector2i(40, 14),
	"qsl_hriz01_end": Vector2i(4, 40), "qsl_hriz02_end": Vector2i(4, 76),
	"qsl_vrtl01_end": Vector2i(44, 4), "qsl_vrtl02_end": Vector2i(80, 4),
	"qsl_hriz01_slot_tile": Vector2i(36, 40), "qsl_hriz02_slot_tile": Vector2i(36, 76),
	"qsl_vrtl01_slot_tile": Vector2i(44, 36), "qsl_vrtl02_slot_tile": Vector2i(80, 36),
	"qsl_left_arrow": Vector2i(12, 20), "qsl_right_arrow": Vector2i(12, 20),
}

const TEXT := [
	["UIIT_STT_ADD_QUICKSLOT_ADD", "tt extra slots"],
	["UIIT_STT_ADD_QUICKSLOT_INVISIBLE", "tt see-through"],
	["UIIT_STT_ADD_QUICKSLOT_LOCK", "tt lock slots"],
	["UIIT_STT_ADD_QUICKSLOT_FIXING_POSITION", "tt lock bar"],
	["UIIT_STT_ADD_QUICKSLOT_TWO_LINE", "tt two rows"],
	["UIIT_CTL_OPTION", "tt option"],
	["UIIS_CTL_CONFIRM", "tt ok"],
	["UIIT_CTL_APPLY", "tt apply"],
]

static func _control(name: String, cls: String, id: int, rect: String, ddj: String = "", text: String = "",
		extra: String = "") -> String:
	return "\t%s:%s\n\t{\n\t\tDDJ=STRING,\"%s\"\n\t\tID=INTEGER,\"%d\"\n\t\tRect=RECT,\"%s\"\n\t\tText=STRING,\"%s\"\n%s\t}\n" % [
		name, cls, ddj.replace("\\", "\\\\"), id, rect, text, extra]

static func _r(at: Vector2i, size: Vector2i = Vector2i.ZERO) -> String:
	return "%d,%d,%d,%d" % [at.x, at.y, size.x, size.y]

## The slot origins of type t, k = 0..9.
static func slot_at(t: int, k: int) -> Vector2i:
	match t:
		0:
			return Vector2i(43 + 36 * k, 4)
		1:
			return Vector2i(31 + 36 * (k % 5), 4 if k < 5 else 40)
		2:
			return Vector2i(5, 43 + 36 * k)
		_:
			return Vector2i(5 if k < 5 else 41, 31 + 36 * (k % 5))

static func layout_text() -> String:
	var out := "Interface Text\n"
	for t in 4:
		var d: Dictionary = TYPES[t]
		out += "Section = Type%d,\"0,0,0,0\",\"0\"\n{\n" % (t + 1)
		for k in range(9, -1, -1):
			out += _control("GDR_EXT_QUICKSLOT_SLOT_%d" % (k + 1), "CIFExtQuickSlotSlot", 100 + k, _r(slot_at(t, k), Vector2i(32, 32)))
		for b in range(int(d["boards"]) - 1, -1, -1):
			var at: Vector2i = d["board_at"] + d["step"] * b
			out += _control("GDR_EXT_QUICKSLOT_SLOT_BOARD_%d" % (b + 1), "CIFStatic", 30 + b, _r(at), QS + d["board"] + ".ddj")
		out += _control("GDR_EXT_QUICKSLOT_SLOT_END", "CIFStatic", 20, _r(d["end_at"]), QS + d["end"] + ".ddj")
		out += _control("GDR_EXT_QUICKSLOT_ONOFF_BTN", "CIFButton", 14, _r(d["onoff"]), QS + d["onoff_art"] + ".ddj")
		out += _control("GDR_EXT_QUICKSLOT_VERT_BTN", "CIFButton", 13, _r(d["vert"]), QS + "qsl_vrtl_button.ddj")
		out += _control("GDR_EXT_QUICKSLOT_HORI_BTN", "CIFButton", 12, _r(d["hori"]), QS + "qsl_hriz_button.ddj")
		out += _control("GDR_EXT_QUICKSLOT_OPT_BTN", "CIFButton", 11, _r(d["opt"]), QS + "qsl_opt_button.ddj")
		var wr: Rect2i = d["wnd_rect"]
		out += _control("GDR_EXT_QUICKSLOT_WND", "CIFDragableArea", 10, _r(wr.position, wr.size), QS + d["wnd"] + ".ddj")
		out += "}\n"
	out += "Section = Option,\"0,0,0,0\",\"0\"\n{\n"
	out += _control("GDR_EXT_QUICKSLOT_OPTION", "CIFExtQuickSlotOption", 5, "0,0,290,223",
		"interface\\messagebox\\msgbox2_window_", "UIIT_STT_ADD_QUICKSLOT_ADD")
	out += "}\n"
	return out

static func option_text() -> String:
	var btn_extra := "\t\tClientRect=RECT,\"0,6,0,0\"\n\t\tFontColor=COLOR,\"255,255,247,202\"\n\t\tHAlign=INTEGER,\"1\"\n"
	var out := "Interface Text\nSection = Create,\"0,0,0,0\",\"0\"\n{\n"
	out += _control("GDR_EXT_QUICKSLOT_APPLY_BTN", "CIFButton", 36, "149,185,0,0", "interface\\ifcommon\\com_button.ddj", "UIIT_CTL_APPLY", btn_extra)
	# The archive's own three-number rect.
	out += _control("GDR_EXT_QUICKSLOT_OK_BTN", "CIFButton", 35, "63,185,0", "interface\\ifcommon\\com_button.ddj", "UIIS_CTL_CONFIRM", btn_extra)
	out += _control("GDR_EXT_QUICKSLOT_OPT_DOUBLELINE_CHECKBOX", "CIFCheckBox", 28, "231,126,0,0", "interface\\ifcommon\\com_checkbutton_off.ddj")
	out += _control("GDR_EXT_QUICKSLOT_OPT_FIX_CHECKBOX", "CIFCheckBox", 27, "231,91,0,0", "interface\\ifcommon\\com_checkbutton_off.ddj")
	out += _control("GDR_EXT_QUICKSLOT_OPT_LOCK_CHECKBOX", "CIFCheckBox", 26, "111,126,0,0", "interface\\ifcommon\\com_checkbutton_off.ddj")
	out += _control("GDR_EXT_QUICKSLOT_OPT_TRANS_CHECKBOX", "CIFCheckBox", 25, "111,91,0,0", "interface\\ifcommon\\com_checkbutton_off.ddj")
	out += _control("GDR_EXT_QUICKSLOT_OPT_DOUBLELINE", "CIFStatic", 18, "160,127,68,16", "", "UIIT_STT_ADD_QUICKSLOT_TWO_LINE")
	out += _control("GDR_EXT_QUICKSLOT_OPT_FIX", "CIFStatic", 17, "160,92,68,16", "", "UIIT_STT_ADD_QUICKSLOT_FIXING_POSITION")
	out += _control("GDR_EXT_QUICKSLOT_OPT_LOCK", "CIFStatic", 16, "46,127,62,16", "", "UIIT_STT_ADD_QUICKSLOT_LOCK")
	out += _control("GDR_EXT_QUICKSLOT_OPT_TRANS", "CIFStatic", 15, "46,92,62,16", "", "UIIT_STT_ADD_QUICKSLOT_INVISIBLE")
	out += _control("GDR_EXT_QUICKSLOT_OPT_FRAME2_TEXT", "CIFStatic", 9, "90,59,111,16", "", "UIIT_CTL_OPTION", "\t\tHAlign=INTEGER,\"1\"\n")
	out += _control("GDR_EXT_QUICKSLOT_OPT_FRAME2", "CIFFrame", 8, "28,54,235,105", "interface\\option\\opt_inner_box_")
	out += _control("GDR_EXT_QUICKSLOT_OPT_FRAME1", "CIFFrame", 7, "14,40,262,135", "interface\\inventory\\int_window_")
	out += _control("GDR_EXT_QUICKSLOT_OPT_BG2", "CIFNormalTile", 6, "16,175,258,32", "interface\\ifcommon\\bg_tile\\com_bg_tile_b.ddj")
	out += _control("GDR_EXT_QUICKSLOT_OPT_BG1", "CIFNormalTile", 5, "48,82,195,65", "interface\\ifcommon\\bg_tile\\com_bg_tile_b.ddj")
	out += "}\n"
	return out

## A header image whose line i along the bar's axis has red = i (so the
## footer's composition can be read back), opaque.
static func header_image(size: Vector2i, vertical: bool) -> Image:
	var img := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	for y in size.y:
		for x in size.x:
			var line := y if vertical else x
			img.set_pixel(x, y, Color8(line, 7, 9, 255))
	return img

## Puts both layouts, the art and the text rows into `builder`.
static func install(builder: UiBuilder) -> void:
	var cache: Dictionary = builder.get("_layout_cache")
	cache[LAYOUT] = UiLayoutParser.parse(layout_text())
	cache[OPTION_LAYOUT] = UiLayoutParser.parse(option_text())
	var tex: Dictionary = builder.get("_texture_cache")
	for art in ART_SIZES:
		var s: Vector2i = ART_SIZES[art]
		var img: Image
		if String(art).ends_with("_windo"):
			img = header_image(s, String(art).begins_with("qsl_vrtl"))
		else:
			img = Image.create(s.x, s.y, false, Image.FORMAT_RGBA8)
			img.fill(Color(0.2, 0.2, 0.2, 1))
		var t := ImageTexture.create_from_image(img)
		for suffix in ["", "_focus", "_press", "_disable"]:
			tex[(QS + art + suffix + ".ddj").to_lower()] = t if suffix == "" else ImageTexture.create_from_image(img)
	for art in ["interface\\ifcommon\\com_checkbutton_off.ddj", "interface\\ifcommon\\com_checkbutton_on.ddj"]:
		var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
		tex[art.to_lower()] = ImageTexture.create_from_image(img)
	var button := Image.create(76, 24, false, Image.FORMAT_RGBA8)
	tex["interface\\ifcommon\\com_button.ddj"] = ImageTexture.create_from_image(button)

## The text rows, merged into an existing table's rows.
static func text_rows() -> PackedStringArray:
	var rows := PackedStringArray()
	for pair in TEXT:
		rows.append("1\t%s\t\t\t\t\t\t\t%s" % pair)
	return rows
