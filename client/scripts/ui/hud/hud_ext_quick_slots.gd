extends Control
class_name HudExtQuickSlots

## The Additional Quick Slot bars (round 788): retail's one bar
## (HudExtQuickSlot index 0, quick slots 41..50 -- READ, always present) and
## OpenSRO's extra bars (index 1.., OURS), each with its own options,
## position, collapse and orientation; ExtQuickSlotSettings keeps them.
##
## OURS, all of it beyond bar 0: how many extra bars and pages per bar come
## from the settings ([ext_quick_slot] extra_bars, pages; default 1 and 4),
## changed in an extra bar's option window (its Bars / Pages row) or the
## settings file. The quick slots are reserved for up to
## HudUnderbar.EXT_BARS_MAX bars of EXT_PAGES_MAX pages, so raising either
## changes no stored format. An extra bar's default place is the retail
## default moved left by one header width plus GAP per bar.
##
## A full-screen layer that takes no click itself: the bars and their option
## windows are its children, at canvas coordinates.

## The bars' new slots (made by a count change), for the owner to fill from
## its quick-slot tables (World3D: icons, tips, counts).
signal slots_created(indices: Array)

const GAP := 4

var settings_path := ClientSettings.PATH
var bars: Array = []
var extra_bars := ExtQuickSlotSettings.DEFAULT_BARS
var pages := ExtQuickSlotSettings.DEFAULT_PAGES

var _builder: UiBuilder
var _underbar: HudUnderbar

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

## Builds retail's bar and the OURS bars the settings ask for. False when
## retail's cannot be built (no layout, no bottom bar): then there are none.
func setup(builder: UiBuilder, underbar: HudUnderbar) -> bool:
	_builder = builder
	_underbar = underbar
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	extra_bars = ExtQuickSlotSettings.extra_bars(settings_path)
	pages = ExtQuickSlotSettings.pages(settings_path)
	if _make_bar(0, 1) == null:
		print("HudExtQuickSlots: no Additional Quick Slot (%s or the bottom bar's slots missing)" % ExtQuickSlotLayout.LAYOUT)
		return false
	for i in range(1, extra_bars + 1):
		_make_bar(i, pages)
	print("HudExtQuickSlots: %d bar(s) -- retail's and %d extra of %d page(s)" % [bars.size(), bars.size() - 1, pages])
	if OS.get_environment("OPENSRO_QA_SLOTS") != "":
		add_to_group("qa_slots")
	return true

func _make_bar(index: int, page_count: int) -> HudExtQuickSlot:
	var eb := HudExtQuickSlot.new(_builder, _underbar, index, page_count)
	eb.name = "ExtQuickSlot%d" % index
	eb.window_host = self
	eb.counts = [extra_bars, pages]
	add_child(eb)
	if not eb.setup(ExtQuickSlotSettings.kept_options(index, settings_path)):
		remove_child(eb)
		eb.queue_free()
		return null
	_place(eb)
	eb.changed.connect(func() -> void: ExtQuickSlotSettings.save_options(eb.bar_index, eb.options(), settings_path))
	eb.moved.connect(func() -> void: ExtQuickSlotSettings.save_position(eb.bar_index, eb.position, settings_path))
	eb.counts_requested.connect(func(b: int, p: int) -> void: set_counts.call_deferred(b, p))
	bars.append(eb)
	return eb

## On show: a kept position clamped on the right and bottom only, or the
## default place (ExtQuickSlotLayout, READ); an extra bar's default is moved
## left (OURS).
func _place(eb: HudExtQuickSlot) -> void:
	var screen := get_viewport_rect().size if is_inside_tree() else size
	var kept = ExtQuickSlotSettings.kept_position(eb.bar_index, settings_path)
	if kept != null:
		eb.position = ExtQuickSlotLayout.clamp_on_show(kept, eb.size, screen)
	else:
		var at := ExtQuickSlotLayout.default_position(screen, eb.size.x)
		at.x -= eb.bar_index * (eb.size.x + GAP)
		eb.position = at

## A bar by its index, or null.
func bar(index: int) -> HudExtQuickSlot:
	for b in bars:
		if (b as HudExtQuickSlot).bar_index == index:
			return b
	return null

## OURS: shows `count` extra bars of `page_count` pages, saved. Bars past the
## count go (their slots stay in the quick-slot tables and come back with
## them); a page change rebuilds every extra bar. New slots are announced.
func set_counts(count: int, page_count: int) -> void:
	count = clampi(count, 0, HudUnderbar.EXT_BARS_MAX)
	page_count = clampi(page_count, 1, HudUnderbar.EXT_PAGES_MAX)
	if count == extra_bars and page_count == pages:
		return
	ExtQuickSlotSettings.save_counts(count, page_count, settings_path)
	var rebuild := page_count != pages
	extra_bars = count
	pages = page_count
	for b in bars.duplicate():
		var eb := b as HudExtQuickSlot
		if eb.bar_index > 0 and (rebuild or eb.bar_index > count):
			_remove_bar(eb)
	var created: Array = []
	for i in range(1, count + 1):
		if bar(i) == null:
			var nb := _make_bar(i, pages)
			if nb != null:
				created.append_array(nb.lent_indices())
	for b in bars:
		(b as HudExtQuickSlot).counts = [extra_bars, pages]
	print("HudExtQuickSlots: now %d extra bar(s) of %d page(s)" % [extra_bars, pages])
	if not created.is_empty():
		slots_created.emit(created)

func _remove_bar(b: HudExtQuickSlot) -> void:
	b.close_option()
	b.release_slots()
	bars.erase(b)
	remove_child(b)
	b.queue_free()

## Alt+digit (OURS, KeyMap): the first extra bar's key k on its page. The
## quick slot fired, or -1 when there is no extra bar.
func activate_key(k: int) -> int:
	var b := bar(1)
	return b.activate_key(k) if b != null else -1

## Whether a bar's button is under a global point (a held icon's pass-through).
func button_at(at: Vector2) -> bool:
	for b in bars:
		if (b as HudExtQuickSlot).button_at(at):
			return true
	return false

## QA only (OPENSRO_QA_SLOTS, F11): where the bars are.
func qa_print_slots() -> void:
	for b in bars:
		(b as HudExtQuickSlot).qa_print()
