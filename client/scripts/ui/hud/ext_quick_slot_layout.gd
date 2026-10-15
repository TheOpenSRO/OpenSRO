extends RefCounted
class_name ExtQuickSlotLayout

## The rules of the Additional Quick Slot bar (round 788) that are pure
## arithmetic, kept apart from the bar (HudExtQuickSlot) so a suite checks
## them without a window. Every address is sro_client.exe's (md5
## 2a5794b72c90908d945be8b3f3f2edd4); docs/protocol/ext_quick_slot.md has the
## whole record. Labels: READ, MEASURED, INFERRED, OURS.

## CIFExtQuickSlot's own layout (READ: Create 0x65f720 loads it) and the
## option window's (READ: 0x65f9d0 loads section Create of it).
const LAYOUT := "resinfo\\ifextquickslot.txt"
const OPTION_LAYOUT := "resinfo\\ifextquickslotoption.txt"
## The option window's own def: section Option of LAYOUT, id 5 (READ:
## 0x65eb10 builds section "Option" and fetches child 5).
const OPTION_SECTION := "Option"
const ID_OPTION_WINDOW := 5

## The bar's controls (MEASURED, ifextquickslot.txt; the message map 0xeb73e8
## routes 11..14, READ).
const ID_WND := 10
const ID_OPT := 11
const ID_HORI := 12
const ID_VERT := 13
const ID_ONOFF := 14
const ID_END := 20
const ID_BOARD := 30
const ID_SLOT := 100
const SLOTS := 10

## The option window's controls (MEASURED, ifextquickslotoption.txt).
const ID_CHECK_TRANS := 25
const ID_CHECK_LOCK := 26
const ID_CHECK_FIX := 27
const ID_CHECK_DOUBLELINE := 28
const ID_OPTION_OK := 35
const ID_OPTION_APPLY := 36

## apply()'s alpha (READ, 0x65f390: 0x6e when Transparent, else 0xff).
const ALPHA_TRANSPARENT := 0x6e
const ALPHA_OPAQUE := 0xff

## The collapse button's art by orientation and state (READ, 0x65ecd0):
## open shows the close art, collapsed the open art.
const ART_HCLOSE := "interface\\quick_slot\\qsl_hclose_button.ddj"
const ART_HOPEN := "interface\\quick_slot\\qsl_hopen_button.ddj"
const ART_VCLOSE := "interface\\quick_slot\\qsl_vclose_button.ddj"
const ART_VOPEN := "interface\\quick_slot\\qsl_vopen_button.ddj"

## The default place (READ, 0x79c600: 0x79c697..0x79c6c3): x = screen width
## less the window's width less 26, y = 181 (push 0xb5).
const DEFAULT_RIGHT_MARGIN := 26
const DEFAULT_Y := 0xb5

## The layout type the four Type sections are picked by (READ, 0x65ef70:
## vertical * 2 + twoLines, stored at +0x372): 0 Type1 horizontal one line,
## 1 Type2 horizontal two lines, 2 Type3 vertical one line, 3 Type4 vertical
## two lines.
static func type_index(vertical: bool, two_lines: bool) -> int:
	return (2 if vertical else 0) + (1 if two_lines else 0)

## A section's control by its layout id, or null (the parser fills no
## by-id map).
static func def_by_id(sec: UiLayoutParser.SectionDef, id: int) -> UiLayoutParser.ControlDef:
	if sec == null:
		return null
	for c in sec.controls:
		if c.id == id:
			return c
	return null

static func section_name(type: int) -> String:
	return "Type%d" % (type + 1)

static func is_vertical(type: int) -> bool:
	return type >= 2

static func is_two_lines(type: int) -> bool:
	return type == 1 or type == 3

## How many boards a type has (READ, 0x65f390 / 0x65ecd0: ten for the one-line
## types, five for the two-line ones; MEASURED, the layout's 30..39 / 30..34).
static func board_count(type: int) -> int:
	return 5 if is_two_lines(type) else 10

## The collapse button's art for a type and state (0x65ecd0).
static func onoff_art(type: int, open: bool) -> String:
	if is_vertical(type):
		return ART_VCLOSE if open else ART_VOPEN
	return ART_HCLOSE if open else ART_HOPEN

static func alpha_for(transparent: bool) -> int:
	return ALPHA_TRANSPARENT if transparent else ALPHA_OPAQUE

## Where the bar starts with no position kept (READ, 0x79c600): `header_w`
## is the window's width -- the WND strip's, the bar's own rect (0x65f12e
## sizes the window from control 10; the slots hang outside it).
static func default_position(screen: Vector2, header_w: float) -> Vector2:
	return Vector2(screen.x - header_w - DEFAULT_RIGHT_MARGIN, DEFAULT_Y)

## A kept position as it is restored on show (READ, 0x79a8d0): clamped on
## the right and bottom only -- past the right edge x = screen width less the
## width, past the bottom likewise; nothing pulls it back from the left or
## the top.
static func clamp_on_show(pos: Vector2, header_size: Vector2, screen: Vector2) -> Vector2:
	var out := pos
	if out.x + header_size.x > screen.x:
		out.x = screen.x - header_size.x
	if out.y + header_size.y > screen.y:
		out.y = screen.y - header_size.y
	return out

