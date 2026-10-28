extends HudWindow
class_name GachaWindow

## Magic POP, the machine's window (round 838, lane 5): CIFGhaCha, READ from
## sro_client.exe (docs/protocol/magic_pop.md) unless labelled.
##
## - **The window**: ginterface.txt's GDR_GHACHA (ID 140), 673 x 428 in
##   mgame_wnd_, caption UIIT_PAG_GACHA_TITLE "Magic POP"; resinfo\ifghacha.txt
##   sections Create and Inventory, with config\define.txt's GACHA_SECOND_VER
##   (MEASURED: defined) taking the page spinner 700.
## - **The prizes** (c:0x748a30): the machine's prize set filtered by the
##   select window's kind, twelve to a page in SLOT_100..111. A click on one
##   keeps its GachaID (+0x7bc).
## - **The status line** (c:0x747940, on static 36): no prize chosen,
##   UIIT_MSG_GACHA_CHOICE "Choose item of desire."; a prize but no card,
##   UIIT_MSG_GACHA_ENTRY "Register Magic POP card."; a card,
##   UIIT_MSG_GACHA_BUTTON_CLICK "Click PLAY button." and PLAY enabled.
## - **The card**: a 3/3/14/1 from the window's inventory pane onto
##   CARD_SLOT (112) (c:0x749a30, c:0x538510).
## - **PLAY** (c:0x7459b0): not busy, a prize chosen, a card in its slot. Busy
##   is set; timer 1 (100 ms) turns both roll statics (20, 21) through
##   interface\game\gacha_roll%04d.ddj, 0000..0020 by 2; timer 2 (4000 ms)
##   sends 0x7118 {npc uid, GachaID, card slot + 13} (c:0x746df8), puts
##   gacha_roll_original.ddj back and stops both.
## - **The result** 0xB118 (c:0x88d690 -> c:0x748270): the card slot shows the
##   coupon; UIIT_MSG_GACHA_WIN or _LOSE; busy cleared. Timer 3 (100 ms)
##   turns STA_EFFACT (50) through ga_effect_%02d.ddj for 41 ticks, then on a
##   win ga_effect_sucess.ddj.
## - **Closing** (vslot_043 c:0x7481f0) is refused while busy.
##
## OURS, labelled:
##   - The card goes in with a left click on it in the window's inventory
##     pane, not by dragging it onto the card slot.
##   - The two result lines have only Korean text in the archive (their
##     English columns are empty, MEASURED); the fallbacks are their meaning,
##     "Congratulations." and "The item you wanted was not won.".
##   - The effect's frame order: ga_effect_01..19 in turn (the archive has
##     those 19; the %02d's counter was not read), and a win ends on
##     ga_effect_sucess_01/_02 alternating (the sprite sheet's frame layout
##     was not read).
##   - A refusal (any code) clears busy and is written to the log: retail
##     keeps only the code's low byte, shows nothing for these codes and stays
##     busy, which would leave the window unclosable.
##   - The inventory pane's page tabs (500+i) are not built: it shows the
##     bag's first 32 slots, and the page spinner (700) is not wired (the
##     archive's prize set has 10 rows, one page).
##   - No sounds (snd_gacha_move / _turn / _win / _end are not in UiSounds).

signal play_requested(npc_uid: int, gacha_id: int, bag_slot: int)

const LAYOUT := "resinfo\\ifghacha.txt"
const REGISTRY := "GDR_GHACHA"
const PRIZE_SLOTS := 12
const PRIZE_FIRST_ID := 100
const BAG_COLS := 4
const BAG_ROWS := 8
## The pane's cells (c: created in code): 200 + i at (494 + 36c, 91 + 36r).
const BAG_ORIGIN := Vector2(494, 91)
const BAG_PITCH := 36.0
const CELL := Vector2(32, 32)

const ROLL_FRAME := "interface\\game\\gacha_roll%04d.ddj"
const ROLL_ORIGINAL := "interface\\game\\gacha_roll_original.ddj"
const ROLL_LAST := 20
const ROLL_MS := 100
const SEND_MS := 4000
const EFFECT_FRAME := "interface\\game\\ga_effect_%02d.ddj"
const EFFECT_FRAMES := 19
const EFFECT_TICKS := 41
const WIN_FRAMES := ["interface\\game\\ga_effect_sucess_01.ddj", "interface\\game\\ga_effect_sucess_02.ddj"]

