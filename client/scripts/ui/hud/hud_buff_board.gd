extends Control
class_name HudBuffBoard

## The active-buff icons right of the HP bar: retail's CIFMagicStateBoard
## (round 618). Every rule here is read out of sro_client.exe unless it says
## OURS; docs/protocol/magic_state_board.md has the full record with the
## addresses. Labels: READ (the binary), MEASURED (the archives), INFERRED,
## OURS (a choice of this project), OPEN.
##
## PLACEMENT (MEASURED, resinfo\ginterface.txt): GDR_MAGICSTATEBOARD
## (CIFMagicStateBoard, ID 22), Rect 220,10,160,40 -- right of
## GDR_PLAYER_MINI_INFO (4,7,212,70). setup() reads the rect from the
## registry, as HudPlayerInfo reads its own; the board then sizes itself to
## 184 x (rows1 + rows2) * 27 (READ, 0x7ffc10).
##
## LAYOUT (READ, 0x7ffc10). Two lists. Icon i of the main list sits at
## ((i % 8) * 23, (i / 8) * 27); the second list -- a skill with `bbuf`
## (READ: the add 0x8048c0 routes it there when its param_4 is 0, and the
## 0xB0BD handler passes 0, asm 0x8a5cbc..0x8a5cc6) -- starts below the main
## list's rows plus 2 px. A list counts as at least one row even when empty.
## Entries are appended in arrival order (0x803ec0 inserts before the head
## sentinel). No cap.
##
## A SLOT (READ, 0x803cd0 / 0x806d50): the 20x20 icon, and under it a 20x4
## CIFGauge at (0, 20) whose fill is icon\stateodd\s_stateodd_time_gauge.ddj
## drawn over the back icon\stateodd\s_stateodd_time.ddj (both 20x4,
## MEASURED). The gauge is shown only when the buff has a duration (asm
## 0x7ffd35..0x7ffd51: ShowWindow(total != -1)); an untimed buff's gauge is
## written 1.0 but stays hidden. CIFGauge draws the back whole and the fill
## cut at the value (0x6387d0 / 0x653140 scale the right edge's position and
## texture coordinate together -- INFERRED from the two products), which is
## TextureProgressBar's left-to-right fill.
##
## THE EXPIRY GAUGE (READ, 0x8056a0, per frame): elapsed += the frame's ms,
## clamped at total; value = (total - elapsed) / total. So it drains from
## full to empty. No blink, threshold or colour change exists anywhere in the
## three classes (the spec's negative over every virtual).
##
## THE END (READ, 0x804b30 -> 0x8068f0 -> 0x8065d0, and CIFStateSlot's timer
## 0x806790). A main-list buff that ends shows a 50x52 overlay centred on the
## icon ((20-50)>>1, (20-52)>>1) = (-15, -16), cut from icon\buf_effect.ddj
## (512x64, MEASURED) at frame i = (50i, 0, 50, 52); hides its gauges; and
## ticks every 100 ms: each tick advances the frame, after tick 3 the icon's
## alpha drops 0x55 a tick (to 0 once below 0x56), and at tick 9 the slot is
## removed and the grid laid out again. prim\snd\ui\buf_disappear.wav plays
## at volume 1.0 when the end starts. A SECOND-list buff that ends is removed
## at once, with no burst and no sound (0x804c60: that loop erases and lays
## out, nothing else). INFERRED: the fade is the icon's own (the slot's +0x84
## render object); the burst is a child window with its own and is not faded.
##
## RIGHT-CLICK (READ, CIFMagicStateBoard::vslot_033 0x800820, the button-up):
## at the RELEASE point, the main list's slots are hit-tested (0xb8f3d0 per
## slot) -- a slot is 20x24, the icon and its gauge (0x806d50 sizes it
## w x (20 + 4)); the second list is not tested; a slot already ending does
## nothing; a skill with `nbuf` and no `lnks` does nothing; with `cbuf` a
## 308x148 confirmation box opens instead (0x6ec5d0, box type 0x20);
## otherwise the cancel is sent (0x81c5b0; here NetClient.send_buff_cancel,
## the contract's OpBuffCancel 0x00F7). Retail also requires 0x93f5d0(skill)
## to be non-null on both paths, and, on the SEND path only, its first dword
## not to be 0xc0000000 -- what that lookup is, is OPEN, and it is not
## modelled.
##
## THE TOOLTIP (READ, 0x800a10, kind 1): "%s %s %d" -- the skill's name,
## UIIT_STT_LEVEL_LV, its level; the description; and, for a timed buff,
## the remaining time: under 60 s "%s %d%s" (UIIT_STT_REMAIN_TIME, seconds,
## PARAM_SECOND), under an hour "%s %d%s %d%s" (minutes PARAM_MINUTE,
## seconds PARAM_SECOND), otherwise "%s: %d%s %d%s %d%s" (days PARAM_DAY,
## hours PARAM_HOUR, minutes PARAM_MINUTE). Every word is the client's own
## textuisystem.txt text. The red "(UIIT_TOOLTIP_OPERATION_STOP)" line (slot
## +0x36c), the admittance sprites that go with it (icon\stateodd\
## s_admittance_back.ddj / s_admittance_icon.ddj, loaded for a skill slot by
## 0x806d50 and drawn by 0x8071c0 while +0x36c is set) and the
## "UIIT_STT_TARGETTING : %s" line are not drawn: what sets either is OPEN.

