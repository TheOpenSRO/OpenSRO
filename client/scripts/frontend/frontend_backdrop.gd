extends Node
class_name FrontEndBackdrop

## A 3D scene behind a front-end screen (round 678): the world's own region
## loaders -- terrain, objects, water, sky and environment -- streamed around
## a point the screen's camera rig moves, with no player, HUD or server. The
## login screen's intro flies it now; character select and create can stand
## one up with their own region and camera later (FRONTEND_CHECKLIST.md).
##
## It is World3D in its `title_mode` (World3D.title_begin and friends): one
## loader, not a second copy of it. What a screen hands it:
##   - the frame region, as Vector2i(hi, lo), positions are relative to;
##   - the window radius in regions (OURS: 1 at the title);
##   - the day phase the environment is read at (CPSTitle's random hour, READ);
##   - each frame, a camera pose (IntroCameraPath.Pose), which this turns
##     into the camera's transform (IntroCameraPath.camera_transform, READ)
##     and whose target the region window follows.

const WORLD_SCENE := "res://scenes/World3D.tscn"
## World3D's script, loaded when first needed (a preload would compile it --
## and the autoloads it names -- into every script that only names this one).
static var _world_script: GDScript = null

## Emitted once, when the region under the camera's target has been built
## (or the whole first window has, whichever is first).
signal first_view_ready
## Emitted once, when every cell queued so far is built -- for a planned
## backdrop (begin's `plan`, round 680) the whole scene.
signal scene_ready

var world: Node3D = null
var _frame_region := Vector2i(-1, -1)
var _ready_sent := false
var _scene_sent := false
var _last_focus := Vector3.ZERO
var _started_ms := 0

## Starts loading the world's scene (and its 20,000-line script) on a
## worker thread, so the screen asking for a backdrop stays responsive while
## it compiles -- measured at ~1.2 s on the main thread when loaded on
## demand (round 678). Safe to call more than once. The cost (round 678's
## review, MEASURED on the Linux box): what the compile frees on that thread
## stays in its glibc arena, ~150-190 MB of resident memory once in the
## world that a main-thread compile does not leave; MALLOC_ARENA_MAX=2
## removes it entirely. Loading here on the main thread would freeze the
## screen 1.2 s instead -- the trade this file makes, OURS.
static func preload_world() -> void:
	if ResourceLoader.load_threaded_get_status(WORLD_SCENE) == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
		# One loader thread, no sub-threads (round 678's review: each thread
		# that allocates keeps its own glibc arena, and what the compile frees
		# there stays resident -- MEASURED, the WORLD_ISSUES entry's Review).
		ResourceLoader.load_threaded_request(WORLD_SCENE, "PackedScene", false)

## Whether the world's scene has finished loading (preload_world); true too
## when it failed, so the caller moves on and begin() reports it.
static func world_loaded() -> bool:
	var status := ResourceLoader.load_threaded_get_status(WORLD_SCENE)
	return status != ResourceLoader.THREAD_LOAD_IN_PROGRESS

## Builds the world and starts loading. False (and nothing left behind) when
## the archives cannot back a backdrop -- the caller keeps its 2D still.
## `plan` (round 680, TitleCellPlan): every cell of the scene, built before
## anything moves and kept; empty for round 678's window that follows the
## focus.
func begin(frame_region: Vector2i, radius: int, day_phase: float, plan: Array = []) -> bool:
	_started_ms = Time.get_ticks_msec()
	var packed: PackedScene = null
	if ResourceLoader.load_threaded_get_status(WORLD_SCENE) != ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
		packed = ResourceLoader.load_threaded_get(WORLD_SCENE) as PackedScene
	else:
		packed = load(WORLD_SCENE) as PackedScene
	if packed == null:
		print("FrontEndBackdrop: %s did not load" % WORLD_SCENE)
		return false
	world = packed.instantiate() as Node3D
	world.set("title_mode", true)
	world.name = "FrontEndWorld"
	add_child(world)
	if not world.call("title_begin", frame_region, radius, day_phase, plan):
		world.queue_free()
		world = null
		return false
	_frame_region = frame_region
	(world.get("camera_3d") as Camera3D).fov = IntroCameraPath.FOV_Y_DEGREES
	return true

func camera() -> Camera3D:
	return world.get("camera_3d") as Camera3D if world != null else null

## World space for a point given in the frame region's local coordinates.
func to_world(local: Vector3) -> Vector3:
	if _world_script == null:
		_world_script = load("res://scripts/World3D.gd") as GDScript
	return _world_script.call("title_world_from_local", local)

## Places the camera for a pose, and moves the region window's focus to the
## pose's target.
func show_pose(pose: IntroCameraPath.Pose) -> void:
	if world == null:
		return
	var cam := camera()
	cam.global_transform = IntroCameraPath.camera_transform(pose, Callable(self, "to_world"))
	_last_focus = to_world(pose.target)
	world.call("title_focus", _last_focus)

func cells_loaded() -> int:
	return world.call("title_cells_loaded") if world != null else 0

func cells_pending() -> int:
	return world.call("title_cells_pending") if world != null else 0

func _process(_delta: float) -> void:
	if world == null or (_ready_sent and _scene_sent):
		return
	if not _ready_sent and cells_loaded() > 0 and (_focus_cell_loaded() or cells_pending() == 0):
		_ready_sent = true
		print("FrontEndBackdrop: first view ready in %d ms (%d cell(s) built, %d pending)" % [
			Time.get_ticks_msec() - _started_ms, cells_loaded(), cells_pending()])
		first_view_ready.emit()
	if _ready_sent and not _scene_sent and cells_pending() == 0:
		_scene_sent = true
		print("FrontEndBackdrop: scene ready in %d ms (%d cell(s) built)" % [
			Time.get_ticks_msec() - _started_ms, cells_loaded()])
		scene_ready.emit()

func _focus_cell_loaded() -> bool:
	var grid = world.get("_grid")
	var origin: Vector3 = world.get("_grid_origin_world")
	var cell := RegionGridState.cell_at(_last_focus - origin)
	return grid != null and grid.loaded_cells.has("%d_%d" % [cell.x, cell.y])
