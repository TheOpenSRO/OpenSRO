extends Node
class_name CharSelectStage

## The 3D half of the character select screen (round 684): the Constantinople
## harbour (FrontEndBackdrop over region 105/81), the account's characters on
## the dock (CharacterAppearance), the race-select table with its idols and
## lizard, the camera, the picking and the models' own fades and poses.
## CharacterSelect.gd runs the screen's states and windows over it; the
## numbers are CharSelectMath's.
##
## How things are placed (READ + the project's own measured fact):
## - Everything here is region-local to 105/81 and hangs under one node that
##   stands at the region's corner with scale.z = -1, as every region group
##   of the world does (World3D._group_position, title_world_from_local).
## - Retail turns the characters, the box, the idols and the lizard with the
##   one setter (FUN_00a5a8c0, called by FUN_0085def0 for a slot's yaw and by
##   OnCreate for the props), so all of them get the world's object rule,
##   `rotation.y = -yaw` (NavGraph.godot_yaw, measured round 506).
## - The models' opacity is GeometryInstance3D.transparency on each mesh
##   instance, never the materials, which CharacterAppearance shares between
##   characters (round 683's note).

signal first_view_ready
signal scene_ready

## OURS: the region window, in regions, around the frame region -- the title's
## (TitleIntro.TITLE_RADIUS). Every viewpoint of this screen (the dock at
## local x 29..95, the table at 155) lies inside region 105/81, so the window
## never moves.
const RADIUS := 1

var backdrop: FrontEndBackdrop = null
var appearance: CharacterAppearance = null
var _data: Pk2Reader = null
var _media: Pk2Reader = null
## The region-local root (see the header).
var root: Node3D = null

## One drawn character.
class Drawn:
	var record = null  # LobbyNet.Character
	var holder: Node3D
	var body: CharacterAppearance.Body
	var slot: Dictionary
	## Opacity: the byte now, and the fade towards `target` (READ: 1.0 s).
	var alpha := 0.0
	var alpha_from := 0.0
	var alpha_target := 255.0
	var alpha_t := 1.0
	## The clip playing, its start (screen clock seconds), whether it loops,
	## and what follows a one-shot (an action type, -1 none).
	var anim: BanReader.ParsedAnimation = null
	var anim_start := 0.0
	var anim_loop := true
	var then_type := -1
	## The local bounding box of the bind pose, for the pick.
	var bounds := AABB()

var drawn: Array = []  # of Drawn, in slot order
var props := {}        # "box"/"europe"/"china"/"lizard" -> Node3D
var _prop_bounds := {} # name -> AABB (local)
var _lizard_skeleton: Skeleton3D = null
var _lizard_assembled: SkinnedBsrAssembler.AssembledCharacter = null
var _lizard_anim: BanReader.ParsedAnimation = null
var _lizard_anim_start := 0.0
var _clock := 0.0
## While set, the models' fade-ins wait (the region is still building under
## the black cover: OURS, so the READ 1.0 s fade is seen and the build's
## main-thread cost is paid before anything moves).
var fades_paused := false
var _pose: IntroCameraPath.Pose = null

## Starts the backdrop and opens the archives. False when there is no 3D
## (no Map.pk2 or region): the caller keeps a 2D screen.
func begin(day_phase: float) -> bool:
	_media = FrontEndUi.open_media()
	var data_path := Pk2Config.data_path()
	_data = Pk2Reader.open(data_path) if data_path != "" else null
	if _data == null or _media == null:
		print("CharSelectStage: no Data.pk2 / Media.pk2 -- no 3D select")
		return false
	backdrop = FrontEndBackdrop.new()
	backdrop.name = "SelectBackdrop"
	add_child(backdrop)
	if not backdrop.begin(CharSelectMath.REGION, RADIUS, day_phase):
		backdrop.queue_free()
		backdrop = null
		return false
	backdrop.first_view_ready.connect(func() -> void: first_view_ready.emit(), CONNECT_ONE_SHOT)
	backdrop.scene_ready.connect(func() -> void: scene_ready.emit(), CONNECT_ONE_SHOT)
	root = Node3D.new()
	root.name = "SelectScene"
	root.position = backdrop.to_world(Vector3.ZERO)
	root.scale = Vector3(1, 1, -1)
	backdrop.world.add_child(root)
	var sw := Time.get_ticks_usec()
	appearance = CharacterAppearance.from_archives(_data, _media)
	print("CharSelectStage: catalogue read in %.1f ms" % ((Time.get_ticks_usec() - sw) / 1000.0))
	return true

