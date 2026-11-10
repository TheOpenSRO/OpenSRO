extends RefCounted
class_name AutoPotionWindow

## The Auto potion window's controls (round 786): CIFAutoPotion
## (sro_client.exe) over the frame HudPanels builds from ifautopotion.txt
## (round 586). READ unless a line says otherwise; the settings and the checks
## behind it are AutoPotion's (scripts/world/auto_potion.gd).
##
## **What Create builds** (CIFAutoPotion::Create 0x741980): the sections
## Create, AbnormalSlot and PotionDelaySlot; children 10 and 11 are the HP
## and MP rows, CIFAutoPotionSlot, each built from ifautopotionslot.txt
## (0x741f20) with the row's ADDID (100, 200) added to its controls' ids; 15
## the abnormal check box, 18/20 its belt and quick-slot combos, 25 the delay
## check box, 27 the delay spin, 30 Confirm, 31 Cancel. Each belt combo lists
## "F1".."F4" (`F%d`, 0x741b44), each quick-slot combo "1".."9","0" (`%d` of
## i % 10, 0x741b91). The row's name is UIIT_STT_MACROPOTION_HP / _MP (its
## vslot 45, 0x741ec0, on static 2), its unit static 7 "%" (0xdb46f8).
##
## **The slider** (CIFSliderCtrl, row control 15; 0x742113..0x742168): range
## 1..100, step 1, its min / centre / max statics (17, 18, 19) "1", "50",
## "100" (`%d` of min, max / 2, max); arrows and thumb from
## com_qst_lefttarrow_button.ddj, com_qst_rightarrow_button.ddj and
## com_scroll_button.ddj (0x659da0) at (0, 0), (312, 0) and (20, 2)
## (0x6596f0), the thumb travelling 276 px (0x659840): x = 20 + trunc((v -
## min) x 276 / (max - min)) (0x6598a0). Disabled (its row unchecked,
## 0x741cc0 -> 0x6597d0) the arrows and thumb are hidden and the bar is drawn
## from `<art>_disable.ddj` (0x65a18d..0x65a1d9). A move updates the row's
## percent and its static 6 (`%d`, 0x741540 -> 0x741ce0).
##
## **A row's check box** (0x741460, ids 101 / 201): enables or disables the
## row's slider and, when it comes on, puts the slider back on the SAVED
## percent (0x7414d7 -> 0x741df0).
##
## **The delay spin** (CIFVerticalSpinCtrl, 0x658740; 0x741bcd..0x741bfe):
## range 500..9500 ms, step 500, shown as ms / 1000 with one decimal (`%0.1f`,
## 0x6583f0); a black field with the com_blacksquare_ frame over (0, 0, W-20,
## H), ub_up_arrow.ddj at (W-20, 1, 20, 12), ub_down_arrow.ddj at (W-20, H-12,
## 20, 12), the value static at (6, 3, W-26, H-6).
##
## **The check box** (CIFCheckBox, 0x656ec0 / ifcheckbox.txt): the box is
## com_checkbutton_off.ddj, the mark the child static GDR_STATIC_SELECTED
## (com_checkbutton_on.ddj) shown while checked; a left-button RELEASE toggles
## it (vslot 17, 0x656ce0: 0x202).
##
## **Open, Confirm, Cancel.** The window is destroyed when it closes and
## built again on the next open (0x79c750), so every open shows the saved
## settings (0x741880); here the window is kept and fill() refills it on each
## open (OURS, the same picture). Confirm (0x741590) hands the values to
## AutoPotion.apply, which saves only when something changed, and closes;
## Cancel and the close button close (0x7417c0).
##
## OURS / INFERRED, each where it is used: the slider's drag (its mouse
## handling is not read); which arrow steps down (by the art's name); the
## spin's arrows' direction (by name); the PML's left alignment (the reference
## picture).
##
## **The vigor row (round 876, OURS, the user's request; AutoPotion's header
## has its rule).** The original builds two slot rows (children 10, 11) and no
## more. A third CIFAutoPotionSlot, VIGOR_NODE, is built from the same
## ifautopotionslot.txt below the MP row, one row pitch further (the HP -> MP
## step of the layout, 86); every window control below it moves down by that
## pitch, the frames it crosses grow by it, and so does the window
## (_add_vigor_row). The text table has no key that says "Vigor" alone (the
## archive's own vigor strings are the items' names, "Vigor Recovery Potion
## (Small)" and the like), so the row is named VIGOR_LABEL; its value box,
## value and "%" move right just enough to clear the longer name.

