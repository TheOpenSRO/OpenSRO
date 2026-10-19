extends SceneTree

## Round 794: the Dynamic Animation option's cloth (ClothSim, SrCloth through
## ClothNative, ClothDriver). Run headless on the render box:
## `client/tools/remote_godot.sh tests`.
##
## Holds the step to retail's arithmetic (CCompChar::FUN_00c0d010, READ;
## docs/protocol/CLOTH.md): gravity `g * -5 * (k * a + 1) * 0.0004` on the
## first step, links pulled in only past rest + 0.01, pinned vertices never
## stepped; MSVC's rand(); the normal bytes to Godot's own encoding; the
## native class to the GDScript twin; and the driver: near it draws the cloth
## mesh and steps it in 50 ms steps, far or with the option off the mesh is
## back on its own skin.
##
## Everything is SYNTHETIC (a strip of four vertices); no game data.
##
## NEGATIVES: on the base (dev d43226f0) none of these classes exist, and the
## option changes nothing.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	var watchdog := create_timer(120.0)
	watchdog.timeout.connect(func() -> void:
		print("FAIL the suite never reported (a script error stopped it)")
		quit(1))
	await process_frame
	_rand()
	_arithmetic()
	_normals()
	_parity()
	await _driver()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

## A rope: vertex 0 pinned at y 1, vertex 1 free at y 0 (rest `rest`).
func _rope(rest: float) -> Dictionary:
	return {"amount": PackedFloat32Array([0.0, 0.5]), "pinned": PackedByteArray([1, 0]),
		"links": PackedInt32Array([0, 1]), "rest": PackedFloat32Array([rest]), "order": PackedInt32Array([0]),
		"params": PackedFloat32Array([1, 0, 0, 1, 9.8, 1.0, 0.0, 0.95, 2]),
		"positions": PackedVector3Array([Vector3(0, 1, 0), Vector3(0, 0, 0)]),
		"normals": PackedVector3Array([Vector3(0, 0, 1), Vector3(0, 0, 1)]),
		"bones": PackedInt32Array(), "weights": PackedFloat32Array(), "vertex_data": PackedByteArray()}

func _rand() -> void:
	ClothSim.srand(1)
	var got := [ClothSim.rand(), ClothSim.rand(), ClothSim.rand()]
	_check(got == [41, 18467, 6334], "rand() is MSVC's: 41, 18467, 6334 after srand(1) (got %s)" % [got])
	_check(ClothSim.shape_p(0.1) == 0.2 * 900.0 and ClothSim.shape_p(0.5) == 450.0 and ClothSim.shape_p(3.0) == 900.0
		and ClothSim.shape_p(0.0) == 0.0, "p is shaped as FUN_00c0d010's top: 180 below 0.2, x900 below 1, 900 above")

func _arithmetic() -> void:
	var c := ClothSim.new()
	_check(c.setup(_rope(2.0)), "a slack rope is a cloth")
	ClothSim.srand(1) # the first roll, 41, is odd: no gust with divisor 2
	c.step_once(Vector3(0, 0, 1), 0.0)
	var want := 9.8 * -5.0 * (1.0 * 0.5 + 1.0) * 0.0004
	_check(absf(c.cur[1].y - want) < 1e-6 and c.cur[1].x == 0.0 and c.cur[1].z == 0.0,
		"one step from rest moves a free vertex by g x -5 x (k a + 1) x 0.0004 = %.6f (got %s)" % [want, c.cur[1]])
	_check(c.cur[0] == Vector3(0, 1, 0), "the pinned vertex is not stepped")
	# Taut: the link pulls the free end back to its rest, never pushes.
	var t := ClothSim.new()
	t.setup(_rope(1.0))
	ClothSim.srand(7)
	t.step(40, Vector3.ZERO, 0.0)
	var length := t.cur[0].distance_to(t.cur[1])
	_check(length <= 1.0101, "a taut rope stays within rest + 0.01 after 40 steps (got %.4f)" % length)
	var close := ClothSim.new()
	close.setup(_rope(1.0))
	close.gravity = 0.0
	close.cur[1] = Vector3(0, 0.9, 0)
	close.prev[1] = close.cur[1]
	ClothSim.srand(1)
	close.step_once(Vector3.ZERO, 0.0)
	_check(close.cur[1] == Vector3(0, 0.9, 0), "a link shorter than its rest is left alone (stretch only)")
	var bad := _rope(1.0)
	bad["params"] = PackedFloat32Array([1, 0, 0, 1, 9.8, 1.0, 0.0, 0.95, 0])
	_check(not ClothSim.new().setup(bad), "a divisor of 0 is refused (retail's idiv would fault)")

