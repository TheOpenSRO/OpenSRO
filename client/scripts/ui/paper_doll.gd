extends SubViewport
class_name PaperDoll

## The dressed character rendered into the equipment window, the way the
## original draws it there: a live 3D view of the same assembled body the
## world uses, in its own little scene so nothing about the world's camera
## or lighting reaches it.
##
## World3D builds the character (it owns the archives and the assembler) and
## hands the Skeleton3D here; this frames a camera on it and lights it. The
## texture is `get_texture()`, which a TextureRect in the equipment window
## shows.

## The scene the doll lives in -- its own world, so the game world's camera
## and environment do not leak in and vice versa.
var _root: Node3D
var _camera: Camera3D
var _character: Node3D

func _init() -> void:
	size = Vector2i(112, 300)
	transparent_bg = true
	own_world_3d = true
	render_target_update_mode = SubViewport.UPDATE_ALWAYS
	disable_3d = false

	_root = Node3D.new()
	_root.name = "DollScene"
	add_child(_root)

	# A soft key light plus fill, so the model reads without the harsh
	# single-side shadow a lone light gives. Colours and energies are a
	# disclosed choice -- nothing recovered says how the original lights its
	# doll -- picked to match the mid-grey, mostly-ambient look of the game.
	var env := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0, 0, 0, 0)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.7, 0.7, 0.72)
	environment.ambient_light_energy = 1.0
	env.environment = environment
	_root.add_child(env)

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-25, 25, 0)
	key.light_energy = 0.7
	_root.add_child(key)

	_camera = Camera3D.new()
	_camera.name = "DollCamera"
	_camera.current = true
	_root.add_child(_camera)

## Shows `skeleton` (an assembled character from World3D) in the doll,
## replacing whatever was there, and frames the camera on it. Takes
## ownership of the node.
func set_character(skeleton: Node3D) -> void:
	if _character != null and is_instance_valid(_character):
		_character.queue_free()
	_character = skeleton
	if skeleton == null:
		return
	_root.add_child(skeleton)
	_frame(skeleton)

## Frames the camera to the character's own bone bounds -- head to foot,
## the front toward the camera -- so a tall model and a short one both fill
## the view. The front is +Z of the assembled body (the world's default
## camera sits at yaw 180, behind it), so the doll camera looks from -Z.
func _frame(skeleton: Node3D) -> void:
	var lo := Vector3.INF
	var hi := -Vector3.INF
	if skeleton is Skeleton3D:
		var skel := skeleton as Skeleton3D
		for i in range(skel.get_bone_count()):
			var p: Vector3 = skel.get_bone_global_pose(i).origin
			lo = Vector3(minf(lo.x, p.x), minf(lo.y, p.y), minf(lo.z, p.z))
			hi = Vector3(maxf(hi.x, p.x), maxf(hi.y, p.y), maxf(hi.z, p.z))
	if lo == Vector3.INF:
		lo = Vector3(-8, 0, -8)
		hi = Vector3(8, 16, 8)
	var centre := (lo + hi) * 0.5
	var height := maxf(hi.y - lo.y, 1.0)
	# Frame by height (a character is far taller than it is wide), with
	# enough margin that the mesh -- whose head and feet reach past the
	# outermost bones -- is not clipped, and drop the look-at target a
	# little so the extra room falls at the head rather than the feet.
	# Orthographic so the doll does not fish-eye at close range.
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.size = height * 1.5
	_camera.position = Vector3(centre.x, centre.y, centre.z - height)
	_camera.look_at(Vector3(centre.x, centre.y - height * 0.08, centre.z), Vector3.UP)
