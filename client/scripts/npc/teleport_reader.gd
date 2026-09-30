extends RefCounted
class_name TeleportReader

## The teleport network, read from the player's own Media.pk2 (round 577):
## the gates (teleportdata.txt), the links between them (teleportlink.txt)
## and the structures they stand in (teleportbuilding.txt). The server loads
## the same three tables as CSVs (server/internal/teleport, round 575); the
## client reads them from the archive so a town's Dimensional Gate can be
## found in the world and talked to (World3D._bind_region_gates,
## World3D._npc_services), and so the destination list is the client's own,
## as the retail dialog's is (UI_TELEPORT::FUN_006fd3e0 builds it from the
## client's link records -- docs/protocol/teleport_network.md, "The client's
## list, read").
##
## Columns are 0-based and the same ones server/cmd/export-refdata reads
## (its tp*/tl*/tb* constants), each checked against the retail rows in
## round 575: docs/protocol/teleport_network.md, "The columns srrevamp
## reads". Column 0 is the service flag.

const DATA_TABLE := "server_dep\\silkroad\\textdata\\teleportdata.txt"
const LINK_TABLE := "server_dep\\silkroad\\textdata\\teleportlink.txt"
const BUILDING_TABLE := "server_dep\\silkroad\\textdata\\teleportbuilding.txt"

const COL_SERVICE := 0

## teleportdata.txt: GlobalDataManager::RefParse_teleportdata (client
## 0x976840) reads id, codename, associated object, zone name, then region,
## x, y, z, radius; the two tokens after radius are the flags the server's
## RefTeleport_ExtractData (0x6a7be0) registers as NPC interaction ids 7 and
## 9 on the associated object (round 454; columns 10/11, round 575).
const TP_ID := 1
const TP_CODE := 2
const TP_OBJECT := 3
const TP_ZONE_NAME := 4
const TP_REGION := 5
const TP_X := 6
const TP_Y := 7
const TP_Z := 8
const TP_RADIUS := 9
const TP_INTERACTION7 := 10
const TP_INTERACTION9 := 11

## teleportlink.txt: source and destination teleport ids, and the fee -- the
## word the server compares with gold (GObjPC::HandleTeleportUse 0x513590,
## `mov esi,[edi+0x4]` at 0x5136d7) and the client's dialog shows
## (UI_TELEPORT::FUN_006fd3e0, the link record's +0x10).
const TL_FROM := 1
const TL_TO := 2
const TL_FEE := 3

## teleportbuilding.txt, in the _RefObjCommon prefix's layout
## (docs/protocol/refobj_binary_format.md): id, codename, the name string id
## (SN_NPC_CH_GATE) at 5, RegionID at 41, OffsetX/Y/Z at 43..45.
const TB_ID := 1
const TB_CODE := 2
const TB_NAME := 5
const TB_REGION := 41
const TB_X := 43
const TB_Y := 44
const TB_Z := 45

## One teleport point: a teleportdata row. `region` is the table's region id,
## `(x << 8) | y` as npcpos packs it (NpcTableReader.parse_positions); a
## negative one is a dungeon's. x/y/z are region-local.
class Point:
	var id: int
	var code: String
	var object_id: int
	var zone_strid: String
	var region: int
	var x: float
	var y: float
	var z: float
	var radius: float
	## The two interaction registrations (round 454): id 7 is the client's
	## talk item 9, UIIT_CTL_RECALL_POSITION; id 9 its item 0x10,
	## UIIT_CTL_TELEPORT_TO_RESURRECT_POS (NpcServiceReader.gate_services).
	var interaction7: bool
	var interaction9: bool

## One directed link, in file order.
class Link:
	var from_id: int
	var to_id: int
	var fee: int

## One gate structure: a teleportbuilding row. x/y/z are region-local in
## region (region_x, region_y); `region` < 0 is a dungeon's.
class Building:
	var id: int
	var code: String
	var name_strid: String
	var region: int
	var region_x: int
	var region_y: int
	var x: float
	var y: float
	var z: float

