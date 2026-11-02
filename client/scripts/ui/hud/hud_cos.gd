extends Control
class_name HudCos

## The COS manager (round 795): the client's CIFCOSManager (registry
## `GDR_COS_MANAGER`, ID 39, an invisible 0,0,0,0 parent with Style 64). It
## keeps one record per summoned COS (ride horse, transport, growth pet,
## ability pet, guild soldier) in summon order, the CURRENT COS (manager
## +0x10), and every piece of the pet / COS interface: the status slots
## (HudCosStatus), the command strips (HudCosCommand), the growth pet's strip
## under the player block (HudPetMiniInfo) and the COS window (HudCosWindow).
## READ from sro_client.exe unless a line says otherwise; client_ui.md has the
## addresses (sections 0, 2 and 3), and each piece's file has its own.
##
## - 0x30C8 (FUN_008a6650 -> 0x811500): the record is parsed; the manager is
##   shown if it was empty; a second guild soldier gets no slot of its own
##   (one slot for all of them); the status slot and the strip are created and
##   laid out; the COS becomes current; a growth pet shows the pet strip; an
##   open COS window is re-shown for the current COS with page 3 (keep).
## - 0x30C9 (FUN_008aa340): 1 removal, 2 the bag, 3 EXP (the client's own
##   level-up loop through leveldata, and the gain / loss line), 4 HGP, 5 the
##   name, 7 the RefObjID; 6 is read and ignored.
## - The current COS (0x810fd0): its outline on and the previous one's off,
##   its strip shown and every other hidden, an open COS window re-shown for
##   it with page 3. W (0x811200) moves to the next COS in summon order,
##   wrapping, when two or more are out.
## - The commands (FUN_007a0980) act on the current COS; while the owner is
##   dead only command 0 runs.
##
## OURS, each said where it is done: whether a COS can be ridden (refchar
## +0x1d4, a column not mapped) comes from the "can_ride" provider, else ride
## horses and transports; the bottom bar's origin is the "underbar_origin"
## provider's or CNIFUnderMenuBar's own placement ((W - 800) / 2, H - 68,
## HudUnderbar); a re-sent 0x30C8 replaces its record in place.

## A command that needs the server: 1 ride, 2 attack, 3 follow, 4 unsummon,
## 5 terminate, 6 AI (FUN_007a0980's numbering).
signal command(uid: int, cmd: int)
## The naming dialog's name, confirmed: send 0x7117.
signal rename_requested(uid: int, cos_name: String)
## The client's name check refused a name (0x8c3cb0).
signal name_rejected(uid: int, cos_name: String)
## 0x7420 {uid, kind, value}: kind 1 a growth pet's AI mode (command 6),
## kind 2 an ability pet's pickup flags (the Setting page).
signal setting_requested(uid: int, kind: int, value: int)
## A pet-bag move (0x7034 with CosNet.BAG_*): COS_TO_COS inside the bag,
## BAG_TO_COS from the player's bag (src is the bag index).
signal bag_move_requested(type: int, uid: int, src: int, dst: int, count: int)
## A pet-bag item was put down on the player's bag (World3D picks the
## destination and sends BAG_COS_TO_BAG).
signal bag_drag_to_inventory(uid: int, src: int)
## A status slot was clicked: select this COS as the target.
signal target_requested(uid: int)
## A line the original prints to the system log.
signal system_line(text: String, color: Color)
## Round 801: the transport window's Sell All.
signal sell_all_requested(uid: int)

## The system log's colour for 0x7781b0 types 0 and 1 (0xffdbc99b, READ) --
## the EXP lines, the HGP warning and the name refusal (0x778190's own
## argument, 0x7a461a).
const SYSTEM_COLOUR := Color8(0xdb, 0xc9, 0x9b)
## The name refusal's system message number (0x7a461f, `push 0x440e`). Its
## text is OPEN; the "message_text" provider may name it.
const NAME_REFUSAL_MESSAGE := 0x440e
## The player block's screen origin (GDR_PLAYER_MINI_INFO's 4,7), used to hang
## the pet strip when no block is given (attach_pet_mini_info).
const PLAYER_BLOCK_ORIGIN := Vector2(4, 7)
## CNIFUnderMenuBar's placement (HudUnderbar, READ 0x7871dc): ((W - 800) / 2,
## H - 0x44).
const UNDERBAR_WIDTH := 800
const UNDERBAR_FROM_BOTTOM := 68