const REGISTRY_NAME := "GDR_MAGICSTATEBOARD"
## GDR_MAGICSTATEBOARD's own rect origin (MEASURED), used only when the
## registry cannot be read.
const FALLBACK_POSITION := Vector2(220, 10)

const ICON_SIZE := Vector2(20, 20)

## AUTHENTIC ICONS (round 624): the icon as retail's screen shows it -- the
## skill window's own 32x32 file (skilldata col 61 under `icon\`, the same
## skill-row string +0x108 that IFSkillSlot 0x6a15f0 and the quick slot
## 0x6809a0 load; this slot's is set by 0x7ff240 -> 0x8068a0), point-sampled
## down to 20x20 once, then drawn with nearest filtering at any UI scale.
## false draws the 32x32 file scaled with the canvas's linear filter, which is
## what rounds 618-623 did. A static var, so a future "high-res icons" setting
## can flip it; icons already built keep their look until rebuilt.
##
## MEASURED, the file: every one of Media.pk2's 622 `icon\skill\` files is
## 32x32 -- 441 A8R8G8B8 and 4 more A8R8G8B8 carrying 6 mips (pixel-format
## flags 0x41, masks, not a FourCC), 4 X8R8G8B8, 159 A1R5G5B5, 2 A4R4G4B4,
## 12 DXT3 with 6 mips; all decode. There is no small or `_s` twin;
## `icon\stateodd\` holds only the gauges, 24 abnormal-state icons (32x32)
## and four 20x20 sprites.
## READ, the draw: the icon is a CIFStatic (class 0xee9720) 20x20 child;
## CIFWnd's sprite draw (0x655d50 -> 0x654c30) sets FVF 0x104 and the
## texture and draws a fan, setting NO sampler state. Its quad is the window
## rect minus 0.5 on each edge (0x6529d0, the double 0.5 at 0xe1b7d0), with
## UVs 0..1 (the base window ctor, 0x654661..0x6546bf), so pixel k of 20
## samples u = (k + 0.5) / 20 -- texel floor((2k+1)*32/40). The UI pass sets
## MIPFILTER NONE and CLAMP (0x8408c0), and the DDJ loader keeps the file's
## own mip count (0xb87f20), so mips never apply.
## READ, the filter the sprite inherits (round 624's review): the board draws
## right after GDR_PLAYER_MINI_INFO's subtree (a window's children draw in
## reverse file order: 0xb3e4d0 prepends, 0xb90a80 appends), whose TXT_ID /
## LEVEL / HP / MP labels draw through 0x8b48b0 -> 0x8b2290. That sets MIN
## and MAG to POINT at text scale 1.0 (0x8b46d0 writes 1.0; |s - 1| <= 0.1
## at 0x8b2447) and nothing puts them back before the icon. The full
## setter table and the four residual assumptions are in
## docs/protocol/magic_state_board.md.
## OURS: nearest filtering of the 20x20 result when the UI scale is not 1
## (retail draws its UI 1:1 and has no scale).
static var AUTHENTIC_ICONS := true

const GAUGE_RECT := Rect2(0, 20, 20, 4)
## The slot window: the icon plus the gauge under it (0x806d50's vslot 0x54
## call, w x (h + gauge h)) -- the right-click hit rect.
const SLOT_SIZE := Vector2(20, 24)
const COLUMNS := 8
const COLUMN_PITCH := 23
const ROW_PITCH := 27
const SECOND_LIST_GAP := 2
const BOARD_WIDTH := 184

const GAUGE_FILL := "icon\\stateodd\\s_stateodd_time_gauge.ddj"
const GAUGE_BACK := "icon\\stateodd\\s_stateodd_time.ddj"

const BURST_TEXTURE := "icon\\buf_effect.ddj"
const BURST_FRAME_SIZE := Vector2(50, 52)
const BURST_OFFSET := Vector2(-15, -16)
const BURST_TICK_MS := 100
const BURST_TICKS := 9
const BURST_FADE_AFTER := 3
const BURST_FADE_STEP := 0x55
const BURST_FADE_FLOOR := 0x56
const DISAPPEAR_SOUND := "prim\\snd\\ui\\buf_disappear.wav"

