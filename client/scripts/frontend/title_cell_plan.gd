extends RefCounted
class_name TitleCellPlan

## The title's whole scene, worked out before the fly (round 680): every
## region cell the intro's camera can see at any moment of its path, so the
## backdrop builds them all under the loading cover and nothing streams in
## -- or pops into view -- while the camera flies. The user (2026-10-01):
## "As the camera moves some buildings pop-in. Let's try to preload the
## scene entirely so that doesn't happen."
##
## What retail does (READ, docs/protocol/intro_script.md "Preloading"): at
## startup, inside Client_LoadAllRefData and so before the title screen
## exists, `FUN_00840670` reads the intro and hands every region of
## `FUN_0056c870`'s set to `CGWorld::FUN_00aa2190(region, 1)`, which loads
## that region through the region manager (`CRegionManagerBody::vslot_005`,
## flag 1) and, when the region's 0x8000 (dungeon) bit is clear, its eight
## neighbours, diagonals included, with flag 0. Retail's set is built
## from the keyframes' own region words, which for roc misses the regions
## the camera's target crosses (100/70 .. 96/70, MEASURED in round 678) --
## its 3x3 neighbourhoods are what cover them.
##
## This client (OURS): the path itself, sampled every SAMPLE_STEP_S, and at
## each sample the union of
##   - the region window around the camera's target (`radius` regions each
##     way: the cells round 678's streaming would have built there) --
##     window_cells, what the title builds (TitleIntro.PLAN_DRAW_DISTANCE);
##   - with cells(), also every cell whose box -- the region's 1920 x 1920
##     footprint between CELL_Y_MIN and CELL_Y_MAX -- meets the camera's
##     view frustum (60 degrees vertical, READ; the widest aspect planned
##     for, MIN_ASPECT) within a draw distance: more of the horizon, at
##     2.3 to 3.9 times the cells at 2500 units (MEASURED, round 680).
## Cells are (dx, dy) relative to the frame region, as the region grid keys
## them: dx along the region's high byte (SRO z), dy along its low byte
## (SRO x) -- RegionGridState.cell_at of the point's world position.
## The plan is conservative: a cell behind a hill or under fog counts.

const REGION_SPAN := 1920.0
## OURS: how densely the path is sampled. The camera's fastest motion in
## the archive's intros (MEASURED every 0.01 s, title_plan_census.gd) is 341
## units a second (roc) and 0.53 rad a second of yaw or pitch
## (constantinople), so 0.05 s is at most 17 units and 0.03 rad between
## samples -- far below the 1920-unit cell. The suite checks the plan at
## five times this density.
const SAMPLE_STEP_S := 0.05
## OURS: the height band a cell is tested over. The archive's intros keep the
## camera's target between y -434 and 2008 (MEASURED, round 678's census);
## that terrain and scenery sit inside this band is INFERRED (it only widens
## which cells count -- a taller band plans more, never fewer).
const CELL_Y_MIN := -1000.0
const CELL_Y_MAX := 4000.0
## OURS: the widest screen planned for (21:9 is ~2.37) -- a narrower
## window sees a subset, so one plan covers every window shape.
const MIN_ASPECT := 2.4
## OURS: the near plane of the planning frustum (the camera's own is 0.05;
## the value only trims what lies behind the eye).
const NEAR := 1.0

## OURS (round 680's review): the most cells a title builds before its fly.
## The archive's largest plan is 28 (constantinople, MEASURED) and retail's
## largest preload set 27; a custom intro may name any path inside
## IntroScript's bounds -- a straight line planned 198 cells and a sweep
## 5,412 (the review's MEASURED) at ~15-20 MB a cell. A plan past the cap is
## abandoned as soon as it passes it, and the title streams round 678's
## window instead, unloading as it goes (TitleIntro).
const PLAN_MAX_CELLS := 36

## The plan: every cell any sample needs, as Vector2i(dx, dy), ordered by
## the first time a sample needs it, then by distance from the frame region
## -- so the cells the fly opens on are built first. Stops early -- after
## the sample that takes it past `max_cells` (>= 0), so the result holds more
## than max_cells, by one sample's cells at most -- or before a sample, as
## soon as `stop` (if valid) returns true.
static func cells(path: IntroCameraPath, radius: int, draw_distance: float, aspect: float = MIN_ASPECT, step: float = SAMPLE_STEP_S, max_cells: int = -1, stop: Callable = Callable()) -> Array[Vector2i]:
	var first_needed := {}
	for_each_sample(path, step, func(t: float, pose: IntroCameraPath.Pose) -> bool:
		add_sample_cells(first_needed, t, pose, radius, draw_distance, maxf(aspect, MIN_ASPECT))
		return not _over(first_needed, max_cells), stop)
	return _ordered(first_needed)

## The plan without the frustum: the region window (`radius` regions each
## way) around the camera's target at every sample -- every cell round 678's
## streaming window would have built at some moment of the fly -- in the
## same order as cells(), with the same early stops.
static func window_cells(path: IntroCameraPath, radius: int, step: float = SAMPLE_STEP_S, max_cells: int = -1, stop: Callable = Callable()) -> Array[Vector2i]:
	var first_needed := {}
	for_each_sample(path, step, func(t: float, pose: IntroCameraPath.Pose) -> bool:
		var centre := cell_of(pose.target)
		for dx in range(-radius, radius + 1):
			for dy in range(-radius, radius + 1):
				var c := centre + Vector2i(dx, dy)
				if not first_needed.has(c):
					first_needed[c] = t
		return not _over(first_needed, max_cells), stop)
	return _ordered(first_needed)

