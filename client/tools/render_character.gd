extends SceneTree

## Dev tool: loads a real .bsk skeleton and a directory of real body-part
## .bms meshes (loose files, e.g. man_thigh.bms, man_torso_upper.bms --
## real samples so far have only been found this way, not inside a pk2),
## assembles them via CharacterAssembler, and renders a screenshot. Exists
## to visually verify real body-part meshes actually land in the right
## place on a real skeleton, not just assert offsets in a unit test.
##
## Usage (needs a real display-less GL context; run under xvfb-run):
##   LIBGL_ALWAYS_SOFTWARE=1 xvfb-run -a godot4 --path client \
##     --rendering-driver opengl3 --script res://tools/render_character.gd -- \
##     --bsk=/path/to/chinaman_skel.bsk --parts-dir=/path/to/dir/with/man_*.bms \
##     [--out=/tmp/out.png]

func _arg(flag: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return ""

func _init() -> void:
	var bsk_path := _arg("--bsk")
	var parts_dir := _arg("--parts-dir")
	var out_path := _arg("--out")
	if out_path == "":
		out_path = "/tmp/render_character.png"
	if bsk_path == "" or parts_dir == "":
		printerr("usage: --bsk=<path> --parts-dir=<dir> [--out=<png-path>]")
		quit(1)
		return

	var bsk_file := FileAccess.open(bsk_path, FileAccess.READ)
	if bsk_file == null:
		printerr("could not open ", bsk_path)
		quit(1)
		return
	var skel := BskReader.parse(bsk_file.get_buffer(bsk_file.get_length()))
	if skel == null:
		printerr("failed to parse skeleton")
		quit(1)
		return
	print("skeleton: root=%s bones=%d" % [skel.root_name, skel.bones.size()])

	var skeleton := Skeleton3DBuilder.build_skeleton3d(skel)

	var parts := {}
	var dir := DirAccess.open(parts_dir)
	if dir == null:
		printerr("could not open ", parts_dir)
		quit(1)
		return
	for fn in dir.get_files():
		if not fn.ends_with(".bms"):
			continue
		var f := FileAccess.open(parts_dir + "/" + fn, FileAccess.READ)
		var mesh := BmsReader.parse(f.get_buffer(f.get_length()))
		if mesh == null:
			printerr("failed to parse ", fn)
			continue
		parts[fn.get_basename()] = mesh
		print("loaded part: ", fn, " (", mesh.vertices.size(), " verts)")

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.85, 0.7, 0.55)
	CharacterAssembler.assemble(skeleton, parts, mat)

	var root := get_root()
	var world := Node3D.new()
	root.add_child(world)
	world.add_child(skeleton)

	var min_pos := Vector3.INF
	var max_pos := -Vector3.INF
	for i in range(skeleton.get_bone_count()):
		var pos: Vector3 = skeleton.get_bone_global_pose(i).origin
		min_pos = Vector3(min(min_pos.x, pos.x), min(min_pos.y, pos.y), min(min_pos.z, pos.z))
		max_pos = Vector3(max(max_pos.x, pos.x), max(max_pos.y, pos.y), max(max_pos.z, pos.z))
	var extent := (max_pos - min_pos).length()
	if extent < 1.0:
		extent = 20.0
	var center := (min_pos + max_pos) / 2.0

	var cam := Camera3D.new()
	var cam_pos := center + Vector3(extent * 0.8, extent * 0.2, extent * 1.2)
	cam.transform = Transform3D.IDENTITY.looking_at((center - cam_pos).normalized(), Vector3.UP)
	cam.position = cam_pos
	cam.far = extent * 10.0
	cam.current = true
	world.add_child(cam)

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
