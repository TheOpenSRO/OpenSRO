extends SubViewport
class_name CharCreatePreview

## The customize screen's model (round 685): retail's CIFCharacterWnd, the
## full-screen window 6 that draws the chosen character over the backdrop
## (layout rect 0,0,1600,1200; created after the bands, the title and China's
## calligraphy and before the panels, so it draws over the first and under
## the second -- the client's reverse-file-order creation, round 583).
##
## What it shows is CharacterAppearance's body for the model's choices; where
## it stands, how the camera looks at it and how it turns are CharCreateView's
## (READ there). Here:
## - **Handedness** (as PaperDoll and PlayerPortrait, READ in their headers):
##   the client is left-handed, so the model hangs under a z -> -z node and the
##   camera stands at the mirrored eye. At yaw 0 the model faces the camera
##   (READ, the yaw setter's forward (sin, 0, -cos)), and its pivot turns by
##   -yaw under the mirror.
## - **The light is the zone's** (INFERRED, the chain round 633's review READ
##   for the equipment window's model: every character draw goes through the
##   vertex shader whose light constants only the world draw writes -- and the
##   create screens draw a world, 98/168 or 105/79). So the body wears
##   PlayerPortrait's zone-lit materials, fed the backdrop's environment light.
## - **The pose** (READ, CCustomInfoManager 0x80b440): a model or weapon change
##   plays animation 0 -- ANI_STAND1, the body's stand clip in the weapon's
##   group -- from its start at speed 1.0 (vt+0xc(0, 0, 0, 0, 1.0, 1.0)); an
##   armour change only re-dresses (vt+0x20), the clip runs on.
## - Near and far are OURS (the window's camera copies the constructor's, not
##   traced).

const NEAR := 1.0
const FAR := 2000.0

var appearance: CharacterAppearance = null
var body: CharacterAppearance.Body = null
var _root: Node3D
var _mirror: Node3D
var _pivot: Node3D
var _camera: Camera3D
var _environment: Environment
var _lighter: PlayerPortrait = null
var _anim: BanReader.ParsedAnimation = null
var _anim_time := 0.0
var _zone_light: Array = []
## The last rebuild's cost, microseconds: the body build, and the materials.
var last_build_usec := 0
var last_material_usec := 0
var rebuilds := 0

func _init() -> void:
	transparent_bg = true
	own_world_3d = true
	render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_root = Node3D.new()
	_root.name = "CreateScene"
	add_child(_root)
	var we := WorldEnvironment.new()
	_environment = Environment.new()
	_environment.background_mode = Environment.BG_COLOR
	_environment.background_color = Color(0, 0, 0, 0)
	# Nothing here is lit by Godot: the materials light themselves.
	_environment.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	_environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	we.environment = _environment
	_root.add_child(we)
	_camera = Camera3D.new()
	_camera.name = "CreateCamera"
	_camera.current = true
	_camera.keep_aspect = Camera3D.KEEP_HEIGHT
	_camera.fov = CharCreateView.FOV_Y_DEGREES
	_camera.near = NEAR
	_camera.far = FAR
	_root.add_child(_camera)
	_mirror = Node3D.new()
	_mirror.name = "D3DSpace"
	_mirror.scale = Vector3(1.0, 1.0, -1.0)
	_root.add_child(_mirror)
	_pivot = Node3D.new()
	_pivot.name = "ModelPivot"
	_pivot.position = CharCreateView.MODEL_POSITION
	_mirror.add_child(_pivot)
	_lighter = PlayerPortrait.new()

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _lighter != null and is_instance_valid(_lighter):
		_lighter.free()

## The backdrop's zone light (World3D's _portrait_zone_light: environment
## channels 2 and 3).
func set_zone_light(diffuse_channel: Color, ambient_channel: Color) -> void:
	_zone_light = [diffuse_channel, ambient_channel]
	_lighter.set_zone_light(diffuse_channel, ambient_channel)

## Shows the character for these choices (round 847: its look, the create
## kit's CharCreateModel.preview_look). `restart` plays the stand clip from its
## start (a model or weapon change); otherwise the clip runs on.
func show_character(look: CharacterLook, restart: bool) -> bool:
	if appearance == null:
		return false
	var t0 := Time.get_ticks_usec()
	var next := appearance.build_look(look)
	var t1 := Time.get_ticks_usec()
	if next == null:
		return false
	if body != null and is_instance_valid(body):
		_pivot.remove_child(body)
		body.free()
	body = next
	_pivot.add_child(body)
	_lighter.set("_materials", [])
	_lighter.unmapped_materials = 0
	_lighter.call("_apply_materials", body)
	if not _zone_light.is_empty():
		_lighter.set_zone_light(_zone_light[0], _zone_light[1])
	last_build_usec = t1 - t0
	last_material_usec = Time.get_ticks_usec() - t1
	rebuilds += 1
	var anim := appearance.animation_for(body, BsrReader.AnimationEntry.TYPE_STAND)
	if restart or anim != _anim:
		_anim_time = 0.0
	_anim = anim
	body.pose(_anim, _anim_time)
	return true

## Height and Volume without a rebuild.
func set_scale_byte(scale: int) -> void:
	if body != null and is_instance_valid(body):
		body.set_scale_byte(scale)

func height_factor() -> float:
	return body.height_factor if body != null and is_instance_valid(body) else 1.0

func set_yaw(yaw: float) -> void:
	_pivot.rotation.y = -yaw

## The camera for a CharCreateView pose (its target in the window's own,
## left-handed space).
func set_pose(p: IntroCameraPath.Pose) -> void:
	var etu := IntroCameraPath.sro_eye_target_up(p)
	var eye := PlayerPortrait.to_godot(etu[0])
	var target := PlayerPortrait.to_godot(etu[1])
	var up := PlayerPortrait.to_godot(etu[2])
	_camera.transform = Transform3D(Basis.IDENTITY, eye).looking_at(target, up)

func advance(dt: float) -> void:
	if _anim == null or body == null or not is_instance_valid(body):
		return
	_anim_time += dt
	body.pose(_anim, _anim_time)

## Where a bone of the shown body lands on the window (pixels), or (-1, -1):
## the measurement for framing and facing.
func bone_on_screen(bone: String) -> Vector2:
	if body == null or body.skeleton == null or not body.skeleton.is_inside_tree():
		return Vector2(-1, -1)
	var skel := body.skeleton
	var i := skel.find_bone(bone)
	if i < 0:
		return Vector2(-1, -1)
	var p := skel.global_transform * skel.get_bone_global_pose(i).origin
	if _camera.is_position_behind(p):
		return Vector2(-1, -1)
	# In the buffer's pixels: the screen's physical pixels from round 695
	# (ViewportPixels), the UI's units before it.
	return _camera.unproject_position(p)

func camera() -> Camera3D:
	return _camera

func release() -> void:
	if body != null and is_instance_valid(body):
		body.free()
	body = null
	_anim = null
	if appearance != null:
		appearance.free_templates()
