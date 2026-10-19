extends Node
class_name ClothDriver

## Round 794: the Dynamic Animation option -- the per-vertex cloth of every
## cloth mesh (robes, skirts, capes, hair, tassels, wings, banners, flags,
## cobwebs), READ from sro_client.exe; docs/protocol/CLOTH.md has every
## address. ClothSim (and SrCloth, through ClothNative) steps one mesh.
##
## **Which hosts.** A node joins GROUP (enlist) when a cloth mesh is under it
## (one whose mesh carries BmsReader.CLOTH_META): a body's Skeleton3D
## (CharacterAppearance.build, SkinnedBsrAssembler), or a placed object's
## root (ObjectLoader, with OBJECT_META). Retail runs the cloth in the slot-14
## update every compound object shares (CCompoundObj, `c33230`): characters
## (CCompChar), buildings (CCompBldg) and the rest (CCompSimple).
##
## **Each frame, per host** (`c33230`'s tail, READ):
## - nothing while the option is off (renderer +0x19c, `option_on`);
## - a character not in view at the last draw (the animate flag, ent+0xbc,
##   GlobalDataManager::FUN_009c4aa0's frustum test) is skipped: no skin, no
##   step, the count kept. A placed object has no such test (SWorld::vslot_004
##   passes the flag as 1); it is stepped while it is drawn (its fade range);
## - near is LOD level 0: a character's `trunc(4 f) == 0`, f its camera
##   distance / 800 (FUN_009c4aa0, CCompChar::FUN_00c25620) -- within 200
##   units; always for the own player and a unique (`ALWAYS_NEAR_META`); a
##   placed object's LOD is always 0 (READ: nothing writes it after its reset);
## - near: the pinned vertices of a skinned mesh are skinned (FUN_00c526e0 ->
##   FUN_00c52270; a mesh with no skin is never skinned: its pinned vertices
##   stay at the bind pose), then the frame's milliseconds go to the host's
##   count (+0x194): under 50 nothing more; else clamped to 200, `count / 50`
##   steps (FUN_00c0d720 -> FUN_00c0d610 -> FUN_00c0d010), the rest kept; then
##   every particle goes to the buffer;
## - far: retail skins every vertex on the CPU, the static skinned pose; here
##   the mesh goes back to its own GPU skin, the same pose, and the count does
##   not move. Coming near again, every particle takes the skinned pose first
##   (the far frames' last skin), the previous positions as they were.
##
## **The wind** (FUN_00c0d720): the mesh's own vector when its flag is set;
## else `-(+0xa0)` = (-sin t, 0, cos t), t the host's yaw (CCompChar::
## FUN_00c26e70) -- a world vector used in the mesh's own space, as retail
## does. Godot's world axes are retail's (`rotation.y = -yaw`, AGENTS.md), so
## it is the host's +Z in the world, flattened (INFERRED that the dynamic
## batch draws in the object's frame: CLOTH.md, OPEN). A dungeon block's own
## wind (RTDunBlock +0xfc) is not read: OPEN.
##
## **p** (FUN_00c0d010's third argument, ent+0xcc): what the character moved
## this frame, in world units (FUN_00a59710: the speed times the frame time;
## reset after every tick) -- here the host's own displacement since the last
## frame; 0 for a placed object (SWorld::vslot_004's literal).
##
## **Turning the option on or off** (the setter 0xbc11f0 -> Map::FUN_00bea840,
## READ): every host's cloth is made again, its particles at the bind pose
## (FUN_00c1af60); off, every mesh draws its own skin.

