extends SceneTree

## Dev tool: loads a real .bsk skeleton through this project's own BskReader
## and renders a screenshot of its bone hierarchy (a line segment per
## bone-to-parent connection, a small sphere at each joint) to disk. Exists
## to visually verify the skeleton hierarchy/position data looks like a
## real, sensible skeleton shape, not just assert numbers in a unit test.
##
## Position field offset within each bone's raw transform bytes: 0x2c for
## an ordinary (88-byte) bone, 0x30 for a root-attached (92-byte) bone --
## see docs/protocol/BSK_FORMAT.md for how that 4-byte shift was confirmed.
##
## Usage (needs a real display-less GL context; run under xvfb-run):
##   LIBGL_ALWAYS_SOFTWARE=1 xvfb-run -a godot4 --path client \
##     --rendering-driver opengl3 --script res://tools/render_skeleton.gd -- \
##     --bsk=/path/to/Something.bsk [--out=/tmp/out.png]

func _arg(flag: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return ""

func _init() -> void:
	var bsk_path := _arg("--bsk")
	var out_path := _arg("--out")
	if out_path == "":
		out_path = "/tmp/render_skeleton.png"
	if bsk_path == "":
		printerr("usage: --bsk=<path> [--out=<png-path>]")
		quit(1)
		return

	var f := FileAccess.open(bsk_path, FileAccess.READ)
	if f == null:
		printerr("could not open ", bsk_path)
		quit(1)
		return
	var data := f.get_buffer(f.get_length())
	var skel := BskReader.parse(data)
	if skel == null:
		printerr("failed to parse skeleton")
		quit(1)
		return
	print("skeleton: root=%s bones=%d" % [skel.root_name, skel.bones.size()])

	var positions := SkeletonPose.bind_positions(skel)

	var root := get_root()
	var world := Node3D.new()
	root.add_child(world)

	var min_pos := Vector3.INF
	var max_pos := -Vector3.INF
	var shortest_bone := INF

	for b in skel.bones:
		var pos: Vector3 = positions[b.bone_name]
		min_pos = Vector3(min(min_pos.x, pos.x), min(min_pos.y, pos.y), min(min_pos.z, pos.z))
		max_pos = Vector3(max(max_pos.x, pos.x), max(max_pos.y, pos.y), max(max_pos.z, pos.z))
		if b.parent_name != "" and positions.has(b.parent_name):
			var seg_len: float = (pos - positions[b.parent_name]).length()
			if seg_len > 0.01 and seg_len < shortest_bone:
				shortest_bone = seg_len

	# Scale the joint sphere to the skeleton's own bone spacing instead of a
	# fixed size -- a fixed radius tuned for one skeleton fuses into a solid
	# blob on another with much tighter bone spacing (e.g. face/hand bones).
	if not is_finite(shortest_bone):
		shortest_bone = 12.0
	var joint_radius: float = clamp(shortest_bone * 0.35, 0.5, 6.0)

	var joint_mesh := SphereMesh.new()
	joint_mesh.radius = joint_radius
	joint_mesh.height = joint_radius * 2.0
	var joint_mat := StandardMaterial3D.new()
	joint_mat.albedo_color = Color(1, 0.8, 0.2)

	var bone_mat := StandardMaterial3D.new()
	bone_mat.albedo_color = Color(0.3, 0.7, 1.0)

	for b in skel.bones:
		var pos: Vector3 = positions[b.bone_name]

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
				cyl.top_radius = joint_radius * 0.5
				cyl.bottom_radius = joint_radius * 0.5
				cyl.height = length
				var bone_instance := MeshInstance3D.new()
				bone_instance.mesh = cyl
				bone_instance.material_override = bone_mat
				bone_instance.position = (pos + parent_pos) / 2.0
				bone_instance.transform.basis = Basis.IDENTITY.looking_at(seg.normalized(), Vector3.UP) \
					* Basis(Vector3.RIGHT, deg_to_rad(90))
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
	quit(0)