class Entry:
	var data: CosNet.Data
	var kind: int = -1
	var status: HudCosStatus
	var command: HudCosCommand
	## A second guild soldier: kept, but with no slot or strip of its own.
	var hidden := false

var _builder: UiBuilder
var providers: Dictionary = {}
## uid -> Entry, and the summon order (the list at manager +0x374).
var _entries := {}
var _order: Array = []
var _current := 0
var _dead := false
## The COS the player rides (0xB0CB), 0 when on foot (player +0x2a4).
var _ridden := 0
var window: HudCosWindow
var pet_info: HudPetMiniInfo
var clean_box: HudCosBox
var _item_lookup: Callable
var _last_screen := Vector2.ZERO

func _init(builder: UiBuilder = null) -> void:
	_builder = builder
	name = "COSManager"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	# Style 64: hidden at creation, shown with the first COS.
	visible = false

## Providers, each a Callable:
##   "cos_row"(ref_id) -> CosTable.Row or null
##   "item_row"(ref_item_id) -> ItemTableReader.Item or null
##   "text"(key) -> String (the UI text table; the key itself or "" when absent)
##   "exp_to_next"(level) -> int (leveldata's threshold; 0 when unknown)
##   "screen_width"() -> int
## and, optional: "screen_height"() -> int, "underbar_origin"() -> Vector2,
## "item_tooltip"(ItemInstance, ItemTableReader.Item) (null, null to hide),
## "object_name"(name_key) -> String (the object text table: a ride's,
## transport's or soldier's record takes its row's name),
## "pick_up"(what: Dictionary, icon, source, at) -> bool (HudPanels.pick_up_icon),
## "bubble_tip"(control, source) (HudPanels.set_bubble_tip), "can_ride"(ref_id)
## -> bool, "message_text"(number) -> String, "cos_stats"(ref_id) ->
## Dictionary, "trade_level"() -> int, "trade_price"(ref_item_id) -> int,
## "special_store_open"() -> bool, "item_lookup"(bag_index) -> ItemInstance.
func setup(p: Dictionary) -> void:
	providers = p.duplicate()
	if providers.has("item_lookup"):
		_item_lookup = providers["item_lookup"]
	_ensure_window()
	_ensure_pet_info()

## The summon item lookup (bag index -> ItemInstance) the Basic Info page's
## rental row and a bag-to-pet move read.
func set_item_lookup(lookup: Callable) -> void:
	_item_lookup = lookup
	if window != null:
		window.providers["item_lookup"] = lookup

## A UI text key through the provider, `fallback` when it does not resolve
## (the fallbacks are the stock English rows client_ui.md quotes, used only
## without the archive's table).
func text(key: String, fallback: String) -> String:
	var c: Callable = providers.get("text", Callable())
	var r := ""
	if c.is_valid():
		r = String(c.call(key))
	elif _builder != null:
		r = _builder.resolve_text(key)
	return fallback if r == "" or r == key else r

func _p(key: String) -> Callable:
	return providers.get(key, Callable())

func _ensure_window() -> void:
	if window != null:
		return
	window = HudCosWindow.new()
	var wp := providers.duplicate()
	wp["text"] = Callable(self, "text")
	wp["screen_size"] = Callable(self, "_screen_size")
	if _item_lookup.is_valid():
		wp["item_lookup"] = _item_lookup
	window.providers = wp
	if _builder == null or not window.build_window(_builder):
		# No archive: the window keeps its rules (tests) but draws nothing.
		window.providers = wp
	add_child(window)
	window.visible = false
	window.rename_requested.connect(func(uid: int, n: String) -> void: rename_requested.emit(uid, n))
	window.name_rejected.connect(_on_name_rejected)
	window.setting_requested.connect(func(uid: int, k: int, v: int) -> void: setting_requested.emit(uid, k, v))
	window.bag_slot_picked.connect(_on_bag_slot_picked)
	window.bag_slot_hovered.connect(_on_bag_slot_hovered)
	window.sell_all_requested.connect(func(uid: int) -> void: sell_all_requested.emit(uid))

func _ensure_pet_info() -> void:
	if pet_info != null:
		return
	pet_info = HudPetMiniInfo.new(_builder, Callable(self, "text"))
	pet_info.build()
	pet_info.visible = false
	# Until a player block is given, the strip hangs at its place under the
	# block's registry origin (OURS: attach_pet_mini_info puts it in the block).
	pet_info.position = PLAYER_BLOCK_ORIGIN + HudPetMiniInfo.RECT.position
	add_child(pet_info)