const CONFIRM_SIZE := Vector2(308, 148)
const CONFIRM_NAME := "BuffCancelConfirm"

## What a right-click does (right_click_action).
const ACTION_NONE := "none"
const ACTION_CONFIRM := "confirm"
const ACTION_CANCEL := "cancel"

## Retail's name-only tooltip titles (READ, 0x800a10: the name code is
## compared with each of these, full length, before "%s %s %d" is printed).
const NAME_ONLY_CODES := [
	"SN_SKILL_MALL_PRE_APRU_4W", "SN_SKILL_ASSAULTING_SOILDER",
	"SN_SKILL_ELITE_ASSAULTING_SOILDER", "SN_SKILL_CENTURION",
	"SN_SKILL_ASSAULTING_LEADER", "SN_SKILL_ELITE_IMPERIAL_GUARD",
	"SN_SKILL_COMBAT_COMMANDER", "SN_SKILL_MALL_PET_GROWTH_POTION",
	"SN_SKILL_MALL_PET_SKILL_COLD", "SN_SKILL_MALL_PET_SKILL_FIRE",
	"SN_SKILL_MALL_PET_SKILL_LIGHTNING", "SN_SKILL_MALL_PET_WATCH_CHULHYEN",
	"SN_SKILL_MALL_PET_WATCH_AGOL",
]

## A right-click asked for a cancel (after the confirm box, for a `cbuf`).
signal cancel_requested(skill_id: int, token: int)

## One icon on the board.
class Buff:
	var owner_id: int
	var skill_id: int
	var token: int
	## -1: no duration (the gauge stays hidden).
	var total_ms: int
	var elapsed_ms: float
	var main_list: bool
	var info: Dictionary
	var slot: BuffSlot
	var ending := false
	var tick := 0
	var alpha := 0xFF
	var tick_accum_ms := 0.0

	## (total - elapsed) / total; 1.0 without a duration (0x8056a0).
	func gauge_value() -> float:
		if total_ms < 0:
			return 1.0
		if total_ms == 0:
			return 0.0
		return clampf((float(total_ms) - elapsed_ms) / float(total_ms), 0.0, 1.0)

	func remaining_ms() -> int:
		return maxi(0, int(float(total_ms) - elapsed_ms)) if total_ms >= 0 else -1

## A slot's control: the icon, the gauge, the burst; routes its right
## button-up to the board and asks it for the tooltip.
class BuffSlot extends Control:
	var board: HudBuffBoard
	var token: int
	var icon: TextureRect
	var gauge: TextureProgressBar
	var burst: TextureRect

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton:
			var mb := event as InputEventMouseButton
			if mb.button_index == MOUSE_BUTTON_RIGHT:
				accept_event()
				# WM_RBUTTONUP: vslot_033 is the button-up (0x46c8e0's 0x205
				# case), and it hit-tests where the button came UP. Godot
				# hands the release to the slot the press was on, wherever
				# the cursor is now, so the board tests the point.
				if not mb.pressed and board != null:
					board.on_right_release(get_global_transform() * mb.position)

	func _get_tooltip(_at_position: Vector2) -> String:
		return board.tooltip_for(token) if board != null else ""

var _builder: UiBuilder = null
var catalog: SkillBuffCatalog = null
## The buffs in arrival order, one Array per list.
var _main: Array = []
var _second: Array = []
var _by_token: Dictionary = {}
## Buffs that arrived before the catalog's index was ready, oldest first:
## [owner_id, skill_id, token, duration_ms, remaining_ms, waited_ms].
var _pending: Array = []
## Whether (owner_id, owner_kind) is this client's player; World3D supplies
## it (World3D._buff_owner_is_self: a character whose id is the one OpSelfId
## gave). Default: nobody, so an unwired board shows nothing it was not told.
var is_self: Callable = func(_owner_id: int, _owner_kind: int) -> bool: return false
## The node connect_net wired (NetClient), whose send_buff_cancel the
## default sender calls.
var _net: Object = null
## Sends a cancel; tests replace it. Default: NetClient.send_buff_cancel.
var cancel_sender: Callable = Callable()
## Plays the end sound; tests replace it. Default: SoundTable.play_file.
var sound_player: Callable = Callable()
## UI text lookups (tests replace it): token -> text.
var ui_text: Callable = Callable()

var _gauge_fill_tex: Texture2D = null
var _gauge_back_tex: Texture2D = null
var _burst_tex: Texture2D = null
var _textures_loaded := false
var _icon_cache: Dictionary = {}
var _icon_image_cache: Dictionary = {}
var _icon_authentic_cache: Dictionary = {}