const GROUP := &"opensro_cloth"
## On a MeshInstance3D drawing its cloth mesh: [the mesh, the skin, the
## skeleton path] it had.
const ORIGINAL_META := &"opensro_cloth_original"
## On a character host: true when its LOD is always 0 (the own player, a unique).
const ALWAYS_NEAR_META := &"opensro_cloth_always_near"
## On a placed object's root: LOD 0, no view test, p 0.
const OBJECT_META := &"opensro_cloth_object"
## READ (`c33230`): the step and the count's cap, in ms.
const STEP_MS := 50
const CAP_MS := 200
## READ: LOD level = trunc(clamp(distance / 800, 0, 1) * 4); level 0 is near.
const LOD_DISTANCE := 800.0
## OURS: the radius a character's origin is tested against the view with
## (retail tests the object's own box).
const VIEW_RADIUS := 20.0

## The Dynamic Animation row (VideoOptions.DYNAMIC_ANIMATION); on by default
## (the renderer's constructor, 0xbc1a72).
static var option_on := true
## Bumped by set_option: every host's cloth is made again.
static var _generation := 0
static var _option_read := false
static var _qa_log := OS.get_environment("OPENSRO_QA_CLOTH") != ""

static func set_option(on: bool) -> void:
	_option_read = true
	if on == option_on:
		return
	option_on = on
	_generation += 1

## The saved row, the first time a driver is made before the world applies
## its options (the login and select screens).
static func _read_option() -> void:
	if _option_read:
		return
	_option_read = true
	option_on = VideoOptions.in_force().value(VideoOptions.DYNAMIC_ANIMATION) != 0

class Piece:
	var sim: Object
	var mesh: ArrayMesh
	var source: Mesh
	var skin: Skin
	var skel_path: NodePath
	var mis: Array = []
	var binds := PackedInt32Array()
	## Null for a mesh with no skin (rigid).
	var skeleton: Skeleton3D

class Host:
	var node: Node3D
	var pieces: Array = []
	var count_ms := 0
	var state := 0 # 0 fresh, 1 near, 2 far
	var generation := -1
	var refused := 0
	var last_pos := Vector3.INF

var _hosts := {} # instance id -> Host
var camera: Camera3D = null
## Stats for the QA log.
var steps_run := 0
var hosts_near := 0
var last_usec := 0
## OPENSRO_QA_CLOTH=<frames> (QA): the driver's line and each host's cloth
## meshes every that many frames.
var _qa_every := int(OS.get_environment("OPENSRO_QA_CLOTH")) if OS.get_environment("OPENSRO_QA_CLOTH").is_valid_int() else 0
var _qa_frames := 0

static func driver_for(viewport: Viewport) -> ClothDriver:
	const META := &"opensro_cloth_driver"
	if viewport.has_meta(META):
		var d = viewport.get_meta(META)
		if is_instance_valid(d):
			return d
	_read_option()
	var drv := ClothDriver.new()
	drv.name = "ClothDriver"
	# After the world's _process (the poses of the frame are set).
	drv.process_priority = 100
	viewport.add_child(drv)
	viewport.set_meta(META, drv)
	if _qa_log:
		print("QA CLOTH driver for %s (option %s)" % [viewport.name, option_on])
	return drv

## Puts `host` in GROUP when any mesh under it is cloth (a body just built,
## one an item was hung on, a placed object), and makes its viewport's driver
## once it is in the tree. The driver drops it again if none can run.
static func enlist(host: Node3D) -> void:
	if host == null:
		return
	# A copy of a template keeps the template's groups (Node.duplicate), so a
	# body may be in the group already; it still needs its viewport's driver.
	if not host.is_in_group(GROUP):
		if not _has_cloth(host):
			return
		host.add_to_group(GROUP)
	if _qa_log:
		print("QA CLOTH enlist %s" % host.name)
	if host.is_inside_tree():
		driver_for(host.get_viewport())
	elif not host.tree_entered.is_connected(_on_enlisted_entered.bind(host)):
		host.tree_entered.connect(_on_enlisted_entered.bind(host), CONNECT_ONE_SHOT)

static func _on_enlisted_entered(host: Node3D) -> void:
	if is_instance_valid(host) and host.is_inside_tree():
		driver_for(host.get_viewport())

