class_name ItemCountLabel
extends Label

## A slot's stack count, drawn as the original draws it (round 728): from the
## ten digit images `interface\item_number\item_number_0..9.ddj`, at the slot's
## TOP LEFT, not in a font.
##
## READ in sro_client.exe:
## - `CIFSlotWithHelp::vslot_010` (0x66b460) loads the ten digits into +0x5a0
##   ("interface\\item_number\\item_number_%d.ddj"); each file is an 8x8 RGBA
##   image (404 bytes in Media.pk2, MEASURED) whose dark rim is the "black
##   border" that keeps the digits legible.
## - The draw, `FUN_0067bd70`, writes the count with `_itoa_s` and walks it
##   from the LAST digit: the first quad's left edge is
##   `slot.x - 2 + digits * 4`, each next one 5 px further left
##   (`local_98 -= 5`), all at `slot.y + 2`; a quad spans (x - 0.5)..(x + 7.5)
##   (the doubles 0.5 at 0xe1b7d0 and 7.5 at 0xda3730), i.e. exactly the
##   8x8 pixels from (x, y) in Direct3D 9's pixel-centre convention, with the
##   image's own UVs 0..1. So the digits overlap by 3 px and a 4-digit count
##   starts 1 px left of the slot.
## - `CIFSlotWithHelp::vslot_013` (0x685e50) draws it only when
##   `FUN_00680da0` holds: for a bag-type slot, the item is an expendable --
##   `(b & 2) == 0 && (b & 0x1c) == 0xc && (b & 0x60) == 0x60` on the type
##   word, i.e. not bionic, TypeID1 3, TypeID2 3 -- with a non-zero stack.
##   A count of 1 is drawn too (shows_count).
##
## The Label's own text is kept (callers set `text` as before) but not drawn:
## its font colour is transparent and _draw paints the digits.

const DIGIT_DDJ := "interface\\item_number\\item_number_%d.ddj"
const DIGIT_SIZE := Vector2(8, 8)
## The first (rightmost) digit's left edge is x0 - 2 + 4n; the pitch is 5.
const ORIGIN_X := -2
const PER_DIGIT_SHIFT := 4
const PITCH := 5
const ORIGIN_Y := 2

static var _digits: Array = []

## Loads the ten digit images once, through a UiBuilder (its archive and
## texture cache). Safe to call for every slot.
static func ensure_digits(builder) -> void:
	if not _digits.is_empty() or builder == null:
		return
	var loaded: Array = []
	for d in range(10):
		var tex: Texture2D = builder.load_texture(DIGIT_DDJ % d)
		if tex == null:
			return
		loaded.append(tex)
	_digits = loaded

## Whether the original draws a count on a bag-type slot holding this item:
## an expendable (not bionic, TypeID1 3, TypeID2 3) with a stack of 1 or more
## (FUN_00680da0, READ). type_ids is [TypeID1..4].
static func shows_count(type_ids: Array, bionic: bool, quantity: int) -> bool:
	if quantity < 1 or bionic or type_ids.size() < 2:
		return false
	return int(type_ids[0]) == 3 and int(type_ids[1]) == 3

## The left edge of each digit's quad for an n-digit count, left to right
## (FUN_0067bd70's arithmetic, READ).
static func digit_xs(n: int) -> Array:
	var xs: Array = []
	var x := ORIGIN_X + n * PER_DIGIT_SHIFT
	for i in range(n):
		xs.push_front(x)
		x -= PITCH
	return xs

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_theme_color_override("font_color", Color(0, 0, 0, 0))
	add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0))
	add_theme_color_override("font_outline_color", Color(0, 0, 0, 0))
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

func _draw() -> void:
	var t := text.strip_edges()
	if t == "" or not t.is_valid_int() or _digits.is_empty():
		return
	var xs := digit_xs(t.length())
	for i in range(t.length()):
		var d := t.unicode_at(i) - 48
		if d < 0 or d > 9:
			continue
		draw_texture_rect(_digits[d], Rect2(Vector2(xs[i], ORIGIN_Y), DIGIT_SIZE), false)
