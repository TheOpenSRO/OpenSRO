extends RefCounted
class_name QaShotEnv

## QA only (round 702, OURS): per-viewpoint settings for OPENSRO_QA_SHOTS and
## a screen box for named ground patches, so one boot can measure the same
## patch at several zooms with each effect on and off.
##
## A viewpoint may end in `|key=value,...` (`near@1002,1020:0,-25,45|fog=0`).
## Each viewpoint starts from the settings the run had before its first
## viewpoint, then applies its own keys:
## - a Video-tab row's key, `quality` or `brightness` (VideoOptions.apply_spec),
##   applied as Apply would (World3D._on_video_options_applied);
## - `tonemap=<n>`: Environment.tonemap_mode (0 linear, 2 Filmic);
## - `objtm=0|1` (round 706): whether the object shaders undo the tone map
##   (ObjectLight); `objdiag=1|2`: the objects' diffuse term alone / ambient
##   term alone (ObjectLight.qa_diag);
## - `sdist=<units>`: DirectionalLight3D.directional_shadow_max_distance;
## - `glow_bloom=<f>`: Environment.glow_bloom.
## - `fogprobe=1` (round 705): the fog pass draws its own measurement, opaque
##   -- red the fog amount it applies, green the view depth / 5000 it reads
##   from the depth buffer (WorldFog's qa_probe); read it with `tonemap=0` and
##   `bloom=0` so the frame shows the values as written.
## The fog is the Video tab's `fog_temporary` row.
##
## OPENSRO_QA_PATCHES="name:dx,dz,half;..." names squares on the ground
## around the player (world offsets from the player's feet, `half` units each
## way); at every `QA SHOT` the line `QA PATCH <shot> <name> x0 y0 x1 y1
## dist <d>` gives each square's box on screen (the four corners projected)
## and its distance from the camera, so a frame crop measures the same ground
## at every zoom.

const _BASE_META := &"qa_shot_env_base"

static func apply(world: Node, spec: String) -> void:
	var env: Environment = world.world_environment.environment if world.world_environment != null else null
	var light: DirectionalLight3D = world.directional_light
	if not world.has_meta(_BASE_META):
		var base := {
			"video": (world.video_options() as VideoOptions).duplicate_options(),
			"tonemap": env.tonemap_mode if env != null else 0,
			"sdist": light.directional_shadow_max_distance if light != null else 0.0,
			"glow_bloom": env.glow_bloom if env != null else 0.0,
		}
		world.set_meta(_BASE_META, base)
	var b: Dictionary = world.get_meta(_BASE_META)
	var video := (b["video"] as VideoOptions).duplicate_options()
	var video_spec := PackedStringArray()
	var tonemap: int = b["tonemap"]
	var sdist: float = b["sdist"]
	var bloom: float = b["glow_bloom"]
	var probe := false
	ObjectLight.qa_undo = -1
	var diag := 0
	for pair in spec.split(",", false):
		var kv := pair.split("=")
		if kv.size() != 2:
			continue
		var k := kv[0].strip_edges()
		var v := kv[1].strip_edges()
		match k:
			"tonemap":
				tonemap = int(v)
			"sdist":
				sdist = float(v)
			"glow_bloom":
				bloom = float(v)
			"fogprobe":
				probe = v == "1"
			"objtm":
				# Round 706: whether the object shaders undo the tone map.
				ObjectLight.qa_undo = int(v)
			"objdiag":
				diag = int(v)
			_:
				video_spec.append(pair)
	VideoOptions.apply_spec(video, ",".join(video_spec))
	ObjectLight.qa_diag = diag
	world._on_video_options_applied(video)
	ObjectLight.reapply()
	if env != null:
		env.tonemap_mode = tonemap
		env.glow_bloom = bloom
		# The fog's colour and the pass's mix follow the tone map (round 705).
		world._apply_fog()
	if light != null:
		light.directional_shadow_max_distance = sdist
	var blobs: CharacterBlobs = world.get("_character_blobs")
	var fog_pass: Node3D = world.get("_fog_pass")
	if fog_pass is MeshInstance3D and (fog_pass as MeshInstance3D).material_override is ShaderMaterial:
		((fog_pass as MeshInstance3D).material_override as ShaderMaterial).set_shader_parameter("qa_probe", probe)
	print("QA SHOT ENV '%s': tonemap %d sdist %.0f glow %s bloom %.2f fog_pass %s ssao %s shadow_map %s blobs %d" % [
		spec, tonemap, light.directional_shadow_max_distance if light != null else 0.0,
		str(env.glow_enabled) if env != null else "-", bloom,
		str(fog_pass.visible) if fog_pass != null else "-", str(env.ssao_enabled) if env != null else "-",
		str(light.shadow_enabled) if light != null else "-", blobs.shown_count() if blobs != null else -1])

