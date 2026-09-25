extends SceneTree

## The grid's origin, _grid_origin_world -- the frame region's corner, which
## the streaming test (World3D._maybe_stream_regions -> RegionGridState.cell_at)
## measures the player from -- is the same whether or not the centre region's
## terrain loaded (round 571, World3D._frame_corner). Run headless:
##   godot4 --headless --path client --script res://scripts/world/grid_origin_test.gd
##
## Round 570's review: _load_region_neighborhood read the corner off the centre
## group and took Vector3.ZERO as that group's position when the centre's
## terrain failed to load. With the frame not the centre -- the server's
## -single-frame names 97/168 for every town but Jangan -- the corner then
## landed at minus the centre's cell_world_offset, and the streaming test put a
## player at Donwhang's landing in a region far from 102/153 (derived below,
## never typed). With the frame the centre it was half a region off.
##
## World3D._load_region_neighborhood itself runs, radius 0 (the centre only),
## on bare instances of the script (no _ready, not in the tree), whose three
## archives are ONE synthetic pk2 holding only `97\168.m` -- the layout
## terrain_prepare_test.gd writes (docs/protocol/PK2_FORMAT.md,
## MAPM_FORMAT.md); never game data. So the frame 97/168 has a height to
## anchor on and 102/153 has no terrain, which is the failed centre under test.
## Every expected position is derived from World3D._group_position and
## RegionGridState.frame_world (the port of server/internal/worldmap.ToWorld)
## -- region y -> world X, region x -> world Z, Z mirrored (AGENTS.md).
##
## NEGATIVE: on the tree before round 571 the two failed-centre cases FAIL on
## their _grid_origin_world checks (no parse error: World3D is reached through
## load() and call()), and the loaded-centre case passes -- it is the value
## the old code read off the group.
##
## Freeing the loaded-centre instance prints one `ERROR: Parameter "m" is
## null` from the headless dummy renderer's mesh_get_surface_count (located by
## probe prints around the free; clearing SubPatch's material_override first
## does not stop it; not traced further -- terrain_prepare_test.gd's textured
## commit does not print it, this archive has no tile table). It is not a
## failure (remote_godot.sh: `ERROR:` is not one; round 556's audit), and
## every check has already run.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## World3D.gd needs the NetClient autoload registered before it compiles,
## which is the case in _initialize and not in _init (world3d_reentry_test.gd).
func _initialize() -> void:
	var S := load("res://scripts/World3D.gd") as GDScript
	var state_script := load("res://scripts/world/region_grid_state.gd") as GDScript
	_check(S != null and S.can_instantiate(), "World3D.gd loads and can instantiate headless")
	if S == null or not S.can_instantiate() or state_script == null:
		_finish()
		return
	var names := {}
	for m in S.get_script_method_list():
		names[m["name"]] = true
	_check(names.has("_frame_corner"), "World3D has _frame_corner (absent before round 571)")

	var mapm := _build_mapm()
	var frame_anchor := MapmTerrainBuilder.near_row_middle_height(MapmReader.parse(mapm))
	var path := "user://srrevamp_r571_grid_origin.pk2"
	_write_pk2(path, {"97\\168.m": mapm})
	var pk2 := Pk2Reader.open(path)
	_check(pk2 != null, "the synthetic archive opens")
	if pk2 == null:
		_finish()
		return

	_test_frame_not_the_centre(S, state_script, pk2, frame_anchor)
	_test_frame_is_the_centre(S, state_script, pk2)
	_test_centre_loaded(S, pk2, frame_anchor)

	pk2.close()
	DirAccess.remove_absolute(path)
	_finish()

## A bare World3D reading only `pk2`: every table it would load on the way
## finds nothing there, and no Pk2Config path (the box's own archives) is
## consulted, because each archive member is already set.
func _world(S: GDScript, pk2: Pk2Reader) -> Node:
	var w: Node = S.new()
	w.set("_map_pk2", pk2)
	w.set("_data_pk2", pk2)
	w.set("_media_pk2", pk2)
	return w