## The camera, standing where the screen last put it. MEASURED (round 684):
## World3D's spring arm moves its camera on every physics tick even in title
## mode -- (-904.2, -12.0, 270.4) put there became (-900, 29.5, 266.6) a tick
## later -- and the rendered frame is right only because the pose is set
## again each _process before drawing. Anything projecting through the
## camera between those (the name labels, a pick) puts the pose back first.
func camera() -> Camera3D:
	var cam := backdrop.camera() if backdrop != null else null
	if cam != null and _pose != null:
		cam.global_transform = IntroCameraPath.camera_transform(_pose, Callable(backdrop, "to_world"))
	return cam

func show_pose(pose: IntroCameraPath.Pose) -> void:
	_pose = pose
	if backdrop != null:
		backdrop.show_pose(pose)

func current_pose() -> IntroCameraPath.Pose:
	return _pose

## World space for a region-local point.
func to_world(local: Vector3) -> Vector3:
	return root.global_transform * local if root != null else local

# --- Characters ---------------------------------------------------------------

## Draws `records` (in slot order) at their slots, each fading in from
## nothing over 1.0 s (READ, FUN_0085f840 zeroes the alpha, FUN_0085def0 sets
## the fade) in its idle -- standing, or seated when pending deletion
## (READ, FUN_0085a580: action 0 or 0xe).
func set_characters(records: Array, plan: Array) -> void:
	clear_characters()
	if root == null or appearance == null:
		return
	if _lighter != null:
		_lighter.set("_materials", [])
		_lighter.unmapped_materials = 0
	var sw := Time.get_ticks_usec()
	for k in range(records.size()):
		var r = records[k]
		var p: Dictionary = plan[k]
		var d := Drawn.new()
		d.record = r
		d.slot = p
		d.holder = Node3D.new()
		d.holder.name = "Slot%d" % k
		d.holder.position = p["pos"]
		d.holder.rotation.y = NavGraph.godot_yaw(float(p["yaw"]))
		root.add_child(d.holder)
		var items: Array = []
		items.append_array(r.items)
		items.append_array(r.avatars)
		d.body = appearance.build(r.ref_obj_id, r.scale, items)
		if d.body != null:
			d.holder.add_child(d.body)
			_dress(d.body)
			d.bounds = _bounds_of(d.body)
		else:
			print("CharSelectStage: %s's body %d could not be built" % [r.char_name, r.ref_obj_id])
		d.alpha = 0.0
		d.alpha_from = 0.0
		d.alpha_target = float(p["alpha"])
		d.alpha_t = 0.0
		_play(d, int(p["action"]), true)
		_apply_alpha(d)
		drawn.append(d)
	print("CharSelectStage: %d character(s) built in %.1f ms" % [records.size(), (Time.get_ticks_usec() - sw) / 1000.0])

## The characters' light (round 688's review): retail draws every character
## through one vertex shader whose light is the world's (PlayerPortrait's
## header, READ: oD0 = object colour 0.6 x ambient + max(0, n.l) x material
## colour x diffuse, diffuse = environment channel 2 clamped x 0.6, ambient =
## channel 3 clamped, then texture x oD0 x 2 -- MODULATE2X). The customize
## preview (round 685), the equipment window and the portrait draw bodies so;
## the select screen hung them in the backdrop with Godot's lit materials under
## World3D's tuned light (energy 0.3, OURS since round 43), which MEASURED
## (the review, and OPENSRO_QA_SELECT_LUMA's per-body line) about 1.8x
## darker than the same character in the preview at the same hour. Now each
## body wears PlayerPortrait's materials fed the backdrop's zone light, as
## CharCreatePreview does; the body hides (round 687) and default wear (round
## 685) are on the body before this and only its materials change.
## OPENSRO_QA_SELECT_GODOT_LIGHT=1 (OURS, QA) keeps the old materials, for a
## before/after on one build.
var _lighter: PlayerPortrait = null
var _zone_light: Array = []

