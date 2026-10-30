extends RefCounted
class_name StallWindowView

## Round 839 (lane S): what HudPanels' "stall" window adds to its built
## layout and how it is drawn from a StallController. READ unless marked;
## StallController's header has the addresses.
##
## Built once per window (wire): the "Items to sell" tab; ten CIFStallSlots
## from `resinfo\ifstallslot.txt` in GDR_STALL_DISPLAY; the chat module from
## `resinfo\ifchatmodule.txt` in GDR_STALL_CHAT; the buttons wired.
## Drawn on every change (draw): the title, greeting, state icon and text,
## the state button's caption, the buttons' states, the slots, the user list.
##
## OURS, disclosed: the chat module's text boxes (CIFTextBox) are drawn as a
## RichTextLabel / Label in their authored rects with the module's white
## font; the slot names' red (c:0x8bd0e0's test, OPEN) is not drawn.

const SLOT_NAME := "StallSlot%d"

## The window's controls built in (once).
static func wire(panels, window: HudWindow, controller: StallController) -> void:
	if window.has_meta("stall_wired"):
		return
	window.set_meta("stall_wired", true)
	window.close_hides = false
	window.closed.connect(func() -> void: controller.press_close())
	var builder: UiBuilder = panels._builder
	var buttons := {"GDR_BTN_TRADINGSTATE": controller.press_state, "GDR_BTN_CHANGETITLE": controller.press_title,
		"GDR_BTN_OWNERMSG": controller.press_greeting}
	for n in buttons:
		var b := window.node(n) as BaseButton
		if b != null:
			b.pressed.connect(buttons[n])
	_add_tab(window, builder)
	_add_slots(panels, window, builder, controller)
	_add_chat(window, builder, controller)

## The one tab (c:0x6bb9c9..0x6bbb72): class 0xee96c0, ID 50, at (28, 86)
## 80x24, `com_long_tab_on.ddj` (MEASURED 72x24), UIIT_STT_SELL_GOODS, checked.
static func _add_tab(window: HudWindow, builder: UiBuilder) -> void:
	var host := window.node("GDR_STALL_INTERNAL_FRAME") as Control
	var parent: Control = host.get_parent() as Control if host != null else window
	var tab := TextureRect.new()
	tab.name = "StallTabSell"
	tab.position = StallController.TAB_RECT.position
	tab.size = StallController.TAB_RECT.size
	tab.texture = builder.load_texture(StallController.TAB_ON) if builder != null else null
	tab.stretch_mode = TextureRect.STRETCH_KEEP
	tab.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l := Label.new()
	l.name = "Caption"
	l.text = builder.resolve_text("UIIT_STT_SELL_GOODS") if builder != null else "Items to sell"
	if l.text == "" or l.text == "UIIT_STT_SELL_GOODS":
		l.text = "Items to sell"
	l.size = Vector2(72, 24)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_font(l, builder, "font")
	tab.add_child(l)
	parent.add_child(tab)

## Ten slots, 2 x 5, at the manager's (6 + 206 c, 6 + 41 r).
static func _add_slots(panels, window: HudWindow, builder: UiBuilder, controller: StallController) -> void:
	var display := window.node("GDR_STALL_DISPLAY") as Control
	if display == null or builder == null:
		return
	var layout := builder.load_layout(StallController.SLOT_LAYOUT)
	for i in StallNet.SLOTS:
		var slot := Control.new()
		slot.name = SLOT_NAME % i
		slot.position = StallController.SLOT_ORIGIN + Vector2(StallController.SLOT_PITCH.x * (i % 2), StallController.SLOT_PITCH.y * (i / 2))
		slot.size = StallController.SLOT_SIZE
		slot.mouse_filter = Control.MOUSE_FILTER_PASS
		var art := TextureRect.new()
		art.name = "SlotArt"
		art.size = StallController.SLOT_SIZE
		art.stretch_mode = TextureRect.STRETCH_KEEP
		art.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(art)
		if layout != null:
			var root := builder.build_section(layout, "Create")
			if root != null:
				root.name = "Body"
				root.mouse_filter = Control.MOUSE_FILTER_PASS
				slot.add_child(root)
				UiBuilder.settle_authored_rects(root)
				var modify := root.get_node_or_null("GDR_STALLSLOT_MODIFY") as BaseButton
				if modify != null:
					var index: int = i
					modify.pressed.connect(func() -> void: controller.press_modify(index))
					modify.tooltip_text = builder.resolve_text("UIIT_STT_TOGGLE_STORE_PRICE_CHANGE")
				var icon_holder := root.get_node_or_null("GDR_STALLSLOT_ICON") as Control
				var icon := icon_holder.get_node_or_null("ItemIcon") as TextureRect if icon_holder != null else null
				if icon != null:
					var index2: int = i
					icon.gui_input.connect(func(ev: InputEvent) -> void: panels._on_stall_cell_input(ev, icon, index2))
		display.add_child(slot)

