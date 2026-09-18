extends SceneTree

## Dev tool: assembles SEVERAL dressed characters and lines them up in one
## render, so the range of real equipment coming out of the archives shows in a
## single image instead of one boot per outfit.
##
## Each character is "BODY_CODE|item.bsr,item.bsr,.." (body codes resolve
## through Media.pk2's character table the same way World3D does); characters
## are laid along +X, spaced by their own width, and the camera frames them all.
## Everything -- bodies, worn meshes, materials, textures -- comes from the
## archives; nothing is extracted.
##
## Usage (needs a real GL context; run under xvfb-run + vglrun, no --headless):
##   xvfb-run -a vglrun -d egl0 godot4 --path client --rendering-driver opengl3 \
##     --resolution 1600x900 --script res://tools/render_lineup.gd -- \
##     --pk2=/opt/sro-files/client/Data.pk2 --media=/opt/sro-files/client/Media.pk2 \
##     --chars="CHAR_CH_MAN_FIGHTER|item\china\weapon\sword_01.bsr; CHAR_CH_WOMAN_FIGHTER|..." \
##     [--out=/var/tmp/lineup.png]

func _arg(flag: String, fallback: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return fallback

func _initialize() -> void:
	var pk2_path := _arg("--pk2")
	var media_path := _arg("--media")
	var chars_arg := _arg("--chars")
	var out_path := _arg("--out", "/var/tmp/render_lineup.png")
	if pk2_path == "" or media_path == "" or chars_arg == "":
		printerr("usage: --pk2=<Data.pk2> --media=<Media.pk2> --chars=\"CODE|a.bsr,b.bsr; CODE|..\" [--out=<png>]")
		quit(2)
		return

	var data := Pk2Reader.open(pk2_path)
	var media := Pk2Reader.open(media_path)
	if data == null or media == null:
		printerr("could not open archives")
		quit(1)
		return

	# Body code -> .bsr, resolved from Media's character table (as World3D does).
	var bodies := {}
	for path in NpcTableReader.MODEL_TABLE_PATHS:
		var entry := ObjectLoader.find_file(media, path)
		if entry != null:
			bodies = NpcTableReader.parse_models_by_code(media.read_file(entry), bodies)

	var root := get_root()
	var world := Node3D.new()
	root.add_child(world)

	var placed := 0
	var cursor_x := 0.0
	var bounds := AABB()
	var seeded := false
	for spec in chars_arg.split(";", false):
		var parts: PackedStringArray = String(spec).strip_edges().split("|")
		var code: String = parts[0].strip_edges()
		var body_path: String = bodies.get(code, "")
		if body_path == "":
			printerr("no body row for code ", code)
			continue
		var assembled := SkinnedBsrAssembler.assemble_from_archive(data, body_path, false)
		if assembled == null:
			printerr("could not assemble ", body_path)
			continue
		var skeleton := assembled.skeleton
		var worn := 0
		if parts.size() > 1:
			for item_path in String(parts[1]).split(",", false):
				var item_str := String(item_path).strip_edges()
				if item_str == "":
					continue
				var att := SkinnedBsrAssembler.attach_item_from_archive(data, skeleton, item_str)
				if att != null:
					worn += 1
					# --gizmo: draw the own-skeleton item node's axes (red X,
					# green Y, blue Z, 5 long) so a render shows where the
					# node's frame is against where the mesh actually draws.
					if _arg("--gizmo") != "" and att.attach_bone != "":
						var item_node := att.node.get_child(0) as Node3D
						if item_node != null:
							item_node.add_child(_axes_gizmo(5.0))
							print("   gizmo on %s (item node under '%s')" % [item_str.get_file(), att.attach_bone])
		# Measure this character's own width so the next one clears its arms.
		var own := _skel_bounds(skeleton)
		skeleton.position = Vector3(cursor_x - own.get_center().x, 0.0, 0.0)
		world.add_child(skeleton)
		var placed_box: AABB = own
		placed_box.position += skeleton.position
		bounds = placed_box if not seeded else bounds.merge(placed_box)
		seeded = true
		cursor_x += own.size.x + 6.0
		placed += 1
		print("%-24s -> %s : %d worn" % [code, body_path.get_file(), worn])

	if not seeded:
		printerr("nothing assembled")
		quit(1)
		return
	print("lineup of %d, bounds size %s centre %s" % [placed, bounds.size.round(), bounds.get_center().round()])
	await process_frame

	var centre := bounds.get_center()
	var cam := Camera3D.new()
	# Straight-on front. A wide row at 16:9 is width-bound, not diagonal-bound,
	# so distance follows the row's width (with a small margin) -- pulling back
	# by the diagonal left the figures tiny in a sea of background.
	var dist := maxf(bounds.size.x, bounds.size.y * 1.4) * 0.52
	var cam_pos := centre + Vector3(0.0, bounds.size.y * 0.10, -dist)
	cam.position = cam_pos
	cam.look_at_from_position(cam_pos, centre, Vector3.UP)
	cam.far = dist * 40.0
	cam.current = true
	world.add_child(cam)

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-35, 155, 0)
	world.add_child(key)

	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.16, 0.17, 0.21)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.62, 0.62, 0.66)
	env_node.environment = env
	world.add_child(env_node)

	for _i in range(4):
		await process_frame
	get_root().get_texture().get_image().save_png(out_path)
	print("saved to ", out_path)
	quit(0)

## Three coloured axis lines from the origin: red +X, green +Y, blue +Z.
func _axes_gizmo(length: float) -> MeshInstance3D:
	var im := ImmediateMesh.new()
	for axis in [[Vector3.RIGHT, Color.RED], [Vector3.UP, Color.GREEN], [Vector3.BACK, Color.BLUE]]:
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = axis[1]
		im.surface_begin(Mesh.PRIMITIVE_LINES, mat)
		im.surface_add_vertex(Vector3.ZERO)
		im.surface_add_vertex((axis[0] as Vector3) * length)
		im.surface_end()
	var mi := MeshInstance3D.new()
	mi.mesh = im
	return mi

## Combined AABB of every drawable mesh under a skeleton, in skeleton-local
## space (skinned MeshInstances sit at identity under the skeleton).
func _skel_bounds(skeleton: Skeleton3D) -> AABB:
	var box := AABB()
	var seeded := false
	var stack: Array[Node] = [skeleton]
	while not stack.is_empty():
		var current: Node = stack.pop_back()
		if current is MeshInstance3D and (current as MeshInstance3D).mesh != null:
			var mi := current as MeshInstance3D
			var b: AABB = mi.transform * mi.mesh.get_aabb()
			box = b if not seeded else box.merge(b)
			seeded = true
		for child in current.get_children():
			stack.append(child)
	return box
