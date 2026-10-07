extends RefCounted
class_name ForceAddObjectReader

## Media.pk2's `server_dep\silkroad\textdata\force_addobject.txt`: the map
## objects the client adds beside every region's `.o2` (round 643's review).
## Every rule here is READ in sro_client.exe unless marked otherwise:
##
## - The file is loaded by Client_LoadAllRefData (`"%stextdata\\
##   force_addobject.txt"`, GlobalDataManager::Client_LoadRefDataFile type
##   0x3d). A row is 11 tab-separated columns (the file's own header, in
##   Korean: service, BSR path, region X, region Y, X, Y, Z, rotation,
##   type (flag 0 / structure 1), guild 0 / alliance 1, fortress id). A row
##   whose service column is 0 is not loaded. Region X goes to the row's
##   byte +0x1c and region Y to +0x1d, so the row's region is the packed
##   `(regionY << 8) | regionX` -- the `.o2` owner field's shape, and the
##   `<regionY>\<regionX>` folder. X, Y, Z and the rotation are floats;
##   type and guild are bytes; the fortress id is looked up
##   (FUN_00927350, asserting it resolves) and the row keeps
##   `type << 24 | guild << 16 | fortress` at +0x38.
## - FUN_00927620 hands every loaded row to SWorld::vslot_045 (path, region,
##   &position, rotation, that packed word). vslot_045 finds the path in the
##   world's object-path table case-insensitively (CompareStringA with
##   NORM_IGNORECASE; a path it lacks is appended as a new type), and files
##   a 30-byte record -- the `.o2` record's layout: the type, the position
##   as given, the rotation at +18, and a uid whose bits 13-15 are
##   `int(z) / 320 & 7` and bits 10-12 `int(x) / 320 & 7` (the sector) --
##   under the row's region.
## - When that region's `.o2` is loaded, the tail of FUN_00a361b0 takes the
##   region's filed records, gives each the low 10 bits of its uid from a
##   per-sector counter that starts at 0x3ff and counts down, builds it by
##   the key CONCAT22(region, uid) through Map::FUN_00a1a1d0 -- the same
##   refcounted cache and creator (FUN_00a33530, which copies the record
##   verbatim, so the position is used as given) as the `.o2`'s own records
##   -- stores the packed word at the object's +0x37, and appends the object
##   to the sector's list-1 array. There is no skip-bit test on this path.
##
## The row order the counter walks is the file's (INFERRED: vslot_045
## appends to the region's list; the key only has to be unique).
##
## OPEN: the fortress state. For an object whose +0x37 word is neither 0 nor
## -1 the loader calls the world's callback (world+0x7b34, installed through
## SWorld::vslot_011 as LAB_004ff8c0): a flag gets its guild's or
## alliance's emblem texture, and a structure has FUN_0052d4e0 called with
## arguments chosen by its fortress record's state bits (a clip lookup and
## play by its shape, INFERRED). No visibility write was found there, but
## its vtable calls were not followed, so whether a state HIDES a row is
## not known. This client draws every loaded row, the flags with their own
## texture and no emblem (OURS).
##
## Collision: this path attaches none (FUN_00a33530 copies the record only).
## The bridges' walkable surface is the region `.nvm`'s own copy of each
## (at the `.o2`'s skip-bit Y, 53.7, with the model's navmesh plane at local
## y 5.3); the drawn model at the row's Y 848 has its piers' vertices down to
## local y -1686 and its top at 63.6 (MEASURED, round 643's review).

const PATH := "server_dep\\silkroad\\textdata\\force_addobject.txt"
## The sector size the uid's sector bits divide by (READ: the double at
## sro_client.exe 0xe1b908, 320.0 -- 1920 / 6).
const SECTOR_SPAN := 320.0

class Row:
	var path: String
	## The packed region `(regionY << 8) | regionX` -- World3D's
	## `<x>\<y>` folder with x = regionY, y = regionX.
	var region: int
	var position: Vector3
	var yaw: float
	## 0 a fortress flag, 1 a structure (the file's own header).
	var kind: int
	## 0 guild, 1 alliance, 2 both (the file's header names 0 and 1; the
	## rows also carry 2).
	var guild: int
	var fortress: String

## The loaded rows (service column not 0), in file order. Lines starting
## with "//" and lines with fewer than 11 columns are not rows.
static func parse(bytes: PackedByteArray) -> Array[Row]:
	var rows: Array[Row] = []
	if bytes.is_empty():
		return rows
	var text := TextDecode.utf16(bytes) if bytes.size() >= 2 and bytes[0] == 0xFF and bytes[1] == 0xFE else bytes.get_string_from_utf8()
	for raw_line in text.split("\n"):
		var line := raw_line.strip_edges(false, true)
		if line.begins_with("//") or line.strip_edges() == "":
			continue
		var cols := line.split("\t")
		if cols.size() < 11 or not cols[0].strip_edges().is_valid_int():
			continue
		if int(cols[0]) == 0:
			continue
		var row := Row.new()
		row.path = cols[1].strip_edges()
		row.region = ((int(cols[3]) & 0xFF) << 8) | (int(cols[2]) & 0xFF)
		row.position = Vector3(float(cols[4]), float(cols[5]), float(cols[6]))
		row.yaw = float(cols[7])
		row.kind = int(cols[8])
		row.guild = int(cols[9])
		row.fortress = cols[10].strip_edges()
		rows.append(row)
	return rows

## The rows filed under region `<region_x>\<region_y>`.
static func rows_for(rows: Array[Row], region_x: int, region_y: int) -> Array[Row]:
	var out: Array[Row] = []
	var packed := ((region_x & 0xFF) << 8) | (region_y & 0xFF)
	for row in rows:
		if row.region == packed:
			out.append(row)
	return out

## The uid the loader gives the n-th row of a region: the sector bits from
## the position, the low 10 bits from the per-sector counter (0x3ff, 0x3fe,
## ...). `counters` is sector index -> the next value, shared by one
## region's rows.
static func uid_for(position: Vector3, counters: Dictionary) -> int:
	var row := (int(position.z) / int(SECTOR_SPAN)) & 7
	var col := (int(position.x) / int(SECTOR_SPAN)) & 7
	var sector := col + row * 6
	var counter: int = counters.get(sector, 0x3FF)
	counters[sector] = counter - 1
	return ((row * 8 + col) << 10) | (counter & 0x3FF)

## One region's rows as World3D placements: `{type_id, path, position,
## rotation, key, force}` -- the position as given (the creator copies it),
## the type the object index names for the path case-insensitively (-1 when
## it names none; the path is then drawn by name, as vslot_045 appends it),
## and the loader's key.
static func placements(rows: Array[Row], table: ObjidxReader.Table) -> Array:
	var by_path := {}
	if table != null:
		for e in table.entries:
			if e != null and not by_path.has(e.path.to_lower()):
				by_path[e.path.to_lower()] = e.type_id
	var out: Array = []
	var counters := {}
	for row in rows:
		var uid := uid_for(row.position, counters)
		out.append({"type_id": int(by_path.get(row.path.to_lower(), -1)), "path": row.path,
			"position": row.position, "rotation": row.yaw, "key": (row.region << 16) | uid, "force": true,
			"fortress": row.fortress, "kind": row.kind})
	return out
