extends SceneTree

## Round 786: monsters appear on time, and attacks register promptly.
##
## - MonsterDraw.clone_tree copies a monster template the way duplicate() did
##   -- the same nodes, names, metas, bones, poses, meshes, skins, materials
##   and draw settings, the resources shared -- without reading any node's
##   property list (duplicate()'s read of a GeometryInstance3D's waits for
##   the render thread: 12-25 ms for the first body of a frame, MEASURED).
## - LatencyProbe's records: a monster's wait and why, an attack's
##   click->send->result.
## - NetClient turns Nagle's algorithm off unless OPENSRO_NAGLE=1.
## - RenderSync waits for the render thread once a frame and the reading's
##   budget does not count the wait.
##
## `godot4 --headless --path client --script res://scripts/world/monster_spawn786_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## A template shaped as SkinnedBsrAssembler makes one: a skeleton, two
## skinned pieces (one with a front-pass twin), a rigid piece on a bone
## attachment, metas on the nodes.
func _template() -> Skeleton3D:
	var s := Skeleton3D.new()
	Skeleton3DBuilder.no_physics_step(s)
	s.name = "mangyang"
	s.add_bone("root")
	s.add_bone("spine")
	s.add_bone("head")
	s.set_bone_parent(1, 0)
	s.set_bone_parent(2, 1)
	for i in 3:
		s.set_bone_rest(i, Transform3D(Basis(Vector3.UP, 0.1 * i), Vector3(0, i, 0.5 * i)))
		s.set_bone_pose_position(i, Vector3(0.2 * i, i, 0))
		s.set_bone_pose_rotation(i, Quaternion(Vector3.RIGHT, 0.3 * i))
		s.set_bone_pose_scale(i, Vector3.ONE * (1.0 + 0.1 * i))
	s.set_bone_enabled(2, false)
	s.set_meta("template_meta", 7)
	var mesh := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO, Vector3.UP, Vector3.RIGHT])
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var skin := Skin.new()
	var mat := StandardMaterial3D.new()
	var front := StandardMaterial3D.new()
	for k in 2:
		var mi := MeshInstance3D.new()
		mi.name = "part%d" % k
		mi.mesh = mesh
		mi.material_override = mat
		s.add_child(mi)
		mi.skin = skin
		mi.skeleton = mi.get_path_to(s)
		mi.set_meta("opensro_body_mesh", k)
	var twin := MeshInstance3D.new()
	twin.name = "part0_front"
	twin.mesh = mesh
	twin.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	twin.material_override = front
	twin.sorting_offset = 0.25
	s.add_child(twin)
	twin.skin = skin
	twin.skeleton = twin.get_path_to(s)
	var att := BoneAttachment3D.new()
	att.name = "weapon_head"
	att.bone_name = "head"
	s.add_child(att)
	var rigid := MeshInstance3D.new()
	rigid.name = "sword"
	rigid.mesh = mesh
	rigid.transform = Transform3D(Basis.IDENTITY, Vector3(1, 2, 3))
	rigid.set_surface_override_material(0, front)
	rigid.layers = 5
	att.add_child(rigid)
	return s

## The fields duplicate() and clone_tree must agree on, node by node.
func _same(a: Node, b: Node, path: String) -> void:
	_check(a.get_class() == b.get_class(), "%s: the same class (%s)" % [path, a.get_class()])
	_check(a.name == b.name, "%s: the same name" % path)
	_check(a.get_meta_list() == b.get_meta_list(), "%s: the same metas" % path)
	for k in a.get_meta_list():
		_check(a.get_meta(k) == b.get_meta(k), "%s: meta %s" % [path, k])
	# A bone attachment's transform is its bone's pose, written by the
	# attachment itself once in a tree; the pieces' and the skeleton's are
	# the template's.
	if a is Node3D and not a is BoneAttachment3D:
		_check((a as Node3D).transform.is_equal_approx((b as Node3D).transform), "%s: the same transform" % path)
	if a is Skeleton3D:
		var sa := a as Skeleton3D
		var sb := b as Skeleton3D
		_check(sa.get_bone_count() == sb.get_bone_count(), "%s: the same bone count" % path)
		for i in sa.get_bone_count():
			_check(sa.get_bone_name(i) == sb.get_bone_name(i) and sa.get_bone_parent(i) == sb.get_bone_parent(i)
				and sa.get_bone_rest(i).is_equal_approx(sb.get_bone_rest(i)) and sa.is_bone_enabled(i) == sb.is_bone_enabled(i)
				and sa.get_bone_pose_position(i).is_equal_approx(sb.get_bone_pose_position(i))
				and sa.get_bone_pose_rotation(i).is_equal_approx(sb.get_bone_pose_rotation(i))
				and sa.get_bone_pose_scale(i).is_equal_approx(sb.get_bone_pose_scale(i)), "%s: bone %d the same" % [path, i])
	if a is MeshInstance3D:
		var ma := a as MeshInstance3D
		var mb := b as MeshInstance3D
		_check(ma.mesh == mb.mesh and ma.skin == mb.skin, "%s: the mesh and skin shared, not copied" % path)
		_check(ma.skeleton == mb.skeleton, "%s: the same skeleton path (%s)" % [path, ma.skeleton])
		_check(ma.material_override == mb.material_override, "%s: the same material override" % path)
		_check(ma.get_surface_override_material_count() == mb.get_surface_override_material_count(), "%s: the same surface count" % path)
		for i in ma.get_surface_override_material_count():
			_check(ma.get_surface_override_material(i) == mb.get_surface_override_material(i), "%s: surface %d material" % [path, i])
		_check(ma.cast_shadow == mb.cast_shadow and ma.layers == mb.layers and ma.sorting_offset == mb.sorting_offset,
			"%s: the same shadow, layers and sorting" % path)
	if a is BoneAttachment3D:
		_check((a as BoneAttachment3D).bone_name == (b as BoneAttachment3D).bone_name, "%s: the same bone" % path)
	_check(a.get_child_count() == b.get_child_count(), "%s: the same children" % path)
	for i in mini(a.get_child_count(), b.get_child_count()):
		_same(a.get_child(i), b.get_child(i), "%s/%s" % [path, a.get_child(i).name])