## OPENSRO_QA_DEPTH="name:fx,fy;..." (round 705) names screen points as
## fractions of the view; at every `QA SHOT` the line `QA DEPTH <shot> <name>
## px <x> <y> hit <dist> depth <view depth> fog <amount> planes <start>..<end>
## <collider>` gives what a physics ray from the camera through that pixel
## hits, its view depth (along the camera's axis, what linear fog reads) and
## the fog amount the planes in force give there; `QA CAMERA` gives the
## camera's place, near and far planes and fov.
static func report_depth(world: Node, shot: String) -> void:
	var spec := OS.get_environment("OPENSRO_QA_DEPTH")
	var cam: Camera3D = world.get_viewport().get_camera_3d()
	if spec == "" or cam == null:
		return
	var near_plane: float = world.get("_fog_near_real")
	var far_plane: float = world.get("_fog_far_real")
	var size := world.get_viewport().get_visible_rect().size
	var fwd := -cam.global_transform.basis.z
	print("QA CAMERA %s at %s forward %s near %.3f far %.0f fov %.1f view %s fog planes %.0f..%.0f" % [
		shot, cam.global_position, fwd, cam.near, cam.far, cam.fov, size, near_plane, far_plane])
	var space := cam.get_world_3d().direct_space_state
	for item in spec.split(";", false):
		var parts := item.split(":")
		if parts.size() != 2:
			continue
		var nums := parts[1].split(",")
		if nums.size() != 2:
			continue
		var px := Vector2(float(nums[0]) * size.x, float(nums[1]) * size.y)
		var from := cam.project_ray_origin(px)
		var dir := cam.project_ray_normal(px)
		var q := PhysicsRayQueryParameters3D.create(from, from + dir * 8000.0)
		var exclude: Array[RID] = []
		var player: Node = world.get("player")
		if player is CollisionObject3D:
			exclude.append((player as CollisionObject3D).get_rid())
		q.exclude = exclude
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			print("QA DEPTH %s %s px %.0f %.0f no hit" % [shot, parts[0], px.x, px.y])
			continue
		var p: Vector3 = hit["position"]
		var depth := (p - cam.global_position).dot(fwd)
		var who := String((hit["collider"] as Node).get_path()) if hit["collider"] is Node else "?"
		print("QA DEPTH %s %s px %.0f %.0f hit %.1f depth %.1f fog %.3f planes %.0f..%.0f %s" % [
			shot, parts[0], px.x, px.y, from.distance_to(p), depth,
			WorldFog.amount(depth, near_plane, far_plane), near_plane, far_plane, who])

static func report_patches(world: Node, shot: String) -> void:
	var cam: Camera3D = world.get_viewport().get_camera_3d()
	var player: Node3D = world.player
	if cam == null or player == null:
		return
	# The circles shown now (round 702), each as its screen box.
	var blobs: CharacterBlobs = world.get("_character_blobs")
	if blobs != null:
		var boxes := PackedStringArray()
		for i in CharacterBlobs.MAX_BLOBS:
			var b := blobs.blob(i)
			if b == null or not b.visible:
				continue
			var half := b.global_transform.basis.get_scale().x * 0.5
			var lo := Vector2(INF, INF)
			var hi := Vector2(-INF, -INF)
			for corner in [Vector3(-half, 0, -half), Vector3(half, 0, -half), Vector3(-half, 0, half), Vector3(half, 0, half)]:
				var sp := cam.unproject_position(b.global_position + corner)
				lo = Vector2(minf(lo.x, sp.x), minf(lo.y, sp.y))
				hi = Vector2(maxf(hi.x, sp.x), maxf(hi.y, sp.y))
			boxes.append("%.0f,%.0f,%.0f,%.0f size %.1f" % [lo.x, lo.y, hi.x, hi.y, half * 2.0])
		print("QA BLOBS %s shown %d%s" % [shot, boxes.size(), (": " + "; ".join(boxes)) if not boxes.is_empty() else ""])
	var spec := OS.get_environment("OPENSRO_QA_PATCHES")
	if spec == "":
		return
	var feet := player.global_position
	for item in spec.split(";", false):
		var parts := item.split(":")
		if parts.size() != 2:
			continue
		var nums := parts[1].split(",")
		if nums.size() != 3:
			continue
		var c := feet + Vector3(float(nums[0]), 0.0, float(nums[1]))
		var h := float(nums[2])
		var lo := Vector2(INF, INF)
		var hi := Vector2(-INF, -INF)
		var behind := false
		for corner in [Vector3(-h, 0, -h), Vector3(h, 0, -h), Vector3(-h, 0, h), Vector3(h, 0, h)]:
			var p: Vector3 = c + corner
			if cam.is_position_behind(p):
				behind = true
			var s := cam.unproject_position(p)
			lo = Vector2(minf(lo.x, s.x), minf(lo.y, s.y))
			hi = Vector2(maxf(hi.x, s.x), maxf(hi.y, s.y))
		print("QA PATCH %s %s %.0f %.0f %.0f %.0f dist %.1f%s" % [shot, parts[0], lo.x, lo.y, hi.x, hi.y,
			cam.global_position.distance_to(c), " behind" if behind else ""])

