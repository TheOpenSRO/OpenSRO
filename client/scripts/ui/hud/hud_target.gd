class_name HudTarget
extends Control

## The target window -- the thing the player has clicked, at the top of the
## screen -- built from the client's own authored layouts instead of a
## hand-placed bar over a stretched frame.
##
## What the archive says (2026-09-19, dumped with tools/dump_layout.gd):
##
## - `resinfo\ginterface.txt` registers `GDR_TARGETWINDOW` (`CIFTargetWindow`)
##   at (442, 10) with a 10x10 rect -- "use the art's own size".
## - `resinfo\iftargetwindowex.txt` is the container: a 16x16
##   `CIFCloseButton` at (176, 9) and one sub-window per target kind, each an
##   atlas piece of `interface\ifcommon\window_all.ddj` drawn at its own size:
##   `GDR_TW_COMMONENEMY` 196x51, `GDR_TW_SPECIALMOBWND` 196x78,
##   `GDR_TW_PLAYERWND` 196x36, `GDR_TW_JOB_PLAYERWND` 196x58. (The older
##   `iftargetwindow.txt` lists the same pieces plus 236-wide twins and a buff
##   viewer; both agree on the common-enemy piece.)
## - `resinfo\iftw_commonenemy.txt` is a normal monster's inside: the gem
##   `GDR_TWCE_GEM` at (8, 5) 20x20, the HP gauge `GDR_TWCE_GAUGE_HPGAUGE`
##   (`CIFGauge`, `interface\targetwindow\tw_hp.ddj`) at (14, 37) 168x4, and
##   the name `GDR_TWCE_TEXT_ID` at (34, 10) 137x12, centred. No level text
##   and no rank icon: a common enemy shows its level only through the gem.
## - `resinfo\iftw_specialmob.txt` adds, on the 78-tall piece, `GDR_TWSM_LEVEL`
##   (10, 56) 30x16, the rank icon `GDR_TWSM_ICON` (65, 54) 16x16 and
##   `GDR_TWSM_TEXT_LEV` (85, 56) 168x12.
##
## What the client binary says (sro_client.exe, Ghidra dump on the RE box):
##
## - `CIFTargetWindow` (`0x00699540`) switches on the target's rarity: 0 is
##   the common-enemy window, the others the special-mob one with the rank
##   icon (`Client_TargetWindow_RankIcon`).
## - The gem and the name colour come together from one classifier,
##   `FUN_007780c0(targetLevel)`: `d = targetLevel - playerLevel`; d < -6 ->
##   `tw_gem_weak2` and 0x87d2ff, d < -3 -> `weak1` and 0xa5e0ce, d <= 0 ->
##   `normal` and white, d in 1..5 -> `strong1` and 0xffb387, d > 5 ->
##   `strong2` and 0xff8787.
## - A gauge (`CNIFGauge::vslot_013` -> `FUN_0046d6f0`) draws its texture
##   clipped from the left: both the drawn width and the texture's U extent
##   are scaled by the ratio, so the art is never squashed. Godot's
##   `TextureProgressBar` in its default left-to-right mode does the same,
##   which is what UiBuilder builds a `CIFGauge` as.
##
## Everything shown is the server's: the name, the level (for the gem), the
## rarity (for which window), HP and max HP. Nothing is computed here but
## the level difference.

signal closed

const REGISTRY_NAME := "GDR_TARGETWINDOW"
const CONTAINER_LAYOUT := "resinfo\\iftargetwindowex.txt"
const COMMON_LAYOUT := "resinfo\\iftw_commonenemy.txt"
const SPECIAL_LAYOUT := "resinfo\\iftw_specialmob.txt"
const GEM_DIR := "interface\\targetwindow\\"

## Level-difference classes, from FUN_007780c0: gem art and name colour.
## Index = class 0..4 (weak2, weak1, normal, strong1, strong2).
const GEM_BY_CLASS := ["tw_gem_weak2.ddj", "tw_gem_weak1.ddj", "tw_gem_normal.ddj",
	"tw_gem_strong1.ddj", "tw_gem_strong2.ddj"]
const COLOUR_BY_CLASS := [Color8(0x87, 0xd2, 0xff), Color8(0xa5, 0xe0, 0xce), Color.WHITE,
	Color8(0xff, 0xb3, 0x87), Color8(0xff, 0x87, 0x87)]

