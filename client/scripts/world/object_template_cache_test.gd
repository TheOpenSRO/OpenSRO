extends SceneTree

## Exercises ObjectTemplateCache -- one scenery template per model path per
## world, owned and freed by the cache -- run headless:
## `godot4 --headless --path client --script res://scripts/world/object_template_cache_test.gd`
##
## The loader is a counter that builds a Node3D with one MeshInstance3D
## child (never game data). What is held to account is the ownership: one
## build per path across regions and spellings, copies that outlive a freed
## template, templates freed with their last region, with the world
## (free_all) and with the cache itself (NOTIFICATION_PREDELETE), a zone
## change that keeps them, a failed load that is not cached, and the cap.

var _failures := 0
var _built: Array[Node3D] = [] # every template the fake loader returned, in order
var _load_calls := {} # path -> how many times the loader was asked

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _fake_load(path: String) -> Node3D:
	_load_calls[path] = int(_load_calls.get(path, 0)) + 1
	if path.begins_with("missing"):
		return null
	var root := Node3D.new()
	root.name = path.get_file().get_basename()
	var piece := MeshInstance3D.new()
	piece.name = "piece"
	root.add_child(piece)
	_built.append(root)
	return root

func _reset() -> void:
	_built.clear()
	_load_calls.clear()

func _test_one_build_per_path_across_regions() -> void:
	_reset()
	var cache := ObjectTemplateCache.new(_fake_load)
	var a1 := cache.instance("prim\\bsr\\Wall.bsr", "97\\168.o")
	var a2 := cache.instance("prim\\bsr\\wall.bsr", "97\\168.o")
	var a3 := cache.instance("PRIM\\BSR\\WALL.BSR", "97\\167.o")
	_check(a1 != null and a2 != null and a3 != null, "three placements of one model come back")
	_check(_load_calls.size() == 1 and int(_load_calls.values()[0]) == 1,
		"the loader built it once, for three placements over two regions and three spellings (calls: %s)" % [_load_calls])
	_check(cache.size() == 1 and cache.loads == 1 and cache.reuses == 2,
		"size 1, loads 1, reuses 2 (got %d / %d / %d)" % [cache.size(), cache.loads, cache.reuses])
	_check(cache.has("prim\\bsr\\wall.bsr") and cache.has("PRIM\\BSR\\WALL.BSR"), "has() is case-insensitive")
	_check(a1 != a2 and a2 != a3 and a1 != _built[0] and a3 != _built[0],
		"each placement is its own copy, none of them the template")
	_check(a1.get_child_count() == 1 and a1.get_child(0).name == "piece", "a copy carries the template's children")
	a1.position = Vector3(1, 2, 3)
	a1.name = "Obj_wall_0"
	_check(_built[0].position == Vector3.ZERO and _built[0].name == "Wall",
		"per-placement state goes on the copy: the template is untouched")
	_check(is_instance_valid(_built[0]) and not _built[0].is_inside_tree(), "the template is alive and detached")
	for n in [a1, a2, a3]:
		n.free()
	cache.free_all()

## Round 566: an objects job snapshots the held paths on the main thread
## (World3D._objects_job) so its off-thread prepare skips built models -- a
## copy, lower-cased, that the cache's own changes do not reach. Reached
## through call(), so a cache without it FAILS rather than failing to parse.
func _test_held_keys_is_a_snapshot() -> void:
	_reset()
	var cache := ObjectTemplateCache.new(_fake_load)
	_check(cache.has_method("held_keys"), "ObjectTemplateCache has held_keys (absent before round 566)")
	if not cache.has_method("held_keys"):
		return
	_check(cache.call("held_keys") == {}, "an empty cache holds no key")
	cache.instance("prim\\bsr\\Wall.bsr", "A").free()
	cache.instance("missing\\x.bsr", "A")
	var held: Dictionary = cache.call("held_keys")
	_check(held == {"prim\\bsr\\wall.bsr": true}, "the held template's key, lower-cased; a failed load holds none (got %s)" % [held])
	held["other.bsr"] = true
	cache.release_region("A")
	_check(cache.call("held_keys") == {} and held.size() == 2,
		"a snapshot is a copy: the cache's release does not touch it, nor it the cache")
	cache.free_all()

func _test_failed_load_is_not_cached() -> void:
	_reset()
	var cache := ObjectTemplateCache.new(_fake_load)
	_check(cache.instance("missing\\x.bsr", "r") == null, "a loader null is a null placement")
	_check(cache.instance("missing\\x.bsr", "r") == null and int(_load_calls["missing\\x.bsr"]) == 2,
		"... and the loader is asked again next time, as before (a failure is not cached)")
	_check(cache.size() == 0 and not cache.has("missing\\x.bsr") and cache.loads == 0, "nothing is held for it")