const SLOT_LAYOUT := "resinfo\\ifautopotionslot.txt"
const WINDOW_LAYOUT := "resinfo\\ifautopotion.txt"
const CHECKBOX_LAYOUT := "resinfo\\ifcheckbox.txt"
const ROW_NODES := ["GDR_AUTO_POTION_SLOT_HP", "GDR_AUTO_POTION_SLOT_MP"]
const ROW_NAMES := ["UIIT_STT_MACROPOTION_HP", "UIIT_STT_MACROPOTION_MP"]
const ROW_FALLBACK := ["HP", "MP"]
const META := "auto_potion_window"
## Round 876 (OURS): the vigor row's node and name.
const VIGOR_NODE := "GDR_AUTO_POTION_SLOT_VIGOR"
const VIGOR_LABEL := "Vigor"
## The room left between a row's name and its value box (OURS; the HP row's
## "HP" leaves about 6-8 px before the box at 54).
const VIGOR_NAME_GAP := 6

const CHECK_OFF := "interface\\ifcommon\\com_checkbutton_off.ddj"
const CHECK_ON := "interface\\ifcommon\\com_checkbutton_on.ddj"
const SLIDER_PREV := "interface\\ifcommon\\com_qst_lefttarrow_button.ddj"
const SLIDER_NEXT := "interface\\ifcommon\\com_qst_rightarrow_button.ddj"
const SLIDER_THUMB := "interface\\ifcommon\\com_scroll_button.ddj"
const SLIDER_PREV_AT := Vector2(0, 0)
const SLIDER_NEXT_AT := Vector2(312, 0)
const SLIDER_THUMB_AT := Vector2(20, 2)
const SLIDER_TRAVEL := 276
const SLIDER_MIN := 1
const SLIDER_MAX := 100
const SPIN_MIN := 500
const SPIN_MAX := 9500
const SPIN_STEP := 500
const SPIN_DIVISOR := 1000.0
const SPIN_UP := "interface\\underbar\\ub_up_arrow.ddj"
const SPIN_DOWN := "interface\\underbar\\ub_down_arrow.ddj"
const SPIN_ARROW_W := 20
const SPIN_ARROW_H := 12

var window: HudWindow
var _builder: UiBuilder
## Per row (HP, MP): {"check", "slider", "belt", "quick", "data"}.
var _rows: Array = []
## Round 876 (OURS): the vigor row's controls, the same keys; empty when the
## layout has no MP row to place it under.
var _vigor: Dictionary = {}
## How far the vigor row moved the controls below it and grew the window.
var vigor_pitch := 0
var _abnormal_check: Control
var _abnormal_belt: OptionButton
var _abnormal_quick: OptionButton
var _delay_check: Control
var _spin_value := SPIN_MIN
var _spin_label: Label
## The saved percents, which a row's check box puts the slider back on (HP,
## MP and, round 876, the vigor row).
var _saved_percent := [50, 50, 50]
## Called with the window's values on Confirm (AutoPotion.apply's input).
var on_confirm: Callable

static func of(w: HudWindow) -> AutoPotionWindow:
	if w == null or not w.has_meta(META):
		return null
	return w.get_meta(META) as AutoPotionWindow

## Builds the controls into `w` once and returns the controller.
static func compose(w: HudWindow, builder: UiBuilder) -> AutoPotionWindow:
	var existing := of(w)
	if existing != null:
		return existing
	var c := AutoPotionWindow.new()
	c.window = w
	c._builder = builder
	w.set_meta(META, c)
	c._build()
	return c

func _text(key: String, fallback: String) -> String:
	if _builder == null:
		return fallback
	var t := _builder.resolve_text(key)
	return fallback if t == "" or t == key else t

func _build() -> void:
	var layout := _builder.load_layout(WINDOW_LAYOUT) if _builder != null else null
	var slot_layout := _builder.load_layout(SLOT_LAYOUT) if _builder != null else null
	for i in ROW_NODES.size():
		var host := window.node(ROW_NODES[i]) as Control
		_rows.append(_build_row(host, slot_layout, _text(ROW_NAMES[i], ROW_FALLBACK[i]), i))
	_add_vigor_row(slot_layout)
	_abnormal_check = _make_check(window.node("GDR_AUTO_POTION_ABNORMAL_CHECKBOX") as Control)
	_abnormal_belt = _make_combo(window.node("GDR_AUTO_POTION_ABNORMAL_QUICKSLOT_BELT_COMBOBOX") as Control, true)
	_abnormal_quick = _make_combo(window.node("GDR_AUTO_POTION_ABNORMAL_QUICKSLOT_COMBOBOX") as Control, false)
	_delay_check = _make_check(window.node("GDR_AUTO_POTION_DELAY_CHECKBOX") as Control)
	_make_spin(window.node("GDR_AUTO_POTION_DELAY_VERTSPINCTRL") as Control)
	_fill_pml(window.node("GDR_AUTO_POTION_DESC_PML") as Control, layout)
	var ok := window.node("GDR_AUTO_POTION_OK_BTN") as BaseButton
	if ok != null:
		ok.pressed.connect(confirm)
	var cancel := window.node("GDR_AUTO_POTION_CANCEL_BTN") as BaseButton
	if cancel != null:
		cancel.pressed.connect(cancel_window)

