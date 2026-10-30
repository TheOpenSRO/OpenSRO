class_name ItemStateEdge
extends Control

## The item slot's other per-item effects, beside the seal star
## (ItemSealEdge): the awake devil's spirit's edge, the summoned pet's edge,
## the pet's life flash and the blue wash of a dead pet or a spirit whose
## awakening ran out. Round 843, lane S; docs/protocol/item_seal_edge.md §6.
##
## READ in sro_client.exe (every CIFSlotWithHelp, whatever its window):
## - The sheets (`CIFSlotWithHelp::vslot_010`, 0x66b460):
##   `icon\item\etc\icon_edge_nasrun.ddj` (+0x648),
##   `interface\pet\pt_edge_effect.ddj` (+0x640) and
##   `interface\pet\pt_life_effect.ddj` (+0x644). Each is one row of 32-wide
##   cells; the orbit is in the art, as with the seal star.
## - SetItem (0x6871d0), for a 3/1/14 item (0x55edf0, the devil's spirit) on
##   any slot but the item mall's (kind 0xa7): 0x666640 -- the counter +0x668
##   to `rand() % 12`, timer 0x14 at 0x50 ms; the step (vslot_005 0x66bcf0)
##   `--c; if (c < 1) c = 12`. For any other item, 0x667ac0(the record's
##   state, SOItem +0x5c): state 2 (a pet out) 0x666680(1) -- the counter
##   +0x66c to `rand() % 9`, timer 4 at 0x32 ms, step `--c; if (c < 1) c = 9`;
##   state 4 (dead) the slot's wash colour +0x1f8 = 0x80004b7e (0x652e00).
## - The 0x3040 state update (c:0x88c637..): the bag slot's 0x667ac0(new
##   state) (0x6b4390) and the quick bar's (0x60a940); state 3 while the record
##   still says 4 (a revival) also runs 0x6666d0 -- +0x670 = 8, timer 5 at
##   0x50 ms, step `--c; if (c < 1) { c = 0; kill timer 5 }`. A rent extended
##   (mask 0x80, more seconds than before) runs 0x6666d0 too (0x6b4500).
## - The draw (0x67cfb0, after the icon, for a record whose +0x28 is set):
##   - the pet edge when state == 2 and +0x66c > 0: u (9 - c) * 32 / 288 ..
##     (10 - c) * 32 / 288 (the doubles 32.0 at 0xd99a60, 288.0 at
##     0xda3780), v 0..1;
##   - the seal star (ItemSealEdge);
##   - the spirit's edge for a 3/1/14 item on a slot other than kind 0xa7,
##     when its state (+0x5c, the period word's bit 31: awake) is 1 and its
##     time (+0x60, the word's low 31 bits x 1000 ms) is > 0, and +0x668 > 0:
##     cell `(12 - c) & 15`, u cell * 32 / 512 .. (cell + 1) * 32 / 512
##     (1/512 at 0xda3768), v 0..1. Awake with no time left sets the wash
##     0x80004b7e instead; not awake, no wash;
##   - the life flash, on the bag (kind 0x46) or a quick slot holding a bag
##     item (0xc / 0x46) only, while +0x670 > 0: u (8 - c) * 32 / 256 ..
##     (9 - c) * 32 / 256 (1/256 at 0xda3778), v 0..1.
##   All four on the slot's own quad, FVF 0x104 (no vertex colour), with
##   stage 0's alpha op back at SELECTARG1(TEXTURE) (0x6554c0, the end of
##   the icon's draw): undimmed by the slot's alpha.
## - The wash (0x6550c0 -> 0x654d10 after the icon): a flat quad of the
##   colour, COLOROP SELECTARG1(TFACTOR), alpha 0x80 -- RGB (0x00, 0x4b,
##   0x7e) at half alpha over the icon.

enum Mode { NASRUN, PET, LIFE }

const NASRUN_DDJ := "icon\\item\\etc\\icon_edge_nasrun.ddj"
const PET_DDJ := "interface\\pet\\pt_edge_effect.ddj"
const LIFE_DDJ := "interface\\pet\\pt_life_effect.ddj"
const NODE_NAMES := {Mode.NASRUN: "NasrunEdge", Mode.PET: "PetEdge", Mode.LIFE: "LifeEdge"}
const WASH_NAME := "StateWash"
## 0x80004b7e, ARGB.
const WASH_COLOUR := Color(0x00 / 255.0, 0x4b / 255.0, 0x7e / 255.0, 0x80 / 255.0)