func _dress(body: Node) -> void:
	if OS.get_environment("OPENSRO_QA_SELECT_GODOT_LIGHT") != "":
		return
	if _lighter == null:
		_lighter = PlayerPortrait.new()
		var zl = backdrop.world.get("_portrait_zone_light") if backdrop != null and backdrop.world != null else null
		if zl is Array and (zl as Array).size() == 2:
			_zone_light = zl
	var before: int = (_lighter.get("_materials") as Array).size()
	_lighter.call("_apply_materials", body)
	if not _zone_light.is_empty():
		_lighter.set_zone_light(_zone_light[0], _zone_light[1])
	var env := _backdrop_environment()
	var mats: Array = _lighter.get("_materials")
	for i in range(before, mats.size()):
		_undo_tonemap(mats[i] as ShaderMaterial, env)

## The backdrop's tone mapping undone on the characters (round 688's review,
## OURS on READ Godot source). PlayerPortrait's shader computes the client's
## own colour (gamma space) and, in the preview's and portrait's SubViewports
## (TONE_MAPPER_LINEAR), that value reaches the screen as written (MEASURED,
## round 635). The backdrop is World3D's environment: Filmic (tonemap_mode 2)
## at exposure 1.0, white 1.0. READ, Godot 4.2.2 drivers/gles3/shaders/
## scene.glsl 1369 and 1590-1593 and tonemap_inc.glsl 42-58 and 96-108: an
## unshaded ALBEDO is decoded (srgb_to_linear, a cubic), times exposure,
## filmic-mapped and divided by the mapped white, and encoded (linear_to_srgb,
## 1.055 x^(1/2.4) - 0.055). MEASURED before this undo: the dressed bodies
## came out 13-37 % brighter than the same character's preview (0.73-0.89).
## So the characters' ALBEDO is pre-inverted through that chain -- the
## filmic's quadratic solved exactly, the cubic by Newton's method -- and the
## frame carries the client's value.
const UNDO_TONEMAP := """
uniform float undo_exposure = 1.0;
uniform float undo_white = 1.0;
uniform bool undo_filmic = false;
float undo_f(float x) {
	const float FA = 0.88; const float FB = 0.6; const float FC = 0.1; const float FD = 0.2; const float FE = 0.01; const float FF = 0.3;
	return ((x * (FA * x + FC * FB) + FD * FE) / (x * (FA * x + FB) + FD * FF)) - FE / FF;
}
vec3 undo_tonemap(vec3 o) {
	if (!undo_filmic) {
		return o;
	}
	const float FA = 0.88; const float FB = 0.6; const float FC = 0.1; const float FD = 0.2; const float FE = 0.01; const float FF = 0.3;
	vec3 r;
	for (int i = 0; i < 3; i++) {
		float v = clamp(o[i], 0.0, 1.0);
		// The linear value the encode must see.
		float y = pow((v + 0.055) / 1.055, 2.4);
		// Its pre-filmic linear value.
		float g = y * undo_f(undo_white) + FE / FF;
		float qa = FA * (1.0 - g);
		float qb = FB * (FC - g);
		float qc = FD * (FE - g * FF);
		float x = (-qb + sqrt(max(qb * qb - 4.0 * qa * qc, 0.0))) / (2.0 * qa);
		x = max(x / max(undo_exposure, 1e-4), 0.0);
		// The albedo whose decode is x: srgb_to_linear(a) = a (a (0.305306011 a + 0.682171111) + 0.012522878).
		float a = pow(x, 1.0 / 2.2);
		for (int k = 0; k < 4; k++) {
			float fa = a * (a * (a * 0.305306011 + 0.682171111) + 0.012522878) - x;
			float da = 3.0 * 0.305306011 * a * a + 2.0 * 0.682171111 * a + 0.012522878;
			a = clamp(a - fa / max(da, 1e-4), 0.0, 1.0);
		}
		r[i] = a;
	}
	return r;
}
"""
const PORTRAIT_ALBEDO := "ALBEDO = clamp(modulate_scale * t.rgb * lit, 0.0, 1.0);"
const MOD_ALBEDO := "ALBEDO = clamp(lit + unlit, 0.0, 1.0);"
static var _undo_shaders := {}

