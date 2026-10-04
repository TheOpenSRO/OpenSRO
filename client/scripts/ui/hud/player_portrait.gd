extends SubViewport
class_name PlayerPortrait

## The face in the player block's circle (round 635): the player's own dressed
## model rendered once, from a camera at its head, into a 128x128 buffer that
## the block shows through the round mask `pmi_face.ddj`.
##
## Everything below is READ from sro_client.exe unless it says otherwise
## (docs/protocol/player_mini_info.md, "The portrait", has the addresses and
## the evidence). Labels: READ, MEASURED, INFERRED, OURS, OPEN.
##
## **Which model.** CIFPlayerMiniInfo's render, `FUN_007b7740`, borrows the
## equipment window's avatar (`IFMainPopup::FUN_006a1d50` -> the CIFEquipment
## page, its CCObjAnimation at +0x36c): the same dressed body the equipment
## window turns. Here that is a copy of the player's own assembled skeleton
## (World3D hands one over on every dress), so the portrait wears exactly what
## the body in the world wears.
##
## **The pose.** It plays animation 0x3c on the avatar (`vt+0xc(0x3c, 0, 0, 0,
## 1.0, 1.0)`) and steps it once (`FUN_00a5ac80(1, 0.0)`), then reads the
## head. 0x3c = 60 is ANI_POSE in the client's ANI_ name map (FUN_009e5240,
## SkillEffectReader.ANI_TYPES), and every player body lists one: MEASURED,
## `man_pose.ban` for CHAR_CH_MAN_FIGHTER and CHAR_EU_MAN_WARRIOR,
## `woman_pose.ban` for CHAR_CH_WOMAN_FIGHTER, in the `default` group only
## (client/tools/probe_portrait.gd). The step is one frame's delta from the
## clip's start; the first key is used here (INFERRED: the same pose to
## within a frame).
##
## **The camera** (READ, 0x007b7875..0x007b790a and the camera update
## `CGFXVideo3d::FUN_00bae810` / `FUN_00bae580`): a copy of the game camera
## whose look-at target (+0x10) is the `Bip01 Head` bone's position plus 1.0
## on y (the double at 0x00e1b7f0), whose rotation angles are +0x34 = 0,
## +0x38 = 0.2 (0x00da95f8), +0x3c = 0, whose distance (+0x40) is 6.5
## (0x00da95f4) and whose vertical field of view (+0x50) is 30.0 degrees
## (0x00d82ef0, scaled by pi/180 at 0x00e1b8d8 into
## `D3DXMatrixPerspectiveFovLH`, `FUN_00aa4ef0`). FUN_00bae580 builds
## R = RotZ(+0x3c) * RotX(+0x34) * RotY(+0x38) and puts the eye at
## target - (0, 0, distance) * R: so 0.2 rad is a YAW about the head and the
## look is level (READ in round 635's review: the dispatch table at
## 0x00ec7840 resolves 0x00ec7798 / 779c / 77a0 to D3DX's RotationX / Y / Z;
## M0 = RZ * RX, then R = M0 * RY). The aspect is the target's, 128/128.
## Near and far are the game camera's (copied, OPEN); NEAR/FAR are OURS.
##
## **The avatar's yaw.** `FUN_00a5a8c0(0.1)` (the float at 0x00e1b7fc) turns
## the avatar to 0.1 rad for the render and restores the equipment window's
## own angle (+0x578) after. The CCompoundObj yaw setter (vtable slot 12,
## `CCompChar::FUN_00c26e70`) builds the row-vector matrix
## [[c,0,s],[0,1,0],[-s,0,c]] (cos 0x00b44a10, sin 0x00b44b40, READ);
## INFERRED that the avatar's object is of that family.
##
## **Handedness.** The client is Direct3D, left-handed; the assembled body is
## the file's own coordinates. Drawn straight into Godot's right-handed space
## the picture would be the mirror image of retail's, so the model hangs under
## a z -> -z node, the world's own fix (docs/WORLD_ISSUES.md, round 61), and
## the camera is placed in those same file coordinates.
##
## **The light: the zone's, not the portrait's own** (READ; round 635's
## review follow-up). The render sets a D3DLIGHT9 of its own (0x007b796d:
## directional (0,0,1), diffuse 0.7, ambient 0.3, specular 0.58) with the
## DEVICE's SetLight (0x007b7a2b) -- fixed-function state no draw reads:
## `CGame::FUN_00bc13d0` always builds CObjRendererVS, every object draw goes
## through a vertex shader (`CObjRendererVS::FUN_00bf05e0`), and the shader's
## light constants come only from `CObjRendererVS::vslot_025` (0x00beecc0),
## which only the world draw calls (`Map::FUN_00a19160`, the dungeon's
## `Map::FUN_00a255c0`). So the avatar is lit by the world's light as it
## stands when the portrait renders:
##   * direction: DAT_01109510..18 = normalize(-1, -1, 0) (`Map::FUN_00a2f370`,
##     0x00a300c2..0x00a301c4); vslot_025 stores it times -1.0 (0x00e1b8e8),
##     so the direction TO the light is (0.707, 0.707, 0) in the file's
##     coordinates -- above and to the +x side;
##   * diffuse: world+0x6847.., environment channel 2 (DiffuseColor; record
##     +0xf0, `Map::FUN_00a1baf0` 0x00a1bbf3) clamped to [0, 1]
##     (0x00a1cb96..), times 0.6 (0x00d86fc0), or 0.8 (0x00de4c64) while
##     world+0x2e54 is set -- READ in round 706: the bloom's screen target
##     exists, so 0.8 with the Bloom row on (ObjectLight.diffuse_scale) --
##     halved when world+0x26bb (underwater) is set, taken as clear here; at
##     0x00a1d1b6..0x00a1d20b;
##   * ambient: world+0x6853.., environment channel 3 (ObjectAmbientColor;
##     record +0x124, 0x00a1bc29) clamped to [0, 1] in the same block
##     (0x00a1cc50..0x00a1cc88), put in the light at 0x00a19262;
##   * when world+0x2eb4 is 1 the targets are constants instead (0x00a1be9f,
##     OPEN what that mode is).
## The skinned-object vertex shader (`vertexshader2.c`) lights a vertex as
## `oD0 = c10 + max(0, N.c9) * c11`, saturated:
##   * c9 = that to-light direction in object space (`vslot_038`);
##   * c10 = the OBJECT's colour x the ambient (`vslot_038`, 0x00bf59ce..
##     0x00bf5a04: [[renderer+0xc4]+0x14..0x1c]; raw when renderer+0x120 bit 0
##     is set, OPEN, taken as clear) -- the colour CCompoundObj slot 21
##     (`CCompChar::FUN_00c255e0`) sets, 0.6 from the constructor (0x00d86fc0
##     stored at 0x00c330ed in `FUN_00c32e50`; OPEN whether anything changes it
##     for the equipment avatar);
##   * c11 = the material's colour (+0x10.., MEASURED 0.588 on every player
##     body layer) x the diffuse (`FUN_00bf2360`, 0x00bf2504);
## and the draw sets stage 0 to D3DTOP_MODULATE2X (0x00bf5e1e). The face,
## square to the camera, has n.l = 0 against a light from above and the side:
## it gets the ambient term only. The zone's colours come from World3D
## (set_zone_light), sampled as the world samples them (its fixed reference
## time, OURS); the portrait re-renders when they change -- world entry and a
## teleport, which is when retail's FUN_00786f30 -> FUN_006abc50 dirties it.
## The specular term is not drawn (the vertex shader writes no oD1).
##
## **Clear.** BufRender's begin (`FUN_009edb60`) clears target and depth to
## 0xff000000 -- opaque black -- and 1.0 (READ).
##
## **When it renders** (READ): only while the block's dirty byte (+0x38c) is
## set, checked by vslot_012 every frame (0x007b83ef). It is set at creation,
## on the device reset (message 0x802), by `CIFPlayerMiniInfo::FUN_007b4c00`
## -- called after the item-move reply (`NetProcessInInner::FUN_0087ba20`,
## five sites after the avatar's refresh FUN_006ab690) and by the avatar's
## reset `FUN_006abc50` (from FUN_00786f30) -- and kept set while the avatar
## has not loaded. Nothing in the berserk code touches it: the berserk face is
## the GDR_PMI_HWAN_EFF_FACE overlay, not a re-render. So it renders once per
## dress, not every frame; UPDATE_ONCE here.