## The timers' intervals, in ms (0x666640, 0x666680, 0x6666d0).
const INTERVAL_MS := {Mode.NASRUN: 0x50, Mode.PET: 0x32, Mode.LIFE: 0x50}
## The counters' wrap values (vslot_005 cases 0x14, 4, 5); LIFE does not wrap.
const WRAP := {Mode.NASRUN: 12, Mode.PET: 9, Mode.LIFE: 0}
## The life flash's start (0x6666d0).
const LIFE_START := 8
## The cell width in UV (32 over the draw's divisor).
const CELL_U := {Mode.NASRUN: 32.0 / 512.0, Mode.PET: 32.0 / 288.0, Mode.LIFE: 32.0 / 256.0}

## The COS item states (SOItem +0x5c; CosNet.ITEM_STATE_*).
const STATE_SUMMONED := 2
const STATE_DEAD := 4

static var _textures := {}

var mode: int = Mode.PET
## +0x668 / +0x66c / +0x670.
var counter := 0
var item_id := -1
var _timer_running := false
var _last_ms := 0

## What a slot draws for an item: {"edge": Mode or -1, "wash": bool}.
## `row` is the item's ItemTableReader.Item (or null), `inst` its
## ItemInstance (or null: no record, nothing drawn), `mall` the item mall's
## slot (kind 0xa7, where the spirit's edge is never started).
static func effects_for(row, inst, mall := false) -> Dictionary:
	var out := {"edge": -1, "wash": false}
	if inst == null:
		return out
	if row != null and is_spirit(row):
		if mall:
			return out
		var period := int(inst.get("durability"))
		var awake := (period >> 31) & 1 == 1
		var left := period & 0x7fffffff
		if awake and left > 0:
			out["edge"] = Mode.NASRUN
		elif awake:
			out["wash"] = true
		return out
	var state := int(inst.get("cos_state")) if "cos_state" in inst else 0
	if state == STATE_SUMMONED:
		out["edge"] = Mode.PET
	elif state == STATE_DEAD:
		out["wash"] = true
	return out

## 0x55edf0: a 3/1/14 item (Bionic 0), the devil's spirit.
static func is_spirit(row) -> bool:
	if row == null:
		return false
	var t: PackedInt32Array = row.type_ids
	return int(row.bionic) == 0 and t.size() >= 3 and t[0] == 3 and t[1] == 1 and t[2] == 14

## Puts a slot's state effects on its icon (after the icon, under the count),
## or takes them off: `row`/`inst` as effects_for; id the item's ref id, for
## the phase (the same item set again keeps it, as ItemSealEdge does).
static func show_on(icon: Control, builder, row, inst, id: int, mall := false) -> void:
	if icon == null:
		return
	var fx := effects_for(row, inst, mall) if id >= 0 else {"edge": -1, "wash": false}
	_set_wash(icon, bool(fx["wash"]))
	for m in [Mode.NASRUN, Mode.PET]:
		var edge := icon.get_node_or_null(NODE_NAMES[m]) as ItemStateEdge
		if int(fx["edge"]) != m:
			if edge != null:
				edge.clear()
			continue
		if edge == null:
			edge = _add(icon, builder, m)
		edge.set_item(id)

## 0x6666d0: the one-shot life flash on a slot (the bag, or a quick slot
## holding a bag item).
static func flash_life(icon: Control, builder) -> void:
	if icon == null:
		return
	var edge := icon.get_node_or_null(NODE_NAMES[Mode.LIFE]) as ItemStateEdge
	if edge == null:
		edge = _add(icon, builder, Mode.LIFE)
	edge.start_life()

## The life flash goes with the slot's item (a refill that empties it).
static func clear_life(icon: Control) -> void:
	var edge := icon.get_node_or_null(NODE_NAMES[Mode.LIFE]) as ItemStateEdge if icon != null else null
	if edge != null:
		edge.clear()

## The held icon is a copy of the slot, where the original holds and draws
## the slot itself (docs/protocol/item_seal_edge.md §4): it gets the slot's
## shown effects, each at the slot's phase.
static func copy_from(from_icon: Node, to_icon: Control, builder) -> void:
	if from_icon == null or to_icon == null:
		return
	var wash := from_icon.get_node_or_null(WASH_NAME) as CanvasItem
	_set_wash(to_icon, wash != null and wash.visible)
	for m in [Mode.NASRUN, Mode.PET]:
		var from := from_icon.get_node_or_null(NODE_NAMES[m]) as ItemStateEdge
		var to := to_icon.get_node_or_null(NODE_NAMES[m]) as ItemStateEdge
		if from == null or not from.visible:
			if to != null:
				to.clear()
			continue
		if to == null:
			to = _add(to_icon, builder, m)
		to.set_item(from.item_id)
		to.counter = from.counter
		to._last_ms = from._last_ms
		to.queue_redraw()