static func _undo_tonemap(mat: ShaderMaterial, env: Environment) -> void:
	if mat == null or mat.shader == null:
		return
	var code := mat.shader.code
	var line := PORTRAIT_ALBEDO if code.contains(PORTRAIT_ALBEDO) else (MOD_ALBEDO if code.contains(MOD_ALBEDO) else "")
	var frag := code.find("void fragment()")
	if line == "" or frag < 0:
		return
	var key := code.hash()
	if not _undo_shaders.has(key):
		var sh := Shader.new()
		var inner := line.trim_prefix("ALBEDO = ").trim_suffix(";")
		sh.code = (code.substr(0, frag) + UNDO_TONEMAP + "\n" + code.substr(frag)).replace(line, "ALBEDO = undo_tonemap(%s);" % inner)
		_undo_shaders[key] = sh
	mat.shader = _undo_shaders[key]
	var filmic := env != null and env.tonemap_mode == Environment.TONE_MAPPER_FILMIC
	mat.set_shader_parameter("undo_filmic", filmic)
	mat.set_shader_parameter("undo_exposure", env.tonemap_exposure if env != null else 1.0)
	mat.set_shader_parameter("undo_white", env.tonemap_white if env != null else 1.0)

func _backdrop_environment() -> Environment:
	var we = backdrop.world.get("world_environment") if backdrop != null and backdrop.world != null else null
	return (we as WorldEnvironment).environment if we is WorldEnvironment else null

func clear_characters() -> void:
	for d in drawn:
		if is_instance_valid(d.holder):
			d.holder.queue_free()
	drawn.clear()

## Which page a slot is on; only the current page is drawn (READ, vslot_013).
func show_page(page: int) -> void:
	for k in range(drawn.size()):
		(drawn[k] as Drawn).holder.visible = k / CharSelectMath.PER_PAGE == page

## READ, FUN_0085f840 after a delete or restore: the character sits down
## (0xd, then seated 0xe) at 0xcc, or stands up (0xf, then standing 0) at
## 0xff, its opacity fading there over 1.0 s.
func play_deleted(k: int) -> void:
	var d := _at(k)
	if d == null:
		return
	_play(d, BsrReader.AnimationEntry.TYPE_SIT_DOWN, false, BsrReader.AnimationEntry.TYPE_SITTING)
	_fade_model(d, CharSelectMath.PENDING_ALPHA)

func play_restored(k: int) -> void:
	var d := _at(k)
	if d == null:
		return
	_play(d, BsrReader.AnimationEntry.TYPE_STAND_UP, false, BsrReader.AnimationEntry.TYPE_STAND)
	_fade_model(d, 255)

func _fade_model(d: Drawn, to: int) -> void:
	d.alpha_from = d.alpha
	d.alpha_target = float(to)
	d.alpha_t = 0.0

func _at(k: int) -> Drawn:
	return drawn[k] if k >= 0 and k < drawn.size() else null

func _play(d: Drawn, action: int, loop: bool, then_type: int = -1) -> void:
	d.anim = appearance.animation_for(d.body, action) if d.body != null else null
	print("CharSelectStage: %s plays action %d: %s%s" % [d.record.char_name if d.record != null else "?", action,
		d.anim.animation_name if d.anim != null else "(none)", "" if loop else " once"])
	d.anim_start = _clock
	d.anim_loop = loop
	d.then_type = then_type
	if d.anim == null and then_type >= 0:
		# The model names no such clip: go straight to what follows.
		_play(d, then_type, true)

## The clip a character is in, for a check (an action type's clip or null).
func clip_name(k: int) -> String:
	var d := _at(k)
	return d.anim.animation_name if d != null and d.anim != null else ""

func alpha_of(k: int) -> int:
	var d := _at(k)
	return int(roundf(d.alpha)) if d != null else 0