const MSG_CHOICE := ["UIIT_MSG_GACHA_CHOICE", "Choose item of desire."]
const MSG_ENTRY := ["UIIT_MSG_GACHA_ENTRY", "Register Magic POP card."]
const MSG_PLAY := ["UIIT_MSG_GACHA_BUTTON_CLICK", "Click PLAY button."]
const MSG_WIN := ["UIIT_MSG_GACHA_WIN", "Congratulations."]
const MSG_LOSE := ["UIIT_MSG_GACHA_LOSE", "The item you wanted was not won."]

## Hooks the opener sets: icon(ref id) -> Texture2D, types(ref id) ->
## PackedInt32Array, bag() -> Array of InventoryNet.Slot-like entries
## (slot_index, item_id, quantity).
var icon_of: Callable
var types_of: Callable
var bag_of: Callable

var npc_uid := 0
var prizes: Array = []     # GachaTables.Prize
var page := 0
var chosen := -1           # index into prizes
var card_slot := -1        # bag slot of the registered card
var busy := false
var _won := false
var _prize_nodes: Array = []
var _bag_cells: Array = []
var _roll_timer: Timer
var _send_timer: Timer
var _effect_timer: Timer
var _roll_frame := 0
var _effect_tick := 0
var _status: Control
var _play: BaseButton

func setup(builder: UiBuilder) -> bool:
	if not build(builder, LAYOUT, "Magic POP", PackedStringArray(["Inventory"]), builder.archive_defines(), true,
			{"name": REGISTRY, "archive_defines": true}):
		return false
	for i in PRIZE_SLOTS:
		var s := node("GDR_GHACHA_SLOT_%d" % (PRIZE_FIRST_ID + i)) as Control
		_prize_nodes.append(s)
		if s != null:
			s.mouse_filter = Control.MOUSE_FILTER_STOP
			s.gui_input.connect(_on_prize_input.bind(i))
	_status = node("GDR_GHACHA_GRADATION") as Control
	_play = node("GDR_GHACHA_BTN_START") as BaseButton
	if _play != null:
		_play.pressed.connect(play)
		_play.focus_mode = Control.FOCUS_NONE
	_build_bag_cells()
	_roll_timer = _timer(ROLL_MS, _on_roll_tick)
	_send_timer = _timer(SEND_MS, _on_send_due)
	_send_timer.one_shot = true
	_effect_timer = _timer(ROLL_MS, _on_effect_tick)
	visible = false
	return true

func _timer(ms: int, f: Callable) -> Timer:
	var t := Timer.new()
	t.wait_time = ms / 1000.0
	t.timeout.connect(f)
	add_child(t)
	return t

func _build_bag_cells() -> void:
	if panel_root == null:
		return
	for r in BAG_ROWS:
		for c in BAG_COLS:
			var cell := TextureRect.new()
			cell.name = "GachaBag%d" % (200 + r * BAG_COLS + c)
			cell.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			cell.mouse_filter = Control.MOUSE_FILTER_STOP
			var rect := Rect2(BAG_ORIGIN + Vector2(c, r) * BAG_PITCH, CELL)
			cell.set_meta(UiBuilder.AUTHORED_RECT_META, rect)
			cell.position = rect.position
			cell.size = rect.size
			cell.gui_input.connect(_on_bag_input.bind(r * BAG_COLS + c))
			panel_root.add_child(cell)
			_bag_cells.append(cell)
	UiBuilder.settle_authored_rects(panel_root)

func _t(pair: Array) -> String:
	var r := _builder.resolve_text(String(pair[0])) if _builder != null else ""
	return r if r != "" and r != String(pair[0]) else String(pair[1])

## Opens the window for the machine `uid` with these prizes.
func open_for(uid: int, list: Array) -> void:
	npc_uid = uid
	prizes = list
	page = 0
	chosen = -1
	card_slot = -1
	busy = false
	close_hides = true
	_show_roll(ROLL_ORIGINAL)
	_set_effect("interface\\game\\ga_effect_01.ddj")
	refresh()
	centre()
	visible = true