func _init(builder: UiBuilder = null, skill_catalog: SkillBuffCatalog = null) -> void:
	_builder = builder
	catalog = skill_catalog
	if catalog == null:
		catalog = SkillBuffCatalog.new(builder.media_archive() if builder != null else null)

func setup() -> void:
	var pos := FALLBACK_POSITION
	if _builder != null:
		var reg := _builder.window_def(REGISTRY_NAME)
		if reg != null:
			pos = Vector2(reg.rect.position)
	position = pos
	# OURS: the board itself lets clicks through; each slot stops its own.
	# Retail's board is a window whose whole rect takes clicks, but an empty
	# row of it over the world would swallow a walk-click there.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layout()

## Connects the NetClient signals when the node has them (round 617 adds
## them; a base without them leaves the board fed by the QA hook only).
func connect_net(net: Object) -> bool:
	if net == null:
		return false
	_net = net
	var wired := false
	if net.has_signal("buff_started"):
		net.connect("buff_started", on_buff_started)
		wired = true
	if net.has_signal("buff_ended"):
		net.connect("buff_ended", on_buff_ended)
	return wired

## Builds the catalog's index now (World3D calls it as the world is built),
## so no buff arrival parses a shard.
func preload_catalog() -> void:
	if catalog != null:
		catalog.preload_index()

## OpBuffStart (round 617's SkillNet.BuffStart): shown when it is this
## player's -- a character (owner_kind 0) whose id is this player's.
func on_buff_started(start: SkillNet.BuffStart) -> void:
	if start == null or not bool(is_self.call(start.owner_id, start.owner_kind)):
		return
	add_buff(start.owner_id, start.skill_id, start.token, start.duration_ms, start.remaining_ms)

## OpBuffEnd: matched by token alone -- a token is unique on the server, and
## only this player's tokens are on the board.
func on_buff_ended(ended: SkillNet.BuffEnd) -> void:
	if ended == null:
		return
	for t in ended.tokens:
		end_buff(int(t))

## World re-entry or a character switch: everything goes at once, no burst,
## no sound -- the buffs belonged to the entry that ended.
func clear() -> void:
	for list in [_main, _second]:
		for entry in list:
			var b: Buff = entry
			if b.slot != null and is_instance_valid(b.slot):
				remove_child(b.slot)
				b.slot.queue_free()
			b.slot = null
	_main.clear()
	_second.clear()
	_by_token.clear()
	_pending.clear()
	_qa_ends.clear()
	var host: Node = get_parent()
	if host != null:
		var box := host.get_node_or_null(CONFIRM_NAME)
		if box != null:
			host.remove_child(box)
			box.queue_free()
	_layout()

## Adds a buff's icon. A zero duration adds none (0x7fda20: a `dura` of 0
## gets no icon -- INFERRED that our durationMs 0 is that case). A token
## already on the board is replaced in place (OURS: retail has no dedupe,
## but the contract's token is unique per application, so a repeat is a
## re-send).
func add_buff(owner_id: int, skill_id: int, token: int, duration_ms: int, remaining_ms: int) -> Buff:
	if duration_ms == 0 or token == 0:
		return null
	if catalog != null and not catalog.is_ready():
		# OURS: the icon waits for the index (a second or two after world
		# entry at most); the wait is taken off the time left when it lands.
		for p in _pending:
			if int(p[2]) == token:
				return null
		_pending.append([owner_id, skill_id, token, duration_ms, remaining_ms, 0.0])
		print("HudBuffBoard: buff %d (skill %d) waits for the skill index" % [token, skill_id])
		return null
	var info: Dictionary = catalog.info(skill_id) if catalog != null else {}
	var b: Buff = _by_token.get(token)
	var fresh := b == null
	if not fresh and b.ending:
		return b # already playing its end; a late re-send does not revive it
	if fresh:
		b = Buff.new()
	b.owner_id = owner_id
	b.skill_id = skill_id
	b.token = token
	b.total_ms = duration_ms if duration_ms > 0 else -1
	# The add's param_6 is the remaining time: elapsed = total - remaining
	# (0x8048c0). The contract sends both.
	b.elapsed_ms = 0.0
	if b.total_ms > 0 and remaining_ms >= 0:
		b.elapsed_ms = float(clampi(b.total_ms - remaining_ms, 0, b.total_ms))
	b.info = info
	if fresh:
		b.main_list = not bool(info.get("bbuf", false))
		(_main if b.main_list else _second).append(b)
		_by_token[token] = b
		b.slot = _make_slot(b)
		add_child(b.slot)
	b.slot.gauge.value = b.gauge_value()
	b.slot.gauge.visible = b.total_ms > 0
	_layout()
	print("HudBuffBoard: buff %d (skill %d, %s, %s list)%s" % [token, skill_id,
		("%d ms" % b.total_ms) if b.total_ms > 0 else "no duration",
		"main" if b.main_list else "second", "" if not info.is_empty() else " -- skill not in the archive"])
	return b

