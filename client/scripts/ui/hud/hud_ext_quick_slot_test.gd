extends SceneTree

## The Additional Quick Slot bars (round 788): retail's CIFExtQuickSlot and
## the OURS extra bars, built through the real builder from the synthetic
## layouts in ext_quick_slot_fixture.gd (the measured ids, rects and art
## sizes; no archive data), over the bottom bar built from underbar_fixture.gd.
##   godot4 --headless --path client --script res://scripts/ui/hud/hud_ext_quick_slot_test.gd
## docs/protocol/ext_quick_slot.md has every address the checks name.

const UNDERBAR_FIXTURE := "res://scripts/ui/hud/underbar_fixture.gd"
const FIXTURE := "res://scripts/ui/hud/ext_quick_slot_fixture.gd"
const TMP := "user://ext_quick_slot_test.cfg"

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	var watchdog := create_timer(90.0)
	watchdog.timeout.connect(func() -> void:
		print("FAIL the checks never reported (a script error stopped them)")
		quit(1))
	await process_frame
	_layout_rules()
	_footer_image()
	_settings_round_trip()
	await _bars()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP))
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

# --- ExtQuickSlotLayout: the arithmetic ---------------------------------------

func _layout_rules() -> void:
	_check(ExtQuickSlotLayout.type_index(false, false) == 0 and ExtQuickSlotLayout.type_index(false, true) == 1
		and ExtQuickSlotLayout.type_index(true, false) == 2 and ExtQuickSlotLayout.type_index(true, true) == 3,
		"type = vertical * 2 + twoLines (0x65ef70)")
	_check(ExtQuickSlotLayout.section_name(3) == "Type4" and ExtQuickSlotLayout.board_count(0) == 10
		and ExtQuickSlotLayout.board_count(3) == 5, "Type1..4 sections; 10 boards one-line, 5 two-line")
	_check(ExtQuickSlotLayout.onoff_art(0, true).ends_with("qsl_hclose_button.ddj")
		and ExtQuickSlotLayout.onoff_art(1, false).ends_with("qsl_hopen_button.ddj")
		and ExtQuickSlotLayout.onoff_art(2, true).ends_with("qsl_vclose_button.ddj")
		and ExtQuickSlotLayout.onoff_art(3, false).ends_with("qsl_vopen_button.ddj"),
		"the collapse art: open shows close, collapsed shows open (0x65ecd0)")
	_check(ExtQuickSlotLayout.alpha_for(true) == 110 and ExtQuickSlotLayout.alpha_for(false) == 255,
		"Transparent is alpha 0x6e, else 0xff (0x65f390)")
	var screen := Vector2(1024, 768)
	_check(ExtQuickSlotLayout.default_position(screen, 80) == Vector2(1024 - 80 - 26, 181),
		"the default place is (screen_w - header_w - 26, 181) (0x79c600)")
	_check(ExtQuickSlotLayout.clamp_on_show(Vector2(1000, 760), Vector2(80, 32), screen) == Vector2(944, 736),
		"a kept place past the right and bottom is pulled in (0x79a8d0)")
	_check(ExtQuickSlotLayout.clamp_on_show(Vector2(-50, -20), Vector2(80, 32), screen) == Vector2(-50, -20),
		"and nothing pulls it back from the left or the top")
	var opt := Vector2(290, 223)
	_check(ExtQuickSlotLayout.option_position(Rect2(100, 300, 80, 32), true, opt, screen) == Vector2(180, 300),
		"vertical bar in the left half: the option window to its right (0x65eb10)")
	_check(ExtQuickSlotLayout.option_position(Rect2(600, 300, 80, 32), true, opt, screen) == Vector2(310, 300),
		"vertical bar in the right half: to its left")
	_check(ExtQuickSlotLayout.option_position(Rect2(600, 100, 44, 40), false, opt, screen) == Vector2(600, 140),
		"horizontal bar in the top half: below it")
	_check(ExtQuickSlotLayout.option_position(Rect2(600, 500, 44, 40), false, opt, screen) == Vector2(600, 277),
		"horizontal bar in the bottom half: above it")
	# OURS: the pages.
	_check(ExtQuickSlotLayout.slot_for(1, 1, 0) == 51 and ExtQuickSlotLayout.slot_for(1, 2, 0) == 61
		and ExtQuickSlotLayout.slot_for(2, 1, 0) == 101 and ExtQuickSlotLayout.slot_for(4, 5, 9) == 250,
		"extra bar b, page p, key k -> 51 + ((b-1)*5 + p-1)*10 + k, up to 250")
	_check(HudUnderbar.SLOT_COUNT == 251 and ExtQuickSlotLayout.slot_for(4, 5, 9) < HudUnderbar.SLOT_COUNT,
		"the reserved range ends inside SLOT_COUNT")
	_check(ExtQuickSlotLayout.page_label(1) == "F5" and ExtQuickSlotLayout.page_label(4) == "F8",
		"page labels follow the bottom bar's F1..F4: F5..")
	var v: Dictionary = ExtQuickSlotLayout.footer_rects(true, 80, 209)
	_check(v["band"] == Rect2(0, 209, 80, 23) and v["prev"] == Rect2(2, 209, 12, 20) and v["next"] == Rect2(66, 209, 12, 20)
		and v["label"] == Rect2(14, 209, 52, 20), "the vertical footer: 23 under the slots, arrows 2 in (got %s)" % [v])
	var h: Dictionary = ExtQuickSlotLayout.footer_rects(false, 76, 209)
	_check(h["band"] == Rect2(209, 0, 23, 76) and h["prev"] == Rect2(209, 2, 20, 12) and h["next"] == Rect2(209, 62, 20, 12)
		and h["label"] == Rect2(209, 14, 20, 48), "the horizontal footer: 23 right of the slots, arrows turned (got %s)" % [h])