## READ: `BufRender::FUN_009edae0(0x80, 0x80)` in Create (0x007b56ef).
const BUFFER_SIZE := 128

## The buffer for a picture covering `physical` screen pixels (round 695,
## ViewportPixels): retail's 128x128, or a square as large as the picture's
## longer side where that is larger -- at UI scale 2.0 the 128 buffer was
## drawn magnified. Square, so the camera (KEEP_HEIGHT) frames the same.
static func buffer_for(physical: Vector2i) -> Vector2i:
	var side := maxi(BUFFER_SIZE, maxi(physical.x, physical.y))
	return Vector2i(side, side)
## READ: the animation FUN_007b7740 plays, 0x3c = ANI_POSE.
const ANI_POSE := 0x3c
## READ: the bone the camera anchors on (the string at 0x00da95fc).
const HEAD_BONE := "Bip01 Head"
## READ: added to the head's y (the double at 0x00e1b7f0).
const TARGET_LIFT := 1.0
## READ: camera +0x38 (0x00da95f8), a yaw about the target (RotationY).
const CAMERA_YAW := 0.2
## READ: camera +0x34 / +0x3c, both 0.
const CAMERA_PITCH := 0.0
const CAMERA_ROLL := 0.0
## READ: camera +0x40 (0x00da95f4).
const CAMERA_DISTANCE := 6.5
## READ: camera +0x50 (0x00d82ef0), degrees, the vertical field of view.
const CAMERA_FOV_DEG := 30.0
## OURS: the game camera's near/far are copied into the portrait's (OPEN);
## these keep a head 6.5 away well inside the frustum.
const CAMERA_NEAR := 0.5
const CAMERA_FAR := 1000.0
## READ: FUN_00a5a8c0(0.1) (0x00e1b7fc), the avatar's yaw for the render.
const MODEL_YAW := 0.1
## READ: the world light's direction, DAT_01109510 = normalize(-1, -1, 0)
## (Map::FUN_00a2f370), in the file's coordinates.
const WORLD_LIGHT_DIRECTION := Vector3(-0.70710678, -0.70710678, 0.0)
## READ: the world light's diffuse is channel 2 clamped x 0.6 (0x00d86fc0)
## with no bloom target, x 0.8 with one (round 706: zone_light_colors uses
## ObjectLight.diffuse_scale for the Bloom row in force).
const DIFFUSE_SCALE := 0.6
## READ: CCompoundObj's own colour from its constructor (0x00d86fc0 at
## 0x00c330ed), the factor on the ambient term (c10).
const OBJECT_COLOR := 0.6
## OURS: the channel values used before any zone is known (a dev run without
## Map.pk2): 1.0 each, stated rather than guessed at.
const FALLBACK_CHANNEL := Color(1.0, 1.0, 1.0, 1.0)
## READ: BufRender's clear colour, 0xff000000.
const CLEAR_COLOR := Color(0.0, 0.0, 0.0, 1.0)
## READ: the object draw's stage-0 D3DTOP_MODULATE2X.
const MODULATE_SCALE := 2.0
## READ: the object renderer's alpha test, ALPHAREF 0x80 with GREATEREQUAL,
## for a layer whose flag word has 0x200 (ObjectLoader's material rule).
const ALPHA_REF := 128.0 / 255.0

