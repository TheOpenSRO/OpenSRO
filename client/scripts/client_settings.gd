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

## Applies the UI scale to the window that everything is drawn in. Works
## with the project's stretch mode left at "disabled": the window then
## divides its size by this factor for the canvas, which is the whole
## effect wanted.
static func apply_ui_scale(window: Window, scale: float) -> void:
	if window != null:
		window.content_scale_factor = clampf(scale, 0.5, 3.0)
