extends SceneTree

## Dev tool: loads a real .o (JMXVMAPO) map-region object-placement file
## through this project's own MapoReader and renders a screenshot of every
## placed object's real world position as a colored marker (one color per
## distinct type ID), to disk. Exists to visually verify the recovered
## positions look like a real, sensible map layout, not just assert numbers
## in a unit test.
##
## Doesn't attempt to resolve type IDs to their real .bsr models -- no
## mapping from a .mapo type ID to a resource path was found anywhere in
## this project's data (see docs/protocol/MAPO_FORMAT.md), so each object
## renders as a simple colored marker sized/colored by its type ID rather
## than its real mesh.
##
## Usage (needs a real display-less GL context; run under xvfb-run):
##   LIBGL_ALWAYS_SOFTWARE=1 xvfb-run -a godot4 --path client \
##     --rendering-driver opengl3 --script res://tools/render_map_objects.gd -- \
##     --o=/path/to/Something.o [--out=/tmp/out.png]

func _arg(flag: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return ""

func _color_for_type(type_id: int) -> Color:
	# Deterministic per-type color, not meaningful beyond visual grouping.
	var h := float(type_id % 360) / 360.0
	return Color.from_hsv(h, 0.75, 0.95)

func _init() -> void:
	var o_path := _arg("--o")
	var out_path := _arg("--out")
	if out_path == "":
		out_path = "/tmp/render_map_objects.png"
	if o_path == "":
		printerr("usage: --o=<path> [--out=<png-path>]")
		quit(1)
		return

	var f := FileAccess.open(o_path, FileAccess.READ)
	if f == null:
		printerr("could not open ", o_path)
		quit(1)
		return
	var data := f.get_buffer(f.get_length())
	var region := MapoReader.parse(data)
	if region == null:
		printerr("failed to parse region")
		quit(1)
		return
	print("region: version=%s objects=%d" % [region.version, region.objects.size()])

	var root := get_root()
	var world := Node3D.new()
	root.add_child(world)

	var min_pos := Vector3.INF
	var max_pos := -Vector3.INF
	for o in region.objects:
		min_pos = Vector3(min(min_pos.x, o.position.x), min(min_pos.y, o.position.y), min(min_pos.z, o.position.z))
		max_pos = Vector3(max(max_pos.x, o.position.x), max(max_pos.y, o.position.y), max(max_pos.z, o.position.z))

	var extent := (max_pos - min_pos).length()
	if extent < 1.0:
		extent = 100.0
	var marker_radius: float = clamp(extent * 0.006, 1.0, 20.0)

	var marker_mesh := SphereMesh.new()
	marker_mesh.radius = marker_radius
	marker_mesh.height = marker_radius * 2.0

	var type_mats := {}
	for o in region.objects:
		if not type_mats.has(o.type_id):
			var mat := StandardMaterial3D.new()
			mat.albedo_color = _color_for_type(o.type_id)
			type_mats[o.type_id] = mat
		var marker := MeshInstance3D.new()
		marker.mesh = marker_mesh
		marker.material_override = type_mats[o.type_id]
		marker.position = o.position
		world.add_child(marker)

	var center := (min_pos + max_pos) / 2.0

	var cam := Camera3D.new()
	var cam_pos := center + Vector3(0, extent * 0.9, 0.001)
	cam.transform = Transform3D.IDENTITY.looking_at((center - cam_pos).normalized(), Vector3.FORWARD)
	cam.position = cam_pos
	cam.far = extent * 10.0
	world.add_child(cam)
	cam.make_current()

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-90, 0, 0)
	world.add_child(light)

	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.1, 0.1, 0.12)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.7, 0.7, 0.7)
	env_node.environment = env
	world.add_child(env_node)

	await process_frame
	await process_frame
	await process_frame

	var img := root.get_texture().get_image()
	img.save_png(out_path)
	print("saved to ", out_path)
	quit(0)