const PORTRAIT_SHADER := """
shader_type spatial;
render_mode unshaded, %s;

// The skinned-object vertex shader's lighting and the draw's MODULATE2X,
// done in the client's own (gamma) space: see PlayerPortrait. MEASURED
// (client/tools/portrait_shot.gd's calibration, round 635): in this
// renderer's SubViewport a texel reaches the shader as stored and ALBEDO
// reaches the buffer as written -- no sRGB decode, no encode -- so the
// arithmetic below is the client's, value for value. No `source_color`
// hint, so the sample is the stored byte / 255 on every driver. That held
// under GL Compatibility, which decodes ALBEDO and encodes the result;
// Forward+ takes ALBEDO as linear, so it is decoded there at the end
// (ShaderColour, round 693) and still reaches the buffer as written.
uniform sampler2D tex : filter_linear_mipmap, repeat_enable;
uniform vec4 material_color = vec4(0.588, 0.588, 0.588, 1.0);
uniform vec3 to_light = vec3(0.70710678, 0.70710678, 0.0);
uniform vec3 object_color = vec3(0.6);
uniform vec3 light_ambient = vec3(0.6);
uniform vec3 light_diffuse = vec3(0.4);
uniform float modulate_scale = 2.0;
uniform float alpha_ref = 0.0;
uniform bool has_texture = true;
varying vec3 lit;

void vertex() {
	vec3 n = normalize(MODEL_NORMAL_MATRIX * NORMAL);
	float ndl = max(dot(n, normalize(to_light)), 0.0);
	// oD0 = c10 + max(0, N.c9) * c11, saturated as a vs_1_1 colour output is:
	// c10 = object colour x ambient, c11 = material colour x diffuse.
	// material_color is set as a Color: as stored (ShaderColour.srr_color).
	lit = clamp(object_color * light_ambient + ndl * srr_color(material_color, OUTPUT_IS_SRGB).rgb * light_diffuse, 0.0, 1.0);
}

void fragment() {
	vec4 t = has_texture ? texture(tex, UV) : vec4(1.0);
	if (alpha_ref > 0.0 && t.a < alpha_ref) {
		discard;
	}
	ALBEDO = clamp(modulate_scale * t.rgb * lit, 0.0, 1.0);
	%s
	%s
}
"""