func _normals() -> void:
	var ns := PackedVector3Array([Vector3(0, 1, 0), Vector3(0.6, 0, -0.8), Vector3(-0.267261, 0.534522, 0.801784),
		Vector3(0.1, -0.9, 0.3).normalized(), Vector3(-0.7, -0.1, -0.7).normalized()])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	var ps := PackedVector3Array()
	for i in range(ns.size()):
		ps.append(Vector3(i, 0, 0))
	arrays[Mesh.ARRAY_VERTEX] = ps
	arrays[Mesh.ARRAY_NORMAL] = ns
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arrays)
	var vd: PackedByteArray = RenderingServer.mesh_get_surface(am.get_rid(), 0)["vertex_data"]
	var n := ns.size()
	var same := vd.size() == n * 20
	for i in range(n):
		var o := ClothSim.octahedral_u16(ns[i])
		if not same or vd.decode_u16(n * 12 + i * 8) != o.x or vd.decode_u16(n * 12 + i * 8 + 2) != o.y:
			same = false
	_check(same, "the normal words are Godot's own (its vertex stream: positions, then normal and tangent)")

## A 3 x 3 sheet hung by its top row, rolled with gusts: SrCloth and ClothSim.
func _sheet() -> Dictionary:
	var pos := PackedVector3Array()
	var amount := PackedFloat32Array()
	var pinned := PackedByteArray()
	for r in range(3):
		for col in range(3):
			pos.append(Vector3(col, 2 - r, 0))
			amount.append(0.0 if r == 0 else 0.1 * (r + col))
			pinned.append(1 if r == 0 else 0)
	var links := PackedInt32Array()
	var rest := PackedFloat32Array()
	for r in range(3):
		for col in range(3):
			var i := r * 3 + col
			if col < 2 and r > 0:
				links.append_array([i, i + 1])
				rest.append(1.0)
			if r < 2:
				links.append_array([i, i + 3])
				rest.append(1.0)
	var order := PackedInt32Array()
	for k in range(rest.size()):
		order.append(rest.size() - 1 - k)
	var normals := PackedVector3Array()
	var bones := PackedInt32Array()
	var weights := PackedFloat32Array()
	for i in range(9):
		normals.append(Vector3(0, 0, 1))
		bones.append_array([0, 0, 0, 0])
		weights.append_array([1, 0, 0, 0])
	return {"amount": amount, "pinned": pinned, "links": links, "rest": rest, "order": order,
		"params": PackedFloat32Array([1, 0.3, 0, 1, 9.8, 1.0, 3.5, 0.95, 2]),
		"positions": pos, "normals": normals, "bones": bones, "weights": weights, "vertex_data": PackedByteArray()}

func _parity() -> void:
	if not ClothNative.available():
		print("ok  (skipped) the native class is not in this library: %s" % ClothNative.status)
		return
	var nat: Object = ClassDB.instantiate(ClothNative.CLASS)
	var gd := ClothSim.new()
	var d := _sheet()
	_check(bool(nat.call("setup", d)) and gd.setup(d), "both take the sheet")
	# A bone that turns and rises, then 30 rounds of skin + 1 or 2 steps.
	var worst := 0.0
	var words := true
	ClothNative.srand(12345)
	for f in range(30):
		var m := Transform3D(Basis(Vector3.UP, 0.05 * f), Vector3(0, 0.02 * f, 0))
		var mats := PackedFloat32Array([m.basis.x.x, m.basis.x.y, m.basis.x.z, m.basis.y.x, m.basis.y.y, m.basis.y.z,
			m.basis.z.x, m.basis.z.y, m.basis.z.z, m.origin.x, m.origin.y, m.origin.z])
		nat.call("skin", mats, f % 7 != 3)
		gd.skin(mats, f % 7 != 3)
		var steps := 1 + f % 2
		nat.call("step", steps, Vector3(0, 0, 1), 0.3)
		gd.step(steps, Vector3(0, 0, 1), 0.3)
		var a: PackedVector3Array = nat.call("positions")
		for i in range(9):
			worst = maxf(worst, a[i].distance_to(gd.cur[i]))
		var vn: PackedByteArray = nat.call("vertex_data")
		var vg := gd.vertex_data()
		for i in range(9):
			if absi(vn.decode_u16(108 + i * 8) - vg.decode_u16(108 + i * 8)) > 2 or absi(vn.decode_u16(110 + i * 8) - vg.decode_u16(110 + i * 8)) > 2:
				words = false
	_check(worst < 1e-3, "SrCloth and ClothSim agree over 30 frames of skin and gusty steps (worst %.7f)" % worst)
	_check(words, "and their normal words agree to 2 units")
	_check(int(nat.call("rand_state")) == ClothSim.rand_seed, "and both rolled the generator the same number of times")