## Ends a buff: the burst and the sound for a main-list one, straight
## removal for a second-list one (0x804b30).
func end_buff(token: int) -> void:
	for i in _pending.size():
		if int(_pending[i][2]) == token:
			_pending.remove_at(i)
			return
	var b: Buff = _by_token.get(token)
	if b == null or b.ending:
		return
	if not b.main_list:
		_remove(b)
		return
	b.ending = true
	b.tick = 0
	b.tick_accum_ms = 0.0
	b.slot.gauge.visible = false
	_show_burst_frame(b)
	b.slot.burst.visible = true
	_play_disappear()
	print("HudBuffBoard: buff %d ended -- burst" % token)

func _process(delta: float) -> void:
	advance(delta * 1000.0)

## One frame of the board's update (0x8056a0) and the slots' 100 ms timers
## (0x806790), `ms` long. Public so a test steps time exactly.
func advance(ms: float) -> void:
	_qa_clock_ms += ms
	if not _qa_ends.is_empty():
		var i := 0
		while i < _qa_ends.size():
			if _qa_clock_ms >= float(_qa_ends[i][1]):
				var token := int(_qa_ends[i][0])
				_qa_ends.remove_at(i)
				end_buff(token)
			else:
				i += 1
	_advance_list(_main, ms)
	_advance_list(_second, ms)
	# Buffs held for the index land after the lists' frame, their whole wait
	# (this frame's included) taken off the time left.
	if not _pending.is_empty():
		for p in _pending:
			p[5] = float(p[5]) + ms
		if catalog == null or catalog.poll():
			var waiting := _pending
			_pending = []
			for p in waiting:
				var left := int(p[4])
				if int(p[3]) > 0 and left >= 0:
					left = maxi(0, left - int(p[5]))
				add_buff(int(p[0]), int(p[1]), int(p[2]), int(p[3]), left)

## One list's frame; a slot whose end finished is removed in the pass.
func _advance_list(list: Array, ms: float) -> void:
	var i := 0
	while i < list.size():
		var b: Buff = list[i]
		if b.total_ms > 0:
			b.elapsed_ms = minf(b.elapsed_ms + ms, float(b.total_ms))
		if b.slot != null and b.slot.gauge != null:
			b.slot.gauge.value = b.gauge_value()
		if b.ending:
			b.tick_accum_ms += ms
			while b.tick_accum_ms >= BURST_TICK_MS and b.tick < BURST_TICKS:
				b.tick_accum_ms -= BURST_TICK_MS
				_burst_tick(b)
			if b.tick >= BURST_TICKS:
				_remove(b)
				continue
		i += 1

## One 100 ms tick of CIFStateSlot::vslot_005.
func _burst_tick(b: Buff) -> void:
	b.tick += 1
	if b.tick >= BURST_TICKS:
		return
	_show_burst_frame(b)
	if b.tick > BURST_FADE_AFTER:
		b.alpha = 0 if b.alpha < BURST_FADE_FLOOR else b.alpha - BURST_FADE_STEP
		b.slot.icon.modulate.a = float(b.alpha) / 255.0

func _show_burst_frame(b: Buff) -> void:
	var at := b.slot.burst.texture as AtlasTexture
	if at != null:
		at.region = Rect2(BURST_FRAME_SIZE.x * b.tick, 0, BURST_FRAME_SIZE.x, BURST_FRAME_SIZE.y)

func _remove(b: Buff) -> void:
	_main.erase(b)
	_second.erase(b)
	_by_token.erase(b.token)
	if b.slot != null and is_instance_valid(b.slot):
		remove_child(b.slot)
		b.slot.queue_free()
	b.slot = null
	_layout()

## What a right-click on the icon with `token` does (vslot_033).
func right_click_action(token: int) -> String:
	var b: Buff = _by_token.get(token)
	if b == null or not b.main_list or b.ending:
		return ACTION_NONE
	if bool(b.info.get("nbuf", false)) and not bool(b.info.get("lnks", false)):
		return ACTION_NONE
	if bool(b.info.get("cbuf", false)):
		return ACTION_CONFIRM
	return ACTION_CANCEL