var _points_by_id: Dictionary = {}      # teleport id -> Point
var _point_by_object: Dictionary = {}   # associated object id -> Point
var _links_by_from: Dictionary = {}     # source teleport id -> Array[Link], file order
var _buildings: Array = []              # Building, file order
var _building_by_code: Dictionary = {}  # codename (upper) -> Building
var _link_count := 0

## Parses the three tables through `read`, a callback that returns an
## archive path's bytes (or an empty array), as ShopReader.load takes it.
## Returns self.
func load(read: Callable) -> TeleportReader:
	parse(read.call(DATA_TABLE), read.call(LINK_TABLE), read.call(BUILDING_TABLE))
	return self

## Parses the three tables from their bytes (UTF-16LE with or without the
## BOM, as the archive stores them). A row is kept when its id column is an
## integer and it has every column read. teleportdata and teleportlink rows
## are kept only when their service column is a non-zero integer: the
## client's loader reads that column (FUN_00b9cc80, at 0x954b1a before
## RefParse_teleportdata and at 0x954b9d before RefParse_teleportlink) and
## parses the row only when it is non-zero (server/cmd/export-refdata skips
## a 0 the same way). teleportbuilding's service handling is not read, so
## its column 0 is not filtered (round 575).
func parse(data: PackedByteArray, links: PackedByteArray, buildings: PackedByteArray) -> void:
	for cols in _rows(data):
		if cols.size() <= TP_INTERACTION9 or not _serviced(cols) or not _is_int(cols[TP_ID]):
			continue
		var p := Point.new()
		p.id = int(cols[TP_ID].strip_edges())
		p.code = cols[TP_CODE].strip_edges()
		p.object_id = _int_at(cols, TP_OBJECT)
		p.zone_strid = cols[TP_ZONE_NAME].strip_edges()
		p.region = _int_at(cols, TP_REGION)
		p.x = float(cols[TP_X].strip_edges())
		p.y = float(cols[TP_Y].strip_edges())
		p.z = float(cols[TP_Z].strip_edges())
		p.radius = float(cols[TP_RADIUS].strip_edges())
		p.interaction7 = _int_at(cols, TP_INTERACTION7) != 0
		p.interaction9 = _int_at(cols, TP_INTERACTION9) != 0
		_points_by_id[p.id] = p
		# No two retail points name one object (round 575, measured over the
		# 222 rows); 0 is "none" (118 rows) and is not a join key.
		if p.object_id != 0:
			_point_by_object[p.object_id] = p
	for cols in _rows(links):
		if cols.size() <= TL_FEE or not _serviced(cols) or not _is_int(cols[TL_FROM]):
			continue
		var l := Link.new()
		l.from_id = int(cols[TL_FROM].strip_edges())
		l.to_id = _int_at(cols, TL_TO)
		l.fee = _int_at(cols, TL_FEE)
		if not _links_by_from.has(l.from_id):
			_links_by_from[l.from_id] = []
		_links_by_from[l.from_id].append(l)
		_link_count += 1
	for cols in _rows(buildings):
		if cols.size() <= TB_Z or not _is_int(cols[TB_ID]):
			continue
		var b := Building.new()
		b.id = int(cols[TB_ID].strip_edges())
		b.code = cols[TB_CODE].strip_edges()
		b.name_strid = cols[TB_NAME].strip_edges()
		b.region = _int_at(cols, TB_REGION)
		b.region_x = (b.region >> 8) & 0xFF
		b.region_y = b.region & 0xFF
		b.x = float(cols[TB_X].strip_edges())
		b.y = float(cols[TB_Y].strip_edges())
		b.z = float(cols[TB_Z].strip_edges())
		_buildings.append(b)
		_building_by_code[b.code.to_upper()] = b

