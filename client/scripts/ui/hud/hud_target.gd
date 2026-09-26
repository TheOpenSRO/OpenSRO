class_name HudTarget
extends Control

## The target window -- the thing the player has clicked, at the top of the
## screen -- built from the client's own authored layouts instead of a
## hand-placed bar over a stretched frame.
##
## What the archive says (2026-09-19, dumped with tools/dump_layout.gd):
##
## - `resinfo\ginterface.txt` registers `GDR_TARGETWINDOW` (`CIFTargetWindow`)
##   at (442, 10) with a 10x10 rect. The window does not stay there: see
##   **Placement** below.
## - **Placement, read (round 590).** After choosing a piece, the select
##   function 0x699540 moves the window itself (slot 0x98 on esi, 0x69a180)
##   to x = (screen width - w) >> 1, y = 7 (0x69a161..0x69a17e). `w` is the
##   width of the piece it just showed: each branch reads that piece's own
##   rect into the same stack slot ([esp+0x1c] = x, y, w, h via 0xb8f420 --
##   the special mob at 0x6999b1, the common enemy at 0x699b51, the player
##   pieces at 0x699e3e/0x699e64), and the formula reads its third field
##   ([esp+0x24]); it is not the window's own 10x10. The screen width is the
##   display mode's +0x24 (0x4f9cd0), read as the width because a centring
##   routine halves it for x and +0x28 for y (inferred, round 587). When no
##   piece is shown (a rarity-2 monster) nothing writes that slot before the
##   formula reads it, so the client's x there is not defined by anything
##   read; this window then stays where it was.
## - `resinfo\iftargetwindow.txt` is the container, and it is the one the
##   client loads: `CIFTargetWindow::Create` (0x699080) pushes it (0xda5170,
##   at 0x69908b) and builds it into the window itself. The file this window
##   used to read, `iftargetwindowex.txt`, is not in the exe in ASCII or
##   UTF-16 (nor is the substring `targetwindowex`). It holds a 16x16
##   `CIFCloseButton` at (176, 9), a buff viewer, a fortress-structure piece
##   under `#ifdef APPLY_SIEGE_FORTRESS_SYSTEM`, and one sub-window per target
##   kind, each an atlas piece of `interface\ifcommon\window_all.ddj`, in two
##   `#ifdef UI_UPDATE_2009_FIRST` branches: `GDR_TW_COMMONENEMY` 236x51 /
##   196x51, `GDR_TW_SPECIALMOBWND` 236x78 / 196x78, `GDR_TW_JOB_PLAYERWND`
##   236x58 / 196x58, `GDR_TW_PLAYERWND` 236x35 / 196x36.
## - It is read with the defines this build takes (CONTAINER_DEFINES). The
##   define table (0xeed4e0) is one global map with one reader (0x5004a0,
##   called only from the parser's IFTVariable at 0xb37aeb), so every layout
##   parses under the same set. UI_UPDATE_2009_FIRST is in it -- inferred in
##   round 585 from CIFChatViewer, which dereferences a control only that
##   branch declares with no null check (ID 42, 0x7abc9c). So is
##   APPLY_SIEGE_FORTRESS_SYSTEM: CIFTargetWindow::Create fetches ID 8, which
##   only that branch declares, and calls through it with no null check
##   (0x699177). Both inferred from class code, as the define table itself
##   is never visibly filled.
## - Each kind's class loads its own inside into itself: the common enemy
##   `iftw_commonenemy.txt`, the special mob `iftw_specialmob.txt`, the player
##   `iftw_player.txt` (0x69b18b) and the job player
##   `iftw_jobplayer_trijob2.txt` (0x69ac4b, CIFTargetWindowJobPlayer::Create;
##   the plain `iftw_jobplayer.txt` is not in the exe). Create hides all
##   four kinds, the buff viewer and the fortress piece (0x699115..0x699180).
## - `resinfo\iftw_commonenemy.txt` is a normal monster's inside: the gem
##   `GDR_TWCE_GEM` at (8, 5) 20x20, the HP gauge `GDR_TWCE_GAUGE_HPGAUGE`
##   (`CIFGauge`, `interface\targetwindow\tw_hp.ddj`) at (14, 37) 168x4, and
##   the name `GDR_TWCE_TEXT_ID` at (34, 10), 170x12 under
##   UI_UPDATE_2009_FIRST (137x12 without), centred. No level text and no
##   rank icon: a common enemy shows its level only through the gem.
## - `resinfo\iftw_specialmob.txt` adds, on the 78-tall piece, `GDR_TWSM_LEVEL`
##   (10, 56) 30x16, the rank icon `GDR_TWSM_ICON` (65, 54) 16x16 and
##   `GDR_TWSM_TEXT_LEV` (85, 56) 168x12.
##
## What the client binary says (sro_client.exe, Ghidra dump on the RE box):
##
## - **Which window, read (round 589).** The select function 0x699540 hides
##   every kind, then tests the target's class with IsKindOf (0xb94b90)
##   against runtime-class descriptors whose names the binary carries (each
##   descriptor is built by a static initialiser that passes its name, e.g.
##   0xd764a6 -> "CICMonster"):
##   - **CICMonster** (0xef1a84, tested first at 0x6996a0): the rarity byte
##     +0x7ac (characterdata col 15) goes through the table 0x69a2d0. Rarity
##     0, 1, 3, 4, 5, 6, 7 and 8 all show the **special-mob** window (+0x380,
##     ID 2) and call the rank function 0x69b4c0 on it. Rarity 2, and any
##     value above 8 (`cmp eax,8 / ja`), jump past every piece to 0x6999c1:
##     the window is shown with **no piece** -- only its close button (moved
##     to 216,9 before the switch, see below) and the buff viewer. No monster in the
##     archive has rarity 2 (measured: 0 of 7,604 CICMonster rows).
##   - CICCos (0xeef6f0, pets, horses, transport): the **common-enemy** window,
##     tw_gem_animal (0x699a55..).
##   - CICNPC (0xef1ac4): guard types show the fortress piece; any other NPC
##     the **common-enemy** window with tw_gem_player (0x699c8e..).
##   - CICUser (0xef1bc0, players): the player window (ID 0) when its slot 43
##     returns 4, otherwise the job-player window (ID 1) (0x699e0b..). What
##     slot 43 returns was not read.
##   - CICATStruct (0xee774c): the fortress piece, or the **common-enemy**
##     window with tw_gem_normal (0x69a0df..).
##   This window only ever shows monsters here (World3D._show_target takes a
##   monster id; NPCs open the talk box, and players and pets are never
##   targeted), so show_target follows the CICMonster branch.
## - **The rank rows, read (0x69b4c0).** On the special-mob window it sets the
##   rank icon (ID 3) and the rank text (+0x378, ID 2, `GDR_TWSM_TEXT_LEV`,
##   colour 0xffffffff) per rarity through the table 0x69baac, and writes
##   `swprintf_s(.., L"Lv %d", level)` into ID 4 (`GDR_TWSM_LEVEL`), the level
##   from the object's reference data (GlobalDataManager 0x93f630).
##   RANK_TEXT_BY_RARITY has the texts. A party monster (+0x7ad == 1) also
##   gets UIIT_STT_PARTYMOB_TARGET appended; the server sends no such flag.
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