## A right button-up at `at` (viewport coordinates): the main-list slot whose
## 20x24 rect holds the point takes it, as vslot_033 hit-tests at the
## release; none -- the button came up off every icon -- does nothing.
func on_right_release(at: Vector2) -> void:
	for entry in _main:
		var b: Buff = entry
		if b.slot != null and b.slot.get_global_rect().has_point(at):
			on_slot_right_click(b.token)
			return
	print("HudBuffBoard: right button up at %s, off every icon -- nothing" % str(at))

func on_slot_right_click(token: int) -> void:
	var action := right_click_action(token)
	var b: Buff = _by_token.get(token)
	print("HudBuffBoard: right-click on buff %d (skill %d) -> %s" % [token, b.skill_id if b != null else 0, action])
	match action:
		ACTION_CANCEL:
			_send_cancel(b.skill_id, token)
		ACTION_CONFIRM:
			_open_confirm(b.skill_id, token)

func _send_cancel(skill_id: int, token: int) -> void:
	cancel_requested.emit(skill_id, token)
	if cancel_sender.is_valid():
		cancel_sender.call(skill_id, token)
		return
	var net: Object = _net if _net != null else _net_client()
	if net != null and net.has_method("send_buff_cancel"):
		net.call("send_buff_cancel", skill_id, token)
		print("HudBuffBoard: cancel sent for buff %d (skill %d)" % [token, skill_id])
	else:
		print("HudBuffBoard: no NetClient.send_buff_cancel in this build -- cancel for buff %d not sent" % token)

## The cbuf confirmation (0x6ec5d0: box type 0x20, 308x148, centred). Its
## text is OPEN -- retail passes an empty string (DAT_00e17460) -- so the
## body line is empty. OURS: the box is this client's own confirm style (the
## PanelContainer HudPanels' confirms use), titled with the client's own
## UIIT_STT_CONFIRM_BOX, with OK and Cancel; OK sends the cancel (INFERRED:
## what box type 0x20's OK does was not read).
func _open_confirm(skill_id: int, token: int) -> void:
	var host: Node = get_parent() if get_parent() != null else self
	var old := host.get_node_or_null(CONFIRM_NAME)
	if old != null:
		host.remove_child(old)
		old.queue_free()
	var panel := PanelContainer.new()
	panel.name = CONFIRM_NAME
	panel.custom_minimum_size = CONFIRM_SIZE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.07, 0.08, 0.98)
	style.border_color = Color(0.55, 0.45, 0.22)
	style.set_border_width_all(2)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(12)
	panel.add_theme_stylebox_override("panel", style)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)
	var title := Label.new()
	title.name = "Title"
	title.text = _text("UIIT_STT_CONFIRM_BOX")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	var body := Label.new()
	body.name = "Body"
	body.text = ""
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(body)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(row)
	var ok := Button.new()
	ok.name = "OK"
	ok.text = "OK"
	ok.custom_minimum_size = Vector2(96, 0)
	ok.pressed.connect(func() -> void:
		_send_cancel(skill_id, token)
		panel.queue_free())
	row.add_child(ok)
	var cancel := Button.new()
	cancel.name = "Cancel"
	cancel.text = "Cancel"
	cancel.custom_minimum_size = Vector2(96, 0)
	cancel.pressed.connect(func() -> void: panel.queue_free())
	row.add_child(cancel)
	host.add_child(panel)
	var view := get_viewport_rect().size if is_inside_tree() else Vector2(800, 600)
	panel.position = ((view - CONFIRM_SIZE) * 0.5).round()

## The tooltip text for a buff (0x800a10, kind 1).
func tooltip_for(token: int) -> String:
	var b: Buff = _by_token.get(token)
	if b == null:
		return ""
	var lines := PackedStringArray()
	var code := String(b.info.get("name_code", ""))
	var skill_name: String = catalog.text_of(code) if catalog != null else ""
	if skill_name == "":
		skill_name = code if code != "" else "Skill %d" % b.skill_id
	if code in NAME_ONLY_CODES:
		lines.append(skill_name)
	else:
		lines.append("%s %s %d" % [skill_name, _text("UIIT_STT_LEVEL_LV"), int(b.info.get("level", 0))])
	var desc: String = catalog.text_of(String(b.info.get("desc_code", ""))) if catalog != null else ""
	if desc != "":
		lines.append(desc)
	if b.total_ms >= 0:
		lines.append(remain_line(b.remaining_ms(), _unit_texts()))
	return "\n".join(lines)

func _unit_texts() -> Dictionary:
	return {
		"remain": _text("UIIT_STT_REMAIN_TIME"),
		"day": _text("PARAM_DAY"),
		"hour": _text("PARAM_HOUR"),
		"minute": _text("PARAM_MINUTE"),
		"second": _text("PARAM_SECOND"),
	}