## The character under a screen point on page `page`, or -1. READ, vslot_012
## case 2: each character of the page in order is ray-picked against its
## model's bounding box (FUN_00a5b2c0 -> FUN_00a5b000 with the model's local
## box, vslot 0x10, and its matrix, vslot 0x18), and the FIRST hit wins --
## not the nearest.
func pick(screen: Vector2, page: int) -> int:
	var cam := camera()
	if cam == null:
		return -1
	var from := cam.project_ray_origin(screen)
	var dir := cam.project_ray_normal(screen)
	for k in range(drawn.size()):
		if k / CharSelectMath.PER_PAGE != page:
			continue
		var d: Drawn = drawn[k]
		if d.body == null or d.alpha <= 0.0:
			continue
		if _ray_hits_box(from, dir, d.body.global_transform, d.bounds):
			return k
	return -1

## Where a character's name label goes on screen (READ, vslot_013: the slot
## plus label_height, projected), or null behind the camera.
func label_anchor(k: int) -> Variant:
	var d := _at(k)
	var cam := camera()
	if d == null or cam == null:
		return null
	var local: Vector3 = d.slot["pos"] + Vector3(0, CharSelectMath.label_height(d.record.scale, d.body != null and d.body.is_woman), 0)
	var w := to_world(local)
	if cam.is_position_behind(w):
		return null
	return cam.unproject_position(w)

func is_woman(k: int) -> bool:
	var d := _at(k)
	return d != null and d.body != null and d.body.is_woman

# --- The race-select table -----------------------------------------------------------

## Loads the box, the two idols and the lizard (READ: OnCreate loads all four;
## the lizard stays hidden until the race fly ends -- vslot_013 draws it only
## while +0x220 > 0).
func build_props() -> void:
	if root == null:
		return
	var sw := Time.get_ticks_usec()
	_add_prop("box", CharSelectMath.BOX_BSR, CharSelectMath.BOX_POS, CharSelectMath.BOX_YAW)
	_add_prop("europe", CharSelectMath.IDOL_EUROPE_BSR, CharSelectMath.IDOL_EUROPE_POS, CharSelectMath.IDOL_EUROPE_YAW)
	_add_prop("china", CharSelectMath.IDOL_CHINA_BSR, CharSelectMath.IDOL_CHINA_POS, CharSelectMath.IDOL_CHINA_YAW)
	_add_prop("lizard", CharSelectMath.LIZARD_BSR, CharSelectMath.LIZARD_POS, CharSelectMath.LIZARD_YAW)
	set_lizard(false)
	print("CharSelectStage: race table built in %.1f ms (%s)" % [(Time.get_ticks_usec() - sw) / 1000.0, ", ".join(props.keys())])

func _add_prop(key: String, path: String, pos: Vector3, yaw: float) -> void:
	var holder := Node3D.new()
	holder.name = "Prop_" + key
	holder.position = pos
	holder.rotation.y = NavGraph.godot_yaw(yaw)
	root.add_child(holder)
	var node: Node3D = null
	var bytes := _read(_data, path)
	var parsed := BsrReader.parse(bytes) if not bytes.is_empty() else null
	if parsed != null and parsed.is_character:
		var a := SkinnedBsrAssembler.assemble_from_archive(_data, path, false)
		if a != null:
			node = a.skeleton
			if key == "lizard":
				_lizard_skeleton = a.skeleton
				_lizard_assembled = a
	elif parsed != null:
		node = ObjectLoader.load_object(_data, path)
	if node == null:
		print("CharSelectStage: %s (%s) did not load" % [key, path])
		holder.queue_free()
		return
	holder.add_child(node)
	props[key] = holder
	_prop_bounds[key] = _bounds_of(node)
	print("CharSelectStage: %s %s -- %s, %d clip(s)" % [key, path, "skinned" if parsed.is_character else "static",
		parsed.animation_paths.size()])

## READ: the lizard is shown with clip 1 when the race fly ends and hidden
## again when the camera is back (vslot_012 cases 7 and 0xb). Each arrival
## starts the clip again (case 7 calls the animation setter, vslot_003, every
## time), so a second Create walks it in again.
func set_lizard(on: bool) -> void:
	if props.has("lizard"):
		(props["lizard"] as Node3D).visible = on
	_lizard_anim = _lizard_clip(CharSelectMath.LIZARD_RACE_CLIP if on else CharSelectMath.LIZARD_LIST_CLIP)
	_lizard_anim_start = _clock