## One CIFAutoPotionSlot: ifautopotionslot.txt's Create built into the row's
## node (which the builder made as an item slot; its pieces are removed).
func _build_row(host: Control, slot_layout: UiLayoutParser.LayoutDef, row_name: String, i: int) -> Dictionary:
	var row := {}
	if host == null or slot_layout == null:
		return row
	for child in host.get_children():
		host.remove_child(child)
		child.queue_free()
	host.clip_contents = false
	var root := _builder.build_section(slot_layout, "Create")
	if root == null:
		return row
	root.name = "Row"
	host.add_child(root)
	_builder.set_static_text(root.find_child("GDR_AUTOPOTION_SLOT_NAME", true, false) as Control, row_name)
	_builder.set_static_text(root.find_child("GDR_AUTOPOTION_SLOT_DATA_UNIT_STA", true, false) as Control, "%")
	_builder.set_static_text(root.find_child("GDR_AUTOPOTION_SLOT_MIN_STA", true, false) as Control, str(SLIDER_MIN))
	_builder.set_static_text(root.find_child("GDR_AUTOPOTION_SLOT_CENTER_STA", true, false) as Control, str(SLIDER_MAX / 2))
	_builder.set_static_text(root.find_child("GDR_AUTOPOTION_SLOT_MAX_STA", true, false) as Control, str(SLIDER_MAX))
	row["data"] = root.find_child("GDR_AUTOPOTION_SLOT_DATA", true, false)
	row["check"] = _make_check(root.find_child("GDR_AUTOPOTION_SLOT_CHECKBOX", true, false) as Control)
	row["belt"] = _make_combo(root.find_child("GDR_AUTOPOTION_SLOT_QUICKSLOT_BELT_COMBOBOX", true, false) as Control, true)
	row["quick"] = _make_combo(root.find_child("GDR_AUTOPOTION_SLOT_QUICKSLOT_COMBOBOX", true, false) as Control, false)
	row["slider"] = _make_slider(root.find_child("GDR_AUTOPOTION_SLOT_SLIDERCTRL", true, false) as Control, row)
	var check := row["check"] as Control
	if check != null:
		check.set_meta("on_toggle", func(on: bool) -> void:
			# 0x741460: the slider follows the box, and back on the saved percent.
			_slider_enable(row, on)
			if on:
				_slider_set(row, int(_saved_percent[i])))
	return row

# --- The vigor row (round 876, OURS) ------------------------------------------

## A third slot row under the MP row, the controls below it moved down and the
## window grown by the HP -> MP pitch. Nothing happens when the layout has no
## HP and MP rows (a fixture), so the window stays as authored.
func _add_vigor_row(slot_layout: UiLayoutParser.LayoutDef) -> void:
	var hp := window.node(ROW_NODES[0]) as Control
	var mp := window.node(ROW_NODES[1]) as Control
	if hp == null or mp == null or slot_layout == null or mp.get_parent() == null:
		return
	var hp_rect := _authored(hp)
	var mp_rect := _authored(mp)
	var pitch := int(mp_rect.position.y - hp_rect.position.y)
	if pitch <= 0:
		return
	var at := Rect2(Vector2(mp_rect.position.x, mp_rect.position.y + pitch), mp_rect.size)
	# Below the new row: moved down; across its top: grown (the window's frame
	# and background tile). Only the window's own controls -- the sections'
	# direct children -- since a row's pieces carry rects of their own.
	for c in _window_controls():
		if c == hp or c == mp:
			continue
		var r := _authored(c)
		if r.position.y >= at.position.y:
			r.position.y += pitch
		elif r.end.y > at.position.y:
			# A frame's pieces are laid at build time for its authored
			# height (UiBuilder._build_frame): its sides and bottom follow
			# the new one, or the border ends where the old window did.
			UiBuilder.grow_frame_height(c, r.size.y, pitch)
			r.size.y += pitch
		else:
			continue
		_set_authored(c, r)
	var host := Control.new()
	host.name = VIGOR_NODE
	host.mouse_filter = mp.mouse_filter
	mp.get_parent().add_child(host)
	mp.get_parent().move_child(host, mp.get_index() + 1)
	_set_authored(host, at)
	_vigor = _build_row(host, slot_layout, VIGOR_LABEL, 2)
	_fit_vigor_name(host)
	vigor_pitch = pitch
	window.set_registry_size(window.size + Vector2(0, pitch))

