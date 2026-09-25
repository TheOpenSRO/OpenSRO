extends SceneTree

## Exercises RegionGridState -- the per-region bookkeeping World3D keeps
## while a grid is loaded, and what a streaming unload must forget -- run
## headless:
## `godot4 --headless --path client --script res://scripts/world/region_grid_state_test.gd`
##
## The fixtures are bare objects (a NavGraph, an NvmReader.ParsedRegion with
## two MapObjects, a MapmReader.ParsedRegion, a Node3D group per region);
## never game data. What is held to account is the forgetting: unload(97,
## 167) drops that region's cell, NPC mark, nav graph, navmesh, heightmap
## and the object collision meshes only it referenced, and leaves 97/168's
## entries alone; a region marked again after an unload counts as populated
## again; clear_all() empties everything.
##
## NEGATIVE: the class is reached through load() by path and has_method
## guards (level_data_reader_test.gd's pattern), so on the tree before round
## 563 -- no region_grid_state.gd, World3D erasing only `_loaded_cells` in
## its unload loop while `_npc_regions_done` was cleared by `_clear_region_grid`
## alone and `_navmesh_cache` / `_parsed_region_heightmaps` /
## `_object_collision_cache` never -- this suite FAILS its first check
## rather than failing to parse. Proven on that tree for round 563's record.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _navmesh(resource_ids: Array) -> NvmReader.ParsedRegion:
	var region := NvmReader.ParsedRegion.new()
	for id in resource_ids:
		var obj := NvmReader.MapObject.new()
		obj.resource_id = id
		region.objects.append(obj)
	return region

func _init() -> void:
	var script := load("res://scripts/world/region_grid_state.gd") as GDScript
	var compiled := script != null and script.can_instantiate()
	_check(compiled, "region_grid_state.gd loads and can instantiate (absent before round 563)")
	if not compiled:
		_finish()
		return
	var state: RefCounted = script.new()
	var has_unload := state.has_method("unload")
	_check(has_unload, "RegionGridState has unload")
	if not has_unload:
		_finish()
		return

	_test_unload_forgets_one_region(state)
	_test_reentry_and_clear_all(script.new())
	_finish()