## Puts the pet strip into the player block (child 100 of
## GDR_PLAYER_MINI_INFO, at 53,55 of the block, in control 100's place in
## the block's draw order: HudPetMiniInfo.attach_to).
func attach_pet_mini_info(player_info: Control) -> void:
	_ensure_pet_info()
	pet_info.attach_to(player_info)

# --- records ------------------------------------------------------------------

func has_any() -> bool:
	return not _order.is_empty()

func current_uid() -> int:
	return _current

func cos_data(uid: int) -> CosNet.Data:
	var e: Entry = _entries.get(uid)
	return e.data if e != null else null

## The client kind of a summoned COS (CosNet.client_kind), -1 when not out.
func cos_kind(uid: int) -> int:
	var e: Entry = _entries.get(uid)
	return e.kind if e != null else -1

## The summon order (uids).
func summon_order() -> Array:
	return _order.duplicate()

func status_of(uid: int) -> HudCosStatus:
	var e: Entry = _entries.get(uid)
	return e.status if e != null else null

func command_of(uid: int) -> HudCosCommand:
	var e: Entry = _entries.get(uid)
	return e.command if e != null else null

## A row's own name (characterdata column 5 through the object text table,
## the "object_name"(name_key) provider), "" without one.
func _object_name(ref_id: int) -> String:
	var row := _row(ref_id)
	var c := _p("object_name")
	if row == null or row.name_key == "" or not c.is_valid():
		return ""
	return String(c.call(row.name_key))

func _row(ref_id: int) -> CosTable.Row:
	var c := _p("cos_row")
	if not c.is_valid():
		return null
	return c.call(ref_id) as CosTable.Row

## 0x30C8 for the owner.
func add_cos(d: CosNet.Data) -> void:
	if d == null:
		return
	_ensure_window()
	_ensure_pet_info()
	var k := CosNet.client_kind(d.kind)
	# The record's name (+0x1c, FUN_009a1900): a pet's comes in the packet,
	# every other COS takes its row's own name text.
	if not CosNet.is_pet(d.kind) and d.name == "":
		d.name = _object_name(d.ref_id)
	var e: Entry = _entries.get(d.uid)
	if e != null:
		# Re-sent: the record replaced in place, its UI rebuilt for its kind.
		e.data = d
		if e.kind != k and not e.hidden:
			_free_ui(e)
			e.kind = k
			_make_ui(e)
		e.kind = k
		_refresh_entry(e)
	else:
		e = Entry.new()
		e.data = d
		e.kind = k
		# One slot for every guild soldier (0x811500: a second one stops here).
		if k == 4:
			for uid in _order:
				var other: Entry = _entries[uid]
				if other.kind == 4 and not other.hidden:
					e.hidden = true
		_entries[d.uid] = e
		_order.append(d.uid)
		visible = true
		if e.hidden:
			return
		_make_ui(e)
	_layout()
	make_current(d.uid)
	if k == 3:
		_show_pet_info(e)

func _make_ui(e: Entry) -> void:
	var row := _row(e.data.ref_id)
	e.status = HudCosStatus.new(_builder)
	e.status.name = "COSStatus%d" % e.data.uid
	e.status.build()
	e.status.setup_kind(e.kind, row.icon if row != null else "")
	var uid := e.data.uid
	e.status.pressed_left.connect(func() -> void: _on_status_left(uid))
	e.status.released_right.connect(func() -> void: _on_status_right(uid))
	add_child(e.status)
	e.command = HudCosCommand.new(_builder, Callable(self, "text"))
	e.command.name = "COSCommand%d" % e.data.uid
	e.command.build(e.kind)
	e.command.visible = false
	e.command.command_used.connect(run_command)
	e.command.command_picked.connect(_on_command_picked)
	add_child(e.command)
	_wire_command_tips(e.command)
	_refresh_entry(e)

func _free_ui(e: Entry) -> void:
	for n in [e.status, e.command]:
		if n != null and is_instance_valid(n):
			remove_child(n)
			n.queue_free()
	e.status = null
	e.command = null

func _wire_command_tips(strip: HudCosCommand) -> void:
	var tip := _p("bubble_tip")
	if not tip.is_valid():
		return
	for b in strip.buttons:
		var cmd := int(b["cmd"])
		tip.call(b["slot"], func() -> String: return strip.tooltip_of(cmd))

