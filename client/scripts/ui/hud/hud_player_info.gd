extends Control
class_name HudPlayerInfo

## The top-left block: portrait, name, level, and the HP and MP bars.
##
## Unlike the panel windows, this one *is* in the client's window registry:
## `GDR_PLAYER_MINI_INFO` in resinfo\ginterface.txt gives it
## `interface\ifcommon\window_all.ddj` and the rect `4,7,212,70`. Its 53
## child controls come from resinfo\ifplayerminiinfo.txt, of which the ones
## that matter here are GDR_PMI_PICTURE, GDR_PMI_TXT_ID, GDR_PMI_TXT_LEVEL,
## and the HP/MP gauge and text pairs. Since round 629 it also drives the
## berserk orbs with their ready circle and flames, the expandable stat
## panel (GDR_PMI_BTN_CINFO toggling GDR_PMI_STA_CINFOBG and the
## GDR_PMI_TXT_* rows), the race emblem and the stat-point "+" -- each from
## the client's own code; see the sections at the end of this file.
##
## **window_all.ddj is a 1024x512 atlas**, and the registry entry's own
## `UV_LT`/`UV_RB` name this window's slice of it: `0.723633,0` to
## `0.930664,0.136719`, which is atlas pixels (741,0)-(953,70) -- exactly
## the 212x70 the rect declares. That slice is the SRO player block: a
## circular portrait socket on the left and two horizontal bar slots for HP
## and MP on the right.
##
## An earlier version of this file said those UV fields were always
## `0,0`-`1,1` and so the background could not be placed. That was read off
## three layout files; across the 229 real `resinfo` layouts there are 18
## distinct `UV_LT` values.

const UiBuilder = preload("res://scripts/ui/ui_builder.gd")
const UiLayoutParser = preload("res://scripts/ui/ui_layout_parser.gd")

const LAYOUT_PATH := "resinfo\\ifplayerminiinfo.txt"
const REGISTRY_NAME := "GDR_PLAYER_MINI_INFO"

## Fallback size, used only if the registry can't be read. From
## GDR_PLAYER_MINI_INFO's own rect.
const SIZE_WIDTH := 212
const SIZE_HEIGHT := 70

## The only controls from ifplayerminiinfo.txt drawn as part of the
## always-on block. Everything else in that layout belongs to the character
## panel or to decorations this project does not drive yet.
const SHOWN_CONTROLS := [
	"GDR_PMI_PICTURE",
	"GDR_PMI_TXT_ID",
	"GDR_PMI_TXT_LEVEL",
	"GDR_PMI_GAUGE_HP",
	"GDR_PMI_GAUGE_MP",
	"GDR_PMI_TXT_HP",
	"GDR_PMI_TXT_MP",
]

## The five berserk orbs, GDR_PMI_CIRCLE0..4 in layout order (CIRCLE0 is the
## top one at 7,13, CIRCLE4 the bottom one at 31,60). Kept for the QA log.
var _berserk_orbs: Array = []

## A click on the ready circle, GDR_PMI_BTN_JAHWAN (id 13). READ: the
## mini-info message map (initialised at 0x00d71d40, entries 0x28 bytes from
## 0x00ebf1e8) routes message 1 for control ids 13..13 to 0x007b4f00, which
## jumps to 0x00778ac0: `if (player+0x886 >= 5) FUN_0081e690(1)` -- the
## same activation the berserk key runs. World3D sends it through that path.
signal berserk_pressed
## A click on GDR_PMI_BTN_STATUP (id 34, com_plus_button.ddj). READ: the
## same map sends id 34 to 0x007b4c10, which shows the main popup and selects
## its character page (FUN_006a1f70(0x4b)). World3D opens the character
## window.
signal stat_up_pressed
## The stat panel was opened or closed by its button (GDR_PMI_BTN_CINFO).
## World3D asks the server for fresh stats when it opens.
signal stat_panel_toggled(open: bool)

## A left press on the block (round 622's review): retail's
## CIFPlayerMiniInfo::vslot_030 -- the WM_LBUTTONDOWN slot of the window
## dispatcher (0x46c8e0, message 0x201 -> vtable +0x78) -- calls
## FUN_00780ee0(own id), which selects the player itself. World3D selects
## this player on it.
signal self_pressed

var _builder: UiBuilder
var _name_label: Label
var _level_label: Label
var _hp_gauge: TextureProgressBar
var _mp_gauge: TextureProgressBar
var _hp_text: Label
var _mp_text: Label

func _init(builder: UiBuilder = null) -> void:
	_builder = builder

func _gui_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
		self_pressed.emit()