const CONTAINER_LAYOUT := "resinfo\\iftargetwindow.txt"
const COMMON_LAYOUT := "resinfo\\iftw_commonenemy.txt"
const SPECIAL_LAYOUT := "resinfo\\iftw_specialmob.txt"
const PLAYER_LAYOUT := "resinfo\\iftw_player.txt"
const JOB_PLAYER_LAYOUT := "resinfo\\iftw_jobplayer_trijob2.txt"
## The defines the container and the kinds' insides are read with (see the
## header). The kinds' layouts branch only on UI_UPDATE_2009_FIRST.
const CONTAINER_DEFINES := ["UI_UPDATE_2009_FIRST", "APPLY_SIEGE_FORTRESS_SYSTEM"]
const KIND_DEFINES := ["UI_UPDATE_2009_FIRST"]
const GEM_DIR := "interface\\targetwindow\\"

## The special-mob window's rank text per rarity (0x69b4c0, its table
## 0x69baac): 0 -> UIIT_CTL_WARENETWORK_DETAIL_NORMAL, 1 -> UIIT_STT_MOB_CHAMPION,
## 3 and 8 -> UIIT_STT_MOB_UNIQUE, 4 -> UIIT_STT_MOB_GIANT, 5 ->
## UIIT_STT_MOB_TITAN, 6 -> UIIT_STT_MOB_ELITE, 7 -> UIIT_STT_MOB_STRONG.
## 2 falls to the default and sets nothing.
const RANK_TEXT_BY_RARITY := {
	0: "UIIT_CTL_WARENETWORK_DETAIL_NORMAL", 1: "UIIT_STT_MOB_CHAMPION",
	3: "UIIT_STT_MOB_UNIQUE", 4: "UIIT_STT_MOB_GIANT", 5: "UIIT_STT_MOB_TITAN",
	6: "UIIT_STT_MOB_ELITE", 7: "UIIT_STT_MOB_STRONG", 8: "UIIT_STT_MOB_UNIQUE",
}
## The level row's format, `L"Lv %d"` at 0xda58bc.
const LEVEL_FORMAT := "Lv %d"

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
## The two player kinds, built from their live layouts and hidden, as
## Create leaves them. This window shows only monsters today (World3D's
## attack target), so nothing selects them yet.
var _player: Control = null
var _job_player: Control = null
var _close: BaseButton = null