func _footer_image() -> void:
	var F = load(FIXTURE)
	var vimg: Image = F.header_image(Vector2i(80, 32), true)
	var out := ExtQuickSlotLayout.compose_footer(vimg, true)
	var red := func(img: Image, x: int, y: int) -> int:
		return int(round(img.get_pixel(x, y).r * 255.0))
	_check(out != null and out.get_size() == Vector2i(80, 23), "the vertical footer's backing is 80x23")
	if out != null:
		_check(red.call(out, 5, 22) == 0 and red.call(out, 5, 21) == 1, "its last two rows are the header's edge, turned outward")
		_check(red.call(out, 5, 0) == 2 and red.call(out, 5, 10) == 12 and red.call(out, 5, 11) == 2,
			"its other rows repeat the grip rows 2..12")
	var himg: Image = F.header_image(Vector2i(32, 76), false)
	var hout := ExtQuickSlotLayout.compose_footer(himg, false)
	_check(hout != null and hout.get_size() == Vector2i(23, 76), "the horizontal footer's backing is 23x76")
	if hout != null:
		_check(red.call(hout, 22, 40) == 0 and red.call(hout, 21, 40) == 1 and red.call(hout, 0, 40) == 2,
			"its columns are the header's, edge last")

# --- ExtQuickSlotSettings -----------------------------------------------------

