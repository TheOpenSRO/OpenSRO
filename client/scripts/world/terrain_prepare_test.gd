extends SceneTree

## The terrain prepare runs off the main thread (round 565): World3D's
## static _terrain_prepare, run on a WorkerThreadPool task over a job built on
## the main thread (_terrain_job), against synthetic archives (never real
## game data). Run headless:
##   godot4 --headless --path client --script res://scripts/world/terrain_prepare_test.gd
##
## What is held to account is THE PREPARE-THREAD RULE (World3D.gd, at
## _terrain_prepare; client/tools/README.md, "Load benchmark"): the job holds
## no Node and no Resource other than an Image, before the task and after it
## -- a Mesh, Material, Texture or Shape in it would mean the worker built
## something that owns a RenderingServer or PhysicsServer RID -- and the
## caches the prepare consults reach it as a snapshot: a ground tile this
## world has already uploaded is named by filename and flag, never handed
## over as its texture, and is not decoded again. Also that the task
## actually produced the terrain (the surfaces, the collision's height grid --
## or, under SRREVAMP_TERRAIN_TRIMESH=1's job flag, the trimesh faces (round
## 567) -- the lightmap and ground-tile Images, the navmesh, the walls and the
## walkable graph) and that the same prepare on the main thread produces the
## same.
##
## Two synthetic pk2 archives stand in for Map.pk2 (`97\168.m`, `97\168.t`,
## `Tile2D\t1.ddj`) and Data.pk2 (`navmesh\nv_61a8.nvm`); the tile table and
## the object index are built in memory, as _terrain_job would take them from
## World3D's own caches. World3D.gd is reached through load() and call(), so
## on a tree without the split the suite FAILS instead of failing to parse
## (round 563's pattern).

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
	_check(S != null and S.can_instantiate(), "World3D.gd loads and can instantiate headless")
	if S == null or not S.can_instantiate():
		_finish()
		return
	var names := {}
	for m in S.get_script_method_list():
		names[m["name"]] = true
	for needed in ["_terrain_job", "_terrain_prepare"]:
		_check(names.has(needed), "World3D.gd has %s (absent before round 565)" % needed)
	if not names.has("_terrain_job") or not names.has("_terrain_prepare"):
		_finish()
		return
	_test_the_walk_sees_what_it_forbids()
	_test_prepare_off_the_main_thread(S)
	_finish()

## The walk below is the rule's guard, so it is held first: it must find an
## RID-owning object wherever a job could hold one -- in an Array, in a
## nested Dictionary, in a reader struct's variable -- and pass an Image.
func _test_the_walk_sees_what_it_forbids() -> void:
	var holder := MapTReader.ParsedRegion.new()
	holder.texture = ImageTexture.new()
	holder.image = Image.new()
	var node := Node3D.new()
	var found := _forbidden({"list": [ArrayMesh.new()], "nested": {"node": node}, "struct": holder,
		"image": Image.new(), "shape": ConcavePolygonShape3D.new()})
	found.sort()
	_check(found == ["job.list[0]: ArrayMesh", "job.nested.node: Node3D", "job.shape: ConcavePolygonShape3D",
			"job.struct.texture: ImageTexture"],
		"the walk finds a mesh in an Array, a Node in a Dictionary, a shape, and a texture in a reader struct -- and passes Images (got %s)" % str(found))
	node.free()