func setup() -> void:
	var panel_size := Vector2(SIZE_WIDTH, SIZE_HEIGHT)
	if _builder != null:
		var reg := _builder.window_def(REGISTRY_NAME)
		if reg != null and reg.rect.size.x > 0:
			panel_size = Vector2(reg.rect.size)
	custom_minimum_size = panel_size
	size = panel_size
	# The block consumes the clicks on it (round 529). Its rect is the frame's
	# own (the Frame below is placed at 0,0 with this size), so STOP here
	# blocks exactly the drawn block. It was IGNORE, as are its frame and the
	# layout root, and GDR_PMI_PICTURE -- a CIFStaticWithPictureClip with no
	# art (ifplayerminiinfo.txt as dumped in round 529, docs/RE_COMPLETION.md)
	# -- is built PASS, which bubbles up through IGNORE ancestors. So a click
	# on the block reached World3D._unhandled_input (measured by round 522's
	# re-review), which treats it as a click on the world: it walks the
	# character and takes the keyboard back from a focused text line. STOP, as
	# HudWindow uses (its comment has the reasoning): Godot 4.2 hit-tests the
	# deepest control first, so a child that wants a click still gets it, and
	# a PASS child's click stops here instead of reaching the world. A middle
	# press on it fires the first quickslot through the hotbar's relay
	# (HudUnderbar.relay_middle_button, which World3D connects; round 531).
	mouse_filter = Control.MOUSE_FILTER_STOP

	if _builder == null:
		return

	# The frame, from the registry's own atlas slice, behind everything.
	var reg_def := _builder.window_def(REGISTRY_NAME)
	if reg_def != null and reg_def.ddj != "":
		var frame := TextureRect.new()
		frame.name = "Frame"
		frame.texture = _builder.load_texture_region(reg_def.ddj, reg_def.uv_lt, reg_def.uv_rb)
		frame.position = Vector2.ZERO
		frame.size = panel_size
		frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		frame.stretch_mode = TextureRect.STRETCH_SCALE
		frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(frame)

	var layout := _builder.load_layout(LAYOUT_PATH)
	if layout == null:
		return
	var root := _builder.build_section(layout, "Create")
	if root == null:
		return
	add_child(root)
	UiBuilder.settle_authored_rects(root)

	# Show only the always-on block, and hide everything else the layout
	# carries. That file is 53 controls: the expandable character panel
	# (GDR_PMI_STA_CINFOBG plus every GDR_PMI_TXT_*DAT stat row), the
	# Hwan/jahwan level decorations and their glow, the pet strip, the
	# selection highlight and the PK/fortress status icons. Rendered
	# together they are a pile of overlapping artwork sitting on top of the
	# world -- which is exactly what the first render of this panel showed.
	#
	# An allow-list rather than a deny-list, so a control nobody has
	# accounted for stays hidden instead of appearing unannounced.
	for child in root.get_children():
		if child is CanvasItem:
			(child as CanvasItem).visible = child.name in SHOWN_CONTROLS

	_name_label = root.find_child("GDR_PMI_TXT_ID", true, false) as Label
	_level_label = root.find_child("GDR_PMI_TXT_LEVEL", true, false) as Label
	_hp_text = root.find_child("GDR_PMI_TXT_HP", true, false) as Label
	_mp_text = root.find_child("GDR_PMI_TXT_MP", true, false) as Label
	_hp_gauge = root.find_child("GDR_PMI_GAUGE_HP", true, false) as TextureProgressBar
	_mp_gauge = root.find_child("GDR_PMI_GAUGE_MP", true, false) as TextureProgressBar
	# The client's own bar fills, not a colour of ours. See GAUGE_FILL_HP.
	_set_gauge_fill(_hp_gauge, GAUGE_FILL_HP)
	_set_gauge_fill(_mp_gauge, GAUGE_FILL_MP)

	_setup_hwan(root)
	_setup_cinfo(root)
	_setup_race_and_statup(root)

## Fills a gauge with the client's own bar artwork.
##
## `GDR_PMI_GAUGE_HP` and `_MP` name no `DDJ`; the client sets their art
## itself. READ (round 629): CIFPlayerMiniInfo::Create (0x007b5600) takes
## control 0 (GDR_PMI_GAUGE_HP) into +0x394 and control 1 (_MP) into +0x398,
## then hands each a path through the control's set-texture slot (+0x34 of
## the interface at +0x84, the slot 0x007b5f40 also uses to swap the orbs'
## art): `interface\playerminiinfo\pmi_hp.ddj` at 0x007b589a and
## `interface\playerminiinfo\pmi_mp.ddj` at 0x007b58d1. Both are 124x12,
## the gauges' own authored size. An earlier version loaded
## `ifcommon\quick_hp.ddj` / `quick_mp.ddj`, 4x4 swatches found by
## searching the archive, not by reading this code.
const GAUGE_FILL_HP := "interface\\playerminiinfo\\pmi_hp.ddj"
const GAUGE_FILL_MP := "interface\\playerminiinfo\\pmi_mp.ddj"

func _set_gauge_fill(gauge: TextureProgressBar, texture_path: String) -> void:
	if gauge == null:
		return
	gauge.min_value = 0
	gauge.max_value = 100
	gauge.value = 100
	gauge.nine_patch_stretch = true
	if _builder != null:
		var fill := _builder.load_texture(texture_path)
		if fill != null:
			gauge.texture_progress = fill
			gauge.tint_progress = Color.WHITE

func set_character(character_name: String, level: int) -> void:
	if _name_label != null:
		_name_label.text = character_name
	if _level_label != null:
		_level_label.text = "Lv %d" % level