func _settings_round_trip() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP))
	_check(ExtQuickSlotSettings.kept_options(0, TMP) == [1, 1, 1, 1, 0, 0],
		"no file: open, vertical, two lines, transparent, unlocked (0x65f580)")
	_check(ExtQuickSlotSettings.kept_position(0, TMP) == null, "no file: no kept position")
	_check(ExtQuickSlotSettings.extra_bars(TMP) == 1 and ExtQuickSlotSettings.pages(TMP) == 4,
		"no file: one extra bar of four pages (OURS)")
	ExtQuickSlotSettings.save_options(1, [0, 1, 0, 0, 1, 1], TMP)
	ExtQuickSlotSettings.save_position(1, Vector2(12.4, 345.6), TMP)
	ExtQuickSlotSettings.save_counts(3, 2, TMP)
	_check(ExtQuickSlotSettings.kept_options(1, TMP) == [0, 1, 0, 0, 1, 1] and ExtQuickSlotSettings.kept_options(0, TMP) == [1, 1, 1, 1, 0, 0],
		"a bar's six values come back; another bar's stay the defaults")
	_check(ExtQuickSlotSettings.kept_position(1, TMP) == Vector2(12, 346), "a bar's position comes back (whole pixels)")
	_check(ExtQuickSlotSettings.extra_bars(TMP) == 3 and ExtQuickSlotSettings.pages(TMP) == 2, "the counts come back")
	ExtQuickSlotSettings.save_counts(9, 0, TMP)
	_check(ExtQuickSlotSettings.extra_bars(TMP) == HudUnderbar.EXT_BARS_MAX and ExtQuickSlotSettings.pages(TMP) == 1,
		"counts are kept inside the reserved range")
	var f := ConfigFile.new()
	f.load(TMP)
	f.set_value(ExtQuickSlotSettings.SECTION, "options_2", [1, 2, 0])
	f.set_value(ExtQuickSlotSettings.SECTION, "position_2", "far away")
	f.save(TMP)
	_check(ExtQuickSlotSettings.kept_options(2, TMP) == [1, 1, 1, 1, 0, 0] and ExtQuickSlotSettings.kept_position(2, TMP) == null,
		"a damaged entry reads as none")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP))

# --- the bars -------------------------------------------------------------------

func _builder() -> UiBuilder:
	var UF = load(UNDERBAR_FIXTURE)
	var F = load(FIXTURE)
	var rows := PackedStringArray()
	for pair in UF.TEXT:
		rows.append("1\t%s\t\t\t\t\t\t\t%s" % pair)
	rows.append_array(F.text_rows())
	var b := UiBuilder.new(null, UiTextTable.parse(("\n".join(rows)).to_utf16_buffer()))
	UF.install(b)
	F.install(b)
	return b

func _local(bar: Control, node: Control) -> Rect2:
	return Rect2(node.get_global_rect().position - bar.get_global_rect().position, node.size)

## The union of every shown control of the bar, in its own coordinates.
func _extent(bar: HudExtQuickSlot) -> Rect2:
	var r := Rect2()
	var first := true
	for id in [10, 11, 12, 13, 14, 20] + range(30, 40):
		var c := bar.control(id)
		if c != null and c.visible:
			var lr := _local(bar, c)
			r = lr if first else r.merge(lr)
			first = false
	for k in 10:
		var s := bar.slot_node(bar.page, k)
		if s != null and s.visible:
			r = r.merge(_local(bar, s))
	return r