## The gate structures that stand in region (rx, ry) -- the folder names of
## `rx\ry.m` -- in file order. Never a dungeon's (a region id below 0).
func buildings_in_region(rx: int, ry: int) -> Array:
	var out: Array = []
	for b in _buildings:
		if b.region > 0 and b.region_x == rx and b.region_y == ry:
			out.append(b)
	return out

## The gate structure named `code` (teleportbuilding's codename), or null.
func building_by_code(code: String) -> Building:
	return _building_by_code.get(code.strip_edges().to_upper())

## The teleport point a gate structure is, joined by its id: teleportdata's
## associated object (column 3) is the building's id (GATE_CH's 2094 is
## STORE_CH_GATE's row -- docs/protocol/teleport_network.md,
## "teleportbuilding.txt -- the gate objects"). null for a codename that is
## not a building or a building no point names.
func point_for_building(code: String) -> Point:
	var b: Building = _building_by_code.get(code.strip_edges().to_upper())
	if b == null:
		return null
	return _point_by_object.get(b.id)

## The teleport point whose associated object (teleportdata column 3) is ref
## object `object_id` -- a gate building's id or, since round 642, an NPC's
## characterdata id (2011 NPC_CH_FERRY -> GATE_NPC_CH_FERRY). null for 0 or an
## object no point names.
func point_for_object(object_id: int) -> Point:
	if object_id == 0:
		return null
	return _point_by_object.get(object_id)

## The links leaving a point, in file order (the order the retail dialog
## numbers them in, FUN_00976a30(k) for k = 0..count-1).
func links_from(point_id: int) -> Array:
	return (_links_by_from.get(point_id, []) as Array).duplicate()

## The teleport point with teleportdata id `point_id`, or null.
func point_by_id(point_id: int) -> Point:
	return _points_by_id.get(point_id)

## A point's zone-name string id (SN_ZONE_22001 for GATE_CH), which
## textdata_object names; "" for an unknown point.
func place_token(point_id: int) -> String:
	var p: Point = _points_by_id.get(point_id)
	return p.zone_strid if p != null else ""

## "<points> point(s), <links> link(s), <buildings> building(s)", for the
## NPC tables' load line.
func summary() -> String:
	return "%d teleport point(s), %d link(s), %d gate building(s)" % [
		_points_by_id.size(), _link_count, _buildings.size()]

static func _serviced(cols: PackedStringArray) -> bool:
	return _is_int(cols[COL_SERVICE]) and int(cols[COL_SERVICE].strip_edges()) != 0

static func _is_int(field: String) -> bool:
	return field.strip_edges().is_valid_int()

static func _int_at(cols: PackedStringArray, col: int) -> int:
	if col >= cols.size() or not _is_int(cols[col]):
		return 0
	return int(cols[col].strip_edges())

## The table's rows, split on tabs. The UTF-16LE BOM (FF FE) is stripped
## before decoding, as npc_service_reader.gd and ui_text_table.gd do. The
## first row matters -- teleportdata.txt's is GATE_CH (Jangan),
## teleportlink.txt's Jangan -> Donwhang -- and a BOM left on its first field
## would fail the service column's integer test and drop it. Godot 4.2.2's
## get_string_from_utf16 drops a leading BOM by itself (measured on the
## render box, round 577: FF FE + "1\tx" decodes to 3 characters, the first
## "1"), so the strip is kept for an engine that does not.
## teleport_reader_test.gd holds row 1 read with the BOM. Blank lines and
## the trailing //Copyright line are skipped.
static func _rows(data: PackedByteArray) -> Array:
	var out: Array = []
	if data == null or data.is_empty():
		return out
	var raw := data
	if raw.size() >= 2 and raw[0] == 0xFF and raw[1] == 0xFE:
		raw = raw.slice(2)
	var text := raw.get_string_from_utf16()
	if text.is_empty():
		text = raw.get_string_from_utf8()
	for line in text.replace("\r", "").split("\n"):
		if line.strip_edges() == "" or line.begins_with("//"):
			continue
		out.append(line.split("\t"))
	return out