## The longer name: its static widened to the text, and the value box, the
## value and the unit moved right just enough to keep VIGOR_NAME_GAP.
func _fit_vigor_name(host: Control) -> void:
	var name_label := host.find_child("GDR_AUTOPOTION_SLOT_NAME", true, false) as Label
	var box := host.find_child("GDR_AUTOPOTION_SLOT_DATA_BOX", true, false) as Control
	if name_label == null or box == null:
		return
	var font := name_label.get_theme_font("font")
	if font == null:
		return
	var w := ceilf(font.get_string_size(name_label.text, HORIZONTAL_ALIGNMENT_LEFT, -1,
		name_label.get_theme_font_size("font_size")).x)
	var nr := _authored(name_label)
	if w > nr.size.x:
		nr.size.x = w
		_set_authored(name_label, nr)
	var shift := int(maxf(0.0, nr.position.x + w + VIGOR_NAME_GAP - _authored(box).position.x))
	if shift == 0:
		return
	for n in ["GDR_AUTOPOTION_SLOT_DATA_BOX", "GDR_AUTOPOTION_SLOT_DATA", "GDR_AUTOPOTION_SLOT_DATA_UNIT_STA"]:
		var c := host.find_child(n, true, false) as Control
		if c != null:
			var r := _authored(c)
			r.position.x += shift
			_set_authored(c, r)

## The window's own layout controls: the Create section's and each extra
## section's direct children.
func _window_controls() -> Array:
	var out: Array = []
	if window.panel_root == null:
		return out
	for c in window.panel_root.get_children():
		if not c is Control:
			continue
		if c.has_meta(UiBuilder.AUTHORED_RECT_META):
			out.append(c)
		else:
			for cc in c.get_children():
				if cc is Control and cc.has_meta(UiBuilder.AUTHORED_RECT_META):
					out.append(cc)
	return out

static func _authored(c: Control) -> Rect2:
	if c.has_meta(UiBuilder.AUTHORED_RECT_META):
		return c.get_meta(UiBuilder.AUTHORED_RECT_META)
	return Rect2(c.position, c.size)

## A new authored rect, applied now and kept through the settling passes.
static func _set_authored(c: Control, r: Rect2) -> void:
	c.set_meta(UiBuilder.AUTHORED_RECT_META, r)
	UiBuilder.apply_authored_rects(c)

# --- Check box ----------------------------------------------------------------

func _make_check(host: Control) -> Control:
	if host == null:
		return null
	var off := _builder.load_texture(CHECK_OFF)
	if off != null and host.size == Vector2.ZERO:
		host.size = off.get_size()
		host.custom_minimum_size = off.get_size()
	var box := TextureRect.new()
	box.name = "Box"
	box.texture = off
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	host.add_child(box)
	var mark := TextureRect.new()
	mark.name = "Mark"
	mark.texture = _builder.load_texture(CHECK_ON)
	mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	host.add_child(mark)
	host.mouse_filter = Control.MOUSE_FILTER_STOP
	host.set_meta("checked", true) # 0x656c78: built checked
	host.gui_input.connect(func(e: InputEvent) -> void:
		var mb := e as InputEventMouseButton
		if mb != null and mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
			AutoPotionWindow.set_checked(host, not AutoPotionWindow.is_checked(host))
			var cb = (host.get_meta("on_toggle") if host.has_meta("on_toggle") else null)
			if cb is Callable and (cb as Callable).is_valid():
				(cb as Callable).call(AutoPotionWindow.is_checked(host)))
	return host

static func is_checked(box: Control) -> bool:
	return box != null and bool(box.get_meta("checked", false))

static func set_checked(box: Control, on: bool) -> void:
	if box == null:
		return
	box.set_meta("checked", on)
	var mark := box.get_node_or_null("Mark") as CanvasItem
	if mark != null:
		mark.visible = on

# --- Combo --------------------------------------------------------------------

