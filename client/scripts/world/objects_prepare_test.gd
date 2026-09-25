extends SceneTree

## A region's objects prepare off the main thread (round 566): World3D's
## static _objects_prepare, run on a WorkerThreadPool task over a job built
## on the main thread (_objects_job), then committed on the main thread
## (_objects_commit) -- and _cell_prepare, the streamed cell's one task, the
## terrain then the objects. Against synthetic archives (never real game
## data). Run headless:
##   godot4 --headless --path client --script res://scripts/world/objects_prepare_test.gd
##
## Held to account:
## - THE PREPARE-THREAD RULE (World3D.gd, at _terrain_prepare and
##   _objects_prepare; client/tools/README.md, "Load benchmark"): the job
##   holds no Node and no Resource other than an Image before the task and
##   after it; the caches reach it as snapshots -- the templates held by
##   path, the uploaded textures by key and fourCC, never the texture;
## - the task did the work: the `.o` and `.o2` read, merged and
##   de-duplicated, the `.o2` placement standing on a neighbour's ground
##   dropped (the neighbour's heightmap read and parsed ON the task, under
##   Pk2Reader's lock, and handed back for the grid's cache), each distinct
##   model prepared once, their shared texture decoded once, the laps in
##   order;
## - the commit places what the synchronous path placed, from ONE template
##   per model (ObjectTemplateCache, round 559), textures uploaded into the
##   world's cache, no template built unprepared; a second job over the
##   snapshot prepares nothing; a template released between dispatch and
##   commit is rebuilt on the main thread and counted;
## - _cell_prepare hands the objects the terrain's own parse of the region
##   (no second parse of the `.m`);
## - round 566's review: _prepared_again counts what a job prepared that a
##   later commit cached first, and _pump_cell_jobs commits a finished cell
##   before it dispatches the next, so the next job's snapshot holds it;
## - round 566's second review: _prepared_again counts only what the prepare
##   itself decoded or read -- NOT a texture its snapshot held (named, image
##   null) and NOT the region's heightmap taken from the terrain prepare's
##   parse -- two negatives that fail on the counter as first committed;
## - round 568: the third texture case -- a HELD texture _alpha_stat decoded
##   again for a statistic its snapshot lacked -- counts once a later commit
##   has carried that statistic in, and not before; and the stale-cell guard
##   (_finish_cell_job) and the drop (_drop_cell_jobs), which had no headless
##   coverage.
##
## World3D.gd is reached through load() and call(), so on a tree without the
## split the suite FAILS instead of failing to parse (round 563's pattern).

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
	var all_there := true
	for needed in ["_objects_job", "_objects_prepare", "_objects_commit", "_cell_prepare"]:
		_check(names.has(needed), "World3D.gd has %s (absent before round 566)" % needed)
		all_there = all_there and names.has(needed)
	if all_there:
		_test_the_walk_sees_what_it_forbids()
		_test_objects_off_the_main_thread(S)
	_test_pump_commits_before_it_dispatches()
	_test_stale_cells_are_not_committed()
	_finish()

## The walk is the rule's guard, so it is held first: it must find a Node, a
## mesh or a texture wherever a job could hold one, and pass an Image.
func _test_the_walk_sees_what_it_forbids() -> void:
	var node := Node3D.new()
	var found := _forbidden({"models": {"a": {"root": {"pieces": [{"tex": ImageTexture.new()}]}}},
		"node": node, "list": [ArrayMesh.new()], "image": Image.new()})
	found.sort()
	_check(found == ["job.list[0]: ArrayMesh", "job.models.a.root.pieces[0].tex: ImageTexture", "job.node: Node3D"],
		"the walk finds a texture deep in a prepared model, a Node and a mesh -- and passes Images (got %s)" % str(found))
	node.free()

