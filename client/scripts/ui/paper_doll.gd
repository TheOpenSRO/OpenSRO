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
## The node the character hangs from and turns with (set_yaw).
var _pivot: Node3D
var _key: DirectionalLight3D
var _environment: Environment
## Set by use_equipment_view: the client's fixed camera instead of a frame
## fitted to the model's bones.
var _equipment_view := false
var _yaw := 0.0

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
	_key = key
	_environment = environment

	_camera = Camera3D.new()
	_camera.name = "DollCamera"
	_camera.current = true
	_root.add_child(_camera)

	_pivot = Node3D.new()
	_pivot.name = "DollPivot"
	_root.add_child(_pivot)

## The equipment window's preview as CIFEquipment draws it (round 633). READ
## from sro_client.exe:
##
## - the viewport: the pane's rect grown by (+2, +15, -2, -37), 176x318 for
##   the 178x355 pane (vslot_013, 0x6ad8ca..0x6ad8d3);
## - the camera (built on the stack by 0xbae0a0, then set by the draw):
##   perspective, a VERTICAL field of view of 30 degrees (0xd82ef0), near 1.0,
##   far 500000.0 (0xe09630), looking at (0, 9, 0) (9.0 at 0xd82ef8) from 40.0
##   (0xd82ef4) straight in front with no pitch or roll -- the eye (0, 9, -40)
##   through LookAtLH (0xaa4bad), the aspect the viewport's own. Nothing depends
##   on the model's size: a tall model and a short one stand in the same frame;
##   the model's world transform is the identity (0xbaecb0);
## - the light, filled in Create at this + 0x510 (0x6aca1c..0x6acae3) and set
##   for each draw (SetLight(0), 0x6ad9e8): directional, diffuse 0.7
##   (0xd82f04), ambient 0.3 (0xd82f00), specular 1, pointing (0, 0, 1) -- the
##   way the camera looks, so a face turned to the camera is lit full on.
##
## The client lights in gamma space: a face turned to the camera gets its
## texture times 0.3 + 0.7 = 1.0, one turned away 0.3 of it. Godot lights in
## linear space, so the two ends are matched rather than the numbers copied
## (EQUIP_AMBIENT, EQUIP_KEY_ENERGY). D3DRS_AMBIENT and SPECULARENABLE are not
## set by this draw and are inherited from whatever drew before (OPEN), so no
## global ambient or specular is added here.
const EQUIP_VIEW_SIZE := Vector2i(176, 318)
const EQUIP_FOV := 30.0
const EQUIP_NEAR := 1.0
const EQUIP_FAR := 500000.0
const EQUIP_EYE := Vector3(0, 9, -40)
const EQUIP_TARGET := Vector3(0, 9, 0)
## The light's ambient 0.3, applied in gamma space: 0.3 of a texture's sRGB
## value is (0.3 ^ 2.2) of its linear one, and Godot converts an ambient
## Color from sRGB to linear itself -- Color(0.3) is that.
const EQUIP_AMBIENT := Color(0.3, 0.3, 0.3)
## The key light's energy, MEASURED on the render box (round 633,
## tools/measure_doll_light.gd, GL Compatibility on the RX 5700 XT): the
## energy at which a 0.5-grey StandardMaterial3D quad turned full on to the
## camera renders at 128 of 255 with EQUIP_AMBIENT added -- the client's
## 0.5 * (0.3 + 0.7). The sweep: 0.85 -> 126, 0.88 -> 127, 0.89 -> 128,
## 0.90 -> 129, 1.0 -> 134. With the light off the quad reads 34, against
## the client's 0.5 * 0.3 = 38 (Godot's sRGB curve is not the 2.2 power).
const EQUIP_KEY_ENERGY := 0.89

func use_equipment_view() -> void:
	_equipment_view = true
	size = EQUIP_VIEW_SIZE
	_camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	_camera.keep_aspect = Camera3D.KEEP_HEIGHT
	_camera.fov = EQUIP_FOV
	_camera.near = EQUIP_NEAR
	_camera.far = EQUIP_FAR
	# Set as a transform, not with look_at, which needs the node in a tree.
	_camera.transform = Transform3D(Basis.looking_at(EQUIP_TARGET - EQUIP_EYE, Vector3.UP), EQUIP_EYE)
	# The light travels the way the camera looks. A DirectionalLight3D shines
	# down its own -Z, and the camera looks down world +Z here, so the light is
	# the camera's own basis.
	_key.transform = Transform3D(_camera.transform.basis, Vector3.ZERO)
	_key.light_color = Color.WHITE
	_key.light_energy = EQUIP_KEY_ENERGY
	_key.shadow_enabled = false
	_environment.ambient_light_color = EQUIP_AMBIENT
	_environment.ambient_light_energy = 1.0
	_environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR

## Turns the model to `yaw` radians -- CIFEquipment's +0x578, which the rotate
## arrows move and the circle zeroes (HudPanels, "Turning the paper doll").
##
## The client hands the yaw to the model's vslot 0x30, INFERRED (not read) to
## be its plain rotation about Y, D3DXMatrixRotationY(yaw) in the client's
## left-handed space: a positive yaw turns a model facing the camera at -Z so
## that its face goes toward -X, the screen's left for a camera looking down
## +Z. Here the camera looks down +Z too, but Godot is right-handed, so -X of
## that view is the screen's right, and the same turn is a rotation by -yaw.
## A render measures it (round 633): the right arrow turns the face to the
## screen's left.
func set_yaw(yaw: float) -> void:
	_yaw = yaw
	_pivot.rotation.y = -yaw

## Shows `skeleton` (an assembled character from World3D) in the doll,
## replacing whatever was there, and frames the camera on it. Takes
## ownership of the node.
func set_character(skeleton: Node3D) -> void:
	if _character != null and is_instance_valid(_character):
		_character.queue_free()
	_character = skeleton
	if skeleton == null:
		return
	_pivot.add_child(skeleton)
	if _equipment_view:
		# The client's camera is fixed: the model stands at the origin, its
		# feet on y 0, and is not framed (use_equipment_view).
		return
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
			if not Skeleton3DBuilder.is_skeleton_bone(skel, i):
				continue
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
