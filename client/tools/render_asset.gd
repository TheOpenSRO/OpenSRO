extends SceneTree

## Dev tool: loads a real mesh + real texture out of a real pk2 archive
## (never bundled, never committed) through this project's own readers, and
## renders a screenshot to disk. Exists to make "does this actually look
## right against real data" a repeatable check instead of a one-off script.
##
## Usage (needs a real display-less GL context; run under xvfb-run):
##   LIBGL_ALWAYS_SOFTWARE=1 xvfb-run -a godot4 --path client \
##     --rendering-driver opengl3 --script res://tools/render_asset.gd -- \
##     --pk2=/path/to/Something.pk2 --mesh=meshes/foo.bms \
##     [--tex=textures/foo.ddj] [--out=/tmp/out.png]
##
## --pk2 and --mesh are required. --tex is optional (renders untextured if
## omitted or if the texture can't be loaded). Paths inside the archive use
## forward or back slashes, matching the archive's own directory names
## case-insensitively (see ObjectLoader._find_file).

func _arg(flag: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return ""

func _find_file(archive: Pk2Reader, path: String) -> Pk2Reader.Entry:
	var parts := path.replace("\\", "/").split("/")
	var entries := archive.read_dir()
	for i in range(parts.size()):
		var part := parts[i]
		var found: Pk2Reader.Entry = null
		for e in entries:
			if e.name.to_lower() == part.to_lower():
				found = e
				break
		if found == null:
			return null
		if i == parts.size() - 1:
			return found
		if not found.is_dir:
			return null
		entries = archive.read_dir_at(found)
	return null

func _init() -> void:
	var pk2_path := _arg("--pk2")
	var mesh_path := _arg("--mesh")
	var tex_path := _arg("--tex")
	var out_path := _arg("--out")
	if out_path == "":
		out_path = "/tmp/render_asset.png"

	if pk2_path == "" or mesh_path == "":
		printerr("usage: --pk2=<path> --mesh=<archive-path> [--tex=<archive-path>] [--out=<png-path>]")
		quit(1)
		return

	var archive := Pk2Reader.open(pk2_path)
	if archive == null:
		printerr("could not open ", pk2_path)
		quit(1)
		return

	var mesh_entry := _find_file(archive, mesh_path)
	if mesh_entry == null:
		printerr("mesh not found in archive: ", mesh_path)
		quit(1)
		return
	var parsed_mesh := BmsReader.parse(archive.read_file(mesh_entry))
	if parsed_mesh == null:
		printerr("failed to parse mesh: ", mesh_path)
		quit(1)
		return
	print("mesh: %d vertices, bounds %s .. %s" % [parsed_mesh.vertices.size(), parsed_mesh.bounds_min, parsed_mesh.bounds_max])

	var godot_tex: ImageTexture = null
	if tex_path != "":
		var tex_entry := _find_file(archive, tex_path)
		if tex_entry == null:
			printerr("texture not found in archive (rendering untextured): ", tex_path)
		else:
			var parsed_tex := DdjReader.parse(archive.read_file(tex_entry))
			if parsed_tex != null:
				print("texture: %dx%d %s" % [parsed_tex.width, parsed_tex.height, parsed_tex.four_cc if parsed_tex.four_cc != "" else "(uncompressed)"])
				godot_tex = DdjReader.to_texture(parsed_tex)

	var root := get_root()
	var world := Node3D.new()
	root.add_child(world)

	var instance := MeshInstance3D.new()
	instance.mesh = BmsReader.to_array_mesh(parsed_mesh)
	var mat := StandardMaterial3D.new()
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	if godot_tex != null:
		mat.albedo_texture = godot_tex
	instance.material_override = mat
	world.add_child(instance)

	var center := (parsed_mesh.bounds_min + parsed_mesh.bounds_max) / 2.0
	var extent := (parsed_mesh.bounds_max - parsed_mesh.bounds_min).length()
	if extent < 0.1:
		extent = 10.0

	var cam := Camera3D.new()
	var cam_pos := center + Vector3(extent, extent * 0.8, extent)
	cam.transform = Transform3D.IDENTITY.looking_at((center - cam_pos).normalized(), Vector3.UP)
	cam.position = cam_pos
	world.add_child(cam)
	cam.make_current()

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, -45, 0)
	world.add_child(light)

	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.2, 0.2, 0.25)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.5, 0.5, 0.5)
	env_node.environment = env
	world.add_child(env_node)

	await process_frame
	await process_frame
	await process_frame

	var img := root.get_texture().get_image()
	img.save_png(out_path)
	print("saved to ", out_path)
	archive.close()
	quit(0)