## 0x30C9 type 1, and 0x8116f0.
func remove_cos(uid: int) -> void:
	var e: Entry = _entries.get(uid)
	if e == null:
		return
	if window != null and window.visible and window.cos_uid == uid:
		window.close_window()
	if e.kind == 3 and pet_info != null and pet_info.uid == uid:
		pet_info.visible = false
		pet_info.uid = 0
	if clean_box != null and is_instance_valid(clean_box) and int(clean_box.get_meta("uid", 0)) == uid:
		clean_box.close()
		clean_box = null
	_free_ui(e)
	_entries.erase(uid)
	_order.erase(uid)
	if _ridden == uid:
		_ridden = 0
	# A hidden soldier record takes the freed slot when the shown one goes.
	if e.kind == 4 and not e.hidden:
		for other_uid in _order:
			var other: Entry = _entries[other_uid]
			if other.kind == 4 and other.hidden:
				other.hidden = false
				_make_ui(other)
				break
	if _order.is_empty():
		_current = 0
		visible = false
		return
	_layout()
	if _current == uid or not _entries.has(_current):
		_current = 0
		for first in _order:
			if not (_entries[first] as Entry).hidden:
				make_current(first)
				break

## The current COS (0x810fd0): outline, strips, and an open COS window.
func make_current(uid: int) -> void:
	var e: Entry = _entries.get(uid)
	if e == null or e.hidden:
		return
	_current = uid
	for other_uid in _order:
		var o: Entry = _entries[other_uid]
		if o.status != null:
			o.status.set_current(other_uid == uid)
		if o.command != null:
			o.command.visible = other_uid == uid
	_place_strips()
	if window != null and window.visible:
		window.show_cos(e.data, HudCosWindow.PAGE_KEEP)

## W (0x811200): the next COS in summon order, wrapping; only with two or
## more out.
func switch_next() -> void:
	var shown: Array = []
	for uid in _order:
		if not (_entries[uid] as Entry).hidden:
			shown.append(uid)
	if shown.size() < 2:
		return
	var i := shown.find(_current)
	make_current(shown[(i + 1) % shown.size()])

# --- layout -------------------------------------------------------------------

func _screen_size() -> Vector2:
	var w := 0
	var h := 0
	var cw := _p("screen_width")
	if cw.is_valid():
		w = int(cw.call())
	var ch := _p("screen_height")
	if ch.is_valid():
		h = int(ch.call())
	if (w <= 0 or h <= 0) and is_inside_tree():
		var v := get_viewport_rect().size
		w = w if w > 0 else int(v.x)
		h = h if h > 0 else int(v.y)
	return Vector2(w, h)

## The status slots at (W - 172 - 48 i, 2) in summon order (0x810660).
func _layout() -> void:
	var screen := _screen_size()
	_last_screen = screen
	var i := 0
	for uid in _order:
		var e: Entry = _entries[uid]
		if e.status == null:
			continue
		e.status.position = HudCosStatus.slot_position(int(screen.x), i)
		i += 1
	_place_strips()

func _underbar_origin() -> Vector2:
	var c := _p("underbar_origin")
	if c.is_valid():
		return c.call()
	var s := _screen_size()
	return Vector2(floorf((s.x - UNDERBAR_WIDTH) / 2.0), s.y - UNDERBAR_FROM_BOTTOM)

func _place_strips() -> void:
	var origin := _underbar_origin()
	for uid in _order:
		var e: Entry = _entries[uid]
		if e.command != null:
			e.command.place(origin)

func _process(_delta: float) -> void:
	if not visible:
		return
	if _screen_size() != _last_screen:
		_layout()
	for uid in _order:
		_refresh_gauges(_entries[uid])

func _refresh_gauges(e: Entry) -> void:
	var row := _row(e.data.ref_id)
	var hp := HudCosWindow.hp_ratio(e.data.hp, row.max_hp if row != null else 0)
	var hgp := HudCosWindow.hgp_ratio(e.data.hgp) if e.kind == 3 else 0.0
	if e.status != null:
		e.status.set_ratios(hp, hgp)
	if e.kind == 3 and pet_info != null and pet_info.uid == e.data.uid:
		pet_info.set_ratios(hp, hgp)

func _refresh_entry(e: Entry) -> void:
	if e.command != null:
		e.command.refresh(strip_state(e.data.uid))
	_refresh_gauges(e)

