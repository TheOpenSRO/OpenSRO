extends RefCounted
class_name RegionGridState

## The per-region bookkeeping World3D keeps while a region grid is loaded,
## in one place so the streaming unload can forget a region whole -- kept
## apart from World3D so a headless test can hold it to account (round 563).
##
## Why. Until round 563 this was seven parallel members of World3D, and
## `_maybe_stream_regions`' unload loop touched one of them: it queue_freed
## the region's RealTerrain_/RealMapObjects_ nodes, released its scenery
## templates (round 559) and erased its `_loaded_cells` key. Everything else
## the region owned stayed behind:
## - its `_npc_regions_done` mark, so when the cell streamed back in
##   `_try_spawn_region_npcs` returned at its first line and the town came
##   back with nobody in it -- its NPCs are children of the terrain node and
##   went with it (only a zone change, `_clear_region_grid`, cleared the mark);
## - its `[NavGraph, group]` pair in `_region_nav_graphs`, holding the freed
##   group: `_nav_graph_for`'s typed `var group: Node3D = pair[1]` then raised
##   `Trying to assign invalid previously freed instance` and aborted on every
##   call, once per physics tick, for every region loaded after the freed one
##   (round 563's baseline tour: 687 such errors after the first unload, the
##   player's `QA <tick> local` reading `off-region` for the rest of the run,
##   and no later viewpoint able to place the player);
## - its parsed navmesh in `_navmesh_cache`, its heightmap in
##   `_parsed_region_heightmaps` and the object navigation meshes it alone
##   referenced in `_object_collision_cache`, none of which anything pruned,
##   so all three grew with every region ever visited.
##
## What is held to account (region_grid_state_test.gd): `unload(x, y)`
## forgets one region -- its loaded cell, NPC mark, nav graph, navmesh,
## heightmap and the object collision meshes no cached navmesh lists any
## more -- and leaves every other region's entries alone; a region unloaded
## and marked again is populated again; `clear_all()` is the zone change.

## Loaded cells, "dx_dy" relative to World3D's grid origin ->
## Vector2i(region_x, region_y): the region the cell holds, so an unload by
## region finds its cell without the origin.
var loaded_cells := {}
## Cells waiting in World3D._load_queue, "dx_dy" -> true, so a cell is not
## queued twice. A loaded cell is never queued: the queue drops a key as it
## pops it and skips a loaded one, so unload() leaves this alone. Since round
## 565 a cell whose terrain is preparing on a WorkerThreadPool task keeps its
## key until it is committed or dropped (World3D._cell_jobs), so it is not
## queued again while it prepares.
var queued_cells := {}
## Regions whose NPCs stand in the tree, "x_y" -> true, so streaming back
## into a region does not stack a second copy of everyone in it. Cleared
## per region by unload(), since the region's NPCs are children of its
## terrain node and are freed with it.
var npc_regions_done := {}
## Real walkable graphs, "x_y" -> [NavGraph, Node3D]: the graph plus the
## region's terrain group, whose own local space *is* that region's real
## coordinate space, so converting between the two is done with the node's
## real transform rather than by re-deriving the region placement (and its
## mirror) by hand.
var nav_graphs := {}
## Parsed per-region navmeshes by the navmesh file's own id, navmesh_key()
## (World3D.NAVMESH_PATH_FORMAT names the file by it) -> NvmReader.ParsedRegion.
## A null entry means "already tried, nothing usable", and is cached too.
var navmesh_cache := {}
## Parsed `.m` heightmaps, "x_y" -> MapmReader.ParsedRegion (null: tried,
## nothing), for the placement-ownership test that samples a neighbour's
## terrain without rebuilding it. Pruned to the loaded regions and their
## neighbours (prune_heightmaps), since the test parses neighbours that are
## not cells of the grid.
var parsed_heightmaps := {}
## Real object navigation meshes by real resource id -> BmsReader.CollisionMesh
## (null: tried, none), shared by every region that places the object.
## Pruned to what the cached navmeshes still list, never by region.
var object_collision_cache := {}

## The project's own region notation, "x_y" (Jangan town is 97/168, file
## 97\168.m, key "97_168").
static func region_key(region_x: int, region_y: int) -> String:
	return "%d_%d" % [region_x, region_y]

## The navmesh file's own id: `nv_%04x.nvm` is (x << 8) | y, the key
## World3D._load_region_navmesh has always cached by.
static func navmesh_key(region_x: int, region_y: int) -> int:
	return (region_x << 8) | region_y

func mark_loaded(dx: int, dy: int, region_x: int, region_y: int) -> void:
	loaded_cells["%d_%d" % [dx, dy]] = Vector2i(region_x, region_y)

func mark_npcs_done(region_x: int, region_y: int) -> void:
	npc_regions_done[region_key(region_x, region_y)] = true