static func _add(icon: Control, builder, m: int) -> ItemStateEdge:
	ensure_texture(builder, m)
	var edge := ItemStateEdge.new()
	edge.mode = m
	edge.name = NODE_NAMES[m]
	icon.add_child(edge)
	_order(icon)
	return edge

## 0x67cfb0's order: the pet edge, the seal star, the spirit's edge, the
## life flash; the wash before them all (the icon's own draw).
static func _order(icon: Control) -> void:
	var at := 0
	for n in [WASH_NAME, NODE_NAMES[Mode.PET], ItemSealEdge.NODE_NAME, NODE_NAMES[Mode.NASRUN], NODE_NAMES[Mode.LIFE]]:
		var c := icon.get_node_or_null(String(n))
		if c != null:
			icon.move_child(c, at)
			at += 1

static func _set_wash(icon: Control, on: bool) -> void:
	var wash := icon.get_node_or_null(WASH_NAME) as ColorRect
	if not on:
		if wash != null:
			wash.visible = false
		return
	if wash == null:
		wash = ColorRect.new()
		wash.name = WASH_NAME
		wash.color = WASH_COLOUR
		wash.mouse_filter = Control.MOUSE_FILTER_IGNORE
		wash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		icon.add_child(wash)
		_order(icon)
	wash.visible = true

static func ensure_texture(builder, m: int) -> void:
	if _textures.has(m) or builder == null:
		return
	var path: String = {Mode.NASRUN: NASRUN_DDJ, Mode.PET: PET_DDJ, Mode.LIFE: LIFE_DDJ}[m]
	var t: Texture2D = builder.load_texture(path)
	if t != null:
		_textures[m] = t

static func texture_for(m: int) -> Texture2D:
	return _textures.get(m)

## The cell a counter draws, or -1 for none.
static func frame_for(m: int, c: int) -> int:
	if c <= 0:
		return -1
	match m:
		Mode.NASRUN:
			return (12 - c) & 15
		Mode.PET:
			return 9 - c
		Mode.LIFE:
			return 8 - c
	return -1

## A cell's UV rect: one row, the cell's width in u, v 0..1.
static func cell_uv(m: int, frame: int) -> Rect2:
	var w: float = CELL_U[m]
	return Rect2(Vector2(frame * w, 0.0), Vector2(w, 1.0))

## One timer step (vslot_005): -1 when the timer is killed (LIFE at 0).
static func step(m: int, c: int) -> int:
	c -= 1
	if c < 1:
		return -1 if m == Mode.LIFE else int(WRAP[m])
	return c

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	visible = false
	set_process(false)

## 0x666640 / 0x666680(1): a new phase for a new item; the timer started.
func set_item(id: int) -> void:
	if id != item_id:
		item_id = id
		counter = randi() % int(WRAP[mode])
		queue_redraw()
	if not _timer_running:
		_timer_running = true
		_last_ms = Time.get_ticks_msec()
	visible = true
	set_process(true)

## 0x6666d0: +0x670 = 8, timer 5 (re)started.
func start_life() -> void:
	counter = LIFE_START
	_timer_running = true
	_last_ms = Time.get_ticks_msec()
	visible = true
	set_process(true)
	queue_redraw()

## The effect is off: 0x666680(0) zeroes the pet counter and kills timer 4;
## the spirit's draw test fails; nothing drawn and no ticks while hidden.
func clear() -> void:
	visible = false
	set_process(false)
	if mode == Mode.PET or mode == Mode.LIFE:
		counter = 0
		_timer_running = false
		item_id = -1

func _process(_delta: float) -> void:
	tick(Time.get_ticks_msec())

## One pass of the timer list at `now_ms` (0xb933d0: at most one step a
## pass, late steps dropped).
func tick(now_ms: int) -> void:
	if not _timer_running or now_ms - _last_ms < int(INTERVAL_MS[mode]):
		return
	var c := step(mode, counter)
	_last_ms = now_ms
	if c < 0:
		counter = 0
		_timer_running = false
		visible = false
		set_process(false)
	else:
		counter = c
	queue_redraw()

func _draw() -> void:
	var frame := frame_for(mode, counter)
	var tex := texture_for(mode)
	if frame < 0 or tex == null:
		return
	# 0x67cfb0 draws every effect only for a slot holding a record (+0x390):
	# a flash still running when its item moves away is not drawn.
	var host := get_parent() as TextureRect
	if mode == Mode.LIFE and host != null and host.texture == null:
		return
	var uv := cell_uv(mode, frame)
	var ts := tex.get_size()
	draw_texture_rect_region(tex, Rect2(Vector2.ZERO, size), Rect2(uv.position * ts, uv.size * ts))
