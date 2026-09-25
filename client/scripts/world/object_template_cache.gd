extends RefCounted
class_name ObjectTemplateCache

## One built scenery template per model path for a whole world, owned here
## and duplicated per placement -- kept apart from World3D so a headless
## test can hold the ownership rules to account (round 559).
##
## Why. `World3D._try_load_real_map_objects` used to keep a function-local
## `templates` dictionary, so every region parsed, meshed, trimeshed and
## uploaded its own copy of each model it placed -- and the models recur:
## the `cj_s.bsr` city wall is placed by five regions, roofs, walls and
## trees by most of a town's. Worse, the template Nodes were never parented
## and never freed, so they outlived the region, the zone change and the
## World3D instance itself. Measured at the exit of a radius-1 (9-region)
## run (`/var/tmp/yawshot.log` on the render box, round 558's grounding):
## `1234 RID allocations of type 'N5GLES34MeshE' were leaked at exit`, 1234
## Material, 1235 Texture, 1057 GodotBody3D and 1057 GodotShape3D -- and a
## scripted reconnect doubled every one of them (round 558's run A2: 2468 /
## 2468 / 2469 / 2114 / 2114) and the orphan-node count exactly, 3,770 ->
## 7,540.
##
## Ownership rules, each held by object_template_cache_test.gd:
## - A template is a detached Node3D that is never put in the tree; a
##   placement gets `duplicate()`, and anything per placement (position,
##   yaw, name, metadata) goes on the copy, never the template.
## - Copies share the template's Mesh, Material and Texture resources by
##   reference, so freeing a template never touches a placed copy: it gives
##   up only the template's own nodes (and, once the last copy is gone, the
##   shared resources). Eviction is therefore always safe -- at worst a
##   re-parse if the model is placed again.
## - A template is freed when the last region that placed it is released
##   (`release_region`, the streaming unload), when the world drops them
##   all (`free_all`, from `World3D._exit_tree`) and -- belt and braces --
##   when this cache itself is deleted (NOTIFICATION_PREDELETE), so no path
##   out of a world leaves one behind.
## - A zone change keeps them (`forget_regions`): the same models recur
##   across a continent's towns, and they are the first the cap evicts.
## - A failed load is not cached, exactly as before: the next placement of
##   that path tries again (and reports again).

## The most templates held at once. An own safety valve, disclosed: not a
## game value. Chosen so a long walk cannot hold every model ever seen
## while staying several towns' worth: round 558's radius-1 Jangan grid
## (`/var/tmp/r558/runA2.log`, the `loaded ... distinct real models`
## lines) reports 69, 63 and 61 distinct models for its three largest
## cells (97/168, 97/167, 97/169) and 358 over all nine -- 226 templates
## once shared (round 559) -- so 9 cells hold well under this cap. (Round
## 564: this comment had "69, 63 and 20 ... its three largest"; 20 is the
## third cell the log prints, 96/168, not the third largest.) When the cap
## is passed the oldest templates go first, unused ones before ones a
## loaded region still places.
const DEFAULT_MAX_TEMPLATES := 600

## Builds a template: called as `loader.call(path)`, returns a Node3D or
## null. World3D passes a method that commits the model its objects job
## prepared off the main thread (ObjectLoader.commit_object, round 566) or,
## with none, runs ObjectLoader.load_object with its archive and texture
## cache; the test passes a counter.
var _loader: Callable
var max_templates: int

var _templates := {} # path key -> Node3D, detached
var _users := {} # path key -> {region_key: true}
var _order: Array[String] = [] # path keys, oldest first, for the cap

## Counters for the load print and the QA ENTRY line: loader calls that
## returned a template, placements served from an existing one, templates
## the cap evicted.
var loads := 0
var reuses := 0
var evictions := 0

func _init(loader: Callable, cap: int = DEFAULT_MAX_TEMPLATES) -> void:
	_loader = loader
	max_templates = maxi(cap, 1)

## A placed copy of `path`'s template for the region `region_key`: built on
## first sight, duplicated after. Null when the loader returns null. Keys
## are case-insensitive, as the archive's own lookups are
## (ObjectLoader.find_file compares names lower-cased), so two regions
## spelling one file differently share one template.
func instance(path: String, region_key: String) -> Node3D:
	var key := path.to_lower()
	var template: Node3D = _templates.get(key)
	if template == null:
		template = _loader.call(path)
		if template == null:
			return null
		_templates[key] = template
		_users[key] = {region_key: true}
		_order.append(key)
		loads += 1
		_enforce_cap()
	else:
		reuses += 1
		_users[key][region_key] = true
	return template.duplicate()

func has(path: String) -> bool:
	return _templates.has(path.to_lower())

## The path keys (lower-cased) a template is held for now, key -> true: an
## objects job snapshots them on the main thread (World3D._objects_job,
## round 566), so its off-thread prepare skips the models this world has
## already built. A copy -- the cache itself stays the main thread's.
func held_keys() -> Dictionary:
	var keys := {}
	for key in _templates:
		keys[key] = true
	return keys

func size() -> int:
	return _templates.size()

## Withdraws `region_key`'s placements (the region streamed out) and frees
## the templates no loaded region places any more. Returns how many.
func release_region(region_key: String) -> int:
	var freed := 0
	for key in _users.keys():
		var users: Dictionary = _users[key]
		if not users.erase(region_key):
			continue
		if users.is_empty():
			_drop(key)
			freed += 1
	return freed

## A zone change: every region's placements are withdrawn but the templates
## are kept, since the same models recur; they are the first the cap
## evicts, and a later region that places one takes it over again.
func forget_regions() -> void:
	for key in _users.keys():
		_users[key] = {}

## Frees every template. Returns how many.
func free_all() -> int:
	var count := _templates.size()
	for key in _order.duplicate():
		_drop(key)
	return count

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		# Inlined rather than free_all(): at its predelete a RefCounted has
		# no reference left, so `self` as a call base is a null instance
		# here ("Attempt to call function 'free_all' in base 'null
		# instance'", round 559's first test run). Members and the
		# templates' own methods are still reachable.
		for template in _templates.values():
			if is_instance_valid(template):
				template.free()
		_templates.clear()
		_users.clear()
		_order.clear()

func _drop(key: String) -> void:
	var template: Node3D = _templates.get(key)
	if template != null and is_instance_valid(template):
		template.free()
	_templates.erase(key)
	_users.erase(key)
	_order.erase(key)

## Past the cap, the oldest templates go: first those no loaded region
## places (a zone change's leftovers), then the oldest still in use --
## safe, since placed copies never depend on their template.
func _enforce_cap() -> void:
	if _templates.size() <= max_templates:
		return
	var excess := _templates.size() - max_templates
	var victims: Array[String] = []
	for key in _order:
		if victims.size() >= excess:
			break
		if (_users[key] as Dictionary).is_empty():
			victims.append(key)
	for key in _order:
		if victims.size() >= excess:
			break
		if not victims.has(key):
			victims.append(key)
	var names := PackedStringArray()
	for key in victims:
		names.append(key.get_file())
		_drop(key)
	evictions += victims.size()
	print("ObjectTemplateCache: over %d templates -- evicted the %d oldest (%s)" % [
		max_templates, victims.size(), ", ".join(names)])
