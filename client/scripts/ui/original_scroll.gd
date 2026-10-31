extends Node
class_name OriginalScroll

## Round 848 (lane T): the original's scroll bar on a control that scrolls
## natively (RichTextLabel, ItemList, TextEdit, ScrollContainer), in place of
## Godot's VScrollBar.
##
## The original has two scroll bars, both already built here:
##   - CIFVerticalScroll (the .txt windows): HudChat.ChatScroll. READ
##     (CIFVerticalScroll::Create 0x65a9c0): resinfo\ifverticalscroll.txt's
##     parts -- the up arrow chat_arrow_up.ddj at (0, -16), the down arrow
##     chat_arrow_down.ddj, the 16 x 16 thumb com_scroll_button.ddj -- over
##     com_scroll_bar.ddj, and a length of the control's own rect height
##     (0xb8f420 then 0x65a390(height, 0, 100, 1)) unless the window's Create
##     sets another (the chat's 308, the NPC talk's 320). One step is one line
##     (0x6592a0).
##   - CNIFVerticalScroll (the .2dt windows): VScroll2dt, on the record's node.
##
## How to use it (the sites that still have a native bar call one of these):
##   OriginalScroll.attach_cif(rich_text, builder, layout_scroll_node)
##       the layout's CIFVerticalScroll control (length = its rect height);
##   OriginalScroll.attach_2dt(rich_text, builder, record_node)
##       a .2dt window's CNIFVerticalScroll record;
##   OriginalScroll.hide_bars(text_edit)
##       where the original draws no bar at all (the control still scrolls by
##       the wheel and the caret).
## The native bar keeps doing the scrolling, drawn at zero width and
## invisible; the original's bar follows it and drives it, a line a step.
## OURS: the line is the control's own line height (a RichTextLabel's font
## height plus its line separation, an ItemList's row, a TextEdit's line),
## and a ScrollContainer's is the client's 14-px chat line.

const LINE_FALLBACK := 14.0

var target: Control
var native: ScrollBar
var cif: HudChat.ChatScroll = null
var vs2dt: VScroll2dt = null
var _syncing := false

## The vertical bar Godot draws inside `target`, or null.
static func native_bar(target: Control) -> VScrollBar:
	if target is RichTextLabel:
		return (target as RichTextLabel).get_v_scroll_bar()
	if target is ItemList:
		return (target as ItemList).get_v_scroll_bar()
	if target is TextEdit:
		return (target as TextEdit).get_v_scroll_bar()
	if target is ScrollContainer:
		return (target as ScrollContainer).get_v_scroll_bar()
	return null

static func native_h_bar(target: Control) -> HScrollBar:
	if target is ItemList:
		return (target as ItemList).get_h_scroll_bar()
	if target is TextEdit:
		return (target as TextEdit).get_h_scroll_bar()
	if target is ScrollContainer:
		return (target as ScrollContainer).get_h_scroll_bar()
	return null

## A native bar that still scrolls but takes no width, draws nothing and
## takes no clicks: every style empty and every arrow a zero-size texture, so
## its owner reserves no room for it.
static func hide_native(bar: ScrollBar) -> void:
	if bar == null:
		return
	for st in ["scroll", "scroll_focus", "grabber", "grabber_highlight", "grabber_pressed", "hscroll", "vscroll"]:
		bar.add_theme_stylebox_override(st, StyleBoxEmpty.new())
	var none := PlaceholderTexture2D.new()
	none.size = Vector2.ZERO
	for ic in ["increment", "increment_highlight", "increment_pressed", "decrement", "decrement_highlight", "decrement_pressed"]:
		bar.add_theme_icon_override(ic, none)
	bar.modulate = Color(1, 1, 1, 0)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE

## Both native bars of `target` hidden (hide_native); a ScrollContainer's are
## set never to show.
static func hide_bars(target: Control) -> void:
	if target is ScrollContainer:
		var sc := target as ScrollContainer
		sc.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
		sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
		return
	hide_native(native_bar(target))
	hide_native(native_h_bar(target))

