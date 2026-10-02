extends RefCounted
class_name TitlePopProbe

## SRREVAMP_QA_TITLE_POPS=1 (round 680, QA only): measures pop-in during the
## title's fly -- anything that BECOMES drawn while it is inside the camera's
## view frustum -- and says where it came from:
##
##   - `cell`: a region cell committed by the loader (its terrain, water and
##     placed objects appear at once). One line per cell committed while the
##     camera flies; a pop if its terrain or any placement is in view.
##   - `anim`: an animated map object switched on by MapAnimation's range
##     rule (hidden beyond 2020 units, round 645). One line per frame that
##     switched any on in view.
##   - `popout`: a cell unloaded while its terrain was in view.
##   - Godot's own: every GeometryInstance3D in the world with a
##     visibility range (begin or end) is counted when the fly starts; this
##     client generates no mesh LODs (ArrayMesh without generate_lods), so a
##     non-zero count is the only way Godot itself could pop something.
##
## "In view" is the node's global AABB against Camera3D.get_frustum() --
## occlusion and fog are NOT considered, so it over-counts (a cell behind a
## hill counts). "Size" is the projected AABB's share of the screen, clipped
## to the viewport (corners behind the eye make it a whole-screen bound):
## an upper bound of what it covers. Lines are `QA POP ...`; the summary is
## `QA POPS ...` when the path ends. OURS.
##
## Its gap (round 680's review): only the world's `RealTerrain*` children are
## scanned, so the placements of a cell whose `.o` loaded without a `.m` --
## World3D._objects_commit then adds their container to the world directly
## -- are not seen.

var _cells := {} # terrain node name -> the cell's AABB (world)
var _anim_seen := {} # Obj instance id -> was drawn last tick
var _flying_since_ms := -1
var _checked_ranges := false
var cell_pops := 0
var placement_pops := 0
var anim_pops := 0
var popouts := 0
var cells_during_fly := 0
var max_frac := 0.0
var _summary_done := false

static func enabled() -> bool:
	return OS.get_environment("SRREVAMP_QA_TITLE_POPS") != ""

## One frame: `flying` while the camera moves (TitleIntro.State.FLYING).
func tick(world: Node3D, cam: Camera3D, path_t: float, flying: bool, ms: int) -> void:
	if world == null or cam == null:
		return
	var planes := cam.get_frustum()
	var vp := cam.get_viewport().get_visible_rect().size
	if flying and _flying_since_ms < 0:
		_flying_since_ms = ms
		_check_ranges(world)
	var present := {}
	for child in world.get_children():
		var n := String(child.name)
		if not n.begins_with("RealTerrain"):
			continue
		present[n] = true
		if _cells.has(n):
			continue
		var report := _cell_report(child as Node3D, cam, planes, vp)
		_cells[n] = report["aabb"]
		if not flying:
			print("QA POP prefly %s t=%.2f ms=%d (built under the cover: not a pop)" % [n.trim_prefix("RealTerrain_"), path_t, ms])
			continue
		cells_during_fly += 1
		var popped: bool = report["terrain_in_view"] or int(report["placements_in_view"]) > 0
		if popped:
			cell_pops += 1
			placement_pops += int(report["placements_in_view"])
			max_frac = maxf(max_frac, maxf(report["terrain_frac"], report["placement_frac_max"]))
		print("QA POP cell %s t=%.2f ms=%d %s terrain_in_view=%s terrain_frac=%.3f placements_in_view=%d/%d placement_frac_max=%.4f placement_frac_sum=%.3f" % [
			n.trim_prefix("RealTerrain_"), path_t, ms, "IN VIEW" if popped else "off-screen",
			str(report["terrain_in_view"]), report["terrain_frac"], report["placements_in_view"], report["placements"],
			report["placement_frac_max"], report["placement_frac_sum"]])
	for n in _cells.keys():
		if present.has(n):
			continue
		var box: AABB = _cells[n]
		_cells.erase(n)
		if flying and box.has_volume() and aabb_in_frustum(box, planes):
			popouts += 1
			print("QA POP popout %s t=%.2f ms=%d frac=%.3f" % [n.trim_prefix("RealTerrain_"), path_t, ms, screen_fraction(box, cam, vp)])
	_tick_anim(world, cam, planes, vp, path_t, flying, ms)

func _tick_anim(world: Node3D, cam: Camera3D, planes: Array, vp: Vector2, path_t: float, flying: bool, ms: int) -> void:
	var driver = world.get("_map_animations")
	if driver == null:
		return
	var n_on := 0
	var frac := 0.0
	for o in driver.objects():
		if not is_instance_valid(o.root):
			continue
		var id: int = o.get_instance_id()
		var drawn: bool = (o.root as Node3D).is_visible_in_tree()
		var was: bool = _anim_seen.get(id, false)
		_anim_seen[id] = drawn
		if drawn and not was and flying:
			var box := subtree_aabb(o.root as Node3D)
			if box.has_volume() and aabb_in_frustum(box, planes):
				n_on += 1
				frac = maxf(frac, screen_fraction(box, cam, vp))
	if n_on > 0:
		anim_pops += n_on
		max_frac = maxf(max_frac, frac)
		print("QA POP anim t=%.2f ms=%d switched_on_in_view=%d frac_max=%.4f" % [path_t, ms, n_on, frac])