var _builder: UiBuilder
## The player's own level, for the gem. 0 until the stats packet arrives; the
## gem and colour are then left at the neutral class rather than guessed.
var _player_level := 0

## One built window per kind, only one visible at a time.
var _common: Control = null
var _special: Control = null
var _close: BaseButton = null

## Handles into the visible window's controls, refreshed by _select().
var _gem: TextureRect = null
var _gauge: TextureProgressBar = null
var _name: Label = null
var _icon: TextureRect = null

func _init(builder: UiBuilder = null) -> void:
	_builder = builder

## Builds both windows from their layouts. Returns false when the archive has
## no target window (no Media.pk2), in which case the node is empty and stays
## hidden -- there is no stand-in.
func setup() -> bool:
	# The window consumes the clicks on it (round 529). Its rect is the
	# showing piece's (_select sizes it to that piece; each piece's Frame
	# fills its own rect). It was IGNORE, like every node under it, so a click
	# on it reached World3D._unhandled_input (measured by round 522's
	# re-review), which treats it as a click on the world: it walks the
	# character and takes the keyboard back from a focused text line. STOP, as
	# HudWindow uses (its comment has the reasoning): Godot 4.2 hit-tests the
	# deepest control first, so the close button still gets its click. Hidden,
	# the window catches nothing (Godot skips an invisible control). A middle
	# press on it fires the first quickslot through the hotbar's relay
	# (HudUnderbar.relay_middle_button, which World3D connects; round 531).
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	if _builder == null:
		return false
	var container := _builder.load_layout(CONTAINER_LAYOUT)
	if container == null:
		return false
	var sec := container.get_section("Create")
	if sec == null:
		return false

	_common = _build_kind(sec.control_by_name.get("GDR_TW_COMMONENEMY"), COMMON_LAYOUT)
	_special = _build_kind(sec.control_by_name.get("GDR_TW_SPECIALMOBWND"), SPECIAL_LAYOUT)
	if _common == null and _special == null:
		return false
	for w in [_common, _special]:
		if w != null:
			w.visible = false
			add_child(w)

	# The container's own close button, at its authored place; it sits above
	# whichever window is showing.
	var chrome := _builder.build_section(container, "Create")
	if chrome != null:
		var btn := chrome.find_child("GDR_TW_CLOSE", true, false) as BaseButton
		if btn != null:
			btn.get_parent().remove_child(btn)
			_close = btn
			_close.pressed.connect(func() -> void: clear(); closed.emit())
			add_child(_close)
		chrome.queue_free()

	# The window is the size of the piece showing; start with the common one.
	var first: Control = _common if _common != null else _special
	custom_minimum_size = first.size
	size = first.size
	return true

## One kind: its atlas-piece frame at the authored size, with that kind's own
## inner layout on top. Returns null if the piece or the layout is missing.
func _build_kind(piece: UiLayoutParser.ControlDef, layout_path: String) -> Control:
	if piece == null or piece.ddj == "":
		return null
	var layout := _builder.load_layout(layout_path)
	if layout == null:
		return null
	var win := Control.new()
	win.name = piece.name
	win.mouse_filter = Control.MOUSE_FILTER_IGNORE
	win.size = Vector2(piece.rect.size)

	var frame := TextureRect.new()
	frame.name = "Frame"
	frame.texture = _builder.load_texture_region(piece.ddj, piece.uv_lt, piece.uv_rb)
	frame.position = Vector2.ZERO
	frame.size = Vector2(piece.rect.size)
	frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	frame.stretch_mode = TextureRect.STRETCH_SCALE
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	win.add_child(frame)
	if frame.texture != null:
		# Say when the atlas region and the authored rect disagree, so a
		# stretched frame is a logged fact rather than a look.
		var region := frame.texture.get_size()
		if region != Vector2(piece.rect.size):
			print("HudTarget: %s piece is %s but authored %s" % [piece.name, region, piece.rect.size])

	var inner := _builder.build_section(layout, "Create")
	if inner == null:
		return null
	inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	win.add_child(inner)

	# The gem slot is an art-less static, which the builder makes a Label;
	# put a TextureRect at exactly its authored rect instead.
	var gem_name := "GDR_TWCE_GEM" if layout_path == COMMON_LAYOUT else "GDR_TWSM_GEM"
	var gem_slot := inner.find_child(gem_name, true, false) as Control
	if gem_slot != null:
		var gem := TextureRect.new()
		gem.name = gem_name + "_art"
		gem.position = gem_slot.position
		gem.size = gem_slot.size
		gem.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		gem.stretch_mode = TextureRect.STRETCH_SCALE
		gem.mouse_filter = Control.MOUSE_FILTER_IGNORE
		inner.add_child(gem)
	return win

