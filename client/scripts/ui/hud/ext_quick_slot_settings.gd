extends RefCounted
class_name ExtQuickSlotSettings

## What the Additional Quick Slot bars keep between runs (round 788), in the
## client's own settings file (ClientSettings, user://settings.cfg), section
## [ext_quick_slot]. OURS: the location and the keys.
##
## READ, what retail keeps: the six option bytes in `%s\Setting\
## SRExtQSOption.dat` -- a u32 version 1, then open, vertical, twoLines,
## transparent, lockSlots, lockToolbar (writer 0x65e9b0, called only from the
## bar's destructor 0x65ead0, i.e. at teardown; reader 0x65f580 at Create).
## With no file the bar starts open, vertical, two lines, transparent, both
## locks off (Type4). Its position is NOT on disk: CGInterface keeps it in an
## in-memory map for the session (0x79c600(0) -> 0x79a840) and the next
## launch starts at the default place.
##
## OURS: the same six values per bar (`options_<n>`, retail's byte order, as
## ints), written whenever they change rather than at teardown, so a crash
## keeps them; the position too (`position_<n>`), across launches -- retail
## forgets it on exit; and the OURS bars' count and pages (`extra_bars`,
## `pages`). Bar 0 is retail's bar, 1.. the OURS extra bars. Retail's binary
## file is not written: this client keeps no copy of retail's setting files.

const SECTION := "ext_quick_slot"
const KEY_BARS := "extra_bars"
const KEY_PAGES := "pages"
const KEY_OPTIONS := "options_%d"
const KEY_POSITION := "position_%d"

## OURS: one extra bar, four pages (F5..F8), unless the settings say more.
const DEFAULT_BARS := 1
const DEFAULT_PAGES := 4

## The indices into an options array: retail's byte order (0x65f580).
const OPEN := 0
const VERTICAL := 1
const TWO_LINES := 2
const TRANSPARENT := 3
const LOCK_SLOTS := 4
const LOCK_TOOLBAR := 5
## READ (0x65f580 with no file): open, vertical, two lines, transparent.
const DEFAULT_OPTIONS := [1, 1, 1, 1, 0, 0]

static func _load(path: String) -> ConfigFile:
	var f := ConfigFile.new()
	if f.load(path) != OK:
		return null
	return f

static func _read(path: String, key: String, default_val: Variant) -> Variant:
	var f := _load(path)
	if f == null or not f.has_section_key(SECTION, key):
		return default_val
	return f.get_value(SECTION, key, default_val)

static func _write(path: String, key: String, value: Variant) -> bool:
	var f := ConfigFile.new()
	f.load(path) # a missing file is fine
	f.set_value(SECTION, key, value)
	return f.save(path) == OK

## How many OURS bars to show, 0..HudUnderbar.EXT_BARS_MAX.
static func extra_bars(path: String = ClientSettings.PATH) -> int:
	var v = _read(path, KEY_BARS, DEFAULT_BARS)
	return clampi(int(v), 0, HudUnderbar.EXT_BARS_MAX) if typeof(v) == TYPE_INT else DEFAULT_BARS

## Pages per OURS bar, 1..HudUnderbar.EXT_PAGES_MAX.
static func pages(path: String = ClientSettings.PATH) -> int:
	var v = _read(path, KEY_PAGES, DEFAULT_PAGES)
	return clampi(int(v), 1, HudUnderbar.EXT_PAGES_MAX) if typeof(v) == TYPE_INT else DEFAULT_PAGES

static func save_counts(bars: int, page_count: int, path: String = ClientSettings.PATH) -> bool:
	var ok := _write(path, KEY_BARS, clampi(bars, 0, HudUnderbar.EXT_BARS_MAX))
	return _write(path, KEY_PAGES, clampi(page_count, 1, HudUnderbar.EXT_PAGES_MAX)) and ok

## A bar's six option values; DEFAULT_OPTIONS when none are kept or what is
## kept is not six 0/1 ints (OURS: retail leaves its constructor's values on
## a bad version, open and nothing else; a damaged entry here reads as none).
static func kept_options(bar: int, path: String = ClientSettings.PATH) -> Array:
	var v = _read(path, KEY_OPTIONS % bar, null)
	if not (v is Array) or (v as Array).size() != DEFAULT_OPTIONS.size():
		return DEFAULT_OPTIONS.duplicate()
	var out: Array = []
	for x in v:
		if typeof(x) != TYPE_INT or (int(x) != 0 and int(x) != 1):
			return DEFAULT_OPTIONS.duplicate()
		out.append(int(x))
	return out

static func save_options(bar: int, values: Array, path: String = ClientSettings.PATH) -> bool:
	var clean: Array = []
	for x in values:
		clean.append(1 if bool(x) else 0)
	return _write(path, KEY_OPTIONS % bar, clean)

## A bar's kept position, or null for none (the default place then).
static func kept_position(bar: int, path: String = ClientSettings.PATH) -> Variant:
	var v = _read(path, KEY_POSITION % bar, null)
	if v is Vector2 or v is Vector2i:
		return Vector2(v)
	return null

static func save_position(bar: int, pos: Vector2, path: String = ClientSettings.PATH) -> bool:
	return _write(path, KEY_POSITION % bar, Vector2i(pos.round()))
