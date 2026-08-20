extends SceneTree

## Dev tool: loads a real .bsk skeleton and a real .ban animation, applies
## the animation's rotation delta (relative to its own first keyframe) to
## one bone and every one of its descendants via simple forward
## kinematics, and renders two screenshots (bind pose vs. animated pose) so
## the movement is visible as a before/after comparison. Proves keyframe
## data actually drives real bone positions, not just that it parses.
##
## The .ban and .bsk samples used aren't necessarily authored for the same
## character/skeleton -- this demonstrates the playback mechanism against
## real keyframe data landing on a real bone name match ("Bone01"), not a
## claim that this specific animation belongs to this specific skeleton.
##
## Usage:
##   LIBGL_ALWAYS_SOFTWARE=1 xvfb-run -a godot4 --path client \
##     --rendering-driver opengl3 --script res://tools/render_skeleton_animated.gd -- \
##     --bsk=/path/to/Something.bsk --ban=/path/to/Something.ban \
##     --bone=Bone01 [--frame=50] [--out-prefix=/tmp/anim]

func _arg(flag: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return ""

func _render(root: Window, positions: Dictionary, skel: BskReader.ParsedSkeleton, out_path: String) -> void:
	var world := Node3D.new()
	root.add_child(world)

	var joint_mesh := SphereMesh.new()
	joint_mesh.radius = 6.0
	joint_mesh.height = 12.0
	var joint_mat := StandardMaterial3D.new()
	joint_mat.albedo_color = Color(1, 0.8, 0.2)
	var bone_mat := StandardMaterial3D.new()
	bone_mat.albedo_color = Color(0.3, 0.7, 1.0)

	var min_pos := Vector3.INF
	var max_pos := -Vector3.INF

	for b in skel.bones:
		var pos: Vector3 = positions[b.bone_name]
		min_pos = Vector3(min(min_pos.x, pos.x), min(min_pos.y, pos.y), min(min_pos.z, pos.z))
		max_pos = Vector3(max(max_pos.x, pos.x), max(max_pos.y, pos.y), max(max_pos.z, pos.z))

		var joint := MeshInstance3D.new()
		joint.mesh = joint_mesh
		joint.material_override = joint_mat
		joint.position = pos
		world.add_child(joint)

		if b.parent_name != "" and positions.has(b.parent_name):
			var parent_pos: Vector3 = positions[b.parent_name]
			var seg := parent_pos - pos
			var length := seg.length()
			if length > 0.01:
				var cyl := CylinderMesh.new()
				cyl.top_radius = 3.0
				cyl.bottom_radius = 3.0
				cyl.height = length
				var bone_instance := MeshInstance3D.new()
				bone_instance.mesh = cyl
				bone_instance.material_override = bone_mat
				bone_instance.position = (pos + parent_pos) / 2.0
				if seg.normalized().is_equal_approx(Vector3.UP) or seg.normalized().is_equal_approx(-Vector3.UP):
					bone_instance.transform.basis = Basis.IDENTITY
				else:
					bone_instance.transform.basis = Basis.IDENTITY.looking_at(seg.normalized(), Vector3.UP) * Basis(Vector3.RIGHT, deg_to_rad(90))
				world.add_child(bone_instance)

	var center := (min_pos + max_pos) / 2.0
	var extent := (max_pos - min_pos).length()
	if extent < 1.0:
		extent = 100.0

	var cam := Camera3D.new()
	var cam_pos := center + Vector3(extent * 0.7, extent * 0.5, extent * 0.9)
	cam.transform = Transform3D.IDENTITY.looking_at((center - cam_pos).normalized(), Vector3.UP)
	cam.position = cam_pos
	cam.far = extent * 10.0
	world.add_child(cam)
	cam.make_current()

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, -45, 0)
	world.add_child(light)

	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.15, 0.15, 0.18)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.6, 0.6, 0.6)
	env_node.environment = env
	world.add_child(env_node)

	await process_frame
	await process_frame
	await process_frame

	var img := root.get_texture().get_image()
	img.save_png(out_path)
	print("saved to ", out_path)

	world.queue_free()
	await process_frame

func _init() -> void:
	var bsk_path := _arg("--bsk")
	var ban_path := _arg("--ban")
	var bone_name := _arg("--bone")
	var frame_str := _arg("--frame")
	var out_prefix := _arg("--out-prefix")
	if out_prefix == "":
		out_prefix = "/tmp/render_skeleton_animated"
	var frame_idx := 50 if frame_str == "" else int(frame_str)

	if bsk_path == "" or ban_path == "" or bone_name == "":
		printerr("usage: --bsk=<path> --ban=<path> --bone=<name> [--frame=N] [--out-prefix=<path>]")
		quit(1)
		return

	var bsk_file := FileAccess.open(bsk_path, FileAccess.READ)
	var skel := BskReader.parse(bsk_file.get_buffer(bsk_file.get_length()))
	if skel == null:
		printerr("failed to parse skeleton")
		quit(1)
		return

	var ban_file := FileAccess.open(ban_path, FileAccess.READ)
	var anim := BanReader.parse(ban_file.get_buffer(ban_file.get_length()))
	if anim == null:
		printerr("failed to parse animation")
		quit(1)
		return

	var track: BanReader.Bone = null
	for b in anim.bones:
		if b.bone_name == bone_name:
			track = b
			break
	if track == null:
		printerr("animation has no track for bone ", bone_name)
		quit(1)
		return
	frame_idx = clampi(frame_idx, 0, track.keyframes.size() - 1)
	print("animation: %s, bone %s has %d keyframes, using frame %d" % [anim.animation_name, bone_name, track.keyframes.size(), frame_idx])

	var rest_rot: Quaternion = track.keyframes[0].rotation
	var target_rot: Quaternion = track.keyframes[frame_idx].rotation
	var delta: Quaternion = target_rot * rest_rot.inverse()
	print("rest rotation: ", rest_rot, " target rotation: ", target_rot, " delta angle (deg): ", rad_to_deg(delta.get_angle()))

	var bind_positions := SkeletonPose.bind_positions(skel)
	if not bind_positions.has(bone_name):
		printerr("skeleton has no bone named ", bone_name)
		quit(1)
		return

	var animated_positions := SkeletonPose.apply_rotation(skel, bind_positions, bone_name, delta)

	var root := get_root()
	await _render(root, bind_positions, skel, out_prefix + "_bind.png")
	await _render(root, animated_positions, skel, out_prefix + "_animated.png")
	quit(0)
