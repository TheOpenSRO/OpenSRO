extends SceneTree

## Round 786 (the ground flicker): a region's terrain overlays are drawn in
## one fixed order -- ascending tile key, retail's pass order -- whatever else
## is in the transparent list.
##
## The cause it guards (docs/WORLD_ISSUES.md, "Ground textures no longer
## flicker"): a region's overlays are surfaces of one mesh, so Godot gives them
## one depth, and at one render priority they tied in its alpha sort, an
## introsort that is not stable (READ, 4.7.2 render_forward_clustered.h
## `SortByReverseDepthAndPriority`, core/templates/sort_array.h). Their order
## then followed the rest of the list, and quads covered by two overlays
## flipped between two looks with the camera still.
##   - WorldFog.ground_overlay_priority: one priority per rank, increasing,
##     inside the band between the sky's quads and the water;
##   - the builder: each overlay carries its rank in ascending-key order and
##     its material (both the dynamic and the baked kind) that rank's
##     priority, so no two overlays of a region share one;
##   - the band holds the most overlays a region has (38, MEASURED over the
##     whole map archive with tools/ground_overlap_census.gd);
##   - REGRESSION, through a port of Godot 4.7.2's SortArray and the alpha
##     comparator: over 300 random transparent lists (other bodies and effects
##     at other depths and places), the builder's priorities put every
##     region's overlays in ascending key order every time; all at one
##     priority (the build before the fix) they come out in more than one
##     order.
## Headless: `client/tools/remote_godot.sh tests`.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	_test_priority_band()
	_test_builder_ranks()
	_test_sort_regression()
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)

# --- the band ------------------------------------------------------------------

## The sky's quads (World3D: sun -128, moon -127, cloud layer -126).
const SKY_HIGHEST := -126
## MEASURED (round 786): the most overlay surfaces any region of the map
## archive gets (92/131), tools/ground_overlap_census.gd CENSUS_ALL=1.
const MAX_OVERLAYS_MEASURED := 38

func _test_priority_band() -> void:
	var first := WorldFog.ground_overlay_priority(0)
	var last := WorldFog.GROUND_OVERLAY_PRIORITY
	_check(first == WorldFog.GROUND_OVERLAY_PRIORITY_FIRST and first > SKY_HIGHEST,
		"the first overlay rank draws after the sky's quads (%d > %d)" % [first, SKY_HIGHEST])
	var increasing := true
	for r in range(1, last - first + 1):
		if WorldFog.ground_overlay_priority(r) != WorldFog.ground_overlay_priority(r - 1) + 1:
			increasing = false
	_check(increasing, "each next rank one priority later, %d .. %d" % [first, last])
	_check(WorldFog.ground_overlay_priority(10000) == last and WorldFog.ground_overlay_priority(-5) == first,
		"ranks past the band clamp to it")
	_check(last < WorldFog.UNDER_PASS_PRIORITY and WorldFog.UNDER_PASS_PRIORITY < ShadowCatcher.PRIORITY,
		"every overlay still draws before the water (%d) and the shadow catcher (%d)" % [WorldFog.UNDER_PASS_PRIORITY, ShadowCatcher.PRIORITY])
	_check(last - first + 1 >= MAX_OVERLAYS_MEASURED,
		"the band's %d ranks hold the most overlays a region has (%d, MEASURED)" % [last - first + 1, MAX_OVERLAYS_MEASURED])

# --- the builder ---------------------------------------------------------------

## A synthetic region (never game data) whose vertices cycle through `tiles`
## tile IDs, so most quads use three or four of them.
static func _region(tiles: int, offset: int = 0) -> MapmReader.ParsedRegion:
	var region := MapmReader.ParsedRegion.new()
	region.version = "1000"
	for band_row in MapmReader.BLOCKS_PER_SIDE:
		for band_col in MapmReader.BLOCKS_PER_SIDE:
			var block := MapmReader.Block.new()
			block.vertices.resize(17 * 17)
			for r in 17:
				for c in 17:
					var v := MapmReader.Vertex.new()
					v.height = float(r + c) * 0.5
					var extra := PackedByteArray()
					extra.resize(3)
					extra.encode_u16(0, 1 + (((band_row * 16 + r) * 3 + (band_col * 16 + c) * 2 + offset) % tiles))
					v.extra = extra
					block.vertices[r * 17 + c] = v
			region.blocks.append(block)
	return region

static func _lookup(tiles: int) -> Dictionary:
	var out := {}
	for i in tiles:
		out[i + 1] = ImageTexture.create_from_image(Image.create(2, 2, false, Image.FORMAT_RGBA8))
	return out

