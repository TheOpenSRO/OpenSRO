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

## The equipment window's preview as CIFEquipment draws it (round 633 and its
## review). READ from sro_client.exe:
##
## - the viewport: the pane's rect grown by (+2, +15, -2, -37), 176x318 for
##   the 178x355 pane (vslot_013, 0x6ad8ca..0x6ad8d3), cleared in depth only
##   (0x6ad94b) -- the pane's tile shows behind the model;
## - the camera (0xbae0a0, then the draw): perspective, a VERTICAL field of
##   view of 30 degrees (0xd82ef0), near 1.0, far 500000.0 (0xe09630), looking
##   at (0, 9, 0) (0xd82ef8) from 40.0 (0xd82ef4) straight in front -- the eye
##   (0, 9, -40) in the client's left-handed space, through LookAtLH
##   (0xaa4bad). Nothing depends on the model's size;
## - the LIGHT IS THE ZONE'S (round 633's review). The draw fills a
##   D3DLIGHT9 at this + 0x510 (directional (0,0,1), diffuse 0.7, ambient
##   0.3) and hands it to the DEVICE's SetLight (0x6ad9e8), fixed-function
##   state no draw reads: the model is drawn by CObjRendererVS
##   (vslot_038 0xbf5830) through a vertex shader whose light constants
##   (0x1112e18 / 0x1112e28) are written only by vslot_025 (0xbeecc0), which
##   only the world draw calls. So the preview is lit exactly as round 635's
##   portrait is (PlayerPortrait, whose materials this reuses): the world
##   light's diffuse (environment channel 2 clamped x 0.6) and ambient
##   (channel 3), to-light (0.707, 0.707, 0) in the file's coordinates, the
##   object colour 0.6 on the ambient, the material colour on the diffuse,
##   MODULATE2X. The round-633 key light and its 0.89 calibration are gone.
##
## **Handedness and the turn.** The client is left-handed and the assembled
## body is in the file's own coordinates, so the model hangs under a
## (1, 1, -1) node and the camera stands at the mirrored eye (0, 9, 40): drawn
## without it the picture was retail's mirror image, the one-handed weapon in
## the other hand. The yaw setter (CCompChar::FUN_00c26e70) builds the
## row-vector [[c,0,s],[0,1,0],[-s,0,c]], the model's forward (sin, 0, -cos):
## at yaw 0 it faces the camera, and a growing yaw (the right arrow,
## 0x6ab960) turns the face toward +x, the screen's right in the client's
## view. Under the mirror node that matrix is Godot's rotation by -yaw.
const EQUIP_VIEW_SIZE := Vector2i(176, 318)
const EQUIP_FOV := 30.0
const EQUIP_NEAR := 1.0
const EQUIP_FAR := 500000.0
## The eye and target in the file's (left-handed) coordinates.
const EQUIP_EYE_D3D := Vector3(0, 9, -40)
const EQUIP_TARGET_D3D := Vector3(0, 9, 0)

## The zone-lit material machinery (PlayerPortrait's), kept off the tree: this
## doll only borrows its materials and its light, never its viewport.
var _lighter: PlayerPortrait = null
var _mirror: Node3D = null

func use_equipment_view() -> void:
	_equipment_view = true
	size = EQUIP_VIEW_SIZE
	_camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	_camera.keep_aspect = Camera3D.KEEP_HEIGHT
	_camera.fov = EQUIP_FOV
	_camera.near = EQUIP_NEAR
	_camera.far = EQUIP_FAR
	var eye := PlayerPortrait.to_godot(EQUIP_EYE_D3D)
	var target := PlayerPortrait.to_godot(EQUIP_TARGET_D3D)
	_camera.transform = Transform3D(Basis.looking_at(target - eye, Vector3.UP), eye)
	# Nothing here is lit by Godot: the materials light themselves.
	_key.visible = false
	_environment.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	_environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	if _mirror == null:
		_mirror = Node3D.new()
		_mirror.name = "D3DSpace"
		_mirror.scale = Vector3(1.0, 1.0, -1.0)
		_root.add_child(_mirror)
		_root.remove_child(_pivot)
		_mirror.add_child(_pivot)
	if _lighter == null:
		_lighter = PlayerPortrait.new()
	# The preview renders only while it is on screen (set_active).
	render_target_update_mode = SubViewport.UPDATE_DISABLED

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _lighter != null and is_instance_valid(_lighter):
		_lighter.free()

## The zone's light (World3D, as for the portrait): environment channels 2
## (diffuse) and 3 (ambient).
func set_zone_light(diffuse_channel: Color, ambient_channel: Color) -> void:
	if _lighter != null:
		_lighter.set_zone_light(diffuse_channel, ambient_channel)

func zone_light() -> Dictionary:
	return _lighter.zone_light() if _lighter != null else {}

## Renders while the pane shows and not otherwise: CIFEquipment's model is
## drawn by its window's draw, which runs only for a shown window, and its
## pose advances only then (vslot_012 0x6ab6b0 tests 0xb8f530).
func set_active(active: bool) -> void:
	render_target_update_mode = SubViewport.UPDATE_ALWAYS if active else SubViewport.UPDATE_DISABLED

func is_active() -> bool:
	return render_target_update_mode == SubViewport.UPDATE_ALWAYS

## Where a bone of the doll's model lands in the doll's picture (x, y in
## pixels), or (-1, -1): the measurement for which hand is which and which
## way the model turns (round 633's review).
func bone_on_screen(bone: String) -> Vector2:
	var skel := _character as Skeleton3D
	if skel == null or not skel.is_inside_tree():
		return Vector2(-1, -1)
	var i := skel.find_bone(bone)
	if i < 0:
		return Vector2(-1, -1)
	return _camera.unproject_position(skel.global_transform * skel.get_bone_global_pose(i).origin)

## How far, in pixels, a point 3 units in front of the head lands right of
## the head in the picture: positive when the face is turned toward the
## screen's right. "In front" is the model's forward at yaw 0, -z in the
## file's coordinates (it faces the camera), turned by the pivot.
func facing_screen_dx() -> float:
	var skel := _character as Skeleton3D
	if skel == null or not skel.is_inside_tree() or _mirror == null:
		return 0.0
	var i := skel.find_bone("Bip01 Head")
	if i < 0:
		return 0.0
	var head := skel.global_transform * skel.get_bone_global_pose(i).origin
	var fwd := (_mirror.global_transform.basis * _pivot.transform.basis * Vector3(0, 0, -1)).normalized()
	return _camera.unproject_position(head + fwd * 3.0).x - _camera.unproject_position(head).x

## Turns the model to `yaw` radians -- CIFEquipment's +0x578, which the rotate
## arrows move and the circle zeroes (HudPanels, "Turning the paper doll").
## Under the mirror node the setter's matrix is a Godot rotation by -yaw (see
## above); PlayerPortrait.model_rotation_y is the same mapping.
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
		# feet on y 0, and is not framed (use_equipment_view). Its materials
		# are the zone-lit ones (PlayerPortrait's), rebuilt for each dress.
		skeleton.transform = Transform3D.IDENTITY
		_lighter.set("_materials", [])
		_lighter.unmapped_materials = 0
		_lighter.call("_apply_materials", skeleton)
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