func _bars() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP))
	get_root().size = Vector2i(1152, 648)
	var builder := _builder()
	var hud := Control.new()
	hud.size = Vector2(1152, 648)
	root.add_child(hud)
	var ub := HudUnderbar.new(builder, null, builder.text_table())
	hud.add_child(ub)
	ub.position = Vector2(176, 580)
	var fired: Array = []
	ub.quickslot_activated.connect(func(i: int) -> void: fired.append(i))
	var picked: Array = []
	ub.quickslot_pick_requested.connect(func(i: int) -> void: picked.append(i))
	var mgr := HudExtQuickSlots.new()
	mgr.settings_path = TMP
	hud.add_child(mgr)
	var created: Array = []
	mgr.slots_created.connect(func(ix: Array) -> void: created.append_array(ix))
	_check(mgr.setup(builder, ub), "the bars build from the layout")
	for i in 3:
		await process_frame
	var bar0 := mgr.bar(0)
	var bar1 := mgr.bar(1)
	_check(bar0 != null and bar1 != null and mgr.bars.size() == 2, "retail's bar and one extra bar (OURS default)")
	if bar0 == null or bar1 == null:
		return

	# --- retail's bar: the defaults and the place ---
	_check(bar0.current_type == 3 and bar0.open and bar0.transparent and bar0.size == Vector2(80, 32),
		"no settings: Type4, open, transparent; the window is the WND strip's 80x32 (0x65f12e)")
	_check(bar0.position == Vector2(1152 - 80 - 26, 181), "at (screen_w - 80 - 26, 181) (got %s)" % [bar0.position])
	_check(bar1.position == bar0.position - Vector2(84, 0), "the extra bar left of it (OURS; got %s)" % [bar1.position])

	# --- the proxies are the bottom bar's 41..50 ---
	var same := true
	for k in 10:
		same = same and bar0.slot_node(1, k) == ub.slot_node(41 + k) and ub.is_lent(41 + k)
	_check(same, "retail's ten slots are the bottom bar's quick slots 41..50 (0x65fc70)")
	ub.set_page(2)
	ub.set_page(1)
	_check(bar0.slot_node(1, 0).visible and not ub.slot_node(11).visible, "the bottom bar's pages leave them alone")
	var c41 := bar0.slot_node(1, 0).get_global_rect().get_center()
	_check(ub.slot_index_at(c41) == 41, "a drop on the bar's first slot lands on quick slot 41")
	var tex := ImageTexture.create_from_image(Image.create(32, 32, false, Image.FORMAT_RGBA8))
	ub.set_slot_item(41, tex, 3)
	_check(ub.slot_icon(41) == tex and ub.slot_count(41) == 3 and bar0.slot_node(1, 0).get_node("ItemIcon").texture == tex,
		"an icon and a count set on 41 show on the bar")
	_click(bar0.slot_node(1, 0), MOUSE_BUTTON_RIGHT)
	_check(fired == [41], "a right click on it uses quick slot 41 (got %s)" % [fired])

	# --- geometry, all four types, from the built nodes ---
	var F = load(FIXTURE)
	# MEASURED from the rects: Type1's collapse button (26,1) 16x40 hangs one
	# pixel under the 40-tall strip, Type2's VERT (14,61) 16x16 one under 76.
	var extents := [Vector2(405, 41), Vector2(213, 77), Vector2(44, 401), Vector2(80, 209)]
	for t in 4:
		bar0.vertical = t >= 2
		bar0.two_lines = t == 1 or t == 3
		bar0.apply()
		var d: Dictionary = F.TYPES[t]
		var ok := bar0.current_type == t and _local(bar0, bar0.control(10)) == Rect2(d["wnd_rect"])
		ok = ok and bar0.size == Vector2((d["wnd_rect"] as Rect2i).size)
		for pair in [[11, "opt"], [12, "hori"], [13, "vert"]]:
			ok = ok and _local(bar0, bar0.control(pair[0])) == Rect2(Vector2(d[pair[1]]), Vector2(16, 16))
		var onoff_size := Vector2(40, 14) if t >= 2 else Vector2(16, 40)
		ok = ok and _local(bar0, bar0.control(14)) == Rect2(Vector2(d["onoff"]), onoff_size)
		var end_size: Vector2 = Vector2(F.ART_SIZES[d["end"]])
		ok = ok and _local(bar0, bar0.control(20)) == Rect2(Vector2(d["end_at"]), end_size)
		var board_size: Vector2 = Vector2(F.ART_SIZES[d["board"]])
		for b in int(d["boards"]):
			ok = ok and _local(bar0, bar0.control(30 + b)) == Rect2(Vector2(d["board_at"] + d["step"] * b), board_size)
		ok = ok and bar0.control(30 + int(d["boards"])) == null
		for k in 10:
			ok = ok and _local(bar0, bar0.slot_node(1, k)) == Rect2(Vector2(F.slot_at(t, k)), Vector2(32, 32))
		_check(ok, "Type%d: WND, buttons, END, boards and slots at the layout's rects" % (t + 1))
		_check(_extent(bar0).size == extents[t], "Type%d spans %s (got %s)" % [t + 1, extents[t], _extent(bar0).size])

	# --- apply(): its order and the alpha rules ---
	bar0.vertical = true
	bar0.two_lines = true
	bar0.apply()
	var n := bar0.relayouts
	bar0.transparent = false
	bar0.apply()
	_check(bar0.relayouts == n, "apply() rebuilds only when the type changes")
	_check(HudExtQuickSlot.alpha_of(bar0.control(10)) == 255 and HudExtQuickSlot.alpha_of(bar0.control(30)) == 255
		and HudExtQuickSlot.alpha_of(bar0.control(20)) == 255, "opaque: WND, END and boards at 255")
	bar0.transparent = true
	bar0.apply()
	_check(HudExtQuickSlot.alpha_of(bar0.control(10)) == 110 and HudExtQuickSlot.alpha_of(bar0.control(14)) == 110
		and HudExtQuickSlot.alpha_of(bar0.control(34)) == 110 and is_equal_approx(bar0.control(30).modulate.a, 110.0 / 255.0),
		"transparent: WND, buttons and boards at 110")
	_check(int(bar0.slot_node(1, 0).get_meta("ext_alpha", -1)) == 110 and is_equal_approx(bar0.slot_node(1, 0).modulate.a, 1.0),
		"a slot is given the alpha but its icon is not faded (the proxy draws the target)")
	# Collapse: only the header stays, the art swaps.
	var onoff := bar0.control(14) as TextureButton
	var open_art := onoff.texture_normal
	bar0.toggle_open()
	var hidden := not bar0.control(30).visible and not bar0.control(20).visible and not bar0.slot_node(1, 0).visible
	_check(not bar0.open and hidden and bar0.control(10).visible and onoff.texture_normal != open_art
		and onoff.texture_normal == builder.load_texture(ExtQuickSlotLayout.ART_VOPEN), "collapse hides slots, boards and END and swaps the art")
	# The quirk: Transparent changed while collapsed reaches only the header.
	bar0.transparent = false
	bar0.apply()
	bar0.toggle_open()
	_check(HudExtQuickSlot.alpha_of(bar0.control(10)) == 255 and HudExtQuickSlot.alpha_of(bar0.control(30)) == 110
		and HudExtQuickSlot.alpha_of(bar0.control(20)) == 110 and bar0.control(30).visible,
		"changed while collapsed: the header takes the new alpha, the boards and END keep the old one (0x65f390)")
	bar0.apply()
	_check(HudExtQuickSlot.alpha_of(bar0.control(30)) == 255, "until the next apply while open")

	# --- the locks ---
	bar0.lock_slots = true
	bar0.apply()
	_click(bar0.slot_node(1, 0), MOUSE_BUTTON_LEFT)
	_check(picked.is_empty() and bool(ub.slot_node(41).get_meta(HudUnderbar.PICK_LOCK_META, false)),
		"Lock Slots: a left click picks nothing up (0x6525b1)")
	_check(ub.slot_index_at(bar0.slot_node(1, 0).get_global_rect().get_center()) == 41,
		"and a drop still lands there (0x65fb50 has no lock test)")
	bar0.lock_slots = false
	bar0.apply()
	_click(bar0.slot_node(1, 0), MOUSE_BUTTON_LEFT)
	_check(picked == [41], "unlocked, the click picks quick slot 41 up (got %s)" % [picked])
	var start := bar0.position
	bar0.lock_toolbar = true
	bar0.apply()
	_drag(bar0.control(10), Vector2(-300, -100))
	_check(bar0.position == start, "Lock Toolbar: the header does not drag")
	var moved: Array = []
	bar0.moved.connect(func() -> void: moved.append(bar0.position))
	bar0.lock_toolbar = false
	bar0.apply()
	_drag(bar0.control(10), Vector2(-1100, -300))
	_check(bar0.position == start + Vector2(-1100, -300) and moved.size() == 1,
		"unlocked it follows the mouse with no clamp (got %s)" % [bar0.position])
	_check(ExtQuickSlotSettings.kept_position(0, TMP) == start + Vector2(-1100, -300), "and the place is kept (OURS)")
	bar0.drag_to(start)

	# --- the option window ---
	bar0.toggle_option()
	await process_frame
	var w := bar0.option_window
	_check(w != null and w.size == Vector2(290, 223), "OPT opens the 290x223 option window")
	if w != null:
		var screen := Vector2(1152, 648)
		_check(w.global_position == ExtQuickSlotLayout.option_position(Rect2(bar0.global_position, bar0.size), true, w.size, screen),
			"placed beside the header (0x65eb10; got %s)" % [w.global_position])
		var ok_btn := w.node("GDR_EXT_QUICKSLOT_OK_BTN") as Control
		_check(ok_btn != null and _local(w, ok_btn).position == Vector2(63, 185),
			"Confirm at 63,185 from its three-number rect (got %s)" % [_local(w, ok_btn) if ok_btn != null else null])
		_check(w.get_node_or_null("TitleBar") != null and (w.get_node("TitleBar") as Label).text == "tt extra slots",
			"captioned UIIT_STT_ADD_QUICKSLOT_ADD")
		_check(bar0._checked(25) == bar0.transparent and bar0._checked(28) == bar0.two_lines and not bar0._checked(26),
			"the check boxes show the state (0x65f800)")
		bar0.set_option_check(25, true)
		bar0.set_option_check(26, true)
		bar0.set_option_check(28, false)
		bar0.apply_option()
		_check(bar0.transparent and bar0.lock_slots and not bar0.two_lines and bar0.current_type == 2 and bar0.option_window == w,
			"Apply: the boxes into the state, applied, the window stays (0x65f870)")
		_check(ExtQuickSlotSettings.kept_options(0, TMP) == bar0.options(), "and the options are kept (OURS: on change)")
		bar0.set_option_check(27, true)
		w._on_close_pressed()
		_check(bar0.option_window == null and not bar0.lock_toolbar, "the X closes without applying")
		bar0.toggle_option()
		bar0.set_option_check(28, true)
		bar0.toggle_option()
		_check(bar0.option_window == null and not bar0.two_lines, "OPT again closes without applying (0x65eea0)")
		bar0.toggle_option()
		bar0.set_option_check(28, true)
		bar0.set_option_check(26, false)
		bar0.confirm_option()
		_check(bar0.option_window == null and bar0.two_lines and not bar0.lock_slots, "Confirm applies and closes (0x65f9b0)")

	# --- HORI / VERT ---
	(bar0.control(12) as BaseButton).pressed.emit()
	await process_frame
	_check(not bar0.vertical and bar0.current_type == 1, "HORI makes it horizontal (0x65f700)")
	(bar0.control(13) as BaseButton).pressed.emit()
	await process_frame
	_check(bar0.vertical and bar0.current_type == 3, "VERT makes it vertical (0x65f710)")

	# --- OURS: the extra bar's pages and footer ---
	_check(bar1.page_count == 4 and bar1.page_text() == "F5" and bar1.footer() != null, "the extra bar shows page F5 of four")
	_check(bar1.slot_node(1, 0) == ub.slot_node(51) and bar1.slot_node(2, 0) == ub.slot_node(61),
		"its pages are quick slots 51.. and 61..")
	var foot := bar1.footer()
	_check(HudExtQuickSlot.alpha_of(foot.get_node("Band")) == 110 and HudExtQuickSlot.alpha_of(foot.get_node("PageNext")) == 110
		and is_equal_approx((foot.get_node("PageLabel") as Control).modulate.a, 1.0),
		"transparent: the footer's band and arrows at 110, its label white (OURS)")
	_check(_local(bar1, foot.get_node("PagePrev")) == Rect2(2, 209, 12, 20) and _local(bar1, foot.get_node("PageNext")) == Rect2(66, 209, 12, 20)
		and _local(bar1, foot.get_node("Band")) == Rect2(0, 209, 80, 23), "the footer under the slots (Type4)")
	(foot.get_node("PageNext") as BaseButton).pressed.emit()
	_check(bar1.page == 2 and bar1.page_text() == "F6" and bar1.slot_node(2, 0).visible and not bar1.slot_node(1, 0).visible,
		"the right arrow shows page 2 and only its slots")
	_check(ub.slot_index_at(bar1.slot_node(2, 3).get_global_rect().get_center()) == 64, "a drop on page 2's fourth slot is quick slot 64")
	fired.clear()
	_check(mgr.activate_key(1) == 61 and fired == [61], "Alt+1 fires the extra bar's page slot (got %s)" % [fired])
	(foot.get_node("PagePrev") as BaseButton).pressed.emit()
	(foot.get_node("PagePrev") as BaseButton).pressed.emit()
	_check(bar1.page == 4, "the pages wrap")
	bar1.set_page(1)
	bar1.vertical = false
	bar1.apply()
	var hf := bar1.footer()
	_check(bar1.control(20) == null and _local(bar1, hf.get_node("PagePrev")) == Rect2(209, 2, 20, 12)
		and _local(bar1, hf.get_node("Band")) == Rect2(209, 0, 23, 76),
		"horizontal: the footer right of the slots, the arrows turned, no END cap")
	bar1.toggle_open()
	_check(not hf.visible and not bar1.slot_node(1, 0).visible, "collapsed, the footer goes with the boards")
	bar1.toggle_open()

	# --- OURS: the count row ---
	bar1.toggle_option()
	await process_frame
	var w1 := bar1.option_window
	_check(w1 != null and w1.size == Vector2(290, 253) and w1.panel_root.get_node_or_null("CountRow") != null,
		"the extra bar's option window has the Bars / Pages row")
	if w1 != null:
		_check(_local(w1, w1.node("GDR_EXT_QUICKSLOT_OK_BTN") as Control).position == Vector2(63, 215),
			"its buttons move down by the row")
		bar1.step_count(0, 1)
		bar1.confirm_option()
		await process_frame
		await process_frame
		_check(mgr.bars.size() == 3 and mgr.bar(2) != null and ExtQuickSlotSettings.extra_bars(TMP) == 2,
			"Confirm with Bars 2 adds a second extra bar, kept")
		created.sort()
		_check(created.size() == 40 and created[0] == 101 and created[-1] == 140,
			"its 40 slots (101..140) are announced for filling (got %d)" % created.size())
		mgr.set_counts(1, 4)
		await process_frame
		_check(mgr.bars.size() == 2 and ub.slot_node(101) == null and not ub.is_lent(101), "fewer bars give their slots back")

	# --- a new session: what was kept comes back ---
	ExtQuickSlotSettings.save_position(0, Vector2(5000, 4000), TMP)
	var opts := bar0.options()
	for b in mgr.bars.duplicate():
		mgr._remove_bar(b)
	_check(not ub.is_lent(41) and not ub.slot_node(41).visible and ub.slot_node(41).get_parent() == ub.bar_root,
		"a removed retail bar hands 41..50 back to the bottom bar, hidden")
	var mgr2 := HudExtQuickSlots.new()
	mgr2.settings_path = TMP
	hud.add_child(mgr2)
	mgr2.setup(builder, ub)
	var again := mgr2.bar(0)
	_check(again != null and again.options() == opts, "the options come back")
	_check(again != null and again.position == Vector2(1152 - again.size.x, 648 - again.size.y),
		"a kept place off the screen is pulled in on the right and bottom (got %s)" % [again.position if again else null])

func _click(node: Control, button: MouseButton) -> void:
	for pressed in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = button
		ev.pressed = pressed
		ev.global_position = node.get_global_rect().get_center()
		ev.position = node.size / 2.0
		node.gui_input.emit(ev)

func _drag(node: Control, by: Vector2) -> void:
	var from := node.get_global_rect().get_center()
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.global_position = from
	node.gui_input.emit(down)
	var mm := InputEventMouseMotion.new()
	mm.global_position = from + by
	mm.button_mask = MOUSE_BUTTON_MASK_LEFT
	node.gui_input.emit(mm)
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.global_position = from + by
	node.gui_input.emit(up)