## The command strip's state for a COS (HudCosCommand.icon_path's keys).
func strip_state(uid: int) -> Dictionary:
	var e: Entry = _entries.get(uid)
	if e == null:
		return {"has_record": false, "dead": _dead, "kind": -1}
	return {"has_record": true, "dead": _dead, "rideable": can_ride(uid), "riding": _ridden != 0,
		"kind": e.kind, "settings": e.data.pet_option}

## Whether a COS can be ridden (refchar +0x1d4 != 0). OURS: the column behind
## +0x1d4 is not mapped, so the "can_ride" provider decides, else ride horses
## and transports.
func can_ride(uid: int) -> bool:
	var e: Entry = _entries.get(uid)
	if e == null:
		return false
	var c := _p("can_ride")
	if c.is_valid():
		return bool(c.call(e.data.ref_id))
	return e.kind == 0 or e.kind == 1

func _refresh_strips() -> void:
	for uid in _order:
		var e: Entry = _entries[uid]
		if e.command != null:
			e.command.refresh(strip_state(uid))

func _show_pet_info(e: Entry) -> void:
	if pet_info == null:
		return
	var row := _row(e.data.ref_id)
	var icon: Texture2D = null
	if row != null and _builder != null and row.icon != "":
		icon = _builder.load_texture(row.icon)
	pet_info.fill(e.data.uid, e.data.name, e.data.level, icon)
	pet_info.visible = true
	_refresh_gauges(e)

func _refill_pet_info(e: Entry) -> void:
	if e.kind == 3 and pet_info != null and pet_info.uid == e.data.uid:
		_show_pet_info(e)

func _refresh_window(uid: int) -> void:
	if window != null and window.visible and window.cos_uid == uid:
		var e: Entry = _entries.get(uid)
		if e != null:
			window.data = e.data
			window.set_title(window._display_name())
			window.refresh()

# --- updates ------------------------------------------------------------------

## 0x30C9.
func apply_update(u: CosNet.Update) -> void:
	if u == null:
		return
	if u.type == CosNet.UPDATE_REMOVED:
		remove_cos(u.uid)
		return
	var e: Entry = _entries.get(u.uid)
	if e == null:
		return
	match u.type:
		CosNet.UPDATE_INVENTORY:
			e.data.inv_size = u.inv_size
			e.data.items = u.items
			if window != null and window.visible and window.cos_uid == u.uid:
				window.data = e.data
				window.refresh_inventory()
		CosNet.UPDATE_EXP:
			_apply_exp(e, u.exp_delta)
		CosNet.UPDATE_HGP:
			e.data.hgp = u.hgp
			_refresh_window(u.uid)
		CosNet.UPDATE_NAME:
			e.data.name = u.name
			_refill_pet_info(e)
			_refresh_window(u.uid)
		CosNet.UPDATE_REF:
			e.data.ref_id = u.ref_id
			if not CosNet.is_pet(e.data.kind):
				e.data.name = _object_name(u.ref_id)
			# 0x9a0e00: HP to the new row's maximum, HGP full for a growth pet.
			var row := _row(u.ref_id)
			if row != null:
				e.data.hp = row.max_hp
			if e.kind == 3:
				e.data.hgp = CosNet.HGP_FULL
			if e.status != null:
				e.status.setup_kind(e.kind, row.icon if row != null else "")
			_refill_pet_info(e)
			_refresh_entry(e)
			_refresh_window(u.uid)

## The EXP step of 0x30C9 case 3 (FUN_008aa340, READ): a negative delta adds
## and clamps at 0; a zero delta changes nothing; a positive one that reaches
## the level's threshold (leveldata row +8) runs the level-up loop -- take the
## threshold off, level + 1, the next level's threshold, while EXP >= it.
## Returns {"level", "exp", "leveled"}. A threshold of 0 (unknown) stops the
## loop (OURS: the client's rows are never 0).
static func apply_exp_delta(level: int, exp_now: int, delta: int, next_of: Callable) -> Dictionary:
	if delta < 0:
		return {"level": level, "exp": maxi(0, exp_now + delta), "leveled": false}
	if delta == 0:
		return {"level": level, "exp": exp_now, "leveled": false}
	var total := exp_now + delta
	var next := int(next_of.call(level)) if next_of.is_valid() else 0
	if next <= 0 or total < next:
		return {"level": level, "exp": total, "leveled": false}
	while true:
		total -= next
		level += 1
		next = int(next_of.call(level))
		if next <= 0 or total < next:
			break
	return {"level": level, "exp": total, "leveled": true}