## Where the option window opens (READ, 0x65eb10, its asm 0x65ebba..0x65ec78),
## from the bar's own rect (its header): a vertical bar puts it on the right
## of the header when the header starts in the left half of the screen
## (x < width >> 1), else on its left; a horizontal one below the header when
## it starts in the top half, else above. No clamp.
static func option_position(bar_rect: Rect2, vertical: bool, option_size: Vector2, screen: Vector2) -> Vector2:
	var x := bar_rect.position.x
	var y := bar_rect.position.y
	if vertical:
		if x < float(int(screen.x) >> 1):
			return Vector2(x + bar_rect.size.x, y)
		return Vector2(x - option_size.x, y)
	if y < float(int(screen.y) >> 1):
		return Vector2(x, y + bar_rect.size.y)
	return Vector2(x, y - option_size.y)

# --- OURS: the extra bars' pages (round 788) ---------------------------------

## The quick slot an OURS extra bar shows: bar `bar` (1 = the first extra
## bar), page `page` (1..), key k (0..9). Bar b's page p is the ten slots
## from 51 + ((b - 1) * EXT_PAGES_MAX + p - 1) * 10: a fixed stride per bar,
## so raising the page count moves nothing already stored.
static func slot_for(bar: int, page: int, k: int) -> int:
	return HudUnderbar.EXT_SLOT_BASE \
		+ ((bar - 1) * HudUnderbar.EXT_PAGES_MAX + (page - 1)) * SLOTS + k

## The page label (OURS): the pages are numbered after the bottom bar's
## F1..F4, as the reference server's footer reads "F5" on its first page.
## No key selects them.
static func page_label(page: int) -> String:
	return HudUnderbar.PAGE_LABEL_FORMAT % (HudUnderbar.MAX_PAGES + page)

## The footer's geometry (OURS; MEASURED from the user's screenshots of the
## reference server at 2x: the footer adds 23 px after the slot area, the
## arrows 12x20 sit 2 px in from each side flush with the slot area's end,
## the label is centred between them). Vertical types: a band under the
## slots, the left arrow on the left, the right arrow on the right.
## Horizontal types: a band right of the slots, the arrows turned a quarter
## clockwise (left becomes up, right becomes down), up at the top, down at
## the bottom. `across` is the bar's width (vertical) or height (horizontal)
## -- the WND strip's -- and `slot_end` where the slot area ends along it.
const FOOTER_LENGTH := 23
const ARROW_SIZE := Vector2(12, 20)
const ARROW_INSET := 2

static func footer_rects(vertical: bool, across: float, slot_end: float) -> Dictionary:
	var arrow_long := ARROW_SIZE.y
	var arrow_short := ARROW_SIZE.x
	var span := ARROW_INSET + arrow_short
	if vertical:
		return {
			"band": Rect2(0, slot_end, across, FOOTER_LENGTH),
			"prev": Rect2(ARROW_INSET, slot_end, arrow_short, arrow_long),
			"next": Rect2(across - span, slot_end, arrow_short, arrow_long),
			"label": Rect2(span, slot_end, across - 2 * span, arrow_long),
		}
	return {
		"band": Rect2(slot_end, 0, FOOTER_LENGTH, across),
		"prev": Rect2(slot_end, ARROW_INSET, arrow_long, arrow_short),
		"next": Rect2(slot_end, across - span, arrow_long, arrow_short),
		"label": Rect2(slot_end, span, arrow_long, across - 2 * span),
	}

## The header art's lines along the bar's axis (MEASURED, all four
## qsl_*_windo: lines 0-1 the rounded outer edge, 2-12 the grip, opaque across
## the whole width; 13 on hold the buttons' cut-outs).
const HEADER_EDGE_LINES := 2
const HEADER_GRIP_END := 13

## The footer's backing (OURS -- the reference server's art is not in the
## archive): the header's grip lines repeated, closed by its rounded edge
## turned to face outward. `header` is the WND art; along x for a horizontal
## bar, along y for a vertical one.
static func compose_footer(header: Image, vertical: bool, length: int = FOOTER_LENGTH) -> Image:
	if header == null or header.is_empty():
		return null
	var src := header.duplicate() as Image
	if src.is_compressed():
		src.decompress()
	src.convert(Image.FORMAT_RGBA8)
	var across := src.get_width() if vertical else src.get_height()
	var along := src.get_height() if vertical else src.get_width()
	if along < HEADER_GRIP_END:
		return null
	var out := Image.create(across if vertical else length, length if vertical else across, false, Image.FORMAT_RGBA8)
	var grip := HEADER_GRIP_END - HEADER_EDGE_LINES
	for i in length:
		var from: int
		var tail := length - 1 - i
		if tail < HEADER_EDGE_LINES:
			from = tail
		else:
			from = HEADER_EDGE_LINES + (i % grip)
		for j in across:
			if vertical:
				out.set_pixel(j, i, src.get_pixel(j, from))
			else:
				out.set_pixel(i, j, src.get_pixel(from, j))
	return out
