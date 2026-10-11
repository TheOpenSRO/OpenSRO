extends RefCounted
class_name OptionalTeleportReader

## `refoptionalteleport.txt` (round 778): the places the reverse return
## scroll's map option offers, read from the player's own Media.pk2.
## docs/protocol/reverse_return_scroll.md has the system.
##
## READ (Client_LoadRefDataFile case 0x4e, 0x956ba0..0x956d56): column 0 is
## the service flag (a 0 row is not parsed), then the id (record +0), the
## object name, the zone name (+0x20, an SN_ZONE_ key), the region word
## (+0x3c), x, y, z as floats (+0x40..+0x48), the world (+0x4c), the region
## group (+0x50) and the map-point byte (+0x54); the record is filed by id
## and, by group, in a second map (+0x69c) the world map's popup reads
## (FUN_0094d270). Columns 11/12 are the level range the SERVER tests
## (INFERRED: the client does not read them; server/internal/teleport/
## optional.go). The map draws an icon for each map-point row
## (GlobalDataManager::FUN_00927850), and a click on a group's icon lists the
## group's rows whose map-point byte is not 1 (CNIFWorldMap::vslot_017,
## 0x6236e2..0x623761).

const TABLE := "server_dep\\silkroad\\textdata\\refoptionalteleport.txt"

const COL_SERVICE := 0
const COL_ID := 1
const COL_ZONE_NAME := 3
const COL_REGION := 4
const COL_X := 5
const COL_Y := 6
const COL_Z := 7
const COL_WORLD := 8
const COL_GROUP := 9
const COL_MAP_POINT := 10
const COL_LEVEL_MIN := 11
const COL_LEVEL_MAX := 12

## A point standing alone (the group column's -1).
const NO_GROUP := -1

class Point:
	var id: int
	## The name key, "xxx" on a group's flag row.
	var zone_strid: String
	## (x << 8) | y; negative (bit 15) for a dungeon, whose x/y/z are its own.
	var region: int
	var x: float
	var y: float
	var z: float
	var world: int
	var group: int
	var map_point: bool
	var level_min: int
	var level_max: int

	## The region's x and y (the map's "rx" is the id's high byte).
	func region_x() -> int:
		return (region >> 8) & 0xff

	func region_y() -> int:
		return region & 0xff

	func in_dungeon() -> bool:
		return region < 0 or (region & 0x8000) != 0

var _points: Array = []       # Point, file order
var _by_id: Dictionary = {}   # id -> Point
var _by_group: Dictionary = {} # group -> Array[Point], file order

## Reads the table through `read` (an archive path's bytes, or an empty
## array), as TeleportReader.load does. Returns self.
func load(read: Callable) -> OptionalTeleportReader:
	parse(read.call(TABLE))
	supplement_tomb_floors()
	return self

## The Qin-Shi tomb's floors under its map flag (round 779, OURS; the
## server's teleport.TombFloorRows has the reasoning and places them). The
## archive's flag (region 26284, group 2) lists nothing -- ids 32..38 are
## absent (MEASURED) -- while the user's own client lists "Tomb of Qin-Shi
## Emperor lv.2", "lv.3" and "lv.4" there: the game's own zone name keys
## SN_ZONE_26002..26004. Added only when the flag is there and its group has
## no rows, never over an id the table has. Returns how many were added.
const TOMB_FLAG_REGION := 26284
const TOMB_FLAG_GROUP := 2
const TOMB_FLOOR_ROWS := [
	[32, "SN_ZONE_26002", -32762],
	[33, "SN_ZONE_26003", -32763],
	[34, "SN_ZONE_26004", -32764],
]

func supplement_tomb_floors() -> int:
	var flag := false
	for p in _points:
		var pt: Point = p
		if pt.group == TOMB_FLAG_GROUP and pt.map_point and pt.region == TOMB_FLAG_REGION:
			flag = true
		elif pt.group == TOMB_FLAG_GROUP and not pt.map_point:
			return 0
	if not flag:
		return 0
	var added := 0
	for row in TOMB_FLOOR_ROWS:
		if _by_id.has(int(row[0])):
			continue
		var p := Point.new()
		p.id = int(row[0])
		p.zone_strid = String(row[1])
		p.region = int(row[2])
		p.world = 1
		p.group = TOMB_FLAG_GROUP
		p.map_point = false
		_points.append(p)
		_by_id[p.id] = p
		if not _by_group.has(p.group):
			_by_group[p.group] = []
		_by_group[p.group].append(p)
		added += 1
	return added

func parse(data: PackedByteArray) -> void:
	for cols in TeleportReader._rows(data):
		if cols.size() <= COL_MAP_POINT or not TeleportReader._serviced(cols) or not TeleportReader._is_int(cols[COL_ID]):
			continue
		var p := Point.new()
		p.id = int(cols[COL_ID].strip_edges())
		p.zone_strid = cols[COL_ZONE_NAME].strip_edges()
		p.region = TeleportReader._int_at(cols, COL_REGION)
		p.x = float(cols[COL_X].strip_edges())
		p.y = float(cols[COL_Y].strip_edges())
		p.z = float(cols[COL_Z].strip_edges())
		p.world = TeleportReader._int_at(cols, COL_WORLD)
		p.group = TeleportReader._int_at(cols, COL_GROUP)
		p.map_point = TeleportReader._int_at(cols, COL_MAP_POINT) == 1
		p.level_min = TeleportReader._int_at(cols, COL_LEVEL_MIN)
		p.level_max = TeleportReader._int_at(cols, COL_LEVEL_MAX)
		_points.append(p)
		_by_id[p.id] = p
		if not _by_group.has(p.group):
			_by_group[p.group] = []
		_by_group[p.group].append(p)

func size() -> int:
	return _points.size()

func point(id: int) -> Point:
	return _by_id.get(id)

## The rows the world map draws an icon for (map-point byte 1), file order.
func map_points() -> Array:
	var out: Array = []
	for p in _points:
		if (p as Point).map_point:
			out.append(p)
	return out

## What a click on icon `p` lists (0x6236e2..0x623761): a point standing
## alone lists itself; a group's flag lists the group's rows whose map-point
## byte is not 1, in file order.
func choices_for(p: Point) -> Array:
	if p == null:
		return []
	if p.group == NO_GROUP:
		return [p]
	var out: Array = []
	for q in _by_group.get(p.group, []):
		if not (q as Point).map_point:
			out.append(q)
	return out
