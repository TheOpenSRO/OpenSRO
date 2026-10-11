class_name ItemSealEdge
extends Control

## The star that runs round a seal item's slot ("Seal of Star/Moon/Sun/Nova"),
## drawn as the original draws it: one cell of a pre-drawn sprite sheet over
## the slot's own quad, stepped by a 40 ms window timer. The orbit is in the
## art, not in code.
##
## READ in sro_client.exe (docs/protocol/item_seal_edge.md):
## - `CIFSlotWithHelp::vslot_010` (0x66b460) loads
##   "icon\\item\\etc\\icon_edge_rare.ddj" into +0x63c. The file is a 256x128
##   DXT3 (MEASURED), an 8 x 4 grid of 32x32 cells.
## - The slot's SetItem (0x6871d0) calls 0x666610 when the item's ref passes
##   0x8ba600 (Rarity 2 or 6, ItemTooltipLines.is_seal) and the item came off
##   the wire (SOItem +0x28, 0x8be4f0) or the slot is a buy-back slot (0x45).
##   0x666610 sets the counter +0x668 to `rand() & 31` -- a random phase per
##   slot -- and starts timer 3 at 0x28 ms (0xb93320; a timer already running
##   is not restarted).
## - Timer 3 (`vslot_005`, 0x66bcf0): counter -= 1; below 1 it becomes 0x20.
##   The timer list (0xb933d0) fires at most once a tick, when
##   `now - last >= interval`, then sets `last = now` (timeGetTime ms): late
##   ticks are dropped, not caught up.
## - The draw (0x67cfb0, from `vslot_013` 0x685e50 after the icon and before
##   the count): when the ref passes 0x8ba600 and the counter is > 0, cell
##   `i = 32 - counter`, column `i % 8`, row `i / 8`; UVs
##   `col * 32 * (1/256)` .. `(col + 1) * ...` and `row * 32 * (1/128)` ..
##   (the doubles 32.0 at 0xd99a60, 1/256 at 0xda3778, 1/128 at 0xda3770),
##   on the slot's quad (+0x24c) as a two-triangle fan with no render-state
##   change: the UI's ordinary alpha blend.
##
## Added under an item slot's ItemIcon (show_on), so it covers the icon's
## rect, draws after it and before the slot's CountLabel, as the original
## orders them. It inherits the icon's modulate (the grey of a broken item,
## OURS); the original draws the edge undimmed.

const EDGE_DDJ := "icon\\item\\etc\\icon_edge_rare.ddj"
const NODE_NAME := "SealEdge"
## 0x666610's timer, in ms.
const INTERVAL_MS := 0x28
## The counter's wrap value, and the cell count.
const FRAMES := 0x20
const COLUMNS := 8
## The cell's size in UV: 32 * 1/256 across, 32 * 1/128 down.
const CELL_UV := Vector2(32.0 / 256.0, 32.0 / 128.0)

static var _texture: Texture2D = null

## +0x668. 0 draws nothing until the first tick wraps it to 32.
var counter := 0
## The item the phase was drawn for; -1 before the first.
var item_id := -1
## Timer 3 is never killed once started (nothing passes 3 to 0xb93170).
var _timer_running := false
var _last_ms := 0

## Loads the sheet once, through a UiBuilder (its archive and texture cache).
static func ensure_texture(builder) -> void:
	if _texture != null or builder == null:
		return
	_texture = builder.load_texture(EDGE_DDJ)

## Shows or hides the edge on an item slot's icon, adding it on first use.
## `seal` is the caller's whole test (0x8ba600 and the slot's own rule).
static func show_on(icon: Control, builder, seal: bool, id: int) -> void:
	if icon == null:
		return
	var edge := icon.get_node_or_null(NODE_NAME) as ItemSealEdge
	if not seal:
		if edge != null:
			edge.clear()
		return
	ensure_texture(builder)
	if edge == null:
		edge = ItemSealEdge.new()
		edge.name = NODE_NAME
		icon.add_child(edge)
	edge.set_item(id)

## Carries a shown edge's phase and timer from one icon to another: the held
## icon is a copy of the slot, where the original holds and draws the slot
## itself, so its star keeps the slot's place in the orbit.
static func copy_phase(from_icon: Node, to_icon: Node) -> void:
	if from_icon == null or to_icon == null:
		return
	var from := from_icon.get_node_or_null(NODE_NAME) as ItemSealEdge
	var to := to_icon.get_node_or_null(NODE_NAME) as ItemSealEdge
	if from == null or to == null or not from.visible or not to.visible:
		return
	to.counter = from.counter
	to._last_ms = from._last_ms
	to.queue_redraw()

## The cell index the original draws for a counter, or -1 for none.
static func frame_for(c: int) -> int:
	if c <= 0:
		return -1
	return FRAMES - c

## A cell's UV rect (0x67cfb0's arithmetic).
static func cell_uv(frame: int) -> Rect2:
	var col := frame % COLUMNS
	@warning_ignore("integer_division")
	var row := frame / COLUMNS
	return Rect2(Vector2(col * CELL_UV.x, row * CELL_UV.y), CELL_UV)

## Timer 3's step.
static func step(c: int) -> int:
	c -= 1
	return FRAMES if c < 1 else c

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	visible = false
	set_process(false)

## 0x666610: a new phase, and the timer started if it is not already.
## The same item set again keeps its phase (OURS): HudPanels refills every
## slot of a window on any change, where the original's SetItem runs per
## slot, so re-rolling here would make every star jump at once.
func set_item(id: int) -> void:
	if id != item_id:
		item_id = id
		counter = randi() & 31
		queue_redraw()
	if not _timer_running:
		_timer_running = true
		_last_ms = Time.get_ticks_msec()
	visible = true
	set_process(true)

## The slot no longer holds a seal item: nothing drawn (0x67cfb0's ref test
## fails), and no ticks while hidden.
func clear() -> void:
	visible = false
	set_process(false)

func _process(_delta: float) -> void:
	tick(Time.get_ticks_msec())

## One pass of the timer list at `now_ms`.
func tick(now_ms: int) -> void:
	if not _timer_running or now_ms - _last_ms < INTERVAL_MS:
		return
	counter = step(counter)
	_last_ms = now_ms
	queue_redraw()

func _draw() -> void:
	var frame := frame_for(counter)
	if frame < 0 or _texture == null:
		return
	var uv := cell_uv(frame)
	var tex_size := _texture.get_size()
	var region := Rect2(uv.position * tex_size, uv.size * tex_size)
	draw_texture_rect_region(_texture, Rect2(Vector2.ZERO, size), region)