## The remaining-time line (0x800a10, READ). `t` holds the client's own words
## for "remain", "day", "hour", "minute", "second".
static func remain_line(remaining_ms: int, t: Dictionary) -> String:
	var r := maxi(remaining_ms, 0)
	if r < 60000:
		return "%s %d%s" % [t["remain"], r / 1000, t["second"]]
	if r < 3600000:
		return "%s %d%s %d%s" % [t["remain"], r / 60000, t["minute"], (r % 60000) / 1000, t["second"]]
	var in_day := r % 86400000
	return "%s: %d%s %d%s %d%s" % [t["remain"], r / 86400000, t["day"], in_day / 3600000, t["hour"],
		(in_day % 3600000) / 60000, t["minute"]]

func _text(token: String) -> String:
	if ui_text.is_valid():
		return String(ui_text.call(token))
	if _builder != null:
		var s := _builder.resolve_text(token)
		if s != "" and s != token:
			return s
	return token

func _play_disappear() -> void:
	if sound_player.is_valid():
		sound_player.call(DISAPPEAR_SOUND)
		return
	SoundTable.play_file(DISAPPEAR_SOUND)

func _net_client() -> Node:
	var loop := Engine.get_main_loop() as SceneTree
	if loop == null or loop.root == null:
		return null
	return loop.root.get_node_or_null("NetClient")

## Lays both lists out (0x7ffc10) and sizes the board.
func _layout() -> void:
	var rows1 := list_rows(_main.size())
	for i in _main.size():
		var b: Buff = _main[i]
		b.slot.position = slot_position(i, 0)
	for i in _second.size():
		var b: Buff = _second[i]
		b.slot.position = slot_position(i, rows1)
	size = Vector2(BOARD_WIDTH, (rows1 + list_rows(_second.size())) * ROW_PITCH)

## A list's row count as 0x7ffc10 computes it: at least one.
static func list_rows(count: int) -> int:
	return maxi(count - 1, 0) / COLUMNS + 1

## Icon i's position; `rows_above` is 0 for the main list and the main
## list's row count for the second (which also drops 2 px).
static func slot_position(i: int, rows_above: int) -> Vector2:
	var y := (i / COLUMNS + rows_above) * ROW_PITCH
	if rows_above > 0:
		y += SECOND_LIST_GAP
	return Vector2((i % COLUMNS) * COLUMN_PITCH, y)

func _load_textures() -> void:
	if _textures_loaded:
		return
	_textures_loaded = true
	if _builder == null:
		return
	_gauge_fill_tex = _builder.load_texture(GAUGE_FILL)
	_gauge_back_tex = _builder.load_texture(GAUGE_BACK)
	_burst_tex = _builder.load_texture(BURST_TEXTURE)

## The archive path a skill row's icon is read from: col 61 under `icon\`,
## as HudPanels._load_skill_icon builds it for the skill window.
static func icon_path(path: String) -> String:
	if path == "":
		return ""
	return path if path.to_lower().begins_with("icon\\") else "icon\\" + path

## Retail's 20x20 view of an icon (AUTHENTIC_ICONS): point samples at the
## pixel centres the quad's -0.5 edges put them on (0x6529d0), texel
## floor((2k+1) * src / (2 * 20)) in each axis, CLAMP addressing (0x8408c0).
## Integer arithmetic, so the texels on an exact boundary (k = 2, 7, 12, 17
## of a 32-texel side) resolve the way floor does -- INFERRED for the GPU's
## own float interpolation there.
static func retail_icon_image(src: Image, w: int = int(ICON_SIZE.x), h: int = int(ICON_SIZE.y)) -> Image:
	if src == null or src.is_empty():
		return null
	var img := src.duplicate() as Image
	if img.is_compressed():
		img.decompress()
	if img.has_mipmaps():
		img.clear_mipmaps()
	img.convert(Image.FORMAT_RGBA8)
	var sw := img.get_width()
	var sh := img.get_height()
	var out := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		var sy: int = mini(((2 * y + 1) * sh) / (2 * h), sh - 1)
		for x in w:
			var sx: int = mini(((2 * x + 1) * sw) / (2 * w), sw - 1)
			out.set_pixel(x, y, img.get_pixel(sx, sy))
	return out

## Where the authentic path reads an icon's full-size Image; tests replace it.
## Default: UiBuilder.load_image.
var icon_image_source: Callable = Callable()

## The 20x20 Image an icon is drawn from (AUTHENTIC_ICONS), cached per path.
func icon_image(path: String) -> Image:
	var full := icon_path(path)
	if full == "":
		return null
	if not _icon_image_cache.has(full):
		var src: Image = null
		if icon_image_source.is_valid():
			src = icon_image_source.call(full)
		elif _builder != null:
			src = _builder.load_image(full)
		_icon_image_cache[full] = retail_icon_image(src)
	return _icon_image_cache[full]