func _test_objects_off_the_main_thread(S: GDScript) -> void:
	var map_path := "user://srrevamp_r566_objects_map.pk2"
	var data_path := "user://srrevamp_r566_objects_data.pk2"
	_write_pk2(map_path, {
		"97\\168.o": _build_mapo(),
		"97\\168.o2": _build_mapo2(),
		"97\\168.m": _build_flat_mapm(0.0),
		"97\\167.m": _build_flat_mapm(50.0),
	})
	_write_pk2(data_path, {
		"prim\\wall.bsr": _build_bsr("Wall", "prim\\wall.bms", "prim\\scenery.bmt", []),
		"prim\\tree.bsr": _build_bsr("Tree", "prim\\tree.bms", "prim\\scenery.bmt", []),
		"prim\\wall.bms": _build_bms("wall", "scenery"),
		"prim\\tree.bms": _build_bms("tree", "scenery"),
		"prim\\scenery.bmt": _build_bmt("scenery", "scenery.ddj"),
		"prim\\scenery.ddj": _build_bgra_ddj(4, 4),
	})
	var map_pk2 := Pk2Reader.open(map_path)
	var data_pk2 := Pk2Reader.open(data_path)
	_check(map_pk2 != null and data_pk2 != null, "the synthetic archives open")
	if map_pk2 == null or data_pk2 == null:
		return

	var w: Node = S.new()
	w._map_pk2 = map_pk2
	w._data_pk2 = data_pk2
	w._object_index_cache = _object_index()
	w._object_index_load_attempted = true

	# The job, built on the main thread.
	var job: Dictionary = w.call("_objects_job", "97\\168.o", Vector3.ZERO, "_97_168")
	var bad := _forbidden(job)
	_check(bad.is_empty(), "the job holds no Node and no Resource but Image before the task (found %s)" % str(bad))
	_check(job["templates_held"] == {} and job["known_textures"] == {} and job["heightmaps"] == {},
		"a fresh world's snapshot: no template, no texture, no heightmap")

	# The prepare, on a WorkerThreadPool task, as World3D._dispatch_cell runs
	# the cell's (a high-priority task over the bound job).
	job["threaded"] = true
	var task := WorkerThreadPool.add_task(Callable(w, "_objects_prepare").bind(job), true, "r566 objects prepare test")
	WorkerThreadPool.wait_for_task_completion(task)
	_check(job.get("prepared", false) and not job.has("error") and not job.get("stopped", false),
		"the task prepared the objects (error: %s)" % str(job.get("error", "none")))
	bad = _forbidden(job)
	_check(bad.is_empty(), "after the task the job still holds no Node and no Resource but Image (found %s)" % str(bad))
	var placements: Array = job.get("placements", [])
	# .o: wall, wall, tree, an unresolved type; .o2 list 2: a repeat of the
	# first wall (de-duplicated), a tree on this region's ground (kept) and
	# one 50 above it, on 97/167's (dropped).
	_check(placements.size() == 5, "7 placements read, 1 repeat merged, 1 handed to its neighbour: 5 kept (got %d)" % placements.size())
	var lines := PackedStringArray()
	for line in job["log"]:
		lines.append(line[1])
	var text := "\n".join(lines)
	_check(text.contains("dropped 1 duplicate real placements (7 -> 6)")
			and text.contains("dropped 1 real .o2 placement(s) that stand on a neighbouring region's ground"),
		"the prepare's lines are in the job for the commit to print, not printed (got %s)" % text)
	var new_maps: Dictionary = job.get("new_heightmaps", {})
	_check(new_maps.size() == 9 and new_maps["97_168"] is MapmReader.ParsedRegion and new_maps["97_167"] is MapmReader.ParsedRegion
			and new_maps["96_167"] == null,
		"the region and its eight neighbours' heightmaps read on the task, the two that exist parsed (got %s)" % str(new_maps.keys()))
	var models: Dictionary = job.get("models", {})
	_check(models.size() == 2 and models.has("prim\\wall.bsr") and models.has("prim\\tree.bsr"),
		"each distinct model prepared once, the unresolved type skipped (got %s)" % str(models.keys()))
	var textures: Dictionary = job.get("textures", {})
	_check(textures.size() == 1 and textures.values()[0]["image"] is Image,
		"the two models' shared texture decoded once, to an Image (got %s)" % str(textures.keys()))
	var laps: Array = []
	for lap in job["laps"]:
		laps.append(lap[0])
	_check(laps == ["parse", "own", "models"], "the prepare's laps are in the job, in order (got %s)" % str(laps))

	# The commit, on this thread.
	w.call("_objects_commit", job)
	var container: Node = w.get_node_or_null("RealMapObjects_97_168")
	_check(container != null and container.get_child_count() == 4,
		"the commit placed the 4 resolvable placements (got %d)" % (container.get_child_count() if container != null else -1))
	var templates = w.get("_object_templates")
	_check(templates != null and templates.size() == 2 and templates.loads == 2 and templates.reuses == 2,
		"one template per model, the repeats duplicated (size %s)" % (str(templates.size()) if templates != null else "null"))
	_check(int(w.get("_templates_unprepared")) == 0 and (w.get("_prepared_models") as Dictionary).is_empty(),
		"every template built from the prepared model; nothing left over after the commit")
	var world_textures: Dictionary = w.get("_object_textures")
	_check(world_textures.size() == 1 and world_textures.values()[0]["texture"] is ImageTexture,
		"the texture uploaded into the world's cache on the main thread")
	var grid = w.get("_grid")
	_check(grid.parsed_heightmaps.size() == 9 and grid.parsed_heightmaps["97_167"] == new_maps["97_167"],
		"the heightmaps the task parsed went into the grid's cache")
	if container != null and container.get_child_count() > 0:
		var first: Node = container.get_child(0)
		_check(String(first.name).begins_with("Obj_wall_0") and first.get_child_count() == 1
				and (first.get_child(0) as MeshInstance3D).mesh.get_surface_count() == 1,
			"a placed copy carries the committed mesh (%s)" % first.name)

	# A second job over the snapshot: the templates and the texture are held,
	# so nothing is prepared or decoded, and the commit reuses them.
	var job2: Dictionary = w.call("_objects_job", "97\\168.o", Vector3.ZERO, "_97_168_b")
	_check(job2["templates_held"] == {"prim\\wall.bsr": true, "prim\\tree.bsr": true}
			and (job2["known_textures"] as Dictionary).size() == 1 and _forbidden(job2).is_empty(),
		"the snapshot names the held templates and textures, never a Node or texture")
	_check(job2["heightmaps"].size() == 9, "and hands the job the grid's heightmaps")
	job2["threaded"] = true
	var task2 := WorkerThreadPool.add_task(Callable(w, "_objects_prepare").bind(job2), true, "r566 objects prepare test 2")
	WorkerThreadPool.wait_for_task_completion(task2)
	_check((job2["models"] as Dictionary).is_empty() and (job2["textures"] as Dictionary).is_empty()
			and (job2["new_heightmaps"] as Dictionary).is_empty(),
		"nothing prepared, decoded or parsed again")
	w.call("_objects_commit", job2)
	_check(templates.loads == 2 and int(w.get("_templates_unprepared")) == 0,
		"the second commit placed its copies from the held templates")

	# A template released between the snapshot and the commit is rebuilt,
	# whole, on the main thread -- and the objects line says so.
	var job3: Dictionary = w.call("_objects_job", "97\\168.o", Vector3.ZERO, "_97_168_c")
	job3["threaded"] = true
	var task3 := WorkerThreadPool.add_task(Callable(w, "_objects_prepare").bind(job3), true, "r566 objects prepare test 3")
	WorkerThreadPool.wait_for_task_completion(task3)
	templates.release_region("97\\168.o")
	_check(templates.size() == 0, "both templates released")
	w.call("_objects_commit", job3)
	var third: Node = w.get_node_or_null("RealMapObjects_97_168_c")
	_check(third != null and third.get_child_count() == 4 and int(w.get("_templates_unprepared")) == 2,
		"the commit still places all 4, building the 2 released templates unprepared (got %s)" % str(w.get("_templates_unprepared")))

	# The streamed cell's one task: the terrain, then the objects over the
	# terrain's own parse of the region.
	w._tile_index_cache = _tile_table()
	w._tile_index_load_attempted = true
	w._grid.parsed_heightmaps.clear()
	var cell: Dictionary = w.call("_terrain_job", "97\\168.m", "", Vector3.ZERO, "_97_168_d", false, NAN, false)
	cell["threaded"] = true
	cell["objects"] = w.call("_objects_job", "97\\168.o", Vector3.ZERO, "_97_168_d")
	var task4 := WorkerThreadPool.add_task(Callable(w, "_cell_prepare").bind(cell), true, "r566 cell prepare test")
	WorkerThreadPool.wait_for_task_completion(task4)
	var objects: Dictionary = cell["objects"]
	_check(cell.get("prepared", false) and objects.get("prepared", false) and not objects.has("error"),
		"one task prepared the terrain and then the objects")
	_check(cell.get("region") != null and objects["here"] == cell["region"]
			and objects["new_heightmaps"].get("97_168") == cell["region"],
		"the objects sampled the terrain's own parse of 97/168, not a second one")
	_check(_forbidden(cell).is_empty(), "the cell job holds no Node and no Resource but Image after its task")

	_test_prepared_again(S, map_pk2, data_pk2)

	w.free()
	map_pk2.close()
	data_pk2.close()
	DirAccess.remove_absolute(map_path)
	DirAccess.remove_absolute(data_path)

