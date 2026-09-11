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
## fractional oversampling; the project setting that lets the window drive
## oversampling is off, and this sets it by hand -- the scale itself when it
## is an integer, 1.0 (glyphs rasterised at their base size and scaled)
## otherwise, and again after every resize, which resets it.
static func apply_ui_scale(window: Window, scale: float) -> void:
	if window == null:
		return
	var factor := clampf(scale, 0.5, 3.0)
	window.content_scale_factor = factor
	_apply_oversampling(factor)
	if not window.has_meta("ui_scale_oversampling_hooked"):
		window.set_meta("ui_scale_oversampling_hooked", true)
		window.size_changed.connect(func() -> void: _apply_oversampling(window.content_scale_factor))

static func _apply_oversampling(factor: float) -> void:
	var text_server := TextServerManager.get_primary_interface()
	if text_server == null:
		return
	var whole := is_equal_approx(factor, roundf(factor))
	text_server.font_set_global_oversampling(roundf(factor) if whole else 1.0)