func _test_unload_forgets_one_region(state: RefCounted) -> void:
	var group_167 := Node3D.new()
	var group_168 := Node3D.new()
	var graph_167 := NavGraph.new()
	var graph_168 := NavGraph.new()
	# 97/167 lists objects 10 and 11; 97/168 lists 11 and 12: 10 is 167's
	# alone, 11 shared, 12 168's alone.
	state.mark_loaded(0, -1, 97, 167)
	state.mark_loaded(0, 0, 97, 168)
	state.mark_npcs_done(97, 167)
	state.mark_npcs_done(97, 168)
	state.add_nav_graph(97, 167, graph_167, group_167)
	state.add_nav_graph(97, 168, graph_168, group_168)
	state.navmesh_cache[state.navmesh_key(97, 167)] = _navmesh([10, 11])
	state.navmesh_cache[state.navmesh_key(97, 168)] = _navmesh([11, 12])
	state.parsed_heightmaps["97_167"] = MapmReader.ParsedRegion.new()
	state.parsed_heightmaps["97_168"] = MapmReader.ParsedRegion.new()
	# Neighbours the ownership test parsed without loading them: 96/166 is
	# 97/167's alone (diagonal), 98/169 is 97/168's alone, 96/167 is next
	# to both.
	state.parsed_heightmaps["96_166"] = MapmReader.ParsedRegion.new()
	state.parsed_heightmaps["98_169"] = null
	state.parsed_heightmaps["96_167"] = MapmReader.ParsedRegion.new()
	state.object_collision_cache[10] = null # tried, none -- cached too
	state.object_collision_cache[11] = BmsReader.CollisionMesh.new()
	state.object_collision_cache[12] = BmsReader.CollisionMesh.new()

	_check(state.navmesh_key(97, 168) == 0x61a8, "navmesh_key is (x << 8) | y (nv_61a8.nvm for 97/168)")
	_check(state.npcs_done(97, 167) and state.npcs_done(97, 168), "both regions count as populated before the unload")
	var before: Array = state.nav_graph_for_region(97, 167)
	_check(before.size() == 2 and before[0] == graph_167 and before[1] == group_167,
		"nav_graph_for_region answers [graph, group] for a loaded region")
	_check(state.nav_graph_pairs().size() == 2, "two pairs before the unload")

	var dropped: PackedStringArray = state.unload(97, 167)
	print("     unload(97,167) dropped: " + ", ".join(dropped))
	_check(not state.npcs_done(97, 167), "npcs_done(97,167) is false after the unload -- the region is repopulated when it streams back in")
	_check(state.npcs_done(97, 168), "... while 97/168 still counts as populated")
	_check(state.nav_graph_for_region(97, 167).is_empty(), "nav_graph_for_region(97,167) is empty after the unload")
	var after: Array = state.nav_graph_for_region(97, 168)
	_check(after.size() == 2 and after[0] == graph_168, "... while 97/168's pair stays")
	_check(state.nav_graph_pairs().size() == 1 and state.nav_graph_pairs()[0][1] == group_168,
		"nav_graph_pairs lists 97/168's pair alone")
	_check(not state.navmesh_cache.has(state.navmesh_key(97, 167)) and state.navmesh_cache.has(state.navmesh_key(97, 168)),
		"navmesh_cache has no 97/167 key and keeps 97/168's")
	_check(not state.parsed_heightmaps.has("97_167") and state.parsed_heightmaps.has("97_168"),
		"parsed_heightmaps has no 97/167 key and keeps 97/168's")
	_check(not state.parsed_heightmaps.has("96_166"),
		"a neighbour heightmap only the unloaded region's ownership test needed (96/166) is pruned")
	_check(state.parsed_heightmaps.has("98_169") and state.parsed_heightmaps.has("96_167"),
		"neighbour heightmaps next to the still-loaded 97/168 (98/169, 96/167) are kept")
	_check(not state.loaded_cells.has("0_-1") and state.loaded_cells.has("0_0"),
		"the region's own cell (0_-1) is dropped and 97/168's (0_0) kept")
	_check(not state.object_collision_cache.has(10), "object 10, listed by 97/167's navmesh alone, is pruned")
	_check(state.object_collision_cache.has(11) and state.object_collision_cache.has(12),
		"object 11 (shared with 97/168) and 12 (97/168's) are kept")
	_check(dropped.has("cell 0_-1") and dropped.has("npcs") and dropped.has("nav graph")
			and dropped.has("navmesh") and dropped.has("heightmap") and dropped.has("1 neighbour heightmap(s)")
			and dropped.has("1 object collision mesh(es)"),
		"unload names what it dropped (got: %s)" % ", ".join(dropped))
	_check(state.unload(97, 167).is_empty(), "a second unload of the same region drops nothing")
	_check(state.unload(50, 50).is_empty(), "unloading a region never loaded drops nothing")
	_check(state.counts_line() == "cells=1 queued=0 npc_regions=1 nav_graphs=1 navmesh=1 heightmaps=3 collisions=2",
		"counts_line reads the remaining region and its two neighbours (got: %s)" % state.counts_line())

	# A freed group is never handed out: the pair is skipped, not assigned.
	group_168.free()
	_check(state.nav_graph_for_region(97, 168).is_empty() and state.nav_graph_pairs().is_empty(),
		"a pair whose group was freed is not handed out (no typed assignment of a freed instance)")
	group_167.free()

func _test_reentry_and_clear_all(state: RefCounted) -> void:
	state.mark_loaded(1, 0, 98, 168)
	state.mark_npcs_done(98, 168)
	state.unload(98, 168)
	_check(not state.npcs_done(98, 168) and state.loaded_cells.is_empty(), "unloaded: 98/168 is neither loaded nor populated")
	# The cell streams back in: World3D marks it loaded and spawns its NPCs
	# again, which marks it done again.
	state.mark_loaded(1, 0, 98, 168)
	_check(not state.npcs_done(98, 168), "a cell that streamed back in is not yet populated -- _try_spawn_region_npcs runs for it")
	state.mark_npcs_done(98, 168)
	_check(state.npcs_done(98, 168) and state.loaded_cells["1_0"] == Vector2i(98, 168),
		"... and is populated once its NPCs are placed again")

	state.queued_cells["2_0"] = true
	state.navmesh_cache[state.navmesh_key(98, 168)] = _navmesh([7])
	state.object_collision_cache[7] = null
	state.parsed_heightmaps["98_168"] = null
	state.add_nav_graph(98, 168, NavGraph.new(), Node3D.new())
	var group: Node3D = state.nav_graph_for_region(98, 168)[1]
	state.clear_all()
	_check(state.loaded_cells.is_empty() and state.queued_cells.is_empty() and state.npc_regions_done.is_empty()
			and state.nav_graphs.is_empty() and state.navmesh_cache.is_empty()
			and state.parsed_heightmaps.is_empty() and state.object_collision_cache.is_empty(),
		"clear_all empties every dictionary (the zone change)")
	group.free()

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