## What a mod pass (ObjectLoader._mod_shader: an MTRL mod's own stage ops,
## alpha test and blend, READ from CRTModMtrl::vslot_004) gets injected so it
## draws in the portrait: its vertex colour (ObjectLight.OD0_LINE, the
## world's light) is replaced by this one, the portrait's light.
const MOD_INJECT := """
uniform vec3 portrait_to_light = vec3(0.70710678, 0.70710678, 0.0);
uniform vec3 portrait_object_color = vec3(0.6);
uniform vec3 portrait_light_ambient = vec3(0.6);
uniform vec3 portrait_light_diffuse = vec3(0.4);
"""
const MOD_OD0 := "srr_od0 = clamp(portrait_object_color * portrait_light_ambient + max(dot(normalize(MODEL_NORMAL_MATRIX * NORMAL), normalize(portrait_to_light)), 0.0) * srr_color(albedo, OUTPUT_IS_SRGB).rgb * portrait_light_diffuse, 0.0, 1.0);"

var _root: Node3D
var _mirror: Node3D
var _camera: Camera3D
var _character: Skeleton3D
var _shaders := {}
## The portrait's own materials (for a light change).
var _materials: Array = []
## The zone light's colours (zone_light_colors), the fallback until World3D
## sets one.
var _light: Dictionary = zone_light_colors(FALLBACK_CHANNEL, FALLBACK_CHANNEL)
var _zone_known := false
## Materials it could not translate, left as they were (for the log).
var unmapped_materials := 0
## The last dress's CPU cost in microseconds (copy, pose, materials).
var last_build_usec := 0
## How many renders were asked for (one per dress).
var renders_requested := 0

func _init() -> void:
	size = Vector2i(BUFFER_SIZE, BUFFER_SIZE)
	own_world_3d = true
	transparent_bg = false
	disable_3d = false
	msaa_3d = Viewport.MSAA_DISABLED
	render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	render_target_update_mode = SubViewport.UPDATE_DISABLED

	_root = Node3D.new()
	_root.name = "PortraitScene"
	add_child(_root)

	var env := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = CLEAR_COLOR
	# Nothing here is lit by Godot: the material does the client's own
	# lighting (PORTRAIT_SHADER), so no Godot light or ambient is added.
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.environment = environment
	_root.add_child(env)

	# The file's own (left-handed) coordinates, mirrored into Godot's.
	_mirror = Node3D.new()
	_mirror.name = "D3DSpace"
	_mirror.scale = Vector3(1.0, 1.0, -1.0)
	_root.add_child(_mirror)

	_camera = Camera3D.new()
	_camera.name = "PortraitCamera"
	_camera.fov = CAMERA_FOV_DEG
	_camera.keep_aspect = Camera3D.KEEP_HEIGHT
	_camera.near = CAMERA_NEAR
	_camera.far = CAMERA_FAR
	_camera.current = true
	_root.add_child(_camera)