## Handles into the visible window's controls, refreshed by _select().
var _gem: TextureRect = null
var _gauge: TextureProgressBar = null
var _name: Label = null
var _icon: TextureRect = null
var _level_row: Label = null
var _rank_row: Label = null

## Where the close button ends up (see setup): the authored (176, 9) moved by
## (+0x28, 0).
const CLOSE_BUTTON_AT := Vector2(176 + 0x28, 9)

## The special-mob window's rows as its class and 0x69b4c0 place them,
## relative to the piece (read, round 592):
## - CIFTargetWindowSpecialMob::Create (0x69b410) sizes its HP gauge (ID 1,
##   +0x374) with slot 21: `push 4; push 0xd0` (0x69b495..0x69b4a7) -- 208x4,
##   not the layout's 168x4.
## - 0x69b4c0 moves the rank icon (ID 3) to (x + 0x55, y + 0x36) and the rank
##   text (+0x378, ID 2) to (x + 0x69, y + 0x38) before its rarity switch
##   (0x69b52f..0x69b57a), x and y being the piece's own (0xb8f420 at
##   0x69b52a): (85, 54) and (105, 56), not the layout's (65, 54), (85, 56).
## For a party monster it then re-centres the rank row by the text's width
## (0x69b890..0x69b98d); the server sends no party flag, so that is not done.
const SPECIAL_GAUGE_SIZE := Vector2(0xd0, 4)
const SPECIAL_RANK_ICON_AT := Vector2(0x55, 0x36)
const SPECIAL_RANK_TEXT_AT := Vector2(0x69, 0x38)
## Rarity 7's name prefix (0x6997b9..0x699834): the target's name becomes
## UIIT_STT_MOB_STRONG + L" " (0xe19330) + name before 0x69b380 sets it.
const STRONG_NAME_KEY := "UIIT_STT_MOB_STRONG"

## The y the select function puts the window at (0x69a171, `push 7`).
const TOP_Y := 7.0

## Places the window as the select function does (see Placement): centred on
## the screen's width by the shown piece's width, 7 down. In this client the
## screen is the viewport, in the UI's own units -- which is what a UI scale
## changes -- and the placement is redone when the viewport resizes, since the
## client re-runs its formula on every selection and knows no resize of ours.
func place() -> void:
	if _shown == null or not is_inside_tree():
		return
	var view := get_viewport_rect().size
	var at := Vector2(floorf((view.x - size.x) / 2.0), TOP_Y)
	# Our deviation, as the main popup's (HudMainPopup.keep_on_screen): held
	# inside the viewport. It changes nothing unless the logical viewport is
	# narrower than the piece (236) or shorter than 7 + its height.
	at.x = clampf(at.x, 0.0, maxf(0.0, view.x - size.x))
	at.y = clampf(at.y, 0.0, maxf(0.0, view.y - size.y))
	global_position = at

## The piece _select showed, or null.
var _shown: Control = null