## OPENSRO_QA_WATER_SORT=1 (round 780): at every `QA SHOT`, the order the
## transparent pass draws each region's terrain overlays and water in. Godot
## sorts its alpha list by render priority, then far to near by the distance
## from the camera to each instance's AABB centre, less its sorting offset
## (READ, Godot 4.7.2 render_forward_clustered.cpp `_fill_render_list` and
## `SortByReverseDepthAndPriority`; the Compatibility renderer the same). One
## line per terrain patch and water surface in view:
## `QA WATER SORT <shot> <kind> <region> priority <p> depth <d>`, then
## `QA WATER ORDER <shot> water <region> drawn before N overlay patch(es)
## [...]` -- each patch whose overlays share or follow the water's place in
## the list, i.e. paint over it where they lie under it.
static func report_water_sort(world: Node, shot: String) -> void:
	if OS.get_environment("OPENSRO_QA_WATER_SORT") == "":
		return
	var cam: Camera3D = world.get_viewport().get_camera_3d()
	if cam == null:
		return
	var eye := cam.global_position
	var frustum := cam.get_frustum()
	var waters: Array = []
	var patches: Array = []
	for group in (world as Node).get_children():
		if not (group is Node3D) or not String(group.name).begins_with("RealTerrain_"):
			continue
		var region := String(group.name).trim_prefix("RealTerrain_")
		for child in (group as Node).get_children():
			var mi := child as MeshInstance3D
			if mi == null or mi.mesh == null or not mi.is_visible_in_tree():
				continue
			var kind := String(mi.name)
			if kind != "SubPatch" and not kind.begins_with("Water"):
				continue
			var aabb := mi.global_transform * mi.get_aabb()
			if not _aabb_in_frustum(aabb, frustum):
				continue
			var depth := eye.distance_to(aabb.get_center()) - mi.sorting_offset
			var priority := 0
			var overlays := 0
			if kind == "SubPatch":
				# The overlays' priority: the lowest transparent surface's.
				priority = 1 << 30
				for s in range(mi.mesh.get_surface_count()):
					var m := mi.get_active_material(s) as BaseMaterial3D
					if m != null and m.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
						overlays += 1
						priority = mini(priority, m.render_priority)
				if overlays == 0:
					continue
				patches.append([region, priority, depth])
			else:
				var mat := mi.get_active_material(0)
				priority = mat.render_priority if mat != null else 0
				waters.append([region, priority, depth, kind])
			print("QA WATER SORT %s %s %s priority %d depth %.1f centre (%.1f, %.1f, %.1f)%s" % [
				shot, kind, region, priority, depth, aabb.get_center().x, aabb.get_center().y, aabb.get_center().z,
				(" overlays %d" % overlays) if kind == "SubPatch" else ""])
	for w in waters:
		var after := PackedStringArray()
		for p in patches:
			# Drawn after the water: a higher priority, or the same priority
			# and nearer (ties are the unstable sort's to break).
			if p[1] > w[1] or (p[1] == w[1] and p[2] <= w[2]):
				after.append("%s (%+.1f)" % [p[0], p[2] - w[2]])
		print("QA WATER ORDER %s %s %s drawn before %d overlay patch(es)%s" % [
			shot, w[3], w[0], after.size(), (": " + ", ".join(after)) if not after.is_empty() else ""])

## Whether an AABB can touch the frustum: no plane has all eight corners
## outside it (a region's box usually has every corner off screen while
## its middle is in view).
static func _aabb_in_frustum(aabb: AABB, frustum: Array[Plane]) -> bool:
	for pl in frustum:
		var outside := true
		for corner in range(8):
			if not pl.is_point_over(aabb.get_endpoint(corner)):
				outside = false
				break
		if outside:
			return false
	return true