## Whether the lizard's clip repeats (round 688): as the clip's own `.ban`
## says. READ (docs/protocol/BSR_FORMAT.md, "Looping" and "After a
## one-shot"): the client plays an IsCyclic clip with CRTAniCyclic and any
## other with CRTAniOneShot, which plays once, after which the bones keep
## their last pose. MEASURED (round 688, probe_ban_motion.gd):
## interface_lizard_move is NOT cyclic -- 81 keys over 2666 ms, its Bip01
## walking 4.16 units, from (7.02, 0.29, -9.96) to (3.47, 0.29, -7.79) in
## model space, exactly where interface_lizard_stand (cyclic, 15 s) holds it.
## So on arrival the lizard walks in once, from below the frame, and stops
## by the idols. Looping it (rounds 684-687) snapped it back off-screen every
## 2.67 s: the "disappears and then comes back" of the user's report.
static func lizard_clip_loops(anim: BanReader.ParsedAnimation) -> bool:
	return anim != null and anim.cyclic

func _lizard_clip(index: int) -> BanReader.ParsedAnimation:
	if _lizard_assembled == null or index >= _lizard_assembled.animation_paths.size():
		return null
	var path: String = _lizard_assembled.animation_paths[index]
	if _lizard_assembled.animation_cache.has(path):
		return _lizard_assembled.animation_cache[path]
	var bytes := _read(_data, path)
	var anim: BanReader.ParsedAnimation = BanReader.parse(bytes) if not bytes.is_empty() else null
	if anim != null and anim.bones.is_empty():
		anim = null
	_lizard_assembled.animation_cache[path] = anim
	print("CharSelectStage: lizard clip %d = %s" % [index, path])
	return anim

## The idol under a screen point: 0 Europe, 1 China (retail's pick index,
## READ vslot_012 case 8 -- the same box pick as the characters), or -1.
func pick_idol(screen: Vector2) -> int:
	var cam := camera()
	if cam == null:
		return -1
	var from := cam.project_ray_origin(screen)
	var dir := cam.project_ray_normal(screen)
	# READ, vslot_012 case 8: the loop tests both idols without stopping, so
	# where the two overlap the LAST hit -- China -- is the one kept.
	var hit := -1
	var i := 0
	for key in ["europe", "china"]:
		if props.has(key) and _ray_hits_box(from, dir, (props[key] as Node3D).get_child(0).global_transform, _prop_bounds[key]):
			hit = i
		i += 1
	return hit

## READ, vslot_012 case 7: an idol's panel hangs from the projection of the
## idol's bounding-box centre (FUN_00854eb0, turned by the idol's yaw and
## moved to its position).
func idol_anchor(index: int) -> Variant:
	var key: String = ["europe", "china"][index]
	var cam := camera()
	if not props.has(key) or cam == null:
		return null
	var node := (props[key] as Node3D).get_child(0) as Node3D
	var w: Vector3 = node.global_transform * (_prop_bounds[key] as AABB).get_center()
	if cam.is_position_behind(w):
		return null
	return cam.unproject_position(w)

# --- Each frame ------------------------------------------------------------------------

func _process(delta: float) -> void:
	_clock += delta
	for d in drawn:
		_tick(d, delta)
	if _lizard_skeleton != null and _lizard_anim != null and props.has("lizard") and (props["lizard"] as Node3D).visible:
		Skeleton3DBuilder.apply_ban_pose_at(_lizard_skeleton, _lizard_anim, _clock - _lizard_anim_start,
			lizard_clip_loops(_lizard_anim))
		_qa_lizard_probe()