func _notification(what: int) -> void:
	if what == NOTIFICATION_ENTER_TREE:
		var vp := get_viewport()
		if vp != null and not vp.size_changed.is_connected(place):
			vp.size_changed.connect(place)

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
	var container := _builder.load_layout(CONTAINER_LAYOUT,
		PackedStringArray(CONTAINER_DEFINES), true)
	if container == null:
		return false
	var sec := container.get_section("Create")
	if sec == null:
		return false

	_common = _build_kind(sec.control_by_name.get("GDR_TW_COMMONENEMY"), COMMON_LAYOUT, "GDR_TWCE_GEM")
	_special = _build_kind(sec.control_by_name.get("GDR_TW_SPECIALMOBWND"), SPECIAL_LAYOUT, "GDR_TWSM_GEM")
	if _common == null and _special == null:
		return false
	if _special != null:
		_move_authored(_special.find_child("GDR_TWSM_GAUGE_HPGAUGE", true, false), null, SPECIAL_GAUGE_SIZE)
		_move_authored(_special.find_child("GDR_TWSM_ICON", true, false), SPECIAL_RANK_ICON_AT, null)
		_move_authored(_special.find_child("GDR_TWSM_TEXT_LEV", true, false), SPECIAL_RANK_TEXT_AT, null)
	_player = _build_kind(sec.control_by_name.get("GDR_TW_PLAYERWND"), PLAYER_LAYOUT)
	_job_player = _build_kind(sec.control_by_name.get("GDR_TW_JOB_PLAYERWND"), JOB_PLAYER_LAYOUT)
	for w in [_common, _special, _player, _job_player]:
		if w != null:
			w.visible = false
			add_child(w)
			UiBuilder.settle_authored_rects(w)

	# The container's own close button; it sits above whichever window is
	# showing. Read (round 592): each time the select function 0x699540
	# shows a target it moves the button to (window x + 0xb0, window y + 9)
	# (0x699658..0x699684) -- the authored (176, 9) -- and then, before any
	# class test, fetches it again (`push 0; push 0x28; push 1; push 0xb;
	# call 0x8b51f0`, which pops only its own two) and calls 0xb90db0 on it,
	# a thunk to 0xb90c60, MoveBy(dx, dy): `add [esi+0x40],dx; add
	# [esi+0x44],dy` and the same for its children (0x699686..0x69969b). So
	# it sits at (216, 9), which is also where the NPC and structure
	# branches put it outright (x + 0xd8). CLOSE_BUTTON_AT.
	var chrome := _builder.build_section(container, "Create")
	if chrome != null:
		var btn := chrome.find_child("GDR_TW_CLOSE", true, false) as BaseButton
		if btn != null:
			btn.get_parent().remove_child(btn)
			_close = btn
			_close.pressed.connect(func() -> void: clear(); closed.emit())
			add_child(_close)
			# Where the client puts it, held there by the settling pass as
			# every built control is (round 585).
			_close.set_meta(UiBuilder.AUTHORED_RECT_META, Rect2(CLOSE_BUTTON_AT, _close.size))
			_close.position = CLOSE_BUTTON_AT
			UiBuilder.settle_authored_rects(_close)
		chrome.queue_free()

	# The window is the size of the piece showing; start with the common one.
	var first: Control = _common if _common != null else _special
	custom_minimum_size = first.size
	size = first.size
	return true

## Moves and/or resizes a built control the way the class does in code,
## keeping the settling pass's rect in step so it holds the new one.
static func _move_authored(node: Node, at, to) -> void:
	var c := node as Control
	if c == null:
		return
	var rect: Rect2 = c.get_meta(UiBuilder.AUTHORED_RECT_META) if c.has_meta(UiBuilder.AUTHORED_RECT_META) \
		else Rect2(c.position, c.size)
	if at != null:
		rect.position = at
	if to != null:
		rect.size = to
	c.set_meta(UiBuilder.AUTHORED_RECT_META, rect)
	c.custom_minimum_size = Vector2.ZERO
	c.position = rect.position
	c.size = rect.size

## One kind: its atlas-piece frame at the authored size, with that kind's own
## inner layout on top, read with KIND_DEFINES. `gem_name` names the kind's
## art-less gem slot, if it has one. Returns null if the piece or the layout
## is missing.
func _build_kind(piece: UiLayoutParser.ControlDef, layout_path: String,
		gem_name: String = "") -> Control:
	if piece == null or piece.ddj == "":
		return null
	var layout := _builder.load_layout(layout_path, PackedStringArray(KIND_DEFINES), true)
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
	if gem_name == "":
		return win
	var gem_slot := inner.find_child(gem_name, true, false) as Control
	if gem_slot != null:
		var gem := TextureRect.new()
		gem.name = gem_name + "_art"
		# The slot's authored rect, not its size: the slot is a Label, whose
		# size is clamped up to the default font's height until the tree
		# settles (UiBuilder.settle_authored_rects), so copying its size drew
		# the gem 20x23 over an authored 20x20. The meta keeps the settling
		# pass holding it there too.
		var rect := Rect2(gem_slot.position, gem_slot.size)
		if gem_slot.has_meta(UiBuilder.AUTHORED_RECT_META):
			rect = gem_slot.get_meta(UiBuilder.AUTHORED_RECT_META)
			gem.set_meta(UiBuilder.AUTHORED_RECT_META, rect)
		gem.position = rect.position
		gem.size = rect.size
		gem.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		gem.stretch_mode = TextureRect.STRETCH_SCALE
		gem.mouse_filter = Control.MOUSE_FILTER_IGNORE
		inner.add_child(gem)
	return win