## The system line of an EXP change (UIIT_MSG_COSPET_GAIN_EXP /
## _LOST_EXP, "%d" of the delta / its negation), "" for no change.
func exp_line(delta: int) -> String:
	if delta > 0:
		return _fmt_d(text("UIIT_MSG_COSPET_GAIN_EXP", "You have gained [%d]amount of pet experience."), delta)
	if delta < 0:
		return _fmt_d(text("UIIT_MSG_COSPET_LOST_EXP", "You have lost [%d]amount of pet experience."), -delta)
	return ""

static func _fmt_d(fmt: String, v: int) -> String:
	return fmt.replace("%d", str(v)) if fmt.contains("%d") else "%s %d" % [fmt, v]

func _apply_exp(e: Entry, delta: int) -> void:
	var r := apply_exp_delta(e.data.level, e.data.exp, delta, _p("exp_to_next"))
	e.data.level = int(r["level"])
	e.data.exp = int(r["exp"])
	var line := exp_line(delta)
	if line != "":
		system_line.emit(line, SYSTEM_COLOUR)
	if bool(r["leveled"]):
		_refill_pet_info(e)
	_refresh_window(e.data.uid)

## 0x3057 bit 0x01: the COS's HP.
func set_hp(uid: int, hp: int) -> void:
	var e: Entry = _entries.get(uid)
	if e == null:
		return
	e.data.hp = hp
	_refresh_gauges(e)

## 0x3057 bit 0x08: the HGP; crossing from above 3000 to at-or-below prints
## UIIT_MSG_COSPETERR_HGP_30LOW (0x9a0d70) and the stats go grey.
func set_hgp(uid: int, hgp: int) -> void:
	var e: Entry = _entries.get(uid)
	if e == null:
		return
	var before := e.data.hgp
	e.data.hgp = hgp
	if before > CosNet.HGP_LOW and hgp <= CosNet.HGP_LOW:
		system_line.emit(text("UIIT_MSG_COSPETERR_HGP_30LOW",
			"All stats are lowered by 50% when the pet's HGP is lower than 30%."), SYSTEM_COLOUR)
	_refresh_gauges(e)
	_refresh_window(uid)

## 0xB0CB: the player mounted (`riding`) or left `uid`; command 1's icon.
func set_riding(uid: int, riding: bool) -> void:
	if riding:
		_ridden = uid
	elif _ridden == uid or uid == 0:
		_ridden = 0
	_refresh_strips()

## The owner died or revived (player +0x65c bit 1): every command but 0 is
## refused and drawn disabled (0x8113d0).
func set_owner_dead(dead: bool) -> void:
	_dead = dead
	_refresh_strips()

## 0xB420's success: the record's settings word (+0x163a8).
func setting_applied(uid: int, kind: int, value: int) -> void:
	var e: Entry = _entries.get(uid)
	if e == null:
		return
	e.data.pet_option = value
	if e.command != null:
		e.command.refresh(strip_state(uid))
	if window != null and window.cos_uid == uid:
		window.data = e.data
		if kind == CosNet.SETTING_PICKUP:
			window.edit_flags = value
			window.refresh_setup()

## 0xB034's pet-bag forms (CosNet.decode_bag_op): the record follows the move.
## OURS: a move onto a filled slot swaps the two (the server's stacking rule
## is applied by its next 0x30C9 type 2, if it differs).
func bag_applied(op: Dictionary) -> void:
	if not bool(op.get("ok", false)):
		return
	var e: Entry = _entries.get(int(op.get("cos", 0)))
	if e == null:
		return
	var items: Dictionary = e.data.items
	var src := int(op.get("src", -1))
	var dst := int(op.get("dst", -1))
	match int(op.get("type", 0)):
		CosNet.BAG_COS_TO_COS:
			if items.has(src):
				var moving: ItemInstance = items[src]
				var there: ItemInstance = items.get(dst)
				items.erase(src)
				if there != null:
					there.slot = src
					items[src] = there
				moving.slot = dst
				items[dst] = moving
		CosNet.BAG_COS_TO_BAG:
			items.erase(src)
		CosNet.BAG_BAG_TO_COS:
			# The bag's item, read before the bag forgets it.
			if _item_lookup.is_valid():
				var it = _item_lookup.call(src)
				if it is ItemInstance:
					(it as ItemInstance).slot = dst
					items[dst] = it
		CosNet.BAG_PICK:
			var picked = op.get("item")
			if picked is ItemInstance:
				var at := int(op.get("slot", -1))
				var held: ItemInstance = items.get(at)
				# A pick onto a stack of the same item (a good into the
				# transport, round 801) merges into it (c:0x87eb50 case 0x11).
				if held != null and held.ref_item_id == (picked as ItemInstance).ref_item_id and not held.is_equipment:
					held.count += maxi(1, (picked as ItemInstance).count)
				else:
					(picked as ItemInstance).slot = at
					items[at] = picked
	if window != null and window.visible and window.cos_uid == e.data.uid:
		window.data = e.data
		window.refresh_inventory()