## The chat module (its own layout at GDR_STALL_CHAT's origin).
static func _add_chat(window: HudWindow, builder: UiBuilder, controller: StallController) -> void:
	var host := window.node("GDR_STALL_CHAT") as Control
	if host == null or builder == null:
		return
	var layout := builder.load_layout(StallController.CHAT_LAYOUT)
	if layout == null:
		return
	var root := builder.build_section(layout, "Create")
	if root == null:
		return
	root.name = "ChatModule"
	root.mouse_filter = Control.MOUSE_FILTER_PASS
	host.add_child(root)
	UiBuilder.settle_authored_rects(root)
	var msgs := root.get_node_or_null("GDR_CHAT_CHATMESSAGE") as Control
	if msgs != null:
		var rt := RichTextLabel.new()
		rt.name = "Lines"
		rt.size = msgs.size
		rt.scroll_following = true
		rt.bbcode_enabled = false
		rt.mouse_filter = Control.MOUSE_FILTER_PASS
		_font(rt, builder, "normal_font")
		msgs.add_child(rt)
	var users := root.get_node_or_null("GDR_CHAT_OTHERUSER") as Control
	if users != null:
		var l := Label.new()
		l.name = "Users"
		l.size = users.size
		l.clip_text = true
		_font(l, builder, "font")
		users.add_child(l)
	var input := root.get_node_or_null("GDR_CHAT_INPUTBOX") as LineEdit
	if input != null:
		input.text_submitted.connect(func(t: String) -> void:
			controller.send_chat(t)
			input.text = "")

## Font 0 (the module's and the tab's FontIndex) on a label or text box.
static func _font(c: Control, builder: UiBuilder, key: String) -> void:
	if builder == null:
		return
	var f := builder.font_at(0)
	if f != null:
		c.add_theme_font_override(key, f)
	c.add_theme_font_size_override(key + "_size", UiBuilder.FONT_SIZES[0])

## The window drawn from the controller's state.
static func draw(panels, window: HudWindow, c: StallController) -> void:
	if window == null:
		return
	var builder: UiBuilder = panels._builder
	var set_text := func(n: String, t: String) -> void:
		var node := window.node(n) as Control
		if node != null and builder != null:
			builder.set_static_text(node, t)
	set_text.call("GDR_STALL_STALLTITLE", StallNet.plate_title(c.title) if c.title != "" else "")
	set_text.call("GDR_STALL_GREETING", c.greeting)
	set_text.call("GDR_STALL_OWNERSTATE_MSG", c._text("UIIT_STT_TRADING_NOW" if c.open else "UIIT_STT_STALL_MODIFYING",
		"Open!" if c.open else "Closed!"))
	var icon := window.node("GDR_STALL_OWNERSTATE_ICON") as Control
	if icon != null and builder != null:
		var tex := builder.load_texture(StallController.ICON_OPEN if c.open else StallController.ICON_MODIFY)
		var tr := icon.get_node_or_null("StateIcon") as TextureRect
		if tr == null:
			tr = TextureRect.new()
			tr.name = "StateIcon"
			tr.size = Vector2(20, 20)
			tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
			icon.add_child(tr)
		tr.texture = tex
	var state := window.node("GDR_BTN_TRADINGSTATE") as BaseButton
	if state != null:
		if builder != null:
			builder.set_button_text(state, c._text("UIIT_STT_END_STALL" if c.open else "UIIT_STT_START_STALL",
				"Modify Stall" if c.open else "Open Stall"))
		state.disabled = not c.own
	var title_btn := window.node("GDR_BTN_CHANGETITLE") as BaseButton
	if title_btn != null:
		title_btn.disabled = not c.own or c.open
	var msg_btn := window.node("GDR_BTN_OWNERMSG") as BaseButton
	if msg_btn != null:
		msg_btn.disabled = not c.own
	_draw_slots(panels, window, builder, c)
	var users := window.find_child("Users", true, false) as Label
	if users != null:
		users.text = "\n".join(PackedStringArray(c.users))