static func _over(first_needed: Dictionary, max_cells: int) -> bool:
	return max_cells >= 0 and first_needed.size() > max_cells

static func _ordered(first_needed: Dictionary) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for c in first_needed:
		out.append(c)
	out.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		if first_needed[a] != first_needed[b]:
			return first_needed[a] < first_needed[b]
		return absi(a.x) + absi(a.y) < absi(b.x) + absi(b.y))
	return out

## Calls `visit(t, pose)` at t = 0, step, 2 step, ... and at the path's end,
## walking the path forward (IntroCameraPath.sample_forward). Stops when
## `visit` returns false, or before a sample when `stop` (if valid) returns
## true.
static func for_each_sample(path: IntroCameraPath, step: float, visit: Callable, stop: Callable = Callable()) -> void:
	var n := maxi(int(ceilf(path.length / maxf(step, 0.001))), 0)
	for i in range(n + 1):
		if stop.is_valid() and stop.call():
			return
		var t := minf(i * step, path.length)
		var go = visit.call(t, path.sample_forward(t))
		if go is bool and not go:
			return

## The cells one pose needs: the window around its target and every cell its
## frustum meets within `draw_distance`.
static func sample_cells(pose: IntroCameraPath.Pose, radius: int, draw_distance: float, aspect: float) -> Array[Vector2i]:
	var seen := {}
	add_sample_cells(seen, 0.0, pose, radius, draw_distance, aspect)
	var out: Array[Vector2i] = []
	for c in seen:
		out.append(c)
	return out

## sample_cells into `into` (cell -> the time first needed): a cell already
## there is not tested again, so a whole path costs little more than its
## first view.
static func add_sample_cells(into: Dictionary, t: float, pose: IntroCameraPath.Pose, radius: int, draw_distance: float, aspect: float) -> void:
	var centre := cell_of(pose.target)
	for dx in range(-radius, radius + 1):
		for dy in range(-radius, radius + 1):
			var w := centre + Vector2i(dx, dy)
			if not into.has(w):
				into[w] = t
	var xf := camera_transform(pose)
	var planes := frustum_planes(xf, aspect, NEAR, draw_distance)
	# Every cell the far plane can reach from the eye, tested against the planes.
	var eye_cell := cell_of(_sro(xf.origin))
	var reach := int(ceilf(draw_distance / REGION_SPAN)) + 1
	for dx in range(eye_cell.x - reach, eye_cell.x + reach + 1):
		for dy in range(eye_cell.y - reach, eye_cell.y + reach + 1):
			var c := Vector2i(dx, dy)
			if not into.has(c) and box_in_frustum(cell_box(c), planes):
				into[c] = t

## The cell holding a point given in the frame region's local SRO
## coordinates (x along the low byte, z along the high byte).
static func cell_of(local: Vector3) -> Vector2i:
	return Vector2i(int(floorf(local.z / REGION_SPAN)), int(floorf(local.x / REGION_SPAN)))

## A cell's box in the planning space: the frame region's local coordinates
## with z mirrored, as the world places them (World3D.title_world_from_local
## less the frame's corner).
static func cell_box(c: Vector2i) -> AABB:
	return AABB(Vector3(c.y * REGION_SPAN, CELL_Y_MIN, -(c.x + 1) * REGION_SPAN),
		Vector3(REGION_SPAN, CELL_Y_MAX - CELL_Y_MIN, REGION_SPAN))

## The camera's transform in the planning space (IntroCameraPath's own,
## READ, with the world's z mirror and no frame offset).
static func camera_transform(pose: IntroCameraPath.Pose) -> Transform3D:
	return IntroCameraPath.camera_transform(pose, func(v: Vector3) -> Vector3: return Vector3(v.x, v.y, -v.z))

static func _sro(v: Vector3) -> Vector3:
	return Vector3(v.x, v.y, -v.z)

## The view frustum of a camera at `xf` (looking down its -z, 60 degrees
## vertical, IntroCameraPath.FOV_Y_DEGREES) as six planes with outward
## normals, in the space `xf` is in -- what Camera3D.get_frustum() returns,
## built here because Godot 4.2 does not expose Projection's planes.
static func frustum_planes(xf: Transform3D, aspect: float, near: float, far: float) -> Array[Plane]:
	var ty := tan(deg_to_rad(IntroCameraPath.FOV_Y_DEGREES) * 0.5)
	var tx := ty * aspect
	var local: Array[Plane] = [
		Plane(Vector3(0, 0, 1), -near),
		Plane(Vector3(0, 0, -1), far),
		Plane(Vector3(1, 0, tx).normalized(), 0.0),
		Plane(Vector3(-1, 0, tx).normalized(), 0.0),
		Plane(Vector3(0, 1, ty).normalized(), 0.0),
		Plane(Vector3(0, -1, ty).normalized(), 0.0),
	]
	var out: Array[Plane] = []
	for p in local:
		out.append(xf * p)
	return out

## Whether a box meets a convex frustum given as outward-facing planes
## (frustum_planes, Camera3D.get_frustum): out only when all eight corners are
## over one plane. Conservative -- a box near an edge may pass.
static func box_in_frustum(box: AABB, planes: Array) -> bool:
	for plane in planes:
		var p := plane as Plane
		# The corner furthest against the normal: if even it is over the
		# plane, the whole box is.
		var v := Vector3(
			box.position.x if p.normal.x > 0.0 else box.end.x,
			box.position.y if p.normal.y > 0.0 else box.end.y,
			box.position.z if p.normal.z > 0.0 else box.end.z)
		if p.distance_to(v) > 0.0:
			return false
	return true