## Round 801: the transport's bag and trade rows drawn again (a buy, a sale,
## a new scale or price list).
func refresh_trade() -> void:
	if window != null and window.visible:
		window.refresh_inventory()

# --- commands -------------------------------------------------------------------

## The command PgUp runs on a kind (0x811350): unsummon (4) for a pet,
## terminate (5) otherwise.
static func pgup_command(client_kind: int) -> int:
	return HudCosCommand.CMD_UNSUMMON if client_kind == 2 or client_kind == 3 else HudCosCommand.CMD_TERMINATE

## A command on the current COS (FUN_007a0980).
func run_command(cmd: int) -> void:
	var e: Entry = _entries.get(_current)
	if e == null:
		return
	if _dead and cmd != HudCosCommand.CMD_INFO:
		return
	var uid := _current
	var pet := e.kind == 2 or e.kind == 3
	match cmd:
		HudCosCommand.CMD_INFO:
			if e.kind == 4:
				return
			if window == null:
				return
			if window.visible:
				window.close_window()
			else:
				window.open_for(e.data, HudCosWindow.info_command_page(e.kind))
		HudCosCommand.CMD_RIDE:
			if can_ride(uid):
				command.emit(uid, cmd)
		HudCosCommand.CMD_ATTACK:
			if e.kind == 3:
				command.emit(uid, cmd)
		HudCosCommand.CMD_FOLLOW, HudCosCommand.CMD_UNSUMMON:
			if pet:
				command.emit(uid, cmd)
		HudCosCommand.CMD_TERMINATE:
			if pet:
				return
			if e.kind == 1:
				_ask_clean(uid)
			else:
				command.emit(uid, cmd)
		HudCosCommand.CMD_AI:
			if e.kind != 3:
				return
			# 0x7a0f1f: the toggle -- 1 (offensive) unless it is 1 now.
			var next := 0 if e.data.pet_option == 1 else 1
			if next == e.data.pet_option:
				return
			command.emit(uid, cmd)
			setting_requested.emit(uid, CosNet.SETTING_AI, next)

## Round 841: the store opened under the specialty lock (0xB046 {1, 0xc}:
## the specialty traders' stores and NPC_TD_THIEF_BUY). READ c:0x79dbd0 ->
## 0x811130(1) then 0x811310(0, 0xff) (docs/protocol/window_companions.md):
## - 0x811130(1): the current COS when its kind (+0x14) is 1, a transport;
##   else, with two or more out, the first transport in summon order made
##   current (0x810fd0); none: nothing, and no window opens;
## - 0x811310(0, 0xff) -> 0x7a0980(0): command 0 on the current COS, the COS
##   window's TOGGLE -- opened on the Inventory page (kind 1) when closed,
##   closed (its position saved) when it was open.
## `unsaved_at` is the window's place while no position is saved (OURS,
## HudCosWindow.open_for). Returns what it did: "none" (no transport),
## "opened", "closed".
func specialty_store_opened(unsaved_at: Variant = null) -> String:
	var uid := 0
	var cur: Entry = _entries.get(_current)
	if cur != null and cur.kind == 1:
		uid = _current
	elif _order.size() > 1:
		for other in _order:
			var e: Entry = _entries[other]
			if e.kind == 1:
				uid = int(other)
				break
	if uid == 0:
		return "none"
	make_current(uid)
	# Command 0 runs while the owner is dead too (0x7a0a09..0x7a0a16): no
	# test of _dead here.
	if window == null:
		return "none"
	if window.visible:
		window.close_window()
		return "closed"
	var e2: Entry = _entries[uid]
	window.open_for(e2.data, HudCosWindow.info_command_page(e2.kind), unsaved_at)
	return "opened"