## Round 566's review: two jobs dispatched from one snapshot, before either
## commits, prepare the same models, texture and heightmaps; once the first
## commits, World3D._prepared_again counts the second's copies. A job
## dispatched after that commit prepares none of them -- which is why the
## pump commits before it dispatches (_test_pump_commits_before_it_dispatches).
##
## The second review's two NEGATIVES -- both miscounted by the counter as
## first committed (34d0883), which counted every texture KEY a job named and
## every heightmap it held: (a) a texture the job's snapshot already held is
## named by its prepare, not decoded (ObjectLoader._prepare_material's
## `known` branch, image null), so it is not counted even when the
## job's models are; (b) the region's own heightmap taken over from the
## terrain prepare's parse (job["here"], _cell_prepare) was not parsed by the
## objects prepare, so of a cell's 9 heightmaps only its 8 neighbours count.
func _test_prepared_again(S: GDScript, map_pk2: Pk2Reader, data_pk2: Pk2Reader) -> void:
	var w: Node = S.new()
	_check(w.has_method("_prepared_again"), "World3D.gd has _prepared_again (absent before round 566's review)")
	if not w.has_method("_prepared_again"):
		w.free()
		return
	w._map_pk2 = map_pk2
	w._data_pk2 = data_pk2
	w._object_index_cache = _object_index()
	w._object_index_load_attempted = true
	w._tile_index_cache = _tile_table()
	w._tile_index_load_attempted = true
	var none := {"tiles": 0, "navmesh": 0, "collisions": 0, "heightmaps": 0, "models": 0, "textures": 0}
	var first: Dictionary = w.call("_objects_job", "97\\168.o", Vector3.ZERO, "_97_168_e")
	var second: Dictionary = w.call("_objects_job", "97\\168.o", Vector3.ZERO, "_97_168_f")
	# A streamed cell's job from the same (empty) snapshot: its task parses
	# 97/168 for the terrain and hands that parse to the objects (job["here"]).
	var cell: Dictionary = w.call("_terrain_job", "97\\168.m", "", Vector3.ZERO, "_97_168_h", false, NAN, false)
	cell["threaded"] = true
	cell["objects"] = w.call("_objects_job", "97\\168.o", Vector3.ZERO, "_97_168_h")
	for job in [first, second]:
		job["threaded"] = true
		var task := WorkerThreadPool.add_task(Callable(w, "_objects_prepare").bind(job), true, "r566 prepared-again test")
		WorkerThreadPool.wait_for_task_completion(task)
	var cell_task := WorkerThreadPool.add_task(Callable(w, "_cell_prepare").bind(cell), true, "r566 prepared-again cell test")
	WorkerThreadPool.wait_for_task_completion(cell_task)
	_check((second["models"] as Dictionary).size() == 2 and (second["textures"] as Dictionary).size() == 1
			and (second["new_heightmaps"] as Dictionary).size() == 9,
		"a second job from the same snapshot prepares the same 2 models, 1 texture and 9 heightmaps")
	var cell_objects: Dictionary = cell["objects"]
	var cell_maps: Dictionary = cell_objects.get("new_heightmaps", {})
	_check(cell_objects.get("prepared", false) and cell.get("region") != null
			and cell_maps.size() == 9 and cell_maps.get("97_168") == cell["region"],
		"the cell's objects hold 9 heightmaps, 97/168's the terrain prepare's own parse (got %s)" % str(cell_maps.keys()))
	var got: Dictionary = w.call("_prepared_again", {"objects": second})
	_check(got == none, "before either commits nothing is counted (got %s)" % str(got))
	w.call("_objects_commit", first)
	got = w.call("_prepared_again", {"objects": second})
	_check(got == {"tiles": 0, "navmesh": 0, "collisions": 0, "heightmaps": 9, "models": 2, "textures": 1},
		"after the first commits, the second's 9 heightmaps, 2 models and 1 texture are counted as prepared again (got %s)" % str(got))
	# NEGATIVE (b): the objects prepare parsed 8 of the cell's heightmaps; the
	# 9th is the terrain's parse, which the cell needs whatever the snapshot.
	got = w.call("_prepared_again", {"objects": cell_objects})
	_check(got == {"tiles": 0, "navmesh": 0, "collisions": 0, "heightmaps": 8, "models": 2, "textures": 1},
		"the region's own heightmap taken over from the terrain prepare is not counted: 8 heightmaps, not 9 (got %s)" % str(got))
	var third: Dictionary = w.call("_objects_job", "97\\168.o", Vector3.ZERO, "_97_168_g")
	third["threaded"] = true
	var task3 := WorkerThreadPool.add_task(Callable(w, "_objects_prepare").bind(third), true, "r566 prepared-again test 3")
	WorkerThreadPool.wait_for_task_completion(task3)
	got = w.call("_prepared_again", {"objects": third})
	_check(got == none and (third["models"] as Dictionary).is_empty() and (third["new_heightmaps"] as Dictionary).is_empty(),
		"a job dispatched after the commit prepares none of it again (got %s)" % str(got))
	# NEGATIVE (a): the templates released, the texture still uploaded -- a
	# job from that snapshot prepares both models again and only NAMES the
	# texture. Once another commit rebuilds the templates (second's, here),
	# its 2 models count and its texture does not.
	var templates = w.get("_object_templates")
	templates.release_region("97\\168.o")
	var fourth: Dictionary = w.call("_objects_job", "97\\168.o", Vector3.ZERO, "_97_168_i")
	_check((fourth["templates_held"] as Dictionary).is_empty() and (fourth["known_textures"] as Dictionary).size() == 1,
		"a snapshot holding the texture but no template")
	fourth["threaded"] = true
	var task4 := WorkerThreadPool.add_task(Callable(w, "_objects_prepare").bind(fourth), true, "r566 prepared-again test 4")
	WorkerThreadPool.wait_for_task_completion(task4)
	var fourth_textures: Dictionary = fourth.get("textures", {})
	_check((fourth["models"] as Dictionary).size() == 2 and fourth_textures.size() == 1
			and fourth_textures.values()[0]["image"] == null,
		"its prepare prepares the 2 models and names the held texture without decoding it")
	w.call("_objects_commit", second)
	got = w.call("_prepared_again", {"objects": fourth})
	_check(got == {"tiles": 0, "navmesh": 0, "collisions": 0, "heightmaps": 0, "models": 2, "textures": 0},
		"a texture the snapshot held is not counted as decoded again, its models are (got %s)" % str(got))
	_test_held_texture_decoded_again(w, data_pk2, none)
	# The terrain's three caches, over the keys _terrain_prepare leaves in a
	# job: a tile, the navmesh and one of two object navigation meshes cached
	# since its snapshot.
	w._ground_texture_cache["a.ddj"] = null
	w._grid.navmesh_cache[5] = null
	w._grid.object_collision_cache[8] = null
	got = w.call("_prepared_again", {"new_images": {"a.ddj": null, "b.ddj": null},
		"navmesh_loaded": true, "navmesh_key": 5, "parsed_collisions": {7: true, 8: true}})
	_check(got == {"tiles": 1, "navmesh": 1, "collisions": 1, "heightmaps": 0, "models": 0, "textures": 0},
		"the terrain's tile, navmesh and object navigation mesh cached since the snapshot are counted (got %s)" % str(got))
	w.free()

