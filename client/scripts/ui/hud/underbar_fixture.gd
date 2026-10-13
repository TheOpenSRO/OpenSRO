extends RefCounted

## A synthetic `res_ui\nifundermenubar.2dt` for the HUD suites: the ids,
## types, parents, rects, class names and text-table keys of the controls
## CNIFUnderMenuBar's code touches, copied from the real file's structure,
## with no art and no text of the archive's (docs/LEGAL.md): the sample
## strings and the text-table rows below are made up here. The suites put it in a UiBuilder's
## `.2dt` cache, so the bar builds through the real reader and builder:
##
##   var builder := UnderbarFixture.builder()   # or install(builder)
##
## Rects are in the designer's space, as the file stores them: the bar is at
## (107, 438), so a control's place in the bar is its rect less that.

const PATH := "res_ui\\nifundermenubar.2dt"
const READER_PATH := "res://scripts/ui/twodt_reader.gd"
const RECORD := 0x3d0
const BAR_AT := Vector2i(107, 438)

## The first page's quick-slot controls, 40..49, and the "m" slot 50.
const PAGE_SLOTS := [[40, 368, 456], [41, 405, 456], [42, 440, 456], [43, 476, 456], [44, 512, 456],
	[45, 548, 456], [46, 584, 456], [47, 620, 456], [48, 656, 456], [49, 692, 456]]
const MOUSE_SLOT := [50, 316, 455]
## The key numbers' x, 92..101 (MEASURED, the real file's records 96..105).
const NUMBER_X := [392, 428, 464, 500, 536, 572, 608, 644, 680, 716]

## The menu items under 59, in file order, with their caption's text id.
const MENU_ITEMS := [[83, 60, "UIIT_STT_TOGGLE_PARTY"], [93, 85, "UIIT_STT_TOGGLE_PARTYMATCH"],
	[96, 110, "UIIT_STT_TOGGLE_GUILD"], [99, 135, "UIIT_CTL_TC_SHORTKEY_L"],
	[102, 160, "UIIT_STT_TC_MACHING_TITLE"], [105, 195, "UIIT_STT_TOGGLE_ACTION"],
	[108, 220, "UIIT_STT_TOGGLE_COMMUNITY"], [111, 245, "UIIT_STT_TOGGLE_QUEST"],
	[120, 353, ""], [123, 378, "UIIT_STT_TOGGLE_AUTOPOTION"], [126, 413, "UIIT_STT_TOGGLE_SYSTEM"],
	[104, 320, "UIIT_PAG_COLLECTION_WINDOW"], [117, 353, "UIIT_CTL_OPEN_STORE"],
	[114, 270, "UIIT_STT_TOGGLE_ENCHANT"], [115, 295, "UIIT_STT_MK"]]

## The text rows the suites resolve. The keys are the client's; every
## string is made up here (none is the archive's text), with "tt" marking it.
const TEXT := [
	["UIO_CHARINFO_STT_EXP", "tt exp"],
	["UIIT_STT_LEVEL_LV", "tt lv"],
	["UIIT_STT_SKILLPOINT", "tt skill points"],
	["UIIT_STT_TOGGLE_CONTENTS_MENU_PARTY", "tt party %s"],
	["UIIT_STT_TOGGLE_CONTENTS_MENU_PARTYMATCH", "tt party match %s"],
	["UIIT_STT_TOGGLE_CONTENTS_MENU_GUILD", "tt guild %s"],
	["UIIT_STT_TOGGLE_CONTENTS_MENU_TRAININGCAMP", "tt camp %s"],
	["UIIT_STT_TOGGLE_CONTENTS_MENU_ACTION", "tt action %s"],
	["UIIT_STT_TOGGLE_CONTENTS_MENU_COMMUNITY", "tt community %s"],
	["UIIT_STT_TOGGLE_CONTENTS_MENU_QUEST", "tt quest %s"],
	["UIIT_STT_TOGGLE_CONTENTS_MENU_ENCHANT", "tt enchant %s"],
	["UIIT_STT_TOGGLE_CONTENTS_MENU_AUTOPOTION", "tt potion %s"],
	["UIIT_STT_TOGGLE_CONTENTS_MENU_CHARACTER", "tt character %s"],
	["UIIT_STT_TOGGLE_CONTENTS_MENU_INVENTORY", "tt inventory %s"],
	["UIIT_STT_TOGGLE_CONTENTS_MENU_SKILL", "tt skill %s"],
	["UIIT_STT_SILKMALL_SHORT_KEY", "tt mall"],
	["UIIT_STT_TOGGLE_PARTY", "tt party record"],
	["UIIT_STT_TC_MACHING_TITLE", "tt camp match"],
	["UIIT_STT_TOGGLE_SYSTEM", "tt system"],
	["UIIT_PAG_COLLECTION_WINDOW", "tt collection"],
	["UIIT_CTL_OPEN_STORE", "tt stall"],
	["UIIT_STT_MK", "tt making"],
]

