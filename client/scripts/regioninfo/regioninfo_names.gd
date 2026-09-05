class_name RegioninfoNames

## Turns a RegioninfoReader zone's `name_key` into something displayable.
##
## The real `regioninfo.txt` stores every real zone name in **EUC-KR**, and
## carries no English at all (see docs/protocol/REGIONINFO_FORMAT.md).
## Godot has no built-in EUC-KR decoder, so this project cannot render the
## real Korean names straight from the file today.
##
## **Everything in DEFAULT_NAMES below is written by this project, not read
## from the real file.** They are the ordinary transliterations of the real
## Korean names, supplied so the zone label can say something useful now;
## they are a disclosed choice in exactly the same sense as
## BOUNDARY_BLEND_ALPHA, and no part of them is a claim about real client
## text. A real localized client gets its labels from a real text resource
## instead, which this project does not read yet.
##
## Overrides exist so none of that is baked in: a caller can replace any
## name, or supply the real Korean once a decoder exists, without touching
## this table. `set_override`/`set_overrides` win over DEFAULT_NAMES, and
## an unknown key resolves to "" rather than to a guess, so a caller can
## honestly show nothing.

## Real lowercase-hex EUC-KR name bytes -> this project's own English
## transliteration. Keys are exactly what RegioninfoReader.Zone.name_key
## produces. The comment on each line is the real Korean it encodes.
const DEFAULT_NAMES := {
	"c0e5bec8": "Jangan",                       # 장안
	"c0e5bec8c7cab5e5": "Jangan Field",         # 장안필드
	"b5b7c8b2": "Donwhang",                     # 돈황
	"b5b7c8b2c7cab5e5": "Donwhang Field",       # 돈황필드
	"c8a3c5ba": "Hotan",                        # 호탄
	"c8a3c5bac7cab5e5": "Hotan Field",          # 호탄필드
	"c4abb6f3c4dab6f7": "Karakoram",            # 카라코람
	"b5b7c8b2b4f8c1af": "Donwhang Dungeon",     # 돈황던젼
	"c5b8c5acb6f3b8b6c4ad": "Taklamakan",       # 타클라마칸
	"b7cec5a9bbea": "Roc Mountain",             # 로크산
	"c4dcbdbac5bac6bcb3ebc7c3": "Constantinople", # 콘스탄티노플
	"b5bfc0afb7b4": "East Europe",              # 동유럽
	"bcd2bec6bdc3bec6": "Asia Minor",           # 소아시아
	"bbe7b8b6b8a3c4adc6ae": "Samarkand",        # 사마르칸트
	"c1dfbed3bec6bdc3bec6": "Central Asia",     # 중앙아시아
}

static var _overrides: Dictionary = {}

## Replaces (or adds) the display name for one real name key.
static func set_override(name_key: String, display_name: String) -> void:
	_overrides[name_key] = display_name

## Bulk form of set_override -- merges, so a partial table only replaces
## the keys it actually mentions.
static func set_overrides(names: Dictionary) -> void:
	for key in names:
		_overrides[key] = names[key]

static func clear_overrides() -> void:
	_overrides.clear()

## The display name for a real zone name key: an override if one is set,
## otherwise this project's own transliteration, otherwise "" -- never a
## fabricated stand-in built out of the key itself.
static func display_for(name_key: String) -> String:
	if _overrides.has(name_key):
		return _overrides[name_key]
	if DEFAULT_NAMES.has(name_key):
		return DEFAULT_NAMES[name_key]
	return ""

## The display name of whichever real zone owns this whole real region, or
## "" when the answer depends on where in the region you stand (see
## RegioninfoReader.sole_zone_for) or when nothing claims it.
static func display_for_region(table: RegioninfoReader.ParsedTable, region_x: int, region_y: int) -> String:
	if table == null:
		return ""
	return _name_of(table, table.sole_zone_for(region_x, region_y))

## The display name of the real zone a position falls in, resolved the way
## the real client resolves it. Prefer this wherever real region-local
## coordinates are available -- it is exact, and it names the 47 real
## regions display_for_region has to decline.
static func display_for_position(
	table: RegioninfoReader.ParsedTable, region_x: int, region_y: int,
	local_x: float, local_z: float
) -> String:
	if table == null:
		return ""
	return _name_of(table, table.zone_for_position(region_x, region_y, local_x, local_z))

static func _name_of(table: RegioninfoReader.ParsedTable, zone_index: int) -> String:
	if zone_index < 0 or zone_index >= table.zones.size():
		return ""
	return display_for(table.zones[zone_index].name_key)
