extends SceneTree
## Dev tool: measures where an own-skeleton item's mesh lands on the body under
## two compositions, so the attach rule is settled by numbers, not by a render.
##
##   current  -- what the assembler shipped in round 137: the item skeleton under
##               a BoneAttachment3D (bone global pose) with its local transform
##               set to the ITEM ROOT's rest inverse.
##   client   -- the rule read from the client (CCompChar::FUN_00c4fc70 links the
##               item root's parent socket to the named body bone and puts it in
##               update mode 1; CRTBone::FUN_00c48fe0, mode 1: world_root =
##               local_root x [R(attach.skin) | t(attach.world)], skin_root =
##               invBind_root x world_root). With local == bind for a root the
##               root's own rest cancels: item model space lands at the attach
##               bone's world position, rotated by the bone's rotation RELATIVE
##               TO ITS BIND (skin = invBind x world). Under a BoneAttachment3D
##               that is the constant local transform (B_rest_attach^-1, 0).
##
## For each item it prints, at rest and at the body's idle pose (0 s): the item
## mesh centroid's distance from the attach bone, and the direction of the
## item's long axis (its farthest vertex from the origin), in body space.
##
## Usage (headless is fine):
##   godot4 --headless --path client --script res://tools/probe_attach.gd -- \
##     --pk2=/opt/sro-files/client/Data.pk2 --body=char/china/chinaman_fighter.bsr \
##     --items=item/china/weapon/sword_01.bsr,item/china/man_item/clothes_01_sa.bsr