static func _has_cloth(root: Node) -> bool:
	for n in root.find_children("*", "MeshInstance3D", true, false):
		var mesh := (n as MeshInstance3D).mesh
		if mesh != null and mesh.has_meta(BmsReader.CLOTH_META):
			return true
	return false

## The meshes back on their own skin under `root` (a crowd capturing a body,
## CrowdGpu._parts_of). The driver puts the cloth back the next frame the
## host is near.
static func unswap(root: Node) -> void:
	if root == null:
		return
	for n in root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.has_meta(ORIGINAL_META):
			_restore(mi)

## A copy of a live body (the portrait's picture, World3D): its meshes back
## on their own skin and the copy out of the group -- it is drawn once, and
## would otherwise draw the live body's cloth mesh.
static func clean_copy(copy: Node) -> void:
	unswap(copy)
	if copy.is_in_group(GROUP):
		copy.remove_from_group(GROUP)

static func _restore(mi: MeshInstance3D) -> void:
	var o: Array = mi.get_meta(ORIGINAL_META)
	mi.remove_meta(ORIGINAL_META)
	mi.mesh = o[0]
	mi.skin = o[1]
	mi.skeleton = o[2]
	mi.custom_aabb = AABB()

func _process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	var cam := camera if is_instance_valid(camera) else get_viewport().get_camera_3d()
	var planes: Array[Plane] = []
	if cam != null and cam.is_inside_tree():
		planes = cam.get_frustum()
	var dt_ms := int(roundf(delta * 1000.0))
	var seen := {}
	hosts_near = 0
	for node in get_tree().get_nodes_in_group(GROUP):
		var host := node as Node3D
		if host == null or host.get_viewport() != get_viewport():
			continue
		var id := host.get_instance_id()
		seen[id] = true
		var h: Host = _hosts.get(id)
		if h == null:
			h = Host.new()
			h.node = host
			_hosts[id] = h
		_tick(h, cam, planes, dt_ms)
	for id in _hosts.keys():
		if not seen.has(id):
			_drop(_hosts[id])
			_hosts.erase(id)
	last_usec = Time.get_ticks_usec() - t0
	_qa_frames += 1
	if _qa_every > 0 and _qa_frames % _qa_every == 0:
		_qa_print()

func _tick(h: Host, cam: Camera3D, planes: Array[Plane], dt_ms: int) -> void:
	if h.generation != _generation:
		_drop(h)
		h.generation = _generation
	var at := h.node.global_position
	# p: this frame's displacement (FUN_00a59710's speed x frame time).
	var p := 0.0 if h.last_pos == Vector3.INF else at.distance_to(h.last_pos)
	h.last_pos = at
	if not option_on or not h.node.is_visible_in_tree():
		_far(h)
		return
	var object := h.node.has_meta(OBJECT_META)
	var near := object or bool(h.node.get_meta(ALWAYS_NEAR_META, false))
	if not near and cam != null:
		var f := clampf(cam.global_position.distance_to(at) / LOD_DISTANCE, 0.0, 1.0)
		near = int(f * 4.0) < 1
	if not near:
		_far(h)
		return
	if object:
		p = 0.0
	elif not _in_view(planes, at):
		# The animate flag down: nothing this frame, the state kept.
		return
	if h.pieces.is_empty() and not _build(h):
		return
	hosts_near += 1
	var coming := h.state == 2
	h.state = 1
	var wind := host_wind(h.node)
	# The count (+0x194): under 50 nothing; else at most 200, steps of 50.
	h.count_ms += dt_ms
	var steps := 0
	if h.count_ms < STEP_MS:
		if h.count_ms < 0:
			h.count_ms = 0
	else:
		h.count_ms = mini(h.count_ms, CAP_MS)
		steps = h.count_ms / STEP_MS
		h.count_ms %= STEP_MS
	for piece in h.pieces.duplicate():
		# A piece whose instances are gone (a re-dress freed them) leaves; a
		# hidden one is not stepped (CRTMesh's enabled flag, dyn+0x10, gates
		# FUN_00c526e0 and FUN_00c0d720).
		var shown := false
		var live: Array = []
		for mi in piece.mis:
			if is_instance_valid(mi):
				live.append(mi)
				shown = shown or (mi as MeshInstance3D).visible
		piece.mis = live
		if live.is_empty() or (piece.skin != null and not is_instance_valid(piece.skeleton)):
			h.pieces.erase(piece)
			continue
		if not shown:
			continue
		_swap_in(piece)
		if piece.skin != null:
			var mats := _mats(piece.skeleton, piece)
			if coming:
				piece.sim.call("skin", mats, false)
			piece.sim.call("skin", mats, true)
		if steps > 0:
			var params: PackedFloat32Array = (piece.source.get_meta(BmsReader.CLOTH_META) as Dictionary)["params"]
			var w := Vector3(params[1], params[2], params[3]) if params[0] != 0.0 else wind
			piece.sim.call("step", steps, w, p)
			steps_run += steps
		RenderingServer.mesh_surface_update_vertex_region(piece.mesh.get_rid(), 0, 0, piece.sim.call("vertex_data"))
		var box: AABB = piece.sim.call("bounds")
		for mi in piece.mis:
			(mi as MeshInstance3D).custom_aabb = box.grow(1.0)

