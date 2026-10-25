extends Control
class_name CoolTimeText

## Round 826: a quick slot's re-use time in figures, as the original draws it
## after the sweep (SkillDelayOverlay) and before the count: READ from
## sro_client.exe, UI_SILKMALL::FUN_0067c920(ms), which 0x67cfb0 calls for a
## quick slot (kind 0x0c) only -- with SkillCoolTimeManager's time left
## (0x9bba90) for a skill. The skill window's slots and the bag show none.
##
## - ms 0: nothing.
## - s = ms / 1000, truncated (0x10624dd3, sar 6). s <= 60 (`cmp 0x3c; jle`):
##   the veil `effect\icon\icon_effect.ddj` over the slot's quad, then s in
##   white (0xffffffff) -- so "0" in the last second. s <= 3600 (`cmp 0xe10;
##   jle`): the same veil, then s / 60 in 0xffe1e700. Above: the veil
##   `effect\icon\int_effect.ddj`, then s / 3600 in 0xff000ca9.
## - The figures (0x67c540): `effect\icon\cool_time_%d.ddj`, one 8 x 12 quad
##   each, the texture tinted by the colour (D3DRS_TEXTUREFACTOR with
##   MODULATE). For n figures in the slot's rect (x, y, w, h) the last one's
##   left edge is x + w/2 - 8 + 4n and each earlier one is 8 further left, so
##   the string is centred; the top is y + h/2 - 6. The client's quad runs
##   from x0 - 0.5, y0 - 0.5 to x0 + 8, y0 + 12 (0xe1b7d0, 0xd89240,
##   0xd89248): Direct3D 9's half-pixel offset, so one texel to a pixel at
##   (x0, y0) here (INFERRED).
## MEASURED (Media.pk2): icon_effect.ddj is 32 x 32 of (0, 23, 120) at alpha
## 110, int_effect.ddj white at alpha 115, cool_time_0..9.ddj 8 x 12 white
## figures with a 1-bit alpha.

const NODE := "CoolTime"
const VEIL_DDJ := "effect\\icon\\icon_effect.ddj"
const HOUR_VEIL_DDJ := "effect\\icon\\int_effect.ddj"
const DIGIT_DDJ := "effect\\icon\\cool_time_%d.ddj"
const SECONDS_COLOUR := Color8(0xff, 0xff, 0xff, 0xff)
const MINUTES_COLOUR := Color8(0xe1, 0xe7, 0x00, 0xff)
const HOURS_COLOUR := Color8(0x00, 0x0c, 0xa9, 0xff)
const DIGIT_SIZE := Vector2(8, 12)

## Texture by Media.pk2 path (UiBuilder.load_texture).
var sheet_for: Callable
var ms := 0

## What 0x67c920 shows for `p_ms`: {} for none, else {"text", "colour",
## "veil"}.
static func display(p_ms: int) -> Dictionary:
	if p_ms == 0:
		return {}
	var s := int(p_ms / 1000.0) if p_ms >= 0 else -int(-p_ms / 1000.0)
	if s <= 60:
		return {"text": str(s), "colour": SECONDS_COLOUR, "veil": VEIL_DDJ}
	if s <= 3600:
		@warning_ignore("integer_division")
		return {"text": str(s / 60), "colour": MINUTES_COLOUR, "veil": VEIL_DDJ}
	@warning_ignore("integer_division")
	return {"text": str(s / 3600), "colour": HOURS_COLOUR, "veil": HOUR_VEIL_DDJ}

## Figure i's (0-based) of n top-left corner in `rect`.
static func digit_origin(rect: Rect2, i: int, n: int) -> Vector2:
	var last_x := rect.position.x + rect.size.x / 2.0 - 8.0 + 4.0 * n
	return Vector2(last_x - 8.0 * (n - 1 - i), rect.position.y + rect.size.y / 2.0 - 6.0)

## Shows `p_ms` on `host` (a slot node), made on first use and put just
## before `before` (the count) when given; 0 hides it.
static func apply(host: Control, p_sheet_for: Callable, p_ms: int, before: Node = null) -> void:
	var t := host.get_node_or_null(NODE) as CoolTimeText
	if p_ms == 0:
		if t != null:
			t.set_ms(0)
		return
	if t == null:
		t = CoolTimeText.new()
		t.name = NODE
		t.mouse_filter = Control.MOUSE_FILTER_IGNORE
		t.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		host.add_child(t)
	t.sheet_for = p_sheet_for
	if before != null and before.get_parent() == host and t.get_index() > before.get_index():
		host.move_child(t, before.get_index())
	t.set_ms(p_ms)

func set_ms(p_ms: int) -> void:
	var before := display(ms)
	ms = p_ms
	visible = p_ms != 0
	if display(ms) != before:
		queue_redraw()

## The text shown now ("" for none), for tests.
func shown_text() -> String:
	return String(display(ms).get("text", ""))

func _texture(path: String) -> Texture2D:
	return sheet_for.call(path) as Texture2D if sheet_for.is_valid() else null

func _draw() -> void:
	var d := display(ms)
	if d.is_empty():
		return
	var rect := Rect2(Vector2.ZERO, size)
	var veil := _texture(String(d["veil"]))
	if veil != null:
		draw_texture_rect(veil, rect, false)
	var text := String(d["text"])
	for i in text.length():
		var digit := _texture(DIGIT_DDJ % int(text[i]))
		if digit != null:
			draw_texture_rect(digit, Rect2(digit_origin(rect, i, text.length()), DIGIT_SIZE), false, d["colour"])