func set_hp(current: int, maximum: int) -> void:
	_set_bar(_hp_gauge, _hp_text, current, maximum)

## Draws the MP bar full with no readout.
##
## Nothing on the server tracks MP yet, so there is no number to show. An
## empty bar reads as a real state ("you are out of mana") and a made-up
## number reads as live data -- this used to print "1 / 1" over the bar,
## which looked exactly like a real value. Full and silent is the honest
## shape until the server has one. See docs/UI_TODO.md.
func set_mp_unknown() -> void:
	if _mp_gauge != null:
		_mp_gauge.value = _mp_gauge.max_value
	if _mp_text != null:
		_mp_text.text = ""

func set_mp(current: int, maximum: int) -> void:
	_set_bar(_mp_gauge, _mp_text, current, maximum)

func _set_bar(gauge: TextureProgressBar, label: Label, current: int, maximum: int) -> void:
	if maximum <= 0:
		return
	if gauge != null:
		gauge.value = clampf(float(current) / float(maximum) * 100.0, 0.0, 100.0)
	if label != null:
		label.text = "%d / %d" % [current, maximum]

# ---------------------------------------------------------------------------
# The berserk (Hwan) gauge, round 629.
#
# READ from CIFPlayerMiniInfo (docs/protocol/player_mini_info.md has the full
# account with addresses):
#
#   * The gauge is a COUNT, player+0x886 (_CHAR.RemainHwanCount), 0..5. The
#     refresh FUN_007b4f40(0) walks the circles from +0x3b0 (CIRCLE4, the
#     BOTTOM one) up to +0x3a0 (CIRCLE0, the top), showing one per charge
#     and HIDING the rest -- so the orbs fill from the bottom up, and an
#     empty socket shows the frame's own dark socket, not a dimmed orb.
#   * GDR_PMI_BTN_JAHWAN (the big circle above the orbs, pmi_jahwan_button
#     .ddj) is shown exactly when the count is 5 -- "ready".
#   * Activation, FUN_007b4f40(1): the ready circle hides; the five
#     GDR_PMI_DECO_HWAN_SLOT0..4 show pmi_jahwan_burn.ddj -- 16x28 frames,
#     12 of them (FUN_00633b90(16,28), FUN_00633970(12)), each started on a
#     random frame (rand() % 12) and faded in 0 -> 255 over 1.0 s; timer 1
#     advances every flame one frame each 50 ms (0x32, vslot_005 case 1);
#     GDR_PMI_HWAN_EFF_FACE and _GLOW show and fade in over 3.0 s (the float
#     at 0x00d8adc4).
#   * While berserk, timer 2 fires every duration/5 and fades one orb and
#     its flame out over 1.0 s, CIRCLE0/SLOT0 (the top) first. After the
#     fifth everything hides, the face and glow fade out over 3.0 s, and
#     both timers stop. The period is fixed when the display starts:
#     ROUND((stones + player+0x20f8 + 60.0) * 1000.0 / 5.0) ms (0x007b4f40;
#     60.0 the double at 0x00d880d8, 1000.0 at 0x00d83268, 5.0 at
#     0x00d81950). player+0x20f8 is the Energy of life scroll's duration
#     bonus: FUN_0089a0d0 stores the value of a timed job whose FourCC is
#     0x706874 there (FUN_009d4e00) while the job has time left, and
#     FUN_0089a1a0 clears it when that job ends. srrevamp's server sends the
#     same bonus in its composite state (CompositeNet.State.bonus_seconds,
#     set_hwan_time_bonus), the seconds its own berserk adds to param 60.
#     "stones" is FUN_006ac0a0: +0x19c of each worn item's
#     SKILL_ITEM_ETC_SOCKET_STONE_HWAN_E_01..03 socket -- OPEN, 0 here:
#     srrevamp has no socket stones.
#   * The refresh FUN_007b4f40(0) (the count arriving without a start)
#     leaves both timers, the face and the glow alone: a running drain
#     goes on and fades orb k on its next step whatever the refresh lit.
#   * FUN_007b5300 stops the drain (timer 2, not the flames' timer 1): while
#     the drain runs, every SHOWN orb fades 255 -> 0 over 1.0 s with its
#     flame, and the face and the glow fade over 3.0 s -- each only if its
#     alpha is exactly 255 (`+0x12d == -1`). Retail runs it on the player's
#     death and on a zone reset (reset_hwan_display). The server's
#     body-mode end (0x30BF kind 4 value 0) does not touch it.
#
# The base 60 s agrees with the server's own berserk.Duration (60 s,
# recovered from the server binary independently). The Hwan-level art swap
# (FUN_007b5f40, pmi_jahwan_02*.ddj when the byte at player+0x764 is not 0;
# INFERRED to be _CHAR.HwanLevel, as its setter 0x009ca930 builds the Hwan
# title through the hwanleveldata table) is not driven: this server has no
# Hwan level. The blue orbs of a high-level European screenshot are that
# art, not the race.
# ---------------------------------------------------------------------------

const BERSERK_ORBS := 5
## The wire scale of the server's gauge (internal/berserk: Gauge = charges *
## Max/Orbs). set_berserk takes that scale; the display works in charges.
const BERSERK_MAX := 100