## Whether a point is inside the view, VIEW_RADIUS around it.
static func _in_view(planes: Array[Plane], at: Vector3) -> bool:
	for pl in planes:
		if pl.distance_to(at) > VIEW_RADIUS:
			return false
	return true

## `-(+0xa0)` from the host's yaw (FUN_00c26e70): (-sin t, 0, cos t).
static func host_wind(host: Node3D) -> Vector3:
	var z := host.global_transform.basis.z
	var t := -atan2(z.x, z.z)
	return Vector3(-sin(t), 0.0, cos(t))

## Far, off or hidden: the meshes on their own skin.
func _far(h: Host) -> void:
	if h.state == 1:
		for piece in h.pieces:
			for mi in piece.mis:
				if is_instance_valid(mi) and (mi as MeshInstance3D).has_meta(ORIGINAL_META):
					_restore(mi)
	h.state = 2

func _drop(h: Host) -> void:
	for piece in h.pieces:
		for mi in piece.mis:
			if is_instance_valid(mi) and (mi as MeshInstance3D).has_meta(ORIGINAL_META):
				_restore(mi)
	h.pieces.clear()
	h.state = 0
	h.count_ms = 0

## The host's cloth: one sim per cloth mesh, every shown instance of it on
## that sim's mesh. False when it has none (the host then leaves the group).
func _build(h: Host) -> bool:
	var by_mesh := {}
	for n in h.node.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		var src: Mesh = (mi.get_meta(ORIGINAL_META) as Array)[0] if mi.has_meta(ORIGINAL_META) else mi.mesh
		if src == null or not src.has_meta(BmsReader.CLOTH_META) or not mi.visible or _nested(mi, h.node):
			continue
		var key := src.get_instance_id()
		if not by_mesh.has(key):
			by_mesh[key] = []
		(by_mesh[key] as Array).append(mi)
	for key in by_mesh:
		var piece := _piece(by_mesh[key])
		if piece == null:
			h.refused += 1
			continue
		h.pieces.append(piece)
	if h.pieces.is_empty():
		h.node.remove_from_group(GROUP)
		return false
	return true

## Whether `mi` belongs to another host inside `host` (it steps it).
static func _nested(mi: Node, host: Node) -> bool:
	var at := mi.get_parent()
	while at != null and at != host:
		if at.is_in_group(GROUP):
			return true
		at = at.get_parent()
	return false

