extends RefCounted
class_name NavObjectSource

## Which mesh an object's navigation mesh comes from, the way the client's own
## map loader picks it. READ (round 644) from `sro_client.exe`:
##
##   * `FUN_0042ce60` switches on the last letter of the object index's path:
##     'd'/'D' (a `.cpd`) -> `MapLoader::FUN_0042bc00`, 'r'/'R' (a `.bsr`) ->
##     `MapLoader::FUN_0042c4a0`, 's'/'S' (a `.bms`) -> `FUN_0042cbc0`
##     directly; anything else loads nothing.
##   * `FUN_0042c4a0` reads the `.bsr` header (`FUN_0043bfb0`: the 12-byte
##     magic, then fifteen words), and the word it tests is the one at file
##     offset **0x28** (`mov edi,[esp+0x5c]` at 0x42c73d against the header
##     buffer at `esp+0x2c` pushed before the call: 0x54 - 0x2c = 0x28; the
##     decompiler names the wrong local). Zero -> no navigation mesh
##     (`jbe 0x42c5b0`). Otherwise it seeks there (vtable +0x98), reads one
##     length-prefixed string (`FUN_0043c250`) and hands that path to
##     `FUN_0042cbc0`.
##   * `FUN_0042cbc0` reads that `.bms`'s 0x3c-byte header, and when the word
##     at 0x28 -- the collision-section offset -- is non-zero, seeks to it and
##     deserializes that one collision section (`RTNavMeshObj::FUN_004489b0`,
##     with the header word at 0x38 as its record-size bits).
##
## So the client's navigation mesh for a `.bsr` is **one** mesh's collision
## section: the mesh named at the start of the `.bsr`'s bounding-box block
## (the "mesh path before the bounding box" BSR_FORMAT.md lists for the
## building layout). It is not the union of every mesh the `.bsr` lists,
## which is what this project merged from round 505 to round 643.

## The path the client reads at the `.bsr` header word 0x28, or "" when that
## word is zero, out of range, or the string there is not a plausible path.
static func navmesh_path_of_bsr(data: PackedByteArray) -> String:
	if data.size() < 0x2C:
		return ""
	var at := data.decode_u32(0x28)
	if at == 0 or at + 4 > data.size():
		return ""
	var n := data.decode_u32(at)
	# A path longer than the file, or implausibly long, is not one.
	if n == 0 or n > 1024 or at + 4 + n > data.size():
		return ""
	return data.slice(at + 4, at + 4 + n).get_string_from_ascii()

## The navigation mesh the client loads for one object index path, or null
## for none: the `.bsr` branch above, and a path that is itself a `.bms`
## (`FUN_0042ce60`'s 's' case) read directly. A `.cpd` compound
## (`MapLoader::FUN_0042bc00`, the 'd' case) is not read here and gives null,
## as it always has in this project -- OPEN.
##
## MEASURED (round 644, `tools/navmesh_source_census.gd` over Data.pk2's
## `navmesh\object.ifo`, 3,268 entries): for 2,039 objects this is the same
## single mesh the round-505 merge of every mesh found; the merge differed
## on 4 -- three whose 0x28 word names no mesh (`euro_esteuro_ph_box2`,
## `alex_minga07`, `alex_fstair02`: the client gives them no navigation mesh,
## the merge gave them one) and one it merged a second piece into
## (`arabiaf_fpapaya01_03`).
static func load_collision(archive: Pk2Reader, path: String) -> BmsReader.CollisionMesh:
	if archive == null or path == "":
		return null
	var lower := path.to_lower()
	var mesh_path := ""
	if lower.ends_with("s"):
		mesh_path = path
	elif lower.ends_with("r"):
		var bsr_entry := ObjectLoader.find_file(archive, path)
		if bsr_entry == null:
			return null
		mesh_path = navmesh_path_of_bsr(archive.read_file(bsr_entry))
	if mesh_path == "":
		return null
	var mesh_entry := ObjectLoader.find_file(archive, mesh_path)
	if mesh_entry == null:
		return null
	var collision := BmsReader.parse_collision(archive.read_file(mesh_entry))
	if collision == null or collision.cells.is_empty():
		return null
	return collision
