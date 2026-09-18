extends SceneTree

## Dev tool: assembles a character body `.bsr` and DRESSES it with one or more
## equipment item `.bsr` files, then renders the result -- so "does the worn gear
## attach to the body and texture correctly?" has a picture behind it.
##
## The body comes from SkinnedBsrAssembler.assemble_from_archive; each item is
## hung on the body's skeleton by SkinnedBsrAssembler.attach_item_from_archive,
## the same call World3D uses to dress the player from the server's equipment
## list. Everything (skeleton, meshes, materials, textures) comes out of the
## one archive.
##
## Usage (needs a real GL context; run under xvfb-run, no --headless):
##   xvfb-run -a vglrun -d egl0 godot4 --path client --rendering-driver opengl3 \
##     --script res://tools/render_dressed_character.gd -- \
##     --pk2=/path/Data.pk2 --body="Res\\Char\\China\\chinaman_fighter.bsr" \
##     --items="Res\\Item\\China\\MAN_ITEM\\clothes_01_ba.bsr,Res\\Item\\China\\MAN_ITEM\\clothes_01_la.bsr" \
##     [--pose=<seconds>] [--group=sword] [--ban=<explicit .ban>] [--out=/var/tmp/dressed.png]
##
## --pose applies the body's real standing idle (the type-0 entry of the
## named animation group; `chinaman_fighter_standcity.ban` for `sword`) at
## that many seconds in, through the same Skeleton3DBuilder.apply_ban_pose_at
## the world runs every frame -- so a rig question is answered here in one
## ~40 s run instead of a world boot. Without it the body is in its rest
## pose (arms out). tools/probe_skinning.gd gives the same pose as numbers.

func _arg(flag: String, fallback: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return fallback

func _initialize() -> void:
	var pk2_path := _arg("--pk2")
	var body := _arg("--body")
	var items_arg := _arg("--items")
	var out_path := _arg("--out", "/var/tmp/render_dressed.png")
	if pk2_path == "" or body == "":
		printerr("usage: --pk2=<Data.pk2> --body=<path\\body.bsr> --items=<a.bsr,b.bsr> [--out=<png>]")
		quit(2)
		return

	var archive := Pk2Reader.open(pk2_path)
	if archive == null:
		printerr("could not open ", pk2_path)
		quit(1)
		return

	var assembled := SkinnedBsrAssembler.assemble_from_archive(archive, body, true)
	if assembled == null:
		printerr("could not assemble body ", body)
		quit(1)
		return
	var skeleton := assembled.skeleton
	print("body %s: %d bones, %d piece(s) (%d skinned)" % [
		body.get_file(), skeleton.get_bone_count(),
		assembled.piece_bones.size(), assembled.skinned_pieces])

	# Dress it: attach each item .bsr to the body's skeleton.
	var items: Array = []
	if items_arg != "":
		items = Array(items_arg.split(",", false))
	var worn := 0
	for item_path in items:
		var item_str := String(item_path).strip_edges()
		if item_str == "":
			continue
		var attached := SkinnedBsrAssembler.attach_item_from_archive(archive, skeleton, item_str)
		if attached == null:
			printerr("   FAILED to attach ", item_str)
			continue
		worn += 1
		# The assembler sets .skinned on BOTH paths; .attach_bone is set only
		# when the item hangs from its own skeleton on a body bone (a weapon,
		# or an item-local accessory), so it is what distinguishes the modes.
		var mode := ("own skeleton on '%s'" % attached.attach_bone) if attached.attach_bone != "" else "weighted onto the body"
		print("   worn: %-40s (%s)" % [item_str.get_file(), mode])
	print("dressed with %d of %d item(s)" % [worn, items.size()])

	# Optional real pose, exactly as the world applies it.
	var pose_arg := _arg("--pose")
	if pose_arg != "":
		var group := _arg("--group", "sword")
		var ban_path := _arg("--ban")
		if ban_path == "":
			ban_path = assembled.parsed.animation_for(BsrReader.AnimationEntry.TYPE_STAND, group)
		var ban_bytes := AssetSource.read_bytes(ban_path, archive)
		if ban_bytes.is_empty():
			ban_bytes = AssetSource.read_bytes("res\\" + ban_path, archive)
		var anim := BanReader.parse(ban_bytes) if not ban_bytes.is_empty() else null
		if anim == null or anim.bones.is_empty():
			printerr("   could not read the pose animation ", ban_path)
		else:
			Skeleton3DBuilder.apply_ban_pose_at(skeleton, anim, float(pose_arg), true)
			print("   posed with %s at %.2fs (%d tracks)" % [ban_path.get_file(), float(pose_arg), anim.bones.size()])

	var root := get_root()
	var world := Node3D.new()
	root.add_child(world)
	world.add_child(skeleton)
	await process_frame

	# Frame on all drawable geometry (body + worn pieces).
	var bounds := AABB()
	var seeded := false
	var stack: Array[Node] = [skeleton]
	while not stack.is_empty():
		var current: Node = stack.pop_back()
		if current is MeshInstance3D and (current as MeshInstance3D).mesh != null:
			var mi := current as MeshInstance3D
			var box: AABB = mi.global_transform * mi.get_aabb()
			bounds = box if not seeded else bounds.merge(box)
			seeded = true
		for child in current.get_children():
			stack.append(child)
	if not seeded:
		printerr("nothing drawable assembled")
		quit(1)
		return
	print("   bounds size %s centre %s" % [bounds.size.round(), bounds.get_center().round()])

	var extent: float = maxf(bounds.size.length(), 1.0)
	var centre := bounds.get_center()
	var cam := Camera3D.new()
	# Front-left three-quarter view, so the chest/arms of worn armour show.
	var cam_pos := centre + Vector3(extent * 0.55, extent * 0.12, -extent * 0.95)
	cam.position = cam_pos
	cam.look_at_from_position(cam_pos, centre, Vector3.UP)
	cam.far = extent * 20.0
	cam.current = true
	world.add_child(cam)

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-38, 140, 0)
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