## The driver on a strip skinned to one bone, in this tree's viewport.
func _driver() -> void:
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.position = Vector3(0, 1, 10)
	cam.current = true
	var skel := Skeleton3D.new()
	skel.add_bone("root")
	root.add_child(skel)
	var d := _rope(1.0)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(0, 1, 0), Vector3(0, 0, 0), Vector3(0.1, 0, 0)])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3(0, 0, 1), Vector3(0, 0, 1), Vector3(0, 0, 1)])
	arrays[Mesh.ARRAY_BONES] = PackedInt32Array([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
	arrays[Mesh.ARRAY_WEIGHTS] = PackedFloat32Array([1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	am.set_meta(BmsReader.CLOTH_META, {"amount": PackedFloat32Array([0.0, 0.5, 0.5]), "pinned": PackedByteArray([1, 0, 0]),
		"links": PackedInt32Array([0, 1, 0, 2]), "rest": PackedFloat32Array([1.0, 1.005]), "order": PackedInt32Array([0, 1]),
		"params": d["params"]})
	var skin := Skin.new()
	skin.add_named_bind("root", Transform3D.IDENTITY)
	var mi := MeshInstance3D.new()
	mi.mesh = am
	mi.skin = skin
	skel.add_child(mi)
	mi.skeleton = mi.get_path_to(skel)
	ClothDriver.set_option(true)
	ClothDriver.enlist(skel)
	_check(skel.is_in_group(ClothDriver.GROUP), "a skeleton with a cloth mesh joins the driver's group")
	var drv := ClothDriver.driver_for(root)
	await create_timer(0.4).timeout
	await process_frame
	_check(mi.has_meta(ClothDriver.ORIGINAL_META) and mi.mesh != am and mi.skin == null,
		"near (10 units), the mesh draws its cloth: its own mesh and skin kept aside")
	_check(drv.steps_run >= 4, "0.4 s gave 50 ms steps (got %d): %s" % [drv.steps_run, drv.describe()])
	# The bone rises 2: the pinned vertex follows the skin at once.
	skel.set_bone_pose_position(0, Vector3(0, 2, 0))
	await process_frame
	await process_frame
	var at := drv.positions_of(skel)
	_check(at.size() == 3 and absf(at[0].y - 3.0) < 1e-4, "the pinned vertex is skinned each frame (got %s, want y 3)" % at)
	# Far: 300 units is LOD level 1 (300 / 800 x 4 = 1.5).
	cam.position = Vector3(0, 1, 300)
	await process_frame
	await process_frame
	_check(not mi.has_meta(ClothDriver.ORIGINAL_META) and mi.mesh == am and mi.skin == skin,
		"far (300 units), the mesh is back on its own skin")
	skel.set_meta(ClothDriver.ALWAYS_NEAR_META, true)
	await process_frame
	await process_frame
	_check(mi.has_meta(ClothDriver.ORIGINAL_META), "a body marked always near (the own player) draws its cloth at 300")
	# Off screen (the camera turned away): no skin, no step, the particles kept.
	skel.set_meta(ClothDriver.ALWAYS_NEAR_META, false)
	cam.position = Vector3(0, 1, -60)
	await process_frame
	var before := drv.positions_of(skel)
	await create_timer(0.2).timeout
	_check(before.size() == 3 and drv.positions_of(skel) == before, "a character out of view is not stepped (the animate flag)")
	cam.position = Vector3(0, 1, 10)
	# A placed object: a rigid strip, behind the camera and 2,000 units away.
	var obj := Node3D.new()
	root.add_child(obj)
	obj.position = Vector3(0, 0, 2010)
	var rigid_arrays := arrays.duplicate()
	rigid_arrays[Mesh.ARRAY_BONES] = null
	rigid_arrays[Mesh.ARRAY_WEIGHTS] = null
	var rm := ArrayMesh.new()
	rm.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, rigid_arrays)
	rm.set_meta(BmsReader.CLOTH_META, am.get_meta(BmsReader.CLOTH_META))
	var rmi := MeshInstance3D.new()
	rmi.mesh = rm
	obj.add_child(rmi)
	obj.set_meta(ClothDriver.OBJECT_META, true)
	ClothDriver.enlist(obj)
	await create_timer(0.3).timeout
	var ro := drv.positions_of(obj)
	_check(ro.size() == 3 and ro[0] == Vector3(0, 1, 0) and ro[1] != Vector3.ZERO and rmi.mesh != rm,
		"a placed object's rigid cloth runs at 2,000 units behind the camera, its pinned vertex at the bind pose (got %s)" % ro)
	obj.queue_free()
	ClothDriver.set_option(false)
	await process_frame
	await process_frame
	_check(not mi.has_meta(ClothDriver.ORIGINAL_META) and mi.mesh == am, "Dynamic Animation off: the mesh is back on its own skin")
	ClothDriver.set_option(true)
	await process_frame
	await process_frame
	_check(mi.has_meta(ClothDriver.ORIGINAL_META), "on again: the cloth is made again")
	skel.queue_free()
	cam.queue_free()
	await process_frame
	await process_frame
	_check(drv.describe().begins_with("0 hosts"), "a freed body leaves the driver (%s)" % drv.describe())
