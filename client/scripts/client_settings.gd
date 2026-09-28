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

const SECTION_UI := "ui"
## Multiplies the size of everything drawn on screen; 1.0 is as authored.
## For a couch and a TV, where the chat and the HUD were "too tiny to see".
const KEY_UI_SCALE := "scale"
const DEFAULT_UI_SCALE := 1.0
## 0 means the theme's own size.
const KEY_CHAT_FONT_SIZE := "chat_font_size"
## How near an entity has to be before its name shows, in world units;
## World3D.NAME_PLATE_RANGE when unset.
const KEY_NAME_PLATE_RANGE := "name_plate_range"
## Which of the original's three views the camera uses: "free" (the
## default), "third_person" or "quarter" -- World3D.CAMERA_VIEW_*.
const KEY_CAMERA_VIEW := "camera_view"

const SECTION_WORLD := "world"
## Which seasonal event decoration sets are drawn (round 583;
## SeasonalObjects): a comma list of "christmas", "halloween", "obt" and
## "summer". Empty, the default, hides all four. Read once per world scene,
## when it builds its first region's objects, so a change shows after the
## next login or restart; no window writes it yet -- a tester edits the
## file, or sets SRREVAMP_SEASONAL, which adds to it. In the file the value
## MUST be quoted: `seasonal="christmas,halloween"` under `[world]`. An
## unquoted `seasonal=christmas,halloween` is a ConfigFile parse error
## (ERR_PARSE_ERROR, measured on the box): get_value then returns every
## setting's default, and the next set_value rewrites the file from only
## the keys above the bad line plus its own, losing that line and the rest.
const KEY_SEASONAL := "seasonal"
## The Water Reflection video option (round 628; WaterReflection): true, the
## default, draws retail's reflection pass, as the game's shipped
## Setting\SROptionSet.dat has it (tag 5 = 1); false draws the plain animated
## water. Read once per world scene.
const KEY_WATER_REFLECTION := "water_reflection"

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

static func server_address() -> String:
	return str(get_value(SECTION_SERVER, KEY_ADDRESS, ""))

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
## Font oversampling -- rasterising glyphs at the scaled size so they stay
## crisp -- is applied only at a whole-number scale. Measured on the render
## box in a 1160x700 window (2026-09-11): at 2.0 "Register" draws whole, at
## 2.35 and 2.5 its last glyph is missing, and at 2.35 with oversampling off
## it draws whole again. So Godot 4.2 loses the last glyph of a string under
## fractional oversampling. (Round 581's rendered probe -- a Label and the
## current register link, in the default font -- did not reproduce it at
## 2.35 or 2.5; the rule stays, and costs nothing.)
##
## The root window sets the text server's oversampling itself on every
## viewport update -- a resize, a content-scale change: to its content scale
## factor when its font-oversampling flag is on, to 1.0 when it is off
## (scene/main/window.cpp, Window::_update_viewport_size, 4.2.2-stable; the
## project's stretch mode is "disabled"). So this sets the FLAG -- on at a
## whole-number scale, off otherwise -- and the window then holds the right
## value through every later resize. The project setting
## gui/fonts/dynamic_fonts/use_oversampling (false) is the flag at startup.
##
## Until round 581 this set the oversampling by hand and again from the
## window's size_changed signal. That signal is emitted inside the viewport
## update, before the window's own reset, so after a resize the window's
## value won: 2.35 at a 2.35 scale while project.godot's `#` comment swallowed
## the setting, and 1.0 at every scale once the setting applied (measured on
## the render box, headless and in a window, round 581).
static func apply_ui_scale(window: Window, scale: float) -> void:
	if window == null:
		return
	var factor := clampf(scale, 0.5, 3.0)
	# Only the main window drives the oversampling, and only it may set the
	# flag once it is in the tree (Window::set_use_font_oversampling).
	if window.is_inside_tree() and window == window.get_tree().root:
		window.set_use_font_oversampling(is_equal_approx(factor, roundf(factor)))
	window.content_scale_factor = factor