## Round 841: Escape's COS window step (c:0x79d620 -> 0x799140(0x78),
## 0x79bcd0(0, 0, 0)): the window closed, its position saved. True when it
## was open.
func escape_close_window() -> bool:
	if window == null or not window.visible:
		return false
	window.close_window()
	return true

## The transport's terminate question (request type 0xd); Yes sends it.
func _ask_clean(uid: int) -> void:
	if clean_box != null and is_instance_valid(clean_box):
		clean_box.close()
	clean_box = HudCosBox.new()
	if _builder == null or not clean_box.build_clean_confirm(_builder):
		clean_box.free()
		clean_box = null
		return
	clean_box.set_meta("uid", uid)
	clean_box.accepted.connect(func(_t: String) -> void: confirm_clean(uid))
	add_child(clean_box)
	clean_box.centre_on(_screen_size())

## Yes on the terminate question.
func confirm_clean(uid: int) -> void:
	if _entries.has(uid):
		command.emit(uid, HudCosCommand.CMD_TERMINATE)

func _on_status_left(uid: int) -> void:
	make_current(uid)
	target_requested.emit(uid)

func _on_status_right(uid: int) -> void:
	make_current(uid)
	target_requested.emit(uid)
	run_command(HudCosCommand.CMD_INFO)

func _on_command_picked(cmd: int, icon: Texture2D, source: Control, at: Vector2) -> void:
	var c := _p("pick_up")
	if c.is_valid():
		c.call({"kind": "cos_command", "cmd": cmd}, icon, source, at)

func _on_name_rejected(uid: int, n: String) -> void:
	name_rejected.emit(uid, n)
	var c := _p("message_text")
	if c.is_valid():
		var t := String(c.call(NAME_REFUSAL_MESSAGE))
		if t != "":
			system_line.emit(t, SYSTEM_COLOUR)

# --- the pet bag and the held icon ----------------------------------------------

func _on_bag_slot_picked(uid: int, slot: int, icon: Texture2D, source: Control, at: Vector2) -> void:
	var c := _p("pick_up")
	var e: Entry = _entries.get(uid)
	if not c.is_valid() or e == null:
		return
	var it: ItemInstance = e.data.items.get(slot)
	if it == null:
		return
	c.call({"kind": "cos_bag", "uid": uid, "slot": slot, "item_id": it.ref_item_id,
		"qty": maxi(1, it.count)}, icon, source, at)

func _on_bag_slot_hovered(it: ItemInstance, row: ItemTableReader.Item, _source: Control) -> void:
	var c := _p("item_tooltip")
	if c.is_valid():
		c.call(it, row)

## The pet-bag slot under a screen position, -1 when none.
func pet_bag_slot_at(screen_pos: Vector2) -> int:
	return window.bag_slot_at(screen_pos) if window != null else -1

## The held icon was put down at `at`: a pet-bag item moves inside the bag, a
## bag item goes into it (0x7a7780 refuses some items with messages 0x1843
## and UIIT_MSG_COS_CANNOT_BUY_SPECIALTY_TO_INVENTORY; those checks need the
## item's flags and are left to the server here, OURS). True when the drop
## landed on the COS window (taken, whatever it did).
func accept_drop(what: Dictionary, at: Vector2) -> bool:
	if window == null or not window.covers(at):
		return false
	var dst := window.bag_slot_at(at)
	if dst < 0:
		return true
	var qty := maxi(1, int(what.get("qty", 1)))
	match String(what.get("kind", "")):
		"cos_bag":
			var src := int(what.get("slot", -1))
			if int(what.get("uid", 0)) == window.cos_uid and src >= 0 and src != dst:
				bag_move_requested.emit(CosNet.BAG_COS_TO_COS, window.cos_uid, src, dst, qty)
		"bag":
			var from := int(what.get("slot", -1))
			if from >= 0:
				bag_move_requested.emit(CosNet.BAG_BAG_TO_COS, window.cos_uid, from, dst, qty)
	return true

## A pet-bag item was put down on the player's bag: World3D sends it there.
func held_dropped_on_inventory(what: Dictionary) -> bool:
	if String(what.get("kind", "")) != "cos_bag":
		return false
	bag_drag_to_inventory.emit(int(what.get("uid", 0)), int(what.get("slot", -1)))
	return true