func _test_prepare_off_the_main_thread(S: GDScript) -> void:
	var map_path := "user://srrevamp_r565_map.pk2"
	var data_path := "user://srrevamp_r565_data.pk2"
	_write_pk2(map_path, {
		"97\\168.m": _build_mapm(),
		"97\\168.t": _build_mapt(8, 8),
		"Tile2D\\t1.ddj": _build_ddj(8, 8),
	})
	_write_pk2(data_path, {"navmesh\\nv_61a8.nvm": _build_nvm()})
	var map_pk2 := Pk2Reader.open(map_path)
	var data_pk2 := Pk2Reader.open(data_path)
	_check(map_pk2 != null and data_pk2 != null, "the synthetic archives open")
	if map_pk2 == null or data_pk2 == null:
		return

	var w: Node = S.new()
	w._map_pk2 = map_pk2
	w._data_pk2 = data_pk2
	w._tile_index_cache = _tile_table()
	w._tile_index_load_attempted = true
	w._object_index_cache = ObjidxReader.Table.new() # lists nothing: the navmesh's object stays unresolved
	w._object_index_load_attempted = true

	# The job, built on the main thread.
	var job: Dictionary = w.call("_terrain_job", "97\\168.m", "", Vector3.ZERO, "_97_168", false, NAN, false)
	var bad := _forbidden(job)
	_check(bad.is_empty(), "the job holds no Node and no Resource but Image before the task (found %s)" % str(bad))

	# The prepare, on a WorkerThreadPool task -- the way World3D._dispatch_cell
	# runs it (a high-priority task over the bound job).
	job["threaded"] = true
	var task := WorkerThreadPool.add_task(Callable(w, "_terrain_prepare").bind(job), true, "r565 terrain prepare test")
	WorkerThreadPool.wait_for_task_completion(task)
	_check(job.get("prepared", false) and not job.has("error"),
		"the task prepared the terrain (error: %s)" % str(job.get("error", "none")))
	bad = _forbidden(job)
	_check(bad.is_empty(), "after the task the job still holds no Node and no Resource but Image (found %s)" % str(bad))
	var surfaces: Array = job.get("surfaces", [])
	var heights: PackedFloat32Array = job.get("heights", PackedFloat32Array())
	_check(job.get("textured", false) and surfaces.size() >= 3,
		"textured surfaces as data: the base, the fallback pass and ID 1's (got %d)" % surfaces.size())
	# Round 567: the collision is the region's height grid, not the faces.
	_check(heights.size() == 97 * 97 and not job.has("faces"),
		"the collision's height grid as data, 97 x 97, and no trimesh faces (%d heights; faces %s)" % [heights.size(), str(job.has("faces"))])
	_check(heights == TerrainCollision.heights_from_region(job.get("region")),
		"the height grid is TerrainCollision.heights_from_region of the job's own parse")
	_check(job.get("lightmap") is Image, "the .t lightmap as an Image, not a texture")
	var files: Dictionary = job.get("texture_files", {})
	var new_images: Dictionary = job.get("new_images", {})
	_check(files == {1: "t1.ddj"}, "ID 1 resolves to t1.ddj; ID 2's file is missing (got %s)" % str(files))
	_check(new_images.get("t1.ddj") is Image and new_images.has("missing.ddj") and new_images["missing.ddj"] == null,
		"the new ground tiles decoded as Images, a missing one as null (got %s)" % str(new_images.keys()))
	_check(job.get("navmesh_loaded", false) and job.get("navmesh") != null,
		"the navmesh read and parsed on the task")
	_check((job.get("wall_faces", PackedVector3Array()) as PackedVector3Array).size() > 0,
		"the navmesh walls' triangles as data")
	_check(job.get("nav_graph") is NavGraph and (job.get("used_collisions", {}) as Dictionary).has(4242),
		"the walkable graph built on the task, the unresolved object recorded for the cache")
	var laps: Array = []
	for lap in job["laps"]:
		laps.append(lap[0])
	_check(laps == ["read", "parse", "lightmap", "textures", "mesh", "heights", "navmesh", "walls", "navgraph"],
		"the prepare's laps are in the job, in order, for the commit to record (got %s)" % str(laps))

	# The same prepare on this thread gives the same terrain.
	var job_main: Dictionary = w.call("_terrain_job", "97\\168.m", "", Vector3.ZERO, "_97_168", false, NAN, false)
	w.call("_terrain_prepare", job_main)
	var same: bool = (job_main.get("surfaces", []) as Array).size() == surfaces.size() and job_main.get("heights") == heights
	for i in range(mini(surfaces.size(), (job_main.get("surfaces", []) as Array).size())):
		if surfaces[i]["arrays"][Mesh.ARRAY_VERTEX] != job_main["surfaces"][i]["arrays"][Mesh.ARRAY_VERTEX]:
			same = false
	_check(same, "the prepare on the main thread builds the same surfaces and height grid as the task")

	# SRREVAMP_TERRAIN_TRIMESH=1 (A/B, round 567): the job's flag, read by
	# _terrain_job on the main thread, makes the prepare build the pre-567
	# trimesh faces -- MapmTerrainBuilder.surface_faces of the same surfaces --
	# in the same lap, and no height grid.
	var job_tri: Dictionary = w.call("_terrain_job", "97\\168.m", "", Vector3.ZERO, "_97_168", false, NAN, false)
	_check(job_tri.has("trimesh") and not job_tri["trimesh"],
		"_terrain_job reads the trimesh flag on the main thread (off when SRREVAMP_TERRAIN_TRIMESH is unset)")
	job_tri["trimesh"] = true
	w.call("_terrain_prepare", job_tri)
	var tri_faces: PackedVector3Array = job_tri.get("faces", PackedVector3Array())
	_check(not job_tri.has("heights") and tri_faces.size() > 0 and tri_faces == MapmTerrainBuilder.surface_faces(job_tri.get("surfaces", [])),
		"with the flag the prepare builds the trimesh faces of its surfaces and no height grid (%d corners)" % tri_faces.size())
	var tri_laps: Array = []
	for lap in job_tri["laps"]:
		tri_laps.append(lap[0])
	_check(tri_laps == laps, "the flag's faces are in the same `heights` lap (got %s)" % str(tri_laps))

	# The snapshot: once this world holds t1.ddj's texture and the region's
	# navmesh (what the commit would have stored), the next job names the
	# tile by filename and flag only and the task neither decodes it nor
	# reads the navmesh again.
	w._ground_texture_cache["t1.ddj"] = ImageTexture.create_from_image(new_images["t1.ddj"])
	w._grid.navmesh_cache[int(job["navmesh_key"])] = job["navmesh"]
	var job2: Dictionary = w.call("_terrain_job", "97\\168.m", "", Vector3.ZERO, "_97_168", false, NAN, false)
	_check(job2["known_textures"] == {"t1.ddj": true} and job2["navmesh_cached"],
		"the job snapshots the texture cache as filename -> decoded flag, and the cached navmesh")
	bad = _forbidden(job2)
	_check(bad.is_empty(), "the cached ImageTexture does not reach the job (found %s)" % str(bad))
	job2["threaded"] = true
	var task2 := WorkerThreadPool.add_task(Callable(w, "_terrain_prepare").bind(job2), true, "r565 terrain prepare test 2")
	WorkerThreadPool.wait_for_task_completion(task2)
	_check(job2.get("prepared", false) and (job2["texture_files"] as Dictionary) == {1: "t1.ddj"}
			and not (job2["new_images"] as Dictionary).has("t1.ddj"),
		"a tile the world already holds resolves from the snapshot and is not decoded again")
	_check(not job2.get("navmesh_loaded", false) and job2.get("navmesh") == job["navmesh"],
		"a cached navmesh is not read again")
	_check(_forbidden(job2).is_empty(), "the second job holds no Node and no Resource but Image after its task")

	w.free()
	map_pk2.close()
	data_pk2.close()
	DirAccess.remove_absolute(map_path)
	DirAccess.remove_absolute(data_path)