func npcs_done(region_x: int, region_y: int) -> bool:
	return npc_regions_done.has(region_key(region_x, region_y))

func add_nav_graph(region_x: int, region_y: int, graph: NavGraph, group: Node3D) -> void:
	nav_graphs[region_key(region_x, region_y)] = [graph, group]

## The [graph, group] pair for a region, or [] when it has none loaded.
func nav_graph_for_region(region_x: int, region_y: int) -> Array:
	var pair: Array = nav_graphs.get(region_key(region_x, region_y), [])
	if pair.is_empty() or not is_instance_valid(pair[1]):
		return []
	return pair

## Every loaded region's [graph, group] pair whose group is still alive.
## Validity is tested before anything is assigned to a typed variable: a
## typed assignment of a freed instance is a script error that aborts the
## caller (the baseline failure above).
func nav_graph_pairs() -> Array:
	var out: Array = []
	for pair in nav_graphs.values():
		if is_instance_valid(pair[1]):
			out.append(pair)
	return out

## Forgets one region: its loaded cell, its NPC mark, its nav graph, its
## navmesh, its heightmap, and then the object collision meshes no cached
## navmesh lists any more. Returns what it dropped, named, for the log.
## Idempotent: a second call for the same region drops nothing.
func unload(region_x: int, region_y: int) -> PackedStringArray:
	var dropped := PackedStringArray()
	var key := region_key(region_x, region_y)
	var region := Vector2i(region_x, region_y)
	for cell_key in loaded_cells.keys():
		if loaded_cells[cell_key] == region:
			loaded_cells.erase(cell_key)
			dropped.append("cell %s" % cell_key)
			break
	if npc_regions_done.erase(key):
		dropped.append("npcs")
	if nav_graphs.erase(key):
		dropped.append("nav graph")
	if navmesh_cache.erase(navmesh_key(region_x, region_y)):
		dropped.append("navmesh")
	if parsed_heightmaps.erase(key):
		dropped.append("heightmap")
	var neighbours := prune_heightmaps()
	if neighbours > 0:
		dropped.append("%d neighbour heightmap(s)" % neighbours)
	var pruned := prune_object_collisions()
	if pruned > 0:
		dropped.append("%d object collision mesh(es)" % pruned)
	return dropped

## Drops the parsed heightmaps of regions that are neither loaded nor next
## to a loaded region. The placement-ownership test parses a region's eight
## neighbours whether or not they are cells of the grid (round 563's tour
## held 28 heightmaps for 12 cells), and a region that never loaded is never
## unloaded, so without this an unload could only drop the region's own.
## What a cell still to be built next to the loaded ones would re-read is
## kept. Returns how many went.
func prune_heightmaps() -> int:
	var pruned := 0
	for key in parsed_heightmaps.keys():
		var parts := (key as String).split("_")
		var region := Vector2i(int(parts[0]), int(parts[1]))
		var wanted := false
		for loaded in loaded_cells.values():
			var d: Vector2i = (loaded as Vector2i) - region
			if absi(d.x) <= 1 and absi(d.y) <= 1:
				wanted = true
				break
		if not wanted:
			parsed_heightmaps.erase(key)
			pruned += 1
	return pruned

## Drops every object collision mesh whose resource id no cached navmesh
## lists -- after an unload, the objects only the departed region placed.
## Returns how many. Safe: a NavGraph.PlacedObject holds its own reference
## to the mesh it was placed from, and a dropped id is re-read from the
## archive the next time a region lists it.
func prune_object_collisions() -> int:
	var referenced := {}
	for parsed in navmesh_cache.values():
		if parsed == null:
			continue
		for obj in parsed.objects:
			referenced[obj.resource_id] = true
	var pruned := 0
	for resource_id in object_collision_cache.keys():
		if not referenced.has(resource_id):
			object_collision_cache.erase(resource_id)
			pruned += 1
	return pruned

## A zone change: every region's nodes are torn down, so nothing here is
## referenced any more.
func clear_all() -> void:
	loaded_cells.clear()
	queued_cells.clear()
	npc_regions_done.clear()
	nav_graphs.clear()
	navmesh_cache.clear()
	parsed_heightmaps.clear()
	object_collision_cache.clear()

## One line of counts for the QA log (`QA GRID`), so a run that crosses
## region boundaries shows the per-region caches staying bounded instead
## of growing with every region ever visited.
func counts_line() -> String:
	return "cells=%d queued=%d npc_regions=%d nav_graphs=%d navmesh=%d heightmaps=%d collisions=%d" % [
		loaded_cells.size(), queued_cells.size(), npc_regions_done.size(), nav_graphs.size(),
		navmesh_cache.size(), parsed_heightmaps.size(), object_collision_cache.size()]