## The CIF bar (HudChat.ChatScroll) on `host` -- the layout's
## CIFVerticalScroll control, whose top is the bar's top (the up arrow sits 16
## above it) -- driving `target`. `length` < 0 takes the host's rect height
## (READ, CIFVerticalScroll::Create). Returns the binding, or null.
static func attach_cif(target: Control, builder: UiBuilder, host: Control, length: float = -1.0) -> OriginalScroll:
	if target == null or host == null:
		return null
	var s := _bind(target)
	if s == null:
		return null
	var bar := HudChat.ChatScroll.new()
	bar.name = "OriginalScroll"
	if builder != null:
		bar.up_texture = builder.load_texture(HudChat.ARROW_UP_DDJ)
		bar.down_texture = builder.load_texture(HudChat.ARROW_DOWN_DDJ)
		bar.bar_texture = builder.load_texture(HudChat.SCROLL_BAR_DDJ)
		bar.thumb_texture = builder.load_texture(HudChat.SCROLL_THUMB_DDJ)
	bar.length = length if length >= 0.0 else _authored_height(host)
	bar.position = Vector2(0, -HudChat.SCROLL_BUTTON.y)
	bar.size = Vector2(HudChat.SCROLL_BUTTON.x, HudChat.SCROLL_BUTTON.y * 3 + bar.length)
	host.visible = true
	host.add_child(bar)
	s.cif = bar
	bar.moved.connect(s._on_moved)
	s._pull()
	return s

## The CNIF bar (VScroll2dt) on a .2dt window's CNIFVerticalScroll record
## `host`, driving `target`. Returns the binding, or null.
static func attach_2dt(target: Control, builder: UiBuilder, host: Control) -> OriginalScroll:
	if target == null or host == null:
		return null
	var s := _bind(target)
	if s == null:
		return null
	host.visible = true
	# No pane: the target's own wheel already scrolls the native bar, which
	# this follows.
	s.vs2dt = VScroll2dt.build_on(host, builder, null)
	if s.vs2dt != null:
		s.vs2dt.changed.connect(s._on_moved)
	s._pull()
	return s

static func _bind(target: Control) -> OriginalScroll:
	var bar := native_bar(target)
	if target is ScrollContainer:
		(target as ScrollContainer).vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	elif bar != null:
		hide_native(bar)
	if bar == null:
		return null
	var s := OriginalScroll.new()
	s.name = "OriginalScrollBinding"
	s.target = target
	s.native = bar
	target.add_child(s)
	bar.changed.connect(s._pull)
	bar.value_changed.connect(func(_v: float) -> void: s._pull())
	return s

## The height the layout gave `host` (UiBuilder records it; Godot may have
## clamped node.size).
static func _authored_height(host: Control) -> float:
	if host.has_meta(UiBuilder.AUTHORED_RECT_META):
		var r: Variant = host.get_meta(UiBuilder.AUTHORED_RECT_META)
		if r is Rect2:
			return (r as Rect2).size.y
		if r is Rect2i:
			return float((r as Rect2i).size.y)
	return host.size.y

## One line of `target`, in its scroll units (pixels).
func line_px() -> float:
	if target is RichTextLabel:
		var rt := target as RichTextLabel
		var f := rt.get_theme_font("normal_font")
		var fs := rt.get_theme_font_size("normal_font_size")
		if f != null:
			return maxf(1.0, f.get_height(fs) + rt.get_theme_constant("line_separation"))
	elif target is ItemList:
		var il := target as ItemList
		if il.item_count > 0:
			return maxf(1.0, il.get_item_rect(0).size.y + il.get_theme_constant("v_separation"))
	elif target is TextEdit:
		return maxf(1.0, float((target as TextEdit).get_line_height()))
	return LINE_FALLBACK

## The last line the bar can reach: what the native range scrolls, in lines.
func max_line() -> int:
	if native == null:
		return 0
	var span := native.max_value - native.page - native.min_value
	return maxi(0, ceili(span / line_px() - 0.001))

## The line on show.
func line() -> int:
	if native == null:
		return 0
	return mini(roundi((native.value - native.min_value) / line_px()), max_line())

## The native bar moved or its range changed: the original's bar follows.
func _pull() -> void:
	if _syncing or native == null:
		return
	_syncing = true
	if cif != null:
		cif.set_range(max_line(), line())
	if vs2dt != null:
		vs2dt.max_line = max_line()
		vs2dt.line = line()
		vs2dt._place_thumb()
	_syncing = false

## The original's bar moved: the native one follows, a line a step.
func _on_moved(to: int) -> void:
	if _syncing or native == null:
		return
	_syncing = true
	var last := max_line()
	var v := native.min_value + float(clampi(to, 0, last)) * line_px()
	if to >= last:
		v = native.max_value - native.page
	native.value = v
	_syncing = false