const HWAN_BURN_DDJ := "interface\\playerminiinfo\\pmi_jahwan_burn.ddj"
const HWAN_BURN_FRAME := Vector2i(16, 28)
const HWAN_BURN_FRAMES := 12
const HWAN_BURN_FRAME_SEC := 0.05
const HWAN_ORB_FADE_SEC := 1.0
const HWAN_FACE_FADE_SEC := 3.0
## READ base of the client's display duration (0x007b4f40: `+ 60.0`, the
## double at 0x00d880d8); the header has the whole period.
const HWAN_DISPLAY_BASE_SEC := 60.0
## The Hwan socket stones' bonus (FUN_006ac0a0). OPEN: srrevamp has no
## socket stones, so it is 0.
const HWAN_SOCKET_STONE_SEC := 0

var _circles: Array = []   # CIRCLE0..4 (top..bottom)
var _burns: Array = []     # DECO_HWAN_SLOT0..4, each a TextureRect over an AtlasTexture
var _burn_frame: Array = []
var _btn_jahwan: BaseButton
var _hwan_face: CanvasItem
var _hwan_glow: CanvasItem
var _hwan_charges := 0
var _hwan_known := false
var _hwan_active := false
var _hwan_drained := 0
var _burn_clock := 0.0
var _drain_clock := 0.0
## Timer 1 (the flames' frames) runs apart from timer 2 (_hwan_active, the
## drain): FUN_007b5300 stops only the drain, the fifth drain step both.
var _burn_running := false
## player+0x20f8, the scroll's duration bonus in seconds, and the tick it
## stops counting at (the job's end; set_hwan_time_bonus).
var _hwan_time_bonus := 0
var _hwan_time_bonus_until_ms := 0
## Timer 2's period, fixed when the display starts (drain_period_seconds).
var _drain_period := HWAN_DISPLAY_BASE_SEC / float(BERSERK_ORBS)