## Round 568 (round 566's second review, nonblocking): the third texture
## case, which negative (a) above cannot tell from the other two -- its
## texture has image == null, so either exclusion would skip it. A texture
## the job's snapshot HELD, but without a statistic a layer asks for, is
## decoded again by ObjectLoader._alpha_stat (image set, key in
## known_textures). That decode counts only once a commit after the
## snapshot has carried the statistic into the world's entry
## (ObjectLoader.commit_textures merges a prepare's statistics into a
## texture already cached -- what World3D._objects_commit calls): a snapshot
## taken after that commit would have spared it. With nothing carried in,
## the decode was needed and does not count.
##
## The layer here has no flag word (LAYER_FLAG_MASK clear), so the pixels
## decide, and the texture is the uncompressed scenery.ddj (fourCC ""), whose
## statistic is `binary_cutout`; the world's entry for it holds no statistic
## (the synthetic material's flag word 0x40 decided every layer so far).
## World3D.gd as first committed in round 566 skipped every snapshot-held key,
## so the last check FAILS there.
func _test_held_texture_decoded_again(w: Node, data_pk2: Pk2Reader, none: Dictionary) -> void:
	var key := "prim/scenery.ddj"
	var world_textures: Dictionary = w.get("_object_textures")
	_check(world_textures.has(key) and (world_textures[key]["alpha"] as Dictionary).is_empty(),
		"the world holds %s with no alpha statistic measured (got %s)" % [key, str(world_textures.keys())])
	if not world_textures.has(key):
		return
	var pixels := BmtReader.Layer.new()
	pixels.layer_name = "pixels"
	pixels.texture_path = "scenery.ddj"
	pixels.unknown = 0
	var snapshot := ObjectLoader.snapshot_textures(world_textures)
	var fifth := {"textures": {}, "missing": [], "log": []}
	ObjectLoader._prepare_material(data_pk2, "prim\\scenery.bmt", pixels, snapshot, fifth)
	var redecoded: Dictionary = (fifth["textures"] as Dictionary).get(key, {})
	_check(snapshot.has(key) and redecoded.get("image") is Image
			and (redecoded.get("alpha", {}) as Dictionary).has("binary_cutout"),
		"a layer the pixels decide decodes the held texture again for the statistic its snapshot lacked (got %s)" % str(redecoded))
	var job := {"objects": {"known_textures": snapshot, "textures": fifth["textures"]}}
	var got: Dictionary = w.call("_prepared_again", job)
	_check(got == none, "with no statistic carried in since the snapshot, that decode was needed and is not counted (got %s)" % str(got))
	# Another job measured the same statistic and committed first.
	var sixth := {"textures": {}, "missing": [], "log": []}
	ObjectLoader._prepare_material(data_pk2, "prim\\scenery.bmt", pixels, ObjectLoader.snapshot_textures(world_textures), sixth)
	ObjectLoader.commit_textures(sixth["textures"], world_textures)
	_check((world_textures[key]["alpha"] as Dictionary).has("binary_cutout"),
		"that commit merged the statistic into the uploaded texture's entry (ObjectLoader.commit_textures)")
	got = w.call("_prepared_again", job)
	_check(got == {"tiles": 0, "navmesh": 0, "collisions": 0, "heightmaps": 0, "models": 0, "textures": 1},
		"a held texture decoded again counts once a later commit has carried in the statistic it was decoded for (got %s)" % str(got))