## -single-frame's Donwhang: centre 102/153 in 97/168's frame, the centre's
## terrain missing.
func _test_frame_not_the_centre(S: GDScript, state_script: GDScript, pk2: Pk2Reader, frame_anchor: float) -> void:
	var w := _world(S, pk2)
	w.call("_load_region_neighborhood", 102, 153, 0, "", {"x": 97, "y": 168})
	var cell := Vector2i(102 - 97, 153 - 168)
	# The probe: the case is the one meant -- the frame's anchor was read and
	# the centre has no terrain group.
	_check(w.get_node_or_null("RealTerrain_102_153") == null, "102/153 has no terrain in the archive: the centre failed to load")
	_check(w.get("_grid_shared_anchor_height") == frame_anchor,
		"the grid's anchor is 97/168's near-row height, %s (got %s)" % [frame_anchor, w.get("_grid_shared_anchor_height")])
	_check(w.get("_last_stream_cell") == cell, "the loader put the centre at cell %s (got %s)" % [cell, w.get("_last_stream_cell")])

	var corner: Vector3 = w.call("_group_position", Vector3.ZERO, frame_anchor)
	var origin: Vector3 = w.get("_grid_origin_world")
	_check(origin == corner, "_grid_origin_world is 97/168's corner %s with the centre missing (got %s)" % [corner, origin])
	# The streaming test at points of 102/153 -- the landing (its middle,
	# worldmap.Landing) and its four corners -- finds 102/153; points of the
	# neighbours find the neighbours.
	for local in [Vector2(960.0, 960.0), Vector2(10.0, 10.0), Vector2(1910.0, 10.0), Vector2(10.0, 1910.0), Vector2(1910.0, 1910.0)]:
		var at: Vector2 = state_script.call("frame_world", 102, 153, local.x, local.y, 97, 168)
		var got: Vector2i = state_script.call("cell_at", Vector3(at.x, 0.0, at.y) - origin)
		_check(got == cell, "102/153 local %s, world %s, streams as cell %s (got %s)" % [local, at, cell, got])
	for n in [[103, 153], [101, 153], [102, 154], [102, 152]]:
		var at: Vector2 = state_script.call("frame_world", n[0], n[1], 960.0, 960.0, 97, 168)
		var want := Vector2i(n[0] - 97, n[1] - 168)
		var got: Vector2i = state_script.call("cell_at", Vector3(at.x, 0.0, at.y) - origin)
		_check(got == want, "%d/%d's middle streams as cell %s (got %s)" % [n[0], n[1], want, got])
	# What the pre-571 fallback gave: Vector3.ZERO as the centre's position,
	# less its cell_world_offset. Derived, so the check above discriminates.
	var old: Vector3 = Vector3.ZERO - state_script.call("cell_world_offset", cell.x, cell.y)
	var landing: Vector2 = state_script.call("frame_world", 102, 153, 960.0, 960.0, 97, 168)
	var old_cell: Vector2i = state_script.call("cell_at", Vector3(landing.x, 0.0, landing.y) - old)
	_check(old_cell != cell, "the pre-571 corner %s would stream the landing as cell %s = region %d/%d, not 102/153" % [
		old, old_cell, 97 + old_cell.x, 168 + old_cell.y])
	if S.get_script_method_list().any(func(m): return m["name"] == "_frame_corner"):
		_check(w.call("_frame_corner", frame_anchor) == corner, "_frame_corner is _group_position of no offset")
	w.free()

## A zone in its own frame (the default), the centre's terrain missing: no
## height is known, and the corner is still the centre region's corner.
func _test_frame_is_the_centre(S: GDScript, state_script: GDScript, pk2: Pk2Reader) -> void:
	var w := _world(S, pk2)
	w.call("_load_region_neighborhood", 102, 153, 0)
	_check(w.get_node_or_null("RealTerrain_102_153") == null, "frame = centre 102/153: the centre failed to load")
	_check(is_nan(w.get("_grid_shared_anchor_height")), "no anchor: the frame is the centre and it has no terrain")
	var corner: Vector3 = w.call("_group_position", Vector3.ZERO, 0.0)
	var origin: Vector3 = w.get("_grid_origin_world")
	_check(origin == corner, "_grid_origin_world is the centre region's corner %s, y 0 (got %s)" % [corner, origin])
	# The west and east halves of the region are both cell (0, 0).
	for local in [Vector2(10.0, 960.0), Vector2(1910.0, 960.0), Vector2(960.0, 10.0), Vector2(960.0, 1910.0)]:
		var at: Vector2 = state_script.call("frame_world", 102, 153, local.x, local.y, 102, 153)
		var got: Vector2i = state_script.call("cell_at", Vector3(at.x, 0.0, at.y) - origin)
		_check(got == Vector2i.ZERO, "local %s streams as cell (0, 0) (got %s)" % [local, got])
	var west: Vector2 = state_script.call("frame_world", 102, 153, 10.0, 960.0, 102, 153)
	var old_cell: Vector2i = state_script.call("cell_at", Vector3(west.x, 0.0, west.y))
	_check(old_cell != Vector2i.ZERO, "the pre-571 corner (0, 0, 0) would stream the west half as cell %s" % old_cell)
	w.free()

## The centre's terrain loads (97/168, its own frame): the corner is where its
## group stands -- the value the code before round 571 read off the group.
func _test_centre_loaded(S: GDScript, pk2: Pk2Reader, frame_anchor: float) -> void:
	var w := _world(S, pk2)
	# The scene's ground stand-ins, which the terrain commit hides, stubbed
	# (terrain_prepare_test.gd's pattern).
	var stub_mesh := MeshInstance3D.new()
	var stub_collision := CollisionShape3D.new()
	w.set("ground_mesh", stub_mesh)
	w.set("ground_collision", stub_collision)
	w.call("_load_region_neighborhood", 97, 168, 0)
	var group := w.get_node_or_null("RealTerrain_97_168") as Node3D
	_check(group != null, "97/168's terrain loaded as the centre")
	_check(w.get("_grid_shared_anchor_height") == frame_anchor, "the centre calibrated on its own near-row height")
	if group != null:
		_check(w.get("_grid_origin_world") == group.position,
			"_grid_origin_world is the centre group's own position %s (got %s)" % [group.position, w.get("_grid_origin_world")])
	w.set("ground_mesh", null)
	w.set("ground_collision", null)
	stub_mesh.free()
	stub_collision.free()
	# Freed now, before the frame ends: the commit deferred a player snap,
	# which a freed instance never runs.
	w.free()