func _icon_texture(path: String) -> Texture2D:
	var full := icon_path(path)
	if full == "":
		return null
	if AUTHENTIC_ICONS:
		if not _icon_authentic_cache.has(full):
			var img := icon_image(path)
			_icon_authentic_cache[full] = ImageTexture.create_from_image(img) if img != null else null
		return _icon_authentic_cache[full]
	if _builder == null:
		return null
	if not _icon_cache.has(full):
		_icon_cache[full] = _builder.load_texture(full)
	return _icon_cache[full]

func _make_slot(b: Buff) -> BuffSlot:
	_load_textures()
	var slot := BuffSlot.new()
	slot.name = "Buff%d" % b.token
	slot.board = self
	slot.token = b.token
	slot.size = SLOT_SIZE
	slot.custom_minimum_size = SLOT_SIZE
	slot.mouse_filter = Control.MOUSE_FILTER_STOP
	var icon := TextureRect.new()
	icon.name = "Icon"
	icon.texture = _icon_texture(String(b.info.get("icon", "")))
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_SCALE
	icon.size = ICON_SIZE
	if AUTHENTIC_ICONS:
		icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.add_child(icon)
	slot.icon = icon
	var gauge := TextureProgressBar.new()
	gauge.name = "TimeGauge"
	gauge.position = GAUGE_RECT.position
	gauge.size = GAUGE_RECT.size
	gauge.nine_patch_stretch = true
	gauge.texture_under = _gauge_back_tex
	gauge.texture_progress = _gauge_fill_tex
	gauge.fill_mode = TextureProgressBar.FILL_LEFT_TO_RIGHT
	gauge.min_value = 0.0
	gauge.max_value = 1.0
	gauge.step = 0.0
	gauge.value = b.gauge_value()
	gauge.visible = b.total_ms > 0
	gauge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.add_child(gauge)
	slot.gauge = gauge
	var burst := TextureRect.new()
	burst.name = "Burst"
	if _burst_tex != null:
		var at := AtlasTexture.new()
		at.atlas = _burst_tex
		at.region = Rect2(Vector2.ZERO, BURST_FRAME_SIZE)
		burst.texture = at
	burst.position = BURST_OFFSET
	burst.size = BURST_FRAME_SIZE
	burst.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	burst.stretch_mode = TextureRect.STRETCH_SCALE
	burst.mouse_filter = Control.MOUSE_FILTER_IGNORE
	burst.visible = false
	slot.add_child(burst)
	slot.burst = burst
	return slot

## SRREVAMP_QA_BUFFS: "<skill>:<duration ms>[:<ms left>],..." added as the
## server would add them, tokens QA_FIRST_TOKEN up; `ends` ("<i>@<ms>,...")
## ends the i-th that many ms of board time later. Prints one `QA BUFFS` line
## per icon with where it sits on screen, so a run can aim a real click.
const QA_FIRST_TOKEN := 900001
var _qa_ends: Array = []
var _qa_clock_ms := 0.0

func qa_inject(spec: String, ends: String = "") -> void:
	var tokens: Array = []
	for part in spec.split(",", false):
		var f := part.strip_edges().split(":")
		if f.size() < 2 or not f[0].is_valid_int() or not f[1].is_valid_int():
			printerr("QA BUFFS: bad entry '%s' (want skill:ms[:left])" % part)
			continue
		var token: int = QA_FIRST_TOKEN + tokens.size()
		var dur := int(f[1])
		var left := int(f[2]) if f.size() > 2 and f[2].is_valid_int() else dur
		var b := add_buff(-1, int(f[0]), token, dur, left)
		tokens.append(token)
		if b != null:
			var info := b.info
			print("QA BUFFS: token %d skill %d list %s at screen %s size %s icon '%s' cbuf %s nbuf %s bbuf %s lnks %s" % [
				token, b.skill_id, "main" if b.main_list else "second",
				str((b.slot.global_position if b.slot.is_inside_tree() else position + b.slot.position)),
				str(b.slot.size), String(info.get("icon", "")), str(info.get("cbuf", false)),
				str(info.get("nbuf", false)), str(info.get("bbuf", false)), str(info.get("lnks", false))])
	for part in ends.split(",", false):
		var e := part.strip_edges().split("@")
		if e.size() == 2 and e[0].is_valid_int() and e[1].is_valid_int() and int(e[0]) < tokens.size():
			_qa_ends.append([tokens[int(e[0])], _qa_clock_ms + float(e[1])])

## Test and QA read-outs.
func buff_count(main_list: bool = true) -> int:
	return (_main if main_list else _second).size()

func buff(token: int) -> Buff:
	return _by_token.get(token)