## Round 568 (round 565's review, nonblocking: the stale-cell guard and the
## drop had no headless coverage; no box log from rounds 565-567 carries a
## `prepared but not committed` line). World3D._finish_cell_job commits a
## prepared cell only if it is still wanted -- not already loaded, and still
## inside the player's window (the unload margin, _region_load_radius() + 1)
## -- and _drop_cell_jobs waits for every task still preparing and forgets
## it. A subclass records _load_region_cell's calls instead of building, so
## the guard's own decision is what is held; a cell still wanted is its
## control.
func _test_stale_cells_are_not_committed() -> void:
	var sub := GDScript.new()
	sub.source_code = "\n".join(PackedStringArray([
		"extends \"res://scripts/World3D.gd\"",
		"var built: Array = []",
		"func _load_region_cell(region_x: int, region_y: int, dx: int, dy: int, shared_anchor: float, prepared: Dictionary = {}) -> void:",
		"\tbuilt.append(\"%d/%d\" % [region_x, region_y])",
		""]))
	_check(sub.reload() == OK and sub.can_instantiate(), "a subclass of World3D.gd recording its commits compiles")
	if not sub.can_instantiate():
		return
	var w: Node = sub.new()
	w.set("_last_stream_cell", Vector2i(0, 0))
	var far: int = int(w.call("_region_load_radius")) + 2
	var grid = w.get("_grid")
	for key in ["loaded", "far", "wanted"]:
		grid.queued_cells[key] = true
	grid.loaded_cells["loaded"] = true
	w.call("_finish_cell_job", {"cell": {"rx": 97, "ry": 169, "dx": 0, "dy": 1, "key": "loaded"}, "job": {}})
	w.call("_finish_cell_job", {"cell": {"rx": 97 + far, "ry": 168, "dx": far, "dy": 0, "key": "far"}, "job": {}})
	var built: Array = w.get("built")
	_check(built.is_empty(), "a cell already loaded, and one %d cells from the player's (past the unload margin), are not committed (got %s)" % [far, str(built)])
	_check(not grid.queued_cells.has("loaded") and not grid.queued_cells.has("far"), "and both leave the queued set")
	w.call("_finish_cell_job", {"cell": {"rx": 97, "ry": 167, "dx": 0, "dy": -1, "key": "wanted"}, "job": {}})
	built = w.get("built")
	_check(built == ["97/167"] and not grid.queued_cells.has("wanted"), "a cell still wanted is committed (the control; got %s)" % str(built))
	var jobs: Array = w.get("_cell_jobs")
	for k in ["x", "y"]:
		grid.queued_cells[k] = true
		jobs.append({"task": WorkerThreadPool.add_task(func(): OS.delay_msec(20), true, "r568 drop test"), "cell": {"key": k}, "job": {}})
	w.call("_drop_cell_jobs", "the test is over")
	_check((w.get("_cell_jobs") as Array).is_empty() and not grid.queued_cells.has("x") and not grid.queued_cells.has("y")
			and (w.get("built") as Array).size() == 1,
		"_drop_cell_jobs waits for both preparing cells and forgets them, uncommitted")
	w.free()