func _piece(mis: Array) -> Piece:
	var first := mis[0] as MeshInstance3D
	var o: Array = first.get_meta(ORIGINAL_META) if first.has_meta(ORIGINAL_META) else [first.mesh, first.skin, first.skeleton]
	var src: Mesh = o[0]
	var skin: Skin = o[1]
	var path: NodePath = o[2]
	if src.get_surface_count() != 1:
		print("ClothDriver: %s -- %d surfaces, not simulated" % [first.name, src.get_surface_count()])
		return null
	var skel: Skeleton3D = first.get_node_or_null(path) as Skeleton3D if skin != null else null
	if skin != null and skel == null:
		print("ClothDriver: %s -- skinned to no skeleton, not simulated" % first.name)
		return null
	var arrays := src.surface_get_arrays(0)
	var bones = arrays[Mesh.ARRAY_BONES]
	var weights = arrays[Mesh.ARRAY_WEIGHTS]
	var dyn_arrays := arrays.duplicate()
	dyn_arrays[Mesh.ARRAY_BONES] = null
	dyn_arrays[Mesh.ARRAY_WEIGHTS] = null
	var prim := (src as ArrayMesh).surface_get_primitive_type(0) if src is ArrayMesh else Mesh.PRIMITIVE_TRIANGLES
	var dyn := ArrayMesh.new()
	dyn.add_surface_from_arrays(prim, dyn_arrays)
	dyn.surface_set_material(0, src.surface_get_material(0))
	var surf: Dictionary = RenderingServer.mesh_get_surface(dyn.get_rid(), 0)
	var fmt := int(surf["format"])
	var n: int = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	# The stream ClothSim.vertex_data writes: positions, then normal+tangent.
	if RenderingServer.mesh_surface_get_format_vertex_stride(fmt, n) != 12 \
			or RenderingServer.mesh_surface_get_format_offset(fmt, n, Mesh.ARRAY_NORMAL) != n * 12 \
			or (surf["vertex_data"] as PackedByteArray).size() != n * 20:
		print("ClothDriver: %s -- vertex stream not positions + normal/tangent, not simulated" % first.name)
		return null
	var d := (src.get_meta(BmsReader.CLOTH_META) as Dictionary).duplicate()
	d["positions"] = arrays[Mesh.ARRAY_VERTEX]
	d["normals"] = arrays[Mesh.ARRAY_NORMAL]
	d["bones"] = bones if bones is PackedInt32Array and skin != null else PackedInt32Array()
	d["weights"] = PackedFloat32Array(weights) if weights != null and skin != null else PackedFloat32Array()
	d["vertex_data"] = surf["vertex_data"]
	var sim := ClothNative.create()
	if not bool(sim.call("setup", d)):
		print("ClothDriver: %s refused: %s" % [first.name, sim.call("last_error")])
		return null
	var piece := Piece.new()
	piece.sim = sim
	piece.mesh = dyn
	piece.source = src
	piece.skin = skin
	piece.skel_path = path
	piece.mis = mis
	piece.skeleton = skel
	if skin != null:
		for i in range(skin.get_bind_count()):
			var bone := skin.get_bind_bone(i)
			if bone < 0:
				bone = skel.find_bone(skin.get_bind_name(i))
			piece.binds.append(bone)
	return piece

## Each bind's bone pose times its bind pose (CharSelectQa.skinned_points'
## matrices), 12 floats: the basis's columns, then the origin.
static func _mats(skel: Skeleton3D, piece: Piece) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(piece.binds.size() * 12)
	for i in range(piece.binds.size()):
		var bone := piece.binds[i]
		var m := skel.get_bone_global_pose(bone) * piece.skin.get_bind_pose(i) if bone >= 0 else Transform3D.IDENTITY
		var o := i * 12
		out[o] = m.basis.x.x
		out[o + 1] = m.basis.x.y
		out[o + 2] = m.basis.x.z
		out[o + 3] = m.basis.y.x
		out[o + 4] = m.basis.y.y
		out[o + 5] = m.basis.y.z
		out[o + 6] = m.basis.z.x
		out[o + 7] = m.basis.z.y
		out[o + 8] = m.basis.z.z
		out[o + 9] = m.origin.x
		out[o + 10] = m.origin.y
		out[o + 11] = m.origin.z
	return out

