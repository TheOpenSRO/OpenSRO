extends SceneTree

## Dev tool: loads a real .bsk skeleton and a real .ban animation, builds a
## real Godot Skeleton3D via Skeleton3DBuilder, applies the animation's
## rotation (relative to its own first keyframe) to one named bone via the
## engine's own pose-rotation propagation, and renders bind-pose vs.
## animated-pose screenshots -- the Skeleton3D-backed counterpart to
## render_skeleton_animated.gd's manual forward-kinematics version.
##
## Usage (needs a real display-less GL context; run under xvfb-run):
##   LIBGL_ALWAYS_SOFTWARE=1 xvfb-run -a godot4 --path client \
##     --rendering-driver opengl3 --script res://tools/render_skeleton3d_animated.gd -- \
##     --bsk=/path/to/Something.bsk --ban=/path/to/Something.ban --bone="Bone Name" \
##     [--frame=1] [--out-prefix=/tmp/out]

func _arg(flag: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return ""

func _render_pose(root: Window, skeleton: Skeleton3D, out_path: String) -> void:
	var world := Node3D.new()
	root.add_child(world)
	world.add_child(skeleton)

	var joint_mesh := SphereMesh.new()
	var bone_mat := StandardMaterial3D.new()
	bone_mat.albedo_color = Color(1, 0.8, 0.2)

	var min_pos := Vector3.INF
	var max_pos := -Vector3.INF
	for i in range(skeleton.get_bone_count()):
		var pos: Vector3 = skeleton.get_bone_global_pose(i).origin
		min_pos = Vector3(min(min_pos.x, pos.x), min(min_pos.y, pos.y), min(min_pos.z, pos.z))
		max_pos = Vector3(max(max_pos.x, pos.x), max(max_pos.y, pos.y), max(max_pos.z, pos.z))

	var extent := (max_pos - min_pos).length()
	if extent < 1.0:
		extent = 100.0
	var joint_radius: float = clamp(extent * 0.015, 0.5, 6.0)
	joint_mesh.radius = joint_radius
	joint_mesh.height = joint_radius * 2.0

	for i in range(skeleton.get_bone_count()):
		var pos: Vector3 = skeleton.get_bone_global_pose(i).origin
		var joint := MeshInstance3D.new()
		joint.mesh = joint_mesh
		joint.material_override = bone_mat
		joint.position = pos
		world.add_child(joint)

		var parent_idx := skeleton.get_bone_parent(i)
		if parent_idx != -1:
			var parent_pos: Vector3 = skeleton.get_bone_global_pose(parent_idx).origin
			var seg := parent_pos - pos
			var length := seg.length()
			if length > 0.01:
				var cyl := CylinderMesh.new()
				cyl.top_radius = joint_radius * 0.5
				cyl.bottom_radius = joint_radius * 0.5
				cyl.height = length
				var bone_instance := MeshInstance3D.new()
				bone_instance.mesh = cyl
				bone_instance.material_override = bone_mat
				bone_instance.position = (pos + parent_pos) / 2.0
				if not seg.normalized().is_equal_approx(Vector3.UP):
					bone_instance.transform.basis = Basis.IDENTITY.looking_at(seg.normalized(), Vector3.UP) \
						* Basis(Vector3.RIGHT, deg_to_rad(90))
				world.add_child(bone_instance)

	var center := (min_pos + max_pos) / 2.0
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

func _init() -> void:
	var bsk_path := _arg("--bsk")
	var ban_path := _arg("--ban")
	var bone_name := _arg("--bone")
	var frame := int(_arg("--frame")) if _arg("--frame") != "" else 1
	var out_prefix := _arg("--out-prefix")
	if out_prefix == "":
		out_prefix = "/tmp/render_skeleton3d_animated"
	if bsk_path == "" or ban_path == "" or bone_name == "":
		printerr("usage: --bsk=<path> --ban=<path> --bone=\"<name>\" [--frame=1] [--out-prefix=<path>]")
		quit(1)
		return

	var bsk_file := FileAccess.open(bsk_path, FileAccess.READ)
	var ban_file := FileAccess.open(ban_path, FileAccess.READ)
	if bsk_file == null or ban_file == null:
		printerr("could not open input files")
		quit(1)
		return

	var skel := BskReader.parse(bsk_file.get_buffer(bsk_file.get_length()))
	var anim := BanReader.parse(ban_file.get_buffer(ban_file.get_length()))
	if skel == null or anim == null:
		printerr("failed to parse .bsk/.ban")
		quit(1)
		return
	print("skeleton: root=%s bones=%d" % [skel.root_name, skel.bones.size()])
	print("animation: name=%s tracks=%d" % [anim.animation_name, anim.bones.size()])

	var track: BanReader.Bone = null
	for t in anim.bones:
		if t.bone_name == bone_name:
			track = t
			break
	if track == null:
		printerr("no .ban track named ", bone_name)
		quit(1)
		return

	var root := get_root()

	var bind_skeleton := Skeleton3DBuilder.build_skeleton3d(skel)
	await _render_pose(root, bind_skeleton, out_prefix + "_bind.png")

	var animated_skeleton := Skeleton3DBuilder.build_skeleton3d(skel)
	Skeleton3DBuilder.apply_ban_keyframe(animated_skeleton, track, frame)
	await _render_pose(root, animated_skeleton, out_prefix + "_animated.png")

	quit(0)
