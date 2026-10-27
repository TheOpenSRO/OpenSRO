extends RefCounted
class_name ClientSettings

## The few things the client remembers between runs: the server it last
## reached, the account name, and how it draws its own chrome. Kept in a
## plain ConfigFile at user://settings.cfg -- next to the log, so a tester
## can find, read and delete it -- and never anything secret: no password.
##
## Every read has a default and tolerates a missing or unreadable file,
## because the first run has none and a tester may well delete it.

const PATH := "user://settings.cfg"

const SECTION_SERVER := "server"
const KEY_ADDRESS := "address"
const KEY_USERNAME := "username"
## The server last chosen from setting/config.yaml's list, by its name (round
## 679, ClientConfig): the login screen starts on it while the file lists it.
const KEY_SERVER_NAME := "server_name"

const SECTION_UI := "ui"
## Multiplies the size of everything drawn on screen; 1.0 is as authored.
## For a couch and a TV, where the chat and the HUD were "too tiny to see".
const KEY_UI_SCALE := "scale"
const DEFAULT_UI_SCALE := 1.0
## 0 means the theme's own size.
const KEY_CHAT_FONT_SIZE := "chat_font_size"
## How near an entity has to be to the player before its name shows, in world
## units; World3D.NAME_PLATE_RANGE (retail's 300) when unset. A new key in
## round 673: the old "name_plate_range" was a distance from the CAMERA, 80 by
## default, and a value saved under it would keep hiding names the retail
## rule shows.
const KEY_NAME_PLATE_RANGE := "name_range_from_player"
## Which of the original's three views the camera uses: "free" (the
## default), "third_person" or "quarter" -- World3D.CAMERA_VIEW_*.
const KEY_CAMERA_VIEW := "camera_view"

## [ext_quick_slot] (round 788) belongs to ExtQuickSlotSettings: the
## Additional Quick Slot bars' options, places and the extra bars' counts.

const SECTION_WORLD := "world"
## Which seasonal event decoration sets are drawn (round 583;
## SeasonalObjects): a comma list of "christmas", "halloween", "obt" and
## "summer". Empty, the default, hides all four. Read once per world scene,
## when it builds its first region's objects, so a change shows after the
## next login or restart; no window writes it yet -- a tester edits the
## file, or sets OPENSRO_SEASONAL, which adds to it. In the file the value
## MUST be quoted: `seasonal="christmas,halloween"` under `[world]`. An
## unquoted `seasonal=christmas,halloween` is a ConfigFile parse error
## (ERR_PARSE_ERROR, measured on the box): get_value then returns every
## setting's default, and the next set_value rewrites the file from only
## the keys above the bad line plus its own, losing that line and the rest.
const KEY_SEASONAL := "seasonal"
## The Water Reflection video option (round 628; WaterReflection): true draws
## retail's reflection pass, false the plain animated water. Since round 694
## the Option window's Video tab owns it (VideoOptions, sections [video],
## [video_graphic1], [video_graphic2]): a value stored here before them still
## wins over the Middle default; absent, Middle's (off). It is rewritten to
## match the record in force.
const KEY_WATER_REFLECTION := "water_reflection"

## Round 832: the Option window's Extra tab (OURS, private-server add-ons).
const SECTION_EXTRA := "extra"
## The draggable Ping / FPS box, and where it was left (a Vector2, top-left).
const KEY_PING_FPS := "ping_fps_counter"
const KEY_PING_FPS_POS := "ping_fps_position"
## Round 832: retail's "Activate action short cut" (UIIT_CTL_ACTION_LIST_ACTIVE,
## the option byte +0x1a), which opens the right-click target menu. Its
## Default is off (READ, 0x5fce10); shown on the Extra tab until the Game tab
## is built.
const SECTION_GAME := "game"
## Round 833: the Key Map tab's keys (KeyMap.set_keys): 33 Godot keycodes in
## slot order.
const SECTION_KEYMAP := "keymap"
const KEY_KEYMAP_SLOTS := "slots"
const KEY_ACTION_SHORTCUT := "action_short_cut"

static func get_value(section: String, key: String, default_val: Variant) -> Variant:
	var file := ConfigFile.new()
	if file.load(PATH) != OK:
		return default_val
	return file.get_value(section, key, default_val)

## Writes one value, keeping everything else the file already holds.
## Returns false when the file could not be written, which a caller may
## ignore: forgetting a setting is never worth failing an action over.
static func set_value(section: String, key: String, value: Variant) -> bool:
	var file := ConfigFile.new()
	file.load(PATH) # a missing file is fine; it is about to exist
	file.set_value(section, key, value)
	return file.save(PATH) == OK

static func ping_fps_shown() -> bool:
	return bool(get_value(SECTION_EXTRA, KEY_PING_FPS, false))

## Round 833: GI+0x4f9, the Key Map tab's mouse mode (0 or 1; READ, it starts
## at 0).
const KEY_MOUSE_MODE := "mouse_mode"

static func mouse_mode() -> int:
	return clampi(int(get_value(SECTION_UI, KEY_MOUSE_MODE, 0)), 0, 1)

static func action_shortcut() -> bool:
	return bool(get_value(SECTION_GAME, KEY_ACTION_SHORTCUT, false))

static func server_address() -> String:
	return str(get_value(SECTION_SERVER, KEY_ADDRESS, ""))

static func server_name() -> String:
	return str(get_value(SECTION_SERVER, KEY_SERVER_NAME, ""))