## Takes `skeleton` (a copy of the player's dressed body -- this node owns it
## from now on) and `pose` (the body's ANI_POSE clip, or null to keep its
## current pose), frames it and renders it once.
func set_character(skeleton: Skeleton3D, pose: BanReader.ParsedAnimation) -> void:
	var t0 := Time.get_ticks_usec()
	unmapped_materials = 0
	_materials.clear()
	if _character != null and is_instance_valid(_character):
		_character.queue_free()
	_character = skeleton
	if skeleton == null:
		return
	if skeleton.get_parent() != null:
		skeleton.get_parent().remove_child(skeleton)
	# Height stays (round 689's review, READ): the equipment page's avatar this
	# borrows is dressed by FUN_00a619e0, which ends with FUN_00a5b960 (the
	# scale byte at the character info's +0x30) -- the world body's uniform
	# scale, about its feet. The head, read after it, is the scaled head.
	var height := skeleton.scale
	skeleton.transform = Transform3D(Basis.from_scale(height), Vector3.ZERO)
	_mirror.add_child(skeleton)
	if pose != null:
		Skeleton3DBuilder.apply_ban_pose_at(skeleton, pose, 0.0, false)
	else:
		skeleton.force_update_all_bone_transforms()
	var head := head_position(skeleton) * height
	# The avatar's own yaw (after the head is read, as FUN_007b7740 does).
	skeleton.rotation.y = model_rotation_y()
	_place_camera(head + Vector3(0.0, TARGET_LIFT, 0.0))
	_apply_materials(skeleton)
	last_build_usec = Time.get_ticks_usec() - t0
	request_render()

## One render on the next frame, then the buffer holds it.
func request_render() -> void:
	renders_requested += 1
	render_target_update_mode = SubViewport.UPDATE_ONCE

func character() -> Skeleton3D:
	return _character

func camera() -> Camera3D:
	return _camera

## The head bone's position in the body's own coordinates, or the top of the
## skeleton's bones when a body has no such bone (none measured lacks it).
static func head_position(skeleton: Skeleton3D) -> Vector3:
	var i := skeleton.find_bone(HEAD_BONE)
	if i >= 0:
		return skeleton.get_bone_global_pose(i).origin
	var top := Vector3.ZERO
	for b in range(skeleton.get_bone_count()):
		var o := skeleton.get_bone_global_pose(b).origin
		if o.y > top.y:
			top = o
	return top

## The eye in the file's (Direct3D) coordinates for a look-at target:
## target - (0, 0, distance) * RotZ(roll) * RotX(pitch) * RotY(yaw), the
## row-vector product FUN_00bae580 builds with D3DX's rotation matrices.
static func camera_eye(target: Vector3) -> Vector3:
	var v := Vector3(0.0, 0.0, CAMERA_DISTANCE)
	v = _d3d_rot_z(v, CAMERA_ROLL)
	v = _d3d_rot_x(v, CAMERA_PITCH)
	v = _d3d_rot_y(v, CAMERA_YAW)
	return target - v

## v * D3DXMatrixRotationY(a) (row vector): (x c + z s, y, -x s + z c).
static func _d3d_rot_y(v: Vector3, a: float) -> Vector3:
	var c := cos(a)
	var s := sin(a)
	return Vector3(v.x * c + v.z * s, v.y, -v.x * s + v.z * c)

## v * D3DXMatrixRotationX(a): (x, y c - z s, y s + z c).
static func _d3d_rot_x(v: Vector3, a: float) -> Vector3:
	var c := cos(a)
	var s := sin(a)
	return Vector3(v.x, v.y * c - v.z * s, v.y * s + v.z * c)

## v * D3DXMatrixRotationZ(a): (x c - y s, x s + y c, z).
static func _d3d_rot_z(v: Vector3, a: float) -> Vector3:
	var c := cos(a)
	var s := sin(a)
	return Vector3(v.x * c - v.y * s, v.x * s + v.y * c, v.z)

## The body's rotation.y under the mirror node for the avatar's yaw: the
## setter's [[c,0,s],[0,1,0],[-s,0,c]] maps (x, z) to (x c - z s, x s + z c),
## which is Godot's Y rotation by -yaw in the same coordinates.
static func model_rotation_y() -> float:
	return -MODEL_YAW

## A point in the file's coordinates, in this viewport's Godot space (the
## mirror node's z -> -z).
static func to_godot(p: Vector3) -> Vector3:
	return Vector3(p.x, p.y, -p.z)

## The direction TO the light in Godot space: the light's direction times
## -1.0 (vslot_025), mirrored like everything else.
static func to_light_godot() -> Vector3:
	return to_godot(-WORLD_LIGHT_DIRECTION)

