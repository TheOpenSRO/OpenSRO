extends Control
class_name DelayInfoBar

## The return scroll's casting bar (round 779; docs/protocol/
## return_scroll_cast.md): one entry of retail's CIFDelayGaugeBoard, a
## CIFDelayInfo window. Every rule is READ from sro_client.exe unless a line
## says otherwise (labels: READ, MEASURED, INFERRED, OURS, OPEN).
##
## **When it opens (READ).** Item_OnUseItemResult (0x87a7b0), on a success
## for a 3/3/3/1 (the return scroll, case 1 at 0x87ad78) or a 3/3/3/3 item
## (the reverse return scroll, case 3 at 0x87adfb), calls the board's
## FUN_007b15a0(kind 0, the item's ref id, 0, 0). FUN_007b0440 opens kind 0
## too for a 3/3/3/1 or 3/3/3/3 item, reached from 0xB15F's handler
## (FUN_0089b660); what 0xB15F is was not read (OPEN). Kind 0 is the
## return scrolls'; kind 1 a collection (0x88d570), 2 a guild recall
## (0x88d910, UIIT_MSG_GUILD_RECALL_MESSAGE, its seconds * 1000), 3 a fixed
## 5000 ms item cast (0x629f00) and 4 a skill's (0x8a4de0) -- not built here.
##
## **What it is (READ, FUN_007b15a0 -> gwnd 0xba20b0, class 0xeec1c8 =
## CIFDelayInfo, id 100 + kind).** A 192 x 36 window (`{0, 0, 0xc0, 0x24}`)
## whose own texture is `interface\ifcommon\com_casting_window.ddj` (set
## through +0x84 vslot 0x34), built from `resinfo\ifdelayinfo.txt`'s
## section "Create" (CIFDelayInfo::Create 0x7b1b70, the string at
## 0xdbcd20): control 10 GDR_DI_GAUGE_DELAY (CIFGauge, 6,27 184x8) at +0x37c,
## 11 GDR_DI_CANCEL (CIFButton, 171,4 20x20,
## `interface\ifcommon\com_casting_cancel.ddj`) at +0x380, and 12
## GDR_DI_NAME (CIFStatic, 0,7 167x12, HAlign 1, FontColor white) at +0x384.
## MEASURED, the art: the window 192 x 36, the gauge 184 x 8 (green
## (0,197,131)..(0,115,74) in its first 182 columns and 5 rows, the rest
## transparent), the button 20 x 20 with `_focus` and `_press` twins.
##
## **Kind 0's content (READ, UI_SILKMALL::FUN_007b1bf0 case 0).** The gauge's
## texture becomes `interface\ifcommon\com_casting_gauge_return.ddj` (no back
## is set: +0x398 stays empty); the name static's text is the item's name
## (the ref's +0x60 NameStrID through the text table, 0x8c9bb0); the total is
## the item's +0x2b4 -- its Param1 -- taken as MILLISECONDS
## (FUN_007b1aa0 -> +0x370, and +0x36c, the remaining, starts there); the
## gauge's value and target start at 0.
##
## **The fill (READ, CIFDelayInfo::vslot_012 0x7b1960, per frame).** While
## the remaining is not 0 it drops by the frame's milliseconds (DAT_0110f7f8,
## the frame delta capped at 3000, funcs 0xba4106); the gauge's value and
## target are both (total - remaining) / total -- so it fills from empty to
## full, left to right (CIFGauge crops its right edge and u together, as the
## buff board's gauge). At 0 the board's FUN_007b1800(kind) runs, which for
## kind 0 does nothing: the bar stays full until the server ends the state.
##
## **The cancel (READ).** Control 11's handler (message map .data 0xebf008:
## ids 11..11, handler 0x7b1a10) calls FUN_0081ee60(kind, ref), whose case 0
## sends 0x705B with no body ("Teleport Casting Cancel"); for kind 0 the bar
## is NOT removed there -- it goes when the state's 0x30bf value 0 arrives.
## No confirmation box: UIIT_STT_TRANSITION_CANCEL is in the text table but
## not in this binary.
##
## **When it closes (READ).** The 0x30bf handler (0x8a80a0) case 0xb, for
## this player and value 0: when the board holds any entry (+0x378) it shows
## UIIT_MSG_TRANSITION_CANCEL_RESULT ("The teleportation has been
## cancelled.", FUN_007781b0(0, text)), then removes kinds 0 and 2. The
## zone reset (FUN_00787860) and this player's death (FUN_0077b000) clear the
## board (FUN_007b1300) with no message.
##
## **Input (READ, a negative).** Kind 0 does not set the board's busy flag
## (+0x36c: set for kinds 1, 3 and 4 only, 0x7b16d4..0x7b171b), the flag the
## action senders and the key handler ask (FUN_0077c8e0) -- so a return
## scroll's bar refuses no movement, skill or attack on the client.