func _test_builder_ranks() -> void:
	var tiles := 6
	var lookup := _lookup(tiles)
	for dynamic in [true, false]:
		var surfaces := MapmTerrainBuilder.build_full_region_surfaces_textured(_region(tiles), lookup,
			Vector3.UP, Color.WHITE, Color.BLACK, PackedByteArray(), dynamic)
		var keys: Array[int] = []
		var ranks: Array[int] = []
		var priorities: Array[int] = []
		var counts_ok := true
		var opaque_ranked := 0
		for s in surfaces:
			if not s["blend"]:
				if s.has("overlay_rank"):
					opaque_ranked += 1
				continue
			keys.append(int(s["texture_key"]))
			ranks.append(int(s.get("overlay_rank", -1)))
			var mat := MapmTerrainBuilder._surface_material(s, lookup, null)
			priorities.append(mat.render_priority)
			counts_ok = counts_ok and int(s.get("overlay_count", -1)) > 0
		var kind := "dynamic" if dynamic else "baked"
		_check(opaque_ranked == 0, "%s: no opaque surface carries an overlay rank" % kind)
		_check(keys.size() >= 3, "%s: the region has several overlays (%d)" % [kind, keys.size()])
		var sorted_keys := keys.duplicate()
		sorted_keys.sort()
		_check(keys == sorted_keys, "%s: overlays in ascending tile key (%s)" % [kind, str(keys)])
		var want: Array[int] = []
		for i in keys.size():
			want.append(i)
		_check(ranks == want and counts_ok, "%s: ranks 0..%d in that order, with the count (%s)" % [kind, keys.size() - 1, str(ranks)])
		var distinct := {}
		var ascending := true
		for i in priorities.size():
			distinct[priorities[i]] = true
			if i > 0 and priorities[i] <= priorities[i - 1]:
				ascending = false
			if priorities[i] != WorldFog.ground_overlay_priority(ranks[i]):
				ascending = false
		_check(distinct.size() == priorities.size() and ascending,
			"%s: every overlay material at its rank's own priority, none shared (%s)" % [kind, str(priorities)])

# --- the regression: Godot's alpha sort ----------------------------------------

## A port of Godot 4.7.2's SortArray (core/templates/sort_array.h: introsort,
## median of three, Hoare-style partitioner, heapsort fallback, the final
## insertion sort, INTROSORT_THRESHOLD 16) with RenderForwardClustered's alpha
## comparator: priority, then far before near; nothing else. An element is
## [priority, depth, id].
const THRESHOLD := 16

static func _less(a: Array, b: Array) -> bool:
	if a[0] == b[0]:
		return a[1] > b[1]
	return a[0] < b[0]

static func _median3(arr: Array, ai: int, bi: int, ci: int) -> int:
	var a: Array = arr[ai]
	var b: Array = arr[bi]
	var c: Array = arr[ci]
	if _less(a, b):
		if _less(b, c):
			return bi
		elif _less(a, c):
			return ci
		return ai
	elif _less(a, c):
		return ai
	elif _less(b, c):
		return ci
	return bi

static func _partition(first: int, last: int, pivot: int, arr: Array) -> int:
	var piv := pivot
	while true:
		while first != piv and _less(arr[first], arr[piv]):
			first += 1
		last -= 1
		while last != piv and _less(arr[piv], arr[last]):
			last -= 1
		if first >= last:
			return first
		if piv == first:
			piv = last
		elif piv == last:
			piv = first
		var t: Array = arr[first]
		arr[first] = arr[last]
		arr[last] = t
		first += 1
	return first

static func _push_heap(first: int, hole: int, top: int, value: Array, arr: Array) -> void:
	var parent := (hole - 1) / 2
	while hole > top and _less(arr[first + parent], value):
		arr[first + hole] = arr[first + parent]
		hole = parent
		parent = (hole - 1) / 2
	arr[first + hole] = value

static func _adjust_heap(first: int, hole: int, length: int, value: Array, arr: Array) -> void:
	var top := hole
	var second := 2 * hole + 2
	while second < length:
		if _less(arr[first + second], arr[first + second - 1]):
			second -= 1
		arr[first + hole] = arr[first + second]
		hole = second
		second = 2 * (second + 1)
	if second == length:
		arr[first + hole] = arr[first + second - 1]
		hole = second - 1
	_push_heap(first, hole, top, value, arr)

static func _heap_sort(first: int, last: int, arr: Array) -> void:
	var length := last - first
	if length >= 2:
		var parent := (length - 2) / 2
		while true:
			_adjust_heap(first, parent, length, arr[first + parent], arr)
			if parent == 0:
				break
			parent -= 1
	while last - first > 1:
		last -= 1
		var value: Array = arr[last]
		arr[last] = arr[first]
		_adjust_heap(first, 0, last - first, value, arr)