static func username() -> String:
	return str(get_value(SECTION_SERVER, KEY_USERNAME, ""))

static func ui_scale() -> float:
	return clampf(float(get_value(SECTION_UI, KEY_UI_SCALE, DEFAULT_UI_SCALE)), 0.5, 3.0)

static func chat_font_size() -> int:
	return clampi(int(get_value(SECTION_UI, KEY_CHAT_FONT_SIZE, 0)), 0, 72)

static func name_plate_range(default_val: float) -> float:
	return float(get_value(SECTION_UI, KEY_NAME_PLATE_RANGE, default_val))

static func camera_view() -> String:
	return str(get_value(SECTION_UI, KEY_CAMERA_VIEW, "free"))

static func seasonal_shown() -> String:
	return str(get_value(SECTION_WORLD, KEY_SEASONAL, ""))

## Applies the UI scale to the window that everything is drawn in. Works
## with the project's stretch mode left at "disabled": the window then
## divides its size by this factor for the canvas, which is the whole
## effect wanted.
##
## Font oversampling -- rasterising glyphs at the scaled size -- is on at
## EVERY scale (round 672). Off, a glyph is rasterised at its 1x size and
## magnified by the scale, and that is the soft text players saw at 1.25,
## 1.5 and 1.95. Measured on the render box, 3840x2160, the HUD's name,
## level and HP/MP numbers, the chat and the character window: with the old
## whole-number-only rule 84-97 % of text pixels were part-covered at 1.25,
## 1.5 and 1.95 (edges 3-6 px wide); oversampled and drawn unfiltered
## (UiBuilder.crisp_text) every text pixel is one level at every scale, as
## at 1.0 -- docs/WORLD_ISSUES.md round 672 has the table.
##
## The window owns the value: on every viewport update -- a resize, a
## content-scale change -- it sets the text server's oversampling to its
## content scale factor while its font-oversampling flag is on, 1.0 when it
## is off (scene/main/window.cpp, Window::_update_viewport_size, 4.2.2).
## The flag is on from start-up (project.godot) and this keeps it on, so it
## never TOGGLES. That matters: the update resizes the canvas -- which
## queues a redraw of every CanvasItem (Viewport::_set_size ->
## update_canvas_items) -- before it changes the oversampling, and the
## oversampling change frees every cached glyph texture
## (TextServerAdvanced::_font_set_global_oversampling ->
## _font_clear_size_cache). With a size change, the queued redraws pick up
## the new glyphs. A flag flipped with no size change after it (round 672's
## first probe, which turned the flag on by hand after this function had
## set the scale) frees the textures with nothing redrawn, and every glyph
## drawn before it renders as a solid block: measured, round 672.
##
## The 2026-09-11 lost glyph ("Register" read "Registe" at 2.35) was the
## reason oversampling was limited to whole numbers. Round 672 reproduced it
## ("Sell" drew as "Sel" at 1.25) and found it is a Button's alone: a Button
## clips its text to the ceiling of its own width, and fractional advances
## that sum to a whole number pass it. UiBuilder.guard_button_font has the
## READ mechanism and the guard every Button in the UI now wears.
static func apply_ui_scale(window: Window, scale: float) -> void:
	if window == null:
		return
	var factor := clampf(scale, 0.5, 3.0)
	# Only the main window drives the oversampling, and only it may set the
	# flag once it is in the tree (Window::set_use_font_oversampling). It is
	# already on (project.godot); setting it again changes nothing, and it
	# is never turned off.
	if window.is_inside_tree() and window == window.get_tree().root and not window.is_using_font_oversampling():
		window.set_use_font_oversampling(true)
	var changed := not is_equal_approx(window.content_scale_factor, factor)
	window.content_scale_factor = factor
	# Round 760: Godot 4.7.2's text at this scale as 4.2.2 drew it (the bold
	# faces' stroke, the 3D labels' raster; FontOversampling).
	if window.is_inside_tree() and window == window.get_tree().root:
		FontOversampling.set_ui(factor, window)
	elif not window.is_inside_tree():
		FontOversampling.set_ui(factor)
	if changed and window.is_inside_tree():
		_refresh_text(window)
	# The cursor follows the UI scale (round 697, the user's decision).
	if changed:
		GameCursor.refresh(window)

## After a scale change made while text is up (the debug panel's slider):
## the window has already re-rasterised every glyph at the new scale and
## queued every CanvasItem's redraw, but nothing re-measures text. Measured
## in a running client, round 672, at 1.25-1.95: a column of Buttons moved
## the moment its theme next changed (INFERRED: they had kept their old
## sizes), and the name plate's ink grew 5-14 times (INFERRED: its glyph
## quads still pointed at freed glyph textures); a client started at those scales showed
## neither, and with this refresh the running one measures the same. A
## theme-changed notification is what makes a Control reshape its text and
## resize; a Label3D rebuilds its glyph quads when its font size changes,
## so the size is nudged and put back. Rare: a scale is set at start-up and
## from the panel.
static func _refresh_text(window: Window) -> void:
	# Controls only: the notification's number means other things to other
	# classes, so it is not propagated through the 3D world.
	for n in window.find_children("*", "Control", true, false):
		n.notification(Control.NOTIFICATION_THEME_CHANGED)
	# Round 757: the batched plates (NamePlateBatch) are shaped again too.
	NamePlateBatch.generation += 1
	for n in window.find_children("*", "Label3D", true, false):
		var plate := n as Label3D
		var fs := plate.font_size
		plate.font_size = fs + 1
		plate.font_size = fs