## Round 566's review: _pump_cell_jobs commits a finished cell BEFORE it
## dispatches the next, so the next job's snapshot holds what that commit
## cached. Until the review it dispatched first. A subclass overrides
## _dispatch_cell (an empty task per cell) and _finish_cell_job to record
## the calls, so the pump's own order is what is held: with two in flight
## and a third queued, one commit must come before the third's dispatch.
func _test_pump_commits_before_it_dispatches() -> void:
	var sub := GDScript.new()
	sub.source_code = "\n".join(PackedStringArray([
		"extends \"res://scripts/World3D.gd\"",
		"var calls: Array = []",
		"func _dispatch_cell(cell: Dictionary) -> void:",
		"\tcalls.append(\"dispatch %s\" % cell[\"key\"])",
		"\t_cell_jobs.append({\"task\": WorkerThreadPool.add_task(func(): pass, true, \"r566 pump order test\"), \"cell\": cell, \"job\": {}})",
		"func _finish_cell_job(flight: Dictionary) -> void:",
		"\t_grid.queued_cells.erase(flight[\"cell\"][\"key\"])",
		"\tcalls.append(\"finish %s\" % flight[\"cell\"][\"key\"])",
		""]))
	_check(sub.reload() == OK and sub.can_instantiate(), "a recording subclass of World3D.gd compiles")
	if not sub.can_instantiate():
		return
	var w: Node = sub.new()
	w.set("_last_stream_cell", Vector2i(0, 0))
	var queue: Array = []
	for key in ["a", "b", "c"]:
		queue.append({"rx": 97, "ry": 168, "dx": 0, "dy": 1, "key": key, "dist": 1})
	w.set("_load_queue", queue)
	w.call("_dispatch_cell_jobs")
	var flights: Array = w.get("_cell_jobs")
	_check(flights.size() == 2, "two cells in flight, one queued (got %d)" % flights.size())
	# Both empty tasks finished before the pump runs, so it takes the oldest.
	var tries := 0
	while tries < 20000 and not flights.all(func(f): return WorkerThreadPool.is_task_completed(f["task"])):
		OS.delay_usec(100)
		tries += 1
	var finished: int = w.call("_pump_cell_jobs", 1, false)
	var calls: Array = w.get("calls")
	_check(finished == 1 and calls == ["dispatch a", "dispatch b", "finish a", "dispatch c"],
		"the pump commits cell a before it dispatches cell c (got %s)" % str(calls))
	w.call("_drop_cell_jobs", "the test is over")
	w.free()