## One channel as the client draws it: the vertex colour
## clamp(object x ambient + max(0, n.l) x material x diffuse), then
## texture x colour x 2, clamped (gamma space). `ambient` / `diffuse` are the
## light's (zone_light_colors).
static func shade(texel: float, material: float, object: float, ambient: float, diffuse: float, n_dot_l: float) -> float:
	var lit := clampf(object * ambient + maxf(n_dot_l, 0.0) * material * diffuse, 0.0, 1.0)
	return clampf(MODULATE_SCALE * texel * lit, 0.0, 1.0)

## The world light's colours from the zone's environment channels: diffuse =
## channel 2 clamped to [0, 1] x 0.6 or 0.8 (the Bloom row), ambient = channel 3 clamped to [0, 1]
## (Map::FUN_00a1baf0 clamps both world fields, 0x00a1cb96.. and
## 0x00a1cc50..0x00a1cc88).
static func zone_light_colors(diffuse_channel: Color, ambient_channel: Color) -> Dictionary:
	var d := Color(clampf(diffuse_channel.r, 0.0, 1.0), clampf(diffuse_channel.g, 0.0, 1.0), clampf(diffuse_channel.b, 0.0, 1.0)) * ObjectLight.diffuse_scale(ObjectLight.current_bloom)
	var a := Vector3(clampf(ambient_channel.r, 0.0, 1.0), clampf(ambient_channel.g, 0.0, 1.0), clampf(ambient_channel.b, 0.0, 1.0))
	return {"diffuse": Vector3(d.r, d.g, d.b), "ambient": a}

## The zone's light (World3D, on world entry and on each zone load). Re-renders
## a dressed portrait when the colours change: retail re-renders on world
## entry and teleport (FUN_00786f30 -> FUN_006abc50 -> FUN_007b4c00) with the
## world light of that moment.
func set_zone_light(diffuse_channel: Color, ambient_channel: Color) -> void:
	var c := zone_light_colors(diffuse_channel, ambient_channel)
	var changed: bool = c.hash() != _light.hash() or not _zone_known
	_light = c
	_zone_known = true
	_push_light()
	if changed and _character != null and is_instance_valid(_character):
		request_render()

func zone_light() -> Dictionary:
	return _light

func has_zone_light() -> bool:
	return _zone_known

func _push_light() -> void:
	for m in _materials:
		var mat := m as ShaderMaterial
		mat.set_shader_parameter("light_ambient", _light["ambient"])
		mat.set_shader_parameter("light_diffuse", _light["diffuse"])
		mat.set_shader_parameter("portrait_light_ambient", _light["ambient"])
		mat.set_shader_parameter("portrait_light_diffuse", _light["diffuse"])

func _place_camera(target: Vector3) -> void:
	var eye := to_godot(camera_eye(target))
	# The scene root sits at the origin, so the local transform is the global
	# one -- set directly, which also works before the node is in a tree.
	_camera.transform = Transform3D(Basis.looking_at(to_godot(target) - eye, Vector3.UP), eye)

# --- materials ----------------------------------------------------------------

func _apply_materials(node: Node) -> void:
	for child in node.get_children():
		_apply_materials(child)
	var mi := node as MeshInstance3D
	if mi == null or mi.mesh == null:
		return
	if mi.material_override != null:
		var mapped := _portrait_material(mi.material_override)
		if mapped != null:
			mi.material_override = mapped
		else:
			unmapped_materials += 1
		return
	for s in range(mi.mesh.get_surface_count()):
		var src := mi.get_active_material(s)
		var mapped := _portrait_material(src) if src != null else null
		if mapped != null:
			mi.set_surface_override_material(s, mapped)
		elif src != null:
			unmapped_materials += 1

