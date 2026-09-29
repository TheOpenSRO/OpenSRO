extends RefCounted
class_name MapAnimationProbe

## QA only (round 645 cost split): where the frame time of the animated map
## objects goes. `SRREVAMP_QA_MAPANIM_SPLIT=<frame>` with
## `SRREVAMP_QA_MAPANIM_MODE=<mode>` switches, at that frame, every
## registered object to one of the states below and halts the driver, so a
## run's `QA MAPANIM` process time before and after the frame -- against a
## `SRREVAMP_NO_MAP_ANIM=1` run for the drift -- prices that part. Each mode
## is one-way: the objects are not put back. Every mode but `census` and
## `freeze_poses` works on each object's own player, so run it with
## SRREVAMP_MAP_ANIM_NO_SHARE=1 since round 647 (a shared pose's members
## have theirs paused).
##
##   manual       every player on manual stepping, advanced here once a
##                frame (stepped()) -- `mix_usec` brackets the mixers' work
##   strip_player the players freed: the skeletons and skins stay, still
##   strip_skin   the skins unbound: the players and skeletons keep running
##   unskin_hidden the skins of the objects not drawn now (out of range or
##                never visited) unbound; the driver keeps running
##   freeze_skel  the players freed and the skeletons' processing disabled
##   stripped     players, skeletons and skins all gone: the pre-645 object
##   census       (round 647) nothing changes and the driver keeps running:
##                one `QA MAPANIM CENSUS` line -- the running objects, their
##                skinned mesh instances (front-pass twins apart), bones, and
##                the groups a shared pose could form
##   freeze_poses (round 647) every pose player -- the groups' and the lone
##                clips' -- paused where it is: the skins stay bound, nothing
##                re-skins; works with sharing on
##   share        every running copy of one clip draws from the first one's
##                skeleton (its own player and skeleton freed) -- the saving
##                a shared pose would bring, at the cost of lockstep

const MODES := ["census", "freeze_poses", "manual", "strip_player", "unskin_hidden", "freeze_skel", "strip_skin", "stripped", "share"]

static var mix_usec := 0

## Puts every object `driver` holds into `mode` and halts the driver.
static func apply(driver: MapAnimation.Driver, mode: String) -> void:
	if mode == "census":
		census(driver)
		return
	driver.halted = true
	if mode == "freeze_poses":
		for g in driver._live_groups:
			if is_instance_valid(g.player):
				g.player.active = false
		for o in driver.objects():
			if o.group == null and is_instance_valid(o.player):
				o.player.active = false
		return
	var masters := {}
	for entry in driver.entries():
		if not is_instance_valid(entry[0]) or not is_instance_valid(entry[1]):
			continue
		var player: AnimationPlayer = entry[0]
		var root: Node3D = entry[1]
		var skeleton := root.get_node_or_null(MapAnimation.SKELETON_NODE) as Skeleton3D
		var meshes := root.find_children("*", "MeshInstance3D", true, false)
		match mode:
			"manual":
				player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
			"strip_player":
				player.queue_free()
			"unskin_hidden":
				driver.halted = false
				if root.visible:
					continue
				for mi in meshes:
					(mi as MeshInstance3D).skin = null
					(mi as MeshInstance3D).skeleton = NodePath()
			"freeze_skel":
				player.queue_free()
				if skeleton != null:
					skeleton.process_mode = Node.PROCESS_MODE_DISABLED
			"strip_skin":
				for mi in meshes:
					(mi as MeshInstance3D).skin = null
					(mi as MeshInstance3D).skeleton = NodePath()
			"stripped":
				for mi in meshes:
					(mi as MeshInstance3D).skin = null
					(mi as MeshInstance3D).skeleton = NodePath()
				player.queue_free()
				if skeleton != null:
					skeleton.queue_free()
			"share":
				if not player.active or skeleton == null:
					continue
				var clip := player.get_animation(MapAnimation.CLIP_NAME)
				if not masters.has(clip):
					masters[clip] = skeleton
					continue
				var master: Skeleton3D = masters[clip]
				for mi in meshes:
					if (mi as MeshInstance3D).skin != null:
						(mi as MeshInstance3D).skeleton = (mi as MeshInstance3D).get_path_to(master)
				player.queue_free()
				skeleton.queue_free()

## Advances every active player by `delta` in "manual" mode, timing it.
static func step(driver: MapAnimation.Driver, delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	for entry in driver.entries():
		if is_instance_valid(entry[0]) and (entry[0] as AnimationPlayer).active:
			(entry[0] as AnimationPlayer).advance(delta)
	mix_usec = Time.get_ticks_usec() - t0

## The `census` mode's line (round 647): what the running clips cost the
## renderer per frame -- each skin bound to a skeleton is a bone texture
## uploaded, each skinned MeshInstance3D its own skinning pass and AABB
## update -- and how many poses a shared pose could leave: by clip alone,
## by clip and sector, and by clip and clock (what the driver shares).
static func census(driver: MapAnimation.Driver) -> void:
	var running := 0
	var skinned := 0
	var twins := 0
	var binds := 0
	var bones := 0
	var by_clip := {}
	var by_clip_sector := {}
	var by_clip_clock := {}
	var by_model := {}
	for o in driver.objects():
		if not o.running or not is_instance_valid(o.player):
			continue
		running += 1
		var player: AnimationPlayer = o.player if o.group == null else o.group.player
		by_clip[o.clip] = true
		by_clip_sector[[o.clip, o.sector]] = true
		by_clip_clock[[o.clip, player.current_animation_position]] = true
		var name := String(o.root.name).trim_prefix("Obj_")
		name = name.substr(0, name.rfind("_")) if name.rfind("_") > 0 else name
		by_model[name] = int(by_model.get(name, 0)) + 1
		if o.skeleton != null:
			bones += o.skeleton.get_bone_count()
		for pair in o.meshes:
			var mi: MeshInstance3D = pair[0]
			skinned += 1
			binds += mi.skin.get_bind_count()
			if String(mi.name).ends_with("_front"):
				twins += 1
	var models: Array = by_model.keys()
	models.sort_custom(func(a, b): return by_model[a] > by_model[b])
	var top: Array = []
	for m in models.slice(0, 8):
		top.append("%s=%d" % [m, by_model[m]])
	print("QA MAPANIM CENSUS running=%d poses=%d groups=%d skeleton_bones=%d skinned_instances=%d front_twins=%d skin_binds=%d clips=%d clip_sector_groups=%d clip_clock_groups=%d top=%s" % [
		running, driver.poses, driver.groups, bones, skinned, twins, binds, by_clip.size(), by_clip_sector.size(),
		by_clip_clock.size(), ",".join(top)])