func _object_index() -> ObjidxReader.Table:
	var table := ObjidxReader.Table.new()
	var entries: Array[ObjidxReader.Entry] = []
	for id in range(3):
		var e := ObjidxReader.Entry.new()
		e.type_id = id
		e.path = ["", "prim\\wall.bsr", "prim\\tree.bsr"][id]
		entries.append(e)
	table.entries = entries
	return table

func _tile_table() -> TileIndexReader.Table:
	var table := TileIndexReader.Table.new()
	var entries: Array[TileIndexReader.Entry] = []
	for id in range(2):
		var e := TileIndexReader.Entry.new()
		e.id = id
		e.type = TileIndexReader.TileType.GRASS
		e.filename = ["", "missing.ddj"][id]
		entries.append(e)
	table.entries = entries
	return table

## Every Object reachable from `v` -- through Arrays, Dictionaries and each
## object's script variables -- that is a Node, or a Resource other than an
## Image (terrain_prepare_test.gd's walk).
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

## A real-shaped `.o` (MAPO_FORMAT.md; MapoReader): the magic and version,
## the two header words, then 28-byte records -- type, position, a 2-byte
## flag, the yaw, 6 bytes -- back to back. Wall, wall, tree and a type the
## index does not list.
func _build_mapo() -> PackedByteArray:
	var buf := PackedByteArray()
	buf.append_array((MapoReader.MAGIC + "1001").to_ascii_buffer())
	buf.resize(buf.size() + 8)
	for rec in [[1, Vector3(100, 0, 100), 0.0], [1, Vector3(200, 0, 100), 1.0],
			[2, Vector3(300, 0, 300), 0.0], [3, Vector3(400, 0, 400), 0.0]]:
		var r := PackedByteArray()
		r.resize(MapoReader.FIXED_RECORD_LEN)
		r.encode_u32(0, rec[0])
		r.encode_float(4, rec[1].x)
		r.encode_float(8, rec[1].y)
		r.encode_float(12, rec[1].z)
		r.encode_float(MapoReader.POS_FIELD_LEN + 2, rec[2])
		buf.append_array(r)
	return buf

## A real-shaped `.o2` (MAPO2_FORMAT.md; MapO2Reader): 36 sectors of four
## counted fields; sector 0's list 2 (field 3) holds a repeat of the first
## wall, a tree at this region's ground height and one 50 above it.
func _build_mapo2() -> PackedByteArray:
	var buf := PackedByteArray()
	buf.append_array((MapO2Reader.MAGIC + "1001").to_ascii_buffer())
	var entries := [[1, Vector3(100, 0, 100), 0.0], [2, Vector3(500, 0, 500), 0.0], [2, Vector3(600, 50, 600), 0.0]]
	for sector in range(MapO2Reader.SECTORS_PER_SIDE * MapO2Reader.SECTORS_PER_SIDE):
		for field in range(MapO2Reader.FIELDS_PER_SECTOR):
			var count := entries.size() if sector == 0 and field == 3 else 0
			var c := PackedByteArray()
			c.resize(2)
			c.encode_u16(0, count)
			buf.append_array(c)
			for i in range(count):
				var e := PackedByteArray()
				e.resize(MapO2Reader.ENTRY_LEN)
				e.encode_u32(0, entries[i][0])
				e.encode_float(4, entries[i][1].x)
				e.encode_float(8, entries[i][1].y)
				e.encode_float(12, entries[i][1].z)
				e.encode_float(18, entries[i][2])
				buf.append_array(e)
	return buf

## A real-shaped 7-byte-vertex `.m` (terrain_prepare_test.gd's layout), every
## vertex at `height`, texture ID 1.
func _build_flat_mapm(height: float) -> PackedByteArray:
	var block_len := MapmReader.BLOCK_HEADER_LEN + MapmReader.VERTEX_COUNT * MapmReader.VERTEX_LEN_7 \
		+ MapmReader.PLANE_INFO_LEN + MapmReader.TILE_FLAG_LEN + MapmReader.HEIGHT_INFO_LEN + MapmReader.RESERVED_LEN_7
	var buf := PackedByteArray()
	buf.resize(MapmReader.HEADER_LEN + MapmReader.BLOCK_COUNT * block_len)
	var head := (MapmReader.MAGIC + "1000").to_ascii_buffer()
	for i in range(head.size()):
		buf[i] = head[i]
	for b in range(MapmReader.BLOCK_COUNT):
		var off := MapmReader.HEADER_LEN + b * block_len + MapmReader.BLOCK_HEADER_LEN
		for v in range(MapmReader.VERTEX_COUNT):
			buf.encode_float(off, height)
			buf.encode_u16(off + 4, 1)
			off += MapmReader.VERTEX_LEN_7
		buf[off] = 0xff # PlaneType -1 (Normal)
	return buf