static func _rec(f: Dictionary) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(RECORD)
	b.fill(0)
	for pair in [[0x000, "name"], [0x040, "base"], [0x140, "tex"], [0x240, "textid"], [0x300, "sample"]]:
		var bytes: PackedByteArray = str(f.get(pair[1], "")).to_ascii_buffer()
		for i in bytes.size():
			b[pair[0] + i] = bytes[i]
	b.encode_u32(0x340, f.get("type", 5))
	b.encode_u32(0x344, f.get("id", 0))
	b.encode_u32(0x348, f.get("parent", 0))
	b.encode_u32(0x34c, f.get("gp", 0))
	b.encode_u32(0x358, f.get("color", 0xffffffff))
	var r: Rect2i = f.get("rect", Rect2i())
	b.encode_s32(0x35c, r.position.x)
	b.encode_s32(0x360, r.position.y)
	b.encode_s32(0x364, r.size.x)
	b.encode_s32(0x368, r.size.y)
	b.encode_u32(0x390, 0xffffffff)
	b.encode_u32(0x394, 1 if f.get("root", false) else 0)
	b[0x3cd] = f.get("h", 1)
	b[0x3ce] = f.get("v", 1)
	return b

static func records() -> Array:
	var recs := [
		{"type": 18, "id": 175, "name": "CNIFUnderMenuBar", "root": true, "rect": Rect2i(BAR_AT, Vector2i(800, 68))},
		{"type": 5, "id": 2, "parent": 175, "rect": Rect2i(31, 442, 76, 64)},
		{"type": 5, "id": 3, "parent": 175, "rect": Rect2i(907, 442, 76, 64)},
		{"type": 10, "id": 5, "parent": 175, "rect": Rect2i(122, 464, 176, 8)},
		{"type": 4, "id": 6, "parent": 175, "rect": Rect2i(766, 459, 32, 32)},
		{"type": 4, "id": 7, "parent": 175, "rect": Rect2i(797, 459, 32, 32)},
		{"type": 4, "id": 8, "parent": 175, "rect": Rect2i(828, 459, 32, 32)},
		{"type": 4, "id": 9, "parent": 175, "rect": Rect2i(859, 459, 32, 32)},
		{"type": 5, "id": 10, "parent": 175, "rect": Rect2i(109, 495, 14, 9), "sample": "SAMPLE-A"},
		{"type": 5, "id": 11, "parent": 175, "rect": Rect2i(146, 454, 66, 4), "textid": "UIIT_STT_SKILLPOINT"},
		{"type": 5, "id": 12, "parent": 175, "rect": Rect2i(230, 454, 66, 4), "h": 2, "sample": "SAMPLE-B"},
		{"type": 5, "id": 13, "parent": 175, "rect": Rect2i(124, 480, 66, 4), "h": 0, "sample": "SAMPLE-C"},
		{"type": 5, "id": 15, "parent": 175, "rect": Rect2i(250, 480, 43, 4), "h": 2, "sample": "SAMPLE-D"},
		{"type": 18, "id": 16, "parent": 175, "rect": Rect2i(601, 410, 192, 36)},
		{"type": 18, "id": 51, "parent": 16, "gp": 175, "rect": Rect2i(606, 414, 26, 26)},
		{"type": 4, "id": 18, "parent": 175, "rect": Rect2i(732, 478, 20, 12)},
		{"type": 4, "id": 19, "parent": 175, "rect": Rect2i(732, 454, 20, 12)},
	]
	for k in 10:
		if k == 5:
			recs.append({"type": 5, "id": 17, "parent": 175, "rect": Rect2i(492, 497, 43, 4), "sample": "SAMPLE-E"})
		recs.append({"type": 10, "id": 20 + k, "parent": 175, "rect": Rect2i(127 + 78 * k, 497, 76, 8)})
	for s in PAGE_SLOTS:
		recs.append({"type": 18, "id": s[0], "name": "CIFSlotWithHelpEx", "parent": 175, "rect": Rect2i(s[1], s[2], 32, 32)})
	recs.append({"type": 18, "id": MOUSE_SLOT[0], "name": "CIFSlotWithHelpEx", "parent": 175,
		"rect": Rect2i(MOUSE_SLOT[1], MOUSE_SLOT[2], 32, 32)})
	recs.append({"type": 5, "id": 57, "parent": 175, "rect": Rect2i(730, 467, 22, 15), "sample": "SAMPLE-F"})
	recs.append({"type": 5, "id": 14, "parent": 175, "rect": Rect2i(211, 480, 36, 4), "h": 2, "sample": "SAMPLE-G"})
	recs.append({"type": 1, "id": 59, "parent": 175, "rect": Rect2i(758, 44, 138, 403)})
	recs.append({"type": 2, "id": 62, "parent": 59, "gp": 175, "rect": Rect2i(778, 64, 98, 363)})
	for m in MENU_ITEMS:
		var y: int = m[1]
		recs.append({"type": 4, "id": m[0], "name": "CNIFMenuButton", "parent": 59, "gp": 175, "rect": Rect2i(789, y, 97, 20)})
		recs.append({"type": 5, "id": 100, "parent": m[0], "gp": 59, "rect": Rect2i(766, y, 20, 20)})
		recs.append({"type": 5, "id": 200, "parent": m[0], "gp": 59, "rect": Rect2i(793, y + 7, 82, 10), "h": 0,
			"textid": m[2], "sample": "SAMPLE"})
	for pair in [[70, 186], [79, 345], [98, 404]]:
		recs.append({"type": 5, "id": pair[0], "parent": 59, "gp": 175, "rect": Rect2i(767, pair[1], 120, 4)})
	# The key numbers 92..101 (ub_number_1.._0 in the real file, MEASURED
	# round 786: 8x12 at each slot's bottom-right, x 392 + 36k, y 478), after
	# the slots in file order as there; no art here.
	for k in 10:
		recs.append({"type": 5, "id": 92 + k, "parent": 175, "rect": Rect2i(NUMBER_X[k], 478, 8, 12)})
	recs.append({"type": 5, "id": 102, "parent": 175, "rect": Rect2i(340, 478, 8, 12)})
	recs.append({"type": 4, "id": 4, "parent": 175, "rect": Rect2i(788, 439, 78, 24)})
	recs.append({"type": 18, "id": 103, "parent": 175, "rect": Rect2i(364, 452, 40, 40)})
	recs.append({"type": 5, "id": 104, "parent": 175, "rect": Rect2i(126, 496, 773, 6)})
	recs.append({"type": 5, "id": 130, "parent": 175, "rect": Rect2i(116, 432, 32, 36)})
	return recs

static func bytes() -> PackedByteArray:
	var recs := records()
	var out := PackedByteArray()
	out.resize(4)
	out.encode_u32(0, recs.size())
	for r in recs:
		out.append_array(_rec(r))
	return out

static func text_table() -> UiTextTable:
	var rows := PackedStringArray()
	for pair in TEXT:
		rows.append("1\t%s\t\t\t\t\t\t\t%s" % pair)
	return UiTextTable.parse(("\n".join(rows)).to_utf16_buffer())

## Puts the fixture in `builder`'s `.2dt` cache. False when this tree has no
## reader (the file is then simply not there, as on a tree before it).
static func install(builder: UiBuilder) -> bool:
	var Reader = load(READER_PATH)
	var cache = builder.get("_twodt_cache")
	if Reader == null or not (cache is Dictionary):
		return false
	cache[PATH] = Reader.parse(bytes())
	return true

## A builder with the fixture and its text rows, and no archive.
static func builder() -> UiBuilder:
	var b := UiBuilder.new(null, text_table())
	install(b)
	return b