static func _introsort(first: int, last: int, arr: Array, depth: int) -> void:
	while last - first > THRESHOLD:
		if depth == 0:
			_heap_sort(first, last, arr)
			return
		depth -= 1
		var cut := _partition(first, last, _median3(arr, first, first + (last - first) / 2, last - 1), arr)
		_introsort(cut, last, arr, depth)
		last = cut

static func _insertion(first: int, last: int, arr: Array) -> void:
	for i in range(first + 1, last):
		var value: Array = arr[i]
		if _less(value, arr[first]):
			var j := i
			while j > first:
				arr[j] = arr[j - 1]
				j -= 1
			arr[first] = value
		else:
			var j := i
			while _less(value, arr[j - 1]):
				arr[j] = arr[j - 1]
				j -= 1
			arr[j] = value

static func godot_sort(arr: Array) -> void:
	if arr.size() < 2:
		return
	var n := arr.size()
	var lg := 0
	while n != 1:
		n >>= 1
		lg += 1
	_introsort(0, arr.size(), arr, lg * 2)
	_insertion(0, arr.size(), arr)

func _test_sort_regression() -> void:
	# Sanity: the port sorts by the comparator.
	var rng := RandomNumberGenerator.new()
	rng.seed = 786
	var probe: Array = []
	for i in 200:
		probe.append([rng.randi_range(-5, 3), rng.randf_range(0.0, 100.0), i])
	godot_sort(probe)
	var sorted_ok := true
	for i in range(1, probe.size()):
		if _less(probe[i], probe[i - 1]):
			sorted_ok = false
	_check(sorted_ok, "the SortArray port orders by priority, then far to near")
	# Four regions' overlays as the builder makes them: each its surfaces'
	# priorities, one depth per region (Godot's per-instance depth). Godot
	# hands an instance's surfaces last-first (surface_caches is prepended,
	# render_forward_clustered.cpp `_geometry_instance_add_surface`).
	var lookup := _lookup(6)
	var regions: Array = []
	for k in 4:
		var surfaces := MapmTerrainBuilder.build_full_region_surfaces_textured(_region(6, k), lookup,
			Vector3.UP, Color.WHITE, Color.BLACK, PackedByteArray(), true)
		var overlays: Array = []
		for s in surfaces:
			if s["blend"]:
				overlays.append([int(s["texture_key"]), MapmTerrainBuilder._surface_material(s, lookup, null).render_priority])
		regions.append(overlays)
	var fixed_orders := {}
	var tie_orders := {}
	var ascending_always := true
	for trial in 300:
		for tie in [false, true]:
			var arr: Array = []
			var depth_of := [300.0, 520.0, 760.0, 1010.0]
			for k in regions.size():
				var overlays: Array = regions[k]
				for i in range(overlays.size() - 1, -1, -1):
					var o: Array = overlays[i]
					arr.append([WorldFog.GROUND_OVERLAY_PRIORITY if tie else int(o[1]), depth_of[k], "r%d_%d" % [k, o[0]]])
			arr.append([-126, 1.0e9, "clouds"])
			arr.append([WorldFog.UNDER_PASS_PRIORITY, 500.0, "water"])
			arr.append([WorldFog.PASS_PRIORITY, 0.0, "fog"])
			# The rest of a session's list: bodies, labels, effects, here and
			# gone, anywhere in the cull order.
			var t_rng := RandomNumberGenerator.new()
			t_rng.seed = trial
			for j in t_rng.randi_range(0, 120):
				arr.insert(t_rng.randi_range(0, arr.size()), [[0, 0, 0, 1][t_rng.randi_range(0, 3)], t_rng.randf_range(5.0, 1500.0), "dyn%d" % j])
			godot_sort(arr)
			var order := PackedStringArray()
			var per_region := {}
			for e in arr:
				var id := String(e[2])
				if id.begins_with("r"):
					order.append(id)
					var rk := id.get_slice("_", 0)
					if not per_region.has(rk):
						per_region[rk] = []
					(per_region[rk] as Array).append(int(id.get_slice("_", 1)))
			if tie:
				tie_orders[",".join(order)] = true
			else:
				fixed_orders[",".join(order)] = true
				for rk in per_region:
					var ks: Array = per_region[rk]
					var s2 := ks.duplicate()
					s2.sort()
					if ks != s2:
						ascending_always = false
	_check(ascending_always and fixed_orders.size() == 1,
		"REGRESSION: with the ranked priorities every region's overlays sort in ascending tile key in all 300 lists (%d distinct order(s))" % fixed_orders.size())
	_check(tie_orders.size() > 1,
		"the cause, reproduced: at one priority the same overlays sort into %d different orders over the 300 lists" % tie_orders.size())
