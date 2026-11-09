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
##     length-prefixed string (`FUN_0043c250`: a u32 length, then that many
##     bytes; a length of 0 leaves the string empty) and hands that path to
##     `FUN_0042cbc0` -- an empty one too: nothing between the read and the
##     call tests it.
##   * `FUN_0042cbc0` opens the path through the loader's file manager
##     (the object at loader +0x28, its vtable +0x28, access 0x80000000):
##     as given when the loader's +0x14 is non-zero, else prefixed with
##     "data\\" (`MapLoader::FUN_0043a3c0`; `cmp [esi+0x14],ebx` at 0x42cc44).
##     A failed open returns 0 -- no navigation mesh (0x42cc85, 0x42cd0c).
##     An open file's 0x3c-byte header is read, and when its word at 0x28 --
##     the collision-section offset -- is non-zero, that one collision
##     section is deserialized (`RTNavMeshObj::FUN_004489b0`, with the header
##     word at 0x38 as its record-size bits); a zero word returns 0.
##   * **An empty path** therefore opens "data\\" (or ""). What the file
##     manager's open does with a directory name is NOT READ: it is not in
##     `sro_client.exe` but in GFXFileManager.dll. If it fails, the object
##     has no navigation mesh; that it fails is INFERRED (a directory is not
##     a file), and it is what this class does.
##
## So the client's navigation mesh for a `.bsr` is **one** mesh's collision
## section: the mesh named at the start of the `.bsr`'s bounding-box block
## (the "mesh path before the bounding box" BSR_FORMAT.md lists for the
## building layout). It is not the union of every mesh the `.bsr` lists,
## which is what this project merged from round 505 to round 643.

## The path the client reads at the `.bsr` header word 0x28, or "" when that
## word is zero, out of range, or the string there is empty or not a
## plausible path.
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
## (`FUN_0042ce60`'s 's' case) read directly, and (round 869) a `.cpd` compound
## (`MapLoader::FUN_0042bc00`, the 'd' case): the .bsr its header word 0x0C
## names, through the .bsr branch (navmesh_bsr_of_cpd). Until round 869 a
## compound gave null, and the Wrecked Ship's decks had no walkable surface.
##
## MEASURED (round 644, `tools/navmesh_source_census.gd` over Data.pk2's
## `navmesh\object.ifo`, 3,268 entries): for 2,039 objects this is the same
## single mesh the round-505 merge of every mesh found; the merge differed
## on 4 -- three whose 0x28 path is EMPTY and one it merged a second piece
## into (`arabiaf_fpapaya01_03`). The three are not zero words: the word is
## 140 (`euro_esteuro_ph_box2`), 132 (`alex_minga07`) and 133
## (`alex_fstair02`) and points at a length of 0 (MEASURED, round 644
## review), so the client calls `FUN_0042cbc0("")` -- see above for what is
## read of that. The merge gave each a mesh (`euro_esteuro_ph_box2.bms`,
## `alex_minga07_01.bms`, `alex_fstair02_02.bms`); this gives none. MEASURED
## too: no `.nvm` file places any of the three, in its own list or as a
## cross-reference, so neither choice reaches a walk.
## The .bsr a compound's header word 0x0C names (READ, MapLoader::FUN_0042bc00),
## or "" when the word is 0, out of range, or the string there is empty.
static func navmesh_bsr_of_cpd(data: PackedByteArray) -> String:
	if data.size() < 0x10 or data.slice(0, 7).get_string_from_ascii() != "JMXVCPD":
		return ""
	var at := data.decode_u32(0x0C)
	if at == 0 or at + 4 > data.size():
		return ""
	var n := data.decode_u32(at)
	if n == 0 or at + 4 + n > data.size() or n > 512:
		return ""
	var p := data.slice(at + 4, at + 4 + n).get_string_from_ascii()
	return p if p.to_lower().ends_with(".bsr") else ""

static func load_collision(archive: Pk2Reader, path: String) -> BmsReader.CollisionMesh:
	if archive == null or path == "":
		return null
	var lower := path.to_lower()
	var mesh_path := ""
	if lower.ends_with("d"):
		# Round 869 (READ MapLoader::FUN_0042bc00, the 'd' case): the compound's
		# header word at 0x0C (c:0x42bdcb..0x42bdd9: FUN_0043c470 reads the
		# 12-byte magic and nine words; the first, at file offset 0x0C, is
		# tested) is a file offset; a non-zero one is sought (vtable +0x98),
		# one length-prefixed string read there (FUN_0043c250: u32 length,
		# bytes), and a non-empty one handed to the .bsr branch
		# (FUN_0042c4a0). MEASURED: the Wrecked Ship's
		# wreck_sship_in_01.cpd names res\dun\property\wreck\ship\
		# wreck_sship_in_01.bsr there (offset 73).
		var cpd_entry := ObjectLoader.find_file(archive, path)
		if cpd_entry == null:
			return null
		var bsr_path := navmesh_bsr_of_cpd(archive.read_file(cpd_entry))
		if bsr_path == "":
			return null
		return load_collision(archive, bsr_path)
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