## A synthetic pk2 holding `files` ({"folder\\name": bytes}), one directory
## block per folder, unencrypted -- terrain_prepare_test.gd's writer, the
## layout Pk2Reader reads (docs/protocol/PK2_FORMAT.md). Each block's first
## entry is ".", which the reader skips; at most 19 children a folder.
func _write_pk2(path: String, files: Dictionary) -> void:
	var children := {"": []}
	var order: Array[String] = [""]
	for fp in files:
		var parts := (fp as String).split("\\")
		var parent := ""
		for i in range(parts.size() - 1):
			var here: String = parts[i] if parent == "" else parent + "\\" + parts[i]
			if not children.has(here):
				children[here] = []
				order.append(here)
				(children[parent] as Array).append([parts[i], true, here])
			parent = here
		(children[parent] as Array).append([parts[-1], false, fp])
	var block_at := {}
	for n in range(order.size()):
		block_at[order[n]] = Pk2Reader.HEADER_SIZE + n * Pk2Reader.BLOCK_SIZE
	var data_start := Pk2Reader.HEADER_SIZE + order.size() * Pk2Reader.BLOCK_SIZE
	var data := PackedByteArray()
	var file_at := {}
	for fp in files:
		file_at[fp] = data_start + data.size()
		data.append_array(files[fp])
	var out := PackedByteArray()
	out.resize(Pk2Reader.HEADER_SIZE)
	var magic := "JoyMax File Manager!".to_ascii_buffer()
	for i in range(magic.size()):
		out[i] = magic[i]
	for folder in order:
		var block := PackedByteArray()
		block.resize(Pk2Reader.BLOCK_SIZE)
		_write_entry(block, 0, Pk2Reader.ENTRY_TYPE_FOLDER, ".", block_at[folder], 0)
		var slot := 1
		for child in children[folder]:
			if child[1]:
				_write_entry(block, slot, Pk2Reader.ENTRY_TYPE_FOLDER, child[0], block_at[child[2]], 0)
			else:
				_write_entry(block, slot, Pk2Reader.ENTRY_TYPE_FILE, child[0], file_at[child[2]], (files[child[2]] as PackedByteArray).size())
			slot += 1
		out.append_array(block)
	out.append_array(data)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(out)
	f.close()

func _write_entry(block: PackedByteArray, i: int, entry_type: int, name: String, offset: int, size: int) -> void:
	var base := i * Pk2Reader.ENTRY_SIZE
	block[base] = entry_type
	var name_bytes := name.to_ascii_buffer()
	for j in range(name_bytes.size()):
		block[base + Pk2Reader.ENTRY_OFF_NAME + j] = name_bytes[j]
	block.encode_u32(base + Pk2Reader.ENTRY_OFF_POSITION, offset)
	block.encode_u32(base + Pk2Reader.ENTRY_OFF_SIZE, size)

## A real-shaped 7-byte-vertex `.m` (MAPM_FORMAT.md; terrain_prepare_test.gd's
## layout): 36 blocks of synthetic heights, TextureInfo 1 or 2.
func _build_mapm() -> PackedByteArray:
	var block_len := MapmReader.BLOCK_HEADER_LEN + MapmReader.VERTEX_COUNT * MapmReader.VERTEX_LEN_7 \
		+ MapmReader.PLANE_INFO_LEN + MapmReader.TILE_FLAG_LEN + MapmReader.HEIGHT_INFO_LEN + MapmReader.RESERVED_LEN_7
	var buf := PackedByteArray()
	buf.resize(MapmReader.HEADER_LEN + MapmReader.BLOCK_COUNT * block_len)
	var head := (MapmReader.MAGIC + "1000").to_ascii_buffer()
	for i in range(head.size()):
		buf[i] = head[i]
	for b in range(MapmReader.BLOCK_COUNT):
		var off := MapmReader.HEADER_LEN + b * block_len + MapmReader.BLOCK_HEADER_LEN
		var tex_id := 1 if b % MapmReader.BLOCKS_PER_SIDE < 3 else 2
		for v in range(MapmReader.VERTEX_COUNT):
			buf.encode_float(off, float(b * 3 + v % 17) * 0.5)
			buf.encode_u16(off + 4, tex_id)
			off += MapmReader.VERTEX_LEN_7
		buf[off] = 0xff # PlaneType -1 (Normal)
	return buf

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)