func _setup_hwan(root: Control) -> void:
	_circles.clear()
	_burns.clear()
	_burn_frame.clear()
	for i in range(BERSERK_ORBS):
		var orb := root.find_child("GDR_PMI_CIRCLE%d" % i, true, false) as CanvasItem
		if orb != null:
			_circles.append(orb)
	_berserk_orbs = _circles
	var burn_tex := _builder.load_texture(HWAN_BURN_DDJ) if _builder != null else null
	for i in range(BERSERK_ORBS):
		var slot := root.find_child("GDR_PMI_DECO_HWAN_SLOT%d" % i, true, false) as Control
		if slot == null:
			continue
		var rect := slot as TextureRect
		if rect == null:
			rect = TextureRect.new()
			rect.name = "Flame"
			rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
			rect.set_anchors_preset(Control.PRESET_FULL_RECT)
			slot.add_child(rect)
		rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		rect.stretch_mode = TextureRect.STRETCH_SCALE
		if burn_tex != null:
			var atlas := AtlasTexture.new()
			atlas.atlas = burn_tex
			rect.texture = atlas
		_burns.append(slot)
		_burn_frame.append(0)
		slot.visible = false
	_btn_jahwan = root.find_child("GDR_PMI_BTN_JAHWAN", true, false) as BaseButton
	if _btn_jahwan != null:
		_btn_jahwan.mouse_filter = Control.MOUSE_FILTER_STOP
		_btn_jahwan.pressed.connect(func() -> void: berserk_pressed.emit())
	_hwan_face = root.find_child("GDR_PMI_HWAN_EFF_FACE", true, false) as CanvasItem
	_hwan_glow = root.find_child("GDR_PMI_HWAN_EFF_GLOW", true, false) as CanvasItem
	for fx in [_hwan_face, _hwan_glow]:
		if fx != null:
			fx.visible = false
			(fx as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hwan_active = false
	_refresh_hwan()

## Which circles (by CIRCLE index, 0 = top) show for `charges`: READ from
## FUN_007b4f40(0), which lights from CIRCLE4 upwards.
static func lit_circles(charges: int) -> Array:
	var out := []
	var left := clampi(charges, 0, BERSERK_ORBS)
	var i := BERSERK_ORBS - 1
	while i >= 0 and left > 0:
		out.append(i)
		left -= 1
		i -= 1
	out.sort()
	return out

## The server's gauge (0..BERSERK_MAX, a multiple of Max/Orbs) as a count.
static func charges_for_gauge(gauge: int) -> int:
	@warning_ignore("integer_division")
	var per: int = BERSERK_MAX / BERSERK_ORBS
	@warning_ignore("integer_division")
	return clampi(gauge / per, 0, BERSERK_ORBS)

## The berserk state from the server: the gauge on its wire scale, and
## whether this message STARTS a berserk (the activation reply, or the body
## mode going to 1). An AttackResult's "active" flag is not a start: it is
## passed as false, since retail's attack packets carry no such flag and the
## display runs on its own timers once started.
func set_berserk(gauge: int, starts: bool) -> void:
	set_hwan(charges_for_gauge(gauge), starts)

## The orb count the stats packet carries (_CHAR.RemainHwanCount).
func set_hwan_count(charges: int) -> void:
	set_hwan(charges, false)

## FUN_00778ae0(count, flag), READ (0x00778ae0): stores the count; with the
## flag set runs the activation FUN_007b4f40(1) -- which itself does nothing
## while timer 2 (the drain) is running -- else, with a count that is not 0,
## the refresh FUN_007b4f40(0); a count of 0 without the flag refreshes
## NOTHING (round 629's review). So a berserk display, once started, is ended
## only by its own drain or by reset_hwan_display (death, zone reset).
func set_hwan(charges: int, starts: bool) -> void:
	_hwan_known = true
	_hwan_charges = clampi(charges, 0, BERSERK_ORBS)
	if starts:
		if not _hwan_active:
			_start_hwan()
	elif _hwan_charges != 0:
		_refresh_hwan()

## player+0x20f8 from the server's composite state: the Energy of life job's
## duration bonus in seconds and how long the job still runs. A bonus of 0,
## or a job with no time left, clears it (FUN_0089a0d0 stores only while the
## job has time left; FUN_0089a1a0 clears it at the job's end).
func set_hwan_time_bonus(seconds: int, seconds_left: int) -> void:
	if seconds <= 0 or seconds_left <= 0:
		_hwan_time_bonus = 0
		_hwan_time_bonus_until_ms = 0
		return
	_hwan_time_bonus = seconds
	_hwan_time_bonus_until_ms = Time.get_ticks_msec() + seconds_left * 1000

## The bonus in force now: 0 once the job's time has run out.
func hwan_time_bonus() -> int:
	if _hwan_time_bonus <= 0 or Time.get_ticks_msec() >= _hwan_time_bonus_until_ms:
		return 0
	return _hwan_time_bonus

## Timer 2's period in seconds for a display started now: READ, 0x007b4f40,
## ROUND((stones + player+0x20f8 + 60.0) * 1000.0 / 5.0) milliseconds.
func drain_period_seconds() -> float:
	var ms := roundi((float(HWAN_SOCKET_STONE_SEC) + float(hwan_time_bonus()) + HWAN_DISPLAY_BASE_SEC) * 1000.0 / float(BERSERK_ORBS))
	return float(ms) / 1000.0

func drain_period() -> float:
	return _drain_period

## Whether the client would ask for berserk: 0x00778ac0 tests the count only
## (player+0x886 >= 5), not whether a display is running.
func hwan_ready() -> bool:
	return _hwan_charges >= BERSERK_ORBS

func hwan_known() -> bool:
	return _hwan_known

func hwan_charges() -> int:
	return _hwan_charges

func hwan_display_active() -> bool:
	return _hwan_active

## FUN_007b4f40(0), READ: the five flames hide (vslot 0x5c ShowWindow(0));
## the ready circle shows exactly at a count of 5; from CIRCLE4 up, each orb
## is set steady at 255 (FUN_006552b0(0xff, 0xff, 0, 0) and the +0x84 alpha
## call with 0xff -- its fade is over) and shown for a charge or hidden. Both
## timers, the face and the glow are left as they are: a running display
## keeps draining (round 629-632 integration; this used to stop it).
func _refresh_hwan() -> void:
	for b in _burns:
		(b as CanvasItem).visible = false
	if _btn_jahwan != null:
		_btn_jahwan.visible = _hwan_charges >= BERSERK_ORBS
	var lit := lit_circles(_hwan_charges)
	for i in range(_circles.size()):
		var orb := _circles[i] as CanvasItem
		_kill_fade(orb)
		orb.modulate = Color.WHITE
		orb.visible = i in lit

## FUN_007b4f40(1).
func _start_hwan() -> void:
	_kill_fades()
	_hwan_active = true
	_burn_running = true
	_drain_period = drain_period_seconds()
	_hwan_drained = 0
	_drain_clock = 0.0
	_burn_clock = 0.0
	if _btn_jahwan != null:
		_btn_jahwan.visible = false
	for orb in _circles:
		(orb as CanvasItem).visible = true
		(orb as CanvasItem).modulate = Color.WHITE
	for i in range(_burns.size()):
		_burn_frame[i] = randi() % HWAN_BURN_FRAMES
		_show_burn_frame(i)
		var b := _burns[i] as CanvasItem
		b.visible = true
		_fade(b, 0.0, 1.0, HWAN_ORB_FADE_SEC)
	for fx in [_hwan_face, _hwan_glow]:
		if fx != null:
			fx.visible = true
			_fade(fx, 0.0, 1.0, HWAN_FACE_FADE_SEC)

## FUN_007b5300, READ: the reset retail runs on the player's death
## (0x8a80a0 kind 0 value 2 -> FUN_0077b000) and on a zone reset
## (FUN_00787860). Only while timer 2 (the drain) runs: for each of the five,
## top to bottom, when the ORB is shown (FUN_00b8f530), the orb and its flame
## fade 255 -> 0 over 1.0 s -- from 255, whatever alpha the orb had; the face
## and the glow each fade 255 -> 0 over 3.0 s only when their alpha is exactly
## 255 (`*(char *)(+0x12d) == -1`), so one still fading in carries on; then
## timer 2 stops. Timer 1 (the flames' frames) keeps running. The count is
## left as it is.
func reset_hwan_display() -> void:
	if not _hwan_active:
		return
	_hwan_active = false
	for i in range(_circles.size()):
		var orb := _circles[i] as CanvasItem
		if orb == null or not orb.visible:
			continue
		_fade(orb, 1.0, 0.0, HWAN_ORB_FADE_SEC, true)
		if i < _burns.size():
			_fade(_burns[i] as CanvasItem, 1.0, 0.0, HWAN_ORB_FADE_SEC, true)
	for fx in [_hwan_face, _hwan_glow]:
		if fx != null and fx.visible and fx.modulate.a >= 1.0 and not _fades.has(fx):
			_fade(fx, 1.0, 0.0, HWAN_FACE_FADE_SEC, true)

func _show_burn_frame(i: int) -> void:
	var slot := _burns[i] as Control
	var rect := slot as TextureRect
	if rect == null:
		rect = slot.get_node_or_null("Flame") as TextureRect
	if rect == null or not (rect.texture is AtlasTexture):
		return
	var atlas := rect.texture as AtlasTexture
	var tex_w: int = atlas.atlas.get_width() if atlas.atlas != null else HWAN_BURN_FRAME.x * 8
	@warning_ignore("integer_division")
	var cols: int = maxi(1, tex_w / HWAN_BURN_FRAME.x)
	var f: int = int(_burn_frame[i])
	@warning_ignore("integer_division")
	atlas.region = Rect2(Vector2((f % cols) * HWAN_BURN_FRAME.x, (f / cols) * HWAN_BURN_FRAME.y), Vector2(HWAN_BURN_FRAME))

## The running fade of each item, so a new fade, a refresh or a new start
## kills the old one first (round 629's review): an old fade-out's hide
## callback must not land on an orb a new berserk has just shown.
var _fades: Dictionary = {}

func _kill_fade(item: CanvasItem) -> void:
	var old = _fades.get(item)
	if old != null and (old as Tween).is_valid():
		(old as Tween).kill()
	_fades.erase(item)

func _kill_fades() -> void:
	for tw in _fades.values():
		if tw != null and (tw as Tween).is_valid():
			(tw as Tween).kill()
	_fades.clear()

func _fade(item: CanvasItem, from: float, to: float, seconds: float, hide_after: bool = false) -> void:
	var old = _fades.get(item)
	if old != null and (old as Tween).is_valid():
		(old as Tween).kill()
	_fades.erase(item)
	item.modulate.a = from
	if not is_inside_tree():
		item.modulate.a = to
		if hide_after:
			item.visible = false
			item.modulate.a = 1.0
		return
	var tw := create_tween()
	_fades[item] = tw
	tw.tween_property(item, "modulate:a", to, seconds)
	tw.tween_callback(func() -> void:
		_fades.erase(item)
		if hide_after:
			item.visible = false
			item.modulate.a = 1.0)

func _process(delta: float) -> void:
	if _burn_running:
		_burn_clock += delta
		while _burn_clock >= HWAN_BURN_FRAME_SEC:
			_burn_clock -= HWAN_BURN_FRAME_SEC
			for i in range(_burns.size()):
				_burn_frame[i] = (int(_burn_frame[i]) + 1) % HWAN_BURN_FRAMES
				_show_burn_frame(i)
	if not _hwan_active:
		return
	_drain_clock += delta
	while _hwan_active and _drain_clock >= _drain_period and _hwan_drained < BERSERK_ORBS:
		_drain_clock -= _drain_period
		_drain_one()

## vslot_005 case 2 (client timer 2): one orb and its flame fade out, the top
## one first; the fifth ends the display and its timers.
func _drain_one() -> void:
	var k := _hwan_drained
	if k < _circles.size():
		_fade(_circles[k] as CanvasItem, 1.0, 0.0, HWAN_ORB_FADE_SEC)
	if k < _burns.size():
		_fade(_burns[k] as CanvasItem, 1.0, 0.0, HWAN_ORB_FADE_SEC)
	_hwan_drained += 1
	if _hwan_drained >= BERSERK_ORBS:
		print("HudPlayerInfo: berserk display ended by its drain (%d steps of %.3f s)" % [BERSERK_ORBS, _drain_period])
		_hwan_active = false
		_burn_running = false
		for item in _circles + _burns:
			var old = _fades.get(item)
			if old != null and (old as Tween).is_valid():
				(old as Tween).kill()
			_fades.erase(item)
			(item as CanvasItem).visible = false
			(item as CanvasItem).modulate.a = 1.0
		for fx in [_hwan_face, _hwan_glow]:
			if fx != null and fx.visible:
				_fade(fx, fx.modulate.a, 0.0, HWAN_FACE_FADE_SEC, true)

# ---------------------------------------------------------------------------
# The stat panel, round 629.
#
# READ: Create takes GDR_PMI_BTN_CINFO (id 20, pmi_button.ddj at 41,56) and
# the twenty panel controls -- GDR_PMI_STA_CINFOBG (id 21, window_all.ddj's
# 135x189 slice) and the ten label/value pairs -- into +0x3cc..+0x420, hides
# the twenty, and gives the button the tooltip
# UIIT_STT_CHARACTER_ABILITY_VIEW_OFF. The message map sends a press of id 20
# to 0x007b4c60, which flips the background's visibility and gives every row
# the background's new state: a plain toggle, open until pressed again.
# vslot_012 (0x007b7c60), run every frame, rewrites the values from the
# character: "%d" Str (+0x87c) and Int (+0x87e); "%d ~ %d" Phy. atk; "%d"
# Phy. def.; "%d ~ %d" Mag. atk; "%d" Mag. def., Hit rate, Parry ratio; and
# the two balances computed right there (balance_percent below).
# ---------------------------------------------------------------------------

const CINFO_BUTTON := "GDR_PMI_BTN_CINFO"
const CINFO_BG := "GDR_PMI_STA_CINFOBG"
const CINFO_ROWS := [
	"GDR_PMI_TXT_STR", "GDR_PMI_TXT_INT", "GDR_PMI_TXT_PHYATT", "GDR_PMI_TXT_PHYDEF",
	"GDR_PMI_TXT_MAGATT", "GDR_PMI_TXT_MAGDEF", "GDR_PMI_TXT_HIT", "GDR_PMI_TXT_PARRY",
	"GDR_PMI_TXT_PHYBAL", "GDR_PMI_TXT_MAGBAL",
	"GDR_PMI_TXT_STRDAT", "GDR_PMI_TXT_INTDAT", "GDR_PMI_TXT_PHYATTDAT", "GDR_PMI_TXT_PHYDEFDAT",
	"GDR_PMI_TXT_MAGATTDAT", "GDR_PMI_TXT_MAGDEFDAT", "GDR_PMI_TXT_HITDAT", "GDR_PMI_TXT_PARRYDAT",
	"GDR_PMI_TXT_PHYBALDAT", "GDR_PMI_TXT_MAGBALDAT",
]
const CINFO_TOOLTIP := "UIIT_STT_CHARACTER_ABILITY_VIEW_OFF"

var _cinfo_nodes: Array = []
var _cinfo_values: Dictionary = {}
var _cinfo_open := false

func _setup_cinfo(root: Control) -> void:
	_cinfo_nodes.clear()
	_cinfo_values.clear()
	var bg := root.find_child(CINFO_BG, true, false) as Control
	if bg != null:
		# OURS: the panel hangs below the block's 212x70 rect, so it takes its
		# own clicks rather than let them walk the character (round 529's
		# reasoning for the block itself).
		bg.mouse_filter = Control.MOUSE_FILTER_STOP
		_cinfo_nodes.append(bg)
	for n in CINFO_ROWS:
		var c := root.find_child(n, true, false) as Control
		if c != null:
			_cinfo_nodes.append(c)
			if n.ends_with("DAT") and c is Label:
				_cinfo_values[n] = c
	var btn := root.find_child(CINFO_BUTTON, true, false) as BaseButton
	if btn != null:
		btn.visible = true
		btn.mouse_filter = Control.MOUSE_FILTER_STOP
		if _builder != null:
			var tip := _builder.resolve_text(CINFO_TOOLTIP)
			if tip != "" and tip != CINFO_TOOLTIP:
				btn.tooltip_text = tip
		btn.pressed.connect(toggle_stat_panel)
	set_stat_panel_open(false)

func toggle_stat_panel() -> void:
	set_stat_panel_open(not _cinfo_open)
	stat_panel_toggled.emit(_cinfo_open)

func set_stat_panel_open(open: bool) -> void:
	_cinfo_open = open
	for c in _cinfo_nodes:
		(c as CanvasItem).visible = open

func is_stat_panel_open() -> bool:
	return _cinfo_open

## Phy./Mag. balance as vslot_012 computes them (READ, 0x007b802c..0x007b81d0):
##
##   phy = ftol( (Str + 2*L + 14) * 100.0 / float32( ((L - 1) * 7.0 + 56.0) * 0.8571428656578064 ) )
##   mag = ftol(  Int * 100.0             /        ( (L + 7) * 5 * 0.8 ) )
##
## each shown as "%d %%" and capped at 120 (`cmp eax,0x78; jge -> 0x78`). L is
## the byte at player+0x20d8 -- the server-sent MaxLevel (READ, round 629's
## review), which FUN_009d4d50 keeps as max(itself, the level at +0x868).
## Checked against a retail screenshot (Str 21, Int 21, Lv 2 -> 72 % and
## 58 %: MEASURED). INFERRED: this server never lowers a level and sends no
## MaxLevel, so the current level stands in for it.
static func balance_percent(stat: int, level: int, magical: bool) -> int:
	var v: float
	if magical:
		v = float(stat) * 100.0 / (float((level + 7) * 5) * 0.8)
	else:
		var den := PackedFloat32Array([(float(level - 1) * 7.0 + 56.0) * 0.8571428656578064])[0]
		v = float(stat + 2 * level + 14) * 100.0 / den
	var pct := int(v)
	return 120 if pct >= 120 else pct

## Fills the panel from the same stats packet the character window reads
## (StatsNet.Stats). Hit rate and Parry ratio are the server's params 11 / 9
## (round 629's review); a server too old to send them leaves them empty.
func set_stats(s: StatsNet.Stats) -> void:
	if s == null or s.error != "":
		return
	if s.has_character_rows:
		_set_value("GDR_PMI_TXT_STRDAT", "%d" % s.str)
		_set_value("GDR_PMI_TXT_INTDAT", "%d" % s.intel)
		_set_value("GDR_PMI_TXT_PHYATTDAT", "%d ~ %d" % [s.phys_attack_min, s.phys_attack])
		_set_value("GDR_PMI_TXT_MAGATTDAT", "%d ~ %d" % [s.mag_attack_min, s.mag_attack_max])
		_set_value("GDR_PMI_TXT_MAGDEFDAT", "%d" % s.mag_defense)
		_set_value("GDR_PMI_TXT_PHYBALDAT", "%d %%" % balance_percent(s.str, s.level, false))
		_set_value("GDR_PMI_TXT_MAGBALDAT", "%d %%" % balance_percent(s.intel, s.level, true))
	_set_value("GDR_PMI_TXT_PHYDEFDAT", "%d" % s.phys_defense)
	# Hit rate / Parry ratio: "%d" of the u16s retail's 0x303D carries; empty
	# from a server too old to send them.
	_set_value("GDR_PMI_TXT_HITDAT", "%d" % s.hit_rate if s.has_rates else "")
	_set_value("GDR_PMI_TXT_PARRYDAT", "%d" % s.parry_rate if s.has_rates else "")
	if _stat_up != null:
		_stat_up.visible = s.has_character_rows and s.stat_points > 0
	if s.has_hwan_count:
		set_hwan_count(s.hwan_count)

func stat_value(control_name: String) -> String:
	var l := _cinfo_values.get(control_name) as Label
	return l.text if l != null else ""

func _set_value(control_name: String, text: String) -> void:
	var l := _cinfo_values.get(control_name) as Label
	if l != null:
		l.text = text

# ---------------------------------------------------------------------------
# The race emblem and the stat-point button, round 629.
#
# READ: the one-time fill 0x007b6fd0 takes GDR_PMI_RACE_MARK (id 15, 53,41,
# 24x24, no DDJ in the layout), shows it, and sets its art from
# FUN_0098caa0(race byte of the character's reference object +0x9c, 0):
# 0 -> interface\ifcommon\com_kindred_china.ddj, 1 -> com_kindred_europe.ddj.
# That byte is _RefObjCommon.Country (0 China / 1 Europe; RE_COMPLETION
# 2026-09-16), characterdata column 14: all 26 CHAR_CH_* rows read 0 and all
# 26 CHAR_EU_* rows 1 (MEASURED, round 629).
# GDR_PMI_BTN_STATUP (id 34) is shown by vslot_012 while the u16 at
# player+0x884 is not 0 -- the unspent stat points, which the server sends in
# 0x304E type 3 (READ, round 629's review). Its blink (FUN_00655ec0(1)) is
# not reproduced: OPEN.
# ---------------------------------------------------------------------------

const RACE_MARK := "GDR_PMI_RACE_MARK"
const RACE_MARK_DDJ := ["interface\\ifcommon\\com_kindred_china.ddj", "interface\\ifcommon\\com_kindred_europe.ddj"]

var _race_mark: TextureRect
var _race_holder: Control
var _stat_up: BaseButton
var _race := -1

func _setup_race_and_statup(root: Control) -> void:
	var mark := root.find_child(RACE_MARK, true, false) as Control
	if mark != null:
		_race_holder = mark
		_race_mark = mark as TextureRect
		if _race_mark == null:
			_race_mark = TextureRect.new()
			_race_mark.name = "Emblem"
			_race_mark.set_anchors_preset(Control.PRESET_FULL_RECT)
			mark.add_child(_race_mark)
		_race_mark.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_race_mark.stretch_mode = TextureRect.STRETCH_SCALE
		_race_mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
		mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
		mark.visible = false
	_stat_up = root.find_child("GDR_PMI_BTN_STATUP", true, false) as BaseButton
	if _stat_up != null:
		_stat_up.visible = false
		_stat_up.mouse_filter = Control.MOUSE_FILTER_STOP
		_stat_up.pressed.connect(func() -> void: stat_up_pressed.emit())
	if _race >= 0:
		set_race(_race)

## The emblem for a Country value (0 China, 1 Europe); any other value shows
## nothing, as FUN_0098caa0 builds an empty path for it.
func set_race(country: int) -> void:
	_race = country
	if _race_mark == null:
		return
	var holder := _race_holder
	if country < 0 or country >= RACE_MARK_DDJ.size():
		holder.visible = false
		return
	var tex := _builder.load_texture(RACE_MARK_DDJ[country]) if _builder != null else null
	_race_mark.texture = tex
	holder.visible = true
	_race_mark.visible = true

func race_mark_path() -> String:
	return RACE_MARK_DDJ[_race] if _race >= 0 and _race < RACE_MARK_DDJ.size() else ""
