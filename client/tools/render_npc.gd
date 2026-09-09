extends SceneTree

## Dev tool: assembles a character-category `.bsr` (an NPC, a monster, or
## the player's own body) straight out of an archive and renders it, so
## "does this read as a person standing up?" has a picture behind it.
##
## Everything comes from the one `.bsr` path: SkinnedBsrAssembler reads the
## file's own skeleton, mesh pieces and materials through the header's
## section table. Nothing is supplied from outside.
##
## Usage (needs a real GL context; run under xvfb-run, no --headless):
##   xvfb-run -a vglrun -d egl0 godot4 --path client --rendering-driver opengl3 \
##     --script res://tools/render_npc.gd -- \
##     --pk2=/path/Data.pk2 --model="npc\\npc\\chinaquest_priest.bsr" \
##     [--out=/var/tmp/npc.png]

func _arg(flag: String, fallback: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return fallback

func _initialize() -> void:
	var pk2_path := _arg("--pk2")
	var model := _arg("--model")
	var out_path := _arg("--out", "/var/tmp/render_npc.png")
	if pk2_path == "" or model == "":
		printerr("usage: --pk2=<Data.pk2> --model=<path\\inside.bsr> [--out=<png>]")
		quit(2)
		return

	var archive := Pk2Reader.open(pk2_path)
	if archive == null:
		printerr("could not open ", pk2_path)
		quit(1)
		return

	var assembled := SkinnedBsrAssembler.assemble_from_archive(archive, model, true)
	if assembled == null:
		printerr("could not assemble ", model)
		quit(1)
		return

	var skeleton := assembled.skeleton
	print("%s: %d bones, %d piece(s) (%d skinned), %d animation(s)" % [
		model.get_file(), skeleton.get_bone_count(),
		assembled.piece_bones.size(), assembled.skinned_pieces,
		assembled.animation_paths.size()])

	# Pose it, so the picture shows the skin actually deforming rather than
	# the bind pose it would sit in regardless.
	var frame := int(_arg("--frame", "0"))
	if assembled.idle_animation != null and frame > 0:
		Skeleton3DBuilder.apply_ban_pose(skeleton, assembled.idle_animation, frame)
		print("   posed at animation frame %d" % frame)
	for piece in assembled.piece_bones:
		print("   %-34s -> %-18s d=%.2f" % [
			piece, assembled.piece_bones[piece], assembled.piece_distances[piece]])

	var root := get_root()
	var world := Node3D.new()
	root.add_child(world)
	world.add_child(skeleton)

	# Nodes are only given a global transform once they are actually in the
	# tree, and _initialize() runs before that has settled -- reading
	# global_transform straight after add_child() returns identity and
	# prints "!is_inside_tree()".
	await process_frame

	# Frame the camera on the assembled geometry rather than on the bones:
	# a piece can reach well past the bone it hangs from, and it is the
	# geometry the picture is meant to show.
	var bounds := AABB()
	var seeded := false
	var stack: Array[Node] = [skeleton]
	while not stack.is_empty():
		var current: Node = stack.pop_back()
		if current is MeshInstance3D and (current as MeshInstance3D).mesh != null:
			var mi := current as MeshInstance3D
			var box: AABB = mi.global_transform * mi.get_aabb()
			if seeded:
				bounds = bounds.merge(box)
			else:
				bounds = box
				seeded = true
		for child in current.get_children():
			stack.append(child)
	if not seeded:
		printerr("assembled ", model, " has no drawable geometry")
		quit(1)
		return
	print("   bounds size %s centre %s" % [bounds.size.round(), bounds.get_center().round()])

	var extent: float = maxf(bounds.size.length(), 1.0)
	var centre := bounds.get_center()
	var cam := Camera3D.new()
	var cam_pos := centre + Vector3(extent * 0.55, extent * 0.12, extent * 0.95)
	cam.position = cam_pos
	cam.look_at_from_position(cam_pos, centre, Vector3.UP)
	cam.far = extent * 20.0
	cam.current = true
	world.add_child(cam)

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-38, -40, 0)
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
