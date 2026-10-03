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
## - `sdist=<units>`: DirectionalLight3D.directional_shadow_max_distance;
## - `glow_bloom=<f>`: Environment.glow_bloom.
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
			_:
				video_spec.append(pair)
	VideoOptions.apply_spec(video, ",".join(video_spec))
	world._on_video_options_applied(video)
	if env != null:
		env.tonemap_mode = tonemap
		env.glow_bloom = bloom
	if light != null:
		light.directional_shadow_max_distance = sdist
	var blobs: CharacterBlobs = world.get("_character_blobs")
	var fog_pass: Node3D = world.get("_fog_pass")
	print("QA SHOT ENV '%s': tonemap %d sdist %.0f glow %s bloom %.2f fog_pass %s ssao %s shadow_map %s blobs %d" % [
		spec, tonemap, light.directional_shadow_max_distance if light != null else 0.0,
		str(env.glow_enabled) if env != null else "-", bloom,
		str(fog_pass.visible) if fog_pass != null else "-", str(env.ssao_enabled) if env != null else "-",
		str(light.shadow_enabled) if light != null else "-", blobs.shown_count() if blobs != null else -1])

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