func _initialize() -> void:
	# --- clone_tree against duplicate() ---
	var t := _template()
	var dup := t.duplicate()
	var cl := MonsterDraw.clone_tree(t)
	_same(dup, cl, "mangyang")
	_check(cl != t and cl.get_child(0) != t.get_child(0), "new nodes, not the template's")
	var body := SkinnedBsrAssembler.AssembledCharacter.new()
	body.skeleton = t
	var made := MonsterDraw.instance_of(body)
	_check(made != null and made.skeleton != t and made.skeleton.get_bone_count() == 3, "instance_of builds the body from clone_tree")
	# The body is drawn and posed in a tree as the duplicate was.
	root.add_child(cl)
	var piece := cl.get_node("part0") as MeshInstance3D
	_check(piece.get_node_or_null(piece.skeleton) == cl, "the piece's skeleton path resolves to its own skeleton in the tree")
	var holder := cl.get_node_or_null("weapon_head") as BoneAttachment3D
	_check(holder != null and holder.get_node_or_null("sword") is MeshInstance3D, "the rigid piece hangs off its bone attachment")
	cl.queue_free()
	dup.free()
	made.skeleton.free()
	# An unknown kind is still copied, by duplicate().
	var odd := Node3D.new()
	odd.name = "odd"
	odd.add_child(Label3D.new())
	var odd_copy := MonsterDraw.clone_tree(odd)
	_check(odd_copy is Node3D and odd_copy.get_child(0) is Label3D, "another kind falls back to duplicate()")
	odd.free()
	odd_copy.free()
	t.free()

	# --- LatencyProbe ---
	LatencyProbe.on = true
	LatencyProbe.stamp = false
	LatencyProbe.reset()
	LatencyProbe.monster_recv(5, 1000, 512.0, "push")
	LatencyProbe.monster_waits(5, "template")
	LatencyProbe.monster_waits(5, "region")
	var line := LatencyProbe.monster_body(5, 1130, 498.0)
	_check(line == "QA LAT mob 5 via push wait 130 ms (template) dist at recv 512 at body 498", "a monster's wait, its first reason and both distances: " + line)
	_check(LatencyProbe.monster_body(5, 1200, 1.0) == "", "a body is reported once")
	LatencyProbe.monster_recv(6, 2000, 300.0, "list")
	LatencyProbe.monster_forget(6)
	_check(LatencyProbe.monster_body(6, 2100, 1.0) == "", "a monster forgotten before its body is not reported")
	LatencyProbe.attack_click(9, 100)
	LatencyProbe.attack_send(9, 1600)
	line = LatencyProbe.attack_result(9, 1652, "")
	_check(line == "QA LAT atk 9 click->send 1500 ms send->result 52 ms total 1552 ms", "an attack's walk, round trip and total: " + line)
	_check(LatencyProbe.attack_result(9, 1700, "") == "", "a keep-up's later result is not a new attack")
	LatencyProbe.attack_send(10, 5000)
	line = LatencyProbe.attack_result(10, 5001, "too far away")
	_check(line.ends_with("(too far away)") and line.contains("click->send 0 ms"), "a refusal is timed and named; a send with no click counts from the send")
	_check(LatencyProbe.percentile([5, 1, 3, 2, 4], 0.5) == 3.0, "the median")
	LatencyProbe.on = false
	LatencyProbe.reset()
	LatencyProbe.monster_recv(7, 0, 1.0, "push")
	_check(LatencyProbe.monster_body(7, 10, 1.0) == "", "off, nothing is recorded")

	# --- RenderSync: one wait a frame, credited to the reading's budget ---
	RenderSync.reset()
	var first := RenderSync.wait_once()
	_check(first >= 0 and RenderSync.wait_once() == 0, "the render thread is waited for once a frame, not again in it")
	RenderSync.reset()
	RenderSync.on = false
	_check(RenderSync.wait_once() == 0, "off (the A/B's before), nothing is waited for")
	RenderSync.on = true
	var net: Node = (load("res://scripts/net/net_client.gd") as GDScript).new()
	var t0 := Time.get_ticks_usec() - 20000
	var before: int = net.call("_spent", t0)
	net.call("credit_render_sync", 15000)
	var after: int = net.call("_spent", t0)
	_check(before >= 20000 and absi(before - after - 15000) < 1000, "a credited wait is not the reading's own work (%d -> %d)" % [before, after])
	_check(after < 8000 or after - 8000 < 2000, "20 ms spent of which 15 waiting leaves the 8 ms budget open")
	net.free()

	# --- Nagle ---
	_check(NetClient_no_delay(), "the game socket turns Nagle's algorithm off by default")

	print("monster_spawn786_test: %d failure(s)" % _failures)
	quit(0 if _failures == 0 else 1)

func NetClient_no_delay() -> bool:
	var script := load("res://scripts/net/net_client.gd") as GDScript
	return script.call("no_delay_wanted")