## The portrait's own material for a body material: its texture, its colour
## (the layer's ambient, which the loaders put on the material; MEASURED equal
## to the diffuse on every player body), its cull, its alpha test and, for a
## blended layer, its blend. An MTRL mod pass keeps its own shader (stage ops,
## alpha func, blend) with the portrait's lighting injected (_mod_material).
## Null only for a material none of that describes.
func _portrait_material(src: Material) -> ShaderMaterial:
	var tex: Texture2D = null
	var color := Color(1, 1, 1, 1)
	var alpha_ref := 0.0
	var cull := "cull_back"
	var blend := false
	if src is StandardMaterial3D:
		var sm := src as StandardMaterial3D
		if sm.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA or sm.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS:
			blend = true
		tex = sm.albedo_texture
		color = sm.albedo_color
		if sm.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR:
			alpha_ref = sm.alpha_scissor_threshold
		if sm.cull_mode == BaseMaterial3D.CULL_DISABLED:
			cull = "cull_disabled"
		elif sm.cull_mode == BaseMaterial3D.CULL_FRONT:
			cull = "cull_front"
	elif src is ShaderMaterial:
		var shm := src as ShaderMaterial
		var code := shm.shader.code if shm.shader != null else ""
		if code.contains("An MTRL mod's draw"):
			return _mod_material(shm)
		for mode in ["blend_mix", "blend_add", "blend_sub", "blend_mul", "blend_premul_alpha"]:
			if code.contains(mode):
				return null
		var t = shm.get_shader_parameter("albedo_texture")
		tex = t as Texture2D
		var c = shm.get_shader_parameter("albedo")
		if c is Color:
			color = c
		var a = shm.get_shader_parameter("alpha_scissor")
		if a != null:
			alpha_ref = float(a)
		if code.contains("cull_disabled"):
			cull = "cull_disabled"
		elif code.contains("cull_front"):
			cull = "cull_front"
	else:
		return null
	var mat := ShaderMaterial.new()
	mat.shader = _shader(cull, blend)
	mat.set_shader_parameter("tex", tex)
	mat.set_shader_parameter("has_texture", tex != null)
	mat.set_shader_parameter("material_color", color)
	mat.set_shader_parameter("to_light", to_light_godot())
	mat.set_shader_parameter("object_color", Vector3(OBJECT_COLOR, OBJECT_COLOR, OBJECT_COLOR))
	mat.set_shader_parameter("light_ambient", _light["ambient"])
	mat.set_shader_parameter("light_diffuse", _light["diffuse"])
	mat.set_shader_parameter("modulate_scale", MODULATE_SCALE)
	mat.set_shader_parameter("alpha_ref", alpha_ref)
	_materials.append(mat)
	return mat

## An MTRL mod pass in the portrait: the same shader code with MOD_INJECT's
## vertex colour standing in for Godot's lighting as its DIFFUSE, unshaded,
## and every parameter of the source copied (texture, colour, stage ops,
## alpha func and ref, blend). Null when the code is not the shape expected.
func _mod_material(src: ShaderMaterial) -> ShaderMaterial:
	var code := src.shader.code
	var key := "mod:%d" % code.hash()
	if not _shaders.has(key):
		var vert := code.find("void vertex()")
		if vert < 0 or not code.contains(ObjectLight.OD0_LINE) or not code.contains("render_mode unshaded"):
			return null
		# The injection goes just before vertex(), after the source's own
		# uniforms (its vertex colour reads `albedo`).
		var out := code.substr(0, vert) + MOD_INJECT + "\n" + code.substr(vert)
		out = out.replace(ObjectLight.OD0_LINE, MOD_OD0)
		# The portrait's environment is Linear: nothing to undo (round 706).
		out = out.replace("ALBEDO = srr_obj_present(", "ALBEDO = (")
		# The portrait is not in the world's fog (round 702, WorldFog).
		out = out.replace(WorldFog.SHADER_FOG_LINE, "")
		var sh := Shader.new()
		sh.code = out
		_shaders[key] = sh
	var mat := ShaderMaterial.new()
	mat.shader = _shaders[key]
	for u in src.shader.get_shader_uniform_list():
		var n: String = u["name"]
		mat.set_shader_parameter(n, src.get_shader_parameter(n))
	mat.set_shader_parameter("portrait_to_light", to_light_godot())
	mat.set_shader_parameter("portrait_object_color", Vector3(OBJECT_COLOR, OBJECT_COLOR, OBJECT_COLOR))
	mat.set_shader_parameter("portrait_light_ambient", _light["ambient"])
	mat.set_shader_parameter("portrait_light_diffuse", _light["diffuse"])
	_materials.append(mat)
	return mat

func _shader(cull: String, blend: bool = false) -> Shader:
	var key := "%s/%s" % [cull, blend]
	if not _shaders.has(key):
		var sh := Shader.new()
		var modes := cull + (", blend_mix, depth_draw_opaque" if blend else ", depth_draw_opaque")
		sh.code = (PORTRAIT_SHADER % [modes, "ALPHA = t.a * material_color.a;" if blend else "", ShaderColour.DECODE_ALBEDO]) \
			.replace("\nvarying vec3 lit;", ShaderColour.DECODE_FN + "\nvarying vec3 lit;")
		_shaders[key] = sh
	return _shaders[key]