func _make_combo(host: Control, belt: bool) -> OptionButton:
	if host == null:
		return null
	if host.size == Vector2.ZERO:
		host.size = Vector2(57, 20)
	var combo := OptionVideoPage.new(null, _builder, null)._make_combo(host)
	if combo == null:
		return null
	if belt:
		for i in range(1, 5):
			combo.add_item("F%d" % i, i - 1)
	else:
		for i in range(1, 11):
			combo.add_item("%d" % (i % 10), i - 1)
	combo.select(0)
	return combo

## A row's quick slot from its two combos (0x741d80 / 0x741420).
static func slot_of(belt: int, key: int) -> int:
	return mini(belt * 10 + key + 1, AutoPotion.MAX_SLOT)

## The combos for a slot (0x741d30 / 0x7413d0): left alone past 40 or at 0.
static func combos_for(slot: int) -> Array:
	if slot - 1 < 0 or slot - 1 >= AutoPotion.MAX_SLOT:
		return []
	return [(slot - 1) / 10, (slot - 1) % 10]

func _combo_slot(belt: OptionButton, quick: OptionButton) -> int:
	if belt == null or quick == null:
		return 0
	return slot_of(maxi(belt.selected, 0), maxi(quick.selected, 0))

func _set_combos(belt: OptionButton, quick: OptionButton, slot: int) -> void:
	var c := combos_for(slot)
	if c.is_empty() or belt == null or quick == null:
		return
	belt.select(int(c[0]))
	quick.select(int(c[1]))

# --- Slider -------------------------------------------------------------------

func _make_slider(host: Control, row: Dictionary) -> Control:
	if host == null:
		return null
	host.mouse_filter = Control.MOUSE_FILTER_PASS
	var track := TextureRect.new()
	track.name = "Track"
	track.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	track.stretch_mode = TextureRect.STRETCH_SCALE
	track.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	host.add_child(track)
	var defs := [["Prev", SLIDER_PREV, SLIDER_PREV_AT], ["Next", SLIDER_NEXT, SLIDER_NEXT_AT], ["Thumb", SLIDER_THUMB, SLIDER_THUMB_AT]]
	for d in defs:
		var def := UiLayoutParser.ControlDef.new()
		def.name = String(d[0])
		def.type = "CIFButton"
		def.ddj = String(d[1])
		def.rect = Rect2i(Vector2i(d[2]), Vector2i.ZERO)
		var b := _builder.build_control(def)
		if b != null:
			host.add_child(b)
	host.set_meta("value", SLIDER_MIN)
	var prev := host.get_node_or_null("Prev") as BaseButton
	var nxt := host.get_node_or_null("Next") as BaseButton
	if prev != null:
		prev.pressed.connect(func() -> void: _slider_set(row, int(host.get_meta("value")) - 1))
	if nxt != null:
		nxt.pressed.connect(func() -> void: _slider_set(row, int(host.get_meta("value")) + 1))
	var thumb := host.get_node_or_null("Thumb") as Control
	if thumb != null:
		thumb.gui_input.connect(func(e: InputEvent) -> void:
			# OURS: the drag (CIFSliderCtrl's mouse handling is not read) --
			# the placement 0x6598a0 inverted.
			var mm := e as InputEventMouseMotion
			if mm != null and mm.button_mask & MOUSE_BUTTON_MASK_LEFT:
				var x := thumb.position.x + mm.position.x - thumb.size.x / 2.0 - SLIDER_THUMB_AT.x
				_slider_set(row, SLIDER_MIN + int(round(x * (SLIDER_MAX - SLIDER_MIN) / SLIDER_TRAVEL))))
	_slider_enable(row, true, host)
	return host

## 0x6598a0: clamp, place the thumb, tell the window (0x741540 -> 0x741ce0:
## the row's percent and its `%d` static).
func _slider_set(row: Dictionary, v: int) -> void:
	var host := row.get("slider") as Control
	if host == null:
		return
	v = clampi(v, SLIDER_MIN, SLIDER_MAX)
	host.set_meta("value", v)
	var thumb := host.get_node_or_null("Thumb") as Control
	if thumb != null:
		thumb.position = Vector2(SLIDER_THUMB_AT.x + thumb_offset(v), SLIDER_THUMB_AT.y)
		# The thumb is a built control with an authored rect: a settling pass
		# (UiBuilder.apply_authored_rects, e.g. the window's re-centring on
		# its first open) would put it back at the slider's start.
		if thumb.has_meta(UiBuilder.AUTHORED_RECT_META):
			var ar: Rect2 = thumb.get_meta(UiBuilder.AUTHORED_RECT_META)
			ar.position = thumb.position
			thumb.set_meta(UiBuilder.AUTHORED_RECT_META, ar)
	_builder.set_static_text(row.get("data") as Control, "%d" % v)

