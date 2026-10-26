extends SceneTree

## The underbar is the client's own CNIFUnderMenuBar, built from
## `res_ui\nifundermenubar.2dt` the way its class assembles it (round 598;
## HudUnderbar's header has every address). The file is the synthetic one in
## underbar_fixture.gd -- the real file's ids, parents, rects and class names,
## no art and no text -- run through the real reader and builder:
##   godot4 --headless --path client --script res://scripts/ui/hud/hud_underbar_test.gd
##
## Every script is reached through load() and every call through call() or
## get(), so a tree that still builds the bar from resinfo\ifunderbar.txt
## FAILS here instead of failing to compile.

const BAR_PATH := "res://scripts/ui/hud/hud_underbar.gd"
const FIXTURE_PATH := "res://scripts/ui/hud/underbar_fixture.gd"

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	var watchdog := create_timer(60.0)
	watchdog.timeout.connect(func() -> void:
		print("FAIL the checks never reported (a script error stopped them)")
		quit(1))
	await process_frame
	await _run()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

## A control of the bar by its GetChild path from the bar's root, through node
## metadata, so this compiles on a tree without the builder.
func _at(from: Node, path: Array) -> Control:
	var at: Node = from
	for id in path:
		var found: Node = null
		if at != null:
			for c in at.get_children():
				if c.has_meta("twodt_id") and int(c.get_meta("twodt_id")) == int(id):
					found = c
					break
		at = found
	return at as Control

func _text(node: Node) -> String:
	var label := node.get_node_or_null("Text") as Label if node != null else null
	return label.text if label != null else "<none>"

func _local(bar: Control, node: Control) -> Vector2:
	return node.get_global_rect().position - bar.get_global_rect().position if node != null else Vector2(-1, -1)

func _gauge(node: Control) -> float:
	return (node as Range).value if node is Range else -1.0

func _press(node: Control, button: MouseButton) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = button
	ev.pressed = true
	ev.global_position = node.get_global_rect().get_center()
	node.gui_input.emit(ev)

## A press and its release on the node's centre (round 652: the bar's clicks
## act on the release).
func _click_on(node: Control, button: MouseButton) -> void:
	for pressed in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = button
		ev.pressed = pressed
		ev.global_position = node.get_global_rect().get_center()
		node.gui_input.emit(ev)