const LAYOUT := "resinfo\\ifdelayinfo.txt"
const SECTION := "Create"
const WINDOW_DDJ := "interface\\ifcommon\\com_casting_window.ddj"
const GAUGE_RETURN_DDJ := "interface\\ifcommon\\com_casting_gauge_return.ddj"
const CANCEL_DDJ := "interface\\ifcommon\\com_casting_cancel.ddj"

## The window: `{0, 0, 0xc0, 0x24}` (READ, 0x7b1640..0x7b1658).
const SIZE := Vector2(192, 36)
## ifdelayinfo.txt's rects (MEASURED), used when the layout cannot be read.
const GAUGE_RECT := Rect2(6, 27, 184, 8)
const CANCEL_RECT := Rect2(171, 4, 20, 20)
const NAME_RECT := Rect2(0, 7, 167, 12)
const GAUGE_NAME := "GDR_DI_GAUGE_DELAY"
const CANCEL_NAME := "GDR_DI_CANCEL"
const NAME_NAME := "GDR_DI_NAME"

## The board's kinds (READ, FUN_007b1bf0's switch).
const KIND_RETURN := 0

## The frame delta's cap (READ: DAT_0110f7f8 is clamped at 3000 ms).
const FRAME_MS_CAP := 3000

## The cancel button was pressed (control 11 -> 0x7b1a10): send 0x705B.
signal cancel_pressed

var kind := KIND_RETURN
## The item's ref id, for the log and the QA hook.
var item_id := 0
## The total and what is left of it, in milliseconds (+0x370 / +0x36c).
var total_ms := 0
var remaining_ms := 0
var _gauge: Range
var _name_label: Label
var _cancel: BaseButton
var _builder: UiBuilder

## Builds the bar for kind 0 with the item's name and its Param1 (ms).
## Without a builder (a test) the controls are plain stand-ins at the
## layout's rects.
func build(builder: UiBuilder, item_name: String, param1_ms: int, ref_id: int = 0) -> DelayInfoBar:
	_builder = builder
	name = "DelayInfo%d" % (100 + kind)
	item_id = ref_id
	size = SIZE
	custom_minimum_size = SIZE
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_add_window()
	var section_root: Control = null
	if _builder != null:
		var layout := _builder.load_layout(LAYOUT)
		if layout != null:
			section_root = _builder.build_section(layout, SECTION)
	if section_root != null:
		section_root.name = "DelayInfoCreate"
		section_root.position = Vector2.ZERO
		add_child(section_root)
		_gauge = section_root.get_node_or_null(GAUGE_NAME) as Range
		_cancel = section_root.get_node_or_null(CANCEL_NAME) as BaseButton
		var name_node := section_root.get_node_or_null(NAME_NAME) as Control
		if name_node != null:
			_name_label = _builder.set_static_text(name_node, item_name)
	if _gauge == null:
		_gauge = _plain_gauge()
	if _cancel == null:
		_cancel = _plain_cancel()
	if _name_label == null:
		_name_label = _plain_name()
		_name_label.text = item_name
	_set_gauge_art()
	_cancel.pressed.connect(func() -> void: cancel_pressed.emit())
	start(param1_ms)
	if _builder != null:
		UiBuilder.settle_authored_rects(self)
	return self