func _icon(ref: int) -> Texture2D:
	return icon_of.call(ref) if icon_of.is_valid() else null

func _bag() -> Array:
	return bag_of.call() if bag_of.is_valid() else []

static func _field(e, names: Array):
	for n in names:
		if e is Dictionary and (e as Dictionary).has(n):
			return e[n]
		if e is Object and n in e:
			return e.get(n)
	return null

## The item in bag slot `slot`: [item id, quantity], or [-1, 0].
func bag_item(slot: int) -> Array:
	for e in _bag():
		var i = _field(e, ["slot_index", "slot", "index"])
		if i != null and int(i) == slot:
			var id = _field(e, ["item_id", "id"])
			var q = _field(e, ["quantity", "count"])
			return [int(id) if id != null else -1, int(q) if q != null else 1]
	return [-1, 0]

func is_card(item_id: int) -> bool:
	var t: PackedInt32Array = types_of.call(item_id) if types_of.is_valid() and item_id >= 0 else PackedInt32Array()
	return t.size() >= 4 and t[0] == 3 and t[1] == 3 and t[2] == 14 and t[3] == 1

## Redraws the prizes, the pane, the card slot, the status line and PLAY.
func refresh() -> void:
	for i in PRIZE_SLOTS:
		var s: Control = _prize_nodes[i]
		if s == null:
			continue
		var k := page * PRIZE_SLOTS + i
		var icon := s.get_node_or_null("ItemIcon") as TextureRect
		if icon != null:
			icon.texture = _icon((prizes[k] as GachaTables.Prize).ref_id) if k < prizes.size() else null
		var count := s.get_node_or_null("CountLabel") as Label
		if count != null:
			count.text = str((prizes[k] as GachaTables.Prize).count) if k < prizes.size() and (prizes[k] as GachaTables.Prize).count > 1 else ""
		s.modulate = Color(1.4, 1.4, 0.8) if k == chosen else Color.WHITE
	for i in _bag_cells.size():
		var it := bag_item(i)
		var cell: TextureRect = _bag_cells[i]
		cell.texture = _icon(int(it[0])) if int(it[0]) >= 0 else null
		cell.modulate = Color(1, 1, 1, 0.4) if i == card_slot else Color.WHITE
	var card := node("GDR_GHACHA_CARD_SLOT") as Control
	if card != null:
		var icon := card.get_node_or_null("ItemIcon") as TextureRect
		if icon != null:
			icon.texture = _icon(int(bag_item(card_slot)[0])) if card_slot >= 0 else null
	if not busy:
		_say(status_pair())
	if _play != null:
		_play.disabled = not can_play()

## The status line's pair for the window's state (c:0x747940).
func status_pair() -> Array:
	if chosen < 0:
		return MSG_CHOICE
	if card_slot < 0 or not is_card(int(bag_item(card_slot)[0])):
		return MSG_ENTRY
	return MSG_PLAY

func can_play() -> bool:
	return not busy and chosen >= 0 and card_slot >= 0 and is_card(int(bag_item(card_slot)[0]))

func _say(pair: Array) -> void:
	_say_text(_t(pair))

func _say_text(t: String) -> void:
	if _status != null and _builder != null:
		var l := _builder.set_static_text(_status, t)
		if l != null:
			l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			l.add_theme_color_override("font_color", Color.WHITE)

## The text the status line shows now (tests and the QA log).
func status_text() -> String:
	var l: Label = null
	if _status is Label:
		l = _status as Label
	elif _status != null:
		l = _status.get_node_or_null("Text") as Label
	return l.text if l != null else ""

func choose_prize(i: int) -> void:
	if busy:
		return
	var k := page * PRIZE_SLOTS + i
	if k < prizes.size():
		chosen = k
		print("GACHA: prize %d chosen (gacha id %d, item %d)" % [k, (prizes[k] as GachaTables.Prize).gacha_id,
			(prizes[k] as GachaTables.Prize).ref_id])
		refresh()