## The thumb's x past its origin for value v (0x6598e2..0x659901).
static func thumb_offset(v: int) -> int:
	return int(float((v - SLIDER_MIN) * SLIDER_TRAVEL) / float(SLIDER_MAX - SLIDER_MIN))

## 0x6597d0: the children shown with the slider enabled, and the bar's art.
func _slider_enable(row: Dictionary, on: bool, host: Control = null) -> void:
	if host == null:
		host = row.get("slider") as Control
	if host == null:
		return
	host.set_meta("enabled", on)
	for n in ["Prev", "Next", "Thumb"]:
		var c := host.get_node_or_null(n) as CanvasItem
		if c != null:
			c.visible = on
	var track := host.get_node_or_null("Track") as TextureRect
	var def = _slider_def()
	if track != null and def != null:
		var art: String = def.ddj
		if not on:
			art = art.trim_suffix(".ddj") + "_disable.ddj"
		track.texture = _builder.load_texture(art)

func _slider_def() -> UiLayoutParser.ControlDef:
	var layout := _builder.load_layout(SLOT_LAYOUT)
	var sec := layout.get_section("Create") if layout != null else null
	if sec == null:
		return null
	return sec.control_by_name.get("GDR_AUTOPOTION_SLOT_SLIDERCTRL")

# --- Spin ---------------------------------------------------------------------

func _make_spin(host: Control) -> void:
	if host == null:
		return
	var w := host.size.x
	var h := host.size.y
	var field := Control.new()
	field.name = "Field"
	field.position = Vector2.ZERO
	field.size = Vector2(w - SPIN_ARROW_W, h)
	field.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var pieces := {}
	for p in OptionVideoPage.COMBO_FIELD_PIECES:
		pieces[p] = _builder.load_texture(OptionVideoPage.COMBO_FIELD_BASE + p + ".ddj")
	field.draw.connect(func() -> void: OptionVideoPage.draw_combo_field(field, pieces))
	host.add_child(field)
	for d in [["Up", SPIN_UP, Vector2(w - SPIN_ARROW_W, 1), SPIN_STEP], ["Down", SPIN_DOWN, Vector2(w - SPIN_ARROW_W, h - SPIN_ARROW_H), -SPIN_STEP]]:
		var def := UiLayoutParser.ControlDef.new()
		def.name = String(d[0])
		def.type = "CIFButton"
		def.ddj = String(d[1])
		def.rect = Rect2i(Vector2i(d[2]), Vector2i(SPIN_ARROW_W, SPIN_ARROW_H))
		var b := _builder.build_control(def) as BaseButton
		if b != null:
			host.add_child(b)
			var step := int(d[3])
			b.pressed.connect(func() -> void: set_spin(_spin_value + step))
	_spin_label = Label.new()
	_spin_label.name = "Value"
	_spin_label.position = Vector2(6, 3)
	_spin_label.size = Vector2(w - SPIN_ARROW_W - 6, h - 6)
	_spin_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_spin_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_spin_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var font := _builder.font_at(0)
	if font != null:
		_spin_label.add_theme_font_override("font", font)
	_spin_label.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[0])
	UiBuilder.crisp_text(_spin_label)
	host.add_child(_spin_label)
	host.mouse_filter = Control.MOUSE_FILTER_PASS
	set_spin(_spin_value)

## 0x6585c0 (clamped to 500..9500) and 0x6583f0 (`%0.1f` of ms / 1000).
func set_spin(ms: int) -> void:
	_spin_value = clampi(ms, SPIN_MIN, SPIN_MAX)
	if _spin_label != null:
		_spin_label.text = spin_text(_spin_value)

static func spin_text(ms: int) -> String:
	return "%0.1f" % (float(ms) / SPIN_DIVISOR)

func spin_value() -> int:
	return _spin_value

# --- PML ----------------------------------------------------------------------

func _fill_pml(host: Control, layout: UiLayoutParser.LayoutDef) -> void:
	if host == null:
		return
	var key := "UIIT_STT_MACROPOTION_CONTENTS"
	var raw := _text(key, "")
	if raw == "":
		return
	# Round 848: the client's PML (PmlText: the record's FontColor and HAlign
	# 0), where it was a Godot RichTextLabel fed BBCode.
	host.clip_contents = true
	PmlText.put_on(host, _builder, raw)

# --- Load / read / confirm -------------------------------------------------------