static func _draw_slots(panels, window: HudWindow, builder: UiBuilder, c: StallController) -> void:
	var display := window.node("GDR_STALL_DISPLAY") as Control
	if display == null:
		return
	var unit := c._text("UIIT_STT_UNIT", "Unit")
	var gold := c._text("UIIT_STT_GOLD", "Gold")
	for i in StallNet.SLOTS:
		var slot := display.get_node_or_null(SLOT_NAME % i) as Control
		if slot == null:
			continue
		var e: StallNet.Entry = c.entries.get(i)
		var art := slot.get_node_or_null("SlotArt") as TextureRect
		if art != null and builder != null:
			art.texture = builder.load_texture(StallController.SLOT_ART if e != null else StallController.SLOT_EMPTY_ART)
		var body := slot.get_node_or_null("Body") as Control
		if body == null:
			continue
		var holder := body.get_node_or_null("GDR_STALLSLOT_ICON") as Control
		var icon := holder.get_node_or_null("ItemIcon") as TextureRect if holder != null else null
		var name_n := body.get_node_or_null("GDR_STALLSLOT_NAME") as Control
		var amount := body.get_node_or_null("GDR_STALLSLOT_AMOUNT") as Control
		var price := body.get_node_or_null("GDR_STALLSLOT_PRICE") as Control
		var modify := body.get_node_or_null("GDR_STALLSLOT_MODIFY") as BaseButton
		for n in [holder, name_n, amount, price]:
			if n != null:
				(n as CanvasItem).visible = e != null
		if modify != null:
			# c:0x6bab20: an empty slot's button hidden; an occupied one's on
			# only for the owner while modifying.
			modify.visible = e != null
			modify.disabled = not (c.own and not c.open)
		if e == null:
			if icon != null:
				icon.texture = null
				panels._set_item_tip(icon, -1)
				panels._set_item_slot_fx(icon, -1)
			continue
		if icon != null:
			icon.texture = panels._item_icon(e.item.ref_item_id)
			icon.mouse_filter = Control.MOUSE_FILTER_STOP
			# A visitor's icons at alpha 0x80 while the stall is modified
			# (c:0x6bad9a, the slot's alpha +0x12d through 0x655460). The
			# alpha is the icon's own: the icon's draw puts stage 0's alpha
			# op back to SELECTARG1(TEXTURE) when it ends (0x655d50 ->
			# 0x6554c0), so the effects drawn after it (0x67cfb0) are not
			# dimmed -- self_modulate, which the effect children do not
			# inherit.
			icon.modulate = Color.WHITE
			icon.self_modulate.a = StallController.DIM_ALPHA if (not c.own and not c.open) else 1.0
			panels._set_item_tip(icon, e.item.ref_item_id, "stall", i)
			# Round 843 (lane S): the stall slot is a CIFSlotWithHelp
			# (CIFStallSlot c:0x6cada0 -> SetItem 0x6871d0 on the entry's
			# record, +0x48), so its item's effects show as in the bag: the
			# seal star, a pet's edge or wash, a spirit's edge.
			panels._set_item_slot_fx(icon, e.item.ref_item_id, e.item)
		if builder != null:
			var nl := builder.set_static_text(name_n, panels.item_name(e.item.ref_item_id)) if name_n != null else null
			if nl != null:
				nl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			var al := builder.set_static_text(amount, "%d %s" % [e.count, unit]) if amount != null else null
			if al != null:
				al.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			var pl := builder.set_static_text(price, "%s %s" % [StallNet.group_digits(e.price), gold]) if price != null else null
			if pl != null:
				pl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
				pl.add_theme_color_override("font_color", StallNet.price_colour(e.price))

## Round 842 (lane T): the window going takes its chat module with it. Every
## close of CIFStall is 0x79be20(0) (READ c:0x79bec3..0x79bf09): the window
## hidden, then 0x8b59f0("IFStall") deletes every control of the IFStall
## section (0x8b5510 out of the map, 0xba0e40), the CIFChatModule
## (STALL_CHAT) among them; the next stall's 0x79be20(1) loads the section
## afresh (0x8b5580). This client keeps one window and hides it, so the
## lines and the input box's text are emptied here instead.
static func chat_clear(window: HudWindow) -> void:
	if window == null:
		return
	var rt := window.find_child("Lines", true, false) as RichTextLabel
	if rt != null:
		rt.clear()
	var input := window.find_child("GDR_CHAT_INPUTBOX", true, false) as LineEdit
	if input != null:
		input.text = ""

## The chat module's lines as text (tests and QA).
static func chat_text(window: HudWindow) -> String:
	var rt := window.find_child("Lines", true, false) as RichTextLabel if window != null else null
	return rt.get_parsed_text() if rt != null else ""

## A line in the chat module.
static func chat_add(window: HudWindow, text: String, colour: Color) -> void:
	if window == null:
		return
	var rt := window.find_child("Lines", true, false) as RichTextLabel
	if rt == null:
		return
	rt.push_color(colour)
	rt.add_text(text)
	rt.pop()
	rt.newline()