## (Re)starts the count: total and remaining at `ms` (FUN_007b1aa0 then
## `+0x36c = +0x370`), the gauge empty.
func start(ms: int) -> void:
	total_ms = maxi(ms, 0)
	remaining_ms = total_ms
	_show_value()

func _add_window() -> void:
	var bg := TextureRect.new()
	bg.name = "Window"
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	bg.size = SIZE
	if _builder != null:
		bg.texture = _builder.load_texture(WINDOW_DDJ)
	add_child(bg)

## Kind 0's gauge art: the return gauge as the fill, no back (READ).
func _set_gauge_art() -> void:
	var bar := _gauge as TextureProgressBar
	if bar == null:
		return
	bar.min_value = 0
	bar.max_value = 100
	bar.fill_mode = TextureProgressBar.FILL_LEFT_TO_RIGHT
	bar.texture_under = null
	if _builder != null:
		var tex := _builder.load_texture(GAUGE_RETURN_DDJ)
		if tex != null:
			bar.texture_progress = tex
			bar.nine_patch_stretch = false

func _plain_gauge() -> TextureProgressBar:
	var bar := TextureProgressBar.new()
	bar.name = GAUGE_NAME
	bar.position = GAUGE_RECT.position
	bar.size = GAUGE_RECT.size
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bar)
	return bar

func _plain_cancel() -> BaseButton:
	var b := TextureButton.new()
	b.name = CANCEL_NAME
	b.position = CANCEL_RECT.position
	b.size = CANCEL_RECT.size
	add_child(b)
	return b

func _plain_name() -> Label:
	var l := Label.new()
	l.name = NAME_NAME
	l.position = NAME_RECT.position
	l.size = NAME_RECT.size
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(l)
	return l

func _process(delta: float) -> void:
	advance(int(delta * 1000.0))

## One frame of vslot_012: `ms` (capped at 3000) off the remaining, the
## gauge at (total - remaining) / total. At 0 it stops, full.
func advance(ms: int) -> void:
	if remaining_ms <= 0:
		return
	var step := clampi(ms, 0, FRAME_MS_CAP)
	remaining_ms = maxi(remaining_ms - step, 0)
	_show_value()

## The fill, 0..1: (total - remaining) / total.
func fraction() -> float:
	if total_ms <= 0:
		return 1.0
	return float(total_ms - remaining_ms) / float(total_ms)

func _show_value() -> void:
	if _gauge != null:
		_gauge.value = fraction() * 100.0

## The caption shown (the item's name).
func caption() -> String:
	return _name_label.text if _name_label != null else ""

## The cancel button, for the HUD and the QA hook.
func cancel_button() -> BaseButton:
	return _cancel

## The gauge control.
func gauge() -> Range:
	return _gauge

## Where entry `index` of the board sits on a `screen`-sized display (READ,
## FUN_007b1470): the board at x (w - 0xc0) / 2 -- 0x195 when the width is
## 800 -- and y h - 0xa5; entry i at the board's y + 0x4c - 0x26 * i, the
## newest lowest. So one bar's top is 89 px above the bottom edge, centred.
## OPEN, not modelled: at exactly 800 x 600 with window 0x27's +0x36d flag
## set (FUN_00810f50) the board's y is h - 0xc6.
static func screen_position(screen: Vector2, index: int = 0) -> Vector2:
	var w := int(screen.x)
	var h := int(screen.y)
	var x := 0x195 if w == 800 else (w - 0xc0) / 2
	var y := h - 0xa5 + 0x4c - 0x26 * index
	return Vector2(x, y)

## Hidden now, freed at the end of the frame (the button that closes it may
## be its own child).
func close() -> void:
	if is_queued_for_deletion():
		return
	set_process(false)
	name = "%s_closing" % name
	visible = false
	queue_free()