## OPENSRO_QA_LIZARD_PROBE=<seconds> (OURS, QA; CharSelectQa): one line a
## frame about the lizard from its arrival, then the client quits.
var _qa_lizard_until := -1.0
func _qa_lizard_probe() -> void:
	var want := OS.get_environment("OPENSRO_QA_LIZARD_PROBE")
	if want == "" or not want.is_valid_float():
		return
	if _qa_lizard_until < 0.0:
		_qa_lizard_until = _clock + want.to_float()
	var cam := camera()
	var t := _clock - _lizard_anim_start
	var dur := _lizard_anim.duration_seconds()
	var s := CharSelectQa.lizard_sample(props["lizard"] as Node3D, cam, get_viewport().get_visible_rect().size)
	var r: Rect2 = s["rect"]
	print("QA LIZARD frame %d t=%.3f clip=%s clip_t=%.3f/%.3f meshes=%d visible=%d verts=%d inside=%d rect=(%d,%d %dx%d) cull_kept=%d/%d root=(%.2f,%.2f,%.2f)" % [
		Engine.get_frames_drawn(), t, _lizard_anim.animation_name, fposmod(t, dur) if dur > 0.0 else 0.0, dur,
		s["meshes"], s["visible"], s["verts"], s["inside"], int(r.position.x), int(r.position.y), int(r.size.x), int(r.size.y),
		s["cull_kept"], s["cull_meshes"], s["root"].x, s["root"].y, s["root"].z])
	var dir := OS.get_environment("OPENSRO_QA_SELECT_SHOT_DIR")
	var every := int(OS.get_environment("OPENSRO_QA_LIZARD_SHOT_EVERY"))
	if dir != "" and every > 0 and Engine.get_frames_drawn() % every == 0:
		get_viewport().get_texture().get_image().save_png("%s/lizard_%05d.png" % [dir, Engine.get_frames_drawn()])
	if _clock >= _qa_lizard_until:
		print("QA LIZARD done")
		get_tree().quit()

func _tick(d: Drawn, delta: float) -> void:
	if d.alpha_t < CharSelectMath.MODEL_FADE_S and not fades_paused:
		d.alpha_t = minf(d.alpha_t + delta, CharSelectMath.MODEL_FADE_S)
		d.alpha = lerpf(d.alpha_from, d.alpha_target, d.alpha_t / CharSelectMath.MODEL_FADE_S)
		_apply_alpha(d)
	if d.body == null or d.anim == null:
		return
	var t := _clock - d.anim_start
	if not d.anim_loop and t >= d.anim.duration_seconds() and d.then_type >= 0:
		_play(d, d.then_type, true)
		t = 0.0
		if d.anim == null:
			return
	d.body.pose(d.anim, t, d.anim_loop)

func _apply_alpha(d: Drawn) -> void:
	if d.body == null:
		return
	var tr := clampf(1.0 - d.alpha / 255.0, 0.0, 1.0)
	# The page shows or hides the holder (show_page); the fade the body.
	d.body.visible = d.alpha > 0.0
	var stack: Array[Node] = [d.body]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n is GeometryInstance3D:
			(n as GeometryInstance3D).transparency = tr

# --- Helpers ------------------------------------------------------------------------------

## The model's local box from its meshes' own boxes (bind pose).
static func _bounds_of(node: Node3D) -> AABB:
	var box := AABB()
	var first := true
	var inv := node.global_transform.affine_inverse() if node.is_inside_tree() else Transform3D.IDENTITY
	var stack: Array[Node] = [node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var xf := (inv * mi.global_transform) if mi.is_inside_tree() else _local_to(node, mi)
		var b := xf * mi.mesh.get_aabb()
		if first:
			box = b
			first = false
		else:
			box = box.merge(b)
	return box

static func _local_to(ancestor: Node3D, n: Node3D) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var cur: Node = n
	while cur != null and cur != ancestor:
		if cur is Node3D:
			xf = (cur as Node3D).transform * xf
		cur = cur.get_parent()
	return xf

## A ray against a box given in a node's local space (the node's transform
## carries any scale or mirror).
static func _ray_hits_box(from: Vector3, dir: Vector3, xf: Transform3D, box: AABB) -> bool:
	if box.size == Vector3.ZERO:
		return false
	var inv := xf.affine_inverse()
	var lf := inv * from
	var ld := inv.basis * dir
	return box.intersects_ray(lf, ld) != null

static func _read(archive: Pk2Reader, path: String) -> PackedByteArray:
	if archive == null:
		return PackedByteArray()
	var entry := ObjectLoader.find_file(archive, path)
	return archive.read_file(entry) if entry != null else PackedByteArray()

## Everything the screen built goes with it: the backdrop (the world and its
## regions) with the tree; the appearance's detached templates explicitly
## (round 683: they are not in the tree).
func _exit_tree() -> void:
	if appearance != null:
		appearance.free_templates()
		appearance = null

## The lighter is not in the tree (as CharCreatePreview's): freed with the stage.
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _lighter != null and is_instance_valid(_lighter):
		_lighter.free()