## Fills the controls from AutoPotion.values() (0x741880); the vigor row
## from its fourth row (round 876, OURS).
func fill(values: Dictionary) -> void:
	var vr: Array = values.get("rows", [])
	for i in mini(_rows.size(), vr.size()):
		_fill_row(_rows[i], vr[i], i)
	if not _vigor.is_empty() and vr.size() > AutoPotion.ROW_VIGOR:
		_fill_row(_vigor, vr[AutoPotion.ROW_VIGOR], 2)
	if vr.size() > AutoPotion.ROW_ABNORMAL:
		var a: Dictionary = vr[AutoPotion.ROW_ABNORMAL]
		set_checked(_abnormal_check, bool(a.get("enabled", false)))
		_set_combos(_abnormal_belt, _abnormal_quick, int(a.get("slot", 0)))
	set_checked(_delay_check, bool(values.get("delay_enabled", false)))
	set_spin(int(values.get("delay_ms", SPIN_MIN)))

func _fill_row(row: Dictionary, v: Dictionary, saved: int) -> void:
	_saved_percent[saved] = int(v.get("percent", 0))
	set_checked(row.get("check") as Control, bool(v.get("enabled", false)))
	_slider_enable(row, bool(v.get("enabled", false)))
	_set_combos(row.get("belt") as OptionButton, row.get("quick") as OptionButton, int(v.get("slot", 0)))
	_slider_set(row, int(v.get("percent", 0)))

func _row_values(r: Dictionary) -> Dictionary:
	var slider := r.get("slider") as Control
	return {"enabled": is_checked(r.get("check") as Control),
		"percent": int(slider.get_meta("value", SLIDER_MIN)) if slider != null else SLIDER_MIN,
		"slot": _combo_slot(r.get("belt") as OptionButton, r.get("quick") as OptionButton)}

## The controls' values, in AutoPotion.apply's shape (and, the fourth row,
## apply_vigor's; round 876).
func read() -> Dictionary:
	var out_rows: Array = []
	for row in _rows:
		out_rows.append(_row_values(row))
	out_rows.append({"enabled": is_checked(_abnormal_check), "percent": 0,
		"slot": _combo_slot(_abnormal_belt, _abnormal_quick)})
	if not _vigor.is_empty():
		out_rows.append(_row_values(_vigor))
	return {"rows": out_rows, "delay_enabled": is_checked(_delay_check), "delay_ms": _spin_value}

## Confirm (0x741590): the values go to the settings, and the window closes.
func confirm() -> void:
	if on_confirm.is_valid():
		on_confirm.call(read())
	window.hide()
	window.closed.emit()

## Cancel (0x7417c0): closes; the next open shows the saved settings.
func cancel_window() -> void:
	window.hide()
	window.closed.emit()

## Test and QA access: 0 HP, 1 MP, AutoPotion.ROW_VIGOR the vigor row.
func row_controls(i: int) -> Dictionary:
	if i == AutoPotion.ROW_VIGOR:
		return _vigor
	return _rows[i] if i >= 0 and i < _rows.size() else {}

## Round 876 (QA): a control by row (hp, mp, vigor, abn, delay, ok, cancel)
## and part (check, prev, next, thumb, belt, quick, spinup, spindown).
func qa_control(row: String, part: String) -> Control:
	match row:
		"ok":
			return window.node("GDR_AUTO_POTION_OK_BTN") as Control
		"cancel":
			return window.node("GDR_AUTO_POTION_CANCEL_BTN") as Control
		"abn":
			return abnormal_controls().get(part) as Control
		"delay":
			if part == "check":
				return _delay_check
			var spin := window.node("GDR_AUTO_POTION_DELAY_VERTSPINCTRL") as Control
			if spin == null:
				return null
			return spin.get_node_or_null("Up" if part == "spinup" else "Down") as Control
	var r := row_controls({"hp": 0, "mp": 1, "vigor": AutoPotion.ROW_VIGOR}.get(row, -1))
	if part in ["prev", "next", "thumb"]:
		var slider := r.get("slider") as Control
		return slider.get_node_or_null(part.capitalize()) as Control if slider != null else null
	return r.get(part) as Control