func _run() -> void:
	var Fixture = load(FIXTURE_PATH)
	var Bar = load(BAR_PATH)
	_check(Fixture != null and Bar != null, "the fixture and the bar's script load")
	if Fixture == null or Bar == null:
		return
	var builder: UiBuilder = Fixture.builder()
	# The client's default window (the headless root starts at 64x64).
	get_root().size = Vector2i(1152, 648)
	root.notification(Node.NOTIFICATION_VP_MOUSE_ENTER)
	var hud := Control.new()
	root.add_child(hud)
	var bar: Control = Bar.new(builder, null, builder.text_table())
	bar.call("setup")
	hud.add_child(bar)
	bar.position = Vector2(176, 560)
	var fired: Array = []
	bar.connect("quickslot_activated", func(idx: int) -> void: fired.append(idx))
	var actions: Array = []
	bar.connect("menu_action", func(a: String) -> void: actions.append(a))
	for i in 5:
		await process_frame

	# --- the file and the size (0x786f30 loads it and places it 800x68) ---
	var broot: Control = bar.get("bar_root") if "bar_root" in bar else null
	_check(broot != null and str(broot.get_meta("twodt_class", "")) == "CNIFUnderMenuBar",
		"the bar is nifundermenubar.2dt's CNIFUnderMenuBar (got %s)" % [broot])
	_check(bar.size == Vector2(800, 68), "the bar is the file's 800x68 (got %s)" % [bar.size])
	_check(bar.find_child("GDR_TMPQS_0", true, false) == null and bar.find_child("GDR_BTN_MENU", true, false) == null,
		"nothing of resinfo\\ifunderbar.txt is built")

	# --- the OnCreate state (0x60df30) ---
	var menu := _at(broot, [59])
	_check(menu != null and not menu.visible, "the menu 59 starts hidden")
	_check(_at(broot, [16]) != null and not _at(broot, [16]).visible, "the pet bar 16 starts hidden")
	_check(_at(broot, [103]) != null and not _at(broot, [103]).visible, "the slot arrow 103 starts hidden")
	_check(_at(broot, [59, 120]) != null and not _at(broot, [59, 120]).visible, "the stall-network item 59 -> 120 is hidden")
	_check(_at(broot, [104]) != null and _at(broot, [104]).visible, "the bar's own 104 is shown")
	_check(_text(_at(broot, [14])) == "tt exp", "14 is captioned UIO_CHARINFO_STT_EXP (got '%s')" % _text(_at(broot, [14])))
	_check(_text(_at(broot, [11])) == "tt skill points", "11 keeps its record's text id (got '%s')" % _text(_at(broot, [11])))
	for id in [10, 12, 13, 15, 17]:
		_check(not _text(_at(broot, [id])).contains("SAMPLE"),
			"%d draws no sample text (got '%s')" % [id, _text(_at(broot, [id]))])

	# --- quick slots: 0 the "m" slot, 1..10 the authored ten, 11..50 made ---
	var slot_node := func(i: int) -> Control:
		return bar.call("slot_node", i) if bar.has_method("slot_node") else null
	var m: Control = slot_node.call(0)
	_check(m != null and m == _at(broot, [50]) and m.is_visible_in_tree(), "quick slot 0 is the \"m\" slot 50, shown")
	var authored_ok := true
	for k in 10:
		var s: Control = slot_node.call(k + 1)
		authored_ok = authored_ok and s != null and s == _at(broot, [40 + k]) and s.is_visible_in_tree()
	_check(authored_ok, "quick slots 1..10 are 40..49, shown on page F1")
	var made_ok := true
	for i in range(11, 51):
		var s: Control = slot_node.call(i)
		var model: Control = slot_node.call((i - 1) % 10 + 1)
		made_ok = made_ok and s != null and model != null and not s.is_visible_in_tree() \
			and int(s.get_meta("twodt_id", 0)) == i + 999 and s.position == model.position and s.size == Vector2(32, 32)
	_check(made_ok, "quick slots 11..50 are made (ids 1010..1049) at slots 1..10's places, hidden")
	_check(_text(_at(broot, [57])) == "F1", "the page label reads F1 (got '%s')" % _text(_at(broot, [57])))
	var s1: Control = slot_node.call(1)
	_check(s1 != null and _local(bar, s1) == Vector2(261, 18), "slot 1 sits at 368-107, 456-438 (got %s)" % [_local(bar, s1)])

	# --- pages: 19 up, 18 down, wrapping 0..3 (0x60a730) ---
	var up := _at(broot, [19]) as BaseButton
	var down := _at(broot, [18]) as BaseButton
	if up != null:
		up.pressed.emit()
	var s11: Control = slot_node.call(11)
	_check(_text(_at(broot, [57])) == "F2" and s11 != null and s11.is_visible_in_tree() and not s1.is_visible_in_tree(),
		"19 turns to F2: quick slots 11..20 shown, 1..10 hidden (label '%s')" % _text(_at(broot, [57])))
	if down != null:
		down.pressed.emit()
		down.pressed.emit()
	_check(_text(_at(broot, [57])) == "F4" and bar.call("current_page") == 4,
		"18 twice from F2 wraps to F4 (label '%s')" % _text(_at(broot, [57])))
	_check(bar.call("slot_for_key", 0) == 31 and bar.call("slot_for_key", 9) == 40,
		"on F4 the keys 1..0 are quick slots 31..40 (got %s, %s)" % [bar.call("slot_for_key", 0), bar.call("slot_for_key", 9)])
	bar.call("set_page", 1)
	_check(bar.call("slot_for_key", 0) == 1 and bar.call("slot_for_key", 9) == 10,
		"F1 again: key 1 is quick slot 1, key 0 is 10 (got %s, %s)" % [bar.call("slot_for_key", 0), bar.call("slot_for_key", 9)])
	fired.clear()
	bar.call("activate_key", 2)
	_check(fired == [3], "key 3 fires quick slot 3 (got %s)" % [fired])
	# Round 826: the selection frame (0x60a820) on page slot 2, 4 left and 3 up of it.
	var arrow := _at(broot, [103])
	var slot3 := _at(broot, [42])
	_check(arrow != null and arrow.visible and slot3 != null and arrow.position == slot3.position + Vector2(-4, -3)
		and int(bar.call("slot_frame")) == 2, "key 3 shows the frame 103 on page slot 3, at (x - 4, y - 3)")
	_check(arrow != null and arrow.mouse_filter == Control.MOUSE_FILTER_IGNORE, "the frame takes no clicks")
	# Round 827: it fades from 255 to 0 over 4 s (0x46ca80(255, 0, 4.0, 0.0, 0), 0x470780).
	_check(int(bar.call("slot_frame_alpha")) == 255 and is_equal_approx(arrow.modulate.a, 1.0),
		"the frame starts at alpha 255")
	bar.call("step_slot_frame", 1.0)
	_check(int(bar.call("slot_frame_alpha")) == 191, "1 s in: trunc(255 x 0.75) = 191 (got %s)" % bar.call("slot_frame_alpha"))
	bar.call("step_slot_frame", 1.5)
	_check(int(bar.call("slot_frame_alpha")) == 95, "2.5 s in: trunc(255 x 0.375) = 95 (got %s)" % bar.call("slot_frame_alpha"))
	bar.call("activate_key", 2)
	_check(int(bar.call("slot_frame_alpha")) == 255, "a new use starts it over at 255")
	bar.call("step_slot_frame", 3.9)
	_check(int(bar.call("slot_frame_alpha")) == 6, "3.9 s in: trunc(255 x 0.025) = 6 (got %s)" % bar.call("slot_frame_alpha"))
	bar.call("step_slot_frame", 0.2)
	_check(int(bar.call("slot_frame_alpha")) == 0 and arrow.visible and is_equal_approx(arrow.modulate.a, 0.0),
		"past 4 s it is 0 and still shown (+0x18c 0: no hide)")
	bar.call("step_slot_frame", 1.0)
	_check(int(bar.call("slot_frame_alpha")) == 0, "the stopped fade stays at 0")
	bar.call("set_page", 2)
	bar.call("activate_key", 4)
	_check(int(bar.call("slot_frame")) == 4 and arrow.position == _at(broot, [44]).position + Vector2(-4, -3),
		"on F2 a key moves it to the same page position (slot 5)")
	bar.call("activate_slot", 45)
	bar.call("activate_mouse_slot")
	_check(int(bar.call("slot_frame")) == 4 and arrow.visible, "slots 11..50 and the m slot leave it where it was")
	bar.call("set_page", 1)
	_check(arrow.visible and int(bar.call("slot_frame")) == 4, "a page flip leaves it too")
	fired.clear()

	# --- the mouse: RIGHT fires the slot (round 652: CIFSlotWithHelp's
	# right-button-up, vslot 33 -> 0x682040 case 0x0c), LEFT picks it up,
	# middle fires the "m" slot ---
	fired.clear()
	if s1 != null:
		_click_on(s1, MOUSE_BUTTON_RIGHT)
	_check(fired == [1], "a right click on slot 1 fires quick slot 1 (got %s)" % [fired])
	_check(int(bar.call("slot_frame")) == 0, "... and moves the frame to it (round 826)")
	fired.clear()
	var picks: Array = []
	if bar.has_signal("quickslot_pick_requested"):
		bar.connect("quickslot_pick_requested", func(idx: int) -> void: picks.append(idx))
	if s1 != null:
		_click_on(s1, MOUSE_BUTTON_LEFT)
	_check(fired.is_empty(), "a left click on slot 1 fires nothing (got %s)" % [fired])
	_check(picks.is_empty(), "a left click on an EMPTY slot picks nothing up (got %s)" % [picks])
	if s1 != null and bar.has_method("set_slot_item"):
		var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
		bar.call("set_slot_item", 1, ImageTexture.create_from_image(img))
		_click_on(s1, MOUSE_BUTTON_LEFT)
		bar.call("clear_slot", 1)
	_check(picks == [1], "a left click on a filled slot asks to pick it up (got %s)" % [picks])
	fired.clear()
	if s1 != null:
		_press(s1, MOUSE_BUTTON_MIDDLE)
	_check(fired == [0], "a middle press fires the \"m\" slot, quick slot 0 (got %s)" % [fired])
	fired.clear()
	if bar.has_method("activate_mouse_slot"):
		bar.call("activate_mouse_slot")
	_check(fired == [0], "activate_mouse_slot fires quick slot 0 (got %s)" % [fired])
	_check(bar.call("slot_index_at", s1.get_global_rect().get_center()) == 1 if s1 != null else false,
		"slot_index_at finds quick slot 1 under its centre")
	_check(bar.call("slot_index_at", m.get_global_rect().get_center()) == 0 if m != null else false,
		"slot_index_at finds the \"m\" slot under its centre")
	_check(bar.call("slot_index_at", Vector2(-1000, -1000)) == -1, "no slot under a point outside the bar")
	bar.call("set_slot_item", 1, ImageTexture.create_from_image(Image.create(4, 4, false, Image.FORMAT_RGBA8)), 3)
	var count := s1.get_node_or_null("CountLabel") as Label if s1 != null else null
	_check(bar.call("slot_has_item", 1) and count != null and count.text == "3",
		"an item on slot 1 shows its icon and count")
	bar.call("clear_slot", 1)

	# --- round 786: the labels on every page ---
	# The key numbers are the bar's own statics 92..101 (ub_number_1.._0),
	# after the slots in its child list, so they draw over whatever a slot
	# holds; the slots 11..50 the OnCreate makes are sent to the FRONT of the
	# list (0xb90c30 -> CGWndBase::vslot_012 0xb92070's mode 2, READ), so on
	# F2..F4 too. 0xba0300 draws the list first to last (READ).
	var under_ok := true
	var under_bad := []
	for page in range(1, 5):
		for k in 10:
			var s: Control = slot_node.call((page - 1) * 10 + k + 1)
			var num := _at(broot, [92 + k])
			if s == null or num == null or s.get_parent() != num.get_parent() or s.get_index() >= num.get_index():
				under_ok = false
				under_bad.append([page, k + 1])
	_check(under_ok, "every page's slots draw under the key numbers 92..101 (bad: %s)" % [under_bad])
	_check(_at(broot, [96]) != null and _at(broot, [96]).visible and _at(broot, [96]).mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"the key number 96 ('5') is shown and takes no clicks")
	# The count is the original's digit images (ItemCountLabel), unclipped.
	var c23: Control = slot_node.call(23)
	var lbl23 = c23.get_node_or_null("CountLabel") if c23 != null else null
	_check(lbl23 is ItemCountLabel and not c23.clip_contents,
		"a bar slot's count is an ItemCountLabel on an unclipped slot (got %s, clip %s)" % [lbl23, c23.clip_contents if c23 else null])
	# The counts come from the bag slot each item slot is bound to, live
	# (0x6871d0 keeps the bag's own SOItem at +0x390; 0x685e50 draws its
	# +0x9c when 0x680da0 holds: kind 0x0c/0x46, an expendable, non-zero).
	var potion_tex := ImageTexture.create_from_image(Image.create(4, 4, false, Image.FORMAT_RGBA8))
	var quick_items := {1: {"item": 501, "slot": 13}, 23: {"item": 501, "slot": 13},
		38: {"item": 502, "slot": 14}, 5: {"item": 503, "slot": 15}, 31: {"item": 504, "slot": 16}}
	for qs in quick_items:
		bar.call("set_slot_item", qs, potion_tex)
	bar.call("set_slot_item", 2, potion_tex) # a skill: no count
	var bag_slots := [{"slot_index": 13, "item_id": 501, "quantity": 7}, {"slot_index": 14, "item_id": 502, "quantity": 1},
		{"slot_index": 15, "item_id": 503, "quantity": 4}]
	var shows := func(item_id: int, qty: int) -> bool: return item_id != 503 and qty >= 1
	var counts: Dictionary = bar.call("item_counts", quick_items, bag_slots, shows) if bar.has_method("item_counts") else {}
	_check(counts == {1: 7, 23: 7, 38: 1, 5: 0, 31: 0},
		"item_counts: each item slot its bag stack, a 1 too, none for a non-expendable or a missing slot (got %s)" % [counts])
	# The rule HudPanels.bar_shows_count applies (READ 0x680da0 and the
	# SetItem's max-stack flag 0x6875cd): a stackable expendable, a 1 too.
	var on_bar := func(t: Array, bionic: bool, max_stack: int, qty: int) -> bool:
		return ItemCountLabel.shows_on_bar(t, bionic, max_stack, qty)
	_check(on_bar.call([3, 3, 1, 1], false, 50, 1) and on_bar.call([3, 3, 3, 1], false, 10, 7)
		and not on_bar.call([3, 3, 1, 1], false, 1, 1) and not on_bar.call([3, 3, 1, 1], true, 50, 5)
		and not on_bar.call([1, 6, 1, 1], false, 1, 1) and not on_bar.call([3, 3, 1, 1], false, 50, 0),
		"the bar's rule: a stackable 3/3 non-bionic item with a count, 1 included; not max stack 1, bionic, gear or 0")
	if bar.has_method("apply_item_counts"):
		bar.call("apply_item_counts", quick_items, bag_slots, shows)
	var count_on := func(qs: int) -> String:
		var n: Control = slot_node.call(qs)
		var l := n.get_node_or_null("CountLabel") as Label if n != null else null
		return l.text if l != null else "<none>"
	var shown_counts := []
	for page in [3, 4, 1]:
		bar.call("set_page", page)
		for qs in [1, 2, 5, 23, 38]:
			var n: Control = slot_node.call(qs)
			if n != null and n.is_visible_in_tree():
				shown_counts.append([page, qs, count_on.call(qs)])
	_check(shown_counts == [[3, 23, "7"], [4, 38, "1"], [1, 1, "7"], [1, 2, ""], [1, 5, ""]],
		"after F3, F4 and F1 each shown slot draws its count (got %s)" % [shown_counts])
	bag_slots[0]["quantity"] = 6
	bar.call("set_page", 3)
	if bar.has_method("apply_item_counts"):
		bar.call("apply_item_counts", quick_items, bag_slots, shows)
	_check(count_on.call(23) == "6" and count_on.call(1) == "6",
		"a use takes both slots bound to the stack to 6, the shown F3 one and the hidden F1 one (got %s, %s)" % [count_on.call(23), count_on.call(1)])
	bar.call("set_slot_item", 2, potion_tex, 9)
	if bar.has_method("apply_item_counts"):
		bar.call("apply_item_counts", quick_items, bag_slots, shows)
	_check(count_on.call(2) == "", "a slot no item is bound to loses a stale count (got '%s')" % count_on.call(2))
	bar.call("clear_slot", 23)
	_check(count_on.call(23) == "", "an emptied slot draws no count (got '%s')" % count_on.call(23))
	# The count draws after the re-use display (0x685e50: 0x67cfb0, then the
	# count 0x67bd70), so a cooling potion still shows its stack.
	bar.call("set_slot_cooldown", 1, 3, -1)
	var n1: Control = slot_node.call(1)
	var over := n1.get_node_or_null("Delay") if n1 != null else null
	var cl := n1.get_node_or_null("CountLabel") if n1 != null else null
	_check(over != null and cl != null and over.get_index() < cl.get_index(),
		"the re-use display sits under the count (indices %s, %s)" % [over.get_index() if over else -1, cl.get_index() if cl else -1])
	# Round 786: ONE cell over the whole icon. The sheets at their MEASURED
	# sizes (skill_delay.ddj 256 x 256, skill_charge.ddj 64 x 64; synthetic
	# here) through the builder's own texture cache; 0x67cfb0 cuts 1/16 (1/4)
	# of the sheet, so a 16-pixel cell. Round 785 cut 32 pixels -- 2 x 2 cells,
	# four small sweeps in the slot.
	var delay_img := Image.create(256, 256, false, Image.FORMAT_RGBA8)
	var charge_img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	builder._texture_cache["interface\\skill\\skill_delay.ddj"] = ImageTexture.create_from_image(delay_img)
	builder._texture_cache["interface\\skill\\skill_charge.ddj"] = ImageTexture.create_from_image(charge_img)
	bar.call("set_slot_cooldown", 1, 17, -1)
	var dov: TextureRect = n1.get_node_or_null("Delay") as TextureRect if n1 != null else null
	var dat: AtlasTexture = dov.texture as AtlasTexture if dov != null else null
	_check(dov != null and dov.visible and dat != null and dat.region == Rect2(16, 16, 16, 16),
		"delay frame 17 is one 16-pixel cell of the 256 sheet, column 1 row 1 (got %s)" % (str(dat.region) if dat != null else "none"))
	_check(dov != null and dov.get_global_rect() == (slot_node.call(1) as Control).get_global_rect(),
		"the sweep covers the whole slot (got %s against %s)" % [str(dov.get_global_rect()) if dov else "none",
		(slot_node.call(1) as Control).get_global_rect()])
	_check(bar.call("slot_cooldown_cell", 1) == ["delay", 17], "slot_cooldown_cell reads delay 17 (got %s)" % [bar.call("slot_cooldown_cell", 1)])
	bar.call("set_slot_cooldown", 1, 0, -1)
	_check(dat != null and dat.region == Rect2(0, 0, 16, 16), "frame 0 (r = 1): the top-left cell alone (got %s)" % (str(dat.region) if dat != null else "none"))
	bar.call("set_slot_cooldown", 1, -1, 6)
	var cat: AtlasTexture = dov.texture as AtlasTexture if dov != null else null
	_check(cat != null and cat.region == Rect2(32, 16, 16, 16) and bar.call("slot_cooldown_cell", 1) == ["charge", 6],
		"charge frame 6 is one 16-pixel cell of the 64 sheet, column 2 row 1 (got %s)" % (str(cat.region) if cat != null else "none"))
	builder._texture_cache.erase("interface\\skill\\skill_delay.ddj")
	builder._texture_cache.erase("interface\\skill\\skill_charge.ddj")
	for qs in quick_items:
		bar.call("clear_slot", qs)
	bar.call("clear_slot", 2)
	bar.call("set_slot_cooldown", 1, -1, -1)
	bar.call("set_page", 1)

	# --- the readouts (vslot 12, 0x60b440) ---
	bar.call("set_exp", 23.456)
	var tenth: Array = []
	for id in range(20, 30):
		tenth.append(snappedf(_gauge(_at(broot, [id])), 0.01))
	_check(_text(_at(broot, [15])) == "23.46 %", "15 is %%.2f %% of the percent (got '%s')" % _text(_at(broot, [15])))
	_check(_text(_at(broot, [10])) == "2", "10 is the whole tens (got '%s')" % _text(_at(broot, [10])))
	_check(_text(_at(broot, [17])) == "34%", "17 is the progress through the tenth, x = 3.461 -> 34%% (got '%s')" % _text(_at(broot, [17])))
	_check(tenth == [100.0, 100.0, 100.0, 46.1, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
		"the ten gauges: three full, the fourth 46.1, the rest empty (got %s)" % [tenth])
	bar.call("set_exp", 100.0)
	_check(_text(_at(broot, [15])) == "99.99 %" and _text(_at(broot, [10])) == "9" and _text(_at(broot, [17])) == "99%"
		and snappedf(_gauge(_at(broot, [29])), 0.01) == 99.5 and _gauge(_at(broot, [28])) == 100.0,
		"100%% is capped at 99.99: 9 tens, the last gauge 99.5 (got '%s' '%s' '%s' %s)" % [
			_text(_at(broot, [15])), _text(_at(broot, [10])), _text(_at(broot, [17])), _gauge(_at(broot, [29]))])
	if bar.has_method("set_level"):
		bar.call("set_level", 7)
	_check(_text(_at(broot, [13])) == "tt lv. 7", "13 is %%s. %%d of UIIT_STT_LEVEL_LV and the level (got '%s')" % _text(_at(broot, [13])))
	bar.call("set_sp", 500)
	_check(_text(_at(broot, [12])) == "500" and _gauge(_at(broot, [5])) == 0.0,
		"12 shows the SP total and the SP gauge 5 stays empty with no progress (got '%s', %s)" % [_text(_at(broot, [12])), _gauge(_at(broot, [5]))])
	bar.call("set_sp", 500, 42.0)
	_check(_gauge(_at(broot, [5])) == 42.0, "given progress, the SP gauge fills to it (got %s)" % _gauge(_at(broot, [5])))

	# --- the menu (0x60a700, 0x60cd10, 0x60d5f0, 0x60afe0) ---
	var menu_btn := _at(broot, [4]) as BaseButton
	if menu_btn != null:
		menu_btn.pressed.emit()
	_check(menu != null and menu.visible, "the menu button 4 shows the menu")
	_check(_text(_at(broot, [59, 83, 200])) == "tt party P",
		"83's caption is CONTENTS_MENU_PARTY with this client's key (got '%s')" % _text(_at(broot, [59, 83, 200])))
	_check(_text(_at(broot, [59, 108, 200])) == "tt community U",
		"108's caption names the guild's key, as the client's does (got '%s')" % _text(_at(broot, [59, 108, 200])))
	_check(_text(_at(broot, [59, 102, 200])) == "tt camp match",
		"102 keeps its record's caption (got '%s')" % _text(_at(broot, [59, 102, 200])))
	var b6 := _at(broot, [6])
	var b9 := _at(broot, [9])
	_check(b6 != null and b6.tooltip_text == "tt character C" and b9 != null and b9.tooltip_text == "tt mall",
		"6 and 9 carry their hover strings (got '%s', '%s')" % [b6.tooltip_text if b6 else "", b9.tooltip_text if b9 else ""])
	# The fit: the widest caption's overrun past its 82-wide static, plus 10,
	# widens the menu; the menu's right edge is the bar's.
	var overrun := 0
	var font := ThemeDB.fallback_font
	for id in [83, 93, 96, 99, 102, 105, 108, 111, 114, 104, 117, 120, 123, 126]:
		var cap := _at(broot, [59, id, 200])
		var t := _text(cap)
		if cap != null and t != "<none>":
			var w := int(ceil(font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x))
			overrun = maxi(overrun, w - 82)
	var want_w := 138 + (10 + overrun if overrun > 0 else 0)
	_check(menu != null and menu.size.x == want_w and _local(bar, menu) == Vector2(800 - want_w, 44 - 438),
		"the menu is %d wide (138 + 10 + overrun %d) and right-aligned to the bar (got %s at %s)" % [
			want_w, overrun, menu.size if menu else Vector2(), _local(bar, menu)])
	var item83 := _at(broot, [59, 83])
	_check(item83 != null and item83.size.x == 97 + (want_w - 138), "the items widen with it (got %s)" % [item83.size if item83 else Vector2()])
	for pair in [[96, "guild"], [108, "community"], [126, "system"], [83, "party"], [114, "alchemy"]]:
		actions.clear()
		if menu != null:
			menu.visible = true
		var item := _at(broot, [59, pair[0]]) as BaseButton
		if item != null:
			item.pressed.emit()
		_check(menu != null and actions == [pair[1]] and not menu.visible,
			"item %d opens %s and closes the menu (got %s)" % [pair[0], pair[1], actions])
	for id in [102, 104, 117]:
		actions.clear()
		var item := _at(broot, [59, id]) as BaseButton
		if item != null:
			item.pressed.emit()
		_check(actions.is_empty(), "item %d names no window here and emits nothing (got %s)" % [id, actions])
	for pair in [[6, "character"], [7, "inventory"], [8, "skill"]]:
		actions.clear()
		var b := _at(broot, [pair[0]]) as BaseButton
		if b != null:
			b.pressed.emit()
		_check(actions == [pair[1]], "button %d opens %s (got %s)" % [pair[0], pair[1], actions])

	# --- the menu closes when the player clicks elsewhere (CGInterface::
	# vslot_017 0x77c260 -> 0x60a610 on 0x201 and 0x204), and on Escape
	# (this project's choice) ---
	var recorder_script := GDScript.new()
	recorder_script.source_code = "extends Node\nvar keys := 0\nfunc _unhandled_key_input(_e: InputEvent) -> void:\n\tkeys += 1\n"
	recorder_script.reload()
	var recorder := Node.new()
	recorder.set_script(recorder_script)
	root.add_child(recorder)
	var press := func(at: Vector2, button: MouseButton) -> void:
		for is_down in [true, false]:
			var ev := InputEventMouseButton.new()
			ev.button_index = button
			ev.pressed = is_down
			ev.position = at
			ev.global_position = at
			root.push_input(ev, true)
	var open_menu := func() -> void:
		if bar.has_method("show_menu"):
			bar.call("show_menu")
		elif menu != null:
			menu.visible = true
	open_menu.call()
	press.call(Vector2(600, 100), MOUSE_BUTTON_LEFT)
	_check(menu != null and not menu.visible, "a left click in the world closes the menu (0x201 -> 0x60a610)")
	open_menu.call()
	press.call(Vector2(600, 100), MOUSE_BUTTON_RIGHT)
	_check(menu != null and not menu.visible, "a right click in the world closes the menu (0x204 -> 0x60a610)")
	open_menu.call()
	press.call(menu.get_global_rect().position + Vector2(5, 5) if menu else Vector2.ZERO, MOUSE_BUTTON_LEFT)
	_check(menu != null and menu.visible, "a click on the open menu itself leaves it open")
	press.call(_at(broot, [4]).get_global_rect().get_center() if _at(broot, [4]) else Vector2.ZERO, MOUSE_BUTTON_LEFT)
	_check(menu != null and not menu.visible, "a click on the menu button with the menu open closes it (once)")
	open_menu.call()
	recorder.set("keys", 0)
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.pressed = true
	root.push_input(esc, true)
	_check(menu != null and not menu.visible and int(recorder.get("keys")) == 0,
		"Escape closes the menu and goes no further (keys past it: %s)" % recorder.get("keys"))
	root.push_input(esc, true)
	_check(int(recorder.get("keys")) == 1, "with the menu closed, Escape reaches the rest of the HUD again")
	recorder.queue_free()
	# Ours: the open menu is kept inside the view (a UI scale of 1.5 put its
	# top above the screen).
	bar.position = Vector2(176, 300)
	open_menu.call()
	await process_frame
	var view := root.get_visible_rect()
	_check(menu != null and menu.get_global_rect().position.y >= view.position.y - 0.5
		and menu.get_global_rect().end.y <= view.end.y + 0.5,
		"the open menu stays inside the view (top %s)" % [menu.get_global_rect().position.y if menu else -1])
	if bar.has_method("hide_menu"):
		bar.call("hide_menu")
	_check(menu != null and _local(bar, menu).y == 44 - 438, "closed, it is back at its place (got %s)" % [_local(bar, menu)])
	bar.position = Vector2(176, 560)

	# --- labels: centred and right-aligned text overrun its 4-pixel row the
	# way the alignment says (the builder's grow direction) ---
	await process_frame
	var lbl12 := _at(broot, [12]).get_node_or_null("Text") as Label if _at(broot, [12]) else null
	_check(lbl12 != null and is_equal_approx(lbl12.get_global_rect().end.x, _at(broot, [12]).get_global_rect().end.x)
		and is_equal_approx(lbl12.get_global_rect().get_center().y, _at(broot, [12]).get_global_rect().get_center().y),
		"12's right-aligned SP number keeps its right edge and is centred on its row")

	# --- built once ---
	var copies := broot.find_children("Wnd40", "", true, false).size() if broot else 0
	bar.call("setup")
	_check(broot != null and broot.find_children("Wnd40", "", true, false).size() == copies and copies == 1,
		"a second setup() builds nothing more")

	# --- no file: an empty bar that takes no clicks ---
	var bare: Control = Bar.new(UiBuilder.new(null, null), null, null)
	bare.call("setup")
	_check(bare.mouse_filter == Control.MOUSE_FILTER_IGNORE and bar.mouse_filter == Control.MOUSE_FILTER_STOP,
		"without nifundermenubar.2dt the empty bar lets clicks through (filter %d; built bar %d)" % [bare.mouse_filter, bar.mouse_filter])
	bare.free()

	# --- item bindings (unchanged) ---
	var bag := {3: 4001, 7: 4002, 9: 4001}
	_check(bar.call("resolve_item_binding", 4001, 3, bag) == 3, "an unmoved item keeps its bag slot")
	_check(bar.call("resolve_item_binding", 4002, 3, bag) == 7, "a moved item is found in its new slot")
	_check(bar.call("resolve_item_binding", 4003, 3, bag) == -1, "a spent item has no binding")
	_check(bar.call("resolve_item_binding", 4001, 9, bag) == 9, "with two stacks, the bound slot is preferred")
	hud.free()