func _test_release_region_frees_at_last_user() -> void:
	_reset()
	var cache := ObjectTemplateCache.new(_fake_load)
	var shared := cache.instance("wall.bsr", "A")
	cache.instance("wall.bsr", "B").free()
	var only_a := cache.instance("roof.bsr", "A")
	_check(cache.size() == 2, "two templates held")
	_check(cache.release_region("A") == 1, "releasing A frees the template only A placed (roof), not the shared wall")
	_check(cache.has("wall.bsr") and not cache.has("roof.bsr"), "wall kept, roof gone")
	_check(is_instance_valid(_built[0]) and not is_instance_valid(_built[1]),
		"the roof template is freed, the wall template alive")
	_check(is_instance_valid(only_a) and is_instance_valid(shared) and only_a.get_child_count() == 1,
		"placed copies outlive a freed template")
	_check(cache.release_region("A") == 0, "releasing A again frees nothing")
	_check(cache.release_region("B") == 1 and cache.size() == 0 and not is_instance_valid(_built[0]),
		"B's release frees the wall, its last user gone")
	only_a.free()
	shared.free()

func _test_forget_regions_keeps_templates() -> void:
	_reset()
	var cache := ObjectTemplateCache.new(_fake_load)
	cache.instance("wall.bsr", "A").free()
	cache.forget_regions()
	_check(cache.size() == 1 and is_instance_valid(_built[0]), "a zone change keeps the template")
	_check(cache.release_region("A") == 0 and cache.size() == 1, "the old region's release no longer frees it")
	cache.instance("wall.bsr", "C").free()
	_check(int(_load_calls["wall.bsr"]) == 1 and cache.reuses == 1, "the next zone reuses it without a rebuild")
	_check(cache.release_region("C") == 1 and not is_instance_valid(_built[0]), "and its new last user frees it")

func _test_free_all_and_predelete() -> void:
	_reset()
	var cache := ObjectTemplateCache.new(_fake_load)
	cache.instance("a.bsr", "r").free()
	cache.instance("b.bsr", "r").free()
	_check(cache.free_all() == 2 and cache.size() == 0, "free_all frees both")
	_check(not is_instance_valid(_built[0]) and not is_instance_valid(_built[1]), "... really freed")
	cache.instance("c.bsr", "r").free()
	_check(cache.size() == 1 and int(_load_calls["c.bsr"]) == 1, "the cache still works after free_all")
	var template_c := _built[2]
	cache = null # the last reference goes: NOTIFICATION_PREDELETE
	_check(not is_instance_valid(template_c), "deleting the cache frees what it still held")

func _test_cap_evicts_oldest_unused_first() -> void:
	_reset()
	var cache := ObjectTemplateCache.new(_fake_load, 2)
	cache.instance("x.bsr", "A").free()
	cache.forget_regions() # x is unused from here
	cache.instance("y.bsr", "B").free()
	cache.instance("z.bsr", "B").free() # the third: over the cap of 2
	_check(cache.size() == 2 and cache.evictions == 1,
		"the cap holds the size at 2 (got %d, %d evictions)" % [cache.size(), cache.evictions])
	_check(not cache.has("x.bsr") and cache.has("y.bsr") and cache.has("z.bsr"),
		"the unused x went, not the older-in-use y")
	_check(not is_instance_valid(_built[0]), "the evicted template is freed")
	cache.instance("w.bsr", "B").free() # every template in use: the oldest goes
	_check(not cache.has("y.bsr") and cache.has("z.bsr") and cache.has("w.bsr") and cache.evictions == 2,
		"with every template in use the oldest (y) goes")
	var copy := cache.instance("z.bsr", "B")
	cache.instance("v.bsr", "B").free() # evicts z while a copy of it is placed
	_check(not cache.has("z.bsr") and is_instance_valid(copy) and copy.get_child_count() == 1,
		"a placed copy survives its template's eviction")
	copy.free()
	cache.free_all()

func _init() -> void:
	_test_one_build_per_path_across_regions()
	_test_held_keys_is_a_snapshot()
	_test_failed_load_is_not_cached()
	_test_release_region_frees_at_last_user()
	_test_forget_regions_keeps_templates()
	_test_free_all_and_predelete()
	_test_cap_evicts_oldest_unused_first()

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