## Round 876 (QA, tests): what is wrong with the window's layout, as lines --
## any two of its content controls (the three rows, the abnormal and delay
## rows' pieces, the description, Confirm and Cancel) overlapping, any of them
## outside the window, and inside the vigor row any two of its top line's
## pieces (check box, name text, value box, value, unit, the belt and quick
## slot statics and combos) overlapping. Empty when it is right. Rects are
## the authored ones (UI units, window-relative); a text's is its drawn
## extent (place_label's rule, from the label's own font).
func layout_problems() -> Array:
	var out: Array = []
	var named := {}
	for n in ROW_NODES + [VIGOR_NODE, "GDR_AUTO_POTION_DESC_PML", "GDR_AUTO_POTION_OK_BTN", "GDR_AUTO_POTION_CANCEL_BTN",
			"GDR_AUTO_POTION_ABNORMAL_CHECKBOX", "GDR_AUTO_POTION_ABNORMAL_NAME", "GDR_AUTO_POTION_ABNORMAL_QUICKSLOT_BELT_STA",
			"GDR_AUTO_POTION_ABNORMAL_QUICKSLOT_BELT_COMBOBOX", "GDR_AUTO_POTION_ABNORMAL_QUICKSLOT_STA",
			"GDR_AUTO_POTION_ABNORMAL_QUICKSLOT_COMBOBOX", "GDR_AUTO_POTION_DELAY_CHECKBOX", "GDR_AUTO_POTION_DELAY_NAME",
			"GDR_AUTO_POTION_DELAY_VERTSPINCTRL"]:
		var c := window.node(n) as Control
		if c != null:
			named[n] = _content_rect(c, Vector2.ZERO)
	_overlaps(named, out)
	var bounds := Rect2(Vector2.ZERO, window.size)
	for n in named:
		if not bounds.encloses(named[n]):
			out.append("%s %s outside the window %s" % [n, str(named[n]), str(window.size)])
	var host := window.node(VIGOR_NODE) as Control
	if host != null:
		var origin := _authored(host).position
		var row := {}
		for n in ["GDR_AUTOPOTION_SLOT_CHECKBOX", "GDR_AUTOPOTION_SLOT_NAME", "GDR_AUTOPOTION_SLOT_DATA_BOX",
				"GDR_AUTOPOTION_SLOT_UNIT_AND_VALUE", "GDR_AUTOPOTION_SLOT_QUICKSLOT_BELT_STA",
				"GDR_AUTOPOTION_SLOT_QUICKSLOT_BELT_COMBOBOX", "GDR_AUTOPOTION_SLOT_QUICKSLOT_STA",
				"GDR_AUTOPOTION_SLOT_QUICKSLOT_COMBOBOX"]:
			if n == "GDR_AUTOPOTION_SLOT_UNIT_AND_VALUE":
				# The value sits inside its box by design; the unit beside it.
				var unit := host.find_child("GDR_AUTOPOTION_SLOT_DATA_UNIT_STA", true, false) as Control
				if unit != null:
					row["GDR_AUTOPOTION_SLOT_DATA_UNIT_STA"] = _content_rect(unit, origin)
				continue
			var c := host.find_child(n, true, false) as Control
			if c != null:
				row[n] = _content_rect(c, origin)
		_overlaps(row, out)
	return out

static func _overlaps(rects: Dictionary, out: Array) -> void:
	var names := rects.keys()
	for i in names.size():
		for j in range(i + 1, names.size()):
			var a: Rect2 = rects[names[i]]
			var b: Rect2 = rects[names[j]]
			var x := a.intersection(b)
			if x.size.x > 0.5 and x.size.y > 0.5:
				out.append("%s %s overlaps %s %s" % [names[i], str(a), names[j], str(b)])

## A control's rect in its section's units: a static's drawn text extent
## (left / right / centre by its alignment), anything else its authored rect.
func _content_rect(c: Control, origin: Vector2) -> Rect2:
	var r := _authored(c)
	var lbl := c as Label
	if lbl != null and lbl.text != "":
		var font := lbl.get_theme_font("font")
		if font != null:
			var w := font.get_string_size(lbl.text, HORIZONTAL_ALIGNMENT_LEFT, -1, lbl.get_theme_font_size("font_size")).x
			var x := r.position.x
			if lbl.horizontal_alignment == HORIZONTAL_ALIGNMENT_RIGHT:
				x = r.end.x - w
			elif lbl.horizontal_alignment == HORIZONTAL_ALIGNMENT_CENTER:
				x = r.position.x + (r.size.x - w) / 2.0
			r = Rect2(x, r.position.y, w, r.size.y)
	elif r.size == Vector2.ZERO:
		r.size = c.size
	r.position += origin
	return r

func abnormal_controls() -> Dictionary:
	return {"check": _abnormal_check, "belt": _abnormal_belt, "quick": _abnormal_quick}

func delay_check() -> Control:
	return _delay_check