static func _swap_in(piece: Piece) -> void:
	for mi_v in piece.mis:
		var mi := mi_v as MeshInstance3D
		if mi.has_meta(ORIGINAL_META):
			continue
		mi.set_meta(ORIGINAL_META, [mi.mesh, mi.skin, mi.skeleton])
		mi.skin = null
		mi.skeleton = NodePath()
		mi.mesh = piece.mesh

# --- QA ------------------------------------------------------------------------------------

## The particles of `host`'s first cloth mesh (empty when none runs).
func positions_of(host: Node3D) -> PackedVector3Array:
	var h: Host = _hosts.get(host.get_instance_id())
	if h == null or h.pieces.is_empty():
		return PackedVector3Array()
	return (h.pieces[0] as Piece).sim.call("positions")

## What the driver did, for a log line.
func describe() -> String:
	var pieces := 0
	var refused := 0
	for h in _hosts.values():
		pieces += (h as Host).pieces.size()
		refused += (h as Host).refused
	return "%d hosts, %d near, %d cloth meshes (%d refused), %d steps, %.2f ms last frame, %s" % [
		_hosts.size(), hosts_near, pieces, refused, steps_run, last_usec / 1000.0, ClothNative.status]

func _qa_print() -> void:
	print("QA CLOTH %s" % describe())
	for h in _hosts.values():
		var names := PackedStringArray()
		for piece in (h as Host).pieces:
			var off := _qa_off_skin(piece)
			names.append("%s(%d, free off the skin: mean %.3f max %.3f)" % [(piece.mis[0] as Node).name if not piece.mis.is_empty() else "?",
				(piece.sim.call("positions") as PackedVector3Array).size(), off[0], off[1]])
		if not names.is_empty():
			var node: Node3D = (h as Host).node
			print("QA CLOTH   %s state %d: %s" % [node.get_parent().name if node.get_parent() != null else node.name, (h as Host).state, ", ".join(names)])

## How far the free particles sit from where the mesh's own skin (or, rigid,
## its bind pose) puts them now, [mean, max] -- 0 for a cloth that does not move.
static func _qa_off_skin(piece: Piece) -> Array:
	var arrays := piece.source.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var bones = arrays[Mesh.ARRAY_BONES]
	var weights = arrays[Mesh.ARRAY_WEIGHTS]
	var mats := _mats(piece.skeleton, piece) if piece.skin != null else PackedFloat32Array()
	var cur: PackedVector3Array = piece.sim.call("positions")
	var pinned: PackedByteArray = (piece.source.get_meta(BmsReader.CLOTH_META) as Dictionary)["pinned"]
	var per: int = (bones as PackedInt32Array).size() / verts.size() if bones is PackedInt32Array and piece.skin != null else 0
	var total := 0.0
	var worst := 0.0
	var n := 0
	for i in range(verts.size()):
		if pinned[i] != 0:
			continue
		var p := verts[i]
		if per > 0:
			p = Vector3.ZERO
			for k in range(per):
				var w: float = weights[i * per + k]
				var b: int = bones[i * per + k]
				if w <= 0.0 or b < 0 or b * 12 + 11 >= mats.size():
					continue
				var o := b * 12
				p += (Vector3(mats[o], mats[o + 1], mats[o + 2]) * verts[i].x + Vector3(mats[o + 3], mats[o + 4], mats[o + 5]) * verts[i].y
					+ Vector3(mats[o + 6], mats[o + 7], mats[o + 8]) * verts[i].z + Vector3(mats[o + 9], mats[o + 10], mats[o + 11])) * w
		var dist := p.distance_to(cur[i])
		total += dist
		worst = maxf(worst, dist)
		n += 1
	return [total / maxf(n, 1), worst]