## The monster rarities the table 0x69a2d0 maps to the special-mob window;
## any other value shows no piece (see the header).
const MONSTER_RARITIES_WITH_WINDOW := [0, 1, 3, 4, 5, 6, 7, 8]

## The kind a monster of this rarity shows: "special", or "" for none.
static func monster_window(rarity: int) -> String:
	return "special" if rarity in MONSTER_RARITIES_WITH_WINDOW else ""

## Picks the piece for a monster's rarity, as CIFTargetWindow's CICMonster
## branch does, and refreshes the control handles. With no piece the window
## keeps only its close button, and takes no space of its own.
func _select(rarity: int) -> void:
	var want: Control = _special if monster_window(rarity) == "special" else null
	_shown = want
	for w in [_common, _special, _player, _job_player]:
		if w != null:
			w.visible = (w == want)
	var at := want.size if want != null else Vector2.ZERO
	custom_minimum_size = at
	size = at
	if _close != null:
		_close.move_to_front()
	_gem = null
	_gauge = null
	_name = null
	_icon = null
	_level_row = null
	_rank_row = null
	if want == null:
		return
	_gem = want.find_child("GDR_TWSM_GEM_art", true, false) as TextureRect
	_gauge = want.find_child("GDR_TWSM_GAUGE_HPGAUGE", true, false) as TextureProgressBar
	_name = want.find_child("GDR_TWSM_TEXT_ID", true, false) as Label
	_icon = want.find_child("GDR_TWSM_ICON", true, false) as TextureRect
	_level_row = want.find_child("GDR_TWSM_LEVEL", true, false) as Label
	_rank_row = want.find_child("GDR_TWSM_TEXT_LEV", true, false) as Label

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
	# Only CIFTargetWindow's CICMonster branch is followed: this window shows
	# monsters and nothing else (see the header).
	_select(rarity)
	var cls := difficulty_class(level)
	if _name != null:
		_name.text = monster_name(target_name, rarity)
		_name.add_theme_color_override("font_color", COLOUR_BY_CLASS[cls])
	if _gem != null:
		_gem.texture = _builder.load_texture(GEM_DIR + GEM_BY_CLASS[cls]) if _builder != null else null
	if _icon != null:
		var icon_path := rank_icon_path(rarity)
		_icon.texture = _builder.load_texture(icon_path) if (icon_path != "" and _builder != null) else null
		_icon.visible = _icon.texture != null
	if _level_row != null:
		_level_row.text = LEVEL_FORMAT % level
	if _rank_row != null:
		_rank_row.text = rank_text(rarity)
		_rank_row.add_theme_color_override("font_color", Color.WHITE)
	set_hp(hp, max_hp)
	visible = true
	place()

## The name the window shows: rarity 7 prefixes it with UIIT_STT_MOB_STRONG's
## text and a space (read, STRONG_NAME_KEY). If the text table cannot resolve
## the key, the plain name is shown (our fallback).
func monster_name(target_name: String, rarity: int) -> String:
	if rarity != 7 or _builder == null:
		return target_name
	var prefix := _builder.resolve_text(STRONG_NAME_KEY)
	if prefix == "" or prefix == STRONG_NAME_KEY:
		return target_name
	return prefix + " " + target_name

## The rank row's text for a rarity, through the client's text table, or ""
## where 0x69b4c0 sets none.
func rank_text(rarity: int) -> String:
	var key: String = RANK_TEXT_BY_RARITY.get(rarity, "")
	if key == "":
		return ""
	var text := key
	if _builder != null:
		var resolved := _builder.resolve_text(key)
		if resolved != "":
			text = resolved
	return text

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