func _arg(flag: String, fallback: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return fallback

func _apath(flag: String) -> String:
	return _arg(flag).replace("/", "\\")

func _read(archive: Pk2Reader, path: String) -> PackedByteArray:
	var entry := ObjectLoader.find_file(archive, path)
	if entry == null:
		entry = ObjectLoader.find_file(archive, "res\\" + path)
	if entry == null:
		return PackedByteArray()
	return archive.read_file(entry)

## Centroid and farthest-from-origin vertex of an item mesh, in its model space.
func _mesh_stats(mesh: BmsReader.ParsedMesh) -> Array:
	var sum := Vector3.ZERO
	var far := Vector3.ZERO
	var far_d := -1.0
	for v in mesh.vertices:
		var p: Vector3 = v.position
		sum += p
		var d := p.length()
		if d > far_d:
			far_d = d
			far = p
	var n: int = maxi(mesh.vertices.size(), 1)
	return [sum / float(n), far, mesh.vertices.size()]

func _fmt(v: Vector3) -> String:
	return "(%6.2f,%6.2f,%6.2f)" % [v.x, v.y, v.z]

func _report(label: String, skeleton: Skeleton3D, bone_idx: int, root_rest: Transform3D, centroid: Vector3, far: Vector3) -> void:
	var P: Transform3D = skeleton.get_bone_global_pose(bone_idx)          # attach bone, skeleton space
	var B_rest: Basis = skeleton.get_bone_global_rest(bone_idx).basis
	var current: Transform3D = P * root_rest.affine_inverse()              # round 137
	var client: Transform3D = P * Transform3D(B_rest.inverse(), Vector3.ZERO)  # the client's rule
	for pair in [["current", current], ["client ", client]]:
		var name: String = pair[0]
		var X: Transform3D = pair[1]
		var c: Vector3 = X * centroid
		var tip_dir: Vector3 = (X * far - X * Vector3.ZERO).normalized()
		print("   %-6s %s  centroid %s  |centroid-bone| %5.2f  long-axis dir %s  origin %s" % [
			label, name, _fmt(c), c.distance_to(P.origin), _fmt(tip_dir), _fmt(X.origin)])

func _initialize() -> void:
	var archive := Pk2Reader.open(_arg("--pk2"))
	var body := _apath("--body")
	if archive == null or body == "":
		printerr("usage: --pk2=<Data.pk2> --body=<body.bsr> --items=<a.bsr,b.bsr>")
		quit(2)
		return
	var assembled := SkinnedBsrAssembler.assemble_from_archive(archive, body, true)
	if assembled == null:
		printerr("could not assemble ", body)
		quit(1)
		return
	var skeleton := assembled.skeleton
	get_root().add_child(skeleton)
	skeleton.force_update_all_bone_transforms()

	var items: Array = []
	for i in _apath("--items").split(",", false):
		items.append(String(i).strip_edges())
	var parsed_items: Array = []
	for item_path in items:
		var bsr := BsrReader.parse(_read(archive, item_path))
		if bsr == null or bsr.skeleton_path == "":
			print("%s: no own skeleton (weighted onto the body) -- skipped" % item_path.get_file())
			continue
		var bone_idx := skeleton.find_bone(bsr.attach_bone)
		if bone_idx == -1:
			print("%s: body has no bone %s" % [item_path.get_file(), bsr.attach_bone])
			continue
		var skel := BskReader.parse(_read(archive, bsr.skeleton_path))
		var item_skeleton := Skeleton3DBuilder.build_skeleton3d(skel)
		var root_rest: Transform3D = item_skeleton.get_bone_rest(0)
		var mesh := BmsReader.parse(_read(archive, bsr.all_mesh_paths()[0]))
		var stats := _mesh_stats(mesh)
		print("%s -> %s on '%s' (%d verts); root %s rest euler %s pos %s; model centroid %s far %s" % [
			item_path.get_file(), bsr.skeleton_path.get_file(), bsr.attach_bone, stats[2],
			skel.root_name, str(root_rest.basis.get_euler() * 180.0 / PI).replace(" ", ""),
			_fmt(root_rest.origin), _fmt(stats[0]), _fmt(stats[1])])
		var rest_pose: Transform3D = skeleton.get_bone_global_rest(bone_idx)
		print("   attach bone global rest: pos %s euler %s" % [_fmt(rest_pose.origin), str(rest_pose.basis.get_euler() * 180.0 / PI).replace(" ", "")])
		parsed_items.append([item_path.get_file(), bone_idx, root_rest, stats[0], stats[1]])
		item_skeleton.free()

	print("== REST pose ==")
	for it in parsed_items:
		_report(it[0], skeleton, it[1], it[2], it[3], it[4])

	if assembled.idle_animation != null:
		Skeleton3DBuilder.apply_ban_pose_at(skeleton, assembled.idle_animation, 0.0, true)
		skeleton.force_update_all_bone_transforms()
		print("== IDLE pose (body's stand clip, 0 s) ==")
		for it in parsed_items:
			_report(it[0], skeleton, it[1], it[2], it[3], it[4])
	else:
		print("(no idle animation parsed for the body)")

	# The shipped code, not the arithmetic: dress a fresh body through
	# attach_item_from_archive and measure where the attached node actually
	# puts each item's mesh at rest, to compare with the rows above.
	var fresh := SkinnedBsrAssembler.assemble_from_archive(archive, body, false)
	get_root().add_child(fresh.skeleton)
	var attached: Array = []
	for i in range(items.size()):
		var a := SkinnedBsrAssembler.attach_item_from_archive(archive, fresh.skeleton, items[i])
		if a != null and a.attach_bone != "":
			attached.append([String(items[i]).get_file(), a])
	await process_frame
	await process_frame
	print("== SHIPPED attach_item_from_archive, rest pose ==")
	for entry in attached:
		var a: SkinnedBsrAssembler.AttachedItem = entry[1]
		var item_node: Node3D = a.node.get_child(0) as Node3D  # the item Skeleton3D under the BoneAttachment3D
		var X: Transform3D = fresh.skeleton.global_transform.affine_inverse() * item_node.global_transform
		var bone_idx := fresh.skeleton.find_bone(a.attach_bone)
		var P: Transform3D = fresh.skeleton.get_bone_global_pose(bone_idx)
		for it in parsed_items:
			if it[0] != entry[0]:
				continue
			var c: Vector3 = X * it[3]
			var tip_dir: Vector3 = (X * it[4] - X * Vector3.ZERO).normalized()
			print("   %-16s shipped  centroid %s  |centroid-bone| %5.2f  long-axis dir %s  origin %s" % [
				entry[0], _fmt(c), c.distance_to(P.origin), _fmt(tip_dir), _fmt(X.origin)])
	quit(0)