## Godot's own pop sources, counted once: visibility ranges on anything drawn.
func _check_ranges(world: Node3D) -> void:
	if _checked_ranges:
		return
	_checked_ranges = true
	var ranged := 0
	var total := 0
	for gi in world.find_children("*", "GeometryInstance3D", true, false):
		total += 1
		var g := gi as GeometryInstance3D
		if g.visibility_range_begin > 0.0 or g.visibility_range_end > 0.0:
			ranged += 1
	print("QA POP ranges: %d of %d GeometryInstance3D carry a visibility range" % [ranged, total])

## The path ended (or the run is ending): the totals. With
## SRREVAMP_QA_TITLE_POPS=quit the run ends QUIT_AFTER_S later (OURS).
const QUIT_AFTER_S := 2.0

func summary(intro: String, path_t: float, tree: SceneTree = null) -> void:
	if _summary_done:
		return
	_summary_done = true
	if tree != null and OS.get_environment("SRREVAMP_QA_TITLE_POPS") == "quit":
		tree.create_timer(QUIT_AFTER_S).timeout.connect(func() -> void: tree.quit())
	print("QA POPS intro=%s t=%.2f cells_built_during_fly=%d cell_pops=%d placement_pops=%d anim_pops=%d popouts=%d total_in_view=%d max_frac=%.3f" % [
		intro, path_t, cells_during_fly, cell_pops, placement_pops, anim_pops, popouts,
		cell_pops + anim_pops + popouts, max_frac])

func _cell_report(cell: Node3D, cam: Camera3D, planes: Array, vp: Vector2) -> Dictionary:
	var out := {"terrain_in_view": false, "terrain_frac": 0.0, "placements": 0, "placements_in_view": 0,
		"placement_frac_max": 0.0, "placement_frac_sum": 0.0, "aabb": AABB()}
	var terrain := AABB()
	var placements: Array = []
	for child in cell.get_children():
		if String(child.name).begins_with("RealMapObjects"):
			placements.append_array(child.get_children())
			continue
		if child is Node3D:
			var b := subtree_aabb(child as Node3D)
			if b.has_volume():
				terrain = b if not terrain.has_volume() else terrain.merge(b)
	out["aabb"] = terrain
	if terrain.has_volume() and aabb_in_frustum(terrain, planes):
		out["terrain_in_view"] = true
		out["terrain_frac"] = screen_fraction(terrain, cam, vp)
	out["placements"] = placements.size()
	for p in placements:
		if not (p is Node3D):
			continue
		var b := subtree_aabb(p as Node3D)
		if b.has_volume() and aabb_in_frustum(b, planes):
			var f := screen_fraction(b, cam, vp)
			out["placements_in_view"] += 1
			out["placement_frac_max"] = maxf(out["placement_frac_max"], f)
			out["placement_frac_sum"] += f
	return out

## The world AABB of every drawn GeometryInstance3D under `root`.
static func subtree_aabb(root: Node3D) -> AABB:
	var box := AABB()
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is GeometryInstance3D and (n as GeometryInstance3D).is_visible_in_tree():
			var g := n as VisualInstance3D
			var b := g.global_transform * g.get_aabb()
			box = b if not box.has_volume() else box.merge(b)
		for c in n.get_children():
			stack.append(c)
	return box

## Outward-normal planes (Camera3D.get_frustum): out when every corner is
## over one plane.
static func aabb_in_frustum(box: AABB, planes: Array) -> bool:
	for plane in planes:
		var p := plane as Plane
		var v := Vector3(
			box.position.x if p.normal.x > 0.0 else box.end.x,
			box.position.y if p.normal.y > 0.0 else box.end.y,
			box.position.z if p.normal.z > 0.0 else box.end.z)
		if p.distance_to(v) > 0.0:
			return false
	return true

## The box's projected bounding rectangle as a share of the viewport,
## clipped to it; 1.0 when a corner lies behind the eye.
static func screen_fraction(box: AABB, cam: Camera3D, vp: Vector2) -> float:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for i in range(8):
		var c := box.get_endpoint(i)
		if cam.is_position_behind(c):
			return 1.0
		var s := cam.unproject_position(c)
		lo = Vector2(minf(lo.x, s.x), minf(lo.y, s.y))
		hi = Vector2(maxf(hi.x, s.x), maxf(hi.y, s.y))
	lo = lo.clamp(Vector2.ZERO, vp)
	hi = hi.clamp(Vector2.ZERO, vp)
	var area := maxf(hi.x - lo.x, 0.0) * maxf(hi.y - lo.y, 0.0)
	return area / maxf(vp.x * vp.y, 1.0)