## Picks the window for a rarity and refreshes the control handles.
## `CIFTargetWindow` shows the common-enemy window for rarity 0 and the
## special-mob one otherwise.
func _select(rarity: int) -> void:
	var want: Control = _special if (rarity != 0 and _special != null) else _common
	if want == null:
		want = _special
	for w in [_common, _special]:
		if w != null:
			w.visible = (w == want)
	size = want.size
	custom_minimum_size = want.size
	if _close != null:
		_close.move_to_front()
	var common := (want == _common)
	var prefix := "GDR_TWCE_" if common else "GDR_TWSM_"
	_gem = want.find_child(prefix + "GEM_art", true, false) as TextureRect
	_gauge = want.find_child(prefix + "GAUGE_HPGAUGE", true, false) as TextureProgressBar
	_name = want.find_child(prefix + "TEXT_ID", true, false) as Label
	_icon = null if common else want.find_child("GDR_TWSM_ICON", true, false) as TextureRect

## The level-difference class (0..4) FUN_007780c0 computes, or 2 (normal)
## when the player's own level is not known yet.
func difficulty_class(target_level: int) -> int:
	if _player_level <= 0 or target_level <= 0:
		return 2
	var d := target_level - _player_level
	if d < -6:
		return 0
	if d < -3:
		return 1
	if d < 1:
		return 2
	return 4 if d > 5 else 3

func set_player_level(level: int) -> void:
	_player_level = level

## Shows the window for a target: its name, level (through the gem and the
## name colour), rarity (which window, and the rank icon on the special one),
## and HP. All server values.
func show_target(target_name: String, level: int, rarity: int, hp: int, max_hp: int) -> void:
	if _common == null and _special == null:
		return
	_select(rarity)
	var cls := difficulty_class(level)
	if _name != null:
		_name.text = target_name
		_name.add_theme_color_override("font_color", COLOUR_BY_CLASS[cls])
	if _gem != null:
		_gem.texture = _builder.load_texture(GEM_DIR + GEM_BY_CLASS[cls]) if _builder != null else null
	if _icon != null:
		var icon_path := rank_icon_path(rarity)
		_icon.texture = _builder.load_texture(icon_path) if (icon_path != "" and _builder != null) else null
		_icon.visible = _icon.texture != null
	set_hp(hp, max_hp)
	visible = true

## The gauge is the server's hp/max, nothing else. Logged during QA runs so
## a frame can be checked against the number it should show.
func set_hp(hp: int, max_hp: int) -> void:
	if _gauge == null or max_hp <= 0:
		return
	var fraction := clampf(float(hp) / float(max_hp), 0.0, 1.0)
	_gauge.value = fraction * 100.0
	if OS.get_environment("SRREVAMP_QA_ATTACK") != "":
		print("HudTarget: gauge %s size %s fill %.1f%% (%d/%d) window at %s" % [
			str(_gauge.position), str(_gauge.size), fraction * 100.0, hp, max_hp, str(global_position)])

func clear() -> void:
	visible = false

## The rank icon for a rarity (characterdata _RefObjChar col 15), recovered
## from the retail client's switch (FUN_0069b4c0): 0/7 normal, 1 champion,
## 3/8 unique, 4 giant, 5 titan, 6 elite; anything else shows no icon.
static func rank_icon_path(rarity: int) -> String:
	match rarity:
		0, 7:
			return "interface\\targetwindow\\tw_icon_normal.ddj"
		1:
			return "interface\\targetwindow\\tw_icon_champion.ddj"
		3, 8:
			return "interface\\targetwindow\\tw_icon_unique.ddj"
		4:
			return "interface\\targetwindow\\tw_icon_giant.ddj"
		5:
			return "interface\\targetwindow\\tw_icon_titan.ddj"
		6:
			return "interface\\targetwindow\\tw_icon_elite.ddj"
	return ""