## Every Object reachable from `v` -- through Arrays, Dictionaries and each
## object's script variables -- that is a Node, or a Resource other than an
## Image: what the prepare-thread rule forbids a job to hold. Paths, for the
## failure message.
func _forbidden(v: Variant) -> Array:
	var out: Array = []
	_walk(v, {}, "job", out)
	return out

func _walk(v: Variant, seen: Dictionary, path: String, out: Array) -> void:
	match typeof(v):
		TYPE_ARRAY:
			var a: Array = v
			for i in range(a.size()):
				_walk(a[i], seen, "%s[%d]" % [path, i], out)
		TYPE_DICTIONARY:
			var d: Dictionary = v
			for k in d:
				_walk(k, seen, "%s{key}" % path, out)
				_walk(d[k], seen, "%s.%s" % [path, str(k)], out)
		TYPE_OBJECT:
			if v == null or not is_instance_valid(v):
				return
			var o: Object = v
			if seen.has(o.get_instance_id()):
				return
			seen[o.get_instance_id()] = true
			if o is Node or (o is Resource and not o is Image):
				out.append("%s: %s" % [path, o.get_class()])
				return
			for prop in o.get_property_list():
				if int(prop["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE:
					_walk(o.get(prop["name"]), seen, "%s.%s" % [path, prop["name"]], out)

func _tile_table() -> TileIndexReader.Table:
	var table := TileIndexReader.Table.new()
	var entries: Array[TileIndexReader.Entry] = []
	for id in range(3):
		var e := TileIndexReader.Entry.new()
		e.id = id
		e.type = TileIndexReader.TileType.GRASS
		e.filename = ["", "t1.ddj", "missing.ddj"][id]
		entries.append(e)
	table.entries = entries
	return table

## A synthetic pk2 holding `files` ({"folder\\name": bytes}), one directory
## block per folder, unencrypted -- the layout Pk2Reader reads
## (docs/protocol/PK2_FORMAT.md; pk2_reader_test.gd's entry writer). Each
## block's first entry is ".", which the reader skips; at most 19 children a
## folder, so no block chains.
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

## A real-shaped 7-byte-vertex `.m` (MAPM_FORMAT.md; mapm_reader_test.gd's
## layout): 36 blocks, each vertex a height and a TextureInfo -- ID 1 in the
## western half, 2 in the eastern -- written in place rather than appended,
## so the 92 KB file builds in one pass.
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

## A real-shaped `.t` (MAPT_FORMAT.md; mapt_reader_test.gd's layout): the
## shadow map, then an embedded DXT1 DDS.
func _build_mapt(width: int, height: int) -> PackedByteArray:
	var dds := PackedByteArray()
	dds.resize(128 + (width / 4) * (height / 4) * 8)
	var dds_magic := "DDS ".to_ascii_buffer()
	for i in range(4):
		dds[i] = dds_magic[i]
	dds.encode_u32(4, 124)
	dds.encode_u32(4 + 8, height)
	dds.encode_u32(4 + 12, width)
	dds.encode_u32(4 + 72, 32)
	dds.encode_u32(4 + 72 + 4, 0x4) # DDPF_FOURCC
	var cc := "DXT1".to_ascii_buffer()
	for i in range(4):
		dds[4 + 72 + 8 + i] = cc[i]
	var buf := PackedByteArray()
	buf.append_array((MapTReader.MAGIC + "1001").to_ascii_buffer())
	var shadow := PackedByteArray()
	shadow.resize(MapTReader.SHADOW_MAP_LEN)
	buf.append_array(shadow)
	var lengths := PackedByteArray()
	lengths.resize(8)
	lengths.encode_u32(0, dds.size() + 8) # TextureLength counts itself + TextureType
	lengths.encode_u32(4, 3)
	buf.append_array(lengths)
	buf.append_array(dds)
	return buf

## A real-shaped DXT1 `.ddj` (DDJ_FORMAT.md; ddj_reader_test.gd's layout).
func _build_ddj(width: int, height: int) -> PackedByteArray:
	var dds := PackedByteArray()
	dds.resize(4 + DdjReader.DDS_HEADER_SIZE + maxi(width * height / 2, 8))
	var dds_magic := "DDS ".to_ascii_buffer()
	for i in range(4):
		dds[i] = dds_magic[i]
	dds.encode_u32(4, DdjReader.DDS_HEADER_SIZE)
	dds.encode_u32(4 + 8, height)
	dds.encode_u32(4 + 12, width)
	dds.encode_u32(4 + 24, 1)
	dds.encode_u32(4 + 72, 32)
	dds.encode_u32(4 + 72 + 4, DdjReader.DDPF_FOURCC)
	var cc := "DXT1".to_ascii_buffer()
	for i in range(4):
		dds[4 + 72 + 8 + i] = cc[i]
	var buf := PackedByteArray()
	buf.resize(DdjReader.WRAPPER_SIZE + dds.size())
	var magic := DdjReader.MAGIC.to_ascii_buffer()
	for i in range(magic.size()):
		buf[i] = magic[i]
	buf.encode_u32(0x0c, buf.size() - DdjReader.MAGIC_LEN)
	buf.encode_u32(0x10, 3)
	for i in range(dds.size()):
		buf[DdjReader.WRAPPER_SIZE + i] = dds[i]
	return buf

## A real-shaped `.nvm` (NVM_FORMAT.md; nvm_reader_test.gd's layout): one
## object (resource 4242, which the in-memory object index does not list),
## two cells, a global edge and a blocking internal edge (flags 1: the
## client's blocking mask is 0x3, NvmCollision), a full tile map, height map
## and plane maps.
func _build_nvm() -> PackedByteArray:
	_nvm = NvmReader.MAGIC.to_ascii_buffer()
	_put("u16", 1) # ObjectCount
	_put("u32", 4242)
	_put("f32", 10.0); _put("f32", 20.0); _put("f32", 30.0)
	_put("s16", -1); _put("f32", 1.57); _put("u16", 7); _put("u16", 0)
	_put("u8", 1); _put("u8", 0); _put("u16", 0x61a8)
	_put("u16", 1); _put("s16", 2); _put("s16", 3); _put("s16", 4)
	_put("u32", 2); _put("u32", 1)
	_put("f32", 0.0); _put("f32", 0.0); _put("f32", 960.0); _put("f32", 960.0)
	_put("u8", 1); _put("u16", 0)
	_put("f32", 960.0); _put("f32", 960.0); _put("f32", 1920.0); _put("f32", 1920.0)
	_put("u8", 0)
	_put("u32", 1) # GlobalEdgeCount
	_put("f32", 0.0); _put("f32", 1920.0); _put("f32", 960.0); _put("f32", 1920.0)
	_put("u8", 8); _put("s8", 0); _put("s8", 2); _put("s16", 0); _put("s16", 1)
	_put("u16", 0x61a8); _put("u16", 0x61a9)
	_put("u32", 1) # InternalEdgeCount
	_put("f32", 960.0); _put("f32", 0.0); _put("f32", 960.0); _put("f32", 960.0)
	_put("u8", 1); _put("s8", 1); _put("s8", 3); _put("s16", 0); _put("s16", -1)
	var tiles := PackedByteArray()
	tiles.resize(NvmReader.TILE_COUNT * 8)
	for i in range(NvmReader.TILE_COUNT):
		tiles.encode_s32(i * 8, -1)
	_nvm.append_array(tiles)
	var heights := PackedByteArray()
	heights.resize(NvmReader.HEIGHT_COUNT * 4)
	_nvm.append_array(heights)
	var planes := PackedByteArray()
	planes.resize(NvmReader.PLANE_COUNT * 5)
	_nvm.append_array(planes)
	return _nvm

var _nvm := PackedByteArray()

func _put(kind: String, v: Variant) -> void:
	var b := PackedByteArray()
	match kind:
		"u8":
			b = PackedByteArray([v])
		"s8":
			b.resize(1)
			b.encode_s8(0, v)
		"u16":
			b.resize(2)
			b.encode_u16(0, v)
		"s16":
			b.resize(2)
			b.encode_s16(0, v)
		"u32":
			b.resize(4)
			b.encode_u32(0, v)
		"f32":
			b.resize(4)
			b.encode_float(0, v)
	_nvm.append_array(b)

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)