func register_card(bag_slot: int) -> bool:
	if busy or not is_card(int(bag_item(bag_slot)[0])):
		return false
	card_slot = bag_slot
	print("GACHA: card registered from bag slot %d" % bag_slot)
	refresh()
	return true

## The pane's first cell holding a Magic POP card that is not registered yet
## (QA), or null.
func card_cell() -> Control:
	for i in _bag_cells.size():
		if i != card_slot and is_card(int(bag_item(i)[0])):
			return _bag_cells[i]
	return null

func _on_prize_input(event: InputEvent, i: int) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
		choose_prize(i)

func _on_bag_input(event: InputEvent, i: int) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
		register_card(i)

## PLAY (c:0x7459b0).
func play() -> void:
	if not can_play():
		return
	busy = true
	close_hides = false
	_roll_frame = 0
	_roll_timer.start()
	_send_timer.start()
	if _play != null:
		_play.disabled = true
	print("GACHA: PLAY -- rolling for %d ms" % SEND_MS)

func _on_roll_tick() -> void:
	_roll_frame = (_roll_frame + 2) % (ROLL_LAST + 2)
	_show_roll(ROLL_FRAME % _roll_frame)

func _show_roll(path: String) -> void:
	for n in ["GDR_GHACHA_STA_ROLLING_L", "GDR_GHACHA_STA_ROLLING_R"]:
		var s := node(n) as Control
		if s == null or _builder == null:
			continue
		var tex := s.get_node_or_null("GachaRoll") as TextureRect
		if tex == null:
			tex = TextureRect.new()
			tex.name = "GachaRoll"
			tex.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
			s.add_child(tex)
		tex.texture = _builder.load_texture(path)

func _on_send_due() -> void:
	_roll_timer.stop()
	_show_roll(ROLL_ORIGINAL)
	if chosen < 0 or card_slot < 0:
		busy = false
		return
	var p: GachaTables.Prize = prizes[chosen]
	print("GACHA: send 0x7118 npc %d gacha id %d card slot %d" % [npc_uid, p.gacha_id, card_slot])
	play_requested.emit(npc_uid, p.gacha_id, card_slot)

## 0xB118 (c:0x88d690).
func on_result(result: Dictionary) -> void:
	busy = false
	close_hides = true
	if not bool(result.get("ok", false)):
		print("GACHA: refused, code 0x%x" % int(result.get("code", 0)))
		refresh()
		return
	_won = bool(result.get("win", false))
	print("GACHA: result %s" % ("WIN" if _won else "LOSE"))
	_say(MSG_WIN if _won else MSG_LOSE)
	_effect_tick = 0
	_effect_timer.start()
	if _play != null:
		_play.disabled = true

## The bag changed (the card became its coupon): the pane and the card slot
## redraw; the status line keeps the result until the next choice.
func on_bag_changed() -> void:
	if not visible:
		return
	var keep := status_text()
	refresh()
	if card_slot >= 0 and not is_card(int(bag_item(card_slot)[0])) and keep != "":
		_say_text(keep)

func _on_effect_tick() -> void:
	_effect_tick += 1
	if _effect_tick > EFFECT_TICKS:
		_effect_timer.stop()
		if _won:
			_set_effect(WIN_FRAMES[0])
		return
	if _won and _effect_tick > EFFECT_TICKS - 6:
		_set_effect(WIN_FRAMES[_effect_tick % 2])
		return
	_set_effect(EFFECT_FRAME % ((_effect_tick - 1) % EFFECT_FRAMES + 1))

func _set_effect(path: String) -> void:
	var s := node("GDR_GHACHA_STA_EFFACT") as Control
	if s == null or _builder == null:
		return
	var tex := _builder.load_texture(path)
	if tex == null:
		return
	if s is TextureRect:
		(s as TextureRect).texture = tex
	else:
		var t := s.get_node_or_null("GachaEffect") as TextureRect
		if t == null:
			t = TextureRect.new()
			t.name = "GachaEffect"
			t.mouse_filter = Control.MOUSE_FILTER_IGNORE
			s.add_child(t)
		t.texture = tex

func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if visible and key != null and key.pressed and not key.echo and key.keycode == KEY_ESCAPE:
		if not busy:
			hide()
			closed.emit()
		get_viewport().set_input_as_handled()