## A `.bsr` (object_loader_test.gd's layout): name, 48 bytes, mesh path, 60
## bytes, material path, sub-mesh count and paths.
func _build_bsr(obj_name: String, mesh_path: String, material_path: String, sub_paths: Array) -> PackedByteArray:
	var buf := PackedByteArray()
	buf.resize(BsrReader.PREAMBLE_END)
	var magic := BsrReader.MAGIC.to_ascii_buffer()
	for i in range(magic.size()):
		buf[i] = magic[i]
	_append_str(buf, obj_name)
	buf.resize(buf.size() + 48)
	_append_str(buf, mesh_path)
	buf.resize(buf.size() + 60)
	_append_str(buf, material_path)
	var count := PackedByteArray()
	count.resize(4)
	count.encode_u32(0, sub_paths.size())
	buf.append_array(count)
	for p in sub_paths:
		_append_str(buf, p)
	return buf

## A one-triangle `.bms` (object_loader_test.gd's layout).
func _build_bms(mesh_name: String, material_name: String) -> PackedByteArray:
	var buf := PackedByteArray()
	buf.resize(BmsReader.PREAMBLE_END)
	var magic := BmsReader.MAGIC.to_ascii_buffer()
	for i in range(magic.size()):
		buf[i] = magic[i]
	_append_str(buf, mesh_name)
	_append_str(buf, material_name)
	var counts := PackedByteArray()
	counts.resize(8)
	counts.encode_u32(0, 1)
	counts.encode_u32(4, 3)
	buf.append_array(counts)
	for corner in [Vector3(0, 0, 0), Vector3(10, 0, 0), Vector3(0, 0, 10)]:
		var rec := PackedByteArray()
		rec.resize(44)
		rec.encode_float(0, corner.x)
		rec.encode_float(4, corner.y)
		rec.encode_float(8, corner.z)
		rec.encode_float(0x10, 1.0) # normal.y
		buf.append_array(rec)
	buf.encode_u32(BmsReader.HEADER_PTRS_BASE + 4, buf.size())
	var idx := PackedByteArray()
	idx.resize(10)
	idx.encode_u32(0, 1)
	idx.encode_u16(4, 0)
	idx.encode_u16(6, 1)
	idx.encode_u16(8, 2)
	buf.append_array(idx)
	return buf

## An uncompressed one-layer `.bmt` (object_loader_test.gd's layout), flag
## word 0x40: a layer the flag decides, solid.
func _build_bmt(layer_name: String, texture: String) -> PackedByteArray:
	var buf := PackedByteArray()
	buf.append_array("JMXVBMT 0102".to_ascii_buffer())
	var count := PackedByteArray()
	count.resize(4)
	count.encode_u32(0, 1)
	buf.append_array(count)
	_append_str(buf, layer_name)
	var colours := PackedByteArray()
	colours.resize(17 * 4 + 4)
	for i in range(16):
		colours.encode_float(i * 4, 1.0)
	colours.encode_u32(17 * 4, 0x40)
	buf.append_array(colours)
	_append_str(buf, texture)
	return buf

## A 4x4 uncompressed 32-bit BGRA `.ddj`, opaque.
func _build_bgra_ddj(width: int, height: int) -> PackedByteArray:
	var dds := PackedByteArray()
	dds.resize(4 + DdjReader.DDS_HEADER_SIZE + width * height * 4)
	var dds_magic := "DDS ".to_ascii_buffer()
	for i in range(4):
		dds[i] = dds_magic[i]
	dds.encode_u32(4, DdjReader.DDS_HEADER_SIZE)
	dds.encode_u32(4 + 8, height)
	dds.encode_u32(4 + 12, width)
	dds.encode_u32(4 + 24, 1)
	dds.encode_u32(4 + 72, 32)
	dds.encode_u32(4 + 72 + 4, DdjReader.DDPF_RGB | DdjReader.DDPF_ALPHAPIXELS)
	dds.encode_u32(4 + 72 + 12, 32)
	dds.encode_u32(4 + 72 + 16, 0x00ff0000)
	dds.encode_u32(4 + 72 + 20, 0x0000ff00)
	dds.encode_u32(4 + 72 + 24, 0x000000ff)
	dds.encode_u32(4 + 72 + 28, 0xff000000)
	for i in range(width * height * 4):
		dds[4 + DdjReader.DDS_HEADER_SIZE + i] = 0xff
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

func _append_str(buf: PackedByteArray, s: String) -> void:
	var bytes := s.to_ascii_buffer()
	var n := PackedByteArray()
	n.resize(4)
	n.encode_u32(0, bytes.size())
	buf.append_array(n)
	buf.append_array(bytes)

## A synthetic pk2 holding `files` ({"folder\\name": bytes}), one directory
## block per folder, unencrypted (terrain_prepare_test.gd's writer).
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

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)
